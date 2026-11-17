"""Public CLI discovery and failure journeys; no model downloads or recording."""
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())


def run(*args, expected=0):
    result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=15)
    assert result.returncode == expected, (args, result.returncode, result.stderr)
    return result


assert re.fullmatch(r"\d+\.\d+\.\d+", run("--version").stdout.strip())
assert "capture-it NAME_OR_PATTERN" in run("--help").stdout
apps = json.loads(run("apps", "--json").stdout)
devices = json.loads(run("devices", "--json").stdout)
assert isinstance(apps, list) and isinstance(devices, list)
assert all("bundleID" in row and "pid" in row for row in apps)
assert all("uid" in row and "isDefault" in row for row in devices)
status = json.loads(run("doctor", "--json").stdout)
assert isinstance(status["ready"], bool) and status["locale"]
with tempfile.TemporaryDirectory(prefix="capture-it-journey-") as directory:
    output = Path(directory) / "should-not-exist"
    result = run("record", "--app", "invalid.capture-it.not-running", "--out", str(output), expected=1)
    assert "No running app matches" in result.stderr and not output.exists()
    result = run("record", "--app", "example.app", "--out", str(output), "--duration", "nan", expected=1)
    assert "positive finite" in result.stderr and not output.exists()
    run("transcribe", str(Path(directory) / "missing-session"), expected=1)
    result = run("record", "missing", "--app", "other", expected=1)
    assert "either a positional app name or --app" in result.stderr
    result = run("invalid-capture-it-no-match", expected=1)
    assert "No running app matches" in result.stderr
run("record", "--out", "example", expected=1)
run("apps", "--unknown", "x", expected=1)
run("apps", "--json", "--json", expected=1)
print("passed: CLI discovery, model readiness, invalid selection, invalid duration, missing session and argument failures")
