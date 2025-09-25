#!/usr/bin/env sh
# Shared helpers for provisioning services under Supervisor
set -eu

sanitize() {
  printf "%s" "$1" | tr '[:upper:] ' '[:lower:]-' | sed 's/[^a-z0-9._-]//g'
}

derive_name() {
  url="$1"
  base=$(printf "%s" "$url" | sed -E 's#^https?://github.com/##; s#\.git$##; s#/$##')
  name=${base##*/}
  sanitize "$name"
}

codeload_url() {
  url="$1"; ref="$2"
  if printf "%s" "$url" | grep -qiE '^https?://github.com/'; then
    path=$(printf "%s" "$url" | sed -E 's#^https?://github.com/##; s#\.git$##; s#/$##')
    printf "https://codeload.github.com/%s/tar.gz/%s" "$path" "$ref"
  else
    printf "%s" "$url"
  fi
}

fetch_tar_into_dir() {
  url="$1"; dest="$2"
  tmp="/tmp/src.$(date +%s).tar.gz"
  curl -fsSL "$url" -o "$tmp"
  mkdir -p "$dest"
  tar -xzf "$tmp" -C "$dest" --strip-components 1 2>/dev/null || tar -xzf "$tmp" -C "$dest" 2>/dev/null || true
  rm -f "$tmp"
}

ensure_user() {
  u="$1"
  if ! id -u "$u" >/dev/null 2>&1; then
    useradd -r -m -s /usr/sbin/nologin "$u" >/dev/null 2>&1 || true
  fi
  mkdir -p "/home/$u" && chmod 700 "/home/$u" && chown -R "$u":"$u" "/home/$u"
}

detect_default_cmd() {
  d="$1"; port="$2"
  if [ -f "$d/package.json" ]; then
    printf "PORT=%s node server.js" "$port"
  elif [ -f "$d/requirements.txt" ] || [ -f "$d/pyproject.toml" ]; then
    if [ -f "$d/app.py" ]; then
      printf "uvicorn app:app --host 0.0.0.0 --port %s" "$port"
    else
      printf "python3 -m http.server %s --directory %s --bind 0.0.0.0" "$port" "$d"
    fi
  else
    printf "python3 -m http.server %s --directory %s --bind 0.0.0.0" "$port" "$d"
  fi
}

install_deps_if_any() {
  dir="$1"; name="$2"
  if [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then
    python3 -m venv "/opt/venv-${name}" || true
    "/opt/venv-${name}/bin/pip" install --no-cache-dir -r "$dir/requirements.txt" 2>/dev/null || \
    "/opt/venv-${name}/bin/pip" install --no-cache-dir "$dir" 2>/dev/null || true
    export PATH="/opt/venv-${name}/bin:$PATH"
  fi
  if [ -f "$dir/package.json" ]; then
    (cd "$dir" && (npm ci --omit=dev || npm install --omit=dev --no-audit --no-fund) && npm cache clean --force || true)
  fi
}

write_program_conf() {
  name="$1"; dir="$2"; cmd="$3"; user="$4"
  tmpd="/tmp/${name}-tmp"; cache="/tmp/${name}-cache"
  mkdir -p "$tmpd" "$cache"
  chown -R "$user":"$user" "$tmpd" "$cache" "$dir" || true
  cat >"/etc/supervisor/conf.d/program-${name}.conf" <<EOF
[program:${name}]
directory=${dir}
command=/bin/sh -c "${cmd}"
user=${user}
environment=HOME="/home/${user}",TMPDIR="${tmpd}",XDG_CACHE_HOME="${cache}"
umask=0027
autostart=true
autorestart=unexpected
startsecs=8
startretries=3
stopsignal=TERM
stopwaitsecs=15
stopasgroup=true
killasgroup=true
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0
EOF
}

