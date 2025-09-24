# Runpod: Single Pod Running Two Services

Runpod Pods run one container image. To run two services in a single Pod, use a combined image that starts both processes (via Supervisor). Alternatively, run two separate Pods.

## Build and Push Images

- Combined image (Supervisor):
  - CPU: `docker build -f Dockerfile.supervisor.from-images -t ghcr.io/<owner>/supervisor-image-combination:latest .`
  - GPU: `docker build -f Dockerfile.supervisor.from-images.gpu -t ghcr.io/<owner>/supervisor-image-combination:latest .`
  - Or use the CI workflow which builds project-1, project-2, then merges them.

## Create Pod Template (Combined Image)

1. Open Runpod Dashboard → Templates → Create Pod Template.
2. Image: `ghcr.io/<owner>/supervisor-image-combination:latest` (or your registry path).
3. Expose ports: `8080` and `9090`.
4. Optional env: `SERVICE_A_PORT=8080`, `SERVICE_B_PORT=9090` (change if needed; they must differ).
5. Optional volume: mount to `/shared`.
6. GPU (optional): assign GPU to the pod if your apps require it.

## Validate

- External:
  - `curl https://<pod-endpoint-for-8080>/` → JSON from Service A
  - `curl https://<pod-endpoint-for-9090>/` → JSON from Service B
- Internal (from container console):
  - `curl http://localhost:8080/` and `curl http://localhost:9090/`

## Notes

- The combined image starts both processes; they listen on `SERVICE_A_PORT` (default 8080) and `SERVICE_B_PORT` (default 9090).
- Inside the container, processes share the same network namespace; use `localhost` between them.
- If you prefer isolation, run two Pods and use Public Endpoints (or Runpod networking features) for inter-service traffic.

