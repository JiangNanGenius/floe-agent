#!/usr/bin/env python3
"""Stage S5 workload gate for the TinyEMU Linux qualification (FLOE-SMP).

Background (why this exists).  The first S5 implementation typed the DONE
marker on a fixed host timer (@50) and then required the 2-hart run's *total
retired instructions* to be >= 1.5x the 1-hart run's total for the same
workload.  Both were method errors:

* the fixed timer made every wall time ~50 s no matter when the two dd
  workers actually finished, so the marker proved nothing about completion;
* equal guest work retires roughly equal instruction counts in a functional
  emulator -- the per-hart counters account emulated work, they do not
  measure throughput -- so the 1.5x rule failed a run whose guest really did
  use both harts (measured: vcpu=1 393.8 M vs vcpu=2 537.1 M).

This gate instead:

* requires DONE to be emitted by the *same guest shell command* that ran the
  two dd workers, after `wait` returned, with each worker's own completion
  marker preceding it (enforced in the workflow's workload script and
  re-checked here from the transcript), so completion is real;
* measures the work window inside the guest from /proc/uptime immediately
  before launching the workers and immediately after `wait`, isolating boot
  and console-delay overhead;
* keeps the equal-work contract (two dd jobs with the same count) and checks
  the transcript carried the same commanded workload;
* requires 2 harts to actually be faster (median guest work-window speedup
  over the repeats; no speedup is a real failure) and to really execute on
  two host threads with a non-empty hart 1;
* keeps the stopped-run evidence check (rc=2, transcript and stats kept) and
  the boot-pair sha256 record.

Per-hart instruction counters are still recorded as evidence, but they are
never a cross-hart success criterion.

Exit 0 only when every gate passes; on failure all problems are printed and
the JSON report is still written so the failure evidence survives.
"""

import argparse
import json
import os
import re
import statistics
import sys

DONE_MARKER = "FLOE_SMP2PERF_DONE"
T0_RE = re.compile(r"FLOE_SMP2WL_T0\s+([0-9]+(?:\.[0-9]+)?)")
T1_RE = re.compile(r"FLOE_SMP2WL_T1\s+([0-9]+(?:\.[0-9]+)?)")
W_RE = re.compile(r"FLOE_SMP2WL_W([12])\b")
HART1_MIN_INSNS = 100_000
HART0_MIN_INSNS = 100_000
HEX64_RE = re.compile(r"^[0-9a-f]{64}\s+\S")


