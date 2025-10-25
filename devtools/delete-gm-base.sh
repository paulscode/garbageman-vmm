#!/usr/bin/env bash
#
# delete-gm-base.sh - Complete removal tool for Garbageman base VM and artifacts
#
# Purpose:
#   Thoroughly removes the Garbageman base VM and all associated artifacts:
#   - VM definition from libvirt
#   - Virtual disk image (.qcow2 file)
#   - Temporary files from build process (Alpine ISOs, answerfiles)
#   - Optionally removes all clone VMs
#
# Usage:
#   ./devtools/delete-gm-base.sh [vm-name]
#
# Arguments:
#   vm-name: Name of VM to delete (default: gm-base)
#
# Behavior:
#   - Stops VM if running (force shutdown with virsh destroy)
#   - Removes VM definition and disk image
#   - Cleans up temporary build artifacts in /var/tmp
#   - Prompts before removing clones (if any exist)
#   - Requires sudo for disk deletion (stored in /var/lib/libvirt/images)
#
# Notes:
#   - This is a destructive operation - all VM data will be lost
#   - Does NOT remove SSH keys from ~/.cache/gm-monitor/ (shared across recreations)
#   - Safe to run even if VM doesn't exist (cleans up orphaned files)
#   - Does not affect running clones unless user explicitly confirms
#
# Exit Codes:
#   0: Success (cleanup completed)

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Accept VM name as first argument, default to gm-base
VM_NAME="${1:-gm-base}"

echo "=== Cleaning up VM: $VM_NAME and related artifacts ==="
echo ""

# ============================================================================
# CHECK: Does the VM Exist?
# ============================================================================
# Query libvirt to see if this VM is defined.
# We need to know this to determine cleanup strategy.

VM_EXISTS=false
# virsh dominfo returns 0 if VM exists, non-zero if not
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    VM_EXISTS=true
fi

# ============================================================================
# CLEANUP: VM Definition and Disk
# ============================================================================

if [[ "$VM_EXISTS" == "true" ]]; then
    # ------------------------------------------------------------------------
    # Step 1: Stop the VM if it's running
    # ------------------------------------------------------------------------
    # Check VM state (running, paused, shut off, etc.)
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
    
    if [[ "$VM_STATE" != "shut off" ]]; then
        echo "Stopping VM..."
        # virsh destroy = force power off (like pulling the plug)
        # Not a graceful shutdown, but safe since we're deleting anyway
        virsh destroy "$VM_NAME" 2>/dev/null || true
        sleep 2  # Give libvirt time to update state
    fi

    # ------------------------------------------------------------------------
    # Step 2: Identify the disk image location
    # ------------------------------------------------------------------------
    # Query libvirt for the actual disk path before we undefine the VM.
    # domblklist shows all attached disks; we look for vda (primary disk)
    DISK_PATH=$(virsh domblklist "$VM_NAME" | awk '/vda/ {print $2}' | head -1)
    
    # Fallback to default path if query didn't work
    if [[ -z "$DISK_PATH" ]]; then
        DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
    fi

    echo "Disk path: $DISK_PATH"

    # ------------------------------------------------------------------------
    # Step 3: Remove the VM definition from libvirt
    # ------------------------------------------------------------------------
    echo "Removing VM definition..."
    # virsh undefine removes the VM configuration but not the disk
    virsh undefine "$VM_NAME" 2>/dev/null || true

    # ------------------------------------------------------------------------
    # Step 4: Delete the disk image
    # ------------------------------------------------------------------------
    # The disk file is owned by libvirt-qemu or root, so we need sudo
    if [[ -f "$DISK_PATH" ]]; then
        echo "Removing disk image: $DISK_PATH"
        sudo rm -f "$DISK_PATH"
    else
        echo "Disk image not found at: $DISK_PATH"
    fi
else
    # ------------------------------------------------------------------------
    # VM doesn't exist, but check for orphaned disk
    # ------------------------------------------------------------------------
    # Sometimes the VM definition is removed but disk remains
    echo "VM '$VM_NAME' does not exist."
    
    # Try default disk location
    DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
    if [[ -f "$DISK_PATH" ]]; then
        echo "Found orphaned disk image: $DISK_PATH"
        echo "Removing it..."
        sudo rm -f "$DISK_PATH"
    fi
fi

# ============================================================================
# CLEANUP: Temporary Build Artifacts
# ============================================================================
# When the main script creates the base VM, it downloads Alpine ISO and
# creates temporary directories in /var/tmp. Clean these up.

echo ""
echo "Cleaning up temporary files..."

# ------------------------------------------------------------------------
# Find temporary directories from build process
# ------------------------------------------------------------------------
# Look for directories matching tmp.* pattern (created with mktemp -d)
TEMP_DIRS=$(find /var/tmp -maxdepth 1 -type d -name "tmp.*" 2>/dev/null || true)

if [[ -n "$TEMP_DIRS" ]]; then
    echo "Found temporary directories in /var/tmp:"
    echo "$TEMP_DIRS" | while read -r dir; do
        # Only remove directories that look like ours (contain Alpine ISO or answerfile)
        # This avoids accidentally deleting unrelated temp directories
        if [[ -f "$dir/alpine-virt.iso" ]] || [[ -f "$dir/answerfile" ]]; then
            echo "  Removing: $dir"
            sudo rm -rf "$dir"
        fi
    done
else
    echo "No temporary directories found"
fi

# ------------------------------------------------------------------------
# Clean up any Alpine ISOs that might be left behind
# ------------------------------------------------------------------------
# The main script downloads Alpine ISO to temp dir, but sometimes cleanup fails
ISO_FILES=$(find /var/tmp -maxdepth 2 -name "alpine-virt*.iso" 2>/dev/null || true)

if [[ -n "$ISO_FILES" ]]; then
    echo ""
    echo "Cleaning up Alpine ISO files..."
    echo "$ISO_FILES" | while read -r iso; do
        echo "  Removing: $iso"
    echo "$ISO_FILES" | while read -r iso; do
        echo "  Removing: $iso"
        sudo rm -f "$iso"
    done
fi

# ============================================================================
# OPTIONAL: Clone Cleanup
# ============================================================================
# Check if any clones exist and offer to remove them too.
# Clones are independent VMs created from the base VM.

echo ""
echo "Checking for clones..."

# Query virsh for all VMs (running or stopped) that contain "gm-clone" in name
CLONES=$(virsh list --all | grep "gm-clone" | awk '{print $2}' || true)

if [[ -n "$CLONES" ]]; then
    echo "Found clones:"
    echo "$CLONES"
    echo ""
    
    # Prompt user before removing clones (they may want to keep them)
    read -p "Do you want to remove all clones too? (y/N): " -n 1 -r
    echo  # Move to next line after single-character input
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # User confirmed: remove each clone
        for clone in $CLONES; do
            echo "Removing clone: $clone"
            
            # Force stop if running (same as base VM cleanup)
            virsh destroy "$clone" 2>/dev/null || true
            
            # Get clone's disk path before undefining
            CLONE_DISK=$(virsh domblklist "$clone" | awk '/vda/ {print $2}' | head -1)
            
            # Remove VM definition
            virsh undefine "$clone" 2>/dev/null || true
            
            # Remove disk image if found
            if [[ -n "$CLONE_DISK" && -f "$CLONE_DISK" ]]; then
                sudo rm -f "$CLONE_DISK"
            fi
        done
    fi
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "You can now recreate the VM with:"
echo "   ./garbageman-vmm.sh"
echo "   Then choose 'Create Base VM'"
echo ""
