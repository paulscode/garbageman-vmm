#!/usr/bin/env bash
################################################################################
# garbageman-vmm.sh — All-in-one TUI for Garbageman VM lifecycle
#                     Tested on Linux Mint 22.2 (Ubuntu 24.04 base)
#
# Purpose:
#   Automate the creation and management of Bitcoin Garbageman nodes running
#   in lightweight Alpine Linux VMs. This script handles everything from
#   building the Bitcoin fork, creating base VMs, monitoring IBD sync, to
#   cloning multiple nodes each with their own Tor v3 onion address.
#
# Features:
#   - Build Garbageman (a Bitcoin Knots fork) INSIDE Alpine VM (native musl)
#   - Create a tiny Alpine Linux VM (headless, unattended) for the base node
#   - Pre-creation "Configure defaults" step:
#       * Host reserve policy (cores/RAM kept for desktop)
#       * Per-VM runtime resources (vCPUs/RAM) for base after sync + all clones
#       * Toggle: "Allow clearnet peers on one VM?" (YES => base is Tor+clearnet; clones remain Tor-only)
#   - Start & monitor IBD with a dialog progress UI (Stop on demand; auto-downsize base VM after sync)
#   - Clone the base VM any number of times; each clone:
#       * gets a fresh Tor v3 onion address
#       * is forced to Tor-only networking (privacy-preserving)
#   - Host-aware suggestions (vCPU/RAM for initial sync & clone capacity) with fixed reserve policy
#
# Architecture Notes:
#   - Host uses glibc (Ubuntu/Mint), VMs use musl (Alpine) - binaries are NOT compatible
#   - Solution: Build Garbageman INSIDE Alpine using virt-customize
#   - libguestfs creates temporary VMs for build operations
#   - Uses libvirt/qemu-kvm for VM management
#   - OpenRC init system in Alpine (not systemd)
#
# Requirements:
#   - libvirt/qemu-kvm on the host (script auto-installs if missing)
#   - Build tools: cmake, gcc, etc. (auto-installed)
#   - TUI tools: whiptail, dialog, jq (auto-installed)
################################################################################
set -euo pipefail

################################################################################
# User-tunable defaults (override via environment variables)
################################################################################
# These can be overridden before running the script, e.g.:
#   VM_NAME=my-node VM_RAM_MB=4096 ./garbageman-vmm.sh

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

# Clearnet toggle: "Allow clearnet peers on one VM?"
# If "yes", base VM uses Tor+clearnet for better connectivity during IBD
# Clones are ALWAYS Tor-only regardless of this setting (privacy-first)
CLEARNET_OK="${CLEARNET_OK:-yes}"        # "yes" or "no"
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
# Host Package Installation
################################################################################

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
  echo "Note: You may need to log out and back in for group membership to take effect."
  
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
    virsh_cmd net-start default 2>/dev/null || true
  fi
  
  return 0
}

# ensure_tools: Check for required commands and install if missing
# Purpose: Lazy installation - only installs packages when needed
ensure_tools(){
  for t in virsh virt-install virt-clone virt-customize virt-copy-in virt-builder guestfish jq curl git cmake; do
    cmd "$t" || install_deps
  done
  cmd dialog || sudo apt-get install -y dialog whiptail
  
  # Ensure the default network is available after tools are installed
  ensure_default_network || true
}


################################################################################
# Host Resource Detection & Capacity Suggestions
################################################################################
# The script detects host resources and suggests VM allocations based on:
#   - Total host CPU/RAM
#   - User-configured reserves (for host OS/desktop)
#   - VM runtime sizes (for long-term operation)
# Suggestions are recomputed whenever reserves or VM sizes change.

# Global variables for host resource tracking
HOST_CORES=0                    # Total CPU cores on host
HOST_RAM_MB=0                   # Total RAM on host (MiB)
AVAIL_CORES=0                   # Available cores after reserves
AVAIL_RAM_MB=0                  # Available RAM after reserves (MiB)
HOST_SUGGEST_SYNC_VCPUS="$SYNC_VCPUS_DEFAULT"   # Suggested vCPUs for initial IBD
HOST_SUGGEST_SYNC_RAM_MB="$SYNC_RAM_MB_DEFAULT" # Suggested RAM for initial IBD (MiB)
HOST_SUGGEST_CLONES=0           # Suggested number of clones (in addition to base)
HOST_RES_SUMMARY=""             # Formatted summary string for display

