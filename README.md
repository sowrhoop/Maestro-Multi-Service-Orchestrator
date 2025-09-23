# Two Services in One Image (Supervisor)

This repository orchestrates two independent services into a single Docker image and runs them together using Supervisord — built from two external repositories (project-1 and project-2). The CI builds each image and then merges their app payloads into a single Supervisor image.

Default ports:
- Service A (FastAPI): 8080
- Service B (Express): 9090

## Repository Layout

- `Dockerfile.supervisor.from-images(.gpu)`: Merge two pre-built images
- `supervisord.conf`: Starts both apps and wires logs to stdout/stderr
- `scripts/`: Helpers (dispatch bootstrap, smoke tests)
- `.github/workflows/`: CI to build external repos and merge images

Supervisor program names: `project1` and `project2`. Manage them with `supervisorctl` inside the container.

Advanced overrides:
- `SERVICE_A_CMD`: custom command for Service A (default `uvicorn app:app --host 0.0.0.0 --port ${SERVICE_A_PORT:-8080}`)
- `SERVICE_B_CMD`: custom command for Service B (default `PORT=${SERVICE_B_PORT:-9090} node server.js`)

## CI: From-Images Merge (project-1 + project-2)

Use the workflow `.github/workflows/build-two-and-merge.yml` to build two external repos and produce a merged image:

- Inputs: `service_a_repo`, `service_a_ref`, `service_a_dockerfile`, `service_b_repo`, `service_b_ref`, `service_b_dockerfile`, `use_gpu_base`.
- Outputs (GHCR tags):
  - `ghcr.io/<owner>/project-1:latest` and `:<sha>`
  - `ghcr.io/<owner>/project-2:latest` and `:<sha>`
  - `ghcr.io/<owner>/supervisor-image-combination:latest` and `:<sha>` (merged image)

Contract for external images (required for the merge Dockerfiles):
- Each source image must contain the app payload at `/app`.
- Python service (Service A): `/app/requirements.txt` and an `app.py` exposing `app` for Uvicorn.
- Node service (Service B): `/app/package.json` and an entry `server.js` that respects `PORT`.

If your repos follow different layouts, adjust the merge Dockerfiles or provide tiny wrapper Dockerfiles in those repos to present the expected `/app` shape.

If the external repos are private, add a `GH_PAT` secret with `repo` scope so Actions can check them out.

CI troubleshooting (GHCR permissions):
- If you see `denied: permission_denied: write_package` while pushing to GHCR, add these repo secrets:
  - `GHCR_PAT`: Personal Access Token with `write:packages` (and optionally `delete:packages`), tied to the account that owns `ghcr.io/<owner>`.
  - `GHCR_USERNAME`: Set to that account’s username (optional; defaults to `github.actor`).
  The workflow prefers `GHCR_PAT` if present; otherwise it falls back to `GITHUB_TOKEN`.

## Control & Monitoring

Run a merged image (example with GHCR tag):

```sh
docker run -d --name two-services -p 8080:8080 -p 9090:9090 ghcr.io/<owner>/supervisor-image-combination:latest

# Overall status
docker exec -it two-services supervisorctl status

# Restart only one service
docker exec -it two-services supervisorctl restart project1
docker exec -it two-services supervisorctl restart project2

# Tail individual logs
docker exec -it two-services supervisorctl tail -f project1
docker exec -it two-services supervisorctl tail -f project2
```

If your Service A isn’t FastAPI (e.g., a static server), override the command:

```sh
docker run -d --name two-services \
  -e SERVICE_A_CMD='python3 -m http.server ${SERVICE_A_PORT:-8080} --bind 0.0.0.0' \
  -p 8080:8080 -p 9090:9090 \
  ghcr.io/<owner>/supervisor-image-combination:latest
```

Health & safety:
- Healthcheck pings `http://localhost:${SERVICE_A_PORT:-8080}/` and `http://localhost:${SERVICE_B_PORT:-9090}/`.
- Entrypoint enforces distinct ports for both services.
- Each service runs as its own unprivileged UNIX user and has restricted access to the other's files.

## Run on Runpod

- Image: `ghcr.io/<owner>/supervisor-image-combination:latest`
- Expose ports: `8080` and `9090` (override via env `SERVICE_A_PORT`, `SERVICE_B_PORT` — values must differ)
- Manage with `supervisorctl` inside the Pod if needed

## Optional: Bootstrap Example Repos

This repo includes minimal templates under `templates/` to quickly create `project-1` (FastAPI) and `project-2` (Express) using GitHub CLI:

```sh
# Linux/macOS
scripts/bootstrap-multirepo.sh <your_github_user_or_org> public

# Windows PowerShell
scripts/bootstrap-multirepo.ps1 -Owner <your_github_user_or_org> -Visibility public
```

Then run the “Build Service A & B, then Merge” workflow.
