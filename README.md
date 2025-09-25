# Two Projects in One Image (Supervisor)

Single image that runs two independent services, managed by Supervisord. At build time it can clone two external repositories and install their dependencies; at runtime it manages each service separately (start/stop/restart/status/logs) with strict user and tmp isolation.

Default ports:
- Service A: 8080
- Service B: 9090

## Files
- `Dockerfile`: clones both repos, installs deps, prepares runtime
- `config/supervisord-main.conf`: main supervisor cfg (PID + socket in `/tmp`, includes conf.d)
- `supervisord.conf`: program definitions for `project1` and `project2`
- `scripts/entrypoint.sh`: preps dirs/ownership, sane defaults, launches supervisor
- `healthcheck.sh`: checks that both services respond on their ports
- `.github/workflows/build.yml`: CI to build and push image to GHCR

## Build

Provide your repositories and refs via build args (recommended):

```sh
docker build -t two-services . \
  --build-arg SERVICE_A_REPO=https://github.com/<owner>/project-1.git \
  --build-arg SERVICE_A_REF=main \
  --build-arg SERVICE_B_REPO=https://github.com/<owner>/project-2.git \
  --build-arg SERVICE_B_REF=main
```

Optional build args:
- `SERVICE_A_SUBDIR`, `SERVICE_B_SUBDIR`: app lives in a subdirectory
- `SERVICE_A_INSTALL_CMD`, `SERVICE_B_INSTALL_CMD`: custom install steps to mirror each repo’s Dockerfile

Dependency install autodetect:
- Service A (Python): `requirements.txt` → `pip install -r`, or `pyproject.toml`/`setup.py` → `pip install .`
- Service B (Node): prefers `pnpm-lock.yaml`, then `yarn.lock`, then `npm` (`npm ci` fallback to `npm install`)

Tip: If you don’t pass repos at build time, the container still boots and serves static directories by default.

Runtime fetch (no rebuild):
- You can ask the container to fetch source at start using tarballs:

```sh
docker run -d --name two \
  -e SERVICE_A_REPO=https://github.com/<owner>/project-1.git \
  -e SERVICE_A_REF=main \
  -e SERVICE_B_REPO=https://github.com/<owner>/project-2.git \
  -e SERVICE_B_REF=main \
  -p 8080:8080 -p 9090:9090 \
  ghcr.io/<owner>/supervisor-image-combination:latest
```

At runtime the entrypoint downloads GitHub tarballs (via `codeload.github.com`) into `/opt/services/service-a` and `/opt/services/service-b` if those directories are empty.

## Run

```sh
docker run -d --name two-services \
  -p 8080:8080 -p 9090:9090 \
  two-services
```

Supervisor program names: `project1` and `project2`.

```sh
# Status
docker exec -it two-services supervisorctl status

# Restart one service
docker exec -it two-services supervisorctl restart project1

# Tail logs
docker exec -it two-services supervisorctl tail -f project2
```

## Overrides

- Ports: `SERVICE_A_PORT` (default 8080), `SERVICE_B_PORT` (default 9090). Must differ.
- Commands (see `supervisord.conf`):
  - `SERVICE_A_CMD` (default: `python3 -m http.server ${SERVICE_A_PORT} --directory /opt/services/service-a --bind 0.0.0.0` if no Python app detected; otherwise assumes FastAPI `uvicorn app:app`)
  - `SERVICE_B_CMD` (default: `python3 -m http.server ${SERVICE_B_PORT} --directory /opt/services/service-b --bind 0.0.0.0` if no Node app detected; otherwise `PORT=${SERVICE_B_PORT} node server.js`)

Example with custom A command:

```sh
docker run -d --name two-services \
  -e SERVICE_A_CMD='python3 -m http.server ${SERVICE_A_PORT:-8080} --bind 0.0.0.0' \
  -p 8080:8080 -p 9090:9090 two-services
```

## Runtime Hardening (optional but recommended)

Add common container hardening flags. If your apps need to write, mount tmpfs for writable paths.

```sh
docker run -d --name two-services \
  --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 512 --memory 1g --cpus 1.0 \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /home/svc_a:rw,nosuid,size=32m \
  --tmpfs /home/svc_b:rw,nosuid,size=32m \
  -p 8080:8080 -p 9090:9090 \
  two-services
```

Notes:
- If `noexec` on `/tmp` causes issues for your runtime, drop `noexec` from that mount.
- Supervisor starts both services as unprivileged users (`svc_a`, `svc_b`) and logs to stdout/stderr.
- Healthcheck pings both ports via `healthcheck.sh`. Adjust paths if your services differ.

## GitHub Actions (GHCR)

This repo includes a workflow to build and push the image to GHCR. It supports manual dispatch inputs for both repos and refs; on tags (`vX.Y.Z`) it also tags the image with `X.Y.Z` and `X.Y` and creates a GitHub Release.

