#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT/scripts/build-setup-app.sh"
APP="$ROOT/build/MacCouchConsole.app"
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
ditto "$APP" "$STAGE/MacCouchConsole.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/README.md" "$STAGE/README.md"
cp "$ROOT/setup/Start Here.txt" "$STAGE/Start Here.txt"
cp "$ROOT/build/Installer.icns" "$STAGE/.VolumeIcon.icns"
DMG="$ROOT/build/MacCouchConsole-0.3.0-arm64.dmg"
ZIP="$ROOT/build/MacCouchConsole-0.3.0-arm64.zip"
PORTABLE="$WORK/portable/MacCouchConsole.app"
ditto "$APP" "$PORTABLE"
cp "$ROOT/build/Portable.icns" "$PORTABLE/Contents/Resources/Console.icns"
/usr/libexec/PlistBuddy -c "Set :MCCDistribution portable" "$PORTABLE/Contents/Info.plist"
codesign --force --deep --sign - "$PORTABLE"
ditto -c -k --sequesterRsrc --keepParent "$PORTABLE" "$ZIP"
hdiutil create -ov -format UDRW -volname "Mac Couch Console" -srcfolder "$STAGE" "$WORK/writable.dmg"
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
  shasum -a 256 "$(basename "$ZIP")" > "$ZIP.sha256"
)
echo "$DMG"
echo "$ZIP"
