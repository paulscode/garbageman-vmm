/**
 * Instances Route - Manage Daemon Instances
 * ==========================================
 * CRUD operations for daemon instance definitions.
 * 
 * Routes:
 *  GET    /api/instances       - List all instances (config + live status)
 *  GET    /api/instances/:id   - Get single instance
 *  POST   /api/instances       - Create new instance
 *  PUT    /api/instances/:id   - Update instance config
 *  DELETE /api/instances/:id   - Delete instance
 */

import type { FastifyInstance } from 'fastify';
import type {
  ListInstancesResponse,
  CreateInstanceRequest,
  CreateInstanceResponse,
  UpdateInstanceRequest,
  UpdateInstanceResponse,
  DeleteInstanceResponse,
  InstanceDetail,
  InstanceStatus,
  InstanceConfig,
} from '../lib/types.js';
import * as envstore from '../lib/envstore.js';
import { logInstanceCreated, logInstanceStarted, logInstanceStopped, logInstanceDeleted } from '../lib/events.js';
import { peerDiscoveryService } from '../services/peer-discovery.js';
import { torPeerDiscoveryService } from '../services/tor-peer-discovery.js';
import {
  validateCreateInstance,
  formatValidationErrors,
} from '../lib/validation.js';

const SUPERVISOR_URL = process.env.SUPERVISOR_URL || 'http://multi-daemon:9000';

// ============================================================================
// Extraction Progress Tracking
// ============================================================================

interface ExtractionProgress {
  status: 'extracting' | 'complete' | 'error';
  message: string;
  error?: string;
}

const extractionProgressMap = new Map<string, ExtractionProgress>();

// ============================================================================
// Helper: Fetch live status from supervisor
// ============================================================================

async function fetchInstanceStatus(instanceId: string): Promise<InstanceStatus | null> {
  try {
    const response = await fetch(`${SUPERVISOR_URL}/instances/${instanceId}`, {
      signal: AbortSignal.timeout(5000),
    });
    
    if (!response.ok) {
      return null;
    }
    
    return await response.json() as InstanceStatus;
  } catch {
    return null;
  }
}

async function fetchAllInstanceStatuses(): Promise<Map<string, InstanceStatus>> {
  try {
    const response = await fetch(`${SUPERVISOR_URL}/instances`, {
      signal: AbortSignal.timeout(5000),
    });
    
    if (!response.ok) {
      return new Map();
    }
    
    const data = await response.json() as { instances: InstanceStatus[] };
    const map = new Map<string, InstanceStatus>();
    
    for (const status of data.instances) {
      map.set(status.id, status);
    }
    
    return map;
  } catch {
    return new Map();
  }
}

// ============================================================================
// Helper: Extract blockchain data in background
// ============================================================================

