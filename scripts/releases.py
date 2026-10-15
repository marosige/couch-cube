"""Public GitHub release discovery and verified portable-app staging."""

import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request


class ReleaseError(ValueError):
    pass


def configuration():
    path = Path(__file__).resolve().parent.parent / "config/release.json"
    return json.loads(path.read_text())


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"v?\d+\.\d+\.\d+", value):
        raise ReleaseError("Expected a stable release version such as v0.3.0.")
    return tuple(int(part) for part in value.removeprefix("v").split("."))


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
            raise ReleaseError("No public release is available yet. Publish a stable GitHub Release with the ARM64 DMG first.") from exc
        raise ReleaseError(f"GitHub returned HTTP {exc.code}. Check connectivity or API rate limits and try again.") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise ReleaseError(f"Cannot reach GitHub: {exc}. Check your internet connection and try again.") from exc


def latest():
    config = configuration()
    release = json.loads(fetch(f"https://api.github.com/repos/{config['repository']}/releases/latest", 2 * 1024 ** 2))
    if release.get("draft") is not False or release.get("prerelease") is not False:
        raise ReleaseError("Only published stable releases are supported.")
    tag = release["tag_name"]
    version(tag)
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


def stage(directory, run):
    config = configuration()
    release = latest()
    if version(release["version"]) < version(config["version"]):
        raise ReleaseError("The published release is older than this app. Publish the current release before preparing an SSD.")
    filename = release["filename"]
    archive = fetch(release["assets"][filename]["browser_download_url"], 512 * 1024 ** 2)
    digest = hashlib.sha256(archive).hexdigest()
    github_digest = release["assets"][filename]["digest"].lower()
    if github_digest != "sha256:" + digest:
        raise ReleaseError("DMG checksum mismatch against GitHub's asset digest. Nothing will be erased.")
    archive_path = directory / filename
    archive_path.write_bytes(archive)
    run(["/usr/bin/hdiutil", "verify", str(archive_path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    mount = directory / "image"
    mount.mkdir()
    run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(archive_path)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    extracted = directory / "extracted"
    extracted.mkdir()
    try:
        source = mount / config["app_name"]
        if source.is_symlink() or not source.is_dir():
            raise ReleaseError("DMG is missing a real Couch Cube app.")
        for path in source.rglob("*"):
            if path.is_symlink() and not path.resolve().is_relative_to(source.resolve()):
                raise ReleaseError("DMG app has an escaping symbolic link.")
            if not (path.is_file() or path.is_dir() or path.is_symlink()):
                raise ReleaseError("DMG app contains an unsupported file type.")
        run(["/usr/bin/ditto", str(source), str(extracted / config["app_name"])])
    finally:
        run(["/usr/bin/hdiutil", "detach", str(mount)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    app = extracted / config["app_name"]
    for path in app.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise ReleaseError("Extracted app has an escaping symbolic link.")
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("CFBundleIdentifier") != "org.macgameconsole.setup" or info.get("CFBundleShortVersionString") != release["version"]:
        raise ReleaseError("Downloaded app identity/version does not match the release.")
    if info.get("MCCDistribution") != "portable":
        if info.get("MCCDistribution") != "local":
            raise ReleaseError("Unrecognized app distribution in the DMG.")
    minimum = tuple(int(part) for part in info["LSMinimumSystemVersion"].split("."))
    current = tuple(int(part) for part in platform.mac_ver()[0].split("."))
    if current < minimum:
        raise ReleaseError("The newest portable app needs a newer macOS. Nothing will be erased.")
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    result = run(["/usr/bin/lipo", "-archs", str(binary)], stdout=subprocess.PIPE)
    if "arm64" not in result.stdout.decode().split():
        raise ReleaseError("The downloaded app does not support Apple Silicon.")
    return app
