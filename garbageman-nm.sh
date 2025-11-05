#!/usr/bin/env bash
################################################################################
# garbageman-nm.sh — All-in-one TUI for Garbageman lifecycle management
#                     Supports both VMs and Containers
#                     Tested on Linux Mint 22.2 (Ubuntu 24.04 base)
#
# Purpose:
#   Automate the creation and management of Bitcoin Garbageman nodes running
#   in either lightweight Alpine Linux VMs OR Docker/Podman containers.
#   This script handles everything from building the Bitcoin fork, creating
#   base VMs/containers, monitoring IBD sync, to cloning multiple nodes each
#   with their own Tor v3 onion address.
#
# Features:
#   - Deployment mode selection: VMs (libvirt/qemu) OR Containers (Docker/Podman)
#   - Build Garbageman (a Bitcoin Knots fork) INSIDE Alpine (native musl)
#   - Pre-creation "Configure defaults" step:
#       * Host reserve policy (cores/RAM/disk kept for desktop)
#       * Per-VM/container runtime resources (vCPUs/RAM) for base after sync + all clones
#       * Toggle: "Allow clearnet peers on one VM/container?" (YES => base is Tor+clearnet; clones remain Tor-only)
#   - Start & monitor IBD with live progress display (Stop on demand; auto-downsize after sync)
#   - Clone the base VM/container any number of times; each clone:
#       * gets a fresh Tor v3 onion address
#       * is forced to Tor-only networking (privacy-preserving)
#       * copies blockchain data from base (no re-sync needed)
#   - Host-aware capacity detection (CPU/RAM/Disk) with intelligent clone suggestions
#   - Import/export for easy transfer between hosts
#
# Architecture Notes:
#   VM Mode:
#     - Host uses glibc (Ubuntu/Mint), VMs use musl (Alpine) - binaries are NOT compatible
#     - Solution: Build Garbageman INSIDE Alpine using virt-customize
#     - libguestfs creates temporary VMs for build operations
#     - Uses libvirt/qemu-kvm for VM management
#     - OpenRC init system in Alpine (not systemd)
#   
#   Container Mode:
#     - Multi-stage Dockerfile builds Garbageman from source in Alpine
#     - Supports both Docker and Podman (auto-detected)
#     - Lower overhead than VMs (~150MB vs ~200MB)
#     - Faster startup and cloning than VMs
#     - Data stored in Docker/Podman volumes (survives container recreation)
#
# Requirements:
#   VM Mode:
#     - libvirt/qemu-kvm on the host (script auto-installs if missing)
#     - Build tools: libguestfs-tools (auto-installed)
#   
#   Container Mode:
#     - Docker OR Podman (script auto-detects which is available)
#     - No special privileges needed beyond container runtime access
#   
#   Both Modes:
#     - TUI tools: whiptail, dialog, jq (auto-installed)
################################################################################
set -euo pipefail

################################################################################
# User-tunable defaults (override via environment variables)
################################################################################
# These can be overridden before running the script, e.g.:
#   VM_NAME=my-node VM_RAM_MB=4096 ./garbageman-nm.sh

# Base VM identifier
VM_NAME="${VM_NAME:-gm-base}"          # Name of the base VM (clones get unique names automatically)

# Runtime resources (used after IBD completes and for ALL clones)
# These are the "small footprint" values for long-term running nodes
VM_RAM_MB="${VM_RAM_MB:-2048}"         # RAM per VM (MiB) after sync (default: 2 GiB)
VM_VCPUS="${VM_VCPUS:-1}"              # vCPUs per VM after sync

# Initial sync fallbacks (used only if host detection fails)
# During IBD, more resources = faster sync
SYNC_RAM_MB_DEFAULT="${SYNC_RAM_MB_DEFAULT:-4096}"
SYNC_VCPUS_DEFAULT="${SYNC_VCPUS_DEFAULT:-2}"

# Disk size for base VM (qcow2 format, sparse allocation)
VM_DISK_GB="${VM_DISK_GB:-25}"         # 25 GB handles pruned node (prune=750 in bitcoin.conf)

# Source repository to build Garbageman (Bitcoin Core fork)
GM_REPO="${GM_REPO:-https://github.com/chrisguida/bitcoin.git}"
GM_BRANCH="${GM_BRANCH:-garbageman-v29}"
BUILD_DIR="${BUILD_DIR:-$HOME/src/garbageman}"           # Host clone dir (for reference)
BIN_STAGING="${BIN_STAGING:-$HOME/.cache/gm-bins}"       # Deprecated (host build artifacts)

# Guest user/service configuration inside Alpine VM
BITCOIN_USER="${BITCOIN_USER:-bitcoin}"                  # Unprivileged user running bitcoind
BITCOIN_GROUP="${BITCOIN_GROUP:-bitcoin}"
BITCOIN_DATADIR="${BITCOIN_DATADIR:-/var/lib/bitcoin}"   # Blockchain data location
TOR_GROUP="${TOR_GROUP:-tor}"                            # Tor daemon group

# Alpine Linux "virt" ISO mirror (we automatically pick latest-stable)
# The "virt" flavor is optimized for VMs (smaller kernel, no desktop packages)
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64}"

# SSH access for monitoring (a temporary key is injected into the guest for RPC polling)
SSH_USER="${SSH_USER:-root}"                             # User for SSH connection
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_DIR="${SSH_KEY_DIR:-$HOME/.cache/gm-monitor}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$SSH_KEY_DIR/gm_monitor_ed25519}"

# Timing / UX knobs
HOST_WAIT_SSH="${HOST_WAIT_SSH:-300}"   # seconds to wait for VM SSH (Alpine first-boot can be slow)
POLL_SECS="${POLL_SECS:-5}"             # seconds between IBD progress polls
CLONE_PREFIX="${CLONE_PREFIX:-gm-clone}" # Prefix for clone VM names (e.g., gm-clone-20251025-143022)

# Fixed host reserve policy (editable in UI via "Configure Defaults")
# These reserves keep resources available for your desktop/host OS
RESERVE_CORES="${RESERVE_CORES:-2}"      # keep at least 2 cores for host desktop
RESERVE_RAM_MB="${RESERVE_RAM_MB:-4096}" # keep at least 4 GiB for host desktop
RESERVE_DISK_GB="${RESERVE_DISK_GB:-20}" # keep at least 20 GB free disk space for host

# Disk space requirements per VM/container
# VMs: ~25GB each (pruned blockchain + overhead)
# Containers: ~25GB each (same as VMs, shared image reduces initial size)
VM_DISK_SPACE_GB="${VM_DISK_SPACE_GB:-25}"           # Disk space per VM (GB)
CONTAINER_DISK_SPACE_GB="${CONTAINER_DISK_SPACE_GB:-25}"  # Disk space per container (GB)

# Clearnet toggle: "Allow clearnet peers on one VM?"
# If "yes", base VM uses Tor+clearnet for better connectivity during IBD
# Clones are ALWAYS Tor-only regardless of this setting (privacy-first)
CLEARNET_OK="${CLEARNET_OK:-yes}"        # "yes" or "no"

# Deployment mode: "vm" or "container"
# Automatically detected based on existence of gm-base VM or container
# Only prompts user if neither exists
DEPLOYMENT_MODE=""                       # Set by check_deployment_mode()

# Container configuration
CONTAINER_NAME="${CONTAINER_NAME:-gm-base}"           # Base container name
CONTAINER_IMAGE="${CONTAINER_IMAGE:-garbageman-base}" # Container image name
CONTAINER_CLONE_PREFIX="${CONTAINER_CLONE_PREFIX:-gm-clone}" # Prefix for clone containers
################################################################################

################################################################################
# Utilities & Helper Functions
################################################################################

# die: Display error message in whiptail dialog and exit
# Args: $* = error message to display
die(){ 
  whiptail --title "Error" --msgbox "ERROR:\n\n$*" 12 78 2>/dev/null || { 
    echo "ERROR: $*" >&2
  }
  exit 1
}

# need_sudo_for_virsh: Check if we need sudo for virsh operations
# Returns: 0 (true) if sudo is needed, 1 (false) if current user is in libvirt group
# Purpose: Determines whether to use sudo for virt-* commands
# Note: virsh_cmd always uses sudo for consistency
need_sudo_for_virsh(){
  # Check if user is in libvirt group and can access /var/run/libvirt/libvirt-sock
  if groups | grep -qw libvirt && [ -w /var/run/libvirt/libvirt-sock ] 2>/dev/null; then
    return 1  # Don't need sudo
  fi
  return 0  # Need sudo
}

# virsh_cmd: Wrapper for virsh commands that always uses sudo and system instance
# Args: $@ = virsh command and arguments
# Example: virsh_cmd list --all
# Always connects to qemu:///system (not user session) and uses sudo
# This ensures consistent behavior regardless of group membership
virsh_cmd(){ 
  sudo virsh -c qemu:///system "$@"
}

# virt_cmd: Wrapper for virt-* tools (virt-customize, virt-install, etc.) that uses sudo if needed
# Args: $1 = command name (e.g., "virt-customize"), $@ = remaining arguments
virt_cmd(){ 
  local cmd="$1"
  shift
  if need_sudo_for_virsh; then
    sudo "$cmd" "$@"
  else
    "$cmd" "$@"
  fi
}

# cmd: Check if a command exists in PATH
# Args: $1 = command name
# Returns: 0 if exists, 1 if not
cmd(){ 
  command -v "$1" >/dev/null 2>&1
}

# sudo_keepalive_start: Start a background process to keep sudo credentials fresh
# Purpose: Prevents sudo timeout during long operations (like 20-minute builds)
# Side effects: Sets SUDO_KEEPALIVE_PID global variable with background process PID
# Args: $1 = "force" to always start keepalive (optional)
sudo_keepalive_start(){
  local force="${1:-}"
  
  # Only start if we haven't already started keepalive
  # Start if forced OR if we need sudo for virsh
  if [[ -z "${SUDO_KEEPALIVE_PID:-}" ]] && { [[ "$force" == "force" ]] || need_sudo_for_virsh; }; then
    # Initial sudo to cache credentials and prompt user once
    sudo -v || die "This script requires sudo access for libvirt operations"
    
    # Start background process that runs 'sudo -v' every 60 seconds
    # Default sudo timeout is 5-15 minutes depending on system config
    # Running every minute ensures credentials stay fresh
    {
      while true; do
        sleep 60
        sudo -n -v 2>/dev/null || break
      done
    } &
    SUDO_KEEPALIVE_PID=$!
    
    # Make sure it's actually running
    sleep 0.1
    if ! kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
      unset SUDO_KEEPALIVE_PID
      echo "⚠ Warning: Could not start sudo keepalive process" >&2
    fi
    
    # Register cleanup trap to kill keepalive on script exit
    trap "sudo_keepalive_stop" EXIT INT TERM
  fi
}

# sudo_keepalive_stop: Stop the sudo keepalive background process
# Purpose: Clean up the background keepalive process when no longer needed
sudo_keepalive_stop(){
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    unset SUDO_KEEPALIVE_PID
  fi
}

# vm_state: Get the current state of a VM
# Args: $1 = VM name
# Returns: State string ("running", "shut off", "paused", etc.)
vm_state(){ 
  local state
  state=$(virsh_cmd domstate "$1" 2>/dev/null || echo "unknown")
  # Remove carriage returns and newlines, output just the state
  echo "$state" | tr -d '\r\n'
}

# pause: Display an informational message and wait for user acknowledgment
# Args: $1 = message to display
pause(){ 
  whiptail --title "Info" --msgbox "$1" 12 78
}

# ensure_vm_stopped: Ensure a VM is fully stopped before disk operations
# Args: $1 = VM name
# Returns: 0 on success, 1 on failure
# Purpose: libguestfs tools (virt-customize, etc.) require exclusive disk access
#          This function gracefully shuts down a running VM, or force-stops if needed
ensure_vm_stopped(){
  local name="$1"
  
  # If already shut off, nothing to do
  [[ "$(vm_state "$name")" == "shut off" ]] && return 0

  echo "Domain '$name' is being shutdown"
  sudo virsh shutdown "$name" >/dev/null 2>&1 || true

  # Wait up to 60 seconds for a clean shutdown
  for i in {1..60}; do
    [[ "$(vm_state "$name")" == "shut off" ]] && return 0
    sleep 1
  done

  # If still running, escalate to destroy (force off)
  echo "Graceful shutdown timed out; forcing power off for domain '$name'"
  sudo virsh destroy "$name" >/dev/null 2>&1 || true

  # Wait a few seconds for libvirt to settle
  for i in {1..10}; do
    [[ "$(vm_state "$name")" == "shut off" ]] && return 0
    sleep 1
  done

  # Final check: if still not shut off, fail with a clear error so we don't corrupt disks
  if [[ "$(vm_state "$name")" != "shut off" ]]; then
    echo "❌ Failed to stop domain '$name' cleanly. Aborting disk-write operations."
    echo "You can try: sudo virsh list --all; sudo virsh shutdown $name; sudo virsh destroy $name"
    echo "If that fails, shut down the VM from the host or use virt-customize --ro for read-only operations."
    return 1
  fi
}


################################################################################
# Container Runtime Detection & Utilities
################################################################################

# container_runtime: Detect and return the available container runtime
# Returns: "docker" or "podman" (whichever is available), empty if neither found
# Purpose: Support both Docker and Podman for maximum compatibility
container_runtime(){
  if command -v docker >/dev/null 2>&1; then
    echo "docker"
  elif command -v podman >/dev/null 2>&1; then
    echo "podman"
  else
    echo ""
  fi
}

# container_cmd: Wrapper for container runtime commands
# Args: $@ = container command and arguments (e.g., "run", "create", "exec", etc.)
# Purpose: Abstracts Docker vs Podman differences and handles permissions
# Behavior:
#   - Docker: Uses sudo if user not in docker group
#   - Podman: Runs rootless by default (no sudo needed)
# Example: container_cmd run -d --name test alpine:latest
container_cmd(){
  local runtime
  runtime=$(container_runtime)
  [[ -n "$runtime" ]] || die "No container runtime found. This should not happen - ensure_tools should have installed Docker."
  
  # Use sudo for docker if current user isn't in docker group
  if [[ "$runtime" == "docker" ]]; then
    if groups | grep -qw docker; then
      docker "$@"
    else
      sudo docker "$@"
    fi
  else
    # Podman runs rootless by default
    podman "$@"
  fi
}

# container_exists: Check if a container exists
# Args: $1 = container name
# Returns: 0 if exists, 1 if not
# Note: Returns 1 (false) if no container runtime is available (instead of dying)
container_exists(){
  local name="$1"
  local runtime
  runtime=$(container_runtime)
  # If no container runtime available, container doesn't exist
  [[ -n "$runtime" ]] || return 1
  container_cmd ps -a --format '{{.Names}}' | grep -q "^${name}$"
}

# container_state: Get the current state of a container
# Args: $1 = container name
# Returns: State string ("running", "exited", "paused", etc.)
container_state(){
  local name="$1"
  if ! container_exists "$name"; then
    echo "not-found"
    return
  fi
  container_cmd ps -a --filter "name=^${name}$" --format '{{.Status}}' | awk '{print $1}' | tr '[:upper:]' '[:lower:]'
}

# container_ip: Get the IP address of a running container
# Args: $1 = container name
# Returns: IP address string (empty if not found or not running)
container_ip(){
  local name="$1"
  local state
  state=$(container_state "$name")
  
  [[ "$state" == "up" ]] || return 0
  
  # Try to get IP from container inspect
  container_cmd inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null | head -n1
}

# container_exec: Execute command inside a running container
# Args: $1 = container name, $@ = command to run
# Purpose: Similar to SSH for VMs, but using container exec
container_exec(){
  local name="$1"
  shift
  container_cmd exec "$name" "$@"
}

# ensure_container_stopped: Ensure a container is fully stopped before operations
# Args: $1 = container name
# Returns: 0 on success, 1 on failure
# Note: Uses 180s timeout for graceful bitcoind shutdown, waits up to 200s total
ensure_container_stopped(){
  local name="$1"
  local state
  state=$(container_state "$name")
  
  # If not found or already stopped, nothing to do
  [[ "$state" == "not-found" || "$state" == "exited" ]] && return 0
  
  echo "Stopping container '$name' (graceful shutdown, may take up to 3 minutes)..."
  container_cmd stop --time=180 "$name" >/dev/null 2>&1 || true
  
  # Wait up to 200 seconds (180s timeout + 20s buffer) for graceful stop
  for i in {1..200}; do
    state=$(container_state "$name")
    [[ "$state" == "exited" ]] && return 0
    sleep 1
  done
  
  # If still running, force kill
  echo "Graceful stop timed out; forcing kill..."
  container_cmd kill "$name" >/dev/null 2>&1 || true
  sleep 2
  
  state=$(container_state "$name")
  [[ "$state" == "exited" ]] && return 0
  
  echo "❌ Failed to stop container '$name'"
  return 1
}


################################################################################
# Host Package Installation
################################################################################

# install_docker: Install Docker CE from official Docker repository
# Purpose: Install Docker when neither Docker nor Podman is available
# Side effects:
#   - Adds Docker's official GPG key and repository
#   - Installs docker-ce, docker-ce-cli, containerd.io
#   - Starts and enables docker service
#   - Adds current user to docker group (may require logout to take effect)
install_docker() {
  echo "Installing Docker CE (requires sudo)..."
  
  # Install prerequisites
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl gnupg
  
  # Add Docker's official GPG key
  sudo install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  
  # Add Docker repository (using Ubuntu 24.04 "noble" - Linux Mint 22.2 base)
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    noble stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  
  # Install Docker Engine
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  
  # Start and enable Docker service
  sudo systemctl enable --now docker
  
  # Add current user to docker group
  local current_user="${SUDO_USER:-$USER}"
  sudo usermod -aG docker "$current_user"
  echo "Added user '$current_user' to docker group."
  echo ""
  echo "Important: Group membership changes require one of the following:"
  echo "  1. Log out and log back in (recommended for permanent effect)"
  echo "  2. Run this script with: sg docker -c './garbageman-nm.sh'"
  echo "  3. Continue with this session (will use sudo for docker operations)"
  echo ""
  
  # Verify installation
  if command -v docker >/dev/null 2>&1; then
    echo "✓ Docker installed successfully"
  else
    echo "❌ Docker installation may have failed"
    return 1
  fi
}

# install_deps: Install all required host packages
# Purpose: Ensures build tools, libvirt/qemu, and TUI tools are present
# Side effects: 
#   - Runs apt-get update and install (requires sudo)
#   - Enables and starts libvirtd service
#   - Adds current user to libvirt group (may require logout to take effect)
install_deps() {
  echo "Installing required packages (requires sudo)..."
  sudo apt-get update
  sudo apt-get install -y software-properties-common
  sudo add-apt-repository -y universe
  sudo apt-get update
  sudo apt-get install -y \
    git build-essential cmake pkg-config libevent-dev \
    libboost-system-dev libboost-filesystem-dev libboost-thread-dev libsqlite3-dev \
    libzmq3-dev \
    qemu-kvm libvirt-daemon-system libvirt-clients virtinst virt-manager \
    libguestfs-tools xorriso curl jq openssh-client dialog whiptail
  sudo systemctl enable --now libvirtd
  
  # Add current user to libvirt group so they can manage VMs without sudo
  local current_user="${SUDO_USER:-$USER}"
  sudo usermod -a -G libvirt "$current_user"
  echo "Added user '$current_user' to libvirt group."
  echo ""
  echo "Important: Group membership changes require one of the following:"
  echo "  1. Log out and log back in (recommended for permanent effect)"
  echo "  2. Run this script with: sg libvirt -c './garbageman-nm.sh'"
  echo "  3. Continue with this session (will use sudo for privileged operations)"
  echo ""
  
  # Ensure default network is started (required for VM networking)
  ensure_default_network || true
}

# ensure_default_network: Ensure libvirt's default network exists and is active
# Purpose: Creates, defines, starts, and auto-starts the default network if missing
# This is needed for VMs to have network connectivity
# Side effects: May create and start the default libvirt network
ensure_default_network(){
  local network_xml="/tmp/libvirt-default-network.xml"
  
  # Check if default network is already defined
  if ! virsh_cmd net-info default >/dev/null 2>&1; then
    echo "Creating libvirt default network..."
    
    # Create default network XML definition
    cat > "$network_xml" <<'EOF'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF
    
    # Define the network
    if ! virsh_cmd net-define "$network_xml" 2>/dev/null; then
      echo "Warning: Failed to define default network" >&2
      rm -f "$network_xml"
      return 0  # Don't fail the whole script, just continue
    fi
    rm -f "$network_xml"
  fi
  
  # Ensure network is set to autostart (suppress output - may already be set)
  virsh_cmd net-autostart default >/dev/null 2>&1 || true
  
  # Start the network if not already active
  # Store net-list output to avoid pipeline issues with set -o pipefail
  local net_list_output
  net_list_output=$(virsh_cmd net-list --all 2>/dev/null || true)
  if ! echo "$net_list_output" | grep -q "default.*active"; then
    echo "Starting libvirt default network..."
    if ! virsh_cmd net-start default 2>&1 | grep -v "already active" | grep -v "^$"; then
      echo "Warning: May have failed to start default network" >&2
    fi
    # Give network a moment to initialize
    sleep 2
  fi
  
  # Verify network is actually active
  net_list_output=$(virsh_cmd net-list --all 2>/dev/null || true)
  if ! echo "$net_list_output" | grep -q "default.*active"; then
    echo "❌ Warning: libvirt default network is not active" >&2
    echo "VM networking may fail. Try: sudo virsh net-start default" >&2
    return 1
  fi
  
  return 0
}

# ensure_tools: Check for required commands and install if missing
# Purpose: Lazy installation - only installs packages when needed
# Also ensures a container runtime (Docker or Podman) is available
ensure_tools(){
  for t in virsh virt-install virt-clone virt-customize virt-copy-in virt-builder guestfish jq curl git cmake; do
    cmd "$t" || install_deps
  done
  cmd dialog || sudo apt-get install -y dialog whiptail
  
  # Check for container runtime and install Docker if neither exists
  if [[ -z "$(container_runtime)" ]]; then
    echo ""
    echo "No container runtime detected (Docker or Podman)."
    echo "Installing Docker CE for container support..."
    echo ""
    install_docker || die "Failed to install Docker. Please install docker or podman manually."
  fi
  
  # Ensure the default network is available after tools are installed
  ensure_default_network || true
}

# check_libvirt_access: Verify libvirt is accessible before attempting VM operations
# Purpose: Catches permission issues early with helpful error messages
# Returns: 0 if libvirt is accessible, dies with helpful message if not
check_libvirt_access(){
  # Check if libvirtd is running
  if ! sudo systemctl is-active --quiet libvirtd; then
    echo "❌ libvirtd service is not running"
    echo ""
    echo "Attempting to start libvirtd..."
    if sudo systemctl start libvirtd; then
      echo "✓ libvirtd started successfully"
      sleep 2
    else
      die "Failed to start libvirtd service.\n\nTry: sudo systemctl start libvirtd"
    fi
  fi
  
  # Check if we can connect to libvirt
  if ! sudo virsh -c qemu:///system version >/dev/null 2>&1; then
    die "Cannot connect to libvirt.\n\nTroubleshooting:\n1. Check if libvirtd is running: sudo systemctl status libvirtd\n2. Check for errors: sudo journalctl -u libvirtd -n 50"
  fi
  
  # Verify default network exists and is active
  if ! ensure_default_network; then
    echo "⚠ Warning: Default network may not be properly configured"
    echo "   Attempting to fix..."
    sleep 2
    # Try one more time
    if ! ensure_default_network; then
      die "Failed to activate libvirt default network.\n\nTry manually:\n  sudo virsh net-start default\n\nIf that fails, check: sudo journalctl -u libvirtd -n 50"
    fi
  fi
  
  return 0
}

################################################################################
# Host Resource Detection & Capacity Suggestions
################################################################################
# The script detects host resources and suggests VM/container allocations based on:
#   - Total host CPU/RAM/Disk
#   - User-configured reserves (for host OS/desktop)
#   - VM/container runtime sizes (for long-term operation)
#   - Available disk space on storage path
# Suggestions are recomputed whenever reserves or VM/container sizes change.
# Capacity is limited by whichever resource (CPU/RAM/Disk) is most constrained.

# Global variables for host resource tracking
HOST_CORES=0                    # Total CPU cores on host
HOST_RAM_MB=0                   # Total RAM on host (MiB)
HOST_DISK_GB=0                  # Available disk space on storage path (GB)
AVAIL_CORES=0                   # Available cores after reserves
AVAIL_RAM_MB=0                  # Available RAM after reserves (MiB)
AVAIL_DISK_GB=0                 # Available disk after reserves (GB)
HOST_SUGGEST_SYNC_VCPUS="$SYNC_VCPUS_DEFAULT"   # Suggested vCPUs for initial IBD
HOST_SUGGEST_SYNC_RAM_MB="$SYNC_RAM_MB_DEFAULT" # Suggested RAM for initial IBD (MiB)
HOST_SUGGEST_CLONES=0           # Suggested number of clones (in addition to base)
HOST_RES_SUMMARY=""             # Formatted summary string for display

# detect_host_resources: Discover host resources and compute VM capacity suggestions
# Purpose: Called before any resource-related UI to show current capacity
# Side effects: Updates all HOST_* global variables
# Note: For VMs only - containers use detect_host_resources_container()
detect_host_resources(){
  # Discover total host cores and RAM (MiB)
  HOST_CORES="$(nproc --all 2>/dev/null || echo 1)"
  HOST_RAM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"

  # Discover disk space for VM storage path
  local vm_disk_path="/var/lib/libvirt/images"
  local disk_avail_kb
  disk_avail_kb=$(df -k "$vm_disk_path" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  HOST_DISK_GB=$((disk_avail_kb / 1048576))  # Convert KB to GB

  # Budget after fixed reserves (editable via Configure Defaults)
  AVAIL_CORES=$(( HOST_CORES - RESERVE_CORES ))
  (( AVAIL_CORES < 0 )) && AVAIL_CORES=0

  AVAIL_RAM_MB=$(( HOST_RAM_MB - RESERVE_RAM_MB ))
  (( AVAIL_RAM_MB < 0 )) && AVAIL_RAM_MB=0

  AVAIL_DISK_GB=$(( HOST_DISK_GB - RESERVE_DISK_GB ))
  (( AVAIL_DISK_GB < 0 )) && AVAIL_DISK_GB=0

  # Initial sync suggestion: use ALL available resources for fast IBD
  # (clamped to sensible minimums)
  local svcpus="$AVAIL_CORES"
  (( svcpus < 1 )) && svcpus=1
  HOST_SUGGEST_SYNC_VCPUS="$svcpus"

  local sram="$AVAIL_RAM_MB"
  (( sram < 2048 )) && sram=2048   # Minimum 2GB for IBD
  HOST_SUGGEST_SYNC_RAM_MB="$sram"

  # Post-sync simultaneous capacity (base + clones) given runtime VM sizes
  # This calculates how many VMs can run simultaneously after IBD completes
  # Account for hypervisor overhead (~200MB per VM for QEMU process, page tables, etc.)
  local cpu_capacity=0 mem_capacity=0 disk_capacity=0 total_vm_capacity=0
  if (( VM_VCPUS > 0 )); then
    cpu_capacity=$(( AVAIL_CORES / VM_VCPUS ))
  fi
  
  # Account for hypervisor overhead in memory calculation
  local vm_overhead_mb=200
  local effective_ram_per_vm=$((VM_RAM_MB + vm_overhead_mb))
  if (( effective_ram_per_vm > 0 )); then
    mem_capacity=$(( AVAIL_RAM_MB / effective_ram_per_vm ))
  fi
  
  # Account for disk space (each VM needs VM_DISK_SPACE_GB)
  if (( VM_DISK_SPACE_GB > 0 )); then
    disk_capacity=$(( AVAIL_DISK_GB / VM_DISK_SPACE_GB ))
  fi
  
  # Take the smallest of CPU, memory, or disk capacity (most constrained resource)
  total_vm_capacity="$cpu_capacity"
  (( mem_capacity < total_vm_capacity )) && total_vm_capacity="$mem_capacity"
  (( disk_capacity < total_vm_capacity )) && total_vm_capacity="$disk_capacity"
  (( total_vm_capacity < 0 )) && total_vm_capacity=0

  # We suggest clones = total capacity - 1 (leaving one slot for the base)
  HOST_SUGGEST_CLONES=$(( total_vm_capacity > 0 ? total_vm_capacity - 1 : 0 ))
  (( HOST_SUGGEST_CLONES < 0 )) && HOST_SUGGEST_CLONES=0
  (( HOST_SUGGEST_CLONES > 48 )) && HOST_SUGGEST_CLONES=48  # UI sanity limit

  # Format summary string for display in menus
  HOST_RES_SUMMARY=$(
    cat <<TXT
Detected host:
  - CPU cores: ${HOST_CORES}
  - RAM: ${HOST_RAM_MB} MiB
  - Disk: ${HOST_DISK_GB} GB available ($vm_disk_path)

Reserves to keep for the host:
  - CPU cores reserved: ${RESERVE_CORES}
  - RAM reserved: ${RESERVE_RAM_MB} MiB
  - Disk reserved: ${RESERVE_DISK_GB} GB

Available for VMs (after reserve):
  - CPU cores: ${AVAIL_CORES}
  - RAM: ${AVAIL_RAM_MB} MiB
  - Disk: ${AVAIL_DISK_GB} GB

Suggested INITIAL SYNC (base VM only):
  - vCPUs: ${HOST_SUGGEST_SYNC_VCPUS}
  - RAM:   ${HOST_SUGGEST_SYNC_RAM_MB} MiB

Post-sync runtime (each VM uses vCPUs=${VM_VCPUS}, RAM=${VM_RAM_MB} MiB, Disk=${VM_DISK_SPACE_GB} GB):
  - CPU capacity: ${cpu_capacity} VMs
  - RAM capacity: ${mem_capacity} VMs
  - Disk capacity: ${disk_capacity} VMs
  - Estimated total VMs possible simultaneously: ${total_vm_capacity} (limited by $(
      if (( total_vm_capacity == cpu_capacity )); then echo "CPU"
      elif (( total_vm_capacity == mem_capacity )); then echo "RAM"
      elif (( total_vm_capacity == disk_capacity )); then echo "Disk"
      else echo "resources"; fi
    ))
  - Suggested number of clones (besides base): ${HOST_SUGGEST_CLONES}
TXT
  )
}

# detect_host_resources_container: Container-specific capacity detection
# Purpose: Calculate container capacity considering CPU/RAM/Disk constraints
# Side effects: Updates all HOST_* global variables
# Note: Uses same per-container CPU/RAM as VMs for consistency (1 CPU, 2GB RAM by default)
#       Container overhead (~150MB) is lower than VM overhead (~200MB)
#       Disk detection checks Docker/Podman storage paths
detect_host_resources_container(){
  # Discover total host cores and RAM (MiB)
  HOST_CORES="$(nproc --all 2>/dev/null || echo 1)"
  HOST_RAM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"

  # Discover disk space for container storage path
  local container_disk_path="/var/lib/docker"
  [[ -d "/var/lib/podman" ]] && container_disk_path="/var/lib/podman"
  local disk_avail_kb
  disk_avail_kb=$(df -k "$container_disk_path" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
  HOST_DISK_GB=$((disk_avail_kb / 1048576))  # Convert KB to GB

  # Budget after fixed reserves (editable via Configure Defaults)
  # For containers, we can use slightly lower reserves since there's no hypervisor
  AVAIL_CORES=$(( HOST_CORES - RESERVE_CORES ))
  (( AVAIL_CORES < 0 )) && AVAIL_CORES=0

  AVAIL_RAM_MB=$(( HOST_RAM_MB - RESERVE_RAM_MB ))
  (( AVAIL_RAM_MB < 0 )) && AVAIL_RAM_MB=0

  AVAIL_DISK_GB=$(( HOST_DISK_GB - RESERVE_DISK_GB ))
  (( AVAIL_DISK_GB < 0 )) && AVAIL_DISK_GB=0

  # Initial sync suggestion: use ALL available resources for fast IBD
  local svcpus="$AVAIL_CORES"
  (( svcpus < 1 )) && svcpus=1
  HOST_SUGGEST_SYNC_VCPUS="$svcpus"

  local sram="$AVAIL_RAM_MB"
  (( sram < 2048 )) && sram=2048   # Minimum 2GB for IBD
  HOST_SUGGEST_SYNC_RAM_MB="$sram"

  # Post-sync simultaneous capacity (base + clones) given runtime container sizes
  # Containers have lower overhead (~150MB) than VMs (~200MB) but we use
  # the same per-container CPU/RAM allocation for consistency
  local cpu_capacity=0 mem_capacity=0 disk_capacity=0 total_container_capacity=0
  
  # For CPUs: Can be fractional (e.g., 0.5, 1.0, 2.0)
  if (( $(echo "$VM_VCPUS > 0" | bc -l) )); then
    cpu_capacity=$(echo "$AVAIL_CORES / $VM_VCPUS" | bc)
  fi
  
  # For RAM: Account for lower container overhead (~150MB per container)
  local container_overhead_mb=150
  local effective_ram_per_container=$((VM_RAM_MB + container_overhead_mb))
  if (( effective_ram_per_container > 0 )); then
    mem_capacity=$(( AVAIL_RAM_MB / effective_ram_per_container ))
  fi
  
  # For Disk: Account for disk space (each container needs CONTAINER_DISK_SPACE_GB)
  if (( CONTAINER_DISK_SPACE_GB > 0 )); then
    disk_capacity=$(( AVAIL_DISK_GB / CONTAINER_DISK_SPACE_GB ))
  fi
  
  # Take the smallest of CPU, memory, or disk capacity (most constrained resource)
  total_container_capacity="$cpu_capacity"
  (( mem_capacity < total_container_capacity )) && total_container_capacity="$mem_capacity"
  (( disk_capacity < total_container_capacity )) && total_container_capacity="$disk_capacity"
  (( total_container_capacity < 0 )) && total_container_capacity=0

  # We suggest clones = total capacity - 1 (leaving one slot for the base)
  HOST_SUGGEST_CLONES=$(( total_container_capacity > 0 ? total_container_capacity - 1 : 0 ))
  (( HOST_SUGGEST_CLONES < 0 )) && HOST_SUGGEST_CLONES=0
  (( HOST_SUGGEST_CLONES > 48 )) && HOST_SUGGEST_CLONES=48  # UI sanity limit

  # Format summary string for display in menus
  HOST_RES_SUMMARY=$(
    cat <<TXT
Detected host:
  - CPU cores: ${HOST_CORES}
  - RAM: ${HOST_RAM_MB} MiB
  - Disk: ${HOST_DISK_GB} GB available ($container_disk_path)

Reserves to keep for the host:
  - CPU cores reserved: ${RESERVE_CORES}
  - RAM reserved: ${RESERVE_RAM_MB} MiB
  - Disk reserved: ${RESERVE_DISK_GB} GB

Available for containers (after reserve):
  - CPU cores: ${AVAIL_CORES}
  - RAM: ${AVAIL_RAM_MB} MiB
  - Disk: ${AVAIL_DISK_GB} GB

Suggested INITIAL SYNC (base container only):
  - CPUs: ${HOST_SUGGEST_SYNC_VCPUS}
  - RAM:  ${HOST_SUGGEST_SYNC_RAM_MB} MiB

Post-sync runtime (each container uses CPUs=${VM_VCPUS}, RAM=${VM_RAM_MB} MiB, Disk=${CONTAINER_DISK_SPACE_GB} GB):
  - CPU capacity: ${cpu_capacity} containers
  - RAM capacity: ${mem_capacity} containers
  - Disk capacity: ${disk_capacity} containers
  - Estimated total containers possible simultaneously: ${total_container_capacity} (limited by $(
      if (( total_container_capacity == cpu_capacity )); then echo "CPU"
      elif (( total_container_capacity == mem_capacity )); then echo "RAM"
      elif (( total_container_capacity == disk_capacity )); then echo "Disk"
      else echo "resources"; fi
    ))
  - Suggested number of clones (besides base): ${HOST_SUGGEST_CLONES}

Note: Containers use the same CPU/RAM allocation as VMs for consistency.
Lower overhead (~150MB vs ~200MB) may allow more containers on the same hardware.
TXT
  )
}

# show_capacity_suggestions: Display capacity summary in a dialog
# Purpose: Menu option to show user what their host can handle
show_capacity_suggestions(){
  detect_host_resources
  whiptail --title "Capacity Suggestions" --msgbox "$HOST_RES_SUMMARY" 25 78
}


################################################################################
# Configure Defaults (Interactive UI)
################################################################################

# configure_defaults: Interactive menu to edit reserves, VM/container sizes, and clearnet option
# Purpose: Allows users to reset to original host-aware defaults or tune resource allocation manually
# Options:
#   1. Reset to Original Values - Sets hardcoded defaults:
#      - Host reserves: 2 cores, 4GB RAM, 20GB disk
#      - Per-VM/container: 1 vCPU, 2GB RAM, 25GB disk
#      - Clearnet: Yes (base only, clones always Tor-only)
#   2. Choose Custom Values - Interactive prompts for each setting
# Returns: 0 on success (changes saved), 1 on cancel
# Side effects: Updates global variables (RESERVE_*, VM_*, CONTAINER_*, CLEARNET_OK)
#               Triggers detect_host_resources to recalculate capacity
configure_defaults(){
  detect_host_resources

  # Present menu: Reset to original or choose custom values
  local menu_choice
  menu_choice=$(whiptail --title "Configure Defaults" --menu \
    "Choose how to configure resource allocation:\n" 16 78 2 \
    1 "Reset to Original Values (host-aware)" \
    2 "Choose Custom Values" \
    3>&1 1>&2 2>&3) || return 1

  case "$menu_choice" in
    1)
      # Reset to original defaults
      RESERVE_CORES=2
      RESERVE_RAM_MB=4096
      VM_VCPUS=1
      VM_RAM_MB=2048
      CLEARNET_OK="yes"
      
      # Recompute suggestions with reset values
      detect_host_resources
      
      local reset_text="Settings have been reset to original defaults:\n
Reserves (host keeps):  ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB RAM
Runtime per VM:         ${VM_VCPUS} vCPU(s), ${VM_RAM_MB} MiB RAM
Clearnet on base VM:    ${CLEARNET_OK}

Host totals:            ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Available after reserve:${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Initial sync suggestion:
  vCPUs=${HOST_SUGGEST_SYNC_VCPUS}, RAM=${HOST_SUGGEST_SYNC_RAM_MB} MiB

Post-sync capacity estimate:
  Suggested clones alongside the base: ${HOST_SUGGEST_CLONES}"

      whiptail --title "Defaults Reset" --msgbox "$reset_text" 22 78
      return 0
      ;;
    2)
      # Continue with custom configuration
      ;;
    *)
      return 1
      ;;
  esac

  # 1) Edit numeric defaults via individual inputbox prompts
  local _rc _rram _vcpus _vram
  
  # Get reserve cores
  _rc=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nReserve cores for host:" \
    12 60 "$RESERVE_CORES" 3>&1 1>&2 2>&3) || return 1
  
  # Get reserve RAM
  _rram=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nReserve RAM for host (MiB):" \
    12 60 "$RESERVE_RAM_MB" 3>&1 1>&2 2>&3) || return 1
  
  # Get runtime VM vCPUs (used after IBD and for all clones)
  _vcpus=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nRuntime VM vCPUs (per VM after sync):" \
    12 60 "$VM_VCPUS" 3>&1 1>&2 2>&3) || return 1
  
  # Get runtime VM RAM (used after IBD and for all clones)
  _vram=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nRuntime VM RAM (MiB per VM after sync):" \
    12 60 "$VM_RAM_MB" 3>&1 1>&2 2>&3) || return 1

  # Validate integers
  [[ "$_rc" =~ ^[0-9]+$ ]]    || die "Reserve cores must be a non-negative integer."
  [[ "$_rram" =~ ^[0-9]+$ ]]  || die "Reserve RAM must be a non-negative integer."
  [[ "$_vcpus" =~ ^[0-9]+$ ]] || die "Runtime VM vCPUs must be a positive integer."
  [[ "$_vram" =~ ^[0-9]+$ ]]  || die "Runtime VM RAM must be a positive integer."
  (( _vcpus >= 1 )) || die "Runtime VM vCPUs must be at least 1."
  (( _vram >= 512 )) || die "Runtime VM RAM should be at least 512 MiB."

  # Apply edits
  RESERVE_CORES="$_rc"
  RESERVE_RAM_MB="$_rram"
  VM_VCPUS="$_vcpus"
  VM_RAM_MB="$_vram"

  # 2) Toggle clearnet option via radiolist
  # This determines if the base VM can use clearnet peers (clones are always Tor-only)
  local status_yes status_no
  status_yes="ON"; status_no="OFF"
  [[ "${CLEARNET_OK,,}" == "no" ]] && { status_yes="OFF"; status_no="ON"; }
  local choice
  choice=$(whiptail --title "Allow clearnet peers on one VM?" --radiolist \
    "If enabled, the BASE VM (only) will use Tor + clearnet.\nClones are forced to Tor-only regardless." \
    15 78 2 \
    "yes" "" "$status_yes" \
    "no"  "" "$status_no" \
    3>&1 1>&2 2>&3) || return 1
  CLEARNET_OK="$choice"

  # Recompute suggestions & show confirmation summary
  detect_host_resources
  local confirm_text="Please confirm these settings:\n
Reserves (host keeps):  ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB RAM
Runtime per VM:         ${VM_VCPUS} vCPU(s), ${VM_RAM_MB} MiB RAM
Clearnet on base VM:    ${CLEARNET_OK}

Host totals:            ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Available after reserve:${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Initial sync suggestion:
  vCPUs=${HOST_SUGGEST_SYNC_VCPUS}, RAM=${HOST_SUGGEST_SYNC_RAM_MB} MiB

Post-sync capacity estimate:
  Suggested clones alongside the base: ${HOST_SUGGEST_CLONES}"

  whiptail --title "Confirm Defaults" --yesno "$confirm_text" 22 78 || return 1
  return 0
}

# configure_defaults_direct: Jump directly to custom configuration screen
# Purpose: Used by Action 1 to skip the "Reset/Custom" menu and go straight to config
# This provides a streamlined flow for first-time setup
# Returns: 0 on success (changes saved), 1 on cancel
# Side effects: Updates global variables (RESERVE_*, VM_*, CLEARNET_OK)
configure_defaults_direct(){
  detect_host_resources

  # 1) Edit numeric defaults via individual inputbox prompts
  local _rc _rram _vcpus _vram
  
  # Get reserve cores
  _rc=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nReserve cores for host:" \
    12 60 "$RESERVE_CORES" 3>&1 1>&2 2>&3) || return 1
  
  # Get reserve RAM
  _rram=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nReserve RAM for host (MiB):" \
    12 60 "$RESERVE_RAM_MB" 3>&1 1>&2 2>&3) || return 1
  
  # Get runtime VM vCPUs (used after IBD and for all clones)
  _vcpus=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nRuntime VM vCPUs (per VM after sync):" \
    12 60 "$VM_VCPUS" 3>&1 1>&2 2>&3) || return 1
  
  # Get runtime VM RAM (used after IBD and for all clones)
  _vram=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nRuntime VM RAM (MiB per VM after sync):" \
    12 60 "$VM_RAM_MB" 3>&1 1>&2 2>&3) || return 1

  # Validate integers
  [[ "$_rc" =~ ^[0-9]+$ ]]    || die "Reserve cores must be a non-negative integer."
  [[ "$_rram" =~ ^[0-9]+$ ]]  || die "Reserve RAM must be a non-negative integer."
  [[ "$_vcpus" =~ ^[0-9]+$ ]] || die "Runtime VM vCPUs must be a positive integer."
  [[ "$_vram" =~ ^[0-9]+$ ]]  || die "Runtime VM RAM must be a positive integer."
  (( _vcpus >= 1 )) || die "Runtime VM vCPUs must be at least 1."
  (( _vram >= 512 )) || die "Runtime VM RAM should be at least 512 MiB."

  # Apply edits
  RESERVE_CORES="$_rc"
  RESERVE_RAM_MB="$_rram"
  VM_VCPUS="$_vcpus"
  VM_RAM_MB="$_vram"

  # 2) Toggle clearnet option via radiolist
  # This determines if the base VM can use clearnet peers (clones are always Tor-only)
  local status_yes status_no
  status_yes="ON"; status_no="OFF"
  [[ "${CLEARNET_OK,,}" == "no" ]] && { status_yes="OFF"; status_no="ON"; }
  local choice
  choice=$(whiptail --title "Allow clearnet peers on one VM?" --radiolist \
    "If enabled, the BASE VM (only) will use Tor + clearnet.\nClones are forced to Tor-only regardless." \
    15 78 2 \
    "yes" "" "$status_yes" \
    "no"  "" "$status_no" \
    3>&1 1>&2 2>&3) || return 1
  CLEARNET_OK="$choice"

  # Recompute suggestions & show confirmation summary
  detect_host_resources
  local confirm_text="Please confirm these settings:\n
Reserves (host keeps):  ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB RAM
Runtime per VM:         ${VM_VCPUS} vCPU(s), ${VM_RAM_MB} MiB RAM
Clearnet on base VM:    ${CLEARNET_OK}

Host totals:            ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Available after reserve:${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Initial sync suggestion:
  vCPUs=${HOST_SUGGEST_SYNC_VCPUS}, RAM=${HOST_SUGGEST_SYNC_RAM_MB} MiB

Post-sync capacity estimate:
  Suggested clones alongside the base: ${HOST_SUGGEST_CLONES}"

  whiptail --title "Confirm Defaults" --yesno "$confirm_text" 22 78 || return 1
  return 0
}

# configure_defaults_container: Container-specific configuration prompts
# Purpose: Same as configure_defaults_direct but with container-appropriate wording
# Note: Containers have lower overhead than VMs, so defaults can be more generous
configure_defaults_container(){
  detect_host_resources_container

  # 1) Edit numeric defaults via individual inputbox prompts
  local _rc _rram _vcpus _vram
  
  # Get reserve cores
  _rc=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nReserve cores for host:" \
    12 60 "$RESERVE_CORES" 3>&1 1>&2 2>&3) || return 1
  
  # Get reserve RAM
  _rram=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nReserve RAM for host (MiB):" \
    12 60 "$RESERVE_RAM_MB" 3>&1 1>&2 2>&3) || return 1
  
  # Get runtime container CPU limit (used after IBD and for all clones)
  # Note: Containers use --cpus flag (decimal value), not vCPUs
  _vcpus=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nRuntime container CPUs (per container after sync):\n(e.g., 1.0 = 1 full CPU, 0.5 = 50% of 1 CPU)" \
    14 60 "$VM_VCPUS" 3>&1 1>&2 2>&3) || return 1
  
  # Get runtime container RAM (used after IBD and for all clones)
  _vram=$(whiptail --title "Configure Defaults" --inputbox \
    "Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\n\nRuntime container RAM (MiB per container after sync):" \
    14 60 "$VM_RAM_MB" 3>&1 1>&2 2>&3) || return 1

  # Validate
  [[ "$_rc" =~ ^[0-9]+$ ]]    || die "Reserve cores must be a non-negative integer."
  [[ "$_rram" =~ ^[0-9]+$ ]]  || die "Reserve RAM must be a non-negative integer."
  [[ "$_vcpus" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "Runtime container CPUs must be a positive number (can be decimal)."
  [[ "$_vram" =~ ^[0-9]+$ ]]  || die "Runtime container RAM must be a positive integer."
  (( $(echo "$_vcpus >= 0.5" | bc -l) )) || die "Runtime container CPUs must be at least 0.5."
  (( _vram >= 512 )) || die "Runtime container RAM should be at least 512 MiB."

  # Apply edits
  RESERVE_CORES="$_rc"
  RESERVE_RAM_MB="$_rram"
  VM_VCPUS="$_vcpus"
  VM_RAM_MB="$_vram"

  # 2) Toggle clearnet option via radiolist
  local status_yes status_no
  status_yes="ON"; status_no="OFF"
  [[ "${CLEARNET_OK,,}" == "no" ]] && { status_yes="OFF"; status_no="ON"; }
  local choice
  choice=$(whiptail --title "Allow clearnet peers on base container?" --radiolist \
    "If enabled, the BASE CONTAINER (only) will use Tor + clearnet.\nClones are forced to Tor-only regardless." \
    15 78 2 \
    "yes" "" "$status_yes" \
    "no"  "" "$status_no" \
    3>&1 1>&2 2>&3) || return 1
  CLEARNET_OK="$choice"

  # Recompute suggestions & show confirmation summary
  detect_host_resources_container
  local confirm_text="Please confirm these settings:\n
Reserves (host keeps):     ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB RAM
Runtime per container:     ${VM_VCPUS} CPU(s), ${VM_RAM_MB} MiB RAM
Clearnet on base:          ${CLEARNET_OK}

Host totals:               ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Available after reserve:   ${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Initial sync suggestion:
  CPUs=${HOST_SUGGEST_SYNC_VCPUS}, RAM=${HOST_SUGGEST_SYNC_RAM_MB} MiB

Post-sync capacity estimate:
  Suggested clones alongside the base: ${HOST_SUGGEST_CLONES}
  
Note: Containers use the same CPU/RAM allocation as VMs for consistency.
Lower overhead may allow running more containers on the same hardware."

  whiptail --title "Confirm Defaults" --yesno "$confirm_text" 24 78 || return 1
  return 0
}

# prompt_sync_resources_container: Container-specific sync resource prompts
# Purpose: Same as prompt_sync_resources but with container-appropriate wording
prompt_sync_resources_container(){
  detect_host_resources_container

  # Abort early if insufficient resources
  if (( AVAIL_CORES < 1 || AVAIL_RAM_MB < 2048 )); then
    die "Insufficient resources.\n\nHost: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\nReserves: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB} MiB\nAvailable: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB} MiB\n\nNeed at least 1 core + 2048 MiB after reserve to create the base container."
  fi

  local banner="Host: ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Reserve kept: ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB
Available for initial sync: ${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB"

  local svcpus sram
  svcpus=$(whiptail --title "Initial Sync CPUs" --inputbox \
    "${banner}\n\nHow many CPUs for INITIAL sync (base container only)?\n\nMore CPUs = faster blockchain download & validation.\nSuggestion: ${HOST_SUGGEST_SYNC_VCPUS} (use all available)\n\nNote: After sync completes, will downsize to ${VM_VCPUS} CPUs.\nEnter CPU count:" \
    20 78 "${HOST_SUGGEST_SYNC_VCPUS}" 3>&1 1>&2 2>&3) || return 1
  [[ "$svcpus" =~ ^[0-9]+$ ]] || die "CPUs must be a positive integer."
  [[ "$svcpus" -ge 1 ]] || die "CPUs must be at least 1."
  (( svcpus <= AVAIL_CORES )) || die "Requested CPUs ($svcpus) exceeds available after reserve (${AVAIL_CORES})."

  sram=$(whiptail --title "Initial Sync RAM (MiB)" --inputbox \
    "${banner}\n\nHow much RAM for INITIAL sync (base container only)?\n\nMore RAM = faster sync (dbcache, more connections).\nSuggestion: ${HOST_SUGGEST_SYNC_RAM_MB} MiB (use all available)\n\nNote: After sync completes, will downsize to ${VM_RAM_MB} MiB.\nEnter RAM in MiB:" \
    20 78 "${HOST_SUGGEST_SYNC_RAM_MB}" 3>&1 1>&2 2>&3) || return 1
  [[ "$sram" =~ ^[0-9]+$ ]] || die "RAM must be a positive integer."
  [[ "$sram" -ge 2048 ]] || die "RAM should be at least 2048 MiB for IBD."
  (( sram <= AVAIL_RAM_MB )) || die "Requested RAM ($sram MiB) exceeds available after reserve (${AVAIL_RAM_MB} MiB)."

  SYNC_VCPUS="$svcpus"
  SYNC_RAM_MB="$sram"
  return 0
}


################################################################################
# Build Garbageman Binaries
################################################################################

# build_garbageman_host: Build on the host (DEPRECATED - DO NOT USE)
# WARNING: This function is kept for reference only. It builds Garbageman using
#          the host's glibc toolchain, which produces binaries incompatible with
#          Alpine Linux (which uses musl libc).
# Problem: Binary incompatibility - glibc binaries get "symbol not found" errors on musl
# Solution: Use build_garbageman_in_vm() instead, which builds inside Alpine
build_garbageman_host(){
  sudo -u "$(logname)" mkdir -p "$BUILD_DIR"
  if [[ ! -d "$BUILD_DIR/.git" ]]; then
    sudo -u "$(logname)" git clone --branch "$GM_BRANCH" --depth 1 "$GM_REPO" "$BUILD_DIR"
  fi
  pushd "$BUILD_DIR" >/dev/null
  sudo -u "$(logname)" cmake -S . -B build -DBUILD_GUI=OFF -DWITH_ZMQ=ON
  sudo -u "$(logname)" cmake --build build -j"$(nproc)"
  popd >/dev/null

  mkdir -p "$BIN_STAGING"
  cp "$BUILD_DIR/build/bin/bitcoind" "$BIN_STAGING/"
  cp "$BUILD_DIR/build/bin/bitcoin-cli" "$BIN_STAGING/"
  [[ -f "$BUILD_DIR/build/bin/bitcoin-tx" ]] && cp "$BUILD_DIR/build/bin/bitcoin-tx" "$BIN_STAGING/" || true
  chmod 0755 "$BIN_STAGING/bitcoind" "$BIN_STAGING/bitcoin-cli"
  [[ -f "$BIN_STAGING/bitcoin-tx" ]] && chmod 0755 "$BIN_STAGING/bitcoin-tx" || true
}

# build_garbageman_in_vm: Build Garbageman INSIDE the Alpine VM (CORRECT APPROACH)
# Args: $1 = path to the VM disk image (qcow2)
# Purpose: Compile Garbageman using Alpine's native toolchain (musl libc)
# Why: Host uses glibc, Alpine uses musl - binaries are NOT compatible
# How: Uses virt-customize to run commands inside the disk image
# Duration: 2+ hours depending on CPU
# Side effects:
#   - Installs build dependencies in the VM
#   - Clones Garbageman repo to /tmp/garbageman
#   - Compiles with CMake
#   - Installs binaries to /usr/local/bin/
#   - Removes build dependencies and cleans caches (saves ~700-1100 MB)
# Resource usage: Controlled by LIBGUESTFS_MEMSIZE and LIBGUESTFS_SMP env vars
build_garbageman_in_vm(){
  local disk="$1"
  local repo="${2:-$GM_REPO}"
  local branch="${3:-$GM_BRANCH}"
  local is_tag="${4:-false}"
  
  echo "=========================================="
  echo "Building Bitcoin inside Alpine VM..."
  echo "This will take 2+ hours depending on your CPU."
  echo ""
  echo "Build VM resources: ${SYNC_VCPUS} vCPUs, ${SYNC_RAM_MB} MiB RAM"
  echo "=========================================="
  echo ""
  
  # Configure libguestfs to use the sync resources (bigger values for faster builds)
  # These environment variables control the temporary VM that virt-customize spawns
  # Without these, libguestfs uses defaults (~500MB RAM, 1 vCPU) which is slow
  export LIBGUESTFS_MEMSIZE="${SYNC_RAM_MB}"
  export LIBGUESTFS_SMP="${SYNC_VCPUS}"
  
  # Step 1: Install build dependencies
  echo "Step 1/4: Installing build dependencies..."
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "apk update" \
    --run-command "apk add git cmake make g++ pkgconfig boost-dev libevent-dev zeromq-dev sqlite-dev linux-headers" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ Failed to install build dependencies"
    return 1
  fi
  echo "✓ Build dependencies installed"
  echo ""
  
  # Step 2: Clone the repository
  echo "Step 2/4: Cloning Bitcoin repository..."
  echo "Repository: $repo (${is_tag:+tag: }${branch})"
  
  # Use different git clone approach for tags vs branches
  local git_clone_cmd
  if [[ "$is_tag" == "true" ]]; then
    # For tags: clone then checkout specific tag
    git_clone_cmd="cd /tmp && git clone --depth 1 --branch '$branch' '$repo' garbageman"
  else
    # For branches: direct branch clone
    git_clone_cmd="cd /tmp && git clone --branch '$branch' --depth 1 '$repo' garbageman"
  fi
  
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "$git_clone_cmd" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ Failed to clone repository"
    return 1
  fi
  echo "✓ Repository cloned"
  echo ""
  
  # Step 3: Build (this is the slow part - 2+ hours)
  # Split into two commands (configure and compile) for better visibility
  echo "Step 3a/4: Configuring build with CMake..."
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "cd /tmp/garbageman && cmake -S . -B build -DBUILD_GUI=OFF -DWITH_ZMQ=ON -DCMAKE_BUILD_TYPE=Release" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ Failed to configure build with CMake"
    return 1
  fi
  echo "✓ CMake configuration complete"
  
  echo ""
  echo "Step 3b/4: Compiling Bitcoin (this takes 2+ hours)..."
  echo ""
  echo "⚠️  BUILD IN PROGRESS - DO NOT INTERRUPT ⚠️"
  echo ""
  echo "virt-customize is running cmake build inside a temporary VM."
  echo "Output is suppressed to avoid overwhelming the terminal."
  echo "The compilation IS happening - please be patient!"
  echo ""
  echo "Started at: $(date '+%H:%M:%S')"
  echo "Expected completion: $(date -d '+2 hours' '+%H:%M:%S') (approximate)"
  echo ""
  
  # Check if sudo keepalive is still running (prevents password prompts during long operations)
  if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
    if kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
      echo "✓ Sudo keepalive running (PID: $SUDO_KEEPALIVE_PID)"
    else
      echo "⚠ Sudo keepalive process died (PID was: $SUDO_KEEPALIVE_PID)"
    fi
  else
    echo "⚠ No sudo keepalive running (you may be prompted for password later)"
  fi
  echo ""
  
  echo "You can monitor CPU usage in another terminal with: top"
  echo "Look for 'qemu' process at ~100% CPU as confirmation build is active."
  echo "-------------------------------------------"
  echo ""
  
  # Run the build WITHOUT --verbose to avoid overwhelming output
  # The build takes 2+ hours and runs silently
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "cd /tmp/garbageman && cmake --build build -j\$(nproc)" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo ""
    echo "❌ Failed to compile Garbageman"
    return 1
  fi
  
  echo ""
  echo "-------------------------------------------"
  echo "✓ Compilation successful!"
  echo "Completed at: $(date '+%H:%M:%S')"
  echo ""
  
  # Step 4: Install binaries and clean up
  # This saves 700-1100 MB by removing build deps, docs, man pages, caches
  # Note: Keep runtime libraries (libstdc++, libgcc_s, zeromq, sqlite-libs, boost-libs, libevent)
  #       Only remove build tools and *-dev packages
  echo "Step 4/4: Installing binaries and cleaning up..."
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "cp /tmp/garbageman/build/bin/bitcoind /usr/local/bin/" \
    --run-command "cp /tmp/garbageman/build/bin/bitcoin-cli /usr/local/bin/" \
    --run-command "chmod 0755 /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli" \
    --run-command "rm -rf /tmp/garbageman" \
    --run-command "apk del git cmake make pkgconfig linux-headers" \
    --run-command "apk add zeromq sqlite-libs boost-libs libevent" \
    --run-command "apk del boost-dev libevent-dev zeromq-dev sqlite-dev" \
    --run-command "rm -rf /var/cache/apk/*" \
    --run-command "rm -rf /root/.cache /tmp/*" \
    --run-command "find /usr/share/doc -type f -delete 2>/dev/null || true" \
    --run-command "find /usr/share/man -type f -delete 2>/dev/null || true" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ Failed to install binaries or cleanup"
    return 1
  fi
  echo "✓ Installation and cleanup complete"
  echo ""
  echo "=========================================="
  echo "✅ Garbageman compiled successfully inside Alpine VM!"
  echo "=========================================="
  echo ""
}


################################################################################
# Alpine ISO Download
################################################################################

# select_latest_alpine_iso: Download the latest Alpine "virt" ISO
# Args: $1 = temporary directory to store the ISO
# Returns: Path to downloaded ISO
# Purpose: Fetches the latest stable Alpine "virt" ISO from the mirror
# Note: "virt" flavor is optimized for VMs (smaller, no desktop packages)
select_latest_alpine_iso(){
  local tmpd="$1"
  local iso
  # Scrape the mirror directory listing to find the latest virt ISO
  iso="$(curl -fsSL "$ALPINE_MIRROR/" | grep -oE 'alpine-virt-[0-9.]+-x86_64\.iso' | sort -V | tail -n1)"
  [[ -n "$iso" ]] || die "Could not resolve latest alpine-virt ISO at $ALPINE_MIRROR"
  curl -fLo "$tmpd/alpine-virt.iso" "$ALPINE_MIRROR/$iso"
  echo "$tmpd/alpine-virt.iso"
}


# ----------------- Seed ISO (answerfile + post-install) -----------------
# We embed a post-install script that:
#   - installs Tor & sets cookie auth
#   - writes /etc/bitcoin/bitcoin.conf based on CLEARNET_OK
#   - creates a systemd unit for bitcoind
#   - powers off (host then injects compiled binaries)
make_seed_iso(){
  local seeddir="$1"; local out="$2"
  
  # Ensure directories exist
  mkdir -p "$seeddir"
  
  # Alpine answerfile for unattended installation
  cat > "$seeddir/answers" <<'EOF'
KEYMAPOPTS="none"
HOSTNAMEOPTS="gm-node"
DEVDOPTS="mdev"
INTERFACESOPTS="auto lo
iface lo inet loopback
auto eth0
iface eth0 inet dhcp"
DNSOPTS="none"
TIMEZONEOPTS="UTC"
PROXYOPTS="none"
APKREPOSOPTS="-1 -c"
USEROPTS="-a -u -g audio,video,netdev,wheel bitcoin"
SSHDOPTS="openssh"
NTPOPTS="chrony"
DISKOPTS="-m sys /dev/vda"
LBUOPTS="none"
APKCACHEOPTS="none"
EOF

  # Create autorun script that will trigger the installation
  cat > "$seeddir/autorun.sh" <<'EOF'
#!/bin/sh
# Auto-installation script for Alpine Linux
set -e

echo "Starting automatic Alpine installation..."
sleep 10  # Wait for system to be ready

# Mount the seed ISO to access answers file
mkdir -p /mnt/seed
mount /dev/sr1 /mnt/seed 2>/dev/null || mount /dev/sr0 /mnt/seed || {
    echo "Could not mount seed ISO, trying manual setup"
    exit 1
}

# Copy answers to expected location
cp /mnt/seed/answers /tmp/answers

# Run setup-alpine with answers
export ERASE_DISKS="/dev/vda"
setup-alpine -e -f /tmp/answers

echo "Installation complete, rebooting..."
reboot
EOF

  chmod +x "$seeddir/autorun.sh"

  # Produce the bitcoin.conf content depending on CLEARNET_OK
  local BTC_CONF_TOR_ONLY
  BTC_CONF_TOR_ONLY='server=1
daemon=1
# Resource tuning for small VM
prune=750
dbcache=256
maxconnections=12
# Tor-only networking
onlynet=onion
proxy=127.0.0.1:9050
listen=1
listenonion=1
discover=0
dnsseed=0
# Talk to Tor control for auto v3 onion service
torcontrol=127.0.0.1:9051
# RPC (local only)
rpcauth=
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
# Keep default assumevalid enabled
assumevalid=1'

  local BTC_CONF_TOR_AND_CLEAR
  BTC_CONF_TOR_AND_CLEAR='server=1
daemon=1
# Resource tuning for VM
prune=750
dbcache=256
maxconnections=32
# Tor + clearnet
# (No '"'"'onlynet=onion'"'"' so clearnet is allowed; keep Tor enabled too.)
proxy=127.0.0.1:9050
listen=1
listenonion=1
discover=1
dnsseed=1
torcontrol=127.0.0.1:9051
# RPC (local only)
rpcauth=
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
assumevalid=1'

  # Decide which config block to embed for the BASE VM
  local BTC_CONF_BASE="$BTC_CONF_TOR_ONLY"
  [[ "${CLEARNET_OK,,}" == "yes" ]] && BTC_CONF_BASE="$BTC_CONF_TOR_AND_CLEAR"

  # Post-install: packages, Tor config, bitcoin.conf, systemd unit, then poweroff
  cat > "$seeddir/post-install.sh" <<EOF
#!/bin/sh
set -eux

# Update/upgrade base system and install essentials
apk update && apk upgrade -U
apk add --no-cache tor sudo ca-certificates bash shadow su-exec

# Ensure bitcoin user/group exists; add to 'tor' for cookie auth
id -u ${BITCOIN_USER} >/dev/null 2>&1 || adduser -D ${BITCOIN_USER}
addgroup -S ${BITCOIN_GROUP} || true
addgroup ${BITCOIN_USER} ${BITCOIN_GROUP} || true
addgroup ${BITCOIN_USER} ${TOR_GROUP} || true

# Tor cookie auth + readable cookie for group; also Socks & Control ports
rc-update add tor default
sed -i '/^#*ControlPort/d;/^#*CookieAuthentication/d;/^#*CookieAuthFileGroupReadable/d;/^#*DataDirectoryGroupReadable/d;/^#*SocksPort/d' /etc/tor/torrc || true
cat >> /etc/tor/torrc <<'TORRC'
ControlPort 9051
CookieAuthentication 1
CookieAuthFileGroupReadable 1
DataDirectoryGroupReadable 1
SocksPort 9050
HiddenServiceDir /var/lib/tor/bitcoin-service
HiddenServiceVersion 3
HiddenServicePort 8333 127.0.0.1:8333
TORRC
rc-service tor restart

# Bitcoin directories & config
install -d -m0750 -o ${BITCOIN_USER} -g ${BITCOIN_GROUP} ${BITCOIN_DATADIR}
install -d -m0755 -o ${BITCOIN_USER} -g ${BITCOIN_GROUP} /etc/bitcoin

# BASE VM bitcoin.conf (Tor-only or Tor+clearnet based on CLEARNET_OK)
cat > /etc/bitcoin/bitcoin.conf <<'CONF'
${BTC_CONF_BASE}
CONF
chown ${BITCOIN_USER}:${BITCOIN_GROUP} /etc/bitcoin/bitcoin.conf
chmod 0640 /etc/bitcoin/bitcoin.conf

# Systemd unit for bitcoind
cat > /etc/systemd/system/bitcoind.service <<'UNIT'
[Unit]
Description=Bitcoin daemon (Garbageman)
After=network-online.target tor.service
Wants=network-online.target tor.service

[Service]
User=${BITCOIN_USER}
Group=${BITCOIN_GROUP}
Type=simple
ExecStart=/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=${BITCOIN_DATADIR}
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutStopSec=60s
Restart=on-failure
RestartSec=5s
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable bitcoind

# Make console friendlier in serial envs (optional)
sed -i 's/tty1/ttyS0/' /etc/inittab || true

# Done — power off so host can inject compiled binaries
poweroff
EOF

  chmod +x "$seeddir/post-install.sh"

  # Build the seed ISO with answers, autorun, and post-install scripts
  if ! xorriso -as genisoimage -V GMSEED -o "$out" -graft-points \
    /answers="$seeddir/answers" \
    /autorun.sh="$seeddir/autorun.sh" \
    /post-install.sh="$seeddir/post-install.sh" >/dev/null 2>&1; then
    die "Failed to create seed ISO with xorriso. Please ensure xorriso is installed."
  fi
}


################################################################################
# SSH Key Injection for Monitoring
################################################################################

# ensure_monitor_ssh: Inject temporary SSH key into VM for monitoring access
# Purpose: Allows script to SSH into VM to poll bitcoin-cli RPC
# Flow:
#   1. Generate ed25519 SSH key pair if it doesn't exist
#   2. Stop VM if running (virt-customize requires exclusive disk access)
#   3. Inject public key into /root/.ssh/authorized_keys
#   4. Configure SSH to allow root login with key
# Security: Uses dedicated monitoring key (not user's main SSH keys)
# Side effects: Creates ~/.cache/gm-monitor/ directory with SSH keys
ensure_monitor_ssh(){
  mkdir -p "$SSH_KEY_DIR"; chmod 700 "$SSH_KEY_DIR"
  [[ -f "$SSH_KEY_PATH" ]] || ssh-keygen -t ed25519 -N "" -f "$SSH_KEY_PATH" -q
  local pub; pub="$(cat "${SSH_KEY_PATH}.pub")"
  
  # Ensure VM is fully stopped before attempting disk writes
  ensure_vm_stopped "$VM_NAME" || die "Cannot prepare SSH injection because domain did not stop."

  # Inject SSH key and configure sshd (openssh already installed during image build)
  sudo virt-customize -d "$VM_NAME" \
    --no-selinux-relabel \
    --ssh-inject "root:string:$pub" \
    --run-command "mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys" \
    --run-command "grep -qF '$pub' /root/.ssh/authorized_keys || echo '$pub' >> /root/.ssh/authorized_keys" \
    --run-command "sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config" \
    2>&1 | grep -v "random seed" >&2
}

################################################################################
# SSH Monitoring & VM Network Discovery
################################################################################

# vm_ip: Get the IP address of a running VM
# Args: $1 = VM name (optional, defaults to $VM_NAME)
# Returns: IP address string (empty if not found)
# Strategy: Try QEMU guest agent first (more reliable), fallback to libvirt DHCP lease
vm_ip(){
  local vmname="${1:-$VM_NAME}"
  local ip
  # QEMU guest agent provides more reliable IP discovery (requires qemu-guest-agent in VM)
  # Skip loopback (127.x.x.x) addresses, get first real IPv4
  ip="$(sudo virsh domifaddr "$vmname" --source agent 2>/dev/null | awk '/ipv4/ {print $4}' | sed 's#/.*##' | grep -v '^127\.' | head -n1)"
  # Fallback to libvirt's DHCP lease tracking
  [[ -n "$ip" ]] || ip="$(sudo virsh domifaddr "$vmname" 2>/dev/null | awk '/ipv4/ {print $4}' | sed 's#/.*##' | head -n1)"
  echo "$ip"
}

# dump_firstboot_log: Extract and display first-boot log from VM disk image
# Args: $1 = path to disk image
# Purpose: Debug helper for when VM networking doesn't come up
# Note: Uses guestfish to read files from the disk image (VM must be stopped)
dump_firstboot_log(){
  local disk="$1"
  echo "Attempting to extract first-boot log from image: $disk"
  
  # Try to extract the log file if it exists
  if sudo guestfish -a "$disk" --ro -i <<'GUESTEOF' 2>/dev/null
run
mount /dev/sda1 /
exists /var/log/first-boot.log
GUESTEOF
  then
    echo "--- first-boot.log found, extracting ---"
    sudo guestfish -a "$disk" --ro -i <<'GUESTEOF' 2>/dev/null || true
run
mount /dev/sda1 /
download /var/log/first-boot.log /tmp/guest-firstboot.log
GUESTEOF
    if [[ -f /tmp/guest-firstboot.log ]]; then
      cat /tmp/guest-firstboot.log
      rm -f /tmp/guest-firstboot.log
    fi
  else
    echo "No first-boot log found (/var/log/first-boot.log does not exist)."
    echo "Checking if first-boot service was installed correctly..."
    
    # Check if the service files exist
    sudo guestfish -a "$disk" --ro -i <<'GUESTEOF' 2>/dev/null || true
run
mount /dev/sda1 /
ls /etc/init.d/
ls /opt/
GUESTEOF
  fi
}

# gssh: SSH wrapper with monitoring key and connection options
# Args: $1 = IP address, $@ = command to run
# Purpose: Connect to VMs for monitoring without password prompts
# Note: Uses temporary SSH key injected by ensure_monitor_ssh()
#       Automatically removes stale host keys to avoid conflicts when VMs are recreated
gssh(){
  local ip="$1"; shift
  
  # Remove any existing host key for this IP to avoid conflicts when VMs are recreated
  # This is safe for our use case since we control both ends and use key-based auth
  ssh-keygen -f "$SSH_KEY_DIR/known_hosts" -R "$ip" >/dev/null 2>&1 || true
  
  ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile="$SSH_KEY_DIR/known_hosts" \
      -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      -p "$SSH_PORT" \
      "${SSH_USER}@${ip}" "$@"
}


# ----------------- Create Prebuilt Alpine Image -----------------
create_prebuilt_alpine_image(){
  local disk="$1"
  echo "Creating prebuilt Alpine Linux image..."
  
  # Create Alpine image
  if ! create_alpine_image_alternative "$disk"; then
    die "Alpine image creation failed"
  fi
  
  echo "✅ Alpine image created successfully at: $disk"
  echo "Configuration will be handled by first-boot script when VM starts."
  return 0
  
  echo "Configuring Alpine image..."
  
  # Decide which bitcoin.conf to use based on CLEARNET_OK
  local btc_conf_content
  if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
    btc_conf_content="server=1
daemon=1
prune=750
dbcache=256
maxconnections=32
proxy=127.0.0.1:9050
listen=1
listenonion=1
discover=1
dnsseed=1
torcontrol=127.0.0.1:9051
rpcauth=
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
assumevalid=1"
  else
    btc_conf_content="server=1
daemon=1
prune=750
dbcache=256
maxconnections=12
onlynet=onion
proxy=127.0.0.1:9050
listen=1
listenonion=1
discover=0
dnsseed=0
torcontrol=127.0.0.1:9051
rpcauth=
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
assumevalid=1"
  fi
  
  # Configure bitcoin.conf and systemd service
  virt-customize -a "$disk" \
    --no-selinux-relabel \
    --write /etc/bitcoin/bitcoin.conf:"$btc_conf_content" \
    --run-command 'chown bitcoin:bitcoin /etc/bitcoin/bitcoin.conf' \
    --run-command 'chmod 644 /etc/bitcoin/bitcoin.conf'
    
  # Create systemd service for bitcoind
  local systemd_service="[Unit]
Description=Bitcoin daemon
After=network.target

[Service]
User=bitcoin
Group=bitcoin
Type=simple
ExecStart=/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutStopSec=60s
Restart=on-failure
RestartSec=5s
PrivateTmp=true
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target"
  
  virt-customize -a "$disk" \
    --no-selinux-relabel \
    --write /etc/systemd/system/bitcoind.service:"$systemd_service" \
    --run-command 'systemctl enable bitcoind' \
    --run-command 'passwd -d root' \
    --run-command 'passwd -d bitcoin'
    
  echo "Prebuilt Alpine image created successfully at: $disk"
}

create_alpine_image_alternative(){
  local disk="$1"
  echo "Creating minimal Alpine image with kernel..."
  
  local tmpd; tmpd="$(mktemp -d -p /var/tmp)"
  trap "rm -rf '$tmpd'" RETURN EXIT INT TERM
  chmod 755 "$tmpd"
  
  # Download Alpine mini root filesystem
  echo "Downloading Alpine mini root filesystem..."
  local alpine_version="3.18.4"
  local alpine_url="https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64/alpine-minirootfs-${alpine_version}-x86_64.tar.gz"
  
  if ! curl -fsSL "$alpine_url" -o "$tmpd/alpine-mini.tar.gz"; then
    echo "Failed to download Alpine ${alpine_version}, trying latest..."
    if ! curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz" \
      -o "$tmpd/alpine-mini.tar.gz"; then
      rm -rf "$tmpd"
      echo "❌ Failed to download Alpine mini root filesystem"
      return 1
    fi
  fi
  
  echo "Verifying download..."
  if [[ ! -f "$tmpd/alpine-mini.tar.gz" ]] || [[ ! -s "$tmpd/alpine-mini.tar.gz" ]]; then
    rm -rf "$tmpd"
    echo "❌ Downloaded Alpine file is empty or missing"
    return 1
  fi
  
  # Download Alpine kernel and initramfs separately (no network needed during install)
  echo "Downloading Alpine kernel components..."
  local kernel_base="https://dl-cdn.alpinelinux.org/alpine/v3.18/releases/x86_64"
  if ! curl -fsSL "${kernel_base}/linux-virt-6.1.55-r0.apk" -o "$tmpd/linux-virt.apk" 2>/dev/null; then
    echo "Kernel download failed, will install via network later..."
  fi
    
  echo "Creating qcow2 disk image..."
  if ! sudo qemu-img create -f qcow2 "$disk" "${VM_DISK_GB}G"; then
    rm -rf "$tmpd"
    echo "❌ Failed to create qcow2 image"
    return 1
  fi
  
  echo "Setting up Alpine Linux in disk image..."
  
  # Create guestfish script with manual partitioning to leave space for GRUB
  # GRUB needs ~1MB of space before the first partition for embedding
  cat > "$tmpd/setup.fish" <<'FISHEOF'
run
part-init /dev/sda mbr
part-add /dev/sda primary 2048 -1
part-set-bootable /dev/sda 1 true
mkfs ext4 /dev/sda1
mount /dev/sda1 /
FISHEOF

  echo "Running guestfish setup (step 1: basic setup)..."
  if ! sudo guestfish -a "$disk" < "$tmpd/setup.fish"; then
    rm -rf "$tmpd"
    echo "❌ Failed to create partition and filesystem"
    return 1
  fi
  
  echo "Running guestfish setup (step 2: create bootable Alpine system)..."
  
  if ! sudo guestfish -a "$disk" -v <<EOF
run
mount /dev/sda1 /
ls /
# Extract Alpine filesystem
tgz-in $tmpd/alpine-mini.tar.gz /
ls /
EOF
  then
    rm -rf "$tmpd"
    echo "❌ Failed to extract Alpine filesystem"
    echo "Debug: Checking what's in the disk after failure..."
    sudo guestfish -a "$disk" -r <<EOF || true
run
list-filesystems
mount /dev/sda1 /
ls /
EOF
    return 1
  fi
  
  echo "Running guestfish setup (step 3: configure Alpine)..."
  
  # Create APK repositories file
  cat > "$tmpd/repositories" <<'REPO_EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.18/main
https://dl-cdn.alpinelinux.org/alpine/v3.18/community
REPO_EOF

  # Create DNS configuration file
  cat > "$tmpd/resolv.conf" <<'DNS_EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
DNS_EOF

  if ! sudo guestfish -a "$disk" <<EOF
run  
mount /dev/sda1 /
copy-in $tmpd/repositories /etc/apk/
copy-in $tmpd/resolv.conf /etc/
EOF
  then
    rm -rf "$tmpd"
    echo "❌ Failed to install Alpine packages"
    return 1
  fi
  
  echo "Running guestfish setup (step 4: create first-boot script and basic config)..."
  
  # Create first-boot script for package installation and user setup
  cat > "$tmpd/first-boot.sh" <<'BOOT_EOF'
#!/bin/sh
# Alpine first-boot setup script

echo "$(date): Starting first-boot setup" >> /var/log/first-boot.log

# Wait for network connectivity (retry up to 30 seconds)
echo "$(date): Waiting for network connectivity" >> /var/log/first-boot.log
for i in $(seq 1 30); do
  if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
    echo "$(date): Network is up after $i seconds" >> /var/log/first-boot.log
    break
  fi
  sleep 1
done

# Install additional packages (kernel, openssh, and tor already installed during image build)
echo "$(date): Installing additional packages (bash, shadow, qemu-guest-agent)" >> /var/log/first-boot.log
apk update >> /var/log/first-boot.log 2>&1
apk add sudo bash shadow qemu-guest-agent >> /var/log/first-boot.log 2>&1

# Configure OpenRC services
echo "$(date): Configuring OpenRC services" >> /var/log/first-boot.log
rc-update add devfs sysinit
rc-update add dmesg sysinit  
rc-update add mdev sysinit
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot
rc-update add networking boot
rc-update add urandom boot
rc-update add local default
rc-update add sshd default
rc-update add qemu-guest-agent default

# Ensure networking is properly started
echo "$(date): Ensuring networking is running" >> /var/log/first-boot.log
service networking restart >> /var/log/first-boot.log 2>&1

# Start qemu-guest-agent immediately so IP discovery works
echo "$(date): Starting qemu-guest-agent" >> /var/log/first-boot.log
service qemu-guest-agent start >> /var/log/first-boot.log 2>&1

# Create bitcoin user if it doesn't exist (should already exist from image build)
echo "$(date): Configuring bitcoin user" >> /var/log/first-boot.log
id -u bitcoin >/dev/null 2>&1 || adduser -D -s /bin/bash bitcoin
adduser bitcoin wheel 2>/dev/null || true
echo 'bitcoin ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Add bitcoin user to tor group so it can read the Tor control cookie
# This is needed for torcontrol authentication (CookieAuthFileGroupReadable)
# First check what group owns tor files
TOR_GROUP=$(stat -c '%G' /var/lib/tor 2>/dev/null || echo "tor")
if getent group "$TOR_GROUP" >/dev/null 2>&1; then
    adduser bitcoin "$TOR_GROUP" >> /var/log/first-boot.log 2>&1 || true
fi

# Ensure directories exist and have correct ownership
mkdir -p /var/lib/bitcoin
mkdir -p /etc/bitcoin
chown bitcoin:bitcoin /var/lib/bitcoin /etc/bitcoin

# Set ownership of bitcoin binaries (installed during build phase)
echo "$(date): Setting ownership of bitcoin binaries" >> /var/log/first-boot.log
chown bitcoin:bitcoin /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli 2>> /var/log/first-boot.log

# Enable root login temporarily for first-boot setup
echo "\$(date): Configuring SSH for first boot" >> /var/log/first-boot.log
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo 'root:garbageman' | chpasswd

# Start SSH service
service sshd start || /etc/init.d/sshd start || {
  echo "\$(date): Starting sshd manually" >> /var/log/first-boot.log
  /usr/sbin/sshd -D &
}

# After SSH is running and host can connect, disable password authentication
echo "\$(date): Securing SSH (disabling password auth)" >> /var/log/first-boot.log
sleep 3  # Brief delay to ensure SSH is fully started
sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
service sshd reload 2>/dev/null || /etc/init.d/sshd reload 2>/dev/null || pkill -HUP sshd

# Test network connectivity
echo "$(date): Testing network connectivity" >> /var/log/first-boot.log
ip addr show >> /var/log/first-boot.log
route -n >> /var/log/first-boot.log
ping -c 1 8.8.8.8 >> /var/log/first-boot.log 2>&1

# Wait for Tor SOCKS proxy and start bitcoind
echo "$(date): Waiting for Tor SOCKS proxy to be ready" >> /var/log/first-boot.log
for i in $(seq 1 60); do
  if nc -z 127.0.0.1 9050 2>/dev/null; then
    echo "$(date): Tor SOCKS proxy is ready after $i seconds" >> /var/log/first-boot.log
    break
  fi
  sleep 1
done

# Start bitcoind manually
echo "$(date): Starting bitcoind" >> /var/log/first-boot.log
su - bitcoin -s /bin/sh -c '/usr/local/bin/bitcoind -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin' >> /var/log/first-boot.log 2>&1 &
sleep 2

# Verify bitcoind started
if pgrep -x bitcoind >/dev/null; then
  echo "$(date): bitcoind started successfully" >> /var/log/first-boot.log
else
  echo "$(date): ERROR: bitcoind failed to start" >> /var/log/first-boot.log
fi

echo "$(date): First-boot setup complete" >> /var/log/first-boot.log

# Remove this script after execution
rc-update del first-boot default
rm /etc/init.d/first-boot
rm /opt/first-boot.sh

BOOT_EOF

  # Create a small wrapper that busybox init can call directly
  cat > "$tmpd/run-first-boot.sh" <<'WRAPPER_EOF'
#!/bin/sh
# Wrapper executed from /etc/inittab to safely run first-boot once
if [ ! -f /var/log/first-boot-done ] && [ -x /opt/first-boot.sh ]; then
  echo "$(date): run-first-boot wrapper invoking first-boot" >> /var/log/first-boot.log
  /opt/first-boot.sh >> /var/log/first-boot.log 2>&1
  touch /var/log/first-boot-done
fi
WRAPPER_EOF

  # Create OpenRC service for first-boot script
  cat > "$tmpd/first-boot" <<'SERVICE_EOF'
#!/sbin/openrc-run

description="First boot setup for Alpine VM"
depend() {
    after localmount bootmisc
    before networking
}

start() {
    ebegin "Running first-boot setup"
    /opt/first-boot.sh > /var/log/first-boot-service.log 2>&1
    eend $?
}
SERVICE_EOF

  # Create network interfaces file
  cat > "$tmpd/interfaces" <<'NET_EOF'
auto lo
iface lo inet loopback

auto eth0  
iface eth0 inet dhcp
NET_EOF

  # Create hosts file
  cat > "$tmpd/hosts" <<'HOSTS_EOF'
127.0.0.1 localhost gm-node
::1 localhost ipv6-localhost ipv6-loopback
HOSTS_EOF

  # Create hostname file
  echo "gm-node" > "$tmpd/hostname"

  # Create OpenRC-compatible inittab for Alpine
  cat > "$tmpd/inittab" <<'INITTAB_EOF'
# /etc/inittab for Alpine Linux with OpenRC

# System initialization (runs once)
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Set up getty's on tty devices
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6

# Put a getty on the serial line (for VMs and serial consoles)
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100

# Stuff to do for the 3-finger salute
::ctrlaltdel:/sbin/reboot

# Stuff to do before rebooting
::shutdown:/sbin/openrc shutdown
INITTAB_EOF

  # Create rc.local style startup script
  cat > "$tmpd/rc.local" <<'RC_EOF'
#!/bin/sh
# Simple rc.local for Alpine first-boot
if [ -f /opt/first-boot.sh ] && [ ! -f /var/log/first-boot-done ]; then
  /opt/first-boot.sh
  touch /var/log/first-boot-done
fi
RC_EOF

  # Create simple local.d script as backup (runs automatically)
  cat > "$tmpd/00-first-boot.start" <<'LOCAL_EOF'
#!/bin/sh
# First-boot via local.d - should run even without full OpenRC
if [ ! -f /var/log/first-boot-done ]; then
  echo "$(date): local.d first-boot starting" > /var/log/first-boot.log
  /opt/first-boot.sh >> /var/log/first-boot.log 2>&1
  echo "$(date): local.d first-boot completed" >> /var/log/first-boot.log
  touch /var/log/first-boot-done
fi
LOCAL_EOF

  # Create local service file for OpenRC (if it becomes available)
  cat > "$tmpd/local" <<'SERVICE_EOF'
#!/sbin/openrc-run

depend() { after *; }

start() {
  if [ -d /etc/local.d ]; then
    for script in /etc/local.d/*.start; do
      [ -x "\$script" ] && "\$script"
    done
  fi
  [ -x /etc/rc.local ] && /etc/rc.local
}
SERVICE_EOF

  if ! sudo guestfish -a "$disk" <<EOF
run
mount /dev/sda1 /
mkdir-p /etc/local.d
mkdir-p /etc/runlevels/sysinit
mkdir-p /etc/runlevels/boot
mkdir-p /etc/runlevels/default
mkdir-p /etc/runlevels/shutdown
copy-in $tmpd/first-boot.sh /opt/
copy-in $tmpd/run-first-boot.sh /opt/
copy-in $tmpd/first-boot /etc/init.d/
copy-in $tmpd/local /etc/init.d/
copy-in $tmpd/00-first-boot.start /etc/local.d/
copy-in $tmpd/interfaces /etc/network/
copy-in $tmpd/hosts /etc/
copy-in $tmpd/hostname /etc/
copy-in $tmpd/inittab /etc/
copy-in $tmpd/rc.local /etc/
command "chmod +x /opt/first-boot.sh"
command "chmod +x /opt/run-first-boot.sh"
command "chmod +x /etc/init.d/first-boot"
command "chmod +x /etc/init.d/local"
command "chmod +x /etc/local.d/00-first-boot.start"
command "chmod +x /etc/rc.local"
# Create local service file
# Only link services that exist at image creation time  
ln-sf /etc/init.d/first-boot /etc/runlevels/default/first-boot
ln-sf /etc/init.d/local /etc/runlevels/default/local
EOF
  then
    rm -rf "$tmpd"
    echo "❌ Failed to configure Alpine system"
    return 1
  fi

  echo "Installing minimal bootloader using guestfish..."
  
  # Create SYSLINUX bootloader config (simpler than GRUB)
  cat > "$tmpd/syslinux.cfg" <<'SYSLINUX_EOF'
DEFAULT linux
LABEL linux
  KERNEL vmlinuz-virt
  INITRD initramfs-virt
  APPEND root=/dev/sda1 modules=sd-mod,usb-storage,ext4 console=tty0 console=ttyS0,115200 rootfstype=ext4 rw init=/sbin/init
SYSLINUX_EOF

  cat > "$tmpd/fstab" <<'FSTAB_EOF'
/dev/vda1 / ext4 defaults 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
tmpfs /tmp tmpfs defaults 0 0
FSTAB_EOF

  # Create kernel installation script as separate file
  cat > "$tmpd/install-kernel.sh" <<'KERNEL_EOF'
#!/bin/sh
apk update
apk add linux-virt syslinux
cp /boot/syslinux/syslinux.cfg /boot/
extlinux --install /boot
dd bs=440 count=1 conv=notrunc if=/usr/share/syslinux/mbr.bin of=/dev/sda
KERNEL_EOF

  # Use guestfish to set up bootloader (avoiding virt-customize issues)
  if ! sudo guestfish -a "$disk" <<EOF
run
mount /dev/sda1 /
# Create basic system files
copy-in $tmpd/fstab /etc/
write /etc/hostname "gm-node"
mkdir-p /boot
mkdir-p /boot/syslinux
copy-in $tmpd/syslinux.cfg /boot/syslinux/
copy-in $tmpd/install-kernel.sh /boot/
command "chmod +x /boot/install-kernel.sh"
EOF
  then
    rm -rf "$tmpd"
    echo "❌ Failed to configure bootloader"
    return 1
  fi

  rm -rf "$tmpd"
  
  echo "✅ Alpine image creation completed successfully"
}

create_ubuntu_cloud_image(){
  local disk="$1"
  echo "Creating Ubuntu cloud image as fallback..."
  
  # Use virt-builder with Ubuntu (more reliable)
  if virt-builder ubuntu-22.04 \
    --output "$disk" \
    --format qcow2 \
    --size "${VM_DISK_GB}G" \
    --root-password disabled \
    --hostname gm-node \
    --timezone UTC \
    --install openssh-server,tor,sudo,curl \
    --run-command 'systemctl enable ssh tor' \
    --run-command 'useradd -m -s /bin/bash bitcoin' \
    --run-command 'usermod -aG sudo bitcoin' \
    --run-command 'echo "bitcoin ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers' \
    --mkdir /var/lib/bitcoin \
    --run-command 'chown bitcoin:bitcoin /var/lib/bitcoin' \
    --mkdir /etc/bitcoin \
    --run-command 'chown bitcoin:bitcoin /etc/bitcoin' \
    --run-command 'passwd -d bitcoin' \
    --run-command 'passwd -d root'; then
    echo "✅ Ubuntu cloud image created successfully"
    return 0
  else
    echo "❌ Ubuntu cloud image creation failed"
    return 1
  fi
}

# ----------------- Create Base VM (with pre-creation config & confirmation) -----------------

# prompt_sync_resources: Interactive prompts for initial sync vCPU and RAM allocation
# Purpose: Get user confirmation/customization of sync resources before VM creation
# Flow:
#   1. Detect host resources and calculate suggestions
#   2. Validate that minimum resources are available (1 core, 2GB RAM after reserves)
#   3. Prompt for vCPUs (with suggested value based on available cores)
#   4. Prompt for RAM (with suggested value based on available memory)
#   5. Validate inputs don't exceed available resources
# Side effects: Sets SYNC_VCPUS and SYNC_RAM_MB global variables
# Returns: 0 on success, 1 if user cancels
prompt_sync_resources(){
  detect_host_resources

  # Abort early if host cannot keep reserves AND meet the bare minimum for the VM
  if (( AVAIL_CORES < 1 || AVAIL_RAM_MB < 2048 )); then
    die "Insufficient resources.\n\nHost: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB\nReserves: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB} MiB\nAvailable: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB} MiB\n\nNeed at least 1 core + 2048 MiB after reserve to create the base VM."
  fi

  local banner="Host: ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Reserve kept: ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB
Available for initial sync: ${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB"

  local svcpus sram
  svcpus=$(whiptail --title "Initial Sync vCPUs" --inputbox \
    "$banner\n\nEnter vCPUs for INITIAL SYNC (higher helps IBD):" \
    15 78 "${HOST_SUGGEST_SYNC_VCPUS}" 3>&1 1>&2 2>&3) || return 1
  [[ "$svcpus" =~ ^[0-9]+$ ]] || die "vCPUs must be a positive integer."
  [[ "$svcpus" -ge 1 ]] || die "vCPUs must be at least 1."
  (( svcpus <= AVAIL_CORES )) || die "Requested vCPUs ($svcpus) exceeds available after reserve (${AVAIL_CORES})."

  sram=$(whiptail --title "Initial Sync RAM (MiB)" --inputbox \
    "$banner\n\nEnter RAM (MiB) for INITIAL SYNC:" \
    15 78 "${HOST_SUGGEST_SYNC_RAM_MB}" 3>&1 1>&2 2>&3) || return 1
  [[ "$sram" =~ ^[0-9]+$ ]] || die "RAM must be a positive integer."
  [[ "$sram" -ge 2048 ]] || die "RAM should be at least 2048 MiB for IBD."
  (( sram <= AVAIL_RAM_MB )) || die "Requested RAM ($sram MiB) exceeds available after reserve (${AVAIL_RAM_MB} MiB)."

  SYNC_VCPUS="$svcpus"
  SYNC_RAM_MB="$sram"
  return 0
}

################################################################################
# Import Base VM
################################################################################

# import_base_vm: Import base VM from exported folder (unified format only)
# Purpose: Alternative to building from scratch - imports sanitized export
# Supported inputs:
#   - Unified export folder: gm-export-YYYYMMDD-HHMMSS/
#     • Contains VM image archive (vm-image.tar.gz) plus blockchain parts (blockchain.tar.gz.partN)
#     • Contains node binaries (bitcoind-gm/bitcoin-cli-gm or bitcoind-knots/bitcoin-cli-knots)
#     • If only a container image is found, user is guided to the container import
# Flow:
#   1. Let user configure defaults (reserves, VM sizes, clearnet toggle)
#   2. Scan ~/Downloads for gm-export-* folders
#   3. Let user select which export to import
#   4. Prefer VM image; if missing but container image present, show helpful guidance
#   5. Verify checksums (SHA256SUMS)
#   6. Let user select node type (Garbageman or Bitcoin Knots) based on available binaries
#   7. Extract VM archive, detect expected files (vm-disk.qcow2, *.xml)
#   8. If blockchain parts present, reassemble/extract and inject into VM disk
#   9. Inject selected node binaries (bitcoind, bitcoin-cli) into VM using virt-copy-in
#   10. Copy disk image to /var/lib/libvirt/images/ and define VM
# Notes:
#   - Folder detection is flexible: either image type triggers listing in menu
#   - Cross-guidance helps users pick the correct import path (VM vs container)
#   - Node selection: Auto-selects if only one type available, presents menu if both
# Prerequisites: Same as create_base_vm (ensures tools installed)
# Side effects: Creates VM disk at /var/lib/libvirt/images/${VM_NAME}.qcow2
import_base_vm(){
  # Start sudo keepalive for potential long operations
  sudo_keepalive_start force
  
  ensure_tools
  
  # Verify libvirt is accessible before proceeding
  check_libvirt_access

  # Scan for export archives in ~/Downloads
  echo "Scanning ~/Downloads for VM exports..."
  local export_items=()
  
  # Look for unified export folders (gm-export-*)
  while IFS= read -r -d '' folder; do
    # Check if it contains a VM image archive OR container image archive
    # This allows importing from folders that have either or both image types
    if ls "$folder"/vm-image.tar.gz >/dev/null 2>&1 || \
       ls "$folder"/container-image.tar.gz >/dev/null 2>&1; then
      export_items+=("folder:$folder")
    fi
  done < <(find "$HOME/Downloads" -maxdepth 1 -type d -name "gm-export-*" -print0 2>/dev/null | sort -z)
  
  if [[ ${#export_items[@]} -eq 0 ]]; then
    pause "No VM exports found in ~/Downloads.\n\nLooking for:\n  gm-export-* folders with vm-image.tar.gz files"
    return
  fi
  
  echo "Found ${#export_items[@]} export(s)"
  
  # Build menu options for whiptail
  local menu_items=()
  for i in "${!export_items[@]}"; do
    local item="${export_items[$i]}"
    local type="${item%%:*}"
    local path="${item#*:}"
    local basename=$(basename "$path")
    local display
    
    # All items are now folders (unified format)
    local folder_size=$(du -sh "$path" 2>/dev/null | cut -f1)
    local timestamp=$(echo "$basename" | sed 's/gm-export-\(.*\)/\1/')
    
    # Check if blockchain data is present
    local blockchain_status="blockchain included"
    if ! ls "$path"/blockchain.tar.gz.part* >/dev/null 2>&1; then
      blockchain_status="image only, no blockchain"
    fi
    
    display="${timestamp} (${folder_size}) [${blockchain_status}]"
    menu_items+=("$i" "$display")
  done
  
  # Let user select export
  local selection
  selection=$(whiptail --title "Select VM Export" \
    --menu "Choose an export to import:\n\nFound in: ~/Downloads" \
    20 78 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || return
  
  local selected_item="${export_items[$selection]}"
  local item_type="${selected_item%%:*}"
  local item_path="${selected_item#*:}"
  local selected_basename=$(basename "$item_path")
  
  echo ""
  echo "Selected: $selected_basename"
  
  # Verify checksum (unified format - SHA256SUMS file inside the folder)
  local checksum_file="$item_path/SHA256SUMS"
  
  if [[ ! -f "$checksum_file" ]]; then
    pause "❌ Checksum file not found: SHA256SUMS\n\nCannot verify integrity. Import aborted."
    return
  fi
  
  echo "Checksum file found"
  echo "Verifying SHA256 checksums..."
  
  # Verify VM image archive checksum from SHA256SUMS
  local vm_archive=$(ls "$item_path"/vm-image.tar.gz 2>/dev/null | head -n1)
  if [[ -z "$vm_archive" ]]; then
    pause "❌ VM image archive not found: vm-image.tar.gz\n\nThis export may only contain a container image."
    return
  fi
  local vm_basename=$(basename "$vm_archive")
  
  if ! (cd "$item_path" && grep "$vm_basename" SHA256SUMS | sha256sum -c 2>&1 | grep -q "OK"); then
    pause "❌ Checksum verification FAILED!\n\nThe archive may be corrupted or tampered with.\n\nImport aborted for security."
    return
  fi
  
  echo "✅ Checksum verified successfully"
  
  # Let user select node type (Garbageman or Bitcoin Knots)
  echo ""
  echo "Checking available node implementations..."
  
  local node_choice
  local binary_suffix
  local has_gm=false
  local has_knots=false
  
  # Check which binaries are available in the export
  if [[ -f "$item_path/bitcoind-gm" ]] && [[ -f "$item_path/bitcoin-cli-gm" ]]; then
    has_gm=true
    echo "  ✓ Found Garbageman binaries (bitcoind-gm, bitcoin-cli-gm)"
  fi
  
  if [[ -f "$item_path/bitcoind-knots" ]] && [[ -f "$item_path/bitcoin-cli-knots" ]]; then
    has_knots=true
    echo "  ✓ Found Bitcoin Knots binaries (bitcoind-knots, bitcoin-cli-knots)"
  fi
  
  if [[ "$has_gm" == "false" ]] && [[ "$has_knots" == "false" ]]; then
    pause "❌ No node binaries found in export!\n\nExpected: bitcoind-gm + bitcoin-cli-gm OR bitcoind-knots + bitcoin-cli-knots\n\nThis export may be from an older version of the script.\nPlease re-export or download a newer release."
    return
  fi
  
  # Build menu based on available binaries
  local menu_opts=()
  if [[ "$has_gm" == "true" ]]; then
    menu_opts+=("1" "Garbageman")
  fi
  if [[ "$has_knots" == "true" ]]; then
    menu_opts+=("2" "Bitcoin Knots")
  fi
  
  if [[ ${#menu_opts[@]} -eq 0 ]]; then
    pause "❌ No valid node binaries found in export"
    return
  elif [[ "$has_gm" == "true" ]] && [[ "$has_knots" == "true" ]]; then
    # Both available, let user choose
    node_choice=$(whiptail --title "Select Node Type" --menu \
      "Choose which Bitcoin implementation to install:\n\nBoth are available in this export." 15 70 2 \
      "${menu_opts[@]}" \
      3>&1 1>&2 2>&3) || {
        pause "Import cancelled."
        return
      }
  else
    # Only one available, auto-select it
    node_choice="${menu_opts[0]}"
    echo "  ℹ Only one implementation available, auto-selecting: ${menu_opts[1]}"
  fi
  
  # Set binary suffix based on selection
  if [[ "$node_choice" == "1" ]]; then
    binary_suffix="-gm"
    echo "Selected: Garbageman (Libre Relay)"
  elif [[ "$node_choice" == "2" ]]; then
    binary_suffix="-knots"
    echo "Selected: Bitcoin Knots"
  fi
  
  # Show import confirmation
  if ! whiptail --title "Confirm Import" \
    --yesno "Ready to import base VM from:\n\n${selected_basename}\n\nNode implementation: ${binary_suffix#-}\n\nThis will:\n• Extract the archive\n• Import the disk image to /var/lib/libvirt/images/\n• Install ${binary_suffix#-} binaries\n• Create the VM definition\n• Configure for this system\n\nProceed with import?" \
    18 78; then
    pause "Import cancelled."
    return
  fi
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                          Importing Base VM                                     ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # Create temporary extraction directory
  local temp_extract_dir="$HOME/.cache/gm-import-temp-$$"
  mkdir -p "$temp_extract_dir"
  
  local extract_dir
  local blockchain_dir
  
  # Unified format: use folder directly
  echo "[1/7] Using unified export folder..."
  
  # Extract the VM archive within the folder
  local vm_archive=$(ls "$item_path"/vm-image.tar.gz 2>/dev/null | head -n1)
  
  if [[ -z "$vm_archive" ]]; then
    # Check if folder has container image instead
    if ls "$item_path"/container-image.tar.gz >/dev/null 2>&1; then
      rm -rf "$temp_extract_dir"
      pause "❌ This folder only contains a container image.\n\nTo import as a container:\n1. Cancel and return to main menu\n2. Choose 'Create Base Container'\n3. Select 'Import from file'\n4. Choose this same folder\n\nOr download/export a VM image for this release."
      return
    else
      rm -rf "$temp_extract_dir"
      pause "❌ No VM image archive found in export folder"
      return
    fi
  fi
  
  echo "    Extracting VM image archive..."
  tar -xzf "$vm_archive" -C "$temp_extract_dir" || {
    rm -rf "$temp_extract_dir"
    pause "❌ Failed to extract VM image archive"
    return
  }
  
  # Blockchain parts are at folder level in unified format
  blockchain_dir="$item_path"
  extract_dir="$temp_extract_dir"  # Point to extracted VM files
  
  echo "    ✓ Archive extracted"
  
  # Verify disk image exists (unified format)
  local source_disk="${extract_dir}/vm-disk.qcow2"
  
  if [[ ! -f "$source_disk" ]]; then
    rm -rf "$temp_extract_dir"
    pause "❌ Disk image not found in archive (expected vm-disk.qcow2)"
    return
  fi
  
  # Read metadata if available
  local metadata_file="${extract_dir}/metadata.json"
  local has_modular_blockchain=false
  
  # Check if blockchain data is present in the folder
  if ls "$blockchain_dir"/blockchain.tar.gz.part* >/dev/null 2>&1; then
    has_modular_blockchain=true
  fi
  
  if [[ -f "$metadata_file" ]]; then
    echo ""
    echo "[2/7] Reading metadata..."
    local export_date script_name blockchain_height
    export_date=$(jq -r '.export_date // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
    script_name=$(jq -r '.script_name // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
    blockchain_height=$(jq -r '.blockchain.height_at_export // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
    
    echo "    Export date: $export_date"
    echo "    Script: $script_name"
    echo "    Blockchain height at export: $blockchain_height"
    echo "    ✓ Metadata read"
  elif [[ "$has_modular_blockchain" == "false" ]] && ([[ -f "${extract_dir}/vm-disk.qcow2" ]] || [[ -f "${extract_dir}/README.txt" ]]); then
    # Modular format detected, but no blockchain data present
    echo ""
    echo "[2/7] Detected VM image without blockchain data"
    echo "    ⚠ This folder contains ONLY the VM image"
    echo "    ⚠ Blockchain data is NOT included and will need to be synced (24-28 hours)"
    echo ""
    if ! whiptail --title "Image-Only Import" \
      --yesno "This folder contains ONLY the VM image.\n\nBlockchain data is NOT included and will need to be synced.\n\nFor faster setup with blockchain included:\n• Use 'Import from GitHub' option instead\n• Or download a matching blockchain export to the same folder\n\nContinue with image-only import?" \
      16 75; then
      rm -rf "$temp_extract_dir"
      pause "Import cancelled."
      return
    fi
  fi
  
  # Copy disk image to libvirt images directory
  echo ""
  echo "[3/7] Copying disk image to /var/lib/libvirt/images/..."
  local dest_disk="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  
  # Check if VM domain already exists
  if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    echo "    ⚠ VM '$VM_NAME' already exists"
    if whiptail --title "Existing VM Found" \
      --yesno "VM '$VM_NAME' already exists.\n\nDo you want to delete it and import the new one?" \
      10 70; then
      echo "    Shutting down and removing existing VM..."
      
      # Force shutdown if running
      if [[ "$(vm_state "$VM_NAME")" != "shut off" ]]; then
        virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
        sleep 2
      fi
      
      # Undefine the domain
      virsh_cmd undefine "$VM_NAME" 2>/dev/null || true
      sleep 1
      
      # Now remove the disk
      if [[ -f "$dest_disk" ]]; then
        sudo rm -f "$dest_disk"
      fi
    else
      rm -rf "$temp_extract_dir"
      pause "Import cancelled - VM already exists."
      return
    fi
  elif [[ -f "$dest_disk" ]]; then
    # Disk exists but no VM domain - just remove disk
    echo "    ⚠ Disk already exists at $dest_disk"
    if whiptail --title "Existing Disk Found" \
      --yesno "Disk $dest_disk already exists.\n\nDo you want to overwrite it?" \
      10 70; then
      echo "    Removing existing disk..."
      sudo rm -f "$dest_disk"
    else
      rm -rf "$temp_extract_dir"
      pause "Import cancelled - disk already exists."
      return
    fi
  fi
  
  sudo cp "$source_disk" "$dest_disk" || {
    rm -rf "$temp_extract_dir"
    pause "❌ Failed to copy disk image"
    return
  }
  
  sudo chown root:root "$dest_disk"
  sudo chmod 644 "$dest_disk"
  echo "    ✓ Disk image copied"
  
  # [3.5/7] Inject selected node binaries into VM disk
  echo ""
  echo "[3.5/7] Installing ${binary_suffix#-} binaries..."
  
  local src_bitcoind="$item_path/bitcoind${binary_suffix}"
  local src_bitcoin_cli="$item_path/bitcoin-cli${binary_suffix}"
  
  # Create temporary directory for binaries
  local temp_bin_dir="$HOME/.cache/gm-bin-temp-$$"
  mkdir -p "$temp_bin_dir"
  
  # Copy binaries to temp with standard names for injection
  cp "$src_bitcoind" "$temp_bin_dir/bitcoind" || {
    rm -rf "$temp_bin_dir"
    rm -rf "$temp_extract_dir"
    pause "❌ Failed to prepare bitcoind binary"
    return
  }
  
  cp "$src_bitcoin_cli" "$temp_bin_dir/bitcoin-cli" || {
    rm -rf "$temp_bin_dir"
    rm -rf "$temp_extract_dir"
    pause "❌ Failed to prepare bitcoin-cli binary"
    return
  }
  
  # Inject binaries into VM disk
  if sudo virt-copy-in -a "$dest_disk" "$temp_bin_dir/bitcoind" "$temp_bin_dir/bitcoin-cli" /usr/local/bin/ 2>/dev/null; then
    # Set correct permissions
    sudo virt-customize -a "$dest_disk" --no-selinux-relabel \
      --run-command "chmod 755 /usr/local/bin/bitcoind" \
      --run-command "chmod 755 /usr/local/bin/bitcoin-cli" \
      2>&1 | grep -v "random seed" >&2
    
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "    ✓ Binaries installed: bitcoind, bitcoin-cli (${binary_suffix#-})"
    else
      rm -rf "$temp_bin_dir"
      rm -rf "$temp_extract_dir"
      pause "❌ Failed to set binary permissions"
      return
    fi
  else
    rm -rf "$temp_bin_dir"
    rm -rf "$temp_extract_dir"
    pause "❌ Failed to inject binaries into VM disk"
    return
  fi
  
  # Clean up temp binaries directory
  rm -rf "$temp_bin_dir"
  
  # [4/7] Configure bitcoin.conf based on CLEARNET_OK setting
  echo ""
  echo "[4/7] Configuring bitcoin.conf based on clearnet setting..."
  
  local btc_conf_content
  if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
    echo "    Configuring for: Tor + clearnet (faster sync)"
    btc_conf_content="server=1
daemon=1
prune=750
dbcache=450
maxconnections=25

# Tor configuration
proxy=127.0.0.1:9050
listen=1
bind=127.0.0.1

# Allow both Tor and clearnet
onlynet=onion
onlynet=ipv4
listenonion=1
discover=1
dnsseed=1
torcontrol=127.0.0.1:9051

[main]"
  else
    echo "    Configuring for: Tor-only (maximum privacy)"
    btc_conf_content="server=1
daemon=1
prune=750
dbcache=450
maxconnections=25

# Tor-only configuration
proxy=127.0.0.1:9050
listen=1
bind=127.0.0.1
onlynet=onion
listenonion=1
discover=0
dnsseed=0
torcontrol=127.0.0.1:9051

[main]"
  fi
  
  # Write bitcoin.conf to VM disk
  sudo virt-customize -a "$dest_disk" --no-selinux-relabel \
    --write /etc/bitcoin/bitcoin.conf:"$btc_conf_content" \
    --run-command "chown bitcoin:bitcoin /etc/bitcoin/bitcoin.conf || true" \
    --run-command "chmod 640 /etc/bitcoin/bitcoin.conf" \
    2>&1 | grep -v "random seed" >&2
  
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "    ⚠️  Warning: Failed to configure bitcoin.conf (will use default from image)"
  else
    echo "    ✓ bitcoin.conf configured"
  fi
  
  # [5/7] Import blockchain data if available
  if [[ -n "$blockchain_dir" && -d "$blockchain_dir" ]]; then
    echo ""
    echo "[5/7] Importing blockchain data..."
    
    # Clean up any old failed temp directories first
    if ls ~/.cache/gm-blockchain-temp-* >/dev/null 2>&1; then
      echo "  Cleaning up old temp directories from previous failed imports..."
      rm -rf ~/.cache/gm-blockchain-temp-*
    fi
    
    # Check for blockchain parts (blockchain.tar.gz.part*)
    if ls "$blockchain_dir"/blockchain.tar.gz.part* >/dev/null 2>&1; then
      echo "  Found blockchain data in unified export folder..."
      echo "  Reassembling blockchain parts..."
      
      local blockchain_temp="$HOME/.cache/gm-blockchain-temp-$$"
      mkdir -p "$blockchain_temp"
      
      if ! cat "$blockchain_dir"/blockchain.tar.gz.part* > "$blockchain_temp/blockchain.tar.gz"; then
        rm -rf "$blockchain_temp"
        echo "    ✗ Failed to reassemble blockchain parts"
        echo "  ℹ No blockchain data imported - you'll need to sync from scratch"
      else
        echo "    ✓ Blockchain parts reassembled"
        local reassembled_size=$(du -h "$blockchain_temp/blockchain.tar.gz" | cut -f1)
        echo "      Size: $reassembled_size"
        
        # Verify checksum if available (check SHA256SUMS file)
        if [[ -f "$blockchain_dir/SHA256SUMS" ]]; then
          echo "  Verifying blockchain checksum..."
          local expected_sum=$(grep "blockchain.tar.gz$" "$blockchain_dir/SHA256SUMS" | awk '{print $1}')
          local actual_sum=$(sha256sum "$blockchain_temp/blockchain.tar.gz" | awk '{print $1}')
          echo "    Expected: $expected_sum"
          echo "    Actual:   $actual_sum"
          
          if [[ "$expected_sum" != "$actual_sum" ]]; then
            rm -rf "$blockchain_temp"
            echo "    ✗ Blockchain checksum mismatch!"
            echo "  ℹ No blockchain data imported - you'll need to sync from scratch"
          else
            echo "    ✓ Checksum verified"
            
            # Inject blockchain into VM disk
            echo "  Injecting blockchain into VM disk..."
            echo "  Decompressing blockchain archive..."
            if ! gunzip "$blockchain_temp/blockchain.tar.gz"; then
              echo "    ✗ Failed to decompress blockchain"
              rm -rf "$blockchain_temp"
            else
              echo "    ✓ Blockchain decompressed"
              local tar_file="$blockchain_temp/blockchain.tar"
              
              echo "    Injecting blockchain into VM disk (this may take several minutes)..."
              
              # Capture full error output
              local inject_output
              inject_output=$(sudo virt-tar-in -a "$dest_disk" "$tar_file" /var/lib/bitcoin 2>&1)
              local inject_status=$?
              
              # Filter out benign warnings
              local filtered_output=$(echo "$inject_output" | grep -v "random seed")
              
              if [[ $inject_status -eq 0 ]]; then
                echo "    ✓ Blockchain data imported successfully into /var/lib/bitcoin"
                
                # Fix ownership - tar preserves UIDs which may not match the new VM's bitcoin user
                echo "    Fixing ownership of blockchain files..."
                sudo virt-customize -a "$dest_disk" --no-selinux-relabel \
                  --run-command "chown -R bitcoin:bitcoin /var/lib/bitcoin" \
                  2>&1 | grep -v "random seed" >&2
                
                if [ "${PIPESTATUS[0]}" -eq 0 ]; then
                  echo "    ✓ Ownership fixed"
                else
                  echo "    ⚠ Warning: Could not fix ownership (bitcoind may fail to start)"
                fi
                
                rm -rf "$blockchain_temp"
              else
                echo "    ✗ Failed to inject blockchain into VM (exit code: $inject_status)"
                if [[ -n "$filtered_output" ]]; then
                  echo "    Error output:"
                  echo "$filtered_output" | sed 's/^/      /'
                fi
                # Don't remove temp dir so we can investigate
              fi
            fi
          fi
        else
          echo "    ⚠ No checksum file found - skipping blockchain import"
          rm -rf "$blockchain_temp"
        fi
      fi
      
    else
      echo "  ⚠ No blockchain data found - VM will sync from network"
      echo "    (This may take several hours on first startup)"
    fi
  elif [[ -f "$extract_dir/blockchain-data.tar.gz" ]]; then
    # OLD monolithic format with blockchain included
    echo ""
    echo "[5/7] Importing blockchain data (monolithic format)..."
    echo "  Found blockchain data in archive..."
    
    # Clean up any old failed temp directories first
    if ls ~/.cache/gm-blockchain-temp-* >/dev/null 2>&1; then
      echo "  Cleaning up old temp directories from previous failed imports..."
      rm -rf ~/.cache/gm-blockchain-temp-*
    fi
    
    echo "  Decompressing blockchain archive..."
    
    local blockchain_temp="$HOME/.cache/gm-blockchain-temp-$$"
    mkdir -p "$blockchain_temp"
    cp "$extract_dir/blockchain-data.tar.gz" "$blockchain_temp/"
    
    if ! gunzip "$blockchain_temp/blockchain-data.tar.gz"; then
      echo "    ✗ Failed to decompress blockchain"
      rm -rf "$blockchain_temp"
    else
      echo "    ✓ Blockchain decompressed"
      local tar_file="$blockchain_temp/blockchain-data.tar"
      
      echo "    Injecting blockchain into VM disk (this may take several minutes)..."
      
      # Capture full error output
      local inject_output
      inject_output=$(sudo virt-tar-in -a "$dest_disk" "$tar_file" /var/lib/bitcoin 2>&1)
      local inject_status=$?
      
      # Filter out benign warnings
      local filtered_output=$(echo "$inject_output" | grep -v "random seed")
      
      if [[ $inject_status -eq 0 ]]; then
        echo "    ✓ Blockchain data imported successfully into /var/lib/bitcoin"
        
        # Fix ownership - tar preserves UIDs which may not match the new VM's bitcoin user
        echo "    Fixing ownership of blockchain files..."
        sudo virt-customize -a "$dest_disk" --no-selinux-relabel \
          --run-command "chown -R bitcoin:bitcoin /var/lib/bitcoin" \
          2>&1 | grep -v "random seed" >&2
        
        if [ "${PIPESTATUS[0]}" -eq 0 ]; then
          echo "    ✓ Ownership fixed"
        else
          echo "    ⚠ Warning: Could not fix ownership (bitcoind may fail to start)"
        fi
        
        rm -rf "$blockchain_temp"
      else
        echo "    ✗ Failed to inject blockchain into VM (exit code: $inject_status)"
        if [[ -n "$filtered_output" ]]; then
          echo "    Error output:"
          echo "$filtered_output" | sed 's/^/      /'
        fi
        # Don't remove temp dir so we can investigate
      fi
    fi
  else
    echo ""
    echo "  ℹ No blockchain data found in export (image-only export)"
    echo "  ℹ You can sync the blockchain from scratch after starting the VM"
  fi
  
  # Clean up extraction directory
  rm -rf "$temp_extract_dir"
  
  # Let user configure defaults for resource allocation
  echo ""
  echo "[6/7] Configuring VM resources..."
  
  if ! configure_defaults_direct; then
    echo "    Using default resource settings"
  fi
  
  # Prompt for initial resources (in case user wants to start it right away)
  if ! prompt_sync_resources; then
    # Use defaults if cancelled
    detect_host_resources
    SYNC_RAM_MB=$HOST_SUGGEST_SYNC_RAM_MB
    SYNC_VCPUS=$HOST_SUGGEST_SYNC_VCPUS
  fi
  
  # Inject monitoring SSH key BEFORE creating the VM domain
  # This must happen while the disk is not in use by any VM
  echo ""
  echo "[7/7] Configuring monitoring access..."
  
  # Ensure SSH key exists (but don't call ensure_monitor_ssh since VM doesn't exist yet)
  mkdir -p "$SSH_KEY_DIR"
  chmod 700 "$SSH_KEY_DIR"
  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY_PATH" -q >/dev/null 2>&1
  fi
  
  local pub
  pub=$(cat "${SSH_KEY_PATH}.pub")
  
  sudo virt-customize -a "$dest_disk" \
    --no-selinux-relabel \
    --run-command "mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys" \
    --run-command "grep -qF '$pub' /root/.ssh/authorized_keys || echo '$pub' >> /root/.ssh/authorized_keys" \
    2>&1 | grep -v "random seed" >&2
  
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "    ⚠ Warning: Failed to inject SSH key (monitoring may not work)"
  else
    echo "    ✓ Monitoring access configured"
  fi
  
  # Create VM domain definition
  echo ""
  echo "    Creating VM domain..."
  
  # Use explicit connection and better error handling for virt-install
  if ! sudo virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --memory "$SYNC_RAM_MB" --vcpus "$SYNC_VCPUS" --cpu host \
    --disk "path=$dest_disk,format=qcow2,bus=virtio" \
    --network "network=default,model=virtio" \
    --osinfo alpinelinux3.18 \
    --graphics none --noautoconsole \
    --import 2>&1; then
    echo ""
    echo "    ✗ VM creation failed"
    echo ""
    rm -rf "$temp_extract_dir" 2>/dev/null || true
    die "Failed to create VM domain. Check that libvirtd is running and default network is active."
  fi
  
  # virt-install --import automatically starts the VM, but we want it stopped
  echo "    Stopping VM..."
  virsh_cmd shutdown "$VM_NAME" 2>/dev/null || true
  sleep 3
  if [[ "$(vm_state "$VM_NAME")" != "shut off" ]]; then
    virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
    sleep 2
  fi
  
  echo "    ✓ VM domain created"
  
  # Success!
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                        Import Complete!                                        ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "✅ Base VM '$VM_NAME' imported successfully!"
  echo ""
  echo "📋 VM Configuration:"
  echo "   Initial resources: ${SYNC_VCPUS} vCPUs, ${SYNC_RAM_MB} MiB RAM"
  echo "   Disk: $dest_disk"
  echo "   Status: Stopped and ready"
  echo ""
  echo "🔒 Security:"
  echo "   • Fresh SSH keys will be generated on first boot"
  echo "   • Fresh Tor hidden service (.onion) will be generated"
  echo "   • Peer databases are empty (will discover peers independently)"
  echo ""
  echo "📌 Next steps:"
  echo "   1. Choose 'Monitor Base VM Sync' to start and check sync status"
  echo "   2. If blockchain needs updating, it will sync the missing blocks"
  echo "   3. Once synced, you can clone the VM or export it again"
  echo ""
  
  pause "Import complete! VM '$VM_NAME' is ready.\n\nChoose 'Monitor Base VM Sync' to start it."
}

# import_from_github: Import base VM from GitHub release (NEW MODULAR FORMAT)
# Purpose: Download and import pre-built VM using modular architecture
# Modular Design:
#   - Downloads blockchain data separately from images
#   - Downloads BOTH images (VM + container) for flexibility/switching later
#   - Downloads node binaries (Garbageman and/or Bitcoin Knots)
#   - Verifies checksums (unified SHA256SUMS when available)
#   - Reassembles blockchain from split parts
#   - Uses VM image for import; keeps container image for later use
# Flow:
#   1. Let user configure defaults (reserves, VM sizes, clearnet toggle)
#   2. Fetch available releases from GitHub API
#   3. Let user select a release tag
#   4. Parse release assets: blockchain parts, images, binaries, checksums
#   5. Let user select node type (Garbageman or Bitcoin Knots) based on available binaries
#   6. Download blockchain parts (blockchain.tar.gz.part01, part02, ...)
#   7. Download VM image (vm-image.tar.gz)
#   8. Download container image (container-image.tar.gz) - optional
#   9. Download selected node binaries (bitcoind-gm/knots, bitcoin-cli-gm/knots)
#  10. Verify checksums for parts and images (prefer SHA256SUMS)
#  11. Reassemble blockchain from parts
#  12. Extract VM image (vm-disk.qcow2, vm-definition.xml)
#  13. Extract blockchain data
#  14. Inject blockchain into VM disk using virt-tar-in
#  15. Inject selected node binaries into VM disk using virt-copy-in
#  16. Copy disk to /var/lib/libvirt/images/
#  17. Import VM definition with virsh define
#  18. Cleanup temporary files (keep original downloads)
# Prerequisites: curl or wget, jq, virt-tar-in, virt-copy-in, virt-customize (libguestfs-tools)
# Download Size: ~21GB (blockchain) + ~1GB (VM) + ~0.5GB (container) + ~0.1GB (binaries) ≈ ~22.6GB total
# Benefits over old format:
#   - Blockchain is separate (can be reused/shared)
#   - Smaller per-image downloads for updates (~1GB VM, ~0.5GB container)
#   - Download both once, then switch between VM/container without re-downloading blockchain
#   - Downloaded files preserved for USB transfer to other computers
#   - User choice between Garbageman (Libre Relay) and Bitcoin Knots
# Side effects: Downloads to ~/Downloads/gm-export-*, imports complete VM to libvirt
import_from_github(){
  local repo="paulscode/garbageman-nm"
  local api_url="https://api.github.com/repos/$repo/releases"
  
  # Cleanup function for temporary files (called on both success and failure)
  cleanup_vm_import_temps(){
    local dir="$1"
    [[ -z "$dir" || ! -d "$dir" ]] && return
    
    # Remove temporary files (keep original downloads for USB transfer)
    rm -f "$dir"/blockchain.tar.gz 2>/dev/null
    rm -rf "$dir/blockchain-data" "$dir/vm-image" 2>/dev/null
    
    # Clean up blockchain decompression temp directory if it exists
    rm -rf "$HOME"/.cache/gm-blockchain-temp-* 2>/dev/null
  }
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║              Import Base VM from GitHub (Modular Download)                     ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "This import downloads blockchain data and BOTH images (VM + container) separately."
  echo "We'll import the VM now and keep the container image so you can switch later."
  echo "Benefits: Smaller per-image downloads; switch without re-downloading blockchain."
  echo ""
  
  # Check for required tools
  if ! command -v jq >/dev/null 2>&1; then
    pause "❌ Required tool 'jq' not found.\n\nInstall with: sudo apt install jq"
    return
  fi
  
  if ! command -v virt-tar-in >/dev/null 2>&1; then
    pause "❌ Required tool 'virt-tar-in' not found.\n\nInstall with: sudo apt install libguestfs-tools"
    return
  fi
  
  local download_tool=""
  if command -v curl >/dev/null 2>&1; then
    download_tool="curl"
  elif command -v wget >/dev/null 2>&1; then
    download_tool="wget"
  else
    pause "❌ Neither 'curl' nor 'wget' found.\n\nInstall with: sudo apt install curl"
    return
  fi
  
  echo "Fetching available releases from GitHub..."
  local releases_json
  if [[ "$download_tool" == "curl" ]]; then
    releases_json=$(curl -s "$api_url" 2>/dev/null)
  else
    releases_json=$(wget -q -O- "$api_url" 2>/dev/null)
  fi
  
  if [[ -z "$releases_json" ]] || ! echo "$releases_json" | jq -e . >/dev/null 2>&1; then
    pause "❌ Failed to fetch releases from GitHub.\n\nCheck your internet connection."
    return
  fi
  
  # Parse releases and build menu
  local tags=()
  local tag_names=()
  local menu_items=()
  
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    tags+=("$tag")
    local tag_name=$(echo "$releases_json" | jq -r ".[] | select(.tag_name==\"$tag\") | .name // .tag_name")
    local published=$(echo "$releases_json" | jq -r ".[] | select(.tag_name==\"$tag\") | .published_at" | cut -d'T' -f1)
    tag_names+=("$tag_name")
    menu_items+=("$tag" "$tag_name ($published)")
  done < <(echo "$releases_json" | jq -r '.[].tag_name')
  
  if [[ ${#tags[@]} -eq 0 ]]; then
    pause "No releases found."
    return
  fi
  
  echo "Found ${#tags[@]} release(s)"
  echo ""
  
  # Let user select release
  local selected_tag
  selected_tag=$(whiptail --title "Select GitHub Release" \
    --menu "Choose a release to download and import:" 20 78 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || return
  
  echo "Selected: $selected_tag"
  echo ""
  
  # Get assets for selected release
  local release_assets
  release_assets=$(echo "$releases_json" | jq -r ".[] | select(.tag_name==\"$selected_tag\") | .assets")
  
  # Find blockchain parts, VM image, and checksums
  local blockchain_part_urls=()
  local blockchain_part_names=()
  local vm_image_url=""
  local vm_image_name=""
  local container_image_url=""
  local container_image_name=""
  local sha256sums_url=""
  local bitcoind_gm_url=""
  local bitcoin_cli_gm_url=""
  local bitcoind_knots_url=""
  local bitcoin_cli_knots_url=""
  
  while IFS='|' read -r name url; do
    [[ -z "$name" ]] && continue
    # Blockchain parts (blockchain.tar.gz.part*)
    if [[ "$name" =~ ^blockchain\.tar\.gz\.part[0-9]+$ ]]; then
      blockchain_part_names+=("$name")
      blockchain_part_urls+=("$url")
    # Unified checksum file
    elif [[ "$name" == "SHA256SUMS" ]]; then
      sha256sums_url="$url"
    # VM image (vm-image.tar.gz)
    elif [[ "$name" == "vm-image.tar.gz" ]]; then
      vm_image_name="$name"
      vm_image_url="$url"
    # Container image (container-image.tar.gz)
    elif [[ "$name" == "container-image.tar.gz" ]]; then
      container_image_name="$name"
      container_image_url="$url"
    # Binary files
    elif [[ "$name" == "bitcoind-gm" ]]; then
      bitcoind_gm_url="$url"
    elif [[ "$name" == "bitcoin-cli-gm" ]]; then
      bitcoin_cli_gm_url="$url"
    elif [[ "$name" == "bitcoind-knots" ]]; then
      bitcoind_knots_url="$url"
    elif [[ "$name" == "bitcoin-cli-knots" ]]; then
      bitcoin_cli_knots_url="$url"
    fi
  done < <(echo "$release_assets" | jq -r '.[] | "\(.name)|\(.browser_download_url)"')
  
  # Validate required files are present
  if [[ ${#blockchain_part_urls[@]} -eq 0 ]]; then
    pause "❌ No blockchain parts found in release $selected_tag"
    return
  fi
  
  if [[ -z "$vm_image_url" ]]; then
    pause "❌ No VM image found in release $selected_tag"
    return
  fi
  
  # Container image is optional but recommended
  if [[ -z "$container_image_url" ]]; then
    echo "⚠️  Warning: No container image found in release (older format?)"
  fi
  
  # Check for binary files and let user select node type
  echo ""
  echo "Checking available node implementations..."
  
  local has_gm=false
  local has_knots=false
  local node_choice
  local binary_suffix
  
  if [[ -n "$bitcoind_gm_url" ]] && [[ -n "$bitcoin_cli_gm_url" ]]; then
    has_gm=true
    echo "  ✓ Found Garbageman binaries"
  fi
  
  if [[ -n "$bitcoind_knots_url" ]] && [[ -n "$bitcoin_cli_knots_url" ]]; then
    has_knots=true
    echo "  ✓ Found Bitcoin Knots binaries"
  fi
  
  if [[ "$has_gm" == "false" ]] && [[ "$has_knots" == "false" ]]; then
    pause "❌ No node binaries found in release!\n\nThis release may be from an older version.\nPlease choose a newer release or re-export."
    return
  fi
  
  # Build menu based on available binaries
  local menu_opts=()
  if [[ "$has_gm" == "true" ]]; then
    menu_opts+=("1" "Garbageman")
  fi
  if [[ "$has_knots" == "true" ]]; then
    menu_opts+=("2" "Bitcoin Knots")
  fi
  
  if [[ "$has_gm" == "true" ]] && [[ "$has_knots" == "true" ]]; then
    # Both available, let user choose
    node_choice=$(whiptail --title "Select Node Type" --menu \
      "Choose which Bitcoin implementation to install:\n\nBoth are available in this release." 15 70 2 \
      "${menu_opts[@]}" \
      3>&1 1>&2 2>&3) || {
        echo "Cancelled."
        return
      }
  else
    # Only one available, auto-select it
    node_choice="${menu_opts[0]}"
    echo "  ℹ Only one implementation available, auto-selecting: ${menu_opts[1]}"
  fi
  
  # Set binary suffix and URLs based on selection
  local bitcoind_url=""
  local bitcoin_cli_url=""
  if [[ "$node_choice" == "1" ]]; then
    binary_suffix="-gm"
    bitcoind_url="$bitcoind_gm_url"
    bitcoin_cli_url="$bitcoin_cli_gm_url"
    echo "Selected: Garbageman (Libre Relay)"
  elif [[ "$node_choice" == "2" ]]; then
    binary_suffix="-knots"
    bitcoind_url="$bitcoind_knots_url"
    bitcoin_cli_url="$bitcoin_cli_knots_url"
    echo "Selected: Bitcoin Knots"
  fi
  
  # Calculate approximate download sizes (including binaries)
  local blockchain_size="~$(( ${#blockchain_part_urls[@]} * 19 / 10 )) GB"  # parts are ~1.9GB each
  local vm_size="~1 GB"
  local container_size="~500 MB"
  local binaries_size="~100 MB"
  local total_size="~$(( ${#blockchain_part_urls[@]} * 19 / 10 + 2 )) GB"
  
  echo "Download plan:"
  echo "  • Blockchain data: ${#blockchain_part_urls[@]} parts ($blockchain_size)"
  echo "  • VM image: $vm_image_name ($vm_size)"
  if [[ -n "$container_image_url" ]]; then
    echo "  • Container image: $container_image_name ($container_size)"
    echo "  Total: $total_size"
  fi
  echo ""
  
  # Configure resources before downloading
  echo "Before downloading, let's configure resource allocation:"
  echo ""
  
  # Let user configure defaults for resource allocation
  if ! configure_defaults_direct; then
    pause "Cancelled."
    return
  fi
  
  local download_message="This will download approximately $total_size of data.\n\nBlockchain parts: ${#blockchain_part_urls[@]}\nVM image: $vm_image_name"
  if [[ -n "$container_image_url" ]]; then
    download_message+="\nContainer image: $container_image_name"
  fi
  download_message+="\nRelease: $selected_tag\n\nBoth images will be downloaded for flexibility.\nYou can switch between VM and container\nwithout re-downloading the blockchain.\n\nContinue?"
  
  if ! whiptail --title "Confirm Download" \
    --yesno "$download_message" \
    18 75; then
    echo "Download cancelled."
    return
  fi
  
  # Create persistent download directory in ~/Downloads with unified export structure
  local download_timestamp=$(date +%Y%m%d-%H%M%S)
  local download_dir="$HOME/Downloads/gm-export-${download_timestamp}"
  mkdir -p "$download_dir"
  
  # Set trap to cleanup temporary files on exit (success or failure)
  trap "cleanup_vm_import_temps '$download_dir'" RETURN EXIT INT TERM
  
  echo ""
  echo "Downloading to: $download_dir"
  echo "(Files will be kept for USB transfer or future imports)"
  echo ""
  
  # Step 1: Download blockchain parts
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 1: Downloading Blockchain Data (${#blockchain_part_urls[@]} parts)"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  for i in "${!blockchain_part_urls[@]}"; do
    local part_name="${blockchain_part_names[$i]}"
    local part_url="${blockchain_part_urls[$i]}"
    local part_num=$((i + 1))
    
    echo "[Part $part_num/${#blockchain_part_urls[@]}] Downloading $part_name..."
    
    if [[ "$download_tool" == "curl" ]]; then
      curl -L --progress-bar -o "$download_dir/$part_name" "$part_url" || {
        pause "❌ Failed to download $part_name"
        return
      }
    else
      wget --show-progress -O "$download_dir/$part_name" "$part_url" || {
        pause "❌ Failed to download $part_name"
        return
      }
    fi
  done
  
  # Download checksums (unified SHA256SUMS format only)
  if [[ -n "$sha256sums_url" ]]; then
    echo ""
    echo "Downloading unified checksum file (SHA256SUMS)..."
    if [[ "$download_tool" == "curl" ]]; then
      curl -sL -o "$download_dir/SHA256SUMS" "$sha256sums_url"
    else
      wget -q -O "$download_dir/SHA256SUMS" "$sha256sums_url"
    fi
  fi
  
  # Step 2: Download VM image
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 2: Downloading VM Image"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "Downloading $vm_image_name..."
  
  if [[ "$download_tool" == "curl" ]]; then
    curl -L --progress-bar -o "$download_dir/$vm_image_name" "$vm_image_url" || {
      pause "❌ Failed to download VM image"
      return
    }
  else
    wget --show-progress -O "$download_dir/$vm_image_name" "$vm_image_url" || {
      pause "❌ Failed to download VM image"
      return
    }
  fi
  
  # Download container image (if available)
  if [[ -n "$container_image_url" ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Step 2b: Downloading Container Image"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Downloading $container_image_name..."
    
    if [[ "$download_tool" == "curl" ]]; then
      curl -L --progress-bar -o "$download_dir/$container_image_name" "$container_image_url" || {
        echo "⚠ Failed to download container image (optional, continuing...)"
      }
    else
      wget --show-progress -O "$download_dir/$container_image_name" "$container_image_url" || {
        echo "⚠ Failed to download container image (optional, continuing...)"
      }
    fi
  fi
  
  # Step 2c: Download selected node binaries
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 2c: Downloading Node Binaries"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  local bitcoind_filename="bitcoind${binary_suffix}"
  local bitcoin_cli_filename="bitcoin-cli${binary_suffix}"
  
  echo "Downloading $bitcoind_filename..."
  if [[ "$download_tool" == "curl" ]]; then
    curl -L --progress-bar -o "$download_dir/$bitcoind_filename" "$bitcoind_url" || {
      pause "❌ Failed to download bitcoind binary"
      return
    }
  else
    wget --show-progress -O "$download_dir/$bitcoind_filename" "$bitcoind_url" || {
      pause "❌ Failed to download bitcoind binary"
      return
    }
  fi
  
  echo "Downloading $bitcoin_cli_filename..."
  if [[ "$download_tool" == "curl" ]]; then
    curl -L --progress-bar -o "$download_dir/$bitcoin_cli_filename" "$bitcoin_cli_url" || {
      pause "❌ Failed to download bitcoin-cli binary"
      return
    }
  else
    wget --show-progress -O "$download_dir/$bitcoin_cli_filename" "$bitcoin_cli_url" || {
      pause "❌ Failed to download bitcoin-cli binary"
      return
    }
  fi
  
  # Mark binaries as executable
  chmod +x "$download_dir/$bitcoind_filename"
  chmod +x "$download_dir/$bitcoin_cli_filename"
  
  # Step 3: Verify blockchain parts
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 3: Verifying Downloads"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Detect checksum format and verify
  if [[ -f "$download_dir/SHA256SUMS" ]]; then
    echo "Verifying blockchain parts (unified checksum)..."
    cd "$download_dir"
    
    local verify_failed=false
    while IFS= read -r line; do
      [[ "$line" =~ ^# ]] && continue  # Skip comments
      [[ -z "$line" ]] && continue     # Skip empty lines
      [[ ! "$line" =~ \.part[0-9][0-9] ]] && continue  # Skip non-part lines
      
      if ! echo "$line" | sha256sum -c --quiet 2>/dev/null; then
        echo "    ✗ Checksum failed for: $(echo "$line" | awk '{print $2}')"
        verify_failed=true
      fi
    done < "SHA256SUMS"
    
    if [[ "$verify_failed" == "true" ]]; then
      cd - >/dev/null
      pause "❌ One or more blockchain parts failed checksum verification!"
      return
    fi
    
    echo "    ✓ All blockchain parts verified"
    
    # Verify VM image from same SHA256SUMS file
    echo ""
    echo "Verifying VM image (unified checksum)..."
    if grep -q "$(basename "$vm_image_name")" "SHA256SUMS" 2>/dev/null; then
      if sha256sum -c SHA256SUMS --ignore-missing --quiet 2>/dev/null; then
        echo "    ✓ VM image verified"
      else
        cd - >/dev/null
        pause "❌ VM image checksum verification failed!"
        return
      fi
    else
      echo "    ⚠ VM image not in SHA256SUMS (skipping verification)"
    fi
    
    # Verify container image from same SHA256SUMS file (if downloaded)
    if [[ -n "$container_image_url" ]] && [[ -f "$download_dir/$container_image_name" ]]; then
      echo ""
      echo "Verifying container image (unified checksum)..."
      if grep -q "$(basename "$container_image_name")" "SHA256SUMS" 2>/dev/null; then
        if sha256sum -c SHA256SUMS --ignore-missing --quiet 2>/dev/null; then
          echo "    ✓ Container image verified"
        else
          echo "    ⚠ Container image checksum failed (optional, continuing...)"
        fi
      else
        echo "    ⚠ Container image not in SHA256SUMS (skipping verification)"
      fi
    fi
    
    cd - >/dev/null
  else
    echo "    ⚠ No checksum files found (skipping verification)"
  fi
  
  # Step 4: Reassemble blockchain
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 4: Reassembling Blockchain Data"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Reassemble blockchain from parts
  if ls "$download_dir"/blockchain.tar.gz.part* >/dev/null 2>&1; then
    cat "$download_dir"/blockchain.tar.gz.part* > "$download_dir/blockchain.tar.gz"
    echo "✓ Blockchain reassembled"
  else
    pause "❌ No blockchain parts found to reassemble!"
    return
  fi
  
  # Verify reassembled blockchain if checksum available
  if [[ -f "$download_dir/SHA256SUMS" ]]; then
    echo ""
    echo "Verifying reassembled blockchain..."
    cd "$download_dir"
    
    if grep -q "blockchain\.tar\.gz\$" "SHA256SUMS" 2>/dev/null; then
      if sha256sum -c SHA256SUMS --ignore-missing --quiet 2>/dev/null; then
        echo "    ✓ Reassembled blockchain verified"
      else
        cd - >/dev/null
        pause "❌ Reassembled blockchain checksum verification failed!"
        return
      fi
    else
      echo "    ⚠ No checksum entry for reassembled blockchain"
    fi
    
    cd - >/dev/null
  else
    echo "    ⚠ No checksum files found (skipping verification)"
  fi
  
  # Step 5: Extract and import VM image
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 5: Importing VM Image"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  local vm_extract_dir="$download_dir/vm-image"
  mkdir -p "$vm_extract_dir"
  
  echo "Extracting VM image archive..."
  tar -xzf "$download_dir/$vm_image_name" -C "$vm_extract_dir"
  
  # Find the qcow2 disk file
  local vm_disk=$(find "$vm_extract_dir" -name "*.qcow2" | head -n1)
  if [[ -z "$vm_disk" ]]; then
    pause "❌ No .qcow2 disk file found in VM image archive"
    return
  fi
  
  # Find the XML definition
  local vm_xml=$(find "$vm_extract_dir" -name "*.xml" | head -n1)
  if [[ -z "$vm_xml" ]]; then
    pause "❌ No .xml definition file found in VM image archive"
    return
  fi
  
  echo "Found VM disk: $(basename "$vm_disk")"
  echo "Found VM definition: $(basename "$vm_xml")"
  echo ""
  
  # Step 6: Inject blockchain into VM disk
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 6: Injecting Blockchain Data into VM"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Decompress blockchain archive first (virt-tar-in requires uncompressed tar)
  echo "Decompressing blockchain archive..."
  local blockchain_temp="$HOME/.cache/gm-blockchain-temp-$$"
  mkdir -p "$blockchain_temp"
  cp "$download_dir/blockchain.tar.gz" "$blockchain_temp/"
  
  if ! gunzip "$blockchain_temp/blockchain.tar.gz"; then
    rm -rf "$blockchain_temp"
    pause "❌ Failed to decompress blockchain archive"
    return
  fi
  
  # Get the decompressed tar filename (remove .gz extension from blockchain.tar.gz)
  local tar_file="$blockchain_temp/blockchain.tar"
  
  echo "Injecting blockchain into VM disk (this may take several minutes)..."
  sudo virt-tar-in -a "$vm_disk" "$tar_file" /var/lib/bitcoin || {
    rm -rf "$blockchain_temp"
    pause "❌ Failed to inject blockchain data into VM disk"
    return
  }
  
  # Cleanup temporary files
  rm -rf "$blockchain_temp"
  
  echo "    ✓ Blockchain injected"
  
  # Fix ownership - tar preserves UIDs which may not match the VM's bitcoin user
  echo "    Fixing ownership of blockchain files..."
  sudo virt-customize -a "$vm_disk" --no-selinux-relabel \
    --run-command "chown -R bitcoin:bitcoin /var/lib/bitcoin" \
    2>&1 | grep -v "random seed" >&2
  
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    echo "    ✓ Ownership fixed"
  else
    echo "    ⚠ Warning: Failed to fix ownership (may cause startup issues)"
  fi
  
  # Step 6b: Inject selected node binaries into VM disk
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 6b: Injecting Node Binaries into VM"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  echo "Preparing binaries for injection..."
  local binaries_temp="$HOME/.cache/gm-binaries-temp-$$"
  mkdir -p "$binaries_temp"
  
  # Copy binaries to temp location with standard names
  cp "$download_dir/$bitcoind_filename" "$binaries_temp/bitcoind"
  cp "$download_dir/$bitcoin_cli_filename" "$binaries_temp/bitcoin-cli"
  
  echo "Injecting bitcoind and bitcoin-cli into VM..."
  sudo virt-copy-in -a "$vm_disk" "$binaries_temp/bitcoind" "$binaries_temp/bitcoin-cli" /usr/local/bin/ || {
    rm -rf "$binaries_temp"
    pause "❌ Failed to inject binaries into VM disk"
    return
  }
  
  rm -rf "$binaries_temp"
  echo "    ✓ Binaries injected"
  
  # Set permissions on binaries
  echo "    Setting binary permissions..."
  sudo virt-customize -a "$vm_disk" --no-selinux-relabel \
    --run-command "chmod 755 /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli" \
    2>&1 | grep -v "random seed" >&2
  
  if [ "${PIPESTATUS[0]}" -eq 0 ]; then
    echo "    ✓ Permissions set"
  else
    echo "    ⚠ Warning: Failed to set binary permissions"
  fi
  
  # Step 7: Import VM into libvirt
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 7: Installing VM into Libvirt"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Copy disk to libvirt images directory
  local final_disk_path="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  echo "Copying disk to $final_disk_path..."
  sudo cp "$vm_disk" "$final_disk_path"
  sudo chown libvirt-qemu:kvm "$final_disk_path"
  
  # Update XML with correct VM name and disk path
  echo "Updating VM definition..."
  local temp_xml="/tmp/gm-import-$$.xml"
  cp "$vm_xml" "$temp_xml"
  
  # Update VM name
  sed -i "s|<name>.*</name>|<name>$VM_NAME</name>|" "$temp_xml"
  
  # Update disk path
  sed -i "s|<source file='[^']*'/>|<source file='$final_disk_path'/>|" "$temp_xml"
  
  # Import VM definition
  echo "Importing VM definition..."
  sudo virsh define "$temp_xml" || {
    rm -f "$temp_xml"
    pause "❌ Failed to import VM definition"
    return
  }
  
  rm -f "$temp_xml"
  echo "    ✓ VM imported successfully"
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                   VM Import Complete!                                          ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "The base VM '$VM_NAME' has been created with:"
  echo "  • VM image (Alpine Linux + $([ "$binary_suffix" == "-gm" ] && echo "Garbageman" || echo "Bitcoin Knots"))"
  echo "  • Complete blockchain data"
  if [[ -n "$container_image_url" ]] && [[ -f "$download_dir/$container_image_name" ]]; then
    echo "  • Container image (downloaded for later use)"
  fi
  echo ""
  echo "Downloaded files saved to:"
  echo "  $download_dir"
  echo ""
  echo "  ℹ You can copy this folder to USB stick for importing on another computer"
  echo "  ℹ Use 'Import from File' option and select the folder to import"
  if [[ -n "$container_image_url" ]] && [[ -f "$download_dir/$container_image_name" ]]; then
    echo "  ℹ Both VM and container images available - switch between them anytime"
  fi
  echo "  ℹ Temporary files cleaned up automatically"
  echo ""
  echo "Next steps:"
  echo "  • Start VM with 'Monitor Base VM Sync' or 'Manage Base VM'"
  echo "  • Create clones for additional nodes"
  echo ""
  
  pause "Press Enter to return to main menu..."
}

################################################################################
# Create Base VM (Action 1)
################################################################################

# create_base_vm: Main entry point for Action 1
# Purpose: Offers choice between importing from GitHub, importing from file, or building from scratch
# Flow:
#   1. Check if VM already exists (abort if it does)
#   2. Present menu: "Import from GitHub", "Import from file", or "Build from scratch"
#   3. Call appropriate function based on selection
create_base_vm(){
  # Check if VM already exists
  if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    pause "A VM named '$VM_NAME' already exists."
    return
  fi
  
  # Present choice menu
  local choice
  choice=$(whiptail --title "Create Base VM" \
    --menu "How would you like to create the base VM?\n" 18 78 3 \
    "1" "Import from GitHub (download ~22GB from latest release)" \
    "2" "Import from file (local export in ~/Downloads)" \
    "3" "Build from scratch (compile: 2+ hours, sync: 24-28 hours)" \
    3>&1 1>&2 2>&3) || return
  
  case "$choice" in
    1) import_from_github ;;
    2) import_base_vm ;;
    3) create_base_vm_from_scratch ;;
    *) return ;;
  esac
}

# create_base_vm_from_scratch: Build base VM from scratch (original create_base_vm logic)
# Purpose: Main function for Action 1 - creates the initial VM from scratch
# Flow:
#   1. Check if VM already exists (abort if it does)
#   2. Let user configure defaults (reserves, VM sizes, clearnet toggle)
#   3. Prompt for initial sync resources (vCPUs/RAM for IBD)
#   4. Create Alpine Linux disk image with virt-builder
#   5. Install kernel, network tools, and base packages
#   6. Build Garbageman (Bitcoin Knots fork) INSIDE the VM using virt-customize
#   7. Configure bitcoind service, Tor hidden service, user accounts
#   8. Create libvirt domain definition (but don't start VM yet)
# Note: This process takes 2+ hours depending on host resources
# Side effects: Creates VM disk at /var/lib/libvirt/images/${VM_NAME}.qcow2
create_base_vm_from_scratch(){
  # Start sudo keepalive to prevent timeout during long build process
  # Force it to start since we'll be using sudo virt-customize extensively
  sudo_keepalive_start force

  ensure_tools
  
  # Verify libvirt is accessible before proceeding (catches permission issues early)
  check_libvirt_access

  # Step 0: Let user choose node type (Garbageman or Bitcoin Knots)
  local node_choice
  node_choice=$(whiptail --title "Select Node Type" --menu \
    "Choose which Bitcoin implementation to build:" 15 70 2 \
    "1" "Garbageman" \
    "2" "Bitcoin Knots" \
    3>&1 1>&2 2>&3)
  
  if [[ -z "$node_choice" ]]; then
    pause "Cancelled."
    return
  fi
  
  # Set repository and branch/tag based on selection
  local GM_REPO GM_BRANCH GM_IS_TAG
  if [[ "$node_choice" == "1" ]]; then
    GM_REPO="https://github.com/chrisguida/bitcoin.git"
    GM_BRANCH="garbageman-v29"
    GM_IS_TAG="false"
    echo "Selected: Garbageman (Libre Relay)"
  elif [[ "$node_choice" == "2" ]]; then
    GM_REPO="https://github.com/bitcoinknots/bitcoin.git"
    GM_BRANCH="v29.2.knots20251010"
    GM_IS_TAG="true"
    echo "Selected: Bitcoin Knots"
  else
    pause "Invalid selection."
    return
  fi

  # Let user configure/edit defaults & clearnet toggle; show confirmation.
  if ! configure_defaults_direct; then
    pause "Cancelled."
    return
  fi

  # Prompt for initial sync resources (prefilled with new suggestions)
  if ! prompt_sync_resources; then
    pause "Cancelled."
    return
  fi

  local disk="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  
  # Handle existing disk image
  if [[ -f "$disk" ]]; then
    if whiptail --title "Existing Disk Found" \
      --yesno "Disk $disk already exists.\n\nDo you want to overwrite it?\n\nChoose 'Yes' to delete and recreate, or 'No' to cancel." \
      12 70; then
      echo "Removing existing disk: $disk"
      sudo rm -f "$disk"
    else
      pause "Cancelled - disk already exists."
      return
    fi
  fi

  # Create prebuilt Alpine image with all configurations
  create_prebuilt_alpine_image "$disk"
  
  # Install kernel and essential packages BEFORE VM boots
  # This is critical - the VM needs a kernel to boot and networking to complete first-boot
  # Also install tor here so we can configure it before first boot
  echo "Installing kernel and essential packages into Alpine image..."
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "apk update" \
    --run-command "apk add linux-virt grub grub-bios openssh openrc util-linux coreutils e2fsprogs tor shadow netcat-openbsd" \
    --run-command "grub-install --target=i386-pc /dev/sda" \
    --run-command "echo 'GRUB_CMDLINE_LINUX_DEFAULT=\"console=tty0 console=ttyS0,115200n8 rootfstype=ext4\"' >> /etc/default/grub" \
    --run-command "echo 'GRUB_TERMINAL=\"console serial\"' >> /etc/default/grub" \
    --run-command "echo 'GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"' >> /etc/default/grub" \
    --run-command "grub-mkconfig -o /boot/grub/grub.cfg" \
    --run-command "sed -i 's|root=UUID=[^ ]*|root=/dev/vda1|g' /boot/grub/grub.cfg" \
    --run-command "sed -i 's| ro | rw |g' /boot/grub/grub.cfg" \
    --run-command "ln -sf /etc/init.d/networking /etc/runlevels/boot/networking || true" \
    --run-command "ln -sf /etc/init.d/sshd /etc/runlevels/default/sshd || true" \
    --run-command "adduser -D -s /bin/bash bitcoin" \
    --run-command "mkdir -p /var/lib/bitcoin /etc/bitcoin" \
    --run-command "chown bitcoin:bitcoin /var/lib/bitcoin /etc/bitcoin" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ Failed to install kernel and packages"
    return 1
  fi
  
  # Build Bitcoin inside the Alpine VM (native musl build)
  build_garbageman_in_vm "$disk" "$GM_REPO" "$GM_BRANCH" "$GM_IS_TAG"

  # Configure bitcoin.conf and OpenRC service
  echo "Configuring Tor, bitcoin.conf and bitcoind service..."
  
  # Configure Tor
  local tor_config='SOCKSPort 9050
ControlPort 9051
CookieAuthentication 1
CookieAuthFileGroupReadable 1
DataDirectory /var/lib/tor
HiddenServiceDir /var/lib/tor/bitcoin-service
HiddenServicePort 8333 127.0.0.1:8333'

  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "mkdir -p /etc/tor" \
    --write /etc/tor/torrc:"$tor_config" \
    --run-command "chown root:root /etc/tor/torrc" \
    --run-command "chmod 644 /etc/tor/torrc" \
    --run-command "mkdir -p /var/lib/tor" \
    --run-command "chown -R tor /var/lib/tor" \
    --run-command "chmod 700 /var/lib/tor" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ Failed to configure Tor"
    return 1
  fi
  
  # Decide which bitcoin.conf to use based on CLEARNET_OK
  local btc_conf_content
  if [[ "$CLEARNET_OK" == "yes" ]]; then
    btc_conf_content="server=1
daemon=1
prune=750
dbcache=450
maxconnections=25

# Tor configuration
proxy=127.0.0.1:9050
listen=1
bind=127.0.0.1

# Allow both Tor and clearnet
onlynet=onion
onlynet=ipv4

[main]"
  else
    btc_conf_content="server=1
daemon=1
prune=750
dbcache=450
maxconnections=25

# Tor-only configuration
proxy=127.0.0.1:9050
listen=1
bind=127.0.0.1
onlynet=onion

[main]"
  fi

  # Create OpenRC service for bitcoind
  # Simple approach: let bitcoind daemonize itself, OpenRC just starts/stops it
  local bitcoind_service='#!/sbin/openrc-run

name="Bitcoin daemon"
description="Bitcoin cryptocurrency P2P network daemon"

command="/usr/local/bin/bitcoind"
command_args="-conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin"
command_user="bitcoin:bitcoin"

depend() {
    need net
    use tor
    after tor
}

start_pre() {
    checkpath --directory --owner bitcoin:bitcoin --mode 0755 /var/lib/bitcoin
    checkpath --directory --owner bitcoin:bitcoin --mode 0755 /etc/bitcoin
    
    # Wait for Tor SOCKS proxy to be ready (up to 30 seconds)
    ebegin "Waiting for Tor SOCKS proxy"
    local i=0
    while [ $i -lt 30 ]; do
        if nc -z 127.0.0.1 9050 2>/dev/null; then
            eend 0
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    ewarn "Tor SOCKS proxy not available after 30 seconds, starting bitcoind anyway"
}

start() {
    ebegin "Starting bitcoind"
    start-stop-daemon --start --user bitcoin --exec /usr/local/bin/bitcoind -- -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin
    eend $?
}

stop() {
    ebegin "Stopping bitcoind"
    start-stop-daemon --stop --user bitcoin --exec /usr/local/bin/bitcoind --retry 60
    eend $?
}'

  # Install bitcoin.conf and bitcoind service
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "mkdir -p /etc/bitcoin" \
    --run-command "mkdir -p /var/lib/bitcoin" \
    --write /etc/bitcoin/bitcoin.conf:"$btc_conf_content" \
    --run-command "chown bitcoin:bitcoin /etc/bitcoin/bitcoin.conf" \
    --run-command "chmod 640 /etc/bitcoin/bitcoin.conf" \
    --run-command "chown -R bitcoin:bitcoin /var/lib/bitcoin" \
    --write /etc/init.d/bitcoind:"$bitcoind_service" \
    --run-command "chmod +x /etc/init.d/bitcoind" \
    --run-command "rc-update add bitcoind default" \
    --run-command "rc-update add tor default" \
    2>&1 | grep -v "random seed" >&2
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ Failed to install bitcoin configuration"
    return 1
  fi

  echo "✅ Tor, Bitcoin configuration and service installed!"
  echo ""

  # Create VM domain definition using the prebuilt image
  echo "Creating VM domain with prebuilt image..."
  echo ""
  
  # Use sudo and explicit connection for virt-install to avoid permission issues
  # --import starts the VM immediately, --noautoconsole prevents dropping to console
  # Always use qemu:///system to ensure we're working with the system libvirt instance
  if ! sudo virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --memory "$SYNC_RAM_MB" --vcpus "$SYNC_VCPUS" --cpu host \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --network "network=default,model=virtio" \
    --osinfo alpinelinux3.18 \
    --graphics none --noautoconsole \
    --import 2>&1; then
    echo ""
    echo "❌ VM creation failed!"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check if libvirtd is running: sudo systemctl status libvirtd"
    echo "2. Check if default network is active: sudo virsh net-list --all"
    echo "3. Try restarting libvirtd: sudo systemctl restart libvirtd"
    echo "4. If you just installed packages, you may need to log out and back in"
    echo "   Alternatively, run: sg libvirt -c './garbageman-nm.sh'"
    die "Failed to create VM domain with virt-install. See troubleshooting above."
  fi

  # virt-install --import automatically starts the VM, but we want it stopped
  # so the user can start it fresh with monitoring when they choose Action 2
  echo ""
  echo "Stopping VM (will be started fresh when you choose 'Start & Monitor')..."
  virsh_cmd shutdown "$VM_NAME" 2>/dev/null || true
  sleep 3
  if [[ "$(vm_state "$VM_NAME")" != "shut off" ]]; then
    echo "Graceful shutdown taking too long, forcing stop..."
    virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
    sleep 2
  fi

  echo ""
  echo "✅ Base VM '$VM_NAME' created successfully using prebuilt Alpine image!"
  echo "   Initial resources: ${SYNC_VCPUS} vCPUs, ${SYNC_RAM_MB} MiB RAM"
  echo "   VM is stopped and ready to start with monitoring."
  echo ""
  echo "Next step: Choose 'Start & Monitor Base VM' from the menu to begin IBD sync."

  pause "Base VM '$VM_NAME' created.\n\nInitial sync resources: ${SYNC_VCPUS} vCPUs, ${SYNC_RAM_MB} MiB RAM.\n\nThe VM is stopped and ready. Choose 'Start & Monitor Base VM' to begin syncing."
}


################################################################################
# VM Status Monitor
################################################################################

# get_peer_breakdown: Analyze peer user agents and categorize them
# Args: $1 = IP address of VM
# Returns: Formatted string like "21 (5 LR/GM, 3 KNOTS, 2 OLDCORE, 7 COREv30+, 4 OTHER)"
# Categories:
#   LR/GM: Libre Relay or Garbageman (has Libre Relay service bit)
#   KNOTS: Bitcoin Knots (any version)
#   OLDCORE: Bitcoin Core < v30
#   COREv30+: Bitcoin Core >= v30
#   OTHER: Everything else
get_peer_breakdown(){
  local ip="$1"
  local peerinfo
  
  # Get detailed peer information
  peerinfo=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getpeerinfo 2>/dev/null' 2>/dev/null || echo "[]")
  
  # Count total peers
  local total=$(jq 'length' <<<"$peerinfo" 2>/dev/null || echo 0)
  
  if [[ "$total" -eq 0 ]]; then
    echo "0"
    return
  fi
  
  # Initialize counters
  local lr_gm=0 knots=0 oldcore=0 core30plus=0 other=0
  
  # Parse each peer's user agent and services
  while IFS= read -r peer; do
    local subver=$(jq -r '.subver // ""' <<<"$peer" 2>/dev/null)
    local services=$(jq -r '.services // ""' <<<"$peer" 2>/dev/null)
    
    # Check for Libre Relay bit (bit 29: 0x20000000 = 536870912 in decimal)
    # Services is a hex string like "000000000000040d" or "20000409"
    if [[ -n "$services" ]]; then
      local services_dec=$((16#${services}))
      if (( (services_dec & 0x20000000) != 0 )); then
        ((lr_gm++))
        continue
      fi
    fi
    
    # Check user agent string patterns
    if [[ "$subver" =~ [Kk]nots ]]; then
      ((knots++))
    elif [[ "$subver" =~ /Satoshi:([0-9]+)\. ]]; then
      local version="${BASH_REMATCH[1]}"
      if [[ "$version" -ge 30 ]]; then
        ((core30plus++))
      else
        ((oldcore++))
      fi
    else
      ((other++))
    fi
  done < <(jq -c '.[]' <<<"$peerinfo" 2>/dev/null)
  
  # Build the breakdown string - always show all categories
  local breakdown="$total ($lr_gm LR/GM, $knots KNOTS, $oldcore OLDCORE, $core30plus COREv30+, $other OTHER)"
  
  echo "$breakdown"
}

# get_node_classification: Classify the running node on VM
# Args: $1 = IP address of VM
# Returns: Classification string based on the node's subversion and services
# Detection Logic:
#   1. Libre Relay/Garbageman: Has Libre Relay service bit 29 (0x20000000 hex = 536870912 dec)
#      - Checked via localservices field in getnetworkinfo
#   2. Bitcoin Knots: subversion field contains "knots" or "Knots"
#   3. Bitcoin Core pre-30: subversion contains "Satoshi" and version < 30
#   4. Bitcoin Core v30+: subversion contains "Satoshi" and version >= 30
#   5. Unknown: Doesn't match any of the above
# Note: Returns empty string if RPC not ready yet
get_node_classification(){
  local ip="$1"
  local netinfo
  
  # Get network information from the running node
  netinfo=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null' 2>/dev/null || echo "")
  
  if [[ -z "$netinfo" ]]; then
    echo ""  # Blank - RPC not ready yet
    return
  fi
  
  local subver=$(jq -r '.subversion // ""' <<<"$netinfo" 2>/dev/null)
  local services=$(jq -r '.localservices // ""' <<<"$netinfo" 2>/dev/null)
  
  # Check if localservices is available yet (empty means not ready)
  if [[ -z "$services" ]]; then
    echo ""  # Blank - node is still starting up
    return
  fi
  
  # Check for Libre Relay bit (bit 29: 0x20000000 = 536870912 in decimal)
  # localservices is returned as a hexadecimal string
  local services_dec=0
  if [[ "$services" =~ ^[0-9a-fA-F]+$ ]]; then
    services_dec=$((16#${services}))
  fi
  
  if (( (services_dec & 0x20000000) != 0 )); then
    echo "Libre Relay/Garbageman"
    return
  fi
  
  # Libre Relay bit is not set, check if it's a known implementation
  # Check user agent string patterns
  if [[ "$subver" =~ [Kk]nots ]]; then
    echo "Bitcoin Knots"
    return
  elif [[ "$subver" =~ /Satoshi:([0-9]+)\. ]]; then
    local version="${BASH_REMATCH[1]}"
    if [[ "$version" -ge 30 ]]; then
      echo "Bitcoin Core v30+"
      return
    else
      echo "Bitcoin Core pre-30"
      return
    fi
  else
    echo "Unknown"  # Other implementation with Libre Relay bit = 0
    return
  fi
}

# debug_node_classification: Debug helper to test classification logic
# Usage: debug_node_classification <vm_ip_or_container_name> [vm|container]
debug_node_classification(){
  local target="$1"
  local mode="${2:-vm}"
  
  echo "=== Node Classification Debug ==="
  echo "Target: $target"
  echo "Mode: $mode"
  echo ""
  
  local netinfo
  if [[ "$mode" == "container" ]]; then
    echo "Getting network info from container..."
    netinfo=$(container_exec "$target" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>&1)
  else
    echo "Getting network info from VM..."
    netinfo=$(gssh "$target" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>&1')
  fi
  
  echo "RPC Response:"
  echo "$netinfo"
  echo ""
  
  if [[ -z "$netinfo" || "$netinfo" =~ error ]]; then
    echo "Classification: Empty (RPC not ready)"
    return
  fi
  
  local subver=$(echo "$netinfo" | jq -r '.subversion // ""' 2>/dev/null)
  local services=$(echo "$netinfo" | jq -r '.localservices // ""' 2>/dev/null)
  
  echo "Parsed values:"
  echo "  subversion: '$subver'"
  echo "  services: '$services'"
  echo ""
  
  if [[ -z "$services" ]]; then
    echo "Classification: Empty (services not ready)"
    return
  fi
  
  local services_dec=0
  if [[ "$services" =~ ^[0-9a-fA-F]+$ ]]; then
    services_dec=$((16#${services}))
    echo "  services_dec: $services_dec (parsed from hex)"
    echo "  Libre Relay bit 29 (0x20000000 = 536870912): $(( (services_dec & 0x20000000) != 0 ? 1 : 0 ))"
  else
    echo "  services format invalid"
  fi
  echo ""
  
  # Call the actual classification function
  if [[ "$mode" == "container" ]]; then
    local result=$(get_node_classification_container "$target")
  else
    local result=$(get_node_classification "$target")
  fi
  
  echo "Final Classification: '$result'"
}

# monitor_vm_status: Live monitoring display for any VM
# Purpose: Show real-time status with auto-refresh (like IBD monitor but simpler)
# Args: $1 = VM name to monitor
# Display: Auto-refreshing every 5 seconds, exit with Ctrl+C
# Shows: State, Internal IP, .onion address, blocks/headers, peers, resources
#        IPv4 address (only for BASE VM when CLEARNET_OK=yes). VM clones are Tor-only.
monitor_vm_status(){
  local vm_name="$1"
  
  echo ""
  echo "=========================================="
  echo "Monitoring VM: $vm_name"
  echo "Press 'q' to return to menu"
  echo "=========================================="
  echo ""
  
  while true; do
    local state ip onion blocks headers peers ibd vp
    local info netinfo
    
    # Get VM state
    state=$(vm_state "$vm_name" 2>/dev/null || echo "unknown")
    
    # If running, get network info
    if [[ "$state" == "running" ]]; then
      ip=$(vm_ip "$vm_name" 2>/dev/null || echo "")
      
      if [[ -n "$ip" ]]; then
        # Get .onion address
        onion=$(gssh "$ip" 'cat /var/lib/tor/bitcoin-service/hostname 2>/dev/null' 2>/dev/null || echo "unknown")
        
        # Check if this is the base VM and if clearnet is enabled
        local ipv4_address=""
        if [[ "$vm_name" == "$VM_NAME" ]] && [[ "${CLEARNET_OK,,}" == "yes" ]]; then
          # Get external IPv4 address for base VM when clearnet is enabled
          ipv4_address=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null' 2>/dev/null | jq -r '.localaddresses[] | select(.network=="ipv4") | .address' 2>/dev/null | head -n1 || echo "")
          if [[ -z "$ipv4_address" ]]; then
            # Fallback: try to get from VM's network interface
            ipv4_address=$(gssh "$ip" 'ip -4 addr show eth0 2>/dev/null | grep -oP "(?<=inet\s)\d+(\.\d+){3}"' 2>/dev/null | head -n1 || echo "detecting...")
          fi
        fi
        
        # Get blockchain info
        info=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null' 2>/dev/null || echo "")
        blocks=$(jq -r '.blocks // "?"' <<<"$info" 2>/dev/null || echo "?")
        headers=$(jq -r '.headers // "?"' <<<"$info" 2>/dev/null || echo "?")
        vp=$(jq -r '.verificationprogress // 0' <<<"$info" 2>/dev/null || echo "0")
        ibd=$(jq -r '.initialblockdownload // "?"' <<<"$info" 2>/dev/null || echo "?")
        
        # Get network info
        netinfo=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null' 2>/dev/null || echo "")
        peers=$(jq -r '.connections // "?"' <<<"$netinfo" 2>/dev/null || echo "?")
        
        # Get detailed peer breakdown
        local peer_breakdown=$(get_peer_breakdown "$ip")
        
        # Get node classification
        local node_classification=$(get_node_classification "$ip")
        
        # Calculate percentage
        local pct=$(awk -v p="$vp" 'BEGIN{if(p<0)p=0;if(p>1)p=1;printf "%d", int(p*100+0.5)}')
      fi
    fi
    
    # Get VM resource allocation
    local vm_vcpus vm_ram_mb
    if sudo virsh dominfo "$vm_name" >/dev/null 2>&1; then
      vm_vcpus=$(sudo virsh dominfo "$vm_name" 2>/dev/null | grep -i "CPU(s)" | awk '{print $2}' || echo "?")
      local ram_kib=$(sudo virsh dominfo "$vm_name" 2>/dev/null | grep -i "Max memory" | awk '{print $3}' || echo "0")
      vm_ram_mb=$((ram_kib / 1024))
    else
      vm_vcpus="?"
      vm_ram_mb="?"
    fi
    
    detect_host_resources
    
    # Clear screen and display
    clear
    printf "╔════════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║%-80s║\n" "                        VM Status Monitor - $vm_name"
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Host Resources:"
    printf "║%-80s║\n" "    Cores: ${HOST_CORES} total | ${RESERVE_CORES} reserved | ${AVAIL_CORES} available"
    printf "║%-80s║\n" "    RAM:   ${HOST_RAM_MB} MiB total | ${RESERVE_RAM_MB} MiB reserved | ${AVAIL_RAM_MB} MiB available"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  VM Configuration:"
    printf "║%-80s║\n" "    Name:   $vm_name"
    printf "║%-80s║\n" "    State:  $state"
    printf "║%-80s║\n" "    vCPUs:  $vm_vcpus"
    printf "║%-80s║\n" "    RAM:    ${vm_ram_mb} MiB"
    printf "║%-80s║\n" ""
    
    if [[ "$state" == "running" && -n "$ip" ]]; then
      printf "║%-80s║\n" "  Network Status:"
      printf "║%-80s║\n" "    Internal IP: $ip"
      printf "║%-80s║\n" "    Tor:         $onion"
      if [[ -n "$ipv4_address" ]]; then
        printf "║%-80s║\n" "    IPv4:        $ipv4_address (clearnet enabled)"
      fi
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Bitcoin Status:"
      if [[ -n "$node_classification" ]]; then
        printf "║%-80s║\n" "    Node Type:  $node_classification"
      else
        printf "║%-80s║\n" "    Node Type:  Starting..."
      fi
      printf "║%-80s║\n" "    Blocks:     $blocks / $headers"
      printf "║%-80s║\n" "    Progress:   ${pct}% (${vp})"
      printf "║%-80s║\n" "    Peers:      $peer_breakdown"
      printf "║%-80s║\n" ""
    elif [[ "$state" == "running" ]]; then
      printf "║%-80s║\n" "  Network Status:"
      printf "║%-80s║\n" "    Waiting for network connection..."
      printf "║%-80s║\n" ""
    else
      printf "║%-80s║\n" "  VM is not running"
      printf "║%-80s║\n" ""
    fi
    
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" "  Auto-refreshing every 5 seconds... Press 'q' to exit"
    printf "╚════════════════════════════════════════════════════════════════════════════════╝\n"
    
    # Use read with timeout - check if user pressed 'q'
    read -t 5 -n 1 key 2>/dev/null || true
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
      clear
      echo ""
      echo "Monitor stopped."
      sleep 1
      return
    fi
  done
}


################################################################################
# Resize Base VM (after IBD completes)
################################################################################

# resize_vm_to_defaults: Downsize VM to runtime resources after IBD completes
# Purpose: IBD needs more resources, but long-term operation needs less
# Args: None (uses global VM_VCPUS and VM_RAM_MB)
# Side effects: Modifies VM configuration (requires VM to be shut off)
resize_vm_to_defaults(){
  # Only operate when VM is off (can't change resources on running VM)
  [[ "$(vm_state "$VM_NAME")" == "shut off" ]] || return 0
  
  local mem_kib=$(( VM_RAM_MB * 1024 ))
  sudo virsh setmaxmem "$VM_NAME" "${mem_kib}" --config
  sudo virsh setmem    "$VM_NAME" "${mem_kib}" --config
  sudo virsh setvcpus "$VM_NAME" "$VM_VCPUS" --config --maximum
  sudo virsh setvcpus "$VM_NAME" "$VM_VCPUS" --config
  pause "Base VM updated for runtime:\n- vCPUs: ${VM_VCPUS}\n- RAM: ${VM_RAM_MB} MiB"
}


################################################################################
# Start & Monitor IBD Sync (Action 2)
################################################################################

# monitor_sync: Interactive IBD monitoring with progress UI and resource configuration
# Purpose: Main function for Action 2 - starts VM, monitors bitcoind sync progress
# Flow:
#   1. Check VM exists and is stopped
#   2. Prompt user to configure/confirm vCPU and RAM resources
#   3. Apply resource changes if needed (via virsh setvcpus/setmem)
#   4. Inject SSH key for monitoring access
#   5. Start the VM
#   6. Wait for network/SSH to come up
#   7. Poll bitcoin-cli getblockchaininfo every POLL_SECS seconds
#   8. Display progress in dialog gauge (Cancel = graceful shutdown)
#   9. When IBD completes, offer to downsize to runtime resources
# Returns: 0 on normal exit, 1 on error
monitor_sync(){
  ensure_tools
  virsh_cmd dominfo "$VM_NAME" >/dev/null 2>&1 || die "VM '$VM_NAME' not found."

  # Check if VM is already running
  local vm_state_now
  vm_state_now="$(vm_state "$VM_NAME")"
  
  local ip
  if [[ "$vm_state_now" == "running" ]]; then
    # VM is already running - prompt for resource changes
    echo "VM '$VM_NAME' is already running."
    echo ""
    
    # Get current VM resources from libvirt configuration
    local current_vcpus current_ram_mb
    current_vcpus=$(sudo virsh dominfo "$VM_NAME" | grep -i "CPU(s)" | awk '{print $2}')
    
    # Parse RAM - dominfo outputs in KiB, need to convert to MiB
    local ram_line
    ram_line=$(sudo virsh dominfo "$VM_NAME" | grep -i "Max memory")
    current_ram_mb=$(echo "$ram_line" | awk '{print $3}')
    
    # Check if output is in KiB and convert to MiB
    if echo "$ram_line" | grep -qi "KiB"; then
      current_ram_mb=$((current_ram_mb / 1024))
    fi

    detect_host_resources

    # Prompt user to confirm or change resources
    local banner="Host: ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Reserve kept: ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB
Available for sync: ${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Current VM configuration: ${current_vcpus} vCPUs, ${current_ram_mb} MiB RAM
(VM is currently running)"

    local new_vcpus new_ram_mb
    new_vcpus=$(whiptail --title "Sync vCPUs" --inputbox \
      "$banner\n\nEnter vCPUs for this sync session:" \
      19 78 "${current_vcpus}" 3>&1 1>&2 2>&3) || return 1
    [[ "$new_vcpus" =~ ^[0-9]+$ ]] || die "vCPUs must be a positive integer."
    [[ "$new_vcpus" -ge 1 ]] || die "vCPUs must be at least 1."
    (( new_vcpus <= AVAIL_CORES )) || die "Requested vCPUs ($new_vcpus) exceeds available after reserve (${AVAIL_CORES})."

    new_ram_mb=$(whiptail --title "Sync RAM (MiB)" --inputbox \
      "$banner\n\nEnter RAM (MiB) for this sync session:" \
      19 78 "${current_ram_mb}" 3>&1 1>&2 2>&3) || return 1
    [[ "$new_ram_mb" =~ ^[0-9]+$ ]] || die "RAM must be a positive integer."
    [[ "$new_ram_mb" -ge 2048 ]] || die "RAM should be at least 2048 MiB for IBD."
    (( new_ram_mb <= AVAIL_RAM_MB )) || die "Requested RAM ($new_ram_mb MiB) exceeds available after reserve (${AVAIL_RAM_MB} MiB)."

    # Check if resources need to be changed
    local need_restart=false
    if [[ "$new_vcpus" != "$current_vcpus" || "$new_ram_mb" != "$current_ram_mb" ]]; then
      need_restart=true
      echo "Resource changes requested. VM will be restarted to apply changes..."
      echo ""
      
      # Gracefully shutdown the VM
      echo "Stopping VM..."
      virsh_cmd shutdown "$VM_NAME" 2>/dev/null || true
      for _ in {1..60}; do [[ "$(vm_state "$VM_NAME")" == "shut off" ]] && break; sleep 1; done
      
      if [[ "$(vm_state "$VM_NAME")" != "shut off" ]]; then
        echo "Graceful shutdown timed out, forcing stop..."
        virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
        sleep 2
      fi
      
      # Apply new resources
      echo "Updating VM resources: ${new_vcpus} vCPUs, ${new_ram_mb} MiB RAM..."
      local mem_kib=$((new_ram_mb * 1024))
      sudo virsh setmaxmem "$VM_NAME" "${mem_kib}" --config || die "Failed to set max memory"
      sudo virsh setmem "$VM_NAME" "${mem_kib}" --config || die "Failed to set memory"
      sudo virsh setvcpus "$VM_NAME" "$new_vcpus" --config --maximum || die "Failed to set max vcpus"
      sudo virsh setvcpus "$VM_NAME" "$new_vcpus" --config || die "Failed to set vcpus"
      echo "✅ VM resources updated."
      echo ""
    else
      echo "Using current VM resources: ${current_vcpus} vCPUs, ${current_ram_mb} MiB RAM"
      echo ""
    fi
    
    # Handle SSH key and VM start/connection
    if [[ "$need_restart" == "true" ]]; then
      # VM was stopped for resource changes, ensure SSH key and restart
      ensure_monitor_ssh
      
      echo "Starting VM..."
      sudo virsh start "$VM_NAME" >/dev/null || true
      
      # Wait for SSH
      echo "Waiting for network..."
      for _ in $(seq 1 $HOST_WAIT_SSH); do 
        ip="$(vm_ip)"
        [[ -n "$ip" ]] || { sleep 1; continue; }
        if gssh "$ip" "true" 2>/dev/null; then break; fi
        sleep 1
      done
      
      if [[ -z "$ip" ]] || ! gssh "$ip" "true" 2>/dev/null; then
        die "Could not establish SSH connection after restart."
      fi
      
      echo "✅ VM restarted at ${ip}"
      echo ""
    else
      # VM is still running, just get IP and verify SSH
      echo "Discovering VM IP address..."
      for _ in $(seq 1 30); do 
        ip="$(vm_ip)"
        [[ -n "$ip" ]] && break
        sleep 1
      done
      
      if [[ -z "$ip" ]]; then
        die "Could not discover VM IP address. VM may still be booting."
      fi
      
      echo "✅ Connected to VM at ${ip}"
      echo ""
      
      # Try SSH to ensure monitoring key works
      # Use a short timeout and suppress all output
      echo "Verifying SSH access..."
      if ! timeout 5 gssh "$ip" "true" >/dev/null 2>&1; then
        echo "⚠ SSH key not configured for monitoring. Setting up now..."
        echo "Note: This requires stopping the VM briefly."
        echo ""
        
        # Stop VM, inject key, restart
        echo "Stopping VM..."
        virsh_cmd shutdown "$VM_NAME" 2>/dev/null || true
        for _ in {1..60}; do [[ "$(vm_state "$VM_NAME")" == "shut off" ]] && break; sleep 1; done
        
        if [[ "$(vm_state "$VM_NAME")" != "shut off" ]]; then
          echo "Graceful shutdown failed, forcing stop..."
          virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
          sleep 2
        fi
        
        ensure_monitor_ssh
        
        echo "Restarting VM..."
        sudo virsh start "$VM_NAME" >/dev/null || true
        
        # Wait for SSH
        for _ in $(seq 1 $HOST_WAIT_SSH); do 
          ip="$(vm_ip)"
          [[ -n "$ip" ]] || { sleep 1; continue; }
          if gssh "$ip" "true" 2>/dev/null; then break; fi
          sleep 1
        done
        
        if [[ -z "$ip" ]] || ! gssh "$ip" "true" 2>/dev/null; then
          die "Could not establish SSH connection after restart."
        fi
        
        echo "✅ SSH configured and VM restarted at ${ip}"
        echo ""
      fi
    fi
  else
    # VM is stopped - do full setup
    if [[ "$vm_state_now" != "shut off" ]]; then
      die "VM is in state '${vm_state_now}'. Please wait for it to fully stop or use Quick Controls."
    fi

    # Get current VM resources from libvirt configuration
    local current_vcpus current_ram_mb
    current_vcpus=$(sudo virsh dominfo "$VM_NAME" | grep -i "CPU(s)" | awk '{print $2}')
    
    # Parse RAM - dominfo outputs in KiB, need to convert to MiB
    local ram_line
    ram_line=$(sudo virsh dominfo "$VM_NAME" | grep -i "Max memory")
    current_ram_mb=$(echo "$ram_line" | awk '{print $3}')
    
    # Check if output is in KiB and convert to MiB
    if echo "$ram_line" | grep -qi "KiB"; then
      current_ram_mb=$((current_ram_mb / 1024))
    fi

    detect_host_resources

    # Prompt user to confirm or change resources for this sync session
    # This allows adjusting resources between Action 1 (creation) and Action 2 (sync)
    local banner="Host: ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Reserve kept: ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB
Available for sync: ${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Current VM configuration: ${current_vcpus} vCPUs, ${current_ram_mb} MiB RAM"

  local new_vcpus new_ram_mb
  new_vcpus=$(whiptail --title "Sync vCPUs" --inputbox \
    "$banner\n\nEnter vCPUs for this sync session:" \
    18 78 "${current_vcpus}" 3>&1 1>&2 2>&3) || return 1
  [[ "$new_vcpus" =~ ^[0-9]+$ ]] || die "vCPUs must be a positive integer."
  [[ "$new_vcpus" -ge 1 ]] || die "vCPUs must be at least 1."
  (( new_vcpus <= AVAIL_CORES )) || die "Requested vCPUs ($new_vcpus) exceeds available after reserve (${AVAIL_CORES})."

  new_ram_mb=$(whiptail --title "Sync RAM (MiB)" --inputbox \
    "$banner\n\nEnter RAM (MiB) for this sync session:" \
    18 78 "${current_ram_mb}" 3>&1 1>&2 2>&3) || return 1
  [[ "$new_ram_mb" =~ ^[0-9]+$ ]] || die "RAM must be a positive integer."
  [[ "$new_ram_mb" -ge 2048 ]] || die "RAM should be at least 2048 MiB for IBD."
  (( new_ram_mb <= AVAIL_RAM_MB )) || die "Requested RAM ($new_ram_mb MiB) exceeds available after reserve (${AVAIL_RAM_MB} MiB)."

  # Apply new resources if changed
  if [[ "$new_vcpus" != "$current_vcpus" || "$new_ram_mb" != "$current_ram_mb" ]]; then
    echo "Updating VM resources: ${new_vcpus} vCPUs, ${new_ram_mb} MiB RAM..."
    local mem_kib=$((new_ram_mb * 1024))
    sudo virsh setmaxmem "$VM_NAME" "${mem_kib}" --config || die "Failed to set max memory"
    sudo virsh setmem "$VM_NAME" "${mem_kib}" --config || die "Failed to set memory"
    sudo virsh setvcpus "$VM_NAME" "$new_vcpus" --config --maximum || die "Failed to set max vcpus"
    sudo virsh setvcpus "$VM_NAME" "$new_vcpus" --config || die "Failed to set vcpus"
    echo "✅ VM resources updated."
  else
    echo "Using current VM resources: ${current_vcpus} vCPUs, ${current_ram_mb} MiB RAM"
  fi

  # Inject a temporary SSH key & ensure sshd starts
  ensure_monitor_ssh
  
  # Ensure libvirt default network is active (critical for VM networking)
  echo "Ensuring libvirt default network is active..."
  ensure_default_network || die "Failed to start libvirt default network. VM will not have network connectivity."
  
  echo "=========================================="
  echo "Starting VM and waiting for network..."
  echo "This may take a few minutes."
  echo "=========================================="
  echo ""
  sudo virsh start "$VM_NAME" >/dev/null || true

  # Wait for IP & SSH to come up
  local ip=""; for _ in $(seq 1 $HOST_WAIT_SSH); do ip="$(vm_ip)"; [[ -n "$ip" ]] || { sleep 1; continue; }
    if gssh "$ip" "true" 2>/dev/null; then break; fi; sleep 1;
  done
  if [[ -z "$ip" ]]; then
    echo "Could not discover VM IP or SSH. Dumping first-boot log for debugging:"
    dump_firstboot_log "/var/lib/libvirt/images/${VM_NAME}.qcow2"
    die "Could not discover VM IP or SSH. See first-boot log above."
  fi
  
  echo ""
  echo "✅ VM started successfully at ${ip}"
  echo ""
  fi  # End of else block (shut off VM path)

  # Use a simple watch-style display instead of whiptail for auto-refresh
  echo ""
  echo "=========================================="
  echo "Monitoring IBD Progress"
  echo "Press 'q' to exit (VM will keep running)"
  echo "=========================================="
  echo ""
  
  # Track if we've detected a stale tip and are waiting for catch-up
  local stale_tip_detected=false
  local stale_tip_wait_start=0
  local stale_tip_initial_blocks=0
  
  while true; do
    local info netinfo
    info="$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null' || true)"
    netinfo="$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null' || true)"
    
    # Check if bitcoind is actually responding (info will be empty if RPC not ready)
    if [[ -z "$info" || "$info" == "{}" ]]; then
      # Bitcoind not ready yet - check if it's actually running
      local bitcoind_status
      bitcoind_status="$(gssh "$ip" 'pgrep -f bitcoind >/dev/null && echo "running" || echo "not running"' 2>/dev/null || echo "unknown")"
      
      local tor_status
      tor_status="$(gssh "$ip" 'pgrep -f tor >/dev/null && echo "running" || echo "not running"' 2>/dev/null || echo "unknown")"
      
      # Show waiting message
      clear
      printf "╔════════════════════════════════════════════════════════════════════════════════╗\n"
      printf "║%-80s║\n" "                     Garbageman IBD Monitor - Starting"
      printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  VM Status:"
      printf "║%-80s║\n" "    Name: ${VM_NAME}"
      printf "║%-80s║\n" "    IP:   ${ip}"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Service Status:"
      printf "║%-80s║\n" "    Bitcoin: ${bitcoind_status}"
      printf "║%-80s║\n" "    Tor:     ${tor_status}"
      printf "║%-80s║\n" ""
      
      if [[ "$bitcoind_status" == "not running" ]]; then
        printf "║%-80s║\n" "  ⚠ Problem Detected:"
        printf "║%-80s║\n" "    Bitcoin daemon is not running!"
        printf "║%-80s║\n" ""
        printf "║%-80s║\n" "  This usually means there was a problem during import or startup."
        printf "║%-80s║\n" "  Try deleting and re-importing the VM."
      else
        printf "║%-80s║\n" "     Waiting for Bitcoin daemon to initialize..."
        printf "║%-80s║\n" "     (This can take 1-2 minutes on first boot)"
      fi
      
      printf "║%-80s║\n" ""
      printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
      printf "║%-80s║\n" "  Auto-refreshing every ${POLL_SECS} seconds... Press 'q' to exit"
      printf "╚════════════════════════════════════════════════════════════════════════════════╝\n"
      
      # Check for 'q' key press
      if read -t "$POLL_SECS" -n 1 key 2>/dev/null && [[ "$key" == "q" ]]; then
        echo ""
        echo "Exiting monitor. VM will continue running in background."
        return
      fi
      continue  # Skip the rest and retry
    fi
    
    local blocks headers vp ibd pct peers time_block
    blocks="$(jq -r '.blocks // 0' <<<"$info" 2>/dev/null || echo 0)"
    headers="$(jq -r '.headers // 0' <<<"$info" 2>/dev/null || echo 0)"
    vp="$(jq -r '.verificationprogress // 0' <<<"$info" 2>/dev/null || echo 0)"
    ibd="$(jq -r '.initialblockdownload // true' <<<"$info" 2>/dev/null || echo true)"
    peers="$(jq -r '.connections // 0' <<<"$netinfo" 2>/dev/null || echo 0)"
    time_block="$(jq -r '.time // 0' <<<"$info" 2>/dev/null || echo 0)"
    pct=$(awk -v p="$vp" 'BEGIN{if(p<0)p=0;if(p>1)p=1;printf "%d", int(p*100+0.5)}')
    
    # Get detailed peer breakdown
    local peer_breakdown=$(get_peer_breakdown "$ip")
    
    # Get node classification
    local node_classification=$(get_node_classification "$ip")

    # Check if the last block is stale (more than 2 hours old)
    local current_time=$(date +%s)
    local block_age_seconds=$((current_time - time_block))
    local block_age_hours=$((block_age_seconds / 3600))
    local is_stale=false
    
    # Consider tip stale if block is more than 2 hours old and we have blocks > 0
    if [[ "$blocks" -gt 0 && "$time_block" -gt 0 && "$block_age_seconds" -gt 7200 ]]; then
      is_stale=true
    fi
    
    # Handle stale tip detection and waiting logic
    local sync_status_msg=""
    if [[ "$is_stale" == "true" && "$stale_tip_detected" == "false" ]]; then
      # Just detected stale tip - start waiting period
      stale_tip_detected=true
      stale_tip_wait_start=$current_time
      stale_tip_initial_blocks=$blocks
      sync_status_msg="Stale tip detected (${block_age_hours}h old). Waiting for peers to sync..."
    elif [[ "$stale_tip_detected" == "true" ]]; then
      # We're in a waiting period for stale tip
      local wait_elapsed=$((current_time - stale_tip_wait_start))
      local wait_remaining=$((120 - wait_elapsed))
      
      # Check if blocks have increased (catching up)
      if [[ "$blocks" -gt "$stale_tip_initial_blocks" ]]; then
        # Blocks are advancing - check if we're caught up
        if [[ "$is_stale" == "false" ]]; then
          # Tip is no longer stale, we've caught up to recent blocks
          stale_tip_detected=false
          sync_status_msg="Caught up to current tip"
        else
          # Still catching up to current (tip still >2h old means more blocks to sync)
          sync_status_msg="Syncing new blocks (was ${block_age_hours}h behind)..."
        fi
      elif [[ "$wait_elapsed" -lt 120 ]]; then
        # Still waiting for peers and updates (up to 2 minutes)
        sync_status_msg="Waiting for sync (${wait_remaining}s left, ${peers} peers connected)..."
      else
        # Waited 2 minutes and no progress
        # Check if tip is still stale - if not, we can clear the flag
        if [[ "$is_stale" == "false" ]]; then
          # Tip is no longer stale (somehow caught up), clear flag
          stale_tip_detected=false
          sync_status_msg="Synced to current tip"
        else
          # Still stale, keep waiting indefinitely (don't mark as complete until truly synced)
          sync_status_msg="Stale tip (${block_age_hours}h old), waiting for peers (${peers} connected)..."
        fi
      fi
    fi

    detect_host_resources
    
    # Clear screen and show status
    clear
    printf "╔════════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║%-80s║\n" "                     Garbageman IBD Monitor - ${pct}% Complete"
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Host Resources:"
    printf "║%-80s║\n" "    Cores: ${HOST_CORES} total | ${RESERVE_CORES} reserved | ${AVAIL_CORES} available"
    printf "║%-80s║\n" "    RAM:   ${HOST_RAM_MB} MiB total | ${RESERVE_RAM_MB} MiB reserved | ${AVAIL_RAM_MB} MiB available"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  VM Status:"
    printf "║%-80s║\n" "    Name: ${VM_NAME}"
    printf "║%-80s║\n" "    IP:   ${ip}"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Bitcoin Sync Status:"
    if [[ -n "$node_classification" ]]; then
      printf "║%-80s║\n" "    Node Type:  $node_classification"
    else
      printf "║%-80s║\n" "    Node Type:  Starting..."
    fi
    printf "║%-80s║\n" "    Blocks:     ${blocks} / ${headers}"
    printf "║%-80s║\n" "    Progress:   ${pct}% (${vp})"
    printf "║%-80s║\n" "    IBD:        ${ibd}"
    printf "║%-80s║\n" "    Peers:      ${peer_breakdown}"
    if [[ -n "$sync_status_msg" ]]; then
      printf "║%-80s║\n" "    Status:     ${sync_status_msg}"
    fi
    printf "║%-80s║\n" ""
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" "  Auto-refreshing every ${POLL_SECS} seconds... Press 'q' to exit"
    printf "╚════════════════════════════════════════════════════════════════════════════════╝\n"
    
    # Check if IBD is complete - multiple conditions to catch completion
    # BUT: Don't complete if we detected a stale tip and are still waiting for catch-up
    # 1. IBD flag is false (bitcoind says it's done)
    # 2. Blocks caught up to headers
    # 3. Progress is at or near 100%
    # 4. NOT currently waiting for stale tip to catch up
    local should_complete=false
    if [[ "$ibd" == "false" ]] || [[ "$blocks" -ge "$headers" && "$headers" -gt 0 && "$pct" -ge 99 ]]; then
      # Basic completion conditions met, but check stale tip status
      if [[ "$stale_tip_detected" == "false" ]]; then
        # No stale tip detected or we've finished waiting - OK to complete
        should_complete=true
      elif [[ "$blocks" -ge "$headers" && "$pct" -ge 99 && "$blocks" -gt "$stale_tip_initial_blocks" ]]; then
        # Stale tip was detected AND blocks have advanced past initial AND caught up to headers - complete
        should_complete=true
      elif [[ "$blocks" -gt "$stale_tip_initial_blocks" ]]; then
        # Stale tip was detected and blocks are still advancing - keep waiting
        should_complete=false
      else
        # Stale tip detected, no progress yet - keep waiting (no timeout)
        should_complete=false
      fi
    fi
    
    if [[ "$should_complete" == "true" ]]; then
      # Clear screen before showing completion message
      clear
      echo ""
      echo "╔════════════════════════════════════════════════════════════════════════════════╗"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "                    INITIAL BLOCK DOWNLOAD COMPLETE!"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Your base VM (gm-base) is now fully synced with the Bitcoin network."
      printf "║%-80s║\n" ""
      echo "╚════════════════════════════════════════════════════════════════════════════════╝"
      echo ""
      
      # Check if VM is already shut down
      if [[ "$(vm_state "$VM_NAME")" == "shut off" ]]; then
        echo "VM is already shut down, proceeding to resize..."
      else
        echo "Stopping VM to resize to runtime defaults..."
        echo ""
        
        # Rediscover IP in case it changed
        local current_ip
        current_ip="$(vm_ip)"
        if [[ -z "$current_ip" ]]; then
          echo "⚠ Could not discover VM IP, will use virsh shutdown"
          virsh_cmd shutdown "$VM_NAME" 2>/dev/null || true
        else
          # Attempt graceful shutdown via SSH
          if gssh "$current_ip" 'sync; systemctl poweroff' 2>/dev/null; then
            echo "✓ Shutdown command sent"
          else
            echo "⚠ SSH shutdown failed, trying virsh shutdown"
            virsh_cmd shutdown "$VM_NAME" 2>/dev/null || true
          fi
        fi
      fi
      
      # Wait up to 3 minutes for graceful shutdown (bitcoind can take time to flush)
      echo "Waiting for VM to shut down (this may take up to 3 minutes)..."
      local shutdown_wait=0
      while [[ $shutdown_wait -lt 180 ]]; do
        if [[ "$(vm_state "$VM_NAME")" == "shut off" ]]; then
          echo "✓ VM shut down gracefully"
          break
        fi
        sleep 5
        shutdown_wait=$((shutdown_wait + 5))
        if [[ $((shutdown_wait % 30)) -eq 0 ]]; then
          echo "  Still waiting... (${shutdown_wait}s elapsed)"
        fi
      done
      
      # Force shutdown if still running
      if [[ "$(vm_state "$VM_NAME")" != "shut off" ]]; then
        echo ""
        echo "⚠ Graceful shutdown timed out after 3 minutes"
        echo "Force stopping VM..."
        virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
        sleep 2
        if [[ "$(vm_state "$VM_NAME")" == "shut off" ]]; then
          echo "✓ VM force stopped"
        else
          echo "✗ Failed to stop VM. Please check with 'virsh list --all'"
          read -p "Press Enter to return to main menu..."
          return
        fi
      fi
      
      # Resize to runtime defaults
      echo ""
      echo "Resizing VM to runtime defaults (${VM_VCPUS} vCPUs, ${VM_RAM_MB} MiB RAM)..."
      local mem_kib=$(( VM_RAM_MB * 1024 ))
      sudo virsh setmaxmem "$VM_NAME" "${mem_kib}" --config
      sudo virsh setmem    "$VM_NAME" "${mem_kib}" --config
      sudo virsh setvcpus "$VM_NAME" "$VM_VCPUS" --config --maximum
      sudo virsh setvcpus "$VM_NAME" "$VM_VCPUS" --config
      echo "✓ VM resized successfully"
      
      # Clear screen and show final message
      clear
      echo ""
      echo "╔════════════════════════════════════════════════════════════════════════════════╗"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "                    VM READY FOR CLONING!"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  The base VM has been shut down and resized to runtime defaults."
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Next steps:"
      printf "║%-80s║\n" "    - Choose 'Clone VM(s) from Base' from the main menu"
      printf "║%-80s║\n" "    - Each clone will have the full blockchain and unique .onion address"
      printf "║%-80s║\n" "    - Clones are Tor-only for maximum privacy"
      printf "║%-80s║\n" ""
      echo "╚════════════════════════════════════════════════════════════════════════════════╝"
      echo ""
      read -p "Press Enter to return to main menu..."
      clear
      return
    fi
    
    # Use read with timeout - check if user pressed 'q' to exit early
    read -t "$POLL_SECS" -n 1 key 2>/dev/null || true
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
      clear
      echo ""
      echo "Monitor stopped. VM is still running."
      sleep 1
      return
    fi
  done
  
  return
}

################################################################################
# Export Base VM (Action 3 - Manage Base VM submenu)
################################################################################

# export_base_vm: Create a modular export of the base VM (NEW MODULAR FORMAT)
# Purpose: Package the base VM as TWO separate components for efficient distribution
# Export Components:
#   1. VM Image (WITHOUT blockchain) - ~1GB compressed
#      - Alpine Linux + compiled Garbageman
#      - Configuration files and services
#      - Sanitized (no sensitive data)
#   2. Blockchain Data (separate) - ~20GB compressed, split into 1.9GB parts
#      - Complete blockchain (pruned to 750MB)
#      - Can be reused across multiple VM/container exports
#      - GitHub-compatible (parts < 2GB)
# Security: Removes all sensitive/identifying information:
#   FROM VM IMAGE:
#     - Blockchain data (exported separately)
#     - Tor hidden service keys (forces fresh .onion address)
#     - SSH authorized keys (host-specific monitoring key)
#     - Tor control cookie and state data
#     - Machine identifiers (machine-id, SSH host keys)
#     - System logs
#     - Resets bitcoin.conf to generic Tor-only configuration
#   FROM BLOCKCHAIN DATA:
#     - Bitcoin peer databases (peers.dat, anchors.dat, banlist.dat)
#     - Bitcoin debug logs (may contain peer IPs)
#     - Tor hidden service keys
#     - Wallet files (none should exist but removed as precaution)
#     - Mempool and fee estimate data
#     - Lock files and PIDs
# Flow:
#   1. Extract blockchain from VM disk using virt-tar-out
#   2. Sanitize blockchain data (remove sensitive files)
#   3. Compress sanitized blockchain
#   4. Split blockchain into 1.9GB parts for GitHub
#   5. Generate blockchain checksums and manifest
#   6. Shut down base VM (graceful shutdown if running)
#   7. Create temporary clone for sanitization (preserves original)
#   8. Remove blockchain from clone and sanitize using virt-sysprep
#   9. Export VM definition and compress disk image
#   10. Create VM image archive with README
#   11. Clean up temporary clone
# Output: Creates unified export folder in ~/Downloads:
#   gm-export-YYYYMMDD-HHMMSS/
#     - blockchain.tar.gz.part01, part02, etc. (sanitized)
#     - vm-image-YYYYMMDD-HHMMSS.tar.gz (sanitized)
#     - SHA256SUMS
#     - MANIFEST.txt
# Benefits:
#   - Much smaller VM image downloads (1GB vs 22GB)
#   - Blockchain can be shared between VM and container exports
#   - Can update VM image without re-downloading blockchain
#   - GitHub-compatible split files (all parts < 2GB)
# SAFE FOR PUBLIC DISTRIBUTION - All identifying information removed from both components
export_base_vm(){
  ensure_tools
  
  # Check if base VM exists
  sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "Base VM '$VM_NAME' not found. Nothing to export."
  
  # Check if VM is synced (optional warning, not blocking)
  echo "Checking sync status..."
  local current_state
  current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
  
  local sync_warning=""
  local blocks=""
  local headers=""
  local blockchain_height="unknown"
  local node_type=""
  local was_running=true
  
  if [[ "$current_state" == "running" ]]; then
    # VM already running, query directly
    local ip
    ip=$(vm_ip "$VM_NAME" 2>/dev/null || echo "")
    
    if [[ -n "$ip" ]]; then
      local info
      info=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null' 2>/dev/null || echo "")
      blocks=$(jq -r '.blocks // ""' <<<"$info" 2>/dev/null || echo "")
      headers=$(jq -r '.headers // ""' <<<"$info" 2>/dev/null || echo "")
      
      if [[ -n "$blocks" ]]; then
        blockchain_height="$blocks"
        # Also get node type while we're at it
        node_type=$(get_node_classification "$ip")
      fi
      
      if [[ -n "$blocks" && -n "$headers" && "$blocks" != "$headers" ]]; then
        sync_warning="\n⚠️  WARNING: Blockchain may not be fully synced (blocks: $blocks / $headers)"
      fi
    fi
  else
    # VM not running, start it temporarily to get blockchain height
    echo "VM is stopped, starting temporarily to query blockchain..."
    was_running=false
    
    if virsh_cmd start "$VM_NAME" >/dev/null 2>&1; then
      # Wait for VM to get IP address
      local wait_count=0
      local max_wait=24  # 24 * 5 = 120 seconds (2 minutes)
      local ip=""
      
      echo "Waiting for VM to be ready..."
      while [[ $wait_count -lt $max_wait ]]; do
        ip=$(vm_ip "$VM_NAME" 2>/dev/null || echo "")
        if [[ -n "$ip" ]]; then
          break
        fi
        wait_count=$((wait_count + 1))
        sleep 5
      done
      
      if [[ -n "$ip" ]]; then
        # Wait for bitcoind to be ready
        wait_count=0
        max_wait=12  # 12 * 5 = 60 seconds
        echo "Waiting for bitcoind to be ready..."
        
        while [[ $wait_count -lt $max_wait ]]; do
          local info
          info=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null' 2>/dev/null || echo "")
          blocks=$(jq -r '.blocks // ""' <<<"$info" 2>/dev/null || echo "")
          
      if [[ -n "$blocks" ]]; then
        blockchain_height="$blocks"
        # Also get node type while we're at it
        node_type=$(get_node_classification "$ip")
        headers=$(jq -r '.headers // ""' <<<"$info" 2>/dev/null || echo "")
        if [[ -n "$headers" && "$blocks" != "$headers" ]]; then
          sync_warning="\n⚠️  WARNING: Blockchain may not be fully synced (blocks: $blocks / $headers)"
        fi
        # Only break if we got a valid node type (not empty)
        if [[ -n "$node_type" ]]; then
          break
        fi
      fi
      wait_count=$((wait_count + 1))
      sleep 5
    done
    
    if [[ -z "$blocks" ]]; then
      echo "⚠️  bitcoind did not respond in time, block height will be 'unknown'"
    fi
      else
        echo "⚠️  Failed to get VM IP address, block height will be 'unknown'"
      fi
    else
      echo "⚠️  Failed to start VM, block height will be 'unknown'"
    fi
  fi
  
  # Confirm export with user
  if ! whiptail --title "Export Base VM" --yesno \
    "This will create a MODULAR export of '$VM_NAME':\n\n\
Export Components:\n\
• VM Image (WITHOUT blockchain) - ~1 GB compressed\n\
• Blockchain Data (separate file) - ~20 GB compressed\n\n\
Security measures:\n\
• Removes Tor keys (forces fresh .onion on import)\n\
• Removes SSH keys and machine identifiers\n\
• Clears peer databases and logs\n\
• Resets to generic Tor-only configuration\n\n\
Export will be saved to: ~/Downloads/\n\
Total time: 10-30 minutes\n\n\
The base VM will be shut down during export (if running).\n\
Original VM will remain intact.${sync_warning}\n\n\
Proceed with export?" 26 78; then
    return
  fi
  
  # Generate export name with timestamp
  local export_timestamp
  export_timestamp=$(date +%Y%m%d-%H%M%S)
  local export_name="gm-export-${export_timestamp}"
  local export_dir="$HOME/Downloads/${export_name}"
  local temp_clone="${VM_NAME}-export-temp"
  
  # Create export directory (flat structure, no subdirectories)
  mkdir -p "$export_dir" || die "Failed to create export directory: $export_dir"
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    Exporting Base VM (Modular Export)                          ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "This will create a unified export folder containing:"
  echo "  1. VM image (WITHOUT blockchain) - for fast updates"
  echo "  2. Blockchain data (split into parts) - can be reused across exports"
  echo ""
  
  # Step 1: Export blockchain data FIRST (while VM might still be running)
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 1: Export Blockchain Data (Sanitized)"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Export directly to main folder (flat structure)
  local blockchain_export_dir="$export_dir"
  
  echo "[1/7] Extracting blockchain from VM disk..."
  local vm_disk="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  local temp_blockchain="$blockchain_export_dir/.tmp-blockchain"
  mkdir -p "$temp_blockchain" || die "Failed to create temporary blockchain directory"
  
  # Use virt-tar-out to extract blockchain to temporary location for sanitization
  sudo virt-tar-out -a "$vm_disk" /var/lib/bitcoin - | tar x -C "$temp_blockchain" || {
    rm -rf "$export_dir"
    die "Failed to extract blockchain data from VM disk"
  }
  
  echo "    ✓ Blockchain extracted"
  
  echo ""
  echo "[2/7] Sanitizing sensitive data..."
  # Remove sensitive files that shouldn't be in public exports
  rm -f "$temp_blockchain/peers.dat" 2>/dev/null || true
  rm -f "$temp_blockchain/anchors.dat" 2>/dev/null || true
  rm -f "$temp_blockchain/banlist.dat" 2>/dev/null || true
  rm -f "$temp_blockchain/debug.log" 2>/dev/null || true
  rm -f "$temp_blockchain/.lock" 2>/dev/null || true
  rm -f "$temp_blockchain/onion_private_key" 2>/dev/null || true
  rm -f "$temp_blockchain/onion_v3_private_key" 2>/dev/null || true
  rm -rf "$temp_blockchain/.cookie" 2>/dev/null || true
  rm -f "$temp_blockchain/bitcoind.pid" 2>/dev/null || true
  
  # Remove any wallet files (shouldn't exist in pruned node, but be safe)
  rm -f "$temp_blockchain/wallet.dat" 2>/dev/null || true
  rm -rf "$temp_blockchain/wallets" 2>/dev/null || true
  
  # Remove mempool - not needed and may contain transaction info
  rm -f "$temp_blockchain/mempool.dat" 2>/dev/null || true
  
  # Remove fee estimates (not sensitive but not needed)
  rm -f "$temp_blockchain/fee_estimates.dat" 2>/dev/null || true
  
  echo "    ✓ Sensitive data removed:"
  echo "      - Peer databases (peers.dat, anchors.dat, banlist.dat)"
  echo "      - Tor hidden service keys"
  echo "      - Debug logs and lock files"
  echo "      - Wallet files (if any)"
  echo "      - Mempool and fee estimate data"
  
  echo ""
  echo "[3/7] Compressing sanitized blockchain..."
  tar czf "$blockchain_export_dir/blockchain-data.tar.gz" -C "$temp_blockchain" . || {
    rm -rf "$export_dir"
    die "Failed to compress blockchain data"
  }
  
  # Clean up temporary extraction
  rm -rf "$temp_blockchain"
  
  local blockchain_size
  blockchain_size=$(du -h "$blockchain_export_dir/blockchain-data.tar.gz" | cut -f1)
  echo "    ✓ Blockchain compressed ($blockchain_size)"
  
  echo ""
  echo "[4/7] Splitting blockchain for GitHub (1.9GB parts)..."
  cd "$blockchain_export_dir"
  split -b 1900M -d -a 2 "blockchain-data.tar.gz" "blockchain.tar.gz.part"
  
  # Renumber parts to start from 01 instead of 00
  local part_count=0
  for part in blockchain.tar.gz.part*; do
    if [[ -f "$part" ]]; then
      part_count=$((part_count + 1))
    fi
  done
  
  if [[ $part_count -gt 0 ]]; then
    for ((i=part_count-1; i>=0; i--)); do
      local old_num=$(printf "%02d" $i)
      local new_num=$(printf "%02d" $((i+1)))
      mv "blockchain.tar.gz.part${old_num}" "blockchain.tar.gz.part${new_num}"
    done
  fi
  
  rm -f "blockchain-data.tar.gz"  # Remove unsplit version
  
  echo "    ✓ Split into $part_count parts"
  
  echo ""
  echo "[5/7] Creating manifest..."
  
  # Create manifest
  cat > MANIFEST.txt << EOF
Blockchain Data Export (SANITIZED)
===================================

Export Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Export Timestamp: $export_timestamp
Source: $VM_NAME (VM)
Block Height: $blockchain_height

Security:
=========

✓ Peer databases removed (peers.dat, anchors.dat, banlist.dat)
✓ Tor hidden service keys removed
✓ Debug logs removed
✓ Wallet files removed (if any existed)
✓ Mempool and fee estimate data removed
✓ Lock files and PIDs removed

This blockchain data is SAFE for public distribution.
Sensitive/identifying information has been stripped.

Split Information:
==================

This blockchain data has been split into $part_count parts for GitHub compatibility.
Each part is approximately 1.9GB (under GitHub's 2GB limit).

To Reassemble:
==============

cat blockchain.tar.gz.part* > blockchain.tar.gz

Or let garbageman-nm.sh handle it automatically via "Import from file"

Files in this export:
=====================

$(ls -1h blockchain.tar.gz.part* | while read f; do
    size=$(du -h "$f" | cut -f1)
    echo "  $f ($size)"
done)

Total Size: $(du -ch blockchain.tar.gz.part* | tail -n1 | cut -f1)
EOF
  
  echo "    ✓ Blockchain export complete (sanitized)"
  
  # Step 1.5: Export binaries if node type is Garbageman or Knots
  # Note: node_type was already detected earlier when we queried blockchain height
  echo ""
  echo "[6/7] Checking if blockchain export includes binary-compatible data..."
  echo "    ✓ Blockchain data export complete"
  
  echo ""
  echo "[7/7] Exporting binaries (if applicable)..."
  echo "    Node type: ${node_type:-Unknown}"
  
  # Export binaries if node type is Garbageman or Knots
  if [[ "$node_type" == "Libre Relay/Garbageman" ]] || [[ "$node_type" == "Bitcoin Knots" ]]; then
    echo "    Extracting binaries from VM disk..."
    
    # Determine binary suffix based on node type
    local binary_suffix=""
    if [[ "$node_type" == "Libre Relay/Garbageman" ]]; then
      binary_suffix="-gm"
    elif [[ "$node_type" == "Bitcoin Knots" ]]; then
      binary_suffix="-knots"
    fi
    
    # Extract bitcoind and bitcoin-cli from VM disk
    local temp_binaries="$export_dir/.tmp-binaries"
    mkdir -p "$temp_binaries" || die "Failed to create temporary binaries directory"
    
    # Use virt-copy-out to extract binaries
    if sudo virt-copy-out -a "$vm_disk" /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli "$temp_binaries/" 2>/dev/null; then
      # Rename and move to export directory
      mv "$temp_binaries/bitcoind" "$export_dir/bitcoind${binary_suffix}" 2>/dev/null || true
      mv "$temp_binaries/bitcoin-cli" "$export_dir/bitcoin-cli${binary_suffix}" 2>/dev/null || true
      
      # Fix ownership (virt-copy-out runs as root)
      sudo chown "$USER:$USER" "$export_dir/bitcoind${binary_suffix}" 2>/dev/null || true
      sudo chown "$USER:$USER" "$export_dir/bitcoin-cli${binary_suffix}" 2>/dev/null || true
      
      # Clean up temp directory
      rm -rf "$temp_binaries"
      
      # Generate checksums for binaries
      if [[ -f "$export_dir/bitcoind${binary_suffix}" ]] && [[ -f "$export_dir/bitcoin-cli${binary_suffix}" ]]; then
        (cd "$export_dir" && sha256sum "bitcoind${binary_suffix}" "bitcoin-cli${binary_suffix}" >> SHA256SUMS.binaries)
        echo "    ✓ Binaries exported as: bitcoind${binary_suffix}, bitcoin-cli${binary_suffix}"
        echo "    ✓ Binary checksums saved to SHA256SUMS.binaries"
      else
        echo "    ⚠️  Warning: Failed to rename binaries"
      fi
    else
      echo "    ⚠️  Warning: Failed to extract binaries from VM disk"
      rm -rf "$temp_binaries"
    fi
  else
    echo "    Node type is not Garbageman or Knots - skipping binary export"
  fi
  
  # Step 2: Shut down base VM if we started it or if it was already running
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 2: Prepare VM for Image Export"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "[1/1] Ensuring base VM is shut down..."
  current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
  
  if [[ "$current_state" == "running" ]]; then
    if [[ "$was_running" == "false" ]]; then
      echo "      VM was started temporarily for blockchain query. Shutting down..."
    else
      echo "      Base VM is running. Shutting down gracefully..."
    fi
    echo "      This may take up to 3 minutes for bitcoind to close cleanly."
    
    sudo virsh shutdown "$VM_NAME" >/dev/null 2>&1 || true
    
    local timeout=180
    local elapsed=0
    local check_interval=5
    
    while [[ $elapsed -lt $timeout ]]; do
      current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
      if [[ "$current_state" != "running" ]]; then
        echo "      ✓ Base VM shut down successfully after ${elapsed} seconds."
        break
      fi
      
      if [[ $((elapsed % 15)) -eq 0 && $elapsed -gt 0 ]]; then
        echo "      Still waiting... (${elapsed}s elapsed)"
      fi
      
      sleep "$check_interval"
      elapsed=$((elapsed + check_interval))
    done
    
    current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
    if [[ "$current_state" == "running" ]]; then
      echo "      Graceful shutdown timed out. Forcing shutdown..."
      sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
      sleep 2
      echo "      ✓ Base VM forcefully stopped."
    fi
  else
    echo "      ✓ Base VM already shut down."
  fi
  
  # Step 2: Create temporary clone for sanitization
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 3: Create and Sanitize VM Image"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "[1/7] Creating temporary clone..."
  local temp_disk="/var/lib/libvirt/images/${temp_clone}.qcow2"
  
  # Clean up any previous failed export attempt
  if sudo virsh dominfo "$temp_clone" >/dev/null 2>&1; then
    echo "      Cleaning up previous temporary clone..."
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
  fi
  
  sudo virt-clone --original "$VM_NAME" --name "$temp_clone" --file "$temp_disk" --auto-clone || {
    echo "      ✗ Failed to create temporary clone"
    rm -rf "$export_dir"
    die "Export failed during cloning"
  }
  echo "      ✓ Temporary clone created: $temp_clone"
  
  # Step 3: Sanitize using virt-sysprep (removes SSH keys, machine-id, logs, etc.)
  echo ""
  echo "[2/7] Sanitizing VM (removing sensitive data)..."
  echo "      This may take a few minutes..."
  
  # virt-sysprep removes: SSH keys, machine-id, logs, random-seed, etc.
  # Use --operations to be explicit about what we're cleaning
  sudo virt-sysprep -d "$temp_clone" \
    --operations defaults,-lvm-uuids \
    2>&1 | grep -v "random seed" || {
    echo "      ✗ virt-sysprep failed"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir"
    die "Export failed during sanitization"
  }
  echo "      ✓ Basic sanitization complete (SSH keys, logs, machine-id removed)"
  
  # Step 4: Additional cleanup specific to Bitcoin/Tor (INCLUDING removing blockchain)
  echo ""
  echo "[3/7] Removing blockchain data and Bitcoin/Tor sensitive data..."
  
  # Remove blockchain data first
  sudo virt-customize -d "$temp_clone" --no-selinux-relabel \
    --run-command "rm -rf /var/lib/bitcoin/* || true" \
    2>&1 | grep -v "random seed" >&2 || {
    echo "      ✗ Failed to remove blockchain data"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir" "$blockchain_export_dir"
    die "Export failed during blockchain removal"
  }
  
  # Remove Tor hidden service keys and state
  sudo virt-customize -d "$temp_clone" --no-selinux-relabel \
    --run-command "rm -rf /var/lib/tor/bitcoin-service || true" \
    --run-command "rm -rf /var/lib/tor/* || true" \
    --run-command "rm -f ${BITCOIN_DATADIR}/onion_private_key || true" \
    2>&1 | grep -v "random seed" >&2 || {
    echo "      ✗ Failed to remove Tor keys"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir" "$blockchain_export_dir"
    die "Export failed during Tor cleanup"
  }
  
  # Remove Bitcoin peer databases and debug logs
  sudo virt-customize -d "$temp_clone" --no-selinux-relabel \
    --run-command "rm -f ${BITCOIN_DATADIR}/peers.dat || true" \
    --run-command "rm -f ${BITCOIN_DATADIR}/anchors.dat || true" \
    --run-command "rm -f ${BITCOIN_DATADIR}/banlist.dat || true" \
    --run-command "rm -f ${BITCOIN_DATADIR}/debug.log || true" \
    --run-command "rm -f ${BITCOIN_DATADIR}/.lock || true" \
    2>&1 | grep -v "random seed" >&2 || {
    echo "      ✗ Failed to remove Bitcoin peer data"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir" "$blockchain_export_dir"
    die "Export failed during Bitcoin cleanup"
  }
  
  # Reset bitcoin.conf to generic Tor-only configuration
  sudo virt-customize -d "$temp_clone" --no-selinux-relabel \
    --run-command "cat > /etc/bitcoin/bitcoin.conf <<'BTCCONF'
server=1
daemon=1
prune=750
dbcache=450
maxconnections=25

# Tor-only configuration
proxy=127.0.0.1:9050
listen=1
bind=127.0.0.1
onlynet=onion

[main]
BTCCONF" \
    --run-command "chown bitcoin:bitcoin /etc/bitcoin/bitcoin.conf" \
    --run-command "chmod 640 /etc/bitcoin/bitcoin.conf" \
    2>&1 | grep -v "random seed" >&2 || {
    echo "      ✗ Failed to reset bitcoin.conf"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir" "$blockchain_export_dir"
    die "Export failed during bitcoin.conf reset"
  }
  
  # Reset hostname to generic gm-base
  sudo virt-customize -d "$temp_clone" --no-selinux-relabel \
    --hostname "gm-base" \
    2>&1 | grep -v "random seed" >&2 || true
  
  echo "      ✓ VM image sanitized (blockchain removed, sensitive data cleared)"
  
  # Step 5: Export VM definition and disk
  echo ""
  echo "[4/7] Exporting VM definition and compressing disk..."
  
  # Export XML definition
  sudo virsh dumpxml "$temp_clone" > "$export_dir/vm-definition.xml" || {
    echo "      ✗ Failed to export VM definition"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir" "$blockchain_export_dir"
    die "Export failed during VM definition export"
  }
  
  # Convert disk to compressed qcow2
  echo "      Compressing disk image (this may take several minutes)..."
  sudo qemu-img convert -c -O qcow2 "$temp_disk" "$export_dir/vm-disk.qcow2" || {
    echo "      ✗ Failed to compress disk"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir" "$blockchain_export_dir"
    die "Export failed during disk compression"
  }
  
  local vm_disk_size
  vm_disk_size=$(du -h "$export_dir/vm-disk.qcow2" | cut -f1)
  echo "      ✓ VM disk exported and compressed ($vm_disk_size)"
  
  # Step 6: Create README and metadata
  echo ""
  echo "[5/7] Creating README and metadata..."
  
  # Get VM specs
  local vm_ram vm_vcpus
  vm_ram=$(sudo virsh dominfo "$temp_clone" | grep "Max memory:" | awk '{print $3}')
  vm_vcpus=$(sudo virsh dominfo "$temp_clone" | grep "CPU(s):" | awk '{print $2}')
  
  cat > "$export_dir/README.txt" << 'EOF'
Garbageman VM Image Export (NEW MODULAR FORMAT)
================================================

This archive contains a VM image WITHOUT blockchain data.
The blockchain must be downloaded separately for a complete import.

Contents:
---------
- vm-disk.qcow2: Compressed VM disk image (Alpine Linux + Garbageman)
- vm-definition.xml: VM definition for libvirt
- README.txt: This file

What's Included:
----------------
- Alpine Linux base system
- Bitcoin Garbageman (compiled)
- Tor for hidden service
- Configured bitcoind service

What's NOT Included:
--------------------
- Blockchain data (download separately: blockchain.tar.gz.part*)
- Tor keys (regenerated on first boot)
- SSH keys (regenerated on first boot)
- Logs and temporary files

Blockchain Data:
----------------
Download matching blockchain export with same timestamp:
  gm-blockchain-YYYYMMDD-HHMMSS/

Import Instructions:
====================

Method 1 (Recommended): Use garbageman-nm.sh
  ./garbageman-nm.sh → Create Base VM → Import from file
  
  The script will automatically:
  1. Import the VM image
  2. Look for matching blockchain data
  3. Combine them into a complete working VM

Method 2 (Manual):
  1. Extract this archive
  2. Download and reassemble blockchain:
     cd /path/to/blockchain/export
     cat blockchain.tar.gz.part* > blockchain.tar.gz
     tar xzf blockchain.tar.gz
  3. Inject blockchain into VM disk:
     sudo virt-tar-in -a vm-disk.qcow2 /path/to/blockchain/data /var/lib/bitcoin
  4. Copy disk to /var/lib/libvirt/images/gm-base.qcow2
  5. Import VM:
     sudo virsh define vm-definition.xml

Notes:
------
- VM image size: ~500MB-1GB (much smaller than old monolithic format)
- Blockchain size: ~20GB compressed
- Total combined: ~21GB (same as before, but now modular)
- Can update VM image without re-downloading blockchain
- Can share blockchain between VM and container deployments
EOF

  # Create metadata
  cat > "$export_dir/METADATA.txt" <<METADATA
Export Information
==================

Export Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Export Timestamp: $export_timestamp
Format: Modular (VM image + blockchain parts)

VM Specifications:
------------------
Name: $VM_NAME
RAM: ${vm_ram} KiB
vCPUs: $vm_vcpus
Disk Format: qcow2 (compressed)

Blockchain Information:
-----------------------
Height at Export: $blockchain_height
Format: Split into parts (blockchain.tar.gz.part*)

Security & Privacy:
-------------------
VM Image Security:
✓ Blockchain removed from VM image
✓ Tor keys removed (regenerated on import)
✓ SSH keys removed (regenerated on import)
✓ System logs cleared
✓ Machine-id reset
✓ Generic Tor-only bitcoin.conf

Blockchain Data Security:
✓ Blockchain sanitized before export
✓ Peer databases removed (peers.dat, anchors.dat, banlist.dat)
✓ Tor hidden service keys removed
✓ Debug logs removed (may contain IP addresses)
✓ Wallet files removed (none should exist on pruned node)
✓ Mempool and fee estimate data removed
✓ Lock files and PIDs removed

SAFE FOR PUBLIC DISTRIBUTION - No identifying information included.

Companion Files:
----------------
This VM image pairs with blockchain data:
  blockchain.tar.gz.part01, part02, etc.

All files are included in this unified export folder.
METADATA
  
  echo "      ✓ README and metadata created"
  
  # Step 7: Create VM image archive within export folder
  echo ""
  echo "[6/7] Creating VM image archive..."
  local vm_archive_name="vm-image.tar.gz"
  local vm_archive_path="$export_dir/${vm_archive_name}"
  
  # Archive the VM files (excluding blockchain parts and manifest)
  local temp_vm_dir="$export_dir/.tmp-vm"
  mkdir -p "$temp_vm_dir"
  mv "$export_dir"/*.qcow2 "$export_dir"/*.xml "$export_dir"/*METADATA.txt "$export_dir"/README.txt "$temp_vm_dir/" 2>/dev/null || true
  
  tar -czf "$vm_archive_path" -C "$temp_vm_dir" . || {
    echo "      ✗ Failed to create archive"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir"
    die "Export failed during archive creation"
  }
  
  # Remove temporary directory
  rm -rf "$temp_vm_dir"
  
  local vm_archive_size
  vm_archive_size=$(du -h "$vm_archive_path" | cut -f1)
  echo "      ✓ VM image archived ($vm_archive_size)"
  
  # Generate combined checksums for all files
  echo "      Generating checksums..."
  
  # Start with blockchain parts and VM archive
  (cd "$export_dir" && sha256sum blockchain.tar.gz.part* "${vm_archive_name}" > SHA256SUMS)
  
  # Add binaries if they exist
  if [[ -f "$export_dir/SHA256SUMS.binaries" ]]; then
    echo "" >> "$export_dir/SHA256SUMS"
    echo "# Bitcoin binaries:" >> "$export_dir/SHA256SUMS"
    cat "$export_dir/SHA256SUMS.binaries" >> "$export_dir/SHA256SUMS"
    rm -f "$export_dir/SHA256SUMS.binaries"  # Clean up temporary file
  fi
  
  # Add reassembled blockchain checksum
  echo "" >> "$export_dir/SHA256SUMS"
  echo "# Reassembled blockchain checksum:" >> "$export_dir/SHA256SUMS"
  (cd "$export_dir" && cat blockchain.tar.gz.part* | sha256sum | sed 's/-/blockchain.tar.gz/' >> SHA256SUMS)
  
  echo "      ✓ Checksums created"
  
  # Step 8: Cleanup temporary VM
  echo ""
  echo "[7/7] Cleaning up..."
  sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
  sudo rm -f "$temp_disk" 2>/dev/null || true
  echo "      ✓ Temporary files removed"
  
  # Calculate totals
  local total_size
  total_size=$(du -csh "$export_dir"/* 2>/dev/null | tail -n1 | cut -f1)
  
  # Success!
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    Modular Export Complete!                                    ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "📦 Unified Export Folder:"
  echo ""
  echo "  Location: $export_dir/"
  echo "  Total Size: $total_size"
  echo ""
  echo "  Contents:"
  echo "    • blockchain/ - Blockchain data split into GitHub-compatible parts"
  echo "    • ${vm_archive_name} - VM image archive"
  echo "    • ${vm_archive_name}.sha256 - Image checksum"
  echo ""
  echo "  Blockchain Components:"
  echo "    • Parts: $(ls -1 "$blockchain_export_dir"/blockchain.tar.gz.part* 2>/dev/null | wc -l) files"
  # Success!
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    Modular Export Complete!                                    ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "📦 Unified Export Folder:"
  echo ""
  echo "  Location: $export_dir/"
  echo "  Total Size: $total_size"
  echo ""
  echo "  Contents:"
  echo "    • blockchain.tar.gz.part* - Blockchain data split into GitHub-compatible parts"
  echo "    • ${vm_archive_name} - VM image archive"
  echo "    • SHA256SUMS - Combined checksums for all files"
  echo "    • MANIFEST.txt - Export information"
  echo ""
  echo "  Blockchain Components:"
  echo "    • Parts: $(ls -1 "$export_dir"/blockchain.tar.gz.part* 2>/dev/null | wc -l) files"
  echo ""
  echo "🔗 Timestamp: $export_timestamp"
  echo ""
  echo "📋 Benefits of Unified Export:"
  echo "   • All components in one folder - easy to manage and transfer"
  echo "   • Smaller VM image (~1GB vs ~22GB monolithic)"
  echo "   • Blockchain can be reused across exports"
  echo "   • Blockchain split for GitHub 2GB limit compatibility"
  echo ""
  echo "📤 To Import:"
  echo "   Use 'Import from file' in garbageman-nm.sh"
  echo "   The script will automatically combine both components"
  echo ""
  
  pause "Export complete!\n\nUnified export folder: $export_dir/"
}

################################################################################
# Clone VM (Action 4)
################################################################################

# clone_vm_once: Create a Tor-only clone from the base VM
# Args: $1 = new clone name (e.g., "gm-clone-20251025-143022")
# Purpose: Clone the synced base VM to create additional nodes
# Key differences from base:
#   - ALWAYS Tor-only (regardless of base clearnet setting)
#   - Fresh Tor v3 onion address (regenerated on first boot)
#   - Uses runtime resources (VM_VCPUS, VM_RAM_MB)
#   - Blockchain data is cloned (no re-sync needed)
# Flow:
#   1. Ensure base VM is shut off (graceful shutdown if running)
#   2. Use virt-clone to copy disk and create new domain
#   3. Remove old Tor keys (forces regeneration)
#   4. Overwrite bitcoin.conf with Tor-only config
#   5. Boot once to generate new Tor hidden service
#   6. Stop and leave ready for user
# Side effects: Creates new VM and disk image
clone_vm_once(){
  ensure_tools
  sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "Base VM '$VM_NAME' not found."
  local newname="$1"
  local disk="/var/lib/libvirt/images/${newname}.qcow2"

  # Check if base VM is running and shut it down if needed
  # virt-clone requires the source VM to be shut off before cloning
  local base_state
  base_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
  
  if [[ "$base_state" == "running" ]]; then
    echo "Base VM '$VM_NAME' is currently running. Shutting down gracefully..."
    echo "This may take up to 3 minutes for bitcoind to close cleanly."
    
    # Send graceful shutdown signal
    sudo virsh shutdown "$VM_NAME" >/dev/null 2>&1 || true
    
    # Wait up to 3 minutes (180 seconds) for graceful shutdown
    # Bitcoind needs time to flush databases and close connections cleanly
    local timeout=180
    local elapsed=0
    local check_interval=5
    
    while [[ $elapsed -lt $timeout ]]; do
      base_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
      if [[ "$base_state" != "running" ]]; then
        echo "Base VM shut down successfully after ${elapsed} seconds."
        break
      fi
      
      # Show progress every 15 seconds so user knows we're still working
      if [[ $((elapsed % 15)) -eq 0 && $elapsed -gt 0 ]]; then
        echo "Still waiting for graceful shutdown... (${elapsed}s elapsed, ${timeout}s timeout)"
      fi
      
      sleep "$check_interval"
      elapsed=$((elapsed + check_interval))
    done
    
    # Force shutdown if still running after timeout
    base_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
    if [[ "$base_state" == "running" ]]; then
      echo "Graceful shutdown timed out after ${timeout} seconds. Forcing shutdown..."
      sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
      sleep 2
      echo "Base VM forcefully stopped."
    fi
  fi

  # Clone disk+domain (virt-clone handles libvirt domain XML and disk copy)
  # This creates a complete copy of the VM including all blockchain data
  sudo virt-clone --original "$VM_NAME" --name "$newname" --file "$disk" --auto-clone

  # === CRITICAL: Configure clone before first boot ===
  # The following steps MUST happen before bitcoind starts to ensure:
  # 1. Fresh Tor identity (no .onion address reuse)
  # 2. Independent peer discovery (no shared peer connections)
  # 3. Tor-only networking (privacy-preserving)
  
  # Step 1: Disable bitcoind to prevent auto-start during configuration
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "systemctl disable bitcoind || true" 2>&1 | grep -v "random seed" >&2
  
  # Step 2: Remove old Tor hidden service keys
  # This forces generation of a fresh .onion v3 address on first boot
  # Critical for privacy: each clone must have unique Tor identity
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "rm -rf /var/lib/tor/bitcoin-service || true" 2>&1 | grep -v "random seed" >&2
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "rm -f ${BITCOIN_DATADIR}/onion_private_key || true" 2>&1 | grep -v "random seed" >&2
  
  # Step 3: Clear peer databases for independent peer discovery
  # This prevents all clones from clustering around the same peer set
  # Each clone will discover its own independent set of Tor peers
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "rm -f ${BITCOIN_DATADIR}/peers.dat || true" 2>&1 | grep -v "random seed" >&2
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "rm -f ${BITCOIN_DATADIR}/anchors.dat || true" 2>&1 | grep -v "random seed" >&2
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "rm -f ${BITCOIN_DATADIR}/banlist.dat || true" 2>&1 | grep -v "random seed" >&2

  # Step 4: Overwrite bitcoin.conf to enforce Tor-only configuration
  # This ensures ALL clones are privacy-preserving Tor-only nodes
  # regardless of the base VM's clearnet setting
  # Key settings:
  #   - onlynet=onion: Only connect to .onion addresses (no clearnet peers)
  #   - listen=1 + listenonion=1: Accept incoming connections via Tor hidden service
  #   - discover=0 + dnsseed=0: Disable clearnet peer discovery mechanisms
  #   - proxy=127.0.0.1:9050: Route all connections through Tor SOCKS proxy
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "cat > /etc/bitcoin/bitcoin.conf <<'CONF'
server=1
daemon=1
prune=750
dbcache=256
maxconnections=12
onlynet=onion
proxy=127.0.0.1:9050
listen=1
listenonion=1
discover=0
dnsseed=0
torcontrol=127.0.0.1:9051
rpcauth=
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
assumevalid=1
CONF" 2>&1 | grep -v "random seed" >&2

  # Step 5: Update hostname to match clone name (cosmetic, helps with identification)
  sudo virt-customize -d "$newname" --no-selinux-relabel --hostname "$newname" 2>&1 | grep -v "random seed" >&2
  
  # Step 6: Re-enable bitcoind service
  # Now it's safe: config is Tor-only, old keys removed, peer databases cleared
  sudo virt-customize -d "$newname" --no-selinux-relabel --run-command "systemctl enable bitcoind || true" 2>&1 | grep -v "random seed" >&2

  # Step 7: Boot once to generate fresh Tor hidden service keys, then stop
  # The new unique .onion v3 address is created during this first boot
  # We shut down immediately after so the clone is ready but not consuming resources
  sudo virsh start "$newname" >/dev/null
  sleep 30  # Give Tor daemon time to generate keys and write hostname file
  sudo virsh shutdown "$newname" || true
  
  # Wait for graceful shutdown (up to 2 minutes)
  for _ in {1..60}; do [[ "$(vm_state "$newname")" == "shut off" ]] && break; sleep 2; done

  pause "Clone '$newname' ready."
}

# clone_menu: Interactive menu to create multiple clones
# Purpose: Create one or more clones from the synced base VM
# Flow:
#   1. Detect host resources and show capacity suggestions
#   2. Prompt user for number of clones to create
#   3. Generate unique names with timestamp (e.g., gm-clone-20251025-143022)
#   4. If duplicate name exists, append suffix (-2, -3, etc.)
#   5. Create each clone sequentially
# Note: Clone names use timestamp format to avoid collisions across different creation sessions
clone_menu(){
  detect_host_resources
  local suggested="$HOST_SUGGEST_CLONES"
  local prompt="How many clones to create now?
Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB / ${HOST_DISK_GB} GB   |   Reserve: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB} MiB / ${RESERVE_DISK_GB} GB
Available after reserve: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB} MiB / ${AVAIL_DISK_GB} GB

Post-sync per-VM: vCPUs=${VM_VCPUS}, RAM=${VM_RAM_MB} MiB, Disk=${VM_DISK_SPACE_GB} GB
Suggested clones alongside the base: ${suggested}"
  local count
  count=$(whiptail --inputbox "$prompt" 18 90 "$suggested" 3>&1 1>&2 2>&3) || return
  [[ "$count" =~ ^[0-9]+$ ]] || die "Enter a number."

  for i in $(seq 1 "$count"); do
    # Generate base name with timestamp (format: gm-clone-YYYYMMDD-HHMMSS)
    local base_name="${CLONE_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    local name="$base_name"
    
    # Check if name already exists (rare, but possible if creating multiple clones per second)
    # Add numeric suffix (-2, -3, etc.) to ensure uniqueness
    local suffix=2
    while sudo virsh dominfo "$name" >/dev/null 2>&1; do
      name="${base_name}-${suffix}"
      suffix=$((suffix + 1))
    done
    
    clone_vm_once "$name"
  done
}

# manage_clone: Manage individual clone VM
# Args: $1 = clone VM name
# Purpose: Interactive menu for controlling a specific clone
# Features:
#   - Displays VM state in menu header
#   - If running, shows .onion address and block height in real-time
#   - Provides start/stop/delete actions
# Actions:
#   1. Start VM - Power on the clone
#   2. Stop VM (graceful) - Send shutdown signal (waits for bitcoind to close)
#   3. Force Stop VM - Immediate power off (use if graceful shutdown fails)
#   4. Check Status - Show state and IP address
#   5. Delete VM (permanent) - Destroy VM and delete disk (requires confirmation)
#   6. Back to Clone List - Return to clone selection menu
# Loop: Menu stays open after actions (user must select "Back" to exit)
manage_clone(){
  local clone_name="$1"
  
  while true; do
    local current_state
    current_state=$(vm_state "$clone_name" 2>/dev/null || echo "unknown")
    
    # If running, gather additional live info to display in menu header
    local extra_info=""
    if [[ "$current_state" == "running" ]]; then
      local ip
      ip=$(vm_ip "$clone_name" 2>/dev/null || echo "")
      
      if [[ -n "$ip" ]]; then
        # Try to get .onion address
        local onion
        onion=$(gssh "$ip" 'cat /var/lib/tor/bitcoin-service/hostname 2>/dev/null' 2>/dev/null || echo "")
        
        # Try to get blockchain info
        local blocks headers
        local info
        info=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null' 2>/dev/null || echo "")
        blocks=$(jq -r '.blocks // ""' <<<"$info" 2>/dev/null || echo "")
        headers=$(jq -r '.headers // ""' <<<"$info" 2>/dev/null || echo "")
        
        # Try to get network info for peer count
        local netinfo peers
        netinfo=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null' 2>/dev/null || echo "")
        peers=$(jq -r '.connections // ""' <<<"$netinfo" 2>/dev/null || echo "")
        
        # Build extra info string
        [[ -n "$onion" ]] && extra_info="${extra_info}Tor: ${onion}\n"
        [[ -n "$blocks" ]] && extra_info="${extra_info}Blocks: ${blocks}"
        [[ -n "$headers" && -n "$blocks" ]] && extra_info="${extra_info}/${headers}"
        [[ -n "$peers" ]] && extra_info="${extra_info}\nPeers: ${peers}"
        [[ -n "$extra_info" ]] && extra_info="\n${extra_info}"
      fi
    fi
    
    local choice
    choice=$(whiptail --title "Manage Clone: $clone_name" --menu \
      "Current state: ${current_state}${extra_info}\n\nChoose an action:" 20 78 6 \
      1 "Start VM" \
      2 "Stop VM (graceful)" \
      3 "Force Stop VM" \
      4 "Check Status" \
      5 "Delete VM (permanent)" \
      6 "Back to Clone List" \
      3>&1 1>&2 2>&3) || return
    
    case "$choice" in
      1)
        if [[ "$current_state" == "running" ]]; then
          pause "VM '$clone_name' is already running."
        else
          sudo virsh start "$clone_name" && pause "VM '$clone_name' started." || pause "Failed to start VM."
        fi
        ;;
      2)
        if [[ "$current_state" != "running" ]]; then
          pause "VM '$clone_name' is not running."
        else
          virsh_cmd shutdown "$clone_name" && pause "Shutdown signal sent to '$clone_name'." || pause "Failed to send shutdown signal."
        fi
        ;;
      3)
        if [[ "$current_state" != "running" ]]; then
          pause "VM '$clone_name' is not running."
        else
          virsh_cmd destroy "$clone_name" && pause "VM '$clone_name' force stopped." || pause "Failed to force stop VM."
        fi
        ;;
      4)
        monitor_vm_status "$clone_name"
        ;;
      5)
        if whiptail --title "Confirm Deletion" --yesno \
          "Are you sure you want to PERMANENTLY DELETE '$clone_name'?\n\nThis will:\n  - Destroy the VM\n  - Delete the disk image\n  - Remove all blockchain data for this clone\n\nThis action CANNOT be undone!" \
          14 70; then
          
          # Stop VM if running
          if [[ "$current_state" == "running" ]]; then
            echo "Stopping VM..."
            virsh_cmd destroy "$clone_name" 2>/dev/null || true
            sleep 2
          fi
          
          # Undefine and delete disk
          echo "Deleting VM and disk..."
          sudo virsh undefine "$clone_name" 2>/dev/null || true
          sudo rm -f "/var/lib/libvirt/images/${clone_name}.qcow2" 2>/dev/null || true
          
          pause "Clone '$clone_name' has been deleted."
          return
        fi
        ;;
      6)
        return
        ;;
    esac
  done
}

# clone_management_menu: List and manage all clone VMs
# Purpose: Interactive menu to select and manage individual clones
# Flow:
#   1. List all VMs with CLONE_PREFIX in name (e.g., gm-clone-*)
#   2. Show each clone with its current state (running/shut off/etc.)
#   3. User selects a clone to manage
#   4. Opens manage_clone menu for that specific VM
#   5. Returns to list after management (loop continues until user exits)
# Note: If no clones found, displays helpful message about creating clones
clone_management_menu(){
  while true; do
    # Get list of all clones (VMs with CLONE_PREFIX in name)
    local clones
    clones=$(sudo virsh list --all --name | grep "^${CLONE_PREFIX}" | sort || true)
    
    if [[ -z "$clones" ]]; then
      pause "No clone VMs found.\n\nClone VMs have names starting with '${CLONE_PREFIX}'.\nCreate clones using 'Create Clone VMs' from the main menu."
      return
    fi
    
    # Build whiptail menu from clone list
    local menu_items=()
    local i=1
    while IFS= read -r clone; do
      [[ -z "$clone" ]] && continue
      local state
      state=$(vm_state "$clone" 2>/dev/null || echo "unknown")
      menu_items+=("$i" "$clone ($state)")
      i=$((i + 1))
    done <<< "$clones"
    
    # Add back option
    menu_items+=("0" "Back to Main Menu")
    
    local choice
    choice=$(whiptail --title "Clone Management" --menu \
      "Select a clone to manage:\n\n(${#menu_items[@]}/2 clones found)" \
      20 70 12 \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3) || return
    
    if [[ "$choice" == "0" ]]; then
      return
    fi
    
    # Get the selected clone name
    local selected_clone
    selected_clone=$(echo "$clones" | sed -n "${choice}p")
    
    if [[ -n "$selected_clone" ]]; then
      manage_clone "$selected_clone"
      # If manage_clone returned (VM deleted or back pressed), refresh the list
    fi
  done
}


################################################################################
# Onion Address Display (Action 5)
################################################################################

# show_onion: Display the Tor v3 onion address for a VM
# Purpose: Retrieve and show the .onion address from a running VM
# Flow:
#   1. Prompt for VM name (defaults to base VM)
#   2. Ensure VM is running
#   3. SSH into VM and read /var/lib/tor/bitcoin-service/hostname
#   4. Display in dialog
# Note: Onion address is generated on first boot, may not exist immediately
show_onion(){
  ensure_tools
  local target
  target=$(whiptail --inputbox "VM name to inspect (default: ${VM_NAME})" 10 60 "$VM_NAME" 3>&1 1>&2 2>&3) || return
  [[ -z "$target" ]] && target="$VM_NAME"
  if [[ "$(vm_state "$target")" != "running" ]]; then 
    pause "VM '$target' is not running. Start it first."
    return
  fi
  ensure_monitor_ssh
  sudo virsh start "$target" >/dev/null || true
  sleep 2
  local ip onion
  ip="$(vm_ip)"
  [[ -n "$ip" ]] || { pause "Could not determine VM IP."; return; }
  onion="$(gssh "$ip" 'cat /var/lib/tor/bitcoin-service/hostname 2>/dev/null' || true)"
  [[ -n "$onion" ]] || onion="(not available yet; Tor may still be initializing)"
  pause "Onion for '$target':\n\n$onion"
}


################################################################################
# Manage Base VM (Action 3)
################################################################################

# quick_control: Simple start/stop/status/export/delete menu for base VM
# Purpose: Convenient VM power management, export, and deletion without full monitoring
# Features:
#   - Displays VM state in menu header
#   - If VM is running, shows .onion address and block height (like clone management)
#   - Provides start/stop/status/export/delete actions
# Actions:
#   - 1: Start VM (virsh start)
#   - 2: Stop VM gracefully (virsh shutdown)
#   - 3: Check status - display current VM state and live monitoring
#   - 4: Export VM for transfer (creates modular export)
#   - 5: Delete VM permanently (requires two-step confirmation: yes/no + type VM name)
#   - 6: Return to main menu
# Export Format: NEW MODULAR (creates 2 separate components for efficiency)
# Loop: Menu stays open after actions (user must select "back" to exit)
quick_control(){
  while true; do
    local current_state
    current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
    
    # If VM is running, gather additional live info (like clone management does)
    # This provides quick visibility into node status without separate menu option
    local extra_info=""
    if [[ "$current_state" == "running" ]]; then
      local ip
      ip=$(vm_ip "$VM_NAME" 2>/dev/null || echo "")
      
      if [[ -n "$ip" ]]; then
        # Try to get .onion address from Tor hidden service
        local onion
        onion=$(gssh "$ip" 'cat /var/lib/tor/bitcoin-service/hostname 2>/dev/null' 2>/dev/null || echo "")
        
        # Try to get blockchain sync status via bitcoin-cli
        local blocks headers
        local info
        info=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null' 2>/dev/null || echo "")
        blocks=$(jq -r '.blocks // ""' <<<"$info" 2>/dev/null || echo "")
        headers=$(jq -r '.headers // ""' <<<"$info" 2>/dev/null || echo "")
        
        # Try to get network info for peer count
        local netinfo peers
        netinfo=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null' 2>/dev/null || echo "")
        peers=$(jq -r '.connections // ""' <<<"$netinfo" 2>/dev/null || echo "")
        
        # Build extra info string for menu header
        [[ -n "$onion" ]] && extra_info="${extra_info}Tor: ${onion}\n"
        [[ -n "$blocks" ]] && extra_info="${extra_info}Blocks: ${blocks}"
        [[ -n "$headers" && -n "$blocks" ]] && extra_info="${extra_info}/${headers}"
        [[ -n "$peers" ]] && extra_info="${extra_info}\nPeers: ${peers}"
        [[ -n "$extra_info" ]] && extra_info="\n${extra_info}"
      fi
    fi
    
    local sub
    sub=$(whiptail --title "Manage VM: ${VM_NAME}" --menu "VM state: ${current_state}${extra_info}\n\nChoose an action:" 24 78 8 \
          1 "Start VM" \
          2 "Stop VM (graceful)" \
          3 "Check Status (live monitor)" \
          4 "Export VM (for transfer)" \
          5 "Delete VM (permanent)" \
          6 "Back to Main Menu" \
          3>&1 1>&2 2>&3) || return
    case "$sub" in
      1) 
        sudo virsh start "$VM_NAME" >/dev/null || true
        pause "VM '${VM_NAME}' has been started (if it wasn't already running)."
        ;;
      2)
        sudo virsh shutdown "$VM_NAME" || true
        pause "Shutdown command sent to VM '${VM_NAME}'."
        ;;
      3)
        monitor_vm_status "$VM_NAME"
        ;;
      4)
        export_base_vm
        ;;
      5)
        # Confirmation dialog with strong warning
        if whiptail --title "Confirm Deletion" \
          --yesno "Are you SURE you want to PERMANENTLY DELETE '${VM_NAME}'?\n\n⚠️  WARNING: This action is IRREVERSIBLE!\n\nThis will:\n• Destroy the VM definition\n• Delete the disk image (all blockchain data)\n• Remove all configuration\n\nYou will need to rebuild or re-import to use this VM again.\n\nProceed to confirmation step?" \
          20 78; then
          
          # Secondary confirmation - require typing VM name
          local confirm_name
          confirm_name=$(whiptail --inputbox "Type the exact VM name to confirm deletion:\n\nVM name: ${VM_NAME}" 12 78 3>&1 1>&2 2>&3)
          
          if [[ "$confirm_name" == "$VM_NAME" ]]; then
            echo "Deleting VM '${VM_NAME}'..."
            
            # Stop VM if running
            local vm_state_now
            vm_state_now=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
            if [[ "$vm_state_now" == "running" ]]; then
              echo "  Stopping VM..."
              sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
              sleep 2
            fi
            
            # Undefine VM (removes domain definition)
            echo "  Removing VM definition..."
            sudo virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
            
            # Delete disk image
            local disk="/var/lib/libvirt/images/${VM_NAME}.qcow2"
            if [[ -f "$disk" ]]; then
              echo "  Deleting disk image: $disk"
              sudo rm -f "$disk" || true
            fi
            
            echo ""
            pause "✅ VM '${VM_NAME}' has been permanently deleted.\n\nYou can create a new base VM using Option 1 from the main menu."
            return  # Exit to main menu after deletion
          else
            pause "Deletion cancelled - VM name did not match."
          fi
        else
          pause "Deletion cancelled."
        fi
        ;;
      6)
        return
        ;;
      *) : ;;
    esac
  done
}


################################################################################
# Container Implementation Stubs
################################################################################
# The following functions provide container-based equivalents of VM operations.
# These are functional stubs that guide implementation.

# create_base_container: Main entry point for creating base container
# Purpose: Offers choice between importing from GitHub, importing from file, or building from scratch
# Flow:
#   1. Check if container already exists (abort if it does)
#   2. Present menu: "Import from GitHub", "Import from file", or "Build from scratch"
#   3. Call appropriate function based on selection
create_base_container(){
  # Check if container already exists
  if container_exists "$CONTAINER_NAME" 2>/dev/null; then
    whiptail --title "Container Exists" --msgbox \
      "Container '$CONTAINER_NAME' already exists.\n\nTo recreate it:\n1. Delete the existing container first\n2. Use 'Manage Base Container' → 'Delete'\n\nOr use 'Manage Base Container' to control the existing one." 14 78
    return
  fi
  
  # Present choice menu
  local choice
  choice=$(whiptail --title "Create Base Container" \
    --menu "How would you like to create the base container?\n\nOptions:" 18 78 3 \
    "1" "Import from GitHub Release (download pre-built)" \
    "2" "Import from file (use local export)" \
    "3" "Build from scratch (compile Garbageman)" \
    3>&1 1>&2 2>&3) || return
  
  case "$choice" in
    1) import_from_github_container ;;
    2) import_base_container ;;
    3) create_base_container_from_scratch ;;
    *) return ;;
  esac
}

# create_base_container_from_scratch: Build base container from scratch using Dockerfile
# Purpose: Build Garbageman container image with Alpine Linux, Tor, and bitcoind
# Process:
#   1. Configure defaults (CPU/RAM/network settings)
#   2. Create temporary build directory with Dockerfile, entrypoint, and bitcoin.conf
#   3. Multi-stage Docker build compiles Garbageman from source (~2 hours)
#   4. Inject bitcoin.conf into volume (same approach as imports for consistency)
#   5. Create and start container with command override to use volume-based config
# Similar to create_base_vm_from_scratch() but uses container technology instead of VMs
# Note: bitcoin.conf is embedded in image for reference but overridden by volume-based config
create_base_container_from_scratch(){
  # Step 0: Let user choose node type (Garbageman or Bitcoin Knots)
  local node_choice
  node_choice=$(whiptail --title "Select Node Type" --menu \
    "Choose which Bitcoin implementation to build:" 15 70 2 \
    "1" "Garbageman" \
    "2" "Bitcoin Knots" \
    3>&1 1>&2 2>&3)
  
  if [[ -z "$node_choice" ]]; then
    return
  fi
  
  # Set repository and branch/tag based on selection
  local GM_REPO GM_BRANCH GM_IS_TAG
  if [[ "$node_choice" == "1" ]]; then
    GM_REPO="https://github.com/chrisguida/bitcoin.git"
    GM_BRANCH="garbageman-v29"
    GM_IS_TAG="false"
    echo "Selected: Garbageman (Libre Relay)"
  elif [[ "$node_choice" == "2" ]]; then
    GM_REPO="https://github.com/bitcoinknots/bitcoin.git"
    GM_BRANCH="v29.2.knots20251010"
    GM_IS_TAG="true"
    echo "Selected: Bitcoin Knots"
  else
    return
  fi

  # Let user configure defaults (container-specific prompts)
  if ! configure_defaults_container; then
    return
  fi
  
  # Prompt for initial sync resources
  if ! prompt_sync_resources_container; then
    return
  fi
  
  # Start sudo keepalive for long build process
  sudo_keepalive_start force
  
  ensure_tools
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                     Building Base Container                                    ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "This will:"
  echo "  1. Let you choose node type (Garbageman/Libre Relay or Bitcoin Knots)"
  echo "  2. Create a Dockerfile for Alpine Linux with Bitcoin"
  echo "  3. Build the container image (includes compiling Bitcoin - takes 2+ hours)"
  echo "  4. Configure Tor and bitcoind with proper directory setup"
  echo "  5. Inject bitcoin.conf into volume"
  echo "  6. Create and start the container with bridge networking"
  echo ""
  echo "Container will use:"
  echo "  • Initial sync: ${SYNC_VCPUS} CPUs, ${SYNC_RAM_MB}MB RAM"
  echo "  • After sync: ${VM_VCPUS} CPUs, ${VM_RAM_MB}MB RAM"
  echo "  • Network: ${CLEARNET_OK} clearnet during sync (clones are Tor-only)"
  echo "  • Isolated network namespace (not host networking)"
  echo ""
  
  if ! whiptail --title "Confirm Container Creation" --yesno \
    "Ready to build base container?\n\nThis process takes 2+ hours.\n\nProceed?" 12 78; then
    return
  fi
  
  # Create temporary build directory
  local build_dir
  build_dir=$(mktemp -d -t gm-container-build-XXXXXX)
  trap "sudo rm -rf '$build_dir' 2>/dev/null || rm -rf '$build_dir'" RETURN EXIT INT TERM
  
  echo ""
  echo "[1/6] Creating Dockerfile..."
  
  # Determine bitcoin.conf based on CLEARNET_OK
  # Clearnet mode: Allows both IPv4 and Tor connections
  # Tor-only mode: Forces all connections through Tor SOCKS proxy
  local bitcoin_conf_content
  if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
    # Clearnet + Tor: Allow both IPv4 and onion, proxy only for onion connections
    bitcoin_conf_content="server=1
prune=750
dbcache=450
maxconnections=25
listen=1
bind=0.0.0.0
onlynet=onion
onlynet=ipv4
listenonion=1
discover=1
dnsseed=1
proxy=127.0.0.1:9050
torcontrol=127.0.0.1:9051
[main]"
  else
    # Tor-only: Force all connections through Tor
    bitcoin_conf_content="server=1
prune=750
dbcache=450
maxconnections=25
onlynet=onion
proxy=127.0.0.1:9050
listen=1
bind=0.0.0.0
listenonion=1
discover=0
dnsseed=0
torcontrol=127.0.0.1:9051
[main]"
  fi
  
  # Create Dockerfile
  cat > "$build_dir/Dockerfile" <<'DOCKERFILE'
FROM alpine:3.18

# Install runtime and build dependencies
RUN apk update && apk add --no-cache \
    bash \
    su-exec \
    shadow \
    ca-certificates \
    busybox-extras \
    cmake \
    g++ \
    gcc \
    make \
    git \
    boost-dev \
    libevent-dev \
    zeromq-dev \
    sqlite-dev \
    linux-headers

# Create bitcoin user and group (tor user/group will be created when Tor is installed later)
RUN addgroup -S bitcoin && \
    adduser -S -G bitcoin bitcoin

# Create directories
RUN mkdir -p /var/lib/bitcoin /etc/bitcoin

# Clone and build Bitcoin
WORKDIR /tmp/garbageman
RUN GM_GIT_CLONE_CMD && \
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_GUI=OFF \
        -DWITH_ZMQ=ON \
        -DBUILD_TESTS=OFF \
        -DBUILD_BENCH=OFF && \
    cmake --build build -j$(nproc) && \
    install -m 0755 build/bin/bitcoind /usr/local/bin/ && \
    install -m 0755 build/bin/bitcoin-cli /usr/local/bin/ && \
    cd / && rm -rf /tmp/garbageman

# Remove build dependencies to reduce image size
RUN apk del cmake g++ gcc make git boost-dev linux-headers && \
    rm -rf /var/cache/apk/*

# Install Tor and configure user/group access
# Note: Alpine 3.18 tor package creates tor user (UID 101) with nogroup (GID 65533)
# Bitcoin group gets GID 101, so tor group will be GID 102
# We create tor group and change tor user's primary group from 65533 to 102
RUN apk add --no-cache tor && \
    addgroup -S tor && \
    sed -i 's/tor:x:101:65533:/tor:x:101:102:/' /etc/passwd && \
    addgroup bitcoin tor && \
    mkdir -p /var/lib/tor/bitcoin-service && \
    chown -R tor:tor /var/lib/tor && \
    chmod 700 /var/lib/tor && \
    chmod 700 /var/lib/tor/bitcoin-service

# Configure Tor (bind to localhost only - no external exposure needed)
RUN echo "SOCKSPort 127.0.0.1:9050" >> /etc/tor/torrc && \
    echo "ControlPort 127.0.0.1:9051" >> /etc/tor/torrc && \
    echo "CookieAuthentication 1" >> /etc/tor/torrc && \
    echo "DataDirectory /var/lib/tor" >> /etc/tor/torrc && \
    echo "HiddenServiceDir /var/lib/tor/bitcoin-service" >> /etc/tor/torrc && \
    echo "HiddenServicePort 8333 127.0.0.1:8333" >> /etc/tor/torrc

# Copy configuration files
# NOTE: This bitcoin.conf is embedded in the image but not used at runtime.
# Actual config is injected into the volume at /var/lib/bitcoin/bitcoin.conf
# during container creation. This file exists only for documentation/reference.
COPY bitcoin.conf /etc/bitcoin/bitcoin.conf
COPY entrypoint.sh /entrypoint.sh

# Set ownership and permissions
RUN chown -R bitcoin:bitcoin /var/lib/bitcoin /etc/bitcoin && \
    chmod 644 /etc/bitcoin/bitcoin.conf && \
    chmod +x /entrypoint.sh

# Bitcoin data volume
VOLUME ["/var/lib/bitcoin"]

# Ensure /usr/local/bin is in PATH for all users
ENV PATH="/usr/local/bin:$PATH"

EXPOSE 8333 9050

ENTRYPOINT ["/entrypoint.sh"]
# Default CMD (overridden at container creation to use volume-based config)
CMD ["bitcoind", "-conf=/etc/bitcoin/bitcoin.conf", "-datadir=/var/lib/bitcoin"]
DOCKERFILE

  # Replace placeholders in Dockerfile
  # Build the git clone command based on whether using branch or tag
  local git_clone_cmd
  if [[ "$GM_IS_TAG" == "true" ]]; then
    git_clone_cmd="git clone --depth 1 --branch '$GM_BRANCH' '$GM_REPO' ."
  else
    git_clone_cmd="git clone --branch '$GM_BRANCH' --depth 1 '$GM_REPO' ."
  fi
  
  sed -i "s|GM_GIT_CLONE_CMD|$git_clone_cmd|g" "$build_dir/Dockerfile"
  
  # Create entrypoint script with graceful shutdown handling
  # Key features:
  #   - Creates /run/tor directory (required for Tor's control.authcookie)
  #   - Starts Tor and bitcoind in background with proper user permissions
  #   - Traps SIGTERM/SIGINT for graceful shutdown
  #   - Sends bitcoin-cli stop and waits up to 180s for clean exit
  #   - Ensures blockchain data is properly flushed before container stops
  cat > "$build_dir/entrypoint.sh" <<'ENTRYPOINT'
#!/bin/bash
set -e

echo "=== Garbageman Container Starting ==="
echo "Date: $(date)"
echo ""

# Ensure Tor directories exist with correct ownership BEFORE starting Tor
# Critical: /run/tor must exist for Tor to write control.authcookie
# Note: /run is a tmpfs that gets cleared on container restart
echo "Setting up Tor directories..."
mkdir -p /var/lib/tor/bitcoin-service
mkdir -p /run/tor
chown -R tor:tor /var/lib/tor
chown tor:tor /run/tor
chmod 700 /var/lib/tor
chmod 700 /var/lib/tor/bitcoin-service
chmod 755 /run/tor

# Start Tor in background as tor user
echo "Starting Tor..."
su-exec tor tor -f /etc/tor/torrc &
TOR_PID=$!
echo "Tor PID: $TOR_PID"

# Wait for Tor to be ready (checks for SOCKS proxy port)
echo "Waiting for Tor SOCKS proxy on 127.0.0.1:9050..."
for i in {1..30}; do
  if nc -z 127.0.0.1 9050 2>/dev/null; then
    echo "✓ Tor SOCKS proxy is ready"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "⚠️  Warning: Tor SOCKS proxy not responding after 30 seconds"
    echo "Continuing anyway..."
  fi
  sleep 1
done

# Ensure bitcoin directories exist with correct permissions
echo "Setting up Bitcoin directories..."
mkdir -p /var/lib/bitcoin
chown -R bitcoin:bitcoin /var/lib/bitcoin

# Display config for debugging
echo ""
echo "Bitcoin configuration:"
if [ -f /var/lib/bitcoin/bitcoin.conf ]; then
  echo "✓ bitcoin.conf found at /var/lib/bitcoin/bitcoin.conf (volume-based, ACTIVE)"
  echo "  Key settings:"
  grep -E '^(server|daemon|prune|onlynet|proxy)=' /var/lib/bitcoin/bitcoin.conf 2>/dev/null || echo "  (no settings found)"
elif [ -f /etc/bitcoin/bitcoin.conf ]; then
  echo "✓ bitcoin.conf found at /etc/bitcoin/bitcoin.conf (image-based, FALLBACK)"
  echo "  Key settings:"
  grep -E '^(server|daemon|prune|onlynet|proxy)=' /etc/bitcoin/bitcoin.conf 2>/dev/null || echo "  (no settings found)"
else
  echo "⚠️  Warning: bitcoin.conf not found"
fi

# Signal handler for graceful shutdown
shutdown_handler() {
  echo ""
  echo "=== Shutdown signal received ==="
  echo "Stopping bitcoind gracefully..."
  
  # Try to stop bitcoind gracefully using bitcoin-cli
  if su-exec bitcoin bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin stop 2>/dev/null; then
    echo "✓ Sent stop command to bitcoind"
    
    # Wait up to 180 seconds (3 minutes) for bitcoind to exit
    for i in {1..180}; do
      if ! pgrep -x bitcoind >/dev/null 2>&1; then
        echo "✓ bitcoind stopped gracefully"
        break
      fi
      if [ $i -eq 180 ]; then
        echo "⚠️  Warning: bitcoind did not stop within 3 minutes"
      fi
      sleep 1
    done
  else
    echo "⚠️  Could not send stop command to bitcoind"
  fi
  
  # Stop Tor
  if [ -n "$TOR_PID" ] && kill -0 $TOR_PID 2>/dev/null; then
    echo "Stopping Tor (PID: $TOR_PID)..."
    kill $TOR_PID 2>/dev/null || true
    wait $TOR_PID 2>/dev/null || true
    echo "✓ Tor stopped"
  fi
  
  echo "=== Shutdown complete ==="
  exit 0
}

# Trap SIGTERM and SIGINT for graceful shutdown
trap shutdown_handler SIGTERM SIGINT

# Start bitcoind as bitcoin user
echo ""
echo "Starting bitcoind as user 'bitcoin'..."
echo "Command: $@"
echo ""
export PATH="/usr/local/bin:$PATH"

# Start bitcoind in background so we can handle signals
su-exec bitcoin "$@" &
BITCOIND_PID=$!
echo "bitcoind PID: $BITCOIND_PID"

# Wait for bitcoind to exit (or signal to arrive)
wait $BITCOIND_PID
ENTRYPOINT
  
  # Create bitcoin.conf file
  cat > "$build_dir/bitcoin.conf" <<BTCCONF
$bitcoin_conf_content
BTCCONF
  
  echo "    ✓ Dockerfile created"
  
  # Build the container image
  echo ""
  echo "[2/6] Building container image..."
  echo "      This will take 2+ hours (compiling Bitcoin from source)"
  echo "      Note: Using --no-cache to ensure fresh build"
  echo ""
  
  local runtime
  runtime=$(container_runtime)
  
  if ! container_cmd build --no-cache -t "$CONTAINER_IMAGE" "$build_dir" 2>&1 | while IFS= read -r line; do
    echo "      $line"
  done; then
    echo ""
    echo "❌ Container build failed"
    return 1
  fi
  
  echo ""
  echo "    ✓ Container image built successfully"
  
  # Create data volume
  echo ""
  echo "[3/6] Creating data volume..."
  container_cmd volume create "garbageman-data" >/dev/null 2>&1 || true
  echo "    ✓ Data volume created"
  
  # Inject bitcoin.conf into volume (same approach as imports for consistency)
  echo ""
  echo "[4/6] Injecting bitcoin.conf into volume..."
  local temp_conf=$(mktemp)
  echo "$bitcoin_conf_content" > "$temp_conf"
  
  if container_cmd run --rm \
    -v garbageman-data:/data \
    -v "$temp_conf:/bitcoin.conf:ro" \
    alpine:3.18 \
    sh -c 'cp /bitcoin.conf /data/bitcoin.conf && chmod 644 /data/bitcoin.conf' 2>/dev/null; then
    echo "    ✓ bitcoin.conf injected into volume at /var/lib/bitcoin/bitcoin.conf"
  else
    echo "    ⚠️  Warning: Failed to inject bitcoin.conf, will use image default"
  fi
  rm -f "$temp_conf"
  
  # Create and start container with command override
  echo ""
  echo "[5/6] Creating container..."
  
  # Calculate CPU and memory limits
  local cpu_limit="${SYNC_VCPUS}.0"
  local mem_limit="${SYNC_RAM_MB}m"
  
  # Override CMD to use volume-based config for consistency with imports/clones
  if ! container_cmd run -d \
    --name "$CONTAINER_NAME" \
    --cpus="$cpu_limit" \
    --memory="$mem_limit" \
    -v garbageman-data:/var/lib/bitcoin \
    --restart unless-stopped \
    "$CONTAINER_IMAGE" \
    bitcoind -conf=/var/lib/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin 2>&1 | while IFS= read -r line; do
      echo "      $line"
    done; then
    echo ""
    echo "❌ Failed to create container"
    return 1
  fi
  
  echo "    ✓ Container created and started"
  
  # Wait for container to be ready
  echo ""
  echo "[6/6] Waiting for container to initialize..."
  sleep 5
  
  local container_state
  container_state=$(container_state "$CONTAINER_NAME")
  
  if [[ "$container_state" != "up" ]]; then
    echo ""
    echo "⚠️  Container is not running (state: $container_state)"
    echo "    Check logs: $runtime logs $CONTAINER_NAME"
    return 1
  fi
  
  echo "    ✓ Container is running"
  
  # Success!
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                      Container Created Successfully!                           ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "✅ Base container '$CONTAINER_NAME' is ready!"
  echo ""
  echo "📋 Configuration:"
  echo "   Resources: ${SYNC_VCPUS} CPUs, ${SYNC_RAM_MB}MB RAM (initial sync)"
  echo "   Network: ${CLEARNET_OK} clearnet during sync"
  echo "   Image: $CONTAINER_IMAGE"
  echo ""
  echo "📌 Next steps:"
  echo "   1. Choose 'Monitor Base Container Sync' to check sync progress"
  echo "   2. Once synced, clone the container for additional nodes"
  echo ""
  
  pause "Container '$CONTAINER_NAME' created successfully!\n\nChoose 'Monitor Base Container Sync' to track IBD progress."
}

# get_peer_breakdown_container: Analyze peer user agents in container and categorize them
# Args: $1 = Container name
# Returns: Formatted string like "21 (5 LR/GM, 3 KNOTS, 2 OLDCORE, 7 COREv30+, 4 OTHER)"
# Detection Logic (same as VM version):
#   1. LR/GM: Has Libre Relay service bit 29 (0x20000000) in services field
#   2. KNOTS: subver contains "knots" or "Knots"
#   3. OLDCORE: subver contains "Satoshi" and version < 30
#   4. COREv30+: subver contains "Satoshi" and version >= 30
#   5. OTHER: Everything else
# Note: Uses getpeerinfo RPC command which provides both subver and services
get_peer_breakdown_container(){
  local container_name="$1"
  local peerinfo
  
  # Get detailed peer information from container
  peerinfo=$(container_exec "$container_name" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getpeerinfo 2>/dev/null || echo "[]")
  
  # Count total peers
  local total=$(echo "$peerinfo" | jq 'length' 2>/dev/null || echo 0)
  
  if [[ "$total" -eq 0 ]]; then
    echo "0"
    return
  fi
  
  # Initialize counters
  local lr_gm=0 knots=0 oldcore=0 core30plus=0 other=0
  
  # Parse each peer's user agent and services
  while IFS= read -r peer; do
    local subver=$(echo "$peer" | jq -r '.subver // ""' 2>/dev/null)
    local services=$(echo "$peer" | jq -r '.services // ""' 2>/dev/null)
    
    # Check for Libre Relay bit (bit 29: 0x20000000 = 536870912 in decimal)
    # Services is a hex string like "000000000000040d" or "20000409"
    if [[ -n "$services" ]]; then
      local services_dec=$((16#${services}))
      if (( (services_dec & 0x20000000) != 0 )); then
        ((lr_gm++))
        continue
      fi
    fi
    
    # Check user agent string patterns
    if [[ "$subver" =~ [Kk]nots ]]; then
      ((knots++))
    elif [[ "$subver" =~ /Satoshi:([0-9]+)\. ]]; then
      local version="${BASH_REMATCH[1]}"
      if [[ "$version" -ge 30 ]]; then
        ((core30plus++))
      else
        ((oldcore++))
      fi
    else
      ((other++))
    fi
  done < <(echo "$peerinfo" | jq -c '.[]' 2>/dev/null)
  
  # Build the breakdown string - always show all categories
  local breakdown="$total ($lr_gm LR/GM, $knots KNOTS, $oldcore OLDCORE, $core30plus COREv30+, $other OTHER)"
  
  echo "$breakdown"
}

# get_node_classification_container: Classify the running node in container
# Args: $1 = Container name
# Returns: Classification string based on the node's subversion and services
# Detection Logic:
#   1. Libre Relay/Garbageman: Has Libre Relay service bit 29 (0x20000000 hex = 536870912 dec)
#      - Checked via localservices field in getnetworkinfo
#   2. Bitcoin Knots: subversion field contains "knots" or "Knots"
#   3. Bitcoin Core pre-30: subversion contains "Satoshi" and version < 30
#   4. Bitcoin Core v30+: subversion contains "Satoshi" and version >= 30
#   5. Unknown: Doesn't match any of the above
# Note: Returns empty string if RPC not ready yet
get_node_classification_container(){
  local container_name="$1"
  local netinfo
  
  # Get network information from the running node
  netinfo=$(container_exec "$container_name" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null || echo "")
  
  if [[ -z "$netinfo" ]]; then
    echo ""  # Blank - RPC not ready yet
    return
  fi
  
  local subver=$(echo "$netinfo" | jq -r '.subversion // ""' 2>/dev/null)
  local services=$(echo "$netinfo" | jq -r '.localservices // ""' 2>/dev/null)
  
  # Check if localservices is available yet (empty means not ready)
  if [[ -z "$services" ]]; then
    echo ""  # Blank - node is still starting up
    return
  fi
  
  # Check for Libre Relay bit (bit 29: 0x20000000 = 536870912 in decimal)
  # localservices is returned as a hexadecimal string
  local services_dec=0
  if [[ "$services" =~ ^[0-9a-fA-F]+$ ]]; then
    services_dec=$((16#${services}))
  fi
  
  if (( (services_dec & 0x20000000) != 0 )); then
    echo "Libre Relay/Garbageman"
    return
  fi
  
  # Libre Relay bit is not set, check if it's a known implementation
  # Check user agent string patterns
  if [[ "$subver" =~ [Kk]nots ]]; then
    echo "Bitcoin Knots"
    return
  elif [[ "$subver" =~ /Satoshi:([0-9]+)\. ]]; then
    local version="${BASH_REMATCH[1]}"
    if [[ "$version" -ge 30 ]]; then
      echo "Bitcoin Core v30+"
      return
    else
      echo "Bitcoin Core pre-30"
      return
    fi
  else
    echo "Unknown"  # Other implementation with Libre Relay bit = 0
    return
  fi
}

# monitor_container_sync: Monitor IBD sync progress in container with live updates
# Purpose: Display real-time sync progress with automatic refresh
# Process:
#   1. Start container if not running
#   2. Poll bitcoin-cli getblockchaininfo every 5 seconds
#   3. Display blocks, headers, sync progress, verification progress, peers
#   4. Detect and handle stale tip warnings (no progress for 60+ seconds)
#   5. Auto-downsizes container resources when sync completes
# Similar to monitor_sync() but uses container_exec instead of SSH
# User can press 'q' to exit (container continues running)
monitor_container_sync(){
  ensure_tools
  
  if ! container_exists "$CONTAINER_NAME"; then
    die "Container '$CONTAINER_NAME' not found.\n\nCreate it first with 'Create Base Container'."
  fi
  
  # Check if container is running
  local container_state_now
  container_state_now=$(container_state "$CONTAINER_NAME")
  
  if [[ "$container_state_now" == "up" ]]; then
    # Container is already running - prompt for resource changes
    echo "Container '$CONTAINER_NAME' is already running."
    echo ""
    
    # Get current container resource limits
    local current_cpus current_ram_mb
    local runtime=$(container_runtime)
    
    if [[ "$runtime" == "docker" ]]; then
      # Docker inspect returns CPUs as string like "2.000000"
      current_cpus=$(docker inspect --format='{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
      if [[ "$current_cpus" == "0" ]]; then
        # No limit set, use system default (all cores)
        current_cpus="$HOST_CORES"
      else
        # Convert nanocpus to whole CPUs (1 CPU = 1000000000 nanocpus)
        current_cpus=$((current_cpus / 1000000000))
      fi
      
      # Docker memory is in bytes
      local mem_bytes
      mem_bytes=$(docker inspect --format='{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
      if [[ "$mem_bytes" == "0" ]]; then
        # No limit set, use system default
        current_ram_mb="$HOST_RAM_MB"
      else
        current_ram_mb=$((mem_bytes / 1024 / 1024))
      fi
    else
      # Podman
      current_cpus=$(podman inspect --format='{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
      if [[ "$current_cpus" == "0" ]]; then
        current_cpus="$HOST_CORES"
      else
        current_cpus=$((current_cpus / 1000000000))
      fi
      
      local mem_bytes
      mem_bytes=$(podman inspect --format='{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null || echo "0")
      if [[ "$mem_bytes" == "0" ]]; then
        current_ram_mb="$HOST_RAM_MB"
      else
        current_ram_mb=$((mem_bytes / 1024 / 1024))
      fi
    fi

    detect_host_resources_container

    # Prompt user to confirm or change resources
    local banner="Host: ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Reserve kept: ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB
Available for sync: ${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Current container configuration: ${current_cpus} CPUs, ${current_ram_mb} MiB RAM
(Container is currently running - can update on-the-fly)"

    local new_cpus new_ram_mb
    new_cpus=$(whiptail --title "Sync CPUs" --inputbox \
      "$banner\n\nEnter CPUs for this sync session:" \
      19 78 "${current_cpus}" 3>&1 1>&2 2>&3) || return 1
    [[ "$new_cpus" =~ ^[0-9]+$ ]] || die "CPUs must be a positive integer."
    [[ "$new_cpus" -ge 1 ]] || die "CPUs must be at least 1."
    (( new_cpus <= AVAIL_CORES )) || die "Requested CPUs ($new_cpus) exceeds available after reserve (${AVAIL_CORES})."

    new_ram_mb=$(whiptail --title "Sync RAM (MiB)" --inputbox \
      "$banner\n\nEnter RAM (MiB) for this sync session:" \
      19 78 "${current_ram_mb}" 3>&1 1>&2 2>&3) || return 1
    [[ "$new_ram_mb" =~ ^[0-9]+$ ]] || die "RAM must be a positive integer."
    [[ "$new_ram_mb" -ge 2048 ]] || die "RAM must be at least 2048 MiB."
    (( new_ram_mb <= AVAIL_RAM_MB )) || die "Requested RAM (${new_ram_mb} MiB) exceeds available after reserve (${AVAIL_RAM_MB} MiB)."

    # Update container resources if they changed (on-the-fly, no restart needed)
    if [[ "$new_cpus" != "$current_cpus" ]] || [[ "$new_ram_mb" != "$current_ram_mb" ]]; then
      echo "Updating container resources (no restart needed)..."
      # Docker requires memory-swap to be >= memory, set equal to disable swap usage
      if ! container_cmd update --cpus="$new_cpus" --memory="${new_ram_mb}m" --memory-swap="${new_ram_mb}m" "$CONTAINER_NAME" 2>/tmp/container_update_error.log; then
        local error_msg
        error_msg=$(cat /tmp/container_update_error.log 2>/dev/null || echo "Unknown error")
        rm -f /tmp/container_update_error.log
        die "Failed to update container resources.\n\nError: $error_msg"
      fi
      rm -f /tmp/container_update_error.log
      echo "✅ Resources updated: ${new_cpus} CPUs, ${new_ram_mb} MiB RAM"
      sleep 1
    fi
  else
    # Container is stopped - prompt for resource configuration before starting
    echo "Container is stopped."
    echo ""
    
    detect_host_resources_container

    local banner="Host: ${HOST_CORES} cores, ${HOST_RAM_MB} MiB
Reserve kept: ${RESERVE_CORES} cores, ${RESERVE_RAM_MB} MiB
Available for sync: ${AVAIL_CORES} cores, ${AVAIL_RAM_MB} MiB

Suggested for initial sync: ${HOST_SUGGEST_SYNC_VCPUS} CPUs, ${HOST_SUGGEST_SYNC_RAM_MB} MiB RAM"

    local sync_cpus sync_ram_mb
    sync_cpus=$(whiptail --title "Sync CPUs" --inputbox \
      "$banner\n\nEnter CPUs for this sync session:" \
      18 78 "${HOST_SUGGEST_SYNC_VCPUS}" 3>&1 1>&2 2>&3) || return 1
    [[ "$sync_cpus" =~ ^[0-9]+$ ]] || die "CPUs must be a positive integer."
    [[ "$sync_cpus" -ge 1 ]] || die "CPUs must be at least 1."
    (( sync_cpus <= AVAIL_CORES )) || die "Requested CPUs ($sync_cpus) exceeds available after reserve (${AVAIL_CORES})."

    sync_ram_mb=$(whiptail --title "Sync RAM (MiB)" --inputbox \
      "$banner\n\nEnter RAM (MiB) for this sync session:" \
      18 78 "${HOST_SUGGEST_SYNC_RAM_MB}" 3>&1 1>&2 2>&3) || return 1
    [[ "$sync_ram_mb" =~ ^[0-9]+$ ]] || die "RAM must be a positive integer."
    [[ "$sync_ram_mb" -ge 2048 ]] || die "RAM must be at least 2048 MiB."
    (( sync_ram_mb <= AVAIL_RAM_MB )) || die "Requested RAM (${sync_ram_mb} MiB) exceeds available after reserve (${AVAIL_RAM_MB} MiB)."

    # Start container with configured resources
    echo "Starting container with ${sync_cpus} CPUs, ${sync_ram_mb} MiB RAM..."
    container_cmd start "$CONTAINER_NAME" >/dev/null 2>&1 || die "Failed to start container"
    
    # Update resources after starting (memory-swap = memory to disable swap)
    if ! container_cmd update --cpus="$sync_cpus" --memory="${sync_ram_mb}m" --memory-swap="${sync_ram_mb}m" "$CONTAINER_NAME" 2>/tmp/container_update_error.log; then
      local error_msg
      error_msg=$(cat /tmp/container_update_error.log 2>/dev/null || echo "Unknown error")
      rm -f /tmp/container_update_error.log
      die "Failed to update container resources.\n\nError: $error_msg"
    fi
    rm -f /tmp/container_update_error.log
    
    sleep 5
  fi
  
  echo ""
  echo "=========================================="
  echo "Monitoring Container IBD Progress"
  echo "Press 'q' to exit (container keeps running)"
  echo "=========================================="
  echo ""
  
  # Track stale tip detection
  local stale_tip_detected=false
  local stale_tip_wait_start=0
  local stale_tip_initial_blocks=0
  local wait_count=0
  local max_wait=12  # Wait up to 60 seconds (12 * 5 seconds)
  
  while true; do
    # Get blockchain info from container
    local info
    info=$(container_exec "$CONTAINER_NAME" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null || echo "{}")
    
    if [[ "$info" == "{}" ]]; then
      # Check if bitcoind is actually running in the container
      local bitcoind_status
      bitcoind_status=$(container_exec "$CONTAINER_NAME" sh -c 'pgrep -f bitcoind >/dev/null && echo "running" || echo "not running"' 2>/dev/null || echo "unknown")
      
      local tor_status
      tor_status=$(container_exec "$CONTAINER_NAME" sh -c 'pgrep -f tor >/dev/null && echo "running" || echo "not running"' 2>/dev/null || echo "unknown")
      
      wait_count=$((wait_count + 1))
      
      # Display diagnostic info
      clear
      printf "╔════════════════════════════════════════════════════════════════════════════════╗\n"
      printf "║%-80s║\n" "                    Garbageman IBD Monitor - Starting"
      printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Container Status:"
      printf "║%-80s║\n" "    Name:  ${CONTAINER_NAME}"
      printf "║%-80s║\n" "    Image: ${CONTAINER_IMAGE}"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Service Status:"
      printf "║%-80s║\n" "    Bitcoin: ${bitcoind_status}"
      printf "║%-80s║\n" "    Tor:     ${tor_status}"
      printf "║%-80s║\n" ""
      
      if [[ "$bitcoind_status" == "not running" ]]; then
        printf "║%-80s║\n" "  ⚠ Problem Detected:"
        printf "║%-80s║\n" "    Bitcoin daemon is not running!"
        printf "║%-80s║\n" ""
        printf "║%-80s║\n" "  This usually means there was a problem during import or startup."
        printf "║%-80s║\n" "  Try deleting and re-creating the container."
      else
        printf "║%-80s║\n" "     Waiting for Bitcoin daemon to initialize... ($wait_count/$max_wait)"
        printf "║%-80s║\n" "     (This can take 1-2 minutes on first start)"
      fi
      
      printf "║%-80s║\n" ""
      printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
      printf "║%-80s║\n" "  Auto-refreshing every ${POLL_SECS} seconds... Press 'q' to exit"
      printf "╚════════════════════════════════════════════════════════════════════════════════╝\n"
      
      if [[ $wait_count -ge $max_wait ]]; then
        echo ""
        echo "❌ bitcoind is not responding after $((max_wait * POLL_SECS)) seconds"
        echo ""
        pause "bitcoind not responding. Check the diagnostics above for details."
        return 1
      fi
      
      # Check for 'q' key press
      if read -t "$POLL_SECS" -n 1 key 2>/dev/null && [[ "$key" == "q" ]]; then
        echo ""
        echo "Exiting monitor. Container will continue running in background."
        return
      fi
      continue
    fi
    
    # Parse blockchain info
    local blocks headers progress ibd peers
    blocks=$(echo "$info" | jq -r '.blocks // 0' 2>/dev/null || echo "0")
    headers=$(echo "$info" | jq -r '.headers // 0' 2>/dev/null || echo "0")
    progress=$(echo "$info" | jq -r '.verificationprogress // 0' 2>/dev/null || echo "0")
    ibd=$(echo "$info" | jq -r '.initialblockdownload // true' 2>/dev/null || echo "true")
    
    # Get peer count
    peers=$(container_exec "$CONTAINER_NAME" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getconnectioncount 2>/dev/null || echo "0")
    
    # Calculate percentage
    local pct
    pct=$(awk -v p="$progress" 'BEGIN{if(p<0)p=0;if(p>1)p=1;printf "%d", int(p*100+0.5)}')
    
    # Get detailed peer breakdown with categorization
    local peer_breakdown
    peer_breakdown=$(get_peer_breakdown_container "$CONTAINER_NAME")
    
    # Get node classification
    local node_classification
    node_classification=$(get_node_classification_container "$CONTAINER_NAME")
    
    # Check for stale tip
    local current_time=$(date +%s)
    local time_block
    time_block=$(echo "$info" | jq -r '.time // 0' 2>/dev/null || echo "0")
    local block_age_seconds=$((current_time - time_block))
    local block_age_hours=$((block_age_seconds / 3600))
    local is_stale=false
    
    if [[ "$blocks" -gt 0 && "$time_block" -gt 0 && "$block_age_seconds" -gt 7200 ]]; then
      is_stale=true
    fi
    
    # Handle stale tip detection - match VM logic for waiting and progress tracking
    local sync_status_msg=""
    if [[ "$is_stale" == "true" && "$stale_tip_detected" == "false" ]]; then
      # Just detected stale tip - start waiting period
      stale_tip_detected=true
      stale_tip_wait_start=$current_time
      stale_tip_initial_blocks=$blocks
      sync_status_msg="Stale tip detected (${block_age_hours}h old). Waiting for peers to sync..."
    elif [[ "$stale_tip_detected" == "true" ]]; then
      # We're in a waiting period for stale tip
      local wait_elapsed=$((current_time - stale_tip_wait_start))
      local wait_remaining=$((120 - wait_elapsed))
      
      # Check if blocks have increased (catching up)
      if [[ "$blocks" -gt "$stale_tip_initial_blocks" ]]; then
        # Blocks are advancing - check if we're caught up
        if [[ "$is_stale" == "false" ]]; then
          # Tip is no longer stale, we've caught up to recent blocks
          stale_tip_detected=false
          sync_status_msg="Caught up to current tip"
        else
          # Still catching up to current (tip still >2h old means more blocks to sync)
          sync_status_msg="Syncing new blocks (was ${block_age_hours}h behind)..."
        fi
      elif [[ "$wait_elapsed" -lt 120 ]]; then
        # Still waiting for peers and updates (up to 2 minutes)
        sync_status_msg="Waiting for sync (${wait_remaining}s left, ${peers} peers connected)..."
      else
        # Waited 2 minutes and no progress
        # Check if tip is still stale - if not, we can clear the flag
        if [[ "$is_stale" == "false" ]]; then
          # Tip is no longer stale (somehow caught up), clear flag
          stale_tip_detected=false
          sync_status_msg="Synced to current tip"
        else
          # Still stale, keep waiting indefinitely (don't mark as complete until truly synced)
          sync_status_msg="Stale tip (${block_age_hours}h old), waiting for peers (${peers} connected)..."
        fi
      fi
    fi
    
    # Display status with matching format
    clear
    printf "╔════════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║%-80s║\n" "                    Garbageman IBD Monitor - ${pct}% Complete"
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Host Resources:"
    printf "║%-80s║\n" "    Cores: ${HOST_CORES} total | ${RESERVE_CORES} reserved | ${AVAIL_CORES} available"
    printf "║%-80s║\n" "    RAM:   ${HOST_RAM_MB} MiB total | ${RESERVE_RAM_MB} MiB reserved | ${AVAIL_RAM_MB} MiB available"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Container Status:"
    printf "║%-80s║\n" "    Name:  ${CONTAINER_NAME}"
    printf "║%-80s║\n" "    Image: ${CONTAINER_IMAGE}"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Bitcoin Sync Status:"
    if [[ -n "$node_classification" ]]; then
      printf "║%-80s║\n" "    Node Type:  $node_classification"
    else
      printf "║%-80s║\n" "    Node Type:  Starting..."
    fi
    printf "║%-80s║\n" "    Blocks:     ${blocks} / ${headers}"
    printf "║%-80s║\n" "    Progress:   ${pct}% (${progress})"
    printf "║%-80s║\n" "    IBD:        ${ibd}"
    printf "║%-80s║\n" "    Peers:      ${peer_breakdown}"
    if [[ -n "$sync_status_msg" ]]; then
      printf "║%-80s║\n" "    Status:     ${sync_status_msg}"
    fi
    printf "║%-80s║\n" ""
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" "  Auto-refreshing every ${POLL_SECS} seconds... Press 'q' to exit"
    printf "╚════════════════════════════════════════════════════════════════════════════════╝\n"
    
    # Check if sync is complete - match VM logic for stale tip handling
    local should_complete=false
    if [[ "$ibd" == "false" ]] || [[ "$blocks" -ge "$headers" && "$headers" -gt 0 && "$pct" -ge 99 ]]; then
      # Basic completion conditions met, but check stale tip status
      if [[ "$stale_tip_detected" == "false" ]]; then
        # No stale tip detected or we've finished waiting - OK to complete
        should_complete=true
      elif [[ "$blocks" -ge "$headers" && "$pct" -ge 99 && "$blocks" -gt "$stale_tip_initial_blocks" ]]; then
        # Stale tip was detected AND blocks have advanced past initial AND caught up to headers - complete
        should_complete=true
      elif [[ "$blocks" -gt "$stale_tip_initial_blocks" ]]; then
        # Stale tip was detected and blocks are still advancing - keep waiting
        should_complete=false
      else
        # Stale tip detected, no progress yet - keep waiting (no timeout)
        should_complete=false
      fi
    fi
    
    if [[ "$should_complete" == "true" ]]; then
      # Clear screen before showing completion message
      clear
      echo ""
      echo "╔════════════════════════════════════════════════════════════════════════════════╗"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "                    INITIAL BLOCK DOWNLOAD COMPLETE!"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Your base container (gm-base) is now fully synced with the Bitcoin network."
      printf "║%-80s║\n" ""
      echo "╚════════════════════════════════════════════════════════════════════════════════╝"
      echo ""
      
      echo "Stopping container to resize to runtime defaults..."
      echo ""
      
      # Stop container gracefully
      container_cmd stop "$CONTAINER_NAME" 2>/dev/null || true
      
      # Wait up to 3 minutes for graceful shutdown (bitcoind can take time to flush)
      echo "Waiting for container to stop (this may take up to 3 minutes)..."
      local shutdown_wait=0
      while [[ $shutdown_wait -lt 180 ]]; do
        local state=$(container_state "$CONTAINER_NAME")
        if [[ "$state" != "up" ]]; then
          echo "✓ Container stopped gracefully"
          break
        fi
        sleep 5
        shutdown_wait=$((shutdown_wait + 5))
        if [[ $((shutdown_wait % 30)) -eq 0 ]]; then
          echo "  Still waiting... (${shutdown_wait}s elapsed)"
        fi
      done
      
      # Force stop if still running
      if [[ "$(container_state "$CONTAINER_NAME")" == "up" ]]; then
        echo ""
        echo "⚠ Graceful shutdown timed out after 3 minutes"
        echo "Force stopping container..."
        container_cmd kill "$CONTAINER_NAME" 2>/dev/null || true
        sleep 2
        if [[ "$(container_state "$CONTAINER_NAME")" != "up" ]]; then
          echo "✓ Container force stopped"
        else
          echo "✗ Failed to stop container. Please check with 'docker ps -a'"
          read -p "Press Enter to return to main menu..."
          return
        fi
      fi
      
      # Resize to runtime defaults
      echo ""
      echo "Resizing container to runtime defaults (${VM_VCPUS} CPUs, ${VM_RAM_MB} MiB RAM)..."
      container_cmd update \
        --cpus="${VM_VCPUS}" \
        --memory="${VM_RAM_MB}m" \
        --memory-swap="${VM_RAM_MB}m" \
        "$CONTAINER_NAME" 2>/dev/null || true
      echo "✓ Container resized successfully"
      
      # Clear screen and show final message
      clear
      echo ""
      echo "╔════════════════════════════════════════════════════════════════════════════════╗"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "                    CONTAINER READY FOR CLONING!"
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  The base container has been stopped and resized to runtime defaults."
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Next steps:"
      printf "║%-80s║\n" "    - Choose 'Clone Container(s) from Base' from the main menu"
      printf "║%-80s║\n" "    - Each clone will have the full blockchain and unique .onion address"
      printf "║%-80s║\n" "    - Clones are Tor-only for maximum privacy"
      printf "║%-80s║\n" ""
      echo "╚════════════════════════════════════════════════════════════════════════════════╝"
      echo ""
      read -p "Press Enter to return to main menu..."
      clear
      return
    fi
    
    # Use read with timeout - check if user pressed 'q' to exit early
    read -t "$POLL_SECS" -n 1 key 2>/dev/null || true
    if [[ "$key" == "q" || "$key" == "Q" ]]; then
      clear
      echo ""
      echo "Monitor stopped. Container is still running."
      sleep 1
      return
    fi
  done
  
  return
}

# cleanup_orphaned_volumes: Find and remove volumes not used by any container
# Purpose: Clean up leftover volumes from failed clones or partial operations
cleanup_orphaned_volumes(){
  echo ""
  echo "Scanning for orphaned volumes..."
  echo ""
  
  # Get all volumes that match our naming pattern
  local all_volumes
  all_volumes=$(container_cmd volume ls -q | grep -E "^(garbageman-data|gm-clone-.*-data)$" || true)
  
  if [[ -z "$all_volumes" ]]; then
    pause "No garbageman volumes found."
    return
  fi
  
  # Get all containers (including stopped ones)
  local all_containers
  all_containers=$(container_cmd ps -a --format '{{.Names}}' || true)
  
  # Check each volume to see if it's attached to a container
  local orphaned_volumes=()
  while IFS= read -r vol; do
    [[ -z "$vol" ]] && continue
    
    # Check if any container uses this volume
    local in_use=false
    while IFS= read -r container_name; do
      [[ -z "$container_name" ]] && continue
      local mounts
      mounts=$(container_cmd inspect "$container_name" 2>/dev/null | jq -r '.[0].Mounts[].Name // empty' 2>/dev/null || true)
      if echo "$mounts" | grep -q "^${vol}$"; then
        in_use=true
        break
      fi
    done <<< "$all_containers"
    
    if [[ "$in_use" == "false" ]]; then
      orphaned_volumes+=("$vol")
    fi
  done <<< "$all_volumes"
  
  if [[ ${#orphaned_volumes[@]} -eq 0 ]]; then
    pause "No orphaned volumes found. All volumes are in use."
    return
  fi
  
  # Show orphaned volumes
  echo "Found ${#orphaned_volumes[@]} orphaned volume(s):"
  echo ""
  for vol in "${orphaned_volumes[@]}"; do
    local size
    size=$(container_cmd system df -v 2>/dev/null | grep "$vol" | awk '{print $3}' || echo "unknown")
    echo "  • $vol (size: $size)"
  done
  echo ""
  
  if whiptail --title "Clean Up Orphaned Volumes" --yesno \
    "Remove ${#orphaned_volumes[@]} orphaned volume(s)?\n\n⚠️  This will permanently delete the data.\n\nProceed?" 12 78; then
    
    echo ""
    echo "Removing orphaned volumes..."
    for vol in "${orphaned_volumes[@]}"; do
      echo "  Removing: $vol"
      container_cmd volume rm "$vol" 2>/dev/null || echo "    ⚠️  Failed to remove $vol"
    done
    echo ""
    pause "Cleanup complete."
  fi
}

# manage_base_container: Quick controls for base container
# Purpose: Start/stop/status/export/delete menu for base container
# Features:
#   - Start/stop with graceful 180s shutdown timeout
#   - Live status monitor (auto-refreshing, shows IPv4 if clearnet enabled)
#   - Export to modular format
#   - Cleanup orphaned volumes
#   - Delete with two-step confirmation (yes/no + type container name)
# Actions:
#   - 1: Start Container
#   - 2: Stop Container gracefully (180s timeout)
#   - 3: Check Status - live monitor with auto-refresh
#   - 4: Export Container for transfer
#   - 5: Clean Up Orphaned Volumes
#   - 6: Delete Container permanently (requires two-step confirmation)
#   - 7: Return to main menu
# Similar to quick_control() but for containers
manage_base_container(){
  while true; do
    if ! container_exists "$CONTAINER_NAME"; then
      pause "Container '$CONTAINER_NAME' does not exist.\n\nCreate it first with 'Create Base Container'."
      return
    fi
    
    local state
    state=$(container_state "$CONTAINER_NAME")
    
    # Get additional info if running
    local info_text=""
    if [[ "$state" == "up" ]]; then
      local ip blocks onion
      ip=$(container_ip "$CONTAINER_NAME" || echo "N/A")
      blocks=$(container_exec "$CONTAINER_NAME" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount 2>/dev/null || echo "N/A")
      onion=$(container_exec "$CONTAINER_NAME" cat /var/lib/tor/bitcoin-service/hostname 2>/dev/null || echo "generating...")
      
      info_text="\nRunning info:
  IP: $ip
  Blocks: $blocks
  Onion: $onion"
    fi
    
    local choice
    choice=$(whiptail --title "Manage Container: $CONTAINER_NAME" --menu \
      "Container state: $state$info_text\n\nChoose an action:" 22 78 7 \
      1 "Start Container" \
      2 "Stop Container (graceful)" \
      3 "Check Status (live monitor)" \
      4 "Export Container (for transfer)" \
      5 "Clean Up Orphaned Volumes" \
      6 "Delete Container (permanent)" \
      7 "Back to Main Menu" \
      3>&1 1>&2 2>&3) || return
    
    case "$choice" in
      1)
        if [[ "$state" == "up" ]]; then
          pause "Container is already running."
        else
          echo "Starting container..."
          if container_cmd start "$CONTAINER_NAME"; then
            sleep 2
            pause "Container started successfully."
          else
            pause "Failed to start container."
          fi
        fi
        ;;
        
      2)
        if [[ "$state" != "up" ]]; then
          pause "Container is not running."
        else
          echo "Stopping container (graceful shutdown, may take up to 3 minutes)..."
          if container_cmd stop --time=180 "$CONTAINER_NAME"; then
            pause "Container stopped successfully."
          else
            pause "Failed to stop container."
          fi
        fi
        ;;
        
      3)
        monitor_container_status "$CONTAINER_NAME"
        ;;
        
      4)
        export_base_container
        ;;
      
      5)
        cleanup_orphaned_volumes
        ;;
        
      6)
        if whiptail --title "Confirm Deletion" --yesno \
          "Are you SURE you want to PERMANENTLY DELETE '$CONTAINER_NAME'?\n\n⚠️  WARNING: This action is IRREVERSIBLE!\n\nThis will:\n• Stop and remove the container\n• Remove the container image\n• Delete all blockchain data\n• Clean up dangling build layers\n\nProceed to confirmation step?" 17 78; then
          
          # Secondary confirmation - require typing container name
          local confirm_name
          confirm_name=$(whiptail --inputbox "Type the exact container name to confirm deletion:\n\nContainer name: ${CONTAINER_NAME}" 12 78 3>&1 1>&2 2>&3)
          
          if [[ "$confirm_name" == "$CONTAINER_NAME" ]]; then
            echo "Deleting container..."
            container_cmd stop --time=180 "$CONTAINER_NAME" 2>/dev/null || true
            container_cmd rm -f "$CONTAINER_NAME" 2>/dev/null || true
            
            echo "Removing image..."
            container_cmd rmi -f "$CONTAINER_IMAGE" 2>/dev/null || true
            
            echo "Removing data volume..."
            container_cmd volume rm garbageman-data 2>/dev/null || true
            
            echo "Cleaning up dangling images and build cache..."
            container_cmd image prune -f 2>/dev/null || true
            if [[ "$(container_runtime)" == "docker" ]]; then
              container_cmd builder prune -f 2>/dev/null || true
            fi
            
            pause "Container and build cache deleted successfully."
            return
          else
            pause "Deletion cancelled - container name did not match."
          fi
        else
          pause "Deletion cancelled."
        fi
        ;;
        
      7)
        return
        ;;
    esac
  done
}

# clone_container_menu: Create Tor-only container clones with blockchain data copy
# Purpose: Clone base container with fresh Tor identity and full blockchain data
# Flow:
#   1. Ensure base container exists
#   2. Stop base container if running (ensures consistent data during clone)
#   3. Prompt for number of clones with capacity-aware suggestions (CPU/RAM/Disk)
#   4. For each clone:
#      a. Copy blockchain data from base volume to new volume
#      b. Prepare Tor-only bitcoin.conf (overrides base configuration)
#      c. Inject bitcoin.conf into clone volume at /var/lib/bitcoin/bitcoin.conf
#      d. Create container with command override to use volume-based config
#      e. Generate fresh Tor hidden service keys
#      f. Clear peer databases for fresh discovery
#   5. Restart base container if it was running before cloning
# Note: Each clone gets unique .onion address, independent peer discovery, Tor-only networking
#       Clones start with full blockchain (no IBD needed) but fresh network identity
#       All clones use volume-based config (consistent with imports/from-scratch)
clone_container_menu(){
  ensure_tools
  
  if ! container_exists "$CONTAINER_NAME"; then
    die "Base container '$CONTAINER_NAME' not found.\n\nCreate it first with 'Create Base Container'."
  fi
  
  detect_host_resources
  
  # Use same resource allocation as VMs for consistency
  # Users can adjust via "Configure Defaults" if needed
  local container_vcpus=$VM_VCPUS
  local container_ram_mb=$VM_RAM_MB
  
  # Calculate suggested clones accounting for container overhead
  # Containers have ~150MB overhead (Docker daemon, networking, etc.)
  local cpu_capacity=0 mem_capacity=0 disk_capacity=0 total_capacity=0
  if (( container_vcpus > 0 )); then
    cpu_capacity=$((AVAIL_CORES / container_vcpus))
  fi
  
  # Account for container overhead in memory calculation
  local container_overhead_mb=150
  local effective_ram_per_container=$((container_ram_mb + container_overhead_mb))
  if (( effective_ram_per_container > 0 )); then
    mem_capacity=$((AVAIL_RAM_MB / effective_ram_per_container))
  fi
  
  # Calculate disk capacity
  if (( CONTAINER_DISK_SPACE_GB > 0 )); then
    disk_capacity=$((AVAIL_DISK_GB / CONTAINER_DISK_SPACE_GB))
  fi
  
  # Take minimum of CPU, RAM, and Disk capacity
  total_capacity="$cpu_capacity"
  (( mem_capacity < total_capacity )) && total_capacity="$mem_capacity"
  (( disk_capacity < total_capacity )) && total_capacity="$disk_capacity"
  (( total_capacity < 0 )) && total_capacity=0
  
  # Determine limiting resource for user feedback
  local limiting_resource="CPU"
  (( mem_capacity == total_capacity )) && limiting_resource="RAM"
  (( disk_capacity == total_capacity )) && limiting_resource="Disk"
  
  local suggested=$((total_capacity > 1 ? total_capacity - 1 : 0))
  (( suggested > 100 )) && suggested=100  # Practical limit
  
  local prompt="How many container clones to create?

Host: ${HOST_CORES} cores / ${HOST_RAM_MB}MB / ${HOST_DISK_GB}GB   |   Reserve: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB}MB / ${RESERVE_DISK_GB}GB
Available after reserve: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB}MB / ${AVAIL_DISK_GB}GB

Per container: ${container_vcpus} CPU(s), ${container_ram_mb}MB RAM, ${CONTAINER_DISK_SPACE_GB}GB disk
Capacity: ${cpu_capacity} containers (CPU), ${mem_capacity} containers (RAM), ${disk_capacity} containers (Disk) - limited by ${limiting_resource}
Suggested clones: ${suggested}

Enter number of clones (or 0 to cancel):"
  
  local n
  n=$(whiptail --inputbox "$prompt" 22 78 "$suggested" 3>&1 1>&2 2>&3) || return
  [[ "$n" =~ ^[0-9]+$ ]] || { pause "Invalid number."; return; }
  [[ "$n" -eq 0 ]] && return
  
  # === CRITICAL: Stop base container before cloning ===
  # This ensures consistent data state during clone creation
  # Similar to VM cloning which requires source VM to be shut off
  local base_was_running=false
  local base_state
  base_state=$(container_state "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
  
  if [[ "$base_state" == "running" ]]; then
    base_was_running=true
    echo ""
    echo "Base container '$CONTAINER_NAME' is currently running."
    echo "Stopping it now to ensure consistent cloning..."
    echo "This may take up to 1 minute for bitcoind to close cleanly."
    echo ""
    
    # Stop gracefully (allows bitcoind to flush databases)
    container_cmd stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    
    # Wait up to 60 seconds for graceful stop
    local timeout=60
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
      base_state=$(container_state "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
      [[ "$base_state" != "running" ]] && break
      sleep 2
      elapsed=$((elapsed + 2))
    done
    
    # Force stop if still running after timeout
    base_state=$(container_state "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    if [[ "$base_state" == "running" ]]; then
      echo "Graceful stop timed out. Forcing stop..."
      container_cmd kill "$CONTAINER_NAME" >/dev/null 2>&1 || true
      sleep 2
    fi
    
    echo "Base container stopped successfully."
    echo ""
  fi
  
  echo ""
  echo "Creating $n container clone(s)..."
  echo ""
  
  for ((i=1; i<=n; i++)); do
    # Generate base name with timestamp (format: gm-clone-YYYYMMDD-HHMMSS)
    local base_name="${CONTAINER_CLONE_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    local clone_name="$base_name"
    
    # Check for name collision (rare, but possible if creating multiple clones per second)
    # Add numeric suffix (-2, -3, etc.) to ensure uniqueness
    local suffix=2
    while container_exists "$clone_name"; do
      clone_name="${base_name}-${suffix}"
      ((suffix++))
    done
    
    echo "[$i/$n] Creating clone: $clone_name"
    
    # === Step 1: Copy blockchain data from base container's volume ===
    # Create new volume and copy all blockchain data (matching VM clone behavior)
    echo "  • Copying blockchain data from base container..."
    
    # Create a temporary container to copy data between volumes
    # We use the same image and mount both volumes to copy data
    local temp_copy_container="${clone_name}-copy-temp"
    
    if ! container_cmd run --rm \
      -v garbageman-data:/source:ro \
      -v "${clone_name}-data:/dest" \
      --name "$temp_copy_container" \
      alpine:3.18 \
      sh -c "cp -a /source/. /dest/" 2>/dev/null; then
      echo "  ❌ Failed to copy blockchain data for $clone_name"
      # Clean up the volume that was created
      container_cmd volume rm "${clone_name}-data" 2>/dev/null || true
      continue
    fi
    
    echo "  • Blockchain data copied successfully"
    
    # === Step 2: Prepare Tor-only bitcoin.conf ===
    # All clones are Tor-only regardless of base configuration
    # This ensures privacy-preserving operation
    local temp_config_file="/tmp/${clone_name}-bitcoin.conf"
    cat > "$temp_config_file" <<'BTCCONF'
server=1
prune=750
dbcache=256
maxconnections=12
onlynet=onion
proxy=127.0.0.1:9050
listen=1
bind=0.0.0.0
listenonion=1
discover=0
dnsseed=0
torcontrol=127.0.0.1:9051
[main]
BTCCONF
    
    # === Step 3: Inject bitcoin.conf into clone volume ===
    # Write config to volume (mutable) rather than image (immutable)
    # This matches the import function's approach
    if ! container_cmd run --rm \
      -v "${clone_name}-data:/var/lib/bitcoin" \
      -v "$temp_config_file:/tmp/bitcoin.conf:ro" \
      alpine:3.18 \
      sh -c "cp /tmp/bitcoin.conf /var/lib/bitcoin/bitcoin.conf && chmod 644 /var/lib/bitcoin/bitcoin.conf" 2>/dev/null; then
      echo "  ⚠️  Warning: Failed to inject bitcoin.conf for $clone_name (will use image default)"
    fi
    rm -f "$temp_config_file"
    
    # === Step 4: Create container with command override ===
    # Override CMD to use volume-based config (like imports do)
    # Container will use the cloned blockchain data and volume-based config
    if ! container_cmd create \
      --name "$clone_name" \
      --cpus="${container_vcpus}.0" \
      --memory="${container_ram_mb}m" \
      -v "${clone_name}-data:/var/lib/bitcoin" \
      --restart unless-stopped \
      "$CONTAINER_IMAGE" \
      bitcoind -conf=/var/lib/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin >/dev/null 2>&1; then
      echo "  ❌ Failed to create $clone_name"
      # Clean up the volume since container creation failed
      container_cmd volume rm "${clone_name}-data" 2>/dev/null || true
      continue
    fi
    
    # === Step 5: Start container to initialize and clean ===
    container_cmd start "$clone_name" >/dev/null 2>&1 || true
    sleep 3  # Give container time to initialize
    
    # === Step 6: Remove old Tor hidden service keys ===
    # This forces generation of a fresh .onion v3 address on next boot
    # Critical for privacy: each clone must have unique Tor identity
    container_cmd exec "$clone_name" sh -c "rm -rf /var/lib/tor/bitcoin-service/*" 2>/dev/null || true
    
    # === Step 7: Clear peer databases for independent peer discovery ===
    # This prevents all clones from clustering around the same peer set
    # Each clone will discover its own independent set of Tor peers
    container_cmd exec "$clone_name" sh -c "rm -f /var/lib/bitcoin/peers.dat" 2>/dev/null || true
    container_cmd exec "$clone_name" sh -c "rm -f /var/lib/bitcoin/anchors.dat" 2>/dev/null || true
    container_cmd exec "$clone_name" sh -c "rm -f /var/lib/bitcoin/banlist.dat" 2>/dev/null || true
    
    # === Step 8: Stop clone (leave it stopped like VM clones) ===
    # Clone is ready but not running - user must start it manually
    # This matches VM behavior: clones are created in stopped state
    container_cmd stop "$clone_name" >/dev/null 2>&1 || true
    sleep 2
    
    echo "  ✓ Clone created: $clone_name (stopped)"
    sleep 1
  done
  
  # === Step 9: Restart base container if it was running ===
  if [[ "$base_was_running" == true ]]; then
    echo ""
    echo "Restarting base container '$CONTAINER_NAME'..."
    container_cmd start "$CONTAINER_NAME" >/dev/null 2>&1 || true
    sleep 2
    echo "Base container restarted."
  fi
  
  echo ""
  pause "$n container clone(s) created successfully!\n\nEach clone has:\n• Unique Tor onion address\n• Tor-only networking\n• Independent peer discovery\n• Cleared peer databases\n• ${container_vcpus} CPU(s), ${container_ram_mb}MB RAM"
}

# container_management_menu: Manage individual container clones
# Purpose: List and manage container clones
# Similar to clone_management_menu() but for containers
container_management_menu(){
  while true; do
    # List all containers matching prefix
    local clones
    clones=$(container_cmd ps -a --format '{{.Names}}' | grep "^${CONTAINER_CLONE_PREFIX}" | sort || true)
    
    if [[ -z "$clones" ]]; then
      pause "No container clones found.\n\nCreate clones with 'Create Clone Containers'."
      return
    fi
    
    # Build menu items
    local menu_items=()
    while IFS= read -r clone_name; do
      local state
      state=$(container_state "$clone_name")
      menu_items+=("$clone_name" "State: $state")
    done <<< "$clones"
    
    # Add back option
    menu_items+=("back" "Return to main menu")
    
    local choice
    choice=$(whiptail --title "Manage Container Clones" --menu \
      "Select a container clone to manage:" 20 78 10 \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3) || return
    
    [[ "$choice" == "back" ]] && return
    
    # Manage selected clone
    manage_container_clone "$choice"
  done
}

# monitor_container_status: Live monitoring display for container (base or clone)
# Purpose: Show real-time status with auto-refresh (container version of monitor_vm_status)
# Args: $1 = container name to monitor
# Display: Auto-refreshing every 5 seconds, press 'q' to exit
# Shows: State, .onion address (from Tor hidden service), blocks/headers, peers, resources
#        IPv4 address (only for base container with CLEARNET_OK=yes)
# Network Detection:
#   - Tor: Checks multiple paths (/var/lib/tor/bitcoin-service/hostname, /hidden_service/hostname)
#   - IPv4: Detects from localaddresses or network reachability status
#   - Handles "starting" state while services initialize
monitor_container_status(){
  local container_name="$1"
  
  echo ""
  echo "=========================================="
  echo "Monitoring Container: $container_name"
  echo "Press 'q' to return to menu"
  echo "=========================================="
  echo ""
  
  while true; do
    local state onion blocks headers peers ibd vp pct
    
    # Get container state
    state=$(container_state "$container_name" 2>/dev/null || echo "unknown")
    
    # If running, get network info
    if [[ "$state" == "up" ]]; then
      # Get .onion address - try multiple possible paths
      onion=$(container_exec "$container_name" cat /var/lib/tor/bitcoin-service/hostname 2>/dev/null || \
              container_exec "$container_name" cat /var/lib/tor/hidden_service/hostname 2>/dev/null || \
              echo "")
      
      # If onion is still empty, check if Tor is running
      if [[ -z "$onion" ]]; then
        local tor_status=$(container_exec "$container_name" pgrep tor >/dev/null 2>&1 && echo "starting" || echo "not running")
        onion="$tor_status"
      fi
      
      # Check if this is the base container and if clearnet is enabled
      local ipv4_address=""
      if [[ "$container_name" == "$CONTAINER_NAME" ]] && [[ "${CLEARNET_OK,,}" == "yes" ]]; then
        # Get network info first (we'll need it for both IPv4 detection and peer info)
        local netinfo
        netinfo=$(container_exec "$container_name" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null || echo "")
        
        # Try to get IPv4 from localaddresses in networkinfo
        ipv4_address=$(echo "$netinfo" | jq -r '.localaddresses[]? | select(.network=="ipv4") | .address' 2>/dev/null | head -n1 || echo "")
        
        # If that didn't work, check if we have outbound IPv4 connections (networks field)
        if [[ -z "$ipv4_address" ]]; then
          local has_ipv4=$(echo "$netinfo" | jq -r '.networks[]? | select(.name=="ipv4") | .reachable' 2>/dev/null || echo "false")
          if [[ "$has_ipv4" == "true" ]]; then
            ipv4_address="enabled (no public address)"
          else
            ipv4_address="not reachable"
          fi
        fi
      fi
      
      # Get blockchain info
      local info
      info=$(container_exec "$container_name" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null || echo "")
      blocks=$(jq -r '.blocks // "?"' <<<"$info" 2>/dev/null || echo "?")
      headers=$(jq -r '.headers // "?"' <<<"$info" 2>/dev/null || echo "?")
      vp=$(jq -r '.verificationprogress // 0' <<<"$info" 2>/dev/null || echo "0")
      ibd=$(jq -r '.initialblockdownload // "?"' <<<"$info" 2>/dev/null || echo "?")
      
      # Get network info (only if not already fetched for clearnet detection)
      if [[ -z "$netinfo" ]]; then
        local netinfo
        netinfo=$(container_exec "$container_name" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getnetworkinfo 2>/dev/null || echo "")
      fi
      peers=$(jq -r '.connections // "?"' <<<"$netinfo" 2>/dev/null || echo "?")
      
      # Get detailed peer breakdown
      local peer_breakdown=$(get_peer_breakdown_container "$container_name")
      
      # Get node classification
      local node_classification=$(get_node_classification_container "$container_name")
      
      # Calculate percentage
      pct=$(awk -v p="$vp" 'BEGIN{if(p<0)p=0;if(p>1)p=1;printf "%d", int(p*100+0.5)}')
    else
      onion="N/A"
      ipv4_address=""
      blocks="?"
      headers="?"
      peers="?"
      ibd="?"
      pct=0
      peer_breakdown="Container not running"
    fi
    
    # Get container resource limits
    local container_cpus container_mem
    local inspect_data
    inspect_data=$(container_cmd inspect "$container_name" 2>/dev/null || echo "")
    
    if [[ -n "$inspect_data" ]]; then
      # Extract CPU limit (NanoCpus / 1e9 = CPU count)
      local nano_cpus=$(jq -r '.[0].HostConfig.NanoCpus // 0' <<<"$inspect_data" 2>/dev/null || echo "0")
      if [[ "$nano_cpus" != "0" ]]; then
        container_cpus=$(awk -v n="$nano_cpus" 'BEGIN{printf "%.1f", n/1000000000}')
      else
        container_cpus="unlimited"
      fi
      
      # Extract memory limit (bytes to MiB)
      local mem_bytes=$(jq -r '.[0].HostConfig.Memory // 0' <<<"$inspect_data" 2>/dev/null || echo "0")
      if [[ "$mem_bytes" != "0" ]]; then
        container_mem=$((mem_bytes / 1048576))
      else
        container_mem="unlimited"
      fi
    else
      container_cpus="?"
      container_mem="?"
    fi
    
    detect_host_resources
    
    # Clear screen and display
    clear
    printf "╔════════════════════════════════════════════════════════════════════════════════╗\n"
    printf "║%-80s║\n" "                   Container Status Monitor - $container_name"
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Host Resources:"
    printf "║%-80s║\n" "    Cores: ${HOST_CORES} total | ${RESERVE_CORES} reserved | ${AVAIL_CORES} available"
    printf "║%-80s║\n" "    RAM:   ${HOST_RAM_MB} MiB total | ${RESERVE_RAM_MB} MiB reserved | ${AVAIL_RAM_MB} MiB available"
    printf "║%-80s║\n" ""
    printf "║%-80s║\n" "  Container Configuration:"
    printf "║%-80s║\n" "    Name:   $container_name"
    printf "║%-80s║\n" "    State:  $state"
    printf "║%-80s║\n" "    CPUs:   $container_cpus"
    printf "║%-80s║\n" "    RAM:    ${container_mem} MiB"
    printf "║%-80s║\n" ""
    
    if [[ "$state" == "up" ]]; then
      printf "║%-80s║\n" "  Network Status:"
      printf "║%-80s║\n" "    Tor:    $onion"
      if [[ -n "$ipv4_address" ]]; then
        printf "║%-80s║\n" "    IPv4:   $ipv4_address (clearnet enabled)"
      fi
      printf "║%-80s║\n" ""
      printf "║%-80s║\n" "  Bitcoin Status:"
      if [[ -n "$node_classification" ]]; then
        printf "║%-80s║\n" "    Node Type:  $node_classification"
      else
        printf "║%-80s║\n" "    Node Type:  Starting..."
      fi
      printf "║%-80s║\n" "    Blocks:     $blocks / $headers"
      printf "║%-80s║\n" "    Progress:   ${pct}% (${vp})"
      printf "║%-80s║\n" "    Peers:      $peer_breakdown"
      printf "║%-80s║\n" ""
    else
      printf "║%-80s║\n" "  Container is not running"
      printf "║%-80s║\n" ""
    fi
    
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" "  Auto-refreshing every 5 seconds... Press 'q' to exit"
    printf "╚════════════════════════════════════════════════════════════════════════════════╝\n"
    
    # Wait 5 seconds or exit on 'q' press
    # Note: read returns non-zero on timeout, which is expected behavior
    if read -t 5 -n 1 key 2>/dev/null; then
      # Key was pressed
      if [[ "$key" == "q" || "$key" == "Q" ]]; then
        clear
        echo ""
        echo "Monitor stopped."
        sleep 1
        return
      fi
    fi
    # If timeout (no key pressed), loop continues automatically
  done
}

# manage_container_clone: Manage individual container clone
# Args: $1 = clone container name
# Purpose: Interactive menu for controlling a specific container clone
# Features:
#   - Displays container state in menu header
#   - If running, shows .onion address, IPv4 (if clearnet), and block height
#   - Provides start/stop/status/delete actions
# Actions:
#   1. Start Container - Start the clone container
#   2. Stop Container (graceful) - Graceful shutdown with 180s timeout
#   3. Check Status - Show live monitoring (auto-refreshing every 5s)
#   4. Delete Container (permanent) - Remove container permanently (requires confirmation)
#   5. Back to Clone List - Return to clone selection menu
# Loop: Menu stays open after actions (user must select "Back" to exit)
manage_container_clone(){
  local clone_name="$1"
  
  while true; do
    if ! container_exists "$clone_name"; then
      pause "Container '$clone_name' no longer exists."
      return
    fi
    
    local state
    state=$(container_state "$clone_name")
    
    # Get additional info if running
    local info_text=""
    if [[ "$state" == "up" ]]; then
      local ip blocks onion
      ip=$(container_ip "$clone_name" || echo "N/A")
      blocks=$(container_exec "$clone_name" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount 2>/dev/null || echo "N/A")
      onion=$(container_exec "$clone_name" cat /var/lib/tor/bitcoin-service/hostname 2>/dev/null || echo "generating...")
      
      info_text="\nRunning info:
  IP: $ip
  Blocks: $blocks
  Onion: $onion"
    fi
    
    local choice
    choice=$(whiptail --title "Manage Clone: $clone_name" --menu \
      "Container state: $state$info_text\n\nChoose an action:" 18 78 6 \
      1 "Start Container" \
      2 "Stop Container (graceful)" \
      3 "Check Status" \
      4 "Delete Container (permanent)" \
      5 "Back to Clone List" \
      3>&1 1>&2 2>&3) || return
    
    case "$choice" in
      1)
        if [[ "$state" == "up" ]]; then
          pause "Container '$clone_name' is already running."
        else
          echo "Starting container..."
          if container_cmd start "$clone_name"; then
            pause "Container started successfully."
          else
            pause "Failed to start container."
          fi
        fi
        ;;
        
      2)
        if [[ "$state" != "up" ]]; then
          pause "Container '$clone_name' is not running."
        else
          echo "Stopping container (graceful shutdown, may take up to 3 minutes)..."
          if container_cmd stop --time=180 "$clone_name"; then
            pause "Container stopped successfully."
          else
            pause "Failed to stop container."
          fi
        fi
        ;;
        
      3)
        monitor_container_status "$clone_name"
        ;;
        
      4)
        if whiptail --title "Confirm Deletion" --yesno \
          "Are you sure you want to PERMANENTLY DELETE '$clone_name'?\n\nThis will:\n  - Stop the container\n  - Remove the container\n  - Delete the data volume\n  - Remove all blockchain data for this clone\n\nThis action CANNOT be undone!" 14 78; then
          
          echo "Deleting container..."
          container_cmd stop --time=180 "$clone_name" 2>/dev/null || true
          container_cmd rm -f "$clone_name" 2>/dev/null || true
          container_cmd volume rm "${clone_name}-data" 2>/dev/null || true
          
          pause "Clone '$clone_name' has been deleted."
          return
        fi
        ;;
        
      5)
        return
        ;;
    esac
  done
}

# export_base_container: Export container using modular format (NEW MODULAR FORMAT)
# Purpose: Package container as TWO separate components for efficient distribution
# Export Components:
#   1. Container Image (WITHOUT blockchain) - ~500MB
#      - Alpine Linux + compiled Garbageman
#      - Configuration files and services
#      - Sanitized (no blockchain data)
#   2. Blockchain Data (separate) - ~20GB compressed, split into 1.9GB parts
#      - Complete blockchain (pruned to 750MB)
#      - Can be reused across multiple VM/container exports
#      - GitHub-compatible (parts < 2GB)
# Security: Removes all sensitive/identifying information from blockchain:
#   - Bitcoin peer databases (peers.dat, anchors.dat, banlist.dat)
#   - Tor hidden service keys (forces fresh .onion address on import)
#   - Bitcoin debug logs (may contain peer IPs and transaction info)
#   - Wallet files (none should exist on pruned node, but removed as precaution)
#   - Mempool data (not needed for distribution)
#   - Lock files and PIDs
#   - bitcoin.conf (importer will regenerate based on their CLEARNET_OK preference)
# Flow:
#   1. Stop container if running (or start temporarily to get block height)
#   2. Get blockchain height for metadata
#   3. Export blockchain from volume using temporary container
#   4. Sanitize blockchain data (remove sensitive files)
#   5. Compress sanitized blockchain
#   6. Split blockchain into 1.9GB parts for GitHub
#   7. Generate blockchain checksums and manifest
#   8. Export container image using docker/podman save
#   9. Create container image archive with README
#   10. Generate checksums for both exports
# Output: Creates unified export folder in ~/Downloads:
#   gm-export-YYYYMMDD-HHMMSS/
#     - blockchain.tar.gz.part01, part02, etc. (sanitized)
#     - container-image-YYYYMMDD-HHMMSS.tar.gz
#     - SHA256SUMS
#     - MANIFEST.txt
# Benefits: Same as VM export - smaller downloads, shared blockchain, GitHub-compatible
# SAFE FOR PUBLIC DISTRIBUTION - All identifying information removed
export_base_container(){
  if ! container_exists "$CONTAINER_NAME"; then
    die "Container '$CONTAINER_NAME' not found."
  fi
  
  # Generate export name with timestamp
  local export_timestamp
  export_timestamp=$(date +%Y%m%d-%H%M%S)
  local export_name="gm-export-${export_timestamp}"
  local export_dir="$HOME/Downloads/${export_name}"
  
  # Create export directory (flat structure, no subdirectories)
  mkdir -p "$export_dir" || die "Failed to create export directory: $export_dir"
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║              Exporting Base Container (Modular Export)                         ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "This will create a unified export folder containing:"
  echo "  1. Container image (WITHOUT blockchain) - for fast updates"
  echo "  2. Blockchain data (split into parts) - can be reused across exports"
  echo ""
  
  # Step 1: Get blockchain height and node type (start container if needed)
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 1: Prepare Container"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "[1/4] Getting blockchain height and node type..."
  local blocks="unknown"
  local node_type=""
  local was_running=true
  
  if [[ "$(container_state "$CONTAINER_NAME")" != "up" ]]; then
    echo "    Container is stopped, starting temporarily to query blockchain..."
    was_running=false
    
    if ! container_cmd start "$CONTAINER_NAME" >/dev/null 2>&1; then
      echo "    ⚠️  Failed to start container, block height will be 'unknown'"
    else
      # Wait up to 60 seconds for bitcoind to be ready
      local wait_count=0
      local max_wait=12  # 12 * 5 = 60 seconds
      echo "    Waiting for bitcoind to be ready..."
      
      while [[ $wait_count -lt $max_wait ]]; do
        blocks=$(container_exec "$CONTAINER_NAME" /usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount 2>/dev/null || echo "")
        if [[ -n "$blocks" && "$blocks" != "unknown" ]]; then
          # Also get node type while we're at it
          node_type=$(get_node_classification_container "$CONTAINER_NAME")
          # Only break if we got a valid node type (not empty)
          if [[ -n "$node_type" ]]; then
            break
          fi
        fi
        wait_count=$((wait_count + 1))
        sleep 5
      done
      
      if [[ -z "$blocks" || "$blocks" == "unknown" ]]; then
        echo "    ⚠️  bitcoind did not respond in time, block height will be 'unknown'"
        blocks="unknown"
      fi
    fi
  else
    # Container already running, query directly
    blocks=$(container_exec "$CONTAINER_NAME" /usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount 2>/dev/null || echo "unknown")
    # Also get node type
    node_type=$(get_node_classification_container "$CONTAINER_NAME")
  fi
  echo "    Block height: $blocks"
  echo "    Node type: ${node_type:-Unknown}"
  
  echo ""
  echo "[2/4] Ensuring container is stopped..."
  if ! ensure_container_stopped "$CONTAINER_NAME"; then
    die "Failed to stop container"
  fi
  echo "    ✓ Container stopped"
  
  echo ""
  echo "[3/4] Waiting for clean shutdown..."
  sleep 2  # Give it a moment to fully release resources
  echo "    ✓ Ready for export"
  
  echo ""
  echo "[4/4] Node type will be used later for binary export..."
  echo "    Node type: ${node_type:-Unknown}"
  echo "    ✓ Container preparation complete"
  
  # Step 2: Export blockchain data (with sanitization)
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 2: Export Blockchain Data (Sanitized)"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Export directly to main folder (flat structure)
  local blockchain_export_dir="$export_dir"
  
  echo "[1/7] Extracting blockchain from volume..."
  local temp_blockchain="$blockchain_export_dir/.tmp-blockchain"
  mkdir -p "$temp_blockchain" || die "Failed to create temporary blockchain directory"
  
  # First extract to temporary location for sanitization
  if ! container_cmd run --rm \
    -v garbageman-data:/data:ro \
    -v "$temp_blockchain:/backup" \
    alpine:3.18 \
    sh -c 'cp -a /data/* /backup/' >/dev/null 2>&1; then
    sudo rm -rf "$export_dir" 2>/dev/null || rm -rf "$export_dir"
    die "Failed to export blockchain data"
  fi
  
  echo "    ✓ Blockchain extracted"
  
  echo ""
  echo "[2/7] Sanitizing sensitive data..."
  # Remove sensitive files that shouldn't be in public exports
  # Use sudo because files are owned by root (extracted from container)
  sudo rm -f "$temp_blockchain/peers.dat" 2>/dev/null || true
  sudo rm -f "$temp_blockchain/anchors.dat" 2>/dev/null || true
  sudo rm -f "$temp_blockchain/banlist.dat" 2>/dev/null || true
  sudo rm -f "$temp_blockchain/debug.log" 2>/dev/null || true
  sudo rm -f "$temp_blockchain/.lock" 2>/dev/null || true
  sudo rm -f "$temp_blockchain/onion_private_key" 2>/dev/null || true
  sudo rm -f "$temp_blockchain/onion_v3_private_key" 2>/dev/null || true
  sudo rm -rf "$temp_blockchain/.cookie" 2>/dev/null || true
  sudo rm -f "$temp_blockchain/bitcoind.pid" 2>/dev/null || true
  
  # Remove any wallet files (shouldn't exist in pruned node, but be safe)
  sudo rm -f "$temp_blockchain/wallet.dat" 2>/dev/null || true
  sudo rm -rf "$temp_blockchain/wallets" 2>/dev/null || true
  
  # Remove mempool - not needed and may contain transaction info
  sudo rm -f "$temp_blockchain/mempool.dat" 2>/dev/null || true
  
  # Remove bitcoin.conf if it exists in the volume (may contain clearnet preference)
  # Import will regenerate based on importer's CLEARNET_OK setting
  sudo rm -f "$temp_blockchain/bitcoin.conf" 2>/dev/null || true
  
  echo "    ✓ Sensitive data removed:"
  echo "      - Peer databases (peers.dat, anchors.dat, banlist.dat)"
  echo "      - Tor hidden service keys"
  echo "      - Debug logs and lock files"
  echo "      - Wallet files (if any)"
  echo "      - Mempool data"
  echo "      - bitcoin.conf (importer will regenerate based on their preferences)"
  
  echo ""
  echo "[3/7] Compressing sanitized blockchain..."
  # Use sudo because files are owned by root (extracted from container)
  sudo tar czf "$blockchain_export_dir/blockchain-data.tar.gz" -C "$temp_blockchain" . 2>/dev/null || {
    # Clean up if tar fails
    sudo rm -rf "$export_dir" 2>/dev/null || rm -rf "$export_dir"
    die "Failed to compress blockchain data"
  }
  
  # Fix ownership of the compressed file so user can access it
  sudo chown "$USER:$USER" "$blockchain_export_dir/blockchain-data.tar.gz" 2>/dev/null || true
  
  # Clean up temporary extraction (use sudo because container files are owned by root)
  sudo rm -rf "$temp_blockchain" 2>/dev/null || rm -rf "$temp_blockchain"
  
  local blockchain_size
  blockchain_size=$(du -h "$blockchain_export_dir/blockchain-data.tar.gz" | cut -f1)
  echo "    ✓ Blockchain compressed ($blockchain_size)"
  
  echo ""
  echo "[4/7] Splitting blockchain for GitHub (1.9GB parts)..."
  cd "$blockchain_export_dir"
  split -b 1900M -d -a 2 "blockchain-data.tar.gz" "blockchain.tar.gz.part"
  
  # Renumber parts to start from 01 instead of 00
  local part_count=0
  for part in blockchain.tar.gz.part*; do
    if [[ -f "$part" ]]; then
      part_count=$((part_count + 1))
    fi
  done
  
  if [[ $part_count -gt 0 ]]; then
    for ((i=part_count-1; i>=0; i--)); do
      local old_num=$(printf "%02d" $i)
      local new_num=$(printf "%02d" $((i+1)))
      mv "blockchain.tar.gz.part${old_num}" "blockchain.tar.gz.part${new_num}"
    done
  fi
  
  rm -f "blockchain-data.tar.gz"  # Remove unsplit version
  
  echo "    ✓ Split into $part_count parts"
  
  echo ""
  echo "[5/7] Creating manifest..."
  
  # Create manifest
  cat > MANIFEST.txt << EOF
Blockchain Data Export (SANITIZED)
===================================

Export Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Export Timestamp: $export_timestamp
Source: $CONTAINER_NAME (Container)
Block Height: $blocks

Security:
=========

✓ Peer databases removed (peers.dat, anchors.dat, banlist.dat)
✓ Tor hidden service keys removed
✓ Debug logs removed
✓ Wallet files removed (if any existed)
✓ Mempool data removed
✓ Lock files and PIDs removed

This blockchain data is SAFE for public distribution.
Sensitive/identifying information has been stripped.

Split Information:
==================

This blockchain data has been split into $part_count parts for GitHub compatibility.
Each part is approximately 1.9GB (under GitHub's 2GB limit).

To Reassemble:
==============

cat blockchain.tar.gz.part* > blockchain.tar.gz

Or let garbageman-nm.sh handle it automatically via "Import from file"

Files in this export:
=====================

$(ls -1h blockchain.tar.gz.part* | while read f; do
    size=$(du -h "$f" | cut -f1)
    echo "  $f ($size)"
done)

Total Size: $(du -ch blockchain.tar.gz.part* | tail -n1 | cut -f1)
EOF
  
  echo "    ✓ Blockchain export complete (sanitized)"
  
  # Step 2.5: Export binaries if node type is Garbageman or Knots
  # Note: node_type was already detected in Step 1 when we queried blockchain height
  echo ""
  echo "[6/7] Checking if blockchain export includes binary-compatible data..."
  echo "    ✓ Blockchain data export complete"
  
  echo ""
  echo "[7/7] Exporting binaries (if applicable)..."
  echo "    Node type: ${node_type:-Unknown}"
  
  # Export binaries with type-specific suffixes for node selection during import
  # Suffixes: -gm (Garbageman/Libre Relay), -knots (Bitcoin Knots)
  # Import functions will detect available binaries and offer selection menu
  if [[ "$node_type" == "Libre Relay/Garbageman" ]] || [[ "$node_type" == "Bitcoin Knots" ]]; then
    echo "    Extracting binaries from container..."
    
    # Determine binary suffix based on node type
    local binary_suffix=""
    if [[ "$node_type" == "Libre Relay/Garbageman" ]]; then
      binary_suffix="-gm"
    elif [[ "$node_type" == "Bitcoin Knots" ]]; then
      binary_suffix="-knots"
    fi
    
    # Extract bitcoind and bitcoin-cli from container
    # Container must be running to use 'container cp' command
    local need_to_stop=false
    if [[ "$(container_state "$CONTAINER_NAME")" != "up" ]]; then
      echo "    Starting container temporarily to extract binaries..."
      container_cmd start "$CONTAINER_NAME" >/dev/null 2>&1 || true
      sleep 3
      need_to_stop=true
    fi
    
    # Copy binaries from container to export directory
    if container_cmd cp "$CONTAINER_NAME:/usr/local/bin/bitcoind" "$export_dir/bitcoind${binary_suffix}" 2>/dev/null && \
       container_cmd cp "$CONTAINER_NAME:/usr/local/bin/bitcoin-cli" "$export_dir/bitcoin-cli${binary_suffix}" 2>/dev/null; then
      
      # Fix ownership (container cp may create root-owned files)
      sudo chown "$USER:$USER" "$export_dir/bitcoind${binary_suffix}" 2>/dev/null || true
      sudo chown "$USER:$USER" "$export_dir/bitcoin-cli${binary_suffix}" 2>/dev/null || true
      
      # Generate checksums for binaries
      (cd "$export_dir" && sha256sum "bitcoind${binary_suffix}" "bitcoin-cli${binary_suffix}" >> SHA256SUMS.binaries)
      echo "    ✓ Binaries exported as: bitcoind${binary_suffix}, bitcoin-cli${binary_suffix}"
      echo "    ✓ Binary checksums saved to SHA256SUMS.binaries"
    else
      echo "    ⚠️  Warning: Failed to extract binaries from container"
    fi
    
    # Stop container if we started it just for binary extraction
    if [[ "$need_to_stop" == "true" ]]; then
      echo "    Stopping container..."
      ensure_container_stopped "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
  else
    echo "    Node type is not Garbageman or Knots - skipping binary export"
  fi
  
  # Step 3: Export container image
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 3: Export Container Image"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Use temporary directory for image export, then package it
  local temp_export_dir="$export_dir/.tmp-image"
  mkdir -p "$temp_export_dir" || die "Failed to create temporary export directory"
  
  echo "[1/3] Exporting container image..."
  if ! container_cmd save -o "$temp_export_dir/container-image.tar" "$CONTAINER_IMAGE"; then
    rm -rf "$export_dir"
    die "Failed to export container image"
  fi
  
  local image_size
  image_size=$(du -h "$temp_export_dir/container-image.tar" | cut -f1)
  echo "    ✓ Image exported ($image_size)"
  
  echo ""
  echo "[2/3] Creating README and metadata..."
  
  cat > "$temp_export_dir/README.txt" << 'EOF'
Garbageman Container Image Export (NEW MODULAR FORMAT)
=======================================================

This archive contains a container image WITHOUT blockchain data.
The blockchain must be downloaded separately for a complete import.

Contents:
---------
- container-image.tar: Docker/Podman image
- README.txt: This file
- METADATA.txt: Export information

What's Included:
----------------
- Alpine Linux base (~500MB)
- Bitcoin node binaries (Garbageman and/or Bitcoin Knots)
- Tor for hidden service (.onion address)
- Configured entrypoint script with proper Tor setup

What's NOT Included:
--------------------
- Blockchain data (included separately as blockchain.tar.gz.part* files)
- Data volume (created during import)

Blockchain Data:
----------------
The blockchain data is included in this export folder as split parts:
  blockchain.tar.gz.part01, part02, etc.
These are recombined automatically during import.

Import Instructions:
====================

Method 1 (Recommended): Use garbageman-nm.sh
  ./garbageman-nm.sh → Create Base Container → Import from file
  
  The script will automatically:
  1. Import the container image
  2. Let you select node type (if both Garbageman and Knots binaries present)
  3. Reassemble and import blockchain data
  4. Create container with bridge networking (isolated network namespace)

Method 2 (Manual - Docker):
  1. Load image: docker load -i container-image.tar
  2. Create volume: docker volume create garbageman-data
  3. Reassemble blockchain:
     cat blockchain.tar.gz.part* > blockchain.tar.gz
     tar xzf blockchain.tar.gz
  4. Inject blockchain into volume:
     docker run --rm -v garbageman-data:/data -v $(pwd):/import:ro \
       alpine cp -a /import/* /data/
  5. Create container:
     # For clearnet mode (accepts incoming clearnet connections):
     docker create --name gm-base -p 8333:8333 \
       -v garbageman-data:/var/lib/bitcoin \
       garbageman:latest
     
     # For Tor-only mode (Tor-only connections):
     docker create --name gm-base \
       -v garbageman-data:/var/lib/bitcoin \
       garbageman:latest

Method 2 (Manual - Podman): Same as Docker, replace 'docker' with 'podman'

Notes:
------
- Container image size: ~500MB (much smaller than old monolithic format)
- Blockchain size: ~20GB compressed
- Total combined: ~21GB (same as before, but now modular)
- Can update container image without re-downloading blockchain
- Can share blockchain between VM and container deployments
EOF

  cat > "$temp_export_dir/METADATA.txt" <<METADATA
Export Information
==================

Export Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Export Timestamp: $export_timestamp
Format: Modular (container image + blockchain parts)

Container Specifications:
--------------------------
Name: $CONTAINER_NAME
Image: $CONTAINER_IMAGE
Runtime: $(container_runtime)

Blockchain Information:
-----------------------
Height at Export: $blocks
Format: Split into parts (blockchain.tar.gz.part*)

Security & Privacy:
-------------------
✓ Blockchain sanitized before export
✓ Peer databases removed (peers.dat, anchors.dat, banlist.dat)
✓ Tor hidden service keys removed (regenerated on import)
✓ Debug logs removed (may contain IP addresses)
✓ Wallet files removed (none should exist on pruned node)
✓ Mempool data removed
✓ Lock files and PIDs removed

SAFE FOR PUBLIC DISTRIBUTION - No identifying information included.

Companion Files:
----------------
This container image pairs with blockchain data:
  blockchain.tar.gz.part01, part02, etc.

All files are included in this unified export folder.
METADATA
  
  echo "    ✓ README and metadata created"
  
  echo ""
  echo "[3/3] Creating container image archive..."
  local image_archive_name="container-image.tar.gz"
  local image_archive_path="$export_dir/${image_archive_name}"
  
  # Archive the temporary directory contents
  tar -czf "$image_archive_path" -C "$temp_export_dir" . || {
    rm -rf "$export_dir"
    die "Failed to create archive"
  }
  
  # Remove temporary directory
  rm -rf "$temp_export_dir"
  
  local archive_size
  archive_size=$(du -h "$image_archive_path" | cut -f1)
  echo "    ✓ Container image archived ($archive_size)"
  
  # Generate combined checksums for all files
  echo "    Generating checksums..."
  
  # Start with blockchain parts and container image
  (cd "$export_dir" && sha256sum blockchain.tar.gz.part* "${image_archive_name}" > SHA256SUMS)
  
  # Add binaries if they exist
  if [[ -f "$export_dir/SHA256SUMS.binaries" ]]; then
    echo "" >> "$export_dir/SHA256SUMS"
    echo "# Bitcoin binaries:" >> "$export_dir/SHA256SUMS"
    cat "$export_dir/SHA256SUMS.binaries" >> "$export_dir/SHA256SUMS"
    rm -f "$export_dir/SHA256SUMS.binaries"  # Clean up temporary file
  fi
  
  # Add reassembled blockchain checksum
  echo "" >> "$export_dir/SHA256SUMS"
  echo "# Reassembled blockchain checksum:" >> "$export_dir/SHA256SUMS"
  (cd "$export_dir" && cat blockchain.tar.gz.part* | sha256sum | sed 's/-/blockchain.tar.gz/' >> SHA256SUMS)
  
  echo "    ✓ Checksums created"
  
  # Calculate totals
  local total_size
  total_size=$(du -csh "$export_dir"/* 2>/dev/null | tail -n1 | cut -f1)
  
  # Success!
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    Modular Export Complete!                                    ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "📦 Unified Export Folder:"
  echo ""
  echo "  Location: $export_dir/"
  echo "  Total Size: $total_size"
  echo ""
  echo "  Contents:"
  echo "    • blockchain.tar.gz.part* - Blockchain data split into GitHub-compatible parts"
  echo "    • ${image_archive_name} - Container image archive"
  echo "    • SHA256SUMS - Combined checksums for all files"
  echo "    • MANIFEST.txt - Export information"
  echo ""
  echo "  Blockchain Components:"
  echo "    • Parts: $(ls -1 "$export_dir"/blockchain.tar.gz.part* 2>/dev/null | wc -l) files"
  echo ""
  echo "🔗 Timestamp: $export_timestamp"
  echo ""
  echo "📋 Benefits of Unified Export:"
  echo "   • All components in one folder - easy to manage and transfer"
  echo "   • Smaller container image (~500MB vs ~22GB monolithic)"
  echo "   • Blockchain can be reused across exports"
  echo "   • Blockchain split for GitHub 2GB limit compatibility"
  echo ""
  echo "📤 To Import:"
  echo "   Use 'Import from file' in garbageman-nm.sh"
  echo "   The script will automatically combine both components"
  echo ""
  
  pause "Export complete!\n\nUnified export folder: $export_dir/"
}

# import_base_container: Import container from export folder (unified format only)
# Purpose: Restore container image and blockchain data from portable export
# Supported inputs:
#   - Unified export folder: gm-export-YYYYMMDD-HHMMSS/
#     • Contains container image archive (container-image.tar.gz) plus blockchain parts (blockchain.tar.gz.partN)
#     • Contains node binaries (bitcoind-gm/bitcoin-cli-gm or bitcoind-knots/bitcoin-cli-knots)
#     • If only a VM image is found, user is guided to the VM import
# Process:
#   1. Let user configure defaults (reserves, container sizes, clearnet toggle)
#   2. Scan ~/Downloads for gm-export-* folders
#   3. Let user select which export to import
#   4. Prefer container image; if missing but VM image present, show helpful guidance
#   5. Verify checksums (SHA256SUMS)
#   6. Load container image (docker/podman load)
#   7. Let user select node type (Garbageman or Bitcoin Knots) based on available binaries
#   8. Create container with proper configuration
#   9. Inject selected node binaries into container using container_cmd cp
#  10. Create volume and inject blockchain if parts are present
#  11. Inject bitcoin.conf based on clearnet setting
# Notes:
#   - Folder detection is flexible: either image type triggers listing in menu
#   - Cross-guidance helps users pick the correct import path (container vs VM)
#   - Node selection: Auto-selects if only one type available, presents menu if both
# Recommendation: Use "Import from GitHub" for complete automated download/verify/import
import_base_container(){
  # Let user configure defaults for resource allocation
  if ! configure_defaults_container; then
    pause "Cancelled."
    return
  fi
  
  # Prompt for initial sync resources
  if ! prompt_sync_resources_container; then
    pause "Cancelled."
    return
  fi
  
  echo "Scanning ~/Downloads for container exports..."
  local archives=()
  local export_items=()
  
  # Look for unified export folders (gm-export-*)
  while IFS= read -r -d '' folder; do
    # Check if it contains a container image archive OR VM image archive
    # This allows importing from folders that have either or both image types
    if ls "$folder"/container-image.tar.gz >/dev/null 2>&1 || \
       ls "$folder"/vm-image.tar.gz >/dev/null 2>&1; then
      export_items+=("folder:$folder")
    fi
  done < <(find "$HOME/Downloads" -maxdepth 1 -type d -name "gm-export-*" -print0 2>/dev/null | sort -z)
  
  if [[ ${#export_items[@]} -eq 0 ]]; then
    pause "No container exports found in ~/Downloads/\n\nLooking for:\n  gm-export-* folders with container-image.tar.gz files"
    return
  fi
  
  # Build menu
  local menu_items=()
  for i in "${!export_items[@]}"; do
    local item="${export_items[$i]}"
    local type="${item%%:*}"
    local path="${item#*:}"
    local basename=$(basename "$path")
    local display
    
    # All items are now folders (unified format)
    local folder_size=$(du -sh "$path" 2>/dev/null | cut -f1)
    
    # Check if blockchain data is present
    local blockchain_status="blockchain included"
    if ! ls "$path"/blockchain.tar.gz.part* >/dev/null 2>&1; then
      blockchain_status="image only, no blockchain"
    fi
    
    display="$basename/ ($folder_size) [${blockchain_status}]"
    menu_items+=("$i" "$display")
  done
  
  local selection
  selection=$(whiptail --title "Select Container Export" --menu \
    "Select export to import:" 20 78 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || return
  
  local selected_item="${export_items[$selection]}"
  local item_type="${selected_item%%:*}"
  local item_path="${selected_item#*:}"
  
  echo "Importing: $(basename "$item_path")"
  echo ""
  
  # Handle different formats
  local temp_dir
  temp_dir=$(mktemp -d -t gm-container-import-XXXXXX)
  trap "rm -rf '$temp_dir'" RETURN EXIT INT TERM
  
  local extract_dir
  local blockchain_dir
  
  if [[ "$item_type" == "folder" ]]; then
    # NEW unified format: folder with image archive and blockchain parts at root
    echo "[1/5] Using unified export folder..."
    extract_dir="$item_path"
    
    # Find the image archive within the folder
    local image_archive=$(ls "$extract_dir"/container-image.tar.gz 2>/dev/null | head -n1)
    
    if [[ -z "$image_archive" ]]; then
      # Check if folder has VM image instead
      if ls "$extract_dir"/vm-image.tar.gz >/dev/null 2>&1; then
        pause "❌ This folder only contains a VM image.\n\nTo import as a VM:\n1. Cancel and return to main menu\n2. Choose 'Create Base VM'\n3. Select 'Import from file'\n4. Choose this same folder\n\nOr download/export a container image for this release."
        return
      else
        die "No container image archive found in export folder"
      fi
    fi
    
    echo "    Extracting container image archive..."
    tar -xzf "$image_archive" -C "$temp_dir" || die "Failed to extract image archive"
    
    # Blockchain parts are at root level in new format
    blockchain_dir="$extract_dir"
    
    # Blockchain parts are at root level in unified format
    blockchain_dir="$extract_dir"
    
  else
    die "❌ Only unified export folders are supported.\n\nLooking for: gm-export-* folders"
  fi
  
  # Find container image tar in extracted archive
  local image_tar=""
  if [[ -f "$temp_dir/container-image.tar" ]]; then
    image_tar="$temp_dir/container-image.tar"  # Extracted from archive
  elif [[ -f "$extract_dir/container-image.tar" ]]; then
    image_tar="$extract_dir/container-image.tar"  # In export folder
  fi
  
  if [[ -z "$image_tar" ]]; then
    die "Container image tar not found in export"
  fi
  
  # Load container image
  echo ""
  echo "[2/5] Loading container image..."
  if ! container_cmd load -i "$image_tar"; then
    die "Failed to load container image"
  fi
  echo "    ✓ Image loaded"
  
  # Check for binary files and let user select node type
  echo ""
  echo "Checking available node implementations..."
  
  local has_gm=false
  local has_knots=false
  local node_choice
  local binary_suffix
  
  if [[ -f "$extract_dir/bitcoind-gm" ]] && [[ -f "$extract_dir/bitcoin-cli-gm" ]]; then
    has_gm=true
    echo "  ✓ Found Garbageman binaries"
  fi
  
  if [[ -f "$extract_dir/bitcoind-knots" ]] && [[ -f "$extract_dir/bitcoin-cli-knots" ]]; then
    has_knots=true
    echo "  ✓ Found Bitcoin Knots binaries"
  fi
  
  if [[ "$has_gm" == "false" ]] && [[ "$has_knots" == "false" ]]; then
    pause "❌ No node binaries found in export!\n\nExpected: bitcoind-gm + bitcoin-cli-gm OR bitcoind-knots + bitcoin-cli-knots\n\nThis export may be from an older version.\nPlease re-export or download a newer release."
    return
  fi
  
  # Build menu based on available binaries
  local menu_opts=()
  if [[ "$has_gm" == "true" ]]; then
    menu_opts+=("1" "Garbageman")
  fi
  if [[ "$has_knots" == "true" ]]; then
    menu_opts+=("2" "Bitcoin Knots")
  fi
  
  if [[ "$has_gm" == "true" ]] && [[ "$has_knots" == "true" ]]; then
    # Both available, let user choose
    node_choice=$(whiptail --title "Select Node Type" --menu \
      "Choose which Bitcoin implementation to install:\n\nBoth are available in this export." 15 70 2 \
      "${menu_opts[@]}" \
      3>&1 1>&2 2>&3) || {
        echo "Cancelled."
        return
      }
  else
    # Only one available, auto-select it
    node_choice="${menu_opts[0]}"
    echo "  ℹ Only one implementation available, auto-selecting: ${menu_opts[1]}"
  fi
  
  # Set binary suffix based on selection
  if [[ "$node_choice" == "1" ]]; then
    binary_suffix="-gm"
    echo "Selected: Garbageman (Libre Relay)"
  elif [[ "$node_choice" == "2" ]]; then
    binary_suffix="-knots"
    echo "Selected: Bitcoin Knots"
  fi
  
  # Create data volume and import data
  echo ""
  echo "[3/5] Importing blockchain data..."
  container_cmd volume create garbageman-data >/dev/null 2>&1 || true
  
  # Check for blockchain data in different locations
  local blockchain_imported=false
  
  # NEW format: blockchain parts at root level (no subfolder)
  if [[ -n "$blockchain_dir" && -d "$blockchain_dir" ]]; then
    echo "  Found blockchain data in unified export folder..."
    
    # Check for blockchain parts (blockchain.tar.gz.part*)
    if ls "$blockchain_dir"/blockchain.tar.gz.part* >/dev/null 2>&1; then
      echo "  Reassembling blockchain parts..."
      cat "$blockchain_dir"/blockchain.tar.gz.part* > "$temp_dir/blockchain.tar.gz" || die "Failed to reassemble blockchain"
      
      # Verify checksum if available (check SHA256SUMS file)
      if [[ -f "$blockchain_dir/SHA256SUMS" ]]; then
        echo "  Verifying blockchain checksum..."
        local expected_sum=$(grep "blockchain.tar.gz$" "$blockchain_dir/SHA256SUMS" | awk '{print $1}')
        local actual_sum=$(sha256sum "$temp_dir/blockchain.tar.gz" | awk '{print $1}')
        if [[ "$expected_sum" != "$actual_sum" ]]; then
          die "Blockchain checksum mismatch! Export may be corrupted."
        fi
        echo "    ✓ Checksum verified"
      fi
      
      # Import blockchain
      echo "  Importing blockchain to volume..."
      if ! container_cmd run --rm \
        -v garbageman-data:/data \
        -v "$temp_dir:/backup:ro" \
        alpine:3.18 \
        tar xzf /backup/blockchain.tar.gz -C /data >/dev/null 2>&1; then
        die "Failed to import blockchain data"
      fi
      blockchain_imported=true
      echo "    ✓ Blockchain data imported"
    else
      echo "  ⚠ No blockchain data found in export"
      echo "  ⚠ You'll need to:"
      echo "    1. Download blockchain separately from GitHub"
      echo "    2. Use 'Import from GitHub' option instead, OR"
      echo "    3. Manually import blockchain data into the volume"
      pause "\nThis export contains only the container image, not blockchain data.\n\nUse 'Import from GitHub' for complete import, or manually import blockchain."
      return
    fi
  fi
  
  # Create container with bridge networking (not host networking)
  # Each container gets its own isolated network namespace
  # For CLEARNET_OK=yes: Expose port 8333 to allow incoming clearnet connections (user can set up port forwarding)
  # For Tor-only: No port exposure needed - Tor handles incoming via hidden service
  echo ""
  echo "[4/5] Creating container..."
  
  # Container will use CLEARNET_OK setting for bitcoind configuration
  echo "    Configuring for CLEARNET_OK=${CLEARNET_OK}"
  
  # Determine if we should expose P2P port (only for clearnet mode on base container)
  local port_args=""
  if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
    port_args="-p 8333:8333"
    echo "    Exposing port 8333 for incoming clearnet connections"
  fi
  
  if ! container_cmd create \
    --name "$CONTAINER_NAME" \
    $port_args \
    --cpus="$SYNC_VCPUS" \
    --memory="${SYNC_RAM_MB}m" \
    --memory-swap="${SYNC_RAM_MB}m" \
    -v garbageman-data:/var/lib/bitcoin \
    --restart unless-stopped \
    "$CONTAINER_IMAGE"; then
    die "Failed to create container"
  fi
  echo "    ✓ Container created"
  
  # Inject selected node binaries into container
  echo ""
  echo "[4b/5] Injecting node binaries into container..."
  
  local bitcoind_file="$extract_dir/bitcoind${binary_suffix}"
  local bitcoin_cli_file="$extract_dir/bitcoin-cli${binary_suffix}"
  
  # Copy binaries into the container
  if ! container_cmd cp "$bitcoind_file" "${CONTAINER_NAME}:/usr/local/bin/bitcoind"; then
    die "Failed to copy bitcoind to container"
  fi
  
  if ! container_cmd cp "$bitcoin_cli_file" "${CONTAINER_NAME}:/usr/local/bin/bitcoin-cli"; then
    die "Failed to copy bitcoin-cli to container"
  fi
  
  # Set executable permissions on binaries
  container_cmd exec "$CONTAINER_NAME" chmod 755 /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli >/dev/null 2>&1 || true
  
  echo "    ✓ Binaries injected"
  
  # Inject bitcoin.conf into the volume based on CLEARNET_OK setting
  echo ""
  echo "[5/5] Configuring bitcoin.conf based on clearnet setting..."
  
  local btc_conf_content
  if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
    echo "    Injecting config for: Tor + clearnet (faster sync)"
    btc_conf_content="server=1
prune=750
dbcache=450
maxconnections=25
listen=1
bind=0.0.0.0
onlynet=onion
onlynet=ipv4
listenonion=1
discover=1
dnsseed=1
proxy=127.0.0.1:9050
torcontrol=127.0.0.1:9051
[main]"
  else
    echo "    Injecting config for: Tor-only (maximum privacy)"
    btc_conf_content="server=1
prune=750
dbcache=450
maxconnections=25
onlynet=onion
proxy=127.0.0.1:9050
listen=1
bind=0.0.0.0
listenonion=1
discover=0
dnsseed=0
torcontrol=127.0.0.1:9051
[main]"
  fi
  
  # Create temporary file with bitcoin.conf
  local temp_conf=$(mktemp)
  echo "$btc_conf_content" > "$temp_conf"
  
  # Inject bitcoin.conf into the volume using a temporary container
  # Place it at /var/lib/bitcoin/bitcoin.conf (in the volume)
  if container_cmd run --rm \
    -v garbageman-data:/data \
    -v "$temp_conf:/bitcoin.conf:ro" \
    alpine:3.18 \
    sh -c 'cp /bitcoin.conf /data/bitcoin.conf && chmod 644 /data/bitcoin.conf' 2>/dev/null; then
    echo "    ✓ bitcoin.conf injected into volume"
    
    # Recreate container with volume-based config override
    # Port 8333 exposed only if CLEARNET_OK=yes (allows incoming clearnet with port forwarding)
    # Clones never expose ports (Tor-only, would conflict)
    container_cmd rm "$CONTAINER_NAME" >/dev/null 2>&1
    
    # Determine if we should expose P2P port (only for clearnet mode on base container)
    local port_args=""
    if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
      port_args="-p 8333:8333"
      echo "    Exposing port 8333 for incoming clearnet connections"
    fi
    
    if ! container_cmd create \
      --name "$CONTAINER_NAME" \
      $port_args \
      --cpus="$SYNC_VCPUS" \
      --memory="${SYNC_RAM_MB}m" \
      --memory-swap="${SYNC_RAM_MB}m" \
      -v garbageman-data:/var/lib/bitcoin \
      --restart unless-stopped \
      "$CONTAINER_IMAGE" \
      bitcoind -conf=/var/lib/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin; then
      # Fallback: recreate without custom command
      echo "    ⚠️  Failed to override config, using default from image"
      
      # Re-determine port args for fallback
      local port_args=""
      if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
        port_args="-p 8333:8333"
      fi
      
      container_cmd create \
        --name "$CONTAINER_NAME" \
        $port_args \
        --cpus="$SYNC_VCPUS" \
        --memory="${SYNC_RAM_MB}m" \
        --memory-swap="${SYNC_RAM_MB}m" \
        -v garbageman-data:/var/lib/bitcoin \
        --restart unless-stopped \
        "$CONTAINER_IMAGE" >/dev/null 2>&1
    else
      echo "    ✓ Container configured to use injected bitcoin.conf"
    fi
  else
    echo "    ⚠️  Warning: Failed to inject config, using default from image"
  fi
  
  rm -f "$temp_conf"
  
  echo "    ✓ Container configuration complete"
  echo ""
  echo "✅ Import complete!"
  echo ""
  local node_type="$([ "$binary_suffix" == "-gm" ] && echo "Garbageman" || echo "Bitcoin Knots")"
  pause "Container '$CONTAINER_NAME' imported successfully with $node_type!\n\nUse 'Monitor Base Container Sync' to check status."
}

# import_from_github_container: Import container from GitHub release (NEW MODULAR FORMAT)
# Purpose: Download and import pre-built container using modular architecture
# Modular Design:
#   - Downloads blockchain data separately from images
#   - Downloads BOTH images (container + VM) for flexibility/switching later
#   - Downloads node binaries (Garbageman and/or Bitcoin Knots)
#   - Verifies checksums (unified SHA256SUMS when available)
#   - Reassembles blockchain from split parts
#   - Uses container image for import; keeps VM image for later use
# Flow:
#   1. Let user configure defaults (reserves, container sizes, clearnet toggle)
#   2. Fetch available releases from GitHub API
#   3. Let user select a release tag
#   4. Parse release assets: blockchain parts, images, binaries, checksums
#   5. Let user select node type (Garbageman or Bitcoin Knots) based on available binaries
#   6. Download blockchain parts (blockchain.tar.gz.part01, part02, ...)
#   7. Download container image (container-image.tar.gz)
#   8. Download VM image (vm-image.tar.gz) - optional
#   9. Download selected node binaries (bitcoind-gm/knots, bitcoin-cli-gm/knots)
#  10. Verify checksums for parts and images (prefer SHA256SUMS)
#  11. Reassemble blockchain from parts
#  12. Load container image with docker/podman load
#  13. Create data volume (garbageman-data)
#  14. Extract and inject blockchain data into volume
#  15. Inject selected node binaries into temporary container using container_cmd cp
#  16. Create base container with proper configuration
#  17. Inject bitcoin.conf based on clearnet setting
#  18. Cleanup temporary files (keep original downloads)
# Prerequisites: docker or podman, curl or wget, jq
# Download Size: ~21GB (blockchain) + ~0.5GB (container) + ~1GB (VM) + ~0.1GB (binaries) ≈ ~22.6GB total
# Benefits over old format:
#   - Blockchain is separate (can be shared between VM and container)
#   - Much smaller per-image downloads (~0.5GB container, ~1GB VM)
#   - Can switch between VM and container without re-downloading blockchain
#   - Downloaded files preserved for USB transfer to other computers
#   - User choice between Garbageman (Libre Relay) and Bitcoin Knots
# Side effects: Downloads to ~/Downloads/gm-export-*, imports complete container with volume
import_from_github_container(){
  local repo="paulscode/garbageman-nm"
  local api_url="https://api.github.com/repos/$repo/releases"
  
  # Cleanup function for temporary files (called on both success and failure)
  cleanup_container_import_temps(){
    local dir="$1"
    [[ -z "$dir" || ! -d "$dir" ]] && return
    
    # Remove temporary files (keep original downloads for USB transfer)
    rm -f "$dir"/blockchain.tar.gz 2>/dev/null
    rm -rf "$dir/blockchain-data" "$dir/container-image" 2>/dev/null
  }
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║          Import Base Container from GitHub (Modular Download)                  ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "This import downloads blockchain data and BOTH images (container + VM) separately."
  echo "We'll import the container now and keep the VM image so you can switch later."
  echo "Benefits: Smaller per-image downloads; switch without re-downloading blockchain."
  echo ""
  
  # Detect container runtime
  local runtime=$(container_runtime)
  if [[ -z "$runtime" ]]; then
    pause "❌ No container runtime found.\n\nThis should not happen - ensure_tools should have installed Docker.\nTry restarting the script or install docker/podman manually."
    return
  fi
  
  # Check for required tools
  if ! command -v jq >/dev/null 2>&1; then
    pause "❌ Required tool 'jq' not found.\n\nInstall with: sudo apt install jq"
    return
  fi
  
  local download_tool=""
  if command -v curl >/dev/null 2>&1; then
    download_tool="curl"
  elif command -v wget >/dev/null 2>&1; then
    download_tool="wget"
  else
    pause "❌ Neither 'curl' nor 'wget' found.\n\nInstall with: sudo apt install curl"
    return
  fi
  
  echo "Fetching available releases from GitHub..."
  local releases_json
  if [[ "$download_tool" == "curl" ]]; then
    releases_json=$(curl -s "$api_url" 2>/dev/null)
  else
    releases_json=$(wget -q -O- "$api_url" 2>/dev/null)
  fi
  
  if [[ -z "$releases_json" ]] || ! echo "$releases_json" | jq -e . >/dev/null 2>&1; then
    pause "❌ Failed to fetch releases from GitHub.\n\nCheck your internet connection."
    return
  fi
  
  # Parse releases and build menu
  local tags=()
  local tag_names=()
  local menu_items=()
  
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    tags+=("$tag")
    local tag_name=$(echo "$releases_json" | jq -r ".[] | select(.tag_name==\"$tag\") | .name // .tag_name")
    local published=$(echo "$releases_json" | jq -r ".[] | select(.tag_name==\"$tag\") | .published_at" | cut -d'T' -f1)
    tag_names+=("$tag_name")
    menu_items+=("$tag" "$tag_name ($published)")
  done < <(echo "$releases_json" | jq -r '.[].tag_name')
  
  if [[ ${#tags[@]} -eq 0 ]]; then
    pause "No releases found."
    return
  fi
  
  echo "Found ${#tags[@]} release(s)"
  echo ""
  
  # Let user select release
  local selected_tag
  selected_tag=$(whiptail --title "Select GitHub Release" \
    --menu "Choose a release to download and import:" 20 78 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || return
  
  echo "Selected: $selected_tag"
  echo ""
  
  # Get assets for selected release
  local release_assets
  release_assets=$(echo "$releases_json" | jq -r ".[] | select(.tag_name==\"$selected_tag\") | .assets")
  
  # Find blockchain parts, container image, VM image, checksums, and binaries
  local blockchain_part_urls=()
  local blockchain_part_names=()
  local container_image_url=""
  local container_image_name=""
  local vm_image_url=""
  local vm_image_name=""
  local sha256sums_url=""
  local bitcoind_gm_url=""
  local bitcoin_cli_gm_url=""
  local bitcoind_knots_url=""
  local bitcoin_cli_knots_url=""
  
  while IFS='|' read -r name url; do
    [[ -z "$name" ]] && continue
    # Blockchain parts (blockchain.tar.gz.part*)
    if [[ "$name" =~ ^blockchain\.tar\.gz\.part[0-9]+$ ]]; then
      blockchain_part_names+=("$name")
      blockchain_part_urls+=("$url")
    # Unified checksum file
    elif [[ "$name" == "SHA256SUMS" ]]; then
      sha256sums_url="$url"
    # Container image (container-image.tar.gz)
    elif [[ "$name" == "container-image.tar.gz" ]]; then
      container_image_name="$name"
      container_image_url="$url"
    # VM image (vm-image.tar.gz)
    elif [[ "$name" == "vm-image.tar.gz" ]]; then
      vm_image_name="$name"
      vm_image_url="$url"
    # Bitcoin binaries
    elif [[ "$name" == "bitcoind-gm" ]]; then
      bitcoind_gm_url="$url"
    elif [[ "$name" == "bitcoin-cli-gm" ]]; then
      bitcoin_cli_gm_url="$url"
    elif [[ "$name" == "bitcoind-knots" ]]; then
      bitcoind_knots_url="$url"
    elif [[ "$name" == "bitcoin-cli-knots" ]]; then
      bitcoin_cli_knots_url="$url"
    fi
  done < <(echo "$release_assets" | jq -r '.[] | "\(.name)|\(.browser_download_url)"')
  
  # Validate required files are present
  if [[ ${#blockchain_part_urls[@]} -eq 0 ]]; then
    pause "❌ No blockchain parts found in release $selected_tag"
    return
  fi
  
  if [[ -z "$container_image_url" ]]; then
    pause "❌ No container image found in release $selected_tag"
    return
  fi
  
  # Warn if VM image not found (optional but recommended)
  if [[ -z "$vm_image_url" ]]; then
    echo "⚠ Warning: VM image not found in this release (older format)"
    echo "  You can still use the container, but won't be able to switch to VM later."
    echo ""
  fi
  
  # Check for binary files and let user select node type
  echo ""
  echo "Checking available node implementations..."
  
  local has_gm=false
  local has_knots=false
  local node_choice
  local binary_suffix
  
  if [[ -n "$bitcoind_gm_url" ]] && [[ -n "$bitcoin_cli_gm_url" ]]; then
    has_gm=true
    echo "  ✓ Found Garbageman binaries"
  fi
  
  if [[ -n "$bitcoind_knots_url" ]] && [[ -n "$bitcoin_cli_knots_url" ]]; then
    has_knots=true
    echo "  ✓ Found Bitcoin Knots binaries"
  fi
  
  if [[ "$has_gm" == "false" ]] && [[ "$has_knots" == "false" ]]; then
    pause "❌ No node binaries found in release!\n\nThis release may be from an older version.\nPlease choose a newer release or re-export."
    return
  fi
  
  # Build menu based on available binaries
  local menu_opts=()
  if [[ "$has_gm" == "true" ]]; then
    menu_opts+=("1" "Garbageman")
  fi
  if [[ "$has_knots" == "true" ]]; then
    menu_opts+=("2" "Bitcoin Knots")
  fi
  
  if [[ "$has_gm" == "true" ]] && [[ "$has_knots" == "true" ]]; then
    # Both available, let user choose
    node_choice=$(whiptail --title "Select Node Type" --menu \
      "Choose which Bitcoin implementation to install:\n\nBoth are available in this release." 15 70 2 \
      "${menu_opts[@]}" \
      3>&1 1>&2 2>&3) || {
        echo "Cancelled."
        return
      }
  else
    # Only one available, auto-select it
    node_choice="${menu_opts[0]}"
    echo "  ℹ Only one implementation available, auto-selecting: ${menu_opts[1]}"
  fi
  
  # Set binary suffix and URLs based on selection
  local bitcoind_url=""
  local bitcoin_cli_url=""
  if [[ "$node_choice" == "1" ]]; then
    binary_suffix="-gm"
    bitcoind_url="$bitcoind_gm_url"
    bitcoin_cli_url="$bitcoin_cli_gm_url"
    echo "Selected: Garbageman (Libre Relay)"
  elif [[ "$node_choice" == "2" ]]; then
    binary_suffix="-knots"
    bitcoind_url="$bitcoind_knots_url"
    bitcoin_cli_url="$bitcoin_cli_knots_url"
    echo "Selected: Bitcoin Knots"
  fi
  
  # Calculate approximate download sizes (including binaries)
  local blockchain_size="~$(( ${#blockchain_part_urls[@]} * 19 / 10 )) GB"  # parts are ~1.9GB each
  local container_size="~500 MB"
  local vm_size="~1 GB"
  local binaries_size="~100 MB"
  local total_size="~$(( ${#blockchain_part_urls[@]} * 19 / 10 + 2 )) GB"  # +2GB for both images
  
  echo "Download plan:"
  echo "  • Blockchain data: ${#blockchain_part_urls[@]} parts ($blockchain_size)"
  echo "  • Container image: $container_image_name ($container_size)"
  if [[ -n "$vm_image_url" ]]; then
    echo "  • VM image: $vm_image_name ($vm_size)"
    echo "  Total: $total_size"
  fi
  echo ""
  
  # Configure resources before downloading
  echo "Before downloading, let's configure resource allocation:"
  echo ""
  
  # Let user configure defaults for resource allocation
  if ! configure_defaults_container; then
    pause "Cancelled."
    return
  fi
  
  # Prompt for initial sync resources
  if ! prompt_sync_resources_container; then
    pause "Cancelled."
    return
  fi
  
  local download_message="This will download approximately $total_size of data.\n\nBlockchain parts: ${#blockchain_part_urls[@]}\nContainer image: $container_image_name"
  if [[ -n "$vm_image_url" ]]; then
    download_message+="\nVM image: $vm_image_name"
  fi
  download_message+="\nRelease: $selected_tag\n\nBoth images will be downloaded for flexibility.\nYou can switch between VM and container\nwithout re-downloading the blockchain.\n\nContinue?"
  
  if ! whiptail --title "Confirm Download" \
    --yesno "$download_message" \
    18 75; then
    echo "Download cancelled."
    return
  fi
  
  # Create persistent download directory in ~/Downloads with unified export structure
  local download_timestamp=$(date +%Y%m%d-%H%M%S)
  local download_dir="$HOME/Downloads/gm-export-${download_timestamp}"
  mkdir -p "$download_dir"
  
  # Set trap to cleanup temporary files on exit (success or failure)
  trap "cleanup_container_import_temps '$download_dir'" RETURN EXIT INT TERM
  
  echo ""
  echo "Downloading to: $download_dir"
  echo "(Files will be kept for USB transfer or future imports)"
  echo ""
  
  # Step 1: Download blockchain parts
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 1: Downloading Blockchain Data (${#blockchain_part_urls[@]} parts)"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  for i in "${!blockchain_part_urls[@]}"; do
    local part_name="${blockchain_part_names[$i]}"
    local part_url="${blockchain_part_urls[$i]}"
    local part_num=$((i + 1))
    
    echo "[Part $part_num/${#blockchain_part_urls[@]}] Downloading $part_name..."
    
    if [[ "$download_tool" == "curl" ]]; then
      curl -L --progress-bar -o "$download_dir/$part_name" "$part_url" || {
        pause "❌ Failed to download $part_name"
        return
      }
    else
      wget --show-progress -O "$download_dir/$part_name" "$part_url" || {
        pause "❌ Failed to download $part_name"
        return
      }
    fi
  done
  
  # Download checksums (unified SHA256SUMS format only)
  if [[ -n "$sha256sums_url" ]]; then
    echo ""
    echo "Downloading unified checksum file (SHA256SUMS)..."
    if [[ "$download_tool" == "curl" ]]; then
      curl -sL -o "$download_dir/SHA256SUMS" "$sha256sums_url"
    else
      wget -q -O "$download_dir/SHA256SUMS" "$sha256sums_url"
    fi
  fi
  
  # Step 2: Download container image
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 2: Downloading Container Image"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "Downloading $container_image_name..."
  
  if [[ "$download_tool" == "curl" ]]; then
    curl -L --progress-bar -o "$download_dir/$container_image_name" "$container_image_url" || {
      pause "❌ Failed to download container image"
      return
    }
  else
    wget --show-progress -O "$download_dir/$container_image_name" "$container_image_url" || {
      pause "❌ Failed to download container image"
      return
    }
  fi
  
  # Download VM image (if available)
  if [[ -n "$vm_image_url" ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Step 2b: Downloading VM Image"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Downloading $vm_image_name..."
    
    if [[ "$download_tool" == "curl" ]]; then
      curl -L --progress-bar -o "$download_dir/$vm_image_name" "$vm_image_url" || {
        echo "⚠ Failed to download VM image (optional, continuing...)"
      }
    else
      wget --show-progress -O "$download_dir/$vm_image_name" "$vm_image_url" || {
        echo "⚠ Failed to download VM image (optional, continuing...)"
      }
    fi
    
  fi
  
  # Step 2c: Download selected node binaries
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 2c: Downloading Node Binaries"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  local bitcoind_filename="bitcoind${binary_suffix}"
  local bitcoin_cli_filename="bitcoin-cli${binary_suffix}"
  
  echo "Downloading $bitcoind_filename..."
  if [[ "$download_tool" == "curl" ]]; then
    curl -L --progress-bar -o "$download_dir/$bitcoind_filename" "$bitcoind_url" || {
      pause "❌ Failed to download bitcoind binary"
      return
    }
  else
    wget --show-progress -O "$download_dir/$bitcoind_filename" "$bitcoind_url" || {
      pause "❌ Failed to download bitcoind binary"
      return
    }
  fi
  
  echo "Downloading $bitcoin_cli_filename..."
  if [[ "$download_tool" == "curl" ]]; then
    curl -L --progress-bar -o "$download_dir/$bitcoin_cli_filename" "$bitcoin_cli_url" || {
      pause "❌ Failed to download bitcoin-cli binary"
      return
    }
  else
    wget --show-progress -O "$download_dir/$bitcoin_cli_filename" "$bitcoin_cli_url" || {
      pause "❌ Failed to download bitcoin-cli binary"
      return
    }
  fi
  
  # Mark binaries as executable
  chmod +x "$download_dir/$bitcoind_filename"
  chmod +x "$download_dir/$bitcoin_cli_filename"
  
  # Step 3: Verify blockchain parts
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 3: Verifying Downloads"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Detect checksum format and verify
  if [[ -f "$download_dir/SHA256SUMS" ]]; then
    echo "Verifying blockchain parts (unified checksum)..."
    cd "$download_dir"
    
    local verify_failed=false
    while IFS= read -r line; do
      [[ "$line" =~ ^# ]] && continue  # Skip comments
      [[ -z "$line" ]] && continue     # Skip empty lines
      [[ ! "$line" =~ \.part[0-9][0-9] ]] && continue  # Skip non-part lines
      
      if ! echo "$line" | sha256sum -c --quiet 2>/dev/null; then
        echo "    ✗ Checksum failed for: $(echo "$line" | awk '{print $2}')"
        verify_failed=true
      fi
    done < "SHA256SUMS"
    
    if [[ "$verify_failed" == "true" ]]; then
      cd - >/dev/null
      pause "❌ One or more blockchain parts failed checksum verification!"
      return
    fi
    
    echo "    ✓ All blockchain parts verified"
    
    # Verify container image from same SHA256SUMS file
    echo ""
    echo "Verifying container image (unified checksum)..."
    if grep -q "$(basename "$container_image_name")" "SHA256SUMS" 2>/dev/null; then
      if sha256sum -c SHA256SUMS --ignore-missing --quiet 2>/dev/null; then
        echo "    ✓ Container image verified"
      else
        cd - >/dev/null
        pause "❌ Container image checksum verification failed!"
        return
      fi
    else
      echo "    ⚠ Container image not in SHA256SUMS (skipping verification)"
    fi
    
    # Verify VM image from same SHA256SUMS file (if downloaded)
    if [[ -n "$vm_image_url" ]] && [[ -f "$download_dir/$vm_image_name" ]]; then
      echo ""
      echo "Verifying VM image (unified checksum)..."
      if grep -q "$(basename "$vm_image_name")" "SHA256SUMS" 2>/dev/null; then
        if sha256sum -c SHA256SUMS --ignore-missing --quiet 2>/dev/null; then
          echo "    ✓ VM image verified"
        else
          echo "    ⚠ VM image checksum failed (optional, continuing...)"
        fi
      else
        echo "    ⚠ VM image not in SHA256SUMS (skipping verification)"
      fi
    fi
    
    cd - >/dev/null
  else
    echo "    ⚠ No checksum files found (skipping verification)"
  fi
  
  # Step 4: Reassemble blockchain
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 4: Reassembling Blockchain Data"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Reassemble blockchain from parts
  if ls "$download_dir"/blockchain.tar.gz.part* >/dev/null 2>&1; then
    cat "$download_dir"/blockchain.tar.gz.part* > "$download_dir/blockchain.tar.gz"
    echo "✓ Blockchain reassembled"
  else
    pause "❌ No blockchain parts found to reassemble!"
    return
  fi
  
  # Verify reassembled blockchain if checksum available
  if [[ -f "$download_dir/SHA256SUMS" ]]; then
    echo ""
    echo "Verifying reassembled blockchain..."
    cd "$download_dir"
    
    if grep -q "blockchain\.tar\.gz\$" "SHA256SUMS" 2>/dev/null; then
      if sha256sum -c SHA256SUMS --ignore-missing --quiet 2>/dev/null; then
        echo "    ✓ Reassembled blockchain verified"
      else
        cd - >/dev/null
        pause "❌ Reassembled blockchain checksum verification failed!"
        return
      fi
    else
      echo "    ⚠ No checksum entry for reassembled blockchain"
    fi
    
    cd - >/dev/null
  else
    echo "    ⚠ No checksum files found (skipping verification)"
  fi
  
  # Step 5: Extract and import container image
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 5: Importing Container Image"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  local container_extract_dir="$download_dir/container-image"
  mkdir -p "$container_extract_dir"
  
  echo "Extracting container image archive..."
  tar -xzf "$download_dir/$container_image_name" -C "$container_extract_dir"
  
  # Find the container tar file (handle both formats)
  local container_tar=$(find "$container_extract_dir" -name "container-image.tar" | head -n1)
  if [[ -z "$container_tar" ]]; then
    container_tar=$(find "$container_extract_dir" -name "garbageman-image.tar" | head -n1)
  fi
  if [[ -z "$container_tar" ]]; then
    pause "❌ No container-image.tar file found in container image archive"
    return
  fi
  
  echo "Found container image: $(basename "$container_tar")"
  echo ""
  
  # Load container image
  echo "Loading container image into $runtime..."
  if [[ "$runtime" == "docker" ]]; then
    container_cmd load -i "$container_tar" || {
      pause "❌ Failed to load container image"
      return
    }
  else
    container_cmd load -i "$container_tar" || {
      pause "❌ Failed to load container image"
      return
    }
  fi
  
  # Get the loaded image name
  local image_name
  image_name=$(container_cmd images --filter "reference=garbageman-base:latest" --format "{{.Repository}}:{{.Tag}}" | head -n1)
  if [[ -z "$image_name" ]]; then
    pause "❌ Failed to find loaded container image"
    return
  fi
  
  echo "    ✓ Container image loaded: $image_name"
  
  # Step 6: Create data volume and inject blockchain
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 6: Creating Data Volume and Injecting Blockchain"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  # Create volume
  echo "Creating data volume: garbageman-data..."
  if $runtime volume inspect garbageman-data >/dev/null 2>&1; then
    echo "    ⚠ Volume 'garbageman-data' already exists (removing old volume)"
    $runtime volume rm garbageman-data || {
      pause "❌ Failed to remove existing volume"
      return
    }
  fi
  
  $runtime volume create garbageman-data || {
    pause "❌ Failed to create data volume"
    return
  }
  
  echo "    ✓ Data volume created"
  echo ""
  
  # Extract blockchain
  echo "Extracting blockchain archive..."
  local blockchain_extract_dir="$download_dir/blockchain-data"
  mkdir -p "$blockchain_extract_dir"
  tar -xzf "$download_dir/blockchain.tar.gz" -C "$blockchain_extract_dir"
  
  # Inject blockchain into volume
  echo "Injecting blockchain into volume (this may take several minutes)..."
  container_cmd run --rm \
    -v garbageman-data:/data \
    -v "$blockchain_extract_dir:/import:ro" \
    alpine sh -c "cp -a /import/* /data/" || {
    pause "❌ Failed to inject blockchain data into volume"
    return
  }
  
  echo "    ✓ Blockchain injected"
  
  # Step 6b: Inject selected node binaries into temporary container
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 6b: Injecting Node Binaries"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  echo "Creating temporary container for binary injection..."
  local temp_container_name="gm-temp-$$"
  
  # Create a temporary container
  if ! container_cmd create --name "$temp_container_name" \
    -v garbageman-data:/var/lib/bitcoin \
    "$image_name" >/dev/null 2>&1; then
    echo "    ⚠ Failed to create temporary container, will try to inject binaries later"
  else
    # Copy binaries into the temporary container
    if container_cmd cp "$download_dir/$bitcoind_filename" "${temp_container_name}:/usr/local/bin/bitcoind" && \
       container_cmd cp "$download_dir/$bitcoin_cli_filename" "${temp_container_name}:/usr/local/bin/bitcoin-cli"; then
      
      # Set executable permissions
      container_cmd start "$temp_container_name" >/dev/null 2>&1
      container_cmd exec "$temp_container_name" chmod 755 /usr/local/bin/bitcoind /usr/local/bin/bitcoin-cli >/dev/null 2>&1 || true
      container_cmd stop "$temp_container_name" >/dev/null 2>&1
      
      echo "    ✓ Binaries injected and marked executable"
    else
      echo "    ⚠ Failed to inject binaries"
    fi
    
    # Remove temporary container
    container_cmd rm "$temp_container_name" >/dev/null 2>&1
  fi
  
  # Step 7: Create base container
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "Step 7: Creating Base Container"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  
  echo "    Configuring for CLEARNET_OK=${CLEARNET_OK}"
  
  # First, inject bitcoin.conf into the volume based on CLEARNET_OK
  local btc_conf_content
  if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
    echo "    Preparing config for: Tor + clearnet (faster sync)"
    btc_conf_content="server=1
prune=750
dbcache=450
maxconnections=25
listen=1
bind=0.0.0.0
onlynet=onion
onlynet=ipv4
listenonion=1
discover=1
dnsseed=1
proxy=127.0.0.1:9050
torcontrol=127.0.0.1:9051
[main]"
  else
    echo "    Preparing config for: Tor-only (maximum privacy)"
    btc_conf_content="server=1
prune=750
dbcache=450
maxconnections=25
onlynet=onion
proxy=127.0.0.1:9050
listen=1
bind=0.0.0.0
listenonion=1
discover=0
dnsseed=0
torcontrol=127.0.0.1:9051
[main]"
  fi
  
  # Create temporary file with bitcoin.conf
  local temp_conf=$(mktemp)
  echo "$btc_conf_content" > "$temp_conf"
  
  # Inject bitcoin.conf into the volume
  echo "    Injecting bitcoin.conf into volume..."
  if container_cmd run --rm \
    -v garbageman-data:/data \
    -v "$temp_conf:/bitcoin.conf:ro" \
    alpine:3.18 \
    sh -c 'cp /bitcoin.conf /data/bitcoin.conf && chmod 644 /data/bitcoin.conf' 2>/dev/null; then
    echo "    ✓ bitcoin.conf injected successfully"
    
    # Create container with bridge networking (isolated network namespace)
    # Port 8333 exposed only if CLEARNET_OK=yes (allows incoming clearnet with port forwarding)
    echo ""
    echo "Creating container '$CONTAINER_NAME' with custom configuration..."
    
    # Determine if we should expose P2P port (only for clearnet mode on base container)
    local port_args=""
    if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
      port_args="-p 8333:8333"
      echo "    Exposing port 8333 for incoming clearnet connections"
    fi
    
    container_cmd create \
      --name "$CONTAINER_NAME" \
      $port_args \
      -v garbageman-data:/var/lib/bitcoin \
      --memory="${SYNC_RAM_MB}m" \
      --memory-swap="${SYNC_RAM_MB}m" \
      --cpus="$SYNC_VCPUS" \
      "$image_name" \
      bitcoind -conf=/var/lib/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin || {
      # Fallback: create without custom command
      echo "    ⚠️  Failed to create with custom config, using default"
      
      # Re-determine port args for fallback
      local port_args=""
      if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
        port_args="-p 8333:8333"
      fi
      
      container_cmd create \
        --name "$CONTAINER_NAME" \
        $port_args \
        -v garbageman-data:/var/lib/bitcoin \
        --memory="${SYNC_RAM_MB}m" \
        --memory-swap="${SYNC_RAM_MB}m" \
        --cpus="$SYNC_VCPUS" \
        "$image_name" || {
        rm -f "$temp_conf"
        pause "❌ Failed to create base container"
        return
      }
    }
    echo "    ✓ Container configured to use custom bitcoin.conf"
  else
    echo "    ⚠️  Warning: Failed to inject config, creating with default from image"
    
    # Determine if we should expose P2P port
    local port_args=""
    if [[ "${CLEARNET_OK,,}" == "yes" ]]; then
      port_args="-p 8333:8333"
    fi
    
    container_cmd create \
      --name "$CONTAINER_NAME" \
      $port_args \
      -v garbageman-data:/var/lib/bitcoin \
      --memory="${SYNC_RAM_MB}m" \
      --memory-swap="${SYNC_RAM_MB}m" \
      --cpus="$SYNC_VCPUS" \
      "$image_name" || {
      rm -f "$temp_conf"
      pause "❌ Failed to create base container"
      return
    }
  fi
  
  rm -f "$temp_conf"
  
  echo "    ✓ Container created"
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                Container Import Complete!                                      ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "The base container '$CONTAINER_NAME' has been created with:"
  echo "  • Container image (Alpine Linux + $([ "$binary_suffix" == "-gm" ] && echo "Garbageman" || echo "Bitcoin Knots"))"
  echo "  • Complete blockchain data in volume 'garbageman-data'"
  if [[ -n "$vm_image_url" ]] && [[ -f "$download_dir/$vm_image_name" ]]; then
    echo "  • VM image (downloaded for later use)"
  fi
  echo ""
  echo "Downloaded files saved to:"
  echo "  $download_dir"
  echo ""
  echo "  ℹ You can copy this folder to USB stick for importing on another computer"
  echo "  ℹ Use 'Import from File' option and select the folder to import"
  if [[ -n "$vm_image_url" ]] && [[ -f "$download_dir/$vm_image_name" ]]; then
    echo "  ℹ Both VM and container images available - switch between them anytime"
  fi
  echo "  ℹ Temporary files cleaned up automatically"
  echo ""
  echo "Next steps:"
  echo "  • Start container with 'Monitor Base Container Sync' or 'Manage Base Container'"
  echo "  • Create clones for additional nodes"
  echo ""
  
  pause "Press Enter to return to main menu..."
}


################################################################################
# Deployment Mode Detection
################################################################################

# check_deployment_mode: Detect or prompt for VM vs Container deployment
# Purpose: Auto-detect based on existing gm-base VM or container
#          Only prompts user if neither exists yet
# Side effects: Sets global DEPLOYMENT_MODE variable ("vm" or "container")
# Detection Logic:
#   1. If gm-base VM exists → mode = "vm"
#   2. Else if gm-base container exists → mode = "container"
#   3. Else prompt user with comparison info
# Note: Once a base is created, deployment mode is locked to that type
check_deployment_mode(){
  # Check if gm-base VM exists
  if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    DEPLOYMENT_MODE="vm"
    return 0
  fi
  
  # Check if gm-base container exists
  if container_exists "$CONTAINER_NAME" 2>/dev/null; then
    DEPLOYMENT_MODE="container"
    return 0
  fi
  
  # Neither exists - prompt user
  local choice
  choice=$(whiptail --title "Choose Deployment Type" --menu \
"Welcome to Garbageman Nodes Manager!

This tool helps you run Bitcoin Garbageman nodes for resisting
spam in the Libre Relay network. You can deploy using either:

• Containers (RECOMMENDED) - Lightweight, faster startup
  - Uses Docker or Podman for container management  
  - Faster cloning and resource efficiency
  
• Virtual Machines (VMs) - Legacy implementation
  - Uses libvirt/qemu-kvm for VM management
  - Slower to start, but more stable on some systems

⚠️  NOTE: Garbageman NM is experimental software.

If you encounter issues with one method:
  1. Delete the base (via Manage menu)
  2. Exit and relaunch the script
  3. Try the other deployment type

Choose your deployment type:" 30 78 2 \
    "container" "Containers (recommended)" \
    "vm" "Virtual Machines (legacy)" \
    3>&1 1>&2 2>&3)
  
  if [[ -z "$choice" ]]; then
    echo "No deployment mode selected. Exiting."
    exit 0
  fi
  
  DEPLOYMENT_MODE="$choice"
}


################################################################################
# Main Menu & Entry Point
################################################################################

# main_menu: Interactive TUI menu loop (adaptive to deployment mode)
# Purpose: Primary user interface for VM or Container management operations
# Routes to appropriate implementation based on DEPLOYMENT_MODE
# Menu Options (available in both VM and Container modes):
#   1. Create Base - Build and configure initial VM/container (runs once)
#   2. Monitor Base Sync - Start and monitor IBD progress with live updates
#   3. Manage Base - Start/stop/status/export/delete/cleanup controls
#   4. Create Clones - Create additional Tor-only nodes with blockchain data copy
#   5. Manage Clones - Monitor, start, stop, or delete clones
#   6. Capacity Suggestions - Show host-aware resource recommendations (CPU/RAM/Disk)
#   7. Configure Defaults - Edit reserves, runtime sizes, clearnet option
#   8. Quit - Exit the script
# Loop: Continues until user selects Quit
main_menu(){
  # Route to appropriate menu based on deployment mode
  if [[ "$DEPLOYMENT_MODE" == "container" ]]; then
    main_menu_container
  else
    main_menu_vm
  fi
}

# main_menu_vm: VM-specific menu implementation
main_menu_vm(){
  while true; do
    detect_host_resources
    local base_exists="No"
    virsh_cmd dominfo "$VM_NAME" >/dev/null 2>&1 && base_exists="Yes"

    local header="Deployment: VMs (libvirt/qemu)
Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB   |   Reserve: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB} MiB
Available after reserve: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB} MiB
Base VM exists: ${base_exists}"

    local choice
    choice=$(whiptail --title "Garbageman Nodes Manager" --menu "$header\n\nChoose an action:" 24 92 10 \
      1 "Create Base VM (${VM_NAME})" \
      2 "Monitor Base VM Sync (${VM_NAME})" \
      3 "Manage Base VM (${VM_NAME})" \
      4 "Create Clone VMs (${CLONE_PREFIX}-*)" \
      5 "Manage Clone VMs (${CLONE_PREFIX}-*)" \
      6 "Capacity Suggestions (host-aware)" \
      7 "Configure Defaults (reserves, runtime, clearnet)" \
      8 "Quit" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1) create_base_vm ;;         # Action 1: Build Alpine VM, compile Garbageman inside, configure services
      2) monitor_sync ;;           # Action 2: Configure resources, start VM, monitor IBD progress
      3) quick_control ;;          # Action 3: Simple start/stop/status/export/delete controls
      4) clone_menu ;;             # Action 4: Create Tor-only clones from synced base
      5) clone_management_menu ;;  # Action 5: Manage existing clones (start/stop/delete)
      6) show_capacity_suggestions ;;  # Action 6: Show host-aware resource calculations
      7)
         # Action 7: Configure reserves, VM runtime sizes, clearnet toggle
         if configure_defaults; then
           pause "Defaults updated. Suggestions and capacity have been recalculated."
         fi
         ;;
      8) return ;;  # Action 8: Exit script
    esac
  done
}

# main_menu_container: Container-specific menu implementation
main_menu_container(){
  while true; do
    detect_host_resources
    local base_exists="No"
    container_exists "$CONTAINER_NAME" 2>/dev/null && base_exists="Yes"

    local header="Deployment: Containers ($(container_runtime))
Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB   |   Reserve: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB} MiB
Available after reserve: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB} MiB
Base Container exists: ${base_exists}"

    local choice
    choice=$(whiptail --title "Garbageman Container Manager" --menu "$header\n\nChoose an action:" 24 92 10 \
      1 "Create Base Container (${CONTAINER_NAME})" \
      2 "Monitor Base Container Sync (${CONTAINER_NAME})" \
      3 "Manage Base Container (${CONTAINER_NAME})" \
      4 "Create Clone Containers (${CONTAINER_CLONE_PREFIX}-*)" \
      5 "Manage Clone Containers (${CONTAINER_CLONE_PREFIX}-*)" \
      6 "Capacity Suggestions (host-aware)" \
      7 "Configure Defaults (reserves, runtime, clearnet)" \
      8 "Quit" \
      3>&1 1>&2 2>&3) || return

    case "$choice" in
      1) create_base_container ;;         # Action 1: Build container image, configure services
      2) monitor_container_sync ;;        # Action 2: Start container, monitor IBD progress
      3) manage_base_container ;;         # Action 3: Start/stop/status/export/delete controls
      4) clone_container_menu ;;          # Action 4: Create Tor-only container clones
      5) container_management_menu ;;     # Action 5: Manage existing container clones
      6) show_capacity_suggestions ;;     # Action 6: Show host-aware resource calculations
      7)
         # Action 7: Configure reserves, container runtime sizes, clearnet toggle
         if configure_defaults; then
           pause "Defaults updated. Suggestions and capacity have been recalculated."
         fi
         ;;
      8) return ;;  # Action 8: Exit script
    esac
  done
}


################################################################################
# Script Entry Point
################################################################################
# Execution starts here:
#   1. Detect deployment mode (VM or container) based on existing setup
#   2. Ensure all required tools are installed (installs if missing)
#   3. Launch main menu loop (runs until user quits)
# Note: Script requires bash and runs with set -euo pipefail for safety

check_deployment_mode  # Detect or prompt for VM vs container deployment
ensure_tools           # Install dependencies if needed
main_menu              # Start interactive TUI
