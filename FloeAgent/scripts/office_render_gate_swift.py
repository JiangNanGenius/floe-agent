#!/usr/bin/env python3
"""Compile and exercise the shipped Swift visible-render gate.

`OfficeRenderRequirement` and `OfficeVisibleRenderGate` are extracted verbatim
from `OfficeDocumentEditorView.swift` and compiled with a small harness. The
harness proves the contract the app relies on:

  - a presentation is NOT ready when only the open event settled;
  - it becomes ready on the host's visible-render signal, in either order;
  - the bounded deadline fails it, while Word/Excel keep open-only readiness;
  - a late host failure can never fail an already-ready session;
  - the failure copy states the edits were retained and offers recovery.

The engine and the device remain separate gates; this only exercises the state
machine that decides what the user is told.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'FloeApp/Workspace/OfficeDocumentEditorView.swift'


def extraction():
    text = SOURCE.read_text()
    return text.split('// FLOE_VISIBLE_RENDER_GATE_BEGIN', 1)[1] \
               .split('// FLOE_VISIBLE_RENDER_GATE_END', 1)[0]


HARNESS = r'''
import Foundation

/// The real file supplies this; the harness keeps both languages visible.
enum OfficeInkText {
    static func t(_ zh: String, _ en: String) -> String { zh + " || " + en }
}

func expect(_ condition: Bool, _ label: String) {
    if !condition {
        FileHandle.standardError.write(("FAIL " + label + "\n").data(using: .utf8)!)
        exit(1)
    }
}

@MainActor
func main() {
    // Classification mirrors the native host list.
    for name in ["ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx",
                 "odp", "otp", "fodp", "odg", "otg", "fodg", "PPTX", "PpTx"] {
        expect(OfficeRenderRequirement.forDocument(pathExtension: name) == .visibleRenderRequired, "classify " + name)
    }
    for name in ["docx", "doc", "xlsx", "xls", "odt", "ods", "rtf", "txt", "pdf", ""] {
        expect(OfficeRenderRequirement.forDocument(pathExtension: name) == .openOnly, "classify " + name)
    }

    // A presentation is never ready from the open event alone.
    var presentation = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
    expect(presentation.openSettled() == .waitingForRender, "presentation open is not ready")
    expect(!presentation.isReady && presentation.awaitsVisibleRender, "presentation waits for render")
    expect(!presentation.permitsSave, "an unrendered presentation cannot save")
    expect(presentation.visibleRenderObserved() == .ready, "presentation render settles ready")
    expect(presentation.isReady, "presentation is ready after render")
    expect(presentation.permitsSave, "a rendered presentation permits save")
    // A late failure after a real render never fails the session.
    expect(presentation.hostFailed() == .ready, "late failure cannot fail a rendered session")

    // Reverse order: the render signal can beat the open report.
    var earlyRender = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
    expect(earlyRender.visibleRenderObserved() == .ready, "render first settles ready")
    expect(earlyRender.openSettled() == .ready, "open after render keeps ready")

    // The bounded deadline fails only a session that awaits a render.
    var timedOut = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
    _ = timedOut.openSettled()
    expect(timedOut.deadlineExceeded() == .failed, "deadline fails a waiting presentation")
    expect(timedOut.hasFailed, "timed out presentation is failed")
    expect(!timedOut.permitsSave, "a timed out presentation cannot save")

    // Word/Excel keep the existing open-only contract.
    var document = OfficeVisibleRenderGate(requirement: .openOnly)
    expect(document.openSettled() == .ready, "document open is ready")
    expect(document.deadlineExceeded() == .ready, "deadline never fails a document")
    expect(document.hostFailed() == .ready, "host failure never fails a settled document")

    // The failure copy is actionable in both languages and never blank-claims.
    let readOnlyError = OfficeRenderFailure.noVisibleRender(readOnly: true)
    let editingError = OfficeRenderFailure.noVisibleRender(readOnly: false)
    for error in [readOnlyError, editingError] {
        let text = (error.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
        expect(text.contains("保留"), "chinese copy retains the copy: " + text)
        expect(text.contains("retained"), "english copy retains the copy: " + text)
        expect(text.contains("恢复") || text.contains("recover") || text.contains("retry"), "copy offers recovery: " + text)
        expect(text.contains("编辑副本") || text.contains("editing copy"), "copy names the retained editing copy: " + text)
    }
    expect(readOnlyError.domain == "org.floeagent.office.render", "stable error domain")
    print("swift visible-render gate passed")
}

main()
'''


def check():
    fragment = extraction()
    with tempfile.TemporaryDirectory(prefix='floe-swift-gate-') as folder:
        source = Path(folder) / 'main.swift'
        source.write_text(fragment + '\n' + HARNESS)
        subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '6', str(source),
                        '-o', str(Path(folder) / 'gate')],
                       check=True, capture_output=True, text=True, timeout=120)
        result = subprocess.run([str(Path(folder) / 'gate')], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise AssertionError('swift gate harness failed: ' + result.stdout + result.stderr)
    return {
        'checksPassed': [
            'presentation formats require a visible-render signal before ready',
            'Word/Excel keep their open-only readiness',
            'the bounded deadline fails a session that never paints',
            'a presentation that has not rendered cannot save',
            'a late host failure cannot fail an already rendered session',
            'the failure copy retains the editing copy and offers recovery',
        ],
        'swiftGateCompiled': True,
        'engineVisibleRenderPassed': False,
        'deviceVisibleRenderPassed': False,
    }


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
