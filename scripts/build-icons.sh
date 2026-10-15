#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" != "--reuse-build" ]]; then
  bash "$ROOT/scripts/clean-build.sh"
fi
mkdir -p "$ROOT/build/module-cache"
xcrun swiftc -target arm64-apple-macos13.0 -swift-version 5 -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit "$ROOT/setup/GenerateIcon.swift" -o "$ROOT/build/generate-icon"
"$ROOT/build/generate-icon" "$ROOT/build/Console.iconset"
iconutil -c icns "$ROOT/build/Console.iconset" -o "$ROOT/build/Console.icns"
for variant in Console Installer Portable; do
  case "$variant" in
    Console) name="icon" ;;
    Installer) name="dmg-icon" ;;
    Portable) name="portable-icon" ;;
  esac
  if [[ "$variant" == Portable ]]; then
    "$ROOT/build/generate-icon" "$ROOT/build/Portable.iconset" --portable
    iconutil -c icns "$ROOT/build/Portable.iconset" -o "$ROOT/build/Portable.icns"
  elif [[ "$variant" == Installer ]]; then
    cp "$ROOT/build/Console.icns" "$ROOT/build/$variant.icns"
  fi
  if [[ "${1:-}" == "--export" ]]; then
    for size in 128 512 1024; do
      file="icon_${size}x${size}.png"
      if [[ "$size" == 1024 ]]; then file="icon_512x512@2x.png"; fi
      iconset=Console
      if [[ "$variant" == Portable ]]; then iconset=Portable; fi
      cp "$ROOT/build/$iconset.iconset/$file" "$ROOT/assets/$name-$size.png"
    done
    if [[ "$variant" == Installer ]]; then
      cp "$ROOT/assets/icon.svg" "$ROOT/assets/$name.svg"
    fi
  fi
done
