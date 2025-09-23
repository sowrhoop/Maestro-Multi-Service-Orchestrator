#!/usr/bin/env bash
set -euo pipefail

APORT="${APORT:-8080}"
BPORT="${BPORT:-9090}"

echo "Starting local dev servers (A:${APORT}, B:${BPORT})"

python -m venv .venv >/dev/null 2>&1 || true
. ./.venv/bin/activate
pip install --disable-pip-version-check -q -r services/service-a/requirements.txt
PORT="$APORT" python services/service-a/app.py &
PID_A=$!

pushd services/service-b >/dev/null
if [ -f package-lock.json ]; then npm ci --silent; else npm install --no-audit --no-fund --silent; fi
PORT="$BPORT" SERVICE_A_URL="http://127.0.0.1:${APORT}" node server.js &
PID_B=$!
popd >/dev/null

trap 'echo "Stopping..."; kill $PID_A $PID_B 2>/dev/null || true' EXIT INT TERM

echo "Service A: http://localhost:${APORT}/"
echo "Service B (UI): http://localhost:${BPORT}/"
wait

