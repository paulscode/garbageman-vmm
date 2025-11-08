#!/usr/bin/env bash
# ==============================================================================
# scaffold-daemon.sh - Clone Base Daemon for New Instance
# ==============================================================================
# This script will (in production) clone the gm_base daemon directory and
# configure it with instance-specific settings from an ENV file.
#
# Usage:
#   scaffold-daemon.sh <instance-id> <path-to-instance-env>
#
# Example:
#   scaffold-daemon.sh gm-clone-20251105-143216 /envfiles/instances/gm-clone-20251105-143216.env
#
# Steps (future implementation):
#   1. Validate instance ENV file exists and is well-formed
#   2. Copy gm_base to a new directory (e.g., /data/bitcoin/<instance-id>)
#   3. Generate bitcoin.conf with instance-specific ports/settings
#   4. Set up Tor hidden service (if configured)
#   5. Create systemd unit or supervisor config for this instance
#   6. Return success/failure status
#
# For MVP: Just echo what we'd do (stub).

set -euo pipefail

INSTANCE_ID="${1:-}"
ENV_FILE="${2:-}"

echo "=================================================="
echo "scaffold-daemon.sh - STUB MODE"
echo "=================================================="
echo ""

if [[ -z "${INSTANCE_ID}" ]]; then
  echo "ERROR: Missing required argument: instance-id"
  echo "Usage: $0 <instance-id> <path-to-instance-env>"
  exit 1
fi

if [[ -z "${ENV_FILE}" ]]; then
  echo "ERROR: Missing required argument: path-to-instance-env"
  echo "Usage: $0 <instance-id> <path-to-instance-env>"
  exit 1
fi

echo "Instance ID: ${INSTANCE_ID}"
echo "ENV File: ${ENV_FILE}"
echo ""

echo "TODO: In production, this script would:"
echo "  1. Validate ${ENV_FILE} schema"
echo "  2. Clone /data/bitcoin/gm_base -> /data/bitcoin/${INSTANCE_ID}"
echo "  3. Generate bitcoin.conf from ENV vars"
echo "  4. Configure Tor hidden service (if TOR_ONION is set)"
echo "  5. Set resource limits (cgroups: CPUS, RAM_MB)"
echo "  6. Register with supervisor"
echo ""

echo "Stub mode: pretending to succeed."
echo "New daemon '${INSTANCE_ID}' scaffolded successfully (fake)."
echo ""

exit 0
