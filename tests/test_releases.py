import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location("releases", Path(__file__).resolve().parents[1] / "scripts/releases.py")
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.config = {"repository": "marosige/couch-cube", "version": "0.1.0", "build": 1,
                       "asset_prefix": "CouchCube", "app_name": "CouchCube.app",
                       "bundle_id": "me.marosi.couchcube"}
        configuration = patch.object(releases, "configuration", return_value=self.config)
        configuration.start()
        self.addCleanup(configuration.stop)
        self.image = b"DMG fixture; never mounted by tests"
        self.filename = "CouchCube-0.4.0-arm64.dmg"
        self.asset = {"name": self.filename, "browser_download_url":
                      "https://github.com/marosige/couch-cube/releases/download/v0.4.0/" + self.filename,
                      "digest": "sha256:" + hashlib.sha256(self.image).hexdigest()}
        self.metadata = {"tag_name": "v0.4.0", "draft": False, "prerelease": False, "assets": [self.asset]}

    def download(self):
        def fetch(url, limit):
            return json.dumps([self.metadata]).encode() if "/releases?" in url else self.image
        return patch.object(releases, "fetch", side_effect=fetch)

    def test_latest_only_requires_one_dmg_with_github_digest(self):
        with self.download():
            report = releases.latest()
        self.assertTrue(report["available"])
        self.assertEqual(list(report["assets"]), [self.filename])

    def test_missing_asset_unexpected_url_and_prerelease_refused(self):
        for key, value in [("assets", []), ("prerelease", True), ("draft", True), ("tag_name", "../../bad")]:
            with patch.object(releases, "fetch", return_value=json.dumps([dict(self.metadata, **{key: value})]).encode()):
                with self.assertRaises(releases.ReleaseError):
                    releases.latest()
        self.asset["browser_download_url"] = "https://example.com/installer.dmg"
        with self.download(), self.assertRaisesRegex(releases.ReleaseError, "URL"):
            releases.latest()

    def test_semver_ordering(self):
        ordered = ["0.1.0-alpha.1", "0.1.0-alpha.2", "0.1.0-alpha.10", "0.1.0-beta.1",
                   "0.1.0-rc.1", "0.1.0", "0.1.1-alpha.1", "0.1.1", "0.2.0", "1.0.0"]
        self.assertEqual(sorted(ordered, key=releases.version), ordered)
        for bad in ["0.1", "v0.1-alpha.1", "0.1.0-dev.1", "0.1.0-alpha", None]:
            with self.assertRaises(releases.ReleaseError):
                releases.version(bad)

    def prerelease(self, tag):
        name = f"CouchCube-{tag[1:]}-arm64.dmg"
        return {"tag_name": tag, "draft": False, "prerelease": True, "assets": [dict(
            self.asset, name=name,
            browser_download_url=f"https://github.com/marosige/couch-cube/releases/download/{tag}/{name}")]}

    def test_stable_app_ignores_prereleases(self):
        listing = [self.prerelease("v0.5.0-alpha.1"), self.metadata]
        with patch.object(releases, "fetch", return_value=json.dumps(listing).encode()):
            self.assertEqual(releases.latest()["version"], "0.4.0")

    def test_prerelease_app_follows_newest_prerelease(self):
        self.config["version"] = "0.1.0-alpha.1"
        listing = [self.prerelease("v0.1.0-alpha.2"), self.prerelease("v0.1.0-alpha.10"),
                   self.prerelease("v0.1.0-alpha.1")]
        with patch.object(releases, "fetch", return_value=json.dumps(listing).encode()):
            report = releases.latest()
        self.assertEqual(report["version"], "0.1.0-alpha.10")
        self.assertTrue(report["available"])
        self.assertEqual(report["filename"], "CouchCube-0.1.0-alpha.10-arm64.dmg")

    def test_prerelease_flag_must_match_tag(self):
        self.config["version"] = "0.1.0-alpha.1"
        mismatched = dict(self.prerelease("v0.2.0-alpha.1"), prerelease=False)
        with patch.object(releases, "fetch", return_value=json.dumps([mismatched]).encode()):
            with self.assertRaisesRegex(releases.ReleaseError, "No public release"):
                releases.latest()

    def test_missing_or_invalid_github_digest_refused(self):
        for digest in [None, "", "sha256:bad", "md5:" + "0" * 64]:
            self.asset["digest"] = digest
            with self.download(), self.assertRaisesRegex(releases.ReleaseError, "digest"):
                releases.latest()

    def test_unpublished_release_reports_actionable_error(self):
        error = urllib.error.HTTPError("https://api.github.com/test", 404, "Not found", {}, None)
        with patch.object(releases.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(releases.ReleaseError, "No public release"):
                releases.latest()


if __name__ == "__main__":
    unittest.main()
