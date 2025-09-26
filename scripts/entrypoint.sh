#!/usr/bin/env sh
# POSIX-compliant entrypoint orchestrating Supervisor programs.
set -eu

. /usr/local/lib/deploy/lib-deploy.sh

umask 0027

ENTRYPOINT_LOG_LEVEL=${ENTRYPOINT_LOG_LEVEL:-info}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

log_level_value() {
  case "$(to_lower "$1")" in
    debug) printf '0';;
    info) printf '1';;
    warn|warning) printf '2';;
    error|err) printf '3';;
    *) printf '1';;
  esac
}

current_log_level=$(log_level_value "$ENTRYPOINT_LOG_LEVEL")

log_emit() {
  level_name="$1"; shift
  level_value=$(log_level_value "$level_name")
  if [ "$level_value" -lt "$current_log_level" ]; then
    return 0
  fi
  printf '[entrypoint][%s] %s\n' "$level_name" "$*" >&2
}

log_debug() { log_emit debug "$@"; }
log_info() { log_emit info "$@"; }
log_warn() { log_emit warn "$@"; }
log_error() { log_emit error "$@"; }

trap 'status=$?; if [ $status -ne 0 ]; then log_error "Exiting with status $status"; fi' EXIT

log_info "Entrypoint log level set to ${ENTRYPOINT_LOG_LEVEL}"

is_true() {
  case "$(to_lower "$1")" in
    1|true|yes|on) return 0 ;;
  esac
  return 1
}

is_false() {
  case "$(to_lower "$1")" in
    0|false|no|off) return 0 ;;
  esac
  return 1
}

dir_empty() {
  path="$1"
  if [ ! -d "$path" ]; then
    return 0
  fi
  entries=$(ls -A "$path" 2>/dev/null || true)
  [ -z "$entries" ]
}

validate_port() {
  name="$1"; value="$2"
  case "$value" in
    ''|*[!0-9]*)
      log_error "${name} (${value}) must be an integer"
      exit 1
      ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    log_error "${name} (${value}) must be between 1 and 65535"
    exit 1
  fi
}

prepare_user_home() {
  user="$1"
  home="/home/$user"
  mkdir -p "$home"
  chmod 700 "$home" || true
  chown -R "$user":"$user" "$home" || true
}

prepare_service_dir() {
  dir="$1"; user="$2"
  mkdir -p "$dir"
  chown -R "$user":"$user" "$dir" || true
  chmod 750 "$dir" || true
}

derive_tarball_name() {
  url="$1"
  if [ -z "$url" ]; then
    return 0
  fi
  trimmed=$(printf '%s' "$url" | sed 's/[?#].*$//')
  trimmed=${trimmed%/}
  base=${trimmed##*/}
  if [ -z "$base" ]; then
    return 0
  fi
  base=$(printf '%s' "$base" | sed -E 's/\.(tar\.gz|tar\.bz2|tar\.xz|tar\.zst|tgz|tbz2|txz|zip)$//')
  sanitize "$base"
}

derive_service_user() {
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

# Resolve default services mode: auto|always|never
resolve_default_mode() {
  mode="${DEFAULT_SERVICES_MODE:-}"
  if [ -z "$mode" ]; then
    if [ -n "${SERVICES:-}" ] || [ -n "${SERVICES_COUNT:-}" ]; then
      mode="never"
    else
      mode="auto"
    fi
  fi
  case "$(to_lower "$mode")" in
    auto|always|never) printf '%s' "$(to_lower "$mode")" ;;
    *)
      log_warn "Unknown DEFAULT_SERVICES_MODE='$mode', falling back to auto"
      printf 'auto'
      ;;
  esac
}

