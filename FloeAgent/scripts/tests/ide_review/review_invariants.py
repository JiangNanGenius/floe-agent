#!/usr/bin/env python3
"""Regression net for the independently fixed Build191 IDE review findings and
the Build211 Git crash repair.

Static invariant checks only; the behavioral evidence lives in the
build_and_run*.sh harnesses (for the Git repair:
`ide_review/git_repair211_main.swift` via `run_git_review_harness.sh`). These
checks fail if one of the reviewed fixes is silently reverted.
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
check(".task(id: IDEOfficeLoadTrigger.identity(activeTab: tab))" in ide
      and 'activeTab?.id ?? ""' in tabs and "await openOfficeDocument(tab: tab, session: session)" in ide,
      "IDE: the embedded Office loader follows the active tab identity")
check(".task(id: tab.id)" not in ide,
      "IDE: no office loader tied to a replaced branch")
check("await tabs.releaseAll()" in ide, "IDE: teardown happens on IDE close")
check("func close(_ id: String) async" in tabs and "await tab.release()" in tabs,
      "Tabs: release only on actual tab close/releaseAll")

# --- Git build211 repair: bounded discovery + latest-only refresh -----------
# The crash frames resolve to LocalGitService.repositoryRoot(at:) line 25
# (the ancestor walk's existence probe) < snapshot < refreshRepository. The
# repair keeps discovery unbounded in depth but bounded by the app sandbox /
# home ownership boundary, and replaces the Foundation file-manager probe with
# one POSIX stat. Behavioural proof: git_repair211_main.swift (17 checks).
check("guard root.isFileURL else { return nil }" in git,
      "Git: non-file URLs never reach the ancestor walk")
check("func repositoryRoot(at root: URL, ownershipBoundary: URL) -> URL?" in git,
      "Git: discovery has an explicit, testable ownership boundary")
check("boundaryPaths.contains(path)" in git,
      "Git: walk stops at the ownership boundary")
check("private static func hasGitEntry(in directory: String)" in git
      and 'stat(directory + "/.git", &info) == 0' in git,
      "Git: .git marker probed with one POSIX stat")
check("0..<64" not in git and '"/System"' not in git and '"/private"' not in git,
      "Git: no arbitrary ancestor cap or system-directory denylist")
check("refreshGeneration &+= 1" in center,
      "SourceControlCenter: every refresh captures a new generation")
check("isCurrentRefresh(generation, root: root)" in center,
      "SourceControlCenter: stale results cannot publish")
check("generation == refreshGeneration && workspaceCenter.currentRootURL == root" in center,
      "SourceControlCenter: generation and workspace root both guard publishing")
check("await refreshTask.value" not in center,
      "SourceControlCenter: a workspace switch no longer joins the stale task")

# --- IDE Run eligibility: no play affordance for an unrelated workspace -----
# An ordinary workspace that merely contains index.html must not show a Run
# play button at all: the toolbar item renders only for a genuine target —
# an explicit project run extension, a recognized game root, or an active
# file the language-runner policy can actually run. Recognition comes from a
# bounded read-only game probe of the pinned root; tap-time
# `prepare`/`resolve` stay the single run path.
run_provider = read("FloeAgent/FloeApp/Game/GameIDERunExtensionProvider.swift")
check("enum IDEGameRootRecognition" in run_provider
      and "case recognized" in run_provider
      and "case notRecognized" in run_provider
      and "case unknown" in run_provider,
      "Run provider: recognition is tri-state with an unknown fallback")
check("func recognize(_ center: WorkspaceCenter)" in run_provider
      and "GameProjectInspector.hasGameCandidate(rootURL:" in run_provider,
      "Run provider: recognition is the bounded read-only hasGameCandidate preflight")
check("gameRootRecognition = result" in ide and "func probeGameRootIfNeeded()" in ide,
      "IDE: the pinned root is probed once per presentation for Run eligibility")
check("guard gameRootRecognition == nil," in ide and "projectRunExtension == nil," in ide,
      "IDE: the probe is a one-shot and defers to an explicit project extension")
check("private var runVisible: Bool" in ide
      and "if projectRunExtension != nil { return true }" in ide,
      "IDE: an explicit project run extension always keeps its run entry")
check("if gameRootRecognition == .recognized { return true }" in ide,
      "IDE: a recognized game root keeps Run without a text selection")
check("guard let path = state.activePath, !path.isEmpty else { return false }" in ide,
      "IDE: Run is absent when nothing is selected (the screenshot case)")
check("IDELanguageRunPolicy.definition(forRelativePath: path) != nil" in ide
      and "IDELanguageRunPolicy.isSafeWorkspaceRelativePath(path)" in ide,
      "IDE: Run is absent for active files the language runner cannot run")
check("if runVisible {" in ide
      and re.search(r'if runVisible \{.*?accessibilityIdentifier\("workspace\.ide\.run"\)',
                    ide, re.S) is not None,
      "IDE: the toolbar play renders only inside the runVisible gate")
check(re.search(r'if runVisible \{.*?\.disabled\(gameLookupTask != nil \|\| root == nil',
                ide, re.S) is not None,
      "IDE: the gated play keeps its transient busy/workspace guards")
ui_tests = read("FloeAgent/Tests/FloeAgentUITests/WorkspaceIDEUITests.swift")
check("XCTAssertFalse(app.buttons[\"workspace.ide.run\"].exists" in ui_tests
      and "workspace.ide.nativeRun" in ui_tests,
      "UI: an unsupported active file asserts the play affordance is absent")
check("ide-run-affordance-absent" in ui_tests,
      "UI: the absence assertion captures the screenshot case")
check("renameFixtureFile" in ui_tests and "IDE验收.py" in ui_tests,
      "UI: a runnable file makes the same play appear for the run-sheet checks")

# --- Sidebar quick collapse: one shared gesture on every persistent family ----
# Every persistent sidebar family must offer the shared quick-collapse route
# in addition to its reopen control (system sidebar toggle, activity rail or
# the phone drawer button); no family grows a second competing button.
check("collapseSidebarOnRightSwipe" in read("FloeAgent/FloeApp/App/FloeAgentApp.swift"),
      "Sidebar: the workbench split uses the shared quick collapse")
check("collapseSidebarOnRightSwipe" in read("FloeAgent/FloeApp/Settings/SettingsRootView.swift"),
      "Sidebar: the settings split uses the shared quick collapse")
github_view = read("FloeAgent/FloeApp/Workspace/GitHubCollaboration/GitHubCollaborationView.swift")
check("NavigationSplitView(columnVisibility: $columnVisibility," in github_view
      and "collapseSidebarOnRightSwipe" in github_view,
      "Sidebar: GitHub collaboration folds with the shared quick collapse")
quick_edit = read("FloeAgent/FloeApp/Game/GameProjectQuickEditScreen.swift")
check("NavigationSplitView(columnVisibility: $columnVisibility)" in quick_edit
      and "collapseSidebarOnRightSwipe" in quick_edit,
      "Sidebar: the game quick-edit split folds with the shared quick collapse")
canvas_view = read("FloeAgent/FloeApp/Workspace/WorkspaceCanvasView.swift")
check("collapseSidebarOnRightSwipe" in canvas_view
      and "columnVisibility = .detailOnly" in canvas_view,
      "Sidebar: the canvas document list folds with the shared quick collapse")
onboarding_view = read("FloeAgent/FloeApp/Onboarding/OnboardingView.swift")
check("NavigationSplitView(columnVisibility: $columnVisibility)" in onboarding_view
      and "collapseSidebarOnRightSwipe" in onboarding_view,
      "Sidebar: the setup guide split folds with the shared quick collapse")
check("workspace.ide.sidebar.close" in read("FloeAgent/FloeApp/Workspace/IDESidebar.swift"),
      "Sidebar: the IDE keeps its own accessible close control")

print(f"\n{checks - len(failures)}/{checks} review invariant checks passed")
if failures:
    print("FAILED: " + "; ".join(failures))
    sys.exit(1)
print("ALL REVIEW INVARIANT CHECKS PASSED")
