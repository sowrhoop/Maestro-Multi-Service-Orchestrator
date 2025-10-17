#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: maestro-sandbox [--workdir DIR] -- COMMAND [ARG...]

Run COMMAND inside a restricted bubblewrap sandbox with read-only system
mounts and writable project/cache/tmp directories derived from the current
user context. Set MAESTRO_SANDBOX_DISABLE=1 to bypass the sandbox.
EOF
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

if [[ "${MAESTRO_SANDBOX_DISABLE:-0}" == "1" ]]; then
  exec "$@"
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

declare -a args
args=(bwrap --die-with-parent --unshare-pid --unshare-ipc --proc /proc)

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

args+=(--)

exec "${args[@]}" "${command[@]}"
