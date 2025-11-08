# 🚀 QUICK START - Garbageman WebUI

## What This Is

A fully containerized web control plane for managing multiple Bitcoin daemon instances (Garbageman/Knots). Features a dark neon war room aesthetic, peer discovery, artifact management, and real-time instance monitoring. Built with TypeScript end-to-end.

---

## Getting Started in 60 Seconds

### 1. Ensure Docker is Running

```bash
docker --version  # Should show Docker version 20.10+
docker compose version  # Should show Compose v2+
```

### 2. Start All Services

```bash
cd devtools
make up
```

This will:
- Build 4 Docker containers (tor-proxy, multi-daemon, API, UI)
- Start Tor SOCKS5 proxy on port 9050
- Start supervisor on port 9000
- Start API on port 8080  
- Start UI on port 5173

Wait ~30-60 seconds for build and health checks to complete.

### 3. Open the UI

```bash
# Open in your browser
open http://localhost:5173

# Or manually visit:
# http://localhost:5173
```

You should see:
- ✅ Dark neon orange UI (war room aesthetic)
- ✅ Status board with real-time metrics
- ✅ Bitcoin daemon instance cards (if any exist)
- ✅ Command bar with Import Artifact and New Instance buttons
- ✅ Peer Discovery dialog showing discovered Bitcoin nodes

### 4. Create Your First Instance

**Import an Artifact (Pre-built Binary):**
1. Click "IMPORT ARTIFACT" in the command bar
2. Choose "Import from GitHub" for fastest setup
3. Select latest release (e.g., `v2025-11-03-rc2`)
4. Wait for download and extraction (~5-10 minutes)

**Create a Node:**
1. Click "NEW INSTANCE" in the command bar
2. Select implementation (Garbageman or Knots)
3. Choose network (mainnet, testnet, signet, regtest)
4. Configure ports (auto-assigned if left blank)
5. Click "CREATE"
6. Wait for blockchain extraction (~2 minutes with pre-synced data)
7. Click "START" to launch the daemon

### 5. Explore Features

**Instance Management:**
- Start/stop instances with action buttons
- View real-time sync progress, peer counts, block height
- Monitor disk usage and network connectivity
- View peer breakdown (Libre Relay, Knots, Core versions)

**Peer Discovery:**
- Click "VIEW PEERS" to see discovered Bitcoin nodes
- Tabs: Clearnet Peers, Tor Peers, Seeds Checked
- Filter by: Libre Relay, Core v30+, All
- Real-time discovery via DNS seeds and Tor

**Check the API:**
```bash
curl http://localhost:8080/api/health
curl http://localhost:8080/api/instances
curl http://localhost:8080/api/peers
curl http://localhost:8080/api/artifacts
```

**Check the Supervisor:**
```bash
curl http://localhost:9000/health
curl http://localhost:9000/instances
```

### 5. View Logs

```bash
# All services
make logs

# Individual services
make ui          # UI logs only
make api         # API logs only
make supervisor  # Supervisor logs only
```

Press `Ctrl+C` to stop tailing logs.

### 6. Stop Services

```bash
make down
```

---

## What You're Seeing (Current State)

### ✅ Fully Functional Features

**Real Instance Management:**
- Create, start, stop, and monitor Bitcoin daemon instances
- Real blockchain data with IBD (Initial Block Download) support
- Pre-synced artifacts for fast deployment
- Resource isolation via Docker containers
- Real-time metrics: block height, peer count, sync progress

**Real Peer Discovery:**
- DNS seed queries for clearnet peers (IPv4/IPv6)
- Tor-based discovery using .onion seeds from Libre Relay's node list
- Libre Relay node detection (service bit 29 - 0x20000000)
- Bitcoin Core version identification from user agents
- Seed connection tracking (success/failure) for all address types
- Privacy-preserving: all Tor connections via SOCKS5 proxy

**Real Data Flows:**
- UI → API → Supervisor → Bitcoin Daemon
- WebSocket events for live updates
- Blockchain sync status monitoring
- Peer connection state tracking
- Log streaming from daemon containers

**Production-Ready Components:**
- API server with proper error handling
- Multi-daemon supervisor with process management
- Tor proxy integration for privacy
- Artifact management (GitHub releases)
- Environment variable configuration
- Docker Compose orchestration

### 🛠️ Development-Only Features

**Test Data Endpoints:**
- `/api/test-data/inject-peers` - Inject mock peers for UI testing
- `/api/test-data/clear` - Clear injected test data
- **Only available when NODE_ENV !== 'production'**
- Automatically disabled in production environment

**Development Compose:**
- `devtools/compose.webui.yml` - Hot reload, debug ports, dev dependencies
- Uses NODE_ENV=development for enhanced logging and test endpoints

