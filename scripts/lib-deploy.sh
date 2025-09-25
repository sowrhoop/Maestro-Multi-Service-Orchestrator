#!/usr/bin/env sh
# Shared helpers for provisioning services under Supervisor
set -eu

SUPERVISOR_CONF_DIR=${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}

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
  [ -n "$url" ] || { echo "fetch_tar_into_dir: url missing" >&2; return 1; }
  [ -n "$dest" ] || { echo "fetch_tar_into_dir: dest missing" >&2; return 1; }

  tmp="$(mktemp -t fetch.XXXXXX.tar.gz)" || return 1
  if ! curl -fsSL "$url" -o "$tmp"; then
    echo "Failed to download: $url" >&2
    rm -f "$tmp"
    return 1
  fi

  mkdir -p "$dest"
  # Prefer stripping the leading directory when archives contain a root folder.
  if tar -xzf "$tmp" -C "$dest" --strip-components 1 2>/dev/null; then
    :
  elif tar -xzf "$tmp" -C "$dest" 2>/dev/null; then
    :
  else
    echo "Failed to extract archive from $url" >&2
    rm -f "$tmp"
    return 1
  fi

  rm -f "$tmp"
  return 0
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
    if [ -f "$d/server.js" ]; then
      script="server.js"
    elif [ -f "$d/index.js" ]; then
      script="index.js"
    else
      script=""
    fi

    if [ -n "$script" ]; then
      printf "PORT=%s node %s" "$port" "$script"
    else
      start_cmd=$(python3 - <<'PY' "$d")
import json, os, sys
path = os.path.join(sys.argv[1], "package.json")
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("")
    sys.exit(0)
scripts = data.get("scripts") or {}
print((scripts.get("start") or "").strip())
PY
      start_cmd=$(printf "%s" "$start_cmd" | tr -d '\r\n')
      if [ -n "$start_cmd" ]; then
        printf "PORT=%s npm start" "$port"
      else
        printf "python3 -m http.server %s --directory %s --bind 0.0.0.0" "$port" "$d"
      fi
    fi
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
  venv="/opt/venv-${name}"
  npm_flags="${NPM_INSTALL_OPTIONS:---omit=dev --no-audit --no-fund}"

  if [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then
    if python3 -m venv "$venv" >/dev/null 2>&1; then
      if [ -f "$dir/requirements.txt" ]; then
        "$venv/bin/pip" install --no-cache-dir -r "$dir/requirements.txt" >/dev/null 2>&1 || \
        "$venv/bin/pip" install --no-cache-dir "$dir" >/dev/null 2>&1 || true
      else
        "$venv/bin/pip" install --no-cache-dir "$dir" >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [ -f "$dir/package.json" ]; then
    (cd "$dir" && (npm ci ${npm_flags} || npm install ${npm_flags}) && npm cache clean --force || true)
  fi
}

write_program_conf() {
  name="$1"; dir="$2"; cmd="$3"; user="$4"
  tmpd="/tmp/${name}-tmp"; cache="/tmp/${name}-cache"
  mkdir -p "$tmpd" "$cache"
  chown -R "$user":"$user" "$tmpd" "$cache" "$dir" || true
  quoted_cmd=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$cmd")
  if [ -z "$quoted_cmd" ]; then
    echo "write_program_conf: failed to quote command for $name" >&2
    return 1
  fi
  env_line="HOME=\"/home/${user}\",TMPDIR=\"${tmpd}\",XDG_CACHE_HOME=\"${cache}\""
  venv_bin="/opt/venv-${name}/bin"
  node_bin="${dir}/node_modules/.bin"
  path_prefix=""
  if [ -d "$venv_bin" ]; then
    path_prefix="$venv_bin"
  fi
  if [ -d "$node_bin" ]; then
    if [ -n "$path_prefix" ]; then
      path_prefix="${path_prefix}:${node_bin}"
    else
      path_prefix="$node_bin"
    fi
  fi
  if [ -n "$path_prefix" ]; then
    env_line="${env_line},PATH=\"${path_prefix}:\\$PATH\""
  fi

  cat >"${SUPERVISOR_CONF_DIR}/program-${name}.conf" <<EOF
[program:${name}]
directory=${dir}
command=/bin/sh -c ${quoted_cmd}
user=${user}
environment=${env_line}
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
