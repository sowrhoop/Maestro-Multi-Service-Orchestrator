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
log_info()  { log_emit info  "$@"; }
log_warn()  { log_emit warn  "$@"; }
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

prepare_user_home() {
  user="$1"
  home="/home/$user"
  mkdir -p "$home"
  chmod 700 "$home" || true
  chown -R "$user":"$user" "$home" || true
}

prepare_project_dir() {
  dir="$1"; user="$2"
  mkdir -p "$dir"
  chown -R "$user":"$user" "$dir" 2>/dev/null || true
  chmod 750 "$dir" 2>/dev/null || true
}

read_first_line() {
  file="$1"
  [ -f "$file" ] || { printf '%s' ''; return 0; }
  head -n 1 "$file" 2>/dev/null | tr -d '\r'
}

service_env_override() {
  name="$1"; key="$2"
  upper_name=$(printf '%s' "$name" | tr '[:lower:].-' '[:upper:]__')
  var="MAESTRO_${key}_${upper_name}"
  eval value="\${$var:-}"
  printf '%s' "$value"
}

program_name_in_use() {
  candidate="$1"; parent="$2"; exclude="$3"
  case " ${REGISTERED_PROGRAMS:-} " in
    *" ${candidate} "* ) return 0 ;;
  esac
  if [ -f "${SUPERVISOR_CONF_DIR}/program-${candidate}.conf" ]; then
    return 0
  fi
  if [ -n "$parent" ]; then
    path="${parent}/${candidate}"
    if [ "$path" != "$exclude" ] && [ -e "$path" ]; then
      return 0
    fi
  fi
  return 1
}

ensure_unique_program_name() {
  base="$1"; parent="$2"; current_path="$3"
  candidate="$base"
  suffix=1
  while program_name_in_use "$candidate" "$parent" "$current_path"; do
    candidate="${base}-${suffix}"
    suffix=$((suffix+1))
  done
  printf '%s' "$candidate"
}

resolve_preseed_mode() {
  mode="${MAESTRO_PRESEEDED_MODE:-${DEFAULT_SERVICES_MODE:-auto}}"
  case "$(to_lower "$mode")" in
    auto|always|never) printf '%s' "$(to_lower "$mode")" ;;
    *)
      log_warn "Unknown MAESTRO_PRESEEDED_MODE='${mode}', falling back to auto"
      printf 'auto'
      ;;
  esac
}

discover_preseed_dirs() {
  roots_raw=${MAESTRO_PRESEEDED_ROOTS:-/opt/projects}
  printf '%s' "$roots_raw" | tr ',:' '\n' | while IFS= read -r root; do
    trimmed=$(printf '%s' "$root" | sed 's/^ *//; s/ *$//')
    [ -n "$trimmed" ] || continue
    if [ ! -d "$trimmed" ]; then
      log_debug "Preseed root ${trimmed} not found; skipping"
      continue
    fi
    find "$trimmed" -mindepth 1 -maxdepth 1 -type d -print
  done
}

record_program() {
  program="$1"
  REGISTERED_PROGRAMS="${REGISTERED_PROGRAMS} ${program}"
}