### ⚠️ Known Limitations

**Still in Development:**
- No authentication/authorization (single-user assumption)
- No HTTPS/TLS (local development focused)
- No database persistence (in-memory state)
- No backup/restore for daemon data
- No migration path for artifacts between versions

**Performance Notes:**
- Initial Block Download can take hours/days depending on network
- Pre-synced artifacts reduce sync time but increase disk I/O
- Tor peer discovery is slower than clearnet DNS (circuit building overhead)
- Initial Tor bootstrap can take 5-10 minutes to discover first .onion peers
- Docker build times can be 2-5 minutes on first run

---

## Troubleshooting

### Port Already in Use?

If you see errors about ports 5173, 8080, or 9000:

1. Edit `devtools/compose.webui.yml`
2. Change port mappings (e.g., `5173:5173` → `3000:5173`)
3. Run `make restart`

### UI Not Loading?

```bash
# Check container status
docker ps | grep gm-webui-ui

# Check logs
make ui

# Rebuild
make rebuild
```

### API Errors?

```bash
# Check API health
curl http://localhost:8080/api/health

# Check logs
make api

# Check envfiles mount
docker exec -it gm-webui-api ls -la /envfiles
```

### Docker Issues?

```bash
# Clean everything and start fresh
make clean
make up
```

---

## Next Steps

### For Developers

1. **Read the documentation:**
   - `README.md` - Project overview and architecture
   - `CONTRIBUTING.md` - Contributing guidelines
   - `webui/README.md` - WebUI architecture details
   - `webui/api/README.md` - API documentation
   - `multi-daemon/README.md` - Supervisor documentation
   - `seeds/README.md` - Peer discovery and DNS seed usage
   - `TOR_PEER_DISCOVERY.md` - Tor integration details

2. **Modify the UI:**
   - Edit files in `webui/ui/src/`
   - Hot reload is automatic
   - Changes appear at http://localhost:5173
   - Components: `webui/ui/src/components/`
   - Hooks: `webui/ui/src/hooks/`

3. **Modify the API:**
   - Edit files in `webui/api/src/`
   - Auto-restarts on save (nodemon)
   - Test with curl or from UI
   - Routes: `webui/api/src/routes/`
   - Services: `webui/api/src/services/`

4. **Extend functionality:**
   - Add new instance actions (restart, backup, etc.)
   - Implement additional peer discovery sources
   - Add configuration UI for daemon settings
   - Create monitoring dashboards for metrics
   - Build artifact verification and validation

### For Designers

The design system is in:
- `webui/ui/src/styles/tokens.css` - CSS variables
- `webui/ui/src/styles/globals.css` - Global styles
- `webui/ui/tailwind.config.ts` - Tailwind theme

All colors, glows, and animations are customizable via CSS variables.

### For Product Managers

The UI demonstrates:
- Instance management (create, start, stop, delete)
- Real-time status monitoring with blockchain sync
- Peer discovery with Libre Relay detection
- Artifact management (GitHub releases)
- System alerts and notifications
- Radioactive war room aesthetic

Core features are functional with real daemon integration. Test data endpoints available in development mode for UI testing.

---

## Key Files to Know

| File | Purpose |
|------|---------|
| `devtools/Makefile` | Convenience commands (up, down, logs, tor) |
| `devtools/compose.webui.yml` | Docker Compose config for development |
| `webui/ui/src/app/page.tsx` | Main UI page |
| `webui/ui/src/components/` | React components (Dashboard, NodeCard, etc.) |
| `webui/api/src/server.ts` | API entry point |
| `webui/api/src/routes/` | API endpoints (instances, peers, artifacts) |
| `webui/api/src/services/` | Business logic (peer discovery, Tor integration) |
| `multi-daemon/supervisor.stub.ts` | Daemon supervisor and instance manager |
| `multi-daemon/tor-manager.ts` | Tor hidden service management |
| `envfiles/` | Configuration files for instances |
| `seeds/` | DNS seed lists and peer discovery tools |

---

## Support

- **Issues?** Check the troubleshooting section above
- **Questions?** Read the comprehensive docs in each component
- **Bugs?** Check logs with `make logs`
- **Feature requests?** See `CONTRIBUTING.md` for development guidelines

---

## Status

✅ **Core Features Functional** - Instance management, peer discovery, artifact handling  
✅ **Real Daemon Integration** - Bitcoin daemons spawn, sync, and connect to network  
✅ **Development Ready** - Hot reload, test endpoints, comprehensive logging  
⚠️ **Production Considerations** - No auth, no TLS, single-user design

---

**Enjoy exploring the Garbageman Nodes Manager WebUI!** 🚀☢️
