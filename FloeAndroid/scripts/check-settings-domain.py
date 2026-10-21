#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only validator for the Settings-domain P0 source candidate.

Verifies, without writing anything:
  1. The Swift and Kotlin v3 matrices are the accepted 87-entry / 19-label
     append-only ledger: the frozen 57 legacy entries, the frozen 27
     Settings-domain additive tuples (each still proven by its OWN digest)
     and exactly the three approved goal-core run-control tuples appended by
     the 2026-10-21 batch (proven independently against goal_core_contract.py,
     never by recomputing the frozen sections). Mirrored field-for-field and
     anchored to the manual golden matrix file; `content.read` keeps its
     three distinct label-aware entries.
  2. The five additive labels are declared exactly once; credentials,
     settings.approval and operations remain reserved without commands. No
     goal-core row widens labels, create-intent or run-event-poll semantics
     and child.create never appears.
  3. The candidate baseline is 183 operations / 41 G02 / 33 fixtures / 36
     families / 85 packages at g02.2026-10-21.2, with exactly one approved
     planned operation (CHA-MANUAL-COMPACT) and zero added fixtures; the
     unchanged historical validation runs on the exact prior 84-row / 182-op
     projection (approved additions removed, historical version restored),
     where the prior 172 operation identities, goals and statuses and the
     36 family / 85 package inventories stay preserved by frozen digest.
     Every new operation is exactly `planned`.
  4. The ten SET-family operations and seven declarative fixture groups map
     both ways, with no duplicate SET family and no lost G11 SET operations.
  5. The typed Swift/Kotlin vocabulary and independent test sources exist and
     contain the closed payload/digest/chunk/outcome contracts. No new handler
     is registered and no business capability is advertised by source alone.

`--check` is the explicit (default) read-only mode. This script has no write
mode. Exit code 0 = all pass.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path


