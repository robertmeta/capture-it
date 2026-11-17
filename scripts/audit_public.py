"""Offline pre-publication audit. Scans tracked files and public branch/tag history.

PUBLIC_AUDIT_REV may add a candidate commit to the ancestry check. Internal
recovery refs are deliberately excluded; this command does not authorize a push.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]


def git(*args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def forbidden(name):
    path = Path(name)
    private_dirs = {".agents", ".git", ".jj", ".build", ".swiftpm", ".codanna", ".serena", ".claude", ".codex", ".venv", "__pycache__"}
    private_files = {"AGENTS.md", "CLAUDE.md", "GEMINI.md", "PRAXIS.md", "CONTEXT.md", "session.json", "transcript.txt", "transcript.json", "transcript.jsonl", "diarization.json", "diarization.rttm", "speaker-transcript.txt", "speaker-transcript.jsonl"}
    private_suffixes = {".wav", ".caf", ".aif", ".aiff", ".m4a", ".mp3", ".flac", ".ogg", ".opus", ".mp4", ".mov", ".pem", ".key", ".p12", ".pfx", ".log"}
    return (path.is_absolute() or ".." in path.parts or bool(set(path.parts) & private_dirs)
            or path.name in private_files or path.suffix.lower() in private_suffixes
            or (path.name.startswith(".env") and path.name != ".env.example")
            or any(part.endswith((".mlmodelc", ".mlpackage")) for part in path.parts)
            or bool(re.search(r"(?:^|/)hooks/[0-9a-fA-F-]{36}(?:/|$)", name)))


files = sorted({p.decode() for p in git("ls-files", "-z").split(b"\0") if p})
failures = [f"private/generated tracked path: {name}" for name in files if forbidden(name)]
# Deleted working-tree files have no current contents to scan. Their committed
# versions remain covered by the separate ancestry scan below.
files = [name for name in files if (root / name).exists() or (root / name).is_symlink()]
revision = os.environ.get("PUBLIC_AUDIT_REV")
if revision and not re.fullmatch(r"[0-9a-fA-F]{40,64}", revision):
    raise SystemExit("PUBLIC_AUDIT_REV must be a full local commit ID")
tips = ["--branches", "--tags", *([revision] if revision else [])]
commits = git("rev-list", *tips).decode().splitlines()
for commit in commits:
    names = [p.decode() for p in git("ls-tree", "-r", "--name-only", "-z", commit).split(b"\0") if p]
    failures.extend(f"private/generated history path at {commit[:12]}: {name}" for name in names if forbidden(name))

for name in files:
    path = root / name
    if path.is_symlink() or not path.is_file():
        failures.append(f"non-regular tracked file: {name}")
        continue
    if path.stat().st_size > 5 * 1024 * 1024:
        failures.append(f"large tracked file requires review: {name}")
        continue
    if forbidden(name):
        continue  # Never read contents of private files accidentally tracked.
    content = path.read_bytes()
    if re.search(rb"/(?:Users|home)/[^/\s]+/", content) or re.search(rb"[A-Za-z]:\\Users\\[^\\\s]+", content):
        failures.append(f"personal absolute path in tracked file: {name}")

# Protect complete analysis runs, including files whose names are chosen by a hook.
examples = ["teams-20261118-120000/arbitrary-notes.md", "teams-20261118-120000-2/summary.json",
            "custom-output/hooks/01234567-89ab-cdef-0123-456789abcdef/001/notes.md",
            "custom-output/hooks/01234567-89ab-cdef-0123-456789abcdef/input.json",
            "custom-output/speaker-transcript.txt", "custom-output/diarization.json", "local.env.key"]
for name in examples:
    result = subprocess.run(["git", "-C", str(root), "check-ignore", "--no-index", "-q", "--", name])
    if result.returncode != 0:
        failures.append(f"generated/private path is not ignored: {name}")
if failures:
    raise SystemExit("Public audit failed:\n" + "\n".join(failures))
if not shutil.which("gitleaks"):
    raise SystemExit("Install Gitleaks locally to run the secret scan; no tool or rules are downloaded by this audit")

report = root / ".build/public-audit" / str(time.time_ns())
report.mkdir(parents=True, mode=0o700)
config = report / "default-rules.toml"
config.write_text("[extend]\nuseDefault = true\n")
ignore = report / "empty.ignore"
ignore.write_text("")
environment = {k: v for k, v in os.environ.items() if k not in {"GITLEAKS_CONFIG", "GITLEAKS_CONFIG_TOML"}}


def scan(arguments, label):
    command = ["gitleaks", *arguments, "--config", str(config), "--gitleaks-ignore-path", str(ignore),
               "--ignore-gitleaks-allow", "--redact=100", "--no-banner", "--no-color", "--timeout", "60",
               "--report-format", "json", "--report-path", str(report / f"{label}.json")]
    result = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True)
    (report / f"{label}.log").write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        raise SystemExit(f"Secret scan failed ({label}); review the redacted report in {report}")


with tempfile.TemporaryDirectory(prefix="public-tree-", dir=report) as directory:
    tree = Path(directory)
    for name in files:
        target = tree / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
    scan(["dir", str(tree)], "working-tree")
scan(["git", str(root), "--log-opts", " ".join(tips)], "public-history")
print(f"passed: {len(files)} tracked files, {len(commits)} public/candidate commits, generated-output ignore checks, and offline redacted secret scans")
print(f"Private reports: {report}")
