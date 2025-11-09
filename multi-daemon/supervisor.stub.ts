#!/usr/bin/env tsx
/**
 * Multi-Daemon Supervisor - REAL IMPLEMENTATION
 * 
 * This supervisor manages multiple bitcoind daemon processes:
 *  - Spawn/stop instances based on envfile configurations
 *  - Monitor daemon health (RPC ping, log tailing)
 *  - Collect real metrics (blocks, peers, storage)
 *  - Expose unified API for webui backend
 *  - Manage Tor hidden services (one per instance)
 */

import * as http from 'http';
import * as fs from 'fs';
import * as path from 'path';
import { spawn, ChildProcess } from 'child_process';
import { 
  startTor, 
  stopTor, 
  addHiddenService, 
  removeHiddenService, 
  getOnionAddress 
} from './tor-manager';

const PORT = parseInt(process.env.SUPERVISOR_PORT || '9000', 10);
// API writes to $ENVFILES_DIR/instances/, so we need to look in the instances subdirectory
const ENVFILES_BASE = process.env.ENVFILES_DIR || '/envfiles';
const ENVFILES_DIR = path.join(ENVFILES_BASE, 'instances');
const ARTIFACTS_DIR = process.env.ARTIFACTS_DIR || '/artifacts';
const DATA_DIR = process.env.DATA_DIR || '/data/bitcoin';

// ============================================================================
// STUB DATA: Fake daemon instances with realistic fields
// ============================================================================

interface DaemonInstance {
  id: string;
  state: 'up' | 'exited' | 'starting' | 'stopping';
  impl: 'garbageman' | 'knots';
  network: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  version?: string; // e.g., "29.2.0"
  uptime: number; // seconds
  peers: number;
  peerBreakdown?: {
    libreRelay: number; // LR/GM - Libre Relay bit set
    knots: number;      // Bitcoin Knots
    oldCore: number;    // Bitcoin Core pre-v30
    newCore: number;    // Bitcoin Core v30+
    other: number;      // Other implementations
  };
  blocks: number;
  headers: number;
  progress: number; // 0.0 to 1.0
  initialBlockDownload?: boolean; // true during IBD
  diskGb: number;
  rpcPort: number;
  p2pPort: number;
  onion?: string;
  ipv4Enabled: boolean;
  kpiTags: string[]; // e.g., ["pruned", "clearnet", "tor-only"]
}

interface ProcessInfo {
  process: ChildProcess;
  pid?: number;
  startTime: number;
  config: any; // Parsed env config
  restartCount: number;
  lastCrashTime?: number;
  autoRestart: boolean; // Whether to auto-restart on crash
  rpcHealth: RpcHealthState;
}

// Lifecycle management config
const LIFECYCLE_CONFIG = {
  MAX_RESTART_ATTEMPTS: 5,        // Max restart attempts before giving up
  RESTART_WINDOW_MS: 300000,      // 5 minutes - reset restart count after this
  CRASH_BACKOFF_MS: 5000,         // Wait 5s before restarting after crash
  MIN_UPTIME_FOR_SUCCESS_MS: 30000, // 30s uptime = successful start
  UPTIME_UPDATE_INTERVAL_MS: 1000,  // Update uptime every second
  RPC_HEALTH_CHECK_INTERVAL_MS: 10000, // Check RPC health every 10 seconds
  RPC_TIMEOUT_MS: 5000,           // RPC request timeout
};

// Track RPC health state
interface RpcHealthState {
  lastSuccessfulPing?: number;
  consecutiveFailures: number;
  isResponsive: boolean;
}

// Track instances in memory
const instances = new Map<string, DaemonInstance>();
// Track running processes
const processes = new Map<string, ProcessInfo>();

// ============================================================================
// Load instances from envfiles
// ============================================================================

