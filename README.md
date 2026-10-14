# Mac Game Console

A **native macOS setup window** for an Apple Silicon Mac mini (M4 or newer),
with **Steam Big Picture** as the controller/TV launcher and **ES-DE** for retro
games. No HTML launcher, bootable Linux image, formatting, paid CrossOver
requirement, ROM/BIOS downloads or automatic account login.

## Open the clickable setup app

Requires macOS 13+, Apple Command Line Tools (`xcode-select --install`, if needed),
and `/usr/bin/python3` 3.9+. Build locally without a paid developer account:

```sh
bash scripts/setup.sh
```

This builds and opens `build/Mac Game Console Setup.app`. After building, you can
double-click that app in Finder. Building/opening the window **does not install
gaming software or write to a selected drive**.

1. Select **Mac internal SSD** for a local console, or a connected external
   SSD/USB volume for portable game data. **Refresh drives** rescans mounts.
2. Optionally tick host apps to install. All installation choices start unchecked.
   [Homebrew](https://brew.sh) must already be installed if you select any.
3. Click **Review & Set Up**, check the destination/install list, then confirm.
   Cancel leaves the machine and drive unchanged. Errors/progress appear in the
   window. Keep the drive connected and wait for a running operation to finish.
4. Use **Open game folder** and the one-time steps below. **Add game shortcut**
   registers an existing native game or a working Wine wrapper; it does not
   install games or configure Wine recipes.

Homebrew may require an interactive administrator password for installation.
The GUI never asks for/stores passwords or runs `sudo`. If an install fails,
install the selected casks yourself in Terminal, then rerun with them unchecked:

```sh
brew install --cask steam es-de retroarch-metal dolphin porting-kit
```

Install only the components you want. The old Intel-only `retroarch` cask
conflicts with `retroarch-metal`: resolve that explicitly, rather than having
this setup uninstall it. Steam and some Wine engines may need
[Rosetta](https://support.apple.com/en-us/102527); accept Apple's installation
prompt manually. We do not install it or accept its license for you.

## Storage and safety

| Selection | Dedicated data directory | Mode |
|---|---|---|
| Internal SSD | `~/Games/Mac Game Console` | Local game console |
| External volume | `/Volumes/<volume>/Mac Game Console` | Portable data |

External choices are mounted, unlocked, user-writable volumes backed by
physical external disks. Read-only volumes, network shares and disk images are
excluded. **APFS or Mac OS Extended** is required for the complete app/Wine/Steam
layout. exFAT volumes can appear in the menu but setup rejects them with an
explanation; it never reformats anything.

Selection is stored by volume UUID, not just a potentially reused name. The
backend rechecks mount identity and writability before its managed writes and
launches. Disconnected/renamed/replaced mounts fail explicitly; no missing
volume mountpoint is created. On a different Mac or after a mount-name change,
rerun setup on that drive and re-add Steam shortcuts if their paths changed.

Repeat runs keep ROMs, BIOS, saves, native assets, wrappers and registered game
entries. Setup owns only its generated runtime/config/launcher files, recorded
with fingerprints in `.mac-game-console.json`. If you edit one of those
generated files, setup refuses to overwrite it: move the changed file aside
before rerunning. ES-DE's settings are preserved; only `ROMDirectory` is updated.
Close ES-DE during setup to avoid concurrent settings writes. A nonempty folder
without our marker is left untouched and rejected.

```text
Mac Game Console/
  SteamLibrary/             # Select this in Steam Storage; no fake Steam manifests
  ROMs/                     # ES-DE system names: psx, megadrive, gc, wii, ...
  BIOS/retroarch/            # Includes dc/ for Flycast
  BIOS/PCSX2/               # Optional PS2 BIOS dumps; no forced filename
  Saves/RetroArch/States/
  Saves/Dolphin/
  Saves/Native/              # Per-engine save destinations you configure
  Saves/Windows/             # Per-game destinations you configure
  Native/Games/              # Self-contained native macOS game .app bundles
  Native/Assets/             # Your original game data/decomp build inputs
  Windows/Wrappers/          # Working Porting Kit/Wine game .app wrappers
  Windows/Installers/        # Your installers; never executed automatically
  Frontend/ES-DE/            # Settings, metadata, controller config, scraped media
  Launchers/Retro.app        # Add this to Steam
  Launchers/Steam Big Picture.app
  Launchers/<game>.app       # Created when you register a game
  Config/                   # RetroArch paths, shortcut instructions, optional index
  Runtime/                  # Self-contained copy of our launcher backend
```

Portable mode is **not host-independent**. Each Mac still needs Steam, ES-DE,
emulators/cores, Python, Wine engines, possibly Rosetta, controller pairing and
Steam/Wine account setup. Steam Cloud and native/Windows games can still save in
your home folder. Configure each game's/engine's save path explicitly if it
supports relocation; this tool does not promise all saves are portable.

## Steam Big Picture: the main controller launcher

1. Install/open Steam and sign in yourself.
2. Steam **Settings > Storage > Add Drive** (or the `+` menu, depending on client
   version): choose the generated `SteamLibrary` folder. If Steam creates a
   nested folder instead, use the actual location Steam shows. Move/install
   macOS-native Steam games there using Steam's own controls.
3. Pair your controller in macOS Bluetooth, or plug it in over USB. In Steam
   **Settings > Controller**, enable Steam Input for supported controllers and
   test input. In **Interface**, enable starting in Big Picture.
4. **Games > Add a Non-Steam Game > Browse**: add
   `Launchers/Retro.app` from your game directory. Select `.app` bundles in the
   file dialog (change its filter if necessary). Add registered game launchers
   the same way. No binary `shortcuts.vdf` file is edited behind Steam's back.
5. Start Big Picture with `Launchers/Steam Big Picture.app` or:

```sh
bash scripts/start-console.sh
```

Native Steam games stay in Steam's own library. Retro launches ES-DE, where you
select emulated games using the controller. Quit the emulator to return to
ES-DE; quit ES-DE to return to Steam. The launcher runs ES-DE in the foreground
so Steam can track its session, rather than just dispatching an `open` request.
Configure controller mappings in ES-DE, RetroArch and Dolphin once; if ES-DE
gets duplicate input, disable Steam Input for **that shortcut**, not globally.

For local mode only, optional login startup:

```sh
bash scripts/install-login-launcher.sh --confirm
```

This installs a user LaunchAgent that opens Steam Big Picture. It does not
enable macOS auto-login, disable FileVault, change power settings or suppress
security prompts. Prefer Steam's own startup option for portable mode.

## Retro: supplied ROMs, real ES-DE and real emulators

Setup installs **ES-DE Apple Silicon**, **RetroArch Metal universal**, and
optionally **Dolphin universal** when explicitly selected. It generates ES-DE
custom commands for these systems:

| ROM folder | Emulator/core |
|---|---|
| `nes` | Nestopia |
| `snes` | Snes9x |
| `gb`, `gbc` | Gambatte |
| `gba` | mGBA |
| `n64` | Mupen64Plus-Next |
| `gc`, `wii` | Dolphin standalone |
| `psx` | PCSX ReARMed |
| `psp` | PPSSPP |
| `megadrive`, `segacd` | Genesis Plus GX |
| `dreamcast` | Flycast |

In RetroArch **Online Updater > Core Downloader**, install the listed cores you
use. Default macOS core location:
`~/Library/Application Support/RetroArch/cores`. Missing cores produce an
actionable error; they are not silently skipped. If you have customized that
directory, restore the default or put the cores there.

Some hardware-rendered cores also require a compatible RetroArch video driver/
core renderer. If N64 or Dreamcast fails with your current Metal configuration,
consult that core's documentation and select a supported renderer rather than
assuming every renderer works. The chosen core filenames are present in the
[Apple ARM64 build feed](https://buildbot.libretro.com/nightly/apple/osx/arm64/latest/);
individual games/renderer settings are not validated by this setup.

For PSP, also install the upstream PPSSPP helper assets via **Online Updater >
Core System Files Downloader > PPSSPP.zip**. Set RetroArch's System/BIOS
directory to the drive's `BIOS/retroarch` **before** downloading those assets.
These are open-source emulator assets, not a PSP BIOS. See
[PPSSPP's setup documentation](https://docs.libretro.com/library/ppsspp/).

Put your ROMs into the matching folders, then run `Launchers/Retro.app` or:

```sh
bash scripts/start-retro-frontend.sh
```

ES-DE keeps its own home/settings on the selected storage via its upstream
`--home` option. It scans ROMs itself; no web catalog is needed. Our per-system
launchers append BIOS/save/state paths to RetroArch without overwriting your
host's main RetroArch config. Dolphin's `-u` option keeps its user data in
`Saves/Dolphin`.

`ROMs/ps2` and `BIOS/PCSX2` are prepared for optional PS2 use, but **PCSX2 is not
installed/configured by this setup**. Upstream's current Homebrew cask requires
Rosetta; install/configure it separately, point its BIOS and save settings at
your data folders and choose it in ES-DE's alternative-emulator menu. ES-DE's
built-in definitions remain available for additional systems; having a
definition is not evidence that a given emulator/game works on your M4.
PS3/newer Sony and newer Nintendo consoles are not promised or auto-installed.

### BIOS guidance

Use only dumps/game data you are entitled to use. Nothing here downloads
copyrighted ROMs, BIOS files, keys or commercial game assets.

```sh
bash scripts/check-bios.sh
```

The report prints exact expected locations and Google **documentation** search
links, not download sites. It exits `2` for missing checklist examples, `0` when
all examples are present, and `1` for execution/config errors. This is a presence
check, not a checksum/authenticity test or a requirement that every system
needs every example.

| Emulator | Typical location relative to the game directory |
|---|---|
| PCSX ReARMed | `BIOS/retroarch/scph1001.bin` (US example; other regions/BIOS names supported) |
| Genesis Plus GX | `BIOS/retroarch/bios_CD_U.bin` (US), `bios_CD_E.bin` (EU), `bios_CD_J.bin` (Japan) |
| Flycast | `BIOS/retroarch/dc/dc_boot.bin`, `dc_flash.bin` (optional firmware; consult core docs) |
| PCSX2 (manual) | `BIOS/PCSX2/<your own dump>`; select the directory in PCSX2, no universal filename |

See [PCSX ReARMed](https://docs.libretro.com/library/pcsx_rearmed/),
[Genesis Plus GX](https://docs.libretro.com/library/genesis_plus_gx/),
[Flycast](https://docs.libretro.com/library/flycast/) and
[PCSX2 BIOS guidance](https://pcsx2.net/docs/category/setup/).

## Windows games: free Wine route, not macOS Proton

Optional **Porting Kit** is a free Wine-based manager with an ARM64 macOS app.
Whisky is no longer maintained, so this project does not recommend it. No
CrossOver purchase is required; that does **not** mean every Windows game works.
Consult Porting Kit's catalog/requirements for the exact game and engine.

1. Open Porting Kit and select a supported game recipe/Steam wrapper.
2. Install the required engine and your legally obtained game installer.
   For Windows Steam titles, install **Windows Steam inside that Wine wrapper**,
   sign in there and install the game there. macOS Steam is not a Windows
   runtime and cannot run these titles just because a shortcut exists.
3. If the recipe supports choosing a destination, put its complete working
   wrapper `.app` in `Windows/Wrappers`. Some wrappers/engines depend on
   host-side caches or absolute paths; do not blindly move a working bottle.
   Recreate it at the desired location using Porting Kit when necessary.
4. Test the game directly in Porting Kit before registering it. Configure the
   wrapper's per-game executable/startup settings there.
5. In this setup app use **Add game shortcut**, select the working wrapper,
   confirm its name, then manually add `Launchers/<name>.app` to macOS Steam.

The shortcut opens the wrapper and waits for it; it does not implement Wine,
inject executables or bypass DRM/anti-cheat. If the wrapper only opens Windows
Steam, that is what the shortcut opens. Configure a game-specific wrapper to
launch a game directly. macOS Steam will not automatically list/import the
Windows Steam account library. Native and Windows Steam clients may both need
authentication. DX12 support varies by engine and game; kernel anti-cheat
games frequently do not work.

## Native ports and decompilations

Prefer official native macOS Steam builds first. For a legally built native
port/decompilation, put its self-contained macOS `.app` under `Native/Games`
and your original data under `Native/Assets/<game>`. Set its data/save paths
using that engine's own configuration. Use **Add game shortcut** to generate a
real `.app` launcher for Steam. Bundles that rely on host installs remain
host-dependent; the tool does not repack/sign third-party games.

For example, [OpenMW](https://openmw.org) has Apple Silicon distributions but
requires your own Morrowind data. Its Homebrew cask is currently disabled due
to a Gatekeeper-check failure, so it is deliberately **not an automatic
installation choice**. Get supported builds/instructions from upstream.
Do not disable Gatekeeper or use arbitrary repacked game-data downloads.

## CLI and development

The GUI uses a standard-library Python backend. Equivalent explicit operations:

```sh
python3 scripts/console.py drives
python3 scripts/console.py setup --drive internal --confirm
# External: use the volume UUID returned by "drives", not a hand-entered mount path.
# Optional installs require explicit selection:
python3 scripts/console.py setup --drive '<volume UUID>' --confirm --install es-de retroarch-metal
python3 scripts/console.py register --name 'My Game' --kind windows \
  --app 'Windows/Wrappers/My Game.app'
bash scripts/scan-games.sh
```

The optional index is `Config/library.json`: installed Steam manifests from
the macOS Steam library folders, scanned ROMs and explicitly registered native/
Wine games. It is not an importer for an entire online Steam account library.
`config/systems.csv` is retained as a folder/extension reference; current launch
definitions and core mappings are in `scripts/console.py`.
Host selection lives in
`~/Library/Application Support/Mac Game Console/setup.json`; existing legacy
`config/paths.env` is left intact, and is still supported by the BIOS checker.

Safe validation (temporary directories/stub apps only; no real installs):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
for script in scripts/*.sh; do bash -n "$script"; done
bash scripts/build-setup-app.sh
```

Upstream integration evidence checked on 2026-10-14:
[ES-DE user guide](https://gitlab.com/es-de/emulationstation-de/-/blob/master/USERGUIDE.md),
[ES-DE settings source](https://gitlab.com/es-de/emulationstation-de/-/blob/master/es-core/src/Settings.cpp),
[ES-DE ARM cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/e/es-de.rb),
[RetroArch Metal cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/r/retroarch-metal.rb),
[Dolphin universal cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/d/dolphin.rb),
[Porting Kit ARM cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/p/porting-kit.rb),
[Whisky maintenance notice](https://getwhisky.app).
These establish supported distributions/config interfaces, not tested
compatibility for every game on your Mac.

## GitHub

Source, tests and macOS build CI are ready for GitHub. Generated apps, private
path settings and unrelated local folders are excluded. No local files are
uploaded and no repository is made public by setup. Publishing still requires
approval of the exact files, GitHub destination and **public/private visibility**.
