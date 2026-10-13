#!/bin/bash
# Prints RamLume's reading next to the system's own tools so the numbers can be compared.
# Usage: scripts/compare-with-system-tools.sh [path/to/RamLume.app]
set -euo pipefail

APP="${1:-}"
if [[ -z "$APP" ]]; then
  for candidate in /Applications/RamLume.app build/DerivedData/Build/Products/Release/RamLume.app build/DerivedData/Build/Products/Debug/RamLume.app; do
    if [[ -x "$candidate/Contents/MacOS/RamLume" ]]; then APP="$candidate"; break; fi
  done
fi
if [[ -z "$APP" || ! -x "$APP/Contents/MacOS/RamLume" ]]; then
  echo "RamLume.app not found. Build it first or pass its path." >&2
  exit 1
fi

echo "== RamLume ($APP) =="
"$APP/Contents/MacOS/RamLume" --dump-metrics
echo
echo "== vm_stat =="
vm_stat
echo
echo "== sysctl =="
sysctl hw.memsize hw.memsize_usable vm.swapusage kern.memorystatus_vm_pressure_level kern.memorystatus_level 2>/dev/null || true
echo
echo "Notes:"
echo "- vm_stat 'Pages free' excludes speculative pages, like RamLume's Free."
echo "- Counters change continuously; small differences between the two readings are expected."
