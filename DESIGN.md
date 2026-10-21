# Couch Cube design notes

How the app is meant to look and behave, page by page. This is the reference for
changes to the native app (`setup/CouchCube/`) and its Python backend (`scripts/`);
the user-facing overview is in [README.md](README.md).


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
The Couch Cube section groups Play (the home screen), Controllers and Cube Shop.
Settings groups Game library, App Store, Retro consoles, Console Mode and App Settings,
in that order. Game library also contains what used to be Library storage.

**Cube Shop** (it replaced the Deals page and always opens on Home) is a native,
read-only Mac game store for PC games: **Home**, **Deals**, **Free Games** and **Wishlist**, plus
search results and a **game page** per game. It never buys anything, signs in anywhere or claims
that a game runs on a Mac. The page is wider than the settings pages (up to 960 pt).

- **Home** is a storefront: one featured banner (big Steam art, discount pill, price), then shelves
  of cards: On Your Wishlist (wishlist games on sale or at your target), Top Deals, **Top Sellers**
  (Steam's keyless `featuredcategories` top sellers, on sale or not), **Couch Games** (Couch Cube's own
  pick of local multiplayer games, `COUCH_GAMES` in shop.py, on sale or not), Price Drops and
  Free to Keep; the deal shelves have **See All** to the full list. Full-price shelves are matched to
  CheapShark by Steam app ID (cached a week) so every card has every store's price. Cards show art, title, Mac/Windows badge,
  the discount pill and the price, with the wishlist heart on the art.
