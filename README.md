# Runpod: Two Services in One Pod (Supervisor)

This repo packages two independent projects into a single Docker image and runs them concurrently in one Runpod.io pod using Supervisord.

- Project 1 (FastAPI): listens on port 8080
- Project 2 (Express): listens on port 9090

## Layout

- `services/service-a` — Python FastAPI app
- `services/service-b` — Node.js Express app
- `Dockerfile.supervisor` — Combined image that contains both apps
- `supervisord.conf` — Process manager config (starts both apps)
- `.github/workflows/build-and-push.yml` — CI to build/push the combined image
- `scripts/` — Optional helpers to build/push per‑service images

## Build and test locally

Combined image with both services:

```sh
# Build combined image
docker build -f Dockerfile.supervisor -t your-username/two-services:latest .

# Run and expose both services
docker run --rm -p 8080:8080 -p 9090:9090 your-username/two-services:latest

# Test
curl http://localhost:8080/
curl http://localhost:9090/
```

## Control & Monitoring

Control each service independently without disturbing the other.

### Combined Image (both services in one container)

The combined image runs both apps under Supervisord with a private UNIX socket for control. Program names:
- `project1` → Service A (FastAPI, 8080)
- `project2` → Service B (Express, 9090)

Run with a fixed container name:

```sh
docker run -d --name two-services -p 8080:8080 -p 9090:9090 your-username/two-services:latest
```

Operate on services independently:

```sh
# Overall status
docker exec -it two-services supervisorctl status

# Stop / start / restart ONLY Service A
docker exec -it two-services supervisorctl stop project1
docker exec -it two-services supervisorctl start project1
docker exec -it two-services supervisorctl restart project1

# Stop / start / restart ONLY Service B
docker exec -it two-services supervisorctl stop project2
docker exec -it two-services supervisorctl start project2
docker exec -it two-services supervisorctl restart project2

# Tail logs per service
docker exec -it two-services supervisorctl tail -f project1
docker exec -it two-services supervisorctl tail -f project2

# Get the managed PID of a service
docker exec -it two-services supervisorctl pid project1
```

Troubleshooting (combined image):
- If `unix:///var/run/supervisor.sock no such file` appears, you’re running an older image. Rebuild/pull the latest (socket support is enabled in `supervisord.conf`).
  ```sh
  docker build -f Dockerfile.supervisor -t two-services:dev .
  docker run -d --name two-services -p 8080:8080 -p 9090:9090 two-services:dev
  ```
- Verify socket and config in the container:
  ```sh
  docker exec -it two-services grep -A2 "\[unix_http_server\]" /etc/supervisor/conf.d/supervisord.conf
  docker exec -it two-services ls -l /var/run/supervisor.sock
  ```

### Separate Containers (Docker Compose)

Control services individually when running with Compose:

```sh
# Build and start everything
docker compose up -d --build

# Start/stop/restart just one service
docker compose up -d service-a
docker compose stop service-b
docker compose restart service-a

# Logs per service
docker compose logs -f service-a
docker compose logs -f service-b

# Status
docker compose ps
```

### Local Dev (no Docker)

Start both as independent local processes and stop either one without affecting the other:

```sh
# PowerShell
scripts/dev.ps1

# Bash
scripts/dev.sh
```

Stop a single service by terminating its process (PowerShell: `Stop-Job`; Bash: `kill <pid>` printed by the script).

### Optional: Supervisor HTTP UI (off by default)

If you prefer a browser-based control panel, we can expose Supervisor’s HTTP interface (e.g., `127.0.0.1:9001`) with basic auth. It’s disabled by default for security. Open an issue or ask to enable it.

## CI: Build and push to GHCR

The workflow builds and pushes the combined image to GitHub Container Registry (GHCR) using the built-in `GITHUB_TOKEN`.

- Trigger: push to `main`/`master` (affected paths) or manual dispatch.
- Resulting tags:
  - `ghcr.io/<owner>/two-services:latest`
  - `ghcr.io/<owner>/two-services:${GITHUB_SHA}`

Workflow file: `.github/workflows/build-and-push.yml`

If your repository is under an organization and you see a permissions error like “installation not allowed to Create organization package”, you have two options:

- Ask an org admin to enable package publishing for Actions: Organization Settings → Packages → “Allow GitHub Actions to create and publish packages”. Also ensure the workflow has `permissions: packages: write` (already set here).
- Or use a Personal Access Token (PAT) with `write:packages` scope from a user with publish rights, and add repo secrets:
  - `GHCR_PAT` → the PAT value
  - `GHCR_USERNAME` → the username tied to that PAT (optional; defaults to `github.actor`)
  The workflow will prefer the PAT if present.

