/**
 * Stub Data for UI Development
 * =============================
 * Mock instance data and API responses for testing UI components
 * without needing a running API or supervisor.
 */

export interface InstanceDetail {
  config: {
    INSTANCE_ID: string;
    RPC_PORT: number;
    P2P_PORT: number;
    ZMQ_PORT: number;
    TOR_ONION?: string;
    BITCOIN_IMPL?: 'garbageman' | 'knots';
    BITCOIN_VERSION?: string;
    NETWORK?: 'mainnet' | 'testnet' | 'signet' | 'regtest';
  };
  status: {
    id: string;
    state: 'up' | 'exited' | 'starting' | 'stopping';
    impl: 'garbageman' | 'knots';
    version?: string;
    network: 'mainnet' | 'testnet' | 'signet' | 'regtest';
    uptime: number;
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
    progress: number;
    initialBlockDownload?: boolean;
    diskGb: number;
    rpcPort: number;
    p2pPort: number;
    onion?: string;
    ipv4Enabled: boolean;
    kpiTags: string[];
  };
}

export const stubInstances: InstanceDetail[] = [
  {
    config: {
      INSTANCE_ID: 'gm-clone-20251105-143216',
      RPC_PORT: 19001,
      P2P_PORT: 18001,
      ZMQ_PORT: 28001,
      TOR_ONION: 'p3y4abcd1234567890abcdefghijklmnopqrstuvwxyz.onion',
      BITCOIN_IMPL: 'garbageman',
      NETWORK: 'mainnet',
    },
    status: {
      id: 'gm-clone-20251105-143216',
      state: 'up',
      impl: 'garbageman',
      network: 'mainnet',
      uptime: 345678,
      peers: 12,
      peerBreakdown: {
        libreRelay: 5,
        knots: 3,
        oldCore: 2,
        newCore: 1,
        other: 1,
      },
      blocks: 820450,
      headers: 820450,
      progress: 1.0,
      diskGb: 150.3,
      rpcPort: 19001,
      p2pPort: 18001,
      onion: 'p3y4abcd1234567890abcdefghijklmnopqrstuvwxyz.onion',
      ipv4Enabled: false,
      kpiTags: ['pruned', 'tor-only', 'mainnet', 'synced'],
    },
  },
  {
    config: {
      INSTANCE_ID: 'gm-clone-20251105-143954',
      RPC_PORT: 19002,
      P2P_PORT: 18002,
      ZMQ_PORT: 28002,
      BITCOIN_IMPL: 'knots',
      NETWORK: 'testnet',
    },
    status: {
      id: 'gm-clone-20251105-143954',
      state: 'up',
      impl: 'knots',
      network: 'testnet',
      uptime: 123456,
      peers: 8,
      peerBreakdown: {
        libreRelay: 2,
        knots: 1,
        oldCore: 1,
        newCore: 3,
        other: 1,
      },
      blocks: 2505123,
      headers: 2505200,
      progress: 0.997,
      diskGb: 45.8,
      rpcPort: 19002,
      p2pPort: 18002,
      ipv4Enabled: true,
      kpiTags: ['full-node', 'clearnet', 'testnet', 'syncing'],
    },
  },
  {
    config: {
      INSTANCE_ID: 'gm_base',
      RPC_PORT: 19000,
      P2P_PORT: 18000,
      ZMQ_PORT: 28000,
      BITCOIN_IMPL: 'garbageman',
      NETWORK: 'mainnet',
    },
    status: {
      id: 'gm_base',
      state: 'exited',
      impl: 'garbageman',
      network: 'mainnet',
      uptime: 0,
      peers: 0,
      blocks: 0,
      headers: 0,
      progress: 0.0,
      diskGb: 0,
      rpcPort: 19000,
      p2pPort: 18000,
      ipv4Enabled: false,
      kpiTags: ['base-template'],
    },
  },
];

/**
 * Simulate API fetch delay
 */
export const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Mock API client for UI development
 */
export const mockAPI = {
  async getInstances(): Promise<InstanceDetail[]> {
    await delay(300);
    return stubInstances;
  },

  async getInstance(id: string): Promise<InstanceDetail | null> {
    await delay(200);
    return stubInstances.find((i) => i.config.INSTANCE_ID === id) || null;
  },

  async createInstance(data: Partial<InstanceDetail['config']>): Promise<{ success: boolean; instanceId: string }> {
    await delay(500);
    return {
      success: true,
      instanceId: `gm-clone-${Date.now()}`,
    };
  },

  async deleteInstance(id: string): Promise<{ success: boolean }> {
    await delay(400);
    return { success: true };
  },
};
