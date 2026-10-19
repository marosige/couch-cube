<p align="center">
  <img src="assets/icon-512.png" width="144" alt="Couch Cube Mac mini and TV icon">
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
| Open the **DMG** and drag **CouchCube.app** to Applications. | Unzip the **SSD pack** onto the SSD and configure **Settings → Library storage**. Or use the installed app → **Settings → Library storage → External SSD** to copy the app or explicitly prepare a new SSD. |

Downloads appear once the first [release](https://github.com/marosige/couch-cube/releases)
is published. Some game players require newer macOS.

## What setup actually does

The interface is for people new to Mac gaming: show a short status and the next
useful action first. Keep technical explanations in details or Activity rather
than crowding the main pages.
Use native AppKit controls, sidebar selection and system materials where available,
so appearance, contrast and keyboard behavior follow macOS. Custom controller and
console artwork remains only where there is no equivalent system component.
The window uses `NSSplitViewController` with a sidebar split item: macOS 26 and
newer supplies the floating Liquid Glass sidebar, while older macOS uses its
standard sidebar appearance. No legacy sidebar material or opacity overlay is
placed over the system background.
Back and Forward are real navigational `NSToolbarItem`s aligned to the split
view, not buttons positioned inside the content. AppKit manages their glass,
spacing and overflow; View menu commands also support Command-[ and Command-].
The page title is an unbordered informational toolbar item. Content uses the
system safe area instead of a fixed-height imitation titlebar.
Your console groups Couch Cube (the home screen), Game library, App Store and Retro
consoles, in that order.
Settings groups Controllers, Console Mode, Library storage and App Settings.
The sidebar uses monochrome symbols without colored square backgrounds,
inspired by Apple Music. Red/yellow attention badges remain distinct.
Home has two compact cards: Play (opens the selected TV menu) and controllers.
There is no separate Play page. Steam setup is a guide reached from Game library.
Additional rows appear only for setup problems, missing game apps or status errors.
App categories and settings retain distinct rounded native NSBox groups with
system colors and subtle separators in both appearances.
App Store rows show the app name, Installed/Not installed and a short purpose;
the full list appears immediately during app checks, with pulsing blue status dots.
Previously checked statuses remain visible; unknown statuses show Checking.
Consoles also shows its full list immediately, with pulsing blue emulator dots
while refreshing. Switches stay unavailable until the saved selection is loaded.
emulators list only their consoles. **Get** uses a native macOS button
with system-managed contrast. Installed apps have a discreet ellipsis menu for
managed **Update** and **Remove…** actions. **Update all** appears above the list
only when updates are available; routine update-check summaries are omitted.
All have tooltips and accessible labels. App logos are bundled for uninstalled apps;
installed apps use their own macOS icons. An available update keeps Remove alongside it;
the status shows a yellow dot and **Installed · Update available**.
App Store groups each category in its own rounded card, ordered **TV menus**,
**PC games**, **Windows games**, then **Retro games**.
Choose the default TV menu in **Settings → Console Mode → Default TV menu**; it has no separate
sidebar page. Install or remove menu applications in App Store.
The default is selected with a native pop-up menu; unavailable menus cannot be selected.
removal still asks for confirmation. Version details are available on hover.

**Website:** [marosige.github.io/couch-cube](https://marosige.github.io/couch-cube/).
The app's Couch Cube branding opens this page. It links to the newest published
release (including alpha releases) with an Installer DMG and SSD pack ZIP.
For the SSD pack, unzip its contents onto your SSD, open `CouchCube.app` and
configure Settings → Library storage before adding games. The empty `Couch Cube` folders are a template:
storage setup checks and binds them to the current volume; it does not erase the SSD.
A modified template with extra files is preserved rather than overwritten.
Emulators, games and BIOS are not included.

The static site lives in `site/`; the Pages workflow adds the app icon and deploys
on changes pushed to `main`. Enable **Settings → Pages → Source: GitHub Actions**
in the repository before the first deployment. Downloads fall back to Releases
when a release asset is unavailable or GitHub's API cannot be reached.

**One window, no wizard.** Home uses a Discover-style layout: a full-width illustrated
slim header showing only the bottom of a centered 16:9 TV, without text, then
Play and controller tiles side by side.
The Play tile uses a bundled Steam Big Picture image or EmulationStation artwork
matching the chosen TV menu, with only the Play title over the image. The entire
tile launches the menu; image sources are recorded in `assets/tv-menus/sources.json`.
The supplied EmulationStation banner is resampled 4x with Lanczos interpolation
and shown without cropping its logo against a matching blue background.
The header preserves the icon's Mac mini geometry, without controller overlays.
The portable edition adds a connected SSD on the cabinet to the left of the Mac mini.
The Controllers tile is an interactive mini version of the Controllers page. Its
header has two buttons: **+** (add a controller) and the list button, which opens
the Controllers page; the rest of the tile is not a navigation target.
Clickable Home and storage-choice tiles show a subtle highlight, outline and
pointing-hand cursor on hover; disabled tiles do not advertise an available action.
There is no Needs attention section on Home. Sidebar destinations show numbered
dots instead, one per severity: a red dot counts required tasks and a yellow dot
counts recommended ones, so a page with both shows two dots with their own numbers.
Hover a dot for the task list grouped by severity. Dots update in place: titles
and icons keep their position whether a row shows none, one or two dots.
**App Settings → Guided setup** (on by default) keeps the sidebar simple: only one
page is marked at a time, in order Library storage, App Store, Console Mode, Retro
consoles, Controllers, Game library, App Settings. That page's dots include all its
tasks, setup and maintenance alike (red and yellow counts can both show); the next page is marked once it is done. Every
page stays freely reachable, and warnings inside pages are unchanged. Turn Guided
setup off to see every page's dots at once. Guided markers appear only after the
startup checks finish, and the shown step stays put until its tasks are done; later
results never make the marker jump to another page.
Play is unavailable until storage and the selected TV menu are ready.
Controllers lists every known controller in one interactive list, with the same
rows as Home: a drag handle to reorder, colored artwork when connected, connection
icons (Bluetooth rune or cable) and a battery icon when macOS reports a level.
Battery is gray above 30%, orange at 30% and below (readable in light mode), red at 10% and below, and green
only while the controller reports charging; unknown battery or transport is not shown.
Each row's **…** menu offers Customize, Move Up/Down, Connect/Disconnect (Bluetooth),
Same Controller As / Separate USB Connection, and Forget Device (Bluetooth) or
Remove from List. Forget uses macOS's Bluetooth device removal and checks the result;
if macOS refuses, it says so and opens Bluetooth Settings. Controllers in pairing mode
appear at the bottom with a **Connect** button while the page is open (classic
Bluetooth inquiry; Xbox and other Bluetooth LE pads may only appear in Bluetooth
Settings). The header's sort button switches between **Your Order** and **Connected
First**; Connected First groups connected controllers above the rest without changing
your saved order, and dragging works within each group. Header icons open Bluetooth
and Game Controller settings. Missing Bluetooth permission or Bluetooth turned off
shows an alert on the page and a Controllers task in the sidebar.
One profile can cover both Bluetooth and USB: the USB connection is joined to the
Bluetooth entry automatically only when the controller reports the same Bluetooth
address as its USB serial. Otherwise use **Same Controller As** to join them
yourself; two controllers of the same model are never merged by name alone.
Settings → Library storage opens the local/SSD choices directly, with the active
library, available libraries, disconnected state and first-library guidance.
There is no separate Setup overview or intermediate Choose storage screen.
The app can stay installed on the Mac while managing either local or SSD content.
Move library copies the active Couch Cube folder to another connected volume
whose Couch Cube folder does not yet exist. It never merges or overwrites libraries.
Files are SHA-256 checked before activation; source data stays untouched.
ROMs, BIOS, saves, frontend data and portable apps inside the folder are included;
SteamLibrary, host-installed apps and data outside that folder are not moved.
Move Steam games using Steam's Storage settings. Custom absolute paths in
third-party configs may need updating; save Console Mode again after moving.
Move old library to Trash is a separate confirmation, available after a verified
transfer (including after reopening the app). It rechecks both libraries and refuses
removal if source files changed, copied content is missing, Steam files remain,
or automatic console mode still points to the old library. It never empties Trash.
An interrupted transfer keeps the source and reports any staging/destination
folder to inspect before retrying; it does not silently delete partial files.
App Store manages software; Retro consoles manages visible systems and BIOS checks.
Game library manages folders and installed Steam games, with a Steam setup guide.
Console Mode holds the default TV menu, automatic launch and optional macOS login
guidance. Library storage sets up and switches the drive; App Settings groups app updates,
app location, installer copy, uninstall and gaming cleanup.
Nothing is installed or erased until you confirm it. Storage is checked on launch,
explicit refresh, volume changes and returning Home, not whenever the app gains focus.
Home keeps its last results during background refreshes. App Store and Retro
consoles also load in the background at launch, and refresh silently every time
their tab opens: rows stay in place, older results never overwrite newer ones, and
pending checks are not counted as solved.
Once an app, console or library status has a result, refreshing keeps its last
status color instead of replacing it with a blue pulsing loading indicator.
Loading indications are reserved for the first check of unknown state.
Errors remain actionable instead of being reported as success.
Read-only storage checks validate the volume before and after
the batch instead of rediscovering every disk for each managed file.

The sidebar groups everyday console actions, games and devices, and this Mac's
preferences in an inset, rounded panel containing the native window controls.
The sidebar's floating background is managed entirely by macOS. The current
page title appears in the native toolbar alongside Back and Forward.
Sidebar and page content begin directly below the native toolbar, without an
extra search-bar-sized top spacer.
Home shows the first four controllers of the Controllers list, in the same order
and sort mode (Your Order or Connected First); removed controllers disappear from
both, and a “N more in Controllers” note appears when the list is longer. An entirely empty tile says “Connect via USB or Bluetooth”.
Connected devices show “Connected” with a Bluetooth or cable icon, unchanged during
input activity. Disconnected devices remain gray. The four-row controller tile uses original, logo-free
line drawings for Xbox, PlayStation, Nintendo, 8BitDo and generic controllers.
PS4 / DualShock 4, PS5 / DualSense (including Edge), Switch Pro Controller,
Joy-Con and Steam Controller have separate outlines. 8BitDo SN30 Pro, Micro,
Pro 2 and Ultimate also have distinct outlines selected automatically from the
reported model name; other 8BitDo models use the general 8BitDo outline.
Generic PlayStation and Nintendo choices remain available. If the device reports
only a generic name, select the model manually rather than guessing its identity.
If a device reports a generic name in its connection mode, choose its model
manually with the controller's pencil button.
Using a controller only flashes its controller icon (VoiceOver reads “Receiving
input”), without button or axis details. Short statuses such as “Not connected”
always fit; long controller names truncate first. The status text stays “Connected”, so rows
never resize or shift; Reduce Motion skips the flashing.
The pencil in Controllers lets you set its name, connected color and artwork.
The color picker lists real retail controller colors in color-family sections
(Black & White, Gray & Silver, Camo, Red & Orange, Pink, Purple & Indigo, Blue &
Teal, Green & Yellow). Brand tags show which hardware each color comes from:
PlayStation (e.g. Cosmic Red, Nova Pink, Gray Camouflage), Xbox (Electric Volt,
Deep Pink…), 8BitDo (Micro Green, Atomic Purple…) and Nintendo Joy-Con colors;
colors shared by several brands carry several tags. Very dark or light colors get
a thin contrast halo. Defaults: Chroma Indigo for DualSense, Micro Green for 8BitDo
Micro, Black for Xbox and other PlayStation controllers; older choices migrate automatically.
On the Controllers page, the selected color tints the
line drawing while its rounded icon background stays gray.
These preferences persist by the existing HID serial/Bluetooth address identity;
USB location is the fallback, and devices without either have session-only identity.
Recent Home slots and their order persist alongside saved customizations.
Restored controllers start disconnected until detected again; devices with only
a session-scoped identity cannot be remembered reliably across app launches.
Connections refresh automatically; no manual status refresh is needed.
The Controllers page uses the same simple activity indication.
The App Store categories distinguish
**PC games** (official macOS launchers) from **Windows games**
(tools for supported Windows games on this Mac). Windows games lists Porting Kit
and CrossOver together. Existing CrossOver installations in `/Applications` or
`~/Applications` are detected and can be opened directly. Otherwise Install opens
CodeWeavers' official site; use your existing license or its trial. Games and
bottles are configured in CrossOver, and compatibility is not guaranteed.
PC games also lists **FX Steam Launcher** ([fxgl/steamac](https://github.com/fxgl/steamac),
v1.9.1) directly below Steam. It is a separate app that runs Valve's SteamOS in a
lightweight VM for Windows Steam games; it needs Apple silicon and macOS 15 or newer
(some DirectX 12 titles need macOS 26). Couch Cube detects `FX Steam Launcher.app`
on its own (Steam.app does not count) and Install opens the official notarized
release page; it is not installed automatically.
Named sections and row separators organize apps and console families.
Compact switches sit on the right. Status dots always have text: green means
ready/connected, yellow means setup or connection is needed, and red marks a
library problem. Console switches alone indicate whether a system is enabled.
Console switches respond instantly and can be flipped one after another without
waiting: the list is updated in place, and the latest choices are saved in the
background shortly after you stop. If saving fails, the switches return to the
last saved selection and the error is shown.
Enabled consoles also show BIOS filename-check results. Their info page lists
each expected filename, destination and Found/Not found state in the selected
storage's `BIOS/retroarch` folder. PS1 accepts any listed alternative; Sega CD
reports regional BIOS files separately; Dreamcast BIOS files are optional.
Systems that need no BIOS say so. PCSX2, RPCS3 and Switch emulator-managed BIOS,
firmware or keys are marked as manual, not falsely reported as missing.
Only file presence is checked, not contents, hashes or authenticity. No BIOS is
downloaded; supply only your own legally obtained dumps.
Console rows show independent emulator and BIOS indicators. The emulator dot is
gray when hidden or unknown, green when installed, red when not installed, and
yellow with an explicit **Update available** label when a known managed update is
available, both in the console list and its details. BIOS never changes the emulator
dot: its own indicator is green when present, red when required files are missing,
yellow for optional BIOS with a fallback, and gray for manually checked firmware.
Every console row has a gray App Store icon before the info button; it opens App
Store, scrolls to that emulator and briefly highlights it. Switching on a console
whose emulator is missing asks whether to install it.
The info button keeps details short: emulator status with **Show in App Store** and,
when BIOS files are missing, the destination folder (click to open), the filenames
(click one to copy it) and a search line with a **Copy** button. Copying never downloads or moves a BIOS file.
Nintendo shares one rounded card with Home consoles and Handhelds sections;
console icons use filled hardware silhouettes in each system's best-known retail
colors: gray/charcoal NES, purple-accented SNES, charcoal N64, indigo GameCube and
Game Boy Advance, white Wii and Dreamcast, gray original Game Boy, yellow Game Boy
Color, black PlayStation 2/3/PSP and SEGA hardware, and blue/red Switch Joy-Cons.
Dark plastics are lifted slightly in Dark Mode. Icon backgrounds stay clear; the
sidebar stays monochrome.
PlayStation and SEGA each have their own card.

1. **Create game folders in Settings → Library storage.** Choose this Mac or an SSD. This creates Couch Cube's
   folders and launcher files only: no apps are installed, no games are moved,
   and Steam's settings are unchanged.
2. **Choose Consoles and App Store.** Switch on only the systems you want; new
   libraries start with none selected. Switch changes save automatically and are the
   only on/off indicator. Systems have original hardware-inspired icons without
   manufacturer logos. Nintendo home consoles (including the hybrid Switch) and
   Nintendo handhelds have separate sections; each section lists systems by their
   first release, oldest first, as do PlayStation and SEGA.
   In **App Store**, rows show installed versions, status and purpose, with **Install**,
   **Remove** or **Update** directly on the right, without an app detail page.
   PC game launchers include Steam, GOG Galaxy, EA app, Epic Games Launcher and
   the official interactive Battle.net installer. Only each launcher's supported
   macOS games are native; Windows-only games do not become compatible automatically.
   CurseForge appears immediately below Battle.net for WoW addon management.
   Choose the WoW installation and manage addons in CurseForge itself.
   The TV menus category shares Steam Big Picture's installation with Steam.
   Console rows show the emulator with an App Store icon,
   an info button for BIOS details and the enable switch.
   Opening App Store or TV menu checks installed versions and Homebrew-managed updates.
   **Update all** confirms and updates only the listed outdated Homebrew-managed apps,
   stopping on errors. Nothing is installed or upgraded merely by opening a page.
   Steam and manual installations also have their own in-app updaters.
   If Homebrew is missing, finish its installer first, then click Install again.
   **Activity remains available during installation**, with live Homebrew output.

3. **Finish in Steam.** Sign in, install a game and connect a controller.
   For local play, keep Steam's existing/default library—no storage change is
   required. To use the SSD or Couch Cube's `SteamLibrary` folder, add it
   yourself in **Steam → Settings (Preferences) → Storage → Add Drive**.
   Choose another location and select the SSD's `Couch Cube/SteamLibrary`.
   Steam may label it Macintosh HD too: check its path. Rename its display label **Console Port**
   if Steam offers that option, and choose **Make Default**. Existing games
   stay in place unless you use Steam's **Move** action. Couch Cube does not
   edit Steam's library database; these settings have no supported public
   automation interface.

**Game library** puts games first: **Your games** summarizes Steam games and ready
retro consoles, with **+** (add a game) and a folder button. **Steam** lists games
per library with a **Play** button for installed ones, and an empty state that opens
Steam. **Retro games** links to the game folders and Retro consoles. **Where your
games live** shows the same icon and name as Library Settings — **This Mac** or
**External SSD**, marked **Active** for the active library — with storage health
and library updates; its **…** menu has Check
Library and Change Storage. App Store categories collapse with the chevron in their
header; collapsed categories still show installed apps, and the choice is remembered.

**Steam integration:** Game library shows installed Steam game counts
on local and external volumes. Game library lists names, manifest-reported install/
update state and recorded size; Steam setup summarizes each library and path.
Disconnected libraries show Offline rather than a misleading zero count. Partial
or unreadable metadata is explicitly reported. These are local Steam manifests,
not account ownership, live download progress or a compatibility check. Counts
exclude entries that Steam does not mark fully installed. Refresh is read-only
and needs no Steam password, API key or SteamCMD installation.
**Open Steam Storage** opens the client's storage settings; use Steam to set a
default library, rename its display label or move games. SteamCMD's
`force_install_dir` controls SteamCMD downloads, not the desktop client's settings.
No verified official end-user library-management CLI is integrated for GOG Galaxy,
EA, Epic or Battle.net; their own apps still manage games and accounts.

**TV menu:** Choose **Make default** for installed Steam Big Picture or ES-DE.
The preference is stored on this Mac, independently of game storage. Play and
automatic console mode use it; a missing chosen menu reports an error instead of
silently opening another. Without an explicit choice, Steam is preferred, then ES-DE.
The future Couch Cube menu is shown as disabled/coming soon.
Play has a large default-menu action plus separate Steam Big Picture and ES-DE
buttons, which launch without changing the default. Couch Cube Launcher is
shown there as coming soon too.

Consoles controls system visibility in ES-DE, not emulator installation. The future
Couch Cube menu will use the same saved selection. Steam's own library is unchanged.

**Settings → Library storage** manages storage setup and transfers. The **Steam setup guide** in Game library
shows the exact storage path and manual steps; Couch Cube does not verify
Steam sign-in, controller configuration or completion of those steps.

**Controllers** combines paired Bluetooth controllers, connected USB/Bluetooth
game controllers and previously seen devices under **Connected Controllers**.
Green means connected, gray means disconnected; connected entries show
**USB** or **Bluetooth** (other transports are labeled separately).
Choose the pencil to save a custom name and icon color in Couch Cube. The original
device/Bluetooth name is available when editing rather than repeated in the list.
Connection and activity appear directly below the displayed name. Names do not rename the device
in macOS or Steam. **Show connected first** brings connected devices to the top;
switching it off restores the original order. Names, colors and order persist on
this Mac. Devices without a serial number may be identified by USB port; changing
ports can create a separate entry. Devices with no stable identity are session-only.

**Manage Controllers** opens macOS Bluetooth and Game Controllers settings.
The list refreshes automatically on Home and Controllers. Bluetooth access is requested only when you choose
**Allow Bluetooth access**. USB devices do not need Bluetooth access. Some
Bluetooth LE pairings are only exposed in macOS Settings; the page says so.
No private pairing APIs or Bluetooth-database edits are used.

Each device shows one short status line, such as **Connected** with Bluetooth/USB and
battery icons; input activity is shown only by the flashing icon described above. The activity indication clears
shortly after input stops; button and axis details are not displayed.
Monitoring covers only gamepad/joystick devices, uses no exclusive capture and
stops when leaving Home and Controllers. Input-access failures are shown explicitly.
Retro games still need your own ROMs, any required BIOS and emulator cores.
Add `Launchers/Retro.app` or registered game shortcuts to Steam through
**Games → Add a Non-Steam Game to My Library → Browse**; this is not automatic.
Without an explicit default, Steam Big Picture is preferred when Steam is installed.
With ES-DE selected (or installed without Steam), **Play** opens ES-DE using this library's retro configuration
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

**Uninstall:** in App Store, click an app's Remove button, then confirm.
Homebrew-managed apps use Homebrew uninstall without `--zap`; manual apps go
to Trash. Games, saves and emulator preferences are kept. **Settings →
Uninstall Couch Cube** removes this copy, its login entry, saved Mac selection
and login log, while preserving game-library folders and other installed apps.
This intentionally does not recursively delete your games or emulator data.

**Settings → Clean up gaming setup → Review…** is a separate, broader cleanup.
It shows an unchecked list with exact paths for detected launchers, emulators,
Steam libraries, connected Couch Cube libraries (including ROMs, BIOS and saves),
known Blizzard game folders, Windows bottles, settings, caches and logs. This
includes software installed before Couch Cube. Select only items you want removed,
back up important files, quit games and launchers, and type `REMOVE` to confirm.
The list is revalidated before cleanup. Homebrew-managed apps are uninstalled
without `--zap`; other selected items use macOS Trash. Failures are reported in
Activity, including partial cleanup. You can also remove this copy of Couch Cube.
Removing Couch Cube settings disables its automatic console mode.

Cleanup does not empty Trash, erase drives, remove Homebrew or Rosetta, or run
global dependency/cache cleanup. Shared dependencies are kept because other
software may need them; dependencies bundled inside selected apps and bottles
leave with those items. Custom locations, disconnected drives, other users'
files, cloud saves and unrecognized gaming software are not removed. Review
those separately rather than assuming cleanup guarantees a game-free Mac.

**Automatic console mode:** enable it in **Settings → Console Mode** on each Mac. After login,
wait 5–300 seconds (30 by default). With no keyboard or mouse connected, a
USB or Bluetooth controller opens your default TV menu,
even if connected later. Save this setting again after changing
the selected game library; older Steam-only login entries also need re-saving
to use ES-DE fallback.
A keyboard or mouse skips auto-launch for that login. macOS still requires
your normal login; Couch Cube never changes passwords or automatic login.

For an optional couch-only startup, Console Mode links to macOS Users & Groups,
FileVault and Lock Screen settings and Apple's automatic-login guide. A separate
**Standard** Couch Cube account with its own password can keep gaming settings
apart from a private administrator account. Put the app in `/Applications`, then
configure storage, launcher sign-ins and automatic console mode from the gaming
account. Existing private-account libraries are not moved or automatically shared.
Choose that account in macOS's **Automatically log in as** setting; removing its
password is not required. FileVault prevents automatic login. Disabling it reduces
startup protection for the entire Mac, including private accounts; a separate
gaming account does not replace that protection. Sleep/screen-lock authentication
is a separate macOS setting. Couch Cube does not change any of these protections
or create users, and organization policies may prohibit automatic login.
Keep the app at its saved location, with its SSD connected at login. After
moving the app, save the setting again. Disable Steam's own login startup to
avoid a second launch. Turn this feature off in Console Mode to remove its login
entry; allow background activity in macOS Login Items if prompted. Logs are in
`~/Library/Logs/Couch Cube/auto-launch.log`.

**Icon:** [Compact, M4-style Mac mini close-up](assets/icon.svg) with a low,
rectangular case and an unmarked lid, two left USB-C ports and a right headphone jack with
the white LED immediately to its left. A lowered oak cabinet leaves space beneath
the wall-mounted TV. The icon is shared
by the app and DMG. The [portable artwork](assets/portable-icon.svg) adds a
front-connected USB SSD, not a badge. SVGs and 128/512/1024 px PNGs are in `assets/`.

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
