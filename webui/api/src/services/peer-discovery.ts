/**
 * Peer Discovery Service
 * ======================
 * Background worker that discovers Bitcoin nodes from DNS seeds,
 * categorizes them by capabilities (Libre Relay, Core v30+),
 * and maintains persistent lists for use in instance creation.
 */

import dns from 'dns';
import { promisify } from 'util';
import net from 'net';
import { EventEmitter } from 'events';
import crypto from 'crypto';
import { SocksClient } from 'socks';

const dnsResolve4 = promisify(dns.resolve4);

// Bitcoin DNS seeds
const DNS_SEEDS = [
  // Potential "Libre Relay-adjacent" nodes
  'libre-relay.btc.petertodd.net',
  'seed.btc.petertodd.net',
  // Other DNS seeds
  'dnsseed.bitcoin.dashjr-list-of-p2p-nodes.us',
  'dnsseed.bluematt.me',
  'seed.bitcoinstats.com',
  'seed.bitcoin.sprovoost.nl',
  'dnsseed.emzy.de',
  'seed.bitcoin.wiz.biz',
  'seed.bitcoin.sipa.be',
  'seed.bitcoin.jonasschnelli.ch',
  'seed.mainnet.achownodes.xyz',
];

// Peer discovery configuration
const DISCOVERY_INTERVAL = 3600000; // 1 hour between full cycles
const PEER_EXPIRY_DAYS = 7; // Remove peers not seen in 7 days
const CONNECTION_TIMEOUT = 5000; // 5 seconds to connect (clearnet)
const HANDSHAKE_TIMEOUT = 10000; // 10 seconds for version handshake
const TOR_CONNECTION_TIMEOUT = 20000; // 20 seconds for Tor connections (slower)
const TOR_HANDSHAKE_TIMEOUT = 15000; // 15 seconds for Tor handshake

// Tor SOCKS proxy configuration
const TOR_PROXY_HOST = '127.0.0.1';
const TOR_PROXY_PORT = 9050;

export interface DiscoveredPeer {
  ip: string;
  port: number;
  services: bigint; // Service bits
  userAgent: string;
  version: number;
  lastSeen: number; // timestamp
  isLibreRelay: boolean;
  isCoreV30Plus: boolean;
}

export interface PeerLists {
  libreRelay: DiscoveredPeer[];
  coreV30Plus: DiscoveredPeer[];
  all: DiscoveredPeer[];
}

/**
 * Bitcoin network constants
 */
const MAGIC_BYTES_MAINNET = Buffer.from([0xf9, 0xbe, 0xb4, 0xd9]);
const NODE_NETWORK = 1n;         // Bit 0: Full node (can serve full blocks)
const NODE_WITNESS = 1n << 3n;    // Bit 3: Witness support (SegWit)
const NODE_LIBRE_RELAY = 1n << 29n; // Bit 29: Libre Relay (0x20000000)
const SERVICES_LIBRE_RELAY = NODE_LIBRE_RELAY; // For backward compatibility
// Garbageman/Libre Relay service bits: NODE_NETWORK | NODE_WITNESS | NODE_LIBRE_RELAY = 0x20000009
const SERVICES_GARBAGEMAN = NODE_NETWORK | NODE_WITNESS | NODE_LIBRE_RELAY;
const USER_AGENT_CORE_V30_REGEX = /\/Satoshi:(0\.)?(3[0-9]|[4-9][0-9])\./i; // Core v30+ (matches both "0.30" and "30")

class PeerDiscoveryService extends EventEmitter {
  private peers: Map<string, DiscoveredPeer> = new Map();
  private isRunning = false;
  private currentSeedIndex = 0;
  private discoveryTimer?: NodeJS.Timeout;
  private currentStatus: 'probing' | 'crawling' | 'waiting' | 'stopped' = 'stopped';
  private currentSeed: string | null = null;
  private nextQueryTime: number = 0;
  private queriedPeers: Set<string> = new Set(); // Track peers we've already queried with getaddr