function loadInstancesFromEnvfiles() {
  try {
    if (!fs.existsSync(ENVFILES_DIR)) {
      console.log(`Envfiles directory not found: ${ENVFILES_DIR}`);
      return;
    }
    
    const files = fs.readdirSync(ENVFILES_DIR);
    const envFiles = files.filter(f => f.endsWith('.env'));
    const foundInstanceIds = new Set<string>();
    
    for (const file of envFiles) {
      const filePath = path.join(ENVFILES_DIR, file);
      const content = fs.readFileSync(filePath, 'utf-8');
      const config: any = {};
      
      // Parse env file
      content.split('\n').forEach(line => {
        const trimmed = line.trim();
        if (trimmed && !trimmed.startsWith('#')) {
          const [key, ...valueParts] = trimmed.split('=');
          if (key && valueParts.length > 0) {
            config[key.trim()] = valueParts.join('=').trim();
          }
        }
      });
      
      if (config.INSTANCE_ID) {
        foundInstanceIds.add(config.INSTANCE_ID);
        
        // Check if instance already exists
        const existing = instances.get(config.INSTANCE_ID);
        if (!existing) {
          // Create new instance with stub data
          const instance: DaemonInstance = {
            id: config.INSTANCE_ID,
            state: 'exited', // Default to exited
            impl: config.BITCOIN_IMPL === 'knots' ? 'knots' : 'garbageman',
            network: (config.NETWORK || 'mainnet') as any,
            uptime: 0,
            peers: 0,
            blocks: 0,
            headers: 0,
            progress: 0.0,
            diskGb: 0,
            rpcPort: parseInt(config.RPC_PORT || '0', 10),
            p2pPort: parseInt(config.P2P_PORT || '0', 10),
            ipv4Enabled: config.IPV4_ENABLED === 'true',
            kpiTags: [],
          };
          
          instances.set(config.INSTANCE_ID, instance);
          console.log(`Loaded new instance: ${config.INSTANCE_ID}`);
        } else {
          // Update config fields that might have changed
          existing.impl = config.BITCOIN_IMPL === 'knots' ? 'knots' : 'garbageman';
          existing.network = (config.NETWORK || 'mainnet') as any;
          existing.rpcPort = parseInt(config.RPC_PORT || '0', 10);
          existing.p2pPort = parseInt(config.P2P_PORT || '0', 10);
          existing.ipv4Enabled = config.IPV4_ENABLED === 'true';
          console.log(`Refreshed existing instance: ${config.INSTANCE_ID}`);
        }
      }
    }
    
    // Remove instances that no longer have envfiles
    for (const [instanceId] of instances) {
      if (!foundInstanceIds.has(instanceId)) {
        console.log(`Removing instance (envfile deleted): ${instanceId}`);
        instances.delete(instanceId);
      }
    }
    
    console.log(`Total instances loaded: ${instances.size}`);
  } catch (err) {
    console.error('Failed to load instances from envfiles:', err);
  }
}

// Load instances on startup
loadInstancesFromEnvfiles();

// Helper to load a single instance from envfile if not already in memory
function loadInstanceIfNeeded(instanceId: string): boolean {
  // Already loaded?
  if (instances.has(instanceId)) {
    return true;
  }
  
  // Try to load from envfile
  const envFilePath = path.join(ENVFILES_DIR, `${instanceId}.env`);
  if (!fs.existsSync(envFilePath)) {
    return false;
  }
  
  try {
    const content = fs.readFileSync(envFilePath, 'utf-8');
    const config: any = {};
    content.split('\n').forEach((line: string) => {
      const trimmed = line.trim();
      if (trimmed && !trimmed.startsWith('#')) {
        const [key, ...valueParts] = trimmed.split('=');
        if (key && valueParts.length > 0) {
          config[key.trim()] = valueParts.join('=').trim();
        }
      }
    });
    
    const instance: DaemonInstance = {
      id: config.INSTANCE_ID,
      state: 'exited',
      impl: config.BITCOIN_IMPL || 'garbageman',
      network: config.NETWORK || 'mainnet',
      uptime: 0,
      peers: 0,
      blocks: 0,
      headers: 0,
      progress: 0,
      diskGb: 0,
      rpcPort: config.RPC_PORT,
      p2pPort: config.P2P_PORT,
      ipv4Enabled: config.IPV4_ENABLED === 'true',
      kpiTags: [],
    };
    
    instances.set(config.INSTANCE_ID, instance);
    console.log(`Dynamically loaded instance: ${config.INSTANCE_ID}`);
    return true;
  } catch (err) {
    console.error(`Failed to load instance ${instanceId}:`, err);
    return false;
  }
}

