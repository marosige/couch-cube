<p align="center">
  <img src="assets/icon-512.png" width="144" alt="A TV and Mac mini on an oak console">
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
| Open the **DMG** and drag **CouchCube.app** to Applications. | Extract the **ZIP** onto your SSD and open **CouchCube.app** there. |

Downloads appear once the first [release](https://github.com/marosige/couch-cube/releases)
is published. Some game players require newer macOS.

---

## For the curious

**What's inside:** a native macOS app with its own Python runtime.
No developer tools or separate Python install needed to run it. Homebrew
helps install optional game players. This isn't a bootable OS or macOS Proton.

**Your library:** APFS or Mac OS Extended storage. Files live in
`~/Games/Couch Cube` locally, or `<SSD>/Couch Cube` for portable
setups. Keep the portable app beside that folder. After moving it, use
**Settings → Update game library**; Steam links may need reconnecting too.
Storage checks aren't speed tests or game-compatibility guarantees.

**SSD preparation:** verifies the latest portable release before erasing,
then copies the app to the SSD root. No available release means no erase.
Internal disks and the disk running the app are protected; uncertain disk
identity requires Disk Utility instead. A failure after erasure can't restore
your data. **Details** opens the activity log.

**Updates:** checked on launch, installed by you. Download, quit the app and
replace your copy. Offline use works. Builds are ad-hoc signed; checksums
and signatures check integrity, not publisher identity.

**Make it yours:** [app icon](assets/icon.svg) · [portable icon](assets/portable-icon.svg)
· [DMG icon](assets/dmg-icon.svg). SVGs and 128/512/1024 px PNGs are in `assets/`.

### Build from source

On macOS with Apple Command Line Tools and Python 3.9+:

```sh
bash scripts/setup.sh                  # Build and open
bash scripts/package-release.sh        # ZIP, DMG and checksums in build/
bash scripts/build-icons.sh --export   # Export artwork
/usr/bin/python3 -B -m unittest discover -s tests -q
/usr/bin/python3 -B scripts/verify-release.py \
  build/CouchCube-0.3.0-arm64.dmg build/CouchCube-0.3.0-arm64.zip
```

The first build downloads a pinned runtime (`config/runtime.json`).
Each build clears `build/` first, including previous apps, releases and caches.
Update settings live in `config/release.json`. The manual GitHub workflow
builds downloads; publishing a release is a separate, explicit action.
