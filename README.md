# Garbageman Nodes Manager

**Modern web-based control plane for managing multiple Bitcoin nodes with privacy-first design**

Run Bitcoin nodes (Garbageman or Bitcoin Knots) with an intuitive web interface featuring real-time monitoring, peer discovery, and artifact management. Each node gets its own Tor hidden service for maximum privacy. Built for embedded platforms like Start9 and Umbrel, as well as traditional server deployments.

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/6af100e5-c873-4c26-b848-6a5ecdf17dbc" />

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux-green.svg)
![Docker](https://img.shields.io/badge/docker-compose-blue.svg)

---

## 🎯 What This Does

Garbageman NM provides **two complementary tools** for running Bitcoin nodes:

### 🖥️ WebUI (Primary Interface)

A modern, containerized web application for managing multiple Bitcoin daemon instances:

- ✅ **Web-based dashboard** - Dark neon aesthetic with real-time updates
- ✅ **Instance management** - Create, start, stop, monitor multiple daemon instances
- ✅ **Real-time monitoring** - Block height, peer counts, sync progress, resource usage
- ✅ **Peer discovery** - Clearnet DNS seeds + Tor-based .onion discovery
- ✅ **Libre Relay detection** - Identify and track Libre Relay nodes on the network
- ✅ **Artifact management** - Import pre-built binaries and pre-synced blockchains from GitHub
- ✅ **Tor integration** - SOCKS5 proxy for privacy-preserving peer discovery
- ✅ **Platform ready** - Designed for Start9, Umbrel, and traditional servers

**Target users:** Node operators seeking a modern UI, embedded platform users, developers building on the API.

### 🛠️ TUI Script (Production Deployment & Build Tool)

A bash-based system for artifact generation and system-level operations:

- ✅ **Artifact generation** - Build from source, create pre-synced blockchain archives, package releases
- ✅ **Container/VM deployment** - Create isolated Bitcoin node environments
- ✅ **Build automation** - Compile Garbageman/Knots with proper dependencies
- ✅ **System configuration** - Networking, storage, resource allocation
- ✅ **Export/transfer** - Modular format for sharing between systems

**Target users:** Release managers, production operators, advanced users needing full system control.

---

## 🚀 Quick Start

### WebUI Setup (Recommended for Most Users)

**Prerequisites:**
- Docker 20.10+ with Docker Compose v2+
- 8+ GB RAM, 4+ CPU cores
- 100+ GB disk space

```bash
# 1. Clone the repository
git clone https://github.com/paulscode/garbageman-nm.git
cd garbageman-nm

# 2. Start all services
cd devtools
make up

# 3. Open your browser
# http://localhost:5173
```

**What you get:**
- **WebUI** (http://localhost:5173) - Dashboard for managing instances
- **API** (http://localhost:8080) - Backend with peer discovery services
- **Supervisor** (http://localhost:9000) - Multi-daemon instance manager
- **Tor Proxy** (localhost:9050) - SOCKS5 proxy for privacy

**First steps in the UI:**
1. **Import Artifact** - Click "IMPORT ARTIFACT" → "Import from GitHub" to download pre-built binaries
2. **Create Instance** - Click "NEW INSTANCE" to configure your first daemon (mainnet, testnet, etc.)
3. **Start & Sync** - Click "START" and monitor real-time sync progress
4. **Discover Peers** - Click "VIEW PEERS" to see discovered Bitcoin nodes (clearnet and Tor)

**Enable HTTPS (Optional):**
For standalone deployments outside of wrapper projects:
```bash
# 1. Uncomment the Caddy service in devtools/compose.webui.yml
# 2. Start services
make up

# 3. Access via HTTPS
# https://localhost (self-signed cert for local dev)
```

For production domains with Let's Encrypt:
- Edit `devtools/Caddyfile` and replace `localhost` with your domain
- See [`docs/TLS_SETUP.md`](docs/TLS_SETUP.md) for full guide

**Note:** Wrapper deployments (Start9/Umbrel) handle TLS at their layer - do NOT enable Caddy.

**See [QUICKSTART.md](QUICKSTART.md) for detailed WebUI documentation.**

### TUI Script (For Artifact Generation)

```bash
# Run the TUI script
./garbageman-nm.sh

# First run will:
# 1. Install dependencies (asks for sudo once)
# 2. Choose between Containers or VMs
# 3. Show menu with deployment options
```

**When to use the TUI:**
- Building Garbageman/Knots from source for release
- Generating pre-synced blockchain archives
- Creating container/VM-based deployments
- Exporting artifacts for distribution

---

## 💻 System Requirements

### For WebUI

**Minimum:**
- **OS:** Linux (Ubuntu 22.04+, Debian 12+, or similar)
- **CPU:** 4 cores
- **RAM:** 8 GB
- **Disk:** 100 GB free
- **Docker:** 20.10+ with Compose v2+

**Recommended:**
- **CPU:** 8+ cores (faster blockchain sync)
- **RAM:** 16+ GB (run multiple instances)
- **Disk:** 250+ GB (more instances)
- **Network:** Broadband connection

**For embedded platforms (Start9, Umbrel):**
- Platform-specific packaging handles dependencies
- Resource requirements same as above
- See platform documentation for deployment

### For TUI Script

Same as WebUI, plus:
- **For Container mode:** Docker or Podman
- **For VM mode:** libvirt, qemu-kvm, virtinst
- All dependencies installed automatically on first run

---

## 🆚 What is Garbageman? Why Does It Exist?

**Garbageman** is a modified Bitcoin node (based on Bitcoin Knots) designed as a **defense against blockchain spam**.

> **Note:** This project also supports standard **Bitcoin Knots** nodes. You can choose your preferred implementation during setup.

### The Problem: The Libre Relay Spam Network

Bitcoin nodes traditionally filter spam transactions to protect network resources and maintain usability. However:

- **Libre Relay** is a network of nodes that intentionally relay spam transactions
- Libre Relay nodes identify each other using a special service bit flag (`NODE_LIBRE_RELAY` - bit 29)
- They preferentially connect with each other to create a zero-friction pipeline for spam
- This bypasses the spam filtering policies that most node operators rely on
- Result: Bad actors can easily flood the network with garbage transactions

**The spam problem is real:**
- Bloats the UTXO set (unspent transaction outputs) with dust outputs
- Wastes block space that could be used for legitimate transactions
- Increases costs for all users (higher fees, more storage)
- Degrades Bitcoin's usability as a payment system

### The Solution: Garbageman's Approach

**Garbageman nodes act as honeypots** to disrupt spam propagation:

1. **Advertise the `NODE_LIBRE_RELAY` flag** - Tricks Libre Relay nodes into connecting
2. **Accept connections from spam relayers** - They think you're part of their network
3. **Silently drop spam transactions** - Instead of relaying, just discard them
4. **Track patterns to avoid detection** - Sophisticated filtering to stay undetected
5. **Relay legitimate transactions normally** - Function as a regular pruned or full node otherwise

**Think of it like:** A network of undercover agents infiltrating spam relay infrastructure and preventing garbage from propagating.

### Why Run Multiple Nodes?

**Network effect:**
- More Garbageman nodes = better coverage against spam relay networks
- Each node with a unique Tor address can serve different parts of the network
- Helps isolate spam-relaying nodes from each other
- Protects Bitcoin's usability and decentralization

**Redundancy:**
- Multiple nodes provide backup if one goes down
- Geographic/network diversity improves resilience
- Different instances can serve different purposes (testing, mainnet, etc.)

**Privacy:**
- Each node gets its own Tor `.onion` address
- No single point of correlation for your activities
- Helps protect your privacy while contributing to the network

### Technical Details

Garbageman is based on Bitcoin Knots, which itself is a Bitcoin Core fork with additional features:

- **Bitcoin Knots:** Aggressive, common-sense spam filtering
- **Garbageman:** Bitcoin Knots + Libre Relay spoofing and preferential peering
- Both function as full or pruned, validating Bitcoin nodes
- Both support all standard Bitcoin features

**For deeper technical discussion:**
- [Bitcoin Dev mailing list](https://gnusha.org/pi/bitcoindev/aDWfDI03I-Rakopb%40petertodd.org)
- [Garbageman source repository](https://github.com/chrisguida/bitcoin/tree/garbageman-v29)
- [Bitcoin Knots documentation](https://bitcoinknots.org/)

---

## 📖 WebUI Usage Guide

### Dashboard Overview

The main dashboard shows:

- **Status Board** - System overview with total instances, active peers, network health
- **Instance Cards** - Each daemon displayed with real-time metrics
- **Command Bar** - Quick access to "Import Artifact" and "New Instance"
- **Alerts Rail** - System notifications and events

### Creating Your First Instance

1. **Import Artifact (Optional but Recommended)**
   - Click "IMPORT ARTIFACT" in command bar
   - Choose "Import from GitHub"
   - Select latest release (e.g., `v2025-11-03-rc2`)
   - Wait for download (~20GB blockchain + ~500MB binaries)
   - Benefit: Pre-synced blockchain means you start at recent block height

2. **Create Instance**
   - Click "NEW INSTANCE"
   - **Implementation:** Choose Garbageman or Knots
   - **Network:** mainnet, testnet, signet, or regtest
   - **Ports:** Auto-assigned or specify custom
   - **Tor Settings:** Configure .onion service
   - Click "CREATE"

3. **Start & Monitor**
   - Click "START" on your instance card
   - Watch real-time sync progress
   - Monitor peer connections, block height, sync status

### Peer Discovery Features

Click "VIEW PEERS" to open peer discovery dialog with three tabs:

**Clearnet Peers:**
- Discovered via DNS seeds (IPv4/IPv6)
- Filter by: All, Libre Relay, Core v30+
- Shows: IP, port, user agent, service bits
- Real-time discovery

**Tor Peers:**
- Discovered via Tor network (.onion addresses)
- Uses Libre Relay's seed list (~512 .onion + ~495 IPv6 + ~512 I2P seeds)
- All connections via Tor SOCKS5 proxy (no IP exposure)
- Filter by: All, Libre Relay
- Shows: .onion address, user agent, connection success

**Seeds Checked:**
- Tracks all seed connection attempts
- Shows: Success/failure, peers returned, timestamp
- Useful for debugging bootstrap issues

**Privacy note:** All Tor peer discovery routes through SOCKS5 proxy. Your real IP is never exposed to any peer.

### Artifact Management

**Import from GitHub:**
- Fetches latest releases from repository
- Downloads in modular format (blockchain + binaries separate)
- Verifies all checksums automatically
- Extracts and prepares for use

**Import from File:**
- For custom artifacts you've built from the TUI
- Supports modular export format
- Verifies integrity via SHA256SUMS

### Instance Monitoring

Each instance card shows:

- **Status:** Up, down, syncing, error
- **Block Height:** Current vs. network height
- **Sync Progress:** Percentage complete during blockchain sync
- **Peers:** Total count and breakdown by type
- **Peer Breakdown:** Shows counts of Libre Relay, Knots, Core v30+, etc.
- **Actions:** Start, stop, view logs, delete

**Real-time updates:**
- Dashboard refreshes every few seconds
- No manual refresh needed
- WebSocket connection for live events

### Configuration

**Instances:**
- Each instance is isolated with its own data directory
- Configuration stored in `envfiles/instances/<instance-id>.env`
- Logs available via WebUI or `docker logs`

**System:**
- Global settings in `envfiles/GLOBAL.env`
- Tor proxy configuration
- API server settings

---

## 🛠️ TUI Script Usage Guide

The TUI script (`garbageman-nm.sh`) is a bash-based menu system for production deployment and artifact generation.

### First Run: Choose Deployment Mode

On first run, you'll choose between:

**Containers (Recommended):**
- Uses Docker or Podman
- Lightweight, fast startup
- Lower resource overhead
- Easy to manage and update

**Virtual Machines:**
- Uses libvirt/qemu-kvm
- Complete OS isolation
- Stable, proven approach
- Slightly higher overhead

**This choice is locked** after you create your first base instance.

### Typical Workflow

**For Artifact Generation (Release Managers):**

1. **Create Base** (Option 1) → Build from Scratch
   - Choose implementation (Garbageman or Knots)
   - Compiles from source (~2 hours)
   - Creates base container/VM

2. **Monitor Sync** (Option 2)
   - Syncs blockchain (~24-48 hours)
   - Live progress display
   - Auto-adjusts resources

3. **Export Artifact** (Option 3) → Manage Base → Export
   - Creates modular export (blockchain + binaries)
   - Splits into GitHub-compatible parts (<2GB each)
   - Generates SHA256SUMS
   - Ready for GitHub release

**For Container/VM Deployment (Production Operators):**

1. **Configure** (Option 7) - Optional, adjust defaults
2. **Create Base** (Option 1) - Import from GitHub or build
2. **Monitor Sync** (Option 2) - Wait for blockchain sync to complete
3. **Create Clones** (Option 4) - Make redundant copies
5. **Start Clones** (Option 5) - Launch your node fleet

### Menu Options Explained

#### Option 1: Create Base Container/VM
- **Import from GitHub** - Download pre-built artifacts (minutes)
- **Import from File** - Use local export folder (minutes)
- **Build from Scratch** - Compile from source (2+ hours)
- Choose implementation: Garbageman or Knots

#### Option 2: Monitor Base Sync
- Live auto-refreshing blockchain sync progress display
- Shows: block height, peers by type, sync percentage
- Detects Libre Relay nodes in peer connections
- Can exit anytime (instance keeps running)
- Auto-resizes resources when sync completes

#### Option 3: Manage Base
- **Start/Stop** - Control base instance
- **Status** - View .onion address and block height
- **Export** - Create modular artifacts for distribution
  - Blockchain data (~20GB, split into parts)
  - Container/VM image (~500MB-1GB)
  - Both implementations' binaries included
  - SHA256 checksums for integrity
  - Removes sensitive data (Tor keys, logs, peer DB)

#### Option 4: Create Clones
- Copies synced blockchain from base
- Each clone gets unique .onion address
- Forced to Tor-only (maximum privacy)
- Fast: 1-2 minutes per clone
- Names include timestamp for identification

#### Option 5: Manage Clones
- Start/stop individual clones
- Monitor status and sync progress
- View .onion addresses
- Delete clones when no longer needed

#### Option 6: Capacity Suggestions
- Shows CPU, RAM, and disk capacity
- Calculates maximum clones possible
- Identifies limiting resource

#### Option 7: Configure Defaults
- **Host Reserves** - Resources kept for system
- **Runtime Resources** - Per-instance allocation
- **Clearnet Option** - Allow clearnet on base (clones always Tor-only)

### Resource Management

**Three-phase model:**

1. **Build** (2+ hours, one-time)
   - Uses sync allocation
   - More CPU = faster compilation

2. **Initial Sync** (24-48 hours, one-time)
   - Configurable resources
   - More resources = faster sync
   - Default: all available after reserves

3. **Runtime** (ongoing)
   - Lower footprint per instance
   - Default: 1 core, 2GB RAM per node
   - Scales based on system capacity

### Exporting Artifacts for GitHub Releases

The TUI script creates modular exports optimized for GitHub releases:

**Export format:**
```
gm-export-YYYYMMDD-HHMMSS/
├── bitcoin-cli
├── bitcoind
├── blockchain.tar.gz.part01 (1.9GB)
├── blockchain.tar.gz.part02 (1.9GB)
├── blockchain.tar.gz.part03 (1.9GB)
├── ... (8-12 parts total, ~20GB)
├── container-image.tar.gz (200MB) OR vm-image.tar.gz (400MB)
├── SHA256SUMS (checksums for all files)
└── MANIFEST.txt (assembly instructions)
```

**Benefits:**
- All parts under 2GB (GitHub limit)
- Blockchain shared across releases
- Can update images without re-uploading blockchain
- Integrity verified via checksums
- Both implementations included

**See [RELEASE_GUIDE.md](RELEASE_GUIDE.md) for complete release creation process.**

### VirtualBox Optimization (Optional)

If running the TUI script inside a VirtualBox VM (sandboxing recommended):

**Critical settings:**
- **Enable Nested VT-x/AMD-V** (for VM mode) or disable (for Container mode)
- **Paravirtualization Interface:** KVM (VM mode) or Default (Container mode)
- **VirtIO SCSI controller** with Host I/O Cache
- **virtio-net network adapter**
- **Minimum:** 8GB RAM, 4 cores, 80GB disk

See the TUI section below for complete VirtualBox optimization guide.

---

## 🔒 Privacy & Security Features

### WebUI Security

**Authentication:**
- JWT-based authentication for all API endpoints
- Server-side password validation with rate limiting
- Support for wrapper-provided passwords (Start9/Umbrel via `WRAPPER_UI_PASSWORD`)
- Auto-generated secure passwords for standalone deployments
- 24-hour token expiration with automatic re-authentication
- See [`docs/AUTHENTICATION.md`](docs/AUTHENTICATION.md) for details

**RPC Credentials:**
- Auto-generated unique credentials per Bitcoin instance
- Cryptographically secure 256-bit passwords
- No hardcoded credentials in codebase
- Wrapper support via environment variables

**Tor Integration:**
- All .onion peer discovery via SOCKS5 proxy
- No clearnet IP exposure during Tor discovery
- Multiple validation layers prevent clearnet leaks
- Null IP addresses in protocol messages (0.0.0.0)

**Network Isolation:**
- Each daemon instance runs in isolated environment
- Separate data directories per instance
- Docker networking provides namespace isolation

**Data Protection:**
- Designed for both trusted local and remote deployments
- For remote access over internet, use TLS/HTTPS (see below)
- Session tokens stored in browser sessionStorage (cleared on close)

**TLS/HTTPS:**
- Optional Caddy reverse proxy for standalone deployments
- Automatic Let's Encrypt certificates for production domains
- Self-signed certificates for local/internal use
- See [`docs/TLS_SETUP.md`](docs/TLS_SETUP.md) for configuration
- **Note:** Wrapper deployments (Start9/Umbrel) handle TLS at their layer

**Input Validation:**
- JSON schema validation on all API endpoints
- Path traversal protection for instance IDs
- Command injection prevention via safe process spawning
- Rate limiting (1000 requests/minute per IP)

**Privacy Protection:**
- Blockchain artifacts automatically cleaned of identifying data
- Removes Tor keys, peer databases, port configurations
- Prevents IP/identity leakage across instances

### TUI Script Security

**Tor-Only Clones:**
All clones created by TUI script are forced to Tor-only:

```
onlynet=onion          # Only connect to .onion addresses
listen=1               # Accept incoming connections
listenonion=1          # Via Tor hidden service only
discover=0             # No local network peer discovery
dnsseed=0              # No DNS seed queries
proxy=127.0.0.1:9050   # All traffic through Tor SOCKS proxy
```

This ensures **complete Tor isolation** - no clearnet IP exposure.

**Base Container/VM:**
- Can optionally use Tor + clearnet (faster initial sync)
- Configurable via CLEARNET_OK setting
- Clones always Tor-only regardless of base setting

**SSH Keys (VMs only):**
- Temporary monitoring key stored in `~/.cache/gm-monitor/`
- Used only for polling bitcoin-cli RPC
- Isolated from your personal SSH keys

**Network Isolation (Container Mode):**
- Bridge networking (not host mode)
- Each container has isolated network namespace
- Base can expose port 8333 if CLEARNET_OK=yes
- Clones never expose ports (always Tor-only)
- Prevents conflicts, improves security

**Export Security:**
- All sensitive data removed from exports
- Tor private keys regenerated on import
- SSH keys not included
- Peer database and logs cleared
- Clean state for distribution

---

## 📊 Architecture

### WebUI Architecture

```
┌─────────────────────────────────────────────┐
│  Browser (localhost:5173)                   │
│  - React + TypeScript + Tailwind            │
│  - Real-time WebSocket connection           │
└──────────────────┬──────────────────────────┘
                   │ HTTP/WS
                   ▼
┌─────────────────────────────────────────────┐
│  API Server (localhost:8080)                │
│  - Express + TypeScript                     │
│  - Peer discovery services                  │
│  - Artifact management                      │
│  - Event streaming                          │
└──────────────────┬──────────────────────────┘
                   │ HTTP
                   ▼
┌─────────────────────────────────────────────┐
│  Multi-Daemon Supervisor (localhost:9000)   │
│  - Instance lifecycle management            │
│  - Process spawning/monitoring              │
│  - Configuration management                 │
└──────────────────┬──────────────────────────┘
                   │ spawn/exec
                   ▼
┌─────────────────────────────────────────────┐
│  Bitcoin Daemons (dynamic ports)            │
│  - Garbageman / Knots implementations       │
│  - Real P2P network connections             │
│  - Blockchain storage and validation        │
└─────────────────────────────────────────────┘

          All containers run on Docker/Podman
          Tor proxy service provides SOCKS5
```

### TUI Script Architecture

```
┌─────────────────────────────────────────────┐
│  garbageman-nm.sh (Bash TUI)                │
│  - Menu system and user interaction         │
│  - Resource calculation and validation      │
│  - Deployment orchestration                 │
└──────────────────┬──────────────────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
        ▼                     ▼
┌──────────────┐      ┌──────────────┐
│  Docker/     │      │  libvirt/    │
│  Podman      │      │  qemu-kvm    │
│  (Containers)│      │  (VMs)       │
└──────┬───────┘      └──────┬───────┘
       │                     │
       ▼                     ▼
┌─────────────────────────────────────────────┐
│  Base Instance (gm-base)                    │
│  - Alpine Linux OS                          │
│  - Garbageman or Knots daemon               │
│  - Tor hidden service                       │
│  - Full blockchain validation               │
└──────────────────┬──────────────────────────┘
                   │ clone
                   ▼
┌─────────────────────────────────────────────┐
│  Clones (gm-clone-*)                        │
│  - Copies of synced base                    │
│  - Unique .onion addresses                  │
│  - Tor-only networking                      │
│  - Independent peer connections             │
└─────────────────────────────────────────────┘
```

---

## 🌐 Deployment Scenarios

### Personal Servers (Start9, Umbrel)

**WebUI designed for the self-sovereign individual:**

- **Docker-based** - Standard containerization
- **Web interface** - No desktop environment needed
- **Privacy-first** - Tor integration built-in

**Platform integration:**
- Package as platform-specific app
- Expose WebUI via platform's app interface
- Leverage platform's Tor proxy if available
- Use platform's storage management

### Traditional Servers

**For VPS/dedicated servers:**

- Use WebUI for management interface
- Deploy via Docker Compose
- Configure reverse proxy (nginx/caddy) for HTTPS
- Set up SSH tunnel for secure remote access

**Production deployment:**
```bash
# 1. Clone and configure
git clone https://github.com/paulscode/garbageman-nm.git
cd garbageman-nm/devtools

# 2. Adjust environment variables
cp ../envfiles/GLOBAL.env ../envfiles/GLOBAL.env.local
# Edit GLOBAL.env.local with your settings

# 3. Start services
make up

# 4. Access via SSH tunnel
# From your local machine:
ssh -L 5173:localhost:5173 user@your-server
# Then open http://localhost:5173
```

### Development Environment

**For developers building on the API:**

```bash
# Run individual services locally
cd webui/api
npm install
npm run dev  # API on :8080

cd webui/ui
npm install
npm run dev  # UI on :5173

cd multi-daemon
npm install
npm run dev  # Supervisor on :9000
```

**Hot reload enabled** for rapid development.

---

## 🎛️ Advanced TUI Configuration

### Containers vs VMs: Detailed Comparison

#### Containers (Docker/Podman) - Recommended

**Pros:**
- **Lower overhead** - Shared kernel, minimal memory footprint
- **Faster operations** - Seconds to start/stop vs minutes for VMs
- **Efficient cloning** - Copy-on-write storage, shared base images
- **Easy management** - Standard Docker/Podman CLI tools
- **Better integration** - Works well with modern orchestration

**Cons:**
- **Less isolation** - Shares host kernel (security consideration)
- **Requires container runtime** - Docker or Podman must be installed

**Resource usage:**
- ~2GB RAM per instance after sync
- ~150MB overhead per container (runtime daemon)
- ~25GB disk per instance (sparse allocation)

#### Virtual Machines (libvirt/qemu) - Legacy

**Pros:**
- **Complete isolation** - Full OS per VM, own kernel
- **Proven stability** - Mature virtualization technology
- **Works with existing tools** - libvirt/virt-manager ecosystem

**Cons:**
- **Higher overhead** - ~200MB RAM per VM for hypervisor
- **Slower operations** - Minutes to start/clone VMs
- **More complex** - Requires nested virtualization in VirtualBox
- **Legacy approach** - Containers now preferred

**Resource usage:**
- ~2GB RAM per instance after sync
- ~200MB overhead per VM (QEMU/KVM, page tables)
- ~25GB disk per instance (qcow2 format)

### Running TUI Script in VirtualBox

For sandboxing, run the TUI script inside a VirtualBox VM.

#### Essential VirtualBox Settings

**System → Motherboard:**
- ✅ Enable I/O APIC (required for multi-core)
- **Base Memory:** 8192 MB minimum (16384+ recommended)

**System → Processor:**
- ✅ Enable PAE/NX (required for 64-bit)
- **Nested VT-x/AMD-V:**
  - ✅ Enable for VM mode (required for nested virtualization)
  - ❌ Disable for Container mode (reduces overhead)
- **Processors:** 4 minimum (8+ recommended)
- **Execution Cap:** 100% (don't throttle)

**System → Acceleration:**
- **Paravirtualization Interface:**
  - **KVM** for VM mode (best nested virt performance)
  - **Default** for Container mode (better compatibility)

**Storage:**
- Use **VirtIO SCSI** controller (not SATA/IDE)
- ✅ Enable "Use Host I/O Cache" (significant performance boost)
- **Disk type:** Fixed size VDI recommended (80+ GB)

**Network → Adapter 1:**
- **Adapter Type:** Paravirtualized Network (virtio-net)
- **Attached to:** NAT or Bridged

**Display:**
- **Video Memory:** 16 MB minimum (graphics don't matter)
- ❌ Disable 3D Acceleration (can cause issues)

**Audio:**
- ❌ Disable Audio (not needed, saves resources)

#### Verifying Nested Virtualization (VM Mode)

Inside your Linux Mint guest VM:

```bash
# Check /dev/kvm exists
ls -la /dev/kvm
# Should show: crw-rw---- 1 root kvm ... /dev/kvm

# Check CPU virtualization extensions
egrep -c '(vmx|svm)' /proc/cpuinfo
# Should show number > 0

# Verify KVM module loaded
lsmod | grep kvm
# Should show: kvm_intel or kvm_amd
```

If these checks fail:
1. Ensure **Nested VT-x/AMD-V** enabled in VirtualBox settings
2. Power off VM completely (not just shutdown) and restart
3. Verify your host BIOS has VT-x/AMD-V enabled

### Environment Variable Overrides

Customize TUI script behavior:

```bash
# Container mode
CONTAINER_NAME=my-node ./garbageman-nm.sh
CONTAINER_RUNTIME_CPUS=2 CONTAINER_RUNTIME_RAM=4096 ./garbageman-nm.sh

# VM mode
VM_NAME=my-node ./garbageman-nm.sh
VM_VCPUS=2 VM_RAM_MB=4096 VM_DISK_GB=50 ./garbageman-nm.sh

# Force Tor-only
CLEARNET_OK=no ./garbageman-nm.sh

# Custom Garbageman branch
GM_BRANCH=my-custom-branch ./garbageman-nm.sh
```

---

## ❓ Frequently Asked Questions

### General Questions

**Q: Should I use the WebUI or TUI script?**

A: **WebUI** for most users - modern interface, easier to use, designed for embedded platforms. **TUI script** for building releases, generating artifacts, or VM/container-based deployments.

**Q: Can I use both WebUI and TUI script?**

A: Yes, but they manage instances independently. WebUI instances are daemons within a single container. TUI script creates separate Docker containers or VMs. They don't interfere with each other.

**Q: Which is better: Garbageman or Bitcoin Knots?**

A: **Garbageman** to fight on the front lines in the spam war. **Knots** for sane, common-sense anti-spam policy.

### WebUI Questions

**Q: How do I access the WebUI remotely?**

A: Use SSH tunnel for security:
```bash
ssh -L 5173:localhost:5173 user@your-server
```
Then open http://localhost:5173 on your local machine.

**Q: How do I update the WebUI?**

A:
```bash
cd garbageman-nm/devtools
make down
git pull
make rebuild
```

**Q: Where are instance data stored?**

A: Each instance gets its own data directory:
- Config: `envfiles/instances/<instance-id>.env`
- Blockchain: Docker volumes or configured data paths
- Logs: Via `docker logs <container-id>`

### TUI Script Questions

**Q: How much disk space does each instance use?**

A: ~25GB per instance (pruned blockchain + OS). Format uses sparse allocation, so it only consumes space it needs.

**Q: Can I transfer instances between computers?**

A: Yes, use the export feature (Option 3 → Manage Base → Export). Creates modular format with blockchain + image + checksums.

**Q: How do I view an instance's .onion address?**

A: Use menu options (Option 3 for base, Option 5 for clones). Or manually:
```bash
# VMs
ssh root@<VM_IP> cat /var/lib/tor/bitcoin-service/hostname

# Containers
docker exec gm-base cat /var/lib/tor/bitcoin-service/hostname
```

**Q: What if I run out of resources?**

A: The script prevents over-allocation and shows capacity suggestions. To expand capacity: reduce per-instance resources (Option 7), upgrade hardware, or stop unneeded instances.

**Q: Can I access the VM console?**

A: Yes:
```bash
virsh console gm-base
# Login: root
# Password: garbageman
# Press Ctrl+] to exit
```

For containers, use exec:
```bash
docker exec -it gm-base sh
```

### Peer Discovery Questions

**Q: How does Tor peer discovery work?**

A: The system loads seed addresses from Libre Relay's node list (~512 .onion + ~495 IPv6 + ~512 I2P), connects via Tor SOCKS5 proxy, performs Bitcoin P2P handshake, requests peer addresses (getaddr), and filters for .onion addresses to save. IPv6 seeds are used as fallback for bootstrap (via Tor exit nodes), but only .onion addresses are persisted. All connections via Tor - your real IP is never exposed.

**Q: Why do I see IPv6 addresses in seed list?**

A: Seeds include .onion, IPv6 (CJDNS), and I2P addresses. IPv6 seeds are used as fallback for initial bootstrap (via Tor exit nodes). Only .onion addresses are saved to database.

**Q: How can I verify Tor connections?**

A:
```bash
# Monitor Tor proxy connections
sudo ss -tunap | grep 9050

# Check for clearnet Bitcoin leaks (should be empty)
sudo tcpdump -i any -n 'port 8333 and not host 127.0.0.1'
```

**Q: What is Libre Relay detection?**

A: The system identifies Libre Relay nodes by checking service bit 29 (0x20000000). This helps track how many spam-relaying nodes are on the network.

---

## 🐛 Troubleshooting

### WebUI Issues

**Services won't start:**
```bash
cd devtools
make logs  # Check all service logs

# Check individual services
make ui
make api
make supervisor
make tor
```

**Can't connect to API:**
```bash
# Verify API is running
curl http://localhost:8080/api/health

# Check Docker network
docker network ls
docker network inspect garbageman-network
```

**Peer discovery not working:**
```bash
# Check Tor proxy status
curl http://localhost:8080/api/peers/tor/status

# Verify Tor container
docker logs gm-tor-proxy

# Test Tor connectivity
curl --socks5 localhost:9050 http://check.torproject.org
```

### TUI Script Issues

**Container/VM won't start:**

For containers:
```bash
# Check Docker/Podman
sudo systemctl status docker
docker logs gm-base

# Verify container exists
docker ps -a | grep gm
```

For VMs:
```bash
# Check libvirt
sudo systemctl status libvirtd

# Verify default network
virsh net-list --all
virsh net-start default

# Check VM console
virsh console gm-base
```

**Sync stuck at 0%:**

Verify bitcoind is running:
```bash
# Containers
docker exec gm-base ps aux | grep bitcoind
docker exec gm-base tail -f /var/lib/bitcoin/debug.log

# VMs
ssh root@<VM_IP> ps aux | grep bitcoind
ssh root@<VM_IP> tail -f /var/lib/bitcoin/debug.log
```

Check network connectivity:
```bash
# Containers
docker exec gm-base ping -c 3 8.8.8.8

# VMs
ssh root@<VM_IP> ping -c 3 8.8.8.8
```

**Build failed during compilation:**

Check resources and retry:
```bash
# Need at least 2GB RAM free
free -h

# Clean and start fresh
# Containers
docker stop gm-base; docker rm gm-base
docker volume rm garbageman-data
docker system prune -f

# VMs
virsh undefine gm-base
sudo rm -f /var/lib/libvirt/images/gm-base.qcow2

# Try again
./garbageman-nm.sh
```

**Tor not starting in container:**

Likely caused by old host networking mode. Recreate with bridge networking:
```bash
docker rm -f gm-base
docker volume rm garbageman-data
./garbageman-nm.sh
# Re-import or rebuild
```

Verify Tor works:
```bash
docker exec gm-base ps aux | grep tor
docker exec gm-base cat /var/lib/tor/bitcoin-service/hostname
```

### Diagnostic Tools

**For TUI base instances:**
```bash
./devtools/diagnose-gm-base.sh
```

Checks:
- Instance power state and IP
- Network connectivity
- SSH access (VMs) / exec access (containers)
- Required binaries (bitcoind, tor)
- Running processes and services
- Data directory structure
- Blockchain sync status

**For WebUI:**
```bash
cd devtools
make logs  # All services
```

---

## 📚 Documentation

- **[QUICKSTART.md](QUICKSTART.md)** - Quick start guide for WebUI
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - How to contribute to the project
- **[docs/TOR_PEER_DISCOVERY.md](docs/TOR_PEER_DISCOVERY.md)** - Tor peer discovery technical details
- **[RELEASE_GUIDE.md](RELEASE_GUIDE.md)** - Creating GitHub releases with TUI script
- **[webui/README.md](webui/README.md)** - WebUI architecture documentation
- **[webui/api/README.md](webui/api/README.md)** - API documentation
- **[multi-daemon/README.md](multi-daemon/README.md)** - Supervisor documentation

---

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Code style guidelines (TypeScript, React, Bash)
- Testing requirements
- Pull request process
- Component-specific guidelines

**Quick start for contributors:**
```bash
git clone https://github.com/paulscode/garbageman-nm.git
cd garbageman-nm/devtools
make up
# Start developing!
```

---

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- **Garbageman:** Bitcoin Knots fork by [Chris Guida](https://github.com/chrisguida)
- **Bitcoin Knots:** Bitcoin Core fork by [Luke Dashjr](https://github.com/luke-jr)
- **Libre Relay:** By [Peter Todd](https://github.com/petertodd) - though we're fighting spam, we respect the technical implementation
- **Alpine Linux:** Lightweight OS for containers and VMs
- **Tor Project:** Privacy layer enabling .onion hidden services
- **Start9 & Umbrel:** Inspiration for embedded platform design

---

## ⚠️ Disclaimer

This is experimental software. Use at your own risk. Always keep backups of important data.

Running Bitcoin nodes requires significant resources and bandwidth. Ensure you understand the implications before running multiple nodes.

The Garbageman implementation is designed to combat blockchain spam. While effective, it operates in a gray area of network policy. Use responsibly and understand the technical and ethical implications.

---

## 🔗 Links

- **Repository:** [github.com/paulscode/garbageman-nm](https://github.com/paulscode/garbageman-nm)
- **Garbageman Source:** [github.com/chrisguida/bitcoin](https://github.com/chrisguida/bitcoin)
- **Bitcoin Knots:** [bitcoinknots.org](https://bitcoinknots.org)
- **Issues:** [github.com/paulscode/garbageman-nm/issues](https://github.com/paulscode/garbageman-nm/issues)

---

**Questions? Issues? Ideas?** Open a GitHub issue or join the discussion!

**Happy noding! 🚀☢️**
