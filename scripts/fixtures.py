"""Local audio fixture app identity and LaunchServices lifecycle; no downloads."""
import json
from pathlib import Path
import plistlib
import subprocess
import time


def start_player(root: Path, name: str, argument: str, binary: str, title: str | None = None) -> int:
    app = root / f"{name}.app" / "Contents"
    (app / "MacOS").mkdir(parents=True, exist_ok=True)
    executable = app / "MacOS" / "FixturePlayer"
    bundle = f"com.robertmeta.capture-it.fixture.{name.lower()}"
    with (app / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle, "CFBundlePackageType": "APPL",
                      "CFBundleName": name, "CFBundleExecutable": "FixturePlayer", "LSUIElement": True}, handle)
    subprocess.run(["xcrun", "swiftc", "-target", "arm64-apple-macos26.0", "Support/FixturePlayer.swift",
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                    "-Xlinker", str(app / "Info.plist"), "-o", str(executable)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", bundle, str(app.parent)], check=True)
    # Separate LaunchServices responsibility identities are essential to app isolation.
    subprocess.run(["open", "-n", "-g", str(app.parent), "--args", argument, *([title] if title is not None else [])], check=True)
    deadline = time.monotonic() + 10
    while True:
        apps = json.loads(subprocess.check_output([binary, "apps", "--json"], text=True))
        matching = [item for item in apps if item["bundleID"] == bundle and item["playing"]]
        if matching:
            return matching[0]["pid"]
        assert time.monotonic() < deadline, f"Fixture did not start audio: {bundle}"
        time.sleep(0.05)