// Reload instances every 10 seconds to pick up new ones
setInterval(() => {
  loadInstancesFromEnvfiles();
}, 10000);

// Update uptime for running processes every second
setInterval(() => {
  processes.forEach((processInfo, instanceId) => {
    const instance = instances.get(instanceId);
    if (instance && instance.state === 'up') {
      const uptimeMs = Date.now() - processInfo.startTime;
      instance.uptime = Math.floor(uptimeMs / 1000); // Convert to seconds
    }
  });
}, LIFECYCLE_CONFIG.UPTIME_UPDATE_INTERVAL_MS);

// ============================================================================
// Process Management
// ============================================================================

async function spawnBitcoind(instanceId: string, config: any): Promise<boolean> {
  try {
    const instance = instances.get(instanceId);
    if (!instance) {
      console.error(`Cannot spawn: instance ${instanceId} not found`);
      return false;
    }
    
    // Determine binary path based on implementation
    if (!config.ARTIFACT) {
      console.error(`Cannot spawn ${instanceId}: ARTIFACT not specified in config. Please recreate the instance.`);
      return false;
    }
    
    const artifactTag = config.ARTIFACT;
    const binaryName = instance.impl === 'knots' ? 'bitcoind-knots' : 'bitcoind-gm';
    const binaryPath = path.join(ARTIFACTS_DIR, artifactTag, binaryName);
    
    // Check if binary exists
    if (!fs.existsSync(binaryPath)) {
      console.error(`Binary not found: ${binaryPath}`);
      console.error(`Make sure artifact '${artifactTag}' is imported with binaries.`);
      return false;
    }
    
    // Prepare data directory
    const dataDir = path.join(DATA_DIR, instanceId);
    if (!fs.existsSync(dataDir)) {
      fs.mkdirSync(dataDir, { recursive: true });
    }
    
    // Get RPC credentials from instance config
    // Generate secure defaults if not present (migration for old instances)
    let rpcUser = config.RPC_USER;
    let rpcPass = config.RPC_PASS;
    
    if (!rpcUser || !rpcPass) {
      // Migration: Generate credentials for instances created before this security fix
      console.warn(`Instance ${instanceId} missing RPC credentials - generating secure defaults`);
      const crypto = require('crypto');
      rpcUser = `gm-${instanceId}`;
      rpcPass = crypto.randomBytes(32).toString('base64url');
      
      // Update config file with new credentials
      config.RPC_USER = rpcUser;
      config.RPC_PASS = rpcPass;
      
      // Write back to envfile
      try {
        const envFilePath = path.join(ENVFILES_DIR, `${instanceId}.env`);
        const envContent = fs.readFileSync(envFilePath, 'utf-8');
        const updatedContent = envContent + `\nRPC_USER=${rpcUser}\nRPC_PASS=${rpcPass}\n`;
        fs.writeFileSync(envFilePath, updatedContent, 'utf-8');
        console.log(`Updated ${instanceId}.env with generated RPC credentials`);
      } catch (writeErr) {
        console.error(`Failed to update envfile with RPC credentials: ${writeErr}`);
        // Continue anyway - credentials will be used for this session
      }
    }
    
    // Build bitcoind arguments
    const args: string[] = [
      `-datadir=${dataDir}`,
      `-rpcport=${instance.rpcPort}`,
      `-port=${instance.p2pPort}`,
      `-rpcuser=${rpcUser}`,
      `-rpcpassword=${rpcPass}`,
      `-server=1`,
      `-daemon=0`, // Run in foreground so we can monitor
      `-printtoconsole=1`,
      // Resource tuning for efficient operation
      `-prune=750`,           // Keep only 750MB of blocks (pruned node)
      `-dbcache=256`,         // Limit memory cache to 256MB
      `-maxconnections=${instance.ipv4Enabled ? 32 : 12}`, // More peers for clearnet
    ];
    
    // Add network flag (mainnet has no flag, others do)
    if (instance.network !== 'mainnet') {
      args.push(`-${instance.network}`); // -testnet, -signet, -regtest
    }
    
    // Add clearnet/tor settings
    if (!instance.ipv4Enabled) {
      // Tor-only mode
      args.push(`-onlynet=onion`);
      args.push(`-proxy=127.0.0.1:9050`);   // Tor SOCKS proxy
      args.push(`-listen=1`);               // Enable listening (required for listenonion)
      args.push(`-listenonion=1`);          // Enable Tor hidden service
      args.push(`-discover=0`);             // Disable address discovery
      args.push(`-dnsseed=0`);              // Disable DNS seeds
      args.push(`-torcontrol=127.0.0.1:9051`); // Tor control for v3 onion
    } else {
      // Clearnet + Tor mode
      args.push(`-proxy=127.0.0.1:9050`);   // Use Tor proxy when available
      args.push(`-listen=1`);               // Enable listening (required for listenonion)
      args.push(`-listenonion=1`);          // Also listen on Tor
      args.push(`-discover=1`);             // Enable address discovery
      args.push(`-dnsseed=1`);              // Enable DNS seeds
      args.push(`-torcontrol=127.0.0.1:9051`); // Tor control for v3 onion
    }
    
    // Add discovered peers from ADDNODE env variable
    if (config.ADDNODE) {
      const peers = config.ADDNODE.split(',').map((p: string) => p.trim()).filter((p: string) => p);
      peers.forEach((peer: string) => {
        args.push(`-addnode=${peer}`);
      });
      console.log(`  Added ${peers.length} peer(s) via -addnode`);
    }
    
    console.log(`Spawning ${binaryName} for ${instanceId}:`);
    console.log(`  Binary: ${binaryPath}`);
    console.log(`  DataDir: ${dataDir}`);
    console.log(`  Args: ${args.join(' ')}`);
    
    // Register Tor hidden service for this instance
    await addHiddenService(instanceId, instance.p2pPort);
    console.log(`  Tor hidden service registered on port ${instance.p2pPort}`);
    
    // Spawn the process
    const proc = spawn(binaryPath, args, {
      cwd: dataDir,
      stdio: ['ignore', 'pipe', 'pipe'], // stdin ignored, capture stdout/stderr
    });
    
    // Track the process
    const processInfo: ProcessInfo = {
      process: proc,
      pid: proc.pid,
      startTime: Date.now(),
      config,
      restartCount: 0,
      autoRestart: true,
      rpcHealth: {
        consecutiveFailures: 0,
        isResponsive: false,
      },
    };
    processes.set(instanceId, processInfo);
    
    // Update instance state
    instance.state = 'starting';
    
    // Handle process events
    proc.stdout?.on('data', (data) => {
      console.log(`[${instanceId}] ${data.toString().trim()}`);
    });
    
    proc.stderr?.on('data', (data) => {
      console.error(`[${instanceId}] ${data.toString().trim()}`);
    });
    
    proc.on('spawn', () => {
      console.log(`[${instanceId}] Process spawned with PID ${proc.pid}`);
      instance.state = 'up';
      instance.uptime = 0;
      
      // Start checking RPC health after a short delay (let bitcoind initialize)
      setTimeout(() => {
        checkRpcHealth(instanceId).catch((err) => {
          console.log(`[${instanceId}] Initial RPC check failed (expected during startup):`, err.message);
        });
      }, 5000);
    });
    
    proc.on('error', (err) => {
      console.error(`[${instanceId}] Process error:`, err);
      instance.state = 'exited';
      processes.delete(instanceId);
    });
    
    proc.on('exit', (code: number | null, signal: string | null) => {
      console.log(`[${instanceId}] Process exited: code=${code}, signal=${signal}`);
      instance.state = 'exited';
      instance.uptime = 0;
      
      const processInfo = processes.get(instanceId);
      processes.delete(instanceId);
      
      // Handle auto-restart on crash (non-zero exit or unexpected termination)
      if (processInfo && processInfo.autoRestart && code !== 0 && signal !== 'SIGTERM') {
        const uptime = Date.now() - processInfo.startTime;
        const wasSuccessfulStart = uptime >= LIFECYCLE_CONFIG.MIN_UPTIME_FOR_SUCCESS_MS;
        
        // Reset restart count if it's been a while since last crash
        if (processInfo.lastCrashTime) {
          const timeSinceLastCrash = Date.now() - processInfo.lastCrashTime;
          if (timeSinceLastCrash > LIFECYCLE_CONFIG.RESTART_WINDOW_MS) {
            processInfo.restartCount = 0;
          }
        }
        
        // Check if we should restart
        if (processInfo.restartCount < LIFECYCLE_CONFIG.MAX_RESTART_ATTEMPTS) {
          processInfo.restartCount++;
          processInfo.lastCrashTime = Date.now();
          
          console.log(`[${instanceId}] Crashed after ${Math.floor(uptime / 1000)}s uptime. ` +
            `Restart attempt ${processInfo.restartCount}/${LIFECYCLE_CONFIG.MAX_RESTART_ATTEMPTS} in ${LIFECYCLE_CONFIG.CRASH_BACKOFF_MS / 1000}s...`);
          
          // Wait before restarting
          setTimeout(async () => {
            console.log(`[${instanceId}] Auto-restarting...`);
            await spawnBitcoind(instanceId, processInfo.config);
          }, LIFECYCLE_CONFIG.CRASH_BACKOFF_MS);
        } else {
          console.error(`[${instanceId}] Max restart attempts (${LIFECYCLE_CONFIG.MAX_RESTART_ATTEMPTS}) reached. Giving up.`);
          instance.state = 'exited';
        }
      }
    });
    
    return true;
  } catch (err) {
    console.error(`Failed to spawn bitcoind for ${instanceId}:`, err);
    return false;
  }
}

