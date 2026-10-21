# Couch Cube – notes for Claude

Native macOS (AppKit, Apple Silicon, macOS 13+) app that turns a Mac into a couch gaming console.
The owner is not a developer and communicates in Hungarian: answer in Hungarian, explain choices in
plain words, and make technical decisions (including versioning) yourself.
Keep every reply very short: a few lines, results only, no long explanations.

## Layout

- `setup/CouchCube/*.swift` – the app (`ConsoleSetup` binary). `SetupController.swift` holds all
  stored state, inits and overrides; behavior lives in `SetupController+<Area>.swift` extensions.
  Stored properties cannot live in extensions, so new state goes into `SetupController.swift`.
  Top-level models/views have their own files (`Models.swift`, `Controllers.swift`, `ShopModels.swift`…).
  `main.swift` is the entry point. Keep files to one area; split rather than grow past ~1,500 lines.
- `setup/ConsoleAutoLaunch.swift`, `setup/GenerateIcon.swift` – separate small binaries.
- `scripts/console.py` – backend CLI the app calls (JSON on stdout); helper modules beside it
  (`shop.py`, `deals.py`, `wishlist.py`, `rates.py`, `store_accounts.py`, `windows_downloads.py`, `releases.py`).
  Runs on the bundled Python 3.13 and must also run on macOS's `/usr/bin/python3` (3.9).
- `tests/` – `unittest` suite (no third-party packages). Some tests read Swift sources statically.
- `README.md` – user-facing. `DESIGN.md` – page-by-page UI/behavior spec; keep it in sync with UI changes.
  `ROADMAP.md` – the owner's goal and milestones; read it before planning features.
- UI review without a Mac: the **Screenshots** workflow (runs on pushes to `claude/**`) uploads a PNG of
  every page in light and dark mode; download the artifact and look at it.
- `docs/` – GitHub Pages website (couchcube.marosi.me), served from `main:/docs`.

## Checks

```sh
python3 -m unittest discover -s tests          # always, before every push
for s in scripts/*.sh; do bash -n "$s"; done
```

Swift only builds on macOS (`bash scripts/build-setup-app.sh`). No local compiler in cloud sessions:
push and watch the **Checks** workflow (`native-app` job on macos-14). The full DMG smoke test runs in
the **Release** workflow; start it by hand (workflow_dispatch) to verify without publishing.

## Versions and releases (Claude manages these)

- SemVer, single source `config/release.json` (`version`, integer `build`). Change it only with
  `python3 scripts/version.py bump <alpha|beta|rc|patch|minor|major|release>`; never edit version
  strings elsewhere (build scripts, workflows and verify-release read it).
- Info.plist: `CFBundleShortVersionString` = numeric core, `CFBundleVersion` = build,
  `CouchCubeVersion` = full SemVer (used by the update check).
- A version change merged to `main` triggers `.github/workflows/release.yml`: build, verify, then it
  creates tag `v<version>` and the GitHub release itself (pre-release for -alpha/-beta/-rc).
  Cloud sessions cannot push tags or edit releases, so never plan on doing that by hand.
- Current phase: `0.1.0-alpha.N` (untested on real hardware for SSD erase, login auto-launch and
  controller hotplug). Bump `alpha` for each test build the owner should try; move to `beta` once
  those flows are confirmed on a real Mac; `release` for 0.1.0.

## Identifiers

- Bundle ID `me.marosi.couchcube`; settings in `~/Library/Application Support/Couch Cube`.
- Pre-rename names are migrated, not used: `org.macgameconsole.setup` (UserDefaults copied once in
  `main.swift`), `Application Support/Mac Game Console` (`migrate_app_support()` in console.py).
- Intentionally kept as on-disk formats: the library marker `.mac-game-console.json` (on users' SSDs)
  and the LaunchAgent label `com.mac-game-console.steam-big-picture`. Renaming either needs a migration.

## Principles already in the code

- Never erase, delete or overwrite without explicit, typed confirmation; re-validate plans by token.
- Network: only allow-listed HTTPS hosts, size limits, no credentials, no in-app browser.
- No games, BIOS, firmware or keys are ever downloaded or bundled.
