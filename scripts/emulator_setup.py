"""First-launch setup for the standalone emulators (PCSX2, RPCS3, Ryujinx, Dolphin).

The player drops their own BIOS / firmware / keys into the library (BIOS/ps2, BIOS/ps3, BIOS/switch).
Right before a game starts, `prepare` copies them to where the emulator expects them and fills in
console-style defaults (fullscreen, no dialogs, controller slots). Nothing is downloaded, existing
BIOS files are never overwritten, and an existing emulator config is backed up before it is touched
and is touched only once; later launches leave the player's own changes alone.
"""
import shutil
import subprocess
from pathlib import Path

CONFIG_VERSION = 1
MARKER = "Config/emulator-setup.json"

BIOS_FOLDERS = {"ps2": "BIOS/ps2", "ps3": "BIOS/ps3", "switch": "BIOS/switch", "xbox": "BIOS/xbox"}
XBOX_FILES = {"bootrom_path": "mcpx_1.0.bin", "flashrom_path": "Complex_4627v1.03.bin", "hdd_path": "xbox_hdd.qcow2"}
PS2_BIOS_SUFFIXES = {".bin", ".rom0", ".rom1", ".erom", ".mec", ".nvm"}
PS2_MIN_BYTES = 1_000_000  # real PS2 BIOS images are 4 MB; this skips stray text and tiny files

# PCSX2 binds pads by SDL index: SDL-0 is the first connected controller. With no multitap a game sees
# ports 1A (Pad1) and 2A (Pad2); with the multitap on port 1 it sees Pad1, Pad3, Pad4 and Pad5.
# Giving Pad2 the second controller and Pad3-5 controllers 2-4 makes both cases work.
PCSX2_PAD_CONTROLLER = {1: 0, 2: 1, 3: 1, 4: 2, 5: 3}
PCSX2_BINDINGS = {
    "Up": "DPadUp", "Right": "DPadRight", "Down": "DPadDown", "Left": "DPadLeft",
    "Triangle": "Y", "Circle": "B", "Cross": "A", "Square": "X",
    "Select": "Back", "Start": "Start", "L1": "LeftShoulder", "L2": "+LeftTrigger",
    "R1": "RightShoulder", "R2": "+RightTrigger", "L3": "LeftStick", "R3": "RightStick",
    "LUp": "-LeftY", "LRight": "+LeftX", "LDown": "+LeftY", "LLeft": "-LeftX",
    "RUp": "-RightY", "RRight": "+RightX", "RDown": "+RightY", "RLeft": "-RightX",
    "Analog": "Guide", "LargeMotor": "LargeMotor", "SmallMotor": "SmallMotor",
}


def _usable(path):
    return path.is_file() and not path.is_symlink()


def library_files(library, system):
    folder = library / BIOS_FOLDERS[system]
    if not folder.is_dir() or folder.is_symlink():
        return []
    return sorted(path for path in folder.iterdir() if _usable(path) and not path.name.startswith("."))


def ps2_bios(library):
    return [path for path in library_files(library, "ps2")
            if path.suffix.lower() in PS2_BIOS_SUFFIXES and path.stat().st_size >= PS2_MIN_BYTES]


def ps3_firmware(library):
    return next((path for path in library_files(library, "ps3") if path.name.upper() == "PS3UPDAT.PUP"), None)


def switch_keys(library):
    return {path.name.lower(): path for path in library_files(library, "switch")
            if path.name.lower() in {"prod.keys", "title.keys"}}


def switch_firmware(library):
    return next((path for path in library_files(library, "switch") if path.suffix.lower() == ".zip"), None)


def bios_files(library, system):
    """Rows for the console's BIOS list: what the player has put in the drop folder."""
    if system == "ps2":
        names = [path.name for path in ps2_bios(library)] or ["a PS2 BIOS image (e.g. scph*.bin)"]
        found = bool(ps2_bios(library))
    elif system == "ps3":
        names, found = ["PS3UPDAT.PUP"], ps3_firmware(library) is not None
    elif system == "switch":
        keys = switch_keys(library)
        rows = [{"filename": "prod.keys", "present": "prod.keys" in keys},
                {"filename": "Firmware .zip", "present": switch_firmware(library) is not None}]
        return [{"filename": row["filename"], "path": str(library / BIOS_FOLDERS[system] / row["filename"]),
                 "present": row["present"], "note": "Your own console dump; drop it into BIOS/switch"}
                for row in rows]
    elif system == "xbox":
        folder = library / BIOS_FOLDERS[system]
        return [{"filename": name, "path": str(folder / name), "present": _usable(folder / name),
                 "note": "Your own copy; drop it into " + BIOS_FOLDERS[system]} for name in XBOX_FILES.values()]
    else:
        return []
    return [{"filename": name, "path": str(library / BIOS_FOLDERS[system] / name), "present": found,
             "note": "Your own copy; drop it into " + BIOS_FOLDERS[system]} for name in names]


