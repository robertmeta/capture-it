"""Probe the real mic used by a controlled capture process, preferably nondefault."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from fixtures import start_player

binary = str(Path(sys.argv[1]).resolve())
root = (Path(".build/microphone-journey") / str(time.time_ns())).resolve()
root.mkdir(parents=True)
probe = root / "mic-probe"
sources = [str(Path("Sources/CaptureCore") / (name + ".swift")) for name in
           ("AppSelection", "AudioHardware", "CaptureDefaults", "MeetingMetadata", "Types")]
subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", "-target", "arm64-apple-macos26.0", *sources, "Support/MicrophoneProbe.swift", "-o", str(probe)], check=True)
devices = json.loads(subprocess.check_output([binary, "devices", "--json"], text=True))
default = next(device for device in devices if device["isDefault"])
chosen = next((device for device in devices if device["uid"] == "BuiltInMicrophoneDevice"), default)
pid = start_player(root, "MicSource", "440", binary)
session = root / "session"
try:
    with (root / "capture-stderr.txt").open("w") as errors:
        child = subprocess.Popen([binary, "MicSource", "--mic", chosen["uid"], "--out", str(session), "--duration", "25", "--no-transcribe"], stdout=subprocess.PIPE, stderr=errors)
        try:
            deadline = time.monotonic() + 15
            while True:
                metadata = session / "session.json"
                if metadata.exists():
                    state = json.loads(metadata.read_text())
                    if state["recording"] == "recording" and (state.get("inputFrames") or {}).get("mic", 0) > 0:
                        break
                assert child.poll() is None and time.monotonic() < deadline, (root / "capture-stderr.txt").read_text()
                time.sleep(0.05)
            report = json.loads(subprocess.check_output([str(probe), "com.robertmeta.capture-it", str(child.pid)], text=True, timeout=10))
            (root / "probe.json").write_text(json.dumps(report, indent=2))
            if report["source"] == "app":
                assert report["uid"] == chosen["uid"], report
                print(f"passed: real active process microphone identified ({'nondefault' if chosen['uid'] != default['uid'] else 'default'} device)")
            else:
                assert report["source"] == "system-default" and report["uid"] == default["uid"], report
                print(f"passed: app input metadata unavailable/ambiguous; conservative default used: {report['reason']}")
            child.send_signal(signal.SIGINT)
            child.communicate(timeout=15)
            assert child.returncode == 0, (root / "capture-stderr.txt").read_text()
            saved = json.loads((session / "session.json").read_text())
            assert saved["microphone"] == chosen["uid"] and saved["microphoneSelection"] == "explicit"
            assert saved["recording"] == "complete"
            print(f"passed: explicit mic override persisted and capture closed cleanly: {root}")
        finally:
            if child.poll() is None:
                child.kill(); child.wait()
finally:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
