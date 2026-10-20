#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build-setup-app.sh"
APP="$ROOT/build/CouchCube.app"
WORK="$(mktemp -d "$ROOT/build/dmg-work.XXXXXX")"
STAGE="$WORK/contents"
MOUNT="$WORK/mount"
ATTACHED=0
mkdir "$STAGE" "$MOUNT"
cleanup() {
  if [[ "$ATTACHED" == 1 ]]; then
    if ! hdiutil detach "$MOUNT"; then
      echo "Cannot detach build image at $MOUNT; temporary build files retained." >&2
      return 1
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
ditto "$APP" "$STAGE/CouchCube.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/README.md" "$STAGE/README.md"
cp "$ROOT/build/Installer.icns" "$STAGE/.VolumeIcon.icns"
DMG="$ROOT/build/CouchCube-0.1.0-arm64.dmg"
hdiutil create -ov -format UDRW -volname "Couch Cube" -srcfolder "$STAGE" "$WORK/writable.dmg"
hdiutil attach -readwrite -nobrowse -mountpoint "$MOUNT" "$WORK/writable.dmg"
ATTACHED=1
xcrun SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT"
ATTACHED=0
hdiutil convert -ov "$WORK/writable.dmg" -format UDZO -o "$DMG"
hdiutil verify "$DMG"
"$ROOT/build/generate-icon" --set-file-icon "$ROOT/build/Installer.icns" "$DMG"
(
  cd "$ROOT/build"
  shasum -a 256 "$(basename "$DMG")" > "$DMG.sha256"
)
echo "$DMG"
SSD_STAGE="$WORK/ssd"
mkdir "$SSD_STAGE"
ditto "$APP" "$SSD_STAGE/CouchCube.app"
"$APP/Contents/Resources/python/bin/python3" -I -B - "$APP" "$SSD_STAGE" <<'PY'
import importlib.util
from pathlib import Path
import sys
source = Path(sys.argv[1]) / "Contents/Resources/scripts/console.py"
spec = importlib.util.spec_from_file_location("backend", source)
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)
root = Path(sys.argv[2]) / backend.FOLDER
for folder in backend.SSD_FOLDERS:
    (root / folder).mkdir(parents=True, exist_ok=True)
(root / backend.SSD_TEMPLATE).write_text("Couch Cube SSD template v1\n")
PY
ditto -c -k --sequesterRsrc "$SSD_STAGE" "$ROOT/build/CouchCube-0.1.0-arm64-SSD.zip"
echo "$ROOT/build/CouchCube-0.1.0-arm64-SSD.zip"
