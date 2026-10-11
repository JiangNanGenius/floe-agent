#!/usr/bin/env python3
"""Selector truth table for the supplementary CI workflow.

Push, pull_request and a ``workflow_dispatch`` without any selector run only
the read-only ``lean-checks`` lane: committed asset/pin/license/localization,
native-runtime and strict diagnostic/verifier contracts plus the secret scan.
That lane never builds the App, bootstraps dependencies, resolves packages,
boots a simulator or produces an archive.

``full: true`` is the explicit manual opt-in for the historical complete
matrix (build-test, appstore-sdk-compatibility, spm-linux-build).
``build_test_only`` and ``ide_only`` remain narrow reruns of the build-test
lane; ``live_agent_demo``, ``local_inference``, ``feedback_ui`` and
``publish_skill_hub`` remain the existing single-purpose modes.

At most one top-level mode may be selected per dispatch, and the palette
modifiers require ``feedback_ui``.  The ``validate-selectors`` job runs this
validator before any paid, write-capable or heavy job can start, so an
ambiguous dispatch fails there instead of silently running or dropping a lane.

``scripts/tests/test_ci_scope.py`` evaluates the job conditions in
``.github/workflows/ci.yml`` against this table, so the workflow and the
accepted semantics cannot drift apart.
"""
from __future__ import annotations

import argparse
import json
import sys

EVENTS = ("push", "pull_request", "workflow_dispatch")

# Top-level manual modes.  At most one may be selected per dispatch.
MODES = (
    "full",
    "live_agent_demo",
    "local_inference",
    "feedback_ui",
    "publish_skill_hub",
    "build_test_only",
    "ide_only",
)

# Modifiers never select a lane on their own; they refine `feedback_ui`.
MODIFIERS = {
    "palette_only": "feedback_ui",
    "palette_unit_only": "feedback_ui",
}

# Workflow job ids mapped to the scope keys used below.
JOBS = (
    "validate-selectors",
    "lean-checks",
    "live-agent-demo",
    "local-inference",
    "feedback-ui",
    "publish-skill-hub",
    "build-test",
    "appstore-sdk-compatibility",
    "spm-linux-build",
)

# The heavy jobs that only ever run from an explicit manual selection.
HEAVY_JOBS = ("build-test", "appstore-sdk-compatibility", "spm-linux-build")

# `full` expands to exactly these three jobs; build_test_only and ide_only
# rerun only build-test.
FULL_MATRIX = ("build-test", "appstore-sdk-compatibility", "spm-linux-build")

ALL_SELECTORS = MODES + tuple(MODIFIERS)


def parse_bool(value):
    """Parse a GitHub boolean input value; absent inputs stay false."""
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in ("", "false", "0"):
        return False
    if text in ("true", "1"):
        return True
    raise ValueError(f"not a boolean selector value: {value!r}")


def selected_modes(selectors):
    """Return the selected top-level modes in declaration order."""
    return tuple(mode for mode in MODES if selectors.get(mode))


def selected_modifiers(selectors):
    """Return the selected modifier names in declaration order."""
    return tuple(name for name in MODIFIERS if selectors.get(name))


def validate(event, selectors):
    """Return human-readable problems; an empty list means the combination is valid."""
    if event not in EVENTS:
        return [f"unknown CI event: {event!r}"]
    problems = []
    for name in sorted(set(selectors) - set(ALL_SELECTORS)):
        problems.append(f"unknown selector: {name}")
    active = selected_modes(selectors) + selected_modifiers(selectors)
    if event != "workflow_dispatch" and active:
        problems.append(
            "manual selectors cannot be set on " + event + ": " + ", ".join(active))
    modes = selected_modes(selectors)
    if len(modes) > 1:
        problems.append("conflicting selectors: " + ", ".join(modes))
    for modifier, required in MODIFIERS.items():
        if selectors.get(modifier) and not selectors.get(required):
            problems.append(f"{modifier} requires {required}")
    return problems


def scope(event, selectors):
    """Resolve the job enablement table for a valid event/selector combination.

    Raises ``ValueError`` for an ambiguous or unknown combination so callers
    can never act on a partially validated dispatch.
    """
    problems = validate(event, selectors)
    if problems:
        raise ValueError("; ".join(problems))
    modes = selected_modes(selectors)
    modifiers = selected_modifiers(selectors)
    mode = modes[0] if modes else None
    dispatch = event == "workflow_dispatch"
    jobs = {job: False for job in JOBS}
    # Pure validation: every dispatch checks its selectors first; push/PR have
    # no manual selector and therefore no validation job at all.
    jobs["validate-selectors"] = dispatch
    # The lean lane is the only lane for push/PR and selector-free dispatches.
    jobs["lean-checks"] = not modes and not modifiers
    if dispatch and mode:
        jobs["build-test"] = mode in ("full", "build_test_only", "ide_only")
        jobs["live-agent-demo"] = mode == "live_agent_demo"
        jobs["local-inference"] = mode == "local_inference"
        jobs["feedback-ui"] = mode == "feedback_ui"
        jobs["publish-skill-hub"] = mode == "publish_skill_hub"
        jobs["appstore-sdk-compatibility"] = mode == "full"
        jobs["spm-linux-build"] = mode == "full"
    return {
        "event": event,
        "selectors": list(modes + modifiers),
        "lean": jobs["lean-checks"],
        "full": mode == "full",
        "jobs": jobs,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Validate a CI selector combination and print the resolved scope.")
    parser.add_argument("--event", choices=EVENTS, default="workflow_dispatch",
                        help="GitHub event; defaults to workflow_dispatch for local runs")
    parser.add_argument("--set", action="append", default=[], metavar="NAME=BOOL",
                        help="selector value, for example --set full=true (repeatable)")
    args = parser.parse_args(argv)

    selectors = {}
    for item in args.set:
        name, separator, value = item.partition("=")
        if not separator or not name:
            print(f"error: --set expects NAME=BOOL, got {item!r}", file=sys.stderr)
            return 2
        if name not in ALL_SELECTORS:
            print(f"error: unknown selector {name!r}", file=sys.stderr)
            return 2
        try:
            selectors[name] = parse_bool(value)
        except ValueError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2

    problems = validate(args.event, selectors)
    if problems:
        print("error: invalid CI selector combination:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(json.dumps(scope(args.event, selectors), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