async function stopBitcoind(instanceId: string): Promise<boolean> {
  try {
    const processInfo = processes.get(instanceId);
    if (!processInfo) {
      console.log(`No running process for ${instanceId}`);
      return false;
    }
    
    // Disable auto-restart for manual stops
    processInfo.autoRestart = false;
    
    const instance = instances.get(instanceId);
    if (instance) {
      instance.state = 'stopping';
    }
    
    console.log(`Stopping ${instanceId} (PID: ${processInfo.pid})`);
    
    // Remove Tor hidden service
    await removeHiddenService(instanceId);
    
    // Send SIGTERM for graceful shutdown
    processInfo.process.kill('SIGTERM');
    
    // Force kill after 30 seconds if still running
    setTimeout(() => {
      if (processes.has(instanceId)) {
        console.log(`Force killing ${instanceId}`);
        processInfo.process.kill('SIGKILL');
      }
    }, 30000);
    
    return true;
  } catch (err) {
    console.error(`Failed to stop ${instanceId}:`, err);
    return false;
  }
}

// ============================================================================
// RPC Health Monitoring
// ============================================================================

/**
 * Make a JSON-RPC call to bitcoind
 */
async function makeRpcCall(
  instanceId: string,
  method: string,
  params: any[] = []
): Promise<any> {
  const instance = instances.get(instanceId);
  if (!instance) {
    throw new Error(`Instance ${instanceId} not found`);
  }

  // Get credentials from process config
  const processInfo = processes.get(instanceId);
  if (!processInfo) {
    throw new Error(`Process info not found for ${instanceId}`);
  }
  
  const rpcUser = processInfo.config.RPC_USER || `gm-${instanceId}`;
  const rpcPass = processInfo.config.RPC_PASS || 'changeme';

  return new Promise((resolve, reject) => {
    const postData = JSON.stringify({
      jsonrpc: '1.0',
      id: 'supervisor',
      method,
      params,
    });

    const options = {
      hostname: '127.0.0.1',
      port: instance.rpcPort,
      path: '/',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
        Authorization: 'Basic ' + Buffer.from(`${rpcUser}:${rpcPass}`).toString('base64'),
      },
      timeout: LIFECYCLE_CONFIG.RPC_TIMEOUT_MS,
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (chunk: Buffer) => {
        data += chunk;
      });
      res.on('end', () => {
        try {
          const response = JSON.parse(data);
          if (response.error) {
            reject(new Error(response.error.message || 'RPC error'));
          } else {
            resolve(response.result);
          }
        } catch (err) {
          reject(err);
        }
      });
    });

    req.on('error', (err) => {
      reject(err);
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('RPC timeout'));
    });

    req.write(postData);
    req.end();
  });
}

