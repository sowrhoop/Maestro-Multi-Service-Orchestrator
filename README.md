# Two Services in One Image (Supervisor)

This repository contains a single Dockerfile plus a minimal Supervisor setup to clone two external projects (project-1 and project-2), install their dependencies, and run both services inside one container.

Default ports:
- Service A: 8080
- Service B: 9090

## Files
- `Dockerfile`: clones both repos, installs deps, prepares runtime
- `supervisord.conf`: starts both services under Supervisor
- `scripts/entrypoint.sh`: validates ports and launches Supervisor
- `healthcheck.sh`: checks that both services respond on their ports
- `.dockerignore`: reduces build context size

## Build

Provide your repositories and refs via build args:

```sh
docker build -t two-services . \
  --build-arg SERVICE_A_REPO=https://github.com/<owner>/project-1 \
  --build-arg SERVICE_A_REF=main \
  --build-arg SERVICE_B_REPO=https://github.com/<owner>/project-2 \
  --build-arg SERVICE_B_REF=main
```

Optional build args:
- `SERVICE_A_SUBDIR` / `SERVICE_B_SUBDIR`: use if the app lives in a subdirectory
- `SERVICE_A_INSTALL_CMD` / `SERVICE_B_INSTALL_CMD`: custom install commands to mirror each repo's Dockerfile

Dependency install autodetect:
- Service A (Python): `requirements.txt` -> `pip install -r`, or `pyproject.toml`/`setup.py` -> `pip install .`
- Service B (Node): prefers `pnpm-lock.yaml`, then `yarn.lock`, then `npm` (`npm ci` fallback to `npm install`)

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
  - `SERVICE_A_CMD` (default assumes FastAPI: `uvicorn app:app --host 0.0.0.0 --port ${SERVICE_A_PORT}`)
  - `SERVICE_B_CMD` (default assumes Node: `PORT=${SERVICE_B_PORT} node server.js`)

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
