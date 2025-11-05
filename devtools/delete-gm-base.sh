#!/usr/bin/env bash
#
# delete-gm-base.sh - Complete removal tool for Garbageman VM and container deployments
#
# Purpose:
#   Thoroughly removes Garbageman base VM and/or container and all associated artifacts:
#   - VM: definition, disk image, temporary build files, clones
#   - Container: instances, images, volumes, clones
#
# Usage:
#   ./devtools/delete-gm-base.sh [both|vm|container] [name]
#
# Arguments:
#   mode: What to delete - 'both' (default), 'vm', or 'container'
#   name: Name of VM/container to delete (default: gm-base)
#
# Behavior:
#   - Stops VM/container if running
#   - Removes definitions, images, and volumes
#   - Cleans up temporary build artifacts
#   - Prompts before removing clones (if any exist)
#
# Notes:
#   - This is a destructive operation - all data will be lost
#   - Safe to run even if VM/container doesn't exist
#   - Does not affect running clones unless user explicitly confirms
#
# Exit Codes:
#   0: Success (cleanup completed)

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Parse arguments
MODE="${1:-both}"
BASE_NAME="${2:-gm-base}"

# Validate mode
if [[ "$MODE" != "both" && "$MODE" != "vm" && "$MODE" != "container" ]]; then
    echo "Usage: $0 [both|vm|container] [name]"
    echo ""
    echo "Modes:"
    echo "  both      - Remove both VM and container (default)"
    echo "  vm        - Remove only VM"
    echo "  container - Remove only container"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════════════════════════════╗"
echo "║               Garbageman Cleanup Tool - VM and Container                       ║"
echo "╚════════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Mode: $MODE"
echo "Base name: $BASE_NAME"
echo ""

# ============================================================================
# VM CLEANUP
# ============================================================================

delete_vm() {
    local VM_NAME="$1"
    
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "VM Cleanup: $VM_NAME"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    # Check if VM exists
    VM_EXISTS=false
    if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        VM_EXISTS=true
    fi

    if [[ "$VM_EXISTS" == "true" ]]; then
        # Stop the VM if it's running
        VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
        
        if [[ "$VM_STATE" != "shut off" ]]; then
            echo "[1/4] Stopping VM..."
            virsh destroy "$VM_NAME" 2>/dev/null || true
            sleep 2
            echo "    ✓ VM stopped"
        else
            echo "[1/4] VM already stopped"
        fi

        # Identify the disk image location
        echo ""
        echo "[2/4] Locating disk image..."
        DISK_PATH=$(virsh domblklist "$VM_NAME" | awk '/vda/ {print $2}' | head -1)
        
        if [[ -z "$DISK_PATH" ]]; then
            DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
        fi
        echo "    Disk path: $DISK_PATH"

        # Remove the VM definition
        echo ""
        echo "[3/4] Removing VM definition..."
        virsh undefine "$VM_NAME" 2>/dev/null || true
        echo "    ✓ VM definition removed"

        # Delete the disk image
        echo ""
        echo "[4/4] Removing disk image..."
        if [[ -f "$DISK_PATH" ]]; then
            sudo rm -f "$DISK_PATH"
            echo "    ✓ Disk image removed"
        else
            echo "    ℹ Disk image not found"
        fi
    else
        echo "ℹ VM '$VM_NAME' does not exist"
        
        # Check for orphaned disk
        DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
        if [[ -f "$DISK_PATH" ]]; then
            echo "  Found orphaned disk image: $DISK_PATH"
            echo "  Removing it..."
            sudo rm -f "$DISK_PATH"
            echo "  ✓ Orphaned disk removed"
        fi
    fi

    # Clean up temporary build artifacts
    echo ""
    echo "Cleaning up temporary files..."
    TEMP_DIRS=$(find /var/tmp -maxdepth 1 -type d -name "tmp.*" 2>/dev/null || true)

    if [[ -n "$TEMP_DIRS" ]]; then
        echo "$TEMP_DIRS" | while read -r dir; do
            if [[ -f "$dir/alpine-virt.iso" ]] || [[ -f "$dir/answerfile" ]]; then
                echo "  Removing: $dir"
                sudo rm -rf "$dir"
            fi
        done
    fi

    # Clean up Alpine ISOs
    ISO_FILES=$(find /var/tmp -maxdepth 2 -name "alpine-virt*.iso" 2>/dev/null || true)
    if [[ -n "$ISO_FILES" ]]; then
        echo "$ISO_FILES" | while read -r iso; do
            echo "  Removing: $iso"
            sudo rm -f "$iso"
        done
    fi

    # Check for clones
    echo ""
    echo "Checking for VM clones..."
    CLONES=$(virsh list --all | grep "gm-clone" | awk '{print $2}' || true)

    if [[ -n "$CLONES" ]]; then
        echo "Found clones:"
        echo "$CLONES" | sed 's/^/  - /'
        echo ""
        
        read -p "Remove all VM clones? (y/N): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for clone in $CLONES; do
                echo "  Removing clone: $clone"
                virsh destroy "$clone" 2>/dev/null || true
                CLONE_DISK=$(virsh domblklist "$clone" | awk '/vda/ {print $2}' | head -1)
                virsh undefine "$clone" 2>/dev/null || true
                if [[ -n "$CLONE_DISK" && -f "$CLONE_DISK" ]]; then
                    sudo rm -f "$CLONE_DISK"
                fi
            done
            echo "  ✓ All VM clones removed"
        else
            echo "  ℹ Skipping VM clone removal"
        fi
    else
        echo "  ℹ No VM clones found"
    fi
    
    echo ""
    echo "✅ VM cleanup complete"
}

