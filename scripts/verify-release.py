#!/usr/bin/env python3
"""Read-only DMG/app verification; never runs setup or erase."""
from pathlib import Path
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time


def detach(mount):
    """Unmount the image; retry while a crashed smoke child releases files, then force."""
    for attempt in range(5):
        result = subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode == 0:
            return
        time.sleep(2)
    result = subprocess.run(["/usr/bin/hdiutil", "detach", "-force", str(mount)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Could not detach {mount}: {result.stderr.strip()}")


RELEASE = json.loads((Path(__file__).resolve().parent.parent / "config/release.json").read_text())


def run(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def verify_app(app, working_directory, distribution="local"):
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    assert info["LSMinimumSystemVersion"] == "13.0"
    assert info["CFBundleName"] == "Couch Cube"
    assert info["CFBundleDisplayName"] == "Couch Cube"
    assert info["CFBundleIconFile"] == "Console"
    assert info["MCCDistribution"] == distribution
    assert info["NSBluetoothAlwaysUsageDescription"]
    assert info["CFBundleIdentifier"] == RELEASE["bundle_id"]
    assert info["CouchCubeVersion"] == RELEASE["version"]
    assert info["CFBundleShortVersionString"] == RELEASE["version"].split("-")[0]
    assert info["CFBundleVersion"] == str(RELEASE["build"])
    # Activity must never open by itself in release: no debug flag baked in, no window restoration.
    assert "COUCH_CUBE_DEBUG_ACTIVITY" not in (info.get("LSEnvironment") or {})
    assert not info.get("NSQuitAlwaysKeepsWindows")
    for key in ("NSRemindersUsageDescription", "NSRemindersFullAccessUsageDescription"):
        assert "reminder" in (info.get(key) or "").lower(), key
    resources = app / "Contents/Resources"
    assert (resources / "Console.icns").is_file()
    assert (resources / "scripts/releases.py").is_file()
    assert (resources / "scripts/deals.py").is_file()
    assert (resources / "scripts/windows_downloads.py").is_file()
    assert (resources / "scripts/store_accounts.py").is_file()
    assert (resources / "scripts/shop.py").is_file()
    assert (resources / "scripts/wishlist.py").is_file()
    assert (resources / "scripts/rates.py").is_file()
    assert os.access(resources / "scripts/askpass.sh", os.X_OK)
    assert (resources / "config/release.json").is_file()
    assert (resources / "config/bios-map.csv").is_file()
    assert (resources / "Install Homebrew.command").is_file()
    helper = app / "Contents/MacOS/ConsoleAutoLaunch"
    assert helper.is_file()
    run([str(helper), "--self-test"], cwd=working_directory)
    run(["/bin/bash", "-n", str(resources / "Install Homebrew.command")])
    python = resources / "python/bin/python3"
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    run([str(python), "-I", "-B", "-c",
         "import json,ssl,hashlib,plistlib,sqlite3,platform,sys; "
         "from pathlib import Path; "
         "assert platform.machine() == 'arm64'; "
         "assert Path(sys.executable).is_relative_to(Path(sys.argv[1])); "
         "print('Relocated bundled Python imports passed')", str(app)],
        cwd=working_directory, env={"PATH": "/usr/bin:/bin", "HOME": str(Path.home())})
    run([str(python), "-I", "-B", str(resources / "scripts/console.py"), "drives"], cwd=working_directory)
    for appearance in ("light", "dark"):
        run([str(app / "Contents/MacOS/ConsoleSetup"), "--smoke-test", "--smoke-flow",
             "--smoke-activity", "--minimum-size",
             "--appearance", appearance], cwd=working_directory)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    assert list(resources.rglob("LICENSE*")), "Runtime licenses missing"
    assert not (resources / "config/paths.env").exists()


image = Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="couch-cube-release-") as directory:
    mount = Path(directory) / "image"
    mount.mkdir()
    attached = False
    try:
        run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        attached = True
        app = mount / "CouchCube.app"
        assert (mount / "Applications").is_symlink()
        assert (mount / "Applications").readlink() == Path("/Applications")
        assert not (mount / "Start Here.txt").exists()
        assert (mount / "README.md").is_file()
        assert (mount / ".VolumeIcon.icns").is_file()
        assert (mount / ".VolumeIcon.icns").read_bytes() == (app / "Contents/Resources/Console.icns").read_bytes()
        local_icon = (app / "Contents/Resources/Console.icns").read_bytes()
        installer_icon = (mount / ".VolumeIcon.icns").read_bytes()
        flags = run(["/usr/bin/xcrun", "GetFileInfo", "-aC", str(mount)], stdout=subprocess.PIPE)
        assert flags.stdout.strip() == b"1", "Mounted DMG custom icon is not enabled"
        verify_app(app, directory)
        relocated = Path(directory) / "SSD copy/CouchCube.app"
        relocated.parent.mkdir()
        run(["/usr/bin/ditto", str(app), str(relocated)])
        print("Read-only release verification passed: DMG contents, signature, relocated runtime, backend and native GUI.")
    finally:
        if attached:
            try:
                detach(mount)
            except RuntimeError as error:
                # Report it, but never mask the verification failure that is already propagating.
                if sys.exc_info()[0] is None:
                    raise
                print(f"warning: {error}", file=sys.stderr)

    with tempfile.TemporaryDirectory(prefix="couch-cube-copy-") as copy_directory:
        app = relocated
        directory = copy_directory
        verify_app(app, directory)
        copied = Path(directory) / "Descriptor copy/CouchCube.app"
        copied.mkdir(parents=True)
        run([str(app / "Contents/Resources/python/bin/python3"), "-I", "-B", "-c",
             "import importlib.util,os,sys; from pathlib import Path; "
             "source=Path(sys.argv[1]); target=Path(sys.argv[2]); "
             "spec=importlib.util.spec_from_file_location('backend',source/'Contents/Resources/scripts/console.py'); "
             "module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); "
             "fd=os.open(target,os.O_RDONLY|os.O_DIRECTORY); "
             "module.copy_bundle_contents(source,fd); os.close(fd)", str(app), str(copied)],
            cwd=directory)
        verify_app(copied, directory)
        print("Single DMG app relocation and descriptor-relative SSD copy passed; no Applications installation used.")

archive = image.with_name(image.stem + "-SSD.zip")
assert archive.is_file(), "SSD pack ZIP missing"
with tempfile.TemporaryDirectory(prefix="couch-cube-ssd-pack-") as directory:
    run(["/usr/bin/ditto", "-x", "-k", str(archive), directory])
    root = Path(directory).resolve()
    app = root / "CouchCube.app"
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    resources = app / "Contents/Resources"
    run([str(resources / "python/bin/python3"), "-I", "-B", "-c",
         "import importlib.util,sys; from pathlib import Path; "
         "source=Path(sys.argv[1]); root=Path(sys.argv[2]); "
         "spec=importlib.util.spec_from_file_location('backend',source); "
         "module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); "
         "assert module.is_ssd_template(root/module.FOLDER); "
         "assert not (root/module.FOLDER/module.MARKER).exists(); "
         "assert all((root/module.FOLDER/folder).is_dir() for folder in module.SSD_FOLDERS); "
         "print('SSD ZIP signature and empty portable template passed')",
         str(resources / "scripts/console.py"), str(root)], cwd=directory)
