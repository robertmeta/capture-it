"""Public AI-enrichment journeys with a deterministic provider boundary and private fixtures.

--fluid additionally exercises real local diarization, terminal confirmation and enrollment.
No model provider is called by this script.
"""
import hashlib
import json
import os
import runpy
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
import wave
from speaker_review_journey import terminal_command


def main():
    contract = runpy.run_path("hooks/ai-enrich.py")
    assert contract["name_in_quote"]("Pat Example", "my pat.example at example.org account")
    assert contract["name_in_quote"]("Jean Luc", "I am Jean-Luc")
    assert not contract["name_in_quote"]("Ann", "Anna is speaking")
    assert not contract["name_in_quote"]("Pat Example", "I am Pat")
    cli = Path(sys.argv[1]).resolve()
    fluid = "--fluid" in sys.argv[2:]
    root = Path(".build/ai-journey").resolve() / str(time.time_ns())
    root.mkdir(parents=True, mode=0o700)
    bindir = root / "bin"
    bindir.mkdir()
    binary = bindir / "capture-it"
    shutil.copy2(cli, binary)
    shutil.copy2("hooks/ai-enrich.py", bindir / "capture-it-ai")
    (bindir / "capture-it-ai").chmod(0o755)
    if fluid:
        shutil.copy2("hooks/fluidaudio", bindir / "capture-it-fluid")
        (bindir / ".capture-it-fluid").symlink_to(Path("hooks/fluid-audio/.build/release").resolve())
    agent = root / "fixture-codex"
    agent.write_text('''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
prompt=sys.stdin.read()
payload=json.loads(prompt.split("Quoted data:\\n",1)[1])
log=Path(os.environ["FIXTURE_AGENT_LOG"])
with log.open("a") as stream: stream.write(json.dumps({"args":sys.argv[1:],"phrases":len(payload["phrases"])})+"\\n")
mode=os.environ.get("FIXTURE_AGENT_MODE","")
if mode=="fail": sys.exit(7)
if mode=="wait": time.sleep(60)
suggestions=[]
for row in payload["phrases"]:
 if "Joe Smith here" in row["text"] and row["attribution"]=="single-speaker-overlap":
  suggestions.append({"speaker":row["speakers"][0],"name":"Joe Smith","confidence":"high","reason":"Self-introduction in this speaker's turn", "evidence":[{"phraseIndex":row["index"],"quote":row["text"] if mode!="invalid" else "a fabricated quote"}]})
response={"suggestions":suggestions,"title":"Fixture planning","summary":"The team reviewed the test plan.","decisions":["Review the test plan"],"actionItems":[],"openQuestions":[]}
text=json.dumps(response)
if "--output-last-message" in sys.argv: Path(sys.argv[sys.argv.index("--output-last-message")+1]).write_text(text)
else: print(text)
''')
    agent.chmod(0o755)
    env = dict(os.environ, CAPTURE_IT_AGENT_BIN=str(agent), FIXTURE_AGENT_LOG=str(root / "agent-calls.jsonl"),
               CAPTURE_IT_HOME=str(root / "home"))
    env.pop("CAPTURE_IT_AI", None)
    env.pop("CAPTURE_IT_AI_MODEL", None)
    env.pop("CAPTURE_IT_VOICES", None)
    bypass = root / "bypass-codex"
    bypass.write_text('#!/bin/sh\nexec codex --dangerously-bypass-approvals-and-sandbox "$@"\n')
    bypass.chmod(0o755)
    session = root / "saved meeting"
    session.mkdir()
    words = [("Daniel", "Hello everyone, Joe Smith here. Today I will walk through our test plan and show you the results from yesterday."),
             ("Samantha", "Thank you for the introduction. I have a few questions about the schedule and I would like to review the results together."),
             ("Daniel", "We can review the test plan now. I have prepared the examples and we can discuss what needs to happen before the next meeting.")]
    phrases = []
    with wave.open(str(session / "recording.wav"), "wb") as writer:
        writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(16000)
        frames = 0
        for index, (voice, text) in enumerate(words):
            if fluid:
                aiff = root / f"voice-{index}.aiff"
                wav = root / f"voice-{index}.wav"
                subprocess.run(["say", "-v", voice, "-r", "175", "-o", str(aiff), text], check=True)
                subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-i", str(aiff), "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], check=True)
                with wave.open(str(wav)) as reader: audio = reader.readframes(reader.getnframes())
            else:
                audio = struct.pack("<h", 0) * 16000
            phrases.append({"source": "recording", "start": frames / 16000, "duration": len(audio) / 32000, "text": text})
            writer.writeframes(audio + bytes(32000))
            frames += len(audio) // 2 + 16000
    if fluid:
        subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-i", str(session / "recording.wav"), "-c:a", "alac", str(session / "meeting.m4a")], check=True)
        (session / "recording.wav").unlink()
    # Importable saved-meeting fixture, including its independently supplied transcript.
    manifest = {"version": 2, "app": "fixture", "microphone": "fixture", "locale": "en-US", "startedAt": "2026-11-26T12:00:00Z",
                "recording": "complete", "transcription": "complete", "issues": [], "chunks": [{"file": "meeting.m4a" if fluid else "recording.wav", "source": "recording", "start": 0,
                "sampleRate": 16000, "channels": 1, "frames": frames, "closed": True}]}
    (session / "session.json").write_text(json.dumps(manifest))
    (session / "transcript.jsonl").write_text("".join(json.dumps(p) + "\n" for p in phrases))
    (session / "transcript.txt").write_text("\n".join(p["text"] for p in phrases))
    (session / "transcript.json").write_text(json.dumps({"complete": True, "segmentCount": len(phrases)}))
    original = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in session.iterdir()}

    def call(*args, expected=0, environment=None):
        p = subprocess.run([str(binary), *map(str, args)], stdin=subprocess.DEVNULL, capture_output=True, text=True, env=environment or env, timeout=120)
        with (root / "commands.log").open("a") as log: log.write(json.dumps(list(map(str, args))) + "\n" + p.stderr)
        assert p.returncode == expected, (args, p.returncode, p.stderr)
        return p

    call("hooks", session, "--no-review")
    initial = list(session.glob("hooks/*/*/enrichment.json"))
    assert len(initial) == 1
    enrichment = initial[0].parent
    meta = json.loads(initial[0].read_text())
    assert meta["agent"]["kind"] == "codex" and meta["agent"]["configuredModel"] == "gpt-6.2-sol"
    assert "Fixture planning" in (enrichment / "notes.md").read_text()
    calls = (root / "agent-calls.jsonl").read_text().splitlines()
    assert "--ephemeral" in json.loads(calls[0])["args"]
    call("hooks", session, "--no-ai", "--no-fluid", "--hook", Path("examples/hooks/inspect-session.py").resolve())
    assert (root / "agent-calls.jsonl").read_text().splitlines() == calls
    call("enrich", session, "--ai", "codex", "--no-review")
    call("enrich", session, "--ai", "codex", "--no-ai", expected=1)
    call("enrich", session, "--run", "../bad", expected=1)
    call("enrich", session, "--no-review", expected=2, environment=dict(env, CAPTURE_IT_AGENT_BIN=str(bypass)))
    call("enrich", session, "--no-review", expected=2, environment=dict(env, FIXTURE_AGENT_MODE="fail"))
    call("enrich", session, "--hook-timeout", "0.15", "--no-review", expected=2, environment=dict(env, FIXTURE_AGENT_MODE="wait"))
    assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in original.items())
    assert not (root / "home/voices").exists(), "AI suggestions must never enroll automatically"

    # Chunking processes every phrase in a long saved transcript, without a second
    # whole-meeting request or silently cutting off at the old 100 KB example limit.
    long_session = root / "long meeting"
    shutil.copytree(session, long_session, ignore=shutil.ignore_patterns("hooks"))
    long_rows = [dict(phrases[0], text="Context " * 400, start=0, duration=0) for _ in range(50)]
    (long_session / "transcript.jsonl").write_text("".join(json.dumps(p) + "\n" for p in long_rows))
    call("enrich", long_session, "--no-review")
    long_meta = json.loads(next(long_session.glob("hooks/*/*/enrichment.json")).read_text())
    assert long_meta["phraseCount"] == 50 and long_meta["chunks"] >= 4

    if fluid:
        # The public file-import path also runs actual local ASR and both installed
        # hooks. Inferred outputs are derived from the ASR text, not fixture seeding.
        imported = root / "imported audio"
        call("transcribe", session / "meeting.m4a", "--out", imported, "--no-review")
        assert json.loads((imported / "transcript.json").read_text())["complete"]
        assert "joe" in (imported / "transcript.txt").read_text().lower()
        assert list(imported.glob("hooks/*/*/diarization.json"))
        assert list(imported.glob("hooks/*/*/enrichment.json"))
        assert not (root / "home/voices").exists()
        analysis = next(session.glob("hooks/*/*/diarization.json")).parent
        run = str(analysis.relative_to(session / "hooks"))
        proposals = [json.loads(line) for line in (enrichment / "speaker-suggestions.jsonl").read_text().splitlines()]
        assert len(proposals) == 1 and proposals[0]["name"] == "Joe Smith"
        speaker = proposals[0]["speaker"]
        assert "Joe Smith" in call("speakers", session, "--list", "--run", run).stdout
        # Reject persists, while the speaker remains unnamed and can still be assigned.
        terminal_command([str(binary), "speakers", str(session), "--run", run],
                         [(b"Who is ", b":reject\n"), (b"Who is ", b":quit\n")], root / "reject.log", env)
        assert json.loads((analysis / "speaker-identities.json").read_text()) == {}
        assert "Suggestion 1" not in call("speakers", session, "--list", "--run", run).stdout
        # A fresh analysis is a new identity scope. Old rejection must not leak into it.
        call("hooks", session, "--no-review")
        fresh = next(p.parent for p in session.glob("hooks/*/*/diarization.json") if p.parent != analysis)
        fresh_run = str(fresh.relative_to(session / "hooks"))
        call("enrich", session, "--no-review", expected=1)
        bad = dict(env, FIXTURE_AGENT_MODE="invalid")
        call("enrich", session, "--run", fresh_run, "--no-review", expected=2, environment=bad)
        # Invalid enrichment never replaces the existing validated proposals.
        assert "Suggestion 1" in call("speakers", session, "--list", "--run", fresh_run).stdout
        logs = terminal_command([str(binary), "speakers", str(session), "--run", fresh_run],
                                [(b"Who is ", b":accept\n"), (b"Who is ", b"\x03")], root / "accept-cancel.log", env)
        assert "Joe Smith" in logs
        ids = json.loads((fresh / "speaker-identities.json").read_text())
        assert list(ids.values()) == [{"name": "Joe Smith", "source": "assigned"}]
        text = (fresh / "speaker-transcript.txt").read_text()
        assert text.count("[Joe Smith]") >= 2
        assert len(list((root / "home/voices").glob("*.voice/sample-*.wav"))) >= 2
        resumed = terminal_command([str(binary), "speakers", str(session), "--run", fresh_run],
                                   [(b"Who is ", b"\n")], root / "resume.log", env)
        assert "Suggestion 1" not in resumed
        call("hooks", session, "--no-ai", "--no-review")
        newest = max(session.glob("hooks/*/*/diarization.json"), key=lambda p: p.stat().st_mtime_ns).parent
        assert any(v == {"name": "Joe Smith", "source": "voice-match"} for v in json.loads((newest / "speaker-identities.json").read_text()).values())
        assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in original.items())
    (root / "result.json").write_text(json.dumps({"passed": True, "realFluidAudio": fluid, "providerBoundary": "deterministic CLI", "originalsPreserved": True}) + "\n")
    print(f"passed: default Codex/Sol, explicit disable, saved-session enrichment, notes, failure/timeout preservation" +
          (", real FluidAudio, evidence, reject/accept, full-file relabeling, sample enrollment, resume and future voice recognition" if fluid else "") + f"; artifacts {root}")


if __name__ == "__main__":
    main()
