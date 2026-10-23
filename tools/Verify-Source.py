"""Check the source-only repository before committing or pushing it."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

FORBIDDEN_SUFFIXES = {
    ".exe", ".dll", ".asar", ".msix", ".msixbundle", ".appx", ".zip",
    ".sqlite", ".sqlite3", ".db", ".log", ".lnk", ".gguf", ".safetensors",
}
FORBIDDEN_NAMES = {
    "auth.json", "freeze-plan.json", "credentials.dpapi.json", "config.toml",
    "config.yml", "launcher.settings.json", "session_index.jsonl", "history.jsonl",
}
FORBIDDEN_PARTS = {
    "sessions", "archived_sessions", "electron-data", "profiles", "backups",
    "snapshot", "runtime",
}
SECRET = re.compile(
    rb"\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,})\b"
)


def check(root: Path) -> dict:
    files = 0
    total = 0
    failures = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if ".git" in relative.parts or "__pycache__" in relative.parts:
            continue
        if path.is_symlink():
            failures.append(str(relative) + ": filesystem link")
            continue
        if not path.is_file():
            continue
        files += 1
        size = path.stat().st_size
        total += size
        if (
            path.suffix.lower() in FORBIDDEN_SUFFIXES
            or path.name.lower() in FORBIDDEN_NAMES
            or any(part.lower() in FORBIDDEN_PARTS for part in relative.parts[:-1])
            or size > 2 * 1024 * 1024
        ):
            failures.append(str(relative) + ": runtime/private/oversized asset")
            continue
        data = path.read_bytes()
        if SECRET.search(data):
            failures.append(str(relative) + ": credential-shaped value")
        # Machine-specific sources must be parameters, not an author's profile.
        if re.search(rb"[A-Za-z]:\\{1,2}Users\\{1,2}Administrator\b", data):
            failures.append(str(relative) + ": personal absolute profile path")
    return {"status": "OK" if not failures else "FAILED", "files": files,
            "bytes": total, "failures": failures}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    result = check(parser.parse_args().root)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["status"] == "OK" else 1)
