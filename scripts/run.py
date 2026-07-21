#!/usr/bin/env python3
"""Small Icarus regression entry point. All generated files stay in build/."""
import argparse
import csv
import math
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


def summarize_waits(path):
    """Nearest-rank P99 of frame starts within the measurement window only."""
    waits = [[] for _ in range(4)]
    with path.open(newline="", encoding="utf-8") as source:
        for row in csv.DictReader(source):
            if row["event"] == "WAIT" and row["measured"] == "1":
                waits[int(row["source"])].append(int(row["data_or_wait"]))
    lines = []
    for lane, values in enumerate(waits):
        values.sort()
        p99 = str(values[math.ceil(len(values) * 0.99) - 1]) if values else "NA"
        lines.append(f"WAIT_P99 source={lane} samples={len(values)} cycles={p99}")
    summary = "\n".join(lines) + "\n"
    path.with_suffix(".p99.txt").write_text(summary, encoding="utf-8")
    print(summary, end="")


def main():
    cases = ["fifo", "directed", "random", "negative", "single", "saturated", "skew", "sparse", "selftest"]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=cases + ["perf", "all"])
    parser.add_argument("--mode", type=int, choices=[0, 1], help="default: both policies")
    parser.add_argument("--seed", type=int, action="append", help="random seeds; default 1, 20261026")
    parser.add_argument("--events", action="store_true", help="write handshake CSV (including frame waits)")
    args = parser.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    selected = cases if args.suite == "all" else cases[4:8] if args.suite == "perf" else [args.suite]
    modes = [args.mode] if args.mode is not None else [0, 1]
    # Match Vivado's rtl/*.sv source discovery; -s elaborates only the chosen top.
    rtl = [path.relative_to(ROOT).as_posix() for path in sorted((ROOT / "rtl").glob("*.sv"))]
    compiled = set()
    for case in selected:
        top = "tb_fifo" if case == "fifo" else "tb_stream_selftest" if case == "selftest" else "tb_stream_arbiter"
        output = f"build/sim/{top}.vvp"
        if top not in compiled:
            run([tool("iverilog"), "-g2012", "-Wall", "-s", top, "-o", output,
                 *rtl, f"sim/{top}.sv"], BUILD / f"{top}-compile.log")
            compiled.add(top)
        for mode in ([0] if case in ("fifo", "selftest") else modes):
            for seed in ((args.seed or [1, 20261026]) if case == "random" else [1]):
                tag = f"{case}-{mode}" + (f"-seed{seed}" if case == "random" else "")
                command = [tool("vvp"), output, f"+CASE={case}", f"+MODE={mode}", f"+SEED={seed}"]
                if args.events and case not in ("fifo", "selftest"):
                    command.append(f"+EVENTS=build/sim/{tag}.csv")
                transcript = run(command, BUILD / f"{tag}.log")
                if "PASS " not in transcript:
                    raise SystemExit("Simulation exited without PASS")
                if args.events and case in cases[4:8]:
                    summarize_waits(BUILD / f"{tag}.csv")


if __name__ == "__main__":
    main()
