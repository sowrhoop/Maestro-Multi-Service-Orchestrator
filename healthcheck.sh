#!/usr/bin/env sh
set -eu

SERVICE_A_PORT="${SERVICE_A_PORT:-8080}"
SERVICE_B_PORT="${SERVICE_B_PORT:-9090}"

# Check both services; fail if any is down
curl -fsS "http://localhost:${SERVICE_A_PORT}/" >/dev/null 2>&1 || exit 1
curl -fsS "http://localhost:${SERVICE_B_PORT}/" >/dev/null 2>&1 || exit 1

exit 0

