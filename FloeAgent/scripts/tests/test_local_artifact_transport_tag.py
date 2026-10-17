"""Focused regression tests for the private local-artifact transport tag.

The local-device sign/upload route may consume a draft transport release whose
tag is distinct from the immutable App source tag. These tests pin the two
workflow changes and execute the real validation shell step locally:

* the caller exposes an optional ``transport_tag`` and forwards it only to the
  local-artifact job; no compile/release job condition changes;
* the reusable workflow keeps ``tag`` as the source tag for checkout, SemVer,
  project-version, provenance, preflight and concurrency, and uses the new
  transport tag only for the draft release view/download;
* the resolved transport tag defaults to the source tag for existing callers;
* malformed transport tags (whitespace, control characters, option prefixes,
  path separators, ref punctuation, overlong values) are rejected without
  shell evaluation.

No network, secret, Apple call, build or remote dispatch is performed.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

REPO_ROOT = Path(__file__).resolve().parents[3]
CALLER = REPO_ROOT / ".github" / "workflows" / "release-unsigned-ipa.yml"
REUSABLE = REPO_ROOT / ".github" / "workflows" / "testflight-local-artifact.yml"

CALLER_TEXT = CALLER.read_text(encoding="utf-8")
REUSABLE_TEXT = REUSABLE.read_text(encoding="utf-8")
CALLER_WORKFLOW = yaml.safe_load(CALLER_TEXT)
REUSABLE_WORKFLOW = yaml.safe_load(REUSABLE_TEXT)

LOCAL_JOB_IF = (
    "${{ github.event_name == 'workflow_dispatch' && "
    "inputs.local_artifact_sha256 != '' && !inputs.publish && "
    "!inputs.lean_release && !inputs.direct_testflight }}"
)
COMPILE_JOBS = {
    "prepare-release": (
        "${{ inputs.local_artifact_sha256 == '' && "
        "!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && "
        "!inputs.direct_testflight && !inputs.recover_build_156 && "
        "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' && "
        "!inputs.lean_release && inputs.reuse_direct_run == '' }}"
    ),
    "notes-component": (
        "${{ inputs.local_artifact_sha256 == '' && "
        "!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && "
        "!inputs.direct_testflight && !inputs.recover_build_156 && "
        "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' && "
        "!inputs.lean_release && inputs.reuse_direct_run == '' }}"
    ),
    "build-verify-release": (
        "${{ inputs.local_artifact_sha256 == '' && "
        "!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && "
        "!inputs.direct_testflight && !inputs.recover_build_156 && "
        "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' && "
        "!inputs.lean_release && inputs.reuse_direct_run == '' }}"
    ),
    "accepted-sdk-build": None,
    "testflight": None,
    "lean-source": (
        "${{ inputs.local_artifact_sha256 == '' && "
        "!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && "
        "!inputs.recover_build_156 && github.event_name == 'workflow_dispatch' && "
        "inputs.lean_release && inputs.reuse_accepted_run == '' && "
        "inputs.component_recovery_run == '' }}"
    ),
    "lean-build": (
        "${{ inputs.local_artifact_sha256 == '' && "
        "!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && "
        "!inputs.recover_build_156 && github.event_name == 'workflow_dispatch' && "
        "inputs.lean_release && !inputs.direct_testflight && "
        "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' }}"
    ),
    "lean-publish": (
        "${{ inputs.local_artifact_sha256 == '' && "
        "!inputs.recover_developer_build191 && !inputs.build191_ui_waiver && "
        "!inputs.recover_build_156 && github.event_name == 'workflow_dispatch' && "
        "inputs.lean_release && inputs.publish && !inputs.direct_testflight && "
        "inputs.reuse_accepted_run == '' && inputs.component_recovery_run == '' }}"
    ),
}


def trigger_inputs(workflow, trigger):
    """Return the declared inputs of one workflow trigger."""
    # PyYAML resolves the bare ``on`` key to True in YAML 1.1 mode.
    triggers = workflow.get("on", workflow.get(True))
    return triggers[trigger]["inputs"]


def steps(workflow):
    return workflow["jobs"]["upload"]["steps"]


def step_named(workflow, name):
    for step in steps(workflow):
        if step.get("name") == name:
            return step
    raise AssertionError("step {!r} is missing".format(name))


def step_index(workflow, name):
    return [step.get("name") for step in steps(workflow)].index(name)


class InputContractTests(unittest.TestCase):
    """Both workflows declare the optional input and the caller forwards it."""

    def test_caller_input_is_optional_and_legacy_values_are_unchanged(self):
        inputs = trigger_inputs(CALLER_WORKFLOW, "workflow_dispatch")
        self.assertIn("transport_tag", inputs)
        transport = inputs["transport_tag"]
        self.assertEqual(transport["required"], False)
        self.assertEqual(transport["default"], "")
        self.assertEqual(transport["type"], "string")
        self.assertTrue(transport.get("description"))
        self.assertEqual(inputs["tag"]["required"], True)
        self.assertEqual(inputs["tag"]["type"], "string")
        self.assertEqual(inputs["local_artifact_sha256"]["required"], False)
        self.assertEqual(inputs["local_artifact_sha256"]["default"], "")
        self.assertEqual(inputs["local_artifact_sha256"]["type"], "string")

    def test_reusable_input_is_optional_and_existing_inputs_stay_required(self):
        inputs = trigger_inputs(REUSABLE_WORKFLOW, "workflow_call")
        self.assertIn("transport_tag", inputs)
        transport = inputs["transport_tag"]
        self.assertEqual(transport["required"], False)
        self.assertEqual(transport["default"], "")
        self.assertEqual(transport["type"], "string")
        self.assertTrue(transport.get("description"))
        self.assertEqual(inputs["tag"]["required"], True)
        self.assertEqual(inputs["artifact_sha256"]["required"], True)

    def test_permissions_are_unchanged(self):
        self.assertEqual(REUSABLE_WORKFLOW["permissions"],
                         {"contents": "write", "actions": "read"})
        self.assertEqual(CALLER_WORKFLOW["permissions"], {"contents": "read"})

    def test_caller_forwards_transport_tag_only_to_the_local_artifact_job(self):
        job = CALLER_WORKFLOW["jobs"]["local-artifact-testflight"]
        self.assertEqual(job["uses"], "./.github/workflows/testflight-local-artifact.yml")
        self.assertEqual(job["if"], LOCAL_JOB_IF)
        self.assertEqual(job["with"], {
            "tag": "${{ inputs.tag }}",
            "transport_tag": "${{ inputs.transport_tag }}",
            "artifact_sha256": "${{ inputs.local_artifact_sha256 }}",
        })
        for name, other in CALLER_WORKFLOW["jobs"].items():
            if name == "local-artifact-testflight":
                continue
            self.assertNotIn("transport_tag", json.dumps(other), name)
        # One declaration, one forwarded key and one caller expression.
        self.assertEqual(CALLER_TEXT.count("transport_tag"), 3)
        self.assertEqual(CALLER_TEXT.count("transport_tag:"), 2)
        self.assertEqual(CALLER_TEXT.count("inputs.transport_tag"), 1)

    def test_compile_job_conditions_are_unchanged(self):
        jobs = CALLER_WORKFLOW["jobs"]
        for name, condition in COMPILE_JOBS.items():
            self.assertIn(name, jobs)
            self.assertEqual(jobs[name].get("if"), condition, name)
            self.assertNotIn("transport_tag", json.dumps(jobs[name]), name)
        self.assertEqual(jobs["build-verify-release"]["runs-on"], "xcode-27")
        self.assertEqual(jobs["accepted-sdk-build"]["runs-on"], "macos-26")
        self.assertEqual(jobs["testflight"]["runs-on"], "macos-26")
        self.assertEqual(jobs["lean-build"]["uses"],
                         "./.github/workflows/testflight-direct.yml")
        self.assertEqual(jobs["notes-component"]["uses"],
                         "./.github/workflows/notes-native-qualification.yml")


class SourceBindingTests(unittest.TestCase):
    """Source identity, concurrency and artifact names stay on the source tag."""

    def test_concurrency_still_serializes_by_source_tag(self):
        self.assertEqual(REUSABLE_WORKFLOW["concurrency"], {
            "group": "floe-local-artifact-${{ inputs.tag }}",
            "cancel-in-progress": False,
        })
        self.assertNotIn("transport_tag", REUSABLE_WORKFLOW["concurrency"]["group"])
        self.assertEqual(CALLER_WORKFLOW["concurrency"],
                         {"group": "floe-release-${{ github.ref }}",
                          "cancel-in-progress": False})

    def test_checkout_and_source_guard_use_the_source_tag(self):
        checkout = REUSABLE_WORKFLOW["jobs"]["upload"]["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "${{ inputs.tag }}")
        source = step_named(REUSABLE_WORKFLOW, "Require exact local release source")["run"]
        for line in (
            '[[ "$RELEASE_TAG" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$ ]]',
            "assert os.environ['RELEASE_TAG'] == 'v' + version",
            'scripts/release_preflight.sh "$RELEASE_TAG"',
        ):
            self.assertIn(line, source)
        self.assertNotIn("TRANSPORT_TAG", source)
        self.assertEqual(step_named(REUSABLE_WORKFLOW,
                                    "Require exact local release source")["id"], "source")

    def test_provenance_still_checks_source_sha_and_source_version(self):
        download = step_named(REUSABLE_WORKFLOW,
                              "Download private draft transport and verify local provenance")
        self.assertIn("assert p['source_sha']==os.environ['SOURCE_SHA']", download["run"])
        self.assertIn("assert 'v'+p['version']==os.environ['RELEASE_TAG']", download["run"])
        self.assertIn("assert p['build'].isdigit()", download["run"])
        self.assertIn("dwarfdump", download["run"])

    def test_transport_tag_is_used_only_for_the_draft_release_lookup(self):
        download = step_named(REUSABLE_WORKFLOW,
                              "Download private draft transport and verify local provenance")["run"]
        self.assertEqual(download.count('"$TRANSPORT_TAG"'), 4)
        self.assertIn('gh release view "$TRANSPORT_TAG" --json isDraft', download)
        self.assertIn('gh release view "$TRANSPORT_TAG" --json assets', download)
        self.assertIn('gh release download "$TRANSPORT_TAG" -p local-device.zip', download)
        self.assertIn('gh release download "$TRANSPORT_TAG" -p \'local-device.zip.part??\'',
                      download)
        self.assertIn("grep -x true", download)
        self.assertIn("EXPECTED_SHA", download)

    def test_signing_and_evidence_stay_bound_to_source_tag(self):
        for name in (
            "Install App Store Connect API key",
            "Install distribution identity and existing App Store profiles",
            "Sign, verify, package, and upload to TestFlight",
            "Upload TestFlight evidence",
            "Retain local provenance and symbols",
            "Confirm Apple processing and existing internal Floe QA availability",
            "Save Apple internal availability evidence",
        ):
            self.assertNotIn("TRANSPORT_TAG", json.dumps(step_named(REUSABLE_WORKFLOW, name)),
                             name)
        upload = step_named(REUSABLE_WORKFLOW, "Upload TestFlight evidence")
        retained = step_named(REUSABLE_WORKFLOW, "Retain local provenance and symbols")
        apple = step_named(REUSABLE_WORKFLOW, "Save Apple internal availability evidence")
        self.assertEqual(upload["with"]["name"],
                         "testflight-${{ steps.source.outputs.version }}"
                         "-build${{ steps.source.outputs.build }}")
        self.assertEqual(retained["with"]["name"],
                         "local-${{ inputs.tag }}-provenance-symbols")
        self.assertEqual(apple["with"]["name"], "local-${{ inputs.tag }}-apple-internal")
        sign = step_named(REUSABLE_WORKFLOW, "Sign, verify, package, and upload to TestFlight")
        self.assertIn("'tag': os.environ['RELEASE_TAG']", sign["run"])

    def test_resolution_step_runs_after_source_guard_and_before_download(self):
        source = step_index(REUSABLE_WORKFLOW, "Require exact local release source")
        resolve = step_index(REUSABLE_WORKFLOW, "Resolve private draft transport tag")
        download = step_index(REUSABLE_WORKFLOW,
                              "Download private draft transport and verify local provenance")
        self.assertEqual(resolve, source + 1)
        self.assertEqual(download, resolve + 1)


class TransportTagValidationTests(unittest.TestCase):
    """Execute the real shell step; the input must never be evaluated."""

    @classmethod
    def setUpClass(cls):
        cls.script = step_named(REUSABLE_WORKFLOW, "Resolve private draft transport tag")["run"]

    def run_resolve(self, transport_input, source_tag="v1.7.35"):
        root = Path(tempfile.mkdtemp(prefix="floe-transport-tag-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        env_file = root / "github-env"
        env = dict(os.environ)
        for name in ("TRANSPORT_TAG", "TRANSPORT_TAG_INPUT", "RELEASE_TAG", "GITHUB_ENV"):
            env.pop(name, None)
        env.update({
            "RELEASE_TAG": source_tag,
            "TRANSPORT_TAG_INPUT": transport_input,
            "GITHUB_ENV": str(env_file),
        })
        result = subprocess.run(["bash", "-c", self.script], cwd=root, env=env,
                                capture_output=True, text=True)
        written = env_file.read_text(encoding="utf-8") if env_file.exists() else ""
        return result, written, root

    def assert_resolved(self, transport_input, expected):
        result, written, _ = self.run_resolve(transport_input)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(written, "TRANSPORT_TAG=" + expected + "\n")

    def test_empty_input_falls_back_to_the_source_tag(self):
        self.assert_resolved("", "v1.7.35")

    def test_distinct_private_transport_tag_is_accepted(self):
        self.assert_resolved("local-device-build276-037698e9",
                             "local-device-build276-037698e9")

    def test_explicit_source_tag_remains_compatible(self):
        self.assert_resolved("v1.7.35", "v1.7.35")

    def test_bounded_dotted_and_underscored_tag_is_accepted(self):
        self.assert_resolved("Local-device.build276_rc-1",
                             "Local-device.build276_rc-1")

    def test_invalid_or_unsafe_transport_tags_are_rejected(self):
        invalid = [
            "bad tag",
            "bad\ttag",
            "bad\ntag",
            " leading",
            "-leading",
            ".hidden",
            "a..b",
            "a.lock",
            "a.",
            "a/b",
            "a\\b",
            "a@{b",
            "a$b",
            "a;b",
            "a&b",
            "a|b",
            "a>b",
            "a*b",
            "a?b",
            "a:b",
            "a[b]",
            "a~b",
            "a^b",
            "a" * 129,
        ]
        for value in invalid:
            with self.subTest(value=value):
                result, written, _ = self.run_resolve(value)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("TRANSPORT_TAG=", written)

    def test_transport_input_is_never_shell_evaluated(self):
        result, written, root = self.run_resolve("$(touch transport-pwned)")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("TRANSPORT_TAG=", written)
        self.assertFalse((root / "transport-pwned").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