Steps:
- Add `GHCR_PAT` secret (write:packages) or rely on `GITHUB_TOKEN`.
- Run “Build and Push Image” workflow and provide:
  - `service_a_repo`, `service_a_ref` (e.g., https://github.com/<owner>/project-1.git, main)
  - `service_b_repo`, `service_b_ref` (e.g., https://github.com/<owner>/project-2.git, main)

Pull and run:
```sh
docker pull ghcr.io/<owner>/supervisor-image-combination:latest
docker run -d --name two -p 8080:8080 -p 9090:9090 ghcr.io/<owner>/supervisor-image-combination:latest
```

## Supervisor Details

- Socket: `unix:///tmp/supervisor.sock`
- PID file: `/tmp/supervisord.pid`
- Configs: main at `/etc/supervisor/supervisord.conf`; includes `/etc/supervisor/conf.d/*.conf`
- Control inside the container:
  - `supervisorctl status | start project1 | stop project2 | restart project1`

## Mounting Local Content (no rebuild)

You can mount content into service directories; default static servers will serve it:

```sh
docker run -d --name two \
  -v $(pwd)/site-a:/opt/services/service-a \
  -v $(pwd)/site-b:/opt/services/service-b \
  -p 8080:8080 -p 9090:9090 two-services
```

## Troubleshooting

- Port is already allocated: pick free host ports (e.g., `-p 18080:8080 -p 19090:9090`) or stop the conflicting listener.
- supervisorctl “no such file”: ensure the container is running; the socket path is `/tmp/supervisor.sock` (created by supervisord). Inside: `ls -l /tmp/supervisor.sock`.
- Services crash on chdir with EACCES: the entrypoint ensures ownership/permissions; if you mount volumes, make sure they are readable by `svc_a`/`svc_b`.

## Security Notes

- Each service runs as its own user with 750 perms on its code tree and isolated tmp/cache directories.
- The container defaults are compatible with read-only rootfs; use `--tmpfs` mounts for writable paths.
- Consider network policies (firewall) to only expose required ports.

## Interactive Multi‑Project Deployer

Run inside a started container to deploy N services dynamically:

```sh
docker exec -it <container_name> deploy
```

It will prompt for:
- how many projects to deploy (1–20)
- each project’s GitHub URL and ref (branch/tag/sha)
- a service name (used for UNIX user and Supervisor program)
- a port for that service
- an optional custom start command (defaults are auto‑detected)

What it does per service:
- Creates a dedicated UNIX user (`svc_<name>`) and private home
- Downloads the repo via GitHub tarball (no git necessary)
- Installs dependencies when `requirements.txt`/`pyproject.toml` or `package.json` exist
- Confines temp/cache to `/tmp/<name>-tmp` and `/tmp/<name>-cache`
- Writes `/etc/supervisor/conf.d/program-<name>.conf` and reloads Supervisor

You can then manage them independently with `supervisorctl` (status/start/stop/restart/tail).

## Non‑Interactive Provisioning (ENV)

Provision many services at boot or later without prompts. Two formats are supported:

1) Compact `SERVICES` list (semicolon separates services; `|` separates fields):

```sh
# repo|port|ref|name|user|cmd (ref/name/user/cmd are optional)
docker run -d --name two \
  -e SERVICES='https://github.com/<owner>/project-1.git|8080|main|alpha|svc_alpha|;https://github.com/<owner>/project-2.git|9090|main|beta|svc_beta|' \
  -p 8080:8080 -p 9090:9090 \
  ghcr.io/<owner>/supervisor-image-combination:latest
```

2) Indexed variables (`SERVICES_COUNT` + `SVC_<i>_*`):

```sh
docker run -d --name two \
  -e SERVICES_COUNT=2 \
  -e SVC_1_REPO=https://github.com/<owner>/project-1.git -e SVC_1_PORT=8080 -e SVC_1_REF=main -e SVC_1_NAME=alpha -e SVC_1_USER=svc_alpha \
  -e SVC_2_REPO=https://github.com/<owner>/project-2.git -e SVC_2_PORT=9090 -e SVC_2_REF=main -e SVC_2_NAME=beta -e SVC_2_USER=svc_beta \
  -p 8080:8080 -p 9090:9090 \
  ghcr.io/<owner>/supervisor-image-combination:latest
```

At boot the entrypoint pre‑provisions services (fetches sources, installs deps, writes program configs), then Supervisor starts and adopts them. You can also apply the spec later to a running container:

```sh
docker exec -it two deploy-from-env
```

### Default CI behavior

- On push to `main`, the GitHub Actions workflow builds the image with defaults:
  - `SERVICE_A_REPO=https://github.com/<owner>/project-1.git`
  - `SERVICE_B_REPO=https://github.com/<owner>/project-2.git`
  - refs default to `main`
- On `workflow_dispatch`, you can override all build args from the UI.
- On tags `vX.Y.Z`, images are additionally tagged with `X.Y.Z` and `X.Y` and a GitHub Release is created.
