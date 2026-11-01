#!/usr/bin/env python3
"""Offline lifecycle tests for the independent Bridge release publisher."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import publication_support as support
import publish_bridge_release as pub
import verify_bridge as vb


class PublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-bridge-publish-")
        self.root = Path(self.temporary.name)
        self.fixture = support.Fixture(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_publisher(self, *, publish=False, client=None, verifier=None, downloader=None, inputs=None):
        publisher, client, verifier, downloader = support.make_publisher(
            self.fixture,
            publish=publish,
            client=client,
            verifier=verifier,
            downloader=downloader,
            inputs=inputs,
        )
        code, report = publisher.run()
        return code, report, publisher, client, verifier, downloader

    # --- dry run and exact verifier boundary ---------------------------
    def test_dry_run_never_mutates_release_state(self) -> None:
        code, report, publisher, client, verifier, _ = self.run_publisher()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "dry-run")
        self.assertTrue(report["complete"])
        self.assertTrue(report["wouldCreateDraft"])
        self.assertEqual(client.mutation_calls(), [])
        self.assertEqual(len(verifier.calls), 1)

    def test_verifier_invocation_exact_data(self) -> None:
        _, _, _, client, verifier, _ = self.run_publisher()
        call = verifier.calls[0]
        self.assertEqual(set(call), {
            "ipa", "sidecar", "summary", "version", "build", "source_ref",
            "tag", "repo_root", "project", "latest_json", "expect_latest_tag",
            "strict",
        })
        self.assertEqual(call["ipa"], str(self.fixture.ipa.resolve()))
        self.assertEqual(call["sidecar"], str(self.fixture.sidecar.resolve()))
        self.assertEqual(call["summary"], str(self.fixture.summary.resolve()))
        self.assertEqual(call["version"], "1.0.0")
        self.assertEqual(call["build"], "14")
        self.assertEqual(call["source_ref"], self.fixture.source)
        self.assertEqual(call["tag"], self.fixture.tag)
        self.assertEqual(call["repo_root"], str(self.fixture.repo.resolve()))
        self.assertEqual(call["project"], str((self.fixture.project_dir / "project.yml").resolve()))
        self.assertEqual(call["expect_latest_tag"], "v1.7.65")
        self.assertTrue(call["strict"])
        self.assertEqual(verifier.latest_payloads[0]["tag_name"], "v1.7.65")
        self.assertEqual(client.mutation_calls(), [])

    def test_dry_run_writes_only_an_explicit_report(self) -> None:
        report_path = self.root / "operator-report.json"
        inputs = self.fixture.inputs(report_path=report_path)
        code, report, _, client, _, _ = self.run_publisher(inputs=inputs)
        self.assertEqual(code, 0)
        self.assertTrue(report_path.is_file())
        self.assertEqual(json.loads(report_path.read_text(encoding="utf-8"))["status"], "dry-run")
        self.assertFalse(self.fixture.evidence.exists())
        self.assertEqual(client.mutation_calls(), [])

    def test_dry_run_existing_published_is_read_only(self) -> None:
        client = self.fixture.client()
        client.seed_release(draft=False, assets=self.fixture.assets())
        code, report, _, client, _, downloader = self.run_publisher(client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "already-published")
        self.assertEqual(client.mutation_calls(), [])
        self.assertEqual(len(downloader.calls), 3)

    def test_expect_latest_tag_mismatch_fails_before_writers(self) -> None:
        inputs = self.fixture.inputs(expect_latest_tag="v1.7.64")
        code, report, _, client, _, _ = self.run_publisher(inputs=inputs)
        self.assertEqual(code, 2)
        self.assertEqual(report["status"], "preflight-failed")
        self.assertEqual(client.mutation_calls(), [])

    # --- happy path and exact payloads --------------------------------
    def test_publish_payloads_are_exact_and_stable(self) -> None:
        code, report, _, client, verifier, downloader = self.run_publisher(publish=True)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published")
        self.assertTrue(report["complete"])
        self.assertEqual(len(verifier.calls), 3)

        creates = [call for call in client.calls if call[0] == "create_release"]
        self.assertEqual(len(creates), 1)
        payload = creates[0][1]
        self.assertEqual(payload, {
            "tag_name": self.fixture.tag,
            "target_commitish": self.fixture.source,
            "name": "Floe iOS Bridge 1.0.0",
            "body": self.fixture.notes.read_text(encoding="utf-8"),
            "draft": True,
            "prerelease": False,
            "make_latest": "false",
            "generate_release_notes": False,
        })
        self.assertIsInstance(payload["make_latest"], str)

        uploads = [call for call in client.calls if call[0] == "upload_asset"]
        self.assertEqual([call[2] for call in uploads], [
            self.fixture.ipa.name,
            self.fixture.sidecar.name,
            self.fixture.summary.name,
        ])
        self.assertEqual([Path(call[3]) for call in uploads], [
            self.fixture.ipa.resolve(),
            self.fixture.sidecar.resolve(),
            self.fixture.summary.resolve(),
        ])

        updates = [call for call in client.calls if call[0] == "update_release"]
        self.assertEqual(len(updates), 1)
        self.assertEqual(updates[0][2], {
            "draft": False,
            "prerelease": False,
            "make_latest": "false",
        })
        self.assertIsInstance(updates[0][2]["make_latest"], str)
        self.assertEqual(len(downloader.calls), 3)
        self.assertEqual({call["expected_size"] for call in downloader.calls},
                         {item["bytes"] for item in report["assets"]})
        self.assertFalse(report["latest"]["bridgeIsLatest"])
        self.assertEqual(list(self.fixture.scratch.iterdir()), [])
        evidence = list(self.fixture.evidence.iterdir())
        self.assertEqual(len(evidence), 1)
        self.assertEqual(json.loads(evidence[0].read_text(encoding="utf-8"))["report"]["status"], "published")

    def test_allowlist_is_exactly_three_public_assets(self) -> None:
        _, report, _, client, _, _ = self.run_publisher(publish=True)
        names = {item["name"] for item in report["assets"]}
        self.assertEqual(names, {
            "Floe-iOS-Bridge-1.0.0-unsigned.ipa",
            "Floe-iOS-Bridge-1.0.0-unsigned.ipa.sha256",
            "Floe-iOS-Bridge-1.0.0-public.json",
        })
        uploads = [call for call in client.calls if call[0] == "upload_asset"]
        self.assertEqual(len(uploads), 3)
        for call in uploads:
            self.assertNotIn("dSYM", call[2])
            self.assertNotIn("mobileprovision", call[2])
            self.assertNotIn("manifest", call[2])
            self.assertNotIn("receipt", call[2])

    def test_only_the_bridge_tag_is_written(self) -> None:
        _, _, _, client, _, _ = self.run_publisher(publish=True)
        for call in client.mutation_calls():
            if call[0] == "create_release":
                payload = call[1]
            elif call[0] == "update_release":
                payload = call[2]
            else:
                continue
            rendered = json.dumps(payload)
            self.assertNotIn("v1.7.65", rendered)
            self.assertNotIn("floe-bridge-", rendered)
            if "tag_name" in payload:
                self.assertEqual(payload["tag_name"], self.fixture.tag)
        updates = [c for c in client.calls if c[0] == "update_release"]
        self.assertTrue(updates)
        self.assertNotEqual(updates[0][1], 1)  # never the existing latest release id

    def test_public_report_has_no_private_content(self) -> None:
        _, report, _, _, _, _ = self.run_publisher(publish=True)
        rendered = json.dumps(report)
        self.assertNotIn("Floe iOS Bridge 1.0.0 (build 14).", rendered)
        self.assertNotIn("floe-ios-bridge-qualification-v1", rendered)
        self.assertNotIn("/Users/", rendered)
        self.assertNotIn("/Volumes/", rendered)
        self.assertNotIn("Local/Private", rendered)
        self.assertNotIn("Local/Scratch", rendered)
        self.assertEqual(report["notes"]["bytes"], self.fixture.notes.stat().st_size)
        self.assertRegex(report["notes"]["sha256"], r"^[0-9a-f]{64}$")

    # --- uncertain API outcomes and resumes ---------------------------
    def test_uncertain_create_is_reconciled_not_retried(self) -> None:
        client = self.fixture.client()
        client.create_behavior = "accept_then_raise"
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published")
        self.assertEqual(len([c for c in client.calls if c[0] == "create_release"]), 1)
        self.assertEqual(len([c for c in client.calls if c[0] == "upload_asset"]), 3)

    def test_create_without_state_is_uncertain_and_stops(self) -> None:
        client = self.fixture.client()
        client.create_behavior = "raise_no_state"
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 3)
        self.assertEqual(report["status"], "uncertain")
        self.assertEqual(len([c for c in client.calls if c[0] == "create_release"]), 1)
        self.assertEqual([c for c in client.calls if c[0] == "upload_asset"], [])
        self.assertEqual([c for c in client.calls if c[0] == "update_release"], [])

    def test_existing_draft_resumes_only_missing_assets(self) -> None:
        client = self.fixture.client()
        client.seed_release(draft=True, assets={self.fixture.ipa.name: self.fixture.ipa.read_bytes()})
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published")
        uploads = [c for c in client.calls if c[0] == "upload_asset"]
        self.assertEqual({c[2] for c in uploads}, {self.fixture.sidecar.name, self.fixture.summary.name})
        self.assertEqual(len([c for c in client.calls if c[0] == "update_release"]), 1)
        downloaded = [c[1] for c in client.calls if c[0] == "download_asset"]
        self.assertIn(self.fixture.ipa.name, downloaded)

    def test_duplicate_create_422_reconciles_existing_draft(self) -> None:
        client = self.fixture.client()
        client.seed_release(
            draft=True,
            assets={self.fixture.ipa.name: self.fixture.ipa.read_bytes()},
        )
        client.hide_existing_once = True
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published")
        self.assertEqual(len([c for c in client.calls if c[0] == "create_release"]), 1)
        uploads = [c for c in client.calls if c[0] == "upload_asset"]
        self.assertEqual({c[2] for c in uploads}, {self.fixture.sidecar.name, self.fixture.summary.name})

    def test_existing_draft_branch_target_is_accepted_when_tag_binds(self) -> None:
        client = self.fixture.client()
        client.seed_release(
            draft=True,
            target="main",
            assets={self.fixture.ipa.name: self.fixture.ipa.read_bytes()},
        )
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published")
        self.assertEqual(len([c for c in client.calls if c[0] == "update_release"]), 1)

    def test_existing_draft_conflicting_explicit_target_is_rejected(self) -> None:
        client = self.fixture.client()
        client.seed_release(
            draft=True,
            target="b" * 40,
            assets={self.fixture.ipa.name: self.fixture.ipa.read_bytes()},
        )
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(report["status"], "preflight-failed")
        self.assertEqual([c for c in client.calls if c[0] == "upload_asset"], [])

    def test_existing_draft_wrong_digest_is_rejected_without_clobber(self) -> None:
        client = self.fixture.client()
        wrong = b"x" * self.fixture.ipa.stat().st_size
        client.seed_release(draft=True, assets={self.fixture.ipa.name: wrong})
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(report["status"], "preflight-failed")
        self.assertEqual([c for c in client.calls if c[0] == "upload_asset"], [])
        self.assertEqual([c for c in client.calls if c[0] == "update_release"], [])

    def test_existing_draft_extra_asset_is_rejected(self) -> None:
        client = self.fixture.client()
        client.seed_release(
            draft=True,
            assets={
                self.fixture.ipa.name: self.fixture.ipa.read_bytes(),
                "BridgeHost.app.dSYM.zip": b"symbols",
            },
        )
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(report["status"], "preflight-failed")
        self.assertEqual([c for c in client.calls if c[0] == "upload_asset"], [])

    def test_permanently_missing_asset_never_flips_source_only_release(self) -> None:
        client = self.fixture.client()
        client.upload_behaviors[self.fixture.summary.name] = "raise_no_state"
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 3)
        self.assertEqual(report["status"], "uncertain")
        self.assertEqual([c for c in client.calls if c[0] == "update_release"], [])

    def test_uncertain_upload_is_reconciled(self) -> None:
        client = self.fixture.client()
        client.upload_behaviors[self.fixture.ipa.name] = "accept_then_raise"
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published")
        uploads = [c for c in client.calls if c[0] == "upload_asset"]
        self.assertEqual(len(uploads), 3)

    def test_draft_download_failure_prevents_flip(self) -> None:
        client = self.fixture.client()
        client.download_failures.add(self.fixture.sidecar.name)
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 3)
        self.assertEqual(report["status"], "publication-failed")
        self.assertEqual([c for c in client.calls if c[0] == "update_release"], [])
        self.assertTrue(report["release"] is None or report["release"].get("draft") is not False)

    def test_uncertain_flip_is_reconciled(self) -> None:
        client = self.fixture.client()
        client.update_behavior = "accept_then_raise"
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published")
        self.assertEqual(len([c for c in client.calls if c[0] == "update_release"]), 1)

    def test_public_readback_failure_is_not_complete(self) -> None:
        downloader = support.FakeDownloader({
            f"https://github.com/JiangNanGenius/floe-agent/releases/download/{self.fixture.tag}/{name}": data
            for name, data in self.fixture.assets().items()
        })
        downloader.failures.add(
            f"https://github.com/JiangNanGenius/floe-agent/releases/download/{self.fixture.tag}/{self.fixture.sidecar.name}"
        )
        code, report, _, client, _, _ = self.run_publisher(publish=True, downloader=downloader)
        self.assertEqual(code, 4)
        self.assertEqual(report["status"], "public-readback-failed")
        self.assertFalse(report["complete"])
        self.assertEqual(len([c for c in client.calls if c[0] == "update_release"]), 1)
        self.assertEqual(len([c for c in client.calls if c[0] == "create_release"]), 1)

    # --- idempotence and conflicts ------------------------------------
    def test_already_published_is_read_only_complete(self) -> None:
        client = self.fixture.client()
        client.seed_release(draft=False, assets=self.fixture.assets())
        code, report, _, client, _, downloader = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "already-published")
        self.assertTrue(report["complete"])
        self.assertEqual(client.mutation_calls(), [])
        self.assertEqual(len(downloader.calls), 3)

    def test_published_wrong_digest_is_rejected(self) -> None:
        client = self.fixture.client()
        wrong = b"x" * self.fixture.ipa.stat().st_size
        client.seed_release(draft=False, assets={
            self.fixture.ipa.name: wrong,
            self.fixture.sidecar.name: self.fixture.sidecar.read_bytes(),
            self.fixture.summary.name: self.fixture.summary.read_bytes(),
        })
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_published_extra_asset_is_rejected(self) -> None:
        client = self.fixture.client()
        assets = self.fixture.assets()
        assets["BridgeHost.app.dSYM.zip"] = b"symbols"
        client.seed_release(draft=False, assets=assets)
        code, _, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_published_prerelease_is_rejected(self) -> None:
        client = self.fixture.client()
        client.seed_release(draft=False, assets=self.fixture.assets(), prerelease=True)
        code, _, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    # --- source, tag, receipt, notes and summary gates ----------------
    def test_remote_tag_wrong_peel_is_rejected(self) -> None:
        client = self.fixture.client()
        client.tag_peeled = "b" * 40
        code, _, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_remote_annotated_tag_name_mismatch_is_rejected(self) -> None:
        client = self.fixture.client()
        client.tag_object_tag = "floe-ios-bridge-v9.9.9"
        code, _, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_missing_local_tag_is_rejected(self) -> None:
        support.git(self.fixture.repo, "tag", "-d", self.fixture.tag)
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_default_tag_is_canonical_and_reported(self) -> None:
        inputs = self.fixture.inputs(tag=None)
        code, report, _, client, _, _ = self.run_publisher(inputs=inputs)
        self.assertEqual(code, 0)
        self.assertEqual(report["tag"], self.fixture.tag)
        self.assertEqual(client.mutation_calls(), [])

    def test_tag_version_mismatch_is_rejected(self) -> None:
        inputs = self.fixture.inputs(tag="floe-ios-bridge-v2.0.0")
        code, _, _, client, _, _ = self.run_publisher(publish=True, inputs=inputs)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_non_hex_source_ref_is_rejected(self) -> None:
        inputs = self.fixture.inputs(source_ref="HEAD")
        code, _, _, client, _, _ = self.run_publisher(publish=True, inputs=inputs)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_build_below_release_minimum_is_rejected(self) -> None:
        inputs = self.fixture.inputs(build="13")
        code, _, _, client, _, _ = self.run_publisher(publish=True, inputs=inputs)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_notes_private_path_is_rejected(self) -> None:
        self.fixture.notes.write_text("See /Users/alice/private/release.md\n", encoding="utf-8")
        code, report, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertIn("private or secret", report["error"])
        self.assertEqual(client.mutation_calls(), [])

    def test_notes_private_key_is_rejected(self) -> None:
        self.fixture.notes.write_text("-----BEGIN PRIVATE KEY-----\nAAAA\n", encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_notes_oversize_is_rejected(self) -> None:
        self.fixture.notes.write_text("A" * (pub.MAX_NOTES_BYTES + 1), encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_receipt_false_check_is_rejected(self) -> None:
        payload = self.fixture.receipt_payload()
        payload["checks"]["iphoneLocalControl"] = False
        self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
        code, report, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertIn("iphoneLocalControl", report["error"])
        self.assertEqual(client.mutation_calls(), [])

    def test_owner_assumed_reboot_is_disclosed_without_claiming_a_device_test(self) -> None:
        payload = self.fixture.receipt_payload()
        payload["checks"]["rebootRecovery"] = pub.REBOOT_OWNER_ASSUMPTION
        self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
        self.fixture.notes.write_text(self.fixture.notes.read_text() + "\n" + pub.REBOOT_ASSUMPTION_NOTE + "\n")
        code, report, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 0)
        self.assertIn(pub.REBOOT_ASSUMPTION_NOTE, report["limitations"])
        self.assertTrue(report["complete"])

    def test_owner_assumed_reboot_requires_public_disclosure(self) -> None:
        payload = self.fixture.receipt_payload()
        payload["checks"]["rebootRecovery"] = pub.REBOOT_OWNER_ASSUMPTION
        self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
        code, report, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertIn("disclose", report["error"])
        self.assertEqual(client.mutation_calls(), [])

    def test_other_physical_checks_cannot_be_assumed(self) -> None:
        payload = self.fixture.receipt_payload()
        payload["checks"]["nativeDDIRecovery"] = pub.REBOOT_OWNER_ASSUMPTION
        self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
        code, report, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertIn("nativeDDIRecovery", report["error"])
        self.assertEqual(client.mutation_calls(), [])

    def test_owner_core_smoke_scope_is_explicit_and_public(self) -> None:
        payload = self.fixture.receipt_payload()
        for name in pub.CORE_SMOKE_DEFERRED_CHECKS:
            payload["checks"][name] = pub.CORE_SMOKE_NOT_REQUIRED
        self.fixture.receipt.write_text(json.dumps(payload))
        self.fixture.notes.write_text(self.fixture.notes.read_text() + "\n" + pub.CORE_SMOKE_SCOPE_NOTE + "\n")
        code, report, _, _, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 0)
        self.assertIn(pub.CORE_SMOKE_SCOPE_NOTE, report["limitations"])

    def test_owner_core_smoke_scope_requires_disclosure(self) -> None:
        payload = self.fixture.receipt_payload()
        for name in pub.CORE_SMOKE_DEFERRED_CHECKS:
            payload["checks"][name] = pub.CORE_SMOKE_NOT_REQUIRED
        self.fixture.receipt.write_text(json.dumps(payload))
        code, report, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertIn("disclose", report["error"])
        self.assertEqual(client.mutation_calls(), [])

    def test_owner_core_smoke_scope_cannot_omit_other_or_partial_checks(self) -> None:
        for names in ({"nativeDDIRecovery"}, {"packageSigning", "nativeDDIRecovery"},
                      set(pub.CORE_SMOKE_DEFERRED_CHECKS) | {"authentication"}):
            with self.subTest(names=sorted(names)):
                payload = self.fixture.receipt_payload()
                for name in names:
                    payload["checks"][name] = pub.CORE_SMOKE_NOT_REQUIRED
                self.fixture.receipt.write_text(json.dumps(payload))
                with self.assertRaises(pub.PublicationAbort):
                    pub.validate_receipt(self.fixture.receipt, source_ref=payload["sourceRef"],
                                         source_tree_sha256=payload["sourceTreeSHA256"],
                                         ipa_sha256=payload["ipaSHA256"], version=payload["marketingVersion"],
                                         build=payload["buildNumber"])

    def test_reboot_false_and_unknown_assumptions_remain_rejected(self) -> None:
        for value in (False, "assumed", 1):
            with self.subTest(value=value):
                payload = self.fixture.receipt_payload()
                payload["checks"]["rebootRecovery"] = value
                self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaises(pub.PublicationAbort):
                    pub.validate_receipt(self.fixture.receipt, source_ref=payload["sourceRef"],
                                         source_tree_sha256=payload["sourceTreeSHA256"],
                                         ipa_sha256=payload["ipaSHA256"],
                                         version=payload["marketingVersion"], build=payload["buildNumber"])

    def test_receipt_unknown_field_is_rejected(self) -> None:
        payload = self.fixture.receipt_payload()
        payload["udid"] = "0000000000000000000000000000000000000000"
        self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_receipt_source_mismatch_is_rejected(self) -> None:
        payload = self.fixture.receipt_payload()
        payload["sourceRef"] = "b" * 40
        self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_receipt_ipad_value_is_rejected(self) -> None:
        payload = self.fixture.receipt_payload()
        payload["ipadQualification"] = "tested"
        self.fixture.receipt.write_text(json.dumps(payload), encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_summary_custom_bundle_ids_are_rejected(self) -> None:
        payload = json.loads(self.fixture.summary.read_text(encoding="utf-8"))
        payload["bundleIdentifier"] = "com.example.floe.bridge"
        self.fixture.summary.write_text(json.dumps(payload), encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_summary_wrong_topology_is_rejected(self) -> None:
        payload = json.loads(self.fixture.summary.read_text(encoding="utf-8"))
        payload["topology"]["appExtensions"] = 2
        self.fixture.summary.write_text(json.dumps(payload), encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_summary_source_mismatch_is_rejected(self) -> None:
        payload = json.loads(self.fixture.summary.read_text(encoding="utf-8"))
        payload["sourceRef"] = "b" * 40
        self.fixture.summary.write_text(json.dumps(payload), encoding="utf-8")
        code, _, _, client, _, _ = self.run_publisher(publish=True)
        self.assertEqual(code, 2)
        self.assertEqual(client.mutation_calls(), [])

    def test_signed_ipa_archive_is_rejected(self) -> None:
        support.make_ipa(self.fixture.ipa, signed=True)
        with self.assertRaises(pub.PublicationAbort):
            pub.validate_ipa_archive(self.fixture.ipa)

    def test_ipa_profile_only_archive_is_rejected(self) -> None:
        support.make_ipa(
            self.fixture.ipa,
            extra={"Payload/BridgeHost.app/embedded.mobileprovision": b"profile"},
        )
        with self.assertRaises(pub.PublicationAbort):
            pub.validate_ipa_archive(self.fixture.ipa)

    def test_verifier_failure_blocks_all_writers(self) -> None:
        verifier = support.FakeVerifier(self.fixture.provenance["sourceTreeSHA256"])
        verifier.responses = [{"ok": False, "checks": [{"name": "artifact", "ok": False}]}]
        code, report, _, client, _, _ = self.run_publisher(
            publish=True, verifier=verifier
        )
        self.assertEqual(code, 2)
        self.assertEqual(report["status"], "preflight-failed")
        self.assertEqual(client.mutation_calls(), [])

    # --- latest pointer -------------------------------------------------
    def test_latest_concurrency_is_reported_without_reset(self) -> None:
        client = self.fixture.client()
        client.latest_after_publish = "v1.7.66"
        verifier = support.FakeVerifier(self.fixture.provenance["sourceTreeSHA256"])
        verifier.responses = [
            {"ok": True},
            {"ok": True},
            {"ok": False, "checks": [{"name": "latest-pointer-unchanged", "ok": False}]},
            {"ok": True},
        ]
        code, report, _, client, verifier, _ = self.run_publisher(
            publish=True, client=client, verifier=verifier
        )
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "published-with-latest-concurrency-review")
        self.assertTrue(report["latest"]["concurrencyReviewPending"])
        self.assertFalse(report["latest"]["bridgeIsLatest"])
        self.assertEqual(len(verifier.calls), 4)
        self.assertEqual(verifier.calls[-1]["expect_latest_tag"], "v1.7.66")
        self.assertEqual([c for c in client.calls if c[0] == "update_release"][0][2],
                         {"draft": False, "prerelease": False, "make_latest": "false"})

    def test_bridge_becoming_latest_is_a_hard_failure(self) -> None:
        client = self.fixture.client()
        client.latest_after_publish = self.fixture.tag
        code, report, _, client, _, _ = self.run_publisher(publish=True, client=client)
        self.assertEqual(code, 4)
        self.assertEqual(report["status"], "public-readback-failed")
        self.assertFalse(report["complete"])
        self.assertEqual(len([c for c in client.calls if c[0] == "update_release"]), 1)


if __name__ == "__main__":
    unittest.main()
