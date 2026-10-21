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


if __name__ == "__main__":
    unittest.main()
