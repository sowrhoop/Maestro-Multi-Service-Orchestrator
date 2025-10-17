#!/usr/bin/env sh
# Shared helpers for provisioning projects under Supervisor
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

derive_project_user() {
  name="$1"
  fallback="$2"
  slot_hint="$3"

  candidate=$(printf '%s' "$name" | tr '.-' '__')
  candidate=$(printf '%s' "$candidate" | sed 's/[^a-z0-9_]//g')
  candidate=$(printf '%.32s' "$candidate")

  if [ -z "$candidate" ]; then
    candidate="$fallback"
  fi

  case "$candidate" in
    ''|[!a-z_]* )
      prefix="svc"
      if [ -n "$slot_hint" ]; then
        prefix="${prefix}_${slot_hint}"
      fi
      candidate="${prefix}_${candidate}"
      candidate=$(printf '%s' "$candidate" | sed 's/[^a-z0-9_]//g')
      candidate=$(printf '%.32s' "$candidate")
      ;;
  esac

  case "$candidate" in
    [a-z_][a-z0-9_]* ) : ;;
    *) candidate="$fallback" ;;
  esac

  if [ -z "$candidate" ]; then
    candidate="$fallback"
  fi

  printf '%s' "$candidate"
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

escape_env_value() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

program_paths() {
  name="$1"; user="$2"
  PROGRAM_USER_HOME="/home/${user}"
  base="${PROGRAM_USER_HOME}/.maestro"
  PROGRAM_RUNTIME_DIR="${base}/runtime/${name}"
  PROGRAM_TMP_DIR="${base}/tmp/${name}"
  PROGRAM_CACHE_DIR="${base}/cache/${name}"
  PROGRAM_VENV_DIR="${base}/venvs/${name}"
}

ensure_program_dirs() {
  name="$1"; user="$2"
  program_paths "$name" "$user"

  for dir in "$PROGRAM_RUNTIME_DIR" "$PROGRAM_TMP_DIR" "$PROGRAM_CACHE_DIR" "$PROGRAM_VENV_DIR"; do
    mkdir -p "$dir"
    chown "$user":"$user" "$dir" 2>/dev/null || true
    case "$dir" in
      "$PROGRAM_CACHE_DIR"|"$PROGRAM_TMP_DIR")
        chmod 700 "$dir" 2>/dev/null || true
        ;;
      *)
        chmod 750 "$dir" 2>/dev/null || true
        ;;
    esac
  done

  for sub in pip npm pnpm yarn; do
    mkdir -p "${PROGRAM_CACHE_DIR}/${sub}"
    chown "$user":"$user" "${PROGRAM_CACHE_DIR}/${sub}" 2>/dev/null || true
    chmod 700 "${PROGRAM_CACHE_DIR}/${sub}" 2>/dev/null || true
  done
}

