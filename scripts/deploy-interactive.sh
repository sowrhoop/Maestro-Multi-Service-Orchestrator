#!/usr/bin/env sh
set -eu

echo "Interactive multi-project deployer (Supervisor)"
echo "This will fetch GitHub repos, create users, and register programs."

# Helpers
sanitize() {
  printf "%s" "$1" | tr '[:upper:] ' '[:lower:]-' | sed 's/[^a-z0-9._-]//g'
}

derive_name() {
  url="$1"
  base=$(printf "%s" "$url" | sed -E 's#^https?://github.com/##; s#\.git$##; s#/$##')
  name=${base##*/}
  sanitize "$name"
}

codeload_url() {
  url="$1"; ref="$2"
  if printf "%s" "$url" | grep -qiE '^https?://github.com/'; then
    path=$(printf "%s" "$url" | sed -E 's#^https?://github.com/##; s#\.git$##; s#/$##')
    printf "https://codeload.github.com/%s/tar.gz/%s" "$path" "$ref"
  else
    printf "%s" "$url"
  fi
}

fetch_tar_into_dir() {
  url="$1"; dest="$2"
  tmp="/tmp/src.$(date +%s).tar.gz"
  echo "-> Downloading $url" >&2
  curl -fsSL "$url" -o "$tmp"
  mkdir -p "$dest"
  # Extract stripping first path component (repo-ref)
  tar -xzf "$tmp" -C "$dest" --strip-components 1 2>/dev/null || tar -xzf "$tmp" -C "$dest" 2>/dev/null || true
  rm -f "$tmp"
}

detect_default_cmd() {
  d="$1"; port="$2"
  if [ -f "$d/package.json" ]; then
    printf "PORT=%s node server.js" "$port"
  elif [ -f "$d/requirements.txt" ] || [ -f "$d/pyproject.toml" ]; then
    # Assume uvicorn if app.py exists, else static server
    if [ -f "$d/app.py" ]; then
      printf "uvicorn app:app --host 0.0.0.0 --port %s" "$port"
    else
      printf "python3 -m http.server %s --directory %s --bind 0.0.0.0" "$port" "$d"
    fi
  else
    printf "python3 -m http.server %s --directory %s --bind 0.0.0.0" "$port" "$d"
  fi
}

ensure_user() {
  u="$1"
  if ! id -u "$u" >/dev/null 2>&1; then
    useradd -r -m -s /usr/sbin/nologin "$u" >/dev/null 2>&1 || true
  fi
  mkdir -p "/home/$u" && chmod 700 "/home/$u" && chown -R "$u":"$u" "/home/$u"
}

write_program_conf() {
  name="$1"; dir="$2"; cmd="$3"; user="$4"
  tmpd="/tmp/${name}-tmp"; cache="/tmp/${name}-cache"
  mkdir -p "$tmpd" "$cache"
  chown -R "$user":"$user" "$tmpd" "$cache" "$dir" || true
  cat >"/etc/supervisor/conf.d/program-${name}.conf" <<EOF
[program:${name}]
directory=${dir}
command=/bin/sh -c "${cmd}"
user=${user}
environment=HOME="/home/${user}",TMPDIR="${tmpd}",XDG_CACHE_HOME="${cache}"
umask=0027
autostart=true
autorestart=unexpected
startsecs=8
startretries=3
stopsignal=TERM
stopwaitsecs=15
stopasgroup=true
killasgroup=true
stdout_logfile=/dev/stdout
stderr_logfile=/dev/stderr
stdout_logfile_maxbytes=0
stderr_logfile_maxbytes=0
EOF
}

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
  echo -n "Name/id for this service [${NAME}]: "
  read NAME_IN; NAME=${NAME_IN:-$NAME}
  NAME=$(sanitize "$NAME")
  echo -n "Port to listen on (1-65535): "
  read PORT
  case "$PORT" in ''|*[!0-9]*) echo "Invalid port" >&2; exit 1;; esac
  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then echo "Invalid port" >&2; exit 1; fi

  USER="svc_${NAME}"
  ensure_user "$USER"
  DEST="/opt/services/${NAME}"
  mkdir -p "$DEST"
  URL=$(codeload_url "$REPO" "$REF")
  fetch_tar_into_dir "$URL" "$DEST"

  # Install dependencies when applicable
  if [ -f "$DEST/requirements.txt" ] || [ -f "$DEST/pyproject.toml" ] || [ -f "$DEST/setup.py" ]; then
    python3 -m venv "/opt/venv-${NAME}" || true
    "/opt/venv-${NAME}/bin/pip" install --no-cache-dir -r "$DEST/requirements.txt" 2>/dev/null || \
    "/opt/venv-${NAME}/bin/pip" install --no-cache-dir "$DEST" 2>/dev/null || true
    export PATH="/opt/venv-${NAME}/bin:$PATH"
  fi
  if [ -f "$DEST/package.json" ]; then
    (cd "$DEST" && (npm ci --omit=dev || npm install --omit=dev --no-audit --no-fund) && npm cache clean --force || true)
  fi

  DEFAULT_CMD=$(detect_default_cmd "$DEST" "$PORT")
  echo -n "Start command [${DEFAULT_CMD}]: "
  read CMD; CMD=${CMD:-$DEFAULT_CMD}

  chown -R "$USER":"$USER" "$DEST" || true
  chmod -R 750 "$DEST" || true

  write_program_conf "$NAME" "$DEST" "$CMD" "$USER"

  i=$((i+1))
done

echo "Reloading Supervisor"
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update >/dev/null 2>&1 || true
supervisorctl status || true

echo "Done. Use 'supervisorctl' to manage services."

