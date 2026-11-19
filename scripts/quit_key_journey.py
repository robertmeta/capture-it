"""Real foreground PTY recording: q drains, Escape does nothing, Ctrl-C escalates."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import termios
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
root = Path(".build/quit-key-journey").resolve() / str(time.time_ns())
root.mkdir(parents=True)


def wait_for(predicate, child, errors, timeout=45):
    deadline = time.monotonic() + timeout
    while not predicate():
        assert child.poll() is None and time.monotonic() < deadline, errors.read_text()
        time.sleep(0.01)


def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(0, os.getpgrp())


@contextmanager
def recording(name, terminal=True):
    work = root / name
    work.mkdir()
    session = work / "session"
    release = work / "release"
    hook = work / "wait-for-release.py"
    hook.write_text('''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
event = json.loads(Path(sys.argv[1]).read_text())
assert event['recordingStatus'] == 'complete' and event['transcriptComplete']
output = Path(os.environ['CAPTURE_IT_HOOK_OUTPUT'])
(output / 'started').touch()
while not Path(''' + repr(str(release)) + ''').exists():
    (output / 'pulse').touch()
    time.sleep(0.02)
(output / 'finished').touch()
''')
    hook.chmod(0o700)
    if terminal:
        writer, reader = pty.openpty()
        original = termios.tcgetattr(reader)
    else:
        reader, writer = os.pipe()
        original = None
    errors = work / "stderr.txt"
    with errors.open("w") as stderr, (work / "stdout.txt").open("w") as stdout:
        child = subprocess.Popen([binary, "record", "--app", "com.robertmeta.capture-it.fixture.quitkeys",
                                  "--out", str(session), "--hook", str(hook)],
                                 stdin=reader, stdout=stdout, stderr=stderr,
                                 preexec_fn=controlling_terminal if terminal else None)
        try:
            wait_for(lambda: (session / "transcript.txt").exists() and (session / "transcript.txt").stat().st_size > 0,
                     child, errors)
            wait_for(lambda: bool(manifest(session)["chunks"]) and manifest(session)["chunks"][0]["frames"] > 0,
                     child, errors)
            if terminal:
                current = termios.tcgetattr(reader)
                assert not current[3] & (termios.ICANON | termios.ECHO)
                assert current[3] & termios.ISIG == original[3] & termios.ISIG
            yield child, writer, reader, session, release, errors
        finally:
            release.touch()
            if child.poll() is None:
                child.send_signal(signal.SIGINT)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.send_signal(signal.SIGINT)
                    child.wait(timeout=5)
            try:
                if terminal:
                    # On macOS the slave rejects ioctls after its session leader
                    # exits; the master retains the terminal attributes.
                    assert termios.tcgetattr(writer) == original, "Terminal settings were not restored"
            finally:
                os.close(reader); os.close(writer)


def manifest(session):
    return json.loads((session / "session.json").read_text())


def wait_for_hook(child, session, errors):
    wait_for(lambda: bool(list(session.glob("hooks/*/*/started"))), child, errors)
    return next(session.glob("hooks/*/*/started")).parent


def assert_saved(child, session, expected):
    assert child.returncode == expected
    saved = manifest(session)
    assert saved["recording"] == "complete" and saved["transcription"] == "complete", saved
    assert saved["chunks"][0]["closed"]
    assert (session / "transcript.txt").stat().st_size > 0
    assert json.loads((session / "transcript.json").read_text())["complete"]
    with wave.open(str(session / "recording.wav")) as audio:
        assert audio.getnchannels() == 3 and audio.getnframes() == saved["chunks"][0]["frames"] > 0
        assert len(audio.readframes(audio.getnframes())) == audio.getnframes() * 6
    rows = json.loads(next(session.glob("hooks/*/result.json")).read_text())["results"]
    assert rows[-1]["status"] == ("complete" if expected == 0 else "interrupted"), rows
    assert all(row["status"] == "complete" for row in rows[:-1]), rows
    if status.get("fluidHook"):
        assert len(rows) == 2
        assert (Path(rows[0]["outputDirectory"]) / "speaker-transcript.txt").is_file()


player = start_player(root, "QuitKeys", fixture, binary)
try:
    with recording("q-graceful") as (child, writer, _, session, release, errors):
        baseline = manifest(session)["chunks"][0]["frames"]
        os.write(writer, b"\x1b")
        wait_for(lambda: manifest(session)["chunks"][0]["frames"] > baseline, child, errors)
        assert manifest(session)["recording"] == "recording", "Escape stopped recording"
        os.write(writer, b"qqq")  # No newline: immediate graceful stop.
        output = wait_for_hook(child, session, errors)
        wait_for(lambda: (output / "pulse").exists(), child, errors)
        pulse = (output / "pulse").stat().st_mtime_ns
        os.write(writer, b"qq\x1bqq")
        wait_for(lambda: (output / "pulse").stat().st_mtime_ns > pulse + 150_000_000, child, errors)
        assert child.poll() is None and not (output / "finished").exists()
        release.touch(); child.wait(timeout=10)
        assert_saved(child, session, 0)
    print("passed: q without Enter saves WAV/live transcript and completes hooks; repeated q never cancels; Escape ignored; terminal restored", flush=True)

    for name, first in [("two-control-c", b"\x03"), ("q-then-control-c", b"q")]:
        with recording(name) as (child, writer, _, session, _, errors):
            os.write(writer, first)
            wait_for_hook(child, session, errors)
            os.write(writer, b"\x03")
            child.wait(timeout=5)
            assert_saved(child, session, 2)
        print(f"passed: {name} cancels a running hook, preserves WAV/text and restores terminal", flush=True)

    with recording("non-tty", terminal=False) as (child, writer, reader, session, release, errors):
        baseline = manifest(session)["chunks"][0]["frames"]
        os.write(writer, b"q")
        wait_for(lambda: manifest(session)["chunks"][0]["frames"] > baseline, child, errors)
        assert manifest(session)["recording"] == "recording"
        assert select.select([reader], [], [], 0)[0], "CLI consumed piped stdin"
        assert os.read(reader, 1) == b"q"
        release.touch(); child.send_signal(signal.SIGINT); child.wait(timeout=15)
        assert_saved(child, session, 0)
    print("passed: piped stdin stays unread; signal-based graceful stop still works", flush=True)
finally:
    try:
        os.kill(player, signal.SIGTERM)
    except ProcessLookupError:
        pass
