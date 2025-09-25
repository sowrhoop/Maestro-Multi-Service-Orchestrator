#!/usr/bin/env sh
set -eu

FORMAT="table"
if [ "${1:-}" = "--json" ]; then
  FORMAT="json"
fi

python3 - "$FORMAT" <<'PY'
import sys, glob, configparser, shlex, subprocess, json

fmt = sys.argv[1]
files = sorted(glob.glob('/etc/supervisor/conf.d/program-*.conf'))
status_map = {}
try:
    proc = subprocess.run(['supervisorctl', 'status'], check=False, capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        parts = line.split()
        if not parts:
            continue
        name = parts[0]
        status = ' '.join(parts[1:3]).strip('[]') if len(parts) > 1 else ''
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
        try:
            tokens = shlex.split(command_raw)
        except ValueError:
            tokens = []
        actual_cmd = tokens[2] if len(tokens) >= 3 and tokens[0] == '/bin/sh' and tokens[1] == '-c' else command_raw
        items.append({
            'name': section,
            'user': parser.get(section, 'user', fallback=''),
            'directory': parser.get(section, 'directory', fallback=''),
            'status': status_map.get(section, ''),
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