# ============================================================================
# CONTAINER CLEANUP
# ============================================================================

delete_container() {
    local CONTAINER_NAME="$1"
    local CONTAINER_IMAGE="${2:-garbageman-base}"
    
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Container Cleanup: $CONTAINER_NAME"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    # Detect container runtime
    RUNTIME=""
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        RUNTIME="docker"
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
    else
        echo "⚠️  No container runtime found (docker or podman required)"
        echo "   Skipping container cleanup"
        return
    fi

    echo "📦 Using container runtime: $RUNTIME"
    echo ""

    # Wrapper function for container commands
    container_cmd() {
        if [[ "$RUNTIME" == "docker" ]]; then
            if groups | grep -qw docker; then
                docker "$@"
            else
                sudo docker "$@"
            fi
        else
            podman "$@"
        fi
    }

    # Check if container exists
    CONTAINER_EXISTS=false
    if container_cmd ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        CONTAINER_EXISTS=true
        echo "✓ Container '$CONTAINER_NAME' found"
    else
        echo "ℹ Container '$CONTAINER_NAME' not found"
    fi

    # Stop and remove container
    if [[ "$CONTAINER_EXISTS" == "true" ]]; then
        CONTAINER_STATE=$(container_cmd inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
        
        if [[ "$CONTAINER_STATE" == "running" ]]; then
            echo ""
            echo "[1/4] Stopping container..."
            container_cmd stop "$CONTAINER_NAME" 2>/dev/null || true
            echo "    ✓ Container stopped"
        else
            echo "[1/4] Container not running (state: $CONTAINER_STATE)"
        fi

        echo ""
        echo "[2/4] Removing container instance..."
        container_cmd rm -f "$CONTAINER_NAME" 2>/dev/null || true
        echo "    ✓ Container instance removed"
    else
        echo "[1-2/4] Container doesn't exist, skipping..."
    fi

    # Check for volumes
    echo ""
    echo "[3/4] Checking for associated volumes..."
    VOLUMES=$(container_cmd volume ls -q | grep -i garbageman 2>/dev/null || true)
    if [[ -n "$VOLUMES" ]]; then
        echo "    Found volumes:"
        echo "$VOLUMES" | sed 's/^/      - /'
        echo ""
        read -p "    Remove these volumes? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            while IFS= read -r vol; do
                echo "      Removing volume: $vol"
                container_cmd volume rm "$vol" 2>/dev/null || echo "        ⚠ Could not remove volume $vol"
            done <<< "$VOLUMES"
            echo "    ✓ Volumes removed"
        else
            echo "    ℹ Skipping volume removal"
        fi
    else
        echo "    ℹ No volumes found"
    fi

    # Optionally remove image
    echo ""
    echo "[4/4] Checking for container image..."
    IMAGE_EXISTS=$(container_cmd images -q "$CONTAINER_IMAGE" 2>/dev/null || true)
    if [[ -n "$IMAGE_EXISTS" ]]; then
        echo "    Container image '$CONTAINER_IMAGE' found"
        read -p "    Remove the base image? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "      Removing image..."
            container_cmd rmi "$CONTAINER_IMAGE" 2>/dev/null || echo "        ⚠ Could not remove image"
            echo "    ✓ Image removed"
        else
            echo "    ℹ Keeping base image"
        fi
    else
        echo "    ℹ No image named '$CONTAINER_IMAGE' found"
    fi

    # Check for clones
    echo ""
    echo "Checking for container clones..."
    CLONE_PREFIX="gm-clone"
    CLONES=$(container_cmd ps -a --format '{{.Names}}' | grep "^${CLONE_PREFIX}" || true)

    if [[ -n "$CLONES" ]]; then
        CLONE_COUNT=$(echo "$CLONES" | wc -l)
        echo "Found $CLONE_COUNT clone container(s):"
        echo "$CLONES" | sed 's/^/  - /'
        echo ""
        read -p "Remove all clone containers? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            while IFS= read -r clone_name; do
                echo "  Removing clone: $clone_name"
                container_cmd stop "$clone_name" 2>/dev/null || true
                container_cmd rm -f "$clone_name" 2>/dev/null || true
            done <<< "$CLONES"
            echo "  ✓ All clone containers removed"
        else
            echo "  ℹ Skipping clone removal"
        fi
    else
        echo "  ℹ No clone containers found"
    fi

    # Clean up dangling images
    echo ""
    echo "Checking for dangling images..."
    DANGLING=$(container_cmd images -f "dangling=true" -q 2>/dev/null || true)

    if [[ -n "$DANGLING" ]]; then
        DANGLING_COUNT=$(echo "$DANGLING" | wc -l)
        echo "Found $DANGLING_COUNT dangling image(s)"
        read -p "Remove dangling images and build cache? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "  Pruning..."
            container_cmd image prune -f 2>/dev/null || true
            if [[ "$RUNTIME" == "docker" ]]; then
                container_cmd builder prune -f 2>/dev/null || true
            fi
            echo "  ✓ Cleanup complete"
        else
            echo "  ℹ Skipping cleanup"
        fi
    else
        echo "  ℹ No dangling images found"
    fi
    
    echo ""
    echo "✅ Container cleanup complete"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Execute cleanup based on mode
if [[ "$MODE" == "both" || "$MODE" == "vm" ]]; then
    delete_vm "$BASE_NAME"
    echo ""
fi

if [[ "$MODE" == "both" || "$MODE" == "container" ]]; then
    delete_container "$BASE_NAME"
    echo ""
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo "╔════════════════════════════════════════════════════════════════════════════════╗"
echo "║                          Cleanup Complete!                                     ║"
echo "╚════════════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Removed:"
if [[ "$MODE" == "both" || "$MODE" == "vm" ]]; then
    echo "  ✓ VM '$BASE_NAME' and associated files"
fi
if [[ "$MODE" == "both" || "$MODE" == "container" ]]; then
    echo "  ✓ Container '$BASE_NAME' and associated files"
fi
echo ""
echo "To recreate, run:"
echo "  ./garbageman-nm.sh"
if [[ "$MODE" == "both" ]]; then
    echo "  Then choose 'Create Base VM' or 'Create Base Container'"
elif [[ "$MODE" == "vm" ]]; then
    echo "  Then choose 'Create Base VM'"
else
    echo "  Then choose 'Create Base Container'"
fi
echo ""

exit 0
