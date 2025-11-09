/**
 * Type Definitions for Garbageman WebUI API
 * ==========================================
 * Shared types for daemon instances, ENV schemas, and API contracts.
 */

// ============================================================================
// Instance Configuration (ENV File Schema)
// ============================================================================

/**
 * Schema for GLOBAL.env - shared defaults for all instances
 */
export interface GlobalConfig {
  BITCOIN_IMPL: 'garbageman' | 'knots';
  NETWORK: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  BASE_DATA_DIR: string;
  EXPOSE_CLEARLY: '0' | '1'; // whether to allow clearnet P2P
}

/**
 * Schema for envfiles/instances/*.env - per-instance configuration
 */
export interface InstanceConfig {
  INSTANCE_ID: string;
  RPC_PORT: number;
  P2P_PORT: number;
  ZMQ_PORT: number;
  TOR_ONION?: string; // optional Tor onion address
  ADDNODE?: string; // Comma-separated list of peer addresses (ip:port)
  ARTIFACT?: string; // Artifact tag (e.g., "v2025-11-03-rc2") for binary location
  // Optional overrides (inherit from GLOBAL if not set)
  BITCOIN_IMPL?: 'garbageman' | 'knots';
  BITCOIN_VERSION?: string; // e.g., "29.2.0"
  NETWORK?: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  RPC_USER?: string;
  RPC_PASS?: string;
  IPV4_ENABLED?: 'true' | 'false'; // Whether clearnet (IPv4/IPv6) is enabled
}

// ============================================================================
// Runtime Instance State (from multi-daemon supervisor)
// ============================================================================

/**
 * Live status of a daemon instance as reported by the supervisor
 */
export interface InstanceStatus {
  id: string;
  state: 'up' | 'exited' | 'starting' | 'stopping';
  impl: 'garbageman' | 'knots';
  version?: string; // e.g., "29.2.0"
  network: 'mainnet' | 'testnet' | 'signet' | 'regtest';
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
  progress: number; // 0.0 to 1.0 (blockchain sync progress)
  initialBlockDownload?: boolean; // true during initial sync/header download
  diskGb: number;
  rpcPort: number;
  p2pPort: number;
  onion?: string;
  ipv4Enabled: boolean;
  kpiTags: string[]; // e.g., ["pruned", "tor-only", "mainnet"]
}

/**
 * Combined view: static config + live status
 */
export interface InstanceDetail {
  config: InstanceConfig;
  status: InstanceStatus;
}

// ============================================================================
// API Request/Response Shapes
// ============================================================================

/**
 * POST /api/instances - Create a new instance
 */
export interface CreateInstanceRequest {
  instanceId?: string; // auto-generate if not provided
  artifact: string; // e.g., "v2025-11-03-rc2"
  implementation: 'garbageman' | 'knots';
  network: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  clearnet?: boolean; // Deprecated: use ipv4Enabled instead
  ipv4Enabled: boolean; // true = allow IPv4/IPv6, false = Tor-only
  useBlockchainSnapshot?: boolean; // true = extract blockchain data if available (default), false = resync from scratch
  rpcPort?: number; // auto-assign if not provided
  p2pPort?: number;
  zmqPort?: number;
  torOnion?: string;
}

export interface CreateInstanceResponse {
  success: boolean;
  instanceId: string;
  message: string;
}

/**
 * PUT /api/instances/:id - Update instance configuration
 */
export interface UpdateInstanceRequest {
  torOnion?: string;
  version?: string; // Bitcoin Core version (e.g., "29.2.0") - set by supervisor after querying daemon
  // Cannot change ports after creation (would require daemon restart + conflict check)
}

export interface UpdateInstanceResponse {
  success: boolean;
  message: string;
}

/**
 * DELETE /api/instances/:id - Delete instance
 */
export interface DeleteInstanceResponse {
  success: boolean;
  message: string;
}

/**
 * GET /api/instances - List all instances
 */
export interface ListInstancesResponse {
  instances: InstanceDetail[];
}

/**
 * POST /api/artifacts/import - Import daemon artifacts (binaries)
 */
export interface ImportArtifactRequest {
  source: 'github' | 'url';
  version?: string; // e.g., "25.0" for Bitcoin Core
  url?: string; // direct download URL
  impl: 'garbageman' | 'knots';
}

export interface ImportArtifactResponse {
  success: boolean;
  message: string;
  artifact?: {
    impl: string;
    version: string;
    path: string;
    sha256?: string;
  };
}

// ============================================================================
// Health Check
// ============================================================================

export interface HealthResponse {
  status: 'ok' | 'degraded' | 'error';
  version: string;
  timestamp: string;
  services: {
    api: 'ok' | 'error';
    supervisor: 'ok' | 'error' | 'unknown';
    envfiles: 'ok' | 'error';
  };
}
