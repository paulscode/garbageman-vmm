/**
 * Tor-Based Peer Discovery Service
 * ==================================
 * Discovers Bitcoin nodes via Tor network using onion (.onion) addresses.
 * Implements a crawling strategy similar to how tor-only nodes bootstrap:
 * 1. Start from seed addresses (from Libre Relay's nodes_main.txt)
 * 2. Connect via SOCKS5 proxy
 * 3. Perform Bitcoin P2P handshake (version/verack/sendaddrv2/getaddr)
 * 4. Parse addr/addrv2 messages for Tor v3 addresses
 * 5. Crawl discovered peers iteratively with rate limiting
 * 
 * Based on:
 * - Bitcoin Core's Tor-only bootstrap mechanism
 * - BIP155 (addrv2 message format for Tor v3)
 * - Peter Todd's Libre Relay seed node approach
 */

import { EventEmitter } from 'events';
import { SocksClient } from 'socks';
import crypto from 'crypto';
import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';
import net from 'net';
import { loadMainnetSeeds, buildPrioritizedSeedList, ParsedSeeds } from '../lib/seed-parser.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Configuration for Tor-based peer discovery
 */
interface TorDiscoveryConfig {
  enabled: boolean;                    // Master enable/disable flag
  maxConcurrentConnections: number;     // Max simultaneous Tor connections
  maxProbesPerInterval: number;         // Max peers to probe per crawl interval
  minPeerBackoffMs: number;             // Min time between probes of same peer
  crawlIntervalMs: number;              // Time between full crawl cycles
  connectionTimeoutMs: number;          // Timeout for Tor SOCKS connection
  handshakeTimeoutMs: number;           // Timeout for Bitcoin protocol handshake
  torProxy: { host: string; port: number }; // SOCKS5 proxy config
}

const DEFAULT_CONFIG: TorDiscoveryConfig = {
  enabled: true,
  maxConcurrentConnections: 8,
  maxProbesPerInterval: 50,
  minPeerBackoffMs: 300000,  // 5 minutes between probes of same peer
  crawlIntervalMs: 3600000,  // 1 hour between full cycles
  connectionTimeoutMs: 30000, // 30 seconds for Tor (slower than clearnet)
  handshakeTimeoutMs: 20000,  // 20 seconds for handshake
  torProxy: { 
    host: process.env.TOR_PROXY_HOST || '127.0.0.1',
    port: parseInt(process.env.TOR_PROXY_PORT || '9050', 10)
  },
};

/**
 * Seed nodes loaded from Libre Relay's nodes_main.txt file
 * 
 * This file contains .onion, IPv6, and I2P addresses curated by the Libre Relay project.
 * We prioritize .onion addresses for privacy (2-3 onion : 1 other address type ratio).
 * 
 * Source: Libre Relay contrib/seeds directory
 * Update: Simply drop in a new nodes_main.txt file as Libre Relay releases updates
 * 
 * Connection flow:
 * - .onion addresses: Our Node → Tor Proxy → Tor Network → .onion Peer
 * - IPv6 addresses: Our Node → Tor Proxy → Tor Exit → IPv6 Peer (fallback)
 * - I2P addresses: Currently unsupported (no I2P proxy configured)
 */
let SEED_ADDRESSES: Array<{ host: string; port: number }> = [];

/**
 * Network type enum for BIP155
 */
enum NetworkType {
  IPV4 = 0x01,
  IPV6 = 0x02,
  TORV2 = 0x03,  // Deprecated but included for completeness
  TORV3 = 0x04,  // Tor v3 (current standard)
  I2P = 0x05,
  CJDNS = 0x06,
}

/**
 * Discovered onion peer
 */
interface OnionPeer {
  host: string;                // .onion hostname
  port: number;
  services: bigint;            // Service bits from version message
  userAgent: string;
  protocolVersion: number;
  networkType: NetworkType;
  firstSeen: number;           // Timestamp of first discovery
  lastSeen: number;            // Timestamp of last successful contact
  lastSuccess: number | null;  // Timestamp of last successful handshake
  lastProbeAttempt: number | null; // Timestamp of last probe (for backoff)
  failureCount: number;        // Consecutive failures
  isLibreRelay: boolean;
}

/**
 * Seed check result (for UI tracking)
 */
interface SeedCheckResult {
  host: string;
  port: number;
  timestamp: number;           // When the check occurred
  success: boolean;            // Whether connection succeeded
  peersReturned: number;       // Number of peer addresses returned
  userAgent?: string;          // User agent if connection succeeded
  error?: string;              // Error message if failed
}

/**
 * Bitcoin protocol constants
 */
const MAGIC_BYTES_MAINNET = Buffer.from([0xf9, 0xbe, 0xb4, 0xd9]);
const PROTOCOL_VERSION = 70016;  // Bitcoin Core 0.21+
const SERVICES_NETWORK = 1n;     // NODE_NETWORK (bit 0)
const SERVICES_WITNESS = 1n << 3n; // NODE_WITNESS (bit 3, SegWit)
const SERVICES_LIBRE_RELAY = 1n << 29n; // NODE_LIBRE_RELAY (bit 29 = 0x20000000)
// Garbageman/Libre Relay service bits: NODE_NETWORK | NODE_WITNESS | NODE_LIBRE_RELAY = 0x20000009
const SERVICES_GARBAGEMAN = SERVICES_NETWORK | SERVICES_WITNESS | SERVICES_LIBRE_RELAY;
const USER_AGENT = '/Satoshi:29.1.0/';  // Standard Bitcoin Core user agent

