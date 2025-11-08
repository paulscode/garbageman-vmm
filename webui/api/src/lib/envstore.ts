/**
 * ENV Store - Read/Write ENV Files
 * ==================================
 * Manages envfiles/GLOBAL.env and envfiles/instances/*.env
 * 
 * Design decisions:
 *  - Atomic writes: write to .tmp file, then rename (safer on crashes)
 *  - Comment preservation: NOT implemented in MVP (limitation noted)
 *  - Validation: Schema checks on read/write + security validation for instance IDs
 *  - Security: Instance ID validation prevents path traversal attacks
 *  - Thread safety: Node.js single-threaded, but file locks would be needed for multi-process
 */

import * as fs from 'fs/promises';
import * as path from 'path';
import type { GlobalConfig, InstanceConfig } from './types.js';

// ============================================================================
// Configuration Paths
// ============================================================================

const ENV_BASE_DIR = process.env.ENVFILES_DIR || '/envfiles';
const GLOBAL_ENV_PATH = path.join(ENV_BASE_DIR, 'GLOBAL.env');
const INSTANCES_DIR = path.join(ENV_BASE_DIR, 'instances');

// ============================================================================
// Security: Instance ID Validation
// ============================================================================

/**
 * Validate instance ID to prevent path traversal attacks.
 * Only allows alphanumeric characters, hyphens, and underscores.
 * Throws error if validation fails.
 */
function validateInstanceId(instanceId: string): void {
  // Check format: only alphanumeric, dash, underscore
  if (!/^[a-zA-Z0-9_-]+$/.test(instanceId)) {
    throw new Error(`Invalid instance ID format: ${instanceId}. Only alphanumeric, dash, and underscore allowed.`);
  }
  
  // Check length (reasonable limit)
  if (instanceId.length < 1 || instanceId.length > 100) {
    throw new Error(`Instance ID length must be 1-100 characters: ${instanceId}`);
  }
  
  // Ensure resolved path stays within INSTANCES_DIR (defense in depth)
  const instancePath = path.join(INSTANCES_DIR, `${instanceId}.env`);
  const resolved = path.resolve(instancePath);
  const allowed = path.resolve(INSTANCES_DIR);
  
  if (!resolved.startsWith(allowed + path.sep) && resolved !== allowed) {
    throw new Error(`Path traversal detected in instance ID: ${instanceId}`);
  }
}

// ============================================================================
// ENV File Parsing
// ============================================================================

/**
 * Parse a .env file into a key-value object.
 * Strips comments and handles basic escaping.
 * 
 * NOTE: This implementation does NOT preserve comments when writing back.
 * For production, consider a library like `dotenv-parse-and-stringify` or
 * implement a proper parser that maintains the AST.
 */
export function parseEnvFile(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    
    // Skip empty lines and comments
    if (!trimmed || trimmed.startsWith('#')) {
      continue;
    }
    
    // Parse KEY=VALUE
    const match = trimmed.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (match) {
      const [, key, value] = match;
      // Strip quotes if present
      const cleanValue = value.replace(/^["']|["']$/g, '');
      result[key] = cleanValue;
    }
  }
  
  return result;
}

/**
 * Serialize key-value object back to .env format.
 * 
 * LIMITATION: Does NOT preserve original comments or formatting.
 * New files will be generated with alphabetically sorted keys and no comments.
 * For production, implement a proper AST-based serializer.
 */
export function serializeEnvFile(data: Record<string, string>): string {
  const lines: string[] = [];
  
  // Sort keys for deterministic output
  const keys = Object.keys(data).sort();
  
  for (const key of keys) {
    const value = data[key];
    // Quote values that contain spaces or special chars
    const needsQuotes = /[\s#]/.test(value);
    const serialized = needsQuotes ? `"${value}"` : value;
    lines.push(`${key}=${serialized}`);
  }
  
  return lines.join('\n') + '\n';
}

// ============================================================================
// Global Config
// ============================================================================

/**
 * Read GLOBAL.env and parse into typed GlobalConfig
 */
export async function readGlobalConfig(): Promise<GlobalConfig> {
  try {
    const content = await fs.readFile(GLOBAL_ENV_PATH, 'utf-8');
    const parsed = parseEnvFile(content);
    
    // Validate and cast to typed config
    return {
      BITCOIN_IMPL: (parsed.BITCOIN_IMPL as GlobalConfig['BITCOIN_IMPL']) || 'garbageman',
      NETWORK: (parsed.NETWORK as GlobalConfig['NETWORK']) || 'mainnet',
      BASE_DATA_DIR: parsed.BASE_DATA_DIR || '/data/bitcoin',
      EXPOSE_CLEARLY: (parsed.EXPOSE_CLEARLY as '0' | '1') || '0',
    };
  } catch (err) {
    // If file doesn't exist, return defaults
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      return {
        BITCOIN_IMPL: 'garbageman',
        NETWORK: 'mainnet',
        BASE_DATA_DIR: '/data/bitcoin',
        EXPOSE_CLEARLY: '0',
      };
    }
    throw err;
  }
}

/**
 * Write GLOBAL.env (atomic write via temp file)
 */
export async function writeGlobalConfig(config: GlobalConfig): Promise<void> {
  const tmpPath = `${GLOBAL_ENV_PATH}.tmp`;
  
  // Ensure base directory exists
  await fs.mkdir(path.dirname(GLOBAL_ENV_PATH), { recursive: true });
  
  // Serialize and write to temp file
  const content = serializeEnvFile(config as unknown as Record<string, string>);
  await fs.writeFile(tmpPath, content, 'utf-8');
  
  // Atomic rename
  await fs.rename(tmpPath, GLOBAL_ENV_PATH);
}

// ============================================================================
// Instance Configs
// ============================================================================

/**
 * List all instance IDs (based on .env files in instances/)
 */
export async function listInstanceIds(): Promise<string[]> {
  try {
    const files = await fs.readdir(INSTANCES_DIR);
    return files
      .filter(f => f.endsWith('.env'))
      .map(f => f.replace(/\.env$/, ''));
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      return [];
    }
    throw err;
  }
}