# detect_host_resources: Discover host resources and compute suggestions
# Purpose: Called before any resource-related UI to show current capacity
# Side effects: Updates all HOST_* global variables
detect_host_resources(){
  # Discover total host cores and RAM (MiB)
  HOST_CORES="$(nproc --all 2>/dev/null || echo 1)"
  HOST_RAM_MB="$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"

  # Budget after fixed reserves (editable via Configure Defaults)
  AVAIL_CORES=$(( HOST_CORES - RESERVE_CORES ))
  (( AVAIL_CORES < 0 )) && AVAIL_CORES=0

  AVAIL_RAM_MB=$(( HOST_RAM_MB - RESERVE_RAM_MB ))
  (( AVAIL_RAM_MB < 0 )) && AVAIL_RAM_MB=0

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
  local cpu_capacity=0 mem_capacity=0 total_vm_capacity=0
  if (( VM_VCPUS > 0 )); then
    cpu_capacity=$(( AVAIL_CORES / VM_VCPUS ))
  fi
  if (( VM_RAM_MB > 0 )); then
    mem_capacity=$(( AVAIL_RAM_MB / VM_RAM_MB ))
  fi
  # Take the smaller of CPU or memory capacity (whichever is more constrained)
  total_vm_capacity="$cpu_capacity"
  (( mem_capacity < total_vm_capacity )) && total_vm_capacity="$mem_capacity"
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

Reserves to keep for the host:
  - CPU cores reserved: ${RESERVE_CORES}
  - RAM reserved: ${RESERVE_RAM_MB} MiB

Available for VMs (after reserve):
  - CPU cores: ${AVAIL_CORES}
  - RAM: ${AVAIL_RAM_MB} MiB

Suggested INITIAL SYNC (base VM only):
  - vCPUs: ${HOST_SUGGEST_SYNC_VCPUS}
  - RAM:   ${HOST_SUGGEST_SYNC_RAM_MB} MiB

Post-sync runtime (each VM uses vCPUs=${VM_VCPUS}, RAM=${VM_RAM_MB} MiB):
  - Estimated total VMs possible simultaneously: ${total_vm_capacity}
  - Suggested number of clones (besides base): ${HOST_SUGGEST_CLONES}
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

# configure_defaults: Interactive menu to reset or edit reserves, VM sizes, and clearnet option
# Purpose: Allows users to reset to original host-aware defaults or tune resource allocation manually
# Options:
#   1. Reset to Original Values - Sets hardcoded defaults (2 cores, 4GB reserve, 1 vCPU, 2GB RAM per VM)
#   2. Choose Custom Values - Interactive prompts for each setting
# Returns: 0 on success (changes saved), 1 on cancel
# Side effects: Updates global variables (RESERVE_*, VM_*, CLEARNET_OK)
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
  
  echo "=========================================="
  echo "Building Garbageman inside Alpine VM..."
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
  
  # Step 2: Clone the Garbageman repository
  echo "Step 2/4: Cloning Garbageman repository..."
  echo "Repository: $GM_REPO (branch: $GM_BRANCH)"
  sudo virt-customize -a "$disk" \
    --no-selinux-relabel \
    --run-command "cd /tmp && git clone --branch '$GM_BRANCH' --depth 1 '$GM_REPO' garbageman" \
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
  echo "Step 3b/4: Compiling Garbageman (this takes 2+ hours)..."
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
  
  # Debug: Check sudo keepalive status
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
gssh(){
  local ip="$1"; shift
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$SSH_KEY_DIR/known_hosts" \
      -o ConnectTimeout=5 -p "$SSH_PORT" "${SSH_USER}@${ip}" "$@"
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

# Enable root login temporarily
echo "$(date): Configuring SSH" >> /var/log/first-boot.log
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo 'root:garbageman' | chpasswd

# Start SSH service
service sshd start || /etc/init.d/sshd start || {
  echo "$(date): Starting sshd manually" >> /var/log/first-boot.log
  /usr/sbin/sshd -D &
}

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

# import_base_vm: Import base VM from exported archive
# Purpose: Alternative to building from scratch - imports sanitized export
# Flow:
#   1. Scan ~/Downloads for gm-base-export-* archives
#   2. Let user select one
#   3. Verify SHA256 checksum
#   4. Extract archive and read metadata
#   5. Check for existing VM/disk and handle cleanup if needed
#   6. Copy disk image to /var/lib/libvirt/images/
#   7. Configure resource allocation
#   8. Inject monitoring SSH key directly into disk (before VM creation)
#   9. Create libvirt domain with virt-install --import
#  10. Stop the auto-started VM (ready for manual startup)
# Prerequisites: Same as create_base_vm (ensures tools installed)
# Side effects: Creates VM disk at /var/lib/libvirt/images/${VM_NAME}.qcow2
# Note: If importing stale blockchain (>2h old), sync monitoring will detect
#       and wait for peers to connect and catch up to current block height
import_base_vm(){
  # Start sudo keepalive for potential long operations
  sudo_keepalive_start force
  
  ensure_tools

  # Scan for export archives in ~/Downloads
  echo "Scanning ~/Downloads for export archives..."
  local archives=()
  local archive_list=""
  
  while IFS= read -r -d '' archive; do
    archives+=("$archive")
    local basename=$(basename "$archive")
    local size=$(du -h "$archive" | cut -f1)
    archive_list="${archive_list}${basename} (${size})\n"
  done < <(find "$HOME/Downloads" -maxdepth 1 -name "gm-base-export-*.tar.gz" -print0 2>/dev/null | sort -z)
  
  if [[ ${#archives[@]} -eq 0 ]]; then
    pause "No export archives found in ~/Downloads.\n\nLooking for files matching: gm-base-export-*.tar.gz"
    return
  fi
  
  echo "Found ${#archives[@]} export archive(s)"
  
  # Build menu options for whiptail
  local menu_items=()
  for i in "${!archives[@]}"; do
    local archive="${archives[$i]}"
    local basename=$(basename "$archive")
    local size=$(du -h "$archive" | cut -f1)
    local timestamp=$(echo "$basename" | sed 's/gm-base-export-\(.*\)\.tar\.gz/\1/')
    menu_items+=("$i" "${timestamp} (${size})")
  done
  
  # Let user select archive
  local selection
  selection=$(whiptail --title "Select Export Archive" \
    --menu "Choose an export archive to import:\n\nFound in: ~/Downloads" \
    20 78 10 \
    "${menu_items[@]}" \
    3>&1 1>&2 2>&3) || return
  
  local selected_archive="${archives[$selection]}"
  local selected_basename=$(basename "$selected_archive")
  
  echo ""
  echo "Selected: $selected_basename"
  
  # Check for SHA256 checksum file
  local checksum_file="${selected_archive}.sha256"
  if [[ ! -f "$checksum_file" ]]; then
    pause "❌ Checksum file not found: ${selected_basename}.sha256\n\nCannot verify integrity. Import aborted."
    return
  fi
  
  echo "Checksum file found: ${selected_basename}.sha256"
  
  # Verify checksum
  echo "Verifying SHA256 checksum..."
  if ! (cd "$HOME/Downloads" && sha256sum -c "$selected_basename.sha256" 2>&1 | grep -q "OK"); then
    pause "❌ Checksum verification FAILED!\n\nThe archive may be corrupted or tampered with.\n\nImport aborted for security."
    return
  fi
  
  echo "✅ Checksum verified successfully"
  
  # Show import confirmation
  if ! whiptail --title "Confirm Import" \
    --yesno "Ready to import base VM from:\n\n${selected_basename}\n\nThis will:\n• Extract the archive\n• Import the disk image to /var/lib/libvirt/images/\n• Create the VM definition\n• Configure for this system\n\nProceed with import?" \
    16 78; then
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
  
  # Extract archive
  echo "[1/5] Extracting archive (this may take a few minutes)..."
  if ! tar -xzf "$selected_archive" -C "$temp_extract_dir"; then
    rm -rf "$temp_extract_dir"
    pause "❌ Failed to extract archive"
    return
  fi
  
  # Find the extracted directory (should be gm-base-export-YYYYMMDD-HHMMSS)
  local extract_dir=$(find "$temp_extract_dir" -maxdepth 1 -type d -name "gm-base-export-*" | head -n1)
  if [[ -z "$extract_dir" ]]; then
    rm -rf "$temp_extract_dir"
    pause "❌ Could not find extracted directory in archive"
    return
  fi
  
  echo "    ✓ Archive extracted"
  
  # Verify disk image exists
  local source_disk="${extract_dir}/gm-base.qcow2"
  if [[ ! -f "$source_disk" ]]; then
    rm -rf "$temp_extract_dir"
    pause "❌ Disk image not found in archive: gm-base.qcow2"
    return
  fi
  
  # Read metadata if available
  local metadata_file="${extract_dir}/metadata.json"
  if [[ -f "$metadata_file" ]]; then
    echo ""
    echo "[2/5] Reading metadata..."
    local export_date script_name blockchain_height
    export_date=$(jq -r '.export_date // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
    script_name=$(jq -r '.script_name // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
    blockchain_height=$(jq -r '.blockchain.height_at_export // "unknown"' "$metadata_file" 2>/dev/null || echo "unknown")
    
    echo "    Export date: $export_date"
    echo "    Script: $script_name"
    echo "    Blockchain height at export: $blockchain_height"
    echo "    ✓ Metadata read"
  fi
  
  # Copy disk image to libvirt images directory
  echo ""
  echo "[3/5] Copying disk image to /var/lib/libvirt/images/..."
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
  
  # Clean up extraction directory
  rm -rf "$temp_extract_dir"
  
  # Let user configure defaults for resource allocation
  echo ""
  echo "[4/5] Configuring VM resources..."
  
  if ! configure_defaults_direct; then
    echo "    Using default resource settings"
  fi
  
  # Prompt for initial resources (in case user wants to start it right away)
  if ! prompt_sync_resources; then
    # Use defaults if cancelled
    detect_host_resources
    SYNC_RAM_MB=$HOST_SUGGEST_SYNC_RAM
    SYNC_VCPUS=$HOST_SUGGEST_SYNC_VCPUS
  fi
  
  # Inject monitoring SSH key BEFORE creating the VM domain
  # This must happen while the disk is not in use by any VM
  echo ""
  echo "[5/5] Configuring monitoring access..."
  
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
  sudo virt-install \
    --name "$VM_NAME" \
    --memory "$SYNC_RAM_MB" --vcpus "$SYNC_VCPUS" --cpu host \
    --disk "path=$dest_disk,format=qcow2,bus=virtio" \
    --network "network=default,model=virtio" \
    --osinfo alpinelinux3.18 \
    --graphics none --noautoconsole \
    --import >/dev/null 2>&1
  
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

# import_from_github: Import base VM from GitHub release
# Purpose: Download and import pre-built VM from GitHub releases
# Flow:
#   1. Fetch available releases from GitHub API
#   2. Let user select a release tag
#   3. Download all parts with progress indicators
#   4. Reassemble the archive
#   5. Verify checksum
#   6. Hand off to standard import process
# Prerequisites: curl or wget for downloads, jq for JSON parsing
# Side effects: Downloads ~22GB to /tmp, then imports to libvirt
import_from_github(){
  local repo="paulscode/garbageman-vmm"
  local api_url="https://api.github.com/repos/$repo/releases"
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                    Import Base VM from GitHub Release                          ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
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
    pause "No releases found with VM exports."
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
  
  # Find all part files and checksum
  local part_urls=()
  local part_names=()
  local checksum_url=""
  local checksum_name=""
  
  while IFS='|' read -r name url; do
    [[ -z "$name" ]] && continue
    if [[ "$name" =~ \.part[0-9]+$ ]]; then
      part_names+=("$name")
      part_urls+=("$url")
    elif [[ "$name" == "gm-base-export.tar.gz.sha256" ]]; then
      checksum_name="$name"
      checksum_url="$url"
    fi
  done < <(echo "$release_assets" | jq -r '.[] | "\(.name)|\(.browser_download_url)"')
  
  if [[ ${#part_urls[@]} -eq 0 ]]; then
    pause "❌ No export parts found in release $selected_tag"
    return
  fi
  
  # Warn about download size
  echo "⚠  Download size: ~22 GB (${#part_urls[@]} parts)"
  echo ""
  if ! whiptail --title "Confirm Download" \
    --yesno "This will download approximately 22 GB of data.\n\nParts to download: ${#part_urls[@]}\nRelease: $selected_tag\n\nContinue?" \
    12 70; then
    echo "Download cancelled."
    return
  fi
  
  # Create temporary download directory
  local temp_dir=$(mktemp -d -t gm-github-import-XXXXXX)
  trap "rm -rf '$temp_dir'" RETURN EXIT INT TERM
  
  echo ""
  echo "Downloading to: $temp_dir"
  echo ""
  
  # Download all parts with progress
  for i in "${!part_urls[@]}"; do
    local part_name="${part_names[$i]}"
    local part_url="${part_urls[$i]}"
    local part_num=$((i + 1))
    
    echo "[Part $part_num/${#part_urls[@]}] Downloading $part_name..."
    
    if [[ "$download_tool" == "curl" ]]; then
      curl -L --progress-bar -o "$temp_dir/$part_name" "$part_url" || {
        pause "❌ Failed to download $part_name"
        return
      }
    else
      wget --show-progress -O "$temp_dir/$part_name" "$part_url" || {
        pause "❌ Failed to download $part_name"
        return
      }
    fi
  done
  
  # Download checksum file if available
  if [[ -n "$checksum_url" ]]; then
    echo ""
    echo "Downloading checksum file..."
    if [[ "$download_tool" == "curl" ]]; then
      curl -sL -o "$temp_dir/$checksum_name" "$checksum_url"
    else
      wget -q -O "$temp_dir/$checksum_name" "$checksum_url"
    fi
  fi
  
  # Verify checksums of downloaded parts if available
  if [[ -f "$temp_dir/$checksum_name" ]]; then
    echo ""
    echo "Verifying downloaded parts..."
    cd "$temp_dir"
    
    # Extract only the part checksums (ignore comments and reassembled file checksum)
    local verify_failed=false
    while IFS= read -r line; do
      [[ "$line" =~ ^# ]] && continue  # Skip comments
      [[ -z "$line" ]] && continue     # Skip empty lines
      [[ ! "$line" =~ \.part[0-9][0-9] ]] && continue  # Skip non-part lines
      
      if ! echo "$line" | sha256sum -c --quiet 2>/dev/null; then
        echo "    ✗ Checksum failed for: $(echo "$line" | awk '{print $2}')"
        verify_failed=true
      fi
    done < "$checksum_name"
    
    if [[ "$verify_failed" == "true" ]]; then
      cd - >/dev/null
      pause "❌ One or more parts failed checksum verification!"
      return
    fi
    
    echo "    ✓ All parts verified"
    cd - >/dev/null
  fi
  
  # Reassemble the archive
  echo ""
  echo "Reassembling archive..."
  cat "$temp_dir"/gm-base-export.tar.gz.part* > "$temp_dir/gm-base-export.tar.gz"
  echo "    ✓ Archive reassembled"
  
  # Verify reassembled archive checksum if available
  if [[ -f "$temp_dir/$checksum_name" ]]; then
    echo ""
    echo "Verifying reassembled archive..."
    cd "$temp_dir"
    
    # Look for the reassembled file checksum (non-comment, non-part line)
    local reassembled_checksum=""
    while IFS= read -r line; do
      [[ "$line" =~ ^# ]] && continue  # Skip comments
      [[ -z "$line" ]] && continue     # Skip empty lines
      [[ "$line" =~ \.part[0-9][0-9] ]] && continue  # Skip part lines
      
      # This should be the reassembled file checksum
      reassembled_checksum="$line"
      break
    done < "$checksum_name"
    
    if [[ -n "$reassembled_checksum" ]]; then
      if echo "$reassembled_checksum" | sha256sum -c --quiet 2>/dev/null; then
        echo "    ✓ Reassembled archive verified"
      else
        cd - >/dev/null
        pause "❌ Reassembled archive checksum verification failed!"
        return
      fi
    else
      echo "    ⚠ No reassembled archive checksum found (skipping)"
    fi
    
    cd - >/dev/null
  fi
  
  # Move to Downloads and create matching .sha256 file
  echo ""
  echo "Moving to ~/Downloads for import..."
  local timestamp=$(date +%Y%m%d-%H%M%S)
  local final_name="gm-base-export-${timestamp}-github.tar.gz"
  mv "$temp_dir/gm-base-export.tar.gz" "$HOME/Downloads/$final_name"
  
  if [[ -f "$temp_dir/$checksum_name" ]]; then
    # Create checksum for the final file
    (cd "$HOME/Downloads" && sha256sum "$final_name" > "${final_name}.sha256")
  fi
  
  echo "    ✓ Saved to ~/Downloads/$final_name"
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                        Download Complete!                                      ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # Ask if user wants to import now
  if whiptail --title "Import Now?" \
    --yesno "Download complete!\n\nWould you like to import this VM now?" \
    10 70; then
    # Call standard import, but we need to set up the selection to point to our file
    # For now, just inform the user
    echo ""
    echo "Starting import process..."
    echo ""
    import_base_vm
  else
    pause "Download complete!\n\nThe archive is in ~/Downloads/$final_name\nYou can import it later via 'Create Base VM' → 'Import from file'"
  fi
}

################################################################################
# Create Base VM (Action 1)
################################################################################

# create_base_vm: Main entry point for Action 1
# Purpose: Offers choice between building from scratch or importing
# Flow:
#   1. Check if VM already exists (abort if it does)
#   2. Present menu: "Build from scratch" or "Import from file"
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
    "1" "Build from scratch (compile: 2+ hours, sync: 24-28 hours)" \
    "2" "Import from file (local export in ~/Downloads)" \
    "3" "Import from GitHub (download ~22GB from latest release)" \
    3>&1 1>&2 2>&3) || return
  
  case "$choice" in
    1) create_base_vm_from_scratch ;;
    2) import_base_vm ;;
    3) import_from_github ;;
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
  
  # Build Garbageman inside the Alpine VM (native musl build)
  build_garbageman_in_vm "$disk"

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
  sudo virt-install \
    --name "$VM_NAME" \
    --memory "$SYNC_RAM_MB" --vcpus "$SYNC_VCPUS" --cpu host \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --network "network=default,model=virtio" \
    --osinfo alpinelinux3.18 \
    --graphics none --noautoconsole \
    --import

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
  
  echo "=========================================="
  echo "Starting VM and waiting for network..."
  echo "This will take up to ${HOST_WAIT_SSH} seconds."
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

  # Set up trap to handle Ctrl+C and clean up background processes
  trap 'echo ""; echo "Monitor interrupted. VM is still running."; return' INT

  # Use a simple watch-style display instead of whiptail for auto-refresh
  echo ""
  echo "=========================================="
  echo "Monitoring IBD Progress"
  echo "Press Ctrl+C to exit (VM will keep running)"
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
    
    local blocks headers vp ibd pct peers time_block
    blocks="$(jq -r '.blocks // 0' <<<"$info" 2>/dev/null || echo 0)"
    headers="$(jq -r '.headers // 0' <<<"$info" 2>/dev/null || echo 0)"
    vp="$(jq -r '.verificationprogress // 0' <<<"$info" 2>/dev/null || echo 0)"
    ibd="$(jq -r '.initialblockdownload // true' <<<"$info" 2>/dev/null || echo true)"
    peers="$(jq -r '.connections // 0' <<<"$netinfo" 2>/dev/null || echo 0)"
    time_block="$(jq -r '.time // 0' <<<"$info" 2>/dev/null || echo 0)"
    pct=$(awk -v p="$vp" 'BEGIN{if(p<0)p=0;if(p>1)p=1;printf "%d", int(p*100+0.5)}')

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
    printf "║%-80s║\n" "    Blocks:   ${blocks} / ${headers}"
    printf "║%-80s║\n" "    Progress: ${pct}% (${vp})"
    printf "║%-80s║\n" "    IBD:      ${ibd}"
    printf "║%-80s║\n" "    Peers:    ${peers}"
    if [[ -n "$sync_status_msg" ]]; then
      printf "║%-80s║\n" "    Status:   ${sync_status_msg}"
    fi
    printf "║%-80s║\n" ""
    printf "╠════════════════════════════════════════════════════════════════════════════════╣\n"
    printf "║%-80s║\n" "  Auto-refreshing every ${POLL_SECS} seconds... Press Ctrl+C to exit"
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
      elif [[ "$blocks" -ge "$headers" && "$pct" -ge 99 ]]; then
        # Stale tip was detected, but blocks caught up to headers - consider complete
        should_complete=true
      elif [[ "$blocks" -gt "$stale_tip_initial_blocks" ]]; then
        # Stale tip was detected and blocks are still advancing - keep waiting
        should_complete=false
      else
        # Stale tip detected, waited 2 minutes, no new blocks - consider done
        local wait_elapsed=$((current_time - stale_tip_wait_start))
        if [[ "$wait_elapsed" -ge 120 ]]; then
          should_complete=true
        fi
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
    
    sleep "$POLL_SECS"
  done
  
  return
}

################################################################################
# Export Base VM (Action 3 - Manage Base VM submenu)
################################################################################

# export_base_vm: Create a sanitized, portable export of the base VM
# Purpose: Package the base VM for import on another system
# Security: Removes all sensitive/identifying information:
#   - Tor hidden service keys (forces fresh .onion address)
#   - SSH authorized keys (host-specific monitoring key)
#   - Tor control cookie and state data
#   - Bitcoin peer databases (peers.dat, anchors.dat, banlist.dat)
#   - Bitcoin debug logs (may contain peer IPs)
#   - Machine identifiers (machine-id, SSH host keys)
#   - System logs
# Flow:
#   1. Check base VM exists and is synced (warn if not)
#   2. Ensure base VM is shut off (graceful shutdown if running)
#   3. Create temporary clone for sanitization (preserves original)
#   4. Sanitize clone using virt-sysprep + manual cleanup
#   5. Compress disk image and create metadata JSON
#   6. Package as tar.gz archive
#   7. Clean up temporary clone
# Output: Creates gm-base-export-YYYYMMDD-HHMMSS.tar.gz in ~/Downloads
#         Contains: sanitized qcow2 disk + metadata.json
export_base_vm(){
  ensure_tools
  
  # Check if base VM exists
  sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1 || die "Base VM '$VM_NAME' not found. Nothing to export."
  
  # Check if VM is synced (optional warning, not blocking)
  echo "Checking sync status..."
  local current_state
  current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
  
  local sync_warning=""
  if [[ "$current_state" == "running" ]]; then
    local ip
    ip=$(vm_ip "$VM_NAME" 2>/dev/null || echo "")
    
    if [[ -n "$ip" ]]; then
      local blocks headers
      local info
      info=$(gssh "$ip" '/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>/dev/null' 2>/dev/null || echo "")
      blocks=$(jq -r '.blocks // ""' <<<"$info" 2>/dev/null || echo "")
      headers=$(jq -r '.headers // ""' <<<"$info" 2>/dev/null || echo "")
      
      if [[ -n "$blocks" && -n "$headers" && "$blocks" != "$headers" ]]; then
        sync_warning="\n⚠️  WARNING: Blockchain may not be fully synced (blocks: $blocks / $headers)"
      fi
    fi
  fi
  
  # Confirm export with user
  if ! whiptail --title "Export Base VM" --yesno \
    "This will create a sanitized, portable export of '$VM_NAME'.\n\n\
Security measures:\n\
• Removes Tor keys (forces fresh .onion on import)\n\
• Removes SSH keys and machine identifiers\n\
• Clears peer databases and logs\n\
• Resets to generic Tor-only configuration\n\n\
Export will be saved to: ~/Downloads/\n\
Size: ~10-15 GB compressed (may take 10-30 minutes)\n\n\
The base VM will be shut down during export (if running).\n\
Original VM will remain intact.${sync_warning}\n\n\
Proceed with export?" 24 78; then
    return
  fi
  
  # Generate export name with timestamp
  local export_timestamp
  export_timestamp=$(date +%Y%m%d-%H%M%S)
  local export_name="gm-base-export-${export_timestamp}"
  local export_dir="$HOME/Downloads/${export_name}"
  local temp_clone="${VM_NAME}-export-temp"
  
  # Create export directory
  mkdir -p "$export_dir" || die "Failed to create export directory: $export_dir"
  
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                          Exporting Base VM                                     ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  
  # Step 1: Shut down base VM if running
  echo "[1/7] Ensuring base VM is shut down..."
  current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
  
  if [[ "$current_state" == "running" ]]; then
    echo "      Base VM is running. Shutting down gracefully..."
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
  echo "[2/7] Creating temporary clone for sanitization..."
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
  echo "[3/7] Sanitizing VM (removing sensitive data)..."
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
  
  # Step 4: Additional cleanup specific to Bitcoin/Tor
  echo ""
  echo "[4/7] Removing Bitcoin/Tor sensitive data..."
  
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
    rm -rf "$export_dir"
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
    rm -rf "$export_dir"
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
    rm -rf "$export_dir"
    die "Export failed during bitcoin.conf reset"
  }
  
  # Reset hostname to generic gm-base
  sudo virt-customize -d "$temp_clone" --no-selinux-relabel \
    --hostname "gm-base" \
    2>&1 | grep -v "random seed" >&2 || true
  
  echo "      ✓ Bitcoin/Tor data sanitized"
  
  # Step 5: Gather metadata before undefining the domain
  echo ""
  echo "[5/7] Gathering metadata..."
  
  # Get VM specs
  local vm_ram vm_vcpus vm_disk_size
  vm_ram=$(sudo virsh dominfo "$temp_clone" | grep "Max memory:" | awk '{print $3}')
  vm_vcpus=$(sudo virsh dominfo "$temp_clone" | grep "CPU(s):" | awk '{print $2}')
  vm_disk_size=$(sudo qemu-img info "$temp_disk" | grep "virtual size:" | awk '{print $3, $4}')
  
  # Try to get blockchain height from previous status check
  local blockchain_height="unknown"
  if [[ -n "$blocks" ]]; then
    blockchain_height="$blocks"
  fi
  
  # Create metadata JSON
  local metadata_file="$export_dir/metadata.json"
  cat > "$metadata_file" <<METADATA
{
  "export_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "export_timestamp": "$export_timestamp",
  "vm_name": "$VM_NAME",
  "script_name": "garbageman-vmm.sh",
  "vm_specs": {
    "ram_mb": "$vm_ram",
    "vcpus": "$vm_vcpus",
    "disk_size": "$vm_disk_size",
    "disk_format": "qcow2"
  },
  "blockchain": {
    "height_at_export": "$blockchain_height",
    "pruned": true,
    "prune_target": "750 MiB"
  },
  "network_config": {
    "tor_only": true,
    "onlynet": "onion",
    "note": "Fresh Tor keys will be generated on first boot"
  },
  "repository": {
    "url": "$GM_REPO",
    "branch": "$GM_BRANCH"
  },
  "sanitization": {
    "tor_keys_removed": true,
    "ssh_keys_removed": true,
    "peer_databases_cleared": true,
    "logs_cleared": true,
    "machine_id_reset": true
  },
  "import_notes": [
    "This VM has been sanitized for secure import",
    "Tor hidden service keys have been removed - fresh .onion will be generated",
    "SSH host keys have been removed - will be regenerated on first boot",
    "Peer databases cleared - VM will discover new peers independently",
    "Bitcoin configuration reset to generic Tor-only setup",
    "Recommended: 2+ GB RAM, 1+ vCPU for normal operation",
    "Initial sync resources were higher, but blockchain is already synced"
  ]
}
METADATA
  echo "      ✓ Metadata created: metadata.json"
  
  # Step 6: Copy disk image to export directory and compress
  echo ""
  echo "[6/7] Copying and compressing disk image..."
  echo "      This will take several minutes (10-15 GB)..."
  
  # Copy the qcow2 disk to export directory
  sudo cp "$temp_disk" "$export_dir/${VM_NAME}.qcow2" || {
    echo "      ✗ Failed to copy disk image"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir"
    die "Export failed during disk copy"
  }
  
  # Fix ownership so user can access the exported files
  sudo chown -R "$USER:$USER" "$export_dir"
  
  echo "      ✓ Disk image copied"
  
  # Create compressed archive
  echo "      Creating compressed archive (this may take 10-20 minutes)..."
  local archive_name="${export_name}.tar.gz"
  local archive_path="$HOME/Downloads/${archive_name}"
  
  tar -czf "$archive_path" -C "$HOME/Downloads" "$export_name" || {
    echo "      ✗ Failed to create compressed archive"
    sudo virsh destroy "$temp_clone" >/dev/null 2>&1 || true
    sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
    sudo rm -f "$temp_disk" 2>/dev/null || true
    rm -rf "$export_dir"
    die "Export failed during compression"
  }
  
  local archive_size
  archive_size=$(du -h "$archive_path" | cut -f1)
  echo "      ✓ Archive created: ${archive_name} (${archive_size})"
  
  # Generate SHA256 checksum for archive verification
  echo "      Generating SHA256 checksum..."
  local checksum_file="${archive_path}.sha256"
  (cd "$HOME/Downloads" && sha256sum "${archive_name}" > "${archive_name}.sha256") || {
    echo "      ⚠ Warning: Failed to generate checksum file"
  }
  
  if [[ -f "$checksum_file" ]]; then
    echo "      ✓ Checksum created: ${archive_name}.sha256"
  fi
  
  # Step 7: Cleanup
  echo ""
  echo "[7/7] Cleaning up temporary files..."
  
  # Remove temporary clone
  sudo virsh undefine "$temp_clone" >/dev/null 2>&1 || true
  sudo rm -f "$temp_disk" 2>/dev/null || true
  
  # Remove uncompressed export directory (we have the .tar.gz)
  rm -rf "$export_dir"
  
  echo "      ✓ Temporary files removed"
  
  # Success!
  echo ""
  echo "╔════════════════════════════════════════════════════════════════════════════════╗"
  echo "║                        Export Complete!                                        ║"
  echo "╚════════════════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "📦 Exported files:"
  echo "   Archive:  $archive_path"
  echo "   Checksum: ${archive_path}.sha256"
  echo "   Size:     $archive_size"
  echo ""
  echo "📋 Archive contains:"
  echo "   • ${VM_NAME}.qcow2 (sanitized disk image)"
  echo "   • metadata.json (VM specifications and import info)"
  echo ""
  echo "🔐 Verify integrity after transfer:"
  echo "   cd ~/Downloads && sha256sum -c ${archive_name}.sha256"
  echo ""
  echo "🔒 Security: All sensitive data has been removed:"
  echo "   ✓ Tor keys cleared (fresh .onion on import)"
  echo "   ✓ SSH keys removed (regenerated on import)"
  echo "   ✓ Peer databases cleared"
  echo "   ✓ Logs and machine identifiers reset"
  echo ""
  echo "📤 This archive can be safely transferred to another system."
  echo "   Use the import feature to create gm-base from this export."
  echo ""
  
  pause "Export saved to: $archive_path"
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
Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB   |   Reserve: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB} MiB
Available after reserve: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB} MiB

Post-sync per-VM: vCPUs=${VM_VCPUS}, RAM=${VM_RAM_MB} MiB
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
        current_state=$(vm_state "$clone_name" 2>/dev/null || echo "unknown")
        local info="State: ${current_state}"
        
        if [[ "$current_state" == "running" ]]; then
          local ip
          ip=$(vm_ip "$clone_name" 2>/dev/null || echo "unknown")
          info="${info}\nIP: ${ip}"
        fi
        
        pause "$info"
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
# Quick VM Controls (Action 3)
################################################################################

# quick_control: Simple start/stop/status/export/delete menu for base VM
# Purpose: Convenient VM power management, export, and deletion without full monitoring
# Features:
#   - Displays VM state in menu header
#   - If VM is running, shows .onion address and block height (like clone management)
#   - Provides start/stop/state/export/delete actions
# Actions:
#   - start: Power on the VM (virsh start)
#   - stop: Graceful shutdown (virsh shutdown)
#   - state: Display current VM state and IP address
#   - export: Create sanitized, portable export for transfer to another system
#   - delete: Permanently delete VM and disk (requires double confirmation)
#   - back: Return to main menu
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
    sub=$(whiptail --title "Quick VM Controls" --menu "Control VM: ${VM_NAME}\nCurrent state: ${current_state}${extra_info}\n\nChoose an action:" 24 78 8 \
          "start" "Power on the VM" \
          "stop" "Gracefully shutdown the VM" \
          "state" "Check current VM status" \
          "export" "Export VM for transfer to another system" \
          "delete" "Delete VM permanently (requires confirmation)" \
          "back" "Return to main menu" \
          3>&1 1>&2 2>&3) || return
    case "$sub" in
      start) 
        sudo virsh start "$VM_NAME" >/dev/null || true
        pause "VM '${VM_NAME}' has been started (if it wasn't already running)."
        ;;
      stop)  
        sudo virsh shutdown "$VM_NAME" || true
        pause "Shutdown command sent to VM '${VM_NAME}'."
        ;;
      state) 
        current_state=$(vm_state "$VM_NAME" 2>/dev/null || echo "unknown")
        local info="State: ${current_state}"
        
        if [[ "$current_state" == "running" ]]; then
          local ip
          ip=$(vm_ip "$VM_NAME" 2>/dev/null || echo "unknown")
          info="${info}\nIP: ${ip}"
        fi
        
        pause "$info"
        ;;
      export)
        export_base_vm
        ;;
      delete)
        # Confirmation dialog with strong warning
        if whiptail --title "⚠️  DELETE BASE VM" \
          --yesno "Are you SURE you want to delete '${VM_NAME}'?\n\n⚠️  WARNING: This action is PERMANENT and IRREVERSIBLE!\n\nThis will:\n• Destroy the VM definition\n• Delete the disk image (all blockchain data)\n• Remove all configuration\n\nYou will need to rebuild or re-import to use this VM again.\n\nProceed to confirmation step?" \
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
      back)
        return
        ;;
      *) : ;;
    esac
  done
}


