/**
 * Authentication Route
 * ====================
 * Handles WebUI authentication with JWT tokens.
 * 
 * Security Features:
 *  - Server-side password validation
 *  - JWT tokens with expiration
 *  - Rate limiting to prevent brute force
 *  - Support for wrapper-provided passwords (Start9/Umbrel)
 *  - Support for standalone deployments via environment variable
 * 
 * Routes:
 *  POST /api/auth/login     - Authenticate and receive JWT token
 *  POST /api/auth/validate  - Validate JWT token
 */

import type { FastifyInstance } from 'fastify';
import * as crypto from 'crypto';

// JWT token generation and validation
// Using HMAC-SHA256 for simplicity (production should use proper JWT library)
const JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
const TOKEN_EXPIRY_MS = 24 * 60 * 60 * 1000; // 24 hours

// Password sources (in order of priority):
// 1. WRAPPER_UI_PASSWORD - provided by wrapper (Start9/Umbrel)
// 2. WEBUI_PASSWORD - set by user for standalone deployments
// 3. Generate random password on first start (log to console for standalone)
let UI_PASSWORD = process.env.WRAPPER_UI_PASSWORD || process.env.WEBUI_PASSWORD;

if (!UI_PASSWORD) {
  // Standalone mode: Generate secure random password
  UI_PASSWORD = crypto.randomBytes(16).toString('base64url');
  console.warn('═══════════════════════════════════════════════════════════');
  console.warn('⚠️  NO PASSWORD CONFIGURED - GENERATED RANDOM PASSWORD');
  console.warn('═══════════════════════════════════════════════════════════');
  console.warn(`WebUI Password: ${UI_PASSWORD}`);
  console.warn('');
  console.warn('To set a custom password, use environment variable:');
  console.warn('  WEBUI_PASSWORD=your_secure_password');
  console.warn('');
  console.warn('For wrapper deployments (Start9/Umbrel), use:');
  console.warn('  WRAPPER_UI_PASSWORD=<password_from_wrapper>');
  console.warn('═══════════════════════════════════════════════════════════');
}

/**
 * Simple JWT token generation (base64url encoding)
 */
function generateToken(payload: any): string {
  const header = { alg: 'HS256', typ: 'JWT' };
  const encodedHeader = Buffer.from(JSON.stringify(header)).toString('base64url');
  const encodedPayload = Buffer.from(JSON.stringify(payload)).toString('base64url');
  
  const signature = crypto
    .createHmac('sha256', JWT_SECRET)
    .update(`${encodedHeader}.${encodedPayload}`)
    .digest('base64url');
  
  return `${encodedHeader}.${encodedPayload}.${signature}`;
}

/**
 * Verify and decode JWT token
 */
function verifyToken(token: string): any | null {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    
    const [encodedHeader, encodedPayload, providedSignature] = parts;
    
    // Verify signature
    const expectedSignature = crypto
      .createHmac('sha256', JWT_SECRET)
      .update(`${encodedHeader}.${encodedPayload}`)
      .digest('base64url');
    
    if (providedSignature !== expectedSignature) return null;
    
    // Decode and validate payload
    const payload = JSON.parse(Buffer.from(encodedPayload, 'base64url').toString());
    
    // Check expiration
    if (payload.exp && Date.now() > payload.exp) return null;
    
    return payload;
  } catch (err) {
    return null;
  }
}

/**
 * Extract token from Authorization header
 */
function extractToken(authHeader?: string): string | null {
  if (!authHeader) return null;
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : null;
}

export default async function authRoute(fastify: FastifyInstance) {
  // --------------------------------------------------------------------------
  // POST /api/auth/login - Authenticate and get JWT token
  // --------------------------------------------------------------------------
  
  fastify.post<{
    Body: { password: string };
    Reply: { success: boolean; token?: string; message?: string };
  }>(
    '/api/auth/login',
    {
      config: {
        rateLimit: {
          max: 10, // Only 10 login attempts per minute
          timeWindow: '1 minute',
        },
      },
    },
    async (request, reply) => {
      const { password } = request.body;
      
      if (!password) {
        return reply.code(400).send({
          success: false,
          message: 'Password required',
        });
      }
      
      // Constant-time comparison to prevent timing attacks
      const providedBuffer = Buffer.from(password);
      const expectedBuffer = Buffer.from(UI_PASSWORD!);
      
      // Ensure same length for constant-time comparison
      const isValid = providedBuffer.length === expectedBuffer.length &&
        crypto.timingSafeEqual(providedBuffer, expectedBuffer);
      
      if (!isValid) {
        // Log failed attempt
        fastify.log.warn(`Failed login attempt from ${request.ip}`);
        
        // Return error after a delay to slow down brute force
        await new Promise(resolve => setTimeout(resolve, 1000));
        
        return reply.code(401).send({
          success: false,
          message: 'Invalid password',
        });
      }
      
      // Generate JWT token
      const token = generateToken({
        iat: Date.now(),
        exp: Date.now() + TOKEN_EXPIRY_MS,
        type: 'webui_access',
      });
      
      fastify.log.info(`Successful login from ${request.ip}`);
      
      reply.send({
        success: true,
        token,
      });
    }
  );
  
  // --------------------------------------------------------------------------
  // POST /api/auth/validate - Validate JWT token
  // --------------------------------------------------------------------------
  
  fastify.post<{
    Reply: { valid: boolean; message?: string };
  }>(
    '/api/auth/validate',
    async (request, reply) => {
      const token = extractToken(request.headers.authorization);
      
      if (!token) {
        return reply.send({ valid: false, message: 'No token provided' });
      }
      
      const payload = verifyToken(token);
      
      if (!payload) {
        return reply.send({ valid: false, message: 'Invalid or expired token' });
      }
      
      reply.send({ valid: true });
    }
  );
}

// Export middleware for protecting routes
export function requireAuth(fastify: FastifyInstance) {
  return async (request: any, reply: any) => {
    const token = extractToken(request.headers.authorization);
    
    if (!token) {
      return reply.code(401).send({
        error: 'Authentication required',
        message: 'No token provided',
      });
    }
    
    const payload = verifyToken(token);
    
    if (!payload) {
      return reply.code(401).send({
        error: 'Authentication required',
        message: 'Invalid or expired token',
      });
    }
    
    // Attach user info to request for downstream handlers
    request.user = payload;
  };
}
