#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mutation/negative tests for the read-only Settings-domain checkers.

These tests do not execute application code. They mutate in-memory copies of
the candidate JSON/source projections and prove that the checkers still reject
dropped/duplicate/changed legacy entries, wrong counts/goals/statuses, missing
operation/fixture/source mappings and stale history digests. Since the
goal-core (run-control) additive integration they additionally prove: the
frozen 57/27 tuple tables and prior 172/182 ledgers survive the approved
87-row / 183-operation additions unchanged; every tampering of the new
goal-core tail, record metadata (including the corrected 33-fixture count),
operation identity/goal/status, unapproved extra rows/operations and the
inventory header is refused.

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
# The standalone approved goal-core delta module (same module object the
# checkers validated their append against; loaded via the checker's path so
# the test works with any importlib layout).
G = CHECKS.G


def live_golden_rows():
    return read_json(
        "FloeAndroid/planning/bridge-v3-command-matrix.golden.json")["entries"]


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
        # The last row is now the approved conversation.compact entry; a
        # relabel of the goal-core tail must also be refused.
        relabelled[-1]["configurationScope"] = "settings.defaults"
        CHECKS.validate_matrix(golden, relabelled, kotlin, swift_labels, kotlin_labels)
        self.assertTrue(CHECKS.FAILURES, "relabelled goal-core tail entry was accepted")

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
        ops = [op for fam in baseline["families"] for op in fam["operations"]
               if op["id"] not in CHECKS.SET_OPERATION_IDS
               and op["id"] != G.GOALCORE_OPERATION_ID]
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
        self.assertEqual(summary["entries"], 90)
        self.assertEqual(summary["legacyEntries"], 57)
        self.assertEqual(summary["settingsAdditiveEntries"], 27)
        self.assertEqual(summary["goalCoreAdditiveEntries"], 3)
        self.assertEqual(summary["additiveEntries"], 33)
        self.assertEqual(summary["operations"], 183)
        self.assertEqual(summary["g02Operations"], 41)
        self.assertEqual(summary["fixtures"], 33)
        self.assertEqual(summary["labels"], 19)
        self.assertEqual(summary["packages"], 85)

    def test_full_fixture_checker_passes_on_live_tree(self):
        inv = FIXTURES.check_inventory()
        self.assertEqual(FIXTURES.failures, [])
        ops = FIXTURES.check_baseline(inv)
        self.assertEqual(FIXTURES.failures, [])
        FIXTURES.check_cross_references(inv, ops)
        self.assertEqual(FIXTURES.failures, [])
        self.assertEqual(len(ops), 183)
        self.assertEqual(len(inv["entries"]), 33)


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
        # entry on the full uniqueness key. Locate it by identity, not by a
        # tail-relative index, so the goal-core append cannot shift it.
        personalization_index = next(
            i for i, row in enumerate(mutated["entries"])
            if row["command"] == "content.read"
            and row["configurationScope"] == "personalization")
        mutated["entries"][personalization_index]["configurationScope"] = \
            "conversations"
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


