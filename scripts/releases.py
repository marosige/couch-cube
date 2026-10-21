"""Public GitHub release discovery for the in-app update check."""

import json
from pathlib import Path
import re
import urllib.error
import urllib.parse
import urllib.request


class ReleaseError(ValueError):
    pass


def configuration():
    path = Path(__file__).resolve().parent.parent / "config/release.json"
    return json.loads(path.read_text())


SEMVER = re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:-((?:alpha|beta|rc)\.\d+))?")


def version(value):
    """SemVer sort key: 0.1.0-alpha.1 < 0.1.0-alpha.2 < 0.1.0-beta.1 < 0.1.0 < 0.1.1."""
    match = SEMVER.fullmatch(value) if isinstance(value, str) else None
    if not match:
        raise ReleaseError("Expected a release version such as v0.1.0 or v0.1.0-alpha.1.")
    major, minor, patch, pre = match.groups()
    if pre is None:
        return int(major), int(minor), int(patch), (1,)
    stage, number = pre.split(".")
    return int(major), int(minor), int(patch), (0, ["alpha", "beta", "rc"].index(stage), int(number))


def is_prerelease(value):
    return version(value)[3][0] == 0


def fetch(url, limit):
    request = urllib.request.Request(url, headers={
        "User-Agent": "Couch-Cube",
        "Accept": "application/vnd.github+json" if url.startswith("https://api.github.com/") else "application/octet-stream",
    })
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            final = urllib.parse.urlparse(response.url)
            if final.scheme != "https" or not (final.hostname in {"github.com", "api.github.com"}
                                              or (final.hostname or "").endswith(".githubusercontent.com")):
                raise ReleaseError("GitHub download redirected to an unsupported host.")
            data = response.read(limit + 1)
            if len(data) > limit:
                raise ReleaseError("GitHub response exceeds the supported size limit.")
            return data
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise ReleaseError("No public release is available yet. Publish a GitHub Release with the ARM64 DMG first.") from exc
        raise ReleaseError(f"GitHub returned HTTP {exc.code}. Check connectivity or API rate limits and try again.") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise ReleaseError(f"Cannot reach GitHub: {exc}. Check your internet connection and try again.") from exc


def latest():
    """Newest published release this app may update to.

    A stable app only follows stable releases; an alpha/beta/rc app also follows pre-releases.
    """
    config = configuration()
    include_prereleases = is_prerelease(config["version"])
    releases = json.loads(fetch(f"https://api.github.com/repos/{config['repository']}/releases?per_page=30",
                                2 * 1024 ** 2))
    candidates = []
    for release in releases if isinstance(releases, list) else []:
        tag = release.get("tag_name")
        if release.get("draft") is not False or not isinstance(tag, str) or not SEMVER.fullmatch(tag):
            continue
        if release.get("prerelease") is not is_prerelease(tag):
            continue
        if is_prerelease(tag) and not include_prereleases:
            continue
        candidates.append(release)
    if not candidates:
        raise ReleaseError("No public release is available yet. Publish a GitHub Release with the ARM64 DMG first.")
    release = max(candidates, key=lambda item: version(item["tag_name"]))
    tag = release["tag_name"]
    filename = f"{config['asset_prefix']}-{tag.removeprefix('v')}-arm64.dmg"
    assets = {}
    for name in [filename]:
        matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
        if len(matches) != 1:
            raise ReleaseError(f"The latest release is missing a unique {name} asset. Nothing will be erased.")
        asset = matches[0]
        expected = f"https://github.com/{config['repository']}/releases/download/{tag}/{name}"
        if asset.get("browser_download_url") != expected:
            raise ReleaseError("Unexpected release asset URL.")
        assets[name] = asset
        if not re.fullmatch(r"sha256:[a-fA-F0-9]{64}", asset.get("digest") or ""):
            raise ReleaseError("The release has no GitHub SHA-256 asset digest. Nothing will be erased.")
    return {"version": tag.removeprefix("v"), "available": version(tag) > version(config["version"]),
            "url": f"https://github.com/{config['repository']}/releases/tag/{tag}",
            "filename": filename, "assets": assets}
