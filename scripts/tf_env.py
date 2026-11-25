"""Load the non-secret settings the local scripts need from `terraform output`."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "app"))


def load() -> None:
    if os.getenv("AZURE_SEARCH_ENDPOINT"):
        return
    out = subprocess.run(
        ["terraform", f"-chdir={ROOT / 'infra'}", "output", "-json", "local_env"],
        capture_output=True, text=True, check=True,
    ).stdout
    os.environ.update(json.loads(out))
