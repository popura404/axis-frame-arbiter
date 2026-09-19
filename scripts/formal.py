#!/usr/bin/env python3
"""Bounded real-RTL admission checks with Yosys-SMTBMC/Z3; no SBY required.

Default: fixed-prefix handoff with continuous READY, G=2/H=9 BMC +
non-vacuity cover, and the expected G=2/H=8
underflow counterexample. Results identify depth, assumptions and source hashes.
Use --check induction explicitly: an induction failure is not a BMC failure.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "formal"


def environment():
    env = dict(os.environ)
    local = ROOT / "build" / "tools" / "root" / "usr"
    if (local / "bin" / "yosys").is_file():
        for variable, path in (("PATH", local / "bin"),
                               ("LD_LIBRARY_PATH", local / "lib" / "x86_64-linux-gnu"),
                               ("PYTHONPATH", local / "share" / "yosys")):
            env[variable] = str(path) + (os.pathsep + env[variable] if env.get(variable) else "")
    for name in ("yosys", "yosys-smtbmc", "z3"):
        if not shutil.which(name, path=env.get("PATH")):
            raise SystemExit(f"Missing {name}; install Yosys and Z3 or supply them on PATH")
    return env


def run(command, log, env, timeout):
    started = time.monotonic()
    with log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Kill the solver too, not only its Python parent.
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            status = process.returncode
    return {"command": command, "returncode": status, "wall_timeout": timed_out,
            "elapsed_seconds": round(time.monotonic()-started, 3),
            "log": log.relative_to(ROOT).as_posix()}


def result_status(record, mode, text, underflow_line, expected_covers):
    if record["wall_timeout"] or "timed out" in text.lower() or "timeout" in text.lower():
        return "TIMEOUT"
    if mode == "negative":
        failures = re.findall(r"Assert failed in .*: formal/admission\.sv:(\d+)\.\d+-(\d+)\.\d+", text)
        correct_property = failures and all(int(a) <= underflow_line <= int(b) for a, b in failures)
        if record["returncode"] != 0 and "Status: FAILED" in text and correct_property:
            return "EXPECTED_UNDERFLOW_COUNTEREXAMPLE"
        return "UNEXPECTED_RESULT"
    if record["returncode"] == 0 and "Status: PASSED" in text:
        if mode == "cover" and text.count("Reached cover statement") < expected_covers:
            return "MISSING_COVER"
        return "PASS"
    if mode == "induction" and "Status: FAILED" in text:
        return "INDUCTION_NOT_ESTABLISHED"
    return "FAIL" if "Status: FAILED" in text else "TOOL_ERROR"


def scheduler_checks(args, env):
    folder = BUILD / "scheduler"
    folder.mkdir(parents=True, exist_ok=True)
    checks = list(dict.fromkeys(args.check or ["bmc", "induction", "cover"]))
    if "negative" in checks or args.gap or args.data:
        raise SystemExit("scheduler supports bmc/induction/cover, without gap or data overrides")
    sources = [ROOT / "rtl/frame_arbiter.sv", ROOT / "formal/scheduler.sv"]
    report = {"configuration": {"target": "frame_arbiter", "ports": 2, "steps": args.depth},
              "scope": "interface-level grant hold and eligible selection; arbitrary availability/frame_done, fixed reset-sampled mode; does not prove parent eligibility, priority order, mode capture, or frame completion",
              "versions": {name: subprocess.check_output(cmd, env=env, text=True).strip() for name, cmd in
                           (("yosys", ["yosys", "-V"]), ("z3", ["z3", "--version"]))},
              "sha256": {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              "jobs": []}
    command = "read_verilog -formal -sv rtl/frame_arbiter.sv formal/scheduler.sv; prep -top formal_scheduler; flatten; opt; dffunmap; write_smt2 -wires build/formal/scheduler/design.smt2"
    compiled = run(["yosys", "-Q", "-T", "-p", command], folder / "compile.log", env, args.timeout)
    report["compile"] = compiled
    okay = compiled["returncode"] == 0 and not compiled["wall_timeout"]
    if okay:
        for check in checks:
            extra = ["-i"] if check == "induction" else ["-c"] if check == "cover" else []
            trace = folder / f"{check}-%.vcd"
            for old_trace in folder.glob(f"{check}*.vcd"):
                old_trace.unlink()
            command = ["yosys-smtbmc", "-s", "z3", "--unroll", "--noprogress", "-t", str(args.depth),
                       *extra, "--dump-vcd", trace.relative_to(ROOT).as_posix(), "build/formal/scheduler/design.smt2"]
            job = run(command, folder / f"{check}.log", env, args.timeout)
            job["check"] = check
            job["status"] = result_status(job, check, (ROOT / job["log"]).read_text(), 0, 2)
            okay &= job["status"] == "PASS"
            report["jobs"].append(job)
            print(f"scheduler {check}: {job['status']}", flush=True)
    report["all_requested_checks_met"] = okay
    (folder / "results.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    return okay


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=("admission", "scheduler"), default="admission")
    parser.add_argument("--gap", type=int, action="append", choices=(1, 2, 4, 8), help="default: 2")
    parser.add_argument("--depth", type=int, default=48, help="SMTBMC time steps, including reset")
    parser.add_argument("--timeout", type=int, default=90, help="wall seconds per tool invocation")
    parser.add_argument("--check", action="append", choices=("bmc", "cover", "negative", "induction"))
    parser.add_argument("--ready", choices=("always", "arbitrary"), default="always",
                        help="default: continuous downstream READY; arbitrary retains all backpressure patterns")
    parser.add_argument("--scenario", choices=("handoff", "general"), default="handoff",
                        help="handoff fixes only the prefix setup; general leaves all legal arrivals free")
    parser.add_argument("--data", action="store_true", help="also check deterministic 32-bit sequence tags")
    args = parser.parse_args()
    if args.depth < 2 or args.timeout < 1:
        parser.error("depth >= 2 and timeout >= 1 are required")
    gaps = list(dict.fromkeys(args.gap or [2]))
    checks = list(dict.fromkeys(args.check or ["bmc", "cover", "negative"]))
    if args.target == "admission" and checks == ["negative"] and gaps == [1]:
        parser.error("G=1 would require illegal H=0; no valid RTL underflow experiment exists")
    env = environment()
    if args.target == "scheduler":
        raise SystemExit(0 if scheduler_checks(args, env) else 1)
    BUILD.mkdir(parents=True, exist_ok=True)
    rtl = sorted((ROOT / "rtl").glob("*.sv"))
    harness = ROOT / "formal" / "admission.sv"
    source = harness.read_text(encoding="utf-8")
    underflow_line = next(i for i, line in enumerate(source.splitlines(), 1)
                          if "conditional no-underflow property" in line)
    versions = {name: subprocess.check_output(command, env=env, text=True).strip()
                for name, command in (("yosys", ["yosys", "-V"]), ("z3", ["z3", "--version"]))}
    report = {"versions": versions, "configuration": {"ports": 2, "width": 32, "depth": 16,
              "policy": "RR", "reset": "initial only", "solver_steps": args.depth,
              "scenario": args.scenario, "downstream_ready": args.ready,
              "data": "deterministic source/sequence tags" if args.data else "control and LAST only"},
              "assumptions": "fixed 16 beats; VALID held under backpressure; at most G-1 missed READY opportunities within each frame; downstream READY as selected",
              "scope": "BMC is bounded; no-underflow starts after first output handshake; cover shows selected witnesses; handoff fixes source0 frame, source1 H-beat prefix, and READY=1 through H+16, then leaves legal source1 supply free and applies the selected downstream READY assumption; induction is separate; no board or arbitrary-payload claim",
              "sha256": {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [*rtl, harness]}, "jobs": []}
    okay = True
    compiled = {}
    for gap in gaps:
        safe = 16 - 15 // gap
        for check in checks:
            if check == "negative" and safe == 1:
                report["jobs"].append({"gap": gap, "check": check, "status": "NOT_APPLICABLE_H0_ILLEGAL"})
                continue
            level = safe - int(check == "negative")
            folder = BUILD / f"g{gap}-h{level}-{args.scenario}-{args.ready}-{'tagged' if args.data else 'control'}"
            folder.mkdir(parents=True, exist_ok=True)
            smt = (folder / "design.smt2").relative_to(ROOT).as_posix()
            key = (gap, level)
            if key not in compiled:
                command = "read_verilog -formal -sv " + " ".join(p.relative_to(ROOT).as_posix() for p in rtl)
                command += "; read_verilog -formal -sv formal/admission.sv"
                command += f"; chparam -set G {gap} -set H {level} -set CHECK_DATA {int(args.data)} -set SCENARIO {int(args.scenario == 'handoff')} -set CONTINUOUS_READY {int(args.ready == 'always')} formal_admission"
                command += f"; prep -top formal_admission; flatten; memory_map; opt; dffunmap; write_smt2 -wires {smt}"
                compile_result = run(["yosys", "-Q", "-T", "-p", command], folder / "compile.log", env, args.timeout)
                compiled[key] = compile_result
            compile_result = compiled[key]
            job = {"gap": gap, "level": level, "check": check, "compile": compile_result}
            if compile_result["returncode"] != 0 or compile_result["wall_timeout"]:
                job["status"] = "COMPILE_ERROR"
            else:
                extra = ["-c"] if check == "cover" else ["-i"] if check == "induction" else []
                trace = (folder / f"{check}-%.vcd").relative_to(ROOT).as_posix()
                for old_trace in folder.glob(f"{check}*.vcd"):
                    old_trace.unlink()
                command = ["yosys-smtbmc", "-s", "z3", "--unroll", "--noprogress", "-t", str(args.depth), *extra,
                           "--dump-vcd", trace, smt]
                record = run(command, folder / f"{check}.log", env, args.timeout)
                job.update(record)
                transcript = (ROOT / record["log"]).read_text(encoding="utf-8", errors="replace")
                job["status"] = result_status(record, check, transcript, underflow_line, 1 if args.ready == "always" else 2)
            report["jobs"].append(job)
            expected = "EXPECTED_UNDERFLOW_COUNTEREXAMPLE" if check == "negative" else "PASS"
            okay &= job["status"] == expected
            print(f"G={gap} H={level} {check}: {job['status']}", flush=True)
            (BUILD / "results.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    report["all_requested_checks_met"] = okay
    (BUILD / "results.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")
    raise SystemExit(0 if okay else 1)


if __name__ == "__main__":
    main()
