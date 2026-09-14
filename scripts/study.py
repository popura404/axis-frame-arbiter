#!/usr/bin/env python3
"""Small preregistered admission pilot using the primary interface scoreboard."""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import random
import subprocess
import sys

from fetch_axis import fetch, VENDOR
from run import ROOT, tool

BUILD = ROOT / "build" / "study"
SCENARIOS = ("saturated", "isolated_g1", "isolated_g2", "isolated_g4", "isolated_g8",
             "burst", "mixed", "periodic", "random")
CANDIDATES = ("B0", "B1", "B2", "C", "E_WORD", "E_FRAME")
SEEDS = (1, 20261027)
PORTS, WIDTH, DEPTH = 4, 32, 16


def plan(scenario, seed):
    """Only external time and this fixed seed determine releases and READY."""
    generator = random.Random(seed)
    gaps = [1, 2, 4, 8]
    start, end, maximum = 1, 2400, 20000
    if scenario == "saturated":
        gaps = [1] * PORTS
        releases = [list(range(1, 1537)) for _ in range(PORTS)]
        start, end = 400, 2000
    elif scenario.startswith("isolated_"):
        gap = int(scenario.rsplit("g", 1)[1])
        gaps = [gap, 0, 0, 0]
        releases = [[1 + frame * 160 + beat * gap for frame in range(8) for beat in range(16)], [], [], []]
        end = 1500
    else:
        releases = [[] for _ in range(PORTS)]
        count, period = (8, 160) if scenario == "burst" else (8, 240) if scenario == "mixed" else (16, 128)
        end = 1500 if scenario == "burst" else 2200 if scenario == "mixed" else 2400
        if scenario == "mixed":
            gaps[-1] = 0  # Unknown supply: no finite G is assumed.
        for lane in range(PORTS):
            for frame in range(count):
                at = 1 + frame * period + lane * 2
                releases[lane].append(at)
                for beat in range(1, 16):
                    if gaps[lane] == 0:
                        increment = 40 if beat % 5 == 0 else 3
                    elif scenario == "burst":
                        increment = generator.randint(1, gaps[lane])
                    else:
                        increment = gaps[lane]
                    at += increment
                    releases[lane].append(at)
    ready = [1] * (maximum + 1)
    consecutive_blocked = 0
    for cycle in range(1, end + 1):
        if scenario == "periodic":
            ready[cycle] = int(cycle % 17 < 11)
        elif scenario == "random":
            ready[cycle] = int(consecutive_blocked >= 4 or generator.random() < 0.7)
            consecutive_blocked = 0 if ready[cycle] else consecutive_blocked + 1
    return dict(scenario=scenario, seed=seed, gaps=gaps, releases=releases,
                ready=ready, window_start=start, window_end=end, maximum=maximum)


