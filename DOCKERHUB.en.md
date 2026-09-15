# deepseek-harness (Docker Image)

Image (default): **`smanx/deepseek-harness:latest`** (Docker Hub)
Image (backup): **`ghcr.io/smanx/deepseek-harness:latest`** (GitHub Container Registry, GHCR; all tags are mirrored there)
Docker Hub project page: https://hub.docker.com/r/smanx/deepseek-harness
Github project page：https://github.com/smanx/deepseek-harness-docker

An out-of-the-box **DeepSeek Harness (DSH)** Docker image with a built-in Node reverse proxy. It solves the issue that DSH officially forbids `--host 0.0.0.0` (loopback-only listening) and makes DSH safely accessible over your LAN.

## Online Demo

- Demo URL: https://dsh.smanx.xx.kg
- Username / Password: `admin` / `admin`

> ⚠️ **Note:** This is a **public address**. If you fill in your own API key (e.g. DeepSeek), please be **very careful** — your key may be exposed.

## About the Project

- **DSH**: Installs the official npm package `@deepseek-ai/dsh` ([deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)) inside the container, listening on `127.0.0.1:3079` (source port) by default;
- **Node proxy**: `0.0.0.0:3080` (proxy port) → `127.0.0.1:3079`, providing HTTP + WebSocket forwarding to the outside;
- **Why a proxy is needed**:
  - DSH officially forbids `--host 0.0.0.0` (security restriction) and can only listen on the loopback address;
  - Pages loaded over a LAN IP are in a browser **non-secure context**, where the `crypto.randomUUID` used by the DSH frontend is unavailable. The proxy automatically injects a `getRandomValues`-based polyfill into served HTML; without it the realtime channel (WS) stays pending forever;
  - The proxy also provides **HTTP Basic Auth**. DSH ships a terminal (node-pty), so an unauthenticated public port is effectively an exposed shell — auth is therefore **enforced by default**: when `PROXY_PASSWORD` is unset, the startup script generates a random password and prints it to the container log (`docker logs`).

## Quick Start (pull & run)

```bash
# 1. Pull the image (default: Docker Hub)
docker pull smanx/deepseek-harness:latest

# 2. Run (defaults: proxy port 3080, data persisted to named volume dsh-data)
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:latest

# 3. Access
#    Local machine: http://127.0.0.1:3080/
#    LAN:           http://<server-LAN-IP>:3080/
```

