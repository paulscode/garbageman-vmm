/**
 * Secure Logging Utility
 * =======================
 * Wraps console logging with security controls:
 * - Respects LOG_LEVEL environment variable
 * - Redacts sensitive data patterns (password, token, key)
 * - Prevents information disclosure in production
 * - Protocol dumps only enabled in DEBUG mode
 * 
 * Usage:
 *   import { createLogger } from '../lib/logger.js';
 *   const logger = createLogger('ServiceName');
 *   
 *   logger.info('Service started');
 *   logger.debug('Detailed diagnostics');
 *   logger.protocol('Raw Bitcoin message', buffer);
 *   logger.error('Operation failed', error);
 * 
 * Environment:
 *   LOG_LEVEL=debug  - Show all logs including protocol dumps
 *   LOG_LEVEL=info   - Normal operational logs (default, production)
 *   LOG_LEVEL=warn   - Warnings and errors only
 *   LOG_LEVEL=error  - Errors only
 */

type LogLevel = 'debug' | 'info' | 'warn' | 'error';

const LOG_LEVEL = (process.env.LOG_LEVEL || 'info') as LogLevel;

const LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

/**
 * Check if a log level should be output based on current LOG_LEVEL
 */
function shouldLog(level: LogLevel): boolean {
  return LEVELS[level] >= LEVELS[LOG_LEVEL];
}

/**
 * Redact sensitive data from log output
 */
function redact(data: any): any {
  if (typeof data === 'string') {
    // Redact potential passwords, tokens, keys
    if (data.toLowerCase().includes('password') || 
        data.toLowerCase().includes('token') ||
        data.toLowerCase().includes('key=')) {
      return '[REDACTED]';
    }
  }
  return data;
}

/**
 * Log at DEBUG level (only in development/debug mode)
 * Should be used for detailed diagnostic information including protocol dumps
 */
export function debug(message: string, ...args: any[]): void {
  if (shouldLog('debug')) {
    console.log(`[DEBUG] ${message}`, ...args.map(redact));
  }
}

/**
 * Log at INFO level (normal operational messages)
 */
export function info(message: string, ...args: any[]): void {
  if (shouldLog('info')) {
    console.log(`[INFO] ${message}`, ...args.map(redact));
  }
}

/**
 * Log at WARN level (warnings that don't prevent operation)
 */
export function warn(message: string, ...args: any[]): void {
  if (shouldLog('warn')) {
    console.warn(`[WARN] ${message}`, ...args.map(redact));
  }
}

/**
 * Log at ERROR level (errors that affect functionality)
 * Does NOT include stack traces or detailed error info in production
 */
export function error(message: string, err?: Error | any): void {
  if (shouldLog('error')) {
    if (LOG_LEVEL === 'debug' && err) {
      // Only show full error details in debug mode
      console.error(`[ERROR] ${message}`, err);
    } else if (err instanceof Error) {
      // In production, only show error message, not stack trace
      console.error(`[ERROR] ${message}: ${err.message}`);
    } else {
      console.error(`[ERROR] ${message}`);
    }
  }
}

/**
 * Log protocol data (hex dumps, raw payloads)
 * Only enabled in DEBUG mode to prevent information disclosure
 */
export function protocol(message: string, data: Buffer | string): void {
  if (shouldLog('debug')) {
    const hexPreview = Buffer.isBuffer(data) 
      ? data.toString('hex').substring(0, 200) + (data.length > 100 ? '...' : '')
      : String(data).substring(0, 200);
    console.log(`[PROTOCOL] ${message}: ${hexPreview}`);
  }
}

/**
 * Log with custom prefix (for service-specific logging)
 */
export function createLogger(prefix: string) {
  return {
    debug: (msg: string, ...args: any[]) => debug(`[${prefix}] ${msg}`, ...args),
    info: (msg: string, ...args: any[]) => info(`[${prefix}] ${msg}`, ...args),
    warn: (msg: string, ...args: any[]) => warn(`[${prefix}] ${msg}`, ...args),
    error: (msg: string, err?: any) => error(`[${prefix}] ${msg}`, err),
    protocol: (msg: string, data: Buffer | string) => protocol(`[${prefix}] ${msg}`, data),
  };
}