/**
 * Message command names
 */
const CMD_VERSION = 'version';
const CMD_VERACK = 'verack';
const CMD_SENDADDRV2 = 'sendaddrv2';
const CMD_GETADDR = 'getaddr';
const CMD_ADDR = 'addr';
const CMD_ADDRV2 = 'addrv2';

export class TorPeerDiscoveryService extends EventEmitter {
  private config: TorDiscoveryConfig;
  private peers: Map<string, OnionPeer> = new Map();  // Key: "host:port"
  private seedChecks: Map<string, SeedCheckResult> = new Map();  // Key: "host:port", deduplicated
  private isRunning = false;
  private crawlTimer?: NodeJS.Timeout;
  private torAvailable = true;  // Track if Tor proxy is reachable
  private lastTorCheck = 0;
  private currentStatus: 'idle' | 'crawling' | 'waiting' | 'error' = 'idle';
  private dataDir: string;
  private seedsLoaded = false;

  constructor(config: Partial<TorDiscoveryConfig> = {}, dataDir = './data/peers') {
    super();
    this.config = { ...DEFAULT_CONFIG, ...config };
    this.dataDir = dataDir;
    this.loadPersistedPeers();
    this.loadSeedAddresses();
  }

  /**
   * Load seed addresses from Libre Relay's nodes_main.txt file
   */
  private async loadSeedAddresses(): Promise<void> {
    try {
      // Resolve path relative to project root, not dist directory
      const projectRoot = path.resolve(__dirname, '../..');
      const seedsDataDir = path.join(projectRoot, 'data/seeds');
      console.log(`[TorPeerDiscovery] Loading seed addresses from ${seedsDataDir}`);
      
      const parsedSeeds = await loadMainnetSeeds(seedsDataDir);
      
      // Build prioritized list (2-3 .onion : 1 other address type)
      SEED_ADDRESSES = buildPrioritizedSeedList(parsedSeeds);
      
      this.seedsLoaded = true;
      console.log(`[TorPeerDiscovery] Loaded ${SEED_ADDRESSES.length} seed addresses (${parsedSeeds.onion.length} onion, ${parsedSeeds.ipv6.length} IPv4/IPv6)`);
    } catch (error) {
      console.error('[TorPeerDiscovery] Failed to load seed addresses:', error);
      console.error('[TorPeerDiscovery] Peer discovery will rely only on previously discovered peers');
      SEED_ADDRESSES = [];
    }
  }

  /**
   * Start the discovery service
   */
  async start(): Promise<void> {
    if (this.isRunning) {
      console.log('[TorPeerDiscovery] Already running');
      return;
    }

    console.log('[TorPeerDiscovery] Starting Tor-based peer discovery');
    
    // Wait for seeds to load if not already loaded
    if (!this.seedsLoaded) {
      await this.loadSeedAddresses();
    }
    
    // Check if Tor is available
    await this.checkTorAvailability();
    
    if (!this.torAvailable) {
      console.error('[TorPeerDiscovery] Tor proxy not available - discovery disabled');
      this.currentStatus = 'error';
      this.emit('tor-unavailable');
      return;
    }

    this.isRunning = true;
    this.currentStatus = 'crawling';
    this.runCrawlCycle();
  }

  /**
   * Stop the discovery service
   */
  stop(): void {
    this.isRunning = false;
    if (this.crawlTimer) {
      clearTimeout(this.crawlTimer);
    }
    this.currentStatus = 'idle';
    console.log('[TorPeerDiscovery] Stopped');
  }

  /**
   * Get current status
   */
  getStatus() {
    return {
      enabled: this.config.enabled,
      running: this.isRunning,
      status: this.currentStatus,
      torAvailable: this.torAvailable,
      totalPeers: this.peers.size,
      successfulPeers: Array.from(this.peers.values()).filter(p => p.lastSuccess !== null).length,
    };
  }

  /**
   * Get discovered onion peers
   */
  getPeers(): OnionPeer[] {
    return Array.from(this.peers.values());
  }

  /**
   * Get seed check history (most recent first, deduplicated)
   * @param limit Maximum number of results to return (default: 100)
   */
  getSeedChecks(limit: number = 100): SeedCheckResult[] {
    return Array.from(this.seedChecks.values())
      .sort((a, b) => b.timestamp - a.timestamp)
      .slice(0, limit);
  }

  /**
   * Clean up old seed check entries to prevent unbounded memory growth
   * Keeps only the most recent maxEntries
   */
  private cleanupOldSeedChecks(maxEntries: number = 500): void {
    if (this.seedChecks.size <= maxEntries) {
      return;
    }

    // Get sorted entries (oldest first)
    const entries = Array.from(this.seedChecks.entries())
      .sort((a, b) => a[1].timestamp - b[1].timestamp);

    // Calculate how many to remove
    const toRemove = this.seedChecks.size - maxEntries;

    // Remove oldest entries
    for (let i = 0; i < toRemove; i++) {
      this.seedChecks.delete(entries[i][0]);
    }

    console.log(`[TorPeerDiscovery] Cleaned up ${toRemove} old seed check entries (${this.seedChecks.size} remaining)`);
  }

