"""Rematch saved M4As through the public CLI using real local synthetic voices."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

cli = Path(sys.argv[1]).resolve()
prepared = subprocess.run([sys.executable, "scripts/ai_journey.py", str(cli), "--fluid"], capture_output=True, text=True, check=True, timeout=120)
root = Path(prepared.stdout.strip().rsplit("; artifacts ", 1)[1])
binary = root / "bin/capture-it"
home = root / "home"
env = dict(os.environ, CAPTURE_IT_AI="off", CAPTURE_IT_HOME=str(home))
env.pop("CAPTURE_IT_VOICES", None)
source = root / "saved meeting"
source_analysis = next(p.parent for p in source.glob("hooks/*/*/diarization.json")
                       if any(v["source"] == "assigned" for v in json.loads(p.with_name("speaker-identities.json").read_text()).values()))
source_run = str(source_analysis.relative_to(source / "hooks"))


def call(*args, environment=None):
    p = subprocess.run([str(binary), *map(str, args), "--home", str(home)], env=environment or env,
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
    with (root / "rematch.log").open("a") as stream: stream.write(p.stdout + p.stderr)
    assert p.returncode == 0, p.stderr
    return p


def profile_hashes():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (home / "voices").rglob("*") if p.is_file()}


# A voice's own recording must not supply its reference for cross-recording rematch.
before = profile_hashes()
call("speakers", source, "--match", "--run", source_run)
same = max((source_analysis / "voice-matches").glob("*.json"), key=lambda p: p.stat().st_mtime_ns)
assert json.loads(same.read_text())["referenceSamples"] == 0
assert profile_hashes() == before

target = root / "other recording"
target.mkdir()
for name in ["meeting.m4a", "session.json", "transcript.txt", "transcript.jsonl", "transcript.json"]:
    shutil.copy2(source / name, target / name)
call("hooks", target, "--no-ai", "--no-review", environment=dict(env, CAPTURE_IT_VOICES=str(root / "empty library")))
analysis = next(target.glob("hooks/*/*/diarization.json")).parent
run = str(analysis.relative_to(target / "hooks"))
phrases = list(map(json.loads, (analysis / "speaker-transcript.jsonl").read_text().splitlines()))
joe = phrases[0]["speakers"][0]
other = phrases[1]["speakers"][0]
assert joe != other
call("speakers", target, "--run", run, "--assign", other, "--name", "Keep Existing")
path = analysis / "speaker-identities.json"
labels = json.loads(path.read_text())
labels[other]["fixtureMetadata"] = {"preserve": True}
path.write_text(json.dumps(labels))
known = labels[other]
before = profile_hashes()
originals = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in target.iterdir() if p.is_file()}
call("speakers", target, "--match", "--run", run)
labels = json.loads(path.read_text())
assert labels[joe] == {"name": "Joe Smith", "source": "voice-match"}
assert labels[other] == known
assert (analysis / "speaker-transcript.txt").read_text().count("[Joe Smith]") >= 2
assert profile_hashes() == before, "Automatic matching must not enroll or alter profiles"
assert all(hashlib.sha256(p.read_bytes()).hexdigest() == digest for p, digest in originals.items())
report_path = max((analysis / "voice-matches").glob("*.json"), key=lambda p: p.stat().st_mtime_ns)
report = json.loads(report_path.read_text())
assert report["complete"] and report["referenceNames"] == 1
entry, = report["entries"]
assert entry["speaker"] == joe and entry["status"] == "matched" and entry["name"] == "Joe Smith"
assert all(len(sample["embedding"]) == 256 for sample in entry["samples"])
assert report_path.stat().st_mode & 0o077 == 0
call("speakers", target, "--list", "--run", run)
call("speakers", target, "--match", "--run", run)
assert json.loads(path.read_text()) == labels
latest = max((analysis / "voice-matches").glob("*.json"), key=lambda p: p.stat().st_mtime_ns)
assert json.loads(latest.read_text())["entries"] == [], "A repeat must skip already named voices"
(root / "rematch-result.json").write_text(json.dumps({"passed": True, "crossRecordingMatch": True, "sameSessionExcluded": True,
                                                    "knownIdentityAndMetadataPreserved": True, "profilesAndOriginalsUnchanged": True}) + "\n")
print(f"passed: real M4A voice rematch, same-session exclusion, existing identity/metadata preservation, full-file labels, no enrollment, evidence and repeat/reopen; artifacts {root}")
