/**
 * StatusBoard Component
 * ======================
 * Dashboard summary showing aggregate KPIs across all instances.
 * War room mission control display.
 * 
 * Displays:
 *  - Total instances (running / total)
 *  - Total peers
 *  - Total disk usage
 *  - Resource utilization (CPU/RAM)
 *  - Network breakdown (clearnet vs tor-only)
 */

'use client';

import { cn, formatDiskSize } from '@/lib/utils';
import type { InstanceDetail } from '@/lib/stubs';

interface StatusBoardProps {
  instances: InstanceDetail[];
  className?: string;
}

export function StatusBoard({ instances, className }: StatusBoardProps) {
  // Aggregate metrics
  const totalInstances = instances.length;
  const runningInstances = instances.filter((i) => i.status.state === 'up').length;
  const totalPeers = instances.reduce((sum, i) => sum + i.status.peers, 0);
  const totalDisk = instances.reduce((sum, i) => sum + i.status.diskGb, 0);
  
  const torOnlyCount = instances.filter((i) => 
    i.status.kpiTags.includes('tor-only')
  ).length;
  const clearnetCount = instances.filter((i) => 
    i.status.kpiTags.includes('clearnet')
  ).length;
  
  const metrics = [
    {
      label: 'INSTANCES',
      value: `${runningInstances} / ${totalInstances}`,
      unit: 'ACTIVE',
      color: runningInstances > 0 ? 'status-up' : 'status-exited',
      glow: runningInstances > 0 ? 'glow-green-1' : 'glow-0',
    },
    {
      label: 'PEERS',
      value: totalPeers.toString(),
      unit: 'CONNECTED',
      color: totalPeers > 0 ? 'text-tx0' : 'text-tx3',
      glow: totalPeers > 10 ? 'glow-1' : 'glow-0',
    },
    {
      label: 'STORAGE',
      value: formatDiskSize(totalDisk),
      unit: 'USED',
      color: 'text-tx0',
      glow: 'glow-0',
    },
    {
      label: 'NETWORK',
      value: `${torOnlyCount} TOR / ${clearnetCount} CLEAR`,
      unit: 'SPLIT',
      color: 'text-tx0',
      glow: 'glow-0',
    },
  ];
  
  return (
    <div className={cn('grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4', className)}>
      {metrics.map((metric) => (
        <div
          key={metric.label}
          className={cn(
            'card hover:border-bright transition-all',
            'scanlines noise-texture',
            metric.glow
          )}
        >
          <div className="space-y-2">
            <p className="text-xs text-tx3 uppercase tracking-wider font-mono">
              {metric.label}
            </p>
            <p className={cn('text-2xl font-bold font-mono', metric.color)}>
              {metric.value}
            </p>
            <p className="text-xs text-tx3 uppercase font-mono">
              {metric.unit}
            </p>
          </div>
        </div>
      ))}
    </div>
  );
}
