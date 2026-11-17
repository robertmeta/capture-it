"""Actual offline FluidAudio through public hooks; no runtime model downloads."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
import wave

binary = str(Path(sys.argv[1]).resolve())
hook = Path("hooks/fluidaudio").resolve()
root = Path(".build/fluid-journey").resolve() / str(time.time_ns())
root.mkdir(parents=True)
# This only verifies local assets; it cannot install or download anything.
subprocess.run([str(hook), "--check"], check=True)
assert shutil.which("ffmpeg"), "This fixture generator requires an installed FFmpeg"

phrases = [
    ("Daniel", "We should schedule the planning review for Friday morning. The recording and transcript must remain available for everyone who needs the notes."),
    ("Samantha", "I agree with that approach. Please include the open questions and the decisions we made today, and leave uncertain speaker identities anonymous."),
    ("Daniel", "The next step is to check the audio files and finish the local analysis. I will prepare the test results before our next meeting."),
    ("Samantha", "That sounds good to me. I will review the summary and make sure the action items are clear. Thank you for walking through the plan.")
]
clips = []
for index, (voice, text) in enumerate(phrases):
    aiff = root / f"voice-{index}.aiff"
    mono = root / f"voice-{index}.wav"
    subprocess.run(["/usr/bin/say", "-v", voice, "-r", "165", "-o", str(aiff), text], check=True)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(aiff), "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(mono)], check=True)
    with wave.open(str(mono)) as reader:
        clips.append(reader.readframes(reader.getnframes()))

session = root / "fixture session"
session.mkdir(mode=0o700)
segments = []
intervals = []
frames = 0
with wave.open(str(session / "recording.wav"), "wb") as writer:
    writer.setnchannels(3); writer.setsampwidth(2); writer.setframerate(48000)
    for index, clip in enumerate(clips):
        start = frames / 48000
        samples = struct.unpack(f"<{len(clip) // 2}h", clip)
        data = bytearray(len(samples) * 6)
        for offset, value in enumerate(samples):
            # Two voices travel through different source lanes: app L/R, then mic.
            channels = (value, value, 0) if index % 2 == 0 else (0, 0, value)
            struct.pack_into("<hhh", data, offset * 6, *channels)
        writer.writeframes(data)
        frames += len(samples)
        end = frames / 48000
        intervals.append((start, end))
        segments.append({"source": "recording", "start": start, "duration": end - start, "text": phrases[index][1]})
        writer.writeframes(bytes(48000 * 6)); frames += 48000
    # A phrase crossing both voices must not be attributed to just one of them.
    segments.append({"source": "recording", "start": intervals[0][0], "duration": intervals[1][1] - intervals[0][0], "text": phrases[0][1] + " " + phrases[1][1]})
manifest = {"version": 2, "startedAt": "local-fixture", "app": "fixture", "microphone": "fixture", "locale": "en-US",
            "recording": "complete", "transcription": "complete", "chunks": [{"file": "recording.wav", "source": "recording", "start": 0,
            "sampleRate": 48000, "channels": 3, "frames": frames, "closed": True}], "issues": [],
            "channelLayout": ["app-left", "app-right", "microphone"], "meeting": {"title": "Offline hook fixture", "source": "explicit", "verified": True, "status": "provided"}}
(session / "session.json").write_text(json.dumps(manifest))
(session / "transcript.jsonl").write_text("".join(json.dumps(row) + "\n" for row in segments))
(session / "transcript.txt").write_text("\n".join(row["text"] for row in segments))
(session / "transcript.json").write_text(json.dumps({"complete": True, "segmentCount": len(segments)}))


def hashes():
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in session.iterdir() if p.is_file()}


before = hashes()
began = time.monotonic()
result = subprocess.run([binary, "hooks", str(session), "--hook", str(hook), "--hook-timeout", "300"], capture_output=True, text=True, timeout=310)
(root / "stderr.txt").write_text(result.stderr)
assert result.returncode == 0, result.stderr
assert result.stdout == "", "Hook output leaked into transcript stdout"
assert hashes() == before, "Original recording or transcript was changed"
report = json.loads(next(session.glob("hooks/*/result.json")).read_text())
row = report["results"][0]
assert row["status"] == "complete", row
output = Path(row["outputDirectory"])
diarization = json.loads((output / "diarization.json").read_text())
turns = diarization["turns"]
assert turns and len(diarization["speakers"]) >= 2, diarization
assert diarization["meeting"]["title"] == "Offline hook fixture"
assert abs(diarization["duration"] - frames / 48000) < 0.01
assert all(0 <= turn["start"] < turn["end"] <= diarization["duration"] for turn in turns)


def dominant(start, end):
    totals = {}
    for turn in turns:
        overlap = max(0, min(end, turn["end"]) - max(start, turn["start"]))
        totals[turn["speaker"]] = totals.get(turn["speaker"], 0) + overlap
    speaker = max(totals, key=totals.get)
    assert totals[speaker] > (end - start) * 0.4, (start, end, totals)
    return speaker


labels = [dominant(start, end) for start, end in intervals]
assert labels[0] == labels[2] and labels[1] == labels[3] and labels[0] != labels[1], labels
derived = [json.loads(line) for line in (output / "speaker-transcript.jsonl").read_text().splitlines()]
assert [row["phrase"]["text"] for row in derived] == [row["text"] for row in segments]
assert derived[-1]["attribution"] == "mixed" and len(derived[-1]["speakers"]) >= 2
assert not list(output.glob(".analysis-*.wav")), "Temporary analysis audio was not removed"
assert (output / "diarization.rttm").read_text().startswith("SPEAKER recording")
print(f"passed: actual offline FluidAudio through hooks in {time.monotonic() - began:.2f}s; repeated synthetic voices retain distinct labels across app/mic lanes; mixed phrases, title, private output and original hashes verified: {output}")