def ini_merge(path, values):
    """Set `values` ({section: {key: value}}) in an INI file, keeping everything else (order, comments)."""
    lines = path.read_text().splitlines() if path.is_file() else []
    for section, entries in values.items():
        header = f"[{section}]"
        start = next((index for index, line in enumerate(lines) if line.strip() == header), None)
        if start is None:
            if lines and lines[-1].strip():
                lines.append("")
            lines.append(header)
            start = len(lines) - 1
        end = start + 1
        while end < len(lines) and not lines[end].lstrip().startswith("["):
            end += 1
        while end > start + 1 and not lines[end - 1].strip():
            end -= 1  # new keys go before the blank line that separates sections
        for key, value in entries.items():
            row = f"{key} = {value}"
            at = next((index for index in range(start + 1, end)
                       if lines[index].split("=", 1)[0].strip() == key and "=" in lines[index]), None)
            if at is None:
                lines.insert(end, row)
                end += 1
            else:
                lines[at] = row
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def _backup_once(path):
    backup = path.with_name(path.name + ".couchcube-backup")
    if path.is_file() and not backup.exists():
        shutil.copy2(path, backup)


def _copy_missing(source, folder):
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / source.name
    if not target.exists():
        shutil.copy2(source, target)
        return True
    return False


def pcsx2_values():
    values = {
        "UI": {"SetupWizardIncomplete": "false", "StartFullscreen": "true", "ConfirmShutdown": "false"},
        "Pad": {"MultitapPort1": "false", "MultitapPort2": "false"},
    }
    for pad, controller in PCSX2_PAD_CONTROLLER.items():
        section = {"Type": "DualShock2"}
        section.update({name: f"SDL-{controller}/{button}" for name, button in PCSX2_BINDINGS.items()})
        values[f"Pad{pad}"] = section
    return values


def prepare_pcsx2(library, home, state):
    notes = []
    data = home / "Library/Application Support/PCSX2"
    for source in ps2_bios(library):
        if _copy_missing(source, data / "bios"):
            notes.append("PS2 BIOS installed: " + source.name)
    if not any((data / "bios").glob("*")):
        notes.append("PS2 BIOS missing: put your BIOS file in " + BIOS_FOLDERS["ps2"])
    if state.get("pcsx2") != CONFIG_VERSION:
        ini = data / "inis/PCSX2.ini"
        _backup_once(ini)
        ini_merge(ini, pcsx2_values())
        state["pcsx2"] = CONFIG_VERSION
        notes.append("PCSX2 configured: fullscreen, controllers 1-4")
    return notes


def rpcs3_firmware_installed(home):
    folder = home / "Library/Application Support/rpcs3/dev_flash/sys"
    return folder.is_dir() and any(folder.iterdir())


def prepare_rpcs3(library, home, binary, state, run=subprocess.run):
    pup = ps3_firmware(library)
    if rpcs3_firmware_installed(home):
        return []
    if pup is None:
        return ["PS3 firmware missing: put PS3UPDAT.PUP in " + BIOS_FOLDERS["ps3"]]
    run([str(binary), "--installfw", str(pup)], check=True, timeout=1800)
    return ["PS3 firmware installed"]


def prepare_switch(library, home):
    notes = []
    data = home / "Library/Application Support/Ryujinx"
    for name, source in switch_keys(library).items():
        if _copy_missing(source, data / "system"):
            notes.append("Switch keys installed: " + name)
    if "prod.keys" not in switch_keys(library) and not (data / "system/prod.keys").is_file():
        notes.append("Switch prod.keys missing: put it in " + BIOS_FOLDERS["switch"])
    return notes


def prepare_xemu(library, home, state):
    notes = []
    data = home / "Library/Application Support/xemu/xemu"
    folder = library / BIOS_FOLDERS["xbox"]
    paths = {}
    for key, name in XBOX_FILES.items():
        source = folder / name
        if _usable(source):
            _copy_missing(source, data)
            paths[key] = "'" + str(data / name) + "'"
        else:
            notes.append(f"Xbox file missing: put {name} in {BIOS_FOLDERS['xbox']}")
    if paths and state.get("xemu") != CONFIG_VERSION:
        config = data / "xemu.toml"
        _backup_once(config)
        ini_merge(config, {"sys.files": paths, "general": {"show_welcome": "false"}})
        state["xemu"] = CONFIG_VERSION
        notes.append("xemu configured with your Xbox files")
    return notes


def prepare_dolphin(library, state):
    if state.get("dolphin") == CONFIG_VERSION:
        return []
    config = library / "Saves/Dolphin/Config/Dolphin.ini"
    _backup_once(config)
    # SIDevice 6 = standard GameCube controller on all four ports.
    ini_merge(config, {"Core": {f"SIDevice{port}": "6" for port in range(4)},
                       "Display": {"Fullscreen": "True"},
                       "Interface": {"ConfirmStop": "False"}})
    state["dolphin"] = CONFIG_VERSION
    return ["Dolphin configured: fullscreen, four controller ports"]


def prepare(core, library, home, binary=None, state=None, run=subprocess.run):
    """Bring one emulator to a ready state. Returns short notes; `state` records one-time config done."""
    state = {} if state is None else state
    if core == "pcsx2":
        return prepare_pcsx2(library, home, state)
    if core == "rpcs3":
        return prepare_rpcs3(library, home, binary, state, run)
    if core == "switch":
        return prepare_switch(library, home)
    if core == "dolphin":
        return prepare_dolphin(library, state)
    if core == "xemu":
        return prepare_xemu(library, home, state)
    return []
