# Garbageman Nodes Manager - WebUI

**Status:** Active Development (Real Implementation)

## Overview

Fully containerized web control plane for managing multiple Garbageman/Bitcoin Knots daemon instances. Features a dark neon war room aesthetic with TypeScript end-to-end architecture.

**Key Capabilities:**
- Manage multiple Bitcoin daemon instances from a unified web interface
- Real-time monitoring of sync status, peers, and resource usage
- Tor-based peer discovery with privacy-first networking
- Automated hidden service (.onion address) generation per instance
- Live blockchain synchronization tracking
- Container-based deployment for easy installation

**Technology Stack:**
- **Frontend:** Next.js 14, React, Tailwind CSS, Framer Motion
- **Backend:** Fastify (Node.js/TypeScript)
- **Supervisor:** Custom process manager with Tor integration
- **Deployment:** Docker Compose for full-stack orchestration

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                   Docker Compose Stack                       │
│                                                              │
│  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐ │
│  │   UI (Next.js) │  │  API (Fastify) │  │  Multi-Daemon │ │
│  │   Port: 5173   │◄─┤   Port: 8080   │◄─┤  Supervisor   │ │
│  │                │  │                │  │   Port: 9000  │ │
│  └────────────────┘  └────────────────┘  └───────────────┘ │
│         │                    │                    │         │
│         │                    ▼                    │         │
│         │            ┌──────────────┐             │         │
│         │            │  ENV Files   │             │         │
│         │            │  /envfiles/  │             │         │
│         │            └──────────────┘             │         │
│         │                                         │         │
│         └─────────────────────────────────────────┘         │
│                  http://localhost:5173                      │
└──────────────────────────────────────────────────────────────┘
```

## Components

### 1. Multi-Daemon Container

- **Path:** `multi-daemon/`
- **Purpose:** Supervises N daemon instances with real process management
- **Stack:** Node 20 (Alpine) + TypeScript + Tor
- **Status:** ✅ Real implementation with:
  - Actual bitcoind process spawning and monitoring
  - Tor hidden service management (one .onion per instance)
  - Health monitoring via Bitcoin RPC
  - Automatic crash recovery and restart logic
  - Peer categorization (Libre Relay, Knots, Core v30+)
- **API:** HTTP server on port 9000

### 2. WebUI API

- **Path:** `webui/api/`
- **Purpose:** REST API for managing instance configurations and proxying live status
- **Stack:** Fastify + TypeScript
- **Status:** ✅ Fully implemented with:
  - CRUD operations on ENV files (atomic writes)
  - Proxy to multi-daemon supervisor for live metrics
  - Tor-based peer discovery service
  - Clearnet peer discovery via DNS seeds
  - Event system for UI notifications
  - Port conflict detection
- **Port:** 8080

### 3. WebUI Frontend

- **Path:** `webui/ui/`
- **Purpose:** Dark neon war room UI for daemon management
- **Stack:** Next.js 14 + Tailwind + shadcn/ui + Framer Motion
- **Status:** ✅ Complete UI implementation with:
  - StatusBoard with aggregate KPIs (nodes, peers, sync progress)
  - NodeCard for each instance (status, peers, blocks, resources)
  - AlertsRail for system event notifications
  - RadioactiveBadge with animated SVG glow effects
  - New Instance Modal for creating daemon instances
  - Import Artifact Modal for blockchain snapshots
  - WCAG AA accessible (tested with keyboard navigation)
- **Port:** 5173 (development), 3000 (production)

### 4. ENV Files

- **Path:** `envfiles/`
- **Purpose:** Configuration persistence layer
- **Structure:**
  - `GLOBAL.env` - Shared defaults (implementation, network, base paths)
  - `instances/*.env` - Per-instance configs (ports, RPC credentials, Tor addresses)

## Quick Start

### Prerequisites

- Docker + Docker Compose
- Make (optional, for convenience targets)

### Run Everything

```bash
# From devtools/ directory
docker compose -f compose.webui.yml up --build

# Or use Make
cd devtools
make up
```

Access the UI at: **http://localhost:5173**

**Default Password:** Check the API container logs for the auto-generated password:
```bash
docker logs webui-api | grep "WebUI Password"
```

Or set a custom password:
```bash
# Edit devtools/compose.webui.yml and add:
environment:
  - WEBUI_PASSWORD=your_secure_password
```

See [Authentication Documentation](../docs/AUTHENTICATION.md) for complete details.

### Stop Everything

```bash
docker compose -f compose.webui.yml down

# Or
make down
```

### View Logs

```bash
# All services
make logs

# Individual services
make ui          # UI logs only
make api         # API logs only
make supervisor  # Supervisor logs only
```

## Development Workflow

### 1. Start Services

```bash
cd devtools
make up
```

### 2. Make Changes

Edit files in:
- `webui/ui/src/` - UI components
- `webui/api/src/` - API routes
- `multi-daemon/` - Supervisor logic

### 3. Rebuild (if needed)

```bash
make rebuild
```

### 4. View Logs

```bash
make logs
```

## Project Structure

```
garbageman-nm/
├── multi-daemon/           # Multi-daemon supervisor container
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── supervisor.stub.ts  # Stub process manager
│   ├── package.json
│   ├── scripts/
│   │   └── scaffold-daemon.sh
│   └── README.md
│
├── webui/
│   ├── api/                # Fastify REST API
│   │   ├── Dockerfile
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   ├── src/
│   │   │   ├── server.ts
│   │   │   ├── lib/
│   │   │   │   ├── types.ts
│   │   │   │   └── envstore.ts
│   │   │   └── routes/
│   │   │       ├── health.ts
│   │   │       ├── instances.ts
│   │   │       └── artifacts.ts
│   │   └── README.md
│   │
│   └── ui/                 # Next.js frontend
│       ├── Dockerfile
│       ├── package.json
│       ├── tsconfig.json
│       ├── next.config.js
│       ├── postcss.config.js
│       ├── tailwind.config.ts
│       ├── src/
│       │   ├── app/
│       │   │   ├── layout.tsx
│       │   │   └── page.tsx
│       │   ├── components/
│       │   │   ├── CommandBar.tsx
│       │   │   ├── NodeCard.tsx
│       │   │   ├── StatusBoard.tsx
│       │   │   ├── AlertsRail.tsx
│       │   │   └── RadioactiveBadge.tsx
│       │   ├── lib/
│       │   │   ├── stubs.ts
│       │   │   └── utils.ts
│       │   └── styles/
│       │       ├── globals.css
│       │       └── tokens.css
│       └── README.md
│
├── envfiles/               # Configuration storage
│   ├── GLOBAL.env
│   └── instances/
│       ├── gm_base.env
│       ├── gm-clone-20251105-143216.env
│       └── gm-clone-20251105-143954.env
│
└── devtools/               # Development tools
    ├── compose.webui.yml   # Docker Compose config
    ├── Makefile            # Convenience targets
    └── (existing tools)
```

## UI Design System

### Color Palette

- **Backgrounds:** `--bg0` through `--bg3` (dark graphite/black)
- **Text:** `--tx0` through `--tx3` (white to gray, WCAG AA)
- **Accents:**
  - Orange (primary): `--acc-orange`
  - Amber (warning): `--acc-amber`
  - Green (success): `--acc-green`
  - Red (error): `--acc-red`

### Glow Effects

- `glow-0` through `glow-4` - Neon orange intensity
- `glow-green-*` - Success state glow
- `glow-amber-*` - Warning state glow

### Motion

- Respects `prefers-reduced-motion`
- Durations: `--duration-fast` (150ms) to `--duration-slower` (600ms)
- Easings: `--ease-in-out`, `--ease-bounce`

### Components

All components include:
- Full TypeScript typing
- Accessibility (ARIA labels, focus-visible)
- Responsive design
- War room aesthetic

## API Endpoints

### Health

- `GET /api/health` - API health check + supervisor connectivity status

### Instances

- `GET /api/instances` - List all instances (config + live status from supervisor)
- `GET /api/instances/:id` - Get detailed status for single instance
- `POST /api/instances` - Create new instance (writes ENV file, supervisor auto-loads)
- `PUT /api/instances/:id` - Update instance config (RPC creds, Tor address)
- `DELETE /api/instances/:id` - Delete instance (removes ENV file, supervisor cleanup)
- `POST /api/instances/:id/start` - Start a stopped daemon instance
- `POST /api/instances/:id/stop` - Gracefully stop a running daemon instance

### Peers

- `GET /api/peers/discovered` - Get discovered peers from Tor and clearnet crawling
- `GET /api/peers/seeds` - Get status of seed address probing
- `GET /api/peers/discovery-status` - Get peer discovery service status

### Events

- `GET /api/events` - Get system event feed (instance lifecycle, errors, sync milestones)
- `GET /api/events?category=instance` - Filter events by category
- `GET /api/events?type=error` - Filter events by type

### Artifacts (Blockchain Snapshots)

- `POST /api/artifacts/import` - Import blockchain snapshot from GitHub release
- `GET /api/artifacts` - List available blockchain artifacts
- `DELETE /api/artifacts/:id` - Delete a blockchain artifact

### Test Data (Development)

- `GET /api/test-data/node-versions` - Get sample node version strings
- `POST /api/test-data/reset` - Reset test data to initial state

## Environment Variables

### Multi-Daemon

| Variable          | Default         | Description             |
|-------------------|-----------------|-------------------------|
| `SUPERVISOR_PORT` | `9000`          | Supervisor HTTP port    |
| `DATA_DIR`        | `/data/bitcoin` | Daemon data directory   |
| `ARTIFACTS_DIR`   | `/app/.artifacts` | Binary storage        |

### API

| Variable          | Default                    | Description             |
|-------------------|----------------------------|-------------------------|
| `PORT`            | `8080`                     | API server port         |
| `ENVFILES_DIR`    | `/envfiles`                | ENV files directory     |
| `SUPERVISOR_URL`  | `http://multi-daemon:9000` | Supervisor endpoint     |
| `LOG_LEVEL`       | `info`                     | Logging verbosity       |

### UI

| Variable                 | Default                  | Description             |
|--------------------------|--------------------------|-------------------------|
| `PORT`                   | `5173`                   | UI server port          |
| `NEXT_PUBLIC_API_BASE`   | `http://localhost:8080`  | API base URL            |

## Current Status & Roadmap

### ✅ Implemented Features

**Multi-Daemon:**
- Real bitcoind process spawning and lifecycle management
- Tor hidden service integration (one .onion per instance)
- Health monitoring via Bitcoin RPC (getblockchaininfo)
- Automatic crash recovery with configurable restart limits
- Peer breakdown categorization (Libre Relay, Knots, Core versions)
- Process uptime tracking and resource monitoring

**API:**
- ENV file CRUD operations with atomic writes
- Proxy to supervisor for live daemon metrics
- Tor-based peer discovery (crawls .onion addresses from seeds)
- Clearnet peer discovery (DNS seeds + handshake)
- Event system for UI notifications
- Port conflict detection and validation

**UI:**
- Complete component library (StatusBoard, NodeCard, AlertsRail, etc.)
- Real-time dashboard with live metrics from supervisor
- Dark neon war room aesthetic with accessibility
- Responsive design for desktop and tablet
- Toast notifications for user actions

### 🚧 In Progress

- WebSocket support for true real-time updates (currently polling)
- Blockchain snapshot extraction and import workflow
- Resource limiting (CPU/RAM cgroups) per instance
- Advanced log parsing and error detection

### 📋 Planned Enhancements

1. **Security:** ~~Authentication~~ ✅ **IMPLEMENTED**, authorization roles, advanced rate limiting
2. **Reliability:** ENV file versioning, backup/restore
3. **Observability:** Prometheus metrics export, structured logging
4. **UX:** Drag-and-drop instance ordering, batch operations
5. **Performance:** Connection pooling, response caching
6. **Deployment:** Helm charts for Kubernetes, systemd service files

### ✅ Recently Completed

- **JWT Authentication** (November 2025) - Server-side authentication with wrapper support
- **Secure RPC Credentials** (November 2025) - Auto-generated per-instance credentials
- **Blockchain Privacy** (November 2025) - Automatic cleanup of identifying data from snapshots
- **Command Injection Protection** - Using spawn() instead of shell commands
- **Path Traversal Prevention** - Comprehensive validation in envstore
- **Input Validation** - JSON schema validation with Ajv

## Target Platforms

- Start9
- Umbrel
- Generic Debian-based systems

## Contributing

See `CONTRIBUTING.md` for guidelines.

## License

See `LICENSE` for details.