> **A password is required on first start**: when `PROXY_PASSWORD` is unset, a random password is
> generated automatically — check it with `docker logs dsh-harness` (username defaults to `admin`).
> To use a fixed password, add `-e PROXY_PASSWORD=yourpass`; see
> [Enabling Basic Auth](#enabling-basic-auth) below.

The WebSocket realtime channels (`/api/events.mux`, `/api/events.host`) are forwarded automatically by the proxy — no extra configuration needed.

### Using docker compose (recommended)

Config lives in `.env`, making upgrades/recreation easier. The repo ships `docker-compose.yml` and `.env.example`:

```bash
# 1. Clone the repo (or download docker-compose.yml + .env.example separately)
git clone https://github.com/smanx/deepseek-harness-docker.git && cd deepseek-harness-docker

# 2. Prepare config (leaving PROXY_PASSWORD empty = a random password is generated on each start)
cp .env.example .env

# 3. Start + view logs/health
docker compose up -d
docker compose logs -f     # includes the random password, Ctrl+C to exit
docker compose ps          # STATUS should show Up (healthy)
```

Common operations:

```bash
docker compose restart                          # restart
docker compose down                             # stop & remove the container (dsh-data volume kept)
docker compose pull && docker compose up -d     # upgrade the image
```

> `.env` contains plaintext credentials and is excluded via `.gitignore` / `.dockerignore` — never commit it.

### Differences between the tags

| Tag | Purpose | Included tools |
|---|---|---|
| `latest` | Slim runtime image | None (only Node runtime + DSH + reverse proxy) |
| `devtools-min-latest` | Minimal tools for common debugging | git, curl, wget, nano, jq, procps, ca-certificates, unzip; npm globals: pnpm; uv |
| `devtools-latest` | Full tools for developing/compiling inside the container | everything in Minimal + vim, openssh-client, zip, htop, tmux, tree, openssl, python3, build-essential (make/g++), bash-completion; npm globals: pnpm; uv |
| `admin-latest` | Admin variant: **latest DSH pre-installed**, works out of the box; admin page to pick/install/switch versions | same as Full Tools (pnpm, uv) + manager service; keeps python3/build-essential to compile node-pty at runtime |

> Each tag also has a matching **versioned tag**: `latest` ↔ `<version>`, `devtools-latest` ↔ `devtools-<version>`, `devtools-min-latest` ↔ `devtools-min-<version>`, `admin-latest` ↔ `admin-<version>` (admin pre-installs the latest DSH, so its version tag is the DSH version).

**A simple example:**

```bash
# Scenario 1: just run DSH in the browser with no debugging → use the slim `latest`
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:latest

# Scenario 2: you need to get inside the container to troubleshoot
# (view logs, process JSON with jq, fetch things with wget) → use devtools-min-latest
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:devtools-min-latest

# Scenario 3: develop/compile inside the container or do heavier ops
# (vim, python3, make, etc.) → use devtools-latest
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:devtools-latest
```

The run command is identical across all three tags — only the image name (tag) changes. The tooled variants are a bit larger than the slim image, so pick what fits.

The tooled variants (`devtools` / `devtools-min` / `test`) ship with **pnpm** (installed via npm globally). DSH's `dsh plugin` command relies on pnpm to manage plugins, and the community plugin market [dsh-market](https://github.com/dsh-market/dsh-market) (`dsh plugin --profile web add dshmarket`) needs it too. The slim `latest` does not bundle it — on first plugin use, dsh-market detects the missing pnpm and offers one-click automatic setup.

They also ship **uv** (Python package manager, static binary, no system Python required). Many community MCP servers launch via `uvx` / `uv run` (commonly seen in DSH MCP client configs as `"command": "uvx"`) — without uv those MCPs cannot run.

#### Admin variant (latest DSH pre-installed)

The `admin` variant **pre-installs the latest DSH (@next)**. After the container starts, the manager service detects and starts DSH automatically, so `/` serves the DSH UI directly; visiting `/__admin/` opens the admin page, where you can:

- Browse available versions of `@deepseek-ai/dsh` (dist-tags like `latest`/`next` plus the full list) and **install / switch** versions, with live install logs;
- Configure the **npm registry (NPM_CONFIG_REGISTRY)** manually: the input field **auto-fills the default** (env `NPM_CONFIG_REGISTRY` or the official registry) and the **last-saved value**, and shows the effective value; you can restore the default or clear it with one click. Priority: **page config > env `NPM_CONFIG_REGISTRY` > default**;
- **Restart** DSH with one click. After install it starts automatically, and a floating "⚙ Admin" button stays in the corner of the DSH page so you can always get back to the admin page.

```bash
# Admin variant: use two named volumes (dsh-data for DSH config/sessions, dsh-install for the
# installed DSH files and config state, so upgrades/registry survive container recreation)
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  -v dsh-install:/opt/dsh \
  --restart unless-stopped \
  smanx/deepseek-harness:admin-latest
```

> The admin variant keeps `python3` + `build-essential` (node-pty has no Linux prebuilds, so installing other DSH versions from the page needs to compile the native module from source in-container), making the image a bit larger than the slim one.

## Quick Start (pull & run)

### Backup Image (GHCR)

If pulling from Docker Hub is restricted (e.g. network issues), you can use the backup image (GitHub Container Registry; tags are identical to Docker Hub):

```bash
# Pull the image from GHCR
docker pull ghcr.io/smanx/deepseek-harness:latest

# Same run command as the default image — just swap the image name
docker run -d \
  --name dsh-harness \
  -p 3080:3080 \
  -v dsh-data:/home/node/.dsh \
  --restart unless-stopped \
  ghcr.io/smanx/deepseek-harness:latest
```

> The two images are identical in configuration and usage — only the registry differs, so they are interchangeable.

## Configuration (Environment Variables)

| Variable | Meaning | Default |
|---|---|---|
| `DSH_PORT` | Source port: where DSH listens inside the container (`127.0.0.1`) | `3079` |
| `PROXY_PORT` | Proxy port: where the proxy listens (LAN entry point) | `3080` |
| `PROXY_USERNAME` | Basic Auth username | `admin` |
| `PROXY_PASSWORD` | Basic Auth password; **a random password is generated at startup and printed to the log if unset** | (random) |
| `ALLOW_REMOTE_SETTINGS` | Whether non-loopback access may use DSH settings features (rewrites `isLoopbackHostname` to always-true); set `false` to disable | `true` |
| `DSH_READY_TIMEOUT` | Seconds to wait for DSH readiness (raise it when the first plugin install / npm registry is slow) | `120` |
| `DSH_LOG_MAX_KB` / `DSH_LOG_KEEP_KB` | `.dsh-web.log` rotation trigger / tail size kept after rotation (KiB) | `8192` / `1024` |
| `DSH_LIVENESS_INTERVAL` | Interval (ms) at which the proxy probes the DSH process; if DSH dies the container exits so the restart policy rebuilds it | `10000` |
| `PROXY_MAX_BODY_BYTES` | Per-response body buffering cap (bytes); beyond it the proxy stops rewriting and streams the body through untouched | `33554432` (32 MiB) |
| `PROXY_MAX_DECOMPRESSED_BYTES` | Cap on decompressed size (decompression-bomb guard) | `67108864` (64 MiB) |
| `DSH_MAX_INDEX_BYTES` | Cap on bytes read from the root index page | `4194304` (4 MiB) |
| `NPM_CONFIG_REGISTRY` | Default npm registry on the admin page (lower priority than the page config) | `https://registry.npmjs.org/` |
| `DSH_INSTALL_DIR` | DSH install directory in the admin variant (installed DSH and config state live here; mount a named volume) | `/opt/dsh` |

> `DSH_PORT` and `PROXY_PORT` must differ (a port can only be bound by one process).
> If you change `PROXY_PORT`, remember to update the port mapping accordingly: `-p <host-port>:<new-proxy-port>`.

### Enabling Basic Auth

Auth is **enforced by default** (DSH ships a terminal — an unauthenticated public port is effectively an exposed shell):

- **`PROXY_PASSWORD` unset**: a random password for this run is generated at startup and printed to the log — check it with `docker logs dsh-harness` (username defaults to `admin`). The random password changes on every restart.
- **Explicit credentials** (recommended; survives restarts):

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

- Auth applies to both HTTP and WebSocket. Unauthenticated requests get `401` + `WWW-Authenticate`, and the browser shows a credential prompt;
- The public static resources `/manifest.webmanifest`, `/favicon.svg`, `/favicon.ico` are exempt from auth (they only contain non-sensitive data like the app name/icon). Browsers fetching `<link rel="manifest">` do not send Basic Auth credentials; enforcing auth there would make the console keep reporting `/manifest.webmanifest` 401.

> **Security note**: Basic Auth credentials are passed via environment variables and are visible through `docker inspect` and `/proc/<pid>/environ`. For stricter requirements, put the container behind a reverse proxy (e.g. Traefik/Caddy) that handles auth and TLS centrally, and let the container listen on the internal network only.

### Changing the proxy port

```bash
# e.g. expose the proxy on port 3088
docker run -d \
  --name dsh-harness \
  -p 3088:3088 \
  -v dsh-data:/home/node/.dsh \
  -e PROXY_PORT=3088 \
  --restart unless-stopped \
  smanx/deepseek-harness:latest
```

## Data Persistence

DSH session/configuration data lives in `/home/node/.dsh` inside the container; the commands above persist it via the named volume `dsh-data`:

- Data survives `docker stop/start` and container removal;
- To wipe it completely: `docker volume rm dsh-data` (stop the container first).

> **The container runs as the `node` user (uid 1000), not root.** The volume is mounted at `/home/node/.dsh` (earlier versions used `/root/.dsh`).
> **Upgrading from an old version**: files in the old volume are owned by root, so mounting them into the new image makes DSH fail to write. Fix ownership before recreating the container:
> `docker run --rm -v dsh-data:/data alpine chown -R 1000:1000 /data`;
> if the old deployment still mounts the volume at `/root/.dsh`, change it to `/home/node/.dsh`, otherwise data lands in the unmounted container layer and is lost on recreation.

## Stability & Operations

The image is hardened for stability (most behaviours are tunable via environment variables, see [Configuration](#configuration-environment-variables)):

- **Process model**: `tini` runs as PID 1, forwarding signals and reaping zombies;
- **DSH liveness monitor**: if upstream DSH crashes, the proxy exits the container so the `--restart` policy rebuilds it, avoiding a permanent-502 state;
- **Graceful shutdown**: on SIGTERM/SIGINT the proxy stops accepting new connections, closes existing ones, terminates DSH, then exits;
- **Health check**: a built-in `HEALTHCHECK` makes the STATUS column of `docker ps` show `(healthy)` / `(unhealthy)`;
- **Log rotation**: `.dsh-web.log` is rotated by actual disk usage (copy-truncate), preventing the writable layer from filling up;
- **Response-body protection**: decompression/recompression is async with size caps, covering both large files and decompression bombs.

> **Reproducible builds**: the image installs `@deepseek-ai/dsh@next` by default. For production, pin the version:
> `docker build --build-arg DSH_VERSION=0.1.2 -t smanx/deepseek-harness .`

## Stop / Restart / Remove

```bash
docker stop dsh-harness     # stop
docker start dsh-harness    # start again
docker logs -f dsh-harness  # view logs
docker rm -f dsh-harness    # remove the container (volume data is kept)
```

## Contact & Feedback

- Discussion & bug feedback: https://github.com/deepseek-ai/deepseek-harness/discussions/1762
