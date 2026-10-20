#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mutation/negative tests for the read-only Settings-domain checkers.

These tests do not execute application code. They mutate in-memory copies of
the candidate JSON/source projections and prove that the checkers still reject
dropped/duplicate/changed legacy entries, wrong counts/goals/statuses, missing
operation/fixture/source mappings and stale history digests.

Run from the validation overlay (or set FLOE_SETTINGS_TEST_ROOT):

    python3 -m unittest discover -s FloeAndroid/scripts/tests \
        -p 'test_settings_domain_checks.py' -v
"""
from __future__ import annotations

import copy
import importlib.util
import json
import os
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve()
BASE = HERE.parents[3]
ROOT = Path(os.environ.get(
    "FLOE_SETTINGS_TEST_ROOT",
    BASE / "validation-overlay" if (BASE / "validation-overlay").is_dir()
    else BASE,
)).resolve()


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


CHECKS = load_module("check_settings_domain",
                     ROOT / "FloeAndroid/scripts/check-settings-domain.py")
FIXTURES = load_module("check_fixtures",
                       ROOT / "FloeAndroid/scripts/check-fixtures.py")


def read_json(relative: str):
    return json.loads((ROOT / relative).read_text(encoding="utf-8"))


def load_projection():
    golden = read_json("FloeAndroid/planning/bridge-v3-command-matrix.golden.json")
    bridge = (ROOT / "FloeAndroid/shared/Sources/FloeAndroidCore/BridgeEnvelopeV3.swift").read_text()
    kotlin = (ROOT / "FloeAndroid/core/contracts/src/main/kotlin/com/floe/android/contracts/BridgeV3Contracts.kt").read_text()
    return (golden, CHECKS.parse_swift_matrix(bridge),
            CHECKS.parse_kotlin_matrix(kotlin),
            CHECKS.parse_swift_labels(bridge),
            CHECKS.parse_kotlin_labels(kotlin))


def load_baseline_projection():
    return (read_json("FloeAndroid/planning/feature-baseline.json"),
            read_json("FloeAndroid/planning/work-packages.json"),
            read_json("FloeAndroid/fixtures/inventory.json"))


class SettingsDomainCheckerTests(unittest.TestCase):
    def setUp(self):
        CHECKS.FAILURES.clear()
        FIXTURES.failures.clear()

    # -- matrix ---------------------------------------------------------

    def test_valid_projection_passes(self):
        golden, swift, kotlin, swift_labels, kotlin_labels = load_projection()
        CHECKS.validate_matrix(golden, swift, kotlin, swift_labels, kotlin_labels)
        self.assertEqual(CHECKS.FAILURES, [])

    def test_matrix_rejects_dropped_and_duplicate_legacy_entries(self):
        golden, swift, kotlin, swift_labels, kotlin_labels = load_projection()
        dropped = copy.deepcopy(swift)
        dropped.pop(0)
        CHECKS.validate_matrix(golden, dropped, kotlin, swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "dropped legacy entry was accepted")

        CHECKS.FAILURES.clear()
        duplicated = copy.deepcopy(swift)
        duplicated.insert(1, copy.deepcopy(duplicated[0]))
        CHECKS.validate_matrix(golden, duplicated, kotlin, swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "duplicate entry was accepted")

    def test_matrix_rejects_relabel_and_count_changes(self):
        golden, swift, kotlin, swift_labels, kotlin_labels = load_projection()
        relabelled = copy.deepcopy(swift)
        relabelled[-1]["configurationScope"] = "settings.defaults"
        CHECKS.validate_matrix(golden, relabelled, kotlin, swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "relabelled privacy entry was accepted")

        CHECKS.FAILURES.clear()
        fewer_labels = swift_labels[:-1]
        CHECKS.validate_matrix(golden, swift, kotlin, fewer_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "18 labels were accepted")

        CHECKS.FAILURES.clear()
        CHECKS.validate_matrix(golden, swift, kotlin[:-1], swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "Kotlin mirror truncation was accepted")

    def test_matrix_rejects_changed_legacy_command(self):
        golden, swift, kotlin, swift_labels, kotlin_labels = load_projection()
        changed = copy.deepcopy(swift)
        changed[0]["command"] = "config.defaults.get"
        CHECKS.validate_matrix(golden, changed, kotlin, swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "changed legacy command was accepted")

    # -- baseline -------------------------------------------------------

    def test_baseline_rejects_old_identity_goal_and_status_changes(self):
        baseline, packages, inventory = load_baseline_projection()
        ops = [op for fam in baseline["families"]
               for op in fam["operations"] if op["id"] not in CHECKS.SET_OPERATION_IDS]
        mutated = copy.deepcopy(baseline)
        next(op for fam in mutated["families"] for op in fam["operations"]
             if op["id"] == ops[0]["id"])["goal"] = "G11"
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "old goal change was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        next(op for fam in mutated["families"] for op in fam["operations"]
             if op["id"] == ops[0]["id"])["status"] = "implementing"
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "old status change was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        for fam in mutated["families"]:
            fam["operations"] = [op for op in fam["operations"]
                                 if op["id"] != ops[0]["id"]]
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "dropped old operation was accepted")

    def test_baseline_rejects_wrong_new_status_and_missing_mapping(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated = copy.deepcopy(baseline)
        target = next(op for fam in mutated["families"] for op in fam["operations"]
                      if op["id"] == "SET-DEFAULTS-TYPED")
        target["status"] = "component_verified"
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "unverified component status was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        for fam in mutated["families"]:
            fam["operations"] = [op for op in fam["operations"]
                                 if op["id"] != "SET-USAGE-AGGREGATE"]
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "missing additive operation was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        next(op for fam in mutated["families"] for op in fam["operations"]
             if op["id"] == "SET-MEMORY-SEARCH")["fixtures"] = ["memory/candidates.json"]
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "wrong fixture mapping was accepted")

        CHECKS.FAILURES.clear()
        mutated_inventory = copy.deepcopy(inventory)
        mutated_inventory["entries"] = [e for e in mutated_inventory["entries"]
                                        if e["path"] != "usage/aggregates.json"]
        CHECKS.validate_baseline(baseline, packages, mutated_inventory)
        self.assertTrue(CHECKS.FAILURES, "missing fixture group was accepted")

    def test_baseline_rejects_stale_history_and_duplicate_family(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated = copy.deepcopy(baseline)
        mutated["settingsDomainAdditive"]["previousOperationIdDigest"] = "0" * 64
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "stale history digest was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        mutated["baselineHistory"]["currentDeclaredCounts"]["operations"] = 171
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "prior reconciliation rewrite was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        set_family = next(f for f in mutated["families"] if f["id"] == "SET")
        mutated["families"].append(copy.deepcopy(set_family))
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "duplicate SET family was accepted")

    def test_baseline_rejects_package_status_change(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated_packages = copy.deepcopy(packages)
        mutable = next(p for p in mutated_packages["packages"] if p["id"] == "P1.2")
        mutable["status"] = "implementing"
        CHECKS.validate_baseline(baseline, mutated_packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "package status change was accepted")

    # -- check-fixtures cross-checks -----------------------------------

    def test_check_fixtures_rejects_old_status_and_missing_fixture(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated = copy.deepcopy(baseline)
        next(op for fam in mutated["families"] for op in fam["operations"]
             if op["id"] == "SET-MEMORY-SEARCH")["status"] = "implementing"
        ops = {op["id"]: op for fam in mutated["families"]
               for op in fam["operations"]}
        FIXTURES.check_baseline_history(mutated, ops, inventory)
        self.assertTrue(FIXTURES.failures, "check-fixtures accepted a status change")

        FIXTURES.failures.clear()
        mutated_inventory = copy.deepcopy(inventory)
        mutated_inventory["entries"] = [e for e in mutated_inventory["entries"]
                                        if e["path"] != "settings/defaults-cas.json"]
        FIXTURES.check_settings_fixture_records(mutated_inventory)
        self.assertTrue(FIXTURES.failures, "check-fixtures accepted a missing fixture")

    def test_fixture_rejects_execution_claim_and_case_drop(self):
        inventory = read_json("FloeAndroid/fixtures/inventory.json")
        entry = next(e for e in inventory["entries"]
                     if e["path"] == "settings/defaults-cas.json")
        doc = json.loads((ROOT / "FloeAndroid/fixtures/settings/defaults-cas.json")
                         .read_text(encoding="utf-8"))
        doc["executed"] = True
        FIXTURES.check_settings_fixture(entry, json.dumps(doc).encode("utf-8"))
        self.assertTrue(FIXTURES.failures, "execution claim was accepted")

        FIXTURES.failures.clear()
        doc = json.loads((ROOT / "FloeAndroid/fixtures/settings/defaults-cas.json")
                         .read_text(encoding="utf-8"))
        doc["cases"] = doc["cases"][:-1]
        FIXTURES.check_settings_fixture(entry, json.dumps(doc).encode("utf-8"))
        self.assertTrue(FIXTURES.failures, "dropped case id was accepted")

    def test_full_checker_passes_on_candidate_overlay(self):
        failures, summary = CHECKS.validate_all(ROOT)
        self.assertEqual(failures, [])
        self.assertEqual(summary["entries"], 84)
        self.assertEqual(summary["operations"], 182)
        self.assertEqual(summary["fixtures"], 33)


    def test_baseline_rejects_missing_command_mapping(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated = copy.deepcopy(baseline)
        target = next(op for fam in mutated["families"] for op in fam["operations"]
                      if op["id"] == "SET-USAGE-AGGREGATE")
        target.pop("commands", None)
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES,
                        "missing command mapping was accepted")

    def test_matrix_rejects_ambiguous_label_and_private_authority(self):
        golden, swift, kotlin, swift_labels, kotlin_labels = load_projection()
        mutated = copy.deepcopy(golden)
        # Make the third content.read entry collide with the conversations
        # entry on the full uniqueness key.
        mutated["entries"][-5]["configurationScope"] = "conversations"
        CHECKS.validate_matrix(mutated, swift, kotlin, swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "ambiguous label collision was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(golden)
        mutated["authority"] = ("Local/Private/example/input/contract.json "
                                "SHA256 " + "0" * 64)
        CHECKS.validate_matrix(mutated, swift, kotlin, swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "private/old authority was accepted")

    def test_baseline_rejects_stale_final_contract_hash(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated = copy.deepcopy(baseline)
        mutated["settingsDomainAdditive"]["contractSHA256"] = "0" * 64
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "stale contract hash was accepted")

    def test_fixture_rejects_secret_reference_and_budget_shape(self):
        privacy_entry = next(e for e in read_json("FloeAndroid/fixtures/inventory.json")["entries"]
                             if e["path"] == "privacy/identity-streams.json")
        privacy = read_json("FloeAndroid/fixtures/privacy/identity-streams.json")
        privacy["vectors"] = [v for v in privacy["vectors"]
                              if v["id"] != "model-config-secret-references"]
        privacy["vectors"].append({
            "id": "model-config-secret-references",
            "sets": ["providers", "models", "preferences"],
        })
        FIXTURES.check_settings_fixture(
            privacy_entry, json.dumps(privacy).encode("utf-8"))
        self.assertTrue(FIXTURES.failures, "missing secret-reference shape was accepted")

        FIXTURES.failures.clear()
        personalization_entry = next(
            e for e in read_json("FloeAndroid/fixtures/inventory.json")["entries"]
            if e["path"] == "personalization/documents.json")
        personalization = read_json("FloeAndroid/fixtures/personalization/documents.json")
        next(v for v in personalization["vectors"]
             if v["id"] == "content-24000-cjk")["frameBound"] = 65_535
        FIXTURES.check_settings_fixture(
            personalization_entry, json.dumps(personalization).encode("utf-8"))
        self.assertTrue(FIXTURES.failures, "weakened frame bound was accepted")

        FIXTURES.failures.clear()
        memory_entry = next(e for e in read_json("FloeAndroid/fixtures/inventory.json")["entries"]
                            if e["path"] == "memory/inventory.json")
        memory = read_json("FloeAndroid/fixtures/memory/inventory.json")
        next(v for v in memory["vectors"]
             if v["id"] == "paging-120")["wireDefaultLimit"] = 100
        FIXTURES.check_settings_fixture(
            memory_entry, json.dumps(memory).encode("utf-8"))
        self.assertTrue(FIXTURES.failures, "wrong wire default was accepted")

    def test_digest_source_rejects_type_tag_mutation(self):
        swift = (ROOT / "FloeAndroid/shared/Sources/FloeAndroidCore/SettingsDomainV1.swift").read_text()
        mutated = swift.replace(
            "case .integer(let value):\n                data.append(0x01)",
            "case .integer(let value):\n                data.append(0x05)")
        self.assertNotEqual(mutated, swift)
        CHECKS.validate_swift_digest_source(mutated)
        self.assertTrue(CHECKS.FAILURES, "Swift type-tag mutation was accepted")

        CHECKS.FAILURES.clear()
        kotlin = (ROOT / "FloeAndroid/core/contracts/src/main/kotlin/com/floe/android/contracts/SettingsDomainV1.kt").read_text()
        mutated = kotlin.replace(
            "is Field.Integer -> {\n                    buffer.write(0x01)",
            "is Field.Integer -> {\n                    buffer.write(0x05)")
        self.assertNotEqual(mutated, kotlin)
        CHECKS.validate_kotlin_digest_source(mutated)
        self.assertTrue(CHECKS.FAILURES, "Kotlin type-tag mutation was accepted")

    def test_source_presence_rejects_missing_path(self):
        CHECKS.FAILURES.clear()
        self.assertFalse(CHECKS.require_file(
            ROOT,
            "FloeAndroid/shared/Sources/FloeAndroidCore/DoesNotExist.swift",
        ))
        self.assertTrue(CHECKS.FAILURES, "missing source path was accepted")

if __name__ == "__main__":
    unittest.main()
