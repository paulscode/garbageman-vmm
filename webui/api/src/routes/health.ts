/**
 * Health Check Route
 * ===================
 * Returns API health status and connectivity to multi-daemon supervisor
 */

import type { FastifyInstance } from 'fastify';
import type { HealthResponse } from '../lib/types.js';

const VERSION = '0.1.0';
const SUPERVISOR_URL = process.env.SUPERVISOR_URL || 'http://multi-daemon:9000';

/**
 * Check if supervisor is reachable
 */
async function checkSupervisor(): Promise<'ok' | 'error'> {
  try {
    const response = await fetch(`${SUPERVISOR_URL}/health`, {
      signal: AbortSignal.timeout(5000),
    });
    return response.ok ? 'ok' : 'error';
  } catch {
    return 'error';
  }
}

export default async function healthRoute(fastify: FastifyInstance) {
  fastify.get('/api/health', async (request, reply) => {
    const supervisorStatus = await checkSupervisor();
    
    const health: HealthResponse = {
      status: supervisorStatus === 'ok' ? 'ok' : 'degraded',
      version: VERSION,
      timestamp: new Date().toISOString(),
      services: {
        api: 'ok',
        supervisor: supervisorStatus,
        envfiles: 'ok', // TODO: validate envfiles directory is accessible
      },
    };
    
    // Always return 200 - API is functional even if supervisor is unavailable
    // Clients can check the 'status' field to see if services are degraded
    reply.code(200).send(health);
  });
}
