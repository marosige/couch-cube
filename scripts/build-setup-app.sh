#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Mac Game Console Setup.app"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Build requires macOS and Apple Command Line Tools (xcode-select --install)." >&2
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit "$ROOT/setup/ConsoleSetup.swift" -o "$APP/Contents/MacOS/ConsoleSetup"
cp "$ROOT/scripts/console.py" "$APP/Contents/Resources/scripts/console.py"
cp "$ROOT/README.md" "$APP/Contents/Resources/README.md"
/usr/bin/python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleName": "Mac Game Console Setup",
    "CFBundleIdentifier": "org.macgameconsole.setup",
    "CFBundleExecutable": "ConsoleSetup",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "1",
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
}))
PY
echo "$APP"
if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
