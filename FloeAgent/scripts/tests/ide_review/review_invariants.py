#!/usr/bin/env python3
"""Regression net for the independently fixed Build191 IDE review findings.

Static invariant checks only; the behavioral evidence lives in the
build_and_run*.sh harnesses. These checks fail if one of the reviewed fixes is
silently reverted.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[4]
failures: list[str] = []
checks = 0


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def check(condition: bool, label: str) -> None:
    global checks
    checks += 1
    if condition:
        print(f"PASS  {label}")
    else:
        print(f"FAIL  {label}")
        failures.append(label)


git = read("FloeAgent/Sources/FloeGit/LocalGitService.swift")
center = read("FloeAgent/FloeApp/Workspace/SourceControlCenter.swift")
view = read("FloeAgent/FloeApp/Workspace/SourceControlView.swift")
office = read("FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift")
ide = read("FloeAgent/FloeApp/Workspace/WorkspaceIDEView.swift")
tabs = read("FloeAgent/FloeApp/Workspace/IDEWorkspaceTabs.swift")

# --- Git: fast-forward moves the current branch, not the merged ref ---------
check("git_reference_set_target(&updated, headReference, targetOID" in git,
      "Git: fast-forward retargets HEAD")
check("git_reference_set_target(&updated, reference, targetOID" not in git,
      "Git: fast-forward does not retarget the merged ref")
check("git_checkout_tree(repository, targetObject, &checkoutOptions)" in git,
      "Git: fast-forward checks out the target tree")
check("git_repository_head(&headReference, repository)" in git,
      "Git: fast-forward resolves the current branch")

# --- Git: conflicted paths read the C string, not the pointer bytes ---------
check("guard let rawPath = entry.pointee.path" in git,
      "Git: conflict path reads entry.pointee.path")
check("assumingMemoryBound" not in git,
      "Git: no pointer-byte reinterpretation for index entry paths")

# --- Git: discard is staged-aware -------------------------------------------
check("includeStaged: Bool = false" in git, "Git: discard exposes includeStaged")
check("writeIndexRecovery" in git, "Git: discard preserves staged index bytes")
check("try unstage(paths: stagedTargets, at: root)" in git,
      "Git: discard resets staged entries")
check("includeStaged" in center, "SourceControlCenter: passes includeStaged")
check("let includeStaged = change.staged" in view,
      "SourceControlView: staged rows discard index + worktree")

# --- Office: released session is terminal until an explicit open ------------
check("private var released = false" in office, "Office: session has a released latch")
check("guard !released else { return false }" in office,
      "Office: queued intent cannot revive a released session")
check("released = true" in office, "Office: release sets the latch")
check(re.search(r"func open\(_ url: URL\) async \{.*?released = false", office, re.S) is not None,
      "Office: explicit open starts a new lifecycle")

# --- IDE: embedded Office ownership ------------------------------------------
# Build 199 repair: the Office document stays embedded in its own IDE tab for
# preview and editing; no second app window re-parents the native controller,
# so the old fullscreen cover and its placeholder are gone for good.
check("officeFullscreenTab" not in ide,
      "IDE: no Office fullscreen cover (second window) remains")
check("OfficeDocumentEditorView" not in ide,
      "IDE: the tab embeds the shared Office surface, not a second editor chrome")
check("OfficeDocumentSurface(session: session)" in ide,
      "IDE: office tab embeds the session surface")
check("officeLoadKey" in ide and "needsOfficeLoad" in ide,
      "IDE: office loader keyed on the stable container")
check(".task(id: tab.id)" not in ide,
      "IDE: no office loader tied to a replaced branch")
check("await tabs.releaseAll()" in ide, "IDE: teardown happens on IDE close")
check("func close(_ id: String) async" in tabs and "await tab.release()" in tabs,
      "Tabs: release only on actual tab close/releaseAll")

print(f"\n{checks - len(failures)}/{checks} review invariant checks passed")
if failures:
    print("FAILED: " + "; ".join(failures))
    sys.exit(1)
print("ALL REVIEW INVARIANT CHECKS PASSED")
