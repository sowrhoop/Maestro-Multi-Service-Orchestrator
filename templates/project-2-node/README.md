# project-2 (Express)

Minimal Express service exposing `/` and listening on `PORT` (default 9090). If `SERVICE_A_URL` is provided, it will fetch `/` from Service A and embed the result.

## Build

```sh
docker build -t ghcr.io/<owner>/project-2:latest .
```

## Run

```sh
docker run --rm -e PORT=9090 -p 9090:9090 ghcr.io/<owner>/project-2:latest
curl http://localhost:9090/
```