  constructor() {
    super();
    this.loadPersistedPeers();
  }

  /**
   * Get current status for monitoring
   */
  getStatus() {
    const now = Date.now();
    return {
      isRunning: this.isRunning,
      status: this.currentStatus,
      currentSeed: this.currentSeed,
      nextSeedIn: this.currentStatus === 'waiting' && this.nextQueryTime > now 
        ? Math.ceil((this.nextQueryTime - now) / 1000) 
        : 0,
      totalPeers: this.peers.size,
    };
  }

  /**
   * Start the background discovery worker
   */
  start() {
    if (this.isRunning) {
      console.log('[PeerDiscovery] Already running');
      return;
    }

    this.isRunning = true;
    console.log('[PeerDiscovery] Starting peer discovery service');
    
    // Start discovery loop
    this.runDiscoveryCycle();
  }

  /**
   * Stop the background worker
   */
  stop() {
    this.isRunning = false;
    if (this.discoveryTimer) {
      clearTimeout(this.discoveryTimer);
    }
    console.log('[PeerDiscovery] Stopped peer discovery service');
  }

  /**
   * Main discovery cycle
   */
  private async runDiscoveryCycle() {
    while (this.isRunning) {
      try {
        // Query one DNS seed at a time
        const seed = DNS_SEEDS[this.currentSeedIndex];
        this.currentSeed = seed;
        this.currentStatus = 'probing';
        
        console.log(`[PeerDiscovery] Querying DNS seed: ${seed}`);
        
        const delayBetweenSeeds = DISCOVERY_INTERVAL / DNS_SEEDS.length;
        const { foundPeers, crawlDuration } = await this.queryDnsSeed(seed, delayBetweenSeeds);
        
        // Persist peers after each seed
        this.persistPeers();
        
        // Move to next seed
        this.currentSeedIndex = (this.currentSeedIndex + 1) % DNS_SEEDS.length;
        
        // If we completed a full cycle, clean up expired peers
        if (this.currentSeedIndex === 0) {
          this.cleanupExpiredPeers();
          this.emit('cycle-complete', this.getPeerLists());
        }
        
        // Only add delay if we got a response with peers
        if (foundPeers) {
          // Subtract crawl time from delay (but ensure at least 1 second delay)
          const remainingDelay = Math.max(1000, delayBetweenSeeds - crawlDuration);
          this.currentStatus = 'waiting';
          this.nextQueryTime = Date.now() + remainingDelay;
          
          console.log(`[PeerDiscovery] Spent ${Math.round(crawlDuration/1000)}s crawling, waiting ${Math.round(remainingDelay/1000)}s until next seed`);
          
          await new Promise(resolve => {
            this.discoveryTimer = setTimeout(resolve, remainingDelay);
          });
        } else {
          // No delay - move to next seed immediately on failure
          console.log(`[PeerDiscovery] No response from ${seed}, moving to next seed immediately`);
        }
      } catch (error) {
        console.error('[PeerDiscovery] Error in discovery cycle:', error);
        // Move to next seed immediately on error (no delay)
      }
    }
  }

