import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

/**
 * Utility to merge Tailwind classes with proper precedence
 * Used extensively by shadcn/ui components
 */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/**
 * Format uptime (seconds) to human-readable string
 * @param seconds Uptime in seconds
 * @returns Formatted string like "4d 2h 15m"
 */
export function formatUptime(seconds: number): string {
  if (seconds === 0) return '0s';
  
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  
  const parts: string[] = [];
  if (days > 0) parts.push(`${days}d`);
  if (hours > 0) parts.push(`${hours}h`);
  if (minutes > 0 || parts.length === 0) parts.push(`${minutes}m`);
  
  return parts.join(' ');
}

/**
 * Format bytes to human-readable size
 * @param gb Gigabytes
 * @returns Formatted string like "150.3 GB"
 */
export function formatDiskSize(gb: number): string {
  if (gb < 1) {
    return `${(gb * 1024).toFixed(1)} MB`;
  }
  if (gb < 1000) {
    return `${gb.toFixed(1)} GB`;
  }
  return `${(gb / 1024).toFixed(2)} TB`;
}

/**
 * Format progress percentage
 * @param progress 0.0 to 1.0
 * @returns Formatted string like "99.7%"
 */
export function formatProgress(progress: number): string {
  return `${(progress * 100).toFixed(1)}%`;
}

/**
 * Get state color class for status indicators
 */
export function getStateColor(state: string): string {
  switch (state) {
    case 'up':
      return 'status-up';
    case 'exited':
      return 'status-exited';
    case 'starting':
    case 'stopping':
      return 'status-warning';
    default:
      return 'status-error';
  }
}

/**
 * Get glow intensity class based on instance state
 */
export function getGlowIntensity(state: string): string {
  switch (state) {
    case 'up':
      return 'glow-green-2';
    case 'starting':
    case 'stopping':
      return 'glow-amber-1';
    default:
      return 'glow-0';
  }
}