bootstrap_builtin_service() {
  slot="$1"       # A or B
  default_program="$2"
  default_service_dir="$3"
  default_user="$4"
  default_port="$5"
  defaults_mode="$6"

  service_root=$(dirname "$default_service_dir")
  if [ "$service_root" = "$default_service_dir" ] || [ -z "$service_root" ]; then
    service_root="/opt/services"
  fi
  mkdir -p "$service_root"

  program="$default_program"
  service_dir="$default_service_dir"

  eval enabled_override="\${SERVICE_${slot}_ENABLED:-}"
  eval repo_url="\${SERVICE_${slot}_REPO:-}"
  eval repo_ref="\${SERVICE_${slot}_REF:-main}"
  eval tarball_url="\${SERVICE_${slot}_TARBALL:-}"
  eval cmd_override="\${SERVICE_${slot}_CMD:-}"
  eval name_override="\${SERVICE_${slot}_NAME:-}"

  identity=""
  identity_source=""
  if [ -n "$name_override" ]; then
    identity=$(sanitize "$name_override")
    [ -n "$identity" ] && identity_source="override"
  fi
  if [ -z "$identity" ] && [ -n "$repo_url" ]; then
    identity=$(derive_name "$repo_url" || true)
    [ -n "$identity" ] && identity_source="repo"
  fi
  if [ -z "$identity" ] && [ -n "$tarball_url" ]; then
    identity=$(derive_tarball_name "$tarball_url" || true)
    [ -n "$identity" ] && identity_source="tarball"
  fi

  stamp_path="${default_service_dir}/.maestro-name"
  if [ -z "$identity" ] && [ -f "$stamp_path" ]; then
    stamp_value=$(head -n 1 "$stamp_path" 2>/dev/null || true)
    identity=$(sanitize "$stamp_value")
    [ -n "$identity" ] && identity_source="stamp"
  fi

  if [ -n "$identity" ] && [ -n "$identity_source" ]; then
    program="$identity"
    service_dir="${service_root}/${program}"
    lower_slot=$(to_lower "$slot")
    if [ -e "$service_dir" ] && [ "$service_dir" != "$default_service_dir" ]; then
      program="${program}-${lower_slot}"
      service_dir="${service_root}/${program}"
      if [ -e "$service_dir" ]; then
        log_warn "${default_program}: resolved name collision for ${program}; falling back to legacy naming"
        program="$default_program"
        service_dir="$default_service_dir"
        identity_source=""
      fi
    fi
    if [ -n "$identity_source" ]; then
      log_debug "Slot ${slot}: derived service name '${program}' from ${identity_source}"
    fi
  fi

  rm -f "${SUPERVISOR_CONF_DIR}/program-${default_program}.conf"
  rm -f "${SUPERVISOR_CONF_DIR}/program-${program}.conf"

  if [ "$service_dir" != "$default_service_dir" ] && [ -d "$default_service_dir" ]; then
    if [ ! -e "$service_dir" ]; then
      mv "$default_service_dir" "$service_dir"
    else
      log_warn "${program}: target directory ${service_dir} already exists; using as-is"
    fi
  fi

  start_service=0
  force_empty_ok=0

  if [ -n "$enabled_override" ]; then
    if is_true "$enabled_override"; then
      start_service=1
      force_empty_ok=1
    elif is_false "$enabled_override"; then
      log_info "${program}: disabled via SERVICE_${slot}_ENABLED=${enabled_override}"
      return 0
    else
      log_warn "${program}: ignoring unrecognised SERVICE_${slot}_ENABLED=${enabled_override}"
    fi
  fi

  if [ "$start_service" -eq 0 ]; then
    case "$defaults_mode" in
      never)
        log_info "${program}: default services disabled (DEFAULT_SERVICES_MODE=never)"
        return 0
        ;;
      always)
        start_service=1
        force_empty_ok=1
        ;;
      auto)
        if [ -n "$cmd_override" ] || [ -n "$repo_url" ] || [ -n "$tarball_url" ]; then
          start_service=1
          [ -n "$cmd_override" ] && force_empty_ok=1
        elif ! dir_empty "$service_dir"; then
          start_service=1
        fi
        ;;
      *)
        start_service=0
        ;;
    esac
  fi

  if [ "$start_service" -eq 0 ]; then
    log_info "${program}: nothing to run; skipping"
    return 0
  fi

  lower_slot=$(to_lower "$slot")

  service_user="$default_user"
  if [ -n "$identity_source" ]; then
    service_user=$(derive_service_user "$program" "$default_user" "$lower_slot")
  fi
  ensure_user "$service_user"
  prepare_user_home "$service_user"
  prepare_service_dir "$service_dir" "$service_user"

  if dir_empty "$service_dir"; then
    if [ -n "$tarball_url" ]; then
      log_info "${program}: fetching tarball ${tarball_url}"
      if ! fetch_tar_into_dir "$tarball_url" "$service_dir"; then
        log_warn "${program}: failed to fetch tarball"
      fi
    elif [ -n "$repo_url" ]; then
      archive_url=$(codeload_url "$repo_url" "$repo_ref")
      log_info "${program}: fetching ${repo_url}@${repo_ref}"
      if ! fetch_tar_into_dir "$archive_url" "$service_dir"; then
        log_warn "${program}: failed to fetch repository"
      fi
    fi
  fi

  prepare_service_dir "$service_dir" "$service_user"

  eval resolved_port="\${SERVICE_${slot}_PORT:-$default_port}"
  validate_port "SERVICE_${slot}_PORT" "$resolved_port"
  export "SERVICE_${slot}_PORT=$resolved_port"

  if printf '%s\n' "$program" >"${service_dir}/.maestro-name" 2>/dev/null; then
    chown "$service_user":"$service_user" "${service_dir}/.maestro-name" 2>/dev/null || true
  fi

  command_value="$cmd_override"
  if [ -z "$command_value" ]; then
    command_value=$(detect_default_cmd "$service_dir" "$resolved_port")
    if [ -z "$command_value" ]; then
      command_value="python3 -m http.server ${resolved_port} --directory ${service_dir} --bind 0.0.0.0"
    fi
  fi

  if dir_empty "$service_dir" && [ "$force_empty_ok" -eq 0 ]; then
    log_warn "${program}: directory still empty after preparation; not registering"
    return 0
  fi

  if ! write_program_conf "$program" "$service_dir" "$command_value" "$service_user"; then
    log_error "${program}: failed to write supervisor configuration"
    return 1
  fi

  REGISTERED_PROGRAMS="${REGISTERED_PROGRAMS} ${program}"
  log_info "${program}: registered command '${command_value}' on port ${resolved_port}"
  return 0
}

