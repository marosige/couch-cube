<p align="center">
  <img src="assets/icon-512.png" width="144" alt="A geometric TV and Mac mini above a solid oak console">
</p>
<h1 align="center">Couch Cube</h1>
<p align="center"><strong>Your Mac. Your games. Your couch.</strong></p>
<p align="center">
  Turn your Mac into a big-screen gaming console.<br>
  Bring a controller. Invite your friends. Make room for game night.
</p>
<p align="center">
  <a href="https://github.com/marosige/couch-cube/releases"><strong>Get Couch Cube</strong></a>
  &nbsp;·&nbsp; Apple Silicon &nbsp;·&nbsp; macOS 13+
</p>

Couch Cube walks you through setting up **Steam games and retro classics**
in a few simple steps. Play from **Steam Big Picture**, browse your retro
collection with **ES-DE**, and connect up to **4 controllers** in supported games.

## Where will you play?

| On this Mac | On an external SSD |
|---|---|
| One Mac, one cozy gaming spot. | More room for games on smaller Macs, such as 256 GB models — or take your app and games between Macs. |
| Open the **DMG** and drag **CouchCube.app** to Applications. | Open that same app → **Setup → External SSD**. Copy the app without erasing, or explicitly prepare a new SSD. |

Downloads appear once the first [release](https://github.com/marosige/couch-cube/releases)
is published. Some game players require newer macOS.

## What setup actually does

**One window, no wizard.** Setup stays in the sidebar, alongside Play, Game
library, Consoles, Controllers, Apps, Steam setup, and Settings. Nothing is installed
or erased until you confirm it. Storage is checked on launch, explicit refresh
and volume changes—not whenever you click back into the app.

The sidebar groups everyday console actions, games and devices, and this Mac's
preferences. Named sections and row separators organize apps and console families.
Compact switches sit on the right. Status dots always have text: green means
ready/connected, yellow means setup or connection is needed, and red marks a
library problem; an inactive console is shown as Off, not as an error.

1. **Create game folders in Setup.** Choose this Mac or an SSD. This creates Couch Cube's
   folders and launcher files only: no apps are installed, no games are moved,
   and Steam's settings are unchanged.
2. **Choose Consoles and Apps.** Switch on only the systems you want; new
   libraries start with none selected. Switch changes save automatically. Each system shows its emulator and
   requirements. In **Apps**, use an app's **Install** button; installed apps
   show their version and an **Installed** button that offers confirmed removal.
   Check Homebrew-managed app updates explicitly and install them individually.
   Steam and manual installations also have their own in-app updaters.
   If Homebrew is missing, finish its installer first, then click Install again.
   **Activity remains available during installation**, with live Homebrew output.
3. **Finish in Steam.** Sign in, install a game and connect a controller.
   For local play, keep Steam's existing/default library—no storage change is
   required. To use the SSD or Couch Cube's `SteamLibrary` folder, add it
   yourself in **Steam → Settings (Preferences) → Storage → Add Drive**.
   Choose another location and select the SSD's `Couch Cube/SteamLibrary`.
   Steam may label it Macintosh HD too: check its path. Rename it Couch Cube
   if Steam offers that option, and choose **Make Default**. Existing games
   stay in place unless you use Steam's **Move** action. Couch Cube does not
   edit Steam's library database; these settings have no supported public
   automation interface.

**Setup** shows your current storage and suggested next actions. **Steam setup**
shows the exact storage path and manual steps; Couch Cube does not verify
Steam sign-in, controller configuration or completion of those steps.

**Controllers** shows game controllers currently recognized by macOS, with battery
levels when reported, separately from Bluetooth pairings and their connection
state. Connection events update the page live; Bluetooth state is refreshed only
while the page is open. Bluetooth access is requested only when you choose
**Allow Bluetooth access**. Denying it does not hide active USB/game controllers.
Only controller-class devices and recognized controller names are included.
macOS does not expose every Bluetooth LE pairing through its public APIs; the
page states that limitation rather than claiming the list is complete.
**Add controller** and **Forget** guide you to macOS Bluetooth settings, where
pairing/removal is actually confirmed. Couch Cube does not use private unpairing
APIs or edit the system's Bluetooth database.
**Open Game Controller Settings** opens macOS's dedicated Game Controllers page
for the system's controller options.
Retro games still need your own ROMs, any required BIOS and emulator cores.
Add `Launchers/Retro.app` or registered game shortcuts to Steam through
**Games → Add a Non-Steam Game to My Library → Browse**; this is not automatic.
Steam Big Picture is preferred when Steam is installed. With ES-DE installed
but no Steam, **Play** opens ES-DE using this library's retro configuration
instead. ES-DE still needs the appropriate emulators, games and any BIOS/cores.
Decky is not included or supported
on macOS. Windows games need compatible, individually configured wrappers,
not macOS Proton.

### Console choices

| Systems | Required app | Additional setup |
|---|---|---|
| GameCube, Wii | Dolphin | Your game dumps and controller setup |
| Wii U | Cemu, manual download from [cemu.info](https://cemu.info/) | Configure Cemu; the Homebrew `cemu` calculator cask is **not** used |
| PlayStation 1 and classic consoles | RetroArch | Required core from RetroArch's Core Downloader, your own BIOS where required |
| PlayStation 2 | PCSX2 | Your own PS2 BIOS; current Homebrew build may require Rosetta |
| PlayStation 3 | RPCS3, manual download from [rpcs3.net](https://rpcs3.net/download) | Install Sony firmware in RPCS3; game compatibility varies |
| Nintendo Switch | Manually supplied compatible Ryujinx-based macOS build (`Ryujinx.app`) | No verified automatic download bundled; configure your own legally obtained keys, firmware and game dumps |

These are launch integrations, not game compatibility guarantees. Disabling a
console preserves its ROMs and saves. Existing disabled ROM folders get ES-DE's
`noload.txt` marker; only Couch Cube's unchanged markers are removed when
re-enabling. The managed frontend disables gamelist-only loading so these
markers are respected. Quit ES-DE before changing console selection or
updating frontend settings. Installed app icons are read from the apps on
your Mac; missing apps use system-symbol placeholders.

---

## For the curious

**What's inside:** a native macOS app with its own Python runtime.
No developer tools or separate Python install needed to run it. Homebrew
helps install optional game players. This isn't a bootable OS or macOS Proton.

**Your library:** APFS or Mac OS Extended storage. Files live in
`~/Games/Couch Cube` locally, or `<SSD>/Couch Cube` for portable
setups. Keep the portable app beside that folder. After moving it, use
**Game library → Update library links**; Steam links may need reconnecting too.
Storage checks aren't speed tests or game-compatibility guarantees.

**SSD preparation:** stages this running app on another disk and verifies its
signature before erasing, then copies the app to the SSD root. No network or
separate portable download is needed. Verification failure means no erase.
**Copy this app to SSD** copies it without erasing anything and refuses to
overwrite an existing copy.
Internal disks and the disk running the app are protected; uncertain disk
identity requires Disk Utility instead. A failure after erasure can't restore
your data. **Details** opens the activity log.

**Updates:** checked on launch, installed by you. Download, quit the app and
replace your copy. Offline use works. Builds are ad-hoc signed; checksums
and signatures check integrity, not publisher identity. Releases contain one
DMG; GitHub's asset digest provides download verification without separate
checksum attachments. A local checksum file is still generated for developers.

**Uninstall:** in Apps, click an app's Installed button, then confirm Remove.
Homebrew-managed apps use Homebrew uninstall without `--zap`; manual apps go
to Trash. Games, saves and emulator preferences are kept. **Settings →
Uninstall Couch Cube** removes this copy, its login entry, saved Mac selection
and login log, while preserving game-library folders and other installed apps.
This intentionally does not recursively delete your games or emulator data.

**Automatic console mode:** enable it in **Settings** on each Mac. After login,
wait 5–300 seconds (30 by default). With no keyboard or mouse connected, a
USB or Bluetooth controller opens Steam Big Picture, or ES-DE if Steam isn't
installed, even if connected later. Save this setting again after changing
the selected game library; older Steam-only login entries also need re-saving
to use ES-DE fallback.
A keyboard or mouse skips auto-launch for that login. macOS still requires
your normal login; Couch Cube never changes passwords or automatic login.
Keep the app at its saved location, with its SSD connected at login. After
moving the app, save the setting again. Disable Steam's own login startup to
avoid a second launch. Turn this feature off in Settings to remove its login
entry; allow background activity in macOS Login Items if prompted. Logs are in
`~/Library/Logs/Couch Cube/auto-launch.log`.

**Make it yours:** [app icon](assets/icon.svg) · [portable icon](assets/portable-icon.svg)
· [DMG icon](assets/dmg-icon.svg). SVGs and 128/512/1024 px PNGs are in `assets/`.

### Build from source

On macOS with Apple Command Line Tools and Python 3.9+:

```sh
bash scripts/setup.sh                  # Build and open
bash scripts/package-release.sh        # One DMG and a local checksum in build/
bash scripts/build-icons.sh --export   # Export artwork
/usr/bin/python3 -B -m unittest discover -s tests -q
/usr/bin/python3 -B scripts/verify-release.py \
  build/CouchCube-0.3.0-arm64.dmg
```

The first build downloads a pinned runtime (`config/runtime.json`).
Each build clears `build/` first, including previous apps, releases and caches.
Update settings live in `config/release.json`. The manual GitHub workflow
builds downloads; publishing a release is a separate, explicit action.
Pushing a `v0.3.0-alpha.N` tag builds and verifies that tagged commit, then
publishes a GitHub prerelease with only the DMG attachment.
Alpha builds retain internal version `0.3.0`. Stable-only in-app release
discovery does not show alpha releases. SSD copying uses the running app
and works offline, including in alpha builds.
