# deepseek-harness（Docker 镜像）

镜像地址（默认）：**`smanx/deepseek-harness:latest`**（Docker Hub）
镜像地址（备用）：**`ghcr.io/smanx/deepseek-harness:latest`**（GitHub Container Registry，GHCR，所有 tag 同步推送）
Docker Hub 项目主页：https://hub.docker.com/r/smanx/deepseek-harness
Github 项目主页：https://github.com/smanx/deepseek-harness-docker


一个开箱即用的 **DeepSeek Harness（DSH）** Docker 镜像，内置了 Node 反向代理，解决 DSH 官方不允许 `--host 0.0.0.0`、只能监听回环地址的问题，让 DSH 可以安全地通过局域网访问。

## 在线体验地址（Demo）

- 体验地址：https://dsh.smanx.xx.kg
- 登录账号 / 密码：`admin` / `admin`

> ⚠️ **注意：** 该地址为**公开地址**。如需填入你自己的 API Key（如 DeepSeek 等），请**谨慎填写**，以免 Key 泄露。

## 项目介绍

- **DSH**：容器内安装官方 npm 包 `@deepseek-ai/dsh`（[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)），默认监听容器内 `127.0.0.1:3079`（源端口）；
- **Node 代理**：`0.0.0.0:3080`（代理端口）→ `127.0.0.1:3079`，对外提供 HTTP + WebSocket 转发；
- **为什么需要代理**：
  - DSH 官方禁止 `--host 0.0.0.0`（安全限制），只能监听回环地址；
  - 局域网 IP 页面属于浏览器**非安全上下文**，DSH 前端依赖的 `crypto.randomUUID` 不可用，代理在转发 HTML 时自动注入基于 `getRandomValues` 的 polyfill，否则实时通道（WS）会一直 pending；
  - 代理同时提供 **HTTP Basic Auth**。DSH 自带终端能力（node-pty），未认证的对外端口等同于暴露一个 shell，因此**认证默认强制启用**：未设置 `PROXY_PASSWORD` 时启动脚本会自动生成随机密码并打印到容器日志（`docker logs` 查看）。

## 快速开始（拉取运行）

```bash
# 1. 拉取镜像（默认从 Docker Hub 拉取）
docker pull smanx/deepseek-harness:latest

# 2. 启动（默认：代理对外端口 3080，数据持久化到命名卷 dsh-data）
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:latest

# 3. 访问
#    本机：  http://127.0.0.1:3080/
#    局域网：http://<服务器局域网IP>:3080/
```

