#!/usr/bin/env bash
# ==============================================================================
# Multi-Daemon Container Entrypoint
# ==============================================================================
# Initializes the stub supervisor process manager.
# In production, this will:
#   1. Read envfiles/instances/*.env
#   2. Clone the base daemon for each instance
#   3. Start each daemon with proper resource limits
#   4. Monitor health and expose metrics
#
# For MVP: just launch the stub supervisor which returns fake data.

set -euo pipefail

echo "=================================================="
echo "Garbageman Multi-Daemon Container - Starting"
echo "=================================================="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo ""

# Environment validation (add more as we expand)
export SUPERVISOR_PORT="${SUPERVISOR_PORT:-9000}"
export DATA_DIR="${DATA_DIR:-/data/bitcoin}"
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-/app/.artifacts}"

echo "Configuration:"
echo "  SUPERVISOR_PORT: ${SUPERVISOR_PORT}"
echo "  DATA_DIR: ${DATA_DIR}"
echo "  ARTIFACTS_DIR: ${ARTIFACTS_DIR}"
echo ""

# Ensure data directories exist
mkdir -p "${DATA_DIR}" "${ARTIFACTS_DIR}"

# TODO: In production, scan envfiles/instances/ and scaffold daemons
# For now: just list what we'd do
echo "Scanning for daemon instances..."
echo "(Stub mode: no real daemons will be started)"
echo ""

# Launch the stub supervisor
echo "Starting stub supervisor on port ${SUPERVISOR_PORT}..."
exec tsx /app/supervisor.stub.ts