def _load_goal_core_contract():
    """Load the sibling standalone contract module robustly.

    Works when this file is executed directly and when a test imports it via
    importlib (plain `import goal_core_contract` would then miss the path).
    """
    try:
        import goal_core_contract  # type: ignore
        return goal_core_contract
    except ImportError:
        path = Path(__file__).resolve().parent / "goal_core_contract.py"
        spec = importlib.util.spec_from_file_location("goal_core_contract", path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module


G = _load_goal_core_contract()

EXPECTED_ENTRIES = G.EXPECTED_MATRIX_ENTRIES            # 87
EXPECTED_LEGACY_ENTRIES = G.LEGACY_ENTRY_COUNT          # 57
EXPECTED_SETTINGS_ADDITIVE_ENTRIES = G.SETTINGS_ADDITIVE_ENTRY_COUNT  # 27
EXPECTED_GOALCORE_ADDITIVE_ENTRIES = G.GOALCORE_ADDITIVE_ENTRY_COUNT  # 3
EXPECTED_ADDITIVE_ENTRIES = G.EXPECTED_MATRIX_ADDITIVE_ENTRIES  # 30
EXPECTED_LABELS = 19
EXPECTED_NEW_LABELS = 5
EXPECTED_DISTINCT_COMMANDS = G.EXPECTED_DISTINCT_COMMANDS      # 85
EXPECTED_SCOPE_COMMAND_PAIRS = G.EXPECTED_SCOPE_COMMAND_PAIRS  # 86
EXPECTED_CONFIGURATION_ENTRIES = 55
EXPECTED_OPERATIONS = G.EXPECTED_OPERATIONS              # 183
EXPECTED_G02_OPERATIONS = G.EXPECTED_G02_OPERATIONS      # 41
EXPECTED_FIXTURES = G.EXPECTED_FIXTURES                  # 33 (unchanged)
EXPECTED_FAMILIES = G.EXPECTED_FAMILIES
EXPECTED_PACKAGES = G.EXPECTED_PACKAGES
EXPECTED_BASELINE_VERSION = G.BASELINE_VERSION_CURRENT   # g02.2026-10-21.2
EXPECTED_PRIOR_BASELINE_VERSION = G.BASELINE_VERSION_PREVIOUS
EXPECTED_CONTRACT_SHA256 = (
    "f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c")
# Independent tuple-set digests. Legacy rows were read from the frozen live
# 57-entry matrix; additive rows come from the accepted rev3 contract table.
EXPECTED_LEGACY_TUPLE_SHA256 = (
    "ca54be58af9aeeda89b397ecc73c8f980ca430235bb7d28967f50c2a8ef35b0d")
EXPECTED_ADDITIVE_TUPLE_SHA256 = (
    "23f0b98eb0781cb76a44f637157b58167b33516ff5e430e92f26e6ed13c9318f")
EXPECTED_LABELS_SHA256 = (
    "69beddbf13d8b0f4271e4159920f7ee767ce9870bdad35250414b8e9105f0a48")

PRIOR_172_OPERATION_ID_DIGEST = (
    "9c176375513bec3a3fd98ce35796d4c251ce61a24cc334d66027084cd9fd5252")
PRIOR_172_OPERATION_GOAL_DIGEST = (
    "ef3b34295131c51fee3b546a00f62e4288f448dccd33a89f326230a1c3281dec")
PRIOR_172_OPERATION_STATUS_DIGEST = (
    "0b92a1ffb309669eb56187c0200f7c26b81fb28dccbf290d92ed3340dc4f9dab")
PRIOR_FAMILY_GOAL_DIGEST = (
    "d0bf7c06112499ddac48e3cb3a1cdbecad46b62347c6d26957c396fd572f8dca")
PRIOR_PACKAGE_GOAL_DIGEST = (
    "84ae0f94db4ada2aeb5e5a5bd365f075b7abb745f5925786c2e4b865a91c0d46")
PRIOR_PACKAGE_STATUS_DIGEST = (
    "df403a256f2318b67239ee78d74ce4c05700f0b36f385af28fe4187dfd1612f7")
ADDITIVE_10_ID_DIGEST = (
    "eb0b8379d8f37241073e60e91ce1e364cb6bde5df1f1ab77e750bbb0a6049cac")
ADDITIVE_10_STATUS_DIGEST = (
    "5acd2aac81aecf7272521ab770233c5408d40f4d2165c5d7d93ca00ecad68e36")

SET_OPERATION_IDS = [
    "SET-DEFAULTS-TYPED",
    "SET-MEMORY-INVENTORY",
    "SET-MEMORY-SEARCH",
    "SET-MEMORY-CANDIDATE-REVIEW",
    "SET-MEMORY-ORGANIZE",
    "SET-PERSONALIZATION-DOCUMENTS",
    "SET-PERSONALIZATION-GENERATE",
    "SET-USAGE-AGGREGATE",
    "SET-HISTORY-CLEAR",
    "SET-MODELCFG-CLEAR",
]
SET_WORK_PACKAGES = {
    "SET-DEFAULTS-TYPED": ["P2.2", "P2.13"],
    "SET-MEMORY-INVENTORY": ["P1.2", "P2.13"],
    "SET-MEMORY-SEARCH": ["P1.2"],
    "SET-MEMORY-CANDIDATE-REVIEW": ["P2.3"],
    "SET-MEMORY-ORGANIZE": ["P2.3", "P2.13"],
    "SET-PERSONALIZATION-DOCUMENTS": ["P1.2", "P2.13"],
    "SET-PERSONALIZATION-GENERATE": ["P2.2", "P2.3"],
    "SET-USAGE-AGGREGATE": ["P1.2", "P2.2"],
    "SET-HISTORY-CLEAR": ["P2.7"],
    "SET-MODELCFG-CLEAR": ["P2.7"],
}
SET_FIXTURES = {
    "SET-DEFAULTS-TYPED": ["settings/defaults-cas.json"],
    "SET-MEMORY-INVENTORY": ["memory/inventory.json"],
    "SET-MEMORY-SEARCH": ["memory/inventory.json"],
    "SET-MEMORY-CANDIDATE-REVIEW": ["memory/candidates.json"],
    "SET-MEMORY-ORGANIZE": ["memory/organizer-model-output.json"],
    "SET-PERSONALIZATION-DOCUMENTS": ["personalization/documents.json"],
    "SET-PERSONALIZATION-GENERATE": ["personalization/documents.json"],
    "SET-USAGE-AGGREGATE": ["usage/aggregates.json"],
    "SET-HISTORY-CLEAR": ["privacy/identity-streams.json"],
    "SET-MODELCFG-CLEAR": ["privacy/identity-streams.json"],
}
SET_COMMANDS = {
    "SET-DEFAULTS-TYPED": ["config.defaults.get", "config.defaults.save"],
    "SET-MEMORY-INVENTORY": ["memory.list", "memory.get", "memory.add",
                             "memory.update", "memory.delete",
                             "memory.delete.bulk"],
    "SET-MEMORY-SEARCH": ["memory.search"],
    "SET-MEMORY-CANDIDATE-REVIEW": ["memory.candidates.list",
                                    "memory.candidate.resolve"],
    "SET-MEMORY-ORGANIZE": ["memory.organize.start",
                            "memory.organize.proposal.read",
                            "memory.organize.apply", "memory.organize.cancel"],
    "SET-PERSONALIZATION-DOCUMENTS": ["personalization.get",
                                      "personalization.revision.read",
                                      "personalization.save",
                                      "personalization.rollback",
                                      "personalization.automatic.set",
                                      "content.read"],
    "SET-PERSONALIZATION-GENERATE": ["personalization.generate",
                                     "personalization.generate.cancel"],
    "SET-USAGE-AGGREGATE": ["usage.statistics.get"],
    "SET-HISTORY-CLEAR": ["privacy.summary.get", "privacy.history.clear"],
    "SET-MODELCFG-CLEAR": ["privacy.modelConfiguration.clear"],
}
SET_FIXTURE_PATHS = sorted({p for paths in SET_FIXTURES.values() for p in paths})

RESERVED_LABELS = ["credentials", "settings.approval", "operations"]
NEW_LABELS = ["settings.defaults", "memory", "personalization", "usage", "privacy"]

FAILURES: list[str] = []


def fail(message: str) -> None:
    FAILURES.append(message)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def digest_lines(lines: list[str]) -> str:
    return sha256(("\n".join(sorted(lines)) + "\n").encode("utf-8"))


def digest_ids(ids: list[str]) -> str:
    return digest_lines(ids)


# --------------------------------------------------------------- matrix

def parse_swift_matrix(text: str) -> list[dict]:
    try:
        block = text.split("public static let commandRules: [CommandRule] = [", 1)[1]
        block = block.split("\n    ]", 1)[0]
    except IndexError:
        return []
    norm = re.sub(r"\s+", " ", block)
    pattern = re.compile(
        r'CommandRule\(command: "([^"]+)", scope: \.([A-Za-z]+)'
        r'(?:, configurationScope: "([^"]+)")?, revisionRequired: (true|false)'
        r'(?:, allowsCreateIntent: (true))?'
        r'(?:, isRunEventPoll: (true))?\)'
    )
    entries = []
    for match in pattern.finditer(norm):
        command, scope, label, revision, create, run = match.groups()
        entries.append({
            "command": command,
            "scope": scope,
            "configurationScope": label,
            "revisionRequired": revision == "true",
            "allowsCreateIntent": bool(create),
            "isRunEventPoll": bool(run),
        })
    return entries


def parse_kotlin_matrix(text: str) -> list[dict]:
    try:
        block = text.split("val ENTRIES: List<BridgeV3CommandRule> = listOf(", 1)[1]
        block = block.split("\n    )", 1)[0]
    except IndexError:
        return []
    norm = re.sub(r"\s+", " ", block)
    pattern = re.compile(
        r'rule\("([^"]+)", BridgeV3Scope\.Kind\.([A-Z_]+)'
        r'(?:, "([^"]+)")?'
        r'(?:, revision = true)?(?:, create = true)?'
        r'(?:, runEventPoll = true)?\)'
    )
    entries = []
    for match in pattern.finditer(norm):
        command, scope, label = match.groups()
        segment = match.group(0)
        entries.append({
            "command": command,
            "scope": {
                "APPLICATION_CONFIGURATION": "applicationConfiguration",
                "CONVERSATION_LIFECYCLE": "conversationLifecycle",
                "LAUNCH": "launch",
                "TASK_EXECUTION": "taskExecution",
            }[scope],
            "configurationScope": label,
            "revisionRequired": "revision = true" in segment,
            "allowsCreateIntent": "create = true" in segment,
            "isRunEventPoll": "runEventPoll = true" in segment,
        })
    return entries


def parse_kotlin_labels(text: str) -> list[str]:
    try:
        block = text.split("val CONFIGURATION_SCOPES = listOf(", 1)[1]
        block = block.split("\n    )", 1)[0]
    except IndexError:
        return []
    return re.findall(r'"([^"]+)"', block)


def parse_swift_labels(text: str) -> list[str]:
    try:
        block = text.split("public static let configurationScopes: [String] = [", 1)[1]
        block = block.split("\n    ]", 1)[0]
    except IndexError:
        return []
    return re.findall(r'"([^"]+)"', block)


def tuple_digest(rows: list[dict]) -> str:
    payload = "\n".join(
        json.dumps(row, sort_keys=True, separators=(",", ":")) for row in rows
    ) + "\n"
    return sha256(payload.encode("utf-8"))


def labels_digest(labels: list[str]) -> str:
    return sha256(("\n".join(labels) + "\n").encode("utf-8"))


def validate_matrix(golden: dict, swift: list[dict], kotlin: list[dict],
                    swift_labels: list[str], kotlin_labels: list[str]) -> None:
    expected = golden.get("expected", {})
    if golden.get("schema") != "floe.bridge-v3-command-matrix.golden/1":
        fail("matrix golden schema changed")
    rows = golden.get("entries")
    if not isinstance(rows, list) or len(rows) != EXPECTED_ENTRIES:
        fail("matrix golden entries must be %d" % EXPECTED_ENTRIES)
        return
    authority = golden.get("authority", "")
    if EXPECTED_CONTRACT_SHA256 not in authority:
        fail("matrix golden authority does not bind the final contract hash")
    if "Local/Private" in authority:
        fail("matrix golden authority contains a private path")
    if tuple_digest(rows[:EXPECTED_LEGACY_ENTRIES]) != EXPECTED_LEGACY_TUPLE_SHA256:
        fail("frozen 57-tuple set digest changed")
    if tuple_digest(G.settings_slice(rows)) != EXPECTED_ADDITIVE_TUPLE_SHA256:
        fail("accepted 27 additive tuple set digest changed")
    for message in G.validate_goalcore_append(rows):
        fail("goal-core append violated the approved delta: %s" % message)
    keys = {(row["scope"], row["configurationScope"], row["command"]) for row in rows}
    if len(keys) != EXPECTED_ENTRIES:
        fail("matrix tuples are not unique on scope+configurationScope+command")
    if len({(row["scope"], row["command"]) for row in rows}) != EXPECTED_SCOPE_COMMAND_PAIRS:
        fail("scope+command pair set must have %d unique values"
             % EXPECTED_SCOPE_COMMAND_PAIRS)
    if len(swift) != EXPECTED_ENTRIES:
        fail("Swift matrix has %d entries, expected %d"
             % (len(swift), EXPECTED_ENTRIES))
    if len(kotlin) != EXPECTED_ENTRIES:
        fail("Kotlin matrix has %d entries, expected %d"
             % (len(kotlin), EXPECTED_ENTRIES))
    if swift != rows:
        fail("Swift matrix differs from the manual golden entries")
    if kotlin != rows:
        fail("Kotlin matrix differs from the manual golden entries")
    if expected.get("entries") != EXPECTED_ENTRIES:
        fail("golden declared entry count changed")
    if expected.get("legacyEntries") != EXPECTED_LEGACY_ENTRIES:
        fail("golden legacy entry count changed")
    if expected.get("additiveEntries") != EXPECTED_ADDITIVE_ENTRIES:
        fail("golden additive entry count changed")
    if expected.get("distinctCommands") != EXPECTED_DISTINCT_COMMANDS:
        fail("golden distinct command count changed")
    if expected.get("configurationEntries") != EXPECTED_CONFIGURATION_ENTRIES:
        fail("golden configuration entry count changed")
    if len(swift_labels) != EXPECTED_LABELS or len(kotlin_labels) != EXPECTED_LABELS:
        fail("declared configuration labels are %d/%d, expected %d"
             % (len(swift_labels), len(kotlin_labels), EXPECTED_LABELS))
    if swift_labels != kotlin_labels:
        fail("Swift and Kotlin label declarations differ")
    if golden.get("configurationLabels") != swift_labels:
        fail("golden label declaration differs from source")
    if labels_digest(swift_labels) != EXPECTED_LABELS_SHA256:
        fail("configuration label set digest changed")
    for label in NEW_LABELS:
        if label not in swift_labels:
            fail("new label missing: %s" % label)
    for label in RESERVED_LABELS:
        if label not in swift_labels:
            fail("reserved label missing: %s" % label)
        if any(row["configurationScope"] == label for row in swift):
            fail("reserved label has a command: %s" % label)
    content_rows = [row for row in swift if row["command"] == "content.read"]
    if len(content_rows) != 3:
        fail("content.read must have three label-aware entries, found %d"
             % len(content_rows))
    if not any(row["configurationScope"] == "personalization"
               for row in content_rows):
        fail("content.read personalization entry missing")
    if not any(row["configurationScope"] == "conversations"
               for row in content_rows):
        fail("content.read conversations entry missing")
    create_only = {"memory.add", "memory.delete.bulk", "memory.organize.start",
                   "memory.organize.apply", "personalization.generate"}
    if {row["command"] for row in swift if row["allowsCreateIntent"]} < create_only:
        fail("create-only commands are not marked allowsCreateIntent")
    if len(swift) == EXPECTED_ENTRIES:
        if swift[:EXPECTED_LEGACY_ENTRIES] != golden["entries"][:EXPECTED_LEGACY_ENTRIES]:
            fail("legacy 57 matrix entries changed")
        if swift[EXPECTED_LEGACY_ENTRIES:] != golden["entries"][EXPECTED_LEGACY_ENTRIES:]:
            fail("additive 27 matrix entries differ from the golden")


# --------------------------------------------------------------- baseline

def validate_baseline(baseline: dict, packages: dict, inventory: dict) -> None:
    if baseline.get("version") != EXPECTED_BASELINE_VERSION:
        fail("baseline version is %r" % baseline.get("version"))
    families = baseline.get("families", [])
    ops = {}
    for family in families:
        for op in family.get("operations", []):
            if op["id"] in ops:
                fail("duplicate operation id: %s" % op["id"])
            ops[op["id"]] = op
    if len(families) != EXPECTED_FAMILIES:
        fail("baseline families %d != %d" % (len(families), EXPECTED_FAMILIES))
    if len(ops) != EXPECTED_OPERATIONS:
        fail("baseline operations %d != %d" % (len(ops), EXPECTED_OPERATIONS))
    g02 = sum(1 for op in ops.values() if op.get("goal") == "G02")
    if g02 != EXPECTED_G02_OPERATIONS:
        fail("baseline G02 operations %d != %d" % (g02, EXPECTED_G02_OPERATIONS))
    if len(packages.get("packages", [])) != EXPECTED_PACKAGES:
        fail("work packages %d != %d"
             % (len(packages.get("packages", [])), EXPECTED_PACKAGES))
    if len(inventory.get("entries", [])) != EXPECTED_FIXTURES:
        fail("fixtures %d != %d"
             % (len(inventory.get("entries", [])), EXPECTED_FIXTURES))

    history = baseline.get("baselineHistory", {})
    if history.get("previousVersion") != "g01.2026-10-18.2":
        fail("prior baselineHistory.previousVersion changed")
    if history.get("currentDeclaredCounts") != {
            "families": 36, "operations": 172, "g02Operations": 30,
            "workPackages": 85, "fixtures": 26}:
        fail("prior baselineHistory.currentDeclaredCounts changed")
    if history.get("additiveOperationIds") != [
            "CHA-ATTACH-INGEST-AND", "CHA-ATTACH-LIFECYCLE-AND"]:
        fail("prior attachment reconciliation changed")

    add = baseline.get("settingsDomainAdditive", {})
    if add.get("version") != EXPECTED_PRIOR_BASELINE_VERSION:
        fail("settingsDomainAdditive historical version changed")
    if add.get("contractSHA256") != EXPECTED_CONTRACT_SHA256:
        fail("settingsDomainAdditive contract hash changed")
    if add.get("previousDeclaredCounts") != history.get("currentDeclaredCounts"):
        fail("additive previous counts do not match the prior reconciliation")
    if add.get("currentDeclaredCounts") != {
            "families": 36, "operations": 182, "g02Operations": 40,
            "workPackages": 85, "fixtures": 33}:
        fail("additive current counts changed")
    if add.get("additiveOperationIds") != SET_OPERATION_IDS:
        fail("additive operation IDs changed")
    expected_mapping = [{
        "id": oid,
        "family": "SET",
        "goal": "G02",
        "status": "planned",
        "workPackages": SET_WORK_PACKAGES[oid],
        "fixture": SET_FIXTURES[oid][0],
    } for oid in SET_OPERATION_IDS]
    if add.get("additiveOperations") != expected_mapping:
        fail("additive operation mapping changed")
    if add.get("additiveFixturePaths") != SET_FIXTURE_PATHS:
        fail("additive fixture path list changed")

    # The unchanged historical validation runs on the exact prior ledger:
    # remove ONLY the approved goal-core operation and the frozen
    # Settings-domain additions. It executes regardless of the live count, so
    # a changed count can never skip the frozen identity/goal/status proofs.
    prior_ids = [oid for oid in ops if oid not in set(SET_OPERATION_IDS)
                 and oid != G.GOALCORE_OPERATION_ID]
    prior_ops = [ops[oid] for oid in prior_ids]
    if len(prior_ids) != 172:
        fail("prior 172 projection count is %d" % len(prior_ids))
    if digest_ids(prior_ids) != PRIOR_172_OPERATION_ID_DIGEST:
        fail("prior 172 operation IDs changed")
    if digest_lines(["%s:%s" % (op["id"], op["goal"])
                     for op in prior_ops]) != PRIOR_172_OPERATION_GOAL_DIGEST:
        fail("prior 172 operation goals changed")
    if digest_lines(["%s:%s" % (op["id"], op["status"])
                     for op in prior_ops]) != PRIOR_172_OPERATION_STATUS_DIGEST:
        fail("prior 172 operation statuses changed")
    if add.get("previousOperationIdDigest") != PRIOR_172_OPERATION_ID_DIGEST:
        fail("additive previous operation ID digest changed")
    if add.get("previousOperationGoalDigest") != PRIOR_172_OPERATION_GOAL_DIGEST:
        fail("additive previous operation goal digest changed")
    if add.get("previousOperationStatusDigest") != PRIOR_172_OPERATION_STATUS_DIGEST:
        fail("additive previous operation status digest changed")
    new_ids = [oid for oid in ops if oid in set(SET_OPERATION_IDS)]
    if digest_ids(new_ids) != ADDITIVE_10_ID_DIGEST:
        fail("additive operation ID digest changed")
    if digest_lines(["%s:%s" % (oid, ops.get(oid, {}).get("status"))
                     for oid in SET_OPERATION_IDS]) != ADDITIVE_10_STATUS_DIGEST:
        fail("additive operation status digest changed")
    if add.get("additiveOperationIdDigest") != ADDITIVE_10_ID_DIGEST:
        fail("recorded additive ID digest changed")
    if add.get("additiveOperationStatusDigest") != ADDITIVE_10_STATUS_DIGEST:
        fail("recorded additive status digest changed")

    # The goal-core record must match the approved delta AND the actual live
    # ledger/inventory numbers (183 ops / 41 G02 / exactly one planned
    # CHA-MANUAL-COMPACT / 33 fixtures with ZERO fixture added).
    for message in G.validate_goalcore_record(
            baseline.get("goalCoreRunControlAdditive"), ops,
            len(inventory.get("entries", [])), g02):
        fail("goal-core ledger record: %s" % message)

    if len(families) == EXPECTED_FAMILIES:
        if digest_lines(["%s:%s" % (f["id"], f["androidOwnerGoal"])
                         for f in families]) != PRIOR_FAMILY_GOAL_DIGEST:
            fail("family owner goals changed")
        if add.get("previousFamilyGoalDigest") != PRIOR_FAMILY_GOAL_DIGEST:
            fail("recorded family goal digest changed")
    if len(packages.get("packages", [])) == EXPECTED_PACKAGES:
        package_rows = packages["packages"]
        if digest_lines(["%s:%s" % (p["id"], p["implementationGoal"])
                         for p in package_rows]) != PRIOR_PACKAGE_GOAL_DIGEST:
            fail("work-package goals changed")
        if digest_lines(["%s:%s" % (p["id"], p["status"])
                         for p in package_rows]) != PRIOR_PACKAGE_STATUS_DIGEST:
            fail("work-package statuses changed")
        if add.get("previousWorkPackageGoalDigest") != PRIOR_PACKAGE_GOAL_DIGEST:
            fail("recorded package goal digest changed")
        if add.get("previousWorkPackageStatusDigest") != PRIOR_PACKAGE_STATUS_DIGEST:
            fail("recorded package status digest changed")

    set_families = [f for f in families if f.get("id") == "SET"]
    if len(set_families) != 1:
        fail("expected exactly one SET family")
        return
    set_family = set_families[0]
    if set_family.get("section2Row") != "设置与数据管理":
        fail("SET section-2 row changed")
    set_ids = [op["id"] for op in set_family.get("operations", [])]
    if set_ids[:4] != ["SET-CACHE-INSTALL-SIZE", "SET-SAFE-CLEANUP",
                       "SET-FONT-DIAG", "SET-CAPABILITY-STATUS"]:
        fail("original G11 SET operations changed")
    if set_ids[4:] != SET_OPERATION_IDS:
        fail("SET additive operation order changed")
    for oid in SET_OPERATION_IDS:
        op = ops.get(oid)
        if op is None:
            fail("missing additive operation: %s" % oid)
            continue
        if op.get("goal") != "G02" or op.get("status") != "planned":
            fail("%s must be planned/G02" % oid)
        if op.get("workPackages") != SET_WORK_PACKAGES[oid]:
            fail("%s work packages changed" % oid)
        if op.get("fixtures") != SET_FIXTURES[oid]:
            fail("%s fixtures changed" % oid)
        if op.get("commands") != SET_COMMANDS[oid]:
            fail("%s commands changed" % oid)
        if op.get("alignment") != "built-in-equivalent":
            fail("%s alignment changed" % oid)
        if op.get("channel") != ["full", "play"]:
            fail("%s channel changed" % oid)
        if op.get("verify") != ["G12", "G13"]:
            fail("%s verify goals changed" % oid)
        if op.get("iosState") != "implemented":
            fail("%s iosState changed" % oid)

    inventory_paths = {entry.get("path"): entry
                       for entry in inventory.get("entries", [])}
    for path in SET_FIXTURE_PATHS:
        entry = inventory_paths.get(path)
        if entry is None:
            fail("settings fixture missing from inventory: %s" % path)
            continue
        if entry.get("determinism") != "stdlib":
            fail("%s is not stdlib-deterministic" % path)
        if not entry.get("operations"):
            fail("%s has no operation mapping" % path)
        if entry.get("operations") != [
                oid for oid in SET_OPERATION_IDS if path in SET_FIXTURES[oid]]:
            fail("%s operation mapping changed" % path)


# --------------------------------------------------------------- source

def require_file(root: Path, relative: str) -> bool:
    path = root / relative
    if not path.is_file():
        fail("required source file missing: %s" % relative)
        return False
    return True


def validate_swift_digest_source(text: str) -> None:
    normalized = re.sub(r"\s+", " ", text)
    required = [
        "case .null: data.append(0x00)",
        "case .integer(let value): data.append(0x01)",
        "case .real(let value): data.append(0x02)",
        "case .text(let value): data.append(0x03)",
        "case .blob(let value): data.append(0x04)",
        "data.append(contentsOf: bigEndian(UInt64(bitPattern: value)))",
        "data.append(contentsOf: bigEndian(value.bitPattern))",
        "data.append(contentsOf: bigEndian(UInt32(bytes.count)))",
        "data.append(contentsOf: bigEndian(UInt32(value.count)))",
        "data.append(contentsOf: bigEndian(UInt32(fields.count)))",
        "data.append(contentsOf: bigEndian(UInt32(0)))",
    ]
    for token in required:
        if token not in normalized:
            fail("Swift canonical encoder lacks %r" % token)
    if "COALESCE(CAST" in text or "CAST(" in text:
        fail("Swift canonical encoder uses CAST/COALESCE")


def validate_kotlin_digest_source(text: str) -> None:
    normalized = re.sub(r"\s+", " ", text)
    required = [
        "is Field.Null -> buffer.write(0x00)",
        "is Field.Integer -> { buffer.write(0x01)",
        "is Field.Real -> { buffer.write(0x02)",
        "is Field.Text -> { buffer.write(0x03)",
        "is Field.Blob -> { buffer.write(0x04)",
        "buffer.write(ByteBuffer.allocate(8).putLong(field.value).array())",
        "doubleToRawLongBits(field.value)",
        "buffer.write(ByteBuffer.allocate(4).putInt(bytes.size).array())",
        "buffer.write(ByteBuffer.allocate(4).putInt(field.value.size).array())",
        "buffer.write(ByteBuffer.allocate(4).putInt(fields.size).array())",
        "buffer.write(ByteBuffer.allocate(4).putInt(0).array())",
    ]
    for token in required:
        if token not in normalized:
            fail("Kotlin canonical encoder lacks %r" % token)
    if "COALESCE(CAST" in text:
        fail("Kotlin canonical encoder uses CAST/COALESCE")


def validate_sources(root: Path) -> None:
    required = [
        "FloeAndroid/shared/Sources/FloeAndroidCore/BridgeEnvelopeV3.swift",
        "FloeAndroid/shared/Sources/FloeAndroidCore/SettingsDomainV1.swift",
        "FloeAndroid/core/contracts/src/main/kotlin/com/floe/android/contracts/BridgeV3Contracts.kt",
        "FloeAndroid/core/contracts/src/main/kotlin/com/floe/android/contracts/SettingsDomainV1.kt",
        "FloeAndroid/shared/Tests/FloeAndroidCoreTests/BridgeEnvelopeV3Tests.swift",
        "FloeAndroid/shared/Tests/FloeAndroidCoreTests/SettingsDomainV1Tests.swift",
        "FloeAndroid/core/contracts/src/test/kotlin/com/floe/android/contracts/SettingsDomainV1Test.kt",
        "FloeAndroid/core/swiftbridge/src/androidTest/kotlin/com/floe/android/bridge/BridgeEnvelopeV3InstrumentedTest.kt",
        "FloeAndroid/core/swiftbridge/src/androidTest/kotlin/com/floe/android/bridge/SettingsDomainV1InstrumentedTest.kt",
        "FloeAndroid/planning/bridge-v3-command-matrix.golden.json",
    ]
    for relative in required:
        require_file(root, relative)

    bridge = (root / "FloeAndroid/shared/Sources/FloeAndroidCore/BridgeEnvelopeV3.swift")
    if bridge.is_file():
        text = bridge.read_text(encoding="utf-8")
        if "SettingsDomainV1.validate(" not in text:
            fail("BridgeEnvelopeV3 does not invoke the closed payload validation")
        if "settingsJSONValue(" not in text:
            fail("BridgeEnvelopeV3 does not preserve strict JSON types")
        if "businessCapabilities\": []" not in text:
            fail("handshake no longer claims zero business capabilities")
        if "RuntimeCommandBinder.shared.register" in text:
            fail("BridgeEnvelopeV3 registers a handler")
        if text.count('CommandRule(command: "content.read"') != 3:
            fail("content.read entries changed")

    swift = (root / "FloeAndroid/shared/Sources/FloeAndroidCore/SettingsDomainV1.swift")
    if swift.is_file():
        text = swift.read_text(encoding="utf-8")
        for token in ("public enum SettingsDomainV1",
                      "static let createOnlyCommands",
                      "enum CanonicalDigest", "enum ContentBudget",
                      "enum PersonalizationGenerateOutcome",
                      "struct PersonalizationDocument"):
            if token not in text:
                fail("Swift vocabulary lacks %r" % token)
        for token in ("public struct Ownership",
                      "public let ownership: Ownership",
                      "public let current: MemoryEntry?",
                      "public let revisionsNextCursor",
                      "metadataEncodedBytesWithEmptyContent",
                      "encodedJSONStringBytes",
                      "public struct UsageBreakdown",
                      "public struct PrivacyHistoryEnumerated",
                      "public struct PrivacyModelConfigEnumerated",
                      "public let route: PersonalizationGenerateRoute",
                      "public let sourceSnapshot: PersonalizationSourceSnapshot",
                      "public let cursor: PersonalizationGenerateCursor"):
            if token not in text:
                fail("Swift final-contract shape lacks %r" % token)
        if "RuntimeCommandBinder.shared.register" in text:
            fail("new Swift vocabulary registers a handler")
        if "import GRDB" in text or "DatabaseManager" in text:
            fail("new Swift vocabulary contains a database implementation")
        validate_swift_digest_source(text)

    kotlin = (root / "FloeAndroid/core/contracts/src/main/kotlin/com/floe/android/contracts/SettingsDomainV1.kt")
    if kotlin.is_file():
        text = kotlin.read_text(encoding="utf-8")
        for token in ("object SettingsDomainV1", "CREATE_ONLY_COMMANDS",
                      "object CanonicalDigest", "object ContentBudget",
                      "sealed interface PersonalizationGenerateOutcome",
                      "data class PersonalizationDocument"):
            if token not in text:
                fail("Kotlin vocabulary lacks %r" % token)
        for token in ("data class Ownership",
                      "val ownership: Ownership",
                      "val current: MemoryEntry?",
                      "val revisionsNextCursor",
                      "metadataEncodedBytesWithEmptyContent",
                      "fun encodedInlineResponseBytes",
                      "data class UsageBreakdown",
                      "data class PrivacyHistoryClearReport",
                      "data class PrivacyModelConfigClearReport",
                      "data class PersonalizationGenerateRoute"):
            if token not in text:
                fail("Kotlin final-contract shape lacks %r" % token)
        if "RuntimeCommandBinder" in text or "SQLiteDatabase" in text:
            fail("Kotlin vocabulary contains a handler/database implementation")
        validate_kotlin_digest_source(text)

    tests = (root / "FloeAndroid/shared/Tests/FloeAndroidCoreTests/BridgeEnvelopeV3Tests.swift")
    if tests.is_file():
        text = tests.read_text(encoding="utf-8")
        if "XCTAssertEqual(goldenPairs.count, 87)" not in text:
            fail("manual golden test is not 87 entries")
        for token in ("testSettingsDomainMatrixAppendsAcceptedTuplesUnderFiveLabels",
                      "testSettingsDomainPayloadValidationRunsBeforeHandler",
                      "testSettingsDomainContentReadLabelIsolation",
                      "testSettingsDomainContentReadSharedHandlerKeyDispatchesLabel"):
            if token not in text:
                fail("host test lacks %s" % token)
        for token in ("let goldenPairs: [(scope: String, configurationScope: String?, command: String)]",
                      "XCTAssertEqual(Set(goldenKeys).count, 87)"):
            if token not in text:
                fail("host matrix test lacks %r" % token)

    instrumented = (root / "FloeAndroid/core/swiftbridge/src/androidTest/kotlin/com/floe/android/bridge/BridgeEnvelopeV3InstrumentedTest.kt")
    if instrumented.is_file():
        text = instrumented.read_text(encoding="utf-8")
        if "assertEquals(87, BridgeV3CommandMatrix.ENTRIES.size)" not in text:
            fail("Android matrix test is not 87 entries")
        for token in ("settingsDomainCreateOnlyRequiresExplicitIntent",
                      "settingsDomainContentReadLabelIsolation"):
            if token not in text:
                fail("Android test lacks %s" % token)
        if "assertEquals(BridgeV3CommandMatrix.ENTRIES.size, keys.toSet().size)" not in text:
            fail("Android matrix test lacks configurationScope uniqueness")

    kotlin_tests = (root / "FloeAndroid/core/contracts/src/test/kotlin/com/floe/android/contracts/SettingsDomainV1Test.kt")
    if kotlin_tests.is_file():
        text = kotlin_tests.read_text(encoding="utf-8")
        for token in ("matrixUniquenessIncludesConfigurationScope",
                      "canonicalDigestFinalContractVectorsMatchSwift",
                      "contentBudgetCountsCompleteEnvelopeAndEscaping",
                      "finalContractDTOShapesAreNestedAndFlat"):
            if token not in text:
                fail("Kotlin JVM test lacks %s" % token)

    golden_path = root / "FloeAndroid/planning/bridge-v3-command-matrix.golden.json"
    if golden_path.is_file():
        golden = json.loads(golden_path.read_text(encoding="utf-8"))
        if golden.get("wireVersion") != 3:
            fail("golden wire version changed")


def validate_docs(root: Path) -> None:
    plan = (root / "docs/FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md")
    if plan.is_file():
        text = plan.read_text(encoding="utf-8")
        if "g02.2026-10-19.1" not in text:
            fail("plan does not record the additive baseline version")
        if "182" not in text or "40" not in text or "33" not in text:
            fail("plan does not record the additive counts")
    progress = (root / "docs/FLOE_ANDROID_PROGRESS.zh-CN.md")
    if progress.is_file():
        text = progress.read_text(encoding="utf-8")
        if "P0 源码候选" not in text:
            fail("progress does not record the P0 candidate status")
    parity = (root / "FloeAndroid/planning/SETTINGS_PARITY.md")
    if parity.is_file():
        text = parity.read_text(encoding="utf-8")
        for oid in SET_OPERATION_IDS:
            if oid not in text:
                fail("SETTINGS_PARITY lacks %s" % oid)
    fixture_readme = (root / "FloeAndroid/fixtures/README.md")
    if fixture_readme.is_file():
        text = fixture_readme.read_text(encoding="utf-8")
        if "33" not in text or "g02.2026-10-19.1" not in text:
            fail("fixtures README lacks the additive count/version")


def validate_all(root: Path) -> tuple[list[str], dict]:
    FAILURES.clear()
    kotlin_tests = (root / "FloeAndroid/core/contracts/src/test/kotlin/com/floe/android/contracts/SettingsDomainV1Test.kt")
    if kotlin_tests.is_file():
        text = kotlin_tests.read_text(encoding="utf-8")
        for token in ("matrixUniquenessIncludesConfigurationScope",
                      "canonicalDigestFinalContractVectorsMatchSwift",
                      "contentBudgetCountsCompleteEnvelopeAndEscaping",
                      "finalContractDTOShapesAreNestedAndFlat"):
            if token not in text:
                fail("Kotlin JVM test lacks %s" % token)

    golden_path = root / "FloeAndroid/planning/bridge-v3-command-matrix.golden.json"
    bridge_path = root / "FloeAndroid/shared/Sources/FloeAndroidCore/BridgeEnvelopeV3.swift"
    kotlin_path = root / "FloeAndroid/core/contracts/src/main/kotlin/com/floe/android/contracts/BridgeV3Contracts.kt"
    baseline_path = root / "FloeAndroid/planning/feature-baseline.json"
    packages_path = root / "FloeAndroid/planning/work-packages.json"
    inventory_path = root / "FloeAndroid/fixtures/inventory.json"
    for path in (golden_path, bridge_path, kotlin_path, baseline_path,
                 packages_path, inventory_path):
        if not path.is_file():
            fail("required file missing: %s" % path)
    if FAILURES:
        return list(FAILURES), {}
    golden = json.loads(golden_path.read_text(encoding="utf-8"))
    bridge = bridge_path.read_text(encoding="utf-8")
    kotlin = kotlin_path.read_text(encoding="utf-8")
    validate_matrix(golden, parse_swift_matrix(bridge), parse_kotlin_matrix(kotlin),
                    parse_swift_labels(bridge), parse_kotlin_labels(kotlin))
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    packages = json.loads(packages_path.read_text(encoding="utf-8"))
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    validate_baseline(baseline, packages, inventory)
    validate_sources(root)
    validate_docs(root)
    summary = {
        "entries": len(golden.get("entries", [])),
        "legacyEntries": EXPECTED_LEGACY_ENTRIES,
        "additiveEntries": EXPECTED_ADDITIVE_ENTRIES,
        "settingsAdditiveEntries": EXPECTED_SETTINGS_ADDITIVE_ENTRIES,
        "goalCoreAdditiveEntries": EXPECTED_GOALCORE_ADDITIVE_ENTRIES,
        "labels": len(golden.get("configurationLabels", [])),
        "operations": sum(len(f.get("operations", []))
                          for f in baseline.get("families", [])),
        "g02Operations": sum(1 for f in baseline.get("families", [])
                             for op in f.get("operations", [])
                             if op.get("goal") == "G02"),
        "fixtures": len(inventory.get("entries", [])),
        "families": len(baseline.get("families", [])),
        "packages": len(packages.get("packages", [])),
        "failures": len(FAILURES),
    }
    return list(FAILURES), summary


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Read-only Settings-domain P0 source checker")
    parser.add_argument("--check", action="store_true",
                        help="explicit read-only mode (default)")
    parser.add_argument("--root", default=None,
                        help="repository/candidate root (default: script root)")
    parser.add_argument("--json", action="store_true",
                        help="emit a JSON summary")
    args = parser.parse_args(argv[1:])
    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[2]
    failures, summary = validate_all(root)
    if args.json:
        print(json.dumps({"ok": not failures, "failures": failures,
                          "summary": summary}, indent=2, ensure_ascii=False))
    else:
        for failure in failures:
            print("FAIL %s" % failure)
        if summary:
            print("check-settings-domain: %d entries (%d legacy + %d additive), "
                  "%d labels, %d operations/%d G02, %d fixtures, %d families, "
                  "%d packages, %d failures"
                  % (summary["entries"], summary["legacyEntries"],
                     summary["additiveEntries"], summary["labels"],
                     summary["operations"], summary["g02Operations"],
                     summary["fixtures"], summary["families"],
                     summary["packages"], summary["failures"]))
        else:
            print("check-settings-domain: %d failures" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
