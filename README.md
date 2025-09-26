# Maestro Multi-Project Orchestrator

Maestro is a production-grade container blueprint for running two or more applications under Supervisord with strict process and filesystem isolation. It replaces the old "Supervisor-Image-Combination" name and puts a polished brand on the same battle-tested runtime so you can ship polyglot projects from a single image without cutting corners on security or operability.

## Core Capabilities
- Clone and install two primary projects at build time with optional subdirectory and custom install hooks.
- Auto-bootstrap the legacy A/B project slots only when code or explicit commands are provided (configurable via `DEFAULT_SERVICES_MODE`).
- Provision any number of additional projects at runtime using interactive or environment-driven workflows; each project receives its own UNIX user, temp/cache directories, and Supervisor program.
- Hardened entrypoint that validates ports, ensures ownership/permissions, and generates Supervisor configs on the fly.
- Healthcheck script that adapts to the projects you enable and falls back to verifying the Supervisor control socket.

## Layout
- `Dockerfile`: clones repositories, installs dependencies, and lays down runtime assets.
- `config/supervisord-main.conf`: Supervisor root configuration (PID and socket in `/tmp`, includes `conf.d`).
- `scripts/entrypoint.sh`: prepares isolation, writes Supervisor program files, honours default-project policy, and launches Supervisor foreground.
- `scripts/lib-deploy.sh`: shared helpers for fetching tarballs, detecting default commands, and writing program stanzas.
- `scripts/deploy-interactive.sh`: prompts inside the container to add projects dynamically.
- `scripts/deploy-from-env.sh`: idempotent provisioning from environment variables (`SERVICES` or indexed `SVC_*`).
- `scripts/list-services.sh`: project inventory helper (name retained for compatibility) with table or JSON output.
- `scripts/remove-service.sh`: removes projects cleanly with optional purge/user deletion modes.
- `healthcheck.sh`: probes configured ports (`HEALTHCHECK_PORTS` override) or falls back to Supervisor status.
- `.github/workflows/build.yml`: GitHub Actions workflow for building and pushing the image to Docker Hub.
- `/opt/projects/<name>`: runtime directories for each provisioned project (legacy slots resolve `<name>` from repo/tarball metadata or fall back to `project1`/`project2`).

## Quickstart

### Build
```sh
# direct Docker CLI
docker build -t maestro-orchestrator . \
  --build-arg SERVICE_A_REPO=https://github.com/<owner>/project-a.git \
  --build-arg SERVICE_A_REF=main \
  --build-arg SERVICE_B_REPO=https://github.com/<owner>/project-b.git \
  --build-arg SERVICE_B_REF=main

# Makefile helper (same build args, shorter command)
make build IMAGE=maestro-orchestrator \
  SERVICE_A_REPO=https://github.com/<owner>/project-a.git \
  SERVICE_B_REPO=https://github.com/<owner>/project-b.git

# buildx multi-architecture build (set PUSH=true to push instead of load)
make buildx PUSH=true IMAGE=docker.io/<namespace>/maestro-orchestrator \
  PLATFORMS=linux/amd64,linux/arm64
```

> Build commands require Docker BuildKit (Docker 20.10+). If you haven't enabled it, export `DOCKER_BUILDKIT=1` before running the commands above.

Optional build arguments:
- `SERVICE_A_SUBDIR`, `SERVICE_B_SUBDIR`: if the runnable project lives below the repo root.
- `SERVICE_A_INSTALL_CMD`, `SERVICE_B_INSTALL_CMD`: custom install steps (useful to mirror each project’s Dockerfile).
- `PIP_INSTALL_OPTIONS`: appended to the pip command (e.g., `--require-hashes`).
- `NPM_INSTALL_OPTIONS`: overrides default npm flags (defaults to `--omit=dev --no-audit --no-fund`).
- `PNPM_VERSION`, `YARN_VERSION`: pin pnpm/yarn toolchain versions when detected.

Dependency autodetect:
- Python (`requirements.txt` → `pip install -r`; otherwise `pyproject.toml` / `setup.py` → `pip install .`).
- Node.js (prefers `pnpm-lock.yaml`, then `yarn.lock`, then `npm ci`, falling back to `npm install`).

### Run the defaults
```sh
docker run -d --name maestro \
  -p 8080:8080 -p 9090:9090 \
  maestro-orchestrator
```

Supervisor program names track the derived project names (sanitized repo/tarball names, or `project1`/`project2` when none are supplied):
```sh
docker exec -it maestro supervisorctl status
docker exec -it maestro supervisorctl restart project1   # replace with the derived name shown above
docker exec -it maestro supervisorctl tail -f project2   # likewise
```

### Runtime source fetch (no rebuild)
If build arguments were omitted, populate directories on container start:
```sh
docker run -d --name maestro \
  -e SERVICE_A_REPO=https://github.com/<owner>/project-a.git \
  -e SERVICE_A_REF=main \
  -e SERVICE_B_REPO=https://github.com/<owner>/project-b.git \
  -e SERVICE_B_REF=main \
  -p 8080:8080 -p 9090:9090 \
  maestro-orchestrator
```
The entrypoint downloads tarballs via `codeload.github.com` when `/opt/projects/project-{a,b}` are empty.

## Configuration Reference