/**
 * Check RPC health for a single instance
 */
async function checkRpcHealth(instanceId: string): Promise<void> {
  const processInfo = processes.get(instanceId);
  const instance = instances.get(instanceId);
  
  if (!processInfo || !instance || instance.state !== 'up') {
    return;
  }

  try {
    // Simple ping using getblockchaininfo - lightweight and always available
    await makeRpcCall(instanceId, 'getblockchaininfo', []);
    
    // Success!
    const wasUnresponsive = !processInfo.rpcHealth.isResponsive;
    processInfo.rpcHealth.isResponsive = true;
    processInfo.rpcHealth.lastSuccessfulPing = Date.now();
    processInfo.rpcHealth.consecutiveFailures = 0;
    console.log(`[${instanceId}] RPC health check: OK`);
    
    // If this is the first successful ping, collect initial metrics
    if (wasUnresponsive) {
      console.log(`[${instanceId}] First successful RPC response, collecting initial metrics...`);
      collectMetrics(instanceId).catch((err) => {
        console.error(`[${instanceId}] Initial metrics collection failed:`, err);
      });
    }
  } catch (err: any) {
    processInfo.rpcHealth.consecutiveFailures++;
    console.log(`[${instanceId}] RPC health check failed (${processInfo.rpcHealth.consecutiveFailures}): ${err.message}`);
    
    if (processInfo.rpcHealth.consecutiveFailures >= 3) {
      processInfo.rpcHealth.isResponsive = false;
      console.warn(`[${instanceId}] RPC unresponsive (${processInfo.rpcHealth.consecutiveFailures} consecutive failures)`);
    }
  }
}