async function extractBlockchainData(
  fastify: FastifyInstance,
  artifact: string,
  instanceId: string,
  network: string,
  config: InstanceConfig
): Promise<void> {
  // Initialize progress tracking
  extractionProgressMap.set(instanceId, {
    status: 'extracting',
    message: 'Starting blockchain extraction...',
  });
  
  try {
    const fs = await import('fs/promises');
    const path = await import('path');
    const artifactPath = path.join(process.env.ARTIFACTS_DIR || '/root/artifacts', artifact);
    
    let blockchainTarPath = `${artifactPath}/blockchain.tar.gz`;
    
    // Check if blockchain.tar.gz exists, or if we have split parts
    let needsConcat = false;
    try {
      await fs.access(blockchainTarPath);
    } catch {
      // Check for split parts (blockchain.tar.gz.part01, part02, etc.)
      try {
        await fs.access(`${artifactPath}/blockchain.tar.gz.part01`);
        needsConcat = true;
        fastify.log.info(`Found split blockchain archive for ${artifact}`);
      } catch {
        throw new Error(`No blockchain data found in artifact '${artifact}'`);
      }
    }
    
    // If we have split parts, concatenate them first
    if (needsConcat) {
      blockchainTarPath = `${artifactPath}/blockchain.tar.gz`;
      fastify.log.info(`Concatenating split archive parts for ${instanceId}`);
      extractionProgressMap.set(instanceId, {
        status: 'extracting',
        message: 'Concatenating split archive parts...',
      });
      
      const { spawn } = await import('child_process');
      await new Promise<void>((resolve, reject) => {
        const cat = spawn('sh', ['-c', `cat ${artifactPath}/blockchain.tar.gz.part* > ${blockchainTarPath}`]);
        
        cat.on('exit', (code) => {
          if (code === 0) {
            fastify.log.info(`Successfully concatenated blockchain archive`);
            resolve();
          } else {
            reject(new Error(`cat failed with code ${code}`));
          }
        });
        
        cat.on('error', (err) => {
          reject(err);
        });
      });
    }
    
    // Instance data directory (mounted via supervisor)
    const dataDir = process.env.DATA_DIR || '/root/data';
    const instanceDataDir = path.join(dataDir, instanceId);
    
    // Verify paths are within allowed directories (prevent path traversal)
    const resolvedArtifactPath = path.resolve(artifactPath);
    const resolvedInstanceDir = path.resolve(instanceDataDir);
    const allowedArtifactsDir = path.resolve(process.env.ARTIFACTS_DIR || '/root/artifacts');
    const allowedDataDir = path.resolve(dataDir);
    
    if (!resolvedArtifactPath.startsWith(allowedArtifactsDir + '/')) {
      throw new Error('Artifact path outside allowed directory');
    }
    if (!resolvedInstanceDir.startsWith(allowedDataDir + '/')) {
      throw new Error('Instance data path outside allowed directory');
    }
    
    // Ensure instance data directory exists
    await fs.mkdir(instanceDataDir, { recursive: true });
    
    // Extract blockchain data using spawn (safer than shell)
    const { spawn } = await import('child_process');
    fastify.log.info(`Extracting blockchain data for ${instanceId} from ${blockchainTarPath}`);
    extractionProgressMap.set(instanceId, {
      status: 'extracting',
      message: 'Extracting blockchain data (this may take 10-30 minutes)...',
    });
    
    // Extract directly to instance data directory using spawn (no shell injection risk)
    await new Promise<void>((resolve, reject) => {
      const tar = spawn('tar', ['-xzf', blockchainTarPath, '-C', instanceDataDir]);
      
      tar.on('exit', (code) => {
        if (code === 0) {
          resolve();
        } else {
          reject(new Error(`tar extraction failed with code ${code}`));
        }
      });
      
      tar.on('error', (err) => {
        reject(err);
      });
    });
    
    // Fix ownership for Bitcoin daemon (runs as UID 1001 in multi-daemon container)
    extractionProgressMap.set(instanceId, {
      status: 'extracting',
      message: 'Fixing file permissions...',
    });
    await new Promise<void>((resolve) => {
      const chown = spawn('chown', ['-R', '1001:1001', instanceDataDir]);
      
      chown.on('exit', (code) => {
        if (code === 0) {
          resolve();
        } else {
          fastify.log.warn(`chown failed with code ${code}, permissions may be incorrect`);
          resolve();
        }
      });
      
      chown.on('error', (err) => {
        fastify.log.warn(`chown error: ${err.message}, permissions may be incorrect`);
        resolve();
      });
    });
    
    // Remove state files and sensitive identifying data
    extractionProgressMap.set(instanceId, {
      status: 'extracting',
      message: 'Cleaning state files for privacy...',
    });
    const stateFiles = [
      'settings.json',
      'peers.dat',
      '.lock',
      'banlist.json',
      'debug.log',
      'bitcoind.pid',
      'onion_v3_private_key',
      'anchors.dat',
      'mempool.dat',
      'fee_estimates.dat',
    ];
    
    const networkSubdir = network === 'mainnet' ? '' : network;
    const dirsToClean = [instanceDataDir];
    if (networkSubdir) {
      dirsToClean.push(`${instanceDataDir}/${networkSubdir}`);
    }
    
    for (const dir of dirsToClean) {
      for (const file of stateFiles) {
        try {
          const { unlink } = await import('fs/promises');
          await unlink(`${dir}/${file}`);
          fastify.log.debug(`Removed ${file} from ${dir}`);
        } catch {
          // File might not exist - that's fine
        }
      }
    }
    fastify.log.info(`Cleaned state and identity files from ${instanceId}`);
    fastify.log.info(`Blockchain extraction complete for ${instanceId}`);
    
    // NOW write config to trigger supervisor to start the instance
    extractionProgressMap.set(instanceId, {
      status: 'extracting',
      message: 'Writing instance configuration...',
    });
    await envstore.writeInstanceConfig(config);
    fastify.log.info(`Instance ${instanceId} config written`);
    
    // Tell supervisor to reload instances immediately (don't wait for 10-second interval)
    try {
      const reloadResponse = await fetch(`${SUPERVISOR_URL}/reload`, {
        method: 'POST',
        signal: AbortSignal.timeout(5000),
      });
      if (reloadResponse.ok) {
        fastify.log.info(`Supervisor reloaded - instance ${instanceId} is now available`);
      }
    } catch (reloadErr) {
      fastify.log.warn(`Failed to reload supervisor: ${reloadErr}. Instance will be available within 10 seconds.`);
    }
    
    // Mark as complete
    extractionProgressMap.set(instanceId, {
      status: 'complete',
      message: 'Blockchain extraction complete - instance is ready!',
    });
    
    // Clean up progress after 60 seconds
    setTimeout(() => {
      extractionProgressMap.delete(instanceId);
    }, 60000);
    
  } catch (err) {
    fastify.log.error(`Blockchain extraction failed for ${instanceId}: ${err}`);
    extractionProgressMap.set(instanceId, {
      status: 'error',
      message: 'Extraction failed',
      error: err instanceof Error ? err.message : String(err),
    });
    
    // Even if extraction fails, write config so instance can at least start and sync from scratch
    try {
      await envstore.writeInstanceConfig(config);
      fastify.log.warn(`Instance ${instanceId} will start without blockchain data and sync from scratch`);
    } catch (configErr) {
      fastify.log.error(`Failed to write config for ${instanceId}: ${configErr}`);
    }
    
    // Clean up progress after 60 seconds
    setTimeout(() => {
      extractionProgressMap.delete(instanceId);
    }, 60000);
  }
}