sandbox_exec() {
  user="$1"; workdir="$2"; name="$3"
  shift 3
  [ $# -gt 0 ] || { echo "sandbox_exec: command missing" >&2; return 1; }

  ensure_program_dirs "$name" "$user"

  env \
    MAESTRO_SANDBOX_NAME="$name" \
    MAESTRO_SANDBOX_PROJECT="$workdir" \
    MAESTRO_SANDBOX_TMP="$PROGRAM_TMP_DIR" \
    MAESTRO_SANDBOX_CACHE="$PROGRAM_CACHE_DIR" \
    MAESTRO_SANDBOX_VENV="$PROGRAM_VENV_DIR" \
    HOME="$PROGRAM_USER_HOME" \
    PIP_INSTALL_OPTIONS="${PIP_INSTALL_OPTIONS:-}" \
    NPM_INSTALL_OPTIONS="${NPM_INSTALL_OPTIONS:-}" \
    PNPM_VERSION="${PNPM_VERSION:-}" \
    YARN_VERSION="${YARN_VERSION:-}" \
    runuser -u "$user" -- /usr/local/bin/maestro-sandbox --workdir "$workdir" -- "$@"
}

fetch_tar_into_dir() {
  url="$1"; dest="$2"; user="$3"; name="$4"
  [ -n "$url" ] || { echo "fetch_tar_into_dir: url missing" >&2; return 1; }
  [ -n "$dest" ] || { echo "fetch_tar_into_dir: dest missing" >&2; return 1; }
  [ -n "$user" ] || { echo "fetch_tar_into_dir: user missing" >&2; return 1; }
  [ -n "$name" ] || { echo "fetch_tar_into_dir: program name missing" >&2; return 1; }

  ensure_program_dirs "$name" "$user"

  mkdir -p "$dest"
  chown "$user":"$user" "$dest" 2>/dev/null || true
  chmod 750 "$dest" 2>/dev/null || true

  if ! sandbox_exec "$user" "$dest" "$name" /usr/local/lib/deploy/fetch-and-extract.sh "$url"; then
    echo "fetch_tar_into_dir: failed to retrieve $url" >&2
    return 1
  fi

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
      start_cmd=$(PACKAGE_JSON_DIR="$d" python3 <<'PY'
import json, os
dir_path = os.environ.get("PACKAGE_JSON_DIR", "")
try:
    with open(os.path.join(dir_path, "package.json"), "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print("")
else:
    scripts = data.get("scripts") or {}
    print((scripts.get("start") or "").strip())
PY
      )
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
  dir="$1"; name="$2"; user="$3"
  ensure_program_dirs "$name" "$user"
  chown -R "$user":"$user" "$dir" 2>/dev/null || true
  chmod -R 750 "$dir" 2>/dev/null || true

  if [ -f "$dir/requirements.txt" ] || [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ]; then
    sandbox_exec "$user" "$dir" "$name" /bin/sh -eu -c '
      venv="${MAESTRO_SANDBOX_VENV}"
      if [ ! -d "${venv}/bin" ]; then
        python3 -m venv "${venv}" >/dev/null 2>&1 || python3 -m venv "${venv}"
      fi
      PATH="${venv}/bin:${PATH}"
      export PATH
      install_opts="${PIP_INSTALL_OPTIONS:-}"
      if [ -f requirements.txt ]; then
        if [ -n "$install_opts" ]; then
          pip install $install_opts -r requirements.txt || pip install $install_opts . || true
        else
          pip install -r requirements.txt || pip install . || true
        fi
      elif [ -f pyproject.toml ] || [ -f setup.py ]; then
        if [ -n "$install_opts" ]; then
          pip install $install_opts . || true
        else
          pip install . || true
        fi
      fi
    '
  fi

  if [ -f "$dir/package.json" ]; then
    sandbox_exec "$user" "$dir" "$name" /bin/sh -eu -c '
      npm_flags="${NPM_INSTALL_OPTIONS:-}"
      if [ -z "$npm_flags" ]; then
        npm_flags="--omit=dev --no-audit --no-fund"
      fi
      if [ -f pnpm-lock.yaml ]; then
        pnpm_spec=""
        if [ -n "${PNPM_VERSION:-}" ]; then
          pnpm_spec="@${PNPM_VERSION}"
        fi
        (corepack enable || true)
        if ! command -v pnpm >/dev/null 2>&1; then
          corepack prepare "pnpm${pnpm_spec}" --activate || npm install --global --no-audit --no-fund --loglevel=error --unsafe-perm=false "pnpm${pnpm_spec}"
        fi
        pnpm install --frozen-lockfile --prod || pnpm install --prod || true
      elif [ -f yarn.lock ]; then
        yarn_spec=""
        if [ -n "${YARN_VERSION:-}" ]; then
          yarn_spec="@${YARN_VERSION}"
        fi
        (corepack enable || true)
        if ! command -v yarn >/dev/null 2>&1; then
          corepack prepare "yarn${yarn_spec}" --activate || npm install --global --no-audit --no-fund --loglevel=error --unsafe-perm=false "yarn${yarn_spec}"
        fi
        yarn install --frozen-lockfile --production || yarn install --production || true
      elif [ -f package-lock.json ]; then
        npm ci $npm_flags || npm install $npm_flags || true
      else
        npm install $npm_flags || true
      fi
      npm cache clean --force || true
    '
  fi
}

write_program_conf() {
  name="$1"; dir="$2"; cmd="$3"; user="$4"
  ensure_program_dirs "$name" "$user"
  quoted_cmd=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$cmd")
  quoted_workdir=$(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$dir")
  if [ -z "$quoted_cmd" ]; then
    echo "write_program_conf: failed to quote command for $name" >&2
    return 1
  fi
  if [ -z "$quoted_workdir" ]; then
    echo "write_program_conf: failed to quote workdir for $name" >&2
    return 1
  fi

  env_line=$(printf 'HOME="%s",TMPDIR="%s",XDG_CACHE_HOME="%s",MAESTRO_SANDBOX_NAME="%s",MAESTRO_SANDBOX_PROJECT="%s",MAESTRO_SANDBOX_TMP="%s",MAESTRO_SANDBOX_CACHE="%s",MAESTRO_SANDBOX_VENV="%s"' \
    "$(escape_env_value "/home/${user}")" \
    "$(escape_env_value "$PROGRAM_TMP_DIR")" \
    "$(escape_env_value "$PROGRAM_CACHE_DIR")" \
    "$(escape_env_value "$name")" \
    "$(escape_env_value "$dir")" \
    "$(escape_env_value "$PROGRAM_TMP_DIR")" \
    "$(escape_env_value "$PROGRAM_CACHE_DIR")" \
    "$(escape_env_value "$PROGRAM_VENV_DIR")")

  venv_bin="${PROGRAM_VENV_DIR}/bin"
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
    env_line="${env_line},PATH=\"$(escape_env_value "${path_prefix}:\$PATH")\""
  fi

  cat >"${SUPERVISOR_CONF_DIR}/program-${name}.conf" <<EOF
[program:${name}]
directory=${dir}
command=/usr/local/bin/maestro-sandbox --workdir ${quoted_workdir} -- /bin/sh -lc ${quoted_cmd}
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
