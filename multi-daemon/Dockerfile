# Multi-Daemon Container for Garbageman Nodes Manager
# ==================================================
# This container supervises multiple Garbageman/Knots daemon instances.
# Manages bitcoind processes, Tor hidden services, and health monitoring.
#
# Security: Runs as non-root 'bitcoin' user (UID 1001)
# Target: Alpine for musl compatibility with bitcoind binaries

FROM node:20-alpine

# Install minimal runtime dependencies (including Tor)
RUN apk add --no-cache \
    curl \
    bash \
    procps \
    libevent \
    zeromq \
    sqlite-libs \
    tor

# Create working directory structure
WORKDIR /app

# Create directories for daemon artifacts and data
RUN mkdir -p /app/.artifacts /data/bitcoin /data/tor

# Create non-root user for running supervisor (security best practice)
# Note: Bitcoin daemons will still run as root for now, but supervisor runs as bitcoin user
RUN addgroup -g 1001 bitcoin && \
    adduser -D -u 1001 -G bitcoin bitcoin

# Copy supervisor stub and helper scripts
COPY supervisor.stub.ts /app/
COPY tor-manager.ts /app/
COPY logger.ts /app/
COPY entrypoint.sh /app/
COPY scripts/ /app/scripts/

# Install TypeScript and dependencies for the supervisor stub
RUN npm install -g tsx typescript
RUN npm init -y && npm install --save \
    @types/node

# Make scripts executable
RUN chmod +x /app/entrypoint.sh /app/scripts/*.sh

# Set ownership of application directories
RUN chown -R bitcoin:bitcoin /app /data

# Health check: supervisor should respond
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:9000/health || exit 1

# Expose internal supervisor API port
EXPOSE 9000

# Switch to non-root user for security
USER bitcoin

# Entry point: start the stub supervisor
ENTRYPOINT ["/app/entrypoint.sh"]
