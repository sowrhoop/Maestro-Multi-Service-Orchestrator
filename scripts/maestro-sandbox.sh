#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: maestro-sandbox [--workdir DIR] -- COMMAND [ARG...]

Run COMMAND inside a restricted bubblewrap sandbox with a read-only system view,
per-project writable areas, offline network namespace, and resource limits.
EOF
}

log_warn() {
  printf 'maestro-sandbox: %s\n' "$*" >&2
}

bwrap_support_state="unknown"

check_bwrap_support() {
  if [[ "$bwrap_support_state" == "yes" ]]; then
    return 0
  elif [[ "$bwrap_support_state" == "no" ]]; then
    return 1
  fi

  local err
  if err=$(bwrap --ro-bind / / --dev-bind /dev/null /dev/null --proc /proc -- /bin/true 2>&1); then
    bwrap_support_state="yes"
    return 0
  else
    log_warn "bubblewrap self-test failed (${err:-unknown}); sandbox disabled for this run"
    bwrap_support_state="no"
    return 1
  fi
}

to_lower() {
  local input="${1:-}"
  printf '%s' "$input" | tr '[:upper:]' '[:lower:]'
}

to_bytes() {
  local input="${1:-}"
  if [[ -z "$input" ]]; then
    return 1
  fi
  case "$input" in
    max|MAX)
      printf 'max'
      return 0
      ;;
  esac
  local number unit value
  number="${input%[kKmMgG]}"
  if [[ "$number" == "$input" ]]; then
    unit=""
  else
    unit="${input: -1}"
  fi
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  value="$number"
  case "$unit" in
    '' ) : ;;
    k|K) value=$((number * 1024)) ;;
    m|M) value=$((number * 1024 * 1024)) ;;
    g|G) value=$((number * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
  printf '%s' "$value"
}

cg_dir=""

setup_cgroup() {
  local root base mem_raw mem_bytes cpu_quota cpu_period pids_limit
  root="${MAESTRO_CGROUP_ROOT:-/sys/fs/cgroup}"
  if [[ ! -d "$root" || ! -w "$root" ]]; then
    return 0
  fi
  base="${root%/}/maestro"
  mkdir -p "$base" 2>/dev/null || return 0

  cg_dir="${base}/${name}-$$"
  mkdir "$cg_dir" 2>/dev/null || { cg_dir=""; return 0; }
  chmod 750 "$cg_dir" 2>/dev/null || true

  mem_raw="${MAESTRO_SANDBOX_MEMORY:-512M}"
  if [[ -f "${cg_dir}/memory.max" ]]; then
    if [[ "$mem_raw" =~ ^[mM][aA][xX]$ ]]; then
      echo "max" >"${cg_dir}/memory.max" 2>/dev/null || true
    else
      if mem_bytes=$(to_bytes "$mem_raw"); then
        echo "$mem_bytes" >"${cg_dir}/memory.max" 2>/dev/null || true
      fi
    fi
  fi

  cpu_quota="${MAESTRO_SANDBOX_CPU_QUOTA_US:-100000}"
  cpu_period="${MAESTRO_SANDBOX_CPU_PERIOD_US:-100000}"
  if [[ -f "${cg_dir}/cpu.max" ]]; then
    if [[ "$cpu_quota" =~ ^[mM][aA][xX]$ ]]; then
      echo "max ${cpu_period}" >"${cg_dir}/cpu.max" 2>/dev/null || true
    elif [[ "$cpu_quota" =~ ^[0-9]+$ && "$cpu_period" =~ ^[0-9]+$ && "$cpu_period" -gt 0 ]]; then
      echo "${cpu_quota} ${cpu_period}" >"${cg_dir}/cpu.max" 2>/dev/null || true
    fi
  fi

  pids_limit="${MAESTRO_SANDBOX_PIDS_MAX:-128}"
  if [[ -f "${cg_dir}/pids.max" ]]; then
    if [[ "$pids_limit" =~ ^[0-9]+$ && "$pids_limit" -gt 0 ]]; then
      echo "$pids_limit" >"${cg_dir}/pids.max" 2>/dev/null || true
    fi
  fi

  if [[ -f "${cg_dir}/cgroup.procs" ]]; then
    echo "$$" >"${cg_dir}/cgroup.procs" 2>/dev/null || true
  fi
}

cleanup_cgroup() {
  if [[ -n "$cg_dir" && -d "$cg_dir" ]]; then
    rmdir "$cg_dir" 2>/dev/null || true
  fi
}

validate_net_allow_file() {
  local path="$1"
  allowed_hosts=""
  if [[ -z "$path" ]]; then
    log_warn "net policy 'allow' ignored (empty allow file path)"
    return 1
  fi
  if [[ ! -e "$path" ]]; then
    log_warn "net policy 'allow' ignored (no allow file at ${path})"
    return 1
  fi
  if [[ ! -r "$path" ]]; then
    log_warn "net allow file ${path} is not readable, enforcing deny"
    return 1
  fi

  local owner perms
  if ! owner=$(stat -c '%u' "$path" 2>/dev/null); then
    log_warn "unable to stat ${path}; enforcing deny"
    return 1
  fi
  if [[ "$owner" != "0" ]]; then
    log_warn "net allow file must be owned by root; enforcing deny"
    return 1
  fi

  if ! perms=$(stat -c '%a' "$path" 2>/dev/null); then
    log_warn "unable to determine permissions for ${path}; enforcing deny"
    return 1
  fi
  local len=${#perms}
  local group_digit="0"
  if (( len >= 2 )); then
    group_digit="${perms:len-2:1}"
  fi
  local other_digit="${perms:len-1:1}"

  case "$group_digit" in
    '') group_digit="0" ;;
    [0-7]) ;;
    *)
      log_warn "unexpected permission mask '${perms}' for ${path}; enforcing deny"
      return 1
      ;;
  esac
  case "$other_digit" in
    '') other_digit="0" ;;
    [0-7]) ;;
    *)
      log_warn "unexpected permission mask '${perms}' for ${path}; enforcing deny"
      return 1
      ;;
  esac

  case "$group_digit" in
    2|3|6|7)
      log_warn "net allow file must not be group writable; enforcing deny"
      return 1
      ;;
  esac
  case "$other_digit" in
    2|3|6|7)
      log_warn "net allow file must not be world writable; enforcing deny"
      return 1
      ;;
  esac

  local allow_flag
  if ! allow_flag=$(awk 'BEGIN {flag=0}
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*ALLOW_HOST_NETWORK=1([[:space:]]|$)/ {flag=1}
    END {print flag}' "$path"); then
    log_warn "unable to parse ${path}; enforcing deny"
    return 1
  fi
  if [[ "$allow_flag" != "1" ]]; then
    log_warn "net allow file does not enable host network; enforcing deny"
    return 1
  fi

  local hosts
  if ! hosts=$(awk 'BEGIN {first=1}
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*$/ {next}
    /^[[:space:]]*ALLOW_HOST_NETWORK=1([[:space:]]|$)/ {next}
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0);
      if ($0 != "") {
        if (first) { printf "%s", $0; first=0 }
        else { printf ",%s", $0 }
      }
    }' "$path"); then
    log_warn "unable to read host allow list from ${path}; enforcing deny"
    return 1
  fi

  if [[ -z "$hosts" ]]; then
    allowed_hosts="*"
  else
    allowed_hosts="$hosts"
  fi

  return 0
}

