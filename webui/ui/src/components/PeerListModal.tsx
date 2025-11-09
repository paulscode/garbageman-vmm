'use client';

import { API_BASE_URL } from '@/lib/api-config';
/**
 * Peer List Modal
 * ================
 * Displays discovered Bitcoin peers categorized by capabilities
 * (Libre Relay, Core v30+, All peers)
 */

import { useEffect, useState } from 'react';

interface DiscoveredPeer {
  ip?: string;
  host?: string;  // For .onion addresses
  port: number;
  services: string; // bigint as string
  userAgent: string;
  version: number;
  lastSeen: number;
  isLibreRelay: boolean;
  isCoreV30Plus: boolean;
}

interface SeedCheckResult {
  host: string;
  port: number;
  timestamp: number;
  success: boolean;
  peersReturned: number;
  userAgent?: string;
  error?: string;
}

interface PeerStats {
  total: number;
  libreRelay: number;
  coreV30Plus: number;
  live: number;
  inactive: number;
  liveClearnet: number;
  inactiveClearnet: number;
  liveTor: number;
  inactiveTor: number;
  knots: number;
  oldCore: number;
  other: number;
}

interface ServiceStatus {
  isRunning: boolean;
  status: 'probing' | 'crawling' | 'waiting' | 'stopped';
  currentSeed: string | null;
  nextSeedIn: number;
  totalPeers: number;
  successfulPeers?: number;
  enabled?: boolean;
  running?: boolean;
  torAvailable?: boolean;
}

interface DiscoveryStatus {
  clearnet?: ServiceStatus;
  tor?: ServiceStatus;
  // Legacy flat properties for backwards compatibility
  isRunning?: boolean;
  status?: 'probing' | 'crawling' | 'waiting' | 'stopped';
  currentSeed?: string | null;
  nextSeedIn?: number;
  totalPeers?: number;
}

interface PeerListModalProps {
  isOpen: boolean;
  onClose: () => void;
  authenticatedFetch: (url: string, options?: RequestInit) => Promise<Response>;
}

