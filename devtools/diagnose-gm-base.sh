#!/usr/bin/env bash
#
# diagnose-gm-base.sh - Diagnostic tool for Garbageman VM health verification
#
# Purpose:
#   Performs comprehensive health checks on a Garbageman base VM to verify:
#   - VM state and network connectivity
#   - SSH accessibility with monitoring key
#   - Binary installation and compatibility (musl vs glibc)
#   - Process and service status (bitcoind, tor)
#   - First-boot completion
#   - Bitcoin configuration and data directory
#   - Network connectivity (clearnet and Tor)
#   - RPC functionality and blockchain sync status
#
# Usage:
#   ./devtools/diagnose-gm-base.sh [vm-name]
#
# Arguments:
#   vm-name: Name of VM to diagnose (default: gm-base)
#
# Environment Variables:
#   SSH_KEY: Path to monitoring SSH key (default: ~/.cache/gm-monitor/gm_monitor_ed25519)
#
# Exit Codes:
#   0: All checks completed (some may have warnings)
#   1: VM not found or not running
#
# Notes:
#   - This script performs read-only checks; it never modifies the VM
#   - Requires virsh and ssh commands
#   - VM must be running for most checks to execute
#   - Uses the monitoring SSH key (same key main script uses for sync monitoring)

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Accept VM name as first argument, default to gm-base
VM_NAME="${1:-gm-base}"

# Accept custom SSH key path via environment variable, default to monitoring key cache location
SSH_KEY="${SSH_KEY:-$HOME/.cache/gm-monitor/gm_monitor_ed25519}"

echo "=========================================="
echo "  Garbageman VM Diagnostics: $VM_NAME"
echo "=========================================="
echo ""

# ============================================================================
# CHECK 1: VM State
# ============================================================================
# Verify the VM exists in libvirt and check its current state.
# Possible states: running, paused, shut off, crashed, etc.
# We require the VM to be running for subsequent checks.

echo "1. VM State:"
# Query virsh for VM state; if VM doesn't exist, virsh returns error so we catch it
VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "NOT_FOUND")

if [[ "$VM_STATE" == "NOT_FOUND" ]]; then
    echo "   ❌ VM not found"
    echo ""
    echo "The VM doesn't exist. Create it with:"
    echo "   ./garbageman-vmm.sh"
    echo "   Then choose 'Create Base VM'"
    exit 1
else
    echo "   ✓ State: $VM_STATE"
    # Most checks require the VM to be running; exit early if not
    if [[ "$VM_STATE" != "running" ]]; then
        echo "   ⚠ VM is not running. Start it with:"
        echo "     virsh start $VM_NAME"
        exit 1
    fi
fi
echo ""

# ============================================================================
# CHECK 2: VM IP Address
# ============================================================================
# Get the VM's IP address from libvirt's DHCP lease information.
# This IP is needed for SSH connectivity checks.

echo "2. VM IP Address:"
# virsh domifaddr queries DHCP leases; we parse out the IPv4 address
VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1)

if [[ -n "$VM_IP" ]]; then
    echo "   ✓ IP: $VM_IP"
else
    echo "   ❌ No IP address assigned"
    echo "      VM may still be booting or DHCP hasn't assigned an address yet"
    VM_IP=""  # Ensure VM_IP is empty for subsequent checks
fi
echo ""

# ============================================================================
# CHECK 3: Network Connectivity
# ============================================================================
# Verify the VM responds to ICMP ping from the host.
# This confirms basic network connectivity before attempting SSH.

if [[ -n "$VM_IP" ]]; then
    echo "3. Network Connectivity:"
    # Send 2 ping packets with 2-second timeout
    if ping -c 2 -W 2 "$VM_IP" >/dev/null 2>&1; then
        echo "   ✓ VM responds to ping"
    else
        echo "   ❌ VM does not respond to ping"
        echo "      This usually means the VM hasn't fully booted or network isn't configured"
    fi
    echo ""
fi

