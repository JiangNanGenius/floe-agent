#!/usr/bin/env python3
"""Read-only guard against silently dropping an agreed work package.

Also validates the plan's six-state completion vocabulary. The Chinese
meanings come from plan section 11.1:

    planned              待开始
    implementing         实现中
    component_verified   组件验证通过
    app_verified         完整 App 验证通过
    samsung_verified     三星验证通过
    delivered            已交付

A verified state (the last four) must carry a nonempty ``evidence`` list of
nonempty references. That is a structural check only: it does not prove the
referenced command, test or device run happened. Current all-``planned`` data
passes; advancing a status later requires real evidence references.
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "docs" / "FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md"
LEDGER = ROOT / "FloeAndroid" / "planning" / "work-packages.json"

STATUS_MEANINGS = {
    "planned": "待开始",
    "implementing": "实现中",
    "component_verified": "组件验证通过",
    "app_verified": "完整 App 验证通过",
    "samsung_verified": "三星验证通过",
    "delivered": "已交付",
}
VERIFIED_STATUSES = {
    "component_verified",
    "app_verified",
    "samsung_verified",
    "delivered",
}
IMPLEMENTATION_GOALS = {"G%02d" % i for i in range(1, 12)}
VERIFICATION_GOALS = {"G%02d" % i for i in range(1, 16)}


def evidence_references(item):
    """Return the evidence list when it is structurally valid, else None."""
    evidence = item.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        return None
    if any(not isinstance(ref, str) or not ref.strip() for ref in evidence):
        return None
    return evidence


def validate(plan_text, ledger):
    failures = []
    expected = set(re.findall(r"^\| (P\d\.\d+) ", plan_text, re.M))
    if len(expected) != 85:
        failures.append("plan lists %d work packages, expected 85" % len(expected))

    packages = ledger.get("packages")
    if not isinstance(packages, list):
        return failures + ["work-package ledger has no packages list"]

    actual = [item.get("id") for item in packages]
    if len(actual) != 85:
        failures.append("ledger lists %d work packages, expected 85" % len(actual))
    duplicates = sorted({pid for pid in actual if actual.count(pid) > 1})
    if duplicates:
        failures.append("duplicate work package ids: %s" % duplicates)
    if set(actual) != expected:
        failures.append("work package ids differ from the plan: %s"
                        % sorted(set(actual) ^ expected))

    for item in packages:
        pid = item.get("id") or "<missing-id>"
        goal = item.get("implementationGoal")
        if goal not in IMPLEMENTATION_GOALS:
            failures.append("%s: bad implementation goal %r" % (pid, goal))
        verification = item.get("verificationGoals")
        if not verification or not all(g in VERIFICATION_GOALS
                                       for g in verification):
            failures.append("%s: bad verification goals %r"
                            % (pid, verification))
        owner = item.get("owner")
        if not isinstance(owner, str) or not owner.strip():
            failures.append("%s: owner must be a nonempty string" % pid)

        status = item.get("status")
        if status not in STATUS_MEANINGS:
            failures.append("%s: unknown status %r (allowed: %s)"
                            % (pid, status, ", ".join(STATUS_MEANINGS)))
            continue
        if status in VERIFIED_STATUSES and evidence_references(item) is None:
            failures.append(
                "%s: status %s (%s) requires a nonempty evidence list"
                % (pid, status, STATUS_MEANINGS[status])
            )
        elif "evidence" in item and evidence_references(item) is None:
            failures.append(
                "%s: evidence must be a nonempty list of nonempty references"
                % pid
            )
    return failures


def main(argv):
    if len(argv) > 1 and argv[1] not in ("--check",):
        print("usage: check-plan.py [--check]   (read-only validator)")
        return 2
    try:
        plan_text = PLAN.read_text(encoding="utf-8")
        ledger = json.loads(LEDGER.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print("FAIL cannot read plan or ledger: %s" % exc)
        return 1

    failures = validate(plan_text, ledger)
    for failure in failures:
        print("FAIL %s" % failure)
    if failures:
        print("check-plan: %d failures" % len(failures))
        return 1

    counts = Counter(item["status"] for item in ledger["packages"])
    summary = ", ".join("%s=%d" % (status, counts[status])
                        for status in STATUS_MEANINGS if counts[status])
    print("85 work packages: unique, assigned, verification ownership present; "
          "statuses %s" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