> **首次启动需要密码**：未设置 `PROXY_PASSWORD` 时会自动生成随机密码，用
> `docker logs dsh-harness` 查看（用户名默认 `admin`）。要固定密码请加
> `-e PROXY_PASSWORD=你的密码`，详见下方 [启用 Basic Auth](#启用-basic-auth)。

WebSocket 实时通道（`/api/events.mux`、`/api/events.host`）由代理自动转发，无需额外配置。

### 使用 docker compose（推荐）

配置集中在 `.env`，升级/重建更省心。仓库自带 `docker-compose.yml` 与 `.env.example`：

```bash
# 1. 克隆仓库（或单独下载 docker-compose.yml + .env.example）
git clone https://github.com/smanx/deepseek-harness-docker.git && cd deepseek-harness-docker

# 2. 准备配置（PROXY_PASSWORD 留空 = 每次启动生成随机密码）
cp .env.example .env

# 3. 启动 + 查看日志/健康状态
docker compose up -d
docker compose logs -f     # 含随机密码，Ctrl+C 退出
docker compose ps          # STATUS 应显示 Up (healthy)
```

常用运维命令：

```bash
docker compose restart                          # 重启
docker compose down                             # 停止并删除容器（dsh-data 卷保留）
docker compose pull && docker compose up -d     # 升级镜像
```

> `.env` 含明文密码，已在 `.gitignore` / `.dockerignore` 中排除，勿提交到仓库。

### 不同 tag 的区别

| tag | 定位 | 包含工具 |
|---|---|---|
| `latest` | 精简运行镜像 | 无（仅 Node 运行时 + DSH + 反向代理） |
| `devtools-min-latest` | 精简工具版，常用调试工具 | git、curl、wget、nano、jq、procps、ca-certificates、unzip；npm 全局包：pnpm；uv |
| `devtools-latest` | 完整工具版，可在容器内开发/编译 | 精简版全部 + vim、openssh-client、zip、htop、tmux、tree、openssl、python3、build-essential(make+g++)、bash-completion；npm 全局包：pnpm；uv |
| `admin-latest` | 管理版：**预装最新 DSH**，开箱即用，页面自选版本安装/切换 | 同完整工具版（含 pnpm、uv）+ 管理服务；保留 python3/build-essential 供运行时编译 node-pty |

> 每个 tag 都有对应的**版本号 tag**：`latest` ↔ `<版本>`、`devtools-latest` ↔ `devtools-<版本>`、`devtools-min-latest` ↔ `devtools-min-<版本>`、`admin-latest` ↔ `admin-<版本>`（admin 预装最新 DSH，版本号 tag 即为 DSH 版本）。

**简单示例：**

```bash
# 场景一：只想在浏览器里跑 DSH，不做任何调试 → 用精简的 latest
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:latest

# 场景二：需要进容器排查问题（看日志、jq 处理 JSON、wget 抓包）→ 用 devtools-min-latest
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:devtools-min-latest

# 场景三：要在容器里开发/编译扩展或做较重的运维（vim、python3、make 等）→ 用 devtools-latest
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:devtools-latest
```

三个 tag 的启动命令完全一样，只是把镜像名替换成对应的 tag 即可；`latest` 之外的工具版镜像会比精简版略大，按需选择。

> 工具版（devtools / devtools-min / test）内置 **pnpm**（npm 全局安装）。DSH 的 `dsh plugin` 命令依赖 pnpm 管理插件，
> 社区插件市场 [dsh-market](https://github.com/dsh-market/dsh-market)（`dsh plugin --profile web add dshmarket`）也需要它；
> 精简版 `latest` 不内置，首次使用插件时 dsh-market 会检测缺失并提供一键自动安装。
>
> 工具版还内置 **uv**（Python 包管理器，静态二进制，不依赖系统 Python）。不少社区 MCP server 以
> `uvx` / `uv run` 方式启动（DSH 的 MCP 客户端配置中常见 `"command": "uvx"`），缺少 uv 时这类 MCP 无法运行。

#### admin 变体（管理版，预装最新 DSH）

`admin` 变体**随镜像预装最新 DSH（@next）**。容器启动后管理服务自动识别并拉起 DSH，直接访问 `/` 即可进入 DSH 界面；访问 `/__admin/` 进入管理台：

- 查看 `@deepseek-ai/dsh` 可用版本（`latest`/`next` 等 dist-tag + 全部版本），选择并**安装 / 切换**版本，安装进度实时显示；
- 手动配置 **npm 源（NPM_CONFIG_REGISTRY）**：输入框**自动回显默认值**（环境变量 `NPM_CONFIG_REGISTRY` 或官方源）与**上次配置的值**，并显示当前生效值，可一键「使用默认值」或清空恢复默认；优先级：**页面配置 > 环境变量 `NPM_CONFIG_REGISTRY` > 默认值**；
- 一键**重启** DSH；安装完成后自动启动，页面右下角悬浮「⚙ 管理」按钮可随时回到管理台调整版本。

```bash
# admin 变体：需要两个命名卷（dsh-data 存 DSH 配置/会话、dsh-install 存 DSH 安装文件与配置状态，
# 这样容器重建后升级/源配置依然有效）
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v dsh-install:/opt/dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:admin-latest
```

> admin 变体保留了 `python3` + `build-essential`（node-pty 在 Linux 上无预编译产物，管理台安装其他版本 DSH 时需容器内从源码编译原生模块），镜像比精简版略大。

### 备用镜像（GHCR）

如果从 Docker Hub 拉取受限（如网络问题），可以使用备用镜像（GitHub Container Registry，tag 与 Docker Hub 完全一致）：

```bash
# 拉取 GHCR 上的镜像
docker pull ghcr.io/smanx/deepseek-harness:latest

# 启动命令与默认镜像完全一样，只需替换镜像名
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  ghcr.io/smanx/deepseek-harness:latest
```

> 除镜像地址不同外，两个镜像的配置与使用方式完全一致，可互相替换。

## 配置（环境变量）

| 环境变量 | 含义 | 默认值 |
|---|---|---|
| `DSH_PORT` | 源端口：DSH 在容器内监听（`127.0.0.1`） | `3079` |
| `PROXY_PORT` | 代理端口：代理对外监听（局域网入口） | `3080` |
| `PROXY_USERNAME` | Basic Auth 用户名 | `admin` |
| `PROXY_PASSWORD` | Basic Auth 密码；**未设置则启动时自动生成随机密码并打印到日志** | （随机生成） |
| `ALLOW_REMOTE_SETTINGS` | 是否允许非回环访问使用 DSH 设置类功能（改写 `isLoopbackHostname` 为恒真）；设 `false` 关闭 | `true` |
| `DSH_READY_TIMEOUT` | 等待 DSH 就绪的超时秒数（首次装插件/npm 源慢时可调大） | `120` |
| `DSH_LOG_MAX_KB` / `DSH_LOG_KEEP_KB` | `.dsh-web.log` 轮转触发阈值 / 轮转后保留尾部大小（KiB） | `8192` / `1024` |
| `DSH_LIVENESS_INTERVAL` | 代理探测 DSH 进程存活的间隔（毫秒）；DSH 崩溃则退出容器触发重启 | `10000` |
| `PROXY_MAX_BODY_BYTES` | 单个响应体缓冲上限（字节），超限则放弃改写、原样透传 | `33554432`（32 MiB） |
| `PROXY_MAX_DECOMPRESSED_BYTES` | 解压后体积上限（防解压炸弹） | `67108864`（64 MiB） |
| `DSH_MAX_INDEX_BYTES` | 根目录首页读取上限（字节） | `4194304`（4 MiB） |
| `NPM_CONFIG_REGISTRY` | admin 变体管理页「npm 源」的默认值（优先级低于页面配置） | `https://registry.npmjs.org/` |
| `DSH_INSTALL_DIR` | admin 变体 DSH 安装目录（页面安装的 DSH 及状态文件都在这里，建议挂载命名卷） | `/opt/dsh` |

> `DSH_PORT` 与 `PROXY_PORT` 必须不同（同一端口只能被一个进程监听）。
> 修改 `PROXY_PORT` 时，`-p` 端口映射要对应改成 `-p <宿主机端口>:<新代理端口>`。

### 启用 Basic Auth

认证**默认强制启用**（DSH 自带终端能力，未认证的对外端口等同于暴露一个 shell）：

- **未设置 `PROXY_PASSWORD`**：启动时自动生成本次运行专用的随机密码并打印到日志，用
  `docker logs dsh-harness` 查看（用户名默认 `admin`）。随机密码每次重启都会变化。
- **显式设置固定凭据**（推荐，重启后不变）：

```bash
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -e PROXY_USERNAME=yourname \
  -e PROXY_PASSWORD=yourpass \
  --restart unless-stopped \
  smanx/deepseek-harness:latest
```

- 认证对 HTTP 和 WebSocket 都生效，未通过认证返回 `401` + `WWW-Authenticate`，浏览器会弹出认证框；
- 公开静态资源 `/manifest.webmanifest`、`/favicon.svg`、`/favicon.ico` 不参与认证（只含应用名/图标等非敏感数据）。浏览器抓取 `<link rel="manifest">` 时不会携带 Basic Auth 凭据，若强制认证，控制台会持续报 `/manifest.webmanifest` 401。

> **安全提示**：Basic Auth 凭据通过环境变量传递，`docker inspect` 与 `/proc/<pid>/environ` 可见。
> 对安全要求更高的场景，建议把容器置于反向代理（如 Traefik/Caddy）之后，由反代统一做认证与 TLS，
> 并仅让容器监听内网。

### 修改代理端口

```bash
# 例如代理对外用 3088
docker run -d \
  --name dsh-harness \
  -p 3088:3088 \
  -v dsh-data:/home/node/.dsh \
  -e PROXY_PORT=3088 \
  --restart unless-stopped \
  smanx/deepseek-harness:latest
```

## 数据持久化

DSH 的会话/配置数据保存在容器内 `/home/node/.dsh`，上面的命令用命名卷 `dsh-data` 持久化：

- `docker stop/start` 和容器删除后卷仍在，数据不丢；
- 彻底清除数据：`docker volume rm dsh-data`（先停容器）。

> **运行用户为 `node`（uid 1000），非 root。** 卷挂载路径是 `/home/node/.dsh`（早期版本为 `/root/.dsh`）。
> **从旧版本升级**：旧卷文件属主是 root，直接挂到新镜像会因权限不足导致 DSH 写入失败。重建容器前先修正属主：
> `docker run --rm -v dsh-data:/data alpine chown -R 1000:1000 /data`；
> 若旧部署仍把卷挂在 `/root/.dsh`，需改为 `/home/node/.dsh`，否则数据写到未挂载的容器层、重建即丢。

## 稳定性与运维

镜像在稳定性方面做了以下加固（多数可通过环境变量调整，见 [配置](#配置环境变量)）：

- **进程模型**：`tini` 作 PID 1，转发信号并回收僵尸进程；
- **DSH 存活监控**：上游 DSH 崩溃后代理会退出容器，交给 `--restart` 策略重建，避免「永久 502」；
- **优雅退出**：收到 SIGTERM/SIGINT 后停止接收新连接、关闭已有连接、终止 DSH 再退出；
- **健康检查**：内置 `HEALTHCHECK`，`docker ps` 的 STATUS 列显示 `(healthy)` / `(unhealthy)`；
- **日志轮转**：`.dsh-web.log` 按实际磁盘占用自动轮转（copy-truncate），防止撑满容器可写层；
- **响应体保护**：解压/重压异步执行且对体积设上限，兼顾大文件与解压炸弹防护。

> **可复现构建**：默认安装 `@deepseek-ai/dsh@next`。生产环境建议固定版本：
> `docker build --build-arg DSH_VERSION=0.1.2 -t smanx/deepseek-harness .`

## 停止 / 重启 / 删除

```bash
docker stop dsh-harness     # 停止
docker start dsh-harness    # 再次启动
docker logs -f dsh-harness  # 查看日志
docker rm -f dsh-harness    # 删除容器（卷中的数据保留）
```

## 联系作者 / 反馈

- 交流与 Bug 反馈：https://github.com/deepseek-ai/deepseek-harness/discussions/1762
