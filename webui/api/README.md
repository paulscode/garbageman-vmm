# Garbageman WebUI - API Server

**Status:** Real Implementation (Active Development)

## Overview

Fastify-based TypeScript REST API that serves as the backend for the Garbageman Nodes Manager WebUI. Handles instance configuration management, proxies live daemon status from the multi-daemon supervisor, and provides peer discovery services.

### Key Responsibilities

- **Configuration Management**: CRUD operations on ENV files (instance definitions)
- **Status Proxying**: Fetches live metrics from multi-daemon supervisor
- **Peer Discovery**: Tor-based and clearnet Bitcoin peer crawling
- **Event System**: Tracks and broadcasts system events to UI
- **Port Management**: Auto-assigns and validates unique port numbers
- **Data Validation**: Schema validation for all API requests

## Architecture

```
┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐
│   UI (Next.js)   │ HTTP  │  API (Fastify)   │ HTTP  │  Multi-Daemon    │
│   localhost:5173 │──────▶│  localhost:8080  │──────▶│  Supervisor      │
└──────────────────┘       └──────────────────┘       │  localhost:9000  │
                                     │                 └──────────────────┘
                                     │
                                     ▼
                           ┌──────────────────┐
                           │   ENV Files      │
                           │   /envfiles/     │
                           └──────────────────┘
```

## API Endpoints

### Health

- `GET /api/health` - API health check + supervisor connectivity test
  - Returns: `{ healthy: boolean, supervisor: { reachable: boolean, url: string } }`

### Instances

- `GET /api/instances` - List all instances (merged config + live status)
  - Returns: Array of instance objects with config and real-time metrics
  
- `GET /api/instances/:id` - Get detailed status for single instance
  - Returns: Complete instance data including peer breakdown, sync progress
  
- `POST /api/instances` - Create new instance
  - Body: `{ artifact, implementation, network, ipv4Enabled, rpcPort?, p2pPort?, zmqPort? }`
  - Returns: `{ success, instanceId, message }`
  - Validates: Port availability, unique instance ID
  
- `PUT /api/instances/:id` - Update instance configuration
  - Body: `{ torOnion?, version? }`
  - Returns: `{ success, message }`
  - Note: Cannot change ports after creation
  
- `DELETE /api/instances/:id` - Delete instance and clean up ENV file
  - Returns: `{ success, message }`
  - Side effect: Supervisor auto-stops daemon if running

### Peers (Peer Discovery Services)

- `GET /api/peers/discovered` - Get discovered peers from Tor and clearnet crawling
  - Returns: `{ libreRelay: Peer[], coreV30Plus: Peer[], all: Peer[] }`
  - Each peer includes: IP/onion, port, services, userAgent, lastSeen
  
- `GET /api/peers/seeds` - Get seed address check results
  - Returns: Array of seed check results with success/failure status
  - Useful for debugging Tor connectivity issues
  
- `GET /api/peers/discovery-status` - Get peer discovery service status
  - Returns: `{ clearnet: Status, tor: Status }`
  - Shows: running state, current seed, next query time, total peers found

### Events

- `GET /api/events` - Get system event feed (newest first)
  - Query params: `?limit=50` (optional)
  - Returns: Array of events with timestamp, type, category, title, message
  
- `GET /api/events?category=instance` - Filter by category
  - Categories: `instance`, `artifact`, `sync`, `network`, `system`
  
- `GET /api/events?type=error` - Filter by severity type
  - Types: `info`, `success`, `warning`, `error`

### Artifacts (Blockchain Snapshots & Binaries)

- `POST /api/artifacts/import` - Import blockchain snapshot from GitHub release
  - Body: `{ source: 'github' | 'url', version?, url?, impl }`
  - Returns: `{ success, message, artifactId? }`
  - Downloads and verifies checksums
  
- `GET /api/artifacts` - List available blockchain artifacts in storage
  - Returns: Array of artifacts with version, size, block height
  
- `DELETE /api/artifacts/:id` - Delete a blockchain artifact to free space
  - Returns: `{ success, message }`

### Test Data (Development Only)

- `GET /api/test-data/node-versions` - Get sample Bitcoin node version strings
  - Useful for testing peer categorization logic
  
- `POST /api/test-data/reset` - Reset test data to initial state
  - Resets stub instances for UI development

## Security Features

### Input Validation
- **JSON Schema Validation** (Ajv): All API requests validated against strict schemas
- **Path Traversal Protection**: Instance IDs validated with regex `^[a-zA-Z0-9._-]+$`
- **Command Injection Prevention**: Artifact names validated before use in shell commands
- **Port Range Validation**: RPC/P2P/ZMQ ports restricted to valid ranges (1024-65535)

### Rate Limiting
- **1000 requests/minute** per IP address (configurable)
- **Localhost exempt**: 127.0.0.1 and ::1 bypass rate limits for local development
- Returns **HTTP 429** when limit exceeded

