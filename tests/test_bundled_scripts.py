from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BundledScriptsTests(unittest.TestCase):
    def test_every_helper_module_is_copied_into_the_app(self):
        """console.py loads its helpers by file name, so a module missing from the build only fails on a real Mac."""
        build = (ROOT / "scripts/build-setup-app.sh").read_text()
        verify = (ROOT / "scripts/verify-release.py").read_text()
        loaded = set()
        for script in (ROOT / "scripts").glob("*.py"):
            loaded.update(re.findall(r'with_name\("([\w.]+\.py)"\)', script.read_text()))
        self.assertTrue(loaded)
        for name in sorted(loaded):
            self.assertIn(f'"$ROOT/scripts/{name}"', build, f"{name} is loaded at runtime but not copied into the app")
            self.assertIn(f'"scripts/{name}"', verify, f"{name} isn't checked in the release DMG")

    def test_library_commands_name_their_library(self):
        """Library commands without --root fall back to a host setup file a local-only library never writes."""
        import re as regex
        actions = ["library-games", "rom-art", "game-art", "game-art-key", "emulate", "porting-kit-folder",
                   "console", "register", "launch", "index"]
        for source in (ROOT / "setup/CouchCube").glob("*.swift"):
            if source.name.endswith("SmokeTests.swift"):
                continue
            for line in source.read_text().splitlines():
                for call in regex.findall(r'(?:runBackendInBackground|execute)\((\w*\(?\["([\w-]+)"[^\]]*\])', line):
                    text, action = call
                    if action in actions:
                        self.assertTrue("--root" in text or text.startswith("libraryCommand"), f"{source.name}: {line.strip()}")


if __name__ == "__main__":
    unittest.main()