SUPERVISOR_CONF_DIR=${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}
mkdir -p "$SUPERVISOR_CONF_DIR"
mkdir -p /tmp/supervisor && chmod 700 /tmp/supervisor || true
log_debug "Supervisor configuration directory: ${SUPERVISOR_CONF_DIR}"

REGISTERED_PROGRAMS=""

SERVICE_A_PORT="${SERVICE_A_PORT:-8080}"
SERVICE_B_PORT="${SERVICE_B_PORT:-9090}"
validate_port SERVICE_A_PORT "$SERVICE_A_PORT"
validate_port SERVICE_B_PORT "$SERVICE_B_PORT"
export SERVICE_A_PORT SERVICE_B_PORT

if [ "$SERVICE_A_PORT" = "$SERVICE_B_PORT" ]; then
  log_error "SERVICE_A_PORT (${SERVICE_A_PORT}) and SERVICE_B_PORT (${SERVICE_B_PORT}) must differ"
  exit 1
fi

DEFAULT_SERVICES_MODE=$(resolve_default_mode)

bootstrap_builtin_service "A" "project1" "/opt/services/service-a" "svc_a" "$SERVICE_A_PORT" "$DEFAULT_SERVICES_MODE"
bootstrap_builtin_service "B" "project2" "/opt/services/service-b" "svc_b" "$SERVICE_B_PORT" "$DEFAULT_SERVICES_MODE"

if [ -n "${SERVICES:-}" ] || [ -n "${SERVICES_COUNT:-}" ]; then
  if [ -x /usr/local/bin/deploy-from-env ]; then
    log_info "Applying SERVICES* specification before Supervisor starts"
    /usr/local/bin/deploy-from-env --prepare-only || true
  fi
fi

program_conf_glob=$(find "$SUPERVISOR_CONF_DIR" -maxdepth 1 -name 'program-*.conf' 2>/dev/null)
program_count=$(printf '%s\n' "$program_conf_glob" | awk 'NF{c++} END{printf (c ? c : 0)}')
trimmed_programs=$(printf '%s' "$REGISTERED_PROGRAMS" | tr -s ' ' | sed 's/^ //')
if [ "$program_count" -eq 0 ]; then
  log_warn "No supervisor programs configured; supervisord will start idle"
else
  if [ -n "$trimmed_programs" ]; then
    log_info "Supervisor programs prepared (${program_count}): ${trimmed_programs}"
  else
    log_info "Supervisor programs detected: ${program_count}"
  fi
fi

log_info "Launching supervisord"
trap - EXIT
exec /usr/bin/supervisord -n
