#!/usr/bin/env python3
"""Stage S5 extension — the 1/2/3-hart equal-work workload gate.

This is the three-hart companion of `smp_workload_check.py` (which stays the
frozen 1-vs-2 contract for the cloud workflow). It runs the SAME equal fixed
work on every hart count: three identical `dd if=/dev/zero of=/dev/null
bs=64k count=6000` workers started in one guest shell command
(`bench/workload-equal-work-3.txt`), DONE assembled at runtime only after
`wait`, and the work window measured in the guest from `/proc/uptime` so
boot/console overhead is excluded.

Gates (per the round's contract):
  * every run really finished the same bounded work (rc=0, DONE, W1..W3
    ordering before T1 before DONE, three identical count=6000 commands);
  * vcpu=3 spawns three real hart host threads (`host_threads=3`) and every
    hart retires instructions (hart 2 non-empty is required for vcpu=3 and
    must stay 0 for vcpu<=2; hart 1 likewise for vcpu>=2);
  * the median guest work window shows real parallelism
    (median(1 hart)/median(3 harts) >= --min-speedup, default 1.10) and the
    3-hart median does not regress beyond --max-regression-vs-2 (default
    5%) against the 2-hart median;
  * per-hart instruction counters are evidence only, never a success ratio.

Exit 0 only when every gate passes; the JSON report is written either way.
"""

import argparse
import json
import os
import re
import statistics
import sys

DONE_MARKER = "FLOE_SMP3PERF_DONE"
T0_RE = re.compile(r"FLOE_SMP3WL_T0\s+([0-9]+(?:\.[0-9]+)?)")
T1_RE = re.compile(r"FLOE_SMP3WL_T1\s+([0-9]+(?:\.[0-9]+)?)")
W_RE = re.compile(r"FLOE_SMP3WL_W([123])\b")
HART_MIN_INSNS = 100_000