workdir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      [[ $# -ge 2 ]] || { echo "maestro-sandbox: --workdir requires a value" >&2; exit 64; }
      workdir="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "maestro-sandbox: unknown option '$1'" >&2
      exit 64
      ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "maestro-sandbox: command required" >&2
  usage
  exit 64
fi

command=("$@")
umask 0027

name="${MAESTRO_SANDBOX_NAME:-sandbox}"
project_dir="${MAESTRO_SANDBOX_PROJECT:-$workdir}"
tmp_dir="${MAESTRO_SANDBOX_TMP:-${TMPDIR:-/tmp}}"
cache_dir="${MAESTRO_SANDBOX_CACHE:-$tmp_dir/cache}"
venv_dir="${MAESTRO_SANDBOX_VENV:-}"
home_dir="${HOME:-/tmp}"
readonly DEFAULT_SANDBOX_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
sandbox_path="${PATH:-$DEFAULT_SANDBOX_PATH}"
target_user="${MAESTRO_SANDBOX_RUNAS_USER:-}"
target_uid="${MAESTRO_SANDBOX_RUNAS_UID:-}"
target_gid="${MAESTRO_SANDBOX_RUNAS_GID:-}"

if [[ -z "$target_user" ]]; then
  target_user="$(id -un 2>/dev/null || printf '%s' "")"
  target_uid="$(id -u 2>/dev/null || printf '%s' "")"
  target_gid="$(id -g 2>/dev/null || printf '%s' "")"
fi

if [[ -n "$target_user" && -z "$target_uid" ]]; then
  target_uid="$(id -u "$target_user" 2>/dev/null || printf '%s' "")"
fi
if [[ -n "$target_user" && -z "$target_gid" ]]; then
  target_gid="$(id -g "$target_user" 2>/dev/null || printf '%s' "")"
fi

if [[ -n "$target_user" && -z "$target_uid" ]]; then
  log_warn "unable to resolve uid for ${target_user}; using current user"
  target_user=""
fi
if [[ -n "$target_user" && -z "$target_gid" ]]; then
  log_warn "unable to resolve gid for ${target_user}; using current user"
  target_user=""
fi

should_drop_priv=0
current_uid=$(id -u)
if [[ -n "$target_user" && -n "$target_uid" && "$current_uid" -eq 0 && "$target_uid" != "$current_uid" ]]; then
  should_drop_priv=1
fi
if [[ "$should_drop_priv" -eq 1 ]]; then
  if ! command -v runuser >/dev/null 2>&1; then
    log_warn "runuser not available; executing sandbox payload as root"
    should_drop_priv=0
  fi
fi

use_bwrap=1
if ! command -v bwrap >/dev/null 2>&1; then
  log_warn "bubblewrap binary missing; running command without sandbox"
  use_bwrap=0
elif ! check_bwrap_support; then
  use_bwrap=0
fi

mkdir -p "$tmp_dir" "$cache_dir" >/dev/null 2>&1 || true
mkdir -p "${cache_dir}/pip" "${cache_dir}/npm" "${cache_dir}/pnpm" "${cache_dir}/yarn" >/dev/null 2>&1 || true
if [[ -n "$venv_dir" ]]; then
  mkdir -p "$venv_dir" >/dev/null 2>&1 || true
fi
if [[ -n "$project_dir" ]]; then
  mkdir -p "$project_dir" >/dev/null 2>&1 || true
fi
mkdir -p "$home_dir" >/dev/null 2>&1 || true

net_policy_raw="${MAESTRO_SANDBOX_NET_POLICY:-allow}"
net_policy=$(to_lower "$net_policy_raw")
net_allow_file="${MAESTRO_SANDBOX_NET_ALLOW_FILE:-/etc/maestro/sandbox-net-allow}"
allowed_hosts=""
case "$net_policy" in
  allow)
    if ! validate_net_allow_file "$net_allow_file"; then
      net_policy="deny"
    fi
    ;;
  deny|loopback|'')
    net_policy="deny"
    ;;
  *)
    log_warn "unknown MAESTRO_SANDBOX_NET_POLICY='${net_policy_raw}' (using deny)"
    net_policy="deny"
    ;;