# ============================================================================
# CHECK 4+: SSH Connectivity and VM Internal Checks
# ============================================================================
# All subsequent checks require SSH access to the VM.
# We use the monitoring SSH key (same key the main script uses for sync monitoring).
# SSH options used:
#   -i $SSH_KEY: Use the monitoring key
#   -o StrictHostKeyChecking=no: Don't prompt about host key (lab environment)
#   -o UserKnownHostsFile=/dev/null: Don't save host keys
#   -o ConnectTimeout=5: Fail quickly if SSH not responding

if [[ -n "$VM_IP" && -f "$SSH_KEY" ]]; then
    echo "4. SSH Connectivity:"
    # Test SSH with a simple echo command
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
           root@"$VM_IP" 'echo "SSH OK"' >/dev/null 2>&1; then
        echo "   ✓ SSH is accessible"
        
        # ====================================================================
        # CHECK 5: Binary Installation and Compatibility
        # ====================================================================
        # Verify bitcoind and bitcoin-cli are installed and compatible with Alpine Linux.
        # Alpine uses musl libc (not glibc), so binaries must be musl-linked or static.
        
        echo ""
        echo "5. Garbageman Binary Installation:"
        echo "   Checking if bitcoind and bitcoin-cli are installed..."
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" '
                # Check if both binaries exist in the expected location
                if [[ -f /usr/local/bin/bitcoind && -f /usr/local/bin/bitcoin-cli ]]; then
                    echo "   ✓ Binaries are installed"
                    # Show binary file types (ELF 64-bit, etc.)
                    echo "     bitcoind: $(file /usr/local/bin/bitcoind | cut -d: -f2-)"
                    echo "     bitcoin-cli: $(file /usr/local/bin/bitcoin-cli | cut -d: -f2-)"
                    
                    # Verify library compatibility: Alpine uses musl, not glibc
                    # ldd shows dynamic library dependencies
                    if ldd /usr/local/bin/bitcoind 2>&1 | grep -q "musl"; then
                        echo "   ✓ Binaries are musl-linked (Alpine compatible)"
                    elif ldd /usr/local/bin/bitcoind 2>&1 | grep -q "not a dynamic executable"; then
                        echo "   ✓ Binaries are statically linked"
                    elif ldd /usr/local/bin/bitcoind 2>&1 | grep -q "not a dynamic executable"; then
                        echo "   ✓ Binaries are statically linked"
                    else
                        # If glibc-linked, binaries won't work on Alpine
                        echo "   ⚠ Binaries may be glibc-linked (incompatible with Alpine)"
                        ldd /usr/local/bin/bitcoind 2>&1 | head -5
                    fi
                else
                    echo "   ❌ Binaries not found in /usr/local/bin/"
                    echo "      The build may have failed. Check build logs."
                fi
            '
        
        # ====================================================================
        # CHECK 6: Process Status
        # ====================================================================
        # Check if bitcoind and tor processes are actually running.
        # Uses pgrep to find process IDs, then ps to show details.
        
        echo ""
        echo "6. Process Status:"
        echo "   Checking running processes..."
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" '
                # pgrep returns PID if process found, empty if not
                BITCOIND_PID=$(pgrep bitcoind || echo "")
                TOR_PID=$(pgrep tor || echo "")
                
                if [[ -n "$BITCOIND_PID" ]]; then
                    echo "   ✓ bitcoind is running (PID: $BITCOIND_PID)"
                    # Show memory usage and command line
                    ps -p "$BITCOIND_PID" -o pid,vsz,rss,comm,args | tail -1
                else
                    echo "   ❌ bitcoind is not running"
                fi
                
                if [[ -n "$TOR_PID" ]]; then
                    echo "   ✓ tor is running (PID: $TOR_PID)"
                else
                    echo "   ⚠ tor is not running"
                fi
            '
        
        # ====================================================================
        # CHECK 7: Service Status (OpenRC)
        # ====================================================================
        # Alpine Linux uses OpenRC (not systemd) for service management.
        # Check if bitcoind and tor services are enabled in the default runlevel.
        
        echo ""
        echo "7. Bitcoin Service Status (OpenRC):"
        # rc-status shows which services are in which runlevels
        # -s flag shows only services (not full status)
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" 'rc-status -s | grep -E "bitcoin|tor" || echo "   ℹ No services in default runlevel"'
        
        # ====================================================================
        # CHECK 8: First-Boot Status
        # ====================================================================
        # The main script injects a first-boot script that runs on initial boot.
        # It configures SSH keys, sets passwords, and prepares the system.
        # Verify this script completed successfully.
        
        echo ""
        echo "8. First-Boot Status:"
        echo "   Checking if first-boot script has completed..."
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" '
                if [[ -f /var/log/first-boot.log ]]; then
                    echo "   ✓ First-boot log exists"
                    # Look for the completion marker in the log
                    if grep -q "First boot configuration complete" /var/log/first-boot.log 2>/dev/null; then
                        echo "   ✓ First-boot script completed successfully"
                    else
                        echo "   ⚠ First-boot script may not have completed"
                        echo "     Last 10 lines of first-boot log:"
                        tail -10 /var/log/first-boot.log
                    fi
                else
                    echo "   ❌ First-boot log not found"
                    echo "      The VM may not have completed first boot initialization"
                fi
            '
        
        # ====================================================================
        # CHECK 9: Bitcoin Configuration
        # ====================================================================
        # Verify bitcoin.conf exists and check key settings.
        # Important settings: datadir, prune, proxy (for Tor), onlynet, txindex
        
        echo ""
        echo "9. Bitcoin Configuration:"
        echo "   Checking bitcoin.conf..."
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" '
                if [[ -f /etc/bitcoin/bitcoin.conf ]]; then
                    echo "   ✓ Configuration file exists"
                    echo "     Key settings:"
                    # Show important config options
                    grep -E "^(datadir|prune|proxy|onlynet|txindex)" /etc/bitcoin/bitcoin.conf 2>/dev/null | sed "s/^/       /" || echo "       (no matching settings)"
                else
                    echo "   ❌ Configuration file not found at /etc/bitcoin/bitcoin.conf"
                fi
            '
        
        # ====================================================================
        # CHECK 10: Bitcoin Data Directory
        # ====================================================================
        # Verify the data directory exists and check disk usage.
        # The debug.log file is created when bitcoind starts.
        
        echo ""
        echo "10. Bitcoin Data Directory:"
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" '
                if [[ -d /var/lib/bitcoin ]]; then
                    echo "   ✓ Data directory exists"
                    # Show total size of data directory
                    DATADIR_SIZE=$(du -sh /var/lib/bitcoin 2>/dev/null | cut -f1)
                    echo "     Size: $DATADIR_SIZE"
                    
                    # Check for debug.log (created when bitcoind starts)
                    if [[ -f /var/lib/bitcoin/debug.log ]]; then
                        echo "   ✓ debug.log exists"
                        LOG_SIZE=$(du -h /var/lib/bitcoin/debug.log | cut -f1)
                        echo "     debug.log size: $LOG_SIZE"
                        echo "   ⚠ debug.log not found (bitcoind may not have started yet)"
                    fi
                else
                    echo "   ❌ Data directory not found"
                fi
            '
        
        # ====================================================================
        # CHECK 11: Bitcoin Debug Log
        # ====================================================================
        # Show recent log entries to see what bitcoind is doing.
        # Useful for spotting errors or confirming sync activity.
        
        echo ""
        echo "11. Bitcoin Debug Log (last 20 lines):"
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" 'tail -n 20 /var/lib/bitcoin/debug.log 2>/dev/null | sed "s/^/     /" || echo "   ❌ Debug log not accessible"'
        
        # ====================================================================
        # CHECK 12: Network Connectivity from VM
        # ====================================================================
        # Test both clearnet (direct internet) and Tor connectivity.
        # For Tor-only clones, clearnet will fail (expected behavior).
        
        echo ""
        echo "12. Network Connectivity from VM:"
        echo "   Checking if VM can reach the internet..."
        # Test direct internet with ping to Google DNS
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" 'ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "   ✓ Internet (direct) is reachable" || echo "   ❌ Cannot reach internet directly"'
        
        echo "   Checking if Tor is working..."
        # Test Tor by querying Tor Project's check endpoint via SOCKS5 proxy
        # Returns JSON with IsTor field if working
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" 'curl -s --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null | grep -q "\"IsTor\":true" && echo "   ✓ Tor SOCKS proxy is working" || echo "   ⚠ Tor SOCKS proxy not working (may still be starting)"'
        
        # ====================================================================
        # CHECK 13: RPC Status and Blockchain Info
        # ====================================================================
        # Query bitcoind RPC to verify it's responding and get sync status.
        # getblockchaininfo shows: chain (main/test), blocks, headers, IBD status, etc.
        
        echo ""
        echo "13. RPC Status (getblockchaininfo):"
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" '
                # Call bitcoin-cli with full paths (works even if PATH not set)
                OUTPUT=$(/usr/local/bin/bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockchaininfo 2>&1)
                
                # Check if response looks like valid JSON (contains "chain" field)
                if echo "$OUTPUT" | grep -q "\"chain\""; then
                    echo "   ✓ RPC is responding"
                    # Extract and display key blockchain metrics
                    echo "$OUTPUT" | grep -E "chain|blocks|headers|initialblockdownload|verificationprogress" | sed "s/^/     /"
                else
                    # RPC error or bitcoind not running
                    echo "   ❌ RPC not responding or error:"
                    echo "$OUTPUT" | head -5 | sed "s/^/     /"
                fi
            '
        
        # ====================================================================
        # CHECK 14: Disk Usage
        # ====================================================================
        # Show overall disk usage and breakdown of bitcoin data directory.
        # Important for monitoring if disk is filling up during sync.
        
        echo ""
        echo "14. Disk Usage:"
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            root@"$VM_IP" '
                echo "   Overall disk usage:"
                df -h / | sed "s/^/     /"
                echo ""
                echo "   Largest directories in /var/lib/bitcoin:"
                # Show top 5 largest subdirectories (blocks, chainstate, etc.)
                du -sh /var/lib/bitcoin/* 2>/dev/null | sort -hr | head -5 | sed "s/^/     /" || echo "     (empty or inaccessible)"
            '
        
    else
        # ====================================================================
        # SSH Connection Failed
        # ====================================================================
        # If we can't SSH, provide troubleshooting guidance.
        
        echo "   ❌ Cannot connect via SSH"
        echo "      The VM may still be booting. Alpine Linux can take 2-5 minutes on first boot."
        echo ""
        echo "   Troubleshooting steps:"
        echo "   1. Wait 2-5 minutes and run this script again"
        echo "   2. Check VM console: virsh console $VM_NAME (Ctrl+] to exit)"
        echo "   3. Check if SSH service is running in the VM"
        echo "   4. Verify the SSH key exists: ls -l $SSH_KEY"
    fi
else
    # ====================================================================
    # Missing Prerequisites
    # ====================================================================
    # Can't run SSH checks without IP address or SSH key.
    
    if [[ ! -f "$SSH_KEY" ]]; then
        echo "4. SSH Key:"
        echo "   ❌ SSH key not found at: $SSH_KEY"
        echo ""
        echo "   The monitoring system hasn't generated the SSH key yet."
        echo "   This is normal if you haven't started the monitoring system."
    fi
fi

# ============================================================================
# Summary and Troubleshooting Guide
# ============================================================================
# Provide common commands and solutions for typical issues.

echo ""
echo "=========================================="
echo "  Summary & Next Steps"
echo "=========================================="
echo ""
echo "Common Issues and Solutions:"
echo ""
echo "• VM won't start:"
echo "    virsh start $VM_NAME"
echo ""
echo "• View VM console (to see boot messages):"
echo "    virsh console $VM_NAME"
echo "    (Press Ctrl+] to exit)"
echo ""
echo "• Restart the VM:"
echo "    virsh reboot $VM_NAME"
echo ""
echo "• Force stop and start:"
echo "    virsh destroy $VM_NAME && virsh start $VM_NAME"
echo ""
echo "• Check libvirt logs:"
echo "    sudo journalctl -u libvirtd -n 50"
echo ""
echo "• Binary incompatibility (glibc vs musl):"
echo "    Rebuild with: ./garbageman-vmm.sh -> Create Base VM"
echo "    (Script now builds inside Alpine with native musl toolchain)"
echo ""
echo "• Complete cleanup and rebuild:"
echo "    ./devtools/delete-gm-base.sh"
echo "    ./garbageman-vmm.sh -> Create Base VM"
echo ""
