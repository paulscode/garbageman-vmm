/// <reference types="node" />

/**
 * Simple Logger for Multi-Daemon Supervisor
 * ==========================================
 * Provides level-based logging to reduce verbosity in production.
 * 
 * Usage:
 *   import { logger } from './logger';
 *   logger.info('Instance started');
 *   logger.debug('Detailed diagnostics');
 *   logger.error('Operation failed', err);
 * 
 * Environment:
 *   LOG_LEVEL=debug  - Show all logs including debug
 *   LOG_LEVEL=info   - Normal operational logs (default)
 *   LOG_LEVEL=warn   - Warnings and errors only
 *   LOG_LEVEL=error  - Errors only
 * 
 * Security:
 *   - Stack traces only shown in DEBUG mode
 *   - Production deployments should use LOG_LEVEL=info or higher
 */

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LOG_LEVEL = (process.env.LOG_LEVEL || 'info') as LogLevel;

const LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

function shouldLog(level: LogLevel): boolean {
  return LEVELS[level] >= LEVELS[LOG_LEVEL];
}

export const logger = {
  debug(message: string, ...args: any[]): void {
    if (shouldLog('debug')) {
      console.log(`[DEBUG] ${message}`, ...args);
    }
  },

  info(message: string, ...args: any[]): void {
    if (shouldLog('info')) {
      console.log(`[INFO] ${message}`, ...args);
    }
  },

  warn(message: string, ...args: any[]): void {
    if (shouldLog('warn')) {
      console.warn(`[WARN] ${message}`, ...args);
    }
  },

  error(message: string, err?: any): void {
    if (shouldLog('error')) {
      if (err instanceof Error) {
        console.error(`[ERROR] ${message}:`, LOG_LEVEL === 'debug' ? err : err.message);
      } else {
        console.error(`[ERROR] ${message}`, err);
      }
    }
  },
};
