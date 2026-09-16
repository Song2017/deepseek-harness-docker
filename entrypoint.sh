#!/bin/sh
set -e

# 端口配置（均可通过环境变量覆盖）
#   DSH_PORT    源端口（DSH 监听，容器内 127.0.0.1），默认 3080
DSH_PORT="${DSH_PORT:-3080}"
export PROXY_USERNAME PROXY_PASSWORD DSH_PORT 

# ── 1. 启动 DSH（监听容器内 127.0.0.1:$DSH_PORT，不直接对外）─────────
# DSH 输出需同时落盘到 /app/.dsh-web.log：代理的 upstream-token.js 靠读该文件
# 打捞 launch token（用于根目录 401 时重发换会话 cookie）。用重定向直写文件
# （立即落盘、无管道缓冲延迟），再用 tail -f 转发到容器输出保持可见。
# 注意：不能用 `| tee` 管道——那样 $! 捕获的是 tee 的 PID，cleanup 会杀错进程。
echo "[dsh] 启动 DSH (dsh web --port $DSH_PORT) ..."
dsh web --port "3080" > /app/.dsh-web.log 2>&1 &
DSH_PID=$!
export DSH_PID
tail -f /app/.dsh-web.log &

# 容器停止时同时关闭 DSH。本 trap 只覆盖「exec node」之前的阶段（就绪探测失败
# 等提前 exit 的路径）；exec 之后 shell 被替换，信号由 tini(PID 1) 转发给 node，
# 由 proxy/index.js 负责优雅退出。
cleanup() {
  echo "[dsh] 收到退出信号，停止 DSH ..."
  kill "$DSH_PID" 2>/dev/null || true
  wait "$DSH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

