import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import zipfile

spec = importlib.util.spec_from_file_location("releases", Path(__file__).resolve().parents[1] / "scripts/releases.py")
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = {"repository": "marosige/couch-cube", "version": "0.3.0",
                       "asset_prefix": "CouchCube", "app_name": "CouchCube.app"}
        self.configuration = patch.object(releases, "configuration", return_value=self.config)
        self.configuration.start()
        self.addCleanup(self.configuration.stop)
        self.filename = "CouchCube-0.4.0-arm64.zip"
        self.metadata = {"tag_name": "v0.4.0", "draft": False, "prerelease": False, "assets": [
            {"name": name, "browser_download_url":
             "https://github.com/marosige/couch-cube/releases/download/v0.4.0/" + name}
            for name in [self.filename, self.filename + ".sha256"]
        ]}

    def archive(self, extra=None, app_version="0.4.0"):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as zipped:
            zipped.writestr("CouchCube.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleIdentifier": "org.macgameconsole.setup",
                "CFBundleExecutable": "ConsoleSetup",
                "CFBundleShortVersionString": app_version,
                "LSMinimumSystemVersion": "13.0",
                "MCCDistribution": "portable",
            }))
            zipped.writestr("CouchCube.app/Contents/MacOS/ConsoleSetup", b"fixture, never executed")
            if extra:
                zipped.writestr(*extra)
        return data.getvalue()

    def download(self, archive, wrong_checksum=False):
        digest = "0" * 64 if wrong_checksum else hashlib.sha256(archive).hexdigest()
        def fetch(url, limit):
            if url.endswith("/latest"):
                return json.dumps(self.metadata).encode()
            if url.endswith(".sha256"):
                return (digest + "  " + self.filename + "\n").encode()
            return archive
        return patch.object(releases, "fetch", side_effect=fetch)

    def extract(self, args, **kwargs):
        if args[0] == "/usr/bin/ditto":
            with zipfile.ZipFile(args[3]) as zipped:
                zipped.extractall(args[4])
        return subprocess.CompletedProcess(args, 0, stdout=b"arm64\n")

    def test_latest_stable_asset_and_version(self):
        with patch.object(releases, "fetch", return_value=json.dumps(self.metadata).encode()):
            report = releases.latest()
        self.assertTrue(report["available"])
        self.assertEqual(report["version"], "0.4.0")
        self.assertEqual(report["url"], "https://github.com/marosige/couch-cube/releases/tag/v0.4.0")

    def test_missing_asset_unexpected_url_and_prerelease_refused(self):
        for key, value in [("assets", []), ("prerelease", True), ("tag_name", "../../bad")]:
            metadata = dict(self.metadata, **{key: value})
            with patch.object(releases, "fetch", return_value=json.dumps(metadata).encode()):
                with self.assertRaises(releases.ReleaseError):
                    releases.latest()
        self.metadata["assets"][0]["browser_download_url"] = "https://example.com/portable.zip"
        with patch.object(releases, "fetch", return_value=json.dumps(self.metadata).encode()):
            with self.assertRaisesRegex(releases.ReleaseError, "URL"):
                releases.latest()

    def test_unpublished_release_reports_actionable_error(self):
        error = urllib.error.HTTPError("https://api.github.com/test", 404, "Not found", {}, None)
        with patch.object(releases.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(releases.ReleaseError, "Publish a stable"):
                releases.latest()

    def test_verified_app_staged_without_execution(self):
        with tempfile.TemporaryDirectory() as directory, self.download(self.archive()), \
                patch.object(releases.platform, "mac_ver", return_value=("13.0", (), "")):
            commands = []
            def run(args, **kwargs):
                commands.append(args)
                return self.extract(args, **kwargs)
            app = releases.stage(Path(directory), run)
            self.assertTrue((app / "Contents/Info.plist").is_file())
            self.assertEqual([args[0] for args in commands], ["/usr/bin/ditto", "/usr/bin/codesign", "/usr/bin/lipo"])

    def test_bad_checksum_never_extracts(self):
        with tempfile.TemporaryDirectory() as directory, self.download(self.archive(), wrong_checksum=True), \
                patch.object(releases, "subprocess") as unused:
            with self.assertRaisesRegex(releases.ReleaseError, "checksum mismatch"):
                releases.stage(Path(directory), unused.run)
            unused.run.assert_not_called()

    def test_path_traversal_and_escaping_symlink_never_extract(self):
        symlink = zipfile.ZipInfo("CouchCube.app/link")
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        for extra in [("../outside", b"bad"), ("/absolute", b"bad"), (symlink, "../outside")]:
            with tempfile.TemporaryDirectory() as directory, self.download(self.archive(extra)), \
                    patch.object(releases, "subprocess") as unused:
                with self.assertRaises(releases.ReleaseError):
                    releases.stage(Path(directory), unused.run)
                unused.run.assert_not_called()

    def test_corrupt_zip_reports_error(self):
        with tempfile.TemporaryDirectory() as directory, self.download(b"not a zip"):
            with self.assertRaisesRegex(releases.ReleaseError, "valid ZIP"):
                releases.stage(Path(directory), self.extract)

    def test_wrong_bundle_version_and_unsupported_os_refused(self):
        for app_version, mac_version in [("0.1.0", "13.0"), ("0.4.0", "12.0")]:
            with tempfile.TemporaryDirectory() as directory, self.download(self.archive(app_version=app_version)), \
                    patch.object(releases.platform, "mac_ver", return_value=(mac_version, (), "")):
                with self.assertRaises(releases.ReleaseError):
                    releases.stage(Path(directory), self.extract)

    def test_signature_failure_propagates(self):
        def run(args, **kwargs):
            if args[0] == "/usr/bin/codesign":
                raise subprocess.CalledProcessError(1, args)
            return self.extract(args, **kwargs)
        with tempfile.TemporaryDirectory() as directory, self.download(self.archive()), \
                patch.object(releases.platform, "mac_ver", return_value=("13.0", (), "")):
            with self.assertRaises(subprocess.CalledProcessError):
                releases.stage(Path(directory), run)


if __name__ == "__main__":
    unittest.main()
