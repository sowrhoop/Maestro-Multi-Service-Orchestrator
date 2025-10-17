#!/usr/bin/env sh
set -eu
. /usr/local/lib/deploy/lib-deploy.sh

echo "Interactive multi-project deployer (Supervisor)"
echo "This will fetch GitHub repos, create users, and register programs."

echo -n "How many projects to deploy? (1-20): "
read COUNT
case "$COUNT" in
  ''|*[!0-9]*) echo "Please enter a number" >&2; exit 1;;
esac
if [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 20 ]; then echo "Out of range" >&2; exit 1; fi

i=1
while [ "$i" -le "$COUNT" ]; do
  echo "\nProject #$i"
  echo -n "GitHub repo URL (e.g., https://github.com/owner/repo): "
  read REPO
  [ -z "$REPO" ] && { echo "Repo URL required" >&2; exit 1; }
  echo -n "Ref (branch/tag/sha) [main]: "
  read REF; REF=${REF:-main}
  NAME=$(derive_name "$REPO")
  echo -n "Name/id for this project [${NAME}]: "
  read NAME_IN; NAME=${NAME_IN:-$NAME}
  NAME=$(sanitize "$NAME")
  echo -n "Port to listen on (1-65535): "
  read PORT
  case "$PORT" in ''|*[!0-9]*) echo "Invalid port" >&2; exit 1;; esac
  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then echo "Invalid port" >&2; exit 1; fi

  USER=$(derive_project_user "$NAME" "svc_${NAME}" "")
  ensure_user "$USER"
  DEST="/opt/projects/${NAME}"
  mkdir -p "$DEST"
  URL=$(codeload_url "$REPO" "$REF")
  fetch_tar_into_dir "$URL" "$DEST" "$USER" "$NAME"

  install_deps_if_any "$DEST" "$NAME" "$USER"

  DEFAULT_CMD=$(detect_default_cmd "$DEST" "$PORT")
  echo -n "Start command [${DEFAULT_CMD}]: "
  read CMD; CMD=${CMD:-$DEFAULT_CMD}

  chown -R "$USER":"$USER" "$DEST" || true
  chmod -R 750 "$DEST" || true
  printf '%s\n' "$NAME" >"${DEST}/.maestro-name" 2>/dev/null || true
  chown "$USER":"$USER" "${DEST}/.maestro-name" 2>/dev/null || true

  write_program_conf "$NAME" "$DEST" "$CMD" "$USER"
  register_service_port "$NAME" "$PORT"
  apply_firewall_rules || true

  i=$((i+1))
done

echo "Reloading Supervisor"
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true
supervisorctl status || true

echo "Done. Use 'supervisorctl' to manage projects."
