# Multi-Daemon Container

**Status:** Real Implementation (Active Development)

## Overview

The `multi-daemon` container supervises multiple Garbageman or Bitcoin Knots daemon instances within a single container. This architecture enables efficient resource sharing while maintaining isolation between instances.

### Key Features

Each managed daemon instance:

- **Isolated execution** with configurable CPU/RAM limits (via cgroups in future)
- **Unique ports** for RPC, P2P, and ZMQ communication
- **Tor integration** with automatic hidden service (.onion address) generation
- **Flexible networking** - Choose Tor-only or clearnet (IPv4/IPv6) operation
- **Real-time monitoring** via Bitcoin RPC and process health checks
- **Centralized management** through unified supervisor API

## Current Implementation Status

The multi-daemon container is **actively implemented with real functionality**:

✅ **Implemented:**
- `supervisor.stub.ts`: Full-featured HTTP server managing real daemon processes
- Tor integration via `tor-manager.ts` (hidden service per instance)
- Process lifecycle management (spawn, monitor, restart, cleanup)
- Real Bitcoin RPC queries for metrics (blocks, peers, sync progress)
- Health monitoring with automatic restart on crashes
- ENV file-based configuration loading
- Peer breakdown categorization (Libre Relay, Knots, Core v30+)

🚧 **In Progress:**
- Resource limiting (CPU/RAM cgroups)
- Blockchain snapshot extraction and import
- Artifact management (binary downloads/verification)

