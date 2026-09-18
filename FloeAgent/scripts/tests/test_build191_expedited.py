"""Exercise the narrowed recovery policy against recorded GitHub metadata."""
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("build191", ROOT / "verify_build191_expedited.py")
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class Build191RecoveryTests(unittest.TestCase):
    def fixture(self):
        return json.loads((ROOT / "tests/fixtures/build191-recovery-metadata.json").read_text())

    def test_recorded_evidence_never_claims_full_qualification(self):
        report = v.verify(*self.fixture(), acknowledged=True)
        self.assertFalse(report["fullQualificationPassed"])
        self.assertEqual(report["sourceCommit"], "715cbc42e9402cf5ca691291fed5c201e61cf222")

    def test_waiver_required(self):
        with self.assertRaises(ValueError):
            v.verify(*self.fixture())

    def test_other_source_attempt_or_run_rejected(self):
        for key, value in [("head_sha", "f" * 40), ("id", 123), ("run_attempt", 2),
                           ("head_branch", "main"), ("event", "pull_request"),
                           ("path", "other.yml"), ("status", "in_progress"),
                           ("head_repository", {"full_name": "other/repository"})]:
            with self.subTest(key=key):
                data = self.fixture(); data[0][key] = value
                with self.assertRaises(ValueError): v.verify(*data, acknowledged=True)

    def test_other_failure_or_missing_build_pass_rejected(self):
        for outcome in ("failure", "skipped", "cancelled"):
            data = self.fixture()
            job = next(j for j in data[1]["jobs"] if j["id"] == 105577179456)
            step = next(s for s in job["steps"] if s["name"] == "Rebuild the exact tag with the accepted App Store SDK")
            step["conclusion"] = outcome
            with self.assertRaises(ValueError): v.verify(*data, acknowledged=True)

    def test_missing_component_or_new_failed_job_rejected(self):
        for identifier in (105577180017, 105577087053, 105597278365):
            data = self.fixture()
            next(j for j in data[1]["jobs"] if j["id"] == identifier)["conclusion"] = "failure"
            with self.assertRaises(ValueError): v.verify(*data, acknowledged=True)

    def test_missing_truncated_or_duplicate_metadata_rejected(self):
        for index, key in ((1, "jobs"), (2, "artifacts")):
            data = self.fixture(); data[index][key].pop()
            with self.assertRaises(ValueError): v.verify(*data, acknowledged=True)
        data = self.fixture()
        job = next(j for j in data[1]["jobs"] if j["id"] == 105577179456)
        data[1]["jobs"].append(job); data[1]["total_count"] += 1
        with self.assertRaises(ValueError): v.verify(*data, acknowledged=True)

    def test_replaced_expired_or_foreign_artifact_rejected(self):
        for artifact_id in (10544612762, 10545243814):
            for key, value in [("digest", "sha256:" + "0" * 64), ("expired", True), ("id", 123),
                               ("workflow_run", {"id": 123, "head_sha": v.SOURCE})]:
                with self.subTest(artifact=artifact_id, key=key):
                    data = self.fixture()
                    next(a for a in data[2]["artifacts"] if a["id"] == artifact_id)[key] = value
                    with self.assertRaises(ValueError): v.verify(*data, acknowledged=True)


if __name__ == "__main__":
    unittest.main()
