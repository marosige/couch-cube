#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/python3 - "$ROOT" <<'PY'
import hashlib, json, pathlib, subprocess, sys, tarfile
root = pathlib.Path(sys.argv[1])
config = json.loads((root / "config/runtime.json").read_text())
cache = root / "build/runtime-cache"
cache.mkdir(parents=True, exist_ok=True)
archive = cache / (config["sha256"] + ".tar.gz")
if not archive.exists():
    subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--output",
                    str(archive), config["url"]], check=True)
if hashlib.sha256(archive.read_bytes()).hexdigest() != config["sha256"]:
    raise SystemExit("Runtime checksum mismatch. Remove the named runtime-cache archive and retry.")
destination = cache / config["sha256"]
if not (destination / "python/bin/python3").is_file():
    destination.mkdir(exist_ok=True)
    with tarfile.open(archive) as tar:
        for item in tar.getmembers():
            if item.name.startswith("/") or ".." in pathlib.PurePosixPath(item.name).parts:
                raise SystemExit("Unsafe runtime archive path")
            if item.isdev() or item.isfifo():
                raise SystemExit("Unsupported runtime archive entry")
            if item.issym() or item.islnk():
                target = pathlib.PurePosixPath(item.linkname)
                if target.is_absolute() or ".." in target.parts:
                    raise SystemExit("Unsupported runtime archive link")
        tar.extractall(destination)
print(destination / "python")
PY