/**
 * Collect real metrics from bitcoind via RPC
 */
async function collectMetrics(instanceId: string): Promise<void> {
  const processInfo = processes.get(instanceId);
  const instance = instances.get(instanceId);
  
  if (!processInfo || !instance || instance.state !== 'up' || !processInfo.rpcHealth.isResponsive) {
    return;
  }

  try {
    // Collect multiple RPC calls in parallel
    const [blockchainInfo, networkInfo, peerInfo] = await Promise.all([
      makeRpcCall(instanceId, 'getblockchaininfo', []),
      makeRpcCall(instanceId, 'getnetworkinfo', []),
      makeRpcCall(instanceId, 'getpeerinfo', []),
    ]);

    // Update instance with real data
    instance.blocks = blockchainInfo.blocks || 0;
    instance.headers = blockchainInfo.headers || 0;
    instance.progress = blockchainInfo.verificationprogress || 0;
    instance.initialBlockDownload = blockchainInfo.initialblockdownload || false;
    instance.peers = peerInfo.length || 0;

    // Extract version from networkInfo (e.g., subversion: "/Satoshi:29.2.0/")
    if (networkInfo.subversion) {
      const versionMatch = networkInfo.subversion.match(/(\d+\.\d+\.\d+)/);
      if (versionMatch) {
        instance.version = versionMatch[1];
      }
    }

    // Calculate disk usage (approximate from size_on_disk if available)
    if (blockchainInfo.size_on_disk) {
      instance.diskGb = Math.round((blockchainInfo.size_on_disk / 1024 / 1024 / 1024) * 10) / 10;
    }

    // Analyze peer breakdown by user agent
    if (peerInfo && peerInfo.length > 0) {
      const breakdown = {
        libreRelay: 0,
        knots: 0,
        oldCore: 0,
        newCore: 0,
        other: 0,
      };

      peerInfo.forEach((peer: any) => {
        const userAgent = (peer.subver || '').toLowerCase();
        if (userAgent.includes('libr') || userAgent.includes('garbageman')) {
          breakdown.libreRelay++;
        } else if (userAgent.includes('knots')) {
          breakdown.knots++;
        } else if (userAgent.includes('satoshi')) {
          // Try to parse version for Core
          const versionMatch = userAgent.match(/satoshi:(\d+\.\d+)/);
          if (versionMatch) {
            const version = parseFloat(versionMatch[1]);
            if (version >= 30.0) {
              breakdown.newCore++;
            } else {
              breakdown.oldCore++;
            }
          } else {
            breakdown.oldCore++;
          }
        } else {
          breakdown.other++;
        }
      });

      instance.peerBreakdown = breakdown;
    }

    // Update KPI tags
    const tags: string[] = [];
    if (blockchainInfo.pruned) {
      tags.push('pruned');
    }
    if (instance.ipv4Enabled) {
      tags.push('clearnet');
    } else {
      tags.push('tor-only');
    }
    instance.kpiTags = tags;
    
    // Get and update onion address
    const onionAddress = getOnionAddress(instanceId);
    if (onionAddress) {
      instance.onion = onionAddress;
    }

    console.log(`[${instanceId}] Metrics updated: ${instance.blocks} blocks, ${instance.peers} peers, ${Math.round(instance.progress * 100)}% synced${onionAddress ? `, onion: ${onionAddress}` : ''}`);
  } catch (err: any) {
    console.error(`[${instanceId}] Failed to collect metrics:`, err.message);
  }
}

