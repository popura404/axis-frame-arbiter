#!/usr/bin/env python3
"""Frozen RFNoC records, real source storage/CDC, matched aggregation comparison."""
import argparse
import csv
import hashlib
from itertools import combinations
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys

from fetch_axis import fetch as fetch_axis, VENDOR as AXIS
from fetch_uhd import fetch as fetch_uhd, VENDOR as UHD, MANIFEST as UHD_MANIFEST

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "rfnoc"
REFERENCE_FILES = ("registered_context.tcl", "clock.xdc", "report_reference.tcl")
SCENARIOS = ("sparse", "contended", "backpressure", "overload", "lost_tail")
CANDIDATES = {"native": 0, "frame_fifo": 1, "rr_only": 2}


def applicable(candidate, scenario):
    # A streaming mux has no second frame-validation boundary. Do not rank it
    # under a fault contract that it does not implement.
    return candidate != "rr_only" or scenario != "lost_tail"


def win(path):
    path = Path(path).resolve()
    return (str(path) if os.name == "nt" else subprocess.check_output(
        ["wslpath", "-w", str(path)], text=True).strip()).replace("\\", "/")


def vivado_root():
    default = "E:/AMDDesignTools/2025.2/Vivado" if os.name == "nt" else "/mnt/e/AMDDesignTools/2025.2/Vivado"
    result = Path(os.environ.get("VIVADO_ROOT", default))
    if not (result / "bin" / "vivado.bat").is_file():
        raise RuntimeError("Set VIVADO_ROOT to the installed Vivado directory (Windows or WSL)")
    return result


def execute(name, arguments, folder, label=None):
    """Keep wrapper and tool logs distinct; Windows launchers can mask failures."""
    folder.mkdir(parents=True, exist_ok=True)
    label = label or name
    command = [win(vivado_root() / "bin" / (name + ".bat")), *map(str, arguments)]
    if any(any(c in item for c in '\r\n"') for item in command):
        raise RuntimeError("Invalid quote/newline in tool argument")
    launch = folder / ("launch_" + label + ".cmd")
    launch.write_text("@echo off\n" + " ".join('"' + a.replace('%', '%%') + '"' for a in command) + "\n")
    result = subprocess.run(["cmd.exe", "/c", launch.name], cwd=folder, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, errors="replace")
    log = folder / ("launcher_" + label + ".log")
    log.write_text(result.stdout)
    if result.returncode or re.search(r"(?im)^\s*(ERROR:|FATAL|Fatal:)", result.stdout):
        raise RuntimeError(f"{name} failed; see {log}\n{result.stdout[-5000:]}")
    return result.stdout


def source_hashes():
    paths = list((ROOT / "rtl").glob("*.sv")) + list((ROOT / "sim").glob("*"))
    paths += [ROOT / "scripts" / n for n in ("rfnoc_compare.py", "rfnoc_impl.tcl",
              "rfnoc_source_synth.tcl", "external_uhd.json", "external_axis.json", "fetch_uhd.py", "fetch_axis.py", "run.py",
              *REFERENCE_FILES)]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths) if p.is_file()}


def prepare_reference():
    sources = {name: (ROOT / "scripts" / name).read_bytes() for name in REFERENCE_FILES}
    folder = BUILD / "impl" / "reference"
    folder.mkdir(parents=True, exist_ok=True)
    for name, content in sources.items():
        (folder / name).write_bytes(content)
    (folder / "manifest.json").write_text(json.dumps(dict(
        source_sha256={f"scripts/{name}": hashlib.sha256(content).hexdigest()
                       for name, content in sources.items()},
        prepared_sha256={name: hashlib.sha256((folder / name).read_bytes()).hexdigest()
                         for name in REFERENCE_FILES}), indent=2)+"\n")


