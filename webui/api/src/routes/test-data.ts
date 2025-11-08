/**
 * Test Data Routes
 * =================
 * Endpoints for managing test data in development
 * 
 * SECURITY: These endpoints are only available in development mode.
 * Set NODE_ENV=production to disable.
 */

import type { FastifyInstance } from 'fastify';
import { peerDiscoveryService } from '../services/peer-discovery.js';
import { torPeerDiscoveryService } from '../services/tor-peer-discovery.js';

const isDevelopment = process.env.NODE_ENV !== 'production';

export default async function testDataRoute(fastify: FastifyInstance) {
  // Skip registering routes in production
  if (!isDevelopment) {
    fastify.log.info('Test data routes disabled (NODE_ENV=production)');
    return;
  }

  fastify.log.warn('Test data routes enabled (NODE_ENV != production) - for development use only');

  /**
   * POST /api/test-data/peers/add - Add test peers
   */
  fastify.post('/api/test-data/peers/add', async (request, reply) => {
    try {
      peerDiscoveryService.addTestPeers();
      torPeerDiscoveryService.addTestPeers();
      
      const clearnetLists = peerDiscoveryService.getPeerLists();
      const torPeers = torPeerDiscoveryService.getPeers();
      
      reply.send({
        success: true,
        message: 'Test peers added',
        stats: {
          clearnet: {
            total: clearnetLists.all.length,
            libreRelay: clearnetLists.libreRelay.length,
            coreV30Plus: clearnetLists.coreV30Plus.length,
          },
          tor: {
            total: torPeers.length,
            libreRelay: torPeers.filter(p => p.isLibreRelay).length,
          },
        },
      });
    } catch (error) {
      fastify.log.error(error);
      reply.code(500).send({ error: 'Failed to add test peers' });
    }
  });

  /**
   * POST /api/test-data/peers/clear - Clear all peers
   */
  fastify.post('/api/test-data/peers/clear', async (request, reply) => {
    try {
      peerDiscoveryService.clearAllPeers();
      torPeerDiscoveryService.clearAllPeers();
      
      reply.send({
        success: true,
        message: 'All peers cleared',
      });
    } catch (error) {
      fastify.log.error(error);
      reply.code(500).send({ error: 'Failed to clear peers' });
    }
  });
}
