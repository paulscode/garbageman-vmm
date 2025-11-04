#!/usr/bin/env bash
#
# diagnose-gm-base.sh - Diagnostic tool for Garbageman VM and container health
#
# Usage: ./devtools/diagnose-gm-base.sh [vm|container] [name]
# Arguments:
#   mode: 'vm' or 'container' (prompts if not provided)
#   name: Name to diagnose (default: gm-base)

set -euo pipefail

MODE="${1:-}"
BASE_NAME="${2:-gm-base}"

# Prompt for mode if not provided
if [[ -z "$MODE" ]]; then
    echo "╔════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                    Garbageman Diagnostics Tool                                 ║"
    echo "╚════════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "What would you like to diagnose?"
    echo ""
    echo "  1) VM deployment"
    echo "  2) Container deployment"
    echo ""
    read -p "Enter choice (1 or 2): " -n 1 -r
    echo ""
    
    case "$REPLY" in
        1) MODE="vm" ;;
        2) MODE="container" ;;
        *) 
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
    echo ""
fi

if [[ "$MODE" != "vm" && "$MODE" != "container" ]]; then
    echo "Usage: $0 [vm|container] [name]"
    exit 1
fi

diagnose_vm() {
    local VM_NAME="$1"
    local SSH_KEY="${SSH_KEY:-$HOME/.cache/gm-monitor/gm_monitor_ed25519}"
    
    echo "VM Diagnostics: $VM_NAME"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    
    VM_STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "NOT_FOUND")
    if [[ "$VM_STATE" == "NOT_FOUND" ]]; then
        echo "❌ VM not found"
        exit 1
    fi
    
    echo "✓ State: $VM_STATE"
    
    if [[ "$VM_STATE" != "running" ]]; then
        echo "⚠️  VM not running. Start with: virsh start $VM_NAME"
        exit 1
    fi
    
    VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1)
    if [[ -z "$VM_IP" ]]; then
        echo "❌ No IP address"
        exit 1
    fi
    echo "✓ IP: $VM_IP"
    
    if ! ping -c 2 -W 2 "$VM_IP" >/dev/null 2>&1; then
        echo "❌ Ping failed"
        exit 1
    fi
    echo "✓ Ping successful"
    
    if [[ ! -f "$SSH_KEY" ]]; then
        echo "❌ SSH key not found: $SSH_KEY"
        exit 1
    fi
    
    if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
           root@"$VM_IP" 'echo OK' >/dev/null 2>&1; then
        echo "❌ SSH failed"
        exit 1
    fi
    echo "✓ SSH accessible"
    
    echo ""
    echo "Bitcoin Status:"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$VM_IP" '
        if pgrep bitcoind >/dev/null; then
            echo "✓ bitcoind running (PID: $(pgrep bitcoind))"
        else
            echo "❌ bitcoind not running"
        fi
        
        if bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount >/dev/null 2>&1; then
            BLOCKS=$(bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount 2>/dev/null)
            echo "✓ RPC responding - Blocks: $BLOCKS"
        else
            echo "❌ RPC not responding"
        fi
    '
    
    echo ""
    echo "✅ VM diagnostics complete"
}

diagnose_container() {
    local CONTAINER_NAME="$1"
    
    echo "Container Diagnostics: $CONTAINER_NAME"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    
    RUNTIME=""
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        RUNTIME="docker"
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
    else
        echo "❌ No container runtime found"
        exit 1
    fi
    
    echo "📦 Runtime: $RUNTIME"
    
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
    
    if ! container_cmd ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "❌ Container not found"
        exit 1
    fi
    
    CONTAINER_STATE=$(container_cmd inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
    echo "✓ State: $CONTAINER_STATE"
    
    if [[ "$CONTAINER_STATE" != "running" ]]; then
        echo "⚠️  Container not running. Start with: $RUNTIME start $CONTAINER_NAME"
        exit 1
    fi
    
    CONTAINER_IP=$(container_cmd inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | head -n1)
    if [[ -n "$CONTAINER_IP" ]]; then
        echo "✓ IP: $CONTAINER_IP"
    fi
    
    if container_cmd exec "$CONTAINER_NAME" sh -c "ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1"; then
        echo "✓ Network connectivity"
    else
        echo "❌ No network"
    fi
    
    echo ""
    echo "Bitcoin Status:"
    if container_cmd exec "$CONTAINER_NAME" pgrep bitcoind >/dev/null 2>&1; then
        PID=$(container_cmd exec "$CONTAINER_NAME" pgrep bitcoind)
        echo "✓ bitcoind running (PID: $PID)"
    else
        echo "❌ bitcoind not running"
    fi
    
    if container_cmd exec "$CONTAINER_NAME" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount >/dev/null 2>&1; then
        BLOCKS=$(container_cmd exec "$CONTAINER_NAME" bitcoin-cli -conf=/etc/bitcoin/bitcoin.conf -datadir=/var/lib/bitcoin getblockcount 2>/dev/null)
        echo "✓ RPC responding - Blocks: $BLOCKS"
    else
        echo "❌ RPC not responding"
    fi
    
    echo ""
    echo "✅ Container diagnostics complete"
}

if [[ "$MODE" == "vm" ]]; then
    diagnose_vm "$BASE_NAME"
else
    diagnose_container "$BASE_NAME"
fi

exit 0
