#!/usr/bin/env python3
"""Fetch the pinned external AXIS baseline; --check verifies its offline cache."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "scripts" / "external_axis.json"
VENDOR = ROOT / "build" / "vendor" / "verilog-axis"


def fetch(check_only=False):
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    commit = manifest["commit"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("External baseline requires a full commit SHA")
    for entry in manifest["files"]:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Invalid manifest path: {relative}")
        target = VENDOR / relative
        cached = target.exists()
        if cached:
            content = target.read_bytes()
        elif check_only:
            raise ValueError(f"Missing {target}; run scripts/fetch_axis.py first")
        else:
            url = f"https://raw.githubusercontent.com/alexforencich/verilog-axis/{commit}/{relative.as_posix()}"
            with urllib.request.urlopen(url, timeout=30) as response:
                content = response.read()
        if hashlib.sha256(content).hexdigest() != entry["sha256"]:
            raise ValueError(f"SHA256 mismatch: {target}; cached files are not silently replaced")
        if not cached:
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
                    temporary = Path(output.name)
                    output.write(content)
                temporary.replace(target)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        print(f"VERIFIED {relative.as_posix()} {entry['sha256']}")
    print(f"PASS external baseline commit={commit} files={len(manifest['files'])}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify cache without accessing the network")
    args = parser.parse_args()
    try:
        fetch(args.check)
    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
        raise SystemExit(f"External baseline unavailable: {error}") from error


if __name__ == "__main__":
    main()
