# DSH（DeepSeek Harness）需要 Node.js；官方 npm 包 @deepseek-ai/dsh 已验证可在 Node 24 运行
# （官方以 Node 24.19.0 构建/验证）
#
# 关键点：@deepseek-ai/dsh 依赖的原生模块 node-pty（终端）在 npm 包里只带 macOS/Windows
# 的预编译产物（prebuilds/ 下仅有 darwin-arm64/darwin-x64/win32-arm64/win32-x64），
# Linux 上没有任何预编译二进制，安装时必然回退到 node-gyp 从源码编译，需要
# python3 + make + g++。node:24-slim 不含这些工具，直接 `npm install -g @deepseek-ai/dsh`
# 会报：
#   gyp ERR! find Python ... Could not find any Python installation to use
# 因此采用多阶段构建：先在带编译工具的阶段安装 DSH（顺带编译 node-pty），
# 再把 /usr/local（Node + DSH + 编译产物）复制进精简运行镜像，运行镜像不保留编译工具。

# ── 阶段 1：安装 DSH 并编译原生模块 ────────────────────────────────
# admin 变体预装最新 DSH（@next）到 /opt/dsh（即管理服务的安装目录，挂载空卷时自动填充、开箱即用）
FROM node:24-slim AS dsh-builder
ARG DEV_TOOLS=none
# DSH 版本：默认 next（跟随上游预发布）。生产环境建议构建时固定具体版本以获得可复现构建：
#   docker build --build-arg DSH_VERSION=0.1.2 ...
ARG DSH_VERSION=next
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/* \
    && if [ "$DEV_TOOLS" = "admin" ]; then \
         npm install -g --prefix /opt/dsh --no-audit --no-fund "@deepseek-ai/dsh@${DSH_VERSION}"; \
       else \
         npm install -g --no-audit --no-fund "@deepseek-ai/dsh@${DSH_VERSION}"; \
       fi \
    && mkdir -p /opt/dsh

# ── 阶段 2：精简运行镜像 ───────────────────────────────────────────
FROM node:24-slim
WORKDIR /app

# 运行用户为 node（见文件末尾 USER 指令），因此 HOME 必须指向其家目录：
# DSH 的数据目录（.dsh）、插件、配置均基于 $HOME 解析。
# 注意：这改变了数据卷挂载路径——旧版为 /root/.dsh，现为 /home/node/.dsh。
ENV HOME=/home/node

# 开发工具变体开关：none（默认，不装）| <tag 前缀>（如 devtools / devtools-min）
# 构建时通过 --build-arg DEV_TOOLS=<前缀> 启用；各前缀要安装的工具由
# .build-variants 文件按前缀定义，直接编辑该文件即可增删工具
ARG DEV_TOOLS=none
ARG DSH_VERSION=next

# 复制 Node 运行时 + DSH（含编译好的 node-pty）。两阶段同为 node:24-slim，
# /usr/local 内容一致，仅多出 npm 全局安装的 @deepseek-ai/dsh
COPY --from=dsh-builder /usr/local/ /usr/local/

# admin 变体：把构建阶段预装的最新 DSH 复制到管理服务安装目录 /opt/dsh
# （首次挂载空卷时 Docker 自动填充该目录，管理服务启动即识别并自动拉起 DSH）
COPY --from=dsh-builder /opt/dsh/ /opt/dsh/

# 生成版本文件，供 CI（docker-build/.github/workflows/projects.yml）用 docker cp 提取 APP_VERSION 打镜像标签；
# 若该文件缺失，CI 会回退为日期标签；admin 变体预装在 /opt/dsh，其余变体在 /usr/local
RUN if [ "$DEV_TOOLS" = "admin" ]; then \
      node -p "'APP_VERSION=' + require('/opt/dsh/lib/node_modules/@deepseek-ai/dsh/package.json').version" > /tmp/app_version.env; \
    else \
      node -p "'APP_VERSION=' + require('/usr/local/lib/node_modules/@deepseek-ai/dsh/package.json').version" > /tmp/app_version.env; \
    fi

# 代理代码及其依赖（http-proxy）
COPY proxy/ /app/proxy/
RUN cd /app/proxy && npm install --omit=dev --no-audit --no-fund

# 管理服务（admin 变体专用）：页面安装/切换 DSH 版本、配置 npm 源、托管 DSH 进程并反向代理
COPY manager/ /app/manager/
RUN cd /app/manager && npm install --omit=dev --no-audit --no-fund

# 启动脚本（默认流程：先启动 DSH，等待就绪后启动代理）
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# tini 作为 PID 1：负责转发信号并 reap 僵尸进程。
# entrypoint.sh 会派生 DSH、tail -f、日志轮转子 shell 等多个后台进程，且最后
# `exec node index.js` 替换掉 shell —— 没有 init 进程时这些子进程退出后会变成
# 僵尸，SIGTERM 也无法送达整个进程组。
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini, curl \
    && rm -rf /var/lib/apt/lists/*

# admin 变体标记：镜像内存在 /app/.admin-mode 时 entrypoint.sh 改走管理服务
# （预装最新 DSH，管理台仍可自选版本安装/切换、配置 npm 源）
RUN if [ "$DEV_TOOLS" = "admin" ]; then touch /app/.admin-mode; fi

# ── 开发工具（按 DEV_TOOLS 前缀从 .build-variants 读取工具列表安装）──
# .build-variants 每行：<tag前缀>|<apt 工具列表>|<npm 全局包列表（可空）>|<uv 安装标记（1=装/空=不装）>，DEV_TOOLS 取第一列前缀值
# 基础镜像（DEV_TOOLS=none）不装任何工具
COPY .build-variants /app/.build-variants
RUN if [ -n "$DEV_TOOLS" ] && [ "$DEV_TOOLS" != "none" ]; then \
      PACKAGES="$(awk -F'|' -v p="$DEV_TOOLS" '$1==p {print $2}' /app/.build-variants)"; \
      NPM_PKGS="$(awk -F'|' -v p="$DEV_TOOLS" '$1==p {print $3}' /app/.build-variants)"; \
      UV_FLAG="$(awk -F'|' -v p="$DEV_TOOLS" '$1==p {print $4}' /app/.build-variants)"; \
      if [ -n "$PACKAGES" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends $PACKAGES \
        && rm -rf /var/lib/apt/lists/*; \
      fi; \
      if [ -n "$NPM_PKGS" ]; then \
        npm install -g --no-audit --no-fund $NPM_PKGS; \
      fi; \
      if [ "$UV_FLAG" = "1" ]; then \
        curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh; \
      fi; \
    fi

# ── 特殊测试 tag（DEV_TOOLS=test）：DSH 安装完毕后额外安装插件 ────────
# 以最终运行用户 node 的 HOME 安装，确保插件落到 /home/node/.dsh 而非 /root/.dsh
RUN if [ "$DEV_TOOLS" = "test" ]; then \
      HOME=/home/node dsh plugin --profile web add github:smanx/dsh-fixed-providers#master; \
    fi

# ── 权限收敛：运行期以非 root 用户 node 运行 ────────────────────────
# DSH 自带终端能力（node-pty），root 运行会放大容器逃逸/越权风险。
# 把运行期需要写入的目录（/app 下的日志与 token、/opt/dsh 管理服务安装目录、
# node 家目录）属主交给 node。/usr/local 只读运行，无需改属主。
RUN chown -R node:node /app /opt/dsh /home/node

# 对外端口：代理/管理服务默认均监听 3080（DSH 在容器内监听 127.0.0.1:<DSH_PORT>，不直接暴露）
EXPOSE 3080

# 健康检查：探测代理端口。DSH 崩溃后代理仍存活（回 502），故这里探测的是
# 「代理 + 上游」整链路——通过根目录（带认证会 401，仍算端口存活；无认证回 200）。
# 用 node 内置 fetch，避免依赖 curl/wget（基础镜像未必带）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=130s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PROXY_PORT||3080)+'/').then(()=>process.exit(0)).catch(()=>process.exit(1))"

USER node

ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