## Run on Runpod (Single Pod, Single Image)

- Image: `your-username/two-services:latest` (or `ghcr.io/<owner>/two-services:latest` if using GHCR)
- Expose ports: `8080` and `9090` (you can override via env: `SERVICE_A_PORT`, `SERVICE_B_PORT` — they must be different)
- Optional: SSH into the pod and manage processes independently with supervisorctl:
  - `supervisorctl status`
  - `supervisorctl restart project1`
  - `supervisorctl restart project2`

## Notes

- The two services are isolated processes; if one crashes, Supervisord auto‑restarts it without impacting the other.
- Inter‑process communication (if needed) is over `localhost` via their ports.
- If you still want two separate containers (one per service) instead of a combined image, you can use the individual service Dockerfiles in `services/` and deploy them as two pods.

### Health & Port Enforcement

The combined image defines a Docker `HEALTHCHECK` that pings both endpoints:
- `http://localhost:${SERVICE_A_PORT:-8080}/`
- `http://localhost:${SERVICE_B_PORT:-9090}/`
If either is down, the container is marked unhealthy.

The container entrypoint enforces unique ports and exits with an error if `SERVICE_A_PORT` equals `SERVICE_B_PORT`.

### Isolation Hardening

- Separate UNIX users per service in the combined image (`svc_a`, `svc_b`) with directory ownership restricted (chmod 750) so services cannot read each other’s code/data.
- Each standalone service image also runs as a non‑root user by default.
- For extra isolation at runtime, consider running the container with a read‑only root filesystem and explicit writable dirs:

  ```sh
  docker run --rm \
    --read-only \
    -v svc_a_tmp:/home/svc_a \
    -v svc_b_tmp:/home/svc_b \
    -p 8080:8080 -p 9090:9090 \
    ghcr.io/<owner>/two-services:latest
  ```

  On Runpod, mount persistent volumes to the same paths as writable homes if your apps need to write.

## Multirepo: Build Two Images Then Merge

If Service A and Service B live in separate GitHub repos with their own Dockerfiles, this repo can build both images and then produce a combined Supervisor image by copying the app payloads from those two images.

- Dockerfiles: `Dockerfile.supervisor.from-images` (CPU) and `Dockerfile.supervisor.from-images.gpu` (CUDA base)
- GitHub Action: `.github/workflows/build-two-and-merge.yml`

Run the workflow manually (Actions → “Build Service A & B, then Merge”) and provide inputs:
- `service_a_repo` (e.g., `yourorg/service-a`), `service_a_ref` (e.g., `main`), `service_a_dockerfile` (path to its Dockerfile)
- `service_b_repo`, `service_b_ref`, `service_b_dockerfile`
- `use_gpu_base` (true to use CUDA base in the merged image)

What it produces in GHCR:
- `ghcr.io/<owner>/project-1:<sha>` and `:latest`
- `ghcr.io/<owner>/project-2:<sha>` and `:latest`
- `ghcr.io/<owner>/two-services:<sha>` and `:latest` (merged Supervisor image)

Technical notes:
- The merged Dockerfiles install Python/Node and re‑install dependencies from the copied app manifests. They don’t try to “copy runtimes” from the source images to avoid libc/base‑image incompatibilities.
- At runtime you still get independent control via `supervisorctl` as documented above.

### Bootstrap external repos with GitHub CLI

GitHub repo names cannot contain spaces. We’ll use `project-1` and `project-2`.

Requirements:
- Install and authenticate GitHub CLI: `gh auth login`
- Have permission to create repos under your user or org

Create the two repos and push the templates:

```sh
# CPU/Linux/macOS
scripts/bootstrap-multirepo.sh <your_github_user_or_org> public

# Windows PowerShell
scripts/bootstrap-multirepo.ps1 -Owner <your_github_user_or_org> -Visibility public
```

This creates and pushes:
- `https://github.com/<owner>/project-1` (FastAPI)
- `https://github.com/<owner>/project-2` (Express)

Each repo includes its own CI to build/push images to GHCR.

Run the merge workflow in this repo:

```text
Actions → Build Service A & B, then Merge → Run workflow
  service_a_repo: <owner>/project-1
  service_a_ref: main
  service_a_dockerfile: Dockerfile
  service_b_repo: <owner>/project-2
  service_b_ref: main
  service_b_dockerfile: Dockerfile
  use_gpu_base: false   # or true to use CUDA runtime
```

If the external repos are private, add a `GH_PAT` secret in this repo with `repo` scope so the workflow can check them out.
