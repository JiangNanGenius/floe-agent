#!/usr/bin/env python3
"""Fail-closed tests for the native Office host pin's engine repair claim.

The tracked single-member engine repair is part of the host identity now.  A
pin must carry exactly the canonical claim; a missing claim means the pinned
framework predates the repair (SOURCE AHEAD), while a present-but-different
claim (wrong SHA/platform/member/lock or an extra diagnostic field such as an
absolute receipt path) is corrupt and must be rejected outright.  ``--check``
stays strictly read-only.
"""
import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = REPO_ROOT / "FloeAgent/scripts"
sys.path.insert(0, str(SCRIPTS))

import office_engine_repair as repair  # noqa: E402
import pin_office_host_artifact as pin  # noqa: E402
from office_release_gates import false_capabilities  # noqa: E402

TRACKED_LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.lock.json"
PATCH_LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.patch.lock.json"


class PinEngineRepairClaim(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.lock = self.root / "engine.lock.json"
        self.lock.write_text(TRACKED_LOCK.read_text())
        # The pin script resolves the sibling engine contract next to the lock.
        (self.root / "engine.patch.lock.json").symlink_to(PATCH_LOCK)
        self.repair_lock, self.section, _ = repair.load_lock(
            PATCH_LOCK, "IOS")
        self.claim = repair.expected_manifest_block(self.repair_lock, self.section)
        self.write_pin(lambda block: block.pop("engineRepair", None))

    def run_check(self, lock_path=None):
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPTS / "pin_office_host_artifact.py"),
             "--lock", str(lock_path or self.lock), "--check"],
            capture_output=True, text=True, check=False, timeout=120)

    def write_pin(self, mutate):
        lock = json.loads(TRACKED_LOCK.read_text())
        # This suite isolates the engineRepair contract, not the live checkout's
        # pending source rebuild. Compiled lifecycle has its own strict tests.
        lock.get("embeddedLifecycleOverlay", {}).pop("compiledMembers", None)
        block = lock["qualifiedHostArtifact"]
        block.pop("embeddedLifecycleMember", None)
        block["hostSourceSHA256"] = {name: pin.source_hashes()[name] for name in block["hostSourceSHA256"]}
        block["overlaySHA256"] = lock["embeddingOverlay"]["sha256"]
        for section, claim_key, _, _ in pin.LIFECYCLE_OVERLAYS:
            if section in lock: block[claim_key] = lock[section]["sha256"]
        block.pop("pendingHostRebuild", None)
        mutate(block)
        self.lock.write_text(json.dumps(lock, indent=2) + "\n")

    def test_missing_claim_reports_source_ahead(self):
        completed = self.run_check()
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("SOURCE AHEAD OF ARTIFACT", completed.stdout)
        self.assertIn("engine repair", completed.stdout)

    def test_canonical_claim_matches(self):
        self.write_pin(lambda pin_block: pin_block.update(engineRepair=self.claim))
        completed = self.run_check()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("matches the current host sources", completed.stdout)

    def test_wrong_claim_values_are_rejected(self):
        def wrong_archive(block):
            block["engineRepair"]["patchedArchiveSHA256"] = "0" * 64

        def wrong_platform(block):
            block["engineRepair"]["platform"] = "IOSSIMULATOR"

        def wrong_member(block):
            block["engineRepair"]["member"]["patchedSHA256"] = "0" * 64

        def wrong_lock(block):
            block["engineRepair"]["lockSHA256"] = "0" * 64

        def extra_field(block):
            block["engineRepair"]["receiptPath"] = "/tmp/absolute/engine-repair.json"

        def missing_field(block):
            block["engineRepair"].pop("upstreamCommit")

        mutations = {
            "patched archive SHA": wrong_archive,
            "platform": wrong_platform,
            "member SHA": wrong_member,
            "lock SHA": wrong_lock,
            "extra field": extra_field,
            "missing field": missing_field,
        }
        for label, mutate in mutations.items():
            with self.subTest(label):
                def apply_mutation(block, _mutate=mutate):
                    block.update(engineRepair=copy.deepcopy(self.claim))
                    _mutate(block)
                self.write_pin(apply_mutation)
                completed = self.run_check()
                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertIn("REJECTED engine repair claim", completed.stdout)

    def test_check_is_read_only(self):
        self.write_pin(lambda block: block.update(engineRepair=self.claim))
        before = self.lock.stat().st_mtime_ns, self.lock.read_bytes()
        self.run_check()
        after = self.lock.stat().st_mtime_ns, self.lock.read_bytes()
        self.assertEqual(before, after)

    def test_provenance_failures_are_strict(self):
        self.assertEqual(pin.engine_repair_provenance_failures(
            {"engineRepair": self.claim}, self.claim), [])
        extra = dict(self.claim, receiptPath="/tmp/x")
        failures = pin.engine_repair_provenance_failures(
            {"engineRepair": extra}, self.claim)
        self.assertTrue(any("unexpected fields" in failure for failure in failures))
        missing = {key: value for key, value in self.claim.items()
                   if key != "member"}
        failures = pin.engine_repair_provenance_failures(
            {"engineRepair": missing}, self.claim)
        self.assertTrue(any("omits member" in failure for failure in failures))
        wrong = copy.deepcopy(self.claim)
        wrong["member"]["patchedSHA256"] = "0" * 64
        failures = pin.engine_repair_provenance_failures(
            {"engineRepair": wrong}, self.claim)
        self.assertTrue(any("member" in failure for failure in failures))


