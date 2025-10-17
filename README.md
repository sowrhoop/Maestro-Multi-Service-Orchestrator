# Maestro Multi-Project Orchestrator

Maestro is a production-grade container blueprint for running two or more applications under Supervisord with strict process and filesystem isolation. It replaces the old "Supervisor-Image-Combination" name and puts a polished brand on the same battle-tested runtime so you can ship polyglot projects from a single image without cutting corners on security or operability.

## Core Capabilities
- Discover and launch any number of pre-seeded project directories (`/opt/projects/*` by default) according to a runtime policy (`MAESTRO_PRESEEDED_MODE`).
- Provision unlimited additional services at runtime via environment-driven specs or the interactive `deploy` helper; every service receives an isolated UNIX user, temp/cache directories, and Supervisor program.
- Hardened entrypoint that validates ports, ensures ownership/permissions, and generates Supervisor configs on the fly.
- Healthcheck script that adapts to registered ports and falls back to verifying the Supervisor control socket.

## Layout
- `Dockerfile`: installs runtime dependencies and lays down the orchestration tooling.
- `config/supervisord-main.conf`: Supervisor root configuration (PID and socket in `/tmp`, includes `conf.d`).
- `scripts/entrypoint.sh`: prepares isolation, discovers pre-seeded projects, honours autostart policy, and launches Supervisor foreground.
- `scripts/lib-deploy.sh`: shared helpers for fetching tarballs, detecting default commands, and writing program stanzas.
- `scripts/deploy-interactive.sh`: prompts inside the container to add projects dynamically.
- `scripts/deploy-from-env.sh`: idempotent provisioning from environment variables (`SERVICES` or indexed `SVC_*`).
- `scripts/list-services.sh`: project inventory helper (name retained for compatibility) with table or JSON output.
- `scripts/remove-project.sh`: removes projects cleanly with optional purge/user deletion modes (also installed as `remove-service` for backward compatibility).
- `healthcheck.sh`: probes configured ports (`HEALTHCHECK_PORTS` override) or falls back to Supervisor status.
- `.github/workflows/build.yml`: GitHub Actions workflow for building and publishing the image to GitHub Container Registry (GHCR).
- `/opt/projects/<name>`: runtime directories for each provisioned project (name derived from metadata or directory name; no hard-coded slots).

## Quickstart

### Build
```sh
# direct Docker CLI
docker build -t maestro-orchestrator .

# Makefile helper (pass BUILD_ARGS to forward any custom --build-arg flags)
make build IMAGE=maestro-orchestrator

# buildx multi-architecture build (set PUSH=true to push instead of load)
make buildx PUSH=true IMAGE=ghcr.io/<namespace>/maestro-orchestrator \
  PLATFORMS=linux/amd64,linux/arm64
```

> Build commands require Docker BuildKit (Docker 20.10+). If you haven't enabled it, export `DOCKER_BUILDKIT=1` before running the commands above.

### Launch with environment specs
Pass the `SERVICES` variable to provision any number of projects at boot. Each entry follows `repo|port|ref|name|user|cmd` (leave a field blank to auto-detect or auto-select a value).

```sh
docker run -d --name maestro \
  -e SERVICES='https://github.com/<owner>/alpha.git|8080|main|alpha|svc_alpha|;https://github.com/<owner>/beta.git||main|beta||;https://github.com/<owner>/gamma.git|0|main|||python app.py' \
  -p 8080:8080 \
  maestro-orchestrator
```

- An empty or zero `port` field tells Maestro to pick a free port; check `list-services` for the resolved value.
- Provide `name`/`user`/`cmd` only when you need explicit overrides; otherwise Maestro derives sane defaults.

Prefer explicit env vars? Use the indexed form:

```sh
docker run -d --name maestro \
  -e SERVICES_COUNT=3 \
  -e SVC_1_REPO=https://github.com/<owner>/alpha.git \
  -e SVC_1_PORT=8080 \
  -e SVC_2_REPO=https://github.com/<owner>/beta.git \
  -e SVC_2_REF=release-2025.01 \
  -e SVC_2_CMD="npm start" \
  -e SVC_3_REPO=https://github.com/<owner>/gamma.git \
  maestro-orchestrator
```

