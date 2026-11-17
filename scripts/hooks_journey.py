"""Real capture → explicit local hooks. No model calls or network requests."""
import hashlib
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
root = Path(".build/hooks-journey").resolve() / f"space ; literal-${time.time_ns()}"
root.mkdir(parents=True)


def script(name, content):
    path = root / name
    path.write_text("#!/usr/bin/env python3\n" + content)
    path.chmod(0o700)
    return str(path)


def run(*args, expected=0, env=None):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, timeout=30, env=env)
    assert result.returncode == expected, (result.returncode, result.stderr)
    return result


def report(session):
    return max((session / "hooks").glob("*/result.json"), key=lambda p: p.stat().st_mtime_ns)


def snapshot(session):
    return {name: hashlib.sha256((session / name).read_bytes()).hexdigest() for name in ["recording.wav", "session.json"]}


good = script("analyze ; $literal.py", '''import json, os, sys, wave
from pathlib import Path
event = json.loads(Path(sys.argv[1]).read_text())
assert event['version'] == 1 and event['event'] == 'session-finished'
assert event['wav'] == os.environ['CAPTURE_IT_WAV']
assert Path(event['wav']).is_absolute()
assert event['recordingStatus'] == 'complete'
assert not event.get('transcript') and not os.environ['CAPTURE_IT_TRANSCRIPT']
with wave.open(event['wav']) as audio:
    assert audio.getnchannels() == 3 and audio.getnframes() > 0
output = Path(os.environ['CAPTURE_IT_HOOK_OUTPUT'])
(output / 'analysis.json').write_text(json.dumps(event))
print('hook stdout stays separate')
print('hook stderr stays separate', file=sys.stderr)
''')
bad = script("fail.py", "import sys\nprint('intentional failure', file=sys.stderr)\nsys.exit(17)\n")
slow = script("slow.py", '''import os, signal, subprocess, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child = subprocess.Popen(['/bin/sleep', '60'])
out = Path(os.environ['CAPTURE_IT_HOOK_OUTPUT'])
(out / 'descendant.pid').write_text(str(child.pid))
(out / 'started').write_text('ready')
while True:
    time.sleep(1)
''')

