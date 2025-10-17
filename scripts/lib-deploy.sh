#!/usr/bin/env sh
# Shared helpers for provisioning projects under Supervisor
set -eu

SUPERVISOR_CONF_DIR=${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}
PORT_LEDGER=${MAESTRO_PORT_LEDGER:-/run/maestro/ports.csv}
IPTABLES_CMD=${MAESTRO_IPTABLES_BIN:-iptables}
MAESTRO_RESERVED_PORTS=${MAESTRO_RESERVED_PORTS:-}
export MAESTRO_RESERVED_PORTS

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
  name="$1"; user="$2"; home_override="${3:-}"
  if [ -n "$home_override" ]; then
    PROGRAM_USER_HOME="$home_override"
  else
    PROGRAM_USER_HOME="/home/${user}"
  fi
  base="${PROGRAM_USER_HOME}/.maestro"
  PROGRAM_RUNTIME_DIR="${base}/runtime/${name}"
  PROGRAM_TMP_DIR="${base}/tmp/${name}"
  PROGRAM_CACHE_DIR="${base}/cache/${name}"
  PROGRAM_VENV_DIR="${base}/venvs/${name}"
}

ensure_port_ledger() {
  ledger="$PORT_LEDGER"
  if [ -z "$ledger" ]; then
    return 0
  fi
  case "$ledger" in
    */*)
      ledger_dir=${ledger%/*}
      ;;
    *)
      ledger_dir="."
      ;;
  esac
  if [ -n "$ledger_dir" ] && [ "$ledger_dir" != "$ledger" ]; then
    mkdir -p "$ledger_dir" 2>/dev/null || true
    chmod 700 "$ledger_dir" 2>/dev/null || true
  fi
  if [ ! -f "$ledger" ]; then
    touch "$ledger" 2>/dev/null || true
    chmod 600 "$ledger" 2>/dev/null || true
  fi
}

register_service_port() {
  name="$1"
  port="$2"
  case "$port" in
    ''|*[!0-9]*)
      return 0
      ;;
  esac
  ensure_port_ledger
  ledger="$PORT_LEDGER"
  tmp="${ledger}.tmp.$$"
  if ! tmp=$(mktemp "${ledger}.XXXXXX" 2>/dev/null); then
    return 0
  fi
  if [ -f "$ledger" ]; then
    awk -F'|' -v key="$name" 'NF>=2 && $1 != key {print $0}' "$ledger" >"$tmp"
  fi
  printf '%s|%s\n' "$name" "$port" >>"$tmp"
  mv "$tmp" "$ledger"
  chmod 600 "$ledger" 2>/dev/null || true
  maestro_reserve_port "$port" >/dev/null 2>&1 || true
}

remove_service_port() {
  name="$1"
  ledger="$PORT_LEDGER"
  [ -f "$ledger" ] || return 0
  if ! tmp=$(mktemp "${ledger}.XXXXXX" 2>/dev/null); then
    return 0
  fi
  awk -F'|' -v key="$name" 'NF>=2 && $1 != key {print $0}' "$ledger" >"$tmp"
  mv "$tmp" "$ledger"
  chmod 600 "$ledger" 2>/dev/null || true
}

list_registered_ports() {
  ledger="$PORT_LEDGER"
  [ -f "$ledger" ] || return 0
  awk -F'|' 'NF>=2 && $2 ~ /^[0-9]+$/ {print $2}' "$ledger" | sort -n | uniq
}

maestro_validate_port() {
  name="$1"; value="$2"
  case "$value" in
    ''|*[!0-9]*)
      printf '%s\n' "maestro: ${name} (${value}) must be an integer" >&2
      return 1
      ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    printf '%s\n' "maestro: ${name} (${value}) must be between 1 and 65535" >&2
    return 1
  fi
  return 0
}

maestro_collect_used_ports() {
  ensured=$(list_registered_ports 2>/dev/null || true)
  combined="${MAESTRO_RESERVED_PORTS:-}"
  if [ -n "$ensured" ]; then
    combined="$(printf '%s %s' "$combined" "$ensured" | tr -s ' ')"
  fi
  printf '%s' "$combined" | tr -s ' ' ' '
}

maestro_find_free_port() {
  used_input=$(printf '%s' "${1:-}" | tr -s ' ' ',')
  python3 - "$used_input" <<'PY'
import socket, sys

raw = sys.argv[1] if len(sys.argv) > 1 else ""
used = set()
for piece in raw.split(","):
    piece = piece.strip()
    if not piece:
        continue
    try:
        used.add(int(piece))
    except ValueError:
        continue

attempts = 0
while attempts < 100:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("0.0.0.0", 0))
        port = sock.getsockname()[1]
    if port not in used:
        print(port)
        sys.exit(0)
    attempts += 1

print("")
PY
}

maestro_reserve_port() {
  port="$1"
  [ -n "$port" ] || return 1
  case " ${MAESTRO_RESERVED_PORTS:-} " in
    *" ${port} "* ) return 0 ;;
  esac
  if [ -z "${MAESTRO_RESERVED_PORTS:-}" ]; then
    MAESTRO_RESERVED_PORTS="$port"
  else
    MAESTRO_RESERVED_PORTS="${MAESTRO_RESERVED_PORTS} ${port}"
  fi
  export MAESTRO_RESERVED_PORTS
}

maestro_resolve_port() {
  requested="$1"
  case "$requested" in
    '' ) : ;;
    0 ) requested="";;
  esac
  requested=$(printf '%s' "$requested" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  used=$(maestro_collect_used_ports)
  if [ -n "$requested" ]; then
    if ! maestro_validate_port "PORT" "$requested"; then
      return 1
    fi
    case " ${used} " in
      *" ${requested} "* )
        printf '%s\n' "maestro: port ${requested} already in use" >&2
        return 1
        ;;
    esac
    maestro_reserve_port "$requested"
    printf '%s' "$requested"
    return 0
  fi
  candidate=$(maestro_find_free_port "$used")
  if [ -z "$candidate" ]; then
    printf '%s\n' "maestro: unable to auto-select a free port" >&2
    return 1
  fi
  maestro_reserve_port "$candidate"
  printf '%s' "$candidate"
}

apply_firewall_rules() {
  if [ "${MAESTRO_FIREWALL_DISABLE:-0}" = "1" ]; then
    return 0
  fi
  if ! command -v "$IPTABLES_CMD" >/dev/null 2>&1; then
    printf '%s\n' "maestro: ${IPTABLES_CMD} not available; skipping firewall rule update" >&2
    return 0
  fi
  ensure_port_ledger

  chain="MAESTRO_INPUT"
  cmd="$IPTABLES_CMD -w"
  if ! $cmd -L "$chain" >/dev/null 2>&1; then
    if ! $cmd -N "$chain" >/dev/null 2>&1; then
      printf '%s\n' "maestro: unable to create ${chain} chain with ${IPTABLES_CMD}" >&2
      return 0
    fi
  fi
  if ! $cmd -F "$chain" >/dev/null 2>&1; then
    printf '%s\n' "maestro: unable to flush ${chain} chain; firewall rules unchanged" >&2
    return 0
  fi
  $cmd -A "$chain" -i lo -j ACCEPT >/dev/null 2>&1 || true
  $cmd -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || true
  ports=$(list_registered_ports || true)
  for port in $ports; do
    $cmd -A "$chain" -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
    $cmd -A "$chain" -p udp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
  done
  $cmd -A "$chain" -j DROP >/dev/null 2>&1 || true
  if ! $cmd -C INPUT -j "$chain" >/dev/null 2>&1; then
    $cmd -I INPUT 1 -j "$chain" >/dev/null 2>&1 || true
  fi
}

ensure_program_dirs() {
  name="$1"; user="$2"
  program_paths "$name" "$user"

  local failed=0

  for dir in "$PROGRAM_RUNTIME_DIR" "$PROGRAM_TMP_DIR" "$PROGRAM_CACHE_DIR" "$PROGRAM_VENV_DIR"; do
    mkdir -p "$dir"
    if ! chown "$user":"$user" "$dir" 2>/dev/null; then
      failed=1
    fi
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
    if ! chown "$user":"$user" "${PROGRAM_CACHE_DIR}/${sub}" 2>/dev/null; then
      failed=1
    fi
    chmod 700 "${PROGRAM_CACHE_DIR}/${sub}" 2>/dev/null || true
  done

  if [ "$failed" -eq 0 ] && command -v runuser >/dev/null 2>&1; then
    if ! runuser -u "$user" -- test -w "$PROGRAM_TMP_DIR" 2>/dev/null; then
      failed=1
    fi
  fi

  if [ "$failed" -eq 0 ]; then
    return 0
  fi

  # Fallback: use root-owned directories under /tmp so provisioning still works
  fallback_root="${MAESTRO_RUNTIME_FALLBACK_BASE:-/tmp/maestro-fallback}"
  [ -n "$fallback_root" ] || fallback_root="/tmp/maestro-fallback"
  fallback_home="${fallback_root}/${user:-root}"
  echo "ensure_program_dirs: using fallback workspace ${fallback_home}" >&2
  program_paths "$name" "$user" "$fallback_home"
  mkdir -p "$fallback_home" 2>/dev/null || true
  chmod 755 "$fallback_home" 2>/dev/null || true

  for dir in "$PROGRAM_RUNTIME_DIR" "$PROGRAM_TMP_DIR" "$PROGRAM_CACHE_DIR" "$PROGRAM_VENV_DIR"; do
    mkdir -p "$dir"
    chmod 755 "$dir" 2>/dev/null || true
  done
  for sub in pip npm pnpm yarn; do
    mkdir -p "${PROGRAM_CACHE_DIR}/${sub}"
    chmod 755 "${PROGRAM_CACHE_DIR}/${sub}" 2>/dev/null || true
  done

  return 1
}

sandbox_exec() {
  user="$1"; workdir="$2"; name="$3"
  shift 3
  [ $# -gt 0 ] || { echo "sandbox_exec: command missing" >&2; return 1; }

  if ! ensure_program_dirs "$name" "$user"; then
    echo "sandbox_exec: unable to assign ownership of runtime directories to $user; running without user drop" >&2
    user=""
  fi

  target_user="$user"
  target_uid=""
  target_gid=""

  if [ -n "$target_user" ]; then
    if ! target_uid=$(id -u "$target_user" 2>/dev/null); then
      echo "sandbox_exec: unable to resolve uid for $target_user; running without user drop" >&2
      target_user=""
    fi
  fi
  if [ -n "$target_user" ]; then
    if ! target_gid=$(id -g "$target_user" 2>/dev/null); then
      echo "sandbox_exec: unable to resolve gid for $target_user; running without user drop" >&2
      target_user=""
    fi
  fi

  env \
    MAESTRO_SANDBOX_NAME="$name" \
    MAESTRO_SANDBOX_PROJECT="$workdir" \
    MAESTRO_SANDBOX_TMP="$PROGRAM_TMP_DIR" \
    MAESTRO_SANDBOX_CACHE="$PROGRAM_CACHE_DIR" \
    MAESTRO_SANDBOX_VENV="$PROGRAM_VENV_DIR" \
    MAESTRO_SANDBOX_RUNAS_USER="${target_user:-}" \
    MAESTRO_SANDBOX_RUNAS_UID="${target_uid:-}" \
    MAESTRO_SANDBOX_RUNAS_GID="${target_gid:-}" \
    HOME="$PROGRAM_USER_HOME" \
    PIP_INSTALL_OPTIONS="${PIP_INSTALL_OPTIONS:-}" \
    NPM_INSTALL_OPTIONS="${NPM_INSTALL_OPTIONS:-}" \
    PNPM_VERSION="${PNPM_VERSION:-}" \
    YARN_VERSION="${YARN_VERSION:-}" \
    /usr/local/bin/maestro-sandbox --workdir "$workdir" -- "$@"
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
    "$(escape_env_value "$PROGRAM_USER_HOME")" \
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

  append_env() {
    key="$1"; value="$2"
    if [ -n "$value" ]; then
      env_line="${env_line},${key}=\"$(escape_env_value "$value")\""
    fi
  }

  append_env MAESTRO_SANDBOX_MEMORY "${MAESTRO_SANDBOX_MEMORY:-}"
  append_env MAESTRO_SANDBOX_CPU_QUOTA_US "${MAESTRO_SANDBOX_CPU_QUOTA_US:-}"
  append_env MAESTRO_SANDBOX_CPU_PERIOD_US "${MAESTRO_SANDBOX_CPU_PERIOD_US:-}"
  append_env MAESTRO_SANDBOX_PIDS_MAX "${MAESTRO_SANDBOX_PIDS_MAX:-}"
  append_env MAESTRO_SANDBOX_NET_POLICY "${MAESTRO_SANDBOX_NET_POLICY:-}"
  append_env MAESTRO_SANDBOX_NET_ALLOW_FILE "${MAESTRO_SANDBOX_NET_ALLOW_FILE:-}"
  append_env MAESTRO_CGROUP_ROOT "${MAESTRO_CGROUP_ROOT:-}"

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
