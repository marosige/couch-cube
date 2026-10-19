import re
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "setup/ConsoleSetup.swift").read_text()


class ActivityWindowReleaseTests(unittest.TestCase):
    """Release builds open Activity only from View > Activity; everything else goes through activityNeeded()."""

    def test_activity_is_only_shown_by_explicit_paths(self):
        calls = [SOURCE[:match.start()].count("\n") + 1 for match in re.finditer(r"\bshowActivity\(\)", SOURCE)]
        allowed = []
        for line_number in calls:
            line = SOURCE.splitlines()[line_number - 1]
            context = "\n".join(SOURCE.splitlines()[max(0, line_number - 4):line_number])
            if "func showActivity()" in line:
                continue
            if "SetupController.activityAutoOpens" in line or ".alertSecondButtonReturn" in line \
                    or '"--smoke-activity"' in context:
                allowed.append(line_number)
                continue
            self.fail(f"setup/ConsoleSetup.swift:{line_number} opens Activity automatically: {line.strip()}")
        self.assertEqual(len(allowed), 3)
        self.assertIn('addItem(withTitle: "Activity", action: #selector(showActivity)', SOURCE)

    def test_auto_open_requires_an_explicit_debug_flag(self):
        self.assertIn('static let activityAutoOpens = ProcessInfo.processInfo.environment["COUCH_CUBE_DEBUG_ACTIVITY"] == "1"', SOURCE)
        self.assertIn("panel.isRestorable = false", SOURCE)
        for script in (ROOT / "scripts").glob("*.sh"):
            self.assertNotIn("COUCH_CUBE_DEBUG_ACTIVITY", script.read_text(), script.name)
        self.assertIn('"COUCH_CUBE_DEBUG_ACTIVITY" not in', (ROOT / "scripts/verify-release.py").read_text())

    def test_app_store_operations_report_progress_in_the_row(self):
        self.assertIn("runAppOperation(app, action: action)", SOURCE)
        self.assertNotIn('execute(["manage-app"', SOURCE)


if __name__ == "__main__":
    unittest.main()
