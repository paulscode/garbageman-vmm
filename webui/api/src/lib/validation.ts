/**
 * API Input Validation Schemas
 * =============================
 * JSON Schema validation using Ajv for all API endpoints.
 * Prevents invalid data from reaching business logic.
 * 
 * Security:
 *  - Strict regex patterns prevent path traversal and command injection
 *  - additionalProperties: false rejects unexpected fields
 *  - Numeric ranges enforce valid port numbers
 *  - Enum validation ensures only allowed values accepted
 */

import Ajv from 'ajv';
import addFormats from 'ajv-formats';

const ajv = new Ajv({
  allErrors: true,
  removeAdditional: 'all', // Remove properties not in schema
  useDefaults: true,
  coerceTypes: false, // Don't coerce types (be strict)
});

// Add format validators (email, uri, etc.)
addFormats(ajv as any); // Type compatibility workaround

// ============================================================================
// Create Instance Schema
// ============================================================================

export const createInstanceSchema = {
  type: 'object',
  required: ['implementation', 'network'],
  additionalProperties: false,
  properties: {
    instanceId: {
      type: 'string',
      pattern: '^[a-zA-Z0-9_-]{1,100}$',
      description: 'Unique instance identifier',
    },
    implementation: {
      type: 'string',
      enum: ['garbageman', 'knots'],
      description: 'Bitcoin implementation',
    },
    network: {
      type: 'string',
      enum: ['mainnet', 'testnet', 'signet', 'regtest'],
      description: 'Bitcoin network',
    },
    artifact: {
      type: 'string',
      pattern: '^[a-zA-Z0-9._-]{1,100}$',
      description: 'Artifact tag (e.g., v2025-11-07)',
    },
    rpcPort: {
      type: 'integer',
      minimum: 1024,
      maximum: 65535,
      description: 'RPC port',
    },
    p2pPort: {
      type: 'integer',
      minimum: 1024,
      maximum: 65535,
      description: 'P2P port',
    },
    zmqPort: {
      type: 'integer',
      minimum: 1024,
      maximum: 65535,
      description: 'ZeroMQ port',
    },
    ipv4Enabled: {
      type: 'boolean',
      default: false,
      description: 'Allow clearnet (IPv4/IPv6) connections',
    },
    useBlockchainSnapshot: {
      type: 'boolean',
      default: true,
      description: 'Extract blockchain data from artifact',
    },
    torOnion: {
      type: 'string',
      pattern: '^[a-z2-7]{56}\\.onion$',
      description: 'Tor hidden service address',
    },
  },
};

export const validateCreateInstance = ajv.compile(createInstanceSchema);

// ============================================================================
// Update Instance Schema
// ============================================================================

export const updateInstanceSchema = {
  type: 'object',
  additionalProperties: false,
  minProperties: 1, // At least one property to update
  properties: {
    ipv4Enabled: {
      type: 'boolean',
      description: 'Allow clearnet connections',
    },
    // Add other updatable fields as needed
  },
};

export const validateUpdateInstance = ajv.compile(updateInstanceSchema);

// ============================================================================
// Import Artifact Schema (GitHub)
// ============================================================================

export const importArtifactSchema = {
  type: 'object',
  required: ['tag'],
  additionalProperties: false,
  properties: {
    tag: {
      type: 'string',
      pattern: '^[a-zA-Z0-9._-]{1,100}$',
      description: 'Release tag (e.g., v2025-11-07)',
    },
    skipBlockchain: {
      type: 'boolean',
      default: true,
      description: 'Skip downloading blockchain parts',
    },
  },
};

export const validateImportArtifact = ajv.compile(importArtifactSchema);

// ============================================================================
// Query Parameter Schemas
// ============================================================================

export const eventsQuerySchema = {
  type: 'object',
  additionalProperties: false,
  properties: {
    limit: {
      type: 'string',
      pattern: '^[0-9]{1,4}$', // 1-9999
      description: 'Maximum number of events',
    },
    category: {
      type: 'string',
      enum: ['instance', 'system', 'peer', 'artifact'],
      description: 'Filter by category',
    },
    type: {
      type: 'string',
      enum: ['info', 'success', 'warning', 'error'],
      description: 'Filter by type',
    },
  },
};

export const validateEventsQuery = ajv.compile(eventsQuerySchema);

// ============================================================================
// Instance ID Parameter Schema
// ============================================================================

export const instanceIdParamSchema = {
  type: 'object',
  required: ['id'],
  additionalProperties: false,
  properties: {
    id: {
      type: 'string',
      pattern: '^[a-zA-Z0-9_-]{1,100}$',
      description: 'Instance ID',
    },
  },
};

export const validateInstanceIdParam = ajv.compile(instanceIdParamSchema);

// ============================================================================
// Artifact Tag Parameter Schema
// ============================================================================

export const artifactTagParamSchema = {
  type: 'object',
  required: ['tag'],
  additionalProperties: false,
  properties: {
    tag: {
      type: 'string',
      pattern: '^[a-zA-Z0-9._-]{1,100}$',
      description: 'Artifact tag',
    },
  },
};

export const validateArtifactTagParam = ajv.compile(artifactTagParamSchema);

// ============================================================================
// Validation Helper
// ============================================================================

/**
 * Format Ajv validation errors into human-readable message
 */
export function formatValidationErrors(validator: any): string {
  if (!validator.errors) return 'Validation failed';
  
  return validator.errors
    .map((err: any) => {
      const path = err.instancePath || 'root';
      return `${path}: ${err.message}`;
    })
    .join(', ');
}