def compile_sim(candidates):
    folder = BUILD / "compiled"
    manifest = json.loads(UHD_MANIFEST.read_text())
    sources = [UHD / p for p in manifest["source_files"]]
    sources += list(sorted((ROOT / "rtl").glob("*.sv")))
    sources += [AXIS / "rtl" / p for p in ("axis_fifo.v", "axis_arb_mux.v", "arbiter.v", "priority_encoder.v")]
    sources += [ROOT / "sim" / p for p in ("axis_external.sv", "rfnoc_arbiter.sv", "rfnoc_source.sv", "tb_stream_arbiter.sv")]
    sources += [vivado_root().parent / "data" / "verilog" / "src" / "glbl.v"]
    includes = [ROOT] + [UHD / p for p in manifest["include_dirs"]]
    execute("xvlog", ["--sv", "--work", "work", *[a for p in includes for a in ("-i", win(p))],
                      *map(win, sources)], folder)
    for candidate in candidates:
        parameters = dict(PORTS=4, DATA_WIDTH=32, FIFO_DEPTH=16, PACKET_MODE=1,
                          MAX_FRAME_BEATS=6, KEEP_ENABLE=0, RFNOC=1, EXTERNAL=CANDIDATES[candidate])
        execute("xelab", ["--timescale", "1ns/1ps", "-L", "xpm", "-L", "unisims_ver",
                           *[a for k,v in parameters.items() for a in ("--generic_top", f"{k}={v}")],
                           "work.tb_stream_arbiter", "work.glbl", "-s", candidate], folder, "xelab_"+candidate)
        if not (folder / "xsim.dir" / candidate).is_dir():
            raise RuntimeError("Elaboration produced no snapshot")
    (folder / "inputs.json").write_text(json.dumps(source_hashes(),indent=2)+"\n")


def statistics_ps(values):
    values = sorted(values)
    if not values:
        return dict(samples=0, mean_ns=None, p99_ns=None, max_ns=None)
    return dict(samples=len(values), mean_ns=sum(values)/len(values)/1000,
                p99_ns=values[math.ceil(.99*len(values))-1]/1000, max_ns=values[-1]/1000)


