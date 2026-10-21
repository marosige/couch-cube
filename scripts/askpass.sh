#!/bin/sh
# SUDO_ASKPASS helper: Homebrew runs `sudo -A` when an app's install or update needs administrator
# rights (Steam's updater, for example). This shows macOS's own password dialog; nothing is stored.
exec /usr/bin/osascript \
  -e 'display dialog "Homebrew needs your Mac password to finish installing, updating or removing this app. Couch Cube never stores it." with title "Couch Cube" default answer "" with hidden answer with icon caution buttons {"Cancel", "OK"} default button "OK"' \
  -e 'text returned of result'
