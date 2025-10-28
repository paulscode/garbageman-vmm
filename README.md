# Garbageman VM Manager

**Easy setup for running multiple Bitcoin Garbageman nodes on Linux Mint 22.2**

Run as many Garbageman (a Bitcoin Knots fork) nodes as your computer can handle, each with its own Tor hidden service for maximum privacy.

<img width="1536" height="1024" alt="image" src="https://github.com/user-attachments/assets/6af100e5-c873-4c26-b848-6a5ecdf17dbc" />


![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20Mint%2022.2-green.svg)

---

## 🎯 What This Does

This script makes it **dead simple** to:

- ✅ Create a lightweight Bitcoin Garbageman node in a virtual machine (VM)
- ✅ Monitor the Initial Block Download (IBD) sync with a live progress display
- ✅ Clone your synced node multiple times for redundancy
- ✅ Each clone gets its own unique Tor `.onion` address (privacy-first!)
- ✅ Automatically manage resources so your desktop stays responsive

**No manual configuration needed** - the script handles everything from building the software to setting up Tor networking.

<img width="1024" height="1255" alt="image" src="https://github.com/user-attachments/assets/da188a73-750d-44df-8555-2a5d08f5f413" />


---

## 💻 Requirements

### Minimum System
- **OS:** Linux Mint 22.2 Cinnamon (or Ubuntu 24.04-based distros)
- **CPU:** 4 cores (2 cores + 2 reserved for host)
- **RAM:** 8 GB (4 GB + 4 GB reserved for host)
- **Disk:** 50 GB free space (25 GB per VM, uses sparse allocation)
- **Internet:** Broadband connection for blockchain sync

### Recommended System
- **CPU:** 8+ cores
- **RAM:** 16+ GB
- **Disk:** 100+ GB free space
- **Faster CPU = faster initial blockchain sync**

### What Gets Installed
The script automatically installs required packages:
- Virtualization: `qemu-kvm`, `libvirt`, `virt-manager`
- Build tools: `git`, `cmake`, `gcc`
- Utilities: `jq`, `dialog`, `whiptail`

---

## 🚀 Quick Start

### 1. Download the Script

```bash
sudo apt-get install -y git
cd ~
git clone https://github.com/paulscode/garbageman-vmm.git
cd garbageman-vmm
```

### 2. Make It Executable

```bash
chmod +x garbageman-vmm.sh
```

### 3. Run It!

```bash
~/garbageman-vmm/garbageman-vmm.sh
```

That's it! The script will:
1. Install any missing dependencies (asks for your password once)
2. Show you a menu with clear options
3. Guide you through each step

---

## 📖 Step-by-Step Usage

### Typical Workflow

Here's the normal sequence most users follow:

1. **First time:** Configure Defaults (Option 7) - *optional, can use defaults*
2. **Create:** Create Base VM (Option 1) - *2+ hours*
3. **Sync:** Monitor Base VM Sync (Option 2) - *24-48 hours, can pause/resume*
4. **Clone:** Create Clone VMs (Option 4) - *1-2 minutes per clone*
5. **Start clones:** Manage Clone VMs (Option 5) → Start each clone
6. **Daily use:** Use Options 3 and 5 to start/stop VMs as needed

**💡 Pro tip:** Leave the base VM running for stability, start/stop clones based on your resource needs.

---

### First Time Setup

#### Step 1: Configure Your Preferences (Optional)

When you first run the script, you can optionally choose **"Configure Defaults"** from the menu to customize:

- **Host Reserves:** How many CPU cores and RAM to keep available for your desktop (default: 2 cores, 4 GB)
- **VM Runtime Resources:** How much CPU/RAM each VM uses after sync (default: 1 core, 2 GB per VM)
- **Clearnet Option:** Whether to allow clearnet connections on the base VM for faster initial sync (default: yes)

**Most users can skip this** and use the defaults!

#### Step 2: Create Base VM

Choose **"Create Base VM"** from the menu. This will:

1. Download Alpine Linux (tiny, fast VM OS)
2. **Build Garbageman inside the VM** (typically takes more than 2 hours, depending on your CPU)
3. Configure Tor and Bitcoin services
4. Stop the VM and leave it ready to sync

**You'll be prompted for sync resources:**
- The script suggests using most of your available CPU/RAM for faster sync
- You can accept the defaults or adjust based on what else you're running

