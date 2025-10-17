#!/usr/bin/env sh
set -eu
. /usr/local/lib/deploy/lib-deploy.sh

PREPARE_ONLY=0
if [ "${1:-}" = "--prepare-only" ]; then PREPARE_ONLY=1; shift; fi

# Parse project specs from env (environment variable names retain the legacy SERVICE prefix).
# Supported forms:
# - SERVICES="repo|port|ref|name|user|cmd; repo2|port2|..."
# - SERVICES_COUNT=N with SVC_1_REPO, SVC_1_PORT, SVC_1_REF, SVC_1_NAME, SVC_1_USER, SVC_1_CMD ...

provision_one() {
  REPO="$1"; PORT="$2"; REF="${3:-main}"; NAME_IN="${4:-}"; USER_IN="${5:-}"; CMD_IN="${6:-}";
  [ -z "$REPO" ] && { echo "Repo required" >&2; return 1; }
  case "$PORT" in ''|*[!0-9]*) echo "Invalid port: $PORT" >&2; return 1;; esac
  [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ] && { echo "Invalid port: $PORT" >&2; return 1; }

  NAME=${NAME_IN:-$(derive_name "$REPO")}
  NAME=$(sanitize "$NAME")
  DEFAULT_USER="svc_${NAME}"
  USER=${USER_IN:-$(derive_project_user "$NAME" "$DEFAULT_USER" "")}
  ensure_user "$USER"

  DEST="/opt/projects/${NAME}"
  mkdir -p "$DEST"
  URL=$(codeload_url "$REPO" "$REF")
  fetch_tar_into_dir "$URL" "$DEST" "$USER" "$NAME"
  install_deps_if_any "$DEST" "$NAME" "$USER"

  CMD=${CMD_IN:-$(detect_default_cmd "$DEST" "$PORT")}
  chown -R "$USER":"$USER" "$DEST" || true
  chmod -R 750 "$DEST" || true
  printf '%s\n' "$NAME" >"${DEST}/.maestro-name" 2>/dev/null || true
  chown "$USER":"$USER" "${DEST}/.maestro-name" 2>/dev/null || true
  write_program_conf "$NAME" "$DEST" "$CMD" "$USER"
}

if [ -n "${SERVICES:-}" ]; then
  IFS=';' ; set -- $SERVICES ; unset IFS
  for ITEM in "$@"; do
    [ -z "$ITEM" ] && continue
    IFS='|' read -r REP PORT REF NAME USER CMD <<EOF
$ITEM
EOF
    provision_one "$REP" "$PORT" "${REF:-main}" "${NAME:-}" "${USER:-}" "${CMD:-}"
  done
elif [ -n "${SERVICES_COUNT:-}" ]; then
  i=1
  while [ "$i" -le "$SERVICES_COUNT" ]; do
    eval REP="\${SVC_${i}_REPO:-}"
    eval PORT="\${SVC_${i}_PORT:-}"
    eval REF="\${SVC_${i}_REF:-main}"
    eval NAME="\${SVC_${i}_NAME:-}"
    eval USER="\${SVC_${i}_USER:-}"
    eval CMD="\${SVC_${i}_CMD:-}"
    provision_one "$REP" "$PORT" "$REF" "$NAME" "$USER" "$CMD"
    i=$((i+1))
  done
else
  echo "No SERVICES or SERVICES_COUNT env provided" >&2
fi

if [ "$PREPARE_ONLY" -eq 0 ]; then
  supervisorctl reread >/dev/null 2>&1 || true
  supervisorctl update >/dev/null 2>&1 || true
  supervisorctl status || true
fi
