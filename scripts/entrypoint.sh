#!/usr/bin/env sh
set -e

A_PORT="${SERVICE_A_PORT:-8080}"
B_PORT="${SERVICE_B_PORT:-9090}"

if [ "$A_PORT" = "$B_PORT" ]; then
  echo "Error: SERVICE_A_PORT ($A_PORT) and SERVICE_B_PORT ($B_PORT) must be different." >&2
  exit 1
fi

echo "Starting services: project1 on ${A_PORT}, project2 on ${B_PORT}"
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf

