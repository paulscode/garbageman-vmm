'use client';

import { API_BASE_URL } from '@/lib/api-config';
/**
 * AlertsRail Component
 * =====================
 * Side panel showing system alerts, warnings, and notifications.
 * War room status feed aesthetic.
 * 
 * Alert types:
 *  - info: General information (blue/neutral)
 *  - warning: Attention needed (amber)
 *  - error: Critical issue (red)
 *  - success: Positive event (green)
 */


import { cn } from '@/lib/utils';
import { useState, useEffect } from 'react';

interface Alert {
  id: number;
  type: 'info' | 'warning' | 'error' | 'success';
  title: string;
  message: string;
  timestamp: number;
  category?: string;
  metadata?: Record<string, unknown>;
}

interface AlertsRailProps {
  className?: string;
  authenticatedFetch: (url: string, options?: RequestInit) => Promise<Response>;
}

// Format timestamp to relative time
function formatRelativeTime(timestamp: number): string {
  const now = Date.now();
  const diff = now - timestamp;
  const seconds = Math.floor(diff / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (seconds < 60) return `${seconds}s ago`;
  if (minutes < 60) return `${minutes}m ago`;
  if (hours < 24) return `${hours}h ago`;
  return `${days}d ago`;
}

export function AlertsRail({ className, authenticatedFetch }: AlertsRailProps) {
  const [alerts, setAlerts] = useState<Alert[]>([]);

  // Fetch events from API
  useEffect(() => {
    const fetchEvents = async () => {
      try {
        const response = await authenticatedFetch(`${API_BASE_URL}/api/events?limit=20`);
        const data = await response.json();
        setAlerts(data.events || []);
      } catch (error) {
        console.error('Failed to fetch events:', error);
      }
    };

    // Initial fetch
    fetchEvents();

    // Poll every 10 seconds
    const interval = setInterval(fetchEvents, 10000);

    return () => clearInterval(interval);
  }, [authenticatedFetch]);
  const getAlertStyles = (type: Alert['type']) => {
    switch (type) {
      case 'success':
        return {
          border: 'border-green/30',
          bg: 'bg-green/5',
          text: 'text-green',
          glow: 'glow-green-1',
        };
      case 'warning':
        return {
          border: 'border-amber/30',
          bg: 'bg-amber/5',
          text: 'text-amber',
          glow: 'glow-amber-1',
        };
      case 'error':
        return {
          border: 'border-red/30',
          bg: 'bg-red/5',
          text: 'text-red',
          glow: 'glow-0',
        };
      default:
        return {
          border: 'border-border',
          bg: 'bg-bg2/50',
          text: 'text-tx1',
          glow: 'glow-0',
        };
    }
  };
  
  return (
    <aside className={cn('space-y-4', className)}>
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-bold font-mono text-tx0 uppercase">
          Status Feed
        </h2>
        <span className="text-xs text-tx3 font-mono uppercase">
          {alerts.length} ALERTS
        </span>
      </div>
      
      <div className="space-y-3">
        {alerts.length === 0 ? (
          <div className="p-4 rounded border border-subtle bg-bg1 text-center">
            <p className="text-sm text-tx3 font-mono">NO ACTIVE ALERTS</p>
          </div>
        ) : (
          alerts.map((alert) => {
            const styles = getAlertStyles(alert.type);
            
            return (
              <div
                key={alert.id}
                className={cn(
                  'p-3 rounded border transition-all',
                  styles.border,
                  styles.bg,
                  styles.glow,
                  'hover:scale-[1.02]'
                )}
              >
                <div className="flex items-start justify-between mb-1">
                  <h3 className={cn('text-xs font-bold font-mono uppercase', styles.text)}>
                    {alert.title}
                  </h3>
                  <span className="text-xs text-tx3 font-mono">
                    {formatRelativeTime(alert.timestamp)}
                  </span>
                </div>
                <p className="text-sm text-tx1 font-mono">
                  {alert.message}
                </p>
              </div>
            );
          })
        )}
      </div>
    </aside>
  );
}