################################################################################
# Main Menu & Entry Point
################################################################################

# main_menu: Interactive TUI menu loop
# Purpose: Primary user interface for all VM management operations
# Menu Options:
#   1. Create Base VM - Build and configure initial VM (runs once)
#   2. Monitor Base VM Sync - Start VM and monitor IBD progress
#   3. Manage Base VM - Simple start/stop/status/export/delete controls
#   4. Create Clone VMs - Create additional Tor-only nodes
#   5. Manage Clone VMs - Start, stop, or delete clone VMs
#   6. Capacity Suggestions - Show host-aware resource recommendations
#   7. Configure Defaults - Edit reserves, VM sizes, clearnet option
#   8. Quit - Exit the script
# Loop: Continues until user selects Quit
main_menu(){
  while true; do
    detect_host_resources
    local base_exists="No"
    virsh_cmd dominfo "$VM_NAME" >/dev/null 2>&1 && base_exists="Yes"

    local header="Host: ${HOST_CORES} cores / ${HOST_RAM_MB} MiB   |   Reserve: ${RESERVE_CORES} cores / ${RESERVE_RAM_MB} MiB
Available after reserve: ${AVAIL_CORES} cores / ${AVAIL_RAM_MB} MiB
Base VM exists: ${base_exists}"

    local choice
    choice=$(whiptail --title "Garbageman VM Manager" --menu "$header\n\nChoose an action:" 24 92 10 \
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


################################################################################
# Script Entry Point
################################################################################
# Execution starts here:
#   1. Ensure all required tools are installed (installs if missing)
#   2. Launch main menu loop (runs until user quits)
# Note: Script requires bash and runs with set -euo pipefail for safety

ensure_tools    # Install dependencies if needed
main_menu       # Start interactive TUI
