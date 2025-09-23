#!/usr/bin/env bash
set -euo pipefail

# Registry settings (secure, token-based). Defaults to Docker Hub.
REGISTRY_HOST=${REGISTRY_HOST:-docker.io}
REGISTRY_USER=${REGISTRY_USER:-${DOCKER_USER:-}}
REGISTRY_TOKEN=${REGISTRY_TOKEN:-}

if [[ -z "${REGISTRY_USER}" ]]; then
  echo "Set REGISTRY_USER (or DOCKER_USER) to your registry username" >&2
  exit 1
fi

# Optional non-interactive login using token from env var REGISTRY_TOKEN
if [[ -n "${REGISTRY_TOKEN}" ]]; then
  echo "Logging into registry ${REGISTRY_HOST} as ${REGISTRY_USER} (token via --password-stdin)"
  if [[ "${REGISTRY_HOST}" == "docker.io" || -z "${REGISTRY_HOST}" ]]; then
    printf '%s' "${REGISTRY_TOKEN}" | docker login -u "${REGISTRY_USER}" --password-stdin
  else
    printf '%s' "${REGISTRY_TOKEN}" | docker login "${REGISTRY_HOST}" -u "${REGISTRY_USER}" --password-stdin
  fi
else
  echo "REGISTRY_TOKEN not set; skipping docker login. Ensure you are already logged in." >&2
fi

# Compute image repo prefix
if [[ "${REGISTRY_HOST}" == "docker.io" || -z "${REGISTRY_HOST}" ]]; then
  REPO_PREFIX="${REGISTRY_USER}"
else
  REPO_PREFIX="${REGISTRY_HOST}/${REGISTRY_USER}"
fi

echo "Building and pushing ${REPO_PREFIX}/service-a:latest"
docker build -t "${REPO_PREFIX}/service-a:latest" services/service-a
docker push "${REPO_PREFIX}/service-a:latest"

echo "Building and pushing ${REPO_PREFIX}/service-b:latest"
docker build -t "${REPO_PREFIX}/service-b:latest" services/service-b
docker push "${REPO_PREFIX}/service-b:latest"

echo "Done. Use these images in your Runpod Pod Template."