/**
 * Periodic RPC health check for all running instances
 */
function startRpcHealthMonitoring() {
  console.log('Starting RPC health monitoring (checking every 10s)...');
  setInterval(async () => {
    const instanceIds = Array.from(processes.keys());
    if (instanceIds.length > 0) {
      console.log(`Running health checks for ${instanceIds.length} instance(s)...`);
    }
    const healthChecks = instanceIds.map((instanceId) =>
      checkRpcHealth(instanceId).catch((err) => {
        console.error(`[${instanceId}] Health check error:`, err);
      })
    );
    await Promise.all(healthChecks);
  }, LIFECYCLE_CONFIG.RPC_HEALTH_CHECK_INTERVAL_MS);
}

/**
 * Periodic metrics collection for all running instances
 */
function startMetricsCollection() {
  console.log('Starting metrics collection (collecting every 30s)...');
  setInterval(async () => {
    const instanceIds = Array.from(processes.keys());
    const metricsCollection = instanceIds.map((instanceId) =>
      collectMetrics(instanceId).catch((err) => {
        console.error(`[${instanceId}] Metrics collection error:`, err);
      })
    );
    await Promise.all(metricsCollection);
  }, 30000); // Collect metrics every 30 seconds
}

// Start RPC health monitoring
startRpcHealthMonitoring();

// Start metrics collection
startMetricsCollection();

// ============================================================================
// HTTP SERVER: Simple REST-like endpoints for the API to consume
// ============================================================================

