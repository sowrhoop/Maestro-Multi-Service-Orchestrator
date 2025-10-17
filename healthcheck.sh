#!/usr/bin/env sh
set -eu

# Allow explicit list via HEALTHCHECK_PORTS (space/comma/semicolon separated).
if [ -n "${HEALTHCHECK_PORTS:-}" ]; then
  PORT_LIST=$(printf '%s' "${HEALTHCHECK_PORTS}" | tr ',;' ' ')
else
  PORT_LIST=""
  PORT_LEDGER=${MAESTRO_PORT_LEDGER:-/run/maestro/ports.csv}
  if [ -f "$PORT_LEDGER" ]; then
    ledger_ports=$(awk -F'|' 'NF>=2 && $2 ~ /^[0-9]+$/ {print $2}' "$PORT_LEDGER" 2>/dev/null | sort -n | uniq)
    for p in $ledger_ports; do
      PORT_LIST="${PORT_LIST} ${p}"
    done
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
