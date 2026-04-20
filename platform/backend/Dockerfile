# syntax=docker/dockerfile:1.7
# Multi-stage production image for the GrowFi Fastify backend.
#   - `deps`  : install ALL npm deps (dev + prod) for the TS → JS build step.
#   - `build` : run tsc and emit `dist/`.
#   - `prune` : reinstall with --omit=dev to drop the TS toolchain from the
#               final image.
#   - final  : slim `node:22-slim` with only `dist/` + production node_modules.

FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:22-slim AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM node:22-slim AS prune
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=4001
ENV HOST=0.0.0.0

# Run as a non-root user so a compromised process can't write anywhere
# important inside the container.
RUN groupadd --system --gid 1001 growfi \
  && useradd --system --uid 1001 --gid 1001 growfi \
  && chown -R growfi:growfi /app
USER growfi

COPY --chown=growfi:growfi --from=prune /app/node_modules ./node_modules
COPY --chown=growfi:growfi --from=build /app/dist ./dist
COPY --chown=growfi:growfi package.json ./

EXPOSE 4001
# Cheap liveness probe for DO App Platform — no extra tooling.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:4001/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/server.js"]
