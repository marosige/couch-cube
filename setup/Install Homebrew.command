#!/bin/bash
set -euo pipefail
printf '%s\n' "Install the official Homebrew package manager on this Mac?" \
  "This downloads and executes https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh" \
  "Homebrew may request your administrator password in this Terminal window." \
  "No password is stored by Mac Game Console. Close this window to cancel."
read -r -p "Type INSTALL HOMEBREW to continue: " consent
if [[ "$consent" != "INSTALL HOMEBREW" ]]; then
  echo "Cancelled. No installer executed."
  exit 1
fi
installer="$(mktemp -t mac-console-homebrew)"
trap 'rm -f "$installer"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
if /bin/bash "$installer"; then
  echo "Homebrew installer completed. Return to Mac Game Console and refresh/check storage."
else
  echo "Homebrew installer failed or was cancelled. Read its error above; no automatic retry." >&2
  exit 1
fi