def summarize(folder):
    candidate = folder.name
    if candidate not in CANDIDATES:
        raise RuntimeError(f"Unknown candidate directory: {folder}")
    complete_frame_admission = candidate != "rr_only"
    with (folder / "trace.csv").open() as f:
        rows = list(csv.DictReader(f))
    records, incoming, resets, releases, alerts, faults = {}, [[] for _ in range(4)], [], [], [], []
    for row in rows:
        t, lane, identity = (int(row[k]) for k in ("time_ps", "lane", "identity"))
        kind = row["kind"]
        key = (lane, identity)
        if kind == "GENERATE":
            if key in records: raise RuntimeError("Duplicate business event identity")
            records[key] = dict(lane=lane, identity=identity, generation=t, epoch=int(row["detail"]))
        elif kind in ("SOURCE_ACCEPT", "SOURCE_DROP", "REQUEST", "ACK", "COMPLETE"):
            if key not in records: raise RuntimeError(f"Unknown event: {row}")
            field = kind.lower()
            if field in records[key]: raise RuntimeError(f"Duplicate {kind}: {key}")
            records[key][field] = t
        elif kind == "IN":
            incoming[lane].append(row)
            if int(row["detail"]):
                words = incoming[lane]
                if len(words) != 6: raise RuntimeError("Producer length changed")
                key = (lane, int(words[2]["data"],16) | (int(words[3]["data"],16)<<32))
                r = records[key]
                r["first_accept"] = int(words[0]["time_ps"])
                r["last_word_accept"] = t
                r["input_frame_complete"] = t if int(row["last"]) else None
                if complete_frame_admission:
                    r["commit"] = r["input_frame_complete"]
                incoming[lane] = []
        elif kind == "RESET_ASSERT":
            resets.append(t)
            incoming = [[] for _ in range(4)]
        elif kind == "RESET_RELEASE": releases.append(t)
        elif kind == "ACK_SEND" and int(row["beat"]) == 0:
            records[key]["ack_send"] = t
        elif kind == "ALERT": alerts.append(dict(time_ps=t,lane=lane))
        elif kind == "FAULT": faults.append(dict(time_ps=t,lane=lane))
    # Associate first output by the separately decoded complete record timestamp.
    out = []
    for row in rows:
        if row["kind"] == "RESET_ASSERT": out=[]
        elif row["kind"] == "OUT":
            out.append(row)
            if int(row["last"]):
                if len(out)!=6: raise RuntimeError("Consumer length mismatch")
                key=(int(row["lane"]),int(out[2]["data"],16)|(int(out[3]["data"],16)<<32))
                records[key]["first_output"] = int(out[0]["time_ps"])
                out=[]
    counts = {}
    for r in records.values():
        reset = next((t for t in resets if t > r["generation"]), None)
        if "source_drop" in r and any(k in r for k in ("source_accept","request","complete","ack")):
            raise RuntimeError("Source-dropped event appeared in a later stage")
        if "ack" in r and not all(k in r for k in ("complete","ack_send")):
            raise RuntimeError("ACK without completed record and response transmission")
        if reset and any(r[k] >= reset for k in ("source_accept","source_drop","request",
                "first_accept","last_word_accept","first_output","complete","ack_send","ack") if k in r):
            raise RuntimeError("An old business identity survived the full-path reset")
        if "source_drop" in r: state="source_drop"
        elif "ack" in r: state="completed_acknowledged"
        elif "complete" in r: state="delivered_ack_lost_at_reset" if reset else "delivered_ack_pending"
        elif reset: state="reset_discarded"
        else: state="unfinished"
        r["state"]=state
        counts[state]=counts.get(state,0)+1
        if "complete" in r:
            if r.get("input_frame_complete") is None:
                raise RuntimeError("Completed output has no accepted input tail")
            if not (r["generation"] <= r["source_accept"] <= r["request"] <= r["first_accept"]
                    <= r["input_frame_complete"] <= r["complete"] and
                    r["first_accept"] <= r["first_output"] <= r["complete"]):
                raise RuntimeError(f"Invalid timestamp order: {r}")
            if complete_frame_admission and r["commit"] > r["first_output"]:
                raise RuntimeError("Frame-buffered candidate output preceded commit")
            if "ack" in r and r["ack"] < r["complete"]: raise RuntimeError("Premature ACK")
            if "ack_send" in r and r["ack_send"]-r["complete"] != 200000:
                raise RuntimeError("Consumer ACK delay differs from the registered 20 control clocks")
    if counts.get("unfinished",0) or counts.get("delivered_ack_pending",0):
        raise RuntimeError("Observation horizon did not drain; do not censor these records")
    complete=[r for r in records.values() if "complete" in r]
    metrics=[("event_to_complete","generation","complete"),
             ("event_to_ack","generation","ack"),
             ("first_accept_to_complete","first_accept","complete"),
             ("tail_accept_to_first_output","input_frame_complete","first_output")]
    if complete_frame_admission:
        metrics.append(("commit_to_first_output","commit","first_output"))
    latency={label:statistics_ps([r[b]-r[a] for r in complete if a in r and b in r])
             for label,a,b in metrics}
    healthy_reset=sum(r["lane"]!=0 and r["state"]=="reset_discarded" for r in records.values())
    recovery = None
    if faults:
        if len(faults)!=1 or len(resets)!=2 or len(releases)!=2:
            raise RuntimeError("Unexpected fault/reset count")
        fault=faults[0]["time_ps"]
        alert=next((a["time_ps"] for a in alerts if a["lane"]==0),None)
        if alert is None: raise RuntimeError("Missing bounded-frame alert")
        post=[r for r in complete if r["generation"]>releases[1]]
        if len(post)!=32 or any("ack" not in r for r in post):
            raise RuntimeError("Post-reset 4x8 events did not fully recover")
        healthy_gaps=[]
        reset_gaps=[]
        for lane in range(1,4):
            times=sorted(r["complete"] for r in complete if r["lane"]==lane)
            healthy_gaps += [b-a for a,b in zip(times,times[1:])]
            previous=[t for t in times if t<resets[1]]
            following=[t for t in times if t>releases[1]]
            reset_gaps.append(dict(lane=lane,observed_gap_ns=(min(following)-max(previous))/1000
                                   if previous and following else None))
        recovery=dict(fault_to_alert_ns=(alert-fault)/1000,
                      policy_fault_to_reset_ns=(resets[1]-fault)/1000,
                      policy_reset_duration_ns=(releases[1]-resets[1])/1000,
                      reset_release_to_first_postreset_complete_ns=(min(r["complete"] for r in post)-releases[1])/1000,
                      postreset_event_to_complete=statistics_ps([r["complete"]-r["generation"] for r in post]),
                      healthy_completed_between_fault_and_reset=sum(r["lane"]!=0 and fault<r["complete"]<resets[1] for r in complete),
                      healthy_max_intercompletion_gap_ns=max(healthy_gaps)/1000 if healthy_gaps else None,
                      healthy_completion_gaps_across_reset=reset_gaps,
                      faulted_lane_reset_release_to_first_complete_ns=(min(r["complete"] for r in post if r["lane"]==0)-releases[1])/1000,
                      healthy_reset_discarded=healthy_reset,
                      reset_discarded=counts.get("reset_discarded",0),
                      delivered_ack_lost_at_reset=counts.get("delivered_ack_lost_at_reset",0))
    summary=dict(candidate=candidate,complete_frame_admission=complete_frame_admission,
                 trace_sha256=hashlib.sha256((folder/"trace.csv").read_bytes()).hexdigest(),
                 events=len(records),outcomes=counts,latency=latency,healthy_reset_discarded=healthy_reset,
                 alerts=alerts,faults=faults,reset_assert_ps=resets,reset_release_ps=releases,recovery=recovery,
                 per_lane=[dict(lane=lane,events=sum(r["lane"]==lane for r in records.values()),
                     completed=sum(r["lane"]==lane for r in complete),
                     event_to_complete=statistics_ps([r["complete"]-r["generation"] for r in complete if r["lane"]==lane])) for lane in range(4)],
                 stage="reference_simulation_not_hardware_traffic",record_bytes=24,
                 records=sorted(records.values(),key=lambda r:(r["lane"],r["generation"])))
    (folder / "summary.json").write_text(json.dumps(summary,indent=2)+"\n")
    return summary


