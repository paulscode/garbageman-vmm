/**
 * Garbageman WebUI - API Server
 * ==============================
 * Fastify-based REST API for managing daemon instances.
 * 
 * Architecture:
 *  - Reads/writes ENV files via envstore module
 *  - Proxies live status from multi-daemon supervisor
 *  - Validates requests with JSON schemas (Ajv)
 *  - Handles errors with appropriate HTTP status codes
 *  - Rate limiting protection (1000 req/min, localhost exempt)
 * 
 * Environment Variables:
 *  - PORT: API server port (default: 8080)
 *  - ENVFILES_DIR: Path to envfiles directory (default: /envfiles)
 *  - SUPERVISOR_URL: Multi-daemon supervisor URL (default: http://multi-daemon:9000)
 *  - LOG_LEVEL: Logging level (default: info, debug for verbose output)
 */

import Fastify from 'fastify';
import cors from '@fastify/cors';
import rateLimit from '@fastify/rate-limit';

// Import route handlers
import healthRoute from './routes/health.js';
import authRoute, { requireAuth } from './routes/auth.js';
import instancesRoute from './routes/instances.js';
import artifactsRoute from './routes/artifacts.js';
import eventsRoute from './routes/events.js';
import peersRoute from './routes/peers.js';
import testDataRoute from './routes/test-data.js';

// Import services
import { peerDiscoveryService } from './services/peer-discovery.js';

// ============================================================================
// Configuration
// ============================================================================

const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = process.env.HOST || '0.0.0.0';
const LOG_LEVEL = (process.env.LOG_LEVEL || 'info') as 'info' | 'debug' | 'error';

// ============================================================================
// Server Initialization
// ============================================================================

// Configure logger (skip pino-pretty in production to avoid dependency issues)
const loggerConfig: any = {
  level: LOG_LEVEL,
};

if (process.env.NODE_ENV === 'development') {
  loggerConfig.transport = {
    target: 'pino-pretty',
    options: {
      colorize: true,
      translateTime: 'HH:MM:ss Z',
      ignore: 'pid,hostname',
    },
  };
}

const fastify = Fastify({
  logger: loggerConfig,
  // Increase body size limit for artifact uploads (multipart handles its own limits)
  bodyLimit: 20 * 1024 * 1024 * 1024, // 20GB to handle large blockchain exports
  // Increase timeouts for long-running operations (artifact imports, blockchain extraction)
  // Set to 2 hours to handle very large file uploads (blockchain exports can be 10GB+)
  connectionTimeout: 7200000, // 2 hours
  requestTimeout: 7200000, // 2 hours
  keepAliveTimeout: 7200000, // 2 hours
});

// Log all incoming requests
fastify.addHook('onRequest', async (request, _reply) => {
  fastify.log.info(`Incoming ${request.method} ${request.url} from ${request.ip}`);
});

// ============================================================================
// Plugins
// ============================================================================

// CORS for local dev (UI on different port)
await fastify.register(cors, {
  origin: true, // Allow all origins in dev; restrict in production
  credentials: true,
});

// Rate limiting (security measure)
await fastify.register(rateLimit, {
  global: true,
  max: 1000, // requests per minute (allows ~16 req/sec for polling UIs)
  timeWindow: '1 minute',
  allowList: ['127.0.0.1', '::1'], // Localhost exempt from rate limiting
  errorResponseBuilder: (request, context) => {
    const error: any = new Error(`Rate limit exceeded. Retry after ${context.after}`);
    error.statusCode = 429;
    return error;
  },
});

// ============================================================================
// Routes
// ============================================================================

// Health check (no auth required)
await fastify.register(healthRoute);

// Authentication (no auth required for login)
await fastify.register(authRoute);

// Protected routes - require authentication
// Create a plugin for protected routes
await fastify.register(async (protectedApp) => {
  // Add auth middleware to all routes in this plugin
  protectedApp.addHook('onRequest', requireAuth(fastify));
  
  // Instance management
  await protectedApp.register(instancesRoute);
  
  // Artifact management
  await protectedApp.register(artifactsRoute);
  
  // Events feed
  await protectedApp.register(eventsRoute);
  
  // Peer discovery
  await protectedApp.register(peersRoute);
  
  // Test data management (development)
  await protectedApp.register(testDataRoute);
});

// ============================================================================
// Services
// ============================================================================

// Start clearnet peer discovery service
peerDiscoveryService.start();
fastify.log.info('Clearnet peer discovery service started');

// Start Tor peer discovery service
import { torPeerDiscoveryService } from './services/tor-peer-discovery.js';
torPeerDiscoveryService.start();
fastify.log.info('Tor peer discovery service started');

// Root endpoint (API info)
fastify.get('/', async (request, reply) => {
  reply.send({
    service: 'garbageman-webui-api',
    version: '0.1.0',
    endpoints: {
      health: 'GET /api/health',
      instances: {
        list: 'GET /api/instances',
        get: 'GET /api/instances/:id',
        create: 'POST /api/instances',
        update: 'PUT /api/instances/:id',
        delete: 'DELETE /api/instances/:id',
      },
      artifacts: {
        import: 'POST /api/artifacts/import',
        list: 'GET /api/artifacts',
      },
      events: {
        list: 'GET /api/events',
      },
    },
  });
});

// ============================================================================
// Error Handling
// ============================================================================

fastify.setErrorHandler((error, request, reply) => {
  fastify.log.error(error);
  
  const statusCode = error.statusCode || 500;
  
  reply.code(statusCode).send({
    error: error.message || 'Internal Server Error',
    statusCode,
  });
});

// ============================================================================
// Graceful Shutdown
// ============================================================================

const shutdown = async () => {
  fastify.log.info('Shutting down gracefully...');
  peerDiscoveryService.stop();
  await fastify.close();
  process.exit(0);
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// ============================================================================
// Start Server
// ============================================================================

try {
  await fastify.listen({ port: PORT, host: HOST });
  
  fastify.log.info('============================================================');
  fastify.log.info('Garbageman WebUI API Server - Running');
  fastify.log.info('============================================================');
  fastify.log.info(`Address: http://${HOST}:${PORT}`);
  fastify.log.info(`Environment: ${process.env.NODE_ENV || 'development'}`);
  fastify.log.info(`Log Level: ${LOG_LEVEL}`);
  fastify.log.info('============================================================');
} catch (err) {
  fastify.log.error(err);
  process.exit(1);
}
