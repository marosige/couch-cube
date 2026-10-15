# Mac Couch Console (MCC)

**Turn your Mac into a couch console.** Connect up to 4 controllers and play
on the big screen in supported games.

A **portable macOS manager** for Apple Silicon Macs. Set up your couch-gaming
experience in just a few clicks, on your Mac or an external SSD.

**Steam Big Picture** is your controller-first launcher. **ES-DE** brings your
retro games together. Multiplayer support depends on the game and emulator.

## Get started

Requires **Apple Silicon and macOS 13+**. Some games and players need newer macOS.

[**Download from GitHub Releases**](https://github.com/marosige/mac-couch-console/releases)
— downloads become available once the first release is published.

- **Portable:** extract `MacCouchConsole-0.3.0-arm64.zip` onto your external SSD.
  Open **MacCouchConsole.app** directly from there.
- **On this Mac:** open `MacCouchConsole-0.3.0-arm64.dmg`, drag the app to
  **Applications**, eject the DMG and open the app. You can also copy it to an SSD.

This build is **not notarized**. If Gatekeeper blocks it, use
**System Settings > Privacy & Security > Open Anyway** only if you trust the
source. Managed Macs may not allow this.

## From setup to sofa

1. **Pick your setup.** Choose **On this Mac** or **On a portable SSD**.
   The SSD route immediately offers **Prepare an SSD** for a fresh start, or
   lets you use an existing drive without erasing it.
2. **Follow the steps.** Choose storage, create your game library, then select
   your game players. MCC explains any one-time download-helper setup.
   Installations are optional and always ask for confirmation.
3. **Connect & play.** The final screen walks you through Steam's library
   connection and controller pairing. Then your **Home** screen puts Big Picture
   first. Existing libraries open there directly; settings stay out of the way.

Supply your own legally obtained games and any required BIOS. Windows games
need a working **Porting Kit/Wine wrapper** first; a shortcut alone cannot run
them. Compatibility varies.

**Taking the SSD to another Mac?** Open MCC from it and check **Game players**.
Steam, emulator cores, Wine engines and controller pairing may still need setup
on that Mac. Keep the app beside the `Mac Game Console` library folder.

**Prepare an SSD**, at the start of the portable setup, downloads and
verifies the latest portable app **before** the separately confirmed erase,
then puts the app at the SSD root. **Erasing destroys every partition and file.**
Back up first. Internal disks and the disk running MCC cannot be erased.
An existing compatible SSD does not need formatting.
You can revisit setup with **Change storage** and find app updates in **Settings**.

---

## Under the hood

Native AppKit UI, bundled Python runtime, real Steam/ES-DE launchers.
No source checkout, separate Python or developer account is needed to use the
packaged app. This is not a bootable OS or macOS Proton.
Reusable artwork: [SVG](assets/icon.svg), [1024](assets/icon-1024.png),
[512](assets/icon-512.png) and [128 px PNG](assets/icon-128.png).
The separate [DMG icon](assets/dmg-icon.svg) adds an installation prompt on the TV.
The [portable icon](assets/portable-icon.svg) adds a cabled SSD beside the Mac mini; only the icon differs
between the ZIP/SSD app and the app inside the DMG.

**Storage:** APFS or Mac OS Extended; SSD preparation creates APFS/GUID.
Local data lives in `~/Games/Mac Game Console`; portable data in
`<SSD>/Mac Game Console`. Volume identity and managed files are checked before
writes. Mount changes may require **Settings > Update game library** and reconnecting
Steam shortcuts. Readiness checks are not SSD benchmarks or compatibility tests.

**Safety:** formatting requires an exact whole-disk review and typed
`ERASE diskN` confirmation. Missing reliable disk identity disables automatic
erase; use Disk Utility manually. Download failures prevent erasure, but a
failure *after* erasure cannot restore data. **Activity** shows actionable errors.
No formatting, host installation or GitHub publication happens during builds.

**Updates:** startup checks public GitHub Releases for
`marosige/mac-couch-console`; no token or automatic app replacement.
Download, quit MCC and replace the app manually. Offline use still works.
Online preparation needs a published stable ARM64 ZIP and its `.sha256`.
Checksums/ad-hoc signing check integrity, not publisher identity.

**Build on macOS** with Apple Command Line Tools and Python 3.9+:

```sh
bash scripts/setup.sh                  # Build and open the app
bash scripts/package-release.sh        # ZIP, DMG and checksums in build/
bash scripts/build-icons.sh --export   # Refresh reusable PNG artwork
/usr/bin/python3 -B -m unittest discover -s tests -q
/usr/bin/python3 -B scripts/verify-release.py \
  build/MacCouchConsole-0.3.0-arm64.dmg build/MacCouchConsole-0.3.0-arm64.zip
```

The first build downloads a pinned, checksum-verified runtime
(`config/runtime.json`). Release settings live in `config/release.json`.
The manual GitHub workflow builds artifacts; publishing a draft is opt-in.
Release publication is always an explicit action, not part of opening the app.
