/**
 * Event System
 * ============
 * In-memory event tracking for the status feed.
 * Tracks important system events with automatic cleanup of old entries.
 */

export interface SystemEvent {
  id: string;
  type: 'info' | 'warning' | 'error' | 'success';
  category: 'instance' | 'artifact' | 'sync' | 'network' | 'system';
  title: string;
  message: string;
  timestamp: number; // Unix timestamp in milliseconds
  metadata?: Record<string, any>; // Optional additional data
}

// In-memory event storage (newest first)
let events: SystemEvent[] = [];
let eventCounter = 0;

const MAX_EVENTS = 100; // Keep last 100 events
const EVENT_TTL = 24 * 60 * 60 * 1000; // 24 hours in milliseconds

/**
 * Add a new event to the feed
 */
export function addEvent(
  type: SystemEvent['type'],
  category: SystemEvent['category'],
  title: string,
  message: string,
  metadata?: Record<string, any>
): SystemEvent {
  const event: SystemEvent = {
    id: `event-${++eventCounter}-${Date.now()}`,
    type,
    category,
    title,
    message,
    timestamp: Date.now(),
    metadata,
  };

  // Add to beginning (newest first)
  events.unshift(event);

  // Trim to max size
  if (events.length > MAX_EVENTS) {
    events = events.slice(0, MAX_EVENTS);
  }

  // Clean up old events
  cleanupOldEvents();

  return event;
}

/**
 * Get all events (newest first)
 */
export function getEvents(limit?: number): SystemEvent[] {
  cleanupOldEvents();
  return limit ? events.slice(0, limit) : [...events];
}

/**
 * Get events by category
 */
export function getEventsByCategory(category: SystemEvent['category'], limit?: number): SystemEvent[] {
  cleanupOldEvents();
  const filtered = events.filter(e => e.category === category);
  return limit ? filtered.slice(0, limit) : filtered;
}

/**
 * Get events by type
 */
export function getEventsByType(type: SystemEvent['type'], limit?: number): SystemEvent[] {
  cleanupOldEvents();
  const filtered = events.filter(e => e.type === type);
  return limit ? filtered.slice(0, limit) : filtered;
}

/**
 * Clear all events
 */
export function clearEvents(): void {
  events = [];
}

/**
 * Remove events older than TTL
 */
function cleanupOldEvents(): void {
  const cutoff = Date.now() - EVENT_TTL;
  events = events.filter(e => e.timestamp > cutoff);
}

/**
 * Helper functions for common event types
 */

export function logInstanceCreated(instanceId: string): void {
  addEvent('success', 'instance', 'INSTANCE CREATED', `${instanceId} has been created`, { instanceId });
}

export function logInstanceStarted(instanceId: string): void {
  addEvent('success', 'instance', 'INSTANCE STARTED', `${instanceId} is now running`, { instanceId });
}

export function logInstanceStopped(instanceId: string): void {
  addEvent('info', 'instance', 'INSTANCE STOPPED', `${instanceId} has been stopped`, { instanceId });
}

export function logInstanceDeleted(instanceId: string): void {
  addEvent('warning', 'instance', 'INSTANCE DELETED', `${instanceId} has been removed`, { instanceId });
}

export function logArtifactImported(tag: string, hasBlockchain: boolean): void {
  const message = hasBlockchain 
    ? `${tag} imported with blockchain data` 
    : `${tag} imported successfully`;
  addEvent('success', 'artifact', 'ARTIFACT IMPORTED', message, { tag, hasBlockchain });
}

export function logArtifactDeleted(tag: string): void {
  addEvent('info', 'artifact', 'ARTIFACT DELETED', `${tag} has been removed`, { tag });
}

export function logSyncProgress(instanceId: string, progress: number): void {
  if (progress >= 100) {
    addEvent('success', 'sync', 'SYNC COMPLETE', `${instanceId} reached 100% sync`, { instanceId, progress });
  } else if (progress >= 75) {
    addEvent('info', 'sync', 'SYNC PROGRESS', `${instanceId} is at ${progress.toFixed(1)}% sync`, { instanceId, progress });
  }
}

export function logLowPeers(instanceId: string, peerCount: number): void {
  addEvent('warning', 'network', 'LOW PEERS', `${instanceId} has only ${peerCount} peer${peerCount === 1 ? '' : 's'} connected`, { instanceId, peerCount });
}

export function logConnectionIssue(instanceId: string, error: string): void {
  addEvent('error', 'network', 'CONNECTION ISSUE', `${instanceId}: ${error}`, { instanceId, error });
}

export function logSystemError(title: string, message: string, error?: any): void {
  addEvent('error', 'system', title, message, { error: error?.message || error });
}