pid = start_player(root, "Hooks", "440", binary)
child = None
try:
    session = root / "audio session"
    result = run("record", "--app", "com.robertmeta.capture-it.fixture.hooks", "--out", session,
                 "--duration", "2", "--no-transcribe", "--hook", good)
    assert result.stdout == "", result.stdout
    persisted = json.loads((session / "session.json").read_text())
    assert persisted["recording"] == "complete" and persisted["transcription"] == "disabled"
    first = json.loads(report(session).read_text())["results"]
    assert [r["status"] for r in first] == ["complete"]
    output = Path(first[0]["outputDirectory"])
    assert (output / "analysis.json").exists()
    assert (output / "stdout.log").read_text().strip() == "hook stdout stays separate"
    assert (output / "stderr.log").read_text().strip() == "hook stderr stays separate"
    assert output.stat().st_mode & 0o777 == 0o700
    assert (output / "stdout.log").stat().st_mode & 0o777 == 0o600
    print("passed: actual recording finalizes before audio-only hook; literal paths, private outputs and isolated stdout/stderr", flush=True)

    partial = root / "capture with failing hook"
    run("record", "--app", "com.robertmeta.capture-it.fixture.hooks", "--out", partial,
        "--duration", "2", "--no-transcribe", "--hook", bad, "--hook", good, expected=2)
    saved = json.loads((partial / "session.json").read_text())
    assert saved["recording"] == "complete" and saved["chunks"][0]["closed"]
    assert any("hooks did not all complete" in issue for issue in saved["issues"])
    assert [r["status"] for r in json.loads(report(partial).read_text())["results"]] == ["failed", "complete"]
    print("passed: a failed capture hook returns partial success with a complete saved WAV and persisted issue", flush=True)

    before = snapshot(session)
    run("hooks", session, "--hook", bad, "--hook", good, expected=2)
    results = json.loads(report(session).read_text())["results"]
    assert [r["status"] for r in results] == ["failed", "complete"]
    assert results[0]["exitCode"] == 17
    assert snapshot(session) == before
    print("passed: repeated hooks preserve order, continue after failure and leave saved artifacts unchanged", flush=True)

    run("hooks", session, "--hook", slow, "--hook", good, "--hook-timeout", "0.4", expected=2)
    results = json.loads(report(session).read_text())["results"]
    assert [r["status"] for r in results] == ["timed-out", "complete"]

    def assert_descendant_stopped(row):
        descendant = int((Path(row["outputDirectory"]) / "descendant.pid").read_text())
        deadline = time.monotonic() + 3
        while True:
            process = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(descendant)], capture_output=True, text=True)
            state = process.stdout.strip()
            if not state or state.startswith("Z"):
                return
            assert time.monotonic() < deadline, f"Hook descendant {descendant} survived cleanup: {state}"
            time.sleep(0.02)

    assert_descendant_stopped(results[0])
    assert snapshot(session) == before
    print("passed: timeout kills the child process group, including TERM-ignoring descendants", flush=True)

    previous = set((session / "hooks").iterdir())
    with (root / "cancel-stderr.txt").open("w") as errors:
        child = subprocess.Popen([binary, "hooks", str(session), "--hook", slow, "--hook", good], stdout=subprocess.PIPE, stderr=errors)
        deadline = time.monotonic() + 10
        while True:
            fresh = set((session / "hooks").iterdir()) - previous
            if fresh and any(p.exists() for folder in fresh for p in folder.glob("*/started")):
                break
            assert child.poll() is None and time.monotonic() < deadline
            time.sleep(0.02)
        child.send_signal(signal.SIGINT)
        stdout, _ = child.communicate(timeout=3)
    assert child.returncode == 2 and stdout == b""
    results = json.loads(report(session).read_text())["results"]
    assert [r["status"] for r in results] == ["interrupted", "skipped"]
    assert_descendant_stopped(results[0])
    assert snapshot(session) == before
    print("passed: Ctrl-C cancels a running hook and descendants, skips remaining hooks and retains saved WAV", flush=True)

    missing = root / "missing session"
    run("hooks", missing, "--hook", good, expected=1)
    assert not missing.exists()
    run("hooks", session, "--hook", good, "--hook-timeout", "nan", expected=1)
    run("hooks", session, expected=1)
    run("hooks", session, "--hook", good + " ; shell", expected=1)
    run("hooks", session, "--hook", good, "--hook-timeout", "1e100")
    # Exercise the shipped adapter with a local CLI stand-in, never a model.
    transcript_dir = root / "retried text"
    transcript_dir.mkdir()
    (transcript_dir / "transcript.txt").write_text("[00:00:01.000] Let's schedule a review.\n")
    (transcript_dir / "transcript.json").write_text(json.dumps({"complete": True}))
    adapter = Path(__file__).resolve().parents[1] / "examples/hooks/agent-notes.py"
    agent = script("agent-stand-in.py", '''import json, os, sys
args = sys.argv[1:]
assert not any('dangerously-' in arg for arg in args)
kind = os.environ['CAPTURE_IT_AGENT']
assert args[0] == ('exec' if kind == 'codex' else '--print')
prompt = next(arg for arg in args if 'Summarize the supplied' in arg)
assert "Let's schedule a review." in prompt
assert 'WAV reference (not an audio attachment)' in prompt
print('Fixture decisions: schedule a review.')
''')
    for kind in ["codex", "claude", "agy"]:
        environment = dict(os.environ, CAPTURE_IT_AGENT=kind, CAPTURE_IT_AGENT_BIN=agent)
        run("hooks", session, "--transcript", transcript_dir, "--hook", adapter, env=environment)
        row = json.loads(report(session).read_text())["results"][0]
        assert row["status"] == "complete"
        assert "Fixture decisions" in (Path(row["outputDirectory"]) / "notes.md").read_text()
    assert snapshot(session) == before
    print("passed: shipped agent example invokes all three CLI modes with a local stand-in; no model calls", flush=True)
    print(f"passed: invalid hook arguments fail before work; artifacts: {root}", flush=True)
finally:
    if child is not None and child.poll() is None:
        child.kill()
        child.wait()
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
