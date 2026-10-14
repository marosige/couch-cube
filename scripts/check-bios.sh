#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/utils.sh"

MAP="$ROOT_DIR/config/bios-map.csv"
missing=0

printf "Checking BIOS files in: %s\n\n" "$BIOS_ROOT"

while IFS=, read -r system filename notes; do
  [[ "$system" == "system" ]] && continue
  target="$BIOS_ROOT/$filename"
  if [[ -f "$target" ]]; then
    printf "[OK] %s (%s)\n" "$filename" "$system"
  else
    missing=$((missing + 1))
    printf "[MISSING] %s (%s)\n" "$filename" "$system"
    printf "  expected path: %s\n" "$target"
    printf "  documentation search: https://www.google.com/search?q=%s+libretro+BIOS+documentation\n" "$filename"
    printf "  note: %s\n" "$notes"
  fi
  printf "\n"
done < "$MAP"

echo "Supply only BIOS dumps you are entitled to use. Presence checks do not validate authenticity."
if [[ $missing -gt 0 ]]; then
  echo "Total missing BIOS files: $missing"
  exit 2
else
  echo "All listed BIOS files are present."
fi
