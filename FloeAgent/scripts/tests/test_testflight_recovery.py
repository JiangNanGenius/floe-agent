import copy
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_testflight_recovery import verify, test_summary


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.run = {"id": 1, "head_sha": "a" * 40, "head_repository": {"full_name": "owner/repo"},
                    "path": ".github/workflows/release-unsigned-ipa.yml", "event": "push", "conclusion": "failure"}
        names = ["Require the App Store accepted Xcode toolchain", "Validate the exact verified application",
                 "Rebuild the exact tag with the accepted App Store SDK", "Verify focused app regressions with the accepted App Store SDK"]
        self.jobs = {"jobs": [{"id": 2, "name": "build-verify-release", "conclusion": "success"},
                    {"id": 3, "name": "Archive and upload the same commit to TestFlight", "conclusion": "failure",
                     "steps": [{"name": n, "conclusion": "success"} for n in names] +
                     [{"name": "Sign, verify, package, and upload to TestFlight", "conclusion": "failure"}]}]}

    def test_trusted_distribution_failure_is_eligible(self):
        self.assertEqual(verify(self.run, self.jobs, "owner/repo", "a" * 40)["accepted_sdk_job"], 3)

    def test_source_and_repository_must_match(self):
        for repo, sha in [("other/repo", "a" * 40), ("owner/repo", "b" * 40)]:
            with self.assertRaises(ValueError): verify(self.run, self.jobs, repo, sha)

    def test_failed_or_missing_qualification_is_rejected(self):
        for conclusion in ("failure", "skipped", None):
            jobs = copy.deepcopy(self.jobs)
            jobs["jobs"][1]["steps"][3]["conclusion"] = conclusion
            with self.assertRaises(ValueError): verify(self.run, jobs, "owner/repo", "a" * 40)

    def test_successful_upload_is_not_retried(self):
        self.jobs["jobs"][1]["steps"][-1]["conclusion"] = "success"
        with self.assertRaises(ValueError): verify(self.run, self.jobs, "owner/repo", "a" * 40)

    def test_incomplete_or_duplicate_summary_is_rejected(self):
        line = "canvas-pip-timeline-app-regression-summary total=135 passed=135 failed=0 skipped=0 expectedFailures=0 result=Passed"
        self.assertEqual(test_summary(line)["passed"], 135)
        for value in ("", line + "\n" + line, line.replace("passed=135", "passed=134"), line.replace("skipped=0", "skipped=1")):
            with self.assertRaises(ValueError): test_summary(value)


if __name__ == "__main__": unittest.main()
