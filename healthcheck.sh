#!/usr/bin/env sh
set -eu

# Allow explicit list via HEALTHCHECK_PORTS (space/comma/semicolon separated).
if [ -n "${HEALTHCHECK_PORTS:-}" ]; then
  PORT_LIST=$(printf '%s' "${HEALTHCHECK_PORTS}" | tr ',;' ' ')
else
  PORT_LIST=""
  if [ -f /etc/supervisor/conf.d/program-project1.conf ]; then
    PORT_LIST="${PORT_LIST} ${SERVICE_A_PORT:-8080}"
  fi
  if [ -f /etc/supervisor/conf.d/program-project2.conf ]; then
    PORT_LIST="${PORT_LIST} ${SERVICE_B_PORT:-9090}"
  fi
fi

PORT_LIST=$(printf '%s' "$PORT_LIST" | tr -s ' ')

if [ -n "$PORT_LIST" ]; then
  for port in $PORT_LIST; do
    [ -n "$port" ] || continue
    curl -fsS --max-time 4 "http://127.0.0.1:${port}/" >/dev/null 2>&1 || exit 1
  done
  exit 0
fi

# Fallback: ensure Supervisor responds.
supervisorctl status >/dev/null 2>&1 || exit 1
exit 0
