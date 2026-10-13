#!/bin/bash
# Measures RamLume's CPU usage and memory footprint over a period.
# Usage: scripts/measure-usage.sh [seconds]   (default 120; RamLume must be running)
set -euo pipefail

DURATION="${1:-120}"
PID="$(pgrep -x RamLume | head -n 1 || true)"
if [[ -z "$PID" ]]; then
  echo "RamLume isn't running." >&2
  exit 1
fi

cpu_seconds() {
  # ps prints cumulative CPU time as [[dd-]hh:]mm:ss.ss
  ps -o time= -p "$PID" | awk '{
    n = split($1, parts, ":"); seconds = 0
    for (i = 1; i <= n; i++) seconds = seconds * 60 + parts[i]
    print seconds
  }'
}

START="$(cpu_seconds)"
sleep "$DURATION"
END="$(cpu_seconds)"

awk -v start="$START" -v end="$END" -v duration="$DURATION" 'BEGIN {
  used = end - start
  printf "CPU time: %.2f s over %d s = %.2f%% of one core\n", used, duration, used / duration * 100
}'
footprint -p "$PID" 2>/dev/null | sed -n 's/.*Footprint: /Memory footprint: /p' || echo "footprint tool unavailable"