  /**
   * Query a DNS seed and discover peers
   * Returns foundPeers flag and crawlDuration in milliseconds
   */
  private async queryDnsSeed(seed: string, maxCrawlTime: number): Promise<{ foundPeers: boolean; crawlDuration: number }> {
    const startTime = Date.now();
    
    try {
      let addresses: string[];
      
      // Check if this is a .onion address (direct peer, not DNS seed)
      if (seed.endsWith('.onion')) {
        // For .onion addresses, probe directly instead of DNS resolution
        console.log(`[PeerDiscovery] Probing Tor address: ${seed}`);
        addresses = [seed];
      } else {
        // Normal DNS resolution for clearnet seeds
        addresses = await dnsResolve4(seed);
      }
      
      if (addresses.length === 0) {
        console.log(`[PeerDiscovery] No addresses returned from ${seed}`);
        return { foundPeers: false, crawlDuration: Date.now() - startTime };
      }
      
      console.log(`[PeerDiscovery] Found ${addresses.length} IP(s) from ${seed}`);
      
      // Probe all peers in batches (10 at a time for controlled concurrency)
      const batchSize = 10;
      const peersBefore = this.peers.size;
      
      for (let i = 0; i < addresses.length; i += batchSize) {
        const batch = addresses.slice(i, i + batchSize);
        const probePromises = batch.map(ip => this.probePeer(ip, 8333));
        await Promise.allSettled(probePromises);
      }
      
      console.log(`[PeerDiscovery] Completed probing ${addresses.length} peer(s) from ${seed}`);
      
      // Second-level crawl: Query peers with getaddr until time runs out
      const crawlStartTime = Date.now();
      const crawlDeadline = startTime + maxCrawlTime;
      
      // Get all unqueried peers in random order
      const unqueriedPeers = Array.from(this.peers.values())
        .filter(peer => !this.queriedPeers.has(`${peer.ip}:${peer.port}`));
      
      // Shuffle for randomness
      for (let i = unqueriedPeers.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [unqueriedPeers[i], unqueriedPeers[j]] = [unqueriedPeers[j], unqueriedPeers[i]];
      }
      
      if (unqueriedPeers.length > 0) {
        // Update status to crawling
        this.currentStatus = 'crawling';
        
        console.log(`[PeerDiscovery] Crawling peers for additional addresses (max ${Math.round(maxCrawlTime/1000)}s)...`);
        
        let crawledCount = 0;
        for (const peer of unqueriedPeers) {
          // Check if we've run out of time
          if (Date.now() >= crawlDeadline) {
            console.log(`[PeerDiscovery] Crawl time limit reached, queried ${crawledCount} peers`);
            break;
          }
          
          crawledCount++;
          const peerAddresses = await this.queryPeerForAddresses(peer.ip, peer.port);
          
          if (peerAddresses.length > 0) {
            console.log(`[PeerDiscovery] Peer ${peer.ip}:${peer.port} returned ${peerAddresses.length} addresses`);
            
            // Probe the returned addresses (limit to prevent explosion)
            const limitedAddresses = peerAddresses.slice(0, 20);
            for (let i = 0; i < limitedAddresses.length; i += batchSize) {
              const batch = limitedAddresses.slice(i, i + batchSize);
              const probePromises = batch.map(addr => this.probePeer(addr.ip, addr.port));
              await Promise.allSettled(probePromises);
              
              // Check time limit again after probing
              if (Date.now() >= crawlDeadline) {
                break;
              }
            }
          }
        }
        
        if (crawledCount > 0) {
          console.log(`[PeerDiscovery] Crawled ${crawledCount} peer(s) in ${Math.round((Date.now() - crawlStartTime)/1000)}s`);
        }
      }
      
      const peersAfter = this.peers.size;
      const newPeerCount = peersAfter - peersBefore;
      const totalDuration = Date.now() - startTime;
      
      console.log(`[PeerDiscovery] Discovered ${newPeerCount} new peer(s) from ${seed} (including crawl)`);
      
      return { foundPeers: true, crawlDuration: totalDuration };
    } catch (error) {
      console.error(`[PeerDiscovery] Failed to query ${seed}:`, error);
      return { foundPeers: false, crawlDuration: Date.now() - startTime };
    }
  }