class GoalCoreDeltaTests(unittest.TestCase):
    """The approved 2026-10-21 goal-core additive delta and its refusals."""

    def setUp(self):
        CHECKS.FAILURES.clear()
        FIXTURES.failures.clear()

    # -- preservation: frozen history survives the append ----------------

    def test_frozen_legacy_and_settings_tables_survive_the_append(self):
        rows = live_golden_rows()[:G.EXPECTED_MATRIX_ENTRIES]
        self.assertEqual(len(rows), 87)
        # The OLD independent digests still hold verbatim on their own
        # sections — never recomputed to pass.
        self.assertEqual(CHECKS.tuple_digest(rows[:57]),
                         CHECKS.EXPECTED_LEGACY_TUPLE_SHA256)
        self.assertEqual(CHECKS.tuple_digest(G.settings_slice(rows)),
                         CHECKS.EXPECTED_ADDITIVE_TUPLE_SHA256)
        # The prior 84-row projection keeps the pre-append ledger shape:
        # 84 unique tuples and 83 scope+command pairs.
        prior = G.project_prior_rows(rows)
        self.assertEqual(len(prior), 84)
        self.assertEqual(len({(r["scope"], r["configurationScope"],
                               r["command"]) for r in prior}), 84)
        self.assertEqual(len({(r["scope"], r["command"]) for r in prior}), 83)
        # The goal-core digest is independent of the frozen ones.
        self.assertEqual(G.GOALCORE_TUPLE_SHA256,
                         G.tuple_digest(G.GOALCORE_COMMAND_ROWS))
        self.assertEqual(G.tuple_digest(G.goalcore_slice(rows)),
                         G.GOALCORE_TUPLE_SHA256)
        self.assertNotEqual(G.GOALCORE_TUPLE_SHA256,
                            CHECKS.EXPECTED_LEGACY_TUPLE_SHA256)
        self.assertNotEqual(G.GOALCORE_TUPLE_SHA256,
                            CHECKS.EXPECTED_ADDITIVE_TUPLE_SHA256)

    def test_prior_182_operation_projection_is_frozen(self):
        baseline, packages, inventory = load_baseline_projection()
        ids = [op["id"] for fam in baseline["families"]
               for op in fam["operations"]]
        self.assertEqual(len(ids), 183)
        prior = G.project_prior_operation_ids(ids)
        self.assertEqual(len(prior), 182)
        old_ledger = [oid for oid in prior if oid not in set(CHECKS.SET_OPERATION_IDS)]
        self.assertEqual(len(old_ledger), 172)
        self.assertEqual(CHECKS.digest_ids(old_ledger),
                         CHECKS.PRIOR_172_OPERATION_ID_DIGEST)

    # -- the approved three tuples are exactly present -------------------

    def test_goalcore_append_is_the_exact_approved_three_tuples(self):
        self.assertEqual(G.validate_goalcore_append(live_golden_rows()[:G.EXPECTED_MATRIX_ENTRIES]), [])

    def test_goalcore_tail_tampering_refused(self):
        rows = live_golden_rows()[:G.EXPECTED_MATRIX_ENTRIES]
        tamperings = [
            (84, "revisionRequired", False),
            (85, "command", "child.create"),
            (85, "revisionRequired", False),
            (86, "scope", "launch"),
            (86, "revisionRequired", True),
            (84, "allowsCreateIntent", True),
            (86, "configurationScope", "conversations"),
            (85, "isRunEventPoll", True),
        ]
        for index, field, value in tamperings:
            CHECKS.FAILURES.clear()
            mutated = copy.deepcopy(rows)
            mutated[index][field] = value
            self.assertTrue(G.validate_goalcore_append(mutated),
                            "tampered tail accepted: entries[%d].%s=%r"
                            % (index, field, value))
            golden = read_json(
                "FloeAndroid/planning/bridge-v3-command-matrix.golden.json")
            golden_mut = copy.deepcopy(golden)
            golden_mut["entries"] = mutated
            _, swift, _, _, _ = load_projection()
            CHECKS.validate_matrix(golden_mut, swift, swift,
                                   golden["configurationLabels"],
                                   golden["configurationLabels"])
            self.assertTrue(CHECKS.FAILURES,
                            "validate_matrix accepted tail tampering: "
                            "entries[%d].%s=%r" % (index, field, value))

    def test_goalcore_tail_removal_or_extra_row_refused(self):
        golden = read_json(
            "FloeAndroid/planning/bridge-v3-command-matrix.golden.json")
        dropped = copy.deepcopy(golden)
        dropped["entries"] = golden["entries"][:84]
        self.assertTrue(G.validate_goalcore_append(dropped["entries"]))
        CHECKS.validate_matrix(dropped, [], [],
                               golden["configurationLabels"],
                               golden["configurationLabels"])
        self.assertTrue(CHECKS.FAILURES, "84-row matrix was accepted")

        CHECKS.FAILURES.clear()
        extra = copy.deepcopy(golden)
        extra["entries"] = golden["entries"] + [
            copy.deepcopy(golden["entries"][86])]
        self.assertTrue(G.validate_goalcore_append(extra["entries"]))
        CHECKS.validate_matrix(extra, [], [],
                               golden["configurationLabels"],
                               golden["configurationLabels"])
        self.assertTrue(CHECKS.FAILURES, "88-row matrix was accepted")

    # -- the ledger record: metadata, counts, identity, status -----------

    def _goalcore_record_mutations(self):
        return [
            ("previous fixture claim rewritten",
             lambda r: r["previousDeclaredCounts"].__setitem__("fixtures", 35)),
            ("current fixture claim rewritten",
             lambda r: r["currentDeclaredCounts"].__setitem__("fixtures", 35)),
            ("operation count weakened",
             lambda r: r["currentDeclaredCounts"].__setitem__("operations", 182)),
            ("g02 count weakened",
             lambda r: r["currentDeclaredCounts"].__setitem__("g02Operations", 40)),
            ("record version rolled back",
             lambda r: r.__setitem__("version", "g02.2026-10-19.1")),
            ("previousVersion changed",
             lambda r: r.__setitem__("previousVersion", "g02.2026-10-18.1")),
            ("unapproved operation id added to the record",
             lambda r: r.__setitem__(
                 "additiveOperationIds",
                 ["CHA-MANUAL-COMPACT", "CHA-SNEAK"])),
            ("fixture claimed as added",
             lambda r: r.__setitem__("additiveFixtureIds", ["FIX-CORE-ONE"])),
            ("fixture path claimed as added",
             lambda r: r.__setitem__("additiveFixturePaths",
                                     ["goal/core.json"])),
            ("recorded operation status advanced",
             lambda r: r["additiveOperations"][0].__setitem__("status",
                                                              "implementing")),
            ("recorded operation goal changed",
             lambda r: r["additiveOperations"][0].__setitem__("goal", "G03")),
            ("recorded operation identity renamed",
             lambda r: r["additiveOperations"][0].__setitem__(
                 "id", "CHA-SOMETHING-ELSE")),
            ("recorded fixture added",
             lambda r: r["additiveOperations"][0].__setitem__(
                 "fixture", "goal/compact.json")),
            ("recorded work packages widened",
             lambda r: r["additiveOperations"][0].__setitem__(
                 "workPackages", ["P2.2", "P2.3", "P2.7", "P2.13"])),
            ("honesty marker removed",
             lambda r: r.__setitem__("status", "DONE")),
        ]

    def test_goalcore_record_metadata_mutations_refused(self):
        baseline, packages, inventory = load_baseline_projection()
        for label, mutate in self._goalcore_record_mutations():
            CHECKS.FAILURES.clear()
            mutated = copy.deepcopy(baseline)
            mutate(mutated["goalCoreRunControlAdditive"])
            CHECKS.validate_baseline(mutated, packages, inventory)
            self.assertTrue(CHECKS.FAILURES,
                            "goal-core record mutation accepted: %s" % label)

    def test_goalcore_record_missing_refused(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated = copy.deepcopy(baseline)
        del mutated["goalCoreRunControlAdditive"]
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "missing goal-core record accepted")

    def test_goalcore_live_operation_identity_goal_status_refused(self):
        baseline, packages, inventory = load_baseline_projection()
        for label, mutate in [
            ("live operation renamed",
             lambda b: self._find_op(b, G.GOALCORE_OPERATION_ID).__setitem__(
                 "id", "CHA-MANUAL-COMPACT2")),
            ("live operation status advanced",
             lambda b: self._find_op(b, G.GOALCORE_OPERATION_ID).__setitem__(
                 "status", "implementing")),
            ("live operation goal changed",
             lambda b: self._find_op(b, G.GOALCORE_OPERATION_ID).__setitem__(
                 "goal", "G03")),
        ]:
            CHECKS.FAILURES.clear()
            mutated = copy.deepcopy(baseline)
            mutate(mutated)
            CHECKS.validate_baseline(mutated, packages, inventory)
            self.assertTrue(CHECKS.FAILURES,
                            "live goal-core mutation accepted: %s" % label)

        # Deletion of the approved operation.
        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        cha = next(f for f in mutated["families"] if f["id"] == "CHA")
        cha["operations"] = [op for op in cha["operations"]
                             if op["id"] != G.GOALCORE_OPERATION_ID]
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "deleted goal-core operation accepted")

        # An unapproved 184th operation.
        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        sneaked = copy.deepcopy(cha["operations"][-1])
        sneaked["id"] = "CHA-SNEAK"
        mutated["families"][0]["operations"].append(sneaked)
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES, "unapproved operation was accepted")

    def test_fixtures_refuses_goalcore_operation_and_header_mutations(self):
        baseline, packages, inventory = load_baseline_projection()
        ops = {op["id"]: op for fam in baseline["families"]
               for op in fam["operations"]}
        # The check-fixtures ledger history accepts the live tree.
        FIXTURES.check_baseline_history(baseline, ops, inventory)
        self.assertEqual(FIXTURES.failures, [])

        # Renamed/removed goal-core operation breaks the CHA frozen order.
        FIXTURES.failures.clear()
        mutated = copy.deepcopy(baseline)
        cha = next(f for f in mutated["families"] if f["id"] == "CHA")
        for op in cha["operations"]:
            if op["id"] == G.GOALCORE_OPERATION_ID:
                op["id"] = "CHA-MANUAL-COMPACT2"
        ops2 = {op["id"]: op for fam in mutated["families"]
                for op in fam["operations"]}
        FIXTURES.check_baseline_history(mutated, ops2, inventory)
        self.assertTrue(FIXTURES.failures, "renamed goal-core id accepted")

        # The real inventory header must track the new baseline; a rolled-
        # back header (or an invented 34th fixture) is refused.
        FIXTURES.failures.clear()
        rolled_back = copy.deepcopy(inventory)
        rolled_back["baselineVersion"] = "g02.2026-10-19.1"
        FIXTURES.check_baseline_history(baseline, ops, rolled_back)
        self.assertTrue(FIXTURES.failures,
                        "rolled-back inventory header accepted")

        FIXTURES.failures.clear()
        extra = copy.deepcopy(inventory)
        extra["entries"].append({"path": "goal/extra.json", "format": "json",
                                 "bytes": 2, "sha256": "0" * 64,
                                 "operations": []})
        FIXTURES.check_baseline_history(baseline, ops, extra)
        self.assertTrue(FIXTURES.failures, "unapproved fixture was accepted")

        # A goal-core assertion-token dilution in the live operation.
        FIXTURES.failures.clear()
        mutated = copy.deepcopy(baseline)
        for op in next(f for f in mutated["families"]
                       if f["id"] == "CHA")["operations"]:
            if op["id"] == G.GOALCORE_OPERATION_ID:
                op["assertions"] = ["compaction works"]
        ops3 = {op["id"]: op for fam in mutated["families"]
                for op in fam["operations"]}
        FIXTURES.check_attachment_operations(mutated, ops3, inventory)
        self.assertTrue(FIXTURES.failures,
                        "diluted goal-core assertions accepted")

    def test_settings_history_record_stays_frozen(self):
        baseline, packages, inventory = load_baseline_projection()
        mutated = copy.deepcopy(baseline)
        mutated["settingsDomainAdditive"]["currentDeclaredCounts"][
            "operations"] = 183
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES,
                        "Settings history count rewrite was accepted")

        CHECKS.FAILURES.clear()
        mutated = copy.deepcopy(baseline)
        mutated["settingsDomainAdditive"]["version"] = "g02.2026-10-21.2"
        CHECKS.validate_baseline(mutated, packages, inventory)
        self.assertTrue(CHECKS.FAILURES,
                        "Settings history version advance was accepted")

    def test_host_and_android_matrix_test_pins_track_90(self):
        host = (ROOT / "FloeAndroid/shared/Tests/FloeAndroidCoreTests/"
                "BridgeEnvelopeV3Tests.swift").read_text(encoding="utf-8")
        self.assertIn("XCTAssertEqual(goldenPairs.count, 90)", host)
        self.assertIn("XCTAssertEqual(Set(goldenKeys).count, 90)", host)
        instrumented = (ROOT / "FloeAndroid/core/swiftbridge/src/androidTest/"
                        "kotlin/com/floe/android/bridge/"
                        "BridgeEnvelopeV3InstrumentedTest.kt"
                        ).read_text(encoding="utf-8")
        self.assertIn("assertEquals(90, BridgeV3CommandMatrix.ENTRIES.size)",
                      instrumented)
        self.assertNotIn("assertEquals(84, BridgeV3CommandMatrix.ENTRIES.size)",
                         instrumented)
        # Every retained assertion of the frozen structure is still present.
        for token in ("assertEquals(19, BridgeProtocolV3.CONFIGURATION_SCOPES.size)",
                      "assertEquals(57, BridgeV3CommandMatrix.ENTRIES.take(57)",
                      "assertEquals(86, BridgeV3CommandMatrix.ENTRIES.map",
                      "assertEquals(BridgeV3CommandMatrix.ENTRIES.size, keys.toSet().size)"):
            self.assertIn(token, instrumented)
        CHECKS.validate_sources(ROOT)
        self.assertEqual(CHECKS.FAILURES, [])

    @staticmethod
    def _find_op(baseline, oid):
        for fam in baseline["families"]:
            for op in fam["operations"]:
                if op["id"] == oid:
                    return op
        raise AssertionError("operation not found: %s" % oid)


class WorkspaceAppendTests(unittest.TestCase):
    def test_exact_tail_and_frozen_prefix_pass(self):
        self.assertEqual(CHECKS.W.validate_workspace_append(live_golden_rows()), [])
        self.assertEqual(G.validate_goalcore_append(live_golden_rows()[:87]), [])

    def test_old_prefix_change_is_rejected(self):
        rows = copy.deepcopy(live_golden_rows())
        rows[86]["revisionRequired"] = True
        self.assertTrue(CHECKS.W.validate_workspace_append(rows))

    def test_workspace_authority_widening_is_rejected(self):
        for field, value in [("scope", "applicationConfiguration"), ("allowsCreateIntent", True),
                             ("revisionRequired", True), ("configurationScope", "memory")]:
            rows = copy.deepcopy(live_golden_rows())
            rows[87][field] = value
            self.assertTrue(CHECKS.W.validate_workspace_append(rows), field)

    def test_missing_duplicate_and_extra_workspace_tuples_are_rejected(self):
        rows = live_golden_rows()
        for bad in [rows[:-1], rows + [rows[-1]], rows[:89] + [rows[87]]]:
            self.assertTrue(CHECKS.W.validate_workspace_append(bad))


if __name__ == "__main__":
    unittest.main()
