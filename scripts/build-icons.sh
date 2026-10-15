#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/module-cache"
xcrun swiftc -target arm64-apple-macos13.0 -swift-version 5 -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit "$ROOT/setup/GenerateIcon.swift" -o "$ROOT/build/generate-icon"
for variant in Console Installer Portable; do
  case "$variant" in
    Console) flag=""; name="icon" ;;
    Installer) flag="--installer"; name="dmg-icon" ;;
    Portable) flag="--portable"; name="portable-icon" ;;
  esac
  "$ROOT/build/generate-icon" "$ROOT/build/$variant.iconset" "$flag"
  iconutil -c icns "$ROOT/build/$variant.iconset" -o "$ROOT/build/$variant.icns"
  if [[ "${1:-}" == "--export" ]]; then
    for size in 128 512 1024; do
      file="icon_${size}x${size}.png"
      if [[ "$size" == 1024 ]]; then file="icon_512x512@2x.png"; fi
      cp "$ROOT/build/$variant.iconset/$file" "$ROOT/assets/$name-$size.png"
    done
  fi
done