// ============================================================================
// Route Handlers
// ============================================================================

export default async function instancesRoute(fastify: FastifyInstance) {
  
  // --------------------------------------------------------------------------
  // GET /api/instances - List all instances
  // --------------------------------------------------------------------------
  
  fastify.get<{ Reply: ListInstancesResponse }>(
    '/api/instances',
    async (request, reply) => {
      try {
        // Read all configs from envfiles
        const configs = await envstore.readAllInstanceConfigs();
        
        // Fetch live status from supervisor
        const statusMap = await fetchAllInstanceStatuses();
        
        // Combine config + status
        const instances: InstanceDetail[] = configs.map(config => {
          const status = statusMap.get(config.INSTANCE_ID);
          
          // If supervisor doesn't know about this instance, create a stub status
          const fallbackStatus: InstanceStatus = {
            id: config.INSTANCE_ID,
            state: 'exited',
            impl: config.BITCOIN_IMPL || 'garbageman',
            version: config.BITCOIN_VERSION,
            network: config.NETWORK || 'mainnet',
            uptime: 0,
            peers: 0,
            blocks: 0,
            headers: 0,
            progress: 0,
            diskGb: 0,
            rpcPort: config.RPC_PORT,
            p2pPort: config.P2P_PORT,
            onion: config.TOR_ONION,
            ipv4Enabled: false,
            kpiTags: [],
          };
          
          // If supervisor provided status, merge with version from config if not already present
          const mergedStatus = status ? {
            ...status,
            version: status.version || config.BITCOIN_VERSION,
          } : fallbackStatus;
          
          return {
            config,
            status: mergedStatus,
          };
        });
        
        reply.send({ instances });
      } catch (err) {
        fastify.log.error(err);
        return reply.code(500).send({ error: 'Failed to list instances' } as any);
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // GET /api/instances/:id - Get single instance
  // --------------------------------------------------------------------------
  
  fastify.get<{ Params: { id: string } }>(
    '/api/instances/:id',
    async (request, reply) => {
      try {
        const { id } = request.params;
        
        // Check if instance exists
        const exists = await envstore.instanceExists(id);
        if (!exists) {
          return reply.code(404).send({ error: 'Instance not found' } as any);
        }
        
        // Read config
        const config = await envstore.readInstanceConfig(id);
        
        // Fetch live status
        const status = await fetchInstanceStatus(id);
        
        // Fallback status if supervisor doesn't know about it
        const fallbackStatus: InstanceStatus = {
          id: config.INSTANCE_ID,
          state: 'exited',
          impl: config.BITCOIN_IMPL || 'garbageman',
          version: config.BITCOIN_VERSION,
          network: config.NETWORK || 'mainnet',
          uptime: 0,
          peers: 0,
          blocks: 0,
          headers: 0,
          progress: 0,
          diskGb: 0,
          rpcPort: config.RPC_PORT,
          p2pPort: config.P2P_PORT,
          onion: config.TOR_ONION,
          ipv4Enabled: false,
          kpiTags: [],
        };
        
        // If supervisor provided status, merge with version from config if not already present
        const mergedStatus = status ? {
          ...status,
          version: status.version || config.BITCOIN_VERSION,
        } : fallbackStatus;
        
        const detail: InstanceDetail = {
          config,
          status: mergedStatus,
        };
        
        reply.send(detail);
      } catch (err) {
        fastify.log.error(err);
        return reply.code(500).send({ error: 'Failed to get instance' } as any);
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // GET /api/instances/extraction/progress/:id - Get blockchain extraction progress
  // --------------------------------------------------------------------------
  
  fastify.get<{ Params: { id: string } }>(
    '/api/instances/extraction/progress/:id',
    async (request, reply) => {
      const { id } = request.params;
      const progress = extractionProgressMap.get(id);
      
      if (!progress) {
        return reply.code(404).send({ error: 'No extraction in progress for this instance' });
      }
      
      reply.send(progress);
    }
  );
  
  // --------------------------------------------------------------------------
  // POST /api/instances - Create new instance
  // --------------------------------------------------------------------------
  
  fastify.post<{
    Body: CreateInstanceRequest;
    Reply: CreateInstanceResponse;
  }>(
    '/api/instances',
    async (request, reply) => {
      try {
        // Validate request body
        if (!validateCreateInstance(request.body)) {
          return reply.code(400).send({
            success: false,
            instanceId: '',
            message: `Validation failed: ${formatValidationErrors(validateCreateInstance)}`,
          });
        }
        
        const body = request.body;
        
        // Generate instance ID if not provided
        const instanceId = body.instanceId || envstore.generateInstanceId();
        
        // Check for conflicts
        const exists = await envstore.instanceExists(instanceId);
        if (exists) {
          return reply.code(409).send({
            success: false,
            instanceId,
            message: 'Instance ID already exists',
          });
        }
        
        // Auto-assign ports if not provided
        const usedPorts = await envstore.getUsedPorts();
        
        const rpcPort = body.rpcPort || await envstore.findAvailablePort(19000, 19999, usedPorts.rpc);
        const p2pPort = body.p2pPort || await envstore.findAvailablePort(18000, 18999, usedPorts.p2p);
        const zmqPort = body.zmqPort || await envstore.findAvailablePort(28000, 28999, usedPorts.zmq);
        
        // Generate secure RPC credentials (per-instance)
        // Check if wrapper environment provides credentials (Start9/Umbrel)
        const wrapperRpcUser = process.env.WRAPPER_RPC_USER;
        const wrapperRpcPass = process.env.WRAPPER_RPC_PASS;
        
        let rpcUser: string;
        let rpcPass: string;
        
        if (wrapperRpcUser && wrapperRpcPass) {
          // Use wrapper-provided credentials
          rpcUser = wrapperRpcUser;
          rpcPass = wrapperRpcPass;
          fastify.log.info(`Using wrapper-provided RPC credentials for ${instanceId}`);
        } else {
          // Generate cryptographically secure credentials
          const crypto = await import('crypto');
          rpcUser = `gm-${instanceId}`;
          // Generate 32 bytes of random data, encode as base64url (URL-safe, no padding)
          rpcPass = crypto.randomBytes(32).toString('base64url');
          fastify.log.info(`Generated secure RPC credentials for ${instanceId}`);
        }
        
        // Select appropriate peers based on implementation and network type
        const torOnly = !body.ipv4Enabled;
        let selectedPeers: string[] = [];
        
        if (torOnly) {
          // Tor-only: pick up to 4 random .onion addresses from Tor discovery
          if (body.implementation === 'garbageman') {
            // Garbageman nodes: Prefer Libre Relay peers
            const torPeers = torPeerDiscoveryService.getRandomPeers(4, { libreRelayOnly: true });
            selectedPeers = torPeers.map(p => {
              // .onion addresses don't need brackets or ports, but IPv6 does
              if (p.host.includes(':') && !p.host.endsWith('.onion')) {
                return `[${p.host}]:${p.port}`;
              }
              return p.host.endsWith('.onion') ? p.host : `${p.host}:${p.port}`;
            });
            fastify.log.info(`Selected ${selectedPeers.length} Libre Relay Tor peers for ${instanceId}`);
          } else if (body.implementation === 'knots') {
            // Bitcoin Knots nodes: Prefer Core v30+ peers (from clearnet Tor-compatible peers)
            const torPeers = peerDiscoveryService.getRandomPeers('coreV30Plus', 4, { torOnly: true });
            selectedPeers = torPeers.map(p => {
              if (p.ip.endsWith('.onion')) {
                return p.ip;
              }
              // Handle IPv6 with brackets
              if (p.ip.includes(':')) {
                return `[${p.ip}]:${p.port}`;
              }
              return `${p.ip}:${p.port}`;
            });
            fastify.log.info(`Selected ${selectedPeers.length} Core v30+ Tor peers for ${instanceId}`);
          }
        } else {
          // Clearnet + Tor: pick up to 3 clearnet + up to 3 Tor
          if (body.implementation === 'garbageman') {
            // Garbageman nodes: Prefer Libre Relay peers
            // Get 3 live clearnet Libre Relay peers
            const clearnetPeers = peerDiscoveryService.getRandomPeers('libreRelay', 3, { torOnly: false });
            // Get 3 Tor Libre Relay peers
            const torPeers = torPeerDiscoveryService.getRandomPeers(3, { libreRelayOnly: true });
            
            const clearnetAddrs = clearnetPeers.map(p => {
              // Handle IPv6 addresses with bracket notation
              if (p.ip.includes(':')) {
                return `[${p.ip}]:${p.port}`;
              }
              return `${p.ip}:${p.port}`;
            });
            const torAddrs = torPeers.map(p => {
              // .onion addresses don't need brackets, but IPv6 does
              if (p.host.includes(':') && !p.host.endsWith('.onion')) {
                return `[${p.host}]:${p.port}`;
              }
              return p.host.endsWith('.onion') ? p.host : `${p.host}:${p.port}`;
            });
            
            selectedPeers = [...clearnetAddrs, ...torAddrs];
            fastify.log.info(`Selected ${clearnetAddrs.length} clearnet + ${torAddrs.length} Tor Libre Relay peers for ${instanceId}`);
          } else if (body.implementation === 'knots') {
            // Bitcoin Knots nodes: Prefer Core v30+ peers
            // Get 3 live clearnet Core v30+ peers
            const clearnetPeers = peerDiscoveryService.getRandomPeers('coreV30Plus', 3, { torOnly: false });
            // Get 3 Tor-compatible Core v30+ peers (from clearnet discovery that have .onion)
            const torPeers = peerDiscoveryService.getRandomPeers('coreV30Plus', 3, { torOnly: true });
            
            const clearnetAddrs = clearnetPeers.map(p => {
              // Handle IPv6 addresses with bracket notation
              if (p.ip.includes(':')) {
                return `[${p.ip}]:${p.port}`;
              }
              return `${p.ip}:${p.port}`;
            });
            const torAddrs = torPeers.map(p => {
              if (p.ip.endsWith('.onion')) {
                return p.ip;
              }
              // Handle IPv6 with brackets
              if (p.ip.includes(':')) {
                return `[${p.ip}]:${p.port}`;
              }
              return `${p.ip}:${p.port}`;
            });
            
            selectedPeers = [...clearnetAddrs, ...torAddrs];
            fastify.log.info(`Selected ${clearnetAddrs.length} clearnet + ${torAddrs.length} Tor Core v30+ peers for ${instanceId}`);
          }
        }
        
        // Create instance config
        const config: InstanceConfig = {
          INSTANCE_ID: instanceId,
          RPC_PORT: rpcPort,
          P2P_PORT: p2pPort,
          ZMQ_PORT: zmqPort,
          TOR_ONION: body.torOnion || '', // empty string instead of undefined
          BITCOIN_IMPL: body.implementation,
          // BITCOIN_VERSION will be populated by supervisor when daemon starts
          NETWORK: body.network,
          IPV4_ENABLED: body.ipv4Enabled ? 'true' : 'false',
          RPC_USER: rpcUser,
          RPC_PASS: rpcPass,
          ADDNODE: selectedPeers.length > 0 ? selectedPeers.join(',') : undefined,
        };
        
        // Extract blockchain data BEFORE writing config (supervisor will auto-start on config write)
        const useBlockchain = body.useBlockchainSnapshot !== false; // default to true if not specified
        
        // BLOCKCHAIN EXTRACTION & PRIVACY PROTECTION
        // ===========================================
        // Features:
        //  - Validates artifact names to prevent command injection
        //  - Supports multi-part archives (blockchain.tar.gz.part01, part02, etc.)
        //  - Extracts with proper ownership (UID 1001) for Start9/Umbrel compatibility
        //  - Cleans sensitive files from both root and network subdirectories:
        //    * Tor private keys (prevents identity reuse)
        //    * Port configs (prevents bind conflicts)
        //    * Peer data (prevents tracking)
        //    * Debug logs (contains IP addresses)
        
        let extractingBlockchain = false;
        
        if (body.artifact && useBlockchain) {
          // Validate artifact name to prevent command injection
          if (!/^[a-zA-Z0-9._-]+$/.test(body.artifact)) {
            fastify.log.warn(`Invalid artifact name rejected: ${body.artifact}`);
            return reply.code(400).send({
              success: false,
              instanceId,
              message: 'Invalid artifact name. Only alphanumeric, dot, dash, and underscore allowed.',
            });
          }
          
          const fs = await import('fs/promises');
          const path = await import('path');
          const artifactPath = path.join(process.env.ARTIFACTS_DIR || '/root/artifacts', body.artifact);
          
          // First, check the artifact metadata to see if blockchain data is available
          const metadataPath = path.join(artifactPath, 'metadata.json');
          let hasBlockchainInMetadata = false;
          try {
            const metadataContent = await fs.readFile(metadataPath, 'utf-8');
            const metadata = JSON.parse(metadataContent);
            hasBlockchainInMetadata = metadata.hasBlockchain === true;
            
            if (!hasBlockchainInMetadata) {
              fastify.log.error(`Artifact ${body.artifact} metadata indicates no blockchain data available`);
              return reply.code(400).send({
                success: false,
                instanceId,
                message: `Artifact '${body.artifact}' was imported without blockchain data. Please re-import the artifact with the "Include Blockchain Data" option checked.`,
              });
            }
          } catch (metadataError) {
            fastify.log.warn(`Could not read metadata for ${body.artifact}, will attempt to find blockchain files directly`);
          }
          
          // Check if blockchain files exist before starting background extraction
          const blockchainTarPath = `${artifactPath}/blockchain.tar.gz`;
          try {
            await fs.access(blockchainTarPath);
          } catch {
            try {
              await fs.access(`${artifactPath}/blockchain.tar.gz.part01`);
            } catch {
              const errorMsg = hasBlockchainInMetadata 
                ? `Metadata indicates blockchain data should be present, but files are missing. The import may have been incomplete.`
                : `No blockchain data found in artifact '${body.artifact}'.`;
              return reply.code(400).send({
                success: false,
                instanceId,
                message: errorMsg,
              });
            }
          }
          
          // Start blockchain extraction in background (don't await)
          extractingBlockchain = true;
          fastify.log.info(`Starting background blockchain extraction for ${instanceId}`);
          extractBlockchainData(fastify, body.artifact, instanceId, body.network, config).catch(err => {
            fastify.log.error(`Background blockchain extraction failed: ${err}`);
          });
        } else if (body.artifact && !useBlockchain) {
          fastify.log.info(`Skipping blockchain extraction for ${instanceId} - user chose to resync from scratch`);
        }
        
        // Write to envfiles ONLY if not extracting blockchain (triggers supervisor to auto-start)
        // If extracting blockchain, the helper function will write config after extraction completes
        if (!extractingBlockchain) {
          await envstore.writeInstanceConfig(config);
          
          // Tell supervisor to reload instances immediately
          try {
            const reloadResponse = await fetch(`${SUPERVISOR_URL}/reload`, {
              method: 'POST',
              signal: AbortSignal.timeout(5000),
            });
            if (reloadResponse.ok) {
              fastify.log.info(`Supervisor reloaded - instance ${instanceId} is now available`);
            }
          } catch (reloadErr) {
            fastify.log.warn(`Failed to reload supervisor: ${reloadErr}. Instance will be available within 10 seconds.`);
          }
        }
        
        fastify.log.info(`Created instance: ${instanceId} (artifact: ${body.artifact}, clearnet: ${body.clearnet})`);
        
        // Log event
        logInstanceCreated(instanceId);
        
        // Return 202 if blockchain is being extracted, 201 otherwise
        const statusCode = extractingBlockchain ? 202 : 201;
        const message = extractingBlockchain 
          ? 'Instance created. Blockchain extraction in progress - instance will start when complete.'
          : 'Instance created successfully';
        
        reply.code(statusCode).send({
          success: true,
          instanceId,
          message,
        });
      } catch (err) {
        fastify.log.error(err);
        reply.code(500).send({
          success: false,
          instanceId: '',
          message: 'Failed to create instance',
        });
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // PUT /api/instances/:id - Update instance config
  // --------------------------------------------------------------------------
  
  fastify.put<{
    Params: { id: string };
    Body: UpdateInstanceRequest;
    Reply: UpdateInstanceResponse;
  }>(
    '/api/instances/:id',
    async (request, reply) => {
      try {
        const { id } = request.params;
        const updates = request.body;
        
        // Check if instance exists
        const exists = await envstore.instanceExists(id);
        if (!exists) {
          return reply.code(404).send({
            success: false,
            message: 'Instance not found',
          });
        }
        
        // Read existing config
        const config = await envstore.readInstanceConfig(id);
        
        // Apply updates (only mutable fields)
        if (updates.torOnion !== undefined) {
          config.TOR_ONION = updates.torOnion;
        }
        
        if (updates.version !== undefined) {
          config.BITCOIN_VERSION = updates.version;
        }
        
        // Write back
        await envstore.writeInstanceConfig(config);
        
        fastify.log.info(`Updated instance: ${id}`);
        
        reply.send({
          success: true,
          message: 'Instance updated successfully',
        });
      } catch (err) {
        fastify.log.error(err);
        reply.code(500).send({
          success: false,
          message: 'Failed to update instance',
        });
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // DELETE /api/instances/:id - Delete instance
  // --------------------------------------------------------------------------
  
  fastify.delete<{
    Params: { id: string };
    Reply: DeleteInstanceResponse;
  }>(
    '/api/instances/:id',
    async (request, reply) => {
      try {
        const { id } = request.params;
        
        // Check if instance exists
        const exists = await envstore.instanceExists(id);
        if (!exists) {
          return reply.code(404).send({
            success: false,
            message: 'Instance not found',
          });
        }
        
        // Delete config file
        await envstore.deleteInstanceConfig(id);
        
        fastify.log.info(`Deleted instance: ${id}`);
        
        // Log event
        logInstanceDeleted(id);
        
        reply.send({
          success: true,
          message: 'Instance deleted successfully',
        });
      } catch (err) {
        fastify.log.error(err);
        reply.code(500).send({
          success: false,
          message: 'Failed to delete instance',
        });
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // POST /api/instances/:id/start - Start instance
  // --------------------------------------------------------------------------
  
  fastify.post<{
    Params: { id: string };
  }>(
    '/api/instances/:id/start',
    async (request, reply) => {
      try {
        const { id } = request.params;
        
        // Check if instance exists
        const exists = await envstore.instanceExists(id);
        if (!exists) {
          return reply.code(404).send({
            success: false,
            message: 'Instance not found',
          });
        }
        
        // Try to start instance, with retry logic for newly created instances
        let lastError: Error | null = null;
        const maxRetries = 3;
        const retryDelay = 500; // ms
        
        for (let attempt = 1; attempt <= maxRetries; attempt++) {
          try {
            // Call supervisor to start instance
            const response = await fetch(`${SUPERVISOR_URL}/instances/${id}/start`, {
              method: 'POST',
              signal: AbortSignal.timeout(10000),
            });
            
            if (!response.ok) {
              if (response.status === 404 && attempt < maxRetries) {
                // Supervisor hasn't discovered instance yet, try to reload and retry
                fastify.log.info(`Instance ${id} not found in supervisor (attempt ${attempt}/${maxRetries}), triggering reload...`);
                try {
                  await fetch(`${SUPERVISOR_URL}/reload`, {
                    method: 'POST',
                    signal: AbortSignal.timeout(5000),
                  });
                } catch {
                  // Ignore reload errors
                }
                // Wait before retry
                await new Promise(resolve => setTimeout(resolve, retryDelay));
                continue;
              }
              throw new Error(`Supervisor error: ${response.status}`);
            }
            
            const result = await response.json();
            
            fastify.log.info(`Started instance: ${id}`);
            
            // Log event
            logInstanceStarted(id);
            
            return reply.send({
              success: true,
              message: `Instance ${id} started`,
              result,
            });
          } catch (err) {
            lastError = err instanceof Error ? err : new Error(String(err));
            if (attempt === maxRetries) {
              throw lastError;
            }
          }
        }
        
        throw lastError || new Error('Failed to start instance');
      } catch (err) {
        fastify.log.error(err);
        reply.code(500).send({
          success: false,
          message: 'Failed to start instance',
        });
      }
    }
  );
  
  // --------------------------------------------------------------------------
  // POST /api/instances/:id/stop - Stop instance
  // --------------------------------------------------------------------------
  
  fastify.post<{
    Params: { id: string };
  }>(
    '/api/instances/:id/stop',
    async (request, reply) => {
      try {
        const { id } = request.params;
        
        // Check if instance exists
        const exists = await envstore.instanceExists(id);
        if (!exists) {
          return reply.code(404).send({
            success: false,
            message: 'Instance not found',
          });
        }
        
        // Call supervisor to stop instance
        const response = await fetch(`${SUPERVISOR_URL}/instances/${id}/stop`, {
          method: 'POST',
          signal: AbortSignal.timeout(10000),
        });
        
        if (!response.ok) {
          throw new Error(`Supervisor error: ${response.status}`);
        }
        
        const result = await response.json();
        
        fastify.log.info(`Stopped instance: ${id}`);
        
        // Log event
        logInstanceStopped(id);
        
        reply.send({
          success: true,
          message: `Instance ${id} stopped`,
          result,
        });
      } catch (err) {
        fastify.log.error(err);
        reply.code(500).send({
          success: false,
          message: 'Failed to stop instance',
        });
      }
    }
  );
}