def compare_runs(candidates, scenarios, phase):
    comparisons=[]
    for scenario in scenarios:
        names=[candidate for candidate in candidates if applicable(candidate,scenario)]
        if not names:
            continue
        folders=[BUILD/"runs"/f"{scenario}-phase{phase}"/candidate for candidate in names]
        if not all((f/"trace.csv").is_file() for f in folders):
            raise RuntimeError(f"Missing requested comparison trace: {scenario}, phase {phase}")
        summaries=[summarize(f) for f in folders]
        records=[{(r["lane"],r["identity"]):r for r in s["records"]} for s in summaries]
        schedule=lambda rs: sorted((k,r["generation"],r["epoch"]) for k,r in rs.items())
        if any(schedule(records[0])!=schedule(rs) for rs in records[1:]):
            raise RuntimeError(f"Candidates received different external event schedules: {scenario}")
        for field in ("reset_assert_ps","reset_release_ps"):
            if any(s[field]!=summaries[0][field] for s in summaries[1:]):
                raise RuntimeError(f"Candidates received different reset schedules: {scenario}")
        delivered=[{k for k,r in rs.items() if "complete" in r} for rs in records]
        common_to_all=set.intersection(*delivered)
        pairs=[]
        for left,right in combinations(range(len(names)),2):
            paired=sorted(delivered[left]&delivered[right])
            delta=[records[left][k]["complete"]-records[right][k]["complete"] for k in paired]
            pairs.append(dict(left=names[left],right=names[right],common_completed=len(paired),
                left_only_completed=len(delivered[left]-delivered[right]),
                right_only_completed=len(delivered[right]-delivered[left]),
                paired_left_minus_right_mean_ns=sum(delta)/len(delta)/1000 if delta else None,
                left_earlier=sum(d<0 for d in delta),ties=sum(d==0 for d in delta),left_later=sum(d>0 for d in delta)))
        comparisons.append(dict(scenario=scenario,phase_ps=phase,identical_business_event_schedule=True,
            generated=len(records[0]),candidates={name:{k:s[k] for k in
                ("trace_sha256","outcomes","latency","recovery")} for name,s in zip(names,summaries)},
            common_to_all_completed=len(common_to_all),
            common_to_all_event_to_complete={name:statistics_ps([rs[k]["complete"]-rs[k]["generation"]
                for k in common_to_all]) for name,rs in zip(names,records)},pairs=pairs))
    (BUILD/f"comparison-phase{phase}.json").write_text(json.dumps(comparisons,indent=2)+"\n")
    return comparisons


