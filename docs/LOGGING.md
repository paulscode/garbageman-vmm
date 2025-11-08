# Logging Best Practices
**Garbageman Nodes Manager**

This guide explains the secure logging system implemented to prevent information disclosure while maintaining good debugging capabilities.

---

## Overview

The project uses level-based logging that respects the `LOG_LEVEL` environment variable:

- **DEBUG**: Detailed diagnostic information (hex dumps, protocol details, verbose traces)
- **INFO**: Normal operational messages (service started, instance created, etc.)
- **WARN**: Warnings that don't prevent operation (deprecated features, retries, etc.)
- **ERROR**: Errors that affect functionality (failures, crashes, exceptions)

---

## Usage

### WebUI API (`webui/api/src/lib/logger.ts`)

```typescript
import { createLogger } from '../lib/logger.js';

const logger = createLogger('ServiceName');

// Info level - normal operations
logger.info('Peer discovery started');
logger.info(`Connected to ${peerCount} peers`);

// Debug level - detailed diagnostics
logger.debug('Processing VERSION message', { version, services });

// Protocol dumps (only in DEBUG mode)
logger.protocol('Raw Bitcoin message', bufferData);

// Warnings
logger.warn('Tor proxy unavailable, retrying in 30s');

// Errors
logger.error('Failed to connect to peer', error);
```

### Multi-Daemon Supervisor (`multi-daemon/logger.ts`)

```typescript
import { logger } from './logger';

// Info level
logger.info(`Spawning bitcoind for ${instanceId}`);
logger.info(`Instance ${instanceId} started with PID ${pid}`);

// Debug level (verbose details)
logger.debug(`Binary path: ${binaryPath}`);
logger.debug(`Args: ${args.join(' ')}`);

// Warnings
logger.warn(`Instance ${instanceId} crashed, restarting...`);

// Errors
logger.error(`Failed to spawn instance ${instanceId}`, error);
```

---

## Environment Configuration

### Development (Verbose)
```bash
LOG_LEVEL=debug npm run dev
```

Shows everything including:
- Debug traces
- Protocol hex dumps
- Detailed error stack traces
- Service internals

### Production (Minimal)
```bash
LOG_LEVEL=info npm start
```

Shows only:
- Operational events
- Warnings
- Errors (without stack traces)

### Production (Critical Only)
```bash
LOG_LEVEL=error npm start
```

Shows only:
- Critical errors
- Nothing else

---

## Security Features

### 1. Automatic Redaction
Sensitive keywords are automatically redacted:

```typescript
logger.info('Connecting with password=secret123');
// Output: Connecting with [REDACTED]

logger.debug('Using RPC token=abc123');
// Output: Using RPC [REDACTED]
```

### 2. Conditional Hex Dumps
Protocol data only logged in DEBUG mode:

```typescript
// This only outputs if LOG_LEVEL=debug
logger.protocol('Bitcoin VERSION payload', buffer);

// In production (LOG_LEVEL=info), nothing is logged
```

### 3. Stack Trace Control
Error stack traces only shown in DEBUG mode:

```typescript
// DEBUG mode: Full error object with stack trace
logger.error('Connection failed', new Error('Timeout'));
// Output: [ERROR] Connection failed: Error: Timeout
//     at ... (full stack trace)

// INFO/WARN/ERROR mode: Only error message
logger.error('Connection failed', new Error('Timeout'));
// Output: [ERROR] Connection failed: Timeout
```

---

## Migration Guide

### Before (Console Statements)
```typescript
console.log(`[TorDiscovery] Discovered ${peers.length} peers`);
console.error('[TorDiscovery] Failed to connect:', error);
console.log(`[DEBUG] Raw payload: ${buffer.toString('hex')}`);
```

### After (Secure Logging)
```typescript
import { createLogger } from '../lib/logger.js';
const logger = createLogger('TorDiscovery');

logger.info(`Discovered ${peers.length} peers`);
logger.error('Failed to connect', error);
logger.protocol('Raw payload', buffer);
```

### Benefits
1. ✅ Respects LOG_LEVEL setting
2. ✅ Automatic sensitive data redaction
3. ✅ Consistent formatting across services
4. ✅ Production-safe by default
5. ✅ Debug mode for development

---

## Common Patterns

### Service Initialization
```typescript
const logger = createLogger('PeerDiscovery');

export class PeerDiscoveryService {
  async start() {
    logger.info('Peer discovery service starting...');
    
    try {
      await this.loadSeeds();
      logger.info(`Loaded ${this.seeds.length} seed addresses`);
      
      this.startCrawling();
      logger.info('Discovery cycle started');
    } catch (err) {
      logger.error('Failed to start service', err);
      throw err;
    }
  }
}
```

