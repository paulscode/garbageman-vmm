/**
 * Peers Discovery Routes
 * ======================
 * Endpoints to access discovered Bitcoin peers categorized by capabilities
 * Supports both clearnet (DNS-based) and Tor (onion-based) peer discovery
 */

import type { FastifyInstance } from 'fastify';
import { peerDiscoveryService } from '../services/peer-discovery.js';
import { torPeerDiscoveryService } from '../services/tor-peer-discovery.js';

export default async function peersRoute(fastify: FastifyInstance) {
  /**
   * GET /api/peers - Get all categorized peer lists (clearnet + Tor)
   */
  fastify.get('/api/peers', async (request, reply) => {
    const clearnetLists = peerDiscoveryService.getPeerLists();
    const torPeers = torPeerDiscoveryService.getPeers();
    
    // Convert BigInt to string for JSON serialization
    const serializePeers = (peers: any[]) =>
      peers.map(p => ({
        ...p,
        services: p.services.toString(),
      }));
    
    reply.send({
      stats: {
        clearnet: {
          total: clearnetLists.all.length,
          libreRelay: clearnetLists.libreRelay.length,
          coreV30Plus: clearnetLists.coreV30Plus.length,
        },
        tor: {
          total: torPeers.length,
          successful: torPeers.filter(p => p.lastSuccess !== null).length,
          libreRelay: torPeers.filter(p => p.isLibreRelay).length,
        },
      },
      clearnet: {
        libreRelay: serializePeers(clearnetLists.libreRelay),
        coreV30Plus: serializePeers(clearnetLists.coreV30Plus),
        all: serializePeers(clearnetLists.all),
      },
      tor: {
        all: serializePeers(torPeers),
        libreRelay: serializePeers(torPeers.filter(p => p.isLibreRelay)),
      },
    });
  });

  /**
   * GET /api/peers/random - Get random peers for connecting
   */
  fastify.get<{
    Querystring: {
      category?: 'libreRelay' | 'coreV30Plus' | 'all';
      count?: number;
      torOnly?: string; // 'true' or 'false'
    };
  }>('/api/peers/random', async (request, reply) => {
    const category = request.query.category || 'all';
    const count = request.query.count || 8;
    const torOnlyParam = request.query.torOnly;
    
    // Parse torOnly parameter (undefined = no filter, 'true' = Tor only, 'false' = clearnet only)
    const torOnly = torOnlyParam === 'true' ? true : torOnlyParam === 'false' ? false : undefined;

    const peers = peerDiscoveryService.getRandomPeers(category, count, 
      torOnly !== undefined ? { torOnly } : undefined
    );
    
    // Convert BigInt to string for JSON serialization
    const serializedPeers = peers.map(p => ({
      ...p,
      services: p.services.toString(),
    }));
    
    reply.send({
      category,
      count: serializedPeers.length,
      torOnly,
      peers: serializedPeers,
    });
  });

  /**
   * GET /api/peers/status - Get current discovery service status
   */
  fastify.get('/api/peers/status', async (request, reply) => {
    const clearnetStatus = peerDiscoveryService.getStatus();
    const torStatus = torPeerDiscoveryService.getStatus();
    
    reply.send({
      clearnet: clearnetStatus,
      tor: torStatus,
    });
  });

  /**
   * GET /api/peers/tor/status - Get Tor discovery status specifically
   */
  fastify.get('/api/peers/tor/status', async (request, reply) => {
    reply.send(torPeerDiscoveryService.getStatus());
  });

  /**
   * GET /api/peers/seeds - Get seed check history (deduplicated, most recent first)
   * Query params:
   *   - limit: Maximum number of results (default: 100, max: 1000)
   */
  fastify.get<{
    Querystring: { limit?: string };
  }>('/api/peers/seeds', async (request, reply) => {
    const limitParam = request.query.limit;
    let limit = 100; // Default

    if (limitParam) {
      const parsed = parseInt(limitParam, 10);
      if (!isNaN(parsed) && parsed > 0) {
        limit = Math.min(parsed, 1000); // Cap at 1000
      }
    }

    const seedChecks = torPeerDiscoveryService.getSeedChecks(limit);
    reply.send({
      total: seedChecks.length,
      limit: limit,
      checks: seedChecks,
    });
  });

  /**
   * POST /api/peers/test-data - Inject test peer data for development
   */
  fastify.post('/api/peers/test-data', async (request, reply) => {
    peerDiscoveryService.addTestPeers();
    const lists = peerDiscoveryService.getPeerLists();
    reply.send({
      success: true,
      message: 'Test peers added',
      stats: {
        total: lists.all.length,
        libreRelay: lists.libreRelay.length,
        coreV30Plus: lists.coreV30Plus.length,
      },
    });
  });
}