def read_text(path):
    try:
        with open(path, "r", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def parse_rc(path):
    raw = read_text(path)
    if raw is None:
        return None
    raw = raw.strip()
    if "=" not in raw:
        return raw or None
    return raw.split("=")[-1].strip()


def load_stats(path):
    raw = read_text(path)
    if raw is None:
        return None
    samples = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            samples.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return samples


def analyze_run(work_dir, vcpu, repeat):
    base = os.path.join(work_dir, "wl-vcpu%d-r%d" % (vcpu, repeat))
    run = {
        "vcpu": vcpu, "repeat": repeat, "rc": parse_rc(base + "-rc.txt"),
        "booted": False, "work_s": None, "work_t0": None, "work_t1": None,
        "workers": [], "equal_work_echoes": 0, "ordering_ok": False,
        "host_threads": 0, "hart_insns": [0, 0, 0], "wall_s": None,
        "final_event": None, "stats_samples": 0, "missing": [],
    }
    transcript = read_text(base + "-transcript.txt")
    if transcript is None:
        run["missing"].append("transcript")
        transcript = ""
    samples = load_stats(base + "-stats.jsonl")
    if samples is None:
        run["missing"].append("stats")
        samples = []
    run["stats_samples"] = len(samples)
    if samples:
        run["host_threads"] = max(int(s.get("host_threads", 0) or 0) for s in samples)
        insns = [0, 0, 0]
        for s in samples:
            per = (s.get("hart_insns") or [0, 0, 0]) + [0, 0, 0]
            for i in range(3):
                insns[i] = max(insns[i], int(per[i]))
        run["hart_insns"] = insns
        final = [s for s in samples if s.get("event") in ("marker", "poweroff", "timeout")]
        last = final[-1] if final else samples[-1]
        run["final_event"] = last.get("event")
        run["wall_s"] = last.get("t")
    if run["rc"] is None:
        run["missing"].append("rc")
    run["booted"] = DONE_MARKER in transcript
    t0_hits = T0_RE.findall(transcript)
    t1_hits = T1_RE.findall(transcript)
    if t0_hits and t1_hits:
        run["work_t0"] = float(t0_hits[-1])
        run["work_t1"] = float(t1_hits[-1])
        run["work_s"] = round(run["work_t1"] - run["work_t0"], 3)
    run["workers"] = sorted({int(w) for w in W_RE.findall(transcript)})
    run["equal_work_echoes"] = len(re.findall(r"count=6000\b", transcript))
    if run["booted"] and run["work_t1"] is not None:
        pos_w = max(transcript.rfind("FLOE_SMP3WL_W%d" % w) for w in (1, 2, 3))
        pos_t1 = transcript.rfind("FLOE_SMP3WL_T1")
        pos_done = transcript.rfind(DONE_MARKER)
        run["ordering_ok"] = 0 <= pos_w < pos_t1 < pos_done
    return run


def evaluate(work_dir, min_speedup, max_regression, max_work_s, repeats):
    problems = {"workload": [], "hart_evidence": [], "speedup": []}
    runs = []
    for vcpu in (1, 2, 3):
        for repeat in range(1, repeats + 1):
            run = analyze_run(work_dir, vcpu, repeat)
            runs.append(run)
            tag = "vcpu=%d r%d" % (vcpu, repeat)
            if run["missing"]:
                problems["workload"].append("%s: missing %s" % (tag, ", ".join(run["missing"])))
            if run["rc"] != "0":
                problems["workload"].append("%s: host rc=%s (real completion requires rc=0)" % (tag, run["rc"]))
            if not run["booted"]:
                problems["workload"].append("%s: %s missing - the workload did not finish" % (tag, DONE_MARKER))
            if run["work_s"] is None:
                problems["workload"].append("%s: no guest work-window timing" % tag)
            elif not 0 < run["work_s"] <= max_work_s:
                problems["workload"].append("%s: work window %.3fs outside (0, %gs]" % (tag, run["work_s"], max_work_s))
            if run["workers"] != [1, 2, 3]:
                problems["workload"].append("%s: worker markers %s != [1, 2, 3]" % (tag, run["workers"]))
            if not run["ordering_ok"]:
                problems["workload"].append("%s: guest ordering is not W1..W3 < T1 < DONE" % tag)
            if run["equal_work_echoes"] < 3:
                problems["workload"].append("%s: the equal-work command (3 x count=6000) is not in the transcript" % tag)
            harts = run["hart_insns"]
            if vcpu == 1:
                if run["host_threads"] != 0:
                    problems["hart_evidence"].append("%s: vcpu=1 control must stay inline (host_threads=%d)" % (tag, run["host_threads"]))
            else:
                if run["host_threads"] != vcpu:
                    problems["hart_evidence"].append("%s: host_threads=%d, expected %d" % (tag, run["host_threads"], vcpu))
            for i in range(vcpu):
                if harts[i] < HART_MIN_INSNS:
                    problems["hart_evidence"].append("%s: hart %d retired %d instructions (< %d)" % (tag, i, harts[i], HART_MIN_INSNS))
            for i in range(vcpu, 3):
                if harts[i] != 0:
                    problems["hart_evidence"].append("%s: hart %d must stay absent (retired %d)" % (tag, i, harts[i]))

    valid = {v: [r for r in runs if r["vcpu"] == v and r["booted"] and r["rc"] == "0" and r["work_s"] is not None]
             for v in (1, 2, 3)}
    med_work = {v: round(statistics.median([r["work_s"] for r in valid[v]]), 3) for v in (1, 2, 3) if valid[v]}
    speedup_1_3 = None
    speedup_1_2 = None
    if len(valid[1]) >= repeats and len(valid[3]) >= repeats and med_work.get(3):
        speedup_1_3 = round(med_work[1] / med_work[3], 3)
    if len(valid[1]) >= repeats and len(valid[2]) >= repeats and med_work.get(2):
        speedup_1_2 = round(med_work[1] / med_work[2], 3)
    if speedup_1_3 is None:
        problems["speedup"].append("speedup not measurable: %d/3 vcpu=1 runs, %d/3 vcpu=3 runs completed"
                                   % (len(valid[1]), len(valid[3])))
    elif speedup_1_3 < min_speedup:
        problems["speedup"].append("no real 3-hart speedup: median work %.3fs (1 hart) vs %.3fs (3 harts), ratio %.3f < %.2f"
                                   % (med_work[1], med_work[3], speedup_1_3, min_speedup))
    if med_work.get(2) and med_work.get(3) and med_work[3] > med_work[2] * (1.0 + max_regression):
        problems["speedup"].append("3-hart regression vs 2 harts: median work %.3fs vs %.3fs (%.1f%% > %.1f%% allowed)"
                                   % (med_work[3], med_work[2],
                                      (med_work[3] / med_work[2] - 1.0) * 100.0, max_regression * 100.0))

    report = {
        "tool": "floe_vm_host --vcpu + FloeVMStats (1/2/3 harts)",
        "method": "Equal fixed work: three guest dd jobs (bs=64k count=6000 each) in one guest "
                  "shell command; DONE assembled at runtime after `wait`; work window measured "
                  "in the guest from /proc/uptime. Per-hart instruction counters are evidence "
                  "only, never a cross-hart success criterion.",
        "min_speedup": min_speedup,
        "max_regression_vs_2hart": max_regression,
        "runs": runs,
        "median_work_s": {str(k): v for k, v in med_work.items()},
        "speedup_1hart_over_3hart": speedup_1_3,
        "speedup_1hart_over_2hart": speedup_1_2,
        "gates": {k: (len(v) == 0) for k, v in problems.items()},
        "problems": [p for group in problems.values() for p in group],
    }
    return report, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description="TinyEMU 1/2/3-hart equal-work gate")
    parser.add_argument("--work-dir", required=True)
    parser.add_argument("--out", default=None)
    parser.add_argument("--min-speedup", type=float, default=1.10)
    parser.add_argument("--max-regression-vs-2", type=float, default=0.05)
    parser.add_argument("--max-work-s", type=float, default=180.0)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args(argv)

    out = args.out or os.path.join(args.work_dir, "smp3-perf.json")
    report, problems = evaluate(args.work_dir, args.min_speedup,
                                args.max_regression_vs_2, args.max_work_s,
                                args.repeats)
    parent = os.path.dirname(out)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")

    for run in report["runs"]:
        print("vcpu=%d r%d: rc=%s done=%s work=%ss host_threads=%d harts=%s wall=%ss final=%s"
              % (run["vcpu"], run["repeat"], run["rc"], run["booted"], run["work_s"],
                 run["host_threads"], run["hart_insns"], run["wall_s"], run["final_event"]))
    print("medians:", json.dumps({
        "work_s": report["median_work_s"],
        "speedup_1_over_3": report["speedup_1hart_over_3hart"],
        "speedup_1_over_2": report["speedup_1hart_over_2hart"],
    }))
    failures = [(cat, msgs) for cat, msgs in problems.items() if msgs]
    if failures:
        for cat, msgs in failures:
            for msg in msgs:
                print("SMP3 WORKLOAD GATE FAILED [%s]: %s" % (cat, msg))
        return 1
    print("SMP3 gate: 1/2/3-hart equal work completed with real per-hart execution and a "
          "measured 3-hart work-window speedup (>= %.2fx) without a 2-hart regression." % args.min_speedup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