/**
 * Read a single instance config by ID
 */
export async function readInstanceConfig(instanceId: string): Promise<InstanceConfig> {
  validateInstanceId(instanceId); // Security: Prevent path traversal
  
  const instancePath = path.join(INSTANCES_DIR, `${instanceId}.env`);
  const content = await fs.readFile(instancePath, 'utf-8');
  const parsed = parseEnvFile(content);
  
  return {
    INSTANCE_ID: parsed.INSTANCE_ID || instanceId,
    RPC_PORT: parseInt(parsed.RPC_PORT || '0', 10),
    P2P_PORT: parseInt(parsed.P2P_PORT || '0', 10),
    ZMQ_PORT: parseInt(parsed.ZMQ_PORT || '0', 10),
    TOR_ONION: parsed.TOR_ONION,
    BITCOIN_IMPL: parsed.BITCOIN_IMPL as InstanceConfig['BITCOIN_IMPL'],
    NETWORK: parsed.NETWORK as InstanceConfig['NETWORK'],
    RPC_USER: parsed.RPC_USER,
    RPC_PASS: parsed.RPC_PASS,
    IPV4_ENABLED: parsed.IPV4_ENABLED as InstanceConfig['IPV4_ENABLED'],
    BITCOIN_VERSION: parsed.BITCOIN_VERSION,
    ADDNODE: parsed.ADDNODE,
  };
}

/**
 * Write instance config (atomic write)
 */
export async function writeInstanceConfig(config: InstanceConfig): Promise<void> {
  validateInstanceId(config.INSTANCE_ID); // Security: Prevent path traversal
  
  const instancePath = path.join(INSTANCES_DIR, `${config.INSTANCE_ID}.env`);
  const tmpPath = `${instancePath}.tmp`;
  
  // Ensure instances directory exists
  await fs.mkdir(INSTANCES_DIR, { recursive: true });
  
  // Serialize and write
  const content = serializeEnvFile(config as unknown as Record<string, string>);
  await fs.writeFile(tmpPath, content, 'utf-8');
  
  // Atomic rename
  await fs.rename(tmpPath, instancePath);
}

/**
 * Delete instance config
 */
export async function deleteInstanceConfig(instanceId: string): Promise<void> {
  validateInstanceId(instanceId); // Security: Prevent path traversal
  
  const instancePath = path.join(INSTANCES_DIR, `${instanceId}.env`);
  await fs.unlink(instancePath);
}

/**
 * Read all instance configs
 */
export async function readAllInstanceConfigs(): Promise<InstanceConfig[]> {
  const ids = await listInstanceIds();
  return Promise.all(ids.map(id => readInstanceConfig(id)));
}

/**
 * Check if an instance ID already exists
 */
export async function instanceExists(instanceId: string): Promise<boolean> {
  validateInstanceId(instanceId); // Security: Prevent path traversal
  
  const instancePath = path.join(INSTANCES_DIR, `${instanceId}.env`);
  try {
    await fs.access(instancePath);
    return true;
  } catch {
    return false;
  }
}

/**
 * Generate a unique instance ID with timestamp
 * Format: prefix-YYYYMMDD-HHMMSS (e.g., "node-20251106-040206")
 */
export function generateInstanceId(prefix = 'node'): string {
  const now = new Date();
  const date = now.toISOString().split('T')[0].replace(/-/g, ''); // YYYYMMDD
  const time = now.toISOString().split('T')[1].split('.')[0].replace(/:/g, ''); // HHMMSS
  return `${prefix}-${date}-${time}`;
}

/**
 * Find next available port in a range (simple linear search)
 * Used to auto-assign ports when creating new instances.
 */
export async function findAvailablePort(
  startPort: number,
  endPort: number,
  usedPorts: Set<number>
): Promise<number> {
  for (let port = startPort; port <= endPort; port++) {
    if (!usedPorts.has(port)) {
      return port;
    }
  }
  throw new Error(`No available ports in range ${startPort}-${endPort}`);
}

/**
 * Get all ports currently in use by instances
 */
export async function getUsedPorts(): Promise<{
  rpc: Set<number>;
  p2p: Set<number>;
  zmq: Set<number>;
}> {
  const configs = await readAllInstanceConfigs();
  
  return {
    rpc: new Set(configs.map(c => c.RPC_PORT)),
    p2p: new Set(configs.map(c => c.P2P_PORT)),
    zmq: new Set(configs.map(c => c.ZMQ_PORT)),
  };
}