  /**
   * Get random onion peers for connection
   */
  getRandomPeers(count: number, filters?: { libreRelayOnly?: boolean }): OnionPeer[] {
    let candidates = Array.from(this.peers.values())
      .filter(p => p.lastSuccess !== null && p.failureCount < 5);

    if (filters?.libreRelayOnly) {
      candidates = candidates.filter(p => p.isLibreRelay);
    }

    // Shuffle and return requested count
    const shuffled = candidates.sort(() => Math.random() - 0.5);
    return shuffled.slice(0, count);
  }

  /**
   * Add test peers for development/testing
   */
  addTestPeers(): void {
    const testPeers: OnionPeer[] = [
      // Libre Relay Tor peers
      {
        host: 'libretest1abcdefgh.onion',
        port: 8333,
        services: (1n << 29n) | 1033n,  // Bit 29 for NODE_LIBRE_RELAY
        userAgent: '/Satoshi:29.0.0/',
        protocolVersion: 70016,
        networkType: NetworkType.TORV3,
        isLibreRelay: true,
        firstSeen: Date.now() - 86400000,
        lastSeen: Date.now() - 60000,
        lastProbeAttempt: Date.now() - 60000,
        lastSuccess: Date.now() - 60000,
        failureCount: 0,
      },
      {
        host: 'libretest2ijklmnop.onion',
        port: 8333,
        services: (1n << 29n) | 1033n,  // Bit 29 for NODE_LIBRE_RELAY
        userAgent: '/Satoshi:28.5.0/',
        protocolVersion: 70016,
        networkType: NetworkType.TORV3,
        isLibreRelay: true,
        firstSeen: Date.now() - 172800000,
        lastSeen: Date.now() - 120000,
        lastProbeAttempt: Date.now() - 120000,
        lastSuccess: Date.now() - 120000,
        failureCount: 0,
      },
      {
        host: 'libretest3qrstuvwx.onion',
        port: 8333,
        services: (1n << 29n) | 1033n,  // Bit 29 for NODE_LIBRE_RELAY
        userAgent: '/Satoshi:27.1.0/',
        protocolVersion: 70016,
        networkType: NetworkType.TORV3,
        isLibreRelay: true,
        firstSeen: Date.now() - 259200000,
        lastSeen: Date.now() - 180000,
        lastProbeAttempt: Date.now() - 180000,
        lastSuccess: Date.now() - 180000,
        failureCount: 0,
      },
      {
        host: 'libretest4yz123456.onion',
        port: 8333,
        services: (1n << 29n) | 1033n,  // Bit 29 for NODE_LIBRE_RELAY
        userAgent: '/Satoshi:29.1.0/',
        protocolVersion: 70016,
        networkType: NetworkType.TORV3,
        isLibreRelay: true,
        firstSeen: Date.now() - 345600000,
        lastSeen: Date.now() - 240000,
        lastProbeAttempt: Date.now() - 240000,
        lastSuccess: Date.now() - 240000,
        failureCount: 0,
      },
      {
        host: 'libretest5abcdef78.onion',
        port: 8333,
        services: (1n << 29n) | 1033n,  // Bit 29 for NODE_LIBRE_RELAY
        userAgent: '/Satoshi:28.0.0/',
        protocolVersion: 70016,
        networkType: NetworkType.TORV3,
        isLibreRelay: true,
        firstSeen: Date.now() - 432000000,
        lastSeen: Date.now() - 300000,
        lastProbeAttempt: Date.now() - 300000,
        lastSuccess: Date.now() - 300000,
        failureCount: 0,
      },
      // Non-Libre Relay Tor peers (Core v30+, etc)
      {
        host: 'coretest1ghijklmn.onion',
        port: 8333,
        services: 1033n,
        userAgent: '/Satoshi:30.0.0/',
        protocolVersion: 70016,
        networkType: NetworkType.TORV3,
        isLibreRelay: false,
        firstSeen: Date.now() - 86400000,
        lastSeen: Date.now() - 60000,
        lastProbeAttempt: Date.now() - 60000,
        lastSuccess: Date.now() - 60000,
        failureCount: 0,
      },
      {
        host: 'coretest2opqrstuv.onion',
        port: 8333,
        services: 1033n,
        userAgent: '/Satoshi:31.1.0/',
        protocolVersion: 70016,
        networkType: NetworkType.TORV3,
        isLibreRelay: false,
        firstSeen: Date.now() - 172800000,
        lastSeen: Date.now() - 120000,
        lastProbeAttempt: Date.now() - 120000,
        lastSuccess: Date.now() - 120000,
        failureCount: 0,
      },
    ];

    for (const peer of testPeers) {
      this.peers.set(peer.host, peer);
    }

    console.log(`[TorPeerDiscovery] Added ${testPeers.length} test peers (${testPeers.filter(p => p.isLibreRelay).length} Libre Relay, ${testPeers.filter(p => !p.isLibreRelay).length} other)`);
    this.persistPeers();
  }