#### Step 3: Start Sync & Monitor

Choose **"Base VM Monitor Sync"** from the menu. This will:

1. **Prompt you to confirm/change resources** (in case you want different settings than creation time)
2. Start the VM with your chosen resources (or connect to it if already running)
3. Show a **live auto-refreshing progress display**:
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
   ║    Blocks:   529668 / 921108                                                   ║
   ║    Progress: 26% (0.255699756115667)                                           ║
   ║    IBD:      true                                                              ║
   ║    Peers:    14                                                                ║
   ║                                                                                ║
   ╠════════════════════════════════════════════════════════════════════════════════╣
   ║  Auto-refreshing every 5 seconds... Press Ctrl+C to exit                       ║
   ╚════════════════════════════════════════════════════════════════════════════════╝
   ```
4. Auto-refresh every 5 seconds (no manual refresh needed)
5. When sync completes, automatically shut down the VM and resize it to runtime resources

**⏰ How long does sync take?**
- With 8+ cores, >8 GB RAM: ~24 hours (depends on multiple factors)
- With 4+ cores <8 GB RAM: >48 hours
- You can stop and resume anytime - progress is saved!

**💡 Tip:** Press Ctrl+C anytime to exit the monitor. The VM keeps running in the background, and you can reconnect later by choosing "Monitor Base VM Sync" again (it will detect the VM is already running and let you change resources if needed).

#### Step 4: Clone Your Synced Node

Once your base VM finishes syncing, you can create clones!

Choose **"Create Clone VMs (gm-clone-*)"** from the menu:

1. Script shows how many clones your system can handle
2. Enter desired number of clones
3. If the base VM is running, it will automatically shut it down gracefully (may take up to 3 minutes)
4. Each clone:
   - Copies the fully-synced blockchain (no re-download!)
   - Gets a fresh Tor `.onion` address
   - Is **forced to Tor-only** (maximum privacy)
   - Uses minimal resources (1 core, 2 GB RAM by default)
   - Named with timestamp (e.g., `gm-clone-20251025-143022`)
5. After cloning completes, clones are left in "shut off" state - start them using **"Manage Clone VMs"**

**Example:** On a 16 GB / 8-core system with defaults:
- Host reserves: 2 cores, 4 GB RAM
- Available: 6 cores, 12 GB RAM
- Runtime per VM: 1 core, 2 GB RAM
- **You can run 6 VMs simultaneously** (1 base + 5 clones)

---

## 🎛️ Menu Options Explained

### Main Menu

```
┌─────────────────────────────────────────────────┐
│         Garbageman VM Manager                   │
│                                                 │
│  1. Create Base VM (gm-base)                    │
│  2. Monitor Base VM Sync (gm-base)              │
│  3. Manage Base VM (gm-base)                    │
│  4. Create Clone VMs (gm-clone-*)               │
│  5. Manage Clone VMs (gm-clone-*)               │
│  6. Capacity Suggestions (host-aware)           │
│  7. Configure Defaults (reserves, runtime)      │
│  8. Quit                                        │
└─────────────────────────────────────────────────┘
```

#### Option 1: Create Base VM
- **When to use:** First time setup, or to rebuild from scratch
- **What it does:** Builds everything and creates your base node
- **Time:** 10-30 minutes (mostly compilation time)

#### Option 2: Monitor Base VM Sync
- **When to use:** After creating the base VM, to sync the blockchain
- **What it does:** Connects to the VM (starts it if stopped) and shows live auto-refreshing IBD progress
- **Time:** 24-48 hours (varies greatly, due to multiple factors)
- **Can be resumed:** Yes! Press Ctrl+C to exit monitor anytime (VM keeps running)
- **On completion:** Automatically shuts down VM and resizes to runtime resources

#### Option 3: Manage Base VM
- **When to use:** Simple start/stop/status controls for the base VM
- **What it does:** Power on/off the base VM, check status
- **Shows when running:** Tor .onion address and current block height
- **Time:** Instant

#### Option 4: Create Clone VMs (gm-clone-*)
- **When to use:** After base VM is fully synced
- **What it does:** Creates additional nodes with unique .onion addresses
- **Time:** 1-2 minutes per clone
- **Blockchain re-sync:** No! Clones copy the synced data
- **Auto-shutdown:** Automatically stops base VM if running (graceful, up to 3 minutes)

#### Option 5: Manage Clone VMs (gm-clone-*)
- **When to use:** Control existing clones
- **What it does:** Start, stop, or delete clone VMs
- **Shows when running:** Tor .onion address and current block height for each clone
- **Time:** Instant

#### Option 6: Capacity Suggestions (host-aware)
- **When to use:** Planning how many nodes you can run
- **What it does:** Shows detailed resource breakdown and clone capacity

#### Option 7: Configure Defaults (reserves, runtime, clearnet)
- **When to use:** Adjust how resources are allocated
- **What it does:** Reset to original host-aware defaults or customize reserves, VM sizes, and clearnet option
- **Options:**
  - **Reset to Original Values:** Restores hardcoded defaults (2 cores, 4GB reserve, 1 vCPU/2GB RAM per VM)
  - **Choose Custom Values:** Fine-tune each setting individually

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

### Base VM Clearnet Option
The base VM can optionally use **Tor + clearnet** (configurable):
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
- **Duration:** 10-30 minutes (one-time)
- **Resources:** Uses your "sync" allocation
- **Why:** More CPU = faster compilation

#### Phase 2: Initial Sync (Temporary)
- **Duration:** 24-48 hours (one-time per base VM)
- **Resources:** You configure this (default: all available after reserves)
- **Why:** More resources = faster blockchain download

#### Phase 3: Runtime (Long-term)
- **Duration:** Forever (or until you stop the VMs)
- **Resources:** Smaller footprint (default: 1 core, 2 GB per VM)
- **Why:** Pruned nodes don't need much after sync

### Example Resource Allocation

**System:** 16 GB RAM, 8 cores

**Defaults:**
```
Host reserves:     4 GB RAM, 2 cores (for your desktop)
Available:        12 GB RAM, 6 cores (for VMs)

