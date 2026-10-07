#!/usr/bin/env python3
"""Icarus regression: fixed frames, packet mode, interface boundaries and parameter guards."""
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


def admission_levels(value, ports):
    """A scalar applies to every lane; lists are ordered lane 0 first."""
    try:
        levels = tuple(int(item) for item in value.split(","))
    except ValueError as error:
        raise ValueError("admission must contain integers") from error
    if len(levels) == 1:
        levels *= ports
    if len(levels) != ports or any(level < 1 or level > 16 for level in levels):
        raise ValueError(f"admission requires one value or {ports} values in 1..16")
    return levels


def packed_admission(levels):
    return sum(level << (lane * 5) for lane, level in enumerate(levels))


def reject_unsupported_parameters(rtl):
    """Require the RTL's specific elaboration guard, not any compiler error."""
    top = "axis_stream_arbiter"
    cases = []
    for name, value in (("PORTS", 3), ("DATA_WIDTH", 48), ("FIFO_DEPTH", 32),
                        ("ADMISSION_LEVELS", packed_admission((0, 1, 1, 1))),
                        ("ADMISSION_LEVELS", packed_admission((17, 1, 1, 1)))):
        guard = "STREAM_ARBITER_UNSUPPORTED_ADMISSION" if name == "ADMISSION_LEVELS" else "STREAM_ARBITER_UNSUPPORTED_PARAMETERS"
        cases.append((f"{name.lower()}-{value}", {name: value}, guard))
    packet_guard = "STREAM_ARBITER_UNSUPPORTED_PACKET_PARAMETERS"
    cases += [("packet-mode-2", {"PACKET_MODE": 2}, packet_guard),
              ("max-frame-0", {"MAX_FRAME_BEATS": 0}, packet_guard),
              ("max-frame-65", {"MAX_FRAME_BEATS": 65}, packet_guard),
              ("packet-max-0", {"PACKET_MODE": 1, "MAX_FRAME_BEATS": 0}, packet_guard),
              ("packet-max-17-depth-16", {"PACKET_MODE": 1, "FIFO_DEPTH": 16, "MAX_FRAME_BEATS": 17}, packet_guard),
              ("packet-admission", {"PACKET_MODE": 1, "ADMISSION_LEVELS": packed_admission((2, 1, 1, 1))}, packet_guard)]
    keep_guard = "STREAM_ARBITER_UNSUPPORTED_KEEP_PARAMETERS"
    cases += [("keep-enable-2", {"PACKET_MODE": 1, "KEEP_ENABLE": 2}, keep_guard),
              ("keep-with-fixed-frames", {"KEEP_ENABLE": 1}, keep_guard)]
    for label, parameters, guard in cases:
        folder = BUILD / "invalid" / label
        folder.mkdir(parents=True, exist_ok=True)
        output = (folder / "rejected.vvp").relative_to(ROOT).as_posix()
        command = [tool("iverilog"), "-g2012", "-s", top,
                   *[f"-P{top}.{name}={value}" for name, value in parameters.items()],
                   "-o", output, *rtl]
        result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        (folder / "compile.log").write_text(result.stdout, encoding="utf-8")
        if result.returncode == 0 or guard not in result.stdout:
            raise SystemExit(f"Unsupported {parameters} did not hit the RTL elaboration guard; inspect {folder}")
        print(f"EXPECTED_REJECTION {label} {parameters}")
    return len(cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=CASES + ["admission", "packet", "perf", "matrix", "parameters", "all"])
    parser.add_argument("--mode", type=int, choices=[0, 1], help="default: both policies")
    parser.add_argument("--seed", type=int, action="append", help="random defaults to 1,20261026; packet defaults to 1; matrix uses 1")
    parser.add_argument("--events", action="store_true", help="write handshake CSV (including frame waits)")
    parser.add_argument("--ports", type=int, choices=[2, 4, 8], default=4)
    parser.add_argument("--width", type=int, choices=[32, 64], default=32)
    parser.add_argument("--depth", type=int, choices=[16, 64], default=64)
    parser.add_argument("--axis", action="store_true", help="test the AXI4-Stream top instead of the native core")
    parser.add_argument("--admission", default="1", help="static threshold(s), lane 0 first; scalar repeats")
    parser.add_argument("--max-frame-beats", type=int, help="packet suite: maximum legal frame length (default: FIFO depth)")
    parser.add_argument("--keep", action="store_true", help="packet suite: enable the packed low-byte TKEEP subset")
    parser.add_argument("--gap", type=int, choices=[1, 2, 4, 8], default=2,
                        help="source opportunity contract for the admission boundary case")
    parser.add_argument("--expect-starve", action="store_true", help="require the H*-1 legal-source counterexample")
    args = parser.parse_args()
    config = (args.ports, args.width, args.depth, args.axis)
    try:
        selected_levels = admission_levels(args.admission, args.ports)
    except ValueError as error:
        parser.error(str(error))
    max_frame_beats = args.max_frame_beats if args.max_frame_beats is not None else args.depth
    if args.max_frame_beats is not None and args.suite != "packet":
        parser.error("--max-frame-beats applies only to packet")
    if args.keep and args.suite != "packet":
        parser.error("--keep applies only to packet")
    if not 1 <= max_frame_beats <= args.depth:
        parser.error("--max-frame-beats must be in 1..FIFO_DEPTH")
    if args.suite == "packet" and any(level != 1 for level in selected_levels):
        parser.error("packet mode requires the default --admission 1")
    if args.suite in ("fifo", "selftest", "all", "matrix", "parameters") and args.admission != "1":
        parser.error(f"{args.suite} uses fixed admission configurations")
    if args.suite != "admission" and (args.expect_starve or args.gap != 2):
        parser.error("--gap/--expect-starve apply only to admission")
    if args.suite == "directed" and any(level != 1 for level in selected_levels):
        parser.error("directed preserves the H=1 legacy semantics; use admission for thresholds")
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
            seeds = (args.seed or [1, 20261026]) if case == "random" else [1]
            if case == "packet":
                seeds = args.seed or [1]
            jobs.append((config, case, seeds))
    if args.suite in ("all", "matrix"):
        for ports, width, depth in itertools.product((2, 4, 8), (32, 64), (16, 64)):
            for case in MATRIX_CASES:
                jobs.append(((ports, width, depth, True), case, [1]))
    if args.suite == "all":
        # One boundary configuration covers high-word stability and late LAST
        # with the shallow FIFO, without repeating negatives across the matrix.
        jobs.append(((8, 64, 16, True), "negative", [1]))

    jobs = [(current, case, seeds,
             selected_levels if args.suite not in ("all", "matrix") else (1,) * current[0],
             args.gap, args.expect_starve) for current, case, seeds in jobs]
    if args.suite == "all":
        for gap, level, unsafe in ((1, 1, False), (2, 9, False), (2, 8, True),
                                   (4, 13, False), (4, 12, True), (8, 15, False),
                                   (8, 14, True), (2, 16, False)):
            jobs.append(((4, 32, 16, True), "admission", [1], (level,) * 4, gap, unsafe))
        jobs.extend([((2, 32, 16, True), "admission", [1], (9, 16), 2, False),
                     ((8, 64, 64, True), "admission", [1], (15, 1, 9, 13, 16, 1, 9, 13), 8, False)])

    jobs = [(*job, int(job[1] == "packet"), max_frame_beats if job[1] == "packet" else job[0][2], int(args.keep))
            for job in jobs]
    if args.suite == "all":
        for current, bound in (((4, 32, 16, False), 16), ((4, 32, 16, True), 16),
                               ((2, 32, 16, True), 1), ((4, 32, 16, True), 7),
                               ((8, 64, 16, True), 13), ((2, 64, 64, True), 31),
                               ((4, 32, 64, True), 64), ((8, 64, 64, True), 64)):
            jobs.append((current, "packet", [1], (1,) * current[0], 1, False, 1, bound, 0))
        for current, bound in (((4, 32, 16, False), 16), ((4, 32, 16, True), 16),
                               ((2, 32, 16, True), 1), ((2, 64, 16, True), 7),
                               ((8, 64, 64, True), 64)):
            jobs.append((current, "packet", [1], (1,) * current[0], 1, False, 1, bound, 1))

    # Match Vivado's rtl/*.sv source discovery; -s elaborates only the chosen top.
    rtl = [path.relative_to(ROOT).as_posix() for path in sorted((ROOT / "rtl").glob("*.sv"))]
    compiled = set()
    simulations = 0
    for current, case, seeds, levels, gap, unsafe, packet_mode, frame_bound, keep_enable in jobs:
        ports, width, depth, axis = current
        tag = configuration_name(current)
        if any(level != 1 for level in levels):
            tag += "-h" + "-".join(map(str, levels))
        if packet_mode:
            tag += f"-packet-max{frame_bound}"
        if keep_enable:
            tag += "-keep"
        folder = BUILD / tag
        folder.mkdir(parents=True, exist_ok=True)
        top = "tb_fifo" if case == "fifo" else "tb_stream_selftest" if case == "selftest" else "tb_stream_arbiter"
        output = (folder / f"{top}.vvp").relative_to(ROOT).as_posix()
        key = (current, top, levels, packet_mode, frame_bound, keep_enable)
        if key not in compiled:
            parameters = []
            if top == "tb_stream_arbiter":
                parameters = [f"-P{top}.{name}={value}" for name, value in
                              (("PORTS", ports), ("DATA_WIDTH", width), ("FIFO_DEPTH", depth), ("AXIS", int(axis)),
                               ("PACKET_MODE", packet_mode), ("MAX_FRAME_BEATS", frame_bound), ("KEEP_ENABLE", keep_enable))]
                parameters.append(f"-P{top}.ADMISSION_LEVELS={ports*5}'d{packed_admission(levels)}")
            run([tool("iverilog"), "-g2012", "-Wall", "-s", top, *parameters, "-o", output,
                 *rtl, f"sim/{top}.sv"], folder / f"{top}-compile.log")
            compiled.add(key)
        for mode in ([0] if case in ("fifo", "selftest") else modes):
            for seed in seeds:
                name = f"{case}-{mode}" + (f"-seed{seed}" if case in ("random", "packet") else "")
                print(f"RUN {tag} {name}", flush=True)
                command = [tool("vvp"), output, f"+CASE={case}", f"+MODE={mode}", f"+SEED={seed}"]
                if case == "admission":
                    command += [f"+GAP={gap}", f"+EXPECT_STARVE={int(unsafe)}"]
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
