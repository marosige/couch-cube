#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CouchCube.app"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Build requires macOS and Apple Command Line Tools (xcode-select --install)." >&2
  exit 1
fi
bash "$ROOT/scripts/clean-build.sh"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts" "$APP/Contents/Resources/config" "$ROOT/build/module-cache"
RUNTIME="$(bash "$ROOT/scripts/prepare-runtime.sh")"
ditto "$RUNTIME" "$APP/Contents/Resources/python"
bash "$ROOT/scripts/build-icons.sh" --reuse-build
cp "$ROOT/build/Console.icns" "$APP/Contents/Resources/Console.icns"
cp "$ROOT/assets/header.png" "$APP/Contents/Resources/HomeHeader.png"
cp "$ROOT/assets/header-portable.png" "$APP/Contents/Resources/HomeHeaderPortable.png"
xcrun swiftc -target arm64-apple-macos13.0 -swift-version 5 -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit -framework GameController -framework CoreBluetooth -framework IOBluetooth \
  "$ROOT/setup/ConsoleSetup.swift" -o "$APP/Contents/MacOS/ConsoleSetup"
xcrun swiftc -target arm64-apple-macos13.0 -swift-version 5 -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit -framework GameController -framework IOKit \
  "$ROOT/setup/ConsoleAutoLaunch.swift" -o "$APP/Contents/MacOS/ConsoleAutoLaunch"
cp "$ROOT/scripts/console.py" "$APP/Contents/Resources/scripts/console.py"
cp "$ROOT/scripts/releases.py" "$APP/Contents/Resources/scripts/releases.py"
cp "$ROOT/scripts/deals.py" "$APP/Contents/Resources/scripts/deals.py"
cp "$ROOT/scripts/windows_downloads.py" "$APP/Contents/Resources/scripts/windows_downloads.py"
cp "$ROOT/scripts/store_accounts.py" "$APP/Contents/Resources/scripts/store_accounts.py"
cp "$ROOT/scripts/shop.py" "$APP/Contents/Resources/scripts/shop.py"
cp "$ROOT/scripts/wishlist.py" "$APP/Contents/Resources/scripts/wishlist.py"
cp "$ROOT/scripts/rates.py" "$APP/Contents/Resources/scripts/rates.py"
cp "$ROOT/config/release.json" "$APP/Contents/Resources/config/release.json"
cp "$ROOT/config/bios-map.csv" "$APP/Contents/Resources/config/bios-map.csv"
ditto "$ROOT/assets/app-icons" "$APP/Contents/Resources/AppIcons"
ditto "$ROOT/assets/tv-menus" "$APP/Contents/Resources/TVMenus"
cp "$ROOT/README.md" "$APP/Contents/Resources/README.md"
cp "$ROOT/setup/Install Homebrew.command" "$APP/Contents/Resources/Install Homebrew.command"
chmod +x "$APP/Contents/Resources/Install Homebrew.command"
/usr/bin/python3 - "$APP" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleName": "Couch Cube",
    "CFBundleDisplayName": "Couch Cube",
    "CFBundleIconFile": "Console",
    "MCCDistribution": "local",
    "CFBundleIdentifier": "org.macgameconsole.setup",
    "CFBundleExecutable": "ConsoleSetup",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": "3",
    "CFBundleShortVersionString": "0.3.0",
    "LSArchitecturePriority": ["arm64"],
    "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": True,
    "NSRemindersUsageDescription": "Add a reminder the day before a free game giveaway ends, only when you choose Remind Me.",
    "NSRemindersFullAccessUsageDescription": "Add a reminder the day before a free game giveaway ends, and check whether it still exists, only when you choose Remind Me.",
    "NSBluetoothAlwaysUsageDescription": "Show your paired game controllers and their Bluetooth connection status. Pairing and forgetting devices stay in macOS Bluetooth settings.",
}))
PY
codesign --force --deep --sign - "$APP"
echo "$APP"
if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
