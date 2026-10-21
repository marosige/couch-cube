#!/usr/bin/env python3
"""The single source of the Couch Cube version: config/release.json.

  version.py get <field>    version | short | build | tag | dmg | zip | prerelease | bundle_id
  version.py bump <part>    alpha | beta | rc | patch | minor | major | release

Versions follow SemVer (https://semver.org): MAJOR.MINOR.PATCH with an
optional -alpha.N / -beta.N / -rc.N pre-release. Every bump also increases
the integer build number used as CFBundleVersion.
"""
import json
from pathlib import Path
import re
import sys

CONFIG = Path(__file__).resolve().parent.parent / "config/release.json"
PATTERN = re.compile(r"(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?")
STAGES = ["alpha", "beta", "rc"]


def parse(value):
    match = PATTERN.fullmatch(value)
    if not match:
        raise SystemExit(f"Not a supported version: {value!r} (expected e.g. 0.1.0 or 0.1.0-alpha.1)")
    major, minor, patch, stage, number = match.groups()
    return int(major), int(minor), int(patch), stage, int(number) if number else None


def bumped(value, part):
    major, minor, patch, stage, number = parse(value)
    core = f"{major}.{minor}.{patch}"
    if part in STAGES:
        if stage == part:
            return f"{core}-{part}.{number + 1}"
        if stage is not None and STAGES.index(part) < STAGES.index(stage):
            raise SystemExit(f"Cannot go back from {stage} to {part}.")
        if stage is None:
            core = f"{major}.{minor}.{patch + 1}"
        return f"{core}-{part}.1"
    if part == "release":
        if stage is None:
            raise SystemExit(f"{value} is already a stable release.")
        return core
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "major":
        return f"{major + 1}.0.0"
    raise SystemExit(f"Unknown bump: {part}")


def field(config, name):
    version = config["version"]
    major, minor, patch, stage, _ = parse(version)
    asset = f"{config['asset_prefix']}-{version}-arm64"
    return {
        "version": version,
        "short": f"{major}.{minor}.{patch}",
        "build": str(config["build"]),
        "tag": "v" + version,
        "dmg": asset + ".dmg",
        "zip": asset + "-SSD.zip",
        "prerelease": "true" if stage else "false",
        "bundle_id": config["bundle_id"],
    }[name]


def main(args):
    config = json.loads(CONFIG.read_text())
    if len(args) == 2 and args[0] == "get":
        print(field(config, args[1]))
    elif len(args) == 2 and args[0] == "bump":
        config["version"] = bumped(config["version"], args[1])
        config["build"] = int(config["build"]) + 1
        CONFIG.write_text(json.dumps(config, indent=2) + "\n")
        print(config["version"])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
