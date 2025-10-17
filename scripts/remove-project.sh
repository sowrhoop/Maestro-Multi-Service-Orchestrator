#!/usr/bin/env sh
set -eu

. /usr/local/lib/deploy/lib-deploy.sh

SUPERVISOR_CONF_DIR=${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}

usage() {
  cat <<USAGE
Usage: remove-service <name> [--conf-only] [--purge] [--delete-user] [--dry-run]

Removes a Supervisor-managed project by program <name>.

Options:
  --conf-only   Remove Supervisor program and reload only (default)
  --purge       Also remove source dir (/opt/projects/<name>), venv (/opt/venv-<name>), and tmp/cache
  --delete-user Delete the project's UNIX user (if it looks like svc_<name>) and its home
  --dry-run     Print actions without executing
USAGE
}

[ $# -ge 1 ] || { usage; exit 1; }
NAME="$1"; shift || true
CONF_ONLY=1
PURGE=0
DELUSER=0
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --conf-only) CONF_ONLY=1 ;;
    --purge) PURGE=1; CONF_ONLY=0 ;;
    --delete-user) DELUSER=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift || true
done

CONF="${SUPERVISOR_CONF_DIR}/program-${NAME}.conf"
if [ ! -f "$CONF" ]; then
  echo "No program conf found for '${NAME}' at $CONF" >&2
fi

# Extract attributes before removing conf
USER_FROM_CONF=""
DIR_FROM_CONF=""
CMD_FROM_CONF=""
if [ -f "$CONF" ]; then
  IFS='|' read -r USER_FROM_CONF DIR_FROM_CONF CMD_FROM_CONF <<EOF
$(python3 - "$CONF" <<'PY'
import sys, configparser, shlex
path = sys.argv[1]
parser = configparser.RawConfigParser()
parser.optionxform = str
try:
    parser.read(path)
except Exception:
    parser = None

user = directory = command = ''
if parser and parser.sections():
    section = parser.sections()[0]
    user = parser.get(section, 'user', fallback='')
    directory = parser.get(section, 'directory', fallback='')
    command_raw = parser.get(section, 'command', fallback='')
    try:
        tokens = shlex.split(command_raw)
    except ValueError:
        tokens = []
    if len(tokens) >= 3 and tokens[0] == '/bin/sh' and tokens[1] == '-c':
        command = tokens[2]
    else:
        command = command_raw
print(f"{user}|{directory}|{command}")
PY
)
EOF
  IFS=$(printf ' \t\n')
fi

run() { [ $DRY -eq 1 ] && echo "+ $*" || sh -c "$*"; }

echo "Stopping ${NAME} (if running)"
run "supervisorctl stop ${NAME} >/dev/null 2>&1 || true"

if [ -f "$CONF" ]; then
  echo "Removing program conf: $CONF"
  run "rm -f '$CONF'"
fi

echo "Reloading Supervisor"
run "supervisorctl reread >/dev/null 2>&1 || true"
run "supervisorctl update >/dev/null 2>&1 || true"

if [ $PURGE -eq 1 ]; then
  DIR_DEFAULT="/opt/projects/${NAME}"
  VENV_DIR="/opt/venv-${NAME}"
  TMP1="/tmp/${NAME}-tmp"; TMP2="/tmp/${NAME}-cache"
  echo "Purging files: $DIR_DEFAULT $DIR_FROM_CONF $VENV_DIR $TMP1 $TMP2"
  run "rm -rf -- '$DIR_DEFAULT' '$DIR_FROM_CONF' '$VENV_DIR' '$TMP1' '$TMP2'"
fi

if [ $DELUSER -eq 1 ]; then
  U="${USER_FROM_CONF:-svc_${NAME}}"
  case "$U" in svc_*|${NAME}|svc_${NAME})
    echo "Deleting user: $U (and home)"
    run "userdel -r '$U' 2>/dev/null || true" ;;
    *) echo "Refusing to delete non-project user '$U'" >&2 ;;
  esac
fi

remove_service_port "$NAME" || true
apply_firewall_rules || true

echo "Done. Current programs:" && supervisorctl status || true