def read_text(path):
    """Return file text, or None when the file is missing/unreadable."""
    try:
        with open(path, "r", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def parse_rc(path):
    """Parse `<anything>=<rc>` as written by the workflow (never a pipeline tail)."""
    raw = read_text(path)
    if raw is None:
        return None
    raw = raw.strip()
    if "=" not in raw:
        return raw or None
    return raw.split("=")[-1].strip()


def load_stats(path):
    samples = []
    raw = read_text(path)
    if raw is None:
        return None
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
    """Collect one run's raw facts (no gate decisions here)."""
    base = os.path.join(work_dir, "wl-vcpu%d-r%d" % (vcpu, repeat))
    run = {
        "vcpu": vcpu,
        "repeat": repeat,
        "rc": parse_rc(base + "-rc.txt"),
        "booted": False,
        "work_s": None,
        "work_t0": None,
        "work_t1": None,
        "workers": [],
        "equal_work_echoes": 0,
        "ordering_ok": False,
        "host_threads": 0,
        "hart0": 0,
        "hart1": 0,
        "wall_s": None,
        "final_event": None,
        "stats_samples": 0,
        "transcript_bytes": 0,
        "missing": [],
    }

    transcript = read_text(base + "-transcript.txt")
    if transcript is None:
        run["missing"].append("transcript")
        transcript = ""
    run["transcript_bytes"] = len(transcript)

    samples = load_stats(base + "-stats.jsonl")
    if samples is None:
        run["missing"].append("stats")
        samples = []
    run["stats_samples"] = len(samples)
    if samples:
        run["host_threads"] = max(int(s.get("host_threads", 0) or 0) for s in samples)
        run["hart0"] = max(((s.get("hart_insns") or [0, 0]) + [0, 0])[0] for s in samples)
        run["hart1"] = max(((s.get("hart_insns") or [0, 0]) + [0, 0])[1] for s in samples)
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
    if (
        run["booted"]
        and len(run["workers"]) == 2
        and run["work_t1"] is not None
    ):
        pos_w = max(transcript.rfind("FLOE_SMP2WL_W%d" % w) for w in run["workers"])
        pos_t1 = transcript.rfind("FLOE_SMP2WL_T1")
        pos_done = transcript.rfind(DONE_MARKER)
        run["ordering_ok"] = 0 <= pos_w < pos_t1 < pos_done
    return run


def evaluate(work_dir, min_speedup, max_work_s, repeats):
    """Run every gate; return the report dict (with problems/gates inside)."""
    problems = {"workload": [], "hart_evidence": [], "speedup": [], "stopped_run": [], "boot_pair": []}
    runs = []
    for vcpu in (1, 2):
        for repeat in range(1, repeats + 1):
            run = analyze_run(work_dir, vcpu, repeat)
            runs.append(run)
            tag = "vcpu=%d r%d" % (vcpu, repeat)
            if run["missing"]:
                problems["workload"].append("%s: missing %s" % (tag, ", ".join(run["missing"])))
            if run["rc"] != "0":
                problems["workload"].append(
                    "%s: host rc=%s (a real completion requires rc=0)" % (tag, run["rc"]))
            if not run["booted"]:
                problems["workload"].append(
                    "%s: %s missing - the workload did not really finish" % (tag, DONE_MARKER))
            if run["work_s"] is None:
                problems["workload"].append(
                    "%s: no guest work-window timing (FLOE_SMP2WL_T0/T1)" % tag)
            elif not 0 < run["work_s"] <= max_work_s:
                problems["workload"].append(
                    "%s: work window %.3fs outside (0, %gs]" % (tag, run["work_s"], max_work_s))
            if run["workers"] != [1, 2]:
                problems["workload"].append(
                    "%s: worker completion markers %s != [1, 2]" % (tag, run["workers"]))
            if not run["ordering_ok"]:
                problems["workload"].append(
                    "%s: guest ordering is not W1/W2 < T1 < DONE" % tag)
            if run["equal_work_echoes"] < 2:
                problems["workload"].append(
                    "%s: the equal-work command (2 x count=6000) is not in the transcript" % tag)
            if vcpu == 2:
                if run["host_threads"] != 2:
                    problems["hart_evidence"].append(
                        "%s: host_threads=%d, expected 2 (one host thread per hart)"
                        % (tag, run["host_threads"]))
                if run["hart1"] < HART1_MIN_INSNS:
                    problems["hart_evidence"].append(
                        "%s: hart 1 retired %d instructions (< %d)"
                        % (tag, run["hart1"], HART1_MIN_INSNS))
                if run["hart0"] < HART0_MIN_INSNS:
                    problems["hart_evidence"].append(
                        "%s: hart 0 retired %d instructions (< %d)"
                        % (tag, run["hart0"], HART0_MIN_INSNS))
            else:
                if run["host_threads"] != 0:
                    problems["hart_evidence"].append(
                        "%s: vcpu=1 control must stay inline (host_threads=%d)"
                        % (tag, run["host_threads"]))
                if run["hart1"] != 0:
                    problems["hart_evidence"].append(
                        "%s: vcpu=1 control retired %d instructions on hart 1"
                        % (tag, run["hart1"]))

    valid = {
        vcpu: [r for r in runs
               if r["vcpu"] == vcpu and r["booted"] and r["rc"] == "0" and r["work_s"] is not None]
        for vcpu in (1, 2)
    }
    med_work = {}
    med_wall = {}
    med_insns = {}
    for vcpu in (1, 2):
        if valid[vcpu]:
            med_work[vcpu] = round(statistics.median([r["work_s"] for r in valid[vcpu]]), 3)
            if all(r["wall_s"] is not None for r in valid[vcpu]):
                med_wall[vcpu] = round(statistics.median([r["wall_s"] for r in valid[vcpu]]), 3)
            med_insns[vcpu] = {
                "hart0": int(statistics.median([r["hart0"] for r in valid[vcpu]])),
                "hart1": int(statistics.median([r["hart1"] for r in valid[vcpu]])),
                "total": int(statistics.median([r["hart0"] + r["hart1"] for r in valid[vcpu]])),
            }
    speedup = None
    if len(valid[1]) >= repeats and len(valid[2]) >= repeats and med_work.get(2):
        speedup = round(med_work[1] / med_work[2], 3)
    if speedup is None:
        problems["speedup"].append(
            "speedup not measurable: %d/3 completed vcpu=1 runs, %d/3 completed vcpu=2 runs"
            % (len(valid[1]), len(valid[2])))
    elif speedup < min_speedup:
        problems["speedup"].append(
            "no real parallel speedup: median guest work window %.3fs (1 hart) vs %.3fs "
            "(2 harts), ratio %.3f < %.2f (dual-hart use is not proven by wall/instruction "
            "accounting alone; a missing speedup is a real failure)"
            % (med_work[1], med_work[2], speedup, min_speedup))

    stop_rc = parse_rc(os.path.join(work_dir, "stop-rc.txt"))
    stop_transcript = os.path.join(work_dir, "stop-transcript.txt")
    stop_stats = os.path.join(work_dir, "stop-stats.jsonl")
    stop_bytes = os.path.getsize(stop_transcript) if os.path.isfile(stop_transcript) else 0
    stop_samples = load_stats(stop_stats)
    stop_sample_count = len(stop_samples) if stop_samples else 0
    if stop_rc != "2":
        problems["stopped_run"].append(
            "stopped run rc=%s, expected 2 (host timeout) with evidence kept" % stop_rc)
    if stop_bytes == 0:
        problems["stopped_run"].append("stopped run transcript is empty/missing")
    if stop_sample_count == 0:
        problems["stopped_run"].append("stopped run wrote no stats sample")

    sha_path = os.path.join(work_dir, "boot-pair-sha256.txt")
    sha_raw = read_text(sha_path)
    sha_lines = [l.strip() for l in (sha_raw or "").splitlines() if l.strip()]
    valid_sha = [l for l in sha_lines if HEX64_RE.match(l)]
    if len(valid_sha) < 2:
        problems["boot_pair"].append(
            "boot-pair-sha256.txt must record 2 sha256 lines (got %d)" % len(valid_sha))

    report = {
        "tool": "floe_vm_host --vcpu + FloeVMStats, fresh CONFIG_SMP kernel",
        "method": (
            "Equal fixed work: two guest dd jobs (bs=64k count=6000 each, to /dev/null) "
            "started in one guest shell command; DONE is assembled at runtime by that same "
            "command only after `wait` returned. The work window is measured in the guest "
            "from /proc/uptime immediately before launching the workers and immediately "
            "after `wait`, so boot/startup overhead is isolated. Per-hart instruction "
            "counters are recorded as evidence only; they are not a cross-hart gate."
        ),
        "min_speedup": min_speedup,
        "max_work_s": max_work_s,
        "runs": runs,
        "median_work_s": {str(k): v for k, v in med_work.items()},
        "median_wall_s": {str(k): v for k, v in med_wall.items()},
        "median_hart_insns": {str(k): v for k, v in med_insns.items()},
        "speedup_work_1hart_over_2hart": speedup,
        "stopped_run": {
            "rc": stop_rc,
            "transcript_bytes": stop_bytes,
            "stats_samples": stop_sample_count,
        },
        "boot_pair_sha256": valid_sha or sha_lines,
        "gates": {k: (len(v) == 0) for k, v in problems.items()},
        "problems": [p for group in problems.values() for p in group],
        "note": (
            "Dual-hart success is asserted from real completion of the same bounded guest "
            "workload plus a measured guest work-window speedup, with host_threads=2 and a "
            "non-empty hart 1 as necessary conditions, never from host nproc and never from "
            "an instruction-count ratio."
        ),
    }
    return report, problems


def main(argv=None):
    parser = argparse.ArgumentParser(description="TinyEMU Stage S5 workload gate")
    parser.add_argument("--work-dir", default="work/smp2")
    parser.add_argument("--out", default=None,
                        help="report path (default: <work-dir>/smp-perf.json)")
    parser.add_argument("--min-speedup", type=float, default=1.10,
                        help="minimum median guest work-window speedup 1 hart / 2 harts")
    parser.add_argument("--max-work-s", type=float, default=180.0,
                        help="upper bound for the guest work window")
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args(argv)

    out = args.out or os.path.join(args.work_dir, "smp-perf.json")
    report, problems = evaluate(args.work_dir, args.min_speedup, args.max_work_s, args.repeats)

    parent = os.path.dirname(out)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2)
        handle.write("\n")

    for run in report["runs"]:
        print("vcpu=%d r%d: rc=%s done=%s work=%ss host_threads=%d hart0=%d hart1=%d "
              "wall=%ss final=%s"
              % (run["vcpu"], run["repeat"], run["rc"], run["booted"], run["work_s"],
                 run["host_threads"], run["hart0"], run["hart1"], run["wall_s"],
                 run["final_event"]))
    print("medians:", json.dumps({
        "work_s": report["median_work_s"],
        "wall_s": report["median_wall_s"],
        "hart_insns": report["median_hart_insns"],
        "speedup_1hart_over_2hart": report["speedup_work_1hart_over_2hart"],
    }))
    print("stopped run:", json.dumps(report["stopped_run"]))

    failures = [(cat, msgs) for cat, msgs in problems.items() if msgs]
    if failures:
        for cat, msgs in failures:
            for msg in msgs:
                print("S5 SMP WORKLOAD GATE FAILED [%s]: %s" % (cat, msg))
        return 1
    print("S5 gate: both workers really completed the same bounded workload, the guest "
          "work window shows a real 2-hart speedup (>= %.2fx), host_threads/hart1 evidence "
          "is present, and the stopped run kept its evidence." % args.min_speedup)
    return 0


if __name__ == "__main__":
    sys.exit(main())
