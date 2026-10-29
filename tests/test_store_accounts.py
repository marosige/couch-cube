import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("store_accounts", ROOT / "scripts/store_accounts.py")
sa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sa)

LOGINUSERS = '''"users"
{
\t"76561198000000001"
\t{
\t\t"AccountName"\t\t"older_acct"
\t\t"PersonaName"\t\t"Old Persona"
\t\t"RememberPassword"\t\t"1"
\t\t"MostRecent"\t\t"0"
\t\t"Timestamp"\t\t"1600000000"
\t}
\t"76561198000000002"
\t{
\t\t"AccountName"\t\t"main_acct"
\t\t"PersonaName"\t\t"Couch \\"Pro\\""
\t\t"WantsOfflineMode"\t\t"0"
\t\t"AllowAutoLogin"\t\t"1"
\t\t"MostRecent"\t\t"1"
\t\t"Timestamp"\t\t"1700000000"
\t}
}
'''


def write(path, text=""):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


class LoginUsersTests(unittest.TestCase):
    def test_most_recent_first_with_names_only(self):
        accounts = sa.parse_loginusers(LOGINUSERS)
        self.assertEqual([a["account"] for a in accounts], ["main_acct", "older_acct"])
        self.assertEqual(accounts[0]["persona"], 'Couch "Pro"')
        self.assertTrue(accounts[0]["most_recent"])
        self.assertEqual(set(accounts[0]), {"account", "persona", "most_recent", "steam_id"})

    def test_without_most_recent_flag_newest_timestamp_wins(self):
        text = LOGINUSERS.replace('"MostRecent"\t\t"1"', '"MostRecent"\t\t"0"')
        accounts = sa.parse_loginusers(text)
        self.assertEqual(accounts[0]["account"], "main_acct")
        self.assertTrue(accounts[0]["most_recent"])

    def test_ignores_unknown_keys_and_rejects_malformed(self):
        text = LOGINUSERS.replace('"AllowAutoLogin"', '"SomeToken"\t"secret-value"\n\t\t"AllowAutoLogin"')
        self.assertNotIn("secret-value", json.dumps(sa.parse_loginusers(text)))
        self.assertEqual(sa.parse_loginusers('"users" { "1" { "AccountName" "x" }'), [])
        self.assertEqual(sa.parse_loginusers("not vdf at all"), [])
        self.assertEqual(sa.parse_loginusers('"users" { "1" { "PersonaName" "no account" } }'), [])

    def test_empty_users_is_not_signed_in(self):
        self.assertEqual(sa.parse_loginusers('"users"\n{\n}\n'), [])
        row = sa.steam_row("mac-steam", "Steam", True, [])
        self.assertEqual(row["state"], "not_signed_in")


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def bottle(self, host, name):
        base = {"CrossOver": "Library/Application Support/CrossOver/Bottles",
                "Whisky": "Library/Containers/com.isaacmarovitz.Whisky/Bottles"}[host]
        drive = self.home / base / name / "drive_c"
        drive.mkdir(parents=True)
        return drive

    def test_mac_steam_states(self):
        report = sa.status(self.home, mac_steam_installed=False)
        self.assertEqual(report["clients"][0]["state"], "not_installed")
        report = sa.status(self.home, mac_steam_installed=True)
        self.assertEqual(report["clients"][0]["state"], "not_signed_in")
        write(self.home / "Library/Application Support/Steam/config/loginusers.vdf", LOGINUSERS)
        report = sa.status(self.home, mac_steam_installed=True)
        mac = report["clients"][0]
        self.assertEqual((mac["state"], mac["account"]), ("signed_in", "main_acct"))
        self.assertEqual(mac["detail"], 'Signed in as Couch "Pro" (main_acct)')
        self.assertEqual((report["installed"], report["signed_in"]), (1, 1))

    def test_windows_launchers_in_bottles(self):
        drive = self.bottle("CrossOver", "Games")
        write(drive / "Program Files (x86)/Steam/steam.exe")
        write(drive / "Program Files (x86)/Steam/config/loginusers.vdf", LOGINUSERS)
        write(drive / "Program Files (x86)/GOG Galaxy/GalaxyClient.exe")
        other = self.bottle("Whisky", "B1")
        write(other / "Program Files (x86)/Battle.net/Battle.net Launcher.exe")
        rows = {row["id"]: row for row in sa.status(self.home, mac_steam_installed=False)["clients"]}
        self.assertEqual(rows["win-steam"]["state"], "signed_in")
        self.assertEqual((rows["win-steam"]["host"], rows["win-steam"]["bottle"]), ("CrossOver", "Games"))
        self.assertEqual(rows["win-gog"]["state"], "installed")
        self.assertEqual(rows["win-gog"]["detail"], "Installed — sign in inside the launcher")
        self.assertNotIn("account", rows["win-gog"])
        self.assertEqual(rows["win-battlenet"]["host"], "Whisky")
        self.assertEqual(rows["win-epic"]["state"], "not_installed")
        self.assertEqual(rows["win-ea"]["detail"], "Not installed")

    def test_symlinked_executable_outside_bottle_is_ignored(self):
        drive = self.bottle("CrossOver", "Games")
        outside = write(self.home / "elsewhere/GalaxyClient.exe")
        (drive / "Program Files (x86)/GOG Galaxy").mkdir(parents=True)
        os.symlink(outside, drive / "Program Files (x86)/GOG Galaxy/GalaxyClient.exe")
        rows = {row["id"]: row for row in sa.status(self.home, mac_steam_installed=False)["clients"]}
        self.assertEqual(rows["win-gog"]["state"], "not_installed")

    def test_oversized_loginusers_is_not_read(self):
        write(self.home / "Library/Application Support/Steam/config/loginusers.vdf", LOGINUSERS + " " * sa.MAX_VDF_BYTES)
        self.assertEqual(sa.status(self.home, mac_steam_installed=True)["clients"][0]["state"], "not_signed_in")

    def test_open_command_is_derived_from_scan(self):
        self.assertEqual(sa.open_command("mac-steam", self.home), ["/usr/bin/open", "-W", "-b", sa.MAC_STEAM_BUNDLE])
        with self.assertRaises(ValueError):
            sa.open_command("win-gog", self.home)
        with self.assertRaises(ValueError):
            sa.open_command("../../bin/sh", self.home)
        drive = self.bottle("CrossOver", "Games")
        exe = write(drive / "Program Files (x86)/GOG Galaxy/GalaxyClient.exe")
        with self.assertRaises(ValueError):
            sa.open_command("win-gog", self.home, app_dirs=(str(self.home / "none"),))
        wine = write(self.home / "Apps/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine")
        self.assertEqual(sa.open_command("win-gog", self.home, app_dirs=(str(self.home / "Apps"),)),
                         [str(wine), "--bottle", "Games", str(exe)])
        other = self.bottle("Whisky", "B1")
        write(other / "Program Files/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe")
        self.assertEqual(sa.open_command("win-ea", self.home), ["/usr/bin/open", "-W", "-b", sa.WHISKY_BUNDLE])


