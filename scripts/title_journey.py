"""Real selected-app AX title capture and saved metadata; requires AX permission."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import wave
from fixtures import start_player

binary = str(Path(sys.argv[1]).resolve())
root = Path(".build/title-journey").resolve() / str(time.time_ns())
root.mkdir(parents=True)
status = json.loads(subprocess.check_output([binary, "doctor", "--json"], text=True))
assert status["accessibilityTrusted"], "Run capture-it setup-accessibility and grant Accessibility before this journey"
subprocess.run([binary, "setup-accessibility"], check=True)
pids = []


def capture(name, title=None, hook=False):
    output = root / name
    args = [binary, "record", "--app", f"com.robertmeta.capture-it.fixture.{name.lower()}",
            "--out", str(output), "--duration", "2", "--no-transcribe"]
    if title is not None:
        args += ["--title", title]
    if hook:
        args += ["--hook", str(Path("examples/hooks/inspect-session.py").resolve())]
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    (root / f"{name}-stderr.txt").write_text(result.stderr)
    assert result.returncode == 0, result.stderr
    assert result.stdout == ""
    metadata = json.loads((output / "session.json").read_text())
    assert metadata["recording"] == "complete", metadata
    with wave.open(str(output / "recording.wav")) as audio:
        assert audio.getnchannels() == 3 and audio.getnframes() > 0
    return output, metadata


try:
    pids.append(start_player(root, "TitleSelected", "440", binary, "Weekly Planning | TitleSelected"))
    pids.append(start_player(root, "TitleOther", "1000", binary, "Unrelated private title | TitleOther"))
    output, metadata = capture("TitleSelected", hook=True)
    meeting = metadata["meeting"]
    assert meeting["title"] == "Weekly Planning", meeting
    assert meeting["source"] == "accessibility-window-title" and not meeting["verified"]
    assert meeting["status"] == "candidate"
    event = json.loads(next(output.glob("hooks/*/input.json")).read_text())
    assert event["meeting"] == meeting
    observed = json.loads(next(output.glob("hooks/*/*/inspection.json")).read_text())
    assert observed["meeting"] == meeting
    assert "Unrelated private title" not in json.dumps(metadata)
    print("passed: actual selected-PID AX title capture, source/uncertainty, saved WAV and hook handoff; unrelated app excluded", flush=True)

    pids.append(start_player(root, "TitleOverride", "440", binary, "A different window title"))
    _, metadata = capture("TitleOverride", title="User-confirmed planning")
    assert metadata["meeting"]["title"] == "User-confirmed planning"
    assert metadata["meeting"]["source"] == "explicit" and metadata["meeting"]["verified"]
    print("passed: explicit meeting title wins over Accessibility evidence", flush=True)

    pids.append(start_player(root, "TitleGeneric", "440", binary, "TitleGeneric"))
    _, metadata = capture("TitleGeneric")
    assert not metadata["meeting"].get("title") and metadata["meeting"]["status"] == "unknown", metadata
    invalid = subprocess.run([binary, "record", "no-app", "--title", " \n "], capture_output=True, text=True)
    assert invalid.returncode == 1 and "--title must not be empty" in invalid.stderr
    print(f"passed: generic title remains unknown and audio succeeds; artifacts: {root}", flush=True)
finally:
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