Phase 2 (sync):   12 GB RAM, 6 cores (base VM only)
Phase 3 (runtime): 2 GB RAM, 1 core (per VM)

Capacity: 6 VMs simultaneously (1 base + 5 clones)
```

**Adjustable in "Configure Defaults"!**

---

## ❓ Frequently Asked Questions

### Should I use "Monitor Base VM Sync" or "Manage Base VM"?

- **Monitor Base VM Sync (Option 2):** Use this when you want to watch the blockchain sync progress with a live updating display. Best for initial sync or checking sync status.
- **Manage Base VM (Option 3):** Use this for simple start/stop/status controls. Shows .onion address and current block height when running. Good for daily management.

Both can start the VM, but Option 2 provides detailed monitoring while Option 3 is quicker for basic operations.

### How much disk space does each VM use?

- **Base VM after sync:** ~25 GB (pruned blockchain + OS)
- **Each clone:** ~25 GB (copy of base VM)
- **Format:** qcow2 with sparse allocation (only uses space it needs)
- **Clone naming:** Clones are named with timestamps (e.g., `gm-clone-20251025-143022`) for easy identification

### Can I run the VMs on a different computer?

Yes! The VMs are standard libvirt/qcow2 format. You can:
1. Export: `virsh dumpxml gm-base > gm-base.xml`
2. Copy disk: `/var/lib/libvirt/images/gm-base.qcow2`
3. Import on another machine

### What if I run out of resources?

The script prevents over-allocation:
- Shows capacity suggestions before creation
- Validates your inputs against available resources
- Warns if you try to allocate too much

If you need more capacity:
- Reduce runtime VM sizes in "Configure Defaults"
- Upgrade your hardware
- Stop some VMs when not needed

### How do I view a VM's .onion address?

**Easy way:** Use the menu options:
- **Option 3: Manage Base VM** - Shows .onion address when the base VM is running
- **Option 5: Manage Clone VMs** - Shows .onion address when you select a running clone

**Manual way:**
```bash
# Get the VM's IP address
virsh domifaddr gm-base

