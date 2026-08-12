#!/usr/bin/env python3
"""Icarus regression: all = core, AXI matrix, wide/shallow negatives and parameter guards."""
import argparse
import csv
import itertools
import math
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "sim"
DEFAULT = (4, 32, 64, False)
CASES = ["fifo", "directed", "random", "negative", "single", "saturated", "skew", "sparse", "selftest"]
PERF = ["single", "saturated", "skew", "sparse"]
MATRIX_CASES = ["directed", "random", "saturated", "single"]


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


def summarize_waits(path, ports):
    """Nearest-rank P99 of frame starts within the measurement window only."""
    waits = [[] for _ in range(ports)]
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


def configuration_name(config):
    ports, width, depth, axis = config
    return f"{'axis' if axis else 'core'}-p{ports}-w{width}-d{depth}"


def reject_unsupported_parameters(rtl):
    """Require the RTL's specific elaboration guard, not any compiler error."""
    top = "axis_stream_arbiter"
    for name, value in (("PORTS", 3), ("DATA_WIDTH", 48), ("FIFO_DEPTH", 32)):
        folder = BUILD / "invalid" / f"{name.lower()}-{value}"
        folder.mkdir(parents=True, exist_ok=True)
        output = (folder / "rejected.vvp").relative_to(ROOT).as_posix()
        command = [tool("iverilog"), "-g2012", "-s", top, f"-P{top}.{name}={value}",
                   "-o", output, *rtl]
        result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        (folder / "compile.log").write_text(result.stdout, encoding="utf-8")
        if result.returncode == 0 or "STREAM_ARBITER_UNSUPPORTED_PARAMETERS" not in result.stdout:
            raise SystemExit(f"Unsupported {name}={value} did not hit the RTL elaboration guard; inspect {folder}")
        print(f"EXPECTED_REJECTION {name}={value}")
    return 3


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=CASES + ["perf", "matrix", "parameters", "all"])
    parser.add_argument("--mode", type=int, choices=[0, 1], help="default: both policies")
    parser.add_argument("--seed", type=int, action="append", help="random seeds; default 1, 20261026; matrix always uses 1")
    parser.add_argument("--events", action="store_true", help="write handshake CSV (including frame waits)")
    parser.add_argument("--ports", type=int, choices=[2, 4, 8], default=4)
    parser.add_argument("--width", type=int, choices=[32, 64], default=32)
    parser.add_argument("--depth", type=int, choices=[16, 64], default=64)
    parser.add_argument("--axis", action="store_true", help="test the AXI4-Stream top instead of the native core")
    args = parser.parse_args()
    config = (args.ports, args.width, args.depth, args.axis)
    if args.suite in ("fifo", "selftest", "all", "matrix", "parameters") and config != DEFAULT:
        parser.error(f"{args.suite} has fixed configurations; use a system case or perf with parameter overrides")
    if args.suite == "matrix" and args.seed:
        parser.error("matrix uses fixed seed 1; use random with parameter overrides for another seed")
    modes = [args.mode] if args.mode is not None else [0, 1]
    # Core and AXI are distinct interfaces. all runs the complete default core
    # regression once, then every AXI matrix combination once (including default).
    jobs = []
    if args.suite not in ("matrix", "parameters"):
        selected = CASES if args.suite == "all" else PERF if args.suite == "perf" else [args.suite]
        for case in selected:
            jobs.append((config, case, (args.seed or [1, 20261026]) if case == "random" else [1]))
    if args.suite in ("all", "matrix"):
        for ports, width, depth in itertools.product((2, 4, 8), (32, 64), (16, 64)):
            for case in MATRIX_CASES:
                jobs.append(((ports, width, depth, True), case, [1]))
    if args.suite == "all":
        # One boundary configuration covers high-word stability and late LAST
        # with the shallow FIFO, without repeating negatives across the matrix.
        jobs.append(((8, 64, 16, True), "negative", [1]))

    # Match Vivado's rtl/*.sv source discovery; -s elaborates only the chosen top.
    rtl = [path.relative_to(ROOT).as_posix() for path in sorted((ROOT / "rtl").glob("*.sv"))]
    compiled = set()
    simulations = 0
    for current, case, seeds in jobs:
        ports, width, depth, axis = current
        tag = configuration_name(current)
        folder = BUILD / tag
        folder.mkdir(parents=True, exist_ok=True)
        top = "tb_fifo" if case == "fifo" else "tb_stream_selftest" if case == "selftest" else "tb_stream_arbiter"
        output = (folder / f"{top}.vvp").relative_to(ROOT).as_posix()
        key = (current, top)
        if key not in compiled:
            parameters = []
            if top == "tb_stream_arbiter":
                parameters = [f"-P{top}.{name}={value}" for name, value in
                              (("PORTS", ports), ("DATA_WIDTH", width), ("FIFO_DEPTH", depth), ("AXIS", int(axis)))]
            run([tool("iverilog"), "-g2012", "-Wall", "-s", top, *parameters, "-o", output,
                 *rtl, f"sim/{top}.sv"], folder / f"{top}-compile.log")
            compiled.add(key)
        for mode in ([0] if case in ("fifo", "selftest") else modes):
            for seed in seeds:
                name = f"{case}-{mode}" + (f"-seed{seed}" if case == "random" else "")
                print(f"RUN {tag} {name}", flush=True)
                command = [tool("vvp"), output, f"+CASE={case}", f"+MODE={mode}", f"+SEED={seed}"]
                events = folder / f"{name}.csv"
                if args.events and case not in ("fifo", "selftest"):
                    command.append(f"+EVENTS={events.relative_to(ROOT).as_posix()}")
                transcript = run(command, folder / f"{name}.log")
                if "PASS " not in transcript:
                    raise SystemExit("Simulation exited without PASS")
                if args.events and case in PERF:
                    summarize_waits(events, ports)
                simulations += 1
    rejections = reject_unsupported_parameters(rtl) if args.suite in ("parameters", "all") else 0
    print(f"PASS regression simulations={simulations} parameter_rejections={rejections}")


if __name__ == "__main__":
    main()