esac

printf -v quoted_cmd '%q ' "${command[@]}"
exec_cmd="${quoted_cmd% }"

if [[ "$use_bwrap" -eq 0 ]]; then
  log_warn "maestro-sandbox operating without isolation"

  if [[ -n "$home_dir" ]]; then export HOME="$home_dir"; fi
  if [[ -n "$tmp_dir" ]]; then export TMPDIR="$tmp_dir"; fi
  if [[ -n "$cache_dir" ]]; then export XDG_CACHE_HOME="$cache_dir"; fi
  export PIP_CACHE_DIR="${cache_dir}/pip"
  export NPM_CONFIG_CACHE="${cache_dir}/npm"
  export YARN_CACHE_FOLDER="${cache_dir}/yarn"
  export PNPM_HOME="${cache_dir}/pnpm"
  export MAESTRO_SANDBOX=1
  export MAESTRO_SANDBOX_NAME="$name"
  if [[ -n "$allowed_hosts" ]]; then export MAESTRO_SANDBOX_NET_ALLOW_LIST="$allowed_hosts"; fi

  if [[ -n "$venv_dir" ]]; then
    export VIRTUAL_ENV="$venv_dir"
    export PATH="$venv_dir/bin:$sandbox_path"
  else
    export PATH="$sandbox_path"
  fi

  if [[ -n "$target_user" ]]; then
    export USER="$target_user"
    export LOGNAME="$target_user"
  fi

  if [[ "$should_drop_priv" -eq 1 ]]; then
    exec runuser -u "$target_user" -- /bin/sh -c "$exec_cmd"
  else
    exec /bin/sh -c "$exec_cmd"
  fi
