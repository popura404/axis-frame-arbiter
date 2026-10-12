#!/usr/bin/env python3
"""Fetch frozen, unchanged UHD source dependencies; --check is offline."""
import argparse
from pathlib import Path
import urllib.error
from fetch_axis import fetch as fetch_pinned

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "scripts" / "external_uhd.json"
VENDOR = ROOT / "build" / "vendor" / "uhd"


def fetch(check_only=False):
    fetch_pinned(check_only, MANIFEST, VENDOR, "UHD")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify cache without network access")
    args = parser.parse_args()
    try:
        fetch(args.check)
    except (OSError, ValueError, KeyError, urllib.error.URLError) as error:
        raise SystemExit(f"UHD source unavailable: {error}") from error


if __name__ == "__main__":
    main()
