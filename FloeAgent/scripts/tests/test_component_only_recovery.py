import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("component_recovery", Path(__file__).parents[1] / "verify_component_only_recovery.py")
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


class ComponentRecoveryTests(unittest.TestCase):
    def fixture(self):
        def run(sha, path, event, conclusion, identifier):
            return dict(id=identifier, head_sha=sha, path=path, event=event,
                        status="completed", conclusion=conclusion,
                        head_branch="v1.7.0-beta.44", head_repository=dict(full_name=v.REPOSITORY))
        def job(name, conclusion):
            return dict(id=hash(name), name=name, status="completed", conclusion=conclusion)
        original = dict(result="Failed", totalTestCount=101, passedTests=100, failedTests=1,
                        skippedTests=0, expectedFailures=0, runtimeWarnings=[],
                        testFailures=[dict(testIdentifierString=v.FAILURE_ID, failureText=v.FAILURE_TEXT)])
        replacement = dict(result="Passed", totalTestCount=101, passedTests=101, failedTests=0,
                           skippedTests=0, expectedFailures=0, runtimeWarnings=[], testFailures=[])
        return [run(v.APP_SOURCE, ".github/workflows/release-unsigned-ipa.yml", "push", "failure", 100),
                run(v.COMPONENT_SOURCE, ".github/workflows/notes-native-qualification.yml", "workflow_dispatch", "success", 101),
                dict(jobs=[job(n, "success") for n in v.SDK_JOBS] +
                     [job(v.SOURCE_COMPONENT, "failure"), job("Archive and upload the same commit to TestFlight", "skipped")]),
                dict(jobs=[job("development", "success"), job("compatibility", "skipped")]),
                {f"{kind}-{family}": copy.deepcopy(value) for kind, value in
                 [("original", original), ("replacement", replacement)] for family in ["iPad", "iPhone"]},
                "v1.7.0-beta.44", v.APP_SOURCE, v.COMPONENT_SOURCE,
                [v.TEST_PATH, "docs/result.json"], v.ORIGINAL_TEST_HASH, v.REPAIRED_TEST_HASH]

    def test_reviewed_pair_preserves_two_source_ids(self):
        result = v.verify(*self.fixture())
        self.assertEqual(result["sourceCommit"], v.APP_SOURCE)
        self.assertEqual(result["componentSource"], v.COMPONENT_SOURCE)
        self.assertIn("No qualification waiver", result["policy"])

    def test_wrong_repository_workflow_event_sha_or_incomplete_run(self):
        for index in [0, 1]:
            for key, value in [("head_sha", "a" * 40), ("path", "wrong.yml"), ("event", "pull_request"),
                               ("status", "in_progress"), ("head_repository", dict(full_name="other/repo"))]:
                with self.subTest(index=index, key=key):
                    data = self.fixture(); data[index][key] = value
                    with self.assertRaises(ValueError): v.verify(*data)

    def test_sdk_failure_skip_missing_or_duplicate_is_rejected(self):
        for index in [0, 1]:
            for outcome in ["failure", "skipped", "cancelled"]:
                data = self.fixture(); data[2]["jobs"][index]["conclusion"] = outcome
                with self.assertRaises(ValueError): v.verify(*data)
        for duplicate in [False, True]:
            data = self.fixture()
            if duplicate: data[2]["jobs"].append(copy.deepcopy(data[2]["jobs"][0]))
            else: data[2]["jobs"].pop(0)
            with self.assertRaises(ValueError): v.verify(*data)

    def test_unreviewed_fixture_or_app_change_is_rejected(self):
        for path in ["FloeAgent/project.yml", "FloeAgent/FloeApp/App/FloeAgentApp.swift",
                     ".github/workflows/notes-native-qualification.yml", "FloeAgent/Package.resolved",
                     "FloeAgent/Qualification/NativeNotes/Tests/OtherTests.swift"]:
            data = self.fixture(); data[8].append(path)
            with self.assertRaises(ValueError): v.verify(*data)
        for index in [5, 6, 7, 9, 10]:
            data = self.fixture(); data[index] = "unreviewed"
            with self.assertRaises(ValueError): v.verify(*data)

    def test_original_must_be_only_the_exact_reviewed_failure(self):
        for family in ["iPad", "iPhone"]:
            for key, value in [("failedTests", 2), ("totalTestCount", 100), ("runtimeWarnings", ["crash"]),
                               ("testFailures", []), ("expectedFailures", 1), ("skippedTests", 1)]:
                data = self.fixture(); data[4][f"original-{family}"][key] = value
                with self.assertRaises(ValueError): v.verify(*data)
            data = self.fixture(); data[4][f"original-{family}"]["testFailures"][0]["failureText"] = "different failure"
            with self.assertRaises(ValueError): v.verify(*data)

    def test_replacement_must_pass_every_case_on_both_devices(self):
        for family in ["iPad", "iPhone"]:
            for key, value in [("result", "Failed"), ("failedTests", 1), ("passedTests", 100),
                               ("totalTestCount", 0), ("skippedTests", 1), ("expectedFailures", 1),
                               ("runtimeWarnings", ["crash"]), ("testFailures", ["unexpected"])]:
                data = self.fixture(); data[4][f"replacement-{family}"][key] = value
                with self.assertRaises(ValueError): v.verify(*data)

    def test_previous_upload_and_failed_component_run_rejected(self):
        data = self.fixture(); data[2]["jobs"][-1]["conclusion"] = "success"
        with self.assertRaises(ValueError): v.verify(*data)
        data = self.fixture(); data[3]["jobs"][0]["conclusion"] = "failure"
        with self.assertRaises(ValueError): v.verify(*data)


if __name__ == "__main__":
    unittest.main()