### Default Project Slots
- `DEFAULT_SERVICES_MODE` (`auto` | `always` | `never`): governs whether the built-in slots start automatically. `auto` (default) starts when code/commands are present. `always` restores the old "serve static" behaviour; `never` suppresses them entirely.
- `SERVICE_A_ENABLED`, `SERVICE_B_ENABLED`: explicit `true/false` overrides for each slot.
- `SERVICE_A_PORT`, `SERVICE_B_PORT`: default 8080/9090; must differ. Ports are validated at runtime.
- `SERVICE_A_CMD`, `SERVICE_B_CMD`: override launch command. If unset Maestro inspects the directory (Python manifests → `uvicorn app:app`; Node projects → `node server.js` or `npm start`; fallback static server).
- `SERVICE_A_TARBALL`, `SERVICE_B_TARBALL`: provide a direct tarball URL instead of a Git repo.
- `SERVICE_A_NAME`, `SERVICE_B_NAME`: optional explicit names for the legacy slots. When omitted, Maestro derives the name from the repo/tarball URL and places the code under `/opt/projects/<name>`; the same name is used for the Supervisor program ID and the project’s UNIX user.

> The environment variable names retain the historical `SERVICE_*` prefix for compatibility, even though Maestro now refers to them as projects.

### Entrypoint & Supervisor Controls
- `ENTRYPOINT_LOG_LEVEL`: adjust runtime verbosity (`debug`, `info`, `warn`, `error`; default `info`).
- `SUPERVISOR_CONF_DIR`: override where generated program configs are written/read (default `/etc/supervisor/conf.d`). CLI helpers (`list-services`, `remove-service`) honour the same variable.
- Generated program environments automatically expose `/opt/venv-<name>/bin` and `<project>/node_modules/.bin` on `PATH` when those directories exist.

### Health & Observability
- `HEALTHCHECK_PORTS`: space/comma separated list (`8080 9090`). When unset, only enabled default slots are probed; if none exist, `supervisorctl status` is used.
- `list-services [--json]`: prints every Supervisor program with user, directory, status and command (projects view).
- Logs stream to stdout/stderr; use `docker logs` or `supervisorctl tail -f <program>`.

### Provisioning Additional Projects
Interactive mode:
```sh
docker exec -it maestro deploy
```

Environment mode (`SERVICES` compact form shown):
```sh
docker run -d --name maestro \
  -e SERVICES='https://github.com/<owner>/alpha.git|8080|main|alpha|svc_alpha|;https://github.com/<owner>/beta.git|9090|main|beta|svc_beta|' \
  -p 8080:8080 -p 9090:9090 \
  maestro-orchestrator
```

Helpers ensure every project gets:
- Dedicated UNIX user per project (dynamic slots use `svc_<name>`, legacy slots reuse the derived repo/tarball name with a sanitized prefix) plus a private home and 0027 umask.
- Temp/cache directories confined to `/tmp/<name>-tmp` and `/tmp/<name>-cache`.
- Command quoting via `shlex.quote` to survive complex start commands.

Removal:
```sh
docker exec -it maestro remove-service <name> --purge --delete-user
```

## Security Hardening
```sh
docker run -d --name maestro \
  --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 512 --memory 1g --cpus 1.0 \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --tmpfs /home/<user_a>:rw,nosuid,size=32m \
  --tmpfs /home/<user_b>:rw,nosuid,size=32m \
  -p 8080:8080 -p 9090:9090 \
  maestro-orchestrator
```
- Drop `noexec` on `/tmp` if your workloads need executable temp files.
- Adjust `/home/<user>` tmpfs mounts to match the derived user names if you override the defaults (e.g., `/home/svc_myrepo`).
- Volume mounts must remain readable by the target project user (sanitized repo name for legacy slots, or the generated `svc_<name>` accounts).
- npm/yarn installs run with audit/funding checks disabled and avoid elevated privileges when bootstrapping toolchains.

## Troubleshooting
- Port already allocated: choose free host ports (`-p 18080:8080` etc.) or stop the conflicting listener.
- `supervisorctl` connection errors: ensure the container is running; the socket lives at `/tmp/supervisor.sock`.
- Project failed to start: confirm the directory contains code, or force-enable via `SERVICE_A_ENABLED=true`. Use `DEFAULT_SERVICES_MODE=always` for the legacy static-server behaviour.
- Permission denied on volume: ensure ownership or use bind mounts with proper UID/GID mapping.

## CI / Docker Hub Workflow
- Workflow builds on pushes to `main` and tags `vX.Y.Z`.
- Manual runs (`workflow_dispatch`) accept overrides for project repos/refs/install commands.
- Set `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` repository secrets for workflow pushes; optionally define a `DOCKERHUB_NAMESPACE` repository variable (or secret) to override the default (lowercased GitHub owner or `DOCKERHUB_USERNAME`).
- Images push to `docker.io/<namespace>/maestro-orchestrator` (`latest`, commit SHA, and semantic tags when available).

## Project Status
- License: MIT
- Maintainers: see `CODEOWNERS` or GitHub contributors
- Issues & ideas: open a ticket on the repository — feedback on the Maestro brand refresh is welcome!

---

**Upgrade note:** If you relied on the original "two static directories" behaviour, set `DEFAULT_SERVICES_MODE=always` or keep explicit `SERVICE_X_CMD` values. Otherwise Maestro only starts projects after assets or commands are supplied, preventing port conflicts when provisioning more workloads.
