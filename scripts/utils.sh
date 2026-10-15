#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATHS_ENV="$ROOT_DIR/config/paths.env"

if [[ -f "$HOME/Library/Application Support/Mac Game Console/setup.json" ]]; then
  env_file="$(mktemp)"
  if ! /usr/bin/python3 "$ROOT_DIR/scripts/console.py" env > "$env_file"; then
    rm -f "$env_file"
    exit 1
  fi
  # Values are emitted by our backend using shlex.quote, never disk-supplied shell code.
  source "$env_file"
  rm -f "$env_file"
elif [[ -f "$PATHS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$PATHS_ENV"
else
  echo "Run bash scripts/setup.sh first (or use legacy config/paths.env)." >&2
  exit 1
fi
