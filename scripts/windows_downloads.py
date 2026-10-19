"""Official Windows launcher installers, downloaded (never run) into the game library's Downloads folder."""

import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import tempfile
import urllib.error
import urllib.parse
import urllib.request

FOLDER = "Downloads"
RECORD = ".couch-cube-downloads.json"
USER_AGENT = "CouchCube/0.3 (+https://github.com/marosige/couch-cube)"
MAX_BYTES = 1 << 30
SPACE_MARGIN = 64 << 20
CHUNK = 1 << 16

# Each start URL is linked from the vendor's own download page; redirects may only stay on the listed hosts.
LAUNCHERS = {
    "win-steam": {
        "name": "Steam (Windows)", "vendor": "Valve", "kind": "exe", "file": "SteamSetup.exe",
        "url": "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe",
        "hosts": {"cdn.akamai.steamstatic.com"},
    },
    "win-epic-games": {
        "name": "Epic Games Launcher (Windows)", "vendor": "Epic Games", "kind": "msi", "file": "EpicInstaller.msi",
        "url": "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi",
        "hosts": {"launcher-public-service-prod06.ol.epicgames.com", "epicgames-download1.akamaized.net"},
    },
    "win-gog-galaxy": {
        "name": "GOG Galaxy (Windows)", "vendor": "GOG", "kind": "exe", "file": "GOG_Galaxy_2.0.exe",
        "url": "https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe",
        "hosts": {"webinstallers.gog-statics.com"},
    },
    "win-ea": {
        "name": "EA app (Windows)", "vendor": "Electronic Arts", "kind": "exe", "file": "EAappInstaller.exe",
        "url": "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe",
        "hosts": {"origin-a.akamaihd.net"},
    },
    "win-battle-net": {
        "name": "Battle.net (Windows)", "vendor": "Blizzard", "kind": "exe", "file": "Battle.net-Setup.exe",
        "url": "https://downloader.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live",
        "hosts": {"downloader.battle.net"},
    },
}


class DownloadError(Exception):
    pass


class Cancelled(DownloadError):
    pass


def allowed_url(url, hosts):
    """Only plain https on the vendor's own hosts: no credentials, no custom ports."""
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError:
        return False
    return (parts.scheme == "https" and parts.hostname in hosts and parts.username is None
            and parts.password is None and port in (None, 443) and len(url) <= 2048)


class VendorRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5

    def __init__(self, hosts):
        super().__init__()
        self.hosts = hosts

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        newurl = urllib.parse.urljoin(req.full_url, newurl)
        if not allowed_url(newurl, self.hosts):
            raise DownloadError(f"The download redirected to an unexpected site ({urllib.parse.urlsplit(newurl).hostname}). Nothing was saved.")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def installer_kind(path):
    """'exe' for a Windows PE image, 'msi' for an OLE compound file, otherwise None."""
    with open(path, "rb") as file:
        head = file.read(64)
        if head.startswith(b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"):
            return "msi"
        if len(head) < 64 or not head.startswith(b"MZ"):
            return None
        offset = int.from_bytes(head[0x3C:0x40], "little")
        if offset < 64 or offset > 1 << 20:
            return None
        file.seek(offset)
        return "exe" if file.read(4) == b"PE\0\0" else None


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_name(name, kind, fallback):
    return name if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._ -]{0,100}\." + kind, name or "") else fallback


def confined(folder, name):
    path = folder / name
    if path.parent != folder or name in (".", "..") or "/" in name or path.is_symlink():
        raise DownloadError("Download path escapes the Downloads folder.")
    return path


def read_record(folder):
    path = folder / RECORD
    if path.is_symlink() or not path.is_file():
        return {}
    try:
        with path.open() as file:
            data = json.load(file)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_record(folder, record):
    with tempfile.NamedTemporaryFile("w", dir=folder, prefix=".record-", delete=False) as temp:
        json.dump(record, temp, indent=2)
        name = temp.name
    os.replace(name, folder / RECORD)


def status(folder):
    """Downloaded only when the recorded file is still there with the recorded size and type."""
    record = read_record(folder) if folder is not None and folder.is_dir() else {}
    items = []
    for identifier, launcher in LAUNCHERS.items():
        item = {"id": identifier, "name": launcher["name"], "vendor": launcher["vendor"], "kind": launcher["kind"],
                "downloaded": False, "file": None, "size": None, "sha256": None}
        entry = record.get(identifier)
        if isinstance(entry, dict) and isinstance(entry.get("file"), str):
            try:
                path = confined(folder, entry["file"])
                if path.is_file() and path.stat().st_size == entry.get("size"):
                    item.update(downloaded=True, file=str(path), size=entry["size"], sha256=entry.get("sha256"))
            except (DownloadError, OSError):
                pass
        items.append(item)
    return items


