# deepseek-harness

English | [中文](README.md)

Deploy **DeepSeek Harness (DSH)** + **Node reverse proxy** with Docker:

1. Install and start DSH inside the container (official npm package `@deepseek-ai/dsh` from [deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)), listening on `127.0.0.1:3079` (source port) by default;
2. Start a Node proxy: `0.0.0.0:3080` (proxy port) → `127.0.0.1:3079`, providing LAN access + WebSocket forwarding.

> Why proxy instead of exposing DSH directly:
> - DSH forbids `--host 0.0.0.0` (security restriction), so it can only listen on the loopback address;
> - Pages loaded over a LAN IP are in a browser **non-secure context**, where the `crypto.randomUUID` used by the DSH frontend is unavailable.
>   The proxy injects a polyfill to work around it (otherwise the realtime channel/WS stays pending forever);
> - The proxy also provides **HTTP Basic Auth**. DSH ships a terminal (node-pty), so an
>   unauthenticated public port is effectively an exposed shell. Auth is therefore
>   **enforced by default**: when `PROXY_PASSWORD` is unset, `entrypoint.sh` generates a
>   random password and prints it to the container log
>   (see [Basic Auth](#basic-auth-enabled-by-default)).

## Directory Structure

```
deepseek-harness/
├── Dockerfile            # node:24-slim + install DSH + proxy (supports DEV_TOOLS / DSH_VERSION build args; admin variant pre-installs the latest DSH)
├── docker-compose.yml    # compose deployment (pull or build the image, config via .env)
├── .env.example          # compose environment template (copy to .env and edit)
├── entrypoint.sh         # enforce auth → start DSH → log rotation daemon → wait until ready → start the proxy (admin variant runs the manager service instead)
├── proxy/
│   ├── index.js          # proxy (forwarding + polyfill injection + Origin alignment + Basic Auth + DSH liveness monitor + graceful shutdown)
│   ├── compression.js    # async "decompress → rewrite → recompress" pipeline for response bodies (gzip/deflate/br, with size caps)
│   ├── upstream-token.js # upstream launch-token harvesting (DSH 0.1.2+: 401 → exchange token for a session cookie)
│   └── package.json
├── manager/              # admin variant only: install/switch DSH versions from the page, configure npm registry, manage the DSH process
│   ├── index.js
│   ├── admin.html
│   └── package.json
└── README.md / README_EN.md
```

## Usage

```bash
# Enter the project directory
cd deepseek-harness

# Build the image (default slim runtime image, no dev tools)
docker build -t smanx/deepseek-harness .

# Run (defaults: proxy port 3080, data persisted to named volume dsh-data)
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness

# View logs
docker logs -f dsh-harness

# Stop / remove (volume data is kept)
docker stop dsh-harness
docker rm dsh-harness
```

> On first start, if `PROXY_PASSWORD` is unset, the log prints an auto-generated random access
> password (username defaults to `admin`) — check it with `docker logs dsh-harness`. To use a
> fixed password, pass `-e PROXY_PASSWORD=...` to `docker run`; see
> [Basic Auth](#basic-auth-enabled-by-default).

Building installs DSH via npm (~250MB of dependencies), so the first build is slower than usual.
On Linux, node-pty has no prebuilt binaries and is compiled from source (the Dockerfile uses a
multi-stage build with python3/make/g++ installed; the runtime image does not keep the build tools).

## docker compose

The project ships a [docker-compose.yml](docker-compose.yml) and an [.env.example](.env.example);
compose is the recommended way to deploy (config lives in `.env`, upgrades/recreation are easier):

```bash
# 1. Prepare config (optional: set a fixed password, change ports)
cp .env.example .env
# Edit .env: leaving PROXY_PASSWORD empty = a random password is generated on each start

# 2. Start (pulls the image)
docker compose up -d

# 3. View logs / random password / health status
docker compose logs -f      # Ctrl+C to exit
docker compose ps           # STATUS should show Up (healthy)
```

Common operations:

```bash
docker compose restart                          # restart
docker compose down                             # stop & remove the container (dsh-data volume kept)
docker compose pull && docker compose up -d     # upgrade the image
docker compose exec dsh-harness bash            # shell into the container (devtools variants only)
```

Build from source (instead of pulling):

```bash
# DSH_VERSION / DEV_TOOLS in .env control the build args
docker compose build
docker compose up -d
```

> `.env` contains plaintext credentials and is excluded via `.gitignore` / `.dockerignore` —
> never commit it. The compose `ports` mapping is `${HOST_PORT}:${PROXY_PORT}`; changing
> `PROXY_PORT` in `.env` keeps `HOST_PORT` aligned automatically, no need to edit the compose file.

## Differences Between the Tags

The default runtime image is slim and does not keep build tools, suitable for production. If you
need to develop/debug inside the container, build with `--build-arg DEV_TOOLS=<tag-prefix>`.
Which tools each prefix installs is defined in the `.build-variants` file at the project root
(each line `<tag-prefix>|<apt packages>|<npm global packages>`; column 2 goes to apt-get install,
column 3 to npm install -g, and can be empty). Edit that file to add/remove tools dynamically
without touching the Dockerfile. Each tag also ships a matching **version tag** (the version
matches the `@deepseek-ai/dsh` version actually installed at build time, currently `<version>`):

| Tag (latest) | Version tag | Purpose | Included tools |
|---|---|---|---|
| `smanx/deepseek-harness:latest` | `smanx/deepseek-harness:<version>` | Original slim image, production-ready | No dev tools |
| `smanx/deepseek-harness:devtools-min-latest` | `smanx/deepseek-harness:devtools-min-<version>` | Minimal tools for common debugging | git, curl, wget, nano, jq, procps, ca-certificates, unzip; npm globals: pnpm; uv |
| `smanx/deepseek-harness:devtools-latest` | `smanx/deepseek-harness:devtools-<version>` | Full tools for developing/compiling inside the container | everything in Minimal + vim, openssh-client, zip, htop, tmux, tree, openssl, python3, build-essential (make/g++), bash-completion; npm globals: pnpm; uv |
| `smanx/deepseek-harness:test-latest` | `smanx/deepseek-harness:test-<version>` | Test tag: full tools + auto-installs DSH plugins | same as Full Tools (pnpm, uv); additionally runs `dsh plugin --profile web add github:smanx/dsh-conversation-indicator#main` after DSH install |
| `smanx/deepseek-harness:admin-latest` | `smanx/deepseek-harness:admin-<version>` | Admin variant: **latest DSH pre-installed**, works out of the box; admin page to pick/install/switch versions | same as Full Tools (pnpm, uv) + manager service; keeps python3/build-essential to compile node-pty at runtime |

```bash
# Minimal tools (DEV_TOOLS matches the first column of .build-variants)
docker build -t smanx/deepseek-harness:devtools-min-<version> --build-arg DEV_TOOLS=devtools-min .

# Full tools
docker build -t smanx/deepseek-harness:devtools-<version> --build-arg DEV_TOOLS=devtools .
```

> GitHub Actions (`docker-build/.github/workflows/projects.yml`) reads the `.build-variants`
> manifest in each project directory and automatically builds and pushes all tags (Docker Hub
> and GHCR, one set each).

> The full-tools version includes `python3` + `build-essential`, so native modules (e.g. node-pty)
> can be compiled directly inside the container — it effectively also brings the build tools of the
> `dsh-builder` stage into the runtime image. The version follows the actual `@deepseek-ai/dsh`
> release; e.g. after upgrading to `0.2.0`, change the tags to `devtools-0.2.0` / `devtools-min-0.2.0`.

> The tooled variants (devtools / devtools-min / test) bundle **pnpm** (installed globally via npm).
> DSH's `dsh plugin` command relies on pnpm to manage plugins, and the community plugin market
> [dsh-market](https://github.com/dsh-market/dsh-market) (`dsh plugin --profile web add dshmarket`)
> needs it too. The slim `latest` does not bundle it — on first plugin use, dsh-market detects the
> missing pnpm and offers one-click automatic installation.
>
> The tooled variants also bundle **uv** (Python package manager, static binary, no system Python
> required). Many community MCP servers launch via `uvx` / `uv run` (commonly seen in DSH MCP
> client configs as `"command": "uvx"`); without uv those MCPs cannot run. uv downloads the Python
> interpreter on demand on first use.

### Admin Variant (latest DSH pre-installed)

The `admin` variant **pre-installs the latest DSH (@next)**. After the container starts, the manager
service detects and starts DSH automatically, so `/` serves the DSH UI directly; visiting `/__admin/`
opens the admin page, where you can:

- Browse the available versions of the npm package `@deepseek-ai/dsh` (dist-tags like `latest`/`next`
  plus the full version list), select and **install / switch** DSH versions, with live install progress;
- Manually configure the **npm registry (NPM_CONFIG_REGISTRY)**: the input field **auto-fills the
  default value** (env `NPM_CONFIG_REGISTRY` or the official registry `https://registry.npmjs.org/`)
  and the **last-saved value**, and shows the effective value; you can restore the default or clear
  it with one click. Priority: **page config > env `NPM_CONFIG_REGISTRY` > default**;
- **Restart** DSH with one click. After install, DSH starts automatically and a floating "⚙ Admin"
  button stays in the corner of the DSH page so you can always get back to the admin page.

Run command (two named volumes: `dsh-data` for DSH config/sessions, `dsh-install` for the installed
DSH files and config state, so upgrades/registry survive container recreation):

```bash
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v dsh-install:/opt/dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:admin-latest
```

> The admin variant keeps `python3` + `build-essential`: node-pty has no Linux prebuilt binaries,
> and installing other DSH versions from the page requires compiling the native module from source
> inside the container, so this image is a bit larger than the slim one. Since the admin variant
> pre-installs the latest DSH, its version tag is the DSH version (e.g. `admin-0.1.1`).

## Port Configuration

The source port (DSH) and proxy port (external) can both be configured via environment variables:

| Environment variable | Meaning | Default |
|---|---|---|
| `DSH_PORT` | Source port: where DSH listens (container `127.0.0.1`) | `3079` |
| `PROXY_PORT` | Proxy port: where the proxy listens (LAN entry point) | `3080` |

> The two must differ (one port can only be bound by one process).

Auth and stability-related environment variables:

| Environment variable | Meaning | Default |
|---|---|---|
| `PROXY_USERNAME` | Basic Auth username | `admin` |
| `PROXY_PASSWORD` | Basic Auth password; **a random password is generated at startup if unset** | (random) |
| `ALLOW_REMOTE_SETTINGS` | Whether non-loopback access may use DSH settings features (rewrites `isLoopbackHostname` to always-true). Set `false` to disable | `true` |
| `DSH_READY_TIMEOUT` | Seconds to wait for DSH readiness; raise it when the first plugin install / npm registry is slow, to avoid a crash loop with the restart policy | `120` |
| `DSH_LOG_MAX_KB` | Rotate `.dsh-web.log` when its actual disk usage exceeds this (KiB) | `8192` |
| `DSH_LOG_KEEP_KB` | Log tail size kept after rotation (KiB) | `1024` |
| `DSH_LIVENESS_INTERVAL` | Interval (ms) at which the proxy probes the DSH process; if DSH dies the container exits so the restart policy rebuilds it | `10000` |
| `PROXY_MAX_BODY_BYTES` | Per-response body buffering cap (bytes); beyond it the proxy stops rewriting and streams the body through untouched | `33554432` (32 MiB) |
| `PROXY_MAX_DECOMPRESSED_BYTES` | Cap on decompressed size (decompression-bomb guard) | `67108864` (64 MiB) |
| `DSH_MAX_INDEX_BYTES` | Cap on bytes read from the root index page | `4194304` (4 MiB) |

The admin variant also supports these environment variables:

| Environment variable | Meaning | Default |
|---|---|---|
| `NPM_CONFIG_REGISTRY` | Default npm registry on the admin page (used when not configured on the page; lower priority than the page config) | `https://registry.npmjs.org/` |
| `DSH_INSTALL_DIR` | DSH install directory in the admin variant (installed DSH and state files live here; mount a named volume) | `/opt/dsh` |

For example, change to "DSH internal 3082, proxy external 3080":

```bash
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -e DSH_PORT=3082 \
  --restart unless-stopped \
  smanx/deepseek-harness
```

## Access

- Local: `http://127.0.0.1:3080/`
- LAN: `http://<server-LAN-IP>:3080/` (e.g. `http://192.168.1.100:3080/`)
- The WebSocket realtime channels are forwarded automatically by the proxy (`/api/events.mux`, `/api/events.host`)

## Basic Auth (enabled by default)

DSH ships a terminal (node-pty), so an unauthenticated public port is effectively an exposed
shell. Auth is therefore **enforced by default**:

- **`PROXY_PASSWORD` unset**: `entrypoint.sh` generates a random password for this run and prints
  it to the container log. Check it with `docker logs dsh-harness`:

  ```
  ======================================================================
  [auth] PROXY_PASSWORD is not set; generated a random password for this run:
  [auth]   username: admin
  [auth]   password: <random string>
  [auth] Set PROXY_USERNAME / PROXY_PASSWORD explicitly for fixed credentials.
  ======================================================================
  ```

  > The random password changes on every container restart. Set the variables explicitly (below)
  > for stable credentials.

- **Explicit credentials** (recommended; survives restarts):

  ```bash
  docker run -d \
    --name dsh-harness \
    -p 3080:3080 \
    -v dsh-data:/home/node/.dsh \
    -e PROXY_USERNAME=yourname \
    -e PROXY_PASSWORD=yourpass \
    --restart unless-stopped \
    smanx/deepseek-harness
  ```

- Auth applies to both HTTP and WebSocket; unauthenticated requests get `401` + `WWW-Authenticate`
  and the browser shows a credential prompt;
- The public static resources `/manifest.webmanifest`, `/favicon.svg`, `/favicon.ico` are exempt
  from auth (they only contain non-sensitive data like the app name/icon). Browsers fetching
  `<link rel="manifest">` do not send Basic Auth credentials; if auth were enforced on these paths,
  the console would keep reporting `/manifest.webmanifest` 401.

> **Security note**: Basic Auth credentials are passed via environment variables and are visible
> through `docker inspect` and `/proc/<pid>/environ`. For stricter requirements, put the container
> behind a reverse proxy (e.g. Traefik/Caddy) that handles auth and TLS centrally, and let the
> container listen on the internal network only.

## Data Persistence

DSH session/config data is stored in the named volume `dsh-data` (container path `/home/node/.dsh`).
The volume survives `docker stop/start` and container removal; to wipe it completely, stop the
container first, then `docker volume rm dsh-data`.

> **The container runs as the `node` user (uid 1000), not root.** DSH resolves its data directory,
> plugins and config from `$HOME=/home/node`, which is why the volume is mounted at
> `/home/node/.dsh` (earlier versions used `/root/.dsh`).
>
> **Upgrading from an old version (`/root/.dsh`)**: files in the old volume are owned by root, so
> mounting them into the new image makes DSH fail to write. Fix ownership before recreating the
> container:
>
> ```bash
> docker run --rm -v dsh-data:/data alpine chown -R 1000:1000 /data
> ```
>
> If the old deployment still mounts the volume at `/root/.dsh`, change it to `/home/node/.dsh`;
> otherwise data lands in the unmounted container layer and is lost on recreation.

## Notes

- DSH officially forbids `--host 0.0.0.0`, so DSH stays on the loopback interface inside the
  container; the proxy handles external access;
- If DSH fails to start under `node:24-slim` due to missing system libraries, change the base image
  of both Dockerfile stages to `node:24` and rebuild;
- The proxy logic is identical to the standalone [dsh-proxy](https://github.com/smanx/dsh-proxy)
  (polyfill injection, Origin alignment, Basic Auth, WS forwarding).
- The DSH frontend uses `connection.isLoopback` to decide whether settings-type features are
  available (plugin config cards, settings file buttons, etc.), and only counts `localhost`/
  `127.x.x.x` etc. loopback hostnames as loopback. When accessed via a hostname/LAN IP these
  features are hidden (e.g. the "Plugin Config" page drops from 3 cards to an empty list). The proxy
  rewrites the `isLoopbackHostname(pageLocation.hostname)` check to always-true when forwarding JS,
  so LAN access can use settings features as well. Because this rewrite punches through DSH's own
  loopback security boundary, it is gated by the `ALLOW_REMOTE_SETTINGS` switch (default `true`;
  set `false` to disable the rewrite and keep only the basic features).

## Stability & Operations

The image is hardened for stability; most behaviours are tunable via environment variables
(see [Port Configuration](#port-configuration)):

- **Process model**: `tini` runs as PID 1, forwarding signals and reaping zombies; the DSH process,
  the `tail -f` forwarder and the log-rotation subshell spawned by `entrypoint.sh` leave no zombies
  behind when they exit.
- **DSH liveness monitor**: if upstream DSH crashes, the proxy keeps answering (502 for every
  request) while the container STATUS stays `Up`, so the `restart` policy never fires. The proxy
  probes the DSH process every `DSH_LIVENESS_INTERVAL`; once the process is gone it exits the
  container and lets `--restart` rebuild it, avoiding a permanent-502 state.
- **Graceful shutdown**: on SIGTERM/SIGINT the proxy stops accepting new connections, closes
  existing ones, terminates DSH, then exits (forced after a 10s timeout).
- **Crash safety**: the root `serveIndex` promise has a `.catch` (Node 24 terminates the process on
  unhandled rejections by default); `uncaughtException` / `unhandledRejection` / `clientError` /
  listen-error handlers log and exit so the container is rebuilt instead of sitting in a
  "port listening but not forwarding" half-dead state.
- **Health check**: the image ships a built-in `HEALTHCHECK` (probes the proxy port; `start-period`
  of 130s covers first startup). The STATUS column of `docker ps` shows `(healthy)` / `(unhealthy)`.
- **Log rotation**: a background daemon rotates `.dsh-web.log` by actual disk usage (`du`, to avoid
  sparse-hole miscounts) using copy-truncate so the inode stays the same — this keeps long-running
  containers from filling the writable layer.
- **Response-body protection**: decompression/recompression is async (never blocks the event loop)
  and both the buffered size and the decompressed size are capped; beyond the caps the proxy stops
  rewriting and streams the body through untouched, covering both large files and decompression bombs.

> **Reproducible builds**: the image installs `@deepseek-ai/dsh@next` by default (tracking upstream
> pre-releases). For production, pin the version:
> `docker build --build-arg DSH_VERSION=0.1.2 -t smanx/deepseek-harness .`