- **One row style** everywhere else: art (Steam's own header art when the game is on Steam), the
  title with its Mac/Windows badge and the heart (Set Target is on the game page and the wishlist); on the right a green discount pill,
  then a fixed-width price block: usual price struck through and the price; the store (logo and
  name) under it; and when known, under the discount pill, the all-time low: "Lowest $7.99 (−47%)" in your
  Shop currency and the discount it was, or a green "All-time low" when today's price is the record.
  Search lists one row per game (best price and how many stores); ratings live on the game page.
- **Game page** (opened by any row or card; Back/Forward and ⌘[ ⌘] return to the same list): a
  gallery (the cover, then Steam's screenshots, with ‹ › arrows dimmed at either end and "2 / 8"), title, badges (Mac/Windows, Installed, Owned, Steam rating, Metacritic), genre tags (Action,
  RPG… from Steam), every platform (Mac, Windows, Linux, Steam Deck Verified/Playable from Steam's keyless
  Deck report; rows only say Mac or Windows), a price card with the pill,
  price, usual price, all-time low, target and heart, and one main button ("View at GOG", "Get It on
  Epic Games Store"); then **Where to Buy** with every store cheapest first, Lowest on the cheapest.
  A page opened from a single deal or the wishlist loads every store with `shop-game --id`.
  **Gameplay Videos** opens a YouTube search for "<game> gameplay" in the browser. **About** (Steam games,
  `shop-steam --app`, cached a week) shows the short description, genre, developer, release date,
  controller support and couch play (split screen, local co-op, Remote Play Together), always listed
  (gray "Not listed by Steam" / "No local multiplayer listed" when missing), then Yes/No for
  single-player, online co-op, online versus, TV streaming (Remote Play on TV), cloud saves, Family
  Sharing and achievements, and the size with the free space in your game library, orange when it doesn't fit.
- **Links** open your default browser only: CheapShark's `cheapshark.com/redirect` for stores
  (their terms require it, Steam included), gamerpower.com for giveaways, apps.apple.com for the
  Mac App Store. Any other host or scheme is refused. No in-app browser, no store-app deep links.

The header has one large search field ("Search games in every store") and, below it, the four
sections with a quiet **My Stores / All Stores** popup and Refresh on the right. Searching
(Return, or a short pause after two or more letters) shows results in place of the section;
clearing the field goes back. Rate source, attribution and store-filter details sit in small print.

- **Sources.** [CheapShark](https://www.cheapshark.com) store deals and per-store prices (USD),
  [GamerPower](https://www.gamerpower.com) giveaways, and Apple's keyless
  [iTunes Search API](https://performance-partners.apple.com/search-api) for Mac App Store
  apps (`entity=macSoftware`, your region's storefront and currency). All are public and
  keyless and are credited on the page.
- **PC stores only.** Steam, GOG, Epic, EA, Battle.net, Ubisoft, Humble, Fanatical and the other
  CheapShark PC stores, itch.io/DRM-free and the Mac App Store. GamerPower is asked only for PC
  platforms and replies are filtered again, so PlayStation, Xbox, Switch, Android and iOS
  giveaways never appear.
- **All Games / Mac Only** (a quiet popup after the store popup, saved): Mac Only means Home, Deals and Search show only games Steam
  confirms have a macOS version (Mac App Store apps always count); Free to Keep hides, since giveaways
  carry no platform data. Games whose platform isn't known yet appear once the lookup confirms them.
- **My Stores / All Stores.** Home, Deals and Free Games share one saved toggle. My Stores keeps
  the stores whose Mac app or Windows launcher is installed (detected like App Store does). With
  none installed, All Stores is used and a hint explains why.
- **Picks** on Home are made locally from discount, ratings, recency and your wishlist. Nothing about
  you is sent anywhere.
- **Deals rows** show an Installed badge when a deal's Steam app ID matches a game installed in
  a Steam library on this Mac, and an Owned badge (every Shop list and the game page) when the
  Mac Steam account has the game: app IDs from Steam's own `userdata/<account>/config/localconfig.vdf`
  (keys only) plus installed manifests.
- **Steam wishlist** (App Settings › Cube Shop, a switch): no sign-in in Couch Cube. The account's
  public SteamID comes from `loginusers.vdf`; when linked, opening Cube Shop asks Steam's keyless Web API
  (`api.steampowered.com`, `IWishlistService/GetWishlist`) for the public wishlist and adds new games
  (looked up on CheapShark by Steam app ID, 25 per open) to the Cube Shop wishlist. One way: a game
  removed here is remembered (`steam-link.json`) and never re-added. A private wishlist reads as empty
  with a hint to make Game details public.
- **Expiry and Reminders.** Only GamerPower provides end dates (`end_date`, read as UTC because
  the API doesn't state a time zone; "N/A" means no badge). CheapShark has none, so store deals
  never show one (a source limit; nothing is guessed from sale start dates or price history). The
  date shows under the price (“Offer ends 22 October”, with the year when it isn't this year) and is
  its own control: clicking it adds a reminder to your default Apple Reminders list at 09:00 on the day
  before the end (or the soonest sensible time, which the confirmation states). Access is asked on
  first use; if denied, a note links to Privacy & Security › Reminders. A second click offers
  removal, and a reminder you delete in Reminders resets the badge.
- **Search** runs on Return or after a short pause, combines identical searches and caches
  replies. CheapShark prices are
  USD and App Store prices use your storefront's currency, labelled; without a Shop currency the
  App Store rows are grouped after the USD stores instead of being mixed into the sort.
- **Store icons.** Every store price without a discount has a small store icon (bundled launcher
  icons, an SF Symbol fallback otherwise); the store's full name and discount are read by VoiceOver.
- **All-time low.** CheapShark's game lookup (used by Search and the Wishlist price check, so no
  extra requests) includes only `cheapestPriceEver`: the lowest USD price it recorded across the
  stores it tracks, and when. Rows show “All-time low” (green) when the best USD price is at or
  below it, or “X% above all-time low”, with the record and date in the tooltip. It's a single
  minimum, not a price history, so Cube Shop never says a price is rare, typical or above average.
  Converted prices aren't used for it, other currencies (App Store) get no note, and Deals and Home
  lists don't carry the record, so they show none.
- **Mac / Windows badges.** A green Mac badge means Steam's `appdetails` lists a Mac build (or
  it's a Mac App Store app). A yellow **Windows** badge means Steam explicitly lists Windows and
  no Mac build; its tooltip says it needs a compatibility app (naming the ones installed, if any).
  CheapShark and GamerPower have no platform data, so other stores' deals and giveaways make no
  claim. Lookups are one Steam app per request, at most 12 per refresh, cached for 7 days.
- **Sort by.** Deals, Free Games, Search and Wishlist each have a Sort by popup (Relevance,
  Name A–Z, lowest/highest price, discount, plus rating on Deals, Ends Soon on Free Games and
  Date Added on Wishlist), remembered per list. Prices sort by the converted value when a Shop
  currency is set, otherwise by currency group; missing values go last and ties keep their order.
  Deals sorting is done by CheapShark because it's paginated; Search sorts games by their lowest
  price while each game's stores stay cheapest first.
- **Wishlist** is Couch Cube's own, saved on the active Couch Cube drive in
  `Couch Cube/Wishlist/wishlist.json` (schema version, title, CheapShark game ID, Steam app ID,
  App Store ID, artwork URL, date added, optional target price with its currency code, last known
  best price with its currency; converted values are never stored).
  It moves with the drive and works offline. Writes are atomic (temp file + rename, coordinated);
  when the drive is unplugged or read-only the last copy is shown read-only with a note, and lists
  from different drives are merged when you switch. Before a drive is set up, the wishlist is
  saved on this Mac (`~/Library/Application Support/Couch Cube/Wishlist`) and moves onto the drive
  when you set one up. Each item shows its artwork (from the artwork cache, with a placeholder),
  current best price and an editable target in your Shop currency (e.g. HUF); the target is
  converted to each store's currency with the current ECB rates, and without rates the comparison
  is shown as unavailable. Add or remove with the heart on any row; the heart never opens the store.
  Prices are checked in batches only when you open Cube Shop or press Refresh, never in the
  background, and hits (on sale, shown under the price as a green “<store> −X%”, or target reached;
  the full “On sale at …” sentence is in the tooltip) appear on Home. There are no
  notifications or e-mail alerts.
- **Caching.** Replies are cached in `~/Library/Caches/Couch Cube/deals`; rate limits
  (including 429 Retry-After) and connection failures keep the last results with a message.

**Shop currency** (App Settings › Cube Shop) converts prices for display only. Choose Original
prices (the default, whatever your Mac's region) or a currency to show Cube Shop prices converted to it,
and an optional card/FX fee %
(0–20, e.g. a weekend markup). Rates are the [ECB reference rates via Frankfurter](https://frankfurter.dev)
(`api.frankfurter.dev/v1`, keyless; Revolut has no public keyless rate API). They are fetched when
Cube Shop opens and cached for 12 hours in `~/Library/Caches/Couch Cube`; offline, the last rates are
used with a “rates from <date>” note, and with no rates at all prices stay original. Conversion uses
Decimal math and the currency's own rounding (HUF has no decimals). Converted prices are marked
“≈” and keep the original in the tooltip and VoiceOver label, Search sorts every store by the
converted price, free items always say Free, and the wishlist file only ever stores original prices.
Bank and Revolut rates may differ slightly.

**Store Accounts** (App Settings) shows which game clients are signed in using local client
files only, with no web view: the Mac Steam client's account names from `loginusers.vdf` (the
most recent one marked; tokens and other fields are never read or stored), and the Windows
launchers in the Couch Cube Wine prefix as Installed (sign in inside the launcher) or Not
installed, because their files don't expose a reliable non-secret account name. Open launches the
client, Check Again re-reads the files, and a guided walkthrough goes through the clients one by
one. Checks run only when the page opens, on Check Again or when a launched client quits.
Web store logins and launcher logins are separate: signing in to one doesn't sign in the other.

**Activity** (View → Activity) is the technical log. It opens only when you choose it:
installs, updates, refreshes, errors, launch and guided setup never open it, and macOS
doesn't restore it. Problems show on the page or in an alert with a **Show Activity**
button. Developers can set `COUCH_CUBE_DEBUG_ACTIVITY=1` to bring back automatic opening.
The sidebar uses monochrome symbols without colored square backgrounds,
inspired by Apple Music. Red/yellow attention badges remain distinct.
Home has two compact cards: Play (opens the selected TV menu) and controllers.
There is no separate Play page. Steam setup is a guide reached from Game library.
Additional rows appear only for setup problems, missing game apps or status errors.
App categories and settings retain distinct rounded native NSBox groups with
system colors and subtle separators in both appearances.
App Store rows show the app name, Installed/Not installed (green / gray dot; red only for a failure) and a short purpose;
Get and Update start at once (no confirmation); only Remove asks. An installed Porting Kit row has **Games Folder**:
it creates `Windows/Porting Kit` in the game library, shows it in Finder and copies its path for Porting
Kit's "Applications default path" (Porting Kit's own setting is not changed by Couch Cube); ports put
there appear in Play under Windows games. The … menu has Open, Update and Remove….
When Homebrew needs administrator rights (Steam's updater, for example) macOS's password dialog appears
through a `SUDO_ASKPASS` helper (`scripts/askpass.sh`); Couch Cube never stores the password. After a
failed operation a hint links to Privacy & Security › App Management, which macOS may require.
the full list appears immediately during app checks, with pulsing blue status dots.
Previously checked statuses remain visible; unknown statuses show Checking.
Consoles also shows its full list immediately, with pulsing blue emulator dots
while refreshing. Switches stay unavailable until the saved selection is loaded.
emulators list only their consoles. **Get** uses a native macOS button
with system-managed contrast. Installed apps have a discreet ellipsis menu for
managed **Update** and **Remove…** actions. While an install, update or removal runs, a spinner takes
the place of that row's button and the status shows the current Homebrew step
(Downloading, Installing…). Homebrew doesn't report download percentages to apps, so the
spinner never shows an invented percentage. When it finishes, Couch Cube re-checks only
that app; the dot turns green (and the sidebar badge updates) only after the re-check
confirms the app is installed and up to date. Otherwise the row shows the failure and
Get/Update stays available to try again. **Update all** appears above the list
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

**Website:** [couchcube.marosi.me](https://couchcube.marosi.me/).
The app's Couch Cube branding opens this page. It links to the newest published
release (including alpha releases) with an Installer DMG and SSD pack ZIP.
For the SSD pack, unzip its contents onto your SSD, open `CouchCube.app` and
configure Settings → Game library before adding games. The empty `Couch Cube` folders are a template:
storage setup checks and binds them to the current volume; it does not erase the SSD.
A modified template with extra files is preserved rather than overwritten.
Emulators, games and BIOS are not included.

The static site lives in `docs/` and is published by GitHub Pages straight from the
`main` branch's `/docs` folder (**Settings → Pages → Deploy from a branch**), so there
is no deployment workflow. `docs/CNAME` keeps the custom domain `couchcube.marosi.me`;
`docs/icon.png` is a copy of `assets/icon-512.png`, so update both together. Downloads
fall back to Releases when a release asset is unavailable or GitHub's API cannot be reached.

**One window, no wizard.** Home (Play) shows the Play and controller tiles side by side,
then **Games**: the launcher, with games only (launchers and emulators stay in App Store). In this
order: installed Steam games (header art read from Steam's local `appcache/librarycache`, never
downloaded; Steam tools and runtimes hidden) via `steam://rungameid/<id>`; retro games — every ROM of a
shown console in the library, started straight in its emulator with `emulate`; Windows games —
Porting Kit ports in `Windows/Porting Kit`, wrappers in `Windows/Wrappers` and CrossOver's program
shortcuts in `~/Applications/CrossOver` (installers and uninstallers skipped); Mac games in
`Native/Games`; and apps added with **+** (UserDefaults `launcherApps`). The list comes from
`library-games`, read-only and unmeasured. Tiles fill the width in a flow grid; click, Return or
VoiceOver opens them, and their menu offers Open, Show in Finder and, for added apps, Remove from Play. The search field filters by name.
The Cube TV tile's artwork is drawn in code (`TVMenuArtwork.swift`) so it stays sharp at any size: the
chosen menu's colors (Steam blue, ES-DE red, Cube TV purple when none is chosen), a soft glow and
scanlines, the installed app's own icon (bundled icon as fallback) and its name ("STEAM / Big Picture",
"ES-DE / Retro Games"), all centered in a square safe area so nothing is cut off however narrow the
tile gets (the name shrinks to fit). The whole tile launches the menu; the line under "Cube TV" only shows status
while no menu is chosen. No third-party screenshots are bundled.
The installer DMG (built with dmgbuild from `scripts/dmg-settings.py`) opens one clean window: a light
background titled **Couch Cube** with the subtitle **Your Mac Console** (the tagline everywhere), the app
on the left, an arrow, and Applications on the right. Nothing else is visible in it.
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
Guided setup (always on, no setting) keeps the sidebar simple: only one
page is marked at a time, in order Game library (storage first), App Store, Console Mode, Retro
consoles, Controllers, App Settings. That page's dots include all its
tasks, setup and maintenance alike (red and yellow counts can both show); the next page is marked once it is done. Every
page stays freely reachable, and warnings inside pages are unchanged. Guided markers appear only after the
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
if macOS refuses, it says so and opens Bluetooth Settings. Forget keeps the controller's
name, color and icon (keyed by its Bluetooth address, which is the controller's own hardware
address), so pairing it again restores them; **Forget and Delete Profile** in the same dialog,
or Remove from List, deletes them. Controllers in pairing mode
appear right under the list with a **Connect** button while Home or Controllers is open (classic
Bluetooth inquiry; Xbox and other Bluetooth LE pads may only appear in Bluetooth
Settings). **Connect** pairs inside Couch Cube and never opens Bluetooth Settings: failures
and PIN-code pads show an in-app message, and Bluetooth Settings opens only from its own
header button. A controller that macOS reports as connected over Bluetooth but that exposes
no HID gamepad/joystick input shows **Bluetooth only** instead of an error or a false
“Connected”; check the pad's input mode switch (for example X/D) or reconnect it. Couch Cube
reads input through HID rather than the GameController framework, so DirectInput-style HID
pads still count as connected. The header's sort button switches between **Your Order** and **Connected
First**; Connected First groups connected controllers above the rest without changing
your saved order, and dragging works within each group. Header icons open Bluetooth
and Game Controller settings. Missing Bluetooth permission or Bluetooth turned off
shows an alert on the page and a Controllers task in the sidebar.
One profile can cover both Bluetooth and USB. The USB connection joins the Bluetooth
profile automatically only when the controller itself proves its Bluetooth address:
DualSense, DualSense Edge and DualShock 4 report it over USB in a feature report (the same
one SDL/Steam read), and some pads use it as their USB serial. A name, color or icon set
over USB moves onto that profile in place. Xbox, Switch Pro and most other pads expose no
shared ID across USB and Bluetooth on macOS, so use **Same Controller As** to join them
yourself; two controllers of the same model are never merged by name alone, and Joy-Cons
are never joined to anything.
Library storage is merged into **Settings → Game library**: one Where your games live
overview with Refresh connected drives, Add or prepare an SSD, your games and Move library.
There is no separate Library storage page, Setup overview or intermediate Choose storage screen.
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
In Retro consoles, each manufacturer card (Nintendo, PlayStation, SEGA) has one switch that
shows or hides every console on it in one batch (a mixed group shows "3 of 7"); showing
consoles never installs emulators.
Game library shows where your games live and each drive's games, with a Steam setup guide.
Console Mode asks three questions in the order they happen, each answered by tapping a row with a
checkmark (no Save buttons, no confirmations): **1 Signing in & waking** (after a restart and when
the Mac wakes from sleep) — type your password, password once then Apple Watch (links to Touch ID &
Password), or start without signing in (automatic login is read from macOS; the System Settings steps,
including Lock Screen's password-after-sleep, show only for this choice). **2 Open at Login** —
nothing, open Couch Cube in its window (a macOS Login Item via SMAppService), or open the TV menu (the
true console experience) when a controller is on and no keyboard or mouse is connected (the LaunchAgent, with its wait in seconds).
**3 On the TV** — Steam Big Picture, ES-DE (a missing one leads to App Store) or Cube TV Home
(Couch Cube's own, shown as coming soon). The Play tile is titled **Cube TV**, with the chosen menu beneath. Game library also sets up and switches the drive; App Settings groups app updates,
app location, uninstall and gaming cleanup. **Clean up gaming setup** opens its own page (not a
popup): what was found, grouped in cards (Apps, Games and data…) with each item's icon, name and path,
Select all, then a Remove card that lists the selection, offers to move Couch Cube to the Trash too, and
needs REMOVE typed before the red Remove button runs; problems (apps still running) show inline.
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
The Home tile has no **+** button: controllers in pairing mode appear in it
automatically with the same **Connect** button as the Controllers page.
Input activity only flashes the controller's icon; other rows never move.
Connected devices show “Connected” with a Bluetooth or cable icon, unchanged during
input activity. Disconnected devices remain gray. The four-row controller tile uses original, logo-free
line drawings for Xbox, PlayStation, Nintendo, 8BitDo and generic controllers.
PS4 / DualShock 4, PS5 / DualSense (including Edge), Switch Pro Controller,
Joy-Con and Steam Controller have separate outlines. Joy-Con (L) and (R) each show their own
side with a small outline of the partner beside it (a pair outline is also available); the
default Nintendo outline is a SNES-style pad, and Steam Controller uses the current dual-trackpad
design. The artwork picker groups choices by company (Microsoft, Sony, Nintendo, Valve, 8BitDo,
Other) like the color menu. 8BitDo SN30 Pro, Micro,
Pro 2 and Ultimate also have distinct outlines selected automatically from the
reported model name; other 8BitDo models use the general 8BitDo outline.
Generic PlayStation and Nintendo choices remain available. If the device reports
only a generic name, select the model manually rather than guessing its identity.
If a device reports a generic name in its connection mode, choose its model
manually with the controller's pencil button.
Nintendo controllers are identified by HID vendor ID 0x057E: product 0x2009 is the
Switch Pro Controller (Bluetooth name “Pro Controller”), 0x2006/0x2007 are Joy-Con (L)/(R)
and stay separate entries: Joy-Cons are never linked automatically and never offer
**Same Controller As**. A pad called “Pro Controller” with another vendor ID gets the
generic outline; Switch-mode clones that report Nintendo's IDs are indistinguishable and
are not guaranteed to work. Before pairing only the Bluetooth name is known, so the pairing
list's outline is a best guess.
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
colors shared by several brands carry several tags.
The first color choice is **Automatic (…)**, the model's standard launch/marketing color:
White for DualSense, Black for DualShock 4, other PlayStation, Xbox, Switch Pro, Steam
Controller, 8BitDo Ultimate and unrecognized pads, Neon Blue/Neon Red for Joy-Con (L)/(R),
gray for the Joy-Con pair, SNES-style Nintendo and other 8BitDo, Micro Green for 8BitDo Micro.
Automatic follows the chosen artwork type. It is a default, not a detection: macOS exposes
no shell-color field, and the open DualSense/DualShock drivers (Linux `hid-playstation`,
SDL) read only firmware/hardware versions from the controller, with no color or retail
variant. Joy-Con body color lives in the controller's SPI flash and can only be read by
sending it subcommands, which Couch Cube doesn't do. A color you pick yourself always wins.
Before Automatic existed Couch Cube saved the inferred default (e.g. Chroma Indigo for
DualSense); such saved values become Automatic once, any other saved color is kept.
Camo colors (Gray Camouflage, Mineral Camo) are drawn with a fixed, seeded camo pattern in
close tones of the color; at very small sizes the art falls back to the flat average tone.
Two outline styles exist: **A · Outline** (default; black lines, light lines only on black
bodies) and **B · Double wall** (black lines on every body plus a subtle offset white wall).
`ConsoleSetup --controller-sheet <dir>` renders comparison sheets of every controller in
both styles.
Controller art is drawn on its own, with no background, in a fixed-size frame on
Home, Controllers, discovered rows and the customize preview. The body is filled with the
controller's color (Automatic or your choice), clipped to its silhouette, and the line drawing
sits on top. Outlines are black for every body color, including dark colors such as purple or
cobalt blue; only black/near-black (neutral) bodies get light outlines on their charcoal fill. When a body would blend into the window background (e.g. white
in Light Mode, black in Dark Mode) a subtle contrasting rim keeps the silhouette visible.
Light outlines on black and partner Joy-Con/shoulder strokes keep at least 3:1 contrast against
the fill or background; Increase Contrast uses pure black/white ink and thicker lines, and fills are
always opaque, so Reduce Transparency changes nothing. Controllers use a single body color;
two-tone shells aren't modeled, so none are guessed. Rendered images are cached per
controller, color, appearance and size and redrawn when the appearance changes.
Input flashing animates the drawing only.
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
Windows games also offers the official **Windows installers** of Steam, Epic Games
Launcher, GOG Galaxy, EA app and Battle.net. These are separate from the macOS
Steam app. **Get** downloads the installer into `Downloads` inside the active game
library's Couch Cube folder (never the drive root), with real byte progress and
Cancel. Only the vendors' own hosts are used: `cdn.akamai.steamstatic.com`
(linked from store.steampowered.com/about), `webinstallers.gog-statics.com`
(gog.com/galaxy), `origin-a.akamaihd.net` (ea.com/ea-app),
`downloader.battle.net` (download.battle.net), and Epic's
`launcher-public-service-prod06.ol.epicgames.com`, which redirects to
`epicgames-download1.akamaized.net`. Epic's download page blocks scripted access,
so that endpoint could not be cross-checked against the page. Epic ships an MSI
(about 260 MB), and the others ship small EXE web installers. Redirects to any other host
are refused. Downloads go to a hidden partial file and are published atomically
only after a free-space check. The file must also be a Windows PE/MSI. An existing
file is reused if identical, otherwise the new file is saved as `Name (2).exe`. Size and
SHA-256 are recorded. Authenticode signatures are not checked, because macOS has no
reliable verifier. Couch Cube never runs or installs these files: they show as
**Downloaded** with Show in Finder, and need Porting Kit or CrossOver to run.
These rows never create sidebar tasks, and an installed Windows launcher is never claimed.
Named sections and row separators organize apps and console families.
Compact switches sit on the right. Status dots always have text: green means
ready/connected, yellow means setup or connection is needed, and red marks a
library problem. Console switches alone indicate whether a system is enabled.
Console switches respond instantly and can be flipped one after another without
waiting: the list is updated in place, and the latest choices are saved in the
background shortly after you stop. If saving fails, the switches return to the
last saved selection and the error is shown.
One switch on each company card (Nintendo, PlayStation, SEGA) shows or hides every console
on that card at once; each card splits into Home consoles and Handhelds (plain headings).
Systems: Nintendo (NES, SNES, N64, GameCube, Wii, Wii U, Switch; Game Boy, Color, Advance), PlayStation
(1, 2, 3; PSP) and SEGA (Mega Drive, Sega CD, Dreamcast; Game Gear). A group switch is on only when all its consoles are shown; a mixed
group is off with an "N of M" count, and switching it shows all. Group switches use the same
instant in-place update and a single batched background save (failures revert them too), and
showing consoles never installs anything.
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

1. **Create game folders in Settings → Game library.** Choose this Mac or an SSD. This creates Couch Cube's
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

**Game library** starts with **Where your games live**, the drive overview
for setup, switching and transfers. **This Mac** is always listed; every
connected external drive gets its own row, and with none connected a disabled
**External SSD — Connect one** row appears. The icon carries the readiness mark
(ready, not set up, needs attention, disconnected or still checking — an
unchecked drive is never called ready or empty), the active library is marked
**Active**, and an existing library's path is a pill that opens it in Finder
without opening the drive. Click the row or its chevron to open the drive page:

- **Couch Cube library**: whether the drive has a library. Without one,
  **Initialize…** creates only the missing Couch Cube folders (APFS/Mac OS
  Extended) and never overwrites existing files. With one, it shows the path,
  **Use this library…** or **Move library…**, and **Remove…**.
- **Remove…** removes only that drive's Couch Cube folder — never the drive,
  SteamLibrary or anything outside it. It lists size and file count, offers Show
  in Finder and **Copy to another drive** (the verified transfer below) first,
  then needs a second confirmation that you backed up what you want to keep.
  The folder goes to the Trash; the running app inside it is refused.
- **Storage**: one bar (Couch Cube files in the accent color, other used files gray, red when 95% full; the rest
  of the track is free), then drive size, used (all files), Couch Cube files and free space.
- **Steam**: games in Steam libraries on that drive, with **Play** and **Manage**
  (opens the game's page in Steam via `steam://nav/games/details/<appid>`) and
  **Open Steam Storage**.
- **Retro games**: only systems that actually have games on that drive.
- **Game storage** (bottom): a bar plus a list showing each game's share of the games
  found on *that* drive — the denominator is the found games' total, not the drive's size.
  Two remembered checkboxes, usable together, change only the presentation (no rescan):
  **Group ROMs by system** (e.g. all PS3 games) and **Group PC games by launcher**
  (Steam, GOG, Battle.net, EA, Epic — only those actually found). The 8 largest entries
  get colors, the rest share a gray "Other" segment; every entry stays in the list
  (**Show all**), tiny ones as "<0.1%". It's insight only: nothing is deleted or moved.
  Sizes are measured off the main thread on the same volume only, skipping symlinks and
  counting hardlinked/shared files once. Coverage: Couch Cube ROMs (when the library is
  ready; multi-disc sets and `.cue/.gdi/.m3u` files are grouped), Steam (`steamapps/common`
  plus Workshop; Steam's reported size if the folder is missing), Battle.net, EA and GOG
  via their install marker files in the drive's Applications/Games folders, Epic via its
  manifests, and CrossOver/Whisky bottles as whole bottles in a "launcher unknown" group
  (internal drive only). Not detected: Amazon, Ubisoft, custom folders and games inside
  bottles individually. Unknown or unreadable sizes are stated and left out of the bar,
  never counted as zero.

Empty sections are hidden. **Your games** summarizes Steam games and ready retro
consoles, with **+** (add a game) and a folder button. The overview's **…** menu
has Check Library and Change Storage. App Store categories collapse with the chevron in their
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

**Settings → Game library** manages storage setup and transfers. The **Steam setup guide** in Game library
shows the exact storage path and manual steps; Couch Cube does not verify
Steam sign-in, controller configuration or completion of those steps.

**Controllers** combines paired Bluetooth controllers, connected USB/Bluetooth
game controllers and previously seen devices under **Connected Controllers**.
Green means connected, gray means disconnected; connected entries show
**USB** or **Bluetooth** (other transports are labeled separately).
Choose the pencil to save a custom name and icon color (or Automatic) in Couch Cube. The sheet previews the
controller's own outline in the chosen color and artwork as you change them; Cancel keeps
the saved look. The original
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
