/**
 * NodeCard Component
 * ===================
 * Display card for a single daemon instance.
 * Shows config, status, and action buttons.
 * 
 * Features:
 *  - State indicator with glow effect
 *  - Key metrics (peers, blocks, progress, uptime)
 *  - KPI tags (pruned, tor-only, network type)
 *  - Copy-to-clipboard for RPC, P2P, and onion addresses
 *  - Action buttons (start/stop/restart/delete)
 *  - Responsive layout with hover effects
 */

'use client';

import { useState } from 'react';
import { cn, formatUptime, formatDiskSize, formatProgress, getStateColor, getGlowIntensity } from '@/lib/utils';
import type { InstanceDetail } from '@/lib/stubs';
import { RadioactiveBadge } from './RadioactiveBadge';

interface NodeCardProps {
  instance: InstanceDetail;
  onStart?: (id: string) => void;
  onStop?: (id: string) => void;
  onDelete?: (id: string) => void;
  className?: string;
}

export function NodeCard({
  instance,
  onStart,
  onStop,
  onDelete,
  className,
}: NodeCardProps) {
  const { config, status } = instance;
  const isRunning = status.state === 'up';
  const isSynced = status.progress >= 1.0;
  const [copiedField, setCopiedField] = useState<string | null>(null);

  const handleCopy = async (text: string, field: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopiedField(field);
      setTimeout(() => setCopiedField(null), 1500);
    } catch (err) {
      console.error('Failed to copy:', err);
    }
  };
  
  return (
    <div
      className={cn(
        'card hover:border-bright transition-all animate-scan-in',
        'scanlines noise-texture',
        getGlowIntensity(status.state),
        className
      )}
    >
      {/* Header: ID + State */}
      <div className="flex items-start justify-between mb-4">
        <div className="flex items-center gap-2">
          {isRunning && <RadioactiveBadge intensity={isSynced ? 2 : 1} size="sm" />}
          <div>
            <h3 className="text-lg font-bold font-mono text-tx0">
              {config.INSTANCE_ID}
            </h3>
            <p className="text-xs text-tx3 uppercase font-mono">
              {status.impl} • {status.network}
            </p>
          </div>
        </div>
        
        <div className={cn('px-2 py-1 rounded text-xs font-mono font-semibold uppercase', getStateColor(status.state))}>
          {status.state}
        </div>
      </div>
      
      {/* Metrics Grid */}
      <div className="grid grid-cols-2 gap-4 mb-4">
        <div className="col-span-2">
          <p className="text-xs text-tx3 uppercase font-mono mb-1">Peers</p>
          <p className="text-xl font-bold font-mono text-tx0 mb-1">{status.peers}</p>
          {status.peerBreakdown && status.peers > 0 && (
            <div className="text-[10px] font-mono text-tx2 leading-tight">
              <span className="text-acc-orange">{status.peerBreakdown.libreRelay}</span> LR/GM {' '}
              <span className="text-acc-amber">{status.peerBreakdown.knots}</span> KNOTS {' '}
              <span className="text-tx2">{status.peerBreakdown.oldCore}</span> OLDCORE {' '}
              <span className="text-acc-green">{status.peerBreakdown.newCore}</span> COREv30+ {' '}
              <span className="text-tx3">{status.peerBreakdown.other}</span> OTHER
            </div>
          )}
        </div>
        
        <div>
          <p className="text-xs text-tx3 uppercase font-mono">Progress</p>
          <p className="text-xl font-bold font-mono text-tx0">
            {formatProgress(status.progress)}
          </p>
        </div>
        
        <div>
          <p className="text-xs text-tx3 uppercase font-mono">Blocks</p>
          <p className="text-lg font-mono text-tx0">
            {status.blocks.toLocaleString()} / {status.headers.toLocaleString()}
          </p>
        </div>
        
        <div>
          <p className="text-xs text-tx3 uppercase font-mono">Uptime</p>
          <p className="text-lg font-mono text-tx0">
            {formatUptime(status.uptime)}
          </p>
        </div>
      </div>
      
      {/* Disk Usage */}
      <div className="mb-4 p-3 rounded bg-bg2 border border-subtle">
        <div className="text-xs">
          <p className="text-tx3 uppercase font-mono">Disk Usage</p>
          <p className="text-tx0 font-mono font-semibold text-lg">{formatDiskSize(status.diskGb)}</p>
        </div>
      </div>
      
      {/* Ports */}
      <div className="mb-4 space-y-1 text-xs font-mono">
        <div className="flex justify-between items-center group">
          <span className="text-tx3">RPC:</span>
          <div className="flex items-center gap-2">
            <span className="text-tx0">localhost:{status.rpcPort}</span>
            <button
              onClick={() => handleCopy(`localhost:${status.rpcPort}`, 'rpc')}
              className="opacity-40 hover:opacity-100 transition-opacity"
              title="Copy to clipboard"
            >
              {copiedField === 'rpc' ? (
                <span className="text-acc-orange">✓</span>
              ) : (
                <svg className="w-3 h-3 text-tx0" fill="none" viewBox="0 0 16 16" stroke="currentColor" strokeWidth="2">
                  <rect x="5" y="5" width="9" height="9" rx="1" />
                  <path d="M3 11V3a2 2 0 0 1 2-2h8" />
                </svg>
              )}
            </button>
          </div>
        </div>
        <div className="flex justify-between items-center group">
          <span className="text-tx3">P2P:</span>
          <div className="flex items-center gap-2">
            <span className="text-tx0">:{status.p2pPort}</span>
            <button
              onClick={() => handleCopy(`:${status.p2pPort}`, 'p2p')}
              className="opacity-40 hover:opacity-100 transition-opacity"
              title="Copy to clipboard"
            >
              {copiedField === 'p2p' ? (
                <span className="text-acc-orange">✓</span>
              ) : (
                <svg className="w-3 h-3 text-tx0" fill="none" viewBox="0 0 16 16" stroke="currentColor" strokeWidth="2">
                  <rect x="5" y="5" width="9" height="9" rx="1" />
                  <path d="M3 11V3a2 2 0 0 1 2-2h8" />
                </svg>
              )}
            </button>
          </div>
        </div>
        {status.onion && (
          <div className="flex justify-between items-center group">
            <span className="text-tx3">Onion:</span>
            <div className="flex items-center gap-2 justify-end flex-1 min-w-0">
              <span className="text-tx0 truncate" title={status.onion}>
                {status.onion}
              </span>
              <button
                onClick={() => handleCopy(status.onion!, 'onion')}
                className="opacity-40 hover:opacity-100 transition-opacity flex-shrink-0"
                title="Copy full address to clipboard"
              >
                {copiedField === 'onion' ? (
                  <span className="text-acc-orange">✓</span>
                ) : (
                  <svg className="w-3 h-3 text-tx0" fill="none" viewBox="0 0 16 16" stroke="currentColor" strokeWidth="2">
                    <rect x="5" y="5" width="9" height="9" rx="1" />
                    <path d="M3 11V3a2 2 0 0 1 2-2h8" />
                  </svg>
                )}
              </button>
            </div>
          </div>
        )}
      </div>
      
      {/* KPI Tags */}
      <div className="flex flex-wrap gap-2 mb-4">
        {status.version && (
          <span className="badge text-xs bg-acc-green/20 border-acc-green text-acc-green">
            v{status.version}
          </span>
        )}
        {status.kpiTags.map((tag) => (
          <span
            key={tag}
            className="badge text-xs"
          >
            {tag}
          </span>
        ))}
      </div>
      
      {/* Initial Block Download / Sync Indicator */}
      {(() => {
        // Hide if node is effectively synced (blocks == headers and progress near 100%)
        const isFullySynced = status.blocks > 0 && status.blocks === status.headers && status.progress >= 0.999;
        // Show if: (IBD active OR starting up with 0/0) AND not fully synced
        return !isFullySynced && (status.initialBlockDownload || (status.state === 'up' && status.blocks === 0 && status.headers === 0));
      })() && (
        <div className="mb-4 p-3 rounded bg-acc-blue/10 border border-acc-blue">
          <div className="flex items-center gap-2 mb-2">
            <div className="animate-spin h-4 w-4">
              <svg viewBox="0 0 24 24" fill="none" className="text-acc-blue">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
              </svg>
            </div>
            <span className="text-sm font-semibold text-acc-blue">
              {status.initialBlockDownload === false && status.blocks > 0 
                ? 'Syncing Blockchain' 
                : 'Initial Sync in Progress'}
            </span>
          </div>
          <div className="text-xs text-tx2 mb-2">
            {status.blocks === 0 && status.headers === 0
              ? 'Starting up and downloading block headers...'
              : 'Downloading and validating block headers...'}
          </div>
          <div className="flex items-center gap-2">
            <div className="flex-1 bg-bg2 rounded-full h-2 overflow-hidden">
              <div 
                className="bg-acc-blue h-full transition-all duration-300"
                style={{ width: `${(status.progress * 100).toFixed(1)}%` }}
              />
            </div>
            <span className="text-xs font-mono text-acc-blue font-semibold min-w-[3rem] text-right">
              {(status.progress * 100).toFixed(1)}%
            </span>
          </div>
        </div>
      )}
      
      {/* Actions */}
      <div className="flex gap-2 pt-4 border-t border-subtle">
        {isRunning ? (
          <button
            onClick={() => onStop?.(config.INSTANCE_ID)}
            className="btn flex-1 text-xs"
          >
            <span className="font-mono">STOP</span>
          </button>
        ) : (
          <button
            onClick={() => onStart?.(config.INSTANCE_ID)}
            className="btn-primary flex-1 text-xs"
          >
            <span className="font-mono">START</span>
          </button>
        )}
        
        <button
          onClick={() => onDelete?.(config.INSTANCE_ID)}
          className="btn text-xs text-red hover:bg-red hover:text-bg0"
          disabled={isRunning}
        >
          <span className="font-mono">DELETE</span>
        </button>
      </div>
    </div>
  );
}
