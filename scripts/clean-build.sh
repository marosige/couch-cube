#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/python3 - "$ROOT" "$@" <<'PY'
import fnmatch
import os
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve(strict=True)
# --keep PATTERN leaves matching top-level entries alone, e.g. the app someone is running.
args = sys.argv[2:]
keep = [args[i + 1] for i, arg in enumerate(args[:-1]) if arg == "--keep"]
build = root / "build"
if build.is_symlink():
    raise SystemExit("Refusing to clean a symlinked build directory.")
if build.exists():
    if not build.is_dir():
        raise SystemExit("Build path is not a directory.")
    for directory, children, _ in os.walk(build, followlinks=False):
        if os.path.ismount(directory) or any(
            os.path.ismount(Path(directory) / child) for child in children
        ):
            raise SystemExit("A volume is mounted inside build/. Eject it before building.")
    for child in build.iterdir():
        if any(fnmatch.fnmatch(child.name, pattern) for pattern in keep):
            continue
        if child.is_symlink() or not child.is_dir():
            child.unlink()
        else:
            shutil.rmtree(child)
else:
    build.mkdir()
PY