  /**
   * Query a peer for its address list using getaddr
   * Returns array of peer addresses
   */
  private async queryPeerForAddresses(ip: string, port: number): Promise<Array<{ip: string, port: number}>> {
    const peerKey = `${ip}:${port}`;
    
    // Mark as queried to avoid duplicates
    this.queriedPeers.add(peerKey);
    
    const isOnion = ip.endsWith('.onion');
    let socket: net.Socket;
    
    try {
      if (isOnion) {
        const socksOptions = {
          proxy: {
            host: TOR_PROXY_HOST,
            port: TOR_PROXY_PORT,
            type: 5 as const,
          },
          command: 'connect' as const,
          destination: {
            host: ip,
            port: port,
          },
          timeout: TOR_CONNECTION_TIMEOUT,
        };
        const info = await SocksClient.createConnection(socksOptions);
        socket = info.socket;
      } else {
        socket = new net.Socket();
        socket.connect(port, ip);
      }
    } catch (error) {
      return [];
    }
    
    return new Promise((resolve) => {

      const addresses: Array<{ip: string, port: number}> = [];
      let buffer = Buffer.alloc(0);
      let versionReceived = false;
      let verackReceived = false;
      let getaddrSent = false;
      
      const cleanup = () => {
        socket.destroy();
        resolve(addresses);
      };

      const timeoutId = setTimeout(cleanup, isOnion ? 35000 : 20000);

      socket.on('error', () => {
        clearTimeout(timeoutId);
        cleanup();
      });

      socket.on('data', (data: Buffer) => {
        buffer = Buffer.concat([buffer, data]);

        // Parse messages
        while (buffer.length >= 24) {
          const msg = this.parseMessage(buffer);
          if (!msg) break;

          if (msg.command === 'version') {
            versionReceived = true;
            // Send verack
            socket.write(this.createVerackMessage());
          }

          if (msg.command === 'verack') {
            verackReceived = true;
          }

          if (msg.command === 'addr') {
            // Parse addr message
            const parsedAddresses = this.parseAddrMessage(msg.payload);
            addresses.push(...parsedAddresses);
            
            // Got addresses, we can close
            clearTimeout(timeoutId);
            cleanup();
            return;
          }

          // Send getaddr after handshake
          if (versionReceived && verackReceived && !getaddrSent) {
            socket.write(this.createGetAddrMessage());
            getaddrSent = true;
          }

          buffer = buffer.slice(msg.totalLength);
        }
      });

      // Send version message
      if (isOnion) {
        socket.write(this.createVersionMessage(ip, port));
      } else {
        socket.on('connect', () => {
          socket.write(this.createVersionMessage(ip, port));
        });
      }
    });
  }

  /**
   * Connect to a peer and perform version handshake
   */
  private async probePeer(ip: string, port: number): Promise<void> {
    const peerKey = `${ip}:${port}`;
    const isOnion = ip.endsWith('.onion');
    
    let socket: net.Socket;
    
    try {
      if (isOnion) {
        // Use SOCKS proxy for .onion addresses
        const socksOptions = {
          proxy: {
            host: TOR_PROXY_HOST,
            port: TOR_PROXY_PORT,
            type: 5 as const,
          },
          command: 'connect' as const,
          destination: {
            host: ip,
            port: port,
          },
          timeout: TOR_CONNECTION_TIMEOUT,
        };

        const info = await SocksClient.createConnection(socksOptions);
        socket = info.socket;
      } else {
        // Direct connection for clearnet addresses
        socket = new net.Socket();
        socket.connect(port, ip);
      }
    } catch (error) {
      // Connection failed (proxy not available or connection refused)
      return;
    }
    
    return new Promise((resolve) => {

      let versionReceived = false;
      let services: bigint | null = null;
      let userAgent = '';
      let protocolVersion = 0;

      const cleanup = () => {
        socket.destroy();
        resolve();
      };

      const totalTimeout = isOnion 
        ? (TOR_CONNECTION_TIMEOUT + TOR_HANDSHAKE_TIMEOUT)
        : (CONNECTION_TIMEOUT + HANDSHAKE_TIMEOUT);
      
      const timeoutId = setTimeout(() => {
        cleanup();
      }, totalTimeout);

      socket.setTimeout(isOnion ? TOR_HANDSHAKE_TIMEOUT : CONNECTION_TIMEOUT);

      socket.on('error', () => {
        clearTimeout(timeoutId);
        cleanup();
      });

      socket.on('timeout', () => {
        clearTimeout(timeoutId);
        cleanup();
      });

      socket.on('connect', () => {
        socket.setTimeout(HANDSHAKE_TIMEOUT);
        
        // Send version message
        const versionMsg = this.createVersionMessage(ip, port);
        socket.write(versionMsg);
      });

      socket.on('data', (data) => {
        if (versionReceived) return;

        try {
          // Parse version message from peer
          const parsed = this.parseVersionMessage(data);
          if (parsed) {
            services = parsed.services;
            userAgent = parsed.userAgent;
            protocolVersion = parsed.version;
            versionReceived = true;

            // Store discovered peer
            const isLibreRelay = (services & SERVICES_LIBRE_RELAY) !== 0n;
            const isCoreV30Plus = USER_AGENT_CORE_V30_REGEX.test(userAgent);

            const peer: DiscoveredPeer = {
              ip,
              port,
              services,
              userAgent,
              version: protocolVersion,
              lastSeen: Date.now(),
              isLibreRelay,
              isCoreV30Plus,
            };

            this.peers.set(peerKey, peer);
            this.emit('peer-discovered', peer);

            console.log(`[PeerDiscovery] Discovered: ${peerKey} - ${userAgent} (services:0x${services.toString(16)}, LR:${isLibreRelay}, v30+:${isCoreV30Plus})`);
            
            clearTimeout(timeoutId);
            cleanup();
          }
        } catch (error) {
          // Ignore parse errors
        }
      });

      // For non-onion addresses, the connect event is triggered by socket.connect()
      // For onion addresses, the socket is already connected after createConnection()
      if (isOnion) {
        socket.setTimeout(HANDSHAKE_TIMEOUT);
        const versionMsg = this.createVersionMessage(ip, port);
        socket.write(versionMsg);
      }
    });
  }

