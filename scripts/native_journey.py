"""Real tone-app + mic capture. Requires macOS privacy permissions."""
import json
import math
import os
from pathlib import Path
import resource
import signal
import struct
import subprocess
import sys
import time
import wave
from fixtures import start_player

binary = str(Path(sys.argv[1]).resolve())
root = Path(".build/native-journey").resolve()
root.mkdir(parents=True, exist_ok=True)
children = []
try:
    for name, frequency in [("Selected", 440), ("Excluded", 1000)]:
        children.append(start_player(root, name, str(frequency), binary))
    directory = root / f"session-{time.time_ns()}"
    args = [binary, "record", "--app", "com.robertmeta.capture-it.fixture.selected", "--out", str(directory), "--duration", "4", "--no-transcribe"]
    # Long deadline allows the user to answer native macOS permission prompts.
    with (root / "last-stderr.txt").open("w") as errors:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=errors, text=True, timeout=90)
    print((root / "last-stderr.txt").read_text(), end="")
    assert result.returncode == 0, f"Capture failed ({result.returncode}); see {root / 'last-stderr.txt'}"
    manifest = json.loads((directory / "session.json").read_text())
    assert manifest["recording"] == "complete" and manifest["transcription"] == "disabled"
    assert len(manifest["chunks"]) == 1 and manifest["chunks"][0]["file"] == "recording.wav"
    assert list(directory.glob("*.wav")) == [directory / "recording.wav"]
    assert manifest["channelLayout"] == ["app-left", "app-right", "microphone"]
    assert manifest["inputFrames"]["app"] > 0 and manifest["inputFrames"]["mic"] > 0
    for chunk in manifest["chunks"]:
        with wave.open(str(directory / chunk["file"]), "rb") as audio:
            assert audio.getnframes() > 0 and audio.getsampwidth() == 2
            assert audio.getnchannels() == 3
            frames = audio.readframes(audio.getnframes())
            values = struct.unpack(f"<{len(frames)//2}h", frames)[::audio.getnchannels()]
            rate = audio.getframerate()
            def power(frequency):
                window = values[rate:rate * 2]
                real = sum(value * math.cos(2 * math.pi * frequency * index / rate) for index, value in enumerate(window))
                imag = sum(value * math.sin(2 * math.pi * frequency * index / rate) for index, value in enumerate(window))
                return real * real + imag * imag
            assert power(440) > max(1, power(1000)) * 100, "Selected tone missing or other app leaked into recording"
    print(f"passed: one three-channel WAV, app isolation, mic input, declared L/R/mic order and timed stop: {directory}")

    # Stop through the public signal interface while both tracks are growing.
    interrupted = root / f"signal-{time.time_ns()}"
    with (root / "signal-stderr.txt").open("w") as errors:
        child = subprocess.Popen([binary, "record", "--app", "com.robertmeta.capture-it.fixture.selected", "--out", str(interrupted), "--no-transcribe"], stdout=subprocess.PIPE, stderr=errors)
        try:
            deadline = time.monotonic() + 15
            while True:
                chunks = list(interrupted.glob("*.wav"))
                if len(chunks) == 1 and chunks[0].stat().st_size > 68:
                    break
                assert child.poll() is None and time.monotonic() < deadline, "No growing recording before signal"
                time.sleep(0.02)
            child.send_signal(signal.SIGINT)
            child.communicate(timeout=15)
            assert child.returncode == 0
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    assert json.loads((interrupted / "session.json").read_text())["recording"] == "complete"
    print("passed: SIGINT drains and closes a growing real recording")

    # Limit only this child, exercising a real write failure without filling disk.
    limited = root / f"file-limit-{time.time_ns()}"
    def limit_files():
        resource.setrlimit(resource.RLIMIT_FSIZE, (65_536, 65_536))
    result = subprocess.run([binary, "record", "--app", "com.robertmeta.capture-it.fixture.selected", "--out", str(limited), "--duration", "3", "--no-transcribe"], capture_output=True, text=True, timeout=20, preexec_fn=limit_files)
    failed = json.loads((limited / "session.json").read_text())
    assert result.returncode == 1 and failed["recording"] == "failed"
    assert any("writer failed" in issue for issue in failed["issues"])
    print("passed: child file-size quota produces a persisted recording failure instead of hanging")

    status = json.loads(subprocess.check_output([binary, "doctor", "--json"], text=True))
    denial_fixture = root / "ScreenCaptureDenialFixture.dylib"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-dynamiclib", "-framework", "Foundation",
                    "-framework", "ScreenCaptureKit", "Support/ScreenCaptureDenialFixture.m",
                    "-o", str(denial_fixture)], check=True)
    for phase in ("enumerate", "start"):
        denied = root / f"denied-{phase}-{time.time_ns()}"
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(denial_fixture), CAPTURE_IT_DENIAL_PHASE=phase)
        result = subprocess.run([binary, "record", "--app", "com.robertmeta.capture-it.fixture.selected",
                                 "--out", str(denied), "--duration", "1", "--no-fluid", "--hook", "/usr/bin/true"],
                                env=env, capture_output=True, text=True, timeout=20)
        (root / f"{denied.name}-stderr.txt").write_text(result.stderr)
        assert result.returncode == 1 and not result.stdout, result.stderr
        assert result.stderr.count("-3801") == 1 and "quit and reopen the terminal" in result.stderr, result.stderr
        assert "Recording did not start" in result.stderr and "Stopping capture" not in result.stderr, result.stderr
        saved = json.loads((denied / "session.json").read_text())
        assert saved["recording"] == "failed" and saved["transcription"] in ("incomplete", "unavailable"), saved
        assert sum("-3801" in issue for issue in saved["issues"]) == 1, saved
        assert saved["chunks"] == [] and saved["inputFrames"] == {"app": 0, "mic": 0}, saved
        assert not (denied / "recording.wav").exists() and not (denied / "hooks").exists()
        summary = denied / "transcript.json"
        if phase == "enumerate":
            assert not list(denied.glob("transcript*"))
        elif summary.exists():
            assert json.loads(summary.read_text())["complete"] is False
        print(f"passed: ScreenCaptureKit {phase} denial preserves a failed session manifest: {denied}")

    if not status["ready"]:
        no_model = root / f"missing-model-{time.time_ns()}"
        result = subprocess.run([binary, "record", "--app", "com.robertmeta.capture-it.fixture.selected", "--out", str(no_model), "--duration", "1"], capture_output=True, text=True, timeout=20)
        saved = json.loads((no_model / "session.json").read_text())
        assert result.returncode == 2 and saved["recording"] == "complete" and saved["transcription"] == "unavailable"
        assert len(saved["chunks"]) == 1 and saved["chunks"][0]["channels"] == 3
        print("passed: missing speech model preserves a complete real recording and reports partial success")

    exited = root / f"app-exit-{time.time_ns()}"
    with (root / "app-exit-stderr.txt").open("w") as errors:
        child = subprocess.Popen([binary, "record", "--app", "com.robertmeta.capture-it.fixture.selected", "--out", str(exited), "--duration", "10", "--no-transcribe"], stdout=subprocess.PIPE, stderr=errors)
        try:
            deadline = time.monotonic() + 15
            while not list(exited.glob("recording.wav")):
                assert child.poll() is None and time.monotonic() < deadline
                time.sleep(0.02)
            os.kill(children[0], signal.SIGTERM)
            child.communicate(timeout=15)
            assert child.returncode == 1
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    saved = json.loads((exited / "session.json").read_text())
    assert saved["recording"] == "failed" and saved["issues"]
    assert saved["chunks"] and all(chunk["closed"] for chunk in saved["chunks"])
    print("passed: selected-app exit stops capture visibly and retains closed audio chunks")
finally:
    for child in children:
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
