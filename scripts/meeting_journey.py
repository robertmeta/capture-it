"""Rotate while a hook is busy, lose/reopen selected apps, and measure the saved audio."""
import fcntl
import json
import math
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import wave

from fixtures import start_player

binary = str(Path(sys.argv[1]).resolve())
work = (Path(".build/meeting-journey") / str(time.time_ns())).resolve()
work.mkdir(parents=True)
recordings = work / "home/recordings"
release = work / "release"
hook = work / "wait"
hook.write_text("""#!/bin/sh
set -eu
touch "$CAPTURE_IT_HOOK_OUTPUT/started"
while [ ! -f "$MEETING_RELEASE" ]; do sleep 0.1; done
touch "$CAPTURE_IT_HOOK_OUTPUT/finished"
""")
hook.chmod(0o700)
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
output = bytearray()
players = {}
child = None


def foreground():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(0, os.getpgrp())


def read_terminal():
    while select.select([master], [], [], 0)[0]:
        try:
            data = os.read(master, 8192)
        except OSError:
            break
        if not data:
            break
        output.extend(data)


def wait_for(check, timeout=30):
    deadline = time.monotonic() + timeout
    while True:
        read_terminal()
        if check():
            return
        assert child.poll() is None and time.monotonic() < deadline, output.decode(errors="replace")
        time.sleep(0.05)


def start(name, frequency):
    players[name] = start_player(work, name, str(frequency), binary)


def stop(name):
    os.kill(players.pop(name), signal.SIGTERM)


def wav(session):
    return session / (session.name + ".wav")


def frames(session):
    file = wav(session)
    return max(0, (file.stat().st_size - 68) // 6) if file.exists() else 0


def levels(session, offset):
    with wave.open(str(wav(session))) as audio:
        rate = audio.getframerate()
        audio.setpos(offset)
        raw = audio.readframes(rate // 2)
        values = struct.unpack(f"<{len(raw)//2}h", raw)[::3]
        assert len(values) == rate // 2
        def amplitude(hz):
            angle = 2 * math.pi * hz / rate
            return abs(sum(value * complex(math.cos(i*angle), math.sin(i*angle))
                           for i, value in enumerate(values))) * 2 / len(values)
        return [amplitude(hz) for hz in (440, 660, 1000)]


try:
    for name, freq in [("MeetAlpha", 440), ("MeetBeta", 660), ("MeetExcluded", 1000)]:
        start(name, freq)
    with (work / "stdout").open("w") as stdout:
        child = subprocess.Popen([binary, "MeetAlpha", "MeetBeta", "--home", str(work / "home"),
                                  "--no-transcribe", "--no-fluid", "--hook", str(hook)],
                                 env=dict(os.environ, TERM="xterm-256color", MEETING_RELEASE=str(release)),
                                 stdin=slave, stderr=slave, stdout=stdout, preexec_fn=foreground)
        wait_for(lambda: bool(list(recordings.glob("*-01"))) and b"[24;1H" in output)
        first = next(recordings.glob("*-01"))
        assert re.fullmatch(r"meetalpha-meetbeta-\d{4}-\d{2}-\d{2}-01", first.name)
        assert b"[q] Quit   [n] New meeting" in output and b"\x1b[1;23r" in output
        wait_for(lambda: frames(first) >= 2 * 48000)
        os.write(master, b"n")
        second = first.with_name(first.name[:-2] + "02")
        wait_for(lambda: any(first.glob("hooks/*/*/started")) and frames(second) > 0)
        initial = frames(second)
        wait_for(lambda: frames(second) > initial + 48000)
        assert not list(first.glob("hooks/*/*/finished"))
        stop("MeetAlpha")
        stop("MeetBeta")
        wait_for(lambda: b"waiting for selected apps" in output)
        silent = frames(second) + 96000
        wait_for(lambda: frames(second) > silent + 48000)
        start("MeetBeta", 660)
        new_pid = f"(pid {players['MeetBeta']})".encode()
        wait_for(lambda: new_pid in output)
        returned = frames(second) + 96000
        wait_for(lambda: frames(second) > returned + 48000)
        release.touch()
        os.write(master, b"q")
        wait_for(lambda: child.poll() is not None)
        assert child.returncode == 0 and b"\x1b[r" in output, output.decode(errors="replace")
    for session, reason in [(first, "new-meeting"), (second, "quit")]:
        manifest = json.loads((session / "session.json").read_text())
        assert manifest["recording"] == "complete" and manifest["stopReason"] == reason
        assert manifest["apps"] == ["com.robertmeta.capture-it.fixture.meetalpha", "com.robertmeta.capture-it.fixture.meetbeta"]
        chunk, = manifest["chunks"]
        assert chunk["file"] == wav(session).name and chunk["closed"]
        with wave.open(str(wav(session))) as audio:
            assert audio.getnchannels() == 3 and audio.getnframes() == chunk["frames"]
        assert list(session.glob("hooks/*/*/finished"))
    a, b, other = levels(first, 48000)
    assert min(a, b) > 10 * max(1, other), (a, b, other)
    idle = levels(second, silent)
    assert max(idle) < min(a, b) / 10, idle
    a, b, other = levels(second, returned)
    assert b > 10 * max(1, a, other), (a, b, other)
    assert (work / "stdout").read_bytes() == b""
    start("MeetAlpha", 440)
    subprocess.run([binary, "MeetAlpha", "MeetBeta", "--home", str(work / "home"),
                    "--duration", "1", "--no-fluid", "--no-transcribe"],
                   stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=20)
    third = first.with_name(first.name[:-2] + "03")
    restarted = json.loads((third / "session.json").read_text())
    assert restarted["stopReason"] == "duration" and restarted["chunks"][0]["file"] == wav(third).name
    print(f"passed: bottom controls, numbered WAVs, overlapping hook/capture, app isolation through exit and relaunch: {work}")
finally:
    release.touch()
    if child is not None and child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    read_terminal()
    (work / "terminal.log").write_bytes(output)
    os.close(slave)
    os.close(master)
    for pid in players.values():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
