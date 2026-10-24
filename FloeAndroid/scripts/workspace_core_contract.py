#!/usr/bin/env python3
"""Read-only G04 workspace append contract. Original goal-core stays frozen.

The first87 tuples are pinned to public3fd597b5; these three exact rows are
independent approved constants, never inferred from the candidate under test.
"""
import hashlib
import json

PRIOR_ENTRIES = 87
WORKSPACE_ENTRY_COUNT = 3
EXPECTED_ENTRIES = 90
EXPECTED_ADDITIVE_ENTRIES = 33
EXPECTED_DISTINCT_COMMANDS = 88
EXPECTED_SCOPE_COMMAND_PAIRS = 89
PRIOR_PREFIX_SHA256 = "1ccc1811f02b345d3b225ad4422f8ce53c91b90a36eae4a04a8b120caf6b3ff1"
WORKSPACE_ROWS = [
    {"command": command, "scope": "conversationLifecycle", "configurationScope": None,
     "revisionRequired": False, "allowsCreateIntent": False, "isRunEventPoll": False}
    for command in ("workspace.read", "workspace.write", "workspace.activate")
]

def tuple_digest(rows):
    payload = "\n".join(json.dumps(row, sort_keys=True, separators=(",", ":")) for row in rows) + "\n"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()

def validate_workspace_append(rows):
    failures = []
    if not isinstance(rows, list): return ["workspace matrix rows must be a list"]
    if len(rows) != EXPECTED_ENTRIES: failures.append("workspace matrix must contain exactly90 rows")
    if tuple_digest(rows[:PRIOR_ENTRIES]) != PRIOR_PREFIX_SHA256:
        failures.append("frozen original87 tuple prefix changed")
    if rows[PRIOR_ENTRIES:] != WORKSPACE_ROWS:
        failures.append("workspace tail differs from the three exact approved lifecycle rows")
    return failures
