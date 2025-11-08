# Garbageman WebUI - Dockerfile
# ===============================
# Multi-stage build for Next.js production deployment

FROM node:20-slim AS base

# Install dependencies only when needed
FROM base AS deps
WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies (use install instead of ci since we don't have lockfile)
RUN npm install

# Rebuild the source code only when needed
FROM base AS builder
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Set environment variables for build
ENV NEXT_TELEMETRY_DISABLED 1
ENV NODE_ENV production

# Build Next.js app
RUN npm run build

# Production image, copy all files and run next
FROM base AS runner
WORKDIR /app

ENV NODE_ENV production
ENV NEXT_TELEMETRY_DISABLED 1

# Create a non-root user
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# Copy built assets from builder
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 5173

ENV PORT 5173
ENV HOSTNAME "0.0.0.0"

CMD ["node", "server.js"]