### Request Processing
```typescript
fastify.post('/api/instances', async (request, reply) => {
  fastify.log.info(`Creating instance: ${request.body.instanceId}`);
  
  try {
    // ... processing
    fastify.log.info(`Instance ${instanceId} created successfully`);
    return reply.send({ success: true });
  } catch (err) {
    fastify.log.error(`Instance creation failed: ${err.message}`);
    return reply.code(500).send({ error: 'Creation failed' });
  }
});
```

### Network Operations
```typescript
async function connectToPeer(address: string) {
  logger.info(`Connecting to peer: ${address}`);
  
  try {
    const socket = await connectViaProxy(address);
    logger.debug(`Socket connected: ${socket.localPort} -> ${socket.remotePort}`);
    
    const versionMsg = await exchangeVersion(socket);
    logger.protocol('Received VERSION', versionMsg.payload);
    
    return socket;
  } catch (err) {
    logger.warn(`Failed to connect to ${address}`, err);
    return null;
  }
}
```

### Background Services
```typescript
async function discoveryLoop() {
  logger.info('Starting discovery loop');
  
  while (this.running) {
    try {
      logger.debug(`Cycle ${this.cycleCount}: Probing ${queue.length} peers`);
      
      await this.probePeers();
      
      logger.info(`Discovery cycle complete: found ${newPeers} new peers`);
    } catch (err) {
      logger.error('Error in discovery cycle', err);
    }
    
    await sleep(CYCLE_INTERVAL);
  }
  
  logger.info('Discovery loop stopped');
}
```

---

## Docker Compose Configuration

```yaml
services:
  webui-api:
    environment:
      LOG_LEVEL: info  # Production: info or warn
      # LOG_LEVEL: debug  # Development: debug
```

```yaml
services:
  multi-daemon:
    environment:
      LOG_LEVEL: info  # Production
      # LOG_LEVEL: debug  # Development
```

---

## Performance Considerations

### Lazy Evaluation
Expensive operations only run if log level allows:

```typescript
// ❌ Bad: Always formats even if not logged
logger.debug(`Peers: ${JSON.stringify(allPeers, null, 2)}`);

// ✅ Good: Check level first
if (shouldLog('debug')) {
  logger.debug(`Peers: ${JSON.stringify(allPeers, null, 2)}`);
}
```

### String Interpolation
Use simple string interpolation for cheap operations:

```typescript
// ✅ OK: Simple variables
logger.info(`Instance ${id} started with ${peers} peers`);

// ❌ Avoid: Complex computations
logger.debug(`Stats: ${calculateComplexStats()}`);

// ✅ Better: Check level first
if (shouldLog('debug')) {
  const stats = calculateComplexStats();
  logger.debug(`Stats: ${stats}`);
}
```

---

## Anti-Patterns

### ❌ Don't Log Sensitive Data
```typescript
// BAD - exposes credentials
logger.info(`Connecting with username=${user} password=${pass}`);

// GOOD - omit sensitive fields
logger.info(`Connecting to RPC as user: ${user}`);
```

### ❌ Don't Log in Tight Loops
```typescript
// BAD - floods logs
for (const peer of peers) {
  logger.debug(`Processing peer ${peer.id}`);
  await processPeer(peer);
}

// GOOD - log summary
logger.debug(`Processing ${peers.length} peers`);
const results = await Promise.all(peers.map(processPeer));
logger.info(`Processed ${results.length} peers successfully`);
```

### ❌ Don't Use console.log Directly
```typescript
// BAD - always outputs
console.log('Debug info');

// GOOD - respects log level
logger.debug('Debug info');
```

---

## Testing

### Verify Log Levels Work
```bash
# Should show debug output
LOG_LEVEL=debug npm run dev | grep DEBUG

# Should NOT show debug output
LOG_LEVEL=info npm run dev | grep DEBUG
```

### Verify Redaction Works
```bash
# Check logs don't contain sensitive patterns
docker logs gm-webui-api 2>&1 | grep -i "password=" 
# Should return nothing or [REDACTED]
```

---

## Summary

✅ **DO:**
- Use appropriate log levels (debug, info, warn, error)
- Create service-specific loggers with `createLogger('ServiceName')`
- Use `logger.protocol()` for hex dumps and raw data
- Set `LOG_LEVEL=info` in production
- Set `LOG_LEVEL=debug` in development

❌ **DON'T:**
- Use console.log/console.error directly
- Log sensitive data (passwords, tokens, keys)
- Log in tight loops without checking level
- Leave DEBUG-level logs in production

**Remember:** Logs are your friend in development but can be a security risk in production. Use the logging system properly to get the best of both worlds!
