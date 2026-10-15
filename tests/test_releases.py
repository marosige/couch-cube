import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location("releases", Path(__file__).resolve().parents[1] / "scripts/releases.py")
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = {"repository": "marosige/couch-cube", "version": "0.3.0",
                       "asset_prefix": "CouchCube", "app_name": "CouchCube.app"}
        configuration = patch.object(releases, "configuration", return_value=self.config)
        configuration.start()
        self.addCleanup(configuration.stop)
        self.image = b"DMG fixture; never mounted by tests"
        self.filename = "CouchCube-0.4.0-arm64.dmg"
        self.asset = {"name": self.filename, "browser_download_url":
                      "https://github.com/marosige/couch-cube/releases/download/v0.4.0/" + self.filename,
                      "digest": "sha256:" + hashlib.sha256(self.image).hexdigest()}
        self.metadata = {"tag_name": "v0.4.0", "draft": False, "prerelease": False, "assets": [self.asset]}
        self.version = "0.4.0"
        self.commands = []

    def download(self):
        def fetch(url, limit):
            return json.dumps(self.metadata).encode() if url.endswith("/latest") else self.image
        return patch.object(releases, "fetch", side_effect=fetch)

    def run_command(self, args, **kwargs):
        self.commands.append(args)
        if args[:2] == ["/usr/bin/hdiutil", "attach"]:
            app = Path(args[args.index("-mountpoint") + 1]) / "CouchCube.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "org.macgameconsole.setup",
                "CFBundleExecutable": "ConsoleSetup",
                "CFBundleShortVersionString": self.version,
                "LSMinimumSystemVersion": "13.0", "MCCDistribution": "local"}))
            (app / "Contents/MacOS/ConsoleSetup").write_bytes(b"fixture")
        elif args[0] == "/usr/bin/ditto":
            shutil.copytree(args[1], args[2])
        return subprocess.CompletedProcess(args, 0, stdout=b"arm64\n")

    def test_latest_only_requires_one_dmg_with_github_digest(self):
        with self.download():
            report = releases.latest()
        self.assertTrue(report["available"])
        self.assertEqual(list(report["assets"]), [self.filename])

    def test_missing_asset_unexpected_url_and_prerelease_refused(self):
        for key, value in [("assets", []), ("prerelease", True), ("draft", True), ("tag_name", "../../bad")]:
            with patch.object(releases, "fetch", return_value=json.dumps(dict(self.metadata, **{key: value})).encode()):
                with self.assertRaises(releases.ReleaseError):
                    releases.latest()
        self.asset["browser_download_url"] = "https://example.com/installer.dmg"
        with self.download(), self.assertRaisesRegex(releases.ReleaseError, "URL"):
            releases.latest()

    def test_missing_or_invalid_github_digest_refused(self):
        for digest in [None, "", "sha256:bad", "md5:" + "0" * 64]:
            self.asset["digest"] = digest
            with self.download(), self.assertRaisesRegex(releases.ReleaseError, "digest"):
                releases.latest()

    def test_unpublished_release_reports_actionable_error(self):
        error = urllib.error.HTTPError("https://api.github.com/test", 404, "Not found", {}, None)
        with patch.object(releases.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(releases.ReleaseError, "Publish a stable"):
                releases.latest()

    def test_dmg_verified_mounted_readonly_copied_and_detached(self):
        with tempfile.TemporaryDirectory() as directory, self.download(), \
                patch.object(releases.platform, "mac_ver", return_value=("13.0", (), "")):
            app = releases.stage(Path(directory), self.run_command)
            self.assertTrue((app / "Contents/Info.plist").is_file())
        self.assertEqual([args[0] for args in self.commands],
                         ["/usr/bin/hdiutil"] * 2 + ["/usr/bin/ditto", "/usr/bin/hdiutil",
                                                    "/usr/bin/codesign", "/usr/bin/lipo"])
        self.assertIn("-readonly", self.commands[1])

    def test_bad_checksum_never_mounts(self):
        self.image = b"tampered"
        with tempfile.TemporaryDirectory() as directory, self.download():
            with self.assertRaisesRegex(releases.ReleaseError, "checksum mismatch"):
                releases.stage(Path(directory), self.run_command)
        self.assertEqual(self.commands, [])

    def test_invalid_image_never_attaches(self):
        def run(args, **kwargs):
            raise subprocess.CalledProcessError(1, args)
        with tempfile.TemporaryDirectory() as directory, self.download():
            with self.assertRaises(subprocess.CalledProcessError):
                releases.stage(Path(directory), run)

    def test_escaping_symlink_refused_and_image_detached(self):
        def run(args, **kwargs):
            result = self.run_command(args, **kwargs)
            if args[:2] == ["/usr/bin/hdiutil", "attach"]:
                (Path(args[args.index("-mountpoint") + 1]) / "CouchCube.app/link").symlink_to("/tmp")
            return result
        with tempfile.TemporaryDirectory() as directory, self.download():
            with self.assertRaisesRegex(releases.ReleaseError, "escaping"):
                releases.stage(Path(directory), run)
        self.assertEqual(self.commands[-1][1], "detach")

    def test_wrong_bundle_version_and_unsupported_os_refused(self):
        for version, os_version in [("0.1.0", "13.0"), ("0.4.0", "12.0")]:
            self.version = version
            with tempfile.TemporaryDirectory() as directory, self.download(), \
                    patch.object(releases.platform, "mac_ver", return_value=(os_version, (), "")):
                with self.assertRaises(releases.ReleaseError):
                    releases.stage(Path(directory), self.run_command)

    def test_copy_failure_still_detaches(self):
        def run(args, **kwargs):
            if args[0] == "/usr/bin/ditto":
                raise subprocess.CalledProcessError(1, args)
            return self.run_command(args, **kwargs)
        with tempfile.TemporaryDirectory() as directory, self.download():
            with self.assertRaises(subprocess.CalledProcessError):
                releases.stage(Path(directory), run)
        self.assertEqual(self.commands[-1][1], "detach")


if __name__ == "__main__":
    unittest.main()