📋 **Future Enhancements:**
- Prometheus metrics export
- Advanced scaling logic
- Log aggregation and parsing

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Multi-Daemon Container (Alpine Linux + Node 20)        │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Supervisor Process (TypeScript)                 │  │
│  │  - Reads envfiles/instances/*.env               │  │
│  │  - Spawns N bitcoind daemon processes           │  │
│  │  - Monitors health via RPC getblockchaininfo    │  │
│  │  - Auto-restarts crashed daemons               │  │
│  │  - Exposes HTTP API on :9000                    │  │
│  └──────────────────────────────────────────────────┘  │
│          │                │                │             │
│          ▼                ▼                ▼             │
│     [Daemon 1]       [Daemon 2]       [Daemon 3]        │
│     bitcoind-gm      bitcoind-knots   bitcoind-gm       │
│     RPC: 19001       RPC: 19002       RPC: 19003        │
│     P2P: 18001       P2P: 18002       P2P: 18003        │
│     ZMQ: 28001       ZMQ: 28002       ZMQ: 28003        │
│                                                          │
│  ┌──────────────────────────────────────────────────┐  │
│  │  Tor Daemon (tor)                                │  │
│  │  - Single process managing all hidden services   │  │
│  │  - One HiddenServiceDir per instance            │  │
│  │  - Auto-generates .onion addresses              │  │
│  │  - SOCKS5 proxy on :9050                        │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

## Files

- **Dockerfile**: Alpine Linux-based Node 20 image with Tor and minimal dependencies
- **entrypoint.sh**: Container startup script (initializes directories, launches supervisor)
- **supervisor.stub.ts**: Main supervisor process (TypeScript, runs via tsx)
- **tor-manager.ts**: Tor hidden service management (add/remove/configure)
- **package.json**: Node.js dependencies (socks, tsx, @types/node)
- **scripts/scaffold-daemon.sh**: (Future) Helper to clone base daemon directories

## Supervisor HTTP API

The supervisor exposes a REST API on port 9000 for management and monitoring:

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Health check (returns 200 OK) |
| `GET` | `/instances` | List all daemon instances with live status |
| `GET` | `/instances/:id` | Get detailed status for single instance |
| `POST` | `/instances/:id/start` | Start a daemon instance |
| `POST` | `/instances/:id/stop` | Stop a daemon instance gracefully |
| `POST` | `/instances/:id/restart` | Restart a daemon instance |

### Example Response: `GET /instances`

```json
{
  "instances": [
    {
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
  ]
}
```

### Field Descriptions

- **state**: `up`, `exited`, `starting`, `stopping`
- **impl**: `garbageman` or `knots` (which Bitcoin implementation)
- **version**: Bitcoin Core version string (queried via RPC)
- **uptime**: Seconds since daemon started
- **peers**: Total connected peer count
- **peerBreakdown**: Categorized peer types based on user agent and service bits
- **blocks/headers**: Current blockchain sync status
- **progress**: 0.0 to 1.0 (blockchain sync completion)
- **initialBlockDownload**: `true` during initial sync, `false` when caught up
- **diskGb**: Disk space used by this instance
- **onion**: Tor v3 hidden service address (if configured)
- **ipv4Enabled**: Whether clearnet networking is enabled
- **kpiTags**: Labels for filtering/categorization in UI

## Building the Container

```bash
# From the multi-daemon directory
docker build -t garbageman-multi-daemon:latest .

# Or from project root
docker build -f multi-daemon/Dockerfile -t garbageman-multi-daemon:latest multi-daemon/
```

## Running Standalone (Development)

```bash
# Run with default ports
docker run -d \
  --name multi-daemon \
  -p 9000:9000 \
  -v $(pwd)/envfiles:/envfiles:ro \
  -v gm-data:/data/bitcoin \
  garbageman-multi-daemon:latest

# Check supervisor health
curl http://localhost:9000/health

# List instances
curl http://localhost:9000/instances | jq
```

## Running in Docker Compose

See `devtools/compose.webui.yml` for full stack deployment with API and UI.

```bash
cd devtools
docker-compose -f compose.webui.yml up multi-daemon
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SUPERVISOR_PORT` | `9000` | Port for supervisor HTTP API |
| `DATA_DIR` | `/data/bitcoin` | Base directory for daemon data dirs |
| `ARTIFACTS_DIR` | `/app/.artifacts` | Downloaded binaries and blockchain artifacts |
| `ENVFILES_DIR` | `/envfiles` | Directory containing instance configurations |
| `TOR_PROXY_HOST` | `127.0.0.1` | Tor SOCKS5 proxy hostname |
| `TOR_PROXY_PORT` | `9050` | Tor SOCKS5 proxy port |

## Configuration via ENV Files

The supervisor reads configuration from `/envfiles/instances/*.env` files. Each file defines one daemon instance.

### Example: `/envfiles/instances/gm-clone-20251107-143216.env`

```bash
INSTANCE_ID=gm-clone-20251107-143216
BITCOIN_IMPL=garbageman
NETWORK=mainnet
RPC_PORT=19001
P2P_PORT=18001
ZMQ_PORT=28001
RPC_USER=gm-gm-clone-20251107-143216
RPC_PASS=kJ8xL2mP9qR4tY6wZ3nB5vC7dF1gH0jK4lM8nP2qR5sT9uV3xW6yZ0
IPV4_ENABLED=false
# TOR_ONION is auto-generated and written back by supervisor
# RPC_USER and RPC_PASS are auto-generated per instance for security
```

The supervisor:
1. Scans `/envfiles/instances/` on startup
2. Spawns a `bitcoind` process for each valid config
3. Generates Tor hidden services (writes `.onion` address back to ENV file)
4. Monitors health and restarts on crashes
5. Exposes live status via HTTP API

## Integration with API Service

The `webui-api` container queries the supervisor's HTTP endpoints to:
- Display real-time daemon status in the UI
- Start/stop instances on user request
- Show peer breakdowns and sync progress

Configuration (ENV file) creation is handled by the API service, which writes new files to `/envfiles/instances/` when users create instances through the UI.

## Tor Hidden Services

Each daemon instance gets its own Tor v3 hidden service:

- **Hidden service directory**: `/data/tor/hidden-services/<instance-id>/`
- **Configuration**: Managed by `tor-manager.ts`
- **Reload**: Supervisor sends `SIGHUP` to Tor after adding/removing services
- **Address persistence**: `.onion` addresses persist across restarts (keys stored in hidden service directory)

The Tor daemon forwards `.onion:8333` connections to the instance's local P2P port.

## Development

### Local Development (without Docker)

```bash
cd multi-daemon

# Install dependencies
npm install

# Set environment variables
export SUPERVISOR_PORT=9000
export DATA_DIR=/tmp/gm-data
export ENVFILES_DIR=../envfiles

# Run supervisor directly
npx tsx supervisor.stub.ts
```

### Debugging

```bash
# View supervisor logs
docker logs -f multi-daemon

# Exec into running container
docker exec -it multi-daemon sh

# Check Tor status
docker exec multi-daemon ps aux | grep tor

# View daemon processes
docker exec multi-daemon ps aux | grep bitcoind

# Check hidden service addresses
docker exec multi-daemon ls -la /data/tor/hidden-services/
```

## Future Enhancements

### Planned Features

1. **Resource Limiting**
   - Apply cgroup CPU shares and memory limits per instance
   - Prevent resource starvation between instances
   - Configurable via ENV file (CPUS, RAM_MB)

2. **Blockchain Snapshot Management**
   - Extract blockchain data from base instance
   - Import blockchain into new instances (skip initial sync)
   - Verify checksums before import

3. **Artifact Management**
   - Download Bitcoin Core/Knots releases from GitHub
   - Verify GPG signatures and checksums
   - Store binaries in `/app/.artifacts/`
   - Support multiple versions side-by-side

4. **Advanced Monitoring**
   - Parse daemon logs for warnings/errors
   - Track connection counts, ban scores, rejected blocks
   - Export metrics in Prometheus format
   - Alerting on crash/restart events

5. **Dynamic Scaling**
   - Add/remove instances via API without supervisor restart
   - Hot-reload ENV file changes
   - Graceful shutdown with configurable timeout

6. **Log Aggregation**
   - Centralized logging with structured JSON
   - Per-instance log files in `/data/bitcoin/<id>/debug.log`
   - Log rotation and retention policies

## Troubleshooting

### Instance won't start

1. Check ENV file syntax: `cat /envfiles/instances/<id>.env`
2. Verify ports aren't already in use: `docker exec multi-daemon netstat -tulpn`
3. Check supervisor logs: `docker logs multi-daemon | grep <id>`
4. Verify bitcoind binary exists: `docker exec multi-daemon which bitcoind-gm`

### Tor hidden service not generating

1. Check Tor daemon is running: `docker exec multi-daemon ps aux | grep tor`
2. Verify permissions: `docker exec multi-daemon ls -la /data/tor/hidden-services/`
3. Check torrc config: `docker exec multi-daemon cat /data/tor/torrc`
4. Restart Tor: `docker exec multi-daemon killall -HUP tor`

### RPC connection refused

1. Verify daemon is running: `docker exec multi-daemon ps aux | grep bitcoind`
2. Check RPC credentials in ENV file match bitcoin.conf
3. Test RPC manually: `docker exec multi-daemon bitcoin-cli -rpcport=19001 -rpcuser=... getblockchaininfo`
4. Check firewall rules if accessing from outside container

## Production Deployment Notes

- **Data persistence**: Mount `/data/bitcoin` and `/data/tor` as volumes
- **ENV files**: Mount `/envfiles` as read-only for security
- **Resource limits**: Set Docker memory/CPU limits at container level
- **Monitoring**: Export supervisor metrics to Prometheus/Grafana
- **Backups**: Regular backups of `/data/bitcoin/` (blockchain data) and `/data/tor/hidden-services/` (hidden service keys)
- **Security**: Run container with minimal privileges, use read-only root filesystem where possible
- **Updates**: Use rolling updates with health checks to minimize downtime

## License

Same as Bitcoin Core and Libre Relay (MIT License)