def place(partial, folder, name, digest):
    """Atomically publishes the finished file without ever replacing a different existing file."""
    stem, suffix = os.path.splitext(name)
    for number in range(1, 100):
        candidate = confined(folder, name if number == 1 else f"{stem} ({number}){suffix}")
        if candidate.exists():
            if candidate.is_file() and not candidate.is_symlink() and sha256(candidate) == digest:
                os.unlink(partial)
                return candidate
            continue
        try:
            os.link(partial, candidate)  # Fails instead of overwriting if the name appeared meanwhile.
        except FileExistsError:
            continue
        except OSError as exc:
            if exc.errno not in (errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EXDEV):
                raise
            if candidate.exists():
                continue
            os.rename(partial, candidate)
            return candidate
        os.unlink(partial)
        return candidate
    raise DownloadError("Too many files with this name in Downloads.")


def download(identifier, folder, progress=print, opener=None, check=lambda: None):
    launcher = LAUNCHERS.get(identifier)
    if launcher is None:
        raise DownloadError("Unknown Windows launcher.")
    if not allowed_url(launcher["url"], launcher["hosts"]):
        raise DownloadError("Launcher download URL is not on its vendor's site.")
    folder.mkdir(exist_ok=True)
    if folder.is_symlink() or not folder.is_dir():
        raise DownloadError("The Downloads folder is not a real folder.")
    opener = opener or urllib.request.build_opener(VendorRedirects(launcher["hosts"]))
    request = urllib.request.Request(launcher["url"], headers={"User-Agent": USER_AGENT})
    descriptor, partial = tempfile.mkstemp(dir=folder, prefix=f".{identifier}-", suffix=".partial")
    published = False

    def cancel(*_):
        raise Cancelled("Download canceled. Nothing was saved.")

    previous = signal.signal(signal.SIGTERM, cancel)
    try:
        try:
            response = opener.open(request, timeout=30)
        except urllib.error.HTTPError as exc:
            raise DownloadError(f"The vendor's server answered {exc.code}. Try again later.") from None
        except urllib.error.URLError as exc:
            if isinstance(exc.reason, DownloadError):
                raise exc.reason from None
            raise DownloadError("Couldn't reach the vendor's download server. Check your internet connection.") from None
        with response:
            final = response.geturl()
            if not allowed_url(final, launcher["hosts"]):
                raise DownloadError("The download ended on an unexpected site. Nothing was saved.")
            total = response.headers.get("Content-Length")
            total = int(total) if total and total.isdigit() else None
            if total is not None and total > MAX_BYTES:
                raise DownloadError("The installer is unexpectedly large. Nothing was saved.")
            free = os.statvfs(folder)
            if total is not None and free.f_bavail * free.f_frsize < total + SPACE_MARGIN:
                raise DownloadError("Not enough free space on this drive for the installer.")
            digest = hashlib.sha256()
            done = 0
            reported = -1
            with os.fdopen(descriptor, "wb") as file:
                descriptor = None
                while True:
                    try:
                        block = response.read(CHUNK)
                    except OSError:
                        raise DownloadError("The connection dropped during the download. Nothing was saved.") from None
                    if not block:
                        break
                    done += len(block)
                    if done > MAX_BYTES:
                        raise DownloadError("The installer is unexpectedly large. Nothing was saved.")
                    try:
                        file.write(block)
                    except OSError as exc:
                        if exc.errno == errno.ENOSPC:
                            raise DownloadError("The drive ran out of space. Nothing was saved.") from None
                        raise DownloadError("Couldn't write to the drive. Is it still connected?") from None
                    digest.update(block)
                    # Whole percents when the size is known, otherwise every megabyte.
                    step = done * 100 // total if total else done >> 20
                    if step != reported:
                        progress(f"PROGRESS {done} {total or 0}")
                        reported = step
                file.flush()
                os.fsync(file.fileno())
        if total is not None and done != total:
            raise DownloadError("The download was incomplete. Nothing was saved.")
        kind = installer_kind(partial)
        if kind != launcher["kind"]:
            raise DownloadError("The vendor's server didn't send a Windows installer. Nothing was saved.")
        check()
        name = safe_name(os.path.basename(urllib.parse.urlsplit(final).path), launcher["kind"], launcher["file"])
        path = place(partial, folder, name, digest.hexdigest())
        published = True
        record = read_record(folder)
        record[identifier] = {"file": path.name, "size": done, "sha256": digest.hexdigest(), "url": final}
        write_record(folder, record)
        return {"id": identifier, "file": str(path), "size": done, "sha256": digest.hexdigest()}
    finally:
        signal.signal(signal.SIGTERM, previous)
        if descriptor is not None:
            os.close(descriptor)
        if not published and os.path.exists(partial):
            os.unlink(partial)
