#!/usr/bin/env python3
"""Exhaust a single-frame inventory model; this is not a proof of the RTL."""
import argparse
from collections import deque
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LENGTH = 16
GAPS = (1, 2, 4, 8)


def explore(threshold, gap, depth):
    """States are (accepted current-frame beats, consumed beats, missed opportunities).

    States are sampled just AFTER an edge. Reading on the next edge uses this
    occupancy, so a simultaneous arrival cannot rescue an empty read. Every
    initial inventory from threshold through LENGTH and every contract phase
    is included. Later frames are unnecessary after this frame is complete.
    """
    initial = [(accepted, 0, phase)
               for accepted in range(threshold, LENGTH + 1)
               for phase in (range(gap) if accepted < LENGTH else (0,))]
    parents = dict.fromkeys(initial)
    queue = deque(initial)
    transitions = 0
    completions = 0
    stall_self_loops = 0
    while queue:
        state = queue.popleft()
        accepted, consumed, phase = state
        occupancy = accepted - consumed
        if consumed == LENGTH:
            completions += 1
            continue
        if occupancy == 0:
            trace = []
            cursor = state
            while parents[cursor] is not None:
                previous, event = parents[cursor]
                trace.append(event)
                cursor = previous
            trace.reverse()
            return {
                "safe": False, "states_seen": len(parents),
                "initial": dict(zip(("accepted", "consumed", "misses"), cursor)),
                "first_empty_after_edge": len(trace),
                "first_blocked_read_edge": len(trace) + 1,
                "empty_state": {"accepted": accepted, "consumed": consumed,
                                "misses": phase},
                "trace": trace,
            }
        input_ready = occupancy < depth
        # Ordered input cannot contain later frames before the current tail.
        assert accepted == LENGTH or input_ready
        if accepted == LENGTH:
            arrivals = (0,)
        elif not input_ready:
            arrivals = (0,)
        else:
            arrivals = (0, 1) if phase < gap - 1 else (1,)
        for output_ready in (0, 1):
            for push in arrivals:
                pop = int(output_ready and occupancy > 0)
                next_accepted = accepted + push
                if next_accepted == LENGTH or push:
                    next_phase = 0
                else:
                    next_phase = phase + int(input_ready)
                next_state = (next_accepted, consumed + pop, next_phase)
                transitions += 1
                if next_state == state and not output_ready:
                    stall_self_loops += 1
                if next_state not in parents:
                    parents[next_state] = (state, {
                        "occupancy_before": occupancy,
                        "input_ready": int(input_ready), "push": push,
                        "output_ready": output_ready, "pop": pop,
                        "occupancy_after": next_accepted - consumed - pop,
                    })
                    queue.append(next_state)
    assert completions > 0, "No completion is reachable: vacuous model"
    assert stall_self_loops > 0, "Persistent downstream stalls were not explored"
    return {"safe": True, "states_seen": len(parents),
            "transitions": transitions, "completion_states": completions,
            "stall_self_loops": stall_self_loops}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "build" / "admission" / "model.json")
    args = parser.parse_args()
    results = []
    for depth in (16, 64):
        for gap in GAPS:
            threshold = LENGTH - (LENGTH - 1) // gap
            safe = explore(threshold, gap, depth)
            assert safe["safe"], (depth, gap, threshold, safe)
            if threshold == 1:
                lower = {"safe": False, "reason": "H=0 has no first beat; admission is invalid"}
            else:
                lower = explore(threshold - 1, gap, depth)
                assert not lower["safe"], (depth, gap, threshold, lower)
                assert lower["first_blocked_read_edge"] == LENGTH
            results.append({"depth": depth, "gap": gap, "threshold": threshold,
                            "at_threshold": safe, "one_below": lower})
            print(f"MODEL_PASS L={LENGTH} D={depth} G={gap} H={threshold} "
                  f"states={safe['states_seen']} H_minus_1=EXPECTED_UNSAFE")
    report = {
        "evidence": "exhaustive finite-state abstract inventory model; NOT RTL formal proof",
        "frame_length": LENGTH,
        "scope": "one newly granted frame; ordered, fixed-length legal input; D>=L; "
                 "all initial inventories H..L, all contract phases, arbitrary output ready; "
                 "q0>L is already a complete frame and follows the separate inventory argument",
        "limitations": "does not check RTL scheduling, RAM contents, AXIS stability, reset, "
                       "multiple streams, or fairness; no unconditional cycle liveness under stalls",
        "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Model report: {args.output}")


if __name__ == "__main__":
    main()