class TransportStorageIdentityCliTests(unittest.TestCase):
    """Real CLI subprocess runs for the storage transport identity policy.

    A copied scripts/contracts tree keeps every strict source/overlay check
    real; only fixture bytes are synthetic. Each test drives
    pin_office_host_artifact.py (and bootstrap_office_host.py) as the release
    would, so an undefined CLI argument or an inherited old run id fails here.
    """

    MODULES = ("pin_office_host_artifact.py", "bootstrap_office_host.py",
               "office_compiled_lifecycle.py", "office_release_gates.py",
               "office_engine_repair.py", "verify_office_engine.py",
               "package_office_engine.py", "office_real_simulator/sim_paths.py")
    LOCAL_RUN = "9000000002"
    LOCAL_COMMIT = "b" * 40
    CLOUD_RUN = "37261456081"
    CLOUD_COMMIT = "7ab667eb76883584613dea4fc0b49fd2fc6f7681"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ws = self.root / "ws"
        scripts = self.ws / "FloeAgent/scripts"
        scripts.mkdir(parents=True)
        for name in self.MODULES:
            (scripts / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SCRIPTS / name, scripts / name)
        self.base = self.ws / "FloeAgent/ThirdParty/Collabora"
        shutil.copytree(REPO_ROOT / "FloeAgent/ThirdParty/Collabora", self.base)
        self.lock_path = self.base / "engine.lock.json"
        self.lock = json.loads(self.lock_path.read_text())
        self.pin_block = self.lock["qualifiedHostArtifact"]
        sources = {path.name: pin.digest(path) for path in (self.base / "FloeOfficeNative").iterdir()
                   if path.is_file()}
        self.pin_block["hostSourceSHA256"] = {name: sources[name]
                                              for name in self.pin_block["hostSourceSHA256"]}
        self.pin_block["overlaySHA256"] = self.lock["embeddingOverlay"]["sha256"]
        self.pin_block.pop("embeddedLifecycleMember", None)
        self.pin_block.pop("pendingHostRebuild", None)
        self.pin_block.pop("filterOverlay", None)
        self.lock["embeddedLifecycleOverlay"].pop("compiledMembers", None)
        for section, claim, _, _ in pin.LIFECYCLE_OVERLAYS:
            if section in self.lock:
                self.pin_block[claim] = self.lock[section]["sha256"]
        self.lock_path.write_text(json.dumps(self.lock, indent=2) + "\n")
        self.archive = self.root / "OfficeNativeHost.zip"

    def manifest(self, **overrides):
        manifest = {
            "sdk": "iphoneos", "arch": "arm64",
            "sourceCommit": self.lock["commit"],
            "overlaySHA256": self.lock["embeddingOverlay"]["sha256"],
            "hostSourceSHA256": {name: pin.digest(self.base / "FloeOfficeNative" / name)
                                 for name in self.pin_block["hostSourceSHA256"]},
            "runtimeResourceSHA256": {}, "runtimeResourceDirectories": [],
            "capabilityQualification": false_capabilities(),
            "hostCompilePassed": True, "hostLinkPassed": True, "swiftModuleImportPassed": True,
        }
        for section, _, block, _ in pin.LIFECYCLE_OVERLAYS:
            if section in self.lock:
                manifest[block] = pin.lifecycle_provenance(self.lock[section], self.lock["commit"])
        claim = pin.engine_repair_claim(self.lock_path)
        if claim is not None:
            manifest["engineRepair"] = claim
        manifest.update(overrides)
        return manifest

    def pack(self, manifest):
        if self.archive.exists():
            self.archive.unlink()
        with zipfile.ZipFile(self.archive, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("OfficeNativeHost/native-host.json", json.dumps(manifest))
            archive.writestr("OfficeNativeHost/FloeOfficeNative.framework/FloeOfficeNative",
                             b"synthetic fixture executable, never compiled")
        return self.archive

    def run_pin(self, *args, script="pin_office_host_artifact.py"):
        return subprocess.run(
            [sys.executable, "-B", str(self.ws / "FloeAgent/scripts" / script),
             "--lock", str(self.lock_path), *args],
            capture_output=True, text=True, timeout=300, check=False)

    def run_bootstrap(self, *args):
        return subprocess.run(
            [sys.executable, "-B", str(self.ws / "FloeAgent/scripts/bootstrap_office_host.py"), *args],
            capture_output=True, text=True, timeout=300, check=False)

    def pinned(self):
        return json.loads(self.lock_path.read_text())["qualifiedHostArtifact"]

    def test_cli_local_manifest_storage_pair_pins_one_resolved_identity(self):
        archive = self.pack(self.manifest())
        completed = self.run_pin("--artifact-zip", str(archive), "--artifact-id", "4242",
                                 "--artifact-run-id", self.LOCAL_RUN,
                                 "--artifact-commit", self.LOCAL_COMMIT, "--apply")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        block = self.pinned()
        self.assertEqual(block["runID"], self.LOCAL_RUN)
        self.assertEqual(block["workflowCommit"], self.LOCAL_COMMIT)
        self.assertEqual(block["artifactID"], 4242)
        self.assertEqual(block["overlaySHA256"], self.lock["embeddingOverlay"]["sha256"])
        storage = block["localStorageArtifact"]
        self.assertEqual(storage["runID"], self.LOCAL_RUN)
        self.assertEqual(storage["workflowCommit"], self.LOCAL_COMMIT)
        self.assertEqual(storage["archiveSHA256"], block["archiveSHA256"])
        self.assertEqual(storage["artifactName"], block["artifactName"])
        self.assertEqual(storage["nativeProducer"], pin.LOCAL_PRODUCER)
        self.assertNotIn(self.CLOUD_RUN, json.dumps(block))
        # The normal bootstrap path resolves the same run for its destination,
        # cold install and verify; no second downloader or registry exists.
        installed = self.run_bootstrap("--archive", str(archive))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertEqual(json.loads(installed.stdout)["runID"], self.LOCAL_RUN)
        destination = self.ws / "FloeAgent/Vendor/Office" / self.LOCAL_RUN / "OfficeNativeHost"
        self.assertTrue((destination / "native-host.json").is_file())
        verified = self.run_bootstrap("--verify-only", "--destination", str(destination))
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertEqual(json.loads(verified.stdout)["runID"], self.LOCAL_RUN)
        check = self.run_pin("--check")
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertIn("matches the current host sources", check.stdout)

    def test_cli_local_manifest_without_storage_pair_refuses_inheritance(self):
        archive = self.pack(self.manifest())
        before = self.lock_path.read_bytes()
        completed = self.run_pin("--artifact-zip", str(archive), "--apply")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("carries no native cloud run identity", completed.stderr)
        self.assertEqual(self.lock_path.read_bytes(), before)

    def test_cli_cloud_manifest_keeps_native_identity_without_storage_block(self):
        cloud = self.manifest(runID=self.CLOUD_RUN, workflowCommit=self.CLOUD_COMMIT)
        archive = self.pack(cloud)
        completed = self.run_pin("--artifact-zip", str(archive), "--artifact-id", "11324529444", "--apply")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        block = self.pinned()
        self.assertEqual(block["runID"], self.CLOUD_RUN)
        self.assertEqual(block["workflowCommit"], self.CLOUD_COMMIT)
        self.assertEqual(block["artifactID"], 11324529444)
        self.assertNotIn("localStorageArtifact", block)
        self.assertEqual(self.run_pin("--check").returncode, 0)

    def test_cli_partial_invalid_or_recycled_storage_pair_rejected(self):
        archive = self.pack(self.manifest())
        before = self.lock_path.read_bytes()
        cases = [
            (("--artifact-run-id", self.LOCAL_RUN), "must be given together"),
            (("--artifact-run-id", "not-a-run", "--artifact-commit", self.LOCAL_COMMIT),
             "numeric Actions run id"),
            (("--artifact-run-id", self.LOCAL_RUN, "--artifact-commit", "abc"),
             "40-character hex commit"),
        ]
        for args, expected in cases:
            with self.subTest(args=args):
                completed = self.run_pin("--artifact-zip", str(archive), *args, "--apply")
                self.assertEqual(completed.returncode, 1, completed.stdout)
                self.assertIn(expected, completed.stderr)
                self.assertEqual(self.lock_path.read_bytes(), before)
        cloud_archive = self.pack(self.manifest(runID=self.CLOUD_RUN, workflowCommit=self.CLOUD_COMMIT))
        recycled = self.run_pin("--artifact-zip", str(cloud_archive),
                                "--artifact-run-id", self.CLOUD_RUN,
                                "--artifact-commit", self.CLOUD_COMMIT, "--apply")
        self.assertEqual(recycled.returncode, 1)
        self.assertIn("must differ from the native build run id", recycled.stderr)

    def test_cli_stale_overlay_or_wrong_source_rejected_without_mutation(self):
        before = self.lock_path.read_bytes()
        stale = self.pack(self.manifest(overlaySHA256="4ac3cc3b3914f0357eae02323fbd92cfce3750e98db84792608e831f65a5e597"))
        completed = self.run_pin("--artifact-zip", str(stale), "--artifact-run-id", self.LOCAL_RUN,
                                 "--artifact-commit", self.LOCAL_COMMIT, "--apply")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("embedding overlay differs from the current locked overlay", completed.stderr)
        forged = self.manifest()
        forged["hostSourceSHA256"] = {name: "0" * 64 for name in forged["hostSourceSHA256"]}
        completed = self.run_pin("--artifact-zip", str(self.pack(forged)), "--artifact-run-id", self.LOCAL_RUN,
                                 "--artifact-commit", self.LOCAL_COMMIT, "--apply")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("different host sources", completed.stderr)
        wrong_engine = self.pack(self.manifest(sourceCommit="0" * 40))
        completed = self.run_pin("--artifact-zip", str(wrong_engine), "--artifact-run-id", self.LOCAL_RUN,
                                 "--artifact-commit", self.LOCAL_COMMIT, "--apply")
        self.assertEqual(completed.returncode, 1)
        self.assertIn("different engine commit", completed.stderr)
        self.assertEqual(self.lock_path.read_bytes(), before)

    def test_check_rejects_corrupt_or_recycled_storage_provenance(self):
        archive = self.pack(self.manifest())
        applied = self.run_pin("--artifact-zip", str(archive), "--artifact-run-id", self.LOCAL_RUN,
                               "--artifact-commit", self.LOCAL_COMMIT, "--apply")
        self.assertEqual(applied.returncode, 0, applied.stderr)
        original = self.lock_path.read_text()

        def mutated(mutate):
            lock = json.loads(original)
            mutate(lock["qualifiedHostArtifact"]["localStorageArtifact"])
            self.lock_path.write_text(json.dumps(lock))

        def other_run(block):
            block["runID"] = "9000000003"

        def recycled(block):
            block.pop("nativeProducer")

        def short_commit(block):
            block["workflowCommit"] = "abc"

        for mutate, reason in ((other_run, "differs from the resolved transport run"),
                               (recycled, "recycles the native build run identity"),
                               (short_commit, "40-character hex commit")):
            with self.subTest(reason=reason):
                mutated(mutate)
                completed = self.run_pin("--check")
                self.assertEqual(completed.returncode, 1, completed.stdout)
                self.assertIn(reason, completed.stderr)
                self.lock_path.write_text(original)
        self.assertEqual(self.run_pin("--check").returncode, 0)


if __name__ == "__main__":
    unittest.main()
