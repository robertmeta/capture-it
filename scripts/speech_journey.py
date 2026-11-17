"""Real on-device speech regression. Requires installed assets and local JFK fixture."""
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
assert status["ready"], "Install speech assets explicitly before this journey"
configured = os.environ.get("CAPTURE_IT_SPEECH_FIXTURE")
whisper = shutil.which("whisper-cli")
fixture = Path(configured) if configured else Path(whisper).resolve().parents[1] / "share/whisper.cpp/jfk.wav" if whisper else None
assert fixture and fixture.is_file(), "Set CAPTURE_IT_SPEECH_FIXTURE to a local JFK speech WAV; no download is performed"
root = Path(".build/speech-journey") / str(time.time_ns())
root = root.resolve()
session = root / "mic-only"
session.mkdir(parents=True)
hook = root / "inspect-speech.py"
hook.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
event = json.loads(Path(sys.argv[1]).read_text())
assert event['transcriptComplete'] is True
assert 'country' in Path(event['transcript']).read_text().lower()
assert Path(event['wav']).is_file()
assert Path(event['segments']).is_file()
Path(os.environ['CAPTURE_IT_HOOK_OUTPUT'], 'observed.json').write_text(json.dumps(event))
print('agent-hook output belongs in its own log')
''')
hook.chmod(0o700)
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(fixture), "-af", "pan=3c|c0=0*c0|c1=0*c0|c2=c0", "-ar", "48000", "-c:a", "pcm_s16le", str(session / "recording.wav")], check=True)
with wave.open(str(session / "recording.wav")) as audio:
    frames = audio.getnframes()
manifest = {"version": 2, "startedAt": "local-fixture", "app": "fixture", "microphone": "fixture", "locale": "en-US", "recording": "complete", "transcription": "disabled", "chunks": [{"file": "recording.wav", "source": "recording", "start": 0, "sampleRate": 48000, "channels": 3, "frames": frames, "closed": True}], "issues": [], "channelLayout": ["app-left", "app-right", "microphone"], "inputFrames": {"app": 0, "mic": frames}}
(session / "session.json").write_text(json.dumps(manifest))
result = subprocess.run([binary, "transcribe", str(session), "--out", str(session / "text"), "--hook", str(hook)], capture_output=True, text=True, timeout=45)
assert result.returncode == 0, result.stderr
text = (session / "text/transcript.txt").read_text()
assert "americans" in text.lower() and "country" in text.lower(), text
assert text == result.stdout, "Transcript file and stdout differ"
assert json.loads((session / "text/transcript.json").read_text())["complete"]
observed = list(session.glob("hooks/*/*/observed.json"))
assert len(observed) == 1
assert json.loads(observed[0].read_text())["transcript"] == str(session / "text/transcript.txt")
retry = subprocess.run([binary, "hooks", str(session), "--transcript", str(session / "text"), "--hook", str(hook)], capture_output=True, text=True, timeout=10)
assert retry.returncode == 0 and retry.stdout == "", retry.stderr
print("passed: actual microphone-channel-only recognition, resampling timestamp regression and identical file/stdout tee", flush=True)

pid = start_player(root, "Speech", str(fixture), binary)
live = root / "live"
try:
    with (root / "live-stdout.txt").open("w") as screen, (root / "live-stderr.txt").open("w") as errors:
        child = subprocess.Popen([binary, "record", "--app", "com.robertmeta.capture-it.fixture.speech", "--out", str(live), "--duration", "25", "--hook", str(hook)], stdout=screen, stderr=errors)
        observed_live = False
        try:
            deadline = time.monotonic() + 45
            while child.poll() is None and time.monotonic() < deadline:
                metadata = live / "session.json"
                transcript = live / "transcript.txt"
                if metadata.exists() and transcript.exists():
                    state = json.loads(metadata.read_text())
                    content = transcript.read_text().lower()
                    if state["recording"] == "recording" and "country" in content:
                        observed_live = True
                        child.send_signal(signal.SIGINT)
                        break
                time.sleep(0.05)
            child.wait(timeout=20)
        finally:
            if child.poll() is None:
                child.kill(); child.wait()
    assert child.returncode == 0, (root / "live-stderr.txt").read_text()
    assert observed_live, "No finalized transcript appeared while WAV capture was running"
    assert (live / "transcript.txt").read_bytes() == (root / "live-stdout.txt").read_bytes()
    assert list(live.glob("*.wav")) == [live / "recording.wav"]
    state = json.loads((live / "session.json").read_text())
    assert state["recording"] == state["transcription"] == "complete", state
    observed = list(live.glob("hooks/*/*/observed.json"))
    assert len(observed) == 1 and json.loads(observed[0].read_text())["transcriptComplete"] is True
    print(f"passed: live local speech arrives before stop, tees to file/screen and preserves one three-channel WAV: {live}", flush=True)
    print("passed: saved-file and live hooks receive finalized WAV + complete transcript; replay transcript override and isolated hook logs", flush=True)
finally:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
