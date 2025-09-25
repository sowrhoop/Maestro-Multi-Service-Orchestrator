#!/usr/bin/env sh
set -eu

usage() {
  cat <<USAGE
Usage: remove-service <name> [--conf-only] [--purge] [--delete-user] [--dry-run]

Removes a Supervisor-managed service by program <name>.

Options:
  --conf-only   Remove Supervisor program and reload only (default)
  --purge       Also remove source dir (/opt/services/<name>), venv (/opt/venv-<name>), and tmp/cache
  --delete-user Delete the service's UNIX user (if it looks like svc_<name>) and its home
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

CONF="/etc/supervisor/conf.d/program-${NAME}.conf"
if [ ! -f "$CONF" ]; then
  echo "No program conf found for '${NAME}' at $CONF" >&2
fi

# Extract attributes before removing conf
USER_FROM_CONF=""
DIR_FROM_CONF=""
CMD_FROM_CONF=""
if [ -f "$CONF" ]; then
  USER_FROM_CONF=$(sed -n 's/^user=//p' "$CONF" | head -n1 || true)
  DIR_FROM_CONF=$(sed -n 's/^directory=//p' "$CONF" | head -n1 || true)
  CMD_FROM_CONF=$(sed -n 's/^command=\/bin\/sh -c \"//p' "$CONF" | head -n1 | sed 's/\"$//' || true)
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
  DIR_DEFAULT="/opt/services/${NAME}"
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
    *) echo "Refusing to delete non-service user '$U'" >&2 ;;
  esac
fi

echo "Done. Current programs:" && supervisorctl status || true

