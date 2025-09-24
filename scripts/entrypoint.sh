#!/usr/bin/env sh
# Use POSIX sh flags only (dash busybox compatible)
set -eu

umask 0027

# Ensure writable runtime dirs exist (works with --read-only + tmpfs mounts)
mkdir -p /tmp/project1-tmp /tmp/project1-cache /tmp/project2-tmp /tmp/project2-cache || true
mkdir -p /home/svc_a /home/svc_b || true
mkdir -p /opt/services/service-a /opt/services/service-b || true
chown -R svc_a:svc_a /opt/services/service-a || true
chown -R svc_b:svc_b /opt/services/service-b || true
chmod 750 /opt/services/service-a /opt/services/service-b || true
chown -R svc_a:svc_a /home/svc_a /tmp/project1-tmp /tmp/project1-cache || true
chown -R svc_b:svc_b /home/svc_b /tmp/project2-tmp /tmp/project2-cache || true
chmod 700 /home/svc_a /home/svc_b || true
chmod 700 /tmp/project1-cache /tmp/project2-cache || true

A_PORT="${SERVICE_A_PORT:-8080}"
B_PORT="${SERVICE_B_PORT:-9090}"

if [ "$A_PORT" = "$B_PORT" ]; then
  echo "Error: SERVICE_A_PORT ($A_PORT) and SERVICE_B_PORT ($B_PORT) must be different." >&2
  exit 1
fi

# Auto-detect static sites and set defaults if no explicit commands
if [ -z "${SERVICE_A_CMD:-}" ]; then
  export SERVICE_A_CMD="python3 -m http.server ${A_PORT} --directory /opt/services/service-a --bind 0.0.0.0"
fi

if [ -z "${SERVICE_B_CMD:-}" ]; then
  export SERVICE_B_CMD="python3 -m http.server ${B_PORT} --directory /opt/services/service-b --bind 0.0.0.0"
fi

echo "Starting services: project1 on ${A_PORT}, project2 on ${B_PORT}"
# Use default config at /etc/supervisor/supervisord.conf which includes conf.d/
exec /usr/bin/supervisord -n
