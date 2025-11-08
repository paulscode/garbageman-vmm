/**
 * CommandBar Component
 * =====================
 * Top-level control bar with global actions and status.
 * War room command center aesthetic.
 * 
 * Features:
 *  - Logo/branding with radioactive symbol
 *  - Global health indicator
 *  - Primary action buttons (create instance, import artifact)
 *  - Settings/help dropdown
 */

'use client';

import { RadioactiveBadge } from './RadioactiveBadge';
import { cn } from '@/lib/utils';

interface CommandBarProps {
  onCreateInstance?: () => void;
  onImportArtifact?: () => void;
  onViewPeers?: () => void;
  health?: 'ok' | 'degraded' | 'error';
}

export function CommandBar({
  onCreateInstance,
  onImportArtifact,
  onViewPeers,
  health = 'ok',
}: CommandBarProps) {
  const healthColor = {
    ok: 'status-up',
    degraded: 'status-warning',
    error: 'status-error',
  }[health];
  
  const healthLabel = {
    ok: 'OPERATIONAL',
    degraded: 'DEGRADED',
    error: 'ERROR',
  }[health];
  
  return (
    <header className="sticky top-0 z-50 w-full border-b border-border bg-bg0/95 backdrop-blur-sm">
      <div className="container mx-auto px-4 py-3">
        <div className="flex items-center justify-between">
          {/* Logo / Branding */}
          <div className="flex items-center gap-3">
            <RadioactiveBadge intensity={2} size="md" />
            <div>
              <h1 className="text-xl font-bold text-gradient-orange font-mono">
                GARBAGEMAN
              </h1>
              <p className="text-xs text-tx3 uppercase tracking-wider">
                Nodes Manager
              </p>
            </div>
          </div>
          
          {/* Health Status */}
          <div className="flex items-center gap-2 px-4 py-2 rounded-md bg-bg1 border border-subtle">
            <div className={cn('status-dot w-2 h-2 rounded-full', healthColor, 'animate-pulse-glow')} />
            <span className={cn('text-xs font-mono font-semibold uppercase', healthColor)}>
              {healthLabel}
            </span>
          </div>
          
          {/* Action Buttons */}
          <div className="flex items-center gap-2">
            <button
              onClick={onViewPeers}
              className="btn text-xs"
              aria-label="View discovered peers"
            >
              <span className="font-mono">PEER DISCOVERY</span>
            </button>
            
            <button
              onClick={onImportArtifact}
              className="btn text-xs"
              aria-label="Import daemon artifacts"
            >
              <span className="font-mono">IMPORT ARTIFACT</span>
            </button>
            
            <button
              onClick={onCreateInstance}
              className="btn-primary text-xs shadow-glow-2"
              aria-label="Create new daemon instance"
            >
              <span className="font-mono">+ NEW INSTANCE</span>
            </button>
          </div>
        </div>
      </div>
    </header>
  );
}
