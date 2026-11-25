"""Actual offline FluidAudio through public hooks; no runtime model downloads."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import time
import wave
from fixtures import start_player
from speaker_review_journey import saved_review, terminal_command

binary = str(Path(sys.argv[1]).resolve())
installed = sys.argv[2:] == ["--installed"]
assert not sys.argv[2:] or installed, "Usage: fluid_journey.py CLI [--installed]"
hook = Path(binary).with_name("capture-it-fluid") if installed else Path("hooks/fluidaudio").resolve()
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


def create_session(session, phrases):
    session.mkdir(mode=0o700)
    clips = []
    for index, (voice, text) in enumerate(phrases):
        aiff = session.parent / f"{session.name}-voice-{index}.aiff"
        mono = session.parent / f"{session.name}-voice-{index}.wav"
        subprocess.run(["/usr/bin/say", "-v", voice, "-r", "165", "-o", str(aiff), text], check=True)
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(aiff), "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(mono)], check=True)
        with wave.open(str(mono)) as reader:
            clips.append(reader.readframes(reader.getnframes()))

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
    return segments, intervals, frames, manifest


os.environ["CAPTURE_IT_VOICES"] = str(root / "voices")
session = root / "fixture session"
segments, intervals, frames, manifest = create_session(session, phrases)


def hashes():
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in session.iterdir() if p.is_file()}


before = hashes()
began = time.monotonic()
command = [binary, "hooks", str(session), "--hook-timeout", "300"]
if not installed:
    command += ["--hook", str(hook)]
# Installed inference must also work when the OS denies network access.
if installed:
    status = json.loads(subprocess.check_output([binary, "doctor", "--json"], text=True))
    assert Path(status["fluidHook"]).resolve() == hook.resolve()
    command = ["/usr/bin/sandbox-exec", "-p", "(version 1) (allow default) (deny network*)"] + command
result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=310)
(root / "stderr.txt").write_text(result.stderr)
assert result.returncode == 0, result.stderr
assert result.stdout == "", "Hook output leaked into transcript stdout"
assert hashes() == before, "Original recording or transcript was changed"
report = json.loads(next(session.glob("hooks/*/result.json")).read_text())
row = report["results"][0]
assert len(report["results"]) == 1
assert row["status"] == "complete", row
output = Path(row["outputDirectory"])
diarization = json.loads((output / "diarization.json").read_text())
turns = diarization["turns"]
assert turns and len(diarization["speakers"]) >= 2, diarization
assert diarization["meeting"]["title"] == "Offline hook fixture"
assert abs(diarization["duration"] - frames / 48000) < 0.01
assert all(0 <= turn["start"] < turn["end"] <= diarization["duration"] for turn in turns)


def dominant(start, end, candidates=turns):
    totals = {}
    for turn in candidates:
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

# Use the normal installed-sibling discovery path, isolated from the user's binaries and voice library.
review_cli = Path(binary)
if not installed:
    bindir = root / "bin"
    bindir.mkdir()
    review_cli = bindir / "capture-it"
    shutil.copy2(binary, review_cli)
    shutil.copy2(hook, bindir / "capture-it-fluid")
    (bindir / ".capture-it-fluid").symlink_to(Path("hooks/fluid-audio/.build/release").resolve())


def review(*args, expected=0):
    command = ["/usr/bin/sandbox-exec", "-p", "(version 1) (allow default) (deny network*)", str(review_cli), *map(str, args)]
    checked = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
    assert checked.returncode == expected, (args, checked.stderr)
    return checked.stdout


saved_review(review_cli, session, root)

library = root / "voices"
assert "No remembered voices" in review("people")
assert "(unnamed)" in review("speakers", session)
review("speakers", session, "--listen", labels[0])
review("speakers", session, "--assign", "nonexistent", "--name", "Joe Smith", expected=1)
assert not library.exists()
for name in ["Joe", "Joe Smith", "Joe Smith"]:
    review("speakers", session, "--assign", labels[0], "--name", name)
assert f"{labels[0]}\tJoe Smith" in review("speakers", session)
assert (output / "speaker-transcript.txt").read_text().count("[Joe Smith]") == 2
assert hashes() == before
profiles = list(library.glob("*.voice/profile.json"))
assert len(profiles) == 1
profile = json.loads(profiles[0].read_text())
clips = list(profiles[0].parent.glob("*.wav"))
assert profile["name"] == "Joe Smith" and len(profile["embeddings"]) == len(clips) >= 2
for clip in clips:
    assert clip.stat().st_mode & 0o077 == 0
    pcm = subprocess.check_output(["ffmpeg", "-loglevel", "error", "-i", str(clip), "-f", "s16le", "-"])
    assert 1.99 * 32000 <= len(pcm) <= 8.01 * 32000 and len(set(pcm)) > 100

later = root / "second call"
new_phrases = [
    ("Samantha", "Thank you for coming today. We have a different project to discuss, and I can stay until noon."),
    ("Daniel", "Good morning everyone. Yesterday the team finished building a prototype. I brought a few recordings so we can listen together."),
    ("Samantha", "That sounds wonderful. Could you play the example from the beginning and tell us which instruments you heard?"),
    ("Daniel", "Of course. The first instrument is the piano, then a violin comes in. I especially like the final passage."),
]
_, later_intervals, _, _ = create_session(later, new_phrases)
review("hooks", later)
second = next(later.glob("hooks/*/*/diarization.json")).parent
second_turns = json.loads((second / "diarization.json").read_text())["turns"]
second_labels = [dominant(start, end, second_turns) for start, end in later_intervals]
matches = json.loads((second / "speaker-identities.json").read_text())
assert second_labels[1] == second_labels[3] and matches == {second_labels[1]: {"name": "Joe Smith", "source": "voice-match"}}, (matches, second_labels)
assert second_labels[0] not in matches and second_labels[2] not in matches
assert "[Joe Smith]" in (second / "speaker-transcript.txt").read_text()
assert len(list(library.glob("*.voice"))) == 1, "Automatic matches must never enroll more samples"
review("speakers", later, "--assign", second_labels[1], "--name", "Joe Smith")
assert len(list(library.glob("*.voice/profile.json"))) == 2
review("speakers", later, "--assign", second_labels[0], "--name", "Alex Chen")
roster = review("people").splitlines()
assert len(roster) == 2 and roster[0].startswith("Alex Chen\t") and roster[1].startswith("Joe Smith\t")
review("hooks", session)
rerun = next(p.parent for p in session.glob("hooks/*/*/diarization.json") if p.parent != output)
assert {v["name"] for v in json.loads((rerun / "speaker-identities.json").read_text()).values()} == {"Joe Smith", "Alex Chen"}
review("speakers", session, expected=1)
assert "Joe Smith" in review("speakers", session, "--run", f"{output.parent.name}/{output.name}")
assert hashes() == before
print("passed: one-step enrollment, multiple playable private samples, correction, repeat enrollment, and offline recognition in a second recording with new words and speaker order")


if installed:
    def latest_report(folder=session):
        path = max(folder.glob("hooks/*/result.json"), key=lambda p: p.stat().st_mtime_ns)
        return json.loads(path.read_text())["results"]

    # Explicit selection of the installed helper keeps its place without duplication.
    check = subprocess.run([binary, "hooks", str(session), "--hook", str(hook)], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    assert check.returncode == 0 and check.stdout == "", check.stderr
    assert len(latest_report()) == 1 and hashes() == before

    check = subprocess.run([binary, "hooks", str(session), "--no-fluid"], capture_output=True, text=True, timeout=10)
    assert check.returncode == 1 and "supply --hook" in check.stderr
    inspector = Path("examples/hooks/inspect-session.py").resolve()
    check = subprocess.run([binary, "hooks", str(session), "--no-fluid", "--hook", str(inspector)], capture_output=True, text=True, timeout=10)
    assert check.returncode == 0 and check.stdout == "", check.stderr
    assert [p["executable"] for p in latest_report()] == [str(inspector)]

    # Run a later hook only after labeled artifacts are durable.
    check = subprocess.run([binary, "hooks", str(session), "--hook", str(inspector)], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    assert check.returncode == 0 and check.stdout == "", check.stderr
    rows = latest_report()
    assert [r["executable"] for r in rows] == [str(hook), str(inspector)]
    assert all(r["status"] == "complete" for r in rows)
    assert (Path(rows[0]["outputDirectory"]) / "speaker-transcript.txt").is_file()

    audio_only = root / "audio-only session"
    audio_only.mkdir(mode=0o700)
    shutil.copyfile(session / "recording.wav", audio_only / "recording.wav")
    manifest["transcription"] = "disabled"
    (audio_only / "session.json").write_text(json.dumps(manifest))
    check = subprocess.run([binary, "hooks", str(audio_only)], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    assert check.returncode == 0 and check.stdout == "", check.stderr
    only_output = Path(latest_report(audio_only)[0]["outputDirectory"])
    assert (only_output / "diarization.json").is_file()
    assert not list(only_output.glob("speaker-transcript.*"))

    # Missing models fail without downloads and do not damage original artifacts.
    missing = dict(os.environ, CAPTURE_IT_FLUID_MODELS=str(root / "missing models"))
    check = subprocess.run([binary, "hooks", str(session)], env=missing, capture_output=True, text=True, timeout=15, stdin=subprocess.DEVNULL)
    assert check.returncode == 2 and not (root / "missing models").exists()
    failed = latest_report()[0]
    assert failed["status"] == "failed"
    assert "models are missing" in (Path(failed["outputDirectory"]) / "stderr.log").read_text()
    assert hashes() == before

    # Corrupt a copied manifest, with links to public model assets; never edit the cache.
    model_directory = Path(os.environ.get("CAPTURE_IT_FLUID_MODELS", Path.home() / "Library/Application Support/capture-it/fluid-models"))
    corrupted = root / "corrupted models"
    corrupted.mkdir()
    model_manifest = json.loads((model_directory / "setup.json").read_text())
    for item in model_manifest["files"]:
        link = corrupted / item["path"]
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to((model_directory / item["path"]).resolve())
    model_manifest["files"][0]["sha256"] = "0" * 64
    (corrupted / "setup.json").write_text(json.dumps(model_manifest))
    check = subprocess.run([str(hook), "--check"], env=dict(os.environ, CAPTURE_IT_FLUID_MODELS=str(corrupted)), capture_output=True, text=True, timeout=15, stdin=subprocess.DEVNULL)
    assert check.returncode == 1 and "integrity check failed" in check.stderr and "No download attempted" in check.stderr

    # A tiny processing timeout must retain the recording and transcript.
    check = subprocess.run([binary, "hooks", str(session), "--hook-timeout", "0.001"], capture_output=True, text=True, timeout=10)
    assert check.returncode == 2 and latest_report()[0]["status"] == "timed-out"
    assert hashes() == before

    # Standalone hooks is already draining; its first Ctrl-C cancels analysis.
    previous = set(session.glob("hooks/*"))
    with (root / "cancel-stderr.txt").open("w") as errors:
        child = subprocess.Popen([binary, "hooks", str(session), "--hook", str(inspector)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=errors)
        try:
            deadline = time.monotonic() + 15
            while True:
                fresh = set(session.glob("hooks/*")) - previous
                if any(list(folder.glob("*/.analysis-*.wav")) for folder in fresh):
                    break
                assert child.poll() is None and time.monotonic() < deadline, "Hook did not start analysis"
                time.sleep(0.01)
            child.send_signal(signal.SIGINT)
            stdout, _ = child.communicate(timeout=5)
            assert child.returncode == 2 and stdout == b""
        finally:
            if child.poll() is None:
                child.kill(); child.wait()
    assert [r["status"] for r in latest_report()] == ["interrupted", "skipped"]
    assert hashes() == before
    print("passed: installed automatic helper with network denied; explicit dedup/order, --no-fluid, audio-only, missing/corrupt models, timeout and real analysis cancellation; original hashes preserved")

    # Capture a real controlled app stream and local mic, then stop with Ctrl-C.
    player = start_player(root, "FluidCapture", str(root / f"{session.name}-voice-0.wav"), binary)
    child = None
    captured = root / "captured session"
    try:
        with (root / "capture-stderr.txt").open("w") as errors:
            child = subprocess.Popen([binary, "record", "--app", "com.robertmeta.capture-it.fixture.fluidcapture", "--out", str(captured)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=errors)
            deadline = time.monotonic() + 45
            while True:
                text = captured / "transcript.txt"
                if text.exists() and text.stat().st_size > 0:
                    assert json.loads((captured / "session.json").read_text())["recording"] == "recording"
                    assert not list(captured.glob("hooks/*")), "Analysis ran before recording ended"
                    break
                assert child.poll() is None and time.monotonic() < deadline, "No live speech during controlled capture"
                time.sleep(0.01)
            child.send_signal(signal.SIGINT)
            child.wait(timeout=30)
        assert child.returncode == 0, (root / "capture-stderr.txt").read_text()
        saved = json.loads((captured / "session.json").read_text())
        assert saved["recording"] == "complete" and saved["transcription"] == "complete"
        assert saved["chunks"][0]["closed"]
        assert json.loads((captured / "transcript.json").read_text())["complete"]
        rows = latest_report(captured)
        assert len(rows) == 1 and rows[0]["status"] == "complete"
        labeled = Path(rows[0]["outputDirectory"]) / "speaker-transcript.txt"
        assert labeled.is_file() and labeled.stat().st_size > 0
        event_path = Path(rows[0]["outputDirectory"]).parent / "input.json"
        event = json.loads(event_path.read_text())
        assert event["recordingStatus"] == "complete" and event["transcriptComplete"]
        print("passed: actual app+mic capture prints live speech; first Ctrl-C saves WAV and final text before automatic FluidAudio writes a labeled copy")
        review_home = root / "record home"
        review_env = dict(os.environ)
        review_env.pop("CAPTURE_IT_VOICES", None)
        review_log = terminal_command([binary, "record", "--app", "com.robertmeta.capture-it.fixture.fluidcapture",
                                       "--home", str(review_home), "--duration", "10", "--no-transcribe"],
                                      [(b"Who is ", b":quit\n")], root / "record-review.log", review_env)
        fresh = next((review_home / "recordings").iterdir())
        assert "WAV saved" in review_log or "Saved " in review_log
        assert json.loads((fresh / "session.json").read_text())["recording"] == "complete"
        assert next(fresh.glob("hooks/*/*/diarization.json")).is_file()
        assert not (review_home / "voices").exists()
        print("passed: real capture automatically saved under its home and entered cancellable voice review")
    finally:
        if child is not None and child.poll() is None:
            child.kill(); child.wait()
        try:
            os.kill(player, signal.SIGTERM)
        except ProcessLookupError:
            pass
