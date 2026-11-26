"""Real local speech capture interrupted during shutdown, with stdout stalled."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import wave
from fixtures import start_player

binary = str(Path(sys.argv[1]).resolve())
status = json.loads(subprocess.check_output([binary, "doctor", "--json"], text=True))
assert status["ready"], "Install local speech assets before this journey"
fixture = os.environ.get("CAPTURE_IT_SPEECH_FIXTURE")
if not fixture:
    whisper = shutil.which("whisper-cli")
    assert whisper, "Set CAPTURE_IT_SPEECH_FIXTURE to a local speech WAV"
    fixture = str(Path(whisper).resolve().parents[1] / "share/whisper.cpp/jfk.wav")
assert Path(fixture).is_file(), fixture
root = Path(".build/shutdown-journey").resolve() / str(time.time_ns())
root.mkdir(parents=True)
hook = root / "should-not-run.py"
hook.write_text("#!/usr/bin/env python3\nraise SystemExit('Hook must be skipped on forced shutdown')\n")
hook.chmod(0o700)
pid = start_player(root, "Shutdown", fixture, binary)
read_fd, write_fd = os.pipe()
child = None
try:
    # A full pipe makes the final stdout join observable even if ASR is fast.
    flags = fcntl.fcntl(write_fd, fcntl.F_GETFL)
    fcntl.fcntl(write_fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    try:
        while True:
            os.write(write_fd, b"x" * 4096)
    except BlockingIOError:
        pass
    fcntl.fcntl(write_fd, fcntl.F_SETFL, flags)
    session = root / "session"
    with (root / "stderr.txt").open("w") as errors:
        child = subprocess.Popen([binary, "record", "--format", "wav", "--app", "com.robertmeta.capture-it.fixture.shutdown", "--out", str(session), "--hook", str(hook)], stdout=write_fd, stderr=errors)
        deadline = time.monotonic() + 45
        while True:
            transcript = session / "transcript.txt"
            if transcript.exists() and transcript.stat().st_size > 0:
                assert json.loads((session / "session.json").read_text())["recording"] == "recording"
                break
            assert child.poll() is None and time.monotonic() < deadline, "No live speech before interrupt"
            time.sleep(0.01)
        child.send_signal(signal.SIGINT)
        deadline = time.monotonic() + 10
        while "Audio saved. Finishing transcription" not in (root / "stderr.txt").read_text():
            assert child.poll() is None and time.monotonic() < deadline, "Did not enter speech drain"
            time.sleep(0.005)
        saved = json.loads((session / "session.json").read_text())
        assert saved["recording"] == "complete" and saved["chunks"][0]["closed"]
        began = time.monotonic()
        child.send_signal(signal.SIGINT)
        child.wait(timeout=2)
        elapsed = time.monotonic() - began
    errors = (root / "stderr.txt").read_text()
    assert child.returncode == 2, errors
    assert elapsed < 1, f"Second interrupt waited {elapsed:.2f}s"
    saved = json.loads((session / "session.json").read_text())
    assert saved["recording"] == "complete" and saved["transcription"] == "interrupted", saved
    assert any("interrupted by user" in issue for issue in saved["issues"])
    assert not json.loads((session / "transcript.json").read_text())["complete"]
    assert (session / "transcript.txt").stat().st_size > 0
    hook_results = list(session.glob("hooks/*/result.json"))
    assert len(hook_results) == 1
    assert json.loads(hook_results[0].read_text())["results"][0]["status"] == "skipped"
    assert list(session.glob("*.wav")) == [session / "recording.wav"]
    with wave.open(str(session / "recording.wav")) as audio:
        assert audio.getnchannels() == 3 and audio.getframerate() == 48000
        assert audio.getnframes() == saved["chunks"][0]["frames"] > 0
        assert len(audio.readframes(audio.getnframes())) == audio.getnframes() * 6
    print(f"passed: first Ctrl-C closes WAV before speech/output drain; second exits in {elapsed:.3f}s with readable WAV and partial transcript: {session}")
finally:
    if child is not None and child.poll() is None:
        child.kill()
        child.wait()
    os.close(read_fd)
    os.close(write_fd)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
