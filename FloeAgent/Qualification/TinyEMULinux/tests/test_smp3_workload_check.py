#!/usr/bin/env python3
"""Focused unit tests for the 1/2/3-hart equal-work gate (smp3_workload_check).

The helper is driven against synthetic work directories: a passing 1/2/3-hart
shape, a missing 3-hart speedup, an empty hart 2 at vcpu=3, wrong
host_threads, a lost DONE/worker/ordering, and a 3-hart regression against the
2-hart median. The workload template itself is also parsed: three identical
bounded dd workers, `wait` before the runtime-assembled marker, and no verbatim
marker literal in the console input line.

Run: python3 FloeAgent/Qualification/TinyEMULinux/tests/test_smp3_workload_check.py
"""

import importlib.util
import json
import os
import re
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER_PATH = os.path.join(HERE, "smp3_workload_check.py")
WORKLOAD_PATH = os.path.join(os.path.dirname(HERE), "bench", "workload-equal-work-3.txt")

spec = importlib.util.spec_from_file_location("smp3_workload_check", HELPER_PATH)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def stats_lines(vcpu, host_threads, insns, wall_s=40.0):
    return "\n".join([
        '{"event":"create","t":0.0,"vcpu_count":%d,"host_threads":%d,'
        '"hart_insns":[%s],"hart_powered_down":[0,0,0]}'
        % (vcpu, host_threads, ",".join(str(i // 2) for i in insns)),
        '{"event":"marker","t":%.3f,"vcpu_count":%d,"host_threads":%d,'
        '"hart_insns":[%s],"hart_powered_down":[0,0,0]}'
        % (wall_s, vcpu, host_threads, ",".join(str(i) for i in insns)),
    ]) + "\n"


def transcript(vcpu, work_s, drop_done=False, drop_worker=None, reorder=False):
    t0 = 100.0
    t1 = t0 + work_s
    lines = ["FLOE_SMP3WL_T0 %.3f" % t0]
    for worker in (1, 2, 3):
        if worker == drop_worker:
            continue
        lines.append("FLOE_SMP3WL_W%d" % worker)
    if reorder:
        lines.insert(1, "FLOE_SMP3WL_T1 %.3f" % t1)
    else:
        lines.append("FLOE_SMP3WL_T1 %.3f" % t1)
    lines.append("count=6000 count=6000 count=6000")  # console echo of the 3-worker line
    if not drop_done:
        lines.append("FLOE_SMP3PERF_DONE")
    return "\n".join(lines) + "\n"


def build_work_dir(root, works=(30.0, 15.0, 10.0), host_threads=(0, 2, 3),
                   insns=((300_000_000, 0, 0), (300_000_000, 140_000_000, 0),
                          (300_000_000, 140_000_000, 140_000_000)),
                   drop_done=(), drop_worker=(), reorder=(), repeats=3):
    for vcpu in (1, 2, 3):
        for repeat in range(1, repeats + 1):
            base = os.path.join(root, "wl-vcpu%d-r%d" % (vcpu, repeat))
            write(base + "-rc.txt", "0\n")
            write(base + "-transcript.txt", transcript(
                vcpu, works[vcpu - 1],
                drop_done=vcpu in drop_done,
                drop_worker=drop_worker if isinstance(drop_worker, int) else None,
                reorder=vcpu in reorder))
            write(base + "-stats.jsonl", stats_lines(vcpu, host_threads[vcpu - 1],
                                                     insns[vcpu - 1]))
    return root


class Smp3GateTests(unittest.TestCase):
    def evaluate(self, root, **kwargs):
        defaults = dict(min_speedup=1.10, max_regression=0.05,
                        max_work_s=180.0, repeats=3)
        defaults.update(kwargs)
        return checker.evaluate(root, **defaults)

    def test_passing_shape(self):
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root)
            report, problems = self.evaluate(root)
            self.assertEqual(problems["workload"], [])
            self.assertEqual(problems["hart_evidence"], [])
            self.assertEqual(problems["speedup"], [])
            self.assertEqual(report["speedup_1hart_over_3hart"], 3.0)
            self.assertEqual(report["speedup_1hart_over_2hart"], 2.0)

    def test_no_three_hart_speedup(self):
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root, works=(10.0, 10.0, 10.0))
            _, problems = self.evaluate(root)
            self.assertTrue(any("no real 3-hart speedup" in p for p in problems["speedup"]))

    def test_hart2_empty(self):
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root, insns=((300_000_000, 0, 0),
                                        (300_000_000, 140_000_000, 0),
                                        (300_000_000, 140_000_000, 0)))
            _, problems = self.evaluate(root)
            self.assertTrue(any("hart 2 retired 0 instructions" in p for p in problems["hart_evidence"]))

    def test_wrong_host_threads(self):
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root, host_threads=(0, 2, 2))
            _, problems = self.evaluate(root)
            self.assertTrue(any("host_threads=2, expected 3" in p for p in problems["hart_evidence"]))

    def test_missing_done_and_worker(self):
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root, drop_done=(1, 2, 3))
            _, problems = self.evaluate(root)
            self.assertTrue(any("FLOE_SMP3PERF_DONE missing" in p for p in problems["workload"]))
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root, drop_worker=2)
            _, problems = self.evaluate(root)
            self.assertTrue(any("worker markers" in p for p in problems["workload"]))

    def test_bad_ordering(self):
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root, reorder=(2,))
            _, problems = self.evaluate(root)
            self.assertTrue(any("ordering" in p for p in problems["workload"]))

    def test_two_hart_regression(self):
        with tempfile.TemporaryDirectory() as root:
            build_work_dir(root, works=(30.0, 2.0, 3.0))
            _, problems = self.evaluate(root)
            self.assertTrue(any("3-hart regression vs 2 harts" in p for p in problems["speedup"]))

    def test_workload_template(self):
        with open(WORKLOAD_PATH, encoding="utf-8") as handle:
            text = handle.read()
        commands = [l for l in text.splitlines() if l.startswith("@")]
        self.assertEqual(len(commands), 2)
        command = commands[-1]
        self.assertEqual(command.count("count=6000"), 3)
        self.assertIn("wait;", command)
        self.assertIn('FLOE_SMP3%s\\n" PERF_DONE', command)
        self.assertNotIn("FLOE_SMP3PERF_DONE", command)
        self.assertIn("floe-dd2.log", command)
        self.assertRegex(command, r"cut -d\" \" -f1 /proc/uptime")


if __name__ == "__main__":
    unittest.main(verbosity=2)
