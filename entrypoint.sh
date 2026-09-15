#!/bin/sh
set -e

# 端口配置（均可通过环境变量覆盖）
#   DSH_PORT    源端口（DSH 监听，容器内 127.0.0.1），默认 3079
#   PROXY_PORT  代理端口（代理对外监听），默认 3080（必须与 DSH_PORT 不同）
DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"

# ── 0. 强制认证：未显式配置凭据时生成一次性随机密码 ──────────────────
# DSH 自带终端能力（node-pty），未认证的 3080 等同于对外暴露一个 shell。
# 因此绝不静默放行：缺少 PROXY_PASSWORD 时生成随机密码并打印到容器日志。
# 注意：必须放在 admin 分支之前——admin 变体会 exec 管理服务，若认证在其后，
# admin 变体将绕过强制认证（manager 同样是「未设凭据则放行」）。
PROXY_USERNAME="${PROXY_USERNAME:-admin}"
if [ -z "${PROXY_PASSWORD:-}" ]; then
  PROXY_PASSWORD="$(node -e 'process.stdout.write(require("crypto").randomBytes(18).toString("base64url"))')"
  echo "======================================================================"
  echo "[auth] 未设置 PROXY_PASSWORD，已生成本次启动专用随机密码："
  echo "[auth]   用户名: ${PROXY_USERNAME}"
  echo "[auth]   密码:   ${PROXY_PASSWORD}"
  echo "[auth] 固定凭据请显式设置 PROXY_USERNAME / PROXY_PASSWORD 环境变量。"
  echo "======================================================================"
fi
export PROXY_USERNAME PROXY_PASSWORD DSH_PORT PROXY_PORT

# admin 变体：镜像内存在 /app/.admin-mode 标记时，改由管理服务接管
# （管理服务负责：页面安装/切换 DSH 版本、配置 npm 源、托管 DSH 进程并反向代理；
#   未安装 DSH 时访问 / 自动跳转管理员页）
if [ -f /app/.admin-mode ]; then
  echo "[admin] 检测到 admin 变体，启动 DSH 管理服务 ..."
  exec node /app/manager/index.js
fi

# ── 1. 启动 DSH（监听容器内 127.0.0.1:$DSH_PORT，不直接对外）─────────
# DSH 输出需同时落盘到 /app/.dsh-web.log：代理的 upstream-token.js 靠读该文件
# 打捞 launch token（用于根目录 401 时重发换会话 cookie）。用重定向直写文件
# （立即落盘、无管道缓冲延迟），再用 tail -f 转发到容器输出保持可见。
# 注意：不能用 `| tee` 管道——那样 $! 捕获的是 tee 的 PID，cleanup 会杀错进程。
echo "[dsh] 启动 DSH (dsh web --port $DSH_PORT) ..."
dsh web --port "$DSH_PORT" > /app/.dsh-web.log 2>&1 &
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

# ── 1.1 日志体积守护（防止 .dsh-web.log 无限增长撑满容器可写层）───────
# DSH 的 stdout 以非 O_APPEND 方式持有该文件，外部截断后其写偏移仍在高位，会
# 形成稀疏空洞：因此用 du（实际占用块数）而非 wc -c（表观大小）判断阈值。
# 轮转必须 copy-truncate（cat > 原地重写、保持 inode 不变），不能 mv，否则 DSH
# 仍写向已被改名的旧 inode。
LOG_MAX_KB="${DSH_LOG_MAX_KB:-8192}"     # 实际占用超过 8 MiB 触发轮转
LOG_KEEP_KB="${DSH_LOG_KEEP_KB:-1024}"   # 轮转后保留尾部 1 MiB
(
  while sleep 60; do
    [ -f /app/.dsh-web.log ] || continue
    used=$(du -k /app/.dsh-web.log 2>/dev/null | cut -f1)
    [ -n "$used" ] && [ "$used" -gt "$LOG_MAX_KB" ] || continue
    echo "[dsh] 日志实际占用 ${used}KiB 超过 ${LOG_MAX_KB}KiB，保留尾部 ${LOG_KEEP_KB}KiB"
    tail -c "$((LOG_KEEP_KB * 1024))" /app/.dsh-web.log > /app/.dsh-web.log.rot \
      && cat /app/.dsh-web.log.rot > /app/.dsh-web.log \
      && rm -f /app/.dsh-web.log.rot
  done
) &

# ── 2. 等待 DSH 就绪（默认最多 120 秒，可用 DSH_READY_TIMEOUT 覆盖）──
# 首次启动需装插件或 npm 源较慢时，可调大该值避免与 restart 策略形成 crash loop。
READY_TIMEOUT="${DSH_READY_TIMEOUT:-120}"
echo "[dsh] 等待 DSH 就绪 (127.0.0.1:$DSH_PORT)，最多 ${READY_TIMEOUT}s ..."
ready=0
i=0
while [ "$i" -lt "$READY_TIMEOUT" ]; do
  if node -e "fetch('http://127.0.0.1:$DSH_PORT/').then(()=>process.exit(0)).catch(()=>process.exit(1))" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$DSH_PID" 2>/dev/null; then
    echo "[dsh] 错误：DSH 进程已退出"
    exit 1
  fi
  i=$((i + 1))
  sleep 1
done

if [ "$ready" != "1" ]; then
  echo "[dsh] 错误：DSH ${READY_TIMEOUT} 秒内未就绪"
  exit 1
fi
echo "[dsh] DSH 就绪（pid $DSH_PID）"

# ── 3. 启动代理（前台运行，保持容器存活）──────────────────────────
# 注意：exec 会替换当前 shell，上面的 cleanup trap 随之失效。DSH 的存活监控与
# 优雅退出改由 proxy/index.js 承担（读 DSH_PID 环境变量），信号经 tini 转发。
echo "[proxy] 启动代理：0.0.0.0:$PROXY_PORT -> 127.0.0.1:$DSH_PORT"
cd /app/proxy
exec node index.js
