#!/usr/bin/env sh
set -eu
. /usr/local/lib/deploy/lib-deploy.sh

PREPARE_ONLY=0
if [ "${1:-}" = "--prepare-only" ]; then PREPARE_ONLY=1; shift; fi

PROVISIONED_SERVICES=""

# Parse project specs from env.
# Supported forms:
# - SERVICES="repo|port|ref|name|user|cmd; repo2|port2|..."
#   (set port blank to auto-select)
# - SERVICES_COUNT=N with SVC_1_REPO, SVC_1_PORT, SVC_1_REF, SVC_1_NAME, SVC_1_USER, SVC_1_CMD ...

provision_one() {
  REPO="$1"; PORT_IN="$2"; REF="${3:-main}"; NAME_IN="${4:-}"; USER_IN="${5:-}"; CMD_IN="${6:-}";
  [ -n "$REPO" ] || { printf '%s\n' "Repo/source required" >&2; return 1; }

  maestro_log_info "Provisioning service from ${REPO} (ref=${REF})"

  NAME=${NAME_IN:-$(derive_name "$REPO")}
  NAME=$(sanitize "$NAME")
  if [ -z "$NAME" ]; then
    NAME="svc_$(date +%s)_$$"
    NAME=$(sanitize "$NAME")
  fi
  DEFAULT_USER="svc_${NAME}"
  USER=${USER_IN:-$(derive_project_user "$NAME" "$DEFAULT_USER" "")}
  ensure_user "$USER"
  maestro_log_debug "Provision target name=${NAME} user=${USER}"

  DEST="/opt/projects/${NAME}"
  mkdir -p "$DEST"
  URL=$(codeload_url "$REPO" "$REF")
  fetch_tar_into_dir "$URL" "$DEST" "$USER" "$NAME"
  install_deps_if_any "$DEST" "$NAME" "$USER"

  RESOLVED_PORT=$(maestro_resolve_port "$PORT_IN") || { printf '%s\n' "Unable to allocate port for ${NAME}" >&2; return 1; }

  CMD=${CMD_IN:-$(detect_default_cmd "$DEST" "$RESOLVED_PORT")}
  CMD=$(printf '%s\n' "$CMD" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -z "$CMD" ]; then
    CMD=$(detect_default_cmd "$DEST" "$RESOLVED_PORT")
  fi
  chown -R "$USER":"$USER" "$DEST" || true
  chmod -R 750 "$DEST" || true
  printf '%s\n' "$NAME" >"${DEST}/.maestro-name" 2>/dev/null || true
  chown "$USER":"$USER" "${DEST}/.maestro-name" 2>/dev/null || true
  write_program_conf "$NAME" "$DEST" "$CMD" "$USER"
  register_service_port "$NAME" "$RESOLVED_PORT"
  apply_firewall_rules || true
  PROVISIONED_SERVICES="${PROVISIONED_SERVICES} ${NAME}"
  maestro_log_info "Provisioned ${NAME} on port ${RESOLVED_PORT}"
}

if [ -n "${SERVICES:-}" ]; then
  OLDIFS=$IFS
  IFS=';'
  for ITEM in $SERVICES; do
    ITEM_TRIM=$(printf '%s' "$ITEM" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$ITEM_TRIM" ] || continue
    IFS='|' read -r REP PORT REF NAME USER CMD <<EOF
$ITEM_TRIM
EOF
    [ -n "${REP:-}" ] || continue
    if ! provision_one "$REP" "${PORT:-}" "${REF:-main}" "${NAME:-}" "${USER:-}" "${CMD:-}"; then
      maestro_log_error "Failed to provision service from ${REP}"
    fi
  done
  IFS=$OLDIFS
elif [ -n "${SERVICES_COUNT:-}" ]; then
  case "$SERVICES_COUNT" in
    ''|*[!0-9]*) printf '%s\n' "SERVICES_COUNT must be numeric" >&2; exit 1;;
  esac
  i=1
  while [ "$i" -le "$SERVICES_COUNT" ]; do
    eval REP="\${SVC_${i}_REPO:-}"
    eval PORT="\${SVC_${i}_PORT:-}"
    eval REF="\${SVC_${i}_REF:-main}"
    eval NAME="\${SVC_${i}_NAME:-}"
    eval USER="\${SVC_${i}_USER:-}"
    eval CMD="\${SVC_${i}_CMD:-}"
    if [ -n "${REP:-}" ]; then
      if ! provision_one "$REP" "$PORT" "$REF" "$NAME" "$USER" "$CMD"; then
        maestro_log_error "Failed to provision service from ${REP}"
      fi
    fi
    i=$((i+1))
  done
else
  printf '%s\n' "No SERVICES or SERVICES_COUNT env provided" >&2
fi

if [ "$PREPARE_ONLY" -eq 0 ]; then
  supervisorctl reread >/dev/null 2>&1 || true
  supervisorctl update >/dev/null 2>&1 || true
  supervisorctl status || true
fi

trimmed_services=$(printf '%s' "$PROVISIONED_SERVICES" | sed 's/^[[:space:]]*//')
if [ -n "$trimmed_services" ]; then
  maestro_log_info "Provisioned services: $trimmed_services"
else
  maestro_log_warn "No services were provisioned"
fi
