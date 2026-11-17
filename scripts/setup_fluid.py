"""Explicit one-time model download. Normal hook inference never calls this script."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from urllib.parse import quote
from urllib.request import urlopen

os.umask(0o077)
root = Path(__file__).resolve().parents[1]
spec = json.loads((root / "hooks/fluid-audio/Sources/FluidHook/Resources/model-spec.json").read_text())
destination = Path(os.environ.get("CAPTURE_IT_FLUID_MODELS", Path.home() / "Library/Application Support/capture-it/fluid-models")).resolve()
if destination.exists():
    existing = destination / "setup.json"
    if existing.is_file():
        configured = json.loads(existing.read_text())
        if configured.get("repository") == spec["repository"] and configured.get("revision") == spec["revision"]:
            print(f"Pinned model setup exists at {destination}; the following --check will validate every file.")
            raise SystemExit(0)
    raise SystemExit(f"Model directory already exists: {destination}. Use hooks/fluidaudio --check; choose a new CAPTURE_IT_FLUID_MODELS directory to reinstall.")
destination.parent.mkdir(parents=True, exist_ok=True)
staging = Path(tempfile.mkdtemp(prefix=".fluid-setup-", dir=destination.parent))
try:
    repository = spec["repository"]
    revision = spec["revision"]
    api = f"https://huggingface.co/api/models/{repository}/tree/{revision}?recursive=true&limit=1000"
    with urlopen(api, timeout=60) as response:
        entries = json.load(response)
        if response.headers.get("Link"):
            raise RuntimeError("Model listing is paginated; refusing an incomplete setup")
    def wanted(path):
        return any(path.startswith(item) if item.endswith("/") else path == item for item in spec["paths"])
    files = [item for item in entries if item["type"] == "file" and wanted(item["path"])]
    assert all(any(item["path"].startswith(path) if path.endswith("/") else item["path"] == path for item in files) for path in spec["paths"]), "Missing required model assets"
    print(f"Downloading {len(files)} pinned files, {sum(item['size'] for item in files) / 1024**2:.1f} MiB from {repository}@{revision}", flush=True)
    installed = []
    for item in files:
        path = item["path"]
        assert not Path(path).is_absolute() and ".." not in Path(path).parts
        target = staging / path
        target.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://huggingface.co/{repository}/resolve/{revision}/{quote(path, safe='/')}"
        sha256 = hashlib.sha256()
        git = hashlib.sha1(f"blob {item['size']}\0".encode())
        size = 0
        with urlopen(url, timeout=120) as response, target.open("xb") as output:
            while chunk := response.read(1_048_576):
                size += len(chunk)
                if size > item["size"]:
                    raise RuntimeError(f"Asset larger than declared size: {path}")
                sha256.update(chunk); git.update(chunk); output.write(chunk)
            output.flush(); os.fsync(output.fileno())
        assert size == item["size"], f"Truncated model file: {path}"
        expected = item.get("lfs", {}).get("oid")
        assert (sha256.hexdigest() == expected if expected else git.hexdigest() == item["oid"]), f"Integrity failure: {path}"
        installed.append({"path": path, "size": size, "sha256": sha256.hexdigest()})
        print(f"  verified {path}", flush=True)
    manifest = {"version": 1, "repository": repository, "revision": revision, "files": installed}
    (staging / "setup.json").write_text(json.dumps(manifest, indent=2) + "\n")
    staging.rename(destination)
    print(f"Offline models installed at {destination}")
finally:
    if staging.exists():
        shutil.rmtree(staging)
