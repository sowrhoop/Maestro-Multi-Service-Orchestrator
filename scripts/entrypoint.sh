#!/usr/bin/env sh
# POSIX-compliant entrypoint orchestrating Supervisor programs.
set -eu

. /usr/local/lib/deploy/lib-deploy.sh

umask 0027

log() {
  printf '[entrypoint] %s\n' "$*" >&2
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

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
      printf 'Error: %s (%s) must be an integer.\n' "$name" "$value" >&2
      exit 1
      ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    printf 'Error: %s (%s) must be between 1 and 65535.\n' "$name" "$value" >&2
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
      log "Unknown DEFAULT_SERVICES_MODE='$mode', falling back to auto"
      printf 'auto'
      ;;
  esac
}

bootstrap_builtin_service() {
  slot="$1"       # A or B
  program="$2"    # supervisor program name (project1/project2)
  service_dir="$3"
  service_user="$4"
  default_port="$5"
  defaults_mode="$6"

  conf_path="/etc/supervisor/conf.d/program-${program}.conf"
  rm -f "$conf_path"

  eval enabled_override="\${SERVICE_${slot}_ENABLED:-}"
  eval repo_url="\${SERVICE_${slot}_REPO:-}"
  eval repo_ref="\${SERVICE_${slot}_REF:-main}"
  eval tarball_url="\${SERVICE_${slot}_TARBALL:-}"
  eval cmd_override="\${SERVICE_${slot}_CMD:-}"

  start_service=0
  force_empty_ok=0

  if [ -n "$enabled_override" ]; then
    if is_true "$enabled_override"; then
      start_service=1
      force_empty_ok=1
    elif is_false "$enabled_override"; then
      log "${program}: disabled via SERVICE_${slot}_ENABLED=${enabled_override}"
      return 0
    else
      log "${program}: ignoring unrecognised SERVICE_${slot}_ENABLED=${enabled_override}"
    fi
  fi

  if [ "$start_service" -eq 0 ]; then
    case "$defaults_mode" in
      never)
        log "${program}: default services disabled (DEFAULT_SERVICES_MODE=never)"
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
    log "${program}: nothing to run; skipping"
    return 0
  fi

  prepare_service_dir "$service_dir" "$service_user"

  if dir_empty "$service_dir"; then
    if [ -n "$tarball_url" ]; then
      log "${program}: fetching tarball ${tarball_url}"
      if ! fetch_tar_into_dir "$tarball_url" "$service_dir"; then
        log "${program}: failed to fetch tarball"
      fi
    elif [ -n "$repo_url" ]; then
      archive_url=$(codeload_url "$repo_url" "$repo_ref")
      log "${program}: fetching ${repo_url}@${repo_ref}"
      if ! fetch_tar_into_dir "$archive_url" "$service_dir"; then
        log "${program}: failed to fetch repository"
      fi
    fi
  fi

  prepare_service_dir "$service_dir" "$service_user"

  eval resolved_port="\${SERVICE_${slot}_PORT:-$default_port}"
  validate_port "SERVICE_${slot}_PORT" "$resolved_port"
  export "SERVICE_${slot}_PORT=$resolved_port"

  command_value="$cmd_override"
  if [ -z "$command_value" ]; then
    command_value=$(detect_default_cmd "$service_dir" "$resolved_port")
    if [ -z "$command_value" ]; then
      command_value="python3 -m http.server ${resolved_port} --directory ${service_dir} --bind 0.0.0.0"
    fi
  fi

  if dir_empty "$service_dir" && [ "$force_empty_ok" -eq 0 ]; then
    log "${program}: directory still empty after preparation; not registering"
    return 0
  fi

  if ! write_program_conf "$program" "$service_dir" "$command_value" "$service_user"; then
    log "${program}: failed to write supervisor configuration"
    return 1
  fi

  log "${program}: registered command '${command_value}' on port ${resolved_port}"
  return 0
}

mkdir -p /etc/supervisor/conf.d
mkdir -p /tmp/supervisor && chmod 700 /tmp/supervisor || true

prepare_user_home svc_a
prepare_user_home svc_b

prepare_service_dir /opt/services/service-a svc_a
prepare_service_dir /opt/services/service-b svc_b

SERVICE_A_PORT="${SERVICE_A_PORT:-8080}"
SERVICE_B_PORT="${SERVICE_B_PORT:-9090}"
validate_port SERVICE_A_PORT "$SERVICE_A_PORT"
validate_port SERVICE_B_PORT "$SERVICE_B_PORT"
export SERVICE_A_PORT SERVICE_B_PORT

if [ "$SERVICE_A_PORT" = "$SERVICE_B_PORT" ]; then
  printf 'Error: SERVICE_A_PORT (%s) and SERVICE_B_PORT (%s) must differ.\n' "$SERVICE_A_PORT" "$SERVICE_B_PORT" >&2
  exit 1
fi

DEFAULT_SERVICES_MODE=$(resolve_default_mode)

bootstrap_builtin_service "A" "project1" "/opt/services/service-a" "svc_a" "$SERVICE_A_PORT" "$DEFAULT_SERVICES_MODE"
bootstrap_builtin_service "B" "project2" "/opt/services/service-b" "svc_b" "$SERVICE_B_PORT" "$DEFAULT_SERVICES_MODE"

if [ -n "${SERVICES:-}" ] || [ -n "${SERVICES_COUNT:-}" ]; then
  if [ -x /usr/local/bin/deploy-from-env ]; then
    log "Applying SERVICES* specification before Supervisor starts"
    /usr/local/bin/deploy-from-env --prepare-only || true
  fi
fi

program_count=$(find /etc/supervisor/conf.d -maxdepth 1 -name 'program-*.conf' 2>/dev/null | wc -l | tr -d ' ')
log "Supervisor programs prepared: ${program_count}"

exec /usr/bin/supervisord -n
