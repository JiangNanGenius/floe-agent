#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Approved goal-core run-control additive delta: standalone contract module.

This module is the single read-only authority for the goal-core code batch
(2026-10-21) append-only ledger delta. It hard-codes the APPROVED values from
the run-control closure decision and the reconciled ledger, and recomputes the
additive tuple digest from its own approved row constants — never from live
files — so the checkers can independently prove the appended tail instead of
recomputing frozen history to pass. It writes nothing and imports nothing
outside the standard library.

The delta (everything before it stays frozen and is validated by the existing
per-section digests in check-settings-domain.py / check-fixtures.py):

  * bridge v3 matrix: 87 entries = 57 frozen legacy + 27 frozen Settings-domain
    additive + exactly 3 appended tuples
    (plan.accept/launch/revisionRequired, goal.confirm/conversationLifecycle/
    revisionRequired, conversation.compact/conversationLifecycle/no-revision),
    85 distinct commands, 86 scope+command pairs, 55 configuration entries,
    19 configuration labels. No label, create-intent or run-event-poll
    widening; no child.create.
  * feature ledger: 183 operations / 41 G02 with exactly one added planned
    operation CHA-MANUAL-COMPACT; 33 fixtures UNCHANGED (the batch added zero
    fixtures — the 35-fixture metadata in the incoming record was a proposal
    error corrected here against the actual inventory); 36 families / 85 work
    packages unchanged; baseline version advances g02.2026-10-19.1 ->
    g02.2026-10-21.2. Source-only: not compiled, not executed, not
    device-qualified.
