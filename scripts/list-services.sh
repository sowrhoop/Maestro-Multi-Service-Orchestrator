#!/usr/bin/env sh
set -eu

FORMAT="table"
if [ "${1:-}" = "--json" ]; then FORMAT="json"; fi

collect() {
  for f in /etc/supervisor/conf.d/program-*.conf; do
    [ -f "$f" ] || continue
    name=$(sed -n 's/^\[program:\(.*\)\]/\1/p' "$f" | head -n1 || basename "$f" | sed 's/^program-//; s/\.conf$//')
    user=$(sed -n 's/^user=//p' "$f" | head -n1)
    dir=$(sed -n 's/^directory=//p' "$f" | head -n1)
    cmd=$(sed -n 's/^command=\/bin\/sh -c \"\(.*\)\"/\1/p' "$f" | head -n1)
    status=$(supervisorctl status "$name" 2>/dev/null | awk '{print $2" "$3}' | sed 's/\[//; s/\]//' || true)
    printf "%s\t%s\t%s\t%s\t%s\n" "$name" "$user" "$dir" "$status" "$cmd"
  done
}

if [ "$FORMAT" = "json" ]; then
  collect | python3 - <<'PY'
import sys, json
items=[]
for line in sys.stdin:
    name,user,dir,status,cmd = line.rstrip('\n').split('\t',4)
    items.append(dict(name=name,user=user,directory=dir,status=status,command=cmd))
print(json.dumps(items))
PY
else
  printf "%-20s %-16s %-28s %-12s %s\n" NAME USER DIRECTORY STATUS COMMAND
  collect | awk -F '\t' '{printf "%-20s %-16s %-28s %-12s %s\n", $1, $2, $3, $4, $5}'
fi

