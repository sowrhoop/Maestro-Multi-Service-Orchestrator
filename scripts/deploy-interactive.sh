#!/usr/bin/env sh
set -eu
. /usr/local/lib/deploy/lib-deploy.sh

printf '%s\n' "Interactive multi-project deployer (Supervisor)"
printf '%s\n' "This will fetch GitHub repos, create users, and register programs."

printf 'How many projects to deploy? (1-20): '
IFS= read -r COUNT
case "$COUNT" in
  ''|*[!0-9]*) printf '%s\n' "Please enter a number" >&2; exit 1;;
esac
if [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 20 ]; then printf '%s\n' "Out of range" >&2; exit 1; fi

i=1
while [ "$i" -le "$COUNT" ]; do
  printf '\nProject #%s\n' "$i"
  printf 'GitHub repo URL (e.g., https://github.com/owner/repo): '
  IFS= read -r REPO
  [ -n "$REPO" ] || { printf '%s\n' "Repo URL required" >&2; exit 1; }
  printf 'Ref (branch/tag/sha) [main]: '
  IFS= read -r REF; REF=${REF:-main}
  NAME=$(derive_name "$REPO")
  printf 'Name/id for this project [%s]: ' "$NAME"
  IFS= read -r NAME_IN; NAME=${NAME_IN:-$NAME}
  NAME=$(sanitize "$NAME")
  if [ -z "$NAME" ]; then
    printf '%s\n' "Unable to derive a valid project name; please choose a different value." >&2
    exit 1
  fi
  printf 'Port to listen on (leave blank to auto-assign): '
  IFS= read -r PORT_INPUT
  RESOLVED_PORT=$(maestro_resolve_port "$PORT_INPUT") || { printf '%s\n' "Unable to allocate port" >&2; exit 1; }

  USER=$(derive_project_user "$NAME" "svc_${NAME}" "")
  ensure_user "$USER"
  DEST="/opt/projects/${NAME}"
  mkdir -p "$DEST"
  URL=$(codeload_url "$REPO" "$REF")
  fetch_tar_into_dir "$URL" "$DEST" "$USER" "$NAME"

  install_deps_if_any "$DEST" "$NAME" "$USER"

  DEFAULT_CMD=$(detect_default_cmd "$DEST" "$RESOLVED_PORT")
  printf 'Start command [%s]: ' "$DEFAULT_CMD"
  IFS= read -r CMD; CMD=${CMD:-$DEFAULT_CMD}

  chown -R "$USER":"$USER" "$DEST" || true
  chmod -R 750 "$DEST" || true
  printf '%s\n' "$NAME" >"${DEST}/.maestro-name" 2>/dev/null || true
  chown "$USER":"$USER" "${DEST}/.maestro-name" 2>/dev/null || true

  write_program_conf "$NAME" "$DEST" "$CMD" "$USER"
  register_service_port "$NAME" "$RESOLVED_PORT"
  apply_firewall_rules || true

  i=$((i+1))
done

printf '%s\n' "Reloading Supervisor"
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true
supervisorctl status || true

printf '%s\n' "Done. Use 'supervisorctl' to manage projects."
