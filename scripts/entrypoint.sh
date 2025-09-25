#!/usr/bin/env sh
# Use POSIX sh flags only (dash busybox compatible)
set -eu

umask 0027

# Ensure writable runtime dirs exist (works with --read-only + tmpfs mounts)
mkdir -p /tmp/project1-tmp /tmp/project1-cache /tmp/project2-tmp /tmp/project2-cache || true
mkdir -p /tmp/supervisor || true
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

# If the service directories are empty and runtime source URLs are provided,
# fetch tarballs (no git needed). Supports GitHub via codeload or direct tarball.
fetch_tar_into_dir() {
  url="$1"; dest="$2";
  tmp="/tmp/src.$(date +%s).tar.gz"
  echo "Fetching $url into $dest" >&2
  if ! curl -fsSL "$url" -o "$tmp"; then
    echo "Warning: fetch failed: $url" >&2; return 1; fi
  mkdir -p "$dest"
  if ! tar -xzf "$tmp" -C "$dest" --strip-components 1 2>/dev/null; then
    echo "Warning: extract failed for $url" >&2; rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
}

# Service A runtime fetch
if [ -z "$(ls -A /opt/services/service-a 2>/dev/null)" ]; then
  if [ -n "${SERVICE_A_TARBALL:-}" ]; then
    fetch_tar_into_dir "$SERVICE_A_TARBALL" "/opt/services/service-a" || true
  elif [ -n "${SERVICE_A_REPO:-}" ] && echo "$SERVICE_A_REPO" | grep -qiE '^https?://github.com/'; then
    _ref="${SERVICE_A_REF:-main}"
    _repo_path=${SERVICE_A_REPO#https://github.com/}; _repo_path=${_repo_path#http://github.com/}; _repo_path=${_repo_path%.git}
    _url="https://codeload.github.com/${_repo_path}/tar.gz/${_ref}"
    fetch_tar_into_dir "$_url" "/opt/services/service-a" || true
  fi
  chown -R svc_a:svc_a /opt/services/service-a || true
fi

# Service B runtime fetch
if [ -z "$(ls -A /opt/services/service-b 2>/dev/null)" ]; then
  if [ -n "${SERVICE_B_TARBALL:-}" ]; then
    fetch_tar_into_dir "$SERVICE_B_TARBALL" "/opt/services/service-b" || true
  elif [ -n "${SERVICE_B_REPO:-}" ] && echo "$SERVICE_B_REPO" | grep -qiE '^https?://github.com/'; then
    _ref="${SERVICE_B_REF:-main}"
    _repo_path=${SERVICE_B_REPO#https://github.com/}; _repo_path=${_repo_path#http://github.com/}; _repo_path=${_repo_path%.git}
    _url="https://codeload.github.com/${_repo_path}/tar.gz/${_ref}"
    fetch_tar_into_dir "$_url" "/opt/services/service-b" || true
  fi
  chown -R svc_b:svc_b /opt/services/service-b || true
fi

# Auto-detect static sites and set defaults if no explicit commands
if [ -z "${SERVICE_A_CMD:-}" ]; then
  export SERVICE_A_CMD="python3 -m http.server ${A_PORT} --directory /opt/services/service-a --bind 0.0.0.0"
fi

if [ -z "${SERVICE_B_CMD:-}" ]; then
  export SERVICE_B_CMD="python3 -m http.server ${B_PORT} --directory /opt/services/service-b --bind 0.0.0.0"
fi

# If SERVICES* env is present, pre-provision before Supervisor starts
if [ -n "${SERVICES:-}" ] || [ -n "${SERVICES_COUNT:-}" ]; then
  if [ -x /usr/local/bin/deploy-from-env ]; then
    /usr/local/bin/deploy-from-env --prepare-only || true
  fi
fi

echo "Starting services: project1 on ${A_PORT}, project2 on ${B_PORT}"
# Use default config at /etc/supervisor/supervisord.conf which includes conf.d/
exec /usr/bin/supervisord -n