### Process Execution
- **spawn() instead of exec()**: Uses Node.js spawn() with argument arrays to prevent shell injection
- **No shell interpretation**: Commands executed directly without shell parsing
- **Path resolution checks**: Artifact and instance paths validated before file operations

### Privacy Protection
- **Sensitive file cleanup**: Removes Tor keys, peer data, port configs from blockchain snapshots
- **Network subdirectory support**: Cleans files from both root and testnet/signet/regtest subdirs
- **Prevents identity reuse**: Each instance gets unique Tor hidden service key
- **Prevents port conflicts**: Removes old settings.json with hardcoded ports

### Logging
- **Sensitive data redaction**: RPC credentials automatically masked in logs
- **Configurable verbosity**: LOG_LEVEL env var controls output detail
- **No IP leakage**: Production logs avoid exposing connection metadata

## Data Flow

1. **Configuration**: API reads/writes ENV files in `/envfiles/`
2. **Live Status**: API queries supervisor HTTP API for real-time metrics
3. **Response**: API merges config + status into unified response

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | API server listening port |
| `HOST` | `0.0.0.0` | Bind address (0.0.0.0 allows external access) |
| `ENVFILES_DIR` | `/envfiles` | Path to instance ENV file directory |
| `SUPERVISOR_URL` | `http://multi-daemon:9000` | Multi-daemon supervisor HTTP endpoint |
| `LOG_LEVEL` | `info` | Logging verbosity (debug, info, warn, error) |
| `NODE_ENV` | `development` | Environment mode (development, production) |
| `TOR_PROXY_HOST` | `127.0.0.1` | Tor SOCKS5 proxy host (for peer discovery) |
| `TOR_PROXY_PORT` | `9050` | Tor SOCKS5 proxy port |

## Project Structure

```
webui/api/
├── Dockerfile                  # Alpine-based Node 20 image
├── package.json                # Dependencies and scripts
├── tsconfig.json               # TypeScript config
├── README.md                   # This file
│
├── src/
│   ├── server.ts               # Main Fastify app entry point
│   │
│   ├── routes/                 # API route handlers
│   │   ├── health.ts           # Health check endpoint
│   │   ├── instances.ts        # Instance CRUD operations
│   │   ├── peers.ts            # Peer discovery endpoints
│   │   ├── events.ts           # Event feed endpoints
│   │   ├── artifacts.ts        # Artifact management
│   │   └── test-data.ts        # Development test data
│   │
│   ├── services/               # Background services
│   │   ├── peer-discovery.ts  # Clearnet peer crawler (DNS seeds)
│   │   └── tor-peer-discovery.ts  # Tor peer crawler (.onion seeds)
│   │
│   └── lib/                    # Shared utilities
│       ├── types.ts            # TypeScript type definitions
│       ├── envstore.ts         # ENV file read/write operations
│       ├── events.ts           # In-memory event system
│       └── seed-parser.ts      # Libre Relay seed file parser
│
└── data/
    └── seeds/
        └── nodes_main.txt      # Libre Relay seed addresses (1519 peers)
```

## Development

```bash
# Install dependencies
npm install

# Run in dev mode (hot reload)
npm run dev

# Build TypeScript
npm run build

# Start production server
npm start

# Lint and format
npm run lint
npm run format
```

## Docker

```bash
# Build image
docker build -t garbageman-webui-api:latest .

# Run standalone
docker run -p 8080:8080 \
  -v $(pwd)/../../envfiles:/envfiles:ro \
  -e SUPERVISOR_URL=http://host.docker.internal:9000 \
  garbageman-webui-api:latest
```

## API Examples

### Create Instance

```bash
curl -X POST http://localhost:8080/api/instances \
  -H "Content-Type: application/json" \
  -d '{
    "artifact": "v2025-11-07",
    "implementation": "garbageman",
    "network": "mainnet",
    "ipv4Enabled": false,
    "useBlockchainSnapshot": true
  }'
```

Response:
```json
{
  "success": true,
  "instanceId": "gm-clone-20251107-143216",
  "message": "Instance created successfully. Supervisor will start daemon automatically."
}
```

### List Instances

```bash
curl http://localhost:8080/api/instances | jq
```

Response:
```json
{
  "instances": [
    {
      "config": {
        "INSTANCE_ID": "gm-clone-20251107-143216",
        "RPC_PORT": 19001,
        "P2P_PORT": 18001,
        "ZMQ_PORT": 28001,
        "BITCOIN_IMPL": "garbageman",
        "NETWORK": "mainnet",
        "IPV4_ENABLED": "false"
      },
      "status": {
        "id": "gm-clone-20251107-143216",
        "state": "up",
        "impl": "garbageman",
        "version": "29.2.0",
        "network": "mainnet",
        "uptime": 345678,
        "peers": 12,
        "peerBreakdown": {
          "libreRelay": 4,
          "knots": 2,
          "oldCore": 3,
          "newCore": 2,
          "other": 1
        },
        "blocks": 870450,
        "headers": 870450,
        "progress": 1.0,
        "initialBlockDownload": false,
        "diskGb": 150.3,
        "rpcPort": 19001,
        "p2pPort": 18001,
        "onion": "p3y4abcdefgh1234567890xyz.onion",
        "ipv4Enabled": false,
        "kpiTags": ["pruned", "tor-only", "mainnet", "garbageman"]
      }
    }
  ]
}
```

