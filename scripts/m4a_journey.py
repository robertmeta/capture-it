"""Import ordinary mono/stereo M4A and WAV through the CLI, decode and label locally."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

binary = str(Path(sys.argv[1]).resolve())
root = (Path(".build/m4a-journey") / str(time.time_ns())).resolve()
root.mkdir(parents=True)
voice = root / "voice.aiff"
subprocess.run(["say", "-v", "Daniel", "-r", "150", "-o", str(voice),
                "We will review the planning notes on Friday morning. The recording should preserve the original audio. "
                "Please include the open questions and the decisions we made today. "
                "I will prepare the results before the next meeting and check the final transcript."], check=True)
helper = str(Path("hooks/fluidaudio").resolve())

for extension, channels, rate, codec in [("m4a", 1, 44100, "aac"), ("m4a", 2, 48000, "aac"), ("wav", 1, 16000, "pcm_s16le"), ("mp3", 2, 32000, "libmp3lame")]:
    original = root / f"input-{channels}-{rate}.{extension}"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(voice), "-ar", str(rate),
                    "-ac", str(channels), "-c:a", codec, str(original)], check=True)
    before = hashlib.sha256(original.read_bytes()).digest()
    output = root / f"imported-{channels}-{rate}"
    result = subprocess.run([binary, "transcribe", str(original), "--out", str(output), "--hook", helper],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
    (root / (output.name + ".log")).write_text(result.stderr)
    assert result.returncode == 0, result.stderr
    assert hashlib.sha256(original.read_bytes()).digest() == before
    manifest = json.loads((output / "session.json").read_text())
    chunk, = manifest["chunks"]
    assert manifest["recording"] == manifest["transcription"] == "complete"
    assert chunk["channels"] == channels and chunk["sampleRate"] == rate and chunk["file"].endswith(".m4a")
    exported = output / chunk["file"]
    if extension == "m4a":
        assert hashlib.sha256(exported.read_bytes()).digest() == before
    stream, = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(exported)]))["streams"]
    assert stream["channels"] == channels and int(stream["sample_rate"]) == rate
    assert json.loads((output / "transcript.json").read_text())["complete"]
    transcript = (output / "transcript.txt").read_text().lower()
    assert "friday" in transcript and "meeting" in transcript, transcript
    analysis = next(output.glob("hooks/*/*/diarization.json"))
    assert json.loads(analysis.read_text())["speakers"]
    assert analysis.with_name("speaker-transcript.jsonl").stat().st_size > 0
    event = json.loads(next(output.glob("hooks/*/input.json")).read_text())
    assert event["audio"] == event["wav"] == str(exported)
    assert exported.stat().st_mode & 0o077 == 0
    retry = root / f"replay-{channels}-{rate}"
    result = subprocess.run([binary, "transcribe", str(output), "--out", str(retry), "--no-fluid"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
    assert result.returncode == 0, result.stderr
    assert (retry / "transcript.jsonl").stat().st_size > 0
    output_hash = hashlib.sha256(exported.read_bytes()).digest()
    rejected = subprocess.run([binary, "transcribe", str(original), "--out", str(output), "--no-fluid"],
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
    assert rejected.returncode == 1 and hashlib.sha256(exported.read_bytes()).digest() == output_hash
home = root / "default home"
result = subprocess.run([binary, "transcribe", str(root / "input-1-44100.m4a"), "--home", str(home), "--no-fluid"],
                        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
assert result.returncode == 0, result.stderr
default, = (home / "recordings").iterdir()
assert default.name.endswith("-01") and json.loads((default / "transcript.json").read_text())["complete"]
print(f"passed: mono/stereo AAC M4A, WAV and MP3 import, source hashes, private M4A output, real local ASR, FluidAudio and saved-session replay: {root}")
