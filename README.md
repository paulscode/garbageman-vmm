# Garbageman Nodes Manager

**Easy (hopefully!) setup for running multiple Bitcoin Garbageman nodes**

Run as many Garbageman (a Bitcoin Knots fork) nodes as your computer can handle, each with its own Tor hidden service for maximum privacy. Choose between **Containers** (Docker/Podman) for lightweight efficiency or **Virtual Machines** (VMs) for greater stability on some systems.

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/6af100e5-c873-4c26-b848-6a5ecdf17dbc" />


![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20Mint%2022.2-green.svg)

---

## 🎯 What This Does

This script makes it **dead simple** (in theory) to:

- ✅ Create a lightweight Bitcoin Garbageman node in a container **or** VM
- ✅ Choose between Containers (lightweight, faster) or VMs (more stable on some systems)
- ✅ Monitor the Initial Block Download (IBD) sync with a live progress display
- ✅ Clone your synced node multiple times for redundancy
- ✅ Each clone gets its own unique Tor `.onion` address (privacy-first!)
- ✅ Export and transfer containers/VMs securely between systems
- ✅ Automatically manage resources (CPU/RAM/Disk) so your system stays responsive

**No manual configuration needed** - the script handles everything from building the software to setting up Tor networking.

<img width="1024" height="1255" alt="image" src="https://github.com/user-attachments/assets/18410a85-0616-4c2d-9025-50d1cdb32433" />


---

## �🚀 Quick Start

### 1. Download the Script

```bash
sudo apt-get install -y git
cd ~
git clone https://github.com/paulscode/garbageman-nm.git
```

### 2. Run It!

```bash
cd ~/garbageman-nm && git pull && ./garbageman-nm.sh
```

That's it! The script will:
1. Install any missing dependencies (asks for your password once)
2. Show you a menu with clear options
3. Guide you through each step

---

> **📝 Note:** This project was recently renamed from `Garbageman VM Manager` to `Garbageman Nodes Manager`. If you have used the tool before this change, rename your local folder so the above "Run It" command works:
> ```bash
> mv ~/garbageman-vmm ~/garbageman-nm
> cd ~/garbageman-nm
> git remote set-url origin https://github.com/paulscode/garbageman-nm.git
> ```

---

## 🆚 Containers vs VMs: Which Should You Choose?

### Containers (Recommended)
**Best for:** Users who want efficiency and faster operations

✅ **Pros:**
- Lower resource overhead
- Faster startup (seconds vs minutes)
- Faster cloning operations
- More efficient disk space usage (shared base image)
- Works with Docker or Podman

❌ **Cons:**
- Requires Docker or Podman installed
- Less isolation than VMs (shares host/sandbox kernel)

**Resource Usage:**
- ~2GB RAM per node after sync
- ~150MB overhead per container (runtime daemon)

### Virtual Machines (Legacy)
**Best for:** Users who have experience instability with containers

✅ **Pros:**
- Complete isolation from host/sandbox
- Works with existing VM management tools
- Full OS environment inside VM

❌ **Cons:**
- Higher resource overhead (~200MB per VM)
- Slower startup times
- Requires nested virtualization if running in VirtualBox sandbox

**Resource Usage:**
- ~2GB RAM per node after sync
- ~200MB overhead per VM (hypervisor, page tables)

### Quick Decision Guide

**Choose Containers if you:**
- Want to maximize efficiency
- Need faster startup and cloning
- Have experience with Docker/Podman

**Choose VMs if you:**
- Experience instability with containers
- Have experience with libvirt/qemu

**Note:** The script auto-detects which mode you're using based on whether you've created a container or VM. You only choose once!

## 💻 Requirements

### Minimum System
- **OS:** Linux Mint 22.2 Cinnamon (or Ubuntu 24.04-based distros)
- **CPU:** 4 cores (2 cores + 2 reserved for host/sandbox)
- **RAM:** 8 GB (4 GB + 4 GB reserved for host/sandbox)
- **Disk:** 50 GB free space (25 GB per container/VM, uses sparse allocation)
- **Internet:** Broadband connection for blockchain sync

### Recommended System
- **CPU:** 8+ cores
- **RAM:** 16+ GB
- **Disk:** 100+ GB free space (more = more clones possible)
- **Faster CPU = faster initial blockchain sync**

### What Gets Installed

**For Container Mode:**
- Container runtime: `docker` OR `podman` (script auto-detects which is available)
- Build tools: `git` (only if building from scratch)
- Utilities: `jq`, `dialog`, `whiptail`

**For VM Mode:**
- Virtualization: `qemu-kvm`, `libvirt-daemon-system`, `libvirt-clients`, `virtinst`, `libguestfs-tools`
- Build tools: `git`, `cmake`, `gcc`
- Utilities: `jq`, `dialog`, `whiptail`

**All dependencies are installed automatically** when you first run the script.

---

## � Running in VirtualBox

I recommend running this script **inside a VirtualBox VM** with a Linux Mint 22.2 guest, so that it is sandboxed from the rest of your computer.  This section explains how to optimize VirtualBox for running containers or VMs inside of a VM.

### Why VirtualBox Performance Matters

This script performs CPU and I/O intensive operations:
- **Compilation:** Building Bitcoin software (30+ minutes of heavy CPU use)
- **Container operations:** Building Docker images and managing container volumes
- **Nested Virtualization (VM mode):** Creates Alpine VMs inside your Linux Mint VM using libguestfs/KVM
- **Blockchain Sync:** Downloads and validates 25+ GB of blockchain data with constant disk I/O

Without proper VirtualBox configuration, these operations can be 3-5x slower than native performance.

### Guest OS Recommendation

