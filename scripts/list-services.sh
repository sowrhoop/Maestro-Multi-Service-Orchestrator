#!/usr/bin/env sh
set -eu

SUPERVISOR_CONF_DIR=${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}

FORMAT="table"
if [ "${1:-}" = "--json" ]; then
  FORMAT="json"
fi

python3 - "$FORMAT" "$SUPERVISOR_CONF_DIR" <<'PY'
import sys, glob, configparser, shlex, subprocess, json, os

fmt = sys.argv[1]
conf_dir = sys.argv[2]
pattern = os.path.join(conf_dir, 'program-*.conf')
files = sorted(glob.glob(pattern))
status_map = {}
try:
    proc = subprocess.run(['supervisorctl', 'status'], check=False, capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 2)
        name = parts[0]
        status = parts[1] if len(parts) > 1 else ''
        status_map[name] = status
except Exception:
    pass

items = []
for path in files:
    parser = configparser.RawConfigParser()
    parser.optionxform = str
    try:
        parser.read(path)
    except Exception:
        continue
    for section in parser.sections():
        command_raw = parser.get(section, 'command', fallback='')
        actual_cmd = command_raw
        try:
            tokens = shlex.split(command_raw)
        except ValueError:
            tokens = []
        if tokens:
            if tokens[0].endswith('maestro-sandbox') and '--' in tokens:
                dash_index = tokens.index('--')
                tail = tokens[dash_index + 1 :]
                if len(tail) >= 3 and tail[0].endswith('/sh') and tail[1] in ('-c', '-lc'):
                    actual_cmd = tail[2]
            elif len(tokens) >= 3 and tokens[0].endswith('/sh') and tokens[1] in ('-c', '-lc'):
                actual_cmd = tokens[2]
        display_name = section.split(":", 1)[-1] if section.startswith("program:") else section
        items.append({
            'name': display_name,
            'user': parser.get(section, 'user', fallback=''),
            'directory': parser.get(section, 'directory', fallback=''),
            'status': status_map.get(display_name, ''),
            'command': actual_cmd,
        })

if fmt == 'json':
    print(json.dumps(items))
else:
    print(f"{'NAME':<20} {'USER':<16} {'DIRECTORY':<32} {'STATUS':<12} COMMAND")
    for item in items:
        directory = item['directory']
        if len(directory) > 32:
            directory = directory[:29] + '...'
        print(f"{item['name']:<20} {item['user']:<16} {directory:<32} {item['status']:<12} {item['command']}")
PY