### Get Discovered Peers

```bash
curl http://localhost:8080/api/peers/discovered | jq
```

Response:
```json
{
  "libreRelay": [
    {
      "ip": "xyz123abc.onion",
      "port": 8333,
      "services": "0x20000009",
      "userAgent": "/Satoshi:29.1.0/",
      "version": 70016,
      "lastSeen": 1699392000000,
      "isLibreRelay": true,
      "isCoreV30Plus": false
    }
  ],
  "coreV30Plus": [...],
  "all": [...]
}
```

### Check Event Feed

```bash
curl "http://localhost:8080/api/events?limit=10" | jq
```

Response:
```json
[
  {
    "id": "event-42-1699392000000",
    "type": "success",
    "category": "instance",
    "title": "Instance Started",
    "message": "gm-clone-20251107-143216 started successfully",
    "timestamp": 1699392000000,
    "metadata": {
      "instanceId": "gm-clone-20251107-143216"
    }
  }
]
```

## Implementation Notes

### ENV File Handling

The `envstore` module (`src/lib/envstore.ts`) provides atomic writes via temporary files:

1. Parse existing ENV file into key-value pairs
2. Apply updates to in-memory map
3. Write new content to `<file>.tmp`
4. Atomic rename to `<file>` (ensures durability)
5. Catch and log errors if write fails

**Current Status**: Basic implementation preserves existing key-value pairs when updating. Comment preservation is handled on a best-effort basis (blank lines and comments at end of file are retained).

**Production Consideration**: For mission-critical comment preservation, consider an AST-based parser that maintains exact formatting and all comments throughout the file.

### Port Assignment

When creating instances without explicit port assignments, the API auto-assigns from configured ranges:

- **RPC Ports**: 19000-19999 (1000 available)
- **P2P Ports**: 18000-18999 (1000 available)  
- **ZMQ Ports**: 28000-28999 (1000 available)

**Algorithm**: Linear search through existing instance ENVs to find first unused port in each range. Checks both `GLOBAL.env` and all `instances/*.env` files.

**Scaling**: Current implementation supports up to 1000 concurrent instances. For larger deployments, implement a port allocation bitmap or database-backed registry.

### Tor Integration

Each instance gets a unique `.onion` address automatically:

- **Multi-daemon Container**: Runs one Tor daemon per instance
- **Hidden Service**: Exposes instance's P2P port as a hidden service
- **Auto-Configuration**: `supervisor.ts` generates `torrc` with hidden service config
- **Persistence**: Onion keys stored in `/data/instances/<id>/tor/` volume

**Discovery**: Background service crawls Libre Relay seeds and discovered peers for additional .onion addresses.

### Error Handling

All routes use try-catch with proper HTTP status codes:

- `200` - Success (read operations)
- `201` - Created (new resource)
- `202` - Accepted (async operation started)
- `400` - Bad Request (validation failed)
- `404` - Not Found (resource doesn't exist)
- `409` - Conflict (duplicate ID or port collision)
- `500` - Internal Server Error (unexpected failure)
- `503` - Service Unavailable (degraded health, supervisor unreachable)

Response format for errors:
```json
{
  "error": "Brief error message",
  "details": "Optional detailed context"
}
```

## Future Enhancements

### Planned Features

1. **JSON Schema Validation**: Add Ajv-based request validation for all POST/PUT endpoints
2. **Authentication & Authorization**: JWT or API key authentication with role-based access control
3. **Rate Limiting**: Implement token bucket or sliding window rate limiter to protect against abuse
4. **Pagination**: Add cursor-based pagination for `/api/instances` and `/api/events` endpoints
5. **WebSocket Support**: Real-time instance status updates via WebSocket for live dashboard updates
6. **Metrics Endpoint**: Expose Prometheus metrics endpoint (`/metrics`) for observability
7. **Backup System**: Automated ENV file versioning with git-like snapshots and restore capability
8. **Health Checks**: Enhanced health endpoint with component-level status (DB, supervisor, Tor)
9. **Audit Logging**: Structured logs for all state-changing operations (create, delete, config updates)
10. **Search & Filtering**: Query instances by network, implementation, status, or custom tags

### Integration Opportunities

- **Alerting**: Webhook integration for instance failures or degraded health
- **Monitoring**: Grafana dashboards consuming Prometheus metrics
- **Orchestration**: Kubernetes operator for cloud-native deployments
- **CI/CD**: Automated testing pipeline for peer discovery accuracy

See main project roadmap in `/webui/README.md` for full feature status.