export function PeerListModal({ isOpen, onClose, authenticatedFetch }: PeerListModalProps) {
  const [loading, setLoading] = useState(true);
  const [stats, setStats] = useState<PeerStats>({ 
    total: 0, 
    libreRelay: 0, 
    coreV30Plus: 0, 
    live: 0, 
    inactive: 0,
    liveClearnet: 0,
    inactiveClearnet: 0,
    liveTor: 0,
    inactiveTor: 0,
    knots: 0,
    oldCore: 0,
    other: 0,
  });
  const [peers, setPeers] = useState<{
    all: DiscoveredPeer[];
    libreRelay: DiscoveredPeer[];
    coreV30Plus: DiscoveredPeer[];
    live: DiscoveredPeer[];
    inactive: DiscoveredPeer[];
  }>({ all: [], libreRelay: [], coreV30Plus: [], live: [], inactive: [] });
  const [seedChecks, setSeedChecks] = useState<SeedCheckResult[]>([]);
  const [activeTab, setActiveTab] = useState<'overview' | 'libreRelay' | 'coreV30Plus' | 'live' | 'inactive' | 'seedsChecked'>('overview');
  const [discoveryStatus, setDiscoveryStatus] = useState<DiscoveryStatus | null>(null);
  const [countdown, setCountdown] = useState<number>(0);

  // Poll for peer updates every 5 seconds
  useEffect(() => {
    if (isOpen) {
      loadPeers();
      loadSeedChecks();
      const interval = setInterval(() => {
        loadPeers();
        loadSeedChecks();
      }, 5000);
      return () => clearInterval(interval);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen]);

  // Poll for status updates every second
  useEffect(() => {
    if (isOpen) {
      loadStatus();
      const interval = setInterval(loadStatus, 1000);
      return () => clearInterval(interval);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen]);

  // Countdown timer
  useEffect(() => {
    if (discoveryStatus && discoveryStatus.nextSeedIn && discoveryStatus.nextSeedIn > 0) {
      setCountdown(discoveryStatus.nextSeedIn);
    }
  }, [discoveryStatus]);

  const loadStatus = async () => {
    try {
      const response = await authenticatedFetch(`${API_BASE_URL}/api/peers/status`);
      const data = await response.json();
      setDiscoveryStatus(data);
    } catch (error) {
      console.error('Failed to load status:', error);
    }
  };

  const loadSeedChecks = async () => {
    try {
      // Request up to 200 most recent checks (reasonable limit for UI)
      const response = await authenticatedFetch(`${API_BASE_URL}/api/peers/seeds?limit=200`);
      const data = await response.json();
      setSeedChecks(data.checks || []);
    } catch (error) {
      console.error('Failed to load seed checks:', error);
    }
  };

  const loadPeers = async () => {
    try {
      setLoading(true);
      const response = await authenticatedFetch(`${API_BASE_URL}/api/peers`);
      const data = await response.json();
      
      // Combine clearnet and tor peers
      const clearnetPeers = data.clearnet?.all || [];
      const torPeers = data.tor?.all || [];
      const allPeers = [...clearnetPeers, ...torPeers];
      
      // Calculate live vs inactive (15 minutes = 900000ms)
      const now = Date.now();
      const fifteenMinutesAgo = now - 900000;
      
      const livePeers = allPeers.filter((p: DiscoveredPeer) => p.lastSeen >= fifteenMinutesAgo);
      const inactivePeers = allPeers.filter((p: DiscoveredPeer) => p.lastSeen < fifteenMinutesAgo);
      
      // Calculate clearnet/tor live/inactive
      const liveClearnet = clearnetPeers.filter((p: DiscoveredPeer) => p.lastSeen >= fifteenMinutesAgo).length;
      const inactiveClearnet = clearnetPeers.filter((p: DiscoveredPeer) => p.lastSeen < fifteenMinutesAgo).length;
      const liveTor = torPeers.filter((p: DiscoveredPeer) => p.lastSeen >= fifteenMinutesAgo).length;
      const inactiveTor = torPeers.filter((p: DiscoveredPeer) => p.lastSeen < fifteenMinutesAgo).length;
      
      // Categorize by node type
      const categorizeNode = (p: DiscoveredPeer) => {
        const ua = p.userAgent.toLowerCase();
        if (p.isLibreRelay) return 'libreRelay';
        if (ua.includes('knots')) return 'knots';
        if (p.isCoreV30Plus) return 'coreV30Plus';
        // Old Core = Satoshi but not v30+
        if (ua.includes('satoshi') && !p.isCoreV30Plus) return 'oldCore';
        return 'other';
      };
      
      const nodeCategories = allPeers.reduce((acc, p) => {
        const cat = categorizeNode(p);
        acc[cat] = (acc[cat] || 0) + 1;
        return acc;
      }, {} as Record<string, number>);
      
      setStats({
        total: (data.stats.clearnet?.total || 0) + (data.stats.tor?.total || 0),
        libreRelay: (data.stats.clearnet?.libreRelay || 0) + (data.stats.tor?.libreRelay || 0),
        coreV30Plus: data.stats.clearnet?.coreV30Plus || 0,
        live: livePeers.length,
        inactive: inactivePeers.length,
        liveClearnet,
        inactiveClearnet,
        liveTor,
        inactiveTor,
        knots: nodeCategories.knots || 0,
        oldCore: nodeCategories.oldCore || 0,
        other: nodeCategories.other || 0,
      });
      setPeers({
        all: allPeers,
        libreRelay: [...(data.clearnet?.libreRelay || []), ...(data.tor?.libreRelay || [])],
        coreV30Plus: data.clearnet?.coreV30Plus || [],
        live: livePeers,
        inactive: inactivePeers,
      });
    } catch (error) {
      console.error('Failed to load peers:', error);
    } finally {
      setLoading(false);
    }
  };

  const formatStatusLine = () => {
    if (!discoveryStatus) {
      return { text: 'Connecting to service...', color: 'bg-tx3', pulsing: false };
    }

    const clearnetStatus = discoveryStatus.clearnet || discoveryStatus;

    if (!clearnetStatus.isRunning) {
      return { text: 'Service stopped', color: 'bg-red-500', pulsing: false };
    }

    if (clearnetStatus.status === 'probing' && clearnetStatus.currentSeed) {
      const seedName = clearnetStatus.currentSeed.split('.').slice(-2).join('.');
      return { 
        text: `Querying ${seedName} for peer gossip...`, 
        color: 'bg-acc-green', 
        pulsing: true 
      };
    }

    if (clearnetStatus.status === 'crawling') {
      return { 
        text: `Crawling ${clearnetStatus.totalPeers || 0} peers to gather more addresses...`, 
        color: 'bg-blue-500', 
        pulsing: true 
      };
    }

    if (clearnetStatus.status === 'waiting' && clearnetStatus.nextSeedIn && clearnetStatus.nextSeedIn > 0) {
      const minutes = Math.floor(countdown / 60);
      const seconds = countdown % 60;
      const timeStr = minutes > 0 
        ? `${minutes}m ${seconds}s` 
        : `${seconds}s`;
      return { 
        text: `Idle - next seed query in ${timeStr}`, 
        color: 'bg-orange-500', 
        pulsing: false 
      };
    }

    return { text: 'Idle', color: 'bg-tx3', pulsing: false };
  };

  const formatTorStatusLine = () => {
    if (!discoveryStatus || !discoveryStatus.tor) {
      return { text: 'Not configured', color: 'bg-tx3', pulsing: false };
    }

    const torStatus = discoveryStatus.tor;

    if (!torStatus.enabled) {
      return { text: 'Disabled', color: 'bg-tx3', pulsing: false };
    }

    if (!torStatus.running) {
      return { text: 'Service stopped', color: 'bg-red-500', pulsing: false };
    }

    if (!torStatus.torAvailable) {
      return { text: 'Tor proxy unavailable - paused', color: 'bg-red-500', pulsing: false };
    }

    if (torStatus.status === 'crawling') {
      const peerCount = torStatus.totalPeers || 0;
      const successCount = torStatus.successfulPeers || 0;
      return { 
        text: `Probing Bitcoin seeds via Tor exit nodes (${successCount}/${peerCount} responsive)...`, 
        color: 'bg-acc-purple', 
        pulsing: true 
      };
    }

    if (torStatus.status === 'waiting') {
      const onionCount = torStatus.totalPeers || 0;
      if (onionCount === 0) {
        return { 
          text: 'Idle - waiting for .onion addresses from seed gossip', 
          color: 'bg-orange-500', 
          pulsing: false 
        };
      } else {
        return { 
          text: `Idle - ${onionCount} .onion peer(s) discovered`, 
          color: 'bg-acc-green', 
          pulsing: false 
        };
      }
    }

    return { text: 'Ready', color: 'bg-acc-green', pulsing: false };
  };

  const formatLastSeen = (timestamp: number) => {
    const now = Date.now();
    const diff = now - timestamp;
    const hours = Math.floor(diff / (1000 * 60 * 60));
    const days = Math.floor(hours / 24);
    
    if (days > 0) return `${days}d ago`;
    if (hours > 0) return `${hours}h ago`;
    return 'just now';
  };

  if (!isOpen) return null;

  const currentPeers = activeTab === 'overview' || activeTab === 'seedsChecked' 
    ? peers.all 
    : peers[activeTab as keyof typeof peers];

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 backdrop-blur-sm">
      <div className="bg-bg1 border-2 border-accent rounded-lg shadow-2xl w-full max-w-6xl max-h-[90vh] flex flex-col animate-fade-in">
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b border-subtle">
          <div>
            <h2 className="text-2xl font-bold font-mono text-tx0 uppercase tracking-wider">
              Discovered Bitcoin Peers
            </h2>
            <p className="text-sm text-tx3 font-mono mt-1">
              Background discovery via Bitcoin P2P gossip network
            </p>
          </div>
          <button
            onClick={onClose}
            className="text-tx3 hover:text-tx0 transition-colors p-2"
            aria-label="Close"
          >
            <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Status Lines - Clearnet and Tor */}
        <div className="px-6 py-3 bg-bg2 border-b border-subtle space-y-2">
          {/* Clearnet Status */}
          <div className="flex items-center gap-2">
            <div className={`w-2 h-2 rounded-full ${formatStatusLine().color} ${formatStatusLine().pulsing ? 'animate-pulse' : ''}`}></div>
            <span className="text-xs text-tx1 font-mono">
              <span className="text-blue-500 font-bold">CLEARNET:</span> {formatStatusLine().text}
            </span>
          </div>
          
          {/* Tor Status */}
          <div className="flex items-center gap-2">
            <div className={`w-2 h-2 rounded-full ${formatTorStatusLine().color} ${formatTorStatusLine().pulsing ? 'animate-pulse' : ''}`}></div>
            <span className="text-xs text-tx1 font-mono">
              <span className="text-purple-500 font-bold">TOR:</span> {formatTorStatusLine().text}
            </span>
          </div>
        </div>

        {/* Tabs */}
        <div className="flex gap-2 p-6 border-b border-subtle">
          <button
            onClick={() => setActiveTab('overview')}
            className={`px-4 py-2 font-mono text-sm uppercase tracking-wider transition-all ${
              activeTab === 'overview'
                ? 'bg-accent/20 border-accent text-accent border-b-2'
                : 'text-tx3 hover:text-tx0'
            }`}
          >
            Overview
          </button>
          <button
            onClick={() => setActiveTab('libreRelay')}
            className={`px-4 py-2 font-mono text-sm uppercase tracking-wider transition-all ${
              activeTab === 'libreRelay'
                ? 'bg-green/20 border-green text-green border-b-2'
                : 'text-tx3 hover:text-tx0'
            }`}
          >
            Libre Relay ({stats.libreRelay})
          </button>
          <button
            onClick={() => setActiveTab('coreV30Plus')}
            className={`px-4 py-2 font-mono text-sm uppercase tracking-wider transition-all ${
              activeTab === 'coreV30Plus'
                ? 'bg-blue-500/20 border-blue-500 text-blue-500 border-b-2'
                : 'text-tx3 hover:text-tx0'
            }`}
          >
            Core v30+ ({stats.coreV30Plus})
          </button>
          <button
            onClick={() => setActiveTab('live')}
            className={`px-4 py-2 font-mono text-sm uppercase tracking-wider transition-all ${
              activeTab === 'live'
                ? 'bg-amber/20 border-amber text-amber border-b-2'
                : 'text-tx3 hover:text-tx0'
            }`}
          >
            Live Peers ({stats.live})
          </button>
          <button
            onClick={() => setActiveTab('inactive')}
            className={`px-4 py-2 font-mono text-sm uppercase tracking-wider transition-all ${
              activeTab === 'inactive'
                ? 'bg-tx3/20 border-tx3 text-tx3 border-b-2'
                : 'text-tx3 hover:text-tx0'
            }`}
          >
            Inactive Peers ({stats.inactive})
          </button>
          <button
            onClick={() => setActiveTab('seedsChecked')}
            className={`px-4 py-2 font-mono text-sm uppercase tracking-wider transition-all ${
              activeTab === 'seedsChecked'
                ? 'bg-purple-500/20 border-purple-500 text-purple-500 border-b-2'
                : 'text-tx3 hover:text-tx0'
            }`}
          >
            Seeds Checked ({seedChecks.length})
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-auto p-6">
          {activeTab === 'overview' ? (
            /* Overview Tab - Circle Graphs */
            <div className="grid grid-cols-2 gap-6">
              {/* Connection Status Circle */}
              <div className="bg-bg2 rounded-lg p-4 border border-subtle">
                <h3 className="text-sm text-tx3 uppercase font-mono mb-4 text-center">Connection Status</h3>
                <div className="flex flex-col items-center">
                  <svg viewBox="0 0 200 200" className="w-48 h-48">
                    {(() => {
                      const total = stats.liveClearnet + stats.inactiveClearnet + stats.liveTor + stats.inactiveTor;
                      if (total === 0) {
                        return (
                          <circle cx="100" cy="100" r="80" fill="none" stroke="#374151" strokeWidth="40" />
                        );
                      }
                      
                      let currentAngle = -90; // Start at top
                      const segments = [
                        { value: stats.liveClearnet, color: '#22c55e', label: 'Live Clearnet' },
                        { value: stats.inactiveClearnet, color: '#6b7280', label: 'Inactive Clearnet' },
                        { value: stats.liveTor, color: '#a855f7', label: 'Live Tor' },
                        { value: stats.inactiveTor, color: '#4b5563', label: 'Inactive Tor' },
                      ];
                      
                      return segments.map((seg, i) => {
                        if (seg.value === 0) return null;
                        const angle = (seg.value / total) * 360;
                        
                        // Handle 100% case (full circle) - use a circle element instead of path
                        if (angle >= 359.9) {
                          return (
                            <circle
                              key={i}
                              cx="100"
                              cy="100"
                              r="80"
                              fill={seg.color}
                              opacity="0.9"
                            />
                          );
                        }
                        
                        const startAngle = currentAngle;
                        const endAngle = currentAngle + angle;
                        currentAngle = endAngle;
                        
                        const startRad = (startAngle * Math.PI) / 180;
                        const endRad = (endAngle * Math.PI) / 180;
                        const largeArc = angle > 180 ? 1 : 0;
                        
                        const x1 = 100 + 80 * Math.cos(startRad);
                        const y1 = 100 + 80 * Math.sin(startRad);
                        const x2 = 100 + 80 * Math.cos(endRad);
                        const y2 = 100 + 80 * Math.sin(endRad);
                        
                        return (
                          <path
                            key={i}
                            d={`M 100 100 L ${x1} ${y1} A 80 80 0 ${largeArc} 1 ${x2} ${y2} Z`}
                            fill={seg.color}
                            opacity="0.9"
                          />
                        );
                      });
                    })()}
                    {/* Center label background */}
                    <circle cx="100" cy="100" r="45" fill="#0a0a0a" opacity="0.95" />
                    <text x="100" y="95" textAnchor="middle" className="fill-tx0 text-2xl font-bold font-mono">
                      {stats.liveClearnet + stats.inactiveClearnet + stats.liveTor + stats.inactiveTor}
                    </text>
                    <text x="100" y="115" textAnchor="middle" fill="#ff6b35" className="text-xs font-mono uppercase font-bold">
                      TOTAL
                    </text>
                  </svg>
                  <div className="mt-4 space-y-2 w-full">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full" style={{ backgroundColor: '#22c55e' }}></div>
                        <span className="text-xs text-tx1 font-mono">Live Clearnet</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.liveClearnet}</span>
                    </div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full bg-gray-500"></div>
                        <span className="text-xs text-tx1 font-mono">Inactive Clearnet</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.inactiveClearnet}</span>
                    </div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full" style={{ backgroundColor: '#a855f7' }}></div>
                        <span className="text-xs text-tx1 font-mono">Live Tor</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.liveTor}</span>
                    </div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full bg-gray-600"></div>
                        <span className="text-xs text-tx1 font-mono">Inactive Tor</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.inactiveTor}</span>
                    </div>
                  </div>
                </div>
              </div>

              {/* Node Type Circle */}
              <div className="bg-bg2 rounded-lg p-4 border border-subtle">
                <h3 className="text-sm text-tx3 uppercase font-mono mb-4 text-center">Node Types</h3>
                <div className="flex flex-col items-center">
                  <svg viewBox="0 0 200 200" className="w-48 h-48">
                    {(() => {
                      const total = stats.libreRelay + stats.knots + stats.oldCore + stats.coreV30Plus + stats.other;
                      if (total === 0) {
                        return (
                          <circle cx="100" cy="100" r="80" fill="none" stroke="#374151" strokeWidth="40" />
                        );
                      }
                      
                      let currentAngle = -90; // Start at top
                      const segments = [
                        { value: stats.libreRelay, color: '#22c55e', label: 'LR/GM' },
                        { value: stats.knots, color: '#f59e0b', label: 'Knots' },
                        { value: stats.oldCore, color: '#6b7280', label: 'Old Core' },
                        { value: stats.coreV30Plus, color: '#3b82f6', label: 'Core v30+' },
                        { value: stats.other, color: '#9ca3af', label: 'Other' },
                      ];
                      
                      return segments.map((seg, i) => {
                        if (seg.value === 0) return null;
                        const angle = (seg.value / total) * 360;
                        
                        // Handle 100% case (full circle) - use a circle element instead of path
                        if (angle >= 359.9) {
                          return (
                            <circle
                              key={i}
                              cx="100"
                              cy="100"
                              r="80"
                              fill={seg.color}
                              opacity="0.9"
                            />
                          );
                        }
                        
                        const startAngle = currentAngle;
                        const endAngle = currentAngle + angle;
                        currentAngle = endAngle;
                        
                        const startRad = (startAngle * Math.PI) / 180;
                        const endRad = (endAngle * Math.PI) / 180;
                        const largeArc = angle > 180 ? 1 : 0;
                        
                        const x1 = 100 + 80 * Math.cos(startRad);
                        const y1 = 100 + 80 * Math.sin(startRad);
                        const x2 = 100 + 80 * Math.cos(endRad);
                        const y2 = 100 + 80 * Math.sin(endRad);
                        
                        return (
                          <path
                            key={i}
                            d={`M 100 100 L ${x1} ${y1} A 80 80 0 ${largeArc} 1 ${x2} ${y2} Z`}
                            fill={seg.color}
                            opacity="0.9"
                          />
                        );
                      });
                    })()}
                    {/* Center label background */}
                    <circle cx="100" cy="100" r="45" fill="#0a0a0a" opacity="0.95" />
                    <text x="100" y="95" textAnchor="middle" className="fill-tx0 text-2xl font-bold font-mono">
                      {stats.libreRelay + stats.knots + stats.oldCore + stats.coreV30Plus + stats.other}
                    </text>
                    <text x="100" y="115" textAnchor="middle" fill="#ff6b35" className="text-xs font-mono uppercase font-bold">
                      TOTAL
                    </text>
                  </svg>
                  <div className="mt-4 space-y-2 w-full">
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full" style={{ backgroundColor: '#22c55e' }}></div>
                        <span className="text-xs text-tx1 font-mono">LR/GM</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.libreRelay}</span>
                    </div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full" style={{ backgroundColor: '#f59e0b' }}></div>
                        <span className="text-xs text-tx1 font-mono">Knots</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.knots}</span>
                    </div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full bg-gray-500"></div>
                        <span className="text-xs text-tx1 font-mono">Old Core</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.oldCore}</span>
                    </div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full" style={{ backgroundColor: '#3b82f6' }}></div>
                        <span className="text-xs text-tx1 font-mono">Core v30+</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.coreV30Plus}</span>
                    </div>
                    <div className="flex items-center justify-between">
                      <div className="flex items-center gap-2">
                        <div className="w-3 h-3 rounded-full bg-gray-400"></div>
                        <span className="text-xs text-tx1 font-mono">Other</span>
                      </div>
                      <span className="text-xs text-tx0 font-mono font-bold">{stats.other}</span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          ) : activeTab === 'seedsChecked' ? (
            /* Seeds Checked Tab */
            <>
          {loading ? (
            <div className="text-center py-12">
              <div className="animate-pulse-glow text-accent text-xl font-mono">
                Loading seed checks...
              </div>
            </div>
          ) : seedChecks.length === 0 ? (
            <div className="text-center py-12 text-tx3 font-mono">
              No seeds checked yet. Peer discovery will check seeds soon...
            </div>
          ) : (
            <>
              {/* Summary header */}
              <div className="mb-3 p-3 bg-bg2 border border-tx4/30 rounded">
                <div className="flex items-center justify-between text-xs text-tx3 font-mono">
                  <span>
                    Showing {seedChecks.length} most recent checks
                  </span>
                  <span>
                    {seedChecks.filter(c => c.success).length} successful, {seedChecks.filter(c => !c.success).length} failed
                  </span>
                </div>
              </div>
              
              {/* Scrollable list with max height */}
              <div className="space-y-2 max-h-[600px] overflow-y-auto pr-2">
                {seedChecks.map((check: SeedCheckResult) => (
                  <div
                    key={`${check.host}:${check.port}-${check.timestamp}`}
                    className={`bg-bg2 border rounded p-4 transition-colors ${
                      check.success 
                        ? 'border-green hover:border-green/80' 
                        : 'border-red-500 hover:border-red-500/80'
                    }`}
                  >
                    <div className="flex items-start justify-between">
                      <div className="flex-1">
                        <div className="flex items-center gap-3 mb-2">
                          <span className="font-mono text-tx0 font-semibold">
                            {check.host}:{check.port}
                          </span>
                          <span className={`badge text-xs ${
                            check.success 
                              ? 'bg-green/20 border-green text-green' 
                              : 'bg-red-500/20 border-red-500 text-red-500'
                          }`}>
                            {check.success ? '✓ Connected' : '✗ Failed'}
                          </span>
                          {check.peersReturned > 0 && (
                            <span className="badge text-xs bg-blue-500/20 border-blue-500 text-blue-500">
                              {check.peersReturned} peers
                            </span>
                          )}
                        </div>
                        {check.userAgent && (
                          <p className="text-xs text-tx3 font-mono mb-1">
                            {check.userAgent}
                          </p>
                        )}
                        {check.error && (
                          <p className="text-xs text-red-500 font-mono mb-1">
                            Error: {check.error}
                          </p>
                        )}
                      </div>
                      <div className="text-right">
                        <div className="text-xs text-tx3 font-mono">
                          {formatLastSeen(check.timestamp)}
                        </div>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </>
          )}
            </>
          ) : (
            /* Peer List Tabs */
            <>
          {loading ? (
            <div className="text-center py-12">
              <div className="animate-pulse-glow text-accent text-xl font-mono">
                Loading peers...
              </div>
            </div>
          ) : currentPeers.length === 0 ? (
            <div className="text-center py-12 text-tx3 font-mono">
              No peers discovered yet. Discovery service is querying DNS seeds...
            </div>
          ) : (
            <>
              {/* Peer count summary */}
              {currentPeers.length > 100 && (
                <div className="mb-3 p-3 bg-bg2 border border-tx4/30 rounded">
                  <div className="text-xs text-tx3 font-mono text-center">
                    Showing {currentPeers.length} peers
                  </div>
                </div>
              )}
              
              {/* Scrollable peer list with max height */}
              <div className="space-y-2 max-h-[600px] overflow-y-auto pr-2">
                {currentPeers.map((peer: DiscoveredPeer, _index: number) => {
                  const peerAddress = peer.ip || peer.host || 'unknown';
                  return (
                    <div
                      key={`${peerAddress}:${peer.port}`}
                      className="bg-bg2 border border-subtle rounded p-4 hover:border-accent transition-colors"
                    >
                      <div className="flex items-start justify-between">
                        <div className="flex-1">
                          <div className="flex items-center gap-3 mb-2">
                            <span className="font-mono text-tx0 font-semibold">
                              {peerAddress}:{peer.port}
                            </span>
                            {peer.isLibreRelay && (
                              <span className="badge text-xs bg-green/20 border-green text-green">
                                LR
                              </span>
                            )}
                            {peer.isCoreV30Plus && (
                              <span className="badge text-xs bg-blue-500/20 border-blue-500 text-blue-500">
                                v30+
                              </span>
                            )}
                          </div>
                          <p className="text-xs text-tx3 font-mono mb-1">
                            {peer.userAgent}
                          </p>
                          <div className="flex gap-4 text-xs text-tx3 font-mono">
                            <span>Protocol: {peer.version}</span>
                            <span>Last seen: {formatLastSeen(peer.lastSeen)}</span>
                          </div>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </>
          )}
            </>
          )}
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between p-6 border-t border-subtle">
          <div className="text-xs text-tx3 font-mono">
            Peers expire after 7 days • Auto-refreshes every 5 seconds
          </div>
          <button
            onClick={onClose}
            className="btn-primary text-xs"
          >
            <span className="font-mono">CLOSE</span>
          </button>
        </div>
      </div>
    </div>
  );
}
