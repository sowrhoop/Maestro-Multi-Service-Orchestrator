#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: maestro-sandbox [--workdir DIR] -- COMMAND [ARG...]

Run COMMAND inside a restricted bubblewrap sandbox with a read-only system view,
per-project writable areas, offline network namespace, and resource limits.
EOF
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

if ! command -v bwrap >/dev/null 2>&1; then
  echo "maestro-sandbox: bubblewrap not available" >&2
  exit 127
fi

command=("$@")
umask 0027

name="${MAESTRO_SANDBOX_NAME:-sandbox}"
project_dir="${MAESTRO_SANDBOX_PROJECT:-$workdir}"
tmp_dir="${MAESTRO_SANDBOX_TMP:-${TMPDIR:-/tmp}}"
cache_dir="${MAESTRO_SANDBOX_CACHE:-$tmp_dir/cache}"
venv_dir="${MAESTRO_SANDBOX_VENV:-}"
home_dir="${HOME:-/tmp}"

mkdir -p "$tmp_dir" "$cache_dir" >/dev/null 2>&1 || true
mkdir -p "${cache_dir}/pip" "${cache_dir}/npm" "${cache_dir}/pnpm" "${cache_dir}/yarn" >/dev/null 2>&1 || true
if [[ -n "$venv_dir" ]]; then
  mkdir -p "$venv_dir" >/dev/null 2>&1 || true
fi
if [[ -n "$project_dir" ]]; then
  mkdir -p "$project_dir" >/dev/null 2>&1 || true
fi
mkdir -p "$home_dir" >/dev/null 2>&1 || true

net_policy="${MAESTRO_SANDBOX_NET_POLICY:-deny}"
net_allow_file="${MAESTRO_SANDBOX_NET_ALLOW_FILE:-/etc/maestro/sandbox-net-allow}"
allowed_hosts=""
case "$net_policy" in
  allow)
    if [[ ! -r "$net_allow_file" ]]; then
      echo "maestro-sandbox: net policy 'allow' ignored (no allow file at ${net_allow_file})" >&2
      net_policy="deny"
    else
      perms=$(stat -c '%a' "$net_allow_file" 2>/dev/null || echo "")
      owner=$(stat -c '%u' "$net_allow_file" 2>/dev/null || echo "")
      if [[ "$owner" != "0" ]]; then
        echo "maestro-sandbox: net allow file must be owned by root; enforcing deny" >&2
        net_policy="deny"
      else
        group_digit="${perms: -2:1}"
        other_digit="${perms: -1}"
        if [[ "$group_digit" =~ [2367] || "$other_digit" =~ [2367] ]]; then
          echo "maestro-sandbox: net allow file must not be group/world writable; enforcing deny" >&2
          net_policy="deny"
        else
          allow_flag=$(awk 'BEGIN{f=0} /^[[:space:]]*#/ {next} /^[[:space:]]*ALLOW_HOST_NETWORK=1([[:space:]]|$)/ {f=1} END{print f}' "$net_allow_file" 2>/dev/null)
          if [[ "$allow_flag" != "1" ]]; then
            echo "maestro-sandbox: net allow file does not enable host network; enforcing deny" >&2
            net_policy="deny"
          else
            allowed_hosts=$(awk 'BEGIN{first=1}
              /^[[:space:]]*#/ {next}
              /^[[:space:]]*$/ {next}
              /^[[:space:]]*ALLOW_HOST_NETWORK=1/ {next}
              {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0);
                if ($0 != "") {
                  if (first) { printf "%s", $0; first=0 }
                  else { printf ",%s", $0 }
                }
              }' "$net_allow_file" 2>/dev/null)
            if [[ -z "$allowed_hosts" ]]; then
              allowed_hosts="*"
            fi
          fi
        fi
      else
        :
      fi
    fi
    ;;
  deny|loopback|'')
    net_policy="deny"
    ;;
  *)
    echo "maestro-sandbox: unknown MAESTRO_SANDBOX_NET_POLICY='${net_policy}', defaulting to deny" >&2
    net_policy="deny"
    ;;
esac

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
  --setenv PATH "${PATH:-/usr/bin}"
)

if [[ -n "$venv_dir" ]]; then
  args+=(--setenv VIRTUAL_ENV "$venv_dir")
  args+=(--setenv PATH "$venv_dir/bin:${PATH:-/usr/bin}")
fi

if [[ -n "$allowed_hosts" ]]; then
  args+=(--setenv MAESTRO_SANDBOX_NET_ALLOW_LIST "$allowed_hosts")
fi

setup_cgroup
trap cleanup_cgroup EXIT

printf -v quoted_cmd '%q ' "${command[@]}"
wrapper_init="ip link set lo up >/dev/null 2>&1 || true"
wrapper="${wrapper_init}; exec ${quoted_cmd% }"

args+=(-- /bin/sh -c "$wrapper")

set +e
"${args[@]}"
status=$?
set -e

exit "$status"
