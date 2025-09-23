# Runpod: Single Pod Running Two Services

Runpod Pods run one container image. To run two services in a single Pod, use a combined image that starts both processes (via Supervisor). Alternatively, run two separate Pods.

## Build and Push Images

- Combined image (Supervisor):
  - `docker build -f Dockerfile.supervisor -t ghcr.io/<owner>/two-in-one:latest .`
  - `docker push ghcr.io/<owner>/two-in-one:latest`
- Or use the CI workflow which also pushes `service-a` and `service-b` images.

## Create Pod Template (Combined Image)

1. Open Runpod Dashboard → Templates → Create Pod Template.
2. Image: `ghcr.io/<owner>/two-in-one:latest` (or your registry path).
3. Expose ports: `8000` and `3000`.
4. Optional env: `SERVICE_A_PORT=8000`, `SERVICE_B_PORT=3000` (change if needed).
5. Optional volume: mount to `/shared`.
6. GPU (optional): assign GPU to the pod if your apps require it.

## Validate

- External:
  - `curl https://<pod-endpoint-for-8000>/` → JSON from Service A
  - `curl https://<pod-endpoint-for-3000>/` → JSON from Service B
- Internal (from container console):
  - `curl http://localhost:8000/` and `curl http://localhost:3000/`

## Notes

- The combined image starts both processes; they listen on `SERVICE_A_PORT` (default 8000) and `SERVICE_B_PORT` (default 3000).
- Inside the container, processes share the same network namespace; use `localhost` between them.
- If you prefer isolation, run two Pods and use Public Endpoints (or Runpod networking features) for inter‑service traffic.

