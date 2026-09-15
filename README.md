# deepseek-harness

[English](README_EN.md) | 中文

Docker 化部署 **DeepSeek Harness（DSH）** + **Node 反向代理**：

1. 容器内安装并启动 DSH（[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 的官方 npm 包 `@deepseek-ai/dsh`），默认监听容器内 `127.0.0.1:3079`（源端口）；
2. 启动 Node 代理：`0.0.0.0:3080`（代理端口）→ `127.0.0.1:3079`，提供局域网访问 + WebSocket 转发。

> 为什么要代理而不是直接暴露 DSH：
> - DSH 的 `--host 0.0.0.0` 被官方禁止（安全限制），只能监听回环地址；
> - 局域网 IP 页面属于浏览器非安全上下文，DSH 前端依赖的 `crypto.randomUUID` 不可用，
>   代理通过注入 polyfill 解决（否则实时通道/WS 一直 pending）；
> - 代理同时提供 **HTTP Basic Auth**。DSH 自带终端能力（node-pty），未认证的对外端口
>   等同于暴露一个 shell，因此**认证默认强制启用**：未设置 `PROXY_PASSWORD` 时
>   `entrypoint.sh` 会自动生成随机密码并打印到容器日志（详见 [Basic Auth](#basic-auth默认强制启用)）。

## 目录结构

```
deepseek-harness/
├── Dockerfile            # node:24-slim + 安装 DSH + 代理（支持 DEV_TOOLS / DSH_VERSION 构建参数；admin 变体预装最新 DSH）
├── docker-compose.yml    # compose 部署（拉取或构建镜像，配置走 .env）
├── .env.example          # compose 环境变量模板（复制为 .env 后修改）
├── entrypoint.sh         # 强制认证 → 启动 DSH → 日志轮转守护 → 等待就绪 → 启动代理（admin 变体改走管理服务）
├── proxy/
│   ├── index.js          # 代理（转发 + polyfill 注入 + Origin 对齐 + Basic Auth + DSH 存活监控 + 优雅退出）
│   ├── compression.js    # 响应体「解压 → 改写 → 重压」异步管线（gzip/deflate/br，带体积上限）
│   ├── upstream-token.js # 上游 launch token 自动打捞（DSH 0.1.2+ 的 401 → token 换会话 cookie）
│   └── package.json
├── manager/              # admin 变体专用：页面安装/切换 DSH 版本、配置 npm 源、托管 DSH 进程
│   ├── index.js
│   ├── admin.html
│   └── package.json
└── README.md / README_EN.md
```

## 使用

```bash
# 进入项目目录
cd deepseek-harness

# 构建镜像（默认精简运行镜像，不带开发工具）
docker build -t songgs/deepseek-harness . 

# 启动（默认：代理对外端口 3080，数据持久化到命名卷 dsh-data）
# registry.cn-shanghai.aliyuncs.com/nsmi/deepseek-harness:latest
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  songgs/deepseek-harness 

# 查看日志
docker logs -f dsh-harness

# 停止 / 删除（卷中的数据保留）
docker stop dsh-harness
docker rm dsh-harness
```

> 首次启动未设置 `PROXY_PASSWORD` 时，日志里会打印自动生成的随机访问密码（用户名默认 `admin`），
> 用 `docker logs dsh-harness` 查看。要固定密码请在 `docker run` 时加 `-e PROXY_PASSWORD=...`，
> 详见 [Basic Auth](#basic-auth默认强制启用)。

构建会通过 npm 安装 DSH（约 250MB 依赖），首次构建较慢属正常。
Linux 下 node-pty 没有预编译产物，会从源码编译（Dockerfile 已用多阶段构建装好 python3/make/g++，
编译完成后运行镜像不保留编译工具）。

## docker compose

项目自带 [docker-compose.yml](docker-compose.yml) 与 [.env.example](.env.example)，
推荐用 compose 部署（配置集中在 `.env`，升级/重建更省心）：

```bash
# 1. 准备配置（可选：填入固定密码、改端口）
cp .env.example .env
# 编辑 .env：PROXY_PASSWORD 留空 = 每次启动生成随机密码

# 2. 启动（拉取镜像）
docker compose up -d

# 3. 查看日志 / 随机密码 / 健康状态
docker compose logs -f      # Ctrl+C 退出
docker compose ps           # STATUS 应显示 Up (healthy)
```

常用运维命令：

```bash
docker compose restart                          # 重启
docker compose down                             # 停止并删除容器（dsh-data 卷保留）
docker compose pull && docker compose up -d     # 升级镜像
docker compose exec dsh-harness bash            # 进入容器（devtools 变体才有 bash）
```

从源码构建（而非拉取镜像）：

```bash
# 可用 .env 里的 DSH_VERSION / DEV_TOOLS 控制构建参数
docker compose build
docker compose up -d
```

> `.env` 含明文密码，已在 `.gitignore` / `.dockerignore` 中排除，勿提交到仓库。
> compose 里的 `ports` 映射为 `${HOST_PORT}:${PROXY_PORT}`，改 `PROXY_PORT` 时
> `HOST_PORT` 会跟着 `.env` 自动对齐，无需手改 compose 文件。

## 各 tag 的区别

默认运行镜像为精简版，不保留编译工具，适合生产部署。若需要在容器内开发/调试，
构建时用 `--build-arg DEV_TOOLS=<tag前缀>` 启用开发工具；各前缀安装哪些工具
在项目根目录的 `.build-variants` 文件中定义（每行 `<tag前缀>|<apt 工具列表>|<npm 全局包列表>`，
第二列走 apt-get install，第三列走 npm install -g，可留空），
直接编辑该文件即可动态增删工具，无需改动 Dockerfile。
每个 tag 同时提供对应的**版本号 tag**（版本号与构建时实际安装的 `@deepseek-ai/dsh` 版本一致，当前 `<版本>`）：

| tag（最新） | 版本 tag | 定位 | 包含工具 |
|---|---|---|---|
| `songgs/deepseek-harness:latest` | `songgs/deepseek-harness:<版本>` | 原版精简镜像，适合生产部署 | 无开发工具 |
<!-- | `songgs/deepseek-harness:devtools-min-latest` | `songgs/deepseek-harness:devtools-min-<版本>` | 精简工具版，常用调试工具 | git、curl、wget、nano、jq、procps、ca-certificates、unzip；npm 全局包：pnpm；uv |
| `songgs/deepseek-harness:devtools-latest` | `songgs/deepseek-harness:devtools-<版本>` | 完整工具版，可在容器内开发/编译 | 精简版全部 + vim、openssh-client、zip、htop、tmux、tree、openssl、python3、build-essential(make+g++)、bash-completion；npm 全局包：pnpm；uv |
| `songgs/deepseek-harness:test-latest` | `songgs/deepseek-harness:test-<版本>` | 测试 tag：完整工具 + 自动安装 DSH 插件 | 同完整工具版（含 pnpm、uv）；DSH 安装后额外执行 `dsh plugin --profile web add github:songgs/dsh-conversation-indicator#main` |
| `songgs/deepseek-harness:admin-latest` | `songgs/deepseek-harness:admin-<版本>` | 管理版：**预装最新 DSH**，开箱即用，管理台可自选版本安装/切换 | 同完整工具版（含 pnpm、uv）+ 管理服务；保留 python3/build-essential 供运行时编译 node-pty | 

```bash
# 精简工具版（DEV_TOOLS=前缀与 .build-variants 第一列一致）
docker build -t songgs/deepseek-harness:devtools-min-<版本> --build-arg DEV_TOOLS=devtools-min .

# 完整工具版
docker build -t songgs/deepseek-harness:devtools-<版本> --build-arg DEV_TOOLS=devtools .
```

> GitHub Actions（`docker-build/.github/workflows/projects.yml`）按各项目目录下的 `.build-variants`
> 清单自动打包并推送全部 tag（Docker Hub 与 GHCR 各一组）。

> 完整工具版含 `python3` + `build-essential`，可在容器内直接编译原生模块（如 node-pty），
> 相当于把多阶段构建里 `dsh-builder` 阶段的编译工具也带进了运行镜像。
> 版本号随 `@deepseek-ai/dsh` 实际版本更新，例如升级到 `0.2.0` 后 tag 应改为
> `devtools-0.2.0` / `devtools-min-0.2.0`。

> 工具版（devtools / devtools-min / test）内置 **pnpm**（npm 全局安装），
> DSH 的 `dsh plugin` 命令依赖 pnpm 管理插件，社区插件市场 [dsh-market](https://github.com/dsh-market/dsh-market)
> （`dsh plugin --profile web add dshmarket`）也需要它；精简版 `latest` 不内置，首次使用插件时
> dsh-market 会检测缺失并提供一键自动安装。
>
> 工具版还内置 **uv**（Python 包管理器，静态二进制，不依赖系统 Python）。
> 不少社区 MCP server 以 `uvx` / `uv run` 方式启动（DSH 的 MCP 客户端配置中常见
> `"command": "uvx"`），缺少 uv 时这类 MCP 无法运行；uv 会在首次使用时按需下载 Python 解释器。 -->

### admin 变体（管理版，预装最新 DSH）

`admin` 变体**随镜像预装最新 DSH（@next）**，容器启动后管理服务自动识别并拉起 DSH，直接访问 `/` 即可进入 DSH 界面；
访问 `/__admin/` 进入管理台，你可以在页面上：

- 查看 npm 包 `@deepseek-ai/dsh` 的可用版本（`latest`/`next` 等 dist-tag + 全部版本列表），
  选择并**安装 / 切换** DSH 版本，安装进度实时显示；
- 手动配置 **npm 源（NPM_CONFIG_REGISTRY）**：输入框会**自动回显默认值**（环境变量
  `NPM_CONFIG_REGISTRY` 或官方源 `https://registry.npmjs.org/`）与**上次配置的值**，
  并显示当前生效值，可一键「使用默认值」或清空恢复默认；
  优先级：**页面配置 > 环境变量 `NPM_CONFIG_REGISTRY` > 默认值**；
- 一键**重启** DSH；安装完成后 DSH 自动启动，页面右下角悬浮「⚙ 管理」按钮可随时回到管理台调整版本。

启动命令（需要两个命名卷：`dsh-data` 保存 DSH 配置/会话、`dsh-install` 保存 DSH 安装文件与配置状态，
容器重建后升级/源配置依然有效）：

```bash
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v dsh-install:/opt/dsh \
  --restart unless-stopped \
  songgs/deepseek-harness:admin-latest
```

> admin 变体保留了 `python3` + `build-essential`：node-pty 在 Linux 上没有预编译产物，
> 在管理台安装其他版本 DSH 时需要容器内从源码编译原生模块，因此该镜像比精简版略大。
> admin 变体预装最新 DSH，版本号 tag 即为 DSH 版本（如 `admin-0.1.1`）。

## 端口配置

源端口（DSH）和代理端口（对外）都可通过环境变量配置，默认值：

| 环境变量 | 含义 | 默认值 |
|---|---|---|
| `DSH_PORT` | 源端口：DSH 监听（容器内 `127.0.0.1`） | `3079` |
| `PROXY_PORT` | 代理端口：代理对外监听（局域网入口） | `3080` |

> 两者必须不同（同一端口只能被一个进程监听）。

认证与稳定性相关环境变量：

| 环境变量 | 含义 | 默认值 |
|---|---|---|
| `PROXY_USERNAME` | Basic Auth 用户名 | `admin` |
| `PROXY_PASSWORD` | Basic Auth 密码；**未设置则启动时自动生成随机密码** | （随机生成） |
| `ALLOW_REMOTE_SETTINGS` | 是否允许非回环访问使用 DSH 设置类功能（改写 `isLoopbackHostname` 为恒真）。设 `false` 关闭 | `true` |
| `DSH_READY_TIMEOUT` | 等待 DSH 就绪的超时秒数；首次装插件/npm 源慢时可调大，避免与 restart 策略形成 crash loop | `120` |
| `DSH_LOG_MAX_KB` | `.dsh-web.log` 实际占用超过该值（KiB）触发轮转 | `8192` |
| `DSH_LOG_KEEP_KB` | 轮转后保留的日志尾部大小（KiB） | `1024` |
| `DSH_LIVENESS_INTERVAL` | 代理探测 DSH 进程存活的间隔（毫秒）；DSH 崩溃则退出容器触发重启 | `10000` |
| `PROXY_MAX_BODY_BYTES` | 单个响应体缓冲上限（字节），超限则放弃改写、原样透传 | `33554432`（32 MiB） |
| `PROXY_MAX_DECOMPRESSED_BYTES` | 解压后体积上限（防解压炸弹） | `67108864`（64 MiB） |
| `DSH_MAX_INDEX_BYTES` | 根目录首页读取上限（字节） | `4194304`（4 MiB） |

admin 变体另有以下环境变量：

| 环境变量 | 含义 | 默认值 |
|---|---|---|
| `NPM_CONFIG_REGISTRY` | admin 管理页「npm 源」的默认值（页面未配置时使用；优先级低于页面配置） | `https://registry.npmjs.org/` |
| `DSH_INSTALL_DIR` | admin 变体中 DSH 的安装目录（页面安装的 DSH 及状态文件都在这，建议挂载命名卷） | `/opt/dsh` |

例如改为「DSH 内部 3082、代理对外 3080」：

```bash
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -e DSH_PORT=3082 \
  --restart unless-stopped \
  songgs/deepseek-harness
```

## 访问

- 本机：`http://127.0.0.1:3080/`
- 局域网：`http://<服务器局域网IP>:3080/`（如 `http://192.168.1.100:3080/`）
- WebSocket 实时通道由代理自动转发（`/api/events.mux`、`/api/events.host`）

## Basic Auth（默认强制启用）

DSH 自带终端能力（node-pty），未认证的对外端口等同于暴露一个 shell。因此认证**默认强制启用**：

- **未设置 `PROXY_PASSWORD`**：`entrypoint.sh` 自动生成本次启动专用的随机密码，并打印到容器日志。
  用 `docker logs dsh-harness` 查看：

  ```
  ======================================================================
  [auth] 未设置 PROXY_PASSWORD，已生成本次启动专用随机密码：
  [auth]   用户名: admin
  [auth]   密码:   <随机字符串>
  [auth] 固定凭据请显式设置 PROXY_USERNAME / PROXY_PASSWORD 环境变量。
  ======================================================================
  ```

  > 随机密码每次容器重启都会变化。要固定凭据，请显式设置环境变量（见下）。

- **显式设置凭据**（推荐，重启后不变）：

  ```bash
  docker run -d \
    --name dsh-harness \
    -p 3080:3080 \
    -v dsh-data:/home/node/.dsh \
    -e PROXY_USERNAME=yourname \
    -e PROXY_PASSWORD=yourpass \
    --restart unless-stopped \
    songgs/deepseek-harness
  ```

- 认证对 HTTP 和 WebSocket 都生效；未通过认证返回 `401` + `WWW-Authenticate`，浏览器会弹出认证框；
- 公开静态资源 `/manifest.webmanifest`、`/favicon.svg`、`/favicon.ico` 不参与认证
  （只含应用名/图标等非敏感数据）。浏览器抓取 `<link rel="manifest">` 时不会携带
  Basic Auth 凭据，若强制认证，控制台会持续报 `/manifest.webmanifest` 401。

> **安全提示**：Basic Auth 凭据通过环境变量传递，`docker inspect` 与 `/proc/<pid>/environ`
> 可见。对安全要求更高的场景，建议把容器置于反向代理（如 Traefik/Caddy）之后，
> 由反代统一做认证与 TLS，并仅让容器监听内网。

## 数据持久化

DSH 的会话/配置数据保存在命名卷 `dsh-data`（容器内 `/home/node/.dsh`）。
`docker stop/start` 与删除容器后卷仍在，数据不丢；彻底清除需先停容器再 `docker volume rm dsh-data`。

> **运行用户为 `node`（uid 1000），非 root。** 容器内 DSH 的数据目录、插件、配置均基于
> `$HOME=/home/node` 解析，因此卷挂载路径是 `/home/node/.dsh`（早期版本为 `/root/.dsh`）。
>
> **从旧版本（`/root/.dsh`）升级**：旧卷里的文件属主是 root，直接挂到新镜像会因权限不足
> 导致 DSH 写入失败。重建容器前先修正属主：
>
> ```bash
> docker run --rm -v dsh-data:/data alpine chown -R 1000:1000 /data
> ```
>
> 若旧部署仍把卷挂在 `/root/.dsh`，需改为 `/home/node/.dsh`，否则数据会写到未挂载的容器层、重建即丢。

## 说明

- DSH 官方禁止 `--host 0.0.0.0`，因此容器内 DSH 保持默认回环监听，代理负责对外；
- 若 `node:24-slim` 下 DSH 因缺少系统库启动失败，可将 Dockerfile 两个阶段的基础镜像都改为 `node:24` 再构建；
- 代理逻辑与独立版 [dsh-proxy](https://github.com/songgs/dsh-proxy) 一致（polyfill 注入、Origin 对齐、Basic Auth、WS 转发）。
- DSH 前端用 `connection.isLoopback` 决定设置类功能是否可用（设置里的插件配置卡片、设置文件按钮等），
  且只把 `localhost`/`127.x.x.x` 等回环主机名算作 loopback。通过主机名/局域网 IP 访问时这些功能会被隐藏
  （例如「插件配置」页从 3 个卡片变成空列表）。代理在转发 JS 时把
  `isLoopbackHostname(pageLocation.hostname)` 判定改写为恒真，使局域网访问也能正常使用设置功能。
  该改写会打穿 DSH 自身的回环安全边界，因此受 `ALLOW_REMOTE_SETTINGS` 开关控制（默认 `true`，
  设 `false` 可关闭改写、仅保留基础功能）。

## 稳定性与运维

镜像在稳定性方面做了以下加固，多数行为可通过环境变量调整（见 [端口配置](#端口配置)）：

- **进程模型**：`tini` 作 PID 1，负责转发信号并回收僵尸进程；`entrypoint.sh` 派生的 DSH、
  `tail -f`、日志轮转子 shell 退出后不会残留僵尸。
- **DSH 存活监控**：上游 DSH 崩溃后代理仍会响应（对每个请求回 502），容器 STATUS 保持 `Up`、
  `restart` 策略不触发。代理每 `DSH_LIVENESS_INTERVAL` 探测一次 DSH 进程，进程消失即退出容器，
  交给 `--restart` 策略重建，避免「永久 502」。
- **优雅退出**：收到 SIGTERM/SIGINT 后停止接收新连接、关闭已有连接、终止 DSH 再退出（10s 超时强制退出）。
- **崩溃兜底**：根目录 `serveIndex` 的 Promise 已挂 `.catch`（Node 24 默认对未处理拒绝直接终止进程）；
  另有 `uncaughtException` / `unhandledRejection` / `clientError` / `listen error` 兜底，异常时记录并退出重建，
  不会停在「端口在听但不转发」的半死状态。
- **健康检查**：镜像内置 `HEALTHCHECK`（探测代理端口，`start-period` 130s 覆盖首次启动）。
  `docker ps` 的 STATUS 列会显示 `(healthy)` / `(unhealthy)`。
- **日志轮转**：`.dsh-web.log` 由后台守护按实际磁盘占用（`du`，规避稀疏空洞）轮转，copy-truncate
  保持 inode 不变，防止长期运行撑满容器可写层。
- **响应体保护**：解压/重压改为异步（不阻塞事件循环），并对缓冲体积、解压后体积设上限，
  超限则放弃改写、原样透传，兼顾大文件与解压炸弹防护。

> **可复现构建**：默认安装 `@deepseek-ai/dsh@next`（跟随上游预发布）。生产环境建议固定版本：
> `docker build --build-arg DSH_VERSION=0.1.2 -t songgs/deepseek-harness .`
