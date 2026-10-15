#!/usr/bin/env python3
"""Read-only DMG/app verification; never runs setup or erase."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


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
    assert info["CFBundleShortVersionString"] == "0.3.0"
    resources = app / "Contents/Resources"
    assert (resources / "Console.icns").is_file()
    assert (resources / "scripts/releases.py").is_file()
    assert (resources / "config/release.json").is_file()
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
    for page in range(7):
        run([str(app / "Contents/MacOS/ConsoleSetup"), "--smoke-test", "--page", str(page)], cwd=working_directory)
    run([str(app / "Contents/MacOS/ConsoleSetup"), "--smoke-test", "--smoke-flow"], cwd=working_directory)
    for appearance in ("light", "dark"):
        run([str(app / "Contents/MacOS/ConsoleSetup"), "--smoke-test", "--smoke-activity",
             "--appearance", appearance], cwd=working_directory)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    assert list(resources.rglob("LICENSE*")), "Runtime licenses missing"
    assert not (resources / "config/paths.env").exists()


image = Path(sys.argv[1]).resolve(strict=True)
with tempfile.TemporaryDirectory(prefix="mac-console-release-") as directory:
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
        assert (mount / ".VolumeIcon.icns").read_bytes() != (app / "Contents/Resources/Console.icns").read_bytes()
        local_icon = (app / "Contents/Resources/Console.icns").read_bytes()
        installer_icon = (mount / ".VolumeIcon.icns").read_bytes()
        flags = run(["/usr/bin/xcrun", "GetFileInfo", "-aC", str(mount)], stdout=subprocess.PIPE)
        assert flags.stdout.strip() == b"1", "Mounted DMG custom icon is not enabled"
        verify_app(app, directory)
        print("Read-only release verification passed: DMG contents, signature, relocated runtime, backend and native GUI.")
    finally:
        if attached:
            run(["/usr/bin/hdiutil", "detach", str(mount)], stdout=subprocess.PIPE)

if len(sys.argv) > 2:
    archive = Path(sys.argv[2]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="mac-console-portable-") as directory:
        download = Path(directory) / "Download"
        moved = Path(directory) / "Gaming SSD with spaces"
        run(["/usr/bin/ditto", "-x", "-k", str(archive), str(download)])
        download.rename(moved)
        verify_app(moved / "CouchCube.app", directory, distribution="portable")
        app = moved / "CouchCube.app"
        portable_icon = (app / "Contents/Resources/Console.icns").read_bytes()
        assert portable_icon not in [local_icon, installer_icon], "Portable icon must differ from local and DMG icons"
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
        verify_app(copied, directory, distribution="portable")
        print("Portable ZIP verification passed after moving the extracted app; no Applications installation used.")
