import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("version", ROOT / "scripts/version.py")
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)
spec = importlib.util.spec_from_file_location("releases_for_version", ROOT / "scripts/releases.py")
releases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(releases)


class VersionTests(unittest.TestCase):
    def test_bumps_follow_semver(self):
        cases = [("0.1.0-alpha.1", "alpha", "0.1.0-alpha.2"),
                 ("0.1.0-alpha.3", "beta", "0.1.0-beta.1"),
                 ("0.1.0-beta.2", "rc", "0.1.0-rc.1"),
                 ("0.1.0-rc.1", "release", "0.1.0"),
                 ("0.1.0", "alpha", "0.1.1-alpha.1"),
                 ("0.1.0", "patch", "0.1.1"),
                 ("0.1.3", "minor", "0.2.0"),
                 ("0.9.1", "major", "1.0.0")]
        for value, part, expected in cases:
            self.assertEqual(version.bumped(value, part), expected)
            self.assertGreater(releases.version(expected), releases.version(value))

    def test_bump_refuses_going_back(self):
        for value, part in [("0.1.0-beta.1", "alpha"), ("0.1.0", "release")]:
            with self.assertRaises(SystemExit):
                version.bumped(value, part)

    def test_repository_version_is_valid_and_bump_raises_build(self):
        config = json.loads(version.CONFIG.read_text())
        releases.version(config["version"])
        self.assertIsInstance(config["build"], int)
        with tempfile.TemporaryDirectory() as directory:
            copy = Path(directory) / "release.json"
            copy.write_text(json.dumps(dict(config, version="0.1.0-alpha.1", build=4)))
            with patch.object(version, "CONFIG", copy), patch("builtins.print"):
                version.main(["bump", "alpha"])
            self.assertEqual(json.loads(copy.read_text()), dict(config, version="0.1.0-alpha.2", build=5))
            self.assertEqual(version.field(json.loads(copy.read_text()), "dmg"), "CouchCube-0.1.0-alpha.2-arm64.dmg")


if __name__ == "__main__":
    unittest.main()