# SSH into the VM and read the hostname file
ssh root@<VM_IP>
cat /var/lib/tor/bitcoin-service/hostname
```

The .onion address is automatically generated when the VM first boots.

### How do I stop all VMs?

From the terminal:
```bash
virsh list --all                    # List all VMs
virsh shutdown gm-base              # Graceful shutdown
virsh destroy gm-base               # Force stop (if needed)
```

Or use the "Manage Base VM" menu option.

### How do I delete a VM?

**Base VM and clones are managed separately:**

**For the Base VM:**
- Choose **"Manage Base VM"** → **"Delete Base VM"**
- This permanently removes the base VM and its disk image
- You'll need to recreate it with "Create Base VM" if you want to make new clones
- Asks for confirmation before deleting

**For Clone VMs:**
- Choose **"Manage Clone VMs"** → select the clone → **"Delete VM (permanent)"**
- This only deletes the specific clone you selected
- Other clones and the base VM remain untouched
- Asks for confirmation before deleting

**Manual way (clones):**
```bash
virsh undefine gm-clone-20251025-143022           # Remove VM definition
rm /var/lib/libvirt/images/gm-clone-20251025-143022.qcow2  # Delete disk
```

**Manual way (base VM):**

Use the included deletion script for thorough removal:
```bash
./devtools/delete-gm-base.sh
```
This removes the VM, disk image, and associated SSH keys.

### Can I access the VM console?

Yes! You can access the VM's console directly:

```bash
virsh console gm-base
# Login: root
# Password: garbageman
```

Press `Ctrl+]` to exit the console.

**Note:** The script automatically handles SSH access for monitoring, so you typically don't need console access. But it's available if you want to troubleshoot or explore the VM internally.

### How do I check if bitcoind is running inside the VM?

**Easy way:** Check the menu options - when a VM is running, Options 3 and 5 show block height (which means bitcoind is running).

**Manual way:**
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

### VM Won't Start

**Check libvirt service:**
```bash
sudo systemctl status libvirtd
sudo systemctl start libvirtd
```

**Check default network:**
```bash
virsh net-list --all
virsh net-start default
```

### Sync Stuck at 0%

**Verify bitcoind is running:**
```bash
# Get VM IP
virsh domifaddr gm-base

# SSH and check
ssh root@<VM_IP>
ps aux | grep bitcoind
tail -f /var/lib/bitcoin/debug.log
```

**Check network connectivity:**
```bash
# Inside VM
ping 8.8.8.8
curl https://icanhazip.com
```

### Build Failed During Compilation

**Check system resources:**
- Build needs at least 2 GB RAM
- Check available memory: `free -h`
- Close other programs and try again

**Clean up and retry:**
```bash
sudo rm -f /var/lib/libvirt/images/gm-base.qcow2
virsh undefine gm-base
./garbageman-vmm.sh  # Start fresh
```

### Can't SSH into VM

**The script handles SSH automatically**, but if you need to manually connect:

```bash
# Use the monitoring key
ssh -i ~/.cache/gm-monitor/gm_monitor_ed25519 root@<VM_IP>
```

---

## 🛠️ Advanced Usage

### Manual Resource Adjustment

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
# Use different VM name
VM_NAME=my-bitcoin-node ./garbageman-vmm.sh

# Change default runtime resources
VM_VCPUS=2 VM_RAM_MB=4096 ./garbageman-vmm.sh

# Change disk size
VM_DISK_GB=50 ./garbageman-vmm.sh

# Force Tor-only on base VM
CLEARNET_OK=no ./garbageman-vmm.sh
```

### Using a Different Garbageman Branch

```bash
GM_BRANCH=my-custom-branch ./garbageman-vmm.sh
```

### Diagnostic Tools

If your Base VM isn't starting correctly or bitcoind isn't running, use the diagnostic script to check system health:

```bash
./devtools/diagnose-gm-base.sh
```

**This tool checks:**
- VM power state and IP address assignment
- Network connectivity (can VM reach internet?)
- SSH accessibility with monitoring key
- Required binaries (bitcoind, bitcoin-cli, tor)
- Running processes (bitcoind and tor daemons)
- OpenRC service status (bitcoind and tor services)
- First-boot completion flag
- Bitcoin configuration settings
- Data directory structure and permissions
- Blockchain sync status (if bitcoind is running)

**When to use it:**
- VM won't start or keeps shutting down
- Action 2 (Monitor Sync) shows errors connecting
- Action 3 (Manage Base VM) can't gather .onion address or block height
- After using `delete-gm-base.sh` to verify clean state
- Before reporting bugs to confirm system health

**Example output:**
```
[✓] VM is running
[✓] IP address: 192.168.122.123
[✓] Network connectivity OK
[✓] SSH access working
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
