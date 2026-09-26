#!/usr/bin/env python3
"""Focused invariant for the IDE Office tab open trigger.

Build 229 device screenshots showed the IDE's embedded Office surface on its
opening spinner for DOCX/XLSX as well as PPTX. The owner loader was a bare
SwiftUI `.task` (plus an `.onAppear` commit binding) inside
`officeSurface(_:)`. Consecutive Office tabs keep the same structural view
identity, so switching from one Office tab to another never re-ran the
loader, and the newly active tab's session stayed `.idle` with no controller
and no watchdog — an endless "正在打开文档…".

The trigger must therefore be keyed on the active tab identity, with the
commit binding and the open call inside that keyed task. These are source
contracts that fail if the binding regresses to an id-less task; they are not
device or engine evidence.
"""

import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
IDE = ROOT / "FloeAgent/FloeApp/Workspace/WorkspaceIDEView.swift"
TABS = ROOT / "FloeAgent/FloeApp/Workspace/IDEWorkspaceTabs.swift"

OFFICE_SURFACE = re.compile(
    r"@ViewBuilder private func officeSurface\(_ tab: IDEWorkspaceTab\) -> some View \{(.*?)\n    \}\n",
    re.S)
TRIGGER_IDENTITY = re.compile(
    r"static func identity\(activeTab: IDEWorkspaceTab\?\) -> String \{\s*"
    r"activeTab\?\.id \?\? \"\"\s*\}")


def evaluate():
    """Return (label, passed) pairs for the trigger contract."""
    ide = IDE.read_text(encoding="utf-8")
    tabs = TABS.read_text(encoding="utf-8")
    match = OFFICE_SURFACE.search(ide)
    body = match.group(1) if match else ""
    return [
        ("officeSurface(_:) exists", match is not None),
        ("loader keyed on the active tab identity",
         ".task(id: IDEOfficeLoadTrigger.identity(activeTab: tab))" in body),
        ("keyed task opens the tab session",
         "openOfficeDocument(tab: tab, session: session)" in body),
        ("commit binding re-binds per active tab",
         "session.onCommitted = { onSaved() }" in body),
        ("no id-less loader task remains", not re.search(r"\.task\s*\{", body)),
        ("no onAppear-only commit binding",
         not re.search(r"\.onAppear\s*\{[^}]*onCommitted", body)),
        ("IDEOfficeLoadTrigger helper exists with the tab id",
         "enum IDEOfficeLoadTrigger" in tabs and TRIGGER_IDENTITY.search(tabs) is not None),
        ("same-path activation keeps a stable identity",
         "if let existing = tabs.first(where: { $0.id == relativePath })" in tabs),
    ]


def violations():
    return [label for label, passed in evaluate() if not passed]


class IDEOfficeTriggerInvariants(unittest.TestCase):
    def test_loader_is_keyed_on_the_active_tab_identity(self):
        failures = violations()
        self.assertEqual([], failures, "; ".join(failures))


def main():
    failures = violations()
    for label, passed in evaluate():
        print(("PASS  " if passed else "FAIL  ") + label)
    if failures:
        print("FAILED: " + "; ".join(failures))
        return 1
    print("ALL IDE OFFICE TRIGGER CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
