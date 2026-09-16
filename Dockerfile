# ── Stage 1: build ────────────────────────────────────────────
FROM node:24-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make g++ && \
    rm -rf /var/lib/apt/lists/*

ARG NPM_REGISTRY=https://registry.npmjs.org/
RUN npm install -g --no-audit --no-fund --registry="$NPM_REGISTRY" @deepseek-ai/dsh@next

# ── Stage 2: runtime ─────────────────────────────────────────
FROM node:24-slim

COPY --from=builder /usr/local/ /usr/local/

RUN npm install -g --no-audit --no-fund http-proxy

ENV DSH_HOME=/home/node/.dsh \
    DSH_PORT=3079 \
    PROXY_PORT=3080 \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_PLUGIN_HMR_DISABLED=1

COPY proxy.js  /opt/proxy.js
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3080

USER node
ENTRYPOINT ["/entrypoint.sh"]