**Use Linux Mint 22.2 Cinnamon Edition** for the guest OS:
- Based on Ubuntu 24.04 LTS (excellent hardware support)
- Cinnamon desktop is lightweight and responsive
- All required packages are available in the default repositories
- Well-tested with this script

**Download:** [linuxmint.com/download.php](https://linuxmint.com/download.php)

### Essential VirtualBox Settings

These settings are **critical** for acceptable performance, and can be edited in the Settings once the VM has been created (shut down the VM first if it is running).

#### 1. System Settings (Settings → System)

**Motherboard Tab:**
- ✅ **Enable I/O APIC:** Required for multi-core support
- Set **Base Memory** to at least 8192 MB (8 GB minimum, 16+ GB recommended)

**Processor Tab:**
- ✅ **Enable PAE/NX:** Required for 64-bit Linux
- **Nested VT-x/AMD-V:** 
  - **(for VM mode):** ✅ **Enable** - Required for nested virtualization (VMs inside a VM)
  - **(for Container mode):** ❌ **Disable** - Reduced overhead
- Set **Processor(s)** to at least 4 cores (8+ recommended)
- Set **Processing Cap** to 100% (ensure VM isn't throttled)

**Acceleration Tab:** _(if page blanks, open General Tab then come back)_
- **Paravirtualization Interface:**
  - **(for VM mode):** Set to **KVM** (best performance for nested virtualization)
  - **(for Container mode):** Set to **Default** (may have better compatibility)

#### 2. Storage Settings (Settings → Storage)

**Use VirtIO SCSI Controller for Best I/O Performance:**

1. Click the **"Add Controller"** icon → Select **"VirtIO SCSI"**
2. Remove your virtual disk from under "Controller: SATA"
3. Attach your virtual disk to "Controller: VirtIO"
4. Under **Attributes:**
   - ✅ **Use Host I/O Cache:** Significantly improves disk performance

#### 3. Network Settings (Settings → Network)

**Adapter 1:**
- Attached to: **NAT** or **Bridged Adapter**
- Expand **Advanced** section
- Set **Adapter Type** to **Paravirtualized Network (virtio-net)** for best performance

#### 4. Display Settings (Settings → Display)

**Screen Tab:**
- Set **Video Memory** to minimum **16 MB** (this is a server workload, graphics don't matter)
- ❌ **Disable 3D Acceleration** (not needed, can cause issues)

#### 5. Audio Settings (Settings → Audio)

- ❌ **Disable "Enable Audio"** (not needed for server workloads, saves resources)

### Quick Configuration Checklist

Before running the script, verify these VirtualBox settings:

- [ ] **Nested VT-x/AMD-V enabled (for VM) or disabled (for container)** (System → Processor)
- [ ] **Paravirtualization Interface = KVM (for VM) or Default (for container)** (System → Acceleration)
- [ ] **VirtIO SCSI controller** with Host I/O Cache enabled (Storage)
- [ ] **virtio-net network adapter** (Network → Advanced)
- [ ] **I/O APIC enabled** (System → Motherboard)
- [ ] **PAE/NX enabled** (System → Processor)
- [ ] **Execution Cap = 100%** (System → Processor)
- [ ] At least **8 GB RAM** and **4 CPU cores** allocated
- [ ] At least **80 GB disk space** (fixed size VDI recommended)
- [ ] **3D acceleration disabled** (Display)
- [ ] **Audio disabled** (Audio)

### Verifying Nested Virtualization Works (VM Mode Only)

If you plan to use VM mode, verify that nested virtualization is working after starting your Linux Mint VM:

```bash
# Check if KVM is available
ls -la /dev/kvm
# Should show: crw-rw---- 1 root kvm ... /dev/kvm

# Check CPU virtualization extensions
egrep -c '(vmx|svm)' /proc/cpuinfo
# Should show a number > 0 (number of cores with virt extensions)

# Verify KVM kernel module is loaded
lsmod | grep kvm
# Should show: kvm_intel or kvm_amd (depending on your CPU)
```

If any of these checks fail:
1. Ensure **Nested VT-x/AMD-V** is enabled in VirtualBox settings
2. Power off the VM completely and restart it (settings only apply after full shutdown)
3. Check your host/sandbox BIOS has virtualization enabled (VT-x/AMD-V)

---

## 📖 Step-by-Step Usage

### Typical Workflow

### Typical Workflow

Here's the normal sequence most users follow:

1. **Choose:** First run selects deployment mode (Container or VM) - *one-time choice*
2. **Configure:** Configure Defaults (Option 7) - *optional, can use defaults*
3. **Create:** Create Base Container/VM (Option 1) - *2+ hours*
4. **Sync:** Monitor Base Sync (Option 2) - *24-28 hours, can pause/resume*
5. **Clone:** Create Clones (Option 4) - *1-2 minutes per clone*
6. **Start clones:** Manage Clones (Option 5) → Start each clone
7. **Daily use:** Use Options 3 and 5 to start/stop as needed

**💡 Pro tip:** Leave the base container/VM running so it remains synced, start/stop clones based on your resource needs.

---

### First Time Setup

#### Step 0: Choose Deployment Mode (First Run Only)

**On first run, the script will ask:** "Do you want to use Containers or Virtual Machines?"

- **Containers:** Recommended approach, lightweight (requires Docker or Podman)
- **Virtual Machines:** Legacy approach, more stable on some systems (requires libvirt/qemu-kvm)

**This choice is locked once you create your base** - the script will remember your choice for all future runs.

See the [Containers vs VMs](#-vms-vs-containers-which-should-you-choose) section above to help decide.

#### Step 1: Configure Your Preferences (Optional)

When you first run the script, you can optionally choose **"Configure Defaults"** from the menu to customize:

- **Host/Sandbox Reserves:** How many CPU cores, RAM, and disk space to keep available for your system (default: 2 cores, 4 GB RAM, 20 GB disk)
- **container/VM Runtime Resources:** How much CPU/RAM each instance uses after sync (default: 1 core, 2 GB per instance)
- **Clearnet Option:** Whether to allow clearnet connections on the base for faster initial sync (default: yes, clones are always Tor-only)

**Most users can skip this** and use the defaults!

**Note:** The script is intelligent about capacity:
- Calculates how many clones you can run based on CPU, RAM, **and disk space**
- Suggests clone counts that won't max out any resource
- Shows which resource (CPU/RAM/Disk) is limiting your capacity

#### Step 2: Create Base Container/VM

Choose **"Create Base Container/VM"** from the menu. You have three options:

**Option 1: Import from GitHub** (modular downloads, ~1-21GB - works for both containers and VMs!)
1. Fetches available releases from GitHub
2. Downloads components based on your choice:
   - **Container:** Downloads blockchain parts (~20GB) + container image (~500MB)
   - **VM:** Downloads blockchain parts (~20GB) + VM image (~1GB)
3. Automatically reassembles blockchain and verifies all checksums
4. Imports and combines blockchain with container/VM image
5. Ready to clone immediately!
6. Note: Blockchain will be slightly behind (hours/days old), but will catch up quickly

**Option 2: Import from File** (for transferring between your own machines)
1. Select a unified export folder from `~/Downloads/`
2. Supports unified modular format:
   - **Unified format:** Separate blockchain + container/VM image in single folder
3. Verify checksums automatically via SHA256SUMS
4. Import the pre-synced blockchain and image
5. Ready in minutes instead of days!
6. Works for both VMs and containers

**Option 3: Build from Scratch** (2+ hours compile, 24-28 hours sync)
1. Build Docker image (Containers) or download Alpine Linux base (VMs)
2. **Build Garbageman inside the container/VM** (typically takes 2+ hours, depending on your CPU)
3. Configure Tor and Bitcoin services
4. Create base instance ready to sync

**Container vs VM Build Differences:**
- **Containers:** Multi-stage Dockerfile build (faster, more efficient)
- **VMs:** Uses libguestfs to build inside Alpine VM (stable, proven approach)
- Both compile from the same Garbageman source code
- Both result in identical Bitcoin node behavior

**After creation, you'll be prompted for sync resources:**
- The script suggests using most of your available CPU/RAM for faster sync
- You can accept the defaults or adjust based on what else you're running

#### Step 3: Start Sync & Monitor

Choose **"Monitor Base Sync"** from the menu. This will:

1. **Prompt you to confirm/change resources** (in case you want different settings than creation time)
2. Start the container/VM with your chosen resources (or connect to it if already running)
3. Show a **live auto-refreshing progress display**:

   **For VMs:**
   ```
   ╔════════════════════════════════════════════════════════════════════════════════╗
   ║                     Garbageman IBD Monitor - 26% Complete                      ║
   ╠════════════════════════════════════════════════════════════════════════════════╣
   ║                                                                                ║
   ║  Host Resources:                                                               ║
   ║    Cores: 8 total | 2 reserved | 6 available                                   ║
   ║    RAM:   24032 MiB total | 4096 MiB reserved | 19936 MiB available            ║
   ║                                                                                ║
   ║  VM Status:                                                                    ║
   ║    Name: gm-base                                                               ║
   ║    IP:   192.168.122.44                                                        ║
   ║                                                                                ║
   ║  Bitcoin Sync Status:                                                          ║
   ║    Node Type: Libre Relay/Garbageman                                           ║
   ║    Blocks:   529668 / 921108                                                   ║
   ║    Progress: 26% (0.255699756115667)                                           ║
   ║    IBD:      true                                                              ║
   ║    Peers:    14 (2 LR/GM, 3 KNOTS, 1 OLDCORE, 7 COREv30+, 1 OTHER)             ║
   ║                                                                                ║
   ╠════════════════════════════════════════════════════════════════════════════════╣
   ║  Auto-refreshing every 5 seconds... Press 'q' to exit                          ║
   ╚════════════════════════════════════════════════════════════════════════════════╝
   ```

   **For Containers:**
   ```
   ╔════════════════════════════════════════════════════════════════════════════════╗
   ║                    Garbageman IBD Monitor - 26% Complete                       ║
   ╠════════════════════════════════════════════════════════════════════════════════╣
   ║                                                                                ║
   ║  Host Resources:                                                               ║
   ║    Cores: 8 total | 2 reserved | 6 available                                   ║
   ║    RAM:   24032 MiB total | 4096 MiB reserved | 19936 MiB available            ║
   ║                                                                                ║
   ║  Container Status:                                                             ║
   ║    Name:  gm-base                                                              ║
   ║    Image: garbageman:latest                                                    ║
   ║                                                                                ║
   ║  Bitcoin Sync Status:                                                          ║
   ║    Node Type: Libre Relay/Garbageman                                           ║
   ║    Blocks:   529668 / 921108                                                   ║
   ║    Progress: 26% (0.255699756115667)                                           ║
   ║    IBD:      true                                                              ║
   ║    Peers:    14 (2 LR/GM, 3 KNOTS, 1 OLDCORE, 7 COREv30+, 1 OTHER)             ║
   ║                                                                                ║
   ╠════════════════════════════════════════════════════════════════════════════════╣
   ║  Auto-refreshing every 5 seconds... Press 'q' to exit                          ║
   ╚════════════════════════════════════════════════════════════════════════════════╝
   ```

4. Auto-refresh every 5 seconds (no manual refresh needed)
5. When sync completes, automatically shut down and resize to runtime resources (VMs) or update limits (containers)

**⏰ How long does sync take?**
- With 8+ cores, >8 GB RAM: ~24 hours (depends on multiple factors)
- With 4+ cores <8 GB RAM: >48 hours
- You can stop and resume anytime - progress is saved!

**💡 Tip:** Press 'q' anytime to exit the monitor. The container/VM keeps running in the background, and you can reconnect later by choosing "Monitor Base Sync" again (it will detect the instance is already running and let you change resources if needed).

**Container Note:** Containers can be resized on-the-fly without restarting (uses `docker update` or `podman update`). VMs require shutdown/restart to change resources.

#### Step 4: Clone Your Synced Node

Once your base container/VM finishes syncing, you can create clones!

Choose **"Create Clones (gm-clone-*)"** from the menu:

1. Script shows how many clones your system can handle (based on CPU, RAM, **and disk space**)
2. Enter desired number of clones
3. If the base is running, it will automatically shut it down gracefully (ensures consistent data during clone)
4. Each clone:
   - **Copies the fully-synced blockchain** (no re-download!)
   - Gets a fresh Tor `.onion` address
   - Is **forced to Tor-only** (maximum privacy, even if base allows clearnet)
   - Uses minimal resources (1 core, 2 GB RAM by default)
   - Named with timestamp (e.g., `gm-clone-20251103-143022`)
5. After cloning completes, clones are left in stopped state - start them using **"Manage Clones"**

**Example:** On a 16 GB / 8-core / 100 GB disk system with defaults:
- Host/sandbox reserves: 2 cores, 4 GB RAM, 20 GB disk
- Available: 6 cores, 12 GB RAM, 80 GB disk
- Runtime per instance: 1 core, 2 GB RAM, 25 GB disk
- **CPU capacity:** 6 instances (6 cores / 1 core each)
- **RAM capacity:** 6 instances (12 GB / 2 GB each)
- **Disk capacity:** 3 instances (80 GB / 25 GB each)
- **Maximum clones:** 3 total (limited by disk space!)

**Container vs VM Cloning:**
- **Containers:** Copy data between volumes (~1 minute per clone, faster due to shared image)
- **VMs:** Use `virt-clone` to copy disk image (~2 minutes per clone)
- Both result in identical blockchain state and Tor isolation

---

## 🎛️ Menu Options Explained

### Main Menu

The script displays different menus depending on whether you're using Containers or VMs:

**Container Mode:**
```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│ Garbageman Container Manager                                                            │
│                                                                                         │
│ Deployment: Containers (docker)                                                         │
│ Host: 8 cores / 24032 MiB   |   Reserve: 2 cores / 4096 MiB                             │
│ Available after reserve: 6 cores / 19936 MiB                                            │
│ Base Container exists: Yes                                                              │
│                                                                                         │
│ Choose an action:                                                                       │
│                                                                                         │
│  1  Create Base Container (gm-base)                                                     │
│  2  Monitor Base Container Sync (gm-base)                                               │
│  3  Manage Base Container (gm-base)                                                     │
│  4  Create Clone Containers (gm-clone-*)                                                │
│  5  Manage Clone Containers (gm-clone-*)                                                │
│  6  Capacity Suggestions (host-aware)                                                   │
│  7  Configure Defaults (reserves, runtime, clearnet)                                    │
│  8  Quit                                                                                │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

**VM Mode:**
```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│ Garbageman Nodes Manager                                                                │
│                                                                                         │
│ Deployment: VMs (libvirt/qemu)                                                          │
│ Host: 8 cores / 24032 MiB   |   Reserve: 2 cores / 4096 MiB                             │
│ Available after reserve: 6 cores / 19936 MiB                                            │
│ Base VM exists: Yes                                                                     │
│                                                                                         │
│ Choose an action:                                                                       │
│                                                                                         │
│  1  Create Base VM (gm-base)                                                            │
│  2  Monitor Base VM Sync (gm-base)                                                      │
│  3  Manage Base VM (gm-base)                                                            │
│  4  Create Clone VMs (gm-clone-*)                                                       │
│  5  Manage Clone VMs (gm-clone-*)                                                       │
│  6  Capacity Suggestions (host-aware)                                                   │
│  7  Configure Defaults (reserves, runtime, clearnet)                                    │
│  8  Quit                                                                                │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

#### Option 1: Create Base Container/VM
- **When to use:** First time setup
- **What it does:** Creates your initial Garbageman node (container or VM)
- **Three methods:** Import from GitHub (both container and VM), Import from file, Build from scratch
- **Time:** Minutes (import) or 2+ hours (build from scratch)
- **Deployment choice:** Locked after first base is created
- **Modular imports:** New format separates blockchain from container/VM image for efficiency

#### Option 2: Monitor Base Sync
- **When to use:** After creating the base, to sync the blockchain
- **What it does:** Connects to the instance (starts it if stopped) and shows live auto-refreshing IBD progress
- **Time:** 24-28 hours (varies greatly, due to multiple factors)
- **Can be resumed:** Yes! Press Ctrl+C to exit monitor anytime (instance keeps running)
- **On completion:** Automatically shuts down and resizes to runtime resources (VMs) or updates limits (containers)
- **Container benefit:** Can resize RAM/CPU on-the-fly without restart

#### Option 3: Manage Base
- **When to use:** Simple start/stop/status controls for the base, or to export for transfer
- **What it does:** Power on/off the base instance, check status, or create a modular export
- **Shows when running:** Tor .onion address and current block height
- **Export feature (NEW MODULAR FORMAT):** 
  - Exports blockchain data separately (~20GB, split into GitHub-compatible 1.9GB parts)
  - Exports container/VM image separately (~500MB-1GB, without blockchain)
  - Both components have matching timestamps for easy reassembly
  - All files SHA256 checksummed for integrity verification
  - Removes all sensitive data: Tor keys, SSH keys, peer databases, logs
- **Export benefits:**
  - Smaller container/VM downloads (~1GB vs ~22GB)
  - Blockchain can be reused across multiple exports
  - Can update container/VM without re-exporting blockchain
  - All files under 2GB (GitHub release compatible)
- **Export location:** Components saved to `~/Downloads/`
- **Time:** Instant for start/stop/status; 10-30 minutes for export
- **Cleanup option:** Container mode includes orphaned volume cleanup

#### Option 4: Create Clones
- **When to use:** After base is fully synced
- **What it does:** Creates additional nodes with unique .onion addresses
- **Time:** 1-2 minutes per clone (containers slightly faster than VMs)
- **Blockchain re-sync:** No! Clones copy the synced data from base
- **Auto-shutdown:** Automatically stops base if running (graceful, ensures data consistency)
- **Capacity check:** Shows how many clones you can create (limited by CPU/RAM/Disk, whichever is most constrained)

#### Option 5: Manage Clones
- **When to use:** Control existing clones
- **What it does:** Start, stop, monitor, or delete clone instances
- **Shows when running:** Tor .onion address and current block height for each clone
- **Live monitor:** Real-time status updates every 5 seconds
- **Time:** Instant

#### Option 6: Capacity Suggestions (host/sandbox-aware)
- **When to use:** Planning how many nodes you can run
- **What it does:** Shows detailed resource breakdown and clone capacity
- **Displays:** CPU capacity, RAM capacity, Disk capacity, and which resource is limiting

#### Option 7: Configure Defaults (reserves, runtime, clearnet)
- **When to use:** Adjust how resources are allocated
- **What it does:** Reset to original host/sandbox-aware defaults or customize reserves, instance sizes, and clearnet option
- **Options:**
  - **Reset to Original Values:** Restores hardcoded defaults (2 cores, 4GB RAM, 20GB disk reserve; 1 vCPU/2GB RAM/25GB disk per instance)
  - **Choose Custom Values:** Fine-tune each setting individually
- **Applies to:** Both containers and VMs use the same settings for consistency

---

## 🔒 Privacy & Security Features

### Tor-Only Clones
All clones are **forced to Tor-only** networking, regardless of your clearnet setting:
- ✅ Every clone gets a unique `.onion` v3 address
- ✅ No clearnet connections (IP address never exposed to peers)
- ✅ All peer discovery happens over Tor
- ✅ Perfect for privacy-conscious node operators
- ✅ Each clone discovers its own independent peer set (no clustering)

**Clone Bitcoin Configuration:**
```
onlynet=onion          # Only connect to .onion addresses
listen=1               # Accept incoming connections
listenonion=1          # Via Tor hidden service only
discover=0             # No local network peer discovery
dnsseed=0              # No DNS seed queries (would leak to clearnet)
proxy=127.0.0.1:9050   # All traffic through Tor SOCKS proxy
```

This configuration ensures **complete Tor isolation** - no clearnet IP exposure.

### Base Container/VM Clearnet Option
The base container/VM can optionally use **Tor + clearnet** (configurable):
- **Why clearnet?** Faster initial sync with more peer options
- **After sync:** You can keep it or switch to Tor-only
- **Clones:** Always Tor-only regardless of base setting

### SSH Keys
The script uses a dedicated temporary SSH key for monitoring:
- Stored in: `~/.cache/gm-monitor/`
- Purpose: Poll `bitcoin-cli` RPC for sync progress
- Not your personal SSH keys (isolated and safe)

---

## 📊 Resource Management

### How Resources Are Allocated

The script uses a **three-phase resource model**:

#### Phase 1: Build (Temporary)
- **Duration:** 2+ hours (one-time)
- **Resources:** Uses your "sync" allocation
- **Why:** More CPU = faster compilation

#### Phase 2: Initial Sync (Temporary)
- **Duration:** 24-28 hours (one-time per base container/VM)
- **Resources:** You configure this (default: all available after reserves)
- **Why:** More resources = faster blockchain download

#### Phase 3: Runtime (Long-term)
- **Duration:** Forever (or until you stop the containers/VMs)
- **Resources:** Smaller footprint (default: 1 core, 2 GB per container/VM)
- **Why:** Pruned nodes don't need much after sync

### Example Resource Allocation

**System:** 16 GB RAM, 8 cores

**Defaults:**
```
Host/sandbox reserves: 4 GB RAM, 2 cores (for your desktop)
Available:             12 GB RAM, 6 cores (for containers/VMs)

Phase 2 (sync):   12 GB RAM, 6 cores (base container/VM only)
Phase 3 (runtime): 2 GB RAM, 1 core (per container/VM)

Capacity: 6 containers/VMs simultaneously (1 base + 5 clones)
```

**Adjustable in "Configure Defaults"!**

---

## ❓ Frequently Asked Questions

### Should I use "Monitor Base container/VM Sync" or "Manage Base container/VM"?

- **Monitor Base container/VM Sync (Option 2):** Use this when you want to watch the blockchain sync progress with a live updating display. Best for initial sync or checking sync status.
- **Manage Base container/VM (Option 3):** Use this for simple start/stop/status controls, or to export the container/VM for transfer to another system. Shows .onion address and current block height when running. Good for daily management and creating portable backups.

Both can start the container/VM, but Option 2 provides detailed monitoring while Option 3 is quicker for basic operations.

### How much disk space does each container/VM use?

- **Base container/VM after sync:** ~25 GB (pruned blockchain + OS)
- **Each clone:** ~25 GB (copy of base container/VM)
- **Format:** qcow2 with sparse allocation (only uses space it needs)
- **Clone naming:** Clones are named with timestamps (e.g., `gm-clone-20251025-143022`) for easy identification

### Can I run the containers/VMs on a different computer?

Yes! Use the built-in modular export feature:

1. **Export from source machine:**
   - Choose **Option 3: Manage Base** → **Export VM/Container (for transfer)**
   - Creates unified export folder: `~/Downloads/gm-export-YYYYMMDD-HHMMSS/`
   - Contains all components:
     - **Blockchain data:** Split into 1.9GB parts (`blockchain.tar.gz.part01`, `part02`, etc.)
     - **Container/VM image:** `container-image.tar.gz` or `vm-image.tar.gz` (~500MB-1GB)
     - **Checksums:** `SHA256SUMS` (unified checksums for all files)
     - **Documentation:** `MANIFEST.txt` (assembly instructions)
   - All sensitive data removed (Tor keys, SSH keys, peer databases, logs)
   - All files SHA256 checksummed for integrity verification

2. **Transfer to destination machine:**
   - Copy entire export folder to `~/Downloads/`
   - All checksums are included automatically

3. **Import on destination machine:**
   - Choose **Option 1: Create Base Container/VM** → **"Import from file"**
   - Script will:
     - Scan `~/Downloads/` for export folders
     - Detect unified modular format
     - Verify all SHA256 checksums automatically via SHA256SUMS
     - Reassemble blockchain if needed
     - Extract and import the image
     - Combine blockchain with container/VM
     - Configure resources and prepare for use
   - If blockchain is >2 hours old, sync monitoring will automatically detect
     and wait for peers to connect and catch up to current height

**Benefits of modular format:**
- Smaller image downloads (~1GB vs ~22GB)
- Blockchain can be reused across multiple exports
- Can update container/VM without re-transferring blockchain
- All parts under 2GB (GitHub release compatible)

**Creating GitHub Releases (for maintainers/contributors):**

If you want to share your synced base container/VM as a GitHub release:

1. **Export from main script:**
   - Run the main script: `./garbageman-nm.sh`
   - For Containers: Choose **"Export Base Container"**
   - For VMs: Choose **"Export Base VM"**
   - Select export type:
     - **Full export (with blockchain)** - Complete package for GitHub releases
     - Image-only export - For updates without blockchain data
   - Output: `~/Downloads/gm-export-YYYYMMDD-HHMMSS/`
   - All files are ready for GitHub release (blockchain split into <2GB parts)

2. **Create a release tag:**
   ```bash
   git tag -a v1.0.0 -m "Release v1.0.0 - Block height 921000"
   git push origin v1.0.0
   ```

3. **Upload to GitHub:**
   - Go to https://github.com/paulscode/garbageman-nm/releases
   - Click "Draft a new release"
   - Select your tag
   - Upload all files from the export directory:
     - All `blockchain.tar.gz.part*` files (shared between container and VM)
     - `SHA256SUMS` (unified checksums) and `MANIFEST.txt`
     - `vm-image.tar.gz` (if VM release)
     - `container-image.tar.gz` (if container release)
   - Add release notes with blockchain height, date, and unified format benefits
   - Publish!

4. **Users can then import via:**
   - **Container:** Option 1: Create Base Container → Import from GitHub
   - **VM:** Option 1: Create Base VM → Import from GitHub
   - Script downloads blockchain parts + image, verifies checksums, reassembles, and imports automatically

**See RELEASE_GUIDE.md for complete release creation instructions.**

### What if I run out of resources?

The script prevents over-allocation:
- Shows capacity suggestions before creation
- Validates your inputs against available resources
- Warns if you try to allocate too much

If you need more capacity:
- Reduce runtime container/VM sizes in "Configure Defaults"
- Upgrade your hardware
- Stop some VMs when not needed

### How do I view a container's/VM's .onion address?

**Easy way:** Use the menu options:
- **Option 3: Manage Base Container/VM** - Shows .onion address when the base is running (also supports exporting)
- **Option 5: Manage Clone Containers/VMs** - Shows .onion address when you select a running clone

**Manual way (VMs only):**
```bash
# Get the VM's IP address
virsh domifaddr gm-base

# SSH into the VM and read the hostname file
ssh root@<VM_IP>
cat /var/lib/tor/bitcoin-service/hostname
```

**Manual way (Containers):**
```bash
# For Docker
docker exec gm-base cat /var/lib/tor/bitcoin-service/hostname

# For Podman
podman exec gm-base cat /var/lib/tor/bitcoin-service/hostname
```

The .onion address is automatically generated when the container/VM first boots.

### How do I stop all containers/VMs?

**For Containers:**
```bash
# Docker
docker ps -a                          # List all containers
docker stop gm-base                   # Graceful shutdown
docker stop $(docker ps -q -f name=gm)  # Stop all gm containers

# Podman
podman ps -a                          # List all containers
podman stop gm-base                   # Graceful shutdown
podman stop $(podman ps -q -f name=gm)  # Stop all gm containers
```

**For VMs:**
```bash
virsh list --all                    # List all VMs
virsh shutdown gm-base              # Graceful shutdown
virsh destroy gm-base               # Force stop (if needed)
```

Or use the "Manage Base Container/VM" and "Manage Clones" menu options.

### How do I delete a container/VM?

**Base container/VM and clones are managed separately:**

**For the Base Container/VM:**
- Choose **"Manage Base Container/VM"** → **"Delete Base Container/VM"**
- This permanently removes the base container/VM and its data
- You'll need to recreate it with "Create Base Container/VM" if you want to make new clones
- Asks for confirmation before deleting

**For Clone Containers/VMs:**
- Choose **"Manage Clone Containers/VMs"** → select the clone → **"Delete Container/VM (permanent)"**
- This only deletes the specific clone you selected
- Other clones and the base remain untouched
- Asks for confirmation before deleting

**Manual way (container clones):**
```bash
# Docker
docker stop gm-clone-20251103-143022
docker rm gm-clone-20251103-143022
docker volume rm gm-clone-20251103-143022-data

# Podman
podman stop gm-clone-20251103-143022
podman rm gm-clone-20251103-143022
podman volume rm gm-clone-20251103-143022-data
```

**Manual way (VM clones):**
```bash
virsh undefine gm-clone-20251025-143022           # Remove VM definition
rm /var/lib/libvirt/images/gm-clone-20251025-143022.qcow2  # Delete disk
```

**Manual way (base container/VM):**

Use the included deletion script for thorough removal:
```bash
./devtools/delete-gm-base.sh
```
This removes the container/VM, data volumes/disk image, and associated SSH keys.

### Can I access the container/VM console?

**For VMs:**
Yes! You can access the VM's console directly:

```bash
virsh console gm-base
# Login: root
# Password: garbageman
```

Press `Ctrl+]` to exit the console.

**Security Note:** The default password `garbageman` is only usable via the direct console (virsh console). SSH password authentication is automatically disabled after first-boot, so remote login requires the monitoring SSH key. VMs run on an isolated NAT network (192.168.122.0/24) and are not accessible from external networks.

**For Containers:**
Use the exec command to get a shell:

```bash
# Docker
docker exec -it gm-base sh

# Podman
podman exec -it gm-base sh
```

**Note:** The script automatically handles SSH access for VMs for monitoring, so you typically don't need console access. But it's available if you want to troubleshoot or explore internally.

### How do I check if bitcoind is running inside the container/VM?

**Easy way:** Check the menu options - when a container/VM is running, Options 3 and 5 show block height (which means bitcoind is running).

**Manual way (VMs):**
```bash
# Get the VM's IP address
virsh domifaddr gm-base

# SSH into the VM (password: garbageman, or use the monitoring key)
ssh root@<VM_IP>

# Check bitcoind status
ps aux | grep bitcoind
bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf getblockchaininfo
```

You can also use the monitoring SSH key:
```bash
ssh -i ~/.cache/gm-monitor/gm_monitor_ed25519 root@<VM_IP>
```

**Manual way (Containers):**
```bash
# Docker
docker exec gm-base ps aux | grep bitcoind
docker exec gm-base bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf getblockchaininfo

# Podman
podman exec gm-base ps aux | grep bitcoind
podman exec gm-base bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf getblockchaininfo
```

### What is Garbageman and why does it exist?

**Garbageman** is a modified Bitcoin node (based on Bitcoin Knots) designed as a **defense against blockchain spam**.

**The Problem:**
- Some users broadcast transactions to the Bitcoin network that most node operators consider spam (though technically valid)
- **Libre Relay** is a network of nodes that intentionally relay this spam
- Libre Relay nodes identify each other using a special flag (`NODE_LIBRE_RELAY`) to preferentially connect with each other
- This creates a gaping, zero-friction pipeline for bad actors to bypass sane spam filtering policy norms and get their garbage into a block

**The Solution:**
- **Garbageman** also advertises the `NODE_LIBRE_RELAY` flag
- This tricks Libre Relay nodes into connecting with it
- But instead of relaying spam, Garbageman **silently drops it**
- This helps isolate spam-relaying nodes from each other
- Result: Spam has a harder time propagating across the network

**Think of it like:** Garbageman nodes act as "honeypots" that attract spam-relaying connections but don't forward the spam, helping to contain it.

**Why run multiple Garbageman nodes?**
- More Garbageman nodes = better coverage against spam relay networks
- Each node with a unique Tor address can attract different spam-relaying peers
- Helps protect the Bitcoin network's usability for monetary transactions

**Technical details:**
- Based on Bitcoin Knots (a Bitcoin Core fork with additional features)
- Functions as a full validating Bitcoin node
- Tracks transactions to avoid detection by spam relayers
- Otherwise behaves like any other Bitcoin node

For deeper technical discussion, see:
- [Bitcoin Dev mailing list discussion](https://gnusha.org/pi/bitcoindev/aDWfDI03I-Rakopb%40petertodd.org)
- [Garbageman source repository](https://github.com/chrisguida/bitcoin/tree/garbageman-v29)

---

## 🐛 Troubleshooting

### Container/VM Won't Start

**For Containers:**
```bash
# Check Docker/Podman status
sudo systemctl status docker   # or: systemctl status podman
sudo systemctl start docker    # or: systemctl start podman

# Check container logs
docker logs gm-base            # or: podman logs gm-base
```

**For VMs:**
Check libvirt service:
```bash
sudo systemctl status libvirtd
sudo systemctl start libvirtd
```

Check default network:
```bash
virsh net-list --all
virsh net-start default
```

### Sync Stuck at 0%

**Verify bitcoind is running:**

**For Containers:**
```bash
# Check if container is running
docker ps | grep gm-base       # or: podman ps | grep gm-base

# Check bitcoind process
docker exec gm-base ps aux | grep bitcoind

# View logs
docker exec gm-base tail -f /var/lib/bitcoin/debug.log
```

**For VMs:**
```bash
# Get VM IP
virsh domifaddr gm-base

# SSH and check
ssh root@<VM_IP>
ps aux | grep bitcoind
tail -f /var/lib/bitcoin/debug.log
```

**Check network connectivity (inside container/VM):**
```bash
# For containers
docker exec gm-base ping -c 3 8.8.8.8
docker exec gm-base curl https://icanhazip.com

# For VMs (via SSH)
ping 8.8.8.8
curl https://icanhazip.com
```

### Build Failed During Compilation

**Check system resources:**
- Build needs at least 2 GB RAM
- Check available memory: `free -h`
- Close other programs and try again

**Clean up and retry:**

**For Containers:**
```bash
docker stop gm-base ; docker rm gm-base
docker volume rm garbageman-data
docker system prune -f
./garbageman-nm.sh  # Start fresh
```

**For VMs:**
```bash
sudo rm -f /var/lib/libvirt/images/gm-base.qcow2
virsh undefine gm-base
./garbageman-nm.sh  # Start fresh
```

### Can't SSH into VM

**The script handles SSH automatically for VMs**, but if you need to manually connect:

```bash
# Use the monitoring key
ssh -i ~/.cache/gm-monitor/gm_monitor_ed25519 root@<VM_IP>
```

**Note:** SSH is only used for VMs. Containers use `docker exec` or `podman exec` instead.

---

## 🛠️ Advanced Usage

### Manual Resource Adjustment

**For Containers:**
Containers can be adjusted on-the-fly:
```bash
# Update CPU/RAM limits (Docker)
docker update --cpus="2" --memory="4g" gm-base

# Update CPU/RAM limits (Podman)
podman update --cpus="2" --memory="4g" gm-base
```

**For VMs:**
Between Action 1 (Create) and Action 2 (Sync), you can manually adjust VM resources:

```bash
# Check current resources
virsh dominfo gm-base

# Change vCPUs (VM must be shut off)
virsh setvcpus gm-base 4 --config --maximum
virsh setvcpus gm-base 4 --config

# Change RAM (in KiB, so 8 GB = 8388608 KiB)
virsh setmaxmem gm-base 8388608 --config
virsh setmem gm-base 8388608 --config
```

**Or just use Action 2's built-in prompt!** It's easier and safer.

### Environment Variable Overrides

Customize script behavior before running:

```bash
# Use different base name
VM_NAME=my-bitcoin-node ./garbageman-nm.sh           # For VMs
CONTAINER_NAME=my-bitcoin-node ./garbageman-nm.sh    # For Containers

# Change default runtime resources
VM_VCPUS=2 VM_RAM_MB=4096 ./garbageman-nm.sh                    # For VMs
CONTAINER_RUNTIME_CPUS=2 CONTAINER_RUNTIME_RAM=4096 ./garbageman-nm.sh  # For Containers

# Change disk size (VMs only, containers use volumes)
VM_DISK_GB=50 ./garbageman-nm.sh

# Force Tor-only on base container/VM
CLEARNET_OK=no ./garbageman-nm.sh
```

### Using a Different Garbageman Branch

```bash
GM_BRANCH=my-custom-branch ./garbageman-nm.sh
```

### Diagnostic Tools

If your Base Container/VM isn't starting correctly or bitcoind isn't running, use the diagnostic script to check system health:

```bash
./devtools/diagnose-gm-base.sh
```

**This tool checks:**
- Container/VM power state and IP address assignment
- Network connectivity (can container/VM reach internet?)
- SSH accessibility with monitoring key (VMs only)
- Required binaries (bitcoind, bitcoin-cli, tor)
- Running processes (bitcoind and tor daemons)
- Service status (systemd for containers, OpenRC for VMs)
- First-boot completion flag
- Bitcoin configuration settings
- Data directory structure and permissions
- Blockchain sync status (if bitcoind is running)

**When to use it:**
- Container/VM won't start or keeps shutting down
- Action 2 (Monitor Sync) shows errors connecting
- Action 3 (Manage Base Container/VM) can't gather .onion address or block height
- After using `delete-gm-base.sh` to verify clean state
- Before reporting bugs to confirm system health

**Example output:**
```
[✓] Container/VM is running
[✓] IP address: 192.168.122.123 / 172.17.0.2
[✓] Network connectivity OK
[✓] SSH access working (VMs) / Exec access working (Containers)
[✓] bitcoind binary found
[✓] tor binary found
[✓] bitcoind process running (PID 1234)
[✓] tor process running (PID 1235)
[✓] bitcoind service enabled
[✓] tor service enabled
[✓] First boot completed
[✓] Bitcoin data directory exists
[✓] Blockchain sync: 12345/850000 blocks (1.45%)
```

If any checks fail, the script provides troubleshooting commands specific to that issue.

---

## 📚 Additional Resources

- **Garbageman Repository:** [github.com/chrisguida/bitcoin](https://github.com/chrisguida/bitcoin)
- **Bitcoin Core Documentation:** [bitcoin.org/en/developer-documentation](https://bitcoin.org/en/developer-documentation)
- **Libvirt Documentation:** [libvirt.org/docs.html](https://libvirt.org/docs.html)
- **Tor Hidden Services:** [community.torproject.org](https://community.torproject.org)

---

## 🤝 Contributing

Found a bug or have a feature request? Please open an issue on GitHub!

Want to contribute code? Pull requests are welcome!

---

## 📄 License

MIT License - see LICENSE file for details

---

## 🙏 Acknowledgments

- **Garbageman:** Bitcoin Knots fork by [Chris Guida](https://github.com/chrisguida)
- **Alpine Linux:** Lightweight VM OS
- **Libvirt/QEMU:** Virtualization stack
- **Tor Project:** Privacy layer

---

## ⚠️ Disclaimer

This is experimental software. Use at your own risk. Always keep backups of important data.

Running Bitcoin nodes requires significant resources and bandwidth. Ensure you understand the implications before running multiple nodes.

---

**Questions? Issues?** Open a GitHub issue or reach out to the community!

**Happy noding! 🚀**
