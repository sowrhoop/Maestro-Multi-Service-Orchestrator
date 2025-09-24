# project-1 (FastAPI)

Minimal FastAPI service exposing `/` and listening on `PORT` (default 8080).

## Build

```sh
docker build -t ghcr.io/<owner>/project-1:latest .
```

## Run

```sh
docker run --rm -e PORT=8080 -p 8080:8080 ghcr.io/<owner>/project-1:latest
curl http://localhost:8080/
```