  /**
   * Clear all test peers
   */
  clearAllPeers(): void {
    const count = this.peers.size;
    this.peers.clear();
    console.log(`[TorPeerDiscovery] Cleared ${count} peers`);
    this.persistPeers();
  }

  /**
   * Check if Tor SOCKS proxy is available
   */
  private async checkTorAvailability(): Promise<boolean> {
    const now = Date.now();
    
    // Cache check results for 60 seconds
    if (now - this.lastTorCheck < 60000) {
      return this.torAvailable;
    }

    this.lastTorCheck = now;

    try {
      // Try to connect to Tor SOCKS proxy
      const socket = new net.Socket();
      
      await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => {
          socket.destroy();
          reject(new Error('Timeout'));
        }, 5000);

        socket.connect(this.config.torProxy.port, this.config.torProxy.host, () => {
          clearTimeout(timeout);
          socket.destroy();
          resolve();
        });

        socket.on('error', (err) => {
          clearTimeout(timeout);
          reject(err);
        });
      });

      this.torAvailable = true;
      return true;
    } catch (error) {
      console.error('[TorPeerDiscovery] Tor proxy check failed:', error);
      this.torAvailable = false;
      return false;
    }
  }

  /**
   * Main crawl cycle
   */
  private async runCrawlCycle(): Promise<void> {
    while (this.isRunning) {
      try {
        this.currentStatus = 'crawling';
        
        // Check Tor availability
        await this.checkTorAvailability();
        
        if (!this.torAvailable) {
          console.error('[TorPeerDiscovery] Tor proxy unavailable - pausing');
          this.currentStatus = 'error';
          this.emit('tor-unavailable');
          
          // Wait before retrying
          await this.sleep(60000);  // 1 minute retry
          continue;
        }

        // Build probe queue from seeds + discovered peers
        const probeQueue = this.buildProbeQueue();
        
        console.log(`[TorPeerDiscovery] Starting crawl with ${probeQueue.length} peers in queue`);
        
        // Probe peers in batches with concurrency control
        const probeResults = await this.probePeersInBatches(probeQueue);
        
        console.log(`[TorPeerDiscovery] Crawl complete: ${probeResults.successful} successful, ${probeResults.failed} failed`);
        
        // Persist discovered peers
        await this.persistPeers();
        
        // Clean up old seed check entries to prevent unbounded memory growth
        this.cleanupOldSeedChecks(500);
        
        // Emit crawl complete event
        this.emit('crawl-complete', {
          totalPeers: this.peers.size,
          successful: probeResults.successful,
          failed: probeResults.failed,
        });
        
        // Wait for next crawl cycle
        this.currentStatus = 'waiting';
        await this.sleep(this.config.crawlIntervalMs);
        
      } catch (error) {
        console.error('[TorPeerDiscovery] Error in crawl cycle:', error);
        this.currentStatus = 'error';
        await this.sleep(60000); // Wait 1 minute on error
      }
    }
  }

  /**
   * Build queue of peers to probe
   * 
   * Includes seed addresses (prioritizing .onion) and discovered peers
   */
  private buildProbeQueue(): Array<{ host: string; port: number }> {
    const now = Date.now();
    const queue: Array<{ host: string; port: number }> = [];

    // Include seed addresses (already prioritized with .onion addresses favored)
    if (SEED_ADDRESSES.length > 0) {
      queue.push(...SEED_ADDRESSES);
    }

    // Add discovered peers that haven't been probed recently
    for (const peer of this.peers.values()) {
      const timeSinceLastProbe = peer.lastProbeAttempt 
        ? now - peer.lastProbeAttempt 
        : Infinity;

      if (timeSinceLastProbe >= this.config.minPeerBackoffMs) {
        queue.push({ host: peer.host, port: peer.port });
      }
    }

    // Shuffle for additional randomness while maintaining .onion priority from seeds
    for (let i = queue.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [queue[i], queue[j]] = [queue[j], queue[i]];
    }

    // Limit to max probes per interval
    return queue.slice(0, this.config.maxProbesPerInterval);
  }

  /**
   * Probe peers in batches with concurrency control
   */
  private async probePeersInBatches(
    queue: Array<{ host: string; port: number }>
  ): Promise<{ successful: number; failed: number }> {
    let successful = 0;
    let failed = 0;

    for (let i = 0; i < queue.length; i += this.config.maxConcurrentConnections) {
      const batch = queue.slice(i, i + this.config.maxConcurrentConnections);
      
      const results = await Promise.allSettled(
        batch.map(peer => this.probePeer(peer.host, peer.port))
      );

      results.forEach(result => {
        if (result.status === 'fulfilled' && result.value) {
          successful++;
        } else {
          failed++;
        }
      });
    }

    return { successful, failed };
  }

  /**
   * Probe a single onion peer
   */
  /**
   * Probe a single peer via Tor
   * 
   * This works for BOTH clearnet and onion addresses:
   * - Clearnet IPs: Tor routes through exit node
   * - Onion addresses: Tor routes through hidden service
   * 
   * Our real IP is never exposed in either case.
   */
  private async probePeer(host: string, port: number): Promise<boolean> {
    const peerKey = `${host}:${port}`;
    const now = Date.now();

    console.log(`[TorPeerDiscovery] Probing ${peerKey} via Tor`);

    try {
      // Update probe attempt time
      const existingPeer = this.peers.get(peerKey);
      if (existingPeer) {
        existingPeer.lastProbeAttempt = now;
      }

      // Connect via Tor SOCKS proxy (works for both clearnet and onion)
      const connection = await this.connectViaTor(host, port);
      
      // Perform Bitcoin handshake
      const peerInfo = await this.performHandshake(connection);
      
      // Request peer addresses
      const discoveredAddresses = await this.requestAddresses(connection);
      
      connection.socket.destroy();

      // Update or create peer entry
      const peer: OnionPeer = existingPeer || {
        host,
        port,
        services: 0n,
        userAgent: '',
        protocolVersion: 0,
        networkType: NetworkType.TORV3,
        firstSeen: now,
        lastSeen: now,
        lastSuccess: null,
        lastProbeAttempt: now,
        failureCount: 0,
        isLibreRelay: false,
      };

      peer.services = peerInfo.services;
      peer.userAgent = peerInfo.userAgent;
      peer.protocolVersion = peerInfo.version;
      peer.lastSeen = now;
      peer.lastSuccess = now;
      peer.failureCount = 0;
      // Check if NODE_LIBRE_RELAY bit (bit 34) is set in services field
      peer.isLibreRelay = (peerInfo.services & SERVICES_LIBRE_RELAY) !== 0n;

      this.peers.set(peerKey, peer);

      // Process discovered addresses
      this.processDiscoveredAddresses(discoveredAddresses);

      // Track seed check result (deduplicated by peerKey)
      this.seedChecks.set(peerKey, {
        host,
        port,
        timestamp: now,
        success: true,
        peersReturned: discoveredAddresses.length,
        userAgent: peerInfo.userAgent,
      });

      console.log(`[TorPeerDiscovery] Successfully probed ${peerKey}: ${peerInfo.userAgent} (services:0x${peerInfo.services.toString(16)}, LR:${peer.isLibreRelay})`);
      
      return true;

    } catch (error) {
      console.error(`[TorPeerDiscovery] Failed to probe ${peerKey}:`, error instanceof Error ? error.message : error);
      
      // Update failure count
      const peer = this.peers.get(peerKey);
      if (peer) {
        peer.failureCount++;
        peer.lastProbeAttempt = now;
      }

      // Track failed seed check (deduplicated by peerKey)
      this.seedChecks.set(peerKey, {
        host,
        port,
        timestamp: now,
        success: false,
        peersReturned: 0,
        error: error instanceof Error ? error.message : String(error),
      });
      
      return false;
    }
  }

  /**
   * Connect to peer via Tor SOCKS5 proxy
   * 
   * SECURITY NOTE: This method connects exclusively through the configured Tor
   * SOCKS5 proxy. Works for both:
   * - Clearnet IPs: Tor creates exit node connection, hiding our real IP
   * - Onion addresses: Tor routes through hidden service
   * 
   * No direct connections are ever made to Bitcoin peers.
   */
  private async connectViaTor(host: string, port: number): Promise<{ socket: net.Socket }> {
    try {
      const result = await SocksClient.createConnection({
        proxy: {
          host: this.config.torProxy.host,
          port: this.config.torProxy.port,
          type: 5,  // SOCKS5
        },
        command: 'connect',
        destination: {
          host,
          port,
        },
        timeout: this.config.connectionTimeoutMs,
      });

      return { socket: result.socket };
    } catch (error) {
      throw new Error(`Tor connection failed: ${error instanceof Error ? error.message : 'Unknown error'}`);
    }
  }

  /**
   * Perform Bitcoin P2P handshake (version/verack/sendaddrv2)
   */
  private async performHandshake(connection: { socket: net.Socket }): Promise<{
    version: number;
    services: bigint;
    userAgent: string;
  }> {
    const socket = connection.socket;
    
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        socket.destroy();
        reject(new Error('Handshake timeout'));
      }, this.config.handshakeTimeoutMs);

      let receivedVersion = false;
      let versionData: any = null;

      const dataHandler = (data: Buffer) => {
        try {
          // Parse Bitcoin protocol messages
          const messages = this.parseMessages(data);
          
          for (const msg of messages) {
            if (msg.command === CMD_VERSION) {
              try {
                versionData = this.parseVersionMessage(msg.payload);
              } catch (parseError) {
                // Log the problematic version message for debugging
                console.error(`[TorPeerDiscovery] Failed to parse VERSION message. Error: ${parseError instanceof Error ? parseError.message : parseError}`);
                console.error(`[TorPeerDiscovery] VERSION payload length: ${msg.payload.length}`);
                console.error(`[TorPeerDiscovery] VERSION payload hex (first 200 bytes): ${msg.payload.toString('hex').substring(0, 400)}`);
                throw parseError;
              }
              
              // Send verack
              this.sendMessage(socket, CMD_VERACK, Buffer.alloc(0));
              
              // Send sendaddrv2 (signal BIP155 support)
              this.sendMessage(socket, CMD_SENDADDRV2, Buffer.alloc(0));
              
              receivedVersion = true;
            } else if (msg.command === CMD_VERACK && receivedVersion) {
              clearTimeout(timeout);
              socket.removeListener('data', dataHandler);
              
              resolve({
                version: versionData.version,
                services: versionData.services,
                userAgent: versionData.userAgent,
              });
            }
          }
        } catch (error) {
          clearTimeout(timeout);
          socket.removeListener('data', dataHandler);
          reject(error);
        }
      };

      socket.on('data', dataHandler);
      socket.on('error', (error) => {
        clearTimeout(timeout);
        socket.removeListener('data', dataHandler);
        reject(error);
      });

      // Send version message
      this.sendVersionMessage(socket);
    });
  }

  /**
   * Request peer addresses using getaddr
   */
  private async requestAddresses(connection: { socket: net.Socket }): Promise<Array<{
    host: string;
    port: number;
    services: bigint;
    networkType: NetworkType;
  }>> {
    const socket = connection.socket;
    
    return new Promise((resolve) => {
      const timeout = setTimeout(() => {
        socket.removeListener('data', dataHandler);
        resolve([]);  // Return empty on timeout
      }, 10000);  // 10 second timeout for addr response

      const addresses: Array<{
        host: string;
        port: number;
        services: bigint;
        networkType: NetworkType;
      }> = [];

      const dataHandler = (data: Buffer) => {
        try {
          const messages = this.parseMessages(data);
          
          for (const msg of messages) {
            if (msg.command === CMD_ADDR) {
              const addrs = this.parseAddrMessage(msg.payload);
              addresses.push(...addrs);
            } else if (msg.command === CMD_ADDRV2) {
              const addrs = this.parseAddrV2Message(msg.payload);
              addresses.push(...addrs);
              
              // Got addrv2 response, we're done
              clearTimeout(timeout);
              socket.removeListener('data', dataHandler);
              resolve(addresses);
              return;
            }
          }
        } catch (error) {
          console.error('[TorPeerDiscovery] Error parsing address messages:', error);
        }
      };

      socket.on('data', dataHandler);

      // Send getaddr message
      this.sendMessage(socket, CMD_GETADDR, Buffer.alloc(0));
    });
  }

  /**
   * Send Bitcoin protocol version message
   */
  private sendVersionMessage(socket: net.Socket): void {
    // Calculate required buffer size:
    // 4 (version) + 8 (services) + 8 (timestamp) + 8 (addr_recv services) + 
    // 16 (addr_recv IP) + 2 (addr_recv port) + 26 (addr_from) + 8 (nonce) + 
    // 1 (user_agent length byte) + user_agent.length + 4 (start_height) + 1 (relay)
    const userAgentBuf = Buffer.from(USER_AGENT, 'utf8');
    const bufferSize = 4 + 8 + 8 + 8 + 16 + 2 + 26 + 8 + 1 + userAgentBuf.length + 4 + 1;
    const payload = Buffer.alloc(bufferSize);
    let offset = 0;

    // version (int32)
    payload.writeInt32LE(PROTOCOL_VERSION, offset);
    offset += 4;

    // services (uint64) - Advertise as Garbageman/Libre Relay node
    payload.writeBigUInt64LE(SERVICES_GARBAGEMAN, offset);
    offset += 8;

    // timestamp (int64)
    payload.writeBigInt64LE(BigInt(Math.floor(Date.now() / 1000)), offset);
    offset += 8;

    // addr_recv services (uint64)
    payload.writeBigUInt64LE(SERVICES_NETWORK, offset);
    offset += 8;

    // addr_recv IP (16 bytes IPv6-mapped IPv4, all zeros for Tor)
    offset += 16;

    // addr_recv port (uint16 big-endian)
    payload.writeUInt16BE(8333, offset);
    offset += 2;

    // addr_from (same format, all zeros)
    offset += 26;

    // nonce (uint64, random)
    const nonce = crypto.randomBytes(8);
    nonce.copy(payload, offset);
    offset += 8;

    // user_agent (var_str)
    payload[offset++] = userAgentBuf.length;
    userAgentBuf.copy(payload, offset);
    offset += userAgentBuf.length;

    // start_height (int32)
    payload.writeInt32LE(0, offset);
    offset += 4;

    // relay (bool)
    payload[offset] = 1;

    this.sendMessage(socket, CMD_VERSION, payload);
  }

  /**
   * Send a Bitcoin protocol message
   */
  private sendMessage(socket: net.Socket, command: string, payload: Buffer): void {
    const header = Buffer.alloc(24);
    let offset = 0;

    // Magic bytes
    MAGIC_BYTES_MAINNET.copy(header, offset);
    offset += 4;

    // Command (12 bytes, null-padded)
    header.write(command, offset, 12, 'ascii');
    offset += 12;

    // Payload length
    header.writeUInt32LE(payload.length, offset);
    offset += 4;

    // Checksum (first 4 bytes of double SHA256)
    const checksum = crypto.createHash('sha256')
      .update(crypto.createHash('sha256').update(payload).digest())
      .digest()
      .slice(0, 4);
    checksum.copy(header, offset);

    socket.write(Buffer.concat([header, payload]));
  }

  /**
   * Parse Bitcoin protocol messages from buffer
   */
  private parseMessages(data: Buffer): Array<{ command: string; payload: Buffer }> {
    const messages: Array<{ command: string; payload: Buffer }> = [];
    let offset = 0;

    while (offset + 24 <= data.length) {
      // Check magic bytes
      if (!data.slice(offset, offset + 4).equals(MAGIC_BYTES_MAINNET)) {
        break;
      }

      // Parse command
      const command = data.slice(offset + 4, offset + 16).toString('ascii').replace(/\0/g, '');
      
      // Parse payload length
      const payloadLength = data.readUInt32LE(offset + 16);
      
      // Validate payload length is reasonable (max 32MB per Bitcoin protocol)
      const MAX_MESSAGE_SIZE = 32 * 1024 * 1024;
      if (payloadLength > MAX_MESSAGE_SIZE) {
        console.error(`[TorPeerDiscovery] Invalid payload length ${payloadLength} for command "${command}" (max ${MAX_MESSAGE_SIZE})`);
        break;
      }
      
      // Check if we have full message
      if (offset + 24 + payloadLength > data.length) {
        break;
      }

      // Extract payload
      const payload = data.slice(offset + 24, offset + 24 + payloadLength);
      
      messages.push({ command, payload });
      offset += 24 + payloadLength;
    }

    return messages;
  }

  /**
   * Parse version message payload
   */
  private parseVersionMessage(payload: Buffer): {
    version: number;
    services: bigint;
    userAgent: string;
  } {
    try {
      let offset = 0;

      // Check minimum payload size
      if (payload.length < 20) {
        throw new Error(`Version message too short: ${payload.length} bytes`);
      }

      const version = payload.readInt32LE(offset);
      offset += 4;

      const services = payload.readBigUInt64LE(offset);
      offset += 8;

      // Skip timestamp (8 bytes)
      offset += 8;
      
      // Skip addr_recv (26 bytes) if present
      if (offset + 26 <= payload.length) {
        offset += 26;
      }
      
      // Skip addr_from (26 bytes) if present
      if (offset + 26 <= payload.length) {
        offset += 26;
      }
      
      // Skip nonce (8 bytes) if present
      if (offset + 8 <= payload.length) {
        offset += 8;
      }

      // Parse user agent if present
      let userAgent = '';
      if (offset < payload.length) {
        const userAgentLen = payload[offset++];
        if (offset + userAgentLen <= payload.length) {
          userAgent = payload.slice(offset, offset + userAgentLen).toString('utf8');
        }
      }

      return { version, services, userAgent: userAgent || 'Unknown' };
    } catch (error) {
      // Log the problematic payload for debugging
      console.error(`[TorPeerDiscovery] Failed to parse version message. Error: ${error instanceof Error ? error.message : error}`);
      console.error(`[TorPeerDiscovery] Payload length: ${payload.length}, Payload hex: ${payload.toString('hex')}`);
      throw error;
    }
  }

  /**
   * Parse legacy addr message (IPv4/IPv6, limited Tor support)
   */
  private parseAddrMessage(payload: Buffer): Array<{
    host: string;
    port: number;
    services: bigint;
    networkType: NetworkType;
  }> {
    const addresses: Array<{
      host: string;
      port: number;
      services: bigint;
      networkType: NetworkType;
    }> = [];

    try {
      let offset = 0;
      const count = this.readVarInt(payload, offset);
      offset += this.varIntSize(count);

      for (let i = 0; i < Number(count); i++) {
        // Check if we have enough data for this entry (4+8+16+2 = 30 bytes)
        if (offset + 30 > payload.length) {
          break;
        }
        
        // Skip time
        offset += 4;

        const services = payload.readBigUInt64LE(offset);
        offset += 8;

        // Parse IP (16 bytes)
        const ip = payload.slice(offset, offset + 16);
        offset += 16;

        const port = payload.readUInt16BE(offset);
        offset += 2;

        // Convert IP to address (skip if not relevant)
        // For Tor discovery, we mainly rely on addrv2
      }
    } catch (error) {
      console.error(`[TorPeerDiscovery] Error parsing ADDR message: ${error instanceof Error ? error.message : error}`);
    }

    return addresses;
  }

  /**
   * Parse BIP155 addrv2 message (Tor v3 support)
   */
  private parseAddrV2Message(payload: Buffer): Array<{
    host: string;
    port: number;
    services: bigint;
    networkType: NetworkType;
  }> {
    const addresses: Array<{
      host: string;
      port: number;
      services: bigint;
      networkType: NetworkType;
    }> = [];

    try {
      let offset = 0;
      const count = this.readVarInt(payload, offset);
      offset += this.varIntSize(count);

      for (let i = 0; i < Number(count); i++) {
        try {
          // Skip time
          offset += 4;

          // Services (compactSize uint)
          const services = this.readVarInt(payload, offset);
          offset += this.varIntSize(services);

          // Network ID
          const networkId = payload[offset++];

          // Address length
          const addrLen = payload[offset++];

          // Address bytes
          const addrBytes = payload.slice(offset, offset + addrLen);
          offset += addrLen;

          // Port
          const port = payload.readUInt16BE(offset);
          offset += 2;

          // Parse Tor v3 addresses
          if (networkId === NetworkType.TORV3 && addrLen === 32) {
            const host = this.decodeTorV3Address(addrBytes);
            addresses.push({
              host,
              port,
              services: BigInt(services),
              networkType: NetworkType.TORV3,
            });
          }
        } catch (innerError) {
          console.error(`[TorPeerDiscovery] Failed to parse individual addrv2 entry ${i}: ${innerError instanceof Error ? innerError.message : innerError}`);
          // Continue parsing other addresses
        }
      }
    } catch (error) {
      console.error(`[TorPeerDiscovery] Failed to parse addrv2 message. Error: ${error instanceof Error ? error.message : error}`);
      console.error(`[TorPeerDiscovery] Payload length: ${payload.length}, Payload hex: ${payload.toString('hex').substring(0, 200)}...`);
    }

    return addresses;
  }

  /**
   * Decode Tor v3 address from 32-byte pubkey
   */
  private decodeTorV3Address(pubkey: Buffer): string {
    // Tor v3 address encoding: base32(pubkey).onion
    const base32Chars = 'abcdefghijklmnopqrstuvwxyz234567';
    let result = '';
    let bits = 0;
    let value = 0;

    for (const byte of pubkey) {
      value = (value << 8) | byte;
      bits += 8;

      while (bits >= 5) {
        result += base32Chars[(value >>> (bits - 5)) & 0x1f];
        bits -= 5;
      }
    }

    if (bits > 0) {
      result += base32Chars[(value << (5 - bits)) & 0x1f];
    }

    return result + '.onion';
  }

  /**
   * Process newly discovered addresses
   * 
   * SECURITY NOTE: Only processes Tor v3 addresses. Clearnet IPs are
   * explicitly rejected to prevent any potential IP leakage.
   */
  private processDiscoveredAddresses(addresses: Array<{
    host: string;
    port: number;
    services: bigint;
    networkType: NetworkType;
  }>): void {
    const now = Date.now();

    for (const addr of addresses) {
      // SECURITY: Only process Tor v3 addresses - reject all others
      if (addr.networkType !== NetworkType.TORV3) {
        continue;
      }

      // SECURITY: Additional validation - must be .onion address
      if (!addr.host.endsWith('.onion')) {
        console.warn(`[TorPeerDiscovery] SECURITY: Rejecting non-onion address from peer: ${addr.host}`);
        continue;
      }

      const peerKey = `${addr.host}:${addr.port}`;
      
      if (!this.peers.has(peerKey)) {
        // New peer discovered
        this.peers.set(peerKey, {
          host: addr.host,
          port: addr.port,
          services: addr.services,
          userAgent: '',
          protocolVersion: 0,
          networkType: addr.networkType,
          firstSeen: now,
          lastSeen: now,
          lastSuccess: null,
          lastProbeAttempt: null,
          failureCount: 0,
          isLibreRelay: false,
        });

        console.log(`[TorPeerDiscovery] Discovered new peer: ${peerKey}`);
      } else {
        // Update existing peer
        const peer = this.peers.get(peerKey)!;
        peer.lastSeen = now;
      }
    }
  }

  /**
   * Read variable-length integer (Bitcoin protocol)
   */
  private readVarInt(buffer: Buffer, offset: number): number {
    const first = buffer[offset];
    
    if (first < 0xfd) {
      return first;
    } else if (first === 0xfd) {
      return buffer.readUInt16LE(offset + 1);
    } else if (first === 0xfe) {
      return buffer.readUInt32LE(offset + 1);
    } else {
      // 0xff - uint64, but we return Number
      return Number(buffer.readBigUInt64LE(offset + 1));
    }
  }

  /**
   * Get size of varint encoding
   */
  private varIntSize(value: number | bigint): number {
    const n = Number(value);
    if (n < 0xfd) return 1;
    if (n <= 0xffff) return 3;
    if (n <= 0xffffffff) return 5;
    return 9;
  }

  /**
   * Sleep utility
   */
  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Load persisted peers from disk
   */
  private async loadPersistedPeers(): Promise<void> {
    try {
      const filePath = path.join(this.dataDir, 'onion-peers.json');
      const data = await fs.readFile(filePath, 'utf8');
      const peersArray = JSON.parse(data);
      
      this.peers.clear();
      for (const peer of peersArray) {
        const peerKey = `${peer.host}:${peer.port}`;
        this.peers.set(peerKey, {
          ...peer,
          services: BigInt(peer.services),
        });
      }
      
      console.log(`[TorPeerDiscovery] Loaded ${this.peers.size} persisted peers`);
    } catch (error) {
      // File doesn't exist or is invalid - start fresh
      console.log('[TorPeerDiscovery] No persisted peers found, starting fresh');
    }
  }

  /**
   * Persist peers to disk
   */
  private async persistPeers(): Promise<void> {
    try {
      // Ensure directory exists
      await fs.mkdir(this.dataDir, { recursive: true });
      
      const filePath = path.join(this.dataDir, 'onion-peers.json');
      const peersArray = Array.from(this.peers.values()).map(peer => ({
        ...peer,
        services: peer.services.toString(),  // Convert BigInt to string for JSON
      }));
      
      await fs.writeFile(filePath, JSON.stringify(peersArray, null, 2), 'utf8');
    } catch (error) {
      console.error('[TorPeerDiscovery] Failed to persist peers:', error);
    }
  }
}

// Export singleton instance
export const torPeerDiscoveryService = new TorPeerDiscoveryService();
