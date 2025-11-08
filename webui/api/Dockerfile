# Garbageman WebUI - API Server
# ==============================
# Fastify-based TypeScript API for managing daemon instance definitions.
# Reads/writes ENV files in envfiles/ and proxies status from multi-daemon supervisor.

FROM node:20-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    curl \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy package files first for better layer caching
COPY package*.json ./
COPY tsconfig.json ./

# Install dependencies (use install instead of ci since we don't have lockfile)
RUN npm install

# Copy source code
COPY src/ ./src/

# Copy data directory (includes seed files)
COPY data/ ./data/

# Build TypeScript
RUN npm run build

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/api/health || exit 1

# Expose API port
EXPOSE 8080

# Start server
CMD ["node", "dist/server.js"]