const server = http.createServer(async (req, res) => {
  const url = req.url || '';
  const method = req.method || 'GET';

  // CORS headers for local dev
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Route: health check
  if (url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        status: 'ok',
        service: 'multi-daemon-supervisor',
        version: '0.1.0-stub',
        timestamp: new Date().toISOString(),
      })
    );
    return;
  }

  // Route: reload instances from envfiles
  if (url === '/reload' && method === 'POST') {
    console.log('Manual reload requested');
    loadInstancesFromEnvfiles();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      success: true,
      instanceCount: instances.size,
      message: 'Instances reloaded from envfiles',
    }));
    return;
  }

  // Route: list all daemon instances
  if (url === '/instances' && method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ instances: Array.from(instances.values()) }));
    return;
  }

  // Route: get single instance by ID
  const instanceMatch = url.match(/^\/instances\/([^/]+)$/);
  if (instanceMatch && method === 'GET') {
    const instanceId = instanceMatch[1];
    const instance = instances.get(instanceId);
    if (instance) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(instance));
    } else {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Instance not found' }));
    }
    return;
  }

  // Route: control endpoint (start/stop/restart)
  const controlMatch = url.match(/^\/instances\/([^/]+)\/(start|stop|restart)$/);
  if (controlMatch && method === 'POST') {
    const instanceId = controlMatch[1];
    const action = controlMatch[2];
    
    // Try to load instance if not in memory
    if (!instances.has(instanceId)) {
      const loaded = loadInstanceIfNeeded(instanceId);
      if (!loaded) {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Instance not found' }));
        return;
      }
    }
    
    const instance = instances.get(instanceId)!;
    
    // Handle actions with real process management
    if (action === 'start') {
      if (instance.state === 'exited') {
        // Load config from envfile
        const envFilePath = path.join(ENVFILES_DIR, `${instanceId}.env`);
        if (fs.existsSync(envFilePath)) {
          const content = fs.readFileSync(envFilePath, 'utf-8');
          const config: any = {};
          content.split('\n').forEach((line: string) => {
            const trimmed = line.trim();
            if (trimmed && !trimmed.startsWith('#')) {
              const [key, ...valueParts] = trimmed.split('=');
              if (key && valueParts.length > 0) {
                config[key.trim()] = valueParts.join('=').trim();
              }
            }
          });
          
          try {
            const success = await spawnBitcoind(instanceId, config);
            if (success) {
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({
                success: true,
                action,
                instanceId,
                newState: instance.state,
                message: `Instance ${action} initiated`,
              }));
            } else {
              res.writeHead(500, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({
                success: false,
                error: 'Failed to spawn process',
              }));
            }
          } catch (err: any) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
              success: false,
              error: err.message,
            }));
          }
        } else {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Envfile not found' }));
        }
        return;
      }
    } else if (action === 'stop') {
      if (instance.state === 'up' || instance.state === 'starting') {
        const success = await stopBitcoind(instanceId);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          success,
          action,
          instanceId,
          newState: instance.state,
          message: `Instance ${action} initiated`,
        }));
        return;
      }
    } else if (action === 'restart') {
      await stopBitcoind(instanceId);
      // Wait a bit then restart
      setTimeout(async () => {
        const envFilePath = path.join(ENVFILES_DIR, `${instanceId}.env`);
        if (fs.existsSync(envFilePath)) {
          const content = fs.readFileSync(envFilePath, 'utf-8');
          const config: any = {};
          content.split('\n').forEach((line: string) => {
            const trimmed = line.trim();
            if (trimmed && !trimmed.startsWith('#')) {
              const [key, ...valueParts] = trimmed.split('=');
              if (key && valueParts.length > 0) {
                config[key.trim()] = valueParts.join('=').trim();
              }
            }
          });
          await spawnBitcoind(instanceId, config);
        }
      }, 2000);
      
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        success: true,
        action,
        instanceId,
        newState: 'stopping',
        message: `Instance ${action} initiated`,
      }));
      return;
    }
    
    // Fallback response if action doesn't apply
    res.writeHead(400, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      success: false,
      error: `Cannot ${action} instance in state ${instance.state}`,
    }));
    return;
  }

  // Default: 404
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

// ============================================================================
// STARTUP
// ============================================================================

async function startup() {
  // Start Tor daemon first
  console.log('Starting Tor daemon...');
  await startTor();
  console.log('Tor daemon started');
  
  // Register hidden services for existing instances
  for (const [instanceId, instance] of instances.entries()) {
    console.log(`Registering hidden service for ${instanceId}...`);
    await addHiddenService(instanceId, instance.p2pPort);
    
    // Try to get onion address (might not exist yet if instance was just created)
    const onionAddress = getOnionAddress(instanceId);
    if (onionAddress) {
      instance.onion = onionAddress;
      console.log(`  ${instanceId}: ${onionAddress}`);
    }
  }
  
  server.listen(PORT, '0.0.0.0', () => {
    console.log('============================================================');
    console.log('Multi-Daemon Supervisor - Listening');
    console.log('============================================================');
    console.log(`Port: ${PORT}`);
    console.log(`Instances loaded: ${instances.size}`);
    console.log('');
    console.log('Endpoints:');
    console.log(`  GET  /health`);
    console.log(`  GET  /instances`);
    console.log(`  GET  /instances/:id`);
    console.log(`  POST /instances/:id/start`);
    console.log(`  POST /instances/:id/stop`);
    console.log(`  POST /instances/:id/restart`);
    console.log('');
    console.log('============================================================');
  });
}

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, shutting down gracefully...');
  
  // Stop all bitcoind processes
  for (const [instanceId] of processes.entries()) {
    await stopBitcoind(instanceId);
  }
  
  // Stop Tor
  await stopTor();
  
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});

process.on('SIGINT', async () => {
  console.log('SIGINT received, shutting down gracefully...');
  
  // Stop all bitcoind processes
  for (const [instanceId] of processes.entries()) {
    await stopBitcoind(instanceId);
  }
  
  // Stop Tor
  await stopTor();
  
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});

// Start everything
startup().catch((err) => {
  console.error('Startup failed:', err);
  process.exit(1);
});