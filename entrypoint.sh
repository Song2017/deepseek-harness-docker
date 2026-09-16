#!/bin/sh
set -e

DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"

# ── 启动 DSH（仅监听 127.0.0.1）──────────────────────────────
echo "[dsh] starting dsh web on port $DSH_PORT ..."
dsh web --port "$DSH_PORT" &
DSH_PID=$!

# ── 启动反向代理（0.0.0.0:PROXY_PORT → 127.0.0.1:DSH_PORT）──
echo "[proxy] starting proxy on port $PROXY_PORT ..."
node /opt/proxy.js &
PROXY_PID=$!

# ── 信号转发：容器 stop 时优雅退出 ────────────────────────────
cleanup() {
  kill -TERM "$PROXY_PID" 2>/dev/null
  kill -TERM "$DSH_PID"   2>/dev/null
  wait
}
trap cleanup TERM INT

wait
