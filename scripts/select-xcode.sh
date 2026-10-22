#!/bin/bash
# CI: build with the newest installed Xcode 26 (or later), so the app links the macOS 26 SDK and gets the
# system's current look (Liquid Glass sidebar). Apps built with an older SDK keep the old look even on new macOS.
set -euo pipefail
xcode=$(ls -d /Applications/Xcode_2[6-9]*.app /Applications/Xcode_[3-9][0-9]*.app 2>/dev/null | sort -V | tail -1 || true)
if [ -z "$xcode" ]; then
  echo "No Xcode 26 or later on this runner; the build would lose the Liquid Glass look." >&2
  ls -d /Applications/Xcode*.app >&2 || true
  exit 1
fi
sudo xcode-select -s "$xcode/Contents/Developer"
xcodebuild -version
