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
  validateUpdateInstance,
  validateInstanceIdParam,
  formatValidationErrors,
} from '../lib/validation.js';

const SUPERVISOR_URL = process.env.SUPERVISOR_URL || 'http://multi-daemon:9000';

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
          
          const artifactPath = `/app/.artifacts/${body.artifact}`;
          let blockchainTarPath = `${artifactPath}/blockchain.tar.gz`;
          const fs = await import('fs/promises');
          const path = await import('path');
          
          try {
            // Check if blockchain.tar.gz exists, or if we have split parts
            let needsConcat = false;
            try {
              await fs.access(blockchainTarPath);
            } catch {
              // Check for split parts (blockchain.tar.gz.part01, part02, etc.)
              try {
                await fs.access(`${artifactPath}/blockchain.tar.gz.part01`);
                needsConcat = true;
                fastify.log.info(`Found split blockchain archive for ${body.artifact}`);
              } catch {
                throw new Error('No blockchain data found');
              }
            }
            
            // If we have split parts, concatenate them first
            if (needsConcat) {
              blockchainTarPath = `${artifactPath}/blockchain.tar.gz`;
              fastify.log.info(`Concatenating split archive parts for ${instanceId}`);
              
              const { spawn } = await import('child_process');
              await new Promise<void>((resolve, reject) => {
                // Use cat to concatenate all parts: cat part01 part02 ... > blockchain.tar.gz
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
            const instanceDataDir = `/data/bitcoin/${instanceId}`;
            
            // Verify paths are within allowed directories (prevent path traversal)
            const resolvedArtifactPath = path.resolve(artifactPath);
            const resolvedInstanceDir = path.resolve(instanceDataDir);
            
            if (!resolvedArtifactPath.startsWith('/app/.artifacts/')) {
              throw new Error('Artifact path outside allowed directory');
            }
            if (!resolvedInstanceDir.startsWith('/data/bitcoin/')) {
              throw new Error('Instance data path outside allowed directory');
            }
            
            // Ensure instance data directory exists
            await fs.mkdir(instanceDataDir, { recursive: true });
            
            // Extract blockchain data using spawn (safer than shell)
            const { spawn } = await import('child_process');
            fastify.log.info(`Extracting blockchain data for ${instanceId} from ${blockchainTarPath}`);
            
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
            // Use numeric UID to avoid needing user/group lookup
            await new Promise<void>((resolve, reject) => {
              const chown = spawn('chown', ['-R', '1001:1001', instanceDataDir]);
              
              chown.on('exit', (code) => {
                if (code === 0) {
                  resolve();
                } else {
                  // Non-fatal - log warning but continue
                  fastify.log.warn(`chown failed with code ${code}, permissions may be incorrect`);
                  resolve();
                }
              });
              
              chown.on('error', (err) => {
                // Non-fatal
                fastify.log.warn(`chown error: ${err.message}, permissions may be incorrect`);
                resolve();
              });
            });
            
            // Remove state files and sensitive identifying data to prevent conflicts and privacy leaks
            // These files will be regenerated by Bitcoin Core/Knots with new instance's configuration
            const stateFiles = [
              'settings.json',        // Port and config settings
              'peers.dat',            // Peer connections (identifying)
              '.lock',                // Process lock
              'banlist.json',         // Node-specific ban list
              'debug.log',            // Contains IPs and connection patterns
              'bitcoind.pid',         // Process ID
              'onion_v3_private_key', // Tor hidden service private key (CRITICAL - prevents key reuse)
              'anchors.dat',          // Trusted peer anchors
              'mempool.dat',          // Mempool state
              'fee_estimates.dat',    // Fee estimation data
            ];
            
            // Clean files from both root datadir and network subdirectory
            // Networks like testnet/signet/regtest create subdirectories
            const networkSubdir = body.network === 'mainnet' ? '' : body.network;
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
                } catch (unlinkErr) {
                  // File might not exist - that's fine
                }
              }
            }
            fastify.log.info(`Cleaned state and identity files from ${instanceId} for privacy and uniqueness`);
            
            fastify.log.info(`Blockchain data extracted to ${instanceDataDir}`);
          } catch (blockchainErr) {
            // Blockchain file doesn't exist or extraction failed - that's okay
            fastify.log.warn(`No blockchain data for artifact ${body.artifact} or extraction failed: ${blockchainErr}`);
          }
        } else if (body.artifact && !useBlockchain) {
          fastify.log.info(`Skipping blockchain extraction for ${instanceId} - user chose to resync from scratch`);
        }
        
        // Write to envfiles (this triggers supervisor to auto-start the instance)
        await envstore.writeInstanceConfig(config);
        
        fastify.log.info(`Created instance: ${instanceId} (artifact: ${body.artifact}, clearnet: ${body.clearnet})`);
        
        // Log event
        logInstanceCreated(instanceId);
        
        reply.code(201).send({
          success: true,
          instanceId,
          message: 'Instance created successfully',
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
        
        // Call supervisor to start instance
        const response = await fetch(`${SUPERVISOR_URL}/instances/${id}/start`, {
          method: 'POST',
          signal: AbortSignal.timeout(10000),
        });
        
        if (!response.ok) {
          throw new Error(`Supervisor error: ${response.status}`);
        }
        
        const result = await response.json();
        
        fastify.log.info(`Started instance: ${id}`);
        
        // Log event
        logInstanceStarted(id);
        
        reply.send({
          success: true,
          message: `Instance ${id} started`,
          result,
        });
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
