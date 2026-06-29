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
    parser.add_argument("suite", choices=["fifo", "directed"])
    parser.add_argument("--mode", type=int, choices=[0, 1], help="default: both policies")
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    top = "tb_fifo" if args.suite == "fifo" else "tb_stream_arbiter"
    output = f"build/sim/{top}.vvp"
    rtl = ["rtl/sync_fifo.sv", "rtl/stream_fifo.sv"]
    if args.suite != "fifo":
        rtl += ["rtl/frame_arbiter.sv", "rtl/stream_arbiter.sv"]
    run([tool("iverilog"), "-g2012", "-Wall", "-s", top, "-o", output,
         *rtl, f"sim/{top}.sv"], BUILD / f"{top}-compile.log")
    modes = [args.mode] if args.mode is not None else [0, 1]
    for mode in ([0] if args.suite == "fifo" else modes):
        transcript = run([tool("vvp"), output, f"+CASE={args.suite}", f"+MODE={mode}"],
                         BUILD / f"{args.suite}-{mode}.log")
        if "PASS " not in transcript:
            raise SystemExit("Simulation exited without PASS")


if __name__ == "__main__":
    main()