"""
from __future__ import annotations

import hashlib
import json

# ----------------------------------------------------------------- versions
BASELINE_VERSION_CURRENT = "g02.2026-10-21.2"
BASELINE_VERSION_PREVIOUS = "g02.2026-10-19.1"

# -------------------------------------------------------------------- matrix
LEGACY_ENTRY_COUNT = 57
SETTINGS_ADDITIVE_ENTRY_COUNT = 27
GOALCORE_ADDITIVE_ENTRY_COUNT = 3
EXPECTED_MATRIX_ENTRIES = (LEGACY_ENTRY_COUNT + SETTINGS_ADDITIVE_ENTRY_COUNT
                           + GOALCORE_ADDITIVE_ENTRY_COUNT)          # 87
EXPECTED_MATRIX_ADDITIVE_ENTRIES = (SETTINGS_ADDITIVE_ENTRY_COUNT
                                    + GOALCORE_ADDITIVE_ENTRY_COUNT)  # 30
EXPECTED_DISTINCT_COMMANDS = 85
EXPECTED_SCOPE_COMMAND_PAIRS = 86
EXPECTED_CONFIGURATION_ENTRIES = 55
EXPECTED_CONFIGURATION_LABELS = 19

GOALCORE_COMMAND_ROWS = [
    {
        "command": "plan.accept",
        "scope": "launch",
        "configurationScope": None,
        "revisionRequired": True,
        "allowsCreateIntent": False,
        "isRunEventPoll": False,
    },
    {
        "command": "goal.confirm",
        "scope": "conversationLifecycle",
        "configurationScope": None,
        "revisionRequired": True,
        "allowsCreateIntent": False,
        "isRunEventPoll": False,
    },
    {
        "command": "conversation.compact",
        "scope": "conversationLifecycle",
        "configurationScope": None,
        "revisionRequired": False,
        "allowsCreateIntent": False,
        "isRunEventPoll": False,
    },
]

# ------------------------------------------------------------------ ledger
EXPECTED_OPERATIONS = 183
EXPECTED_G02_OPERATIONS = 41
PRIOR_OPERATIONS = 182
PRIOR_G02_OPERATIONS = 40
PRIOR_172_OPERATIONS = 172
EXPECTED_FIXTURES = 33            # unchanged: the batch added zero fixtures
EXPECTED_FAMILIES = 36
EXPECTED_PACKAGES = 85

GOALCORE_OPERATION_ID = "CHA-MANUAL-COMPACT"
GOALCORE_OPERATION_WORK_PACKAGES = ["P2.2", "P2.3", "P2.7"]
GOALCORE_OPERATION_RECORD = {
    "id": GOALCORE_OPERATION_ID,
    "family": "CHA",
    "goal": "G02",
    "status": "planned",
    "workPackages": GOALCORE_OPERATION_WORK_PACKAGES,
    "fixture": None,
}
# The record must keep declaring itself unqualified source-only metadata.
GOALCORE_RECORD_STATUS_MARKER = "CANDIDATE ONLY"


# ----------------------------------------------------------------- digests
def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tuple_digest(rows: list[dict]) -> str:
    payload = "\n".join(
        json.dumps(row, sort_keys=True, separators=(",", ":")) for row in rows
    ) + "\n"
    return sha256(payload.encode("utf-8"))


def digest_lines(lines: list[str]) -> str:
    return sha256(("\n".join(sorted(lines)) + "\n").encode("utf-8"))


# Recomputed from the approved constant rows above (independent of live files).
GOALCORE_TUPLE_SHA256 = tuple_digest(GOALCORE_COMMAND_ROWS)
GOALCORE_OPERATION_ID_DIGEST = digest_lines([GOALCORE_OPERATION_ID])
GOALCORE_OPERATION_STATUS_DIGEST = digest_lines(
    ["%s:%s" % (GOALCORE_OPERATION_ID, GOALCORE_OPERATION_RECORD["status"])])

EXPECTED_PREVIOUS_DECLARED_COUNTS = {
    "families": EXPECTED_FAMILIES,
    "operations": PRIOR_OPERATIONS,
    "g02Operations": PRIOR_G02_OPERATIONS,
    "workPackages": EXPECTED_PACKAGES,
    "fixtures": EXPECTED_FIXTURES,
}
EXPECTED_CURRENT_DECLARED_COUNTS = {
    "families": EXPECTED_FAMILIES,
    "operations": EXPECTED_OPERATIONS,
    "g02Operations": EXPECTED_G02_OPERATIONS,
    "workPackages": EXPECTED_PACKAGES,
    "fixtures": EXPECTED_FIXTURES,
}


# ----------------------------------------------------------------- slicing
def goalcore_slice(rows: list[dict]) -> list[dict]:
    """The appended goal-core tail of the full matrix row list."""
    start = LEGACY_ENTRY_COUNT + SETTINGS_ADDITIVE_ENTRY_COUNT
    return rows[start:start + GOALCORE_ADDITIVE_ENTRY_COUNT]


def settings_slice(rows: list[dict]) -> list[dict]:
    start = LEGACY_ENTRY_COUNT
    return rows[start:start + SETTINGS_ADDITIVE_ENTRY_COUNT]


def project_prior_rows(rows: list[dict]) -> list[dict]:
    """The exact prior 84-row matrix with only the approved goal-core
    additions removed; feeds the UNCHANGED historical validation."""
    return rows[:LEGACY_ENTRY_COUNT + SETTINGS_ADDITIVE_ENTRY_COUNT]


def project_prior_operation_ids(ids) -> list[str]:
    """The prior 182-operation ledger projection: the live ID set with only
    the approved goal-core operation removed."""
    return [oid for oid in ids if oid != GOALCORE_OPERATION_ID]


# ----------------------------------------------------------------- validators
def validate_goalcore_append(rows: list[dict]) -> list[str]:
    """Independently verify the exact approved three-tuple tail.

    ``rows`` is the full golden entry list. The frozen 57/27 digests stay the
    checkers' responsibility; this proves only the NEW tail against the
    hard-coded approval, so a passing result never depends on recomputing
    history.
    """
    failures: list[str] = []
    if len(rows) != EXPECTED_MATRIX_ENTRIES:
        failures.append("matrix rows are %d, expected %d"
                        % (len(rows), EXPECTED_MATRIX_ENTRIES))
        # Still check what we can when the tail position is unambiguous.
        if len(rows) <= LEGACY_ENTRY_COUNT + SETTINGS_ADDITIVE_ENTRY_COUNT:
            failures.append("the approved three-tuple tail is missing")
            return failures
    tail = goalcore_slice(rows)
    if tail != GOALCORE_COMMAND_ROWS:
        failures.append("goal-core appended tuples differ from the approved "
                        "plan.accept/goal.confirm/conversation.compact rows")
    if tuple_digest(tail) != GOALCORE_TUPLE_SHA256:
        failures.append("goal-core appended tuple digest differs from the "
                        "approved digest")
    widened = [row for row in rows[LEGACY_ENTRY_COUNT:]
               if row.get("allowsCreateIntent") or row.get("isRunEventPoll")]
    allowed_widening = {
        "memory.add", "memory.delete.bulk", "memory.organize.start",
        "memory.organize.apply", "personalization.generate",
        "run.events.wait",
    }
    unexpected = {row.get("command") for row in widened} - allowed_widening
    if unexpected:
        failures.append("create-intent/run-event-poll widening beyond the "
                        "frozen set: %s" % sorted(unexpected))
    if any(row.get("command") == "child.create" for row in rows):
        failures.append("child.create must not appear in the matrix")
    return failures


def validate_goalcore_record(record, ops: dict, actual_fixture_count: int,
                             actual_g02: int) -> list[str]:
    """Verify the feature-baseline goalCoreRunControlAdditive record against
    the approved delta and the ACTUAL live ledger/inventory numbers."""
    failures: list[str] = []
    if not isinstance(record, dict):
        return ["feature baseline has no goalCoreRunControlAdditive record"]
    if record.get("version") != BASELINE_VERSION_CURRENT:
        failures.append("goalCoreRunControlAdditive.version is %r, expected %r"
                        % (record.get("version"), BASELINE_VERSION_CURRENT))
    if record.get("previousVersion") != BASELINE_VERSION_PREVIOUS:
        failures.append("goalCoreRunControlAdditive.previousVersion is %r, "
                        "expected %r"
                        % (record.get("previousVersion"),
                           BASELINE_VERSION_PREVIOUS))
    status = record.get("status")
    if not isinstance(status, str) or GOALCORE_RECORD_STATUS_MARKER not in status:
        failures.append("goalCoreRunControlAdditive.status must keep the "
                        "CANDIDATE ONLY source-only honesty marker")
    if record.get("previousDeclaredCounts") != EXPECTED_PREVIOUS_DECLARED_COUNTS:
        failures.append("goalCoreRunControlAdditive.previousDeclaredCounts is "
                        "%r, expected %r (fixtures stayed 33; the batch added "
                        "zero fixtures)"
                        % (record.get("previousDeclaredCounts"),
                           EXPECTED_PREVIOUS_DECLARED_COUNTS))
    if record.get("currentDeclaredCounts") != EXPECTED_CURRENT_DECLARED_COUNTS:
        failures.append("goalCoreRunControlAdditive.currentDeclaredCounts is "
                        "%r, expected %r"
                        % (record.get("currentDeclaredCounts"),
                           EXPECTED_CURRENT_DECLARED_COUNTS))
    if record.get("additiveOperationIds") != [GOALCORE_OPERATION_ID]:
        failures.append("goalCoreRunControlAdditive.additiveOperationIds must "
                        "be exactly [CHA-MANUAL-COMPACT]")
    if record.get("additiveOperations") != [GOALCORE_OPERATION_RECORD]:
        failures.append("goalCoreRunControlAdditive.additiveOperations differs "
                        "from the approved mapping")
    if record.get("additiveFixtureIds") != [] or \
            record.get("additiveFixturePaths") != []:
        failures.append("goalCoreRunControlAdditive must declare zero added "
                        "fixtures")
    # Cross-prove the declared counts against the actual live ledger.
    if record.get("currentDeclaredCounts", {}).get("fixtures") != actual_fixture_count:
        failures.append("goalCoreRunControlAdditive fixture claim %r != actual "
                        "inventory count %d"
                        % (record.get("currentDeclaredCounts", {}).get("fixtures"),
                           actual_fixture_count))
    if actual_g02 != EXPECTED_G02_OPERATIONS:
        failures.append("actual G02 operations %d != approved %d"
                        % (actual_g02, EXPECTED_G02_OPERATIONS))
    op = ops.get(GOALCORE_OPERATION_ID)
    if op is None:
        failures.append("live ledger is missing %s" % GOALCORE_OPERATION_ID)
    else:
        if op.get("goal") != "G02" or op.get("status") != "planned":
            failures.append("%s live operation must be planned/G02"
                            % GOALCORE_OPERATION_ID)
        if digest_lines(["%s:%s" % (GOALCORE_OPERATION_ID, op.get("status"))]) \
                != GOALCORE_OPERATION_STATUS_DIGEST:
            failures.append("%s status digest differs from the approved "
                            "planned record" % GOALCORE_OPERATION_ID)
    if digest_lines([GOALCORE_OPERATION_ID]) != GOALCORE_OPERATION_ID_DIGEST:
        failures.append("internal goal-core operation ID digest invariant broke")
    return failures
