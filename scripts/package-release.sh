#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build-setup-app.sh"
APP="$ROOT/build/CouchCube.app"
DMG="$ROOT/build/$(/usr/bin/python3 "$ROOT/scripts/version.py" get dmg)"
SSD_ZIP="$ROOT/build/$(/usr/bin/python3 "$ROOT/scripts/version.py" get zip)"
WORK="$(mktemp -d "$ROOT/build/dmg-work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# The installer window: titled background, the app, an arrow and Applications — nothing else.
"$ROOT/build/generate-icon" --dmg-background "$WORK/background.png" "$WORK/background@2x.png"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff"
# dmgbuild writes the Finder window layout directly (no Finder scripting), so it works on build machines.
VENV="$ROOT/build/dmg-venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  /usr/bin/python3 -m venv "$VENV"
  "$VENV/bin/python3" -m pip install --quiet --disable-pip-version-check "dmgbuild>=1.6,<2"
fi
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" -D background="$WORK/background.tiff" \
  -D icon="$ROOT/build/Installer.icns" "Couch Cube" "$DMG"
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
ditto -c -k --sequesterRsrc "$SSD_STAGE" "$SSD_ZIP"
echo "$SSD_ZIP"
