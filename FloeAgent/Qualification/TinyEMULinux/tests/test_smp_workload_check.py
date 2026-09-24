#!/usr/bin/env python3
"""Focused static/parse tests for the Stage S5 workload correction.

Two layers:

1. The S5 gate helper (``smp_workload_check.py``) is exercised against
   synthetic work directories: a true-completion equal-work pass, the exact
   false-failure shape from cloud run 36004192418 (2-hart total retired
   instructions below 1.5x the 1-hart total but a real speedup), and the
   individual failure modes (missing DONE, missing worker marker, no speedup,
   empty hart 1, wrong host_threads, fixed-timer DONE, out-of-bound work,
   lost stopped-run evidence, bad boot-pair record).

2. The workflow YAML is parsed as the runner would execute it: the S5 step's
   workload script must have no fixed-timer DONE, no verbatim marker string,
   a real ``wait`` before the runtime-assembled marker, bounded equal work,
   and the analysis must not contain the retired 1.5x instruction rule.

Run: ``python3 FloeAgent/Qualification/TinyEMULinux/tests/test_smp_workload_check.py``
"""

import contextlib
import importlib.util
import io
import os
import re
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER_PATH = os.path.join(os.path.dirname(HERE), "smp_workload_check.py")
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
WORKFLOW_PATH = os.path.join(REPO_ROOT, ".github", "workflows",
                             "tinyemu-linux-qualification.yml")

spec = importlib.util.spec_from_file_location("smp_workload_check", HELPER_PATH)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

HEX_A = "a" * 64
HEX_B = "b" * 64

ECHO_LINE = (
    "@18 sh -c 't0=$(cut -d\" \" -f1 /proc/uptime); printf \"FLOE_SMP2WL_T0 %s\\n\" "
    "\"$t0\"; (dd if=/dev/zero of=/dev/null bs=64k count=6000 2>/tmp/floe-dd0.log; "
    "printf \"FLOE_SMP2WL_W%s\\n\" 1) & (dd if=/dev/zero of=/dev/null bs=64k "
    "count=6000 2>/tmp/floe-dd1.log; printf \"FLOE_SMP2WL_W%s\\n\" 2) & wait; "
    "t1=$(cut -d\" \" -f1 /proc/uptime); printf \"FLOE_SMP2WL_T1 %s\\n\" \"$t1\"; "
    "cat /tmp/floe-dd0.log /tmp/floe-dd1.log; printf \"FLOE_SMP2%s\\n\" PERF_DONE'"
)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def stats_lines(vcpu, host_threads, hart0, hart1, wall_s=40.0):
    return "\n".join([
        '{"event":"create","t":0.0,"vcpu_count":%d,"host_threads":%d,'
        '"hart_insns":[0,0],"hart_powered_down":[0,0]}' % (vcpu, host_threads),
        '{"event":"sample","t":1.0,"vcpu_count":%d,"host_threads":%d,'
        '"hart_insns":[%d,%d],"hart_powered_down":[0,0]}'
        % (vcpu, host_threads, hart0 // 2, hart1 // 2),
        '{"event":"marker","t":%.3f,"vcpu_count":%d,"host_threads":%d,'
        '"hart_insns":[%d,%d],"hart_powered_down":[0,0]}'
        % (wall_s, vcpu, host_threads, hart0, hart1),
        '{"event":"end","rc":0}',
    ]) + "\n"


def build_work_dir(root, v1_work=30.0, v2_work=15.0,
                   v1_insns=(393880671, 0), v2_insns=(393000000, 143000000),
                   v2_host_threads=2, drop_done=(), drop_t1=(), drop_worker2=(),
                   rc_override=None, reorder=(), equal_work_echoes=(), stop_rc="2",
                   stop_transcript="boot log\n", stop_stats=True, sha_lines=2):
    """Create a synthetic work/smp2 tree with a passing shape by default."""
    rc_override = rc_override or {}
    for vcpu, work, insns, threads in (
        (1, v1_work, v1_insns, 0),
        (2, v2_work, v2_insns, v2_host_threads),
    ):
        for repeat in (1, 2, 3):
            base = os.path.join(root, "wl-vcpu%d-r%d" % (vcpu, repeat))
            rc = rc_override.get((vcpu, repeat), "0")
            write(base + "-rc.txt", "wl_vcpu%d_r%d_rc=%s\n" % (vcpu, repeat, rc))
            t0 = 20.0
            t1 = t0 + work
            lines = ["[boot] console ready", ECHO_LINE, "FLOE_SMP2WL_T0 %.2f" % t0]
            if (vcpu, repeat) in reorder:
                # deliberately wrong: end recorded before the workers report
                lines += ["FLOE_SMP2WL_T1 %.2f" % t1]
            if (vcpu, repeat) not in drop_worker2:
                lines += ["FLOE_SMP2WL_W1", "FLOE_SMP2WL_W2"]
            if (vcpu, repeat) not in reorder and (vcpu, repeat) not in drop_t1:
                lines += ["FLOE_SMP2WL_T1 %.2f" % t1]
            lines += ["6000+0 records in", "6000+0 records out",
                      "6000+0 records in", "6000+0 records out"]
            if equal_work_echoes:
                lines = [ECHO_LINE] * equal_work_echoes + lines[1:]
            if (vcpu, repeat) not in drop_done:
                lines.append("FLOE_SMP2PERF_DONE")
            write(base + "-transcript.txt", "\n".join(lines) + "\n")
            write(base + "-stats.jsonl",
                  stats_lines(vcpu, threads, insns[0], insns[1]) if vcpu == 2
                  else stats_lines(vcpu, 0, insns[0], insns[1]))
    write(os.path.join(root, "stop-rc.txt"), "stop_run_rc=%s\n" % stop_rc)
    write(os.path.join(root, "stop-transcript.txt"), stop_transcript)
    write(os.path.join(root, "stop-stats.jsonl"),
          stats_lines(2, 2, 100, 100, wall_s=8.0) if stop_stats else "")
    sha = "".join("%s  %s\n" % (h, p) for h, p in (
        (HEX_A, "work/smp/boot/bbl64.bin"), (HEX_B, "work/smp/boot/kernel-riscv64.bin"),
    )[:max(sha_lines, 0)])
    write(os.path.join(root, "boot-pair-sha256.txt"), sha)
    return root


def run_main(root, *extra):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = checker.main(["--work-dir", root, "--out", os.path.join(root, "smp-perf.json"),
                           *extra])
    return rc, buf.getvalue()


class CheckerPassTest(unittest.TestCase):
    def test_true_completion_equal_work_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp)
            rc, out = run_main(tmp)
            self.assertEqual(rc, 0, out)
            self.assertIn("speedup", out)
            import json
            with open(os.path.join(tmp, "smp-perf.json")) as handle:
                report = json.load(handle)
            self.assertEqual(report["problems"], [])
            self.assertTrue(all(report["gates"].values()))
            self.assertAlmostEqual(report["speedup_work_1hart_over_2hart"], 2.0, places=2)

    def test_insn_ratio_15x_is_not_a_gate(self):
        # Exact false-failure shape of cloud run 36004192418: equal work, the
        # 2-hart total (536 M) is below 1.5x the 1-hart total (393.8 M), but a
        # real measured speedup exists. This must PASS now.
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, v1_insns=(393880671, 0),
                           v2_insns=(393000000, 143000000))
            total1 = 393880671
            total2 = 393000000 + 143000000
            self.assertLess(total2, 1.5 * total1)
            rc, out = run_main(tmp)
            self.assertEqual(rc, 0, out)
            self.assertNotIn("GATE FAILED", out)

    def test_identical_work_command_in_both_configs(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp)
            for vcpu in (1, 2):
                for repeat in (1, 2, 3):
                    path = os.path.join(tmp, "wl-vcpu%d-r%d-transcript.txt" % (vcpu, repeat))
                    with open(path) as handle:
                        text = handle.read()
                    self.assertEqual(text.count("count=6000"), 2, path)