class NoSecretsTests(unittest.TestCase):
    """Static scan: sign-in status code reads names only and never touches credentials or web data."""

    def store_accounts_swift(self):
        models = (ROOT / "setup/CouchCube/AppModels.swift").read_text()
        start = models.index("struct StoreAccountName")
        end = models.index("struct WindowsDownloadItem")
        return models[start:end] + (ROOT / "setup/CouchCube/SetupController+StoreAccounts.swift").read_text()

    def test_backend_reads_only_loginusers(self):
        source = (ROOT / "scripts/store_accounts.py").read_text()
        code = re.sub(r'""".*?"""', "", source, flags=re.S)
        for forbidden in ["config.vdf", "local.vdf", "ssfn", "password", "token", "cookie", "GameUserSettings",
                          "Battle.net.config", "keychain", "security find", "urllib", "requests", "socket"]:
            self.assertNotIn(forbidden.lower(), code.lower(), forbidden)
        self.assertEqual(sa.ALLOWED_USER_KEYS, ("accountname", "personaname", "mostrecent", "timestamp"))

    def test_swift_store_accounts_has_no_web_or_persistence(self):
        code = re.sub(r'//[^\n]*|"(?:\\.|[^"\\\n])*"', '""', self.store_accounts_swift())
        for forbidden in ["WKWebView", "WebKit", "WKWebsiteDataStore", "evaluateJavaScript", "UserDefaults",
                          "password", "token", "cookie", "HTTPCookie"]:
            self.assertNotIn(forbidden.lower(), code.lower(), forbidden)
        # Only Cube TV's site-restricted web apps may use WebKit; store accounts never open a web view.
        self.assertNotIn("import WebKit", "\n".join(
            path.read_text() for path in (ROOT / "setup/CouchCube").glob("*.swift") if path.name != "CubeTVWebApps.swift"))

    def test_usernames_are_not_logged(self):
        code = self.store_accounts_swift()
        for line in code.splitlines():
            if "append(" in line and '"' in line and "storeAccountsRows" not in line and "skipped" not in line:
                self.assertNotRegex(line, r"account|persona|detail", line)


if __name__ == "__main__":
    unittest.main()