Discover the registered services at runtime:

```sh
docker exec -it maestro list-services
docker exec -it maestro supervisorctl status
```

## Infrastructure as Code (Terraform)

For teams that prefer a fully automated workflow (or stakeholders who want to avoid hand-written Docker commands), an Infrastructure as Code path is available under `iac/`.

### One-Command Setup
```sh
./iac/provision.sh
```
- The helper checks for Docker and Terraform, prompts you for any missing inputs (container name plus optional repo URLs), writes `iac/terraform/generated.auto.tfvars`, then runs `terraform init` + `apply`.
- Outputs (container ID, published ports, etc.) are echoed at the end so you can copy/paste them into status updates.
- See `iac/README.md` if you prefer a short standalone guide you can hand to non-engineering stakeholders.

### Optional: Run Terraform Manually
- All Terraform sources live in `iac/terraform`. If you prefer to drive Terraform yourself, copy `terraform.tfvars.example`, edit as needed, and run the standard `terraform init/plan/apply` workflow there.
- To dismantle the environment, run either `./iac/provision.sh destroy` or `terraform destroy` from `iac/terraform`.

## Configuration Reference

### Entrypoint & Supervisor Controls
- `ENTRYPOINT_LOG_LEVEL`: adjust runtime verbosity (`debug`, `info`, `warn`, `error`; default `info`).
- `SUPERVISOR_CONF_DIR`: override where generated program configs are written/read (default `/etc/supervisor/conf.d`). CLI helpers (`list-services`, `remove-service`) honour the same variable.
- Generated program environments automatically expose `/opt/venv-<name>/bin` and `<project>/node_modules/.bin` on `PATH` when those directories exist.

### Health & Observability
- `HEALTHCHECK_PORTS`: space/comma separated list (`8080 9090`). When unset, Maestro reads the runtime port ledger and probes every registered service; if no ports are registered, it falls back to `supervisorctl status`.
- `list-services [--json]`: prints every Supervisor program with user, directory, status and command (projects view).
- Logs stream to stdout/stderr; use `docker logs` or `supervisorctl tail -f <program>`.

### Service Provisioning (`SERVICES`, `SERVICES_COUNT`)
- `SERVICES="repo|port|ref|name|user|cmd;..."` — compact string form. Leave any field blank to auto-detect (`repo||main|name||` will auto-select the port, user, and command).
- `SERVICES_COUNT=N` with numbered variables (`SVC_1_REPO`, `SVC_1_PORT`, `SVC_1_REF`, `SVC_1_NAME`, `SVC_1_USER`, `SVC_1_CMD`, ...). Mix-and-match populated fields as needed.
- Ports that evaluate to `0` or empty are auto-allocated and persisted to `.maestro-port` for subsequent boots.

### Pre-seeded Projects
- `MAESTRO_PRESEEDED_MODE`: `auto` (default) starts populated directories or those with explicit command overrides, `always` forces registration even when empty, `never` skips discovery altogether.
- `MAESTRO_PRESEEDED_ROOTS`: whitespace/comma/colon separated list of directories to scan (default `/opt/projects`).
- Metadata files inside a project directory:
  - `.maestro-name`: preferred service name (sanitized to derive user and Supervisor program id).
  - `.maestro-port`: fixed container port (otherwise kept in sync with auto-assigned ports).
  - `.maestro-cmd`: explicit start command (single or multi-line shell).
  - `.maestro-user`: desired UNIX account (sanitized through `derive_project_user`).
- Environment overrides follow `MAESTRO_<KEY>_<SERVICE>` (uppercase, sanitized by replacing `.-` with `_`). Example: `MAESTRO_PORT_ALPHA=8081`, `MAESTRO_CMD_ALPHA="uvicorn app:app --port 8081"`, `MAESTRO_USER_ALPHA=svc_alpha`.

