#!/usr/bin/env python3
"""Regression net for the Build 199 Office/IDE interaction repairs.

Static invariant checks only; the behavioral evidence lives in the Swift
FloeAppTests OfficeBridgeStateTests suite, the node script fixtures and the
user's device pass. These checks fail if one of the reviewed repairs is
silently reverted:

* a discarded-before-mount Office controller close settles immediately instead
  of stalling on a bye ack that can never arrive (the "closing" spinner);
* read-only preview mounts report readiness without the engine permission
  probe delay;
* a failed edit activation restores the truthful read-only claim so retry
  stays possible instead of stranding a writable-looking dead session;
* the edit-permission settling window outlasts cold/compact remounts;
* Office documents in the IDE stay embedded in their tab (no second app
  window, no conflicting internal close chrome);
* the file manager's preview Edit routes to the one dedicated fullscreen
  editor with a single live document session;
* the preview's host-level Edit action is visible on every size class;
* the focused bridge/state/route tests are registered in both the yml spec
  and the generated project.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
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


host = read("FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm")
office = read("FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift")
ide = read("FloeAgent/FloeApp/Workspace/WorkspaceIDEView.swift")
preview = read("FloeAgent/FloeApp/Workspace/FilePreviewView.swift")
inspector = read("FloeAgent/FloeApp/Workspace/FileInspectorView.swift")
fullscreen = read("FloeAgent/FloeApp/Workspace/OfficeFullscreenEditorView.swift")
yml = read("FloeAgent/project.yml")
pbxproj = read("FloeAgent/FloeAgent.xcodeproj/project.pbxproj")

# --- Host: never-opened sessions close immediately --------------------------
check("BOOL openRequested;" in host and "BOOL openSettled;" in host and "BOOL documentOpened;" in host,
      "Host: open lifecycle flags exist")
check("self.openRequested = YES;" in host and "- (void)viewWillAppear:" in host,
      "Host: mounting marks the open request")
check("host.openSettled = YES;" in host and "host.documentOpened = success;" in host,
      "Host: UIDocument open settles the flags")
check(re.search(r"BOOL neverOpened = !self\.openRequested \|\| \(self\.openSettled && !self\.documentOpened\);", host)
      is not None, "Host: never-opened close fast-path exists")
check(re.search(r"if \(host\.readOnly\) \{.*?onWorkingCopyOpenedWithPermission\(YES, YES\)", host, re.S) is not None,
      "Host: preview mounts report readiness without the permission probe")

# --- Session: failed edits restore the truthful read-only claim -------------
execute_edit_catch = re.search(
    r"try await acknowledgeEditPermission\(\)\s*return !readOnly\s*\} catch \{(.*?)\} catch", office, re.S)
check(execute_edit_catch is not None and "readOnly = true" in execute_edit_catch.group(1),
      "Session: failed edit activation restores readOnly")
check("for _ in 0..<60 {" in office,
      "Session: edit-permission settling outlasts cold/compact remounts")

# --- IDE: Office stays embedded in its tab ----------------------------------
check("officeFullscreenTab" not in ide, "IDE: no Office fullscreen cover state")
check(".fullScreenCover" not in ide, "IDE: no full-screen cover at all")
check("正在全屏编辑" not in ide, "IDE: no fullscreen placeholder branch")
check("workspace.ide.office.fullscreen" not in ide, "IDE: no fullscreen action")
check("workspace.ide.office.edit" in ide and "workspace.ide.office.save" in ide
      and "workspace.ide.office.discard" in ide and "workspace.ide.office.share" in ide,
      "IDE: tab action bar keeps edit/save/discard/share")
check("officeLoadKey" in ide and "needsOfficeLoad" in ide,
      "IDE: office loader still keyed on the stable container")

# --- File manager: one dedicated fullscreen editor, one live session --------
check("OfficeFullscreenEditorView(relativePath: relativePath, center: center)" in preview,
      "Preview: Edit routes to the dedicated fullscreen editor")
check("OfficeDocumentEditorView" not in preview,
      "Preview: no parallel cover editor reusing the embedded session")
check(re.search(r"await officeSession\.release\(\)\s*isOfficeEditorPresented = true", preview) is not None,
      "Preview: embedded session releases before the dedicated editor opens")
check("OfficeFullscreenEditorView(relativePath: request.relativePath, center: center)" in inspector,
      "Inspector: expand action opens the dedicated fullscreen editor")
check("requestsEditingOnAppear: false" in fullscreen,
      "Fullscreen: editor requests editing only after its own open settles")

# --- Editor chrome: clear host-level Edit on every size class ---------------
document_actions = re.search(r"private var documentActions: some View \{(.*?)\n    \}", office, re.S)
check(document_actions is not None and "editAction" in document_actions.group(1)
      and document_actions.group(1).index("editAction") < document_actions.group(1).index("documentMenu"),
      "Editor: preview Edit action visible on compact and regular")
check("office.preview.edit.menu" not in office,
      "Editor: no duplicate Edit entry hidden in the menu")

# --- Focused tests registered -----------------------------------------------
check("OfficeBridgeStateTests.swift" in yml, "Spec: Office bridge tests listed in project.yml")
check(pbxproj.count("OfficeBridgeStateTests.swift") >= 4,
      "Project: Office bridge tests wired into the generated project")

print(f"\n{checks - len(failures)}/{checks} repair invariant checks passed")
if failures:
    print("FAILED: " + "; ".join(failures))
    sys.exit(1)
print("ALL REPAIR INVARIANT CHECKS PASSED")