fi

declare -a args
args=(bwrap --die-with-parent --unshare-pid --unshare-ipc --proc /proc)

if [[ "$net_policy" != "allow" ]]; then
  args+=(--unshare-net)
fi

# Minimal device nodes
args+=(--dev-bind /dev/null /dev/null --dev-bind /dev/urandom /dev/urandom)

ro_bind_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    args+=(--ro-bind "$path" "$path")
  fi
}

bind_if_exists() {
  local path="$1"
  if [[ -e "$path" ]]; then
    args+=(--bind "$path" "$path")
  fi
}

ro_bind_if_exists /usr
ro_bind_if_exists /bin
ro_bind_if_exists /sbin
ro_bind_if_exists /lib
ro_bind_if_exists /lib64
ro_bind_if_exists /lib32
ro_bind_if_exists /etc

if [[ -d /opt ]]; then
  args+=(--ro-bind /opt /opt)
fi

bind_if_exists "$home_dir"

if [[ -n "$project_dir" ]]; then
  bind_if_exists "$project_dir"
fi

if [[ -n "$venv_dir" ]]; then
  bind_if_exists "$venv_dir"
fi

if [[ -n "$tmp_dir" ]]; then
  bind_if_exists "$tmp_dir"
  args+=(--bind "$tmp_dir" /tmp)
else
  args+=(--tmpfs /tmp)
fi

if [[ -n "$cache_dir" ]]; then
  bind_if_exists "$cache_dir"
fi

# Lightweight runtime dirs
args+=(--tmpfs /run --tmpfs /var/tmp)

if [[ -n "$workdir" ]]; then
  args+=(--chdir "$workdir")
fi

args+=(
  --setenv HOME "$home_dir"
  --setenv TMPDIR "$tmp_dir"
  --setenv XDG_CACHE_HOME "$cache_dir"
  --setenv PIP_CACHE_DIR "${cache_dir}/pip"
  --setenv NPM_CONFIG_CACHE "${cache_dir}/npm"
  --setenv YARN_CACHE_FOLDER "${cache_dir}/yarn"
  --setenv PNPM_HOME "${cache_dir}/pnpm"
  --setenv MAESTRO_SANDBOX 1
  --setenv MAESTRO_SANDBOX_NAME "$name"
  --setenv PATH "$sandbox_path"
)

if [[ -n "$venv_dir" ]]; then
  args+=(--setenv VIRTUAL_ENV "$venv_dir")
  args+=(--setenv PATH "$venv_dir/bin:$sandbox_path")
fi

if [[ -n "$allowed_hosts" ]]; then
  args+=(--setenv MAESTRO_SANDBOX_NET_ALLOW_LIST "$allowed_hosts")
fi

if [[ -n "$target_user" ]]; then
  args+=(--setenv USER "$target_user")
  args+=(--setenv LOGNAME "$target_user")
fi

setup_cgroup
trap cleanup_cgroup EXIT

wrapper_init="ip link set lo up >/dev/null 2>&1 || true"
if [[ "$should_drop_priv" -eq 1 ]]; then
  run_line=$(printf 'runuser -u %q -- %s' "$target_user" "$exec_cmd")
else
  run_line="$exec_cmd"
fi
wrapper="${wrapper_init}; exec ${run_line}"

args+=(-- /bin/sh -c "$wrapper")

set +e
"${args[@]}"
status=$?
set -e

exit "$status"
