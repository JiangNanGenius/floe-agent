// SPDX-License-Identifier: MPL-2.0
//
// Focused Office bridge / state / routing tests. No simulator, engine or
// network is touched: these assert the intent queue that serializes
// preview/edit lifecycle intents, the typed open routing that keeps Office
// bytes out of the code workbench, and the IDE tab identity that keeps a
// Word/Excel/PowerPoint document embedded in exactly one tab.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.OfficeEditIntentQueue")
struct OfficeEditIntentQueueTests {

    @Test("An idle session runs the intent immediately")
    func idleRunsNow() {
        var queue = OfficeEditIntentQueue()
        #expect(queue.begin(.preview, isBusy: false) == .runNow(token: 1))
        #expect(queue.begin(.edit, isBusy: false) == .runNow(token: 2))
        #expect(!queue.hasPending)
    }

    @Test("An automatic preview reopen can never displace a queued edit")
    func previewNeverDisplacesQueuedEdit() {
        var queue = OfficeEditIntentQueue()
        guard case .queued(let editTicket) = queue.begin(.edit, isBusy: true) else {
            Issue.record("explicit edit must queue behind a busy session")
            return
        }
        #expect(queue.begin(.preview, isBusy: true) == .ignorePreview)
        #expect(queue.begin(.preview, isBusy: true) == .ignorePreview)
        let taken = queue.takePending()
        #expect(taken?.intent == .edit)
        #expect(taken?.token == editTicket.token)
        #expect(!queue.hasPending)
    }

    @Test("A newer explicit intent supersedes an older queued one")
    func newerIntentSupersedesOlder() {
        var queue = OfficeEditIntentQueue()
        guard case .queued(let first) = queue.begin(.preview, isBusy: true) else {
            Issue.record("first intent must queue")
            return
        }
        guard case .queued(let second) = queue.begin(.edit, isBusy: true) else {
            Issue.record("second intent must queue")
            return
        }
        #expect(second.supersededToken == first.token)
        let taken = queue.takePending()
        #expect(taken?.intent == .edit)
        #expect(taken?.token == second.token)
    }

    @Test("Release cancels the queued intent so its waiter can be resumed")
    func releaseCancelsPending() {
        var queue = OfficeEditIntentQueue()
        guard case .queued(let ticket) = queue.begin(.edit, isBusy: true) else {
            Issue.record("explicit edit must queue")
            return
        }
        #expect(queue.cancelPending() == ticket.token)
        #expect(!queue.hasPending)
        #expect(queue.takePending() == nil)
    }

    @Test("A taken intent restored after a race is replayed once")
    func restoreAfterRace() {
        var queue = OfficeEditIntentQueue()
        guard case .queued(let ticket) = queue.begin(.edit, isBusy: true) else {
            Issue.record("explicit edit must queue")
            return
        }
        let firstTake = queue.takePending()
        #expect(firstTake?.intent == .edit)
        #expect(firstTake?.token == ticket.token)
        queue.restoreIfEmpty(intent: .edit, token: ticket.token)
        // A newer queued intent is never clobbered by the restore.
        queue.restoreIfEmpty(intent: .preview, token: 999)
        let restored = queue.takePending()
        #expect(restored?.intent == .edit)
        #expect(restored?.token == ticket.token)
        #expect(queue.takePending() == nil)
    }
}

@Suite("FloeApp.OfficeRouting")
struct OfficeRoutingTests {

    @Test("Word, Excel, PowerPoint and ODF/rtf files route to the native Office editor")
    func officeExtensionsRouteToOfficeEditor() {
        for path in ["报告.docx", "book.docm", "doc.doc", "table.xlsx", "x.xlsm", "x.xls",
                     "deck.pptx", "d.pptm", "d.ppt", "note.odt", "s.ods", "p.odp",
                     "letter.rtf", "dir/子表.XLSX"] {
            #expect(WorkspaceFileRouter.destination(for: path) == .officeEditor, path)
            #expect(!WorkspaceFileRouter.allowsCodeEditor(path), path)
        }
    }

    @Test("Office bytes can never reach the code workbench or the document viewer")
    func officeNeverRoutesToCodeOrViewer() {
        for path in ["a.docx", "b.xlsx", "c.pptx"] {
            #expect(WorkspaceFileRouter.destination(for: path) != .codeEditor, path)
            #expect(WorkspaceFileRouter.destination(for: path) != .documentViewer, path)
            #expect(WorkspaceFileRouter.destination(for: path) != .quickLook, path)
        }
        #expect(WorkspaceFileRouter.destination(for: "main.swift") == .codeEditor)
        #expect(WorkspaceFileRouter.destination(for: "spec.pdf") == .documentViewer)
    }
}

@Suite("FloeApp.OfficeIDETabs")
struct OfficeIDETabTests {

    @Test("Opening an Office file creates exactly one embedded office tab")
    @MainActor
    func officeOpensOneEmbeddedTab() {
        let store = IDEWorkspaceTabStore(initialRelativePath: nil)
        let tab = store.open(relativePath: "docs/报告.docx")
        #expect(tab?.kind == .office)
        #expect(tab?.officeSession != nil)
        #expect(store.tabs.filter { $0.id == "docs/报告.docx" }.count == 1)
        #expect(store.activeTab?.id == "docs/报告.docx")
        // The tab is the editor surface; the session starts as a read-only
        // preview until the tab's explicit Edit action requests editing.
        #expect(tab?.officeSession?.readOnly == true)
        #expect(tab?.hasUnsavedChanges == false)
    }

    @Test("Re-opening the same Office path activates the existing tab instead of duplicating it")
    @MainActor
    func reopeningActivatesSameTab() {
        let store = IDEWorkspaceTabStore(initialRelativePath: nil)
        let first = store.open(relativePath: "docs/报告.docx")
        _ = store.open(relativePath: "main.swift")
        let second = store.open(relativePath: "docs/报告.docx")
        #expect(first === second)
        #expect(store.tabs.filter { $0.kind == .office }.count == 1)
        #expect(store.activeTab === first)
    }

    @Test("A code path stays on the workbench tab and never becomes an office tab")
    @MainActor
    func codePathStaysOnCodeTab() {
        let store = IDEWorkspaceTabStore(initialRelativePath: nil)
        let tab = store.open(relativePath: "Sources/main.swift")
        #expect(tab?.kind == .code)
        #expect(store.activeTab?.kind == .code)
        #expect(store.tabs.allSatisfy { $0.kind != .office })
    }

    @Test("Closing an office tab removes it and releases its session")
    @MainActor
    func closingTabReleasesSession() async {
        let store = IDEWorkspaceTabStore(initialRelativePath: nil)
        let tab = store.open(relativePath: "docs/报告.docx")
        #expect(tab != nil)
        await store.close("docs/报告.docx")
        #expect(store.tabs.allSatisfy { $0.id != "docs/报告.docx" })
        #expect(store.activeTab?.kind == .code)
    }

    @Test("An Office initial path opens embedded in its own tab, never a second surface")
    @MainActor
    func initialOfficePathOpensEmbedded() {
        let store = IDEWorkspaceTabStore(initialRelativePath: "docs/deck.pptx")
        #expect(store.activeTab?.kind == .office)
        #expect(store.activeTab?.id == "docs/deck.pptx")
        #expect(store.tabs.count == 2) // code tab + the one office tab
    }
}
#endif