### Runtime helpers
- `docker exec -it maestro deploy` — interactive workflow for provisioning one or more services in-session.
- `docker exec -it maestro list-services [--json]` — inventory active Supervisor programs with status and commands.
- `docker exec -it maestro remove-service <name> [--purge] [--delete-user]` — unregisters a service and optionally purges its files; also available as `remove-project`.

### Sandboxed command execution
- Internal build/deploy helpers (`fetch_tar_into_dir`, `install_deps_if_any`, interactive deploy, etc.) execute within `maestro-sandbox`, a Bubblewrap-based jail that isolates PID/IPC namespaces, mounts a read-only system view, and constrains CPU/RAM/PIDs via cgroup v2 limits.
- Network access defaults to **deny** (`MAESTRO_SANDBOX_NET_POLICY=deny`), meaning only loopback is reachable. Set `MAESTRO_SANDBOX_NET_POLICY=allow` when a command must reach the network.
- Allow mode requires a root-owned, read-only policy file (`MAESTRO_SANDBOX_NET_ALLOW_FILE`, default `/etc/maestro/sandbox-net-allow`). The build ships this file with `ALLOW_HOST_NETWORK=1` and `0400` permissions; add additional host patterns (one per line) beneath the flag to restrict outbound destinations. If no hosts are listed, all outbound destinations are permitted once allow mode is active.
- Override `MAESTRO_SANDBOX_NET_ALLOW_FILE` to point at your own policy file if you need to manage it externally; the same ownership/permission checks apply.
- Resource ceilings are configurable via `MAESTRO_SANDBOX_MEMORY` (e.g., `512M` or `max`), `MAESTRO_SANDBOX_CPU_QUOTA_US` / `MAESTRO_SANDBOX_CPU_PERIOD_US`, and `MAESTRO_SANDBOX_PIDS_MAX`; see `scripts/maestro-sandbox.sh` for defaults.

## Security Hardening
```sh
docker run -d --name maestro \
  --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 512 --memory 1g --cpus 1.0 \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  -e MAESTRO_PRESEEDED_MODE=never \
  -e SERVICES='https://github.com/<owner>/alpha.git|8080|main|alpha||;https://github.com/<owner>/beta.git|9090|main|beta||' \
  -p 8080:8080 -p 9090:9090 \
  maestro-orchestrator
```
- Drop `noexec` on `/tmp` if your workloads need executable temp files.
- Add per-project tmpfs mounts under `/home/<svc_user>` after you know the derived usernames (see `list-services` output).
- Volume mounts must remain readable by the target project user (sanitized repo name).
- npm/yarn installs run with audit/funding checks disabled and avoid elevated privileges when bootstrapping toolchains.

## Troubleshooting
- Port already allocated: choose free host ports (`-p 18080:8080` etc.) or stop the conflicting listener.
- `supervisorctl` connection errors: ensure the container is running; the socket lives at `/tmp/supervisor.sock`.
- Project failed to start: confirm the directory contains code, or set `MAESTRO_PRESEEDED_MODE=always` so empty directories still register when you provide an explicit command.
- Permission denied on volume: ensure ownership or use bind mounts with proper UID/GID mapping.

## CI / GHCR Workflow
- Workflow builds on pushes to `main` and tags `vX.Y.Z`.
- Manual runs (`workflow_dispatch`) accept overrides for project repos/refs/install commands.
- The job grants `packages: write` permission and authenticates to GHCR with the built-in `GITHUB_TOKEN`.
- Optionally set a `GHCR_NAMESPACE` repository variable (or secret) to override the default (lowercased repository owner).
- Images publish to `ghcr.io/<namespace>/maestro-orchestrator` (`latest`, commit SHA, and semantic tags when available).

## Project Status
- License: MIT
- Maintainers: see `CODEOWNERS` or GitHub contributors
- Issues & ideas: open a ticket on the repository — feedback on the Maestro brand refresh is welcome!

---

**Upgrade note:** Legacy `SERVICE_A_*` / `SERVICE_B_*` variables have been retired. Use the `SERVICES` / `SERVICES_COUNT` specifications for remote sources, or rely on `MAESTRO_PRESEEDED_MODE` plus `.maestro-*` metadata for directories you mount into the image.
