#!/usr/bin/env sh
set -eu

. /usr/local/lib/deploy/lib-deploy.sh

SUPERVISOR_CONF_DIR=${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}
SUPERVISORCTL_BIN=${SUPERVISORCTL_BIN:-supervisorctl}

usage() {
  cat <<'USAGE'
Usage: remove-service <name> [--conf-only] [--purge] [--delete-user] [--dry-run]

Removes a Supervisor-managed project by program <name>.

Options:
  --conf-only   Remove Supervisor program and reload only (default)
  --purge       Remove program config plus project runtime, caches, venvs, and logs
  --delete-user Delete the project's UNIX user (if it looks like svc_<name>) and its home
  --dry-run     Print actions without executing
USAGE
}

[ $# -ge 1 ] || { usage; exit 1; }
NAME="$1"; shift || true
PURGE=0
DELUSER=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --conf-only) PURGE=0 ;;
    --purge) PURGE=1 ;;
    --delete-user) DELUSER=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift || true
done

case "$NAME" in
  ''|.|..|*/*)
    maestro_log_error "Invalid program name '${NAME}'"
    exit 1
    ;;
esac

quote_arg() {
  arg=$1
  case "$arg" in
    ''|*[!A-Za-z0-9_./:-]*)
      printf "'%s'" "$(printf "%s" "$arg" | sed "s/'/'\\\\''/g")"
      ;;
    *)
      printf "%s" "$arg"
      ;;
  esac
}

print_cmd() {
  printf '+'
  for part in "$@"; do
    printf ' '
    quote_arg "$part"
  done
  printf '\n'
}

run_cmd() {
  if [ $DRY -eq 1 ]; then
    print_cmd "$@"
    return 0
  fi
  "$@"
}

supervisorctl_available_flag=0
if command -v "$SUPERVISORCTL_BIN" >/dev/null 2>&1; then
  supervisorctl_available_flag=1
fi

supervisorctl_quiet() {
  cmd="$1"; shift
  if [ $supervisorctl_available_flag -ne 1 ]; then
    return 127
  fi
  if [ $DRY -eq 1 ]; then
    print_cmd "$SUPERVISORCTL_BIN" "$cmd" "$@"
    return 0
  fi
  "$SUPERVISORCTL_BIN" "$cmd" "$@" >/dev/null 2>&1
}

supervisorctl_show() {
  if [ $supervisorctl_available_flag -ne 1 ]; then
    return 127
  fi
  if [ $DRY -eq 1 ]; then
    print_cmd "$SUPERVISORCTL_BIN" "$@"
    return 0
  fi
  "$SUPERVISORCTL_BIN" "$@" || return $?
}

resolve_user_home() {
  user="$1"
  [ -n "$user" ] || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  if home=$(python3 -c 'import pwd, sys
try:
    print(pwd.getpwnam(sys.argv[1]).pw_dir)
except KeyError:
    raise SystemExit(1)
' "$user" 2>/dev/null); then
    home_trimmed=$(printf '%s' "$home" | tr -d '\n')
    if [ -n "$home_trimmed" ]; then
      printf '%s\n' "$home_trimmed"
      return 0
    fi
  fi
  return 1
}

normalize_path() {
  path="$1"
  trimmed=$(printf '%s' "$path" | sed 's://*:/:g; s:/*$::')
  [ -n "$trimmed" ] || return 1
  printf '%s\n' "$trimmed"
}

is_safe_purge_path() {
  path="$1"
  case "$path" in
    ''|/|.|..)
      return 1
      ;;
  esac
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    */../*|*/..|../*)
      return 1
      ;;
  esac
  return 0
}

PURGE_TARGETS=""

add_purge_target() {
  candidate="$1"
  [ -n "$candidate" ] || return 1
  if ! normalized=$(normalize_path "$candidate" 2>/dev/null); then
    return 1
  fi
  if ! is_safe_purge_path "$normalized"; then
    maestro_log_warn "Skipping purge target ${normalized} (unsafe path)"
    return 1
  fi
  if [ -z "$PURGE_TARGETS" ]; then
    PURGE_TARGETS="$normalized"
    return 0
  fi
  if printf '%s\n' "$PURGE_TARGETS" | grep -Fx "$normalized" >/dev/null 2>&1; then
    return 0
  fi
  PURGE_TARGETS=$(printf '%s\n%s' "$PURGE_TARGETS" "$normalized")
}

CONF="${SUPERVISOR_CONF_DIR}/program-${NAME}.conf"
if [ ! -f "$CONF" ]; then
  maestro_log_warn "No program conf found for '${NAME}' at ${CONF}"
fi

DELIM=$(printf '\037')
USER_FROM_CONF=""
DIR_FROM_CONF=""
CMD_FROM_CONF=""
STDOUT_LOG_FROM_CONF=""
STDERR_LOG_FROM_CONF=""

if [ -f "$CONF" ]; then
  OLDIFS=$IFS
  IFS=$DELIM read -r USER_FROM_CONF DIR_FROM_CONF CMD_FROM_CONF STDOUT_LOG_FROM_CONF STDERR_LOG_FROM_CONF <<EOF
$(python3 - "$CONF" <<'PY'
import sys, configparser, shlex

DELIM = "\x1f"
path = sys.argv[1]
parser = configparser.RawConfigParser()
parser.optionxform = str
try:
    parser.read(path)
except Exception:
    parser = None

user = directory = command = stdout_logfile = stderr_logfile = ''
if parser and parser.sections():
    section = parser.sections()[0]
    user = parser.get(section, 'user', fallback='')
    directory = parser.get(section, 'directory', fallback='')
    stdout_logfile = parser.get(section, 'stdout_logfile', fallback='')
    stderr_logfile = parser.get(section, 'stderr_logfile', fallback='')
    command_raw = parser.get(section, 'command', fallback='')
    try:
        tokens = shlex.split(command_raw)
    except ValueError:
        tokens = []
    if len(tokens) >= 3 and tokens[0].endswith('/sh') and tokens[1] in ('-c', '-lc'):
        command = tokens[2]
    elif tokens and tokens[0].endswith('maestro-sandbox') and '--' in tokens:
        sep = tokens.index('--')
        tail = tokens[sep + 1 :]
        if len(tail) >= 3 and tail[0].endswith('/sh') and tail[1] in ('-c', '-lc'):
            command = tail[2]
        else:
            command = command_raw
    else:
        command = command_raw
print(DELIM.join([user, directory, command, stdout_logfile, stderr_logfile]))
PY
)
EOF
  IFS=$OLDIFS
fi

DEFAULT_USER="svc_${NAME}"
SERVICE_USER=${USER_FROM_CONF:-$DEFAULT_USER}
SERVICE_HOME=""
if SERVICE_HOME=$(resolve_user_home "$SERVICE_USER" 2>/dev/null); then
  : # resolved successfully
else
  SERVICE_HOME=""
fi

if [ -n "$SERVICE_HOME" ]; then
  program_paths "$NAME" "$SERVICE_USER" "$SERVICE_HOME"
else
  program_paths "$NAME" "$SERVICE_USER"
fi

if [ $supervisorctl_available_flag -ne 1 ]; then
  maestro_log_warn "supervisorctl (${SUPERVISORCTL_BIN}) not found; Supervisor actions will be skipped"
fi

maestro_log_info "Stopping ${NAME} (if running)"
if ! supervisorctl_quiet stop "$NAME"; then
  if [ $DRY -eq 0 ] && [ $supervisorctl_available_flag -eq 1 ]; then
    maestro_log_debug "Supervisor reported ${NAME} as already stopped or absent"
  fi
fi

if [ -f "$CONF" ]; then
  maestro_log_info "Removing program conf: ${CONF}"
  if ! run_cmd rm -f -- "$CONF"; then
    if [ $DRY -eq 0 ]; then
      maestro_log_error "Failed to remove ${CONF}"
      exit 1
    fi
  fi
fi

maestro_log_info "Reloading Supervisor"
if ! supervisorctl_quiet reread; then
  if [ $DRY -eq 0 ] && [ $supervisorctl_available_flag -eq 1 ]; then
    maestro_log_warn "supervisorctl reread failed"
  fi
fi
if ! supervisorctl_quiet update; then
  if [ $DRY -eq 0 ] && [ $supervisorctl_available_flag -eq 1 ]; then
    maestro_log_warn "supervisorctl update failed"
  fi
fi

if [ $PURGE -eq 1 ]; then
  DIR_DEFAULT="/opt/projects/${NAME}"
  LEGACY_VENV="/opt/venv-${NAME}"
  LEGACY_TMP="/tmp/${NAME}-tmp"
  LEGACY_CACHE="/tmp/${NAME}-cache"

  add_purge_target "$DIR_DEFAULT"
  [ -n "$DIR_FROM_CONF" ] && add_purge_target "$DIR_FROM_CONF"
  add_purge_target "$LEGACY_VENV"
  add_purge_target "$LEGACY_TMP"
  add_purge_target "$LEGACY_CACHE"
  add_purge_target "${PROGRAM_RUNTIME_DIR:-}"
  add_purge_target "${PROGRAM_TMP_DIR:-}"
  add_purge_target "${PROGRAM_CACHE_DIR:-}"
  add_purge_target "${PROGRAM_VENV_DIR:-}"
  [ -n "$STDOUT_LOG_FROM_CONF" ] && add_purge_target "$STDOUT_LOG_FROM_CONF"
  [ -n "$STDERR_LOG_FROM_CONF" ] && add_purge_target "$STDERR_LOG_FROM_CONF"

  if [ -n "$PURGE_TARGETS" ]; then
    maestro_log_info "Purging ${NAME} assets"
    printf '%s\n' "$PURGE_TARGETS" | while IFS= read -r target; do
      [ -n "$target" ] || continue
      maestro_log_debug "Purging ${target}"
      if ! run_cmd rm -rf -- "$target"; then
        if [ $DRY -eq 0 ]; then
          maestro_log_warn "Failed to purge ${target}"
        fi
      fi
    done
  else
    maestro_log_info "No purge targets identified for ${NAME}"
  fi
fi

if [ $DELUSER -eq 1 ]; then
  USER_CANDIDATE="${USER_FROM_CONF:-svc_${NAME}}"
  case "$USER_CANDIDATE" in
    svc_*|${NAME}|svc_${NAME})
      if id -u "$USER_CANDIDATE" >/dev/null 2>&1; then
        maestro_log_info "Deleting user: ${USER_CANDIDATE} (and home)"
        if ! run_cmd userdel -r "$USER_CANDIDATE"; then
          if [ $DRY -eq 0 ]; then
            maestro_log_warn "userdel failed for ${USER_CANDIDATE}"
          fi
        fi
      else
        maestro_log_debug "User ${USER_CANDIDATE} not present; skipping deletion"
      fi
      ;;
    *)
      maestro_log_warn "Refusing to delete non-project user '${USER_CANDIDATE}'"
      ;;
  esac
fi

if [ $DRY -eq 1 ]; then
  maestro_log_info "[dry-run] Would remove service port reservation for ${NAME}"
else
  remove_service_port "$NAME" || true
fi

if [ $DRY -eq 1 ]; then
  maestro_log_info "[dry-run] Would refresh firewall rules"
else
  apply_firewall_rules || true
fi

maestro_log_info "Removal workflow complete for ${NAME}"

if [ $supervisorctl_available_flag -eq 1 ]; then
  maestro_log_info "Current Supervisor programs:"
  supervisorctl_show status || true
fi
