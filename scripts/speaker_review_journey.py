"""Exercise speaker review with a real foreground terminal and an isolated home."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import termios
import time


def foreground():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(0, os.getpgrp())


def terminal_command(command, replies, log, env, capture_text=False):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    with log.open("wb") as errors:
        child = subprocess.Popen(command, stdin=slave, stdout=subprocess.PIPE, stderr=errors,
                                 env=env, preexec_fn=foreground)
        try:
            offset = 0
            for token, answer in replies:
                deadline = time.monotonic() + 60
                while True:
                    data = log.read_bytes()
                    if callable(token):
                        if token():
                            break
                        index = -1
                    else:
                        index = data.find(token, offset)
                    if index != -1:
                        offset = index + len(token)
                        break
                    assert child.poll() is None and time.monotonic() < deadline, data.decode(errors="replace")
                    time.sleep(0.05)
                os.write(master, answer)
            # A real terminal consumes echo (including ^C). macOS drains the tty on
            # session-leader exit, so the PTY master must consume it here as well.
            deadline = time.monotonic() + 30
            while child.poll() is None:
                assert time.monotonic() < deadline, log.read_text()
                if select.select([master], [], [], 0.05)[0]:
                    os.read(master, 4096)
            stdout, _ = child.communicate()
            assert child.returncode == 0 and (bool(stdout) if capture_text else not stdout), (child.returncode, log.read_text(), stdout)
            assert termios.tcgetattr(master) == original, "Terminal mode was not restored"
        finally:
            os.close(slave)
            os.close(master)
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
    return log.read_text()


def saved_review(cli, fixture, root):
    home = root / "review home"
    env = dict(os.environ, CAPTURE_IT_HOME=str(root / "unused home"))
    env.pop("CAPTURE_IT_VOICES", None)
    raw = root / "raw saved call"
    raw.mkdir()
    audio = raw / "recording.wav"
    shutil.copyfile(fixture / audio.name, audio)
    manifest = json.loads((fixture / "session.json").read_text())
    manifest["transcription"] = "disabled"
    (raw / "session.json").write_text(json.dumps(manifest))
    original = {path: hashlib.sha256(path.read_bytes()).digest() for path in raw.iterdir()}

    def invoke(command, replies, tag, *flags):
        return terminal_command([str(cli), command, str(raw), "--home", str(home), *flags], replies, root / (tag + ".log"), env)

    first = invoke("hooks", [(b"Who is ", b"Pat Example\n"), (b"Who is ", b"\x03")], "confirm-cancel")
    assert first.count("Who is ") == 2 and "Review finished" in first
    output = next(raw.glob("hooks/*/*/diarization.json")).parent
    identities = json.loads((output / "speaker-identities.json").read_text())
    assert len(identities) == 1 and next(iter(identities.values())) == {"name": "Pat Example", "source": "assigned"}
    assert list((home / "voices").glob("*.voice/sample-1.wav"))
    assert not (root / "unused home").exists()
    resume = invoke("speakers", [(b"Who is ", b"\n")], "resume-skip")
    assert resume.count("Who is ") == 1
    review_again = invoke("hooks", [(b"Who is ", b":quit\n")], "recognize-quit")
    assert review_again.count("Who is ") == 1
    newest = next(p.parent for p in raw.glob("hooks/*/*/diarization.json") if p.parent != output)
    assert list(json.loads((newest / "speaker-identities.json").read_text()).values()) == [{"name": "Pat Example", "source": "voice-match"}]
    silent = invoke("hooks", [], "no-review", "--no-review")
    assert "Who is " not in silent and "Playing " not in silent
    assert all(hashlib.sha256(path.read_bytes()).digest() == digest for path, digest in original.items())
    print("passed: raw session analysis, interactive assignment, Ctrl-C, resume, skip, recognized voice bypass, quit and --no-review; original WAV and manifest verified")
