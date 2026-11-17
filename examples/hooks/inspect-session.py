#!/usr/bin/env python3
"""Local-only hook example: inspect the handoff without calling an AI service."""
import json
import os
from pathlib import Path
import sys

os.umask(0o077)
event = json.loads(Path(sys.argv[1]).read_text())
summary = {
    "wav": event["wav"],
    "wavBytes": Path(event["wav"]).stat().st_size,
    "transcript": event.get("transcript"),
    "transcriptComplete": event.get("transcriptComplete"),
    "meeting": event.get("meeting"),
}
output = Path(os.environ["CAPTURE_IT_HOOK_OUTPUT"]) / "inspection.json"
output.write_text(json.dumps(summary, indent=2) + "\n")
print(f"Saved {output}")