def simulations(candidates, scenarios, phase):
    compile_sim(candidates)
    folder=BUILD/"compiled"
    run_tcl=folder/"run.tcl"
    run_tcl.write_text("run all\nquit\n")
    for scenario in scenarios:
        for candidate in candidates:
            if not applicable(candidate,scenario):
                continue
            output=BUILD/"runs"/f"{scenario}-phase{phase}"/candidate
            output.mkdir(parents=True,exist_ok=True)
            trace=output/"trace.csv"
            trace.unlink(missing_ok=True)
            arguments=[candidate,"-tclbatch",win(run_tcl)]
            for arg in ["CASE=rfnoc","MODE=1",f"RF_SCENARIO={scenario}",f"RADIO_PHASE_PS={phase}",f"RF_TRACE={win(trace)}"]:
                arguments += ["-testplusarg",arg]
            text=execute("xsim",arguments,folder,"xsim_"+scenario+"_"+candidate+f"_{phase}")
            (output/"simulation.log").write_text(text)
            if "RFNOC_PASS" not in text or "PASS stream" not in text or not trace.is_file():
                raise RuntimeError(f"Simulation missing PASS/evidence: {output}\n{text[-3000:]}")
            (output/"inputs.json").write_text(json.dumps(dict(candidate=candidate,scenario=scenario,
                phase_ps=phase,source_sha256=source_hashes()),indent=2)+"\n")
            result=summarize(output)
            print(candidate,scenario,result["outcomes"],result["latency"]["event_to_complete"],flush=True)
    compare_runs(candidates,scenarios,phase)


def implement(candidates):
    prepare_reference()
    for candidate in candidates:
        external=CANDIDATES[candidate]
        folder=BUILD/"impl"/f"p4-w32-d16-packet-m6-keep0-external{external}"
        execute("vivado",["-mode","batch","-notrace","-source",win(ROOT/"scripts/rfnoc_impl.tcl"),
                          "-tclargs",external],folder)
        if "Implementation status: PASS" not in (folder/"result.txt").read_text():
            raise RuntimeError(f"Implementation failed: {folder}")


def source_synthesis():
    folder=BUILD/"source-synth"
    folder.mkdir(parents=True,exist_ok=True)
    manifest=json.loads(UHD_MANIFEST.read_text())
    generated=folder/"sources.tcl"
    def tcl_list(paths):
        values=[win(p) for p in paths]
        if any(any(c in v for c in '{}\r\n') for v in values):
            raise RuntimeError("Unsupported character in Tcl path")
        return "[list " + " ".join("{"+v+"}" for v in values) + "]"
    generated.write_text("set uhd_sources "+tcl_list([UHD/p for p in manifest["source_files"]])+"\n"+
                         "set uhd_include_dirs "+tcl_list([UHD/p for p in manifest["include_dirs"]])+"\n")
    execute("vivado",["-mode","batch","-notrace","-source",win(ROOT/"scripts/rfnoc_source_synth.tcl"),
                      "-tclargs",win(folder),win(generated)],folder)
    if "status=SYNTHESIS_COMPLETE" not in (folder/"result.txt").read_text():
        raise RuntimeError("Common source synthesis did not finish")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action",choices=("sim","impl","source","prepare","analyze"))
    parser.add_argument("--candidate",choices=CANDIDATES,action="append")
    parser.add_argument("--scenario",choices=SCENARIOS,action="append")
    parser.add_argument("--phase-ps",type=int,choices=(0,2500),default=0)
    args=parser.parse_args()
    if args.action != "prepare":
        fetch_axis();fetch_uhd()
    BUILD.mkdir(parents=True,exist_ok=True)
    candidates=args.candidate or list(CANDIDATES)
    scenarios=args.scenario or SCENARIOS
    if args.action in ("sim","analyze") and not any(applicable(c,s) for c in candidates for s in scenarios):
        parser.error("rr_only has no lost_tail protection contract; select a legal-traffic scenario")
    plan=dict(schema=2,candidates=candidates,scenarios=list(scenarios),phase_ps=args.phase_ps,
              cases=[dict(candidate=c,scenario=s) for c in candidates for s in scenarios if applicable(c,s)],
              control_mhz=100,radio_mhz=80,ack_model_delay_control_cycles=20,
              fixed_observation_control_cycles=12000,source_sha256=source_hashes(),
              lost_tail_policy="third lane0 record TLAST removed after common CDC and terminal gate; all-path reset at loop cycle400 for10cycles; READY low320..399",
              capacity="native64,frame_fifo74,rr_only6 aggregate beat slots; common source/CDC/gate retained; not equal total capacity",
              evidence="simulation and aggregation reference P&R only; no full-system STA or board measurements",
              python=sys.version)
    (BUILD/f"plan-{args.action}-phase{args.phase_ps}.json").write_text(json.dumps(plan,indent=2)+"\n")
    if args.action=="sim": simulations(candidates,scenarios,args.phase_ps)
    elif args.action=="impl": implement(candidates)
    elif args.action=="source": source_synthesis()
    elif args.action=="analyze": compare_runs(candidates,scenarios,args.phase_ps)
    else: prepare_reference()


if __name__=="__main__":
    main()