def save_plan(data):
    folder = BUILD / "plans" / f"{data['scenario']}-seed{data['seed']}"
    folder.mkdir(parents=True, exist_ok=True)
    lines = [f"{PORTS} {data['window_start']} {data['window_end']} {data['maximum']}"]
    for gap, releases in zip(data["gaps"], data["releases"]):
        lines += [f"{len(releases)} {gap}", *(str(at) for at in releases)]
    release_path, ready_path = folder / "release.txt", folder / "ready.hex"
    release_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    ready_path.write_text("\n".join(map(str, data["ready"])) + "\n", encoding="utf-8")
    metadata = {key: value for key, value in data.items() if key not in ("releases", "ready")}
    metadata.update({"schema": 1, "ports": PORTS, "width": WIDTH, "depth": DEPTH,
                     "frame_counts": [len(times)//16 for times in data["releases"]],
                     "release_sha256": hashlib.sha256(release_path.read_bytes()).hexdigest(),
                     "ready_sha256": hashlib.sha256(ready_path.read_bytes()).hexdigest(),
                     "seed_registration": list(SEEDS), "stage": "pilot_not_paper_statistics"})
    (folder / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return release_path, ready_path, metadata


def thresholds(candidate, gaps):
    if candidate == "C":
        return [16 if gap == 0 else 16 - 15//gap for gap in gaps]
    return [{"B0": 1, "B1": 16, "B2": 8}.get(candidate, 1)] * PORTS


def command_run(command, log):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}\n{result.stdout}")
    return result.stdout


def compile_candidate(candidate, levels, cache):
    external = candidate.startswith("E_")
    packed = sum(level << (5 * lane) for lane, level in enumerate(levels))
    key = candidate if external else f"local-h{packed}"
    if key in cache:
        return cache[key]
    folder = BUILD / "compiled"
    folder.mkdir(parents=True, exist_ok=True)
    output = folder / f"{key}.vvp"
    top = "tb_stream_arbiter"
    parameters = dict(PORTS=PORTS, DATA_WIDTH=WIDTH, FIFO_DEPTH=DEPTH,
                      ADMISSION_LEVELS=packed, EXTERNAL=int(external), FRAME_FIFO=int(candidate == "E_FRAME"))
    sources = [str(path.relative_to(ROOT)) for path in sorted((ROOT / "rtl").glob("*.sv"))]
    if external:
        sources += ["sim/axis_external.sv"] + [str(path.relative_to(ROOT)) for path in sorted((VENDOR / "rtl").glob("*.v"))]
    command_run([tool("iverilog"), "-g2012", "-Wall", "-s", top,
                 *(f"-P{top}.{name}={value}" for name, value in parameters.items()),
                 "-o", str(output.relative_to(ROOT)), *sources, "sim/tb_stream_arbiter.sv"], folder / f"{key}.log")
    cache[key] = output
    return output


def statistics(values):
    values = sorted(values)
    if not values:
        return dict(samples=0, mean="NA", p99="NA", maximum="NA")
    return dict(samples=len(values), mean=sum(values)/len(values),
                p99=values[math.ceil(len(values)*0.99)-1], maximum=values[-1])


def provenance(scenarios, candidates, requested_seeds):
    files = sorted((ROOT / "rtl").glob("*.sv")) + [ROOT / name for name in
        ("sim/tb_stream_arbiter.sv", "sim/study_tasks.svh", "sim/axis_external.sv",
         "scripts/study.py", "scripts/fetch_axis.py", "scripts/external_axis.json", "scripts/run.py")]
    versions = {}
    for name in ("iverilog", "vvp"):
        result = subprocess.run([tool(name), "-V"], cwd=ROOT, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(f"Cannot read {name} version: {result.stdout}")
        versions[name] = dict(executable=tool(name), version=result.stdout.splitlines()[0])
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, check=True,
                          stdout=subprocess.PIPE).stdout.strip()
    manifest = dict(schema=1, stage="pilot_not_paper_statistics", git_head_before_run=head,
                    source_sha256={str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
                    python=sys.version, tools=versions, candidates=list(candidates),
                    scenarios={scenario: list(requested_seeds or (SEEDS if scenario in ("burst", "random") else (SEEDS[0],))) for scenario in scenarios},
                    selection="All preregistered runs retained; no significance or confidence-interval claim",
                    latency="Window latency includes observed starts/completions only; censored frame counts remain explicit. Drained finite-load latency includes every frame.")
    target = BUILD / "manifest.json"
    target.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return hashlib.sha256(target.read_bytes()).hexdigest()


def summarize(folder, candidate, levels, metadata):
    with (folder / "frames.csv").open(newline="", encoding="utf-8") as stream:
        frames = [{key: int(value) for key, value in row.items()} for row in csv.DictReader(stream)]
    total, sources = {}, [dict(source=lane) for lane in range(PORTS)]
    with (folder / "counts.csv").open(newline="", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            target = total if row["scope"] == "total" else sources[int(row["source"])]
            target[row["metric"]] = int(row["value"])
    start, end = total["window_start"], total["window_end"]
    length = end - start + 1
    classes = ("transfer", "downstream_not_ready", "source_starvation", "admission_wait",
               "registered_grant", "empty", "external_unclassified")
    if sum(total[name] for name in classes) != length:
        raise RuntimeError("Cycle partition failed")
    total["beat_per_cycle"] = total["transfer"] / length
    observed_all = [row for row in frames if start <= row["completion"] <= end]
    started_all = [row for row in frames if start <= row["first_output"] <= end]
    total.update({"generated_frames": len(frames),
                  "window_completed": len(observed_all),
                  "unfinished_at_window_end": sum(row["generation"] <= end and (row["completion"] < 0 or row["completion"] > end) for row in frames),
                  "unstarted_at_window_end": sum(row["generation"] <= end and (row["first_output"] < 0 or row["first_output"] > end) for row in frames),
                  "unfinished_after_drain": sum(row["completion"] < 0 for row in frames),
                  "window_generation_to_completion": statistics([row["completion"]-row["generation"] for row in observed_all]),
                  "window_accept_to_first_output": statistics([row["first_output"]-row["first_accept"] for row in started_all]),
                  "drained_generation_to_completion": statistics([row["completion"]-row["generation"] for row in frames if row["completion"] >= 0])})
    for source in sources:
        rows = [row for row in frames if row["source"] == source["source"]]
        observed = [row for row in rows if start <= row["completion"] <= end]
        started = [row for row in rows if start <= row["first_output"] <= end]
        generated = [row for row in rows if row["generation"] <= end]
        source.update({"beat_per_cycle": source["output_beats"]/length,
                       "service_share": source["output_beats"]/total["transfer"] if total["transfer"] else "NA",
                       "window_completed": len(observed),
                       "unfinished_at_window_end": sum(row["completion"] < 0 or row["completion"] > end for row in generated),
                       "unstarted_at_window_end": sum(row["first_output"] < 0 or row["first_output"] > end for row in generated),
                       "unfinished_after_drain": sum(row["completion"] < 0 for row in rows),
                       "generated_frames": len(rows),
                       "window_generation_to_completion": statistics([row["completion"]-row["generation"] for row in observed]),
                       "window_accept_to_first_output": statistics([row["first_output"]-row["first_accept"] for row in started]),
                       "drained_generation_to_completion": statistics([row["completion"]-row["generation"] for row in rows if row["completion"] >= 0])})
        if source["unfinished_after_drain"]:
            raise RuntimeError("Incomplete drain; raw frame rows retain censored samples")
        for row in rows:
            if not (row["generation"] <= row["first_offer"] <= row["first_accept"] <= row["first_output"] <= row["completion"]):
                raise RuntimeError(f"Invalid frame timestamp order: {row}")
    if candidate in ("C", "B1") and total["source_starvation"]:
        raise RuntimeError("Contract or full-frame candidate had source starvation")
    result = dict(candidate=candidate, levels=levels, metadata=metadata, window=total, sources=sources,
                  comparison="separate_reference_unequal_capacity_and_pipeline" if candidate.startswith("E_") else "same_core_same_capacity",
                  capacity_beats=PORTS*(DEPTH+2)+2 if candidate.startswith("E_") else PORTS*DEPTH)
    (folder / "summary.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", choices=SCENARIOS, action="append")
    parser.add_argument("--candidate", choices=CANDIDATES, action="append")
    parser.add_argument("--seed", type=int, choices=SEEDS, action="append")
    args = parser.parse_args()
    candidates = args.candidate or CANDIDATES
    scenarios = args.scenario or SCENARIOS
    if any(candidate.startswith("E_") for candidate in candidates):
        fetch()
    BUILD.mkdir(parents=True, exist_ok=True)
    manifest_sha256 = provenance(scenarios, candidates, args.seed)
    results, cache = [], {}
    for scenario in scenarios:
        seeds = args.seed or (SEEDS if scenario in ("burst", "random") else (SEEDS[0],))
        for seed in seeds:
            data = plan(scenario, seed)
            release_path, ready_path, metadata = save_plan(data)
            metadata["manifest_sha256"] = manifest_sha256
            for candidate in candidates:
                levels = thresholds(candidate, data["gaps"])
                output = compile_candidate(candidate, levels, cache)
                folder = BUILD / f"{scenario}-seed{seed}" / candidate
                folder.mkdir(parents=True, exist_ok=True)
                arguments = {"STUDY_PLAN": release_path, "STUDY_READY": ready_path,
                             "STUDY_FRAMES": folder / "frames.csv", "STUDY_COUNTS": folder / "counts.csv"}
                transcript = command_run([tool("vvp"), str(output.relative_to(ROOT)), "+CASE=study", "+MODE=1",
                                          *(f"+{key}={value.relative_to(ROOT).as_posix()}" for key, value in arguments.items())], folder / "simulation.log")
                if "PASS " not in transcript:
                    raise RuntimeError(f"Missing primary scoreboard PASS: {folder}")
                result = summarize(folder, candidate, levels, metadata)
                results.append(result)
                print(f"PASS {scenario} seed={seed} candidate={candidate} throughput={result['window']['beat_per_cycle']:.6f}", flush=True)
    (BUILD / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    print(f"PASS pilot runs={len(results)}; results={BUILD / 'results.json'}; P99 is observed, not a bound")


if __name__ == "__main__":
    main()
