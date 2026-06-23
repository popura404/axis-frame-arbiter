#!/usr/bin/env python3
"""Small Icarus regression entry point. All generated files stay in build/."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "sim"


def tool(name):
    configured = os.environ.get(name.upper())
    found = configured or shutil.which(name) or shutil.which(name + ".exe")
    fallback = Path("/mnt/e/iverilog/bin") / (name + ".exe")
    if not found and fallback.exists():
        found = str(fallback)
    if not found:
        raise SystemExit(f"Set {name.upper()} to the installed {name} executable")
    return found


def run(command, log):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    log.write_text(result.stdout, encoding="utf-8")
    print(result.stdout, end="")
    if result.returncode:
        raise SystemExit(f"Failed ({result.returncode}): {' '.join(command)}; see {log}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=["fifo"])
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    top = "tb_" + args.suite
    output = f"build/sim/{top}.vvp"
    run([tool("iverilog"), "-g2012", "-Wall", "-s", top, "-o", output,
         "rtl/sync_fifo.sv", "rtl/stream_fifo.sv", "sim/tb_fifo.sv"], BUILD / f"{top}-compile.log")
    transcript = run([tool("vvp"), output], BUILD / f"{top}.log")
    if "PASS " not in transcript:
        raise SystemExit("Simulation exited without PASS")


if __name__ == "__main__":
    main()
