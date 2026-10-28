#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/utils.sh"

MAP="$ROOT_DIR/config/bios-map.csv"
missing=0
segacd_found=0
saturn_found=0

printf "Checking BIOS files in: %s\n\n" "$BIOS_ROOT"

while IFS=, read -r system filename notes; do
  [[ "$system" == "system" ]] && continue
  target="$BIOS_ROOT/$filename"
  if [[ -f "$target" ]]; then
    printf "[OK] %s (%s)\n" "$filename" "$system"
    if [[ "$system" == "segacd" ]]; then segacd_found=1; fi
    if [[ "$system" == "saturn" ]]; then saturn_found=1; fi
  else
    case "$system" in
      psx) printf "[OPTIONAL ALTERNATIVE] %s (%s; one supported BIOS is enough; HLE fallback available)\n" "$filename" "$system" ;;
      dreamcast|nds|pcengine) printf "[OPTIONAL] %s (%s)\n" "$filename" "$system" ;;
      saturn) printf "[REGION NOT FOUND] %s (%s; one regional BIOS is enough)\n" "$filename" "$system" ;;
      segacd) printf "[REGION NOT FOUND] %s (%s; needed only for this region)\n" "$filename" "$system" ;;
      *) missing=$((missing + 1)); printf "[MISSING] %s (%s)\n" "$filename" "$system" ;;
    esac
    printf "  expected path: %s\n" "$target"
    printf "  documentation search: https://www.google.com/search?q=%s+libretro+BIOS+documentation\n" "$filename"
    printf "  note: %s\n" "$notes"
  fi
  printf "\n"
done < "$MAP"

if [[ $segacd_found -eq 0 ]]; then
  missing=$((missing + 1))
  echo "Sega CD: supply a BIOS for the region of your games."
fi
if [[ $saturn_found -eq 0 ]]; then
  missing=$((missing + 1))
  echo "Sega Saturn: supply a BIOS for the region of your games."
fi
echo "Supply only BIOS dumps you are entitled to use. Presence checks do not validate authenticity."
if [[ $missing -gt 0 ]]; then
  echo "Total missing required BIOS groups: $missing"
  exit 2
else
  echo "Required BIOS groups have a file present; review optional files and game regions above."
fi