  /**
   * Create a Bitcoin version message
   */
  private createVersionMessage(peerIp: string, peerPort: number): Buffer {
    const buf = Buffer.allocUnsafe(256);
    let offset = 0;

    // Magic bytes
    MAGIC_BYTES_MAINNET.copy(buf, offset);
    offset += 4;

    // Command: "version\0\0\0\0\0"
    buf.write('version', offset, 12, 'ascii');
    offset += 12;

    // Payload length (to be filled)
    const payloadLengthOffset = offset;
    offset += 4;

    // Checksum (to be filled)
    const checksumOffset = offset;
    offset += 4;

    // Payload start
    const payloadStart = offset;

    // Protocol version (70016)
    buf.writeUInt32LE(70016, offset);
    offset += 4;

    // Services - Advertise as Garbageman/Libre Relay node (NODE_NETWORK | NODE_WITNESS | NODE_LIBRE_RELAY)
    buf.writeBigUInt64LE(SERVICES_GARBAGEMAN, offset);
    offset += 8;

    // Timestamp
    buf.writeBigInt64LE(BigInt(Math.floor(Date.now() / 1000)), offset);
    offset += 8;

    // Receiver services
    buf.writeBigUInt64LE(1n, offset);
    offset += 8;

    // Receiver IP (IPv4-mapped IPv6)
    buf.fill(0, offset, offset + 10);
    buf.writeUInt16BE(0xffff, offset + 10);
    const ipParts = peerIp.split('.').map(Number);
    buf.writeUInt8(ipParts[0], offset + 12);
    buf.writeUInt8(ipParts[1], offset + 13);
    buf.writeUInt8(ipParts[2], offset + 14);
    buf.writeUInt8(ipParts[3], offset + 15);
    offset += 16;

    // Receiver port
    buf.writeUInt16BE(peerPort, offset);
    offset += 2;

    // Sender services
    buf.writeBigUInt64LE(0n, offset);
    offset += 8;

    // Sender IP (zeros)
    buf.fill(0, offset, offset + 16);
    offset += 16;

    // Sender port
    buf.writeUInt16BE(0, offset);
    offset += 2;

    // Nonce
    buf.writeBigUInt64LE(BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER)), offset);
    offset += 8;

    // User agent (compact size + string) - Standard Bitcoin Core format
    const userAgent = '/Satoshi:29.1.0/';
    buf.writeUInt8(userAgent.length, offset);
    offset += 1;
    buf.write(userAgent, offset, userAgent.length, 'ascii');
    offset += userAgent.length;

    // Start height
    buf.writeInt32LE(0, offset);
    offset += 4;

    // Relay flag
    buf.writeUInt8(0, offset);
    offset += 1;

    // Calculate payload length
    const payloadLength = offset - payloadStart;
    buf.writeUInt32LE(payloadLength, payloadLengthOffset);

    // Calculate checksum
    const payload = buf.subarray(payloadStart, offset);
    const hash1 = crypto.createHash('sha256').update(payload).digest();
    const hash2 = crypto.createHash('sha256').update(hash1).digest();
    hash2.copy(buf, checksumOffset, 0, 4);

    return buf.subarray(0, offset);
  }

  /**
   * Parse version message from peer
   */
  private parseVersionMessage(data: Buffer): { services: bigint; userAgent: string; version: number } | null {
    try {
      // Check magic bytes
      if (data.length < 24 || !data.subarray(0, 4).equals(MAGIC_BYTES_MAINNET)) {
        return null;
      }

      // Check command
      const command = data.subarray(4, 16).toString('ascii').replace(/\0/g, '');
      if (command !== 'version') {
        return null;
      }

      let offset = 24; // Skip header

      // Version
      const version = data.readUInt32LE(offset);
      offset += 4;

      // Services
      const services = data.readBigUInt64LE(offset);
      offset += 8;

      // Skip timestamp (8), addr_recv (26), addr_from (26), nonce (8)
      offset += 68;

      // User agent
      const userAgentLength = data.readUInt8(offset);
      offset += 1;
      const userAgent = data.subarray(offset, offset + userAgentLength).toString('ascii');

      return { services, userAgent, version };
    } catch {
      return null;
    }
  }

  /**
   * Create a verack message
   */
  private createVerackMessage(): Buffer {
    const buf = Buffer.allocUnsafe(24);
    let offset = 0;

    // Magic bytes
    MAGIC_BYTES_MAINNET.copy(buf, offset);
    offset += 4;

    // Command: "verack"
    buf.write('verack', offset, 12, 'ascii');
    offset += 12;

    // Payload length (0)
    buf.writeUInt32LE(0, offset);
    offset += 4;

    // Checksum for empty payload
    const emptyHash1 = crypto.createHash('sha256').update(Buffer.alloc(0)).digest();
    const emptyHash2 = crypto.createHash('sha256').update(emptyHash1).digest();
    emptyHash2.copy(buf, offset, 0, 4);

    return buf;
  }

  /**
   * Create a getaddr message
   */
  private createGetAddrMessage(): Buffer {
    const buf = Buffer.allocUnsafe(24);
    let offset = 0;

    // Magic bytes
    MAGIC_BYTES_MAINNET.copy(buf, offset);
    offset += 4;

    // Command: "getaddr"
    buf.write('getaddr', offset, 12, 'ascii');
    offset += 12;

    // Payload length (0)
    buf.writeUInt32LE(0, offset);
    offset += 4;

    // Checksum for empty payload
    const emptyHash1 = crypto.createHash('sha256').update(Buffer.alloc(0)).digest();
    const emptyHash2 = crypto.createHash('sha256').update(emptyHash1).digest();
    emptyHash2.copy(buf, offset, 0, 4);

    return buf;
  }

  /**
   * Parse a Bitcoin protocol message header
   */
  private parseMessage(data: Buffer): { command: string; payloadLength: number; payload: Buffer; totalLength: number } | null {
    if (data.length < 24) return null;

    const magic = data.slice(0, 4);
    if (!magic.equals(MAGIC_BYTES_MAINNET)) return null;

    const command = data.slice(4, 16).toString('ascii').replace(/\0/g, '');
    const payloadLength = data.readUInt32LE(16);

    if (data.length < 24 + payloadLength) return null;

    const payload = data.slice(24, 24 + payloadLength);

    return {
      command,
      payloadLength,
      payload,
      totalLength: 24 + payloadLength
    };
  }

  /**
   * Parse addr message payload
   */
  private parseAddrMessage(payload: Buffer): Array<{ip: string, port: number}> {
    const addresses: Array<{ip: string, port: number}> = [];
    
    try {
      let offset = 0;
      
      // Read count (varint - simplified for count < 253)
      const count = payload.readUInt8(offset);
      offset += 1;
      
      for (let i = 0; i < count && offset + 30 <= payload.length; i++) {
        // Skip timestamp (4 bytes)
        offset += 4;
        
        // Skip services (8 bytes)
        offset += 8;
        
        // IP address (16 bytes - IPv6 format)
        const ipBytes = payload.slice(offset, offset + 16);
        offset += 16;
        
        // Port (2 bytes, big-endian)
        const port = payload.readUInt16BE(offset);
        offset += 2;
        
        // Check if it's IPv4 (::ffff: prefix)
        if (ipBytes[10] === 0xff && ipBytes[11] === 0xff) {
          const ip = `${ipBytes[12]}.${ipBytes[13]}.${ipBytes[14]}.${ipBytes[15]}`;
          addresses.push({ ip, port });
        }
        // For IPv6 or .onion, we skip for now (would need special handling)
      }
    } catch (error) {
      // Ignore parse errors
    }
    
    return addresses;
  }

  /**
   * Remove peers that haven't been seen recently
   */
  private cleanupExpiredPeers() {
    const expiryThreshold = Date.now() - (PEER_EXPIRY_DAYS * 24 * 60 * 60 * 1000);
    let removed = 0;

    for (const [key, peer] of this.peers.entries()) {
      if (peer.lastSeen < expiryThreshold) {
        this.peers.delete(key);
        removed++;
      }
    }

    if (removed > 0) {
      console.log(`[PeerDiscovery] Removed ${removed} expired peers`);
    }
  }

  /**
   * Get categorized peer lists
   */
  getPeerLists(): PeerLists {
    const all = Array.from(this.peers.values());
    const libreRelay = all.filter(p => p.isLibreRelay);
    const coreV30Plus = all.filter(p => p.isCoreV30Plus);

    return {
      libreRelay,
      coreV30Plus,
      all,
    };
  }

  /**
   * Get random peers from a list, optionally filtered by network type
   */
  getRandomPeers(
    category: 'libreRelay' | 'coreV30Plus' | 'all', 
    count: number,
    options?: { torOnly?: boolean }
  ): DiscoveredPeer[] {
    const lists = this.getPeerLists();
    let list = lists[category];
    
    // Filter by network type if specified
    if (options?.torOnly) {
      // Tor addresses end in .onion
      list = list.filter(p => p.ip.endsWith('.onion'));
    } else if (options?.torOnly === false) {
      // Clearnet only (not .onion)
      list = list.filter(p => !p.ip.endsWith('.onion'));
    }
    
    return this.sampleArray(list, Math.min(count, list.length));
  }

  /**
   * Inject test data for development/testing
   */
  addTestPeers(): void {
    const testPeers: DiscoveredPeer[] = [
      // Libre Relay test peers (clearnet)
      {
        ip: '192.0.2.1',
        port: 8333,
        services: (1n << 29n) | 1033n, // Libre Relay (bit 29) + standard services
        userAgent: '/Satoshi:29.0.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: true,
        isCoreV30Plus: false,
      },
      {
        ip: '192.0.2.2',
        port: 8333,
        services: (1n << 29n) | 1033n,
        userAgent: '/Satoshi:28.2.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: true,
        isCoreV30Plus: false,
      },
      {
        ip: '192.0.2.3',
        port: 8333,
        services: (1n << 29n) | 1033n,
        userAgent: '/Satoshi:27.1.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: true,
        isCoreV30Plus: false,
      },
      // Libre Relay test peers (Tor)
      {
        ip: 'abcdefghijklmnop.onion',
        port: 8333,
        services: (1n << 29n) | 1033n,
        userAgent: '/Satoshi:29.1.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: true,
        isCoreV30Plus: false,
      },
      {
        ip: 'qrstuvwxyz123456.onion',
        port: 8333,
        services: (1n << 29n) | 1033n,
        userAgent: '/Satoshi:28.0.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: true,
        isCoreV30Plus: false,
      },
      // Core v30+ test peers (clearnet)
      {
        ip: '198.51.100.1',
        port: 8333,
        services: 1033n,
        userAgent: '/Satoshi:30.0.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: false,
        isCoreV30Plus: true,
      },
      {
        ip: '198.51.100.2',
        port: 8333,
        services: 1033n,
        userAgent: '/Satoshi:31.1.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: false,
        isCoreV30Plus: true,
      },
      {
        ip: '198.51.100.3',
        port: 8333,
        services: 1033n,
        userAgent: '/Satoshi:30.2.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: false,
        isCoreV30Plus: true,
      },
      // Core v30+ test peers (Tor)
      {
        ip: 'test1234567890ab.onion',
        port: 8333,
        services: 1033n,
        userAgent: '/Satoshi:30.0.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: false,
        isCoreV30Plus: true,
      },
      {
        ip: 'example123456789.onion',
        port: 8333,
        services: 1033n,
        userAgent: '/Satoshi:31.0.0/',
        version: 70016,
        lastSeen: Date.now(),
        isLibreRelay: false,
        isCoreV30Plus: true,
      },
    ];

    for (const peer of testPeers) {
      const key = `${peer.ip}:${peer.port}`;
      this.peers.set(key, peer);
    }

    console.log(`[PeerDiscovery] Added ${testPeers.length} test peers`);
    this.persistPeers();
  }

  /**
   * Clear all peers
   */
  clearAllPeers(): void {
    const count = this.peers.size;
    this.peers.clear();
    this.queriedPeers.clear();
    console.log(`[PeerDiscovery] Cleared ${count} peers`);
    this.persistPeers();
  }

  /**
   * Randomly sample from an array
   */
  private sampleArray<T>(array: T[], count: number): T[] {
    const shuffled = [...array].sort(() => Math.random() - 0.5);
    return shuffled.slice(0, count);
  }

  /**
   * Load peers from disk
   */
  private async loadPersistedPeers() {
    try {
      const fs = await import('fs/promises');
      const path = await import('path');
      const filePath = path.join(process.cwd(), 'data', 'discovered-peers.json');
      
      const data = await fs.readFile(filePath, 'utf-8');
      const stored = JSON.parse(data);
      
      for (const peer of stored) {
        // Convert services back to bigint
        peer.services = BigInt(peer.services);
        this.peers.set(`${peer.ip}:${peer.port}`, peer);
      }
      
      console.log(`[PeerDiscovery] Loaded ${this.peers.size} persisted peers`);
    } catch {
      // File doesn't exist yet, start fresh
      console.log('[PeerDiscovery] No persisted peers found, starting fresh');
    }
  }

  /**
   * Save peers to disk
   */
  private async persistPeers() {
    try {
      const fs = await import('fs/promises');
      const path = await import('path');
      const dataDir = path.join(process.cwd(), 'data');
      const filePath = path.join(dataDir, 'discovered-peers.json');
      
      // Ensure data directory exists
      await fs.mkdir(dataDir, { recursive: true });
      
      // Convert bigints to strings for JSON
      const peersArray = Array.from(this.peers.values()).map(peer => ({
        ...peer,
        services: peer.services.toString(),
      }));
      
      await fs.writeFile(filePath, JSON.stringify(peersArray, null, 2));
      console.log(`[PeerDiscovery] Persisted ${peersArray.length} peers to disk`);
    } catch (error) {
      console.error('[PeerDiscovery] Failed to persist peers:', error);
    }
  }
}

// Singleton instance
export const peerDiscoveryService = new PeerDiscoveryService();
