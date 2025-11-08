/**
 * Events API Routes
 * =================
 * Exposes system events for the status feed.
 */

import type { FastifyInstance } from 'fastify';
import { getEvents, getEventsByCategory, getEventsByType } from '../lib/events.js';

export default async function eventsRoute(fastify: FastifyInstance) {
  
  // --------------------------------------------------------------------------
  // GET /api/events - Get all events
  // --------------------------------------------------------------------------
  
  fastify.get<{
    Querystring: {
      limit?: string;
      category?: 'instance' | 'artifact' | 'sync' | 'network' | 'system';
      type?: 'info' | 'warning' | 'error' | 'success';
    };
  }>('/api/events', async (request, reply) => {
    try {
      const { limit, category, type } = request.query;
      const limitNum = limit ? parseInt(limit, 10) : undefined;
      
      let events;
      
      if (category) {
        events = getEventsByCategory(category, limitNum);
      } else if (type) {
        events = getEventsByType(type, limitNum);
      } else {
        events = getEvents(limitNum);
      }
      
      reply.send({ events });
      
    } catch (error) {
      fastify.log.error({ error }, 'Failed to fetch events');
      reply.code(500).send({
        error: 'Failed to fetch events',
        message: error instanceof Error ? error.message : 'Unknown error',
      });
    }
  });
}
