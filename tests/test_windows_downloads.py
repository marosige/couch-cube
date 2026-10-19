import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("windows_downloads", ROOT / "scripts/windows_downloads.py")
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)


def pe(size=4096):
    body = bytearray(size)
    body[:2] = b"MZ"
    body[0x3C:0x40] = (0x80).to_bytes(4, "little")
    body[0x80:0x84] = b"PE\0\0"
    return bytes(body)


MSI = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + bytes(2048)


class FakeResponse(io.BytesIO):
    def __init__(self, body, url, length=True, fail_after=None):
        super().__init__(body)
        self.url = url
        self.headers = {"Content-Length": str(len(body))} if length else {}
        self.fail_after = fail_after

    def geturl(self):
        return self.url

    def read(self, size=-1):
        if self.fail_after is not None and self.tell() >= self.fail_after:
            raise ConnectionResetError("reset")
        return super().read(size)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    def __init__(self, response):
        self.response = response
        self.requests = []

    def open(self, request, timeout=None):
        self.requests.append(request)
        return self.response


class WindowsDownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name) / "Downloads"

    def tearDown(self):
        self.temp.cleanup()

    def files(self):
        return sorted(os.listdir(self.folder))

    def fetch(self, identifier, body, url=None, **kwargs):
        launcher = wd.LAUNCHERS[identifier]
        opener = FakeOpener(FakeResponse(body, url or launcher["url"], **{k: v for k, v in kwargs.items() if k in ("length", "fail_after")}))
        progress = []
        result = wd.download(identifier, self.folder, progress=progress.append, opener=opener,
                             check=kwargs.get("check", lambda: None))
        return result, progress, opener

    def test_every_launcher_starts_on_its_vendor_https_host(self):
        self.assertEqual(set(wd.LAUNCHERS), {"win-steam", "win-epic-games", "win-gog-galaxy", "win-ea", "win-battle-net"})
        for launcher in wd.LAUNCHERS.values():
            self.assertTrue(wd.allowed_url(launcher["url"], launcher["hosts"]))
            self.assertIn(launcher["kind"], ("exe", "msi"))

    def test_url_allowlist_rejects_other_hosts_schemes_credentials_and_ports(self):
        hosts = {"downloader.battle.net"}
        self.assertTrue(wd.allowed_url("https://downloader.battle.net/download/installer/win/1/Battle.net-Setup.exe", hosts))
        for url in ["http://downloader.battle.net/x.exe", "https://downloader.battle.net.evil.example/x.exe",
                    "https://evil.example/downloader.battle.net/x.exe", "https://user@downloader.battle.net/x.exe",
                    "https://downloader.battle.net:8443/x.exe", "ftp://downloader.battle.net/x.exe",
                    "https://downloader.battle.net:bad/x.exe", "https://downloader.battle.net/" + "a" * 2100]:
            self.assertFalse(wd.allowed_url(url, hosts), url)

    def test_redirect_to_unexpected_host_is_refused(self):
        handler = wd.VendorRedirects({"downloader.battle.net"})
        request = urllib.request.Request("https://downloader.battle.net/download/getInstallerForGame?os=win")
        allowed = handler.redirect_request(request, None, 302, "Found", {}, "/download/installer/win/1/Battle.net-Setup.exe")
        self.assertEqual(allowed.full_url, "https://downloader.battle.net/download/installer/win/1/Battle.net-Setup.exe")
        for target in ["https://mirror.example/Battle.net-Setup.exe", "http://downloader.battle.net/x.exe"]:
            with self.assertRaises(wd.DownloadError):
                handler.redirect_request(request, None, 302, "Found", {}, target)

    def test_final_url_off_vendor_saves_nothing(self):
        with self.assertRaises(wd.DownloadError):
            self.fetch("win-ea", pe(), url="https://mirror.example/EAappInstaller.exe")
        self.assertEqual(self.files(), [])

    def test_download_publishes_atomically_with_progress_and_record(self):
        result, progress, opener = self.fetch("win-steam", pe(300_000))
        self.assertEqual(opener.requests[0].get_header("User-agent"), wd.USER_AGENT)
        self.assertEqual(self.files(), [wd.RECORD, "SteamSetup.exe"])
        self.assertEqual(result["size"], 300_000)
        self.assertEqual(result["sha256"], wd.sha256(self.folder / "SteamSetup.exe"))
        self.assertEqual(progress[-1], "PROGRESS 300000 300000")
        self.assertLessEqual(len(progress), 101)
        status = {item["id"]: item for item in wd.status(self.folder)}
        self.assertTrue(status["win-steam"]["downloaded"])
        self.assertEqual(status["win-steam"]["file"], str(self.folder / "SteamSetup.exe"))
        self.assertFalse(status["win-ea"]["downloaded"])

    def test_msi_and_final_url_name(self):
        url = "https://epicgames-download1.akamaized.net/Builds/Installers/Windows/EpicInstaller-20.3.3.msi?x=1"
        result, _, _ = self.fetch("win-epic-games", MSI, url=url)
        self.assertEqual(Path(result["file"]).name, "EpicInstaller-20.3.3.msi")

    def test_non_installer_payloads_are_rejected_and_cleaned_up(self):
        for body in [b"<html>login</html>" * 50, b"MZ" + bytes(100), MSI]:
            with self.subTest(body=body[:8]):
                with self.assertRaises(wd.DownloadError):
                    self.fetch("win-gog-galaxy", body)
                self.assertEqual(self.files(), [])

    def test_installer_kind(self):
        path = Path(self.temp.name) / "probe"
        for body, kind in [(pe(), "exe"), (MSI, "msi"), (b"MZ" + bytes(62), None), (b"PK\x03\x04" + bytes(100), None)]:
            path.write_bytes(body)
            self.assertEqual(wd.installer_kind(path), kind)

    def test_interrupted_or_short_download_leaves_no_partial_file(self):
        with self.assertRaises(wd.DownloadError):
            self.fetch("win-ea", pe(500_000), fail_after=1 << 16)
        self.assertEqual(self.files(), [])
        response = FakeResponse(pe(1000), wd.LAUNCHERS["win-ea"]["url"])
        response.headers = {"Content-Length": "5000"}
        with self.assertRaises(wd.DownloadError):
            wd.download("win-ea", self.folder, progress=lambda _: None, opener=FakeOpener(response))
        self.assertEqual(self.files(), [])

    def test_cancel_removes_partial_file(self):
        def cancel(_):
            raise wd.Cancelled("Download canceled.")
        launcher = wd.LAUNCHERS["win-ea"]
        with self.assertRaises(wd.Cancelled):
            wd.download("win-ea", self.folder, progress=cancel, opener=FakeOpener(FakeResponse(pe(200_000), launcher["url"])))
        self.assertEqual(self.files(), [])

    def test_storage_change_before_publishing_saves_nothing(self):
        def gone():
            raise OSError("drive disconnected")
        with self.assertRaises(OSError):
            self.fetch("win-ea", pe(), check=gone)
        self.assertEqual(self.files(), [])

    def test_existing_different_file_is_never_overwritten(self):
        self.folder.mkdir()
        (self.folder / "EAappInstaller.exe").write_bytes(b"user's own file")
        result, _, _ = self.fetch("win-ea", pe())
        self.assertEqual(Path(result["file"]).name, "EAappInstaller (2).exe")
        self.assertEqual((self.folder / "EAappInstaller.exe").read_bytes(), b"user's own file")
        # The same installer again reuses the identical copy instead of adding another.
        again, _, _ = self.fetch("win-ea", pe())
        self.assertEqual(again["file"], result["file"])
        self.assertEqual(self.files(), [wd.RECORD, "EAappInstaller (2).exe", "EAappInstaller.exe"])

    def test_paths_stay_inside_downloads(self):
        self.folder.mkdir()
        for name in ["../escape.exe", "a/b.exe", "..", "."]:
            with self.assertRaises(wd.DownloadError):
                wd.confined(self.folder, name)
        self.assertEqual(wd.safe_name("../../x.exe", "exe", "SteamSetup.exe"), "SteamSetup.exe")
        self.assertEqual(wd.safe_name("Setup.msi", "exe", "SteamSetup.exe"), "SteamSetup.exe")
        outside = Path(self.temp.name) / "outside.exe"
        outside.write_bytes(pe())
        os.symlink(outside, self.folder / "SteamSetup.exe")
        with self.assertRaises(wd.DownloadError):
            self.fetch("win-steam", pe())
        self.assertEqual(outside.read_bytes(), pe())
        # A tampered record can't point status outside the folder.
        (self.folder / wd.RECORD).write_text(json.dumps({"win-ea": {"file": "../outside.exe", "size": len(pe())}}))
        self.assertFalse({item["id"]: item for item in wd.status(self.folder)}["win-ea"]["downloaded"])

    def test_symlinked_downloads_folder_is_refused(self):
        real = Path(self.temp.name) / "elsewhere"
        real.mkdir()
        os.symlink(real, self.folder)
        with self.assertRaises(wd.DownloadError):
            self.fetch("win-ea", pe())
        self.assertEqual(os.listdir(real), [])

    def test_status_transitions_when_file_changes_or_disappears(self):
        self.fetch("win-battle-net", pe())
        self.assertTrue(wd.status(self.folder)[4]["downloaded"])
        (self.folder / "Battle.net-Setup.exe").write_bytes(b"short")
        self.assertFalse(wd.status(self.folder)[4]["downloaded"])
        (self.folder / "Battle.net-Setup.exe").unlink()
        self.assertFalse(wd.status(self.folder)[4]["downloaded"])
        self.assertFalse(any(item["downloaded"] for item in wd.status(None)))

    def test_unknown_launcher_and_oversized_downloads(self):
        with self.assertRaises(wd.DownloadError):
            wd.download("win-unknown", self.folder)
        response = FakeResponse(pe(), wd.LAUNCHERS["win-ea"]["url"])
        response.headers = {"Content-Length": str(wd.MAX_BYTES + 1)}
        with self.assertRaises(wd.DownloadError):
            wd.download("win-ea", self.folder, progress=lambda _: None, opener=FakeOpener(response))
        self.assertEqual(self.files(), [])


if __name__ == "__main__":
    unittest.main()
