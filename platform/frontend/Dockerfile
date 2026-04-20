# syntax=docker/dockerfile:1.7
# Multi-stage production image for the GrowFi Next.js 16 frontend.
#
# Next.js bakes `NEXT_PUBLIC_*` at BUILD time, not runtime — so we need
# every public env var as an ARG here. DO App Platform must pass them
# via build_args (see .do/app.yaml).
#
# `output: "standalone"` in next.config.ts makes `.next/standalone/` a
# self-contained runtime — we only copy that + the static assets into
# the final image (~150 MB vs ~700 MB with full node_modules).

FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:22-slim AS build
WORKDIR /app

# Public env vars MUST be available at build time. If any is missing the
# build crashes loudly; no silent "undefined" in the bundle.
ARG NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID
ARG NEXT_PUBLIC_BACKEND_URL
ARG NEXT_PUBLIC_CHAIN_ID
ARG NEXT_PUBLIC_FACTORY_ADDRESS
ARG NEXT_PUBLIC_USDC_ADDRESS
ARG NEXT_PUBLIC_REGISTRY_ADDRESS
ARG NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS
ARG NEXT_PUBLIC_SUBGRAPH_URL
ENV NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=${NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID}
ENV NEXT_PUBLIC_BACKEND_URL=${NEXT_PUBLIC_BACKEND_URL}
ENV NEXT_PUBLIC_CHAIN_ID=${NEXT_PUBLIC_CHAIN_ID}
ENV NEXT_PUBLIC_FACTORY_ADDRESS=${NEXT_PUBLIC_FACTORY_ADDRESS}
ENV NEXT_PUBLIC_USDC_ADDRESS=${NEXT_PUBLIC_USDC_ADDRESS}
ENV NEXT_PUBLIC_REGISTRY_ADDRESS=${NEXT_PUBLIC_REGISTRY_ADDRESS}
ENV NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS=${NEXT_PUBLIC_PRODUCER_REGISTRY_ADDRESS}
ENV NEXT_PUBLIC_SUBGRAPH_URL=${NEXT_PUBLIC_SUBGRAPH_URL}

COPY --from=deps /app/node_modules ./node_modules
COPY . .
# Telemetry is network + noise — disable for reproducible builds.
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
ENV NEXT_TELEMETRY_DISABLED=1

RUN groupadd --system --gid 1001 growfi \
  && useradd --system --uid 1001 --gid 1001 growfi \
  && chown -R growfi:growfi /app
USER growfi

# standalone/ already bundles only the runtime deps we need.
COPY --chown=growfi:growfi --from=build /app/.next/standalone ./
COPY --chown=growfi:growfi --from=build /app/.next/static ./.next/static
COPY --chown=growfi:growfi --from=build /app/public ./public

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