class CheckerFailureTest(unittest.TestCase):
    def assert_fails(self, out, category=None):
        self.assertIn("S5 SMP WORKLOAD GATE FAILED", out)
        if category:
            self.assertIn("[%s]" % category, out)

    def test_missing_done_marker_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, drop_done={(2, 2)})
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "workload")
            self.assertIn("did not really finish", out)

    def test_missing_worker_marker_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, drop_worker2={(1, 1)})
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "workload")
            self.assertIn("worker completion markers", out)

    def test_missing_timing_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, drop_t1={(2, 3)})
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "workload")
            self.assertIn("no guest work-window timing", out)

    def test_no_speedup_is_a_real_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, v2_work=30.0)  # 2 harts no faster than 1
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "speedup")
            self.assertIn("no real parallel speedup", out)

    def test_hart1_empty_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, v2_insns=(393880671, 0))
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "hart_evidence")
            self.assertIn("hart 1 retired 0", out)

    def test_two_host_threads_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, v2_host_threads=1)
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "hart_evidence")
            self.assertIn("host_threads=1", out)

    def test_vcpu1_control_must_stay_inline(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, v1_insns=(393880671, 100000))
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "hart_evidence")
            self.assertIn("vcpu=1 control", out)

    def test_host_rc_nonzero_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, rc_override={(2, 1): "2"})
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "workload")
            self.assertIn("host rc=2", out)

    def test_ordering_wrong_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, reorder={(1, 2)})
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "workload")
            self.assertIn("ordering", out)

    def test_work_window_over_bound_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, v1_work=200.0, v2_work=100.0)
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "workload")
            self.assertIn("outside (0, 180", out)

    def test_stopped_run_evidence_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, stop_rc="0")
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "stopped_run")
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, stop_transcript="")
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "stopped_run")
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, stop_stats=False)
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "stopped_run")

    def test_boot_pair_record_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, sha_lines=0)
            rc, out = run_main(tmp)
            self.assertEqual(rc, 1)
            self.assert_fails(out, "boot_pair")

    def test_report_written_even_on_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            build_work_dir(tmp, drop_done={(1, 1)})
            rc, _ = run_main(tmp)
            self.assertEqual(rc, 1)
            import json
            with open(os.path.join(tmp, "smp-perf.json")) as handle:
                report = json.load(handle)
            self.assertTrue(report["problems"])
            self.assertFalse(all(report["gates"].values()))


class WorkflowStaticTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(WORKFLOW_PATH, encoding="utf-8") as handle:
            cls.workflow_text = handle.read()
        cls.s5_run = None
        lines = cls.workflow_text.splitlines()
        for i, line in enumerate(lines):
            if line.strip() == "- name: Stage S5 — repeated equal-work SMP workload + stopped-run save check":
                start = i
                indent = len(line) - len(line.lstrip())
                body = []
                for line2 in lines[i + 1:]:
                    if line2.strip() and (len(line2) - len(line2.lstrip())) <= indent:
                        break
                    body.append(line2)
                cls.s5_run = "\n".join(body)
                break
        assert cls.s5_run is not None, "S5 step not found"

    def workload_lines(self):
        """The guest console script exactly as the step writes it."""
        lines = self.s5_run.splitlines()
        out, inside = [], False
        for line in lines:
            if "cat > work/smp2/workload.txt <<'EOF'" in line:
                inside = True
                continue
            if inside and line.strip() == "EOF":
                break
            if inside:
                out.append(line.strip())
        assert out, "workload heredoc not found"
        return out

    def test_no_fixed_timer_done(self):
        # the old @50 unconditional printf is gone: no standalone @N printf
        for line in self.workload_lines():
            self.assertFalse(re.match(r"^@\d+\s+printf\b", line),
                             "fixed-timer printf marker line: %r" % line)
        self.assertNotIn("@50", self.s5_run)

    def test_done_is_assembled_after_real_wait(self):
        marker_lines = [l for l in self.workload_lines()
                        if "PERF_DONE" in l or "wait" in l]
        self.assertTrue(marker_lines)
        joined = "\n".join(marker_lines)
        self.assertIn("wait", joined)
        # same guest command: wait ... then the runtime-assembled marker
        self.assertRegex(joined, r"\bwait;.*PERF_DONE")
        match = re.search(r'printf "([^"]*)%s\\n" PERF_DONE', joined)
        self.assertIsNotNone(match, "marker must be assembled at runtime")
        self.assertEqual(match.group(1) + "PERF_DONE", checker.DONE_MARKER)

    def test_marker_never_verbatim_in_console_input(self):
        # floe_vm_host refuses a --until marker that appears verbatim in a
        # scripted input line (TTY echo could fake it).
        for line in self.workload_lines():
            self.assertNotIn(checker.DONE_MARKER, line)

    def test_work_is_bounded_and_equal(self):
        self.assertIn("--max-s 180", self.s5_run)
        joined = "\n".join(self.workload_lines())
        self.assertEqual(joined.count("count=6000"), 2)
        self.assertEqual(joined.count("bs=64k"), 2)

    def test_host_workload_script_parses(self):
        for line in self.workload_lines():
            match = re.match(r"^@\d+ (.*)$", line)
            if not match:
                continue
            proc = subprocess.run(["bash", "-n", "-c", match.group(1)],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0,
                             "shell syntax error in %r: %s" % (line, proc.stderr))

    def test_old_15x_instruction_rule_is_gone(self):
        self.assertNotIn("1.5", self.s5_run)
        self.assertNotIn("median_total_hart_insns", self.s5_run)
        self.assertNotIn("wall_ratio_1hart_over_2hart", self.s5_run)

    def test_step_runs_the_gate_helper(self):
        self.assertIn("smp_workload_check.py", self.s5_run)
        self.assertIn("--until FLOE_SMP2PERF_DONE", self.s5_run)
        self.assertIn("--max-s 180", self.s5_run)

    def test_old_timed_workload_text_gone_from_whole_workflow(self):
        self.assertNotIn("@50 printf 'FLOE_SMP2PERF_%s\\n' DONE", self.workflow_text)
        self.assertNotIn("work[2] < 1.5 * work[1]", self.workflow_text)

    def test_summary_still_reads_s5_report(self):
        self.assertIn('maybe_json("work/smp2/smp-perf.json")', self.workflow_text)

    def test_stopped_run_and_evidence_uploads_retained(self):
        self.assertIn("stop-transcript.txt", self.s5_run)
        self.assertIn("stop-stats.jsonl", self.s5_run)
        self.assertIn("--max-s 8", self.s5_run)
        self.assertIn("name: smp-workload-${{ github.run_id }}", self.workflow_text)
        self.assertIn("work/smp2/", self.workflow_text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
