"""Real CLI app-name/glob and PTY picker journeys with persisted capture output."""
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import sys
import time
import wave
from fixtures import start_player

binary = str(Path(sys.argv[1]).resolve())
root = (Path(".build/selection-journey") / str(time.time_ns())).resolve()
root.mkdir(parents=True)
children = []


def command(query, directory):
    return [binary, "record", "--app", query, "--out", str(directory), "--duration", "2", "--no-transcribe"]


def assert_capture(directory, pid):
    saved = json.loads((directory / "session.json").read_text())
    assert saved["recording"] == "complete" and saved["app"] == "com.robertmeta.capture-it.fixture.selected", saved
    assert saved["selectedProcessID"] == pid
    assert saved["microphoneSelection"] in ("system-default", "app", "explicit")
    assert list(directory.glob("*.wav")) == [directory / "recording.wav"]
    with wave.open(str(directory / "recording.wav")) as audio:
        assert audio.getnchannels() == 3 and audio.getnframes() > 24_000


def interactive(directory, answer, retry=False):
    master, slave = pty.openpty()
    child = subprocess.Popen(command("*capture-it.fixture.*", directory), stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.close(slave)
    observed = b""

    def until(token):
        nonlocal observed
        deadline = time.monotonic() + 15
        fragment = b""
        while token not in fragment:
            assert child.poll() is None and time.monotonic() < deadline, observed.decode(errors="replace")
            if select.select([child.stderr], [], [], 0.1)[0]:
                data = os.read(child.stderr.fileno(), 4096)
                assert data, observed.decode(errors="replace")
                fragment += data
                observed += data
        return fragment

    try:
        until(b"(q to cancel): ")
        choices = re.findall(rb"\s(\d+)\. ([^\r\n]+)", observed)
        assert len(choices) == 2, choices
        selected = next(number for number, label in choices if b"fixture.selected," in label)
        if retry:
            os.write(master, b"0\n")
            until(b"(q to cancel): ")
            assert b"Enter a number" in observed
        os.write(master, (selected if answer == "select" else answer.encode()) + b"\n")
        stdout, stderr = child.communicate(timeout=20)
        observed += stderr
        assert stdout == b"", "Picker/status leaked onto transcript stdout"
        return child.returncode, observed.decode(errors="replace")
    finally:
        if child.poll() is None:
            child.kill(); child.wait()
        os.close(master)


try:
    for name, frequency in [("Selected", 440), ("Excluded", 1000)]:
        children.append(start_player(root, name, str(frequency), binary))
    for label, query in [("substring", "FIXTURE.SELECTED"), ("wildcard", "*fixture.selected")]:
        directory = root / label
        result = subprocess.run(command(query, directory), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        assert_capture(directory, children[0])
    # Public shorthand creates a query-dated directory in the caller's cwd.
    work = root / "cwd"
    work.mkdir()
    for args in (["Selected"], ["record", "*Selected*"]):
        before = set(work.iterdir())
        result = subprocess.run([binary, *args, "--duration", "1", "--no-transcribe"], cwd=work, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        created = set(work.iterdir()) - before
        assert len(created) == 1
        output = created.pop()
        assert re.fullmatch(r"selected-\d{8}-\d{6}(?:-\d+)?", output.name), output
        assert_capture(output, children[0])
        saved = json.loads((output / "session.json").read_text())
        assert saved["microphoneSelection"] == "system-default", saved
        assert "Microphone:" in result.stderr and "system default" in result.stderr
    # Explicit --mic still wins over automatic inference.
    devices = json.loads(subprocess.check_output([binary, "devices", "--json"], text=True))
    default = next(device for device in devices if device["isDefault"])
    explicit = root / "explicit-mic"
    result = subprocess.run([binary, "Selected", "--out", str(explicit), "--mic", default["uid"], "--duration", "1", "--no-transcribe"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert_capture(explicit, children[0])
    saved = json.loads((explicit / "session.json").read_text())
    assert saved["microphoneSelection"] == "explicit" and saved["microphone"] == default["uid"]
    ambiguous = root / "noninteractive"
    result = subprocess.run(command("*capture-it.fixture.*", ambiguous), stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
    assert result.returncode == 1 and "interactive terminal" in result.stderr and not ambiguous.exists()
    assert result.stdout == ""
    cancelled = root / "cancelled"
    code, errors = interactive(cancelled, "q")
    assert code == 1 and "cancelled" in errors and not cancelled.exists()
    picked = root / "picked"
    code, errors = interactive(picked, "select", retry=True)
    assert code == 0, errors
    assert_capture(picked, children[0])
    print(f"passed: app substring/glob auto-selection, noninteractive ambiguity, picker cancellation/retry and selected PID WAV persistence: {root}")
finally:
    for pid in children:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