register_preseed_project() {
  project_dir="$1"
  mode="$2"

  if [ ! -d "$project_dir" ]; then
    return 0
  fi

  if [ -f "${project_dir}/.maestro-disable" ]; then
    log_info "Skipping $(basename "$project_dir"): disabled via .maestro-disable"
    return 0
  fi

  raw_name=$(read_first_line "${project_dir}/.maestro-name")
  [ -n "$raw_name" ] || raw_name=$(basename "$project_dir")
  sanitized=$(sanitize "$raw_name")
  if [ -z "$sanitized" ]; then
    log_warn "Unable to derive service name from ${project_dir}; skipping"
    return 0
  fi

  parent_dir=$(dirname "$project_dir")
  program=$(ensure_unique_program_name "$sanitized" "$parent_dir" "$project_dir")
  target_dir="${parent_dir}/${program}"
  if [ "$target_dir" != "$project_dir" ] && [ ! -e "$target_dir" ]; then
    mv "$project_dir" "$target_dir"
    project_dir="$target_dir"
    log_debug "Renamed project directory to ${project_dir}"
  fi

  # Collect overrides (prefer base name, then program name)
  port_override=$(service_env_override "$sanitized" "PORT")
  [ -n "$port_override" ] || port_override=$(service_env_override "$program" "PORT")
  if [ -z "$port_override" ]; then
    port_file=$(read_first_line "${project_dir}/.maestro-port")
    port_override="$port_file"
  fi

  user_override=$(service_env_override "$sanitized" "USER")
  [ -n "$user_override" ] || user_override=$(service_env_override "$program" "USER")
  if [ -z "$user_override" ]; then
    user_file=$(read_first_line "${project_dir}/.maestro-user")
    user_override="$user_file"
  fi

  cmd_override=$(service_env_override "$sanitized" "CMD")
  [ -n "$cmd_override" ] || cmd_override=$(service_env_override "$program" "CMD")
  if [ -z "$cmd_override" ] && [ -f "${project_dir}/.maestro-cmd" ]; then
    cmd_override=$(cat "${project_dir}/.maestro-cmd" 2>/dev/null || true)
  fi

  case "$mode" in
    never)
      log_info "${program}: preseed mode=never; skipping directory ${project_dir}"
      return 0
      ;;
    auto)
      if dir_empty "$project_dir" && [ -z "$cmd_override" ]; then
        log_info "${program}: directory empty and no command override; skipping in auto mode"
        return 0
      fi
      ;;
    always)
      :
      ;;
  esac

  resolved_port=$(maestro_resolve_port "$port_override") || {
    log_warn "${program}: unable to allocate port"
    return 0
  }

  fallback_user="svc_${program}"
  if [ -n "$user_override" ]; then
    fallback_user="$user_override"
  fi
  fallback_user=$(printf '%s' "$fallback_user" | tr '.-' '__')
  fallback_user=$(printf '%.32s' "$fallback_user")
  project_user=$(derive_project_user "$program" "$fallback_user" "")

  ensure_user "$project_user"
  prepare_user_home "$project_user"
  prepare_project_dir "$project_dir" "$project_user"

  install_deps_if_any "$project_dir" "$program" "$project_user"

  if printf '%s\n' "$program" >"${project_dir}/.maestro-name" 2>/dev/null; then
    chown "$project_user":"$project_user" "${project_dir}/.maestro-name" 2>/dev/null || true
  fi
  if printf '%s\n' "$resolved_port" >"${project_dir}/.maestro-port" 2>/dev/null; then
    chown "$project_user":"$project_user" "${project_dir}/.maestro-port" 2>/dev/null || true
  fi

  command_value="$cmd_override"
  if [ -z "$command_value" ]; then
    command_value=$(detect_default_cmd "$project_dir" "$resolved_port")
  fi
  if [ -z "$command_value" ]; then
    command_value="python3 -m http.server ${resolved_port} --directory ${project_dir} --bind 0.0.0.0"
  fi

  if dir_empty "$project_dir" && [ -z "$cmd_override" ] && [ "$mode" != "always" ]; then
    log_warn "${program}: directory empty after preparation; not registering"
    return 0
  fi

  if ! write_program_conf "$program" "$project_dir" "$command_value" "$project_user"; then
    log_error "${program}: failed to write supervisor configuration"
    return 1
  fi

  register_service_port "$program" "$resolved_port"
  record_program "$program"
  log_info "${program}: registered command '${command_value}' on port ${resolved_port}"
  return 0
}

SUPERVISOR_CONF_DIR=${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}
mkdir -p "$SUPERVISOR_CONF_DIR"
mkdir -p /tmp/supervisor && chmod 700 /tmp/supervisor || true
log_debug "Supervisor configuration directory: ${SUPERVISOR_CONF_DIR}"

MAESTRO_RUNTIME_DIR=${MAESTRO_RUNTIME_DIR:-/run/maestro}
MAESTRO_PORT_LEDGER=${MAESTRO_PORT_LEDGER:-${MAESTRO_RUNTIME_DIR}/ports.csv}
export MAESTRO_RUNTIME_DIR MAESTRO_PORT_LEDGER
mkdir -p "$MAESTRO_RUNTIME_DIR" && chmod 700 "$MAESTRO_RUNTIME_DIR" || true
rm -f "$MAESTRO_PORT_LEDGER" 2>/dev/null || true
MAESTRO_RESERVED_PORTS=""
export MAESTRO_RESERVED_PORTS
ensure_port_ledger

REGISTERED_PROGRAMS=""

PRESEEDED_MODE=$(resolve_preseed_mode)
if [ "$PRESEEDED_MODE" != "never" ]; then
  log_info "Scanning for preseeded projects (mode=${PRESEEDED_MODE})"
  discover_preseed_dirs | sort | while IFS= read -r project_path; do
    [ -z "$project_path" ] && continue
    register_preseed_project "$project_path" "$PRESEEDED_MODE" || true
  done
fi

if [ -n "${SERVICES:-}" ] || [ -n "${SERVICES_COUNT:-}" ]; then
  if [ -x /usr/local/bin/deploy-from-env ]; then
    log_info "Applying SERVICES* specification before Supervisor starts"
    /usr/local/bin/deploy-from-env --prepare-only || true
  fi
fi

apply_firewall_rules || true

program_names=$(find "$SUPERVISOR_CONF_DIR" -maxdepth 1 -name 'program-*.conf' -type f -exec basename {} \; 2>/dev/null | sort | sed 's/^program-//; s/\.conf$//')
program_count=$(printf '%s\n' "$program_names" | awk 'NF{c++} END{print (c ? c : 0)}')

if [ "$program_count" -eq 0 ]; then
  log_warn "No supervisor programs configured; supervisord will start idle"
else
  formatted=$(printf '%s' "$program_names" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
  log_info "Supervisor programs prepared (${program_count}): ${formatted}"
fi

log_info "Launching supervisord"
trap - EXIT
exec /usr/bin/supervisord -n
