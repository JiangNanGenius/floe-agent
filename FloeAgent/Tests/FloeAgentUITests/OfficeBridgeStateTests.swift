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
import FloeGit
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
            #expect(WorkspaceFileRouter.destination(for: path) == .officeEditor, Comment(rawValue: path))
            #expect(!WorkspaceFileRouter.allowsCodeEditor(path), Comment(rawValue: path))
        }
    }

    @Test("Office bytes can never reach the code workbench or the document viewer")
    func officeNeverRoutesToCodeOrViewer() {
        for path in ["a.docx", "b.xlsx", "c.pptx"] {
            #expect(WorkspaceFileRouter.destination(for: path) != .codeEditor, Comment(rawValue: path))
            #expect(WorkspaceFileRouter.destination(for: path) != .documentViewer, Comment(rawValue: path))
            #expect(WorkspaceFileRouter.destination(for: path) != .quickLook, Comment(rawValue: path))
        }
        #expect(WorkspaceFileRouter.destination(for: "main.swift") == .codeEditor)
        #expect(WorkspaceFileRouter.destination(for: "spec.pdf") == .documentViewer)
    }

    @Test("Archives route to the tree browser and never to the code workbench")
    func archivesRouteToBrowser() {
        for path in ["bundle.zip", "src.tar", "data.7z", "nested/inner.ZIP"] {
            #expect(WorkspaceFileRouter.destination(for: path) == .archiveBrowser, Comment(rawValue: path))
            #expect(!WorkspaceFileRouter.allowsCodeEditor(path), Comment(rawValue: path))
        }
        // Formats the browser cannot read still reach it, so it can report the
        // concrete reason instead of opening an opaque binary preview.
        for path in ["photo.tgz", "legacy.rar", "raw.gz"] {
            #expect(WorkspaceFileRouter.destination(for: path) == .archiveBrowser, Comment(rawValue: path))
        }
        #expect(WorkspaceFileRouter.destination(for: "image.png") == .imageViewer)
    }

    @Test("A workspace preview routes Office to the standalone editor; only PDF keeps the IDE entry")
    func previewHeaderRoutingKeepsOfficeStandalone() {
        // Office documents opened from a workspace preview keep the standalone
        // full-screen editor; the IDE embedded tab is reserved for opens that
        // start in the IDE file tree.
        for path in ["deck.pptx", "report.docx", "book.xlsx", "dir/子表.XLSX"] {
            #expect(!FileInspectorView.previewHeaderShowsIDEEntry(for: path), Comment(rawValue: path))
        }
        // PDF keeps its IDE viewer expansion.
        #expect(FileInspectorView.previewHeaderShowsIDEEntry(for: "spec.pdf"))
    }

    @Test("An archive opens one IDE document tab, never an Office or code tab")
    @MainActor
    func archiveOpensDocumentTab() {
        let store = IDEWorkspaceTabStore(initialRelativePath: "bundle.zip")
        let tab = store.open(relativePath: "bundle.zip")
        #expect(tab?.kind == .document)
        #expect(tab?.officeSession == nil)
        #expect(store.tabs.filter { $0.id == "bundle.zip" }.count == 1)
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

    @Test("An Office initial path opens its typed IDE tab")
    @MainActor
    func initialOfficePathOpensEmbedded() {
        let store = IDEWorkspaceTabStore(initialRelativePath: "docs/deck.pptx")
        #expect(store.activeTab?.kind == .office)
        #expect(store.activeTab?.relativePath == "docs/deck.pptx")
        #expect(store.tabs.count == 2)
    }

    @Test("A PDF initial path opens its typed IDE tab")
    @MainActor
    func initialPDFPathOpensEmbedded() {
        let store = IDEWorkspaceTabStore(initialRelativePath: "docs/spec.pdf")
        #expect(store.activeTab?.kind == .document)
        #expect(store.activeTab?.relativePath == "docs/spec.pdf")
        #expect(store.tabs.count == 2)
    }

    @Test("Closing a clean read-only Office tab needs no user decision")
    func closeDecisionCleanPreviewClosesImmediately() {
        #expect(IDEOfficeCloseDecision.decide(readOnly: true, hasUncommittedChanges: false, isReady: true)
            == .closeImmediately)
        #expect(IDEOfficeCloseDecision.decide(readOnly: true, hasUncommittedChanges: false, isReady: false)
            == .closeImmediately)
    }

    @Test("Closing an Office tab with edits at stake always asks the user")
    func closeDecisionDirtyAsksUser() {
        // Uncommitted edits, even on a preview that regained read-only.
        #expect(IDEOfficeCloseDecision.decide(readOnly: true, hasUncommittedChanges: true, isReady: false)
            == .askUser)
        // An editable session, settled or still settling.
        #expect(IDEOfficeCloseDecision.decide(readOnly: false, hasUncommittedChanges: false, isReady: true)
            == .askUser)
        #expect(IDEOfficeCloseDecision.decide(readOnly: false, hasUncommittedChanges: false, isReady: false)
            == .askUser)
        #expect(IDEOfficeCloseDecision.decide(readOnly: false, hasUncommittedChanges: true, isReady: true)
            == .askUser)
    }
}

@Suite("FloeApp.OfficeVisibleRenderGate")
struct OfficeVisibleRenderGateTests {

    @Test("A presentation is not ready when only UIDocument open and permission settled")
    func presentationOpenIsNotReady() {
        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        #expect(gate.openSettled() == .waitingForRender)
        #expect(!gate.isReady)
        #expect(gate.awaitsVisibleRender)
        // A save may not start from an unrendered presentation: this is the
        // same condition `canAct` applies through `phase == .ready`.
        #expect(!gate.permitsSave)
        // The engine permission and the save receipt are not render evidence:
        // neither exists in this state machine, and only the host's painted
        // surface can move it to ready.
        #expect(gate.visibleRenderObserved() == .ready)
        #expect(gate.isReady)
        #expect(gate.permitsSave)
    }

    @Test("The visible-render signal settles ready in either order")
    func renderSignalSettlesInEitherOrder() {
        var renderFirst = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        #expect(renderFirst.visibleRenderObserved() == .ready)
        #expect(renderFirst.openSettled() == .ready)
        var openFirst = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        #expect(openFirst.openSettled() == .waitingForRender)
        #expect(openFirst.visibleRenderObserved() == .ready)
        #expect(openFirst.isReady)
    }

    @Test("The bounded deadline fails a presentation that never paints")
    func deadlineFailsWithoutRender() {
        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        _ = gate.openSettled()
        #expect(gate.deadlineExceeded() == .failed)
        #expect(gate.hasFailed)
        #expect(!gate.permitsSave)
        // A host failure is terminal too, and a late render cannot revive it.
        #expect(gate.visibleRenderObserved() == .failed)
        #expect(!gate.isReady)
    }

    @Test("A late host failure never fails an already rendered session")
    func lateFailureCannotFailReadySession() {
        var gate = OfficeVisibleRenderGate(requirement: .visibleRenderRequired)
        _ = gate.openSettled()
        _ = gate.visibleRenderObserved()
        #expect(gate.hostFailed() == .ready)
        #expect(gate.isReady)
        #expect(gate.permitsSave)
    }

    @Test("Word and Excel keep the open-only contract")
    func documentsKeepOpenOnlyReadiness() {
        var gate = OfficeVisibleRenderGate(requirement: .openOnly)
        #expect(gate.openSettled() == .ready)
        #expect(gate.deadlineExceeded() == .ready)
        #expect(gate.hostFailed() == .ready)
        #expect(gate.isReady)
        #expect(gate.permitsSave)
    }

    @Test("Presentation formats require a visible render; Word/Excel do not")
    func formatClassification() {
        for name in ["ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx",
                     "odp", "otp", "fodp", "odg", "otg", "fodg", "PPTX", "PpTx"] {
            #expect(OfficeRenderRequirement.forDocument(pathExtension: name) == .visibleRenderRequired,
                    Comment(rawValue: name))
        }
        for name in ["docx", "doc", "xlsx", "xls", "odt", "ods", "rtf", "txt", "pdf", ""] {
            #expect(OfficeRenderRequirement.forDocument(pathExtension: name) == .openOnly,
                    Comment(rawValue: name))
        }
    }

    @Test("The no-render failure retains the editing copy and offers recovery")
    @MainActor
    func noRenderFailureIsActionable() {
        for readOnly in [true, false] {
            let error = OfficeRenderFailure.noVisibleRender(readOnly: readOnly)
            let text = (error.userInfo[NSLocalizedDescriptionKey] as? String) ?? ""
            #expect(text.contains("保留") || text.contains("retained"),
                    Comment(rawValue: "copy must state the working copy was retained: \(text)"))
            #expect(text.contains("恢复") || text.contains("retry") || text.contains("recover"),
                    Comment(rawValue: "copy must offer retry/recovery: \(text)"))
            // Never a blank editor claim: the copy must not present as a
            // successful, ready presentation.
            #expect(!text.contains("已就绪") || text.contains("未"))
        }
    }
}

@Suite("FloeApp.OfficeOpenRecovery")
struct OfficeOpenRecoveryTests {

    @Test("A resolve/open failure reaches a recoverable failed state, not an idle spinner")
    @MainActor
    func openFailureIsTerminalAndRecoverable() async {
        let session = OfficeFileSession()
        // Before any open the session is an idle, read-only preview.
        #expect(session.phase == .idle)
        #expect(session.readOnly)
        // The owning surface reports a resolve/open failure (previously this
        // only set `error`, leaving the phase on `.idle` → endless spinner).
        session.reportOpenFailure(CocoaError(.fileReadNoPermission))
        #expect(session.phase == .failed)
        #expect(session.error != nil)
        // Retry resets to `.idle` even though no working copy was ever
        // created, so the owning loader re-arms and can retry the open.
        await session.retryPreview()
        #expect(session.phase == .idle)
        #expect(session.error == nil)
    }
}

@Suite("FloeApp.OfficeDeadlineGate")
struct OfficeDeadlineGateTests {

    @Test("The receipt returns at the deadline even when the callback never fires")
    @MainActor
    func deadlineGateReturnsWithoutCallback() async {
        let receipt = OfficeSaveReceipt()
        // Arm only a deadline; no engine callback ever resolves the receipt.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            receipt.resolve(.failure(CocoaError(.fileReadUnknown)))
        }
        let start = Date()
        try? await receipt.wait()
        // `wait()` returned because the deadline fired, not a callback.
        #expect(Date().timeIntervalSince(start) < 2.0)
        await deadline.value
        // A late second resolve is ignored (no double-resume crash).
        receipt.resolve(.success(()))
    }

    @Test("The first resolver wins and a late resolution is ignored")
    @MainActor
    func firstResolverWins() async {
        let receipt = OfficeSaveReceipt()
        receipt.resolve(.success(()))
        try? await receipt.wait()
        receipt.resolve(.failure(CocoaError(.fileReadUnknown)))
        // Reaching here without a crash means the late failure was ignored.
    }
}

@Suite("FloeApp.SourceControlChangeTree")
struct SourceControlChangeTreeTests {

    @Test("groups changes by directory into a nested, sorted tree")
    @MainActor
    func groupsByDirectory() {
        let changes = [
            GitFileChange(path: "Sources/Core/engine.swift", kind: .modified, staged: false),
            GitFileChange(path: "Sources/App/main.swift", kind: .modified, staged: false),
            GitFileChange(path: "README.md", kind: .modified, staged: false),
        ]
        let tree = SourceControlChangeTree.build(changes)
        #expect(tree.count == 2)
        // Sorted: "README.md" < "Sources".
        #expect(tree[0].name == "README.md")
        #expect(tree[0].change != nil)
        #expect(tree[0].isFolder == false)
        #expect(tree[1].name == "Sources")
        #expect(tree[1].isFolder)
        #expect(tree[1].change == nil)
        #expect(tree[1].children.map(\.name) == ["App", "Core"])
        let app = tree[1].children[0]
        #expect(app.isFolder)
        #expect(app.children.count == 1)
        #expect(app.children[0].name == "main.swift")
        #expect(app.children[0].change?.path == "Sources/App/main.swift")
        // Ids are full repository-relative paths (stable across refreshes).
        #expect(app.children[0].id == "Sources/App/main.swift")
    }

    @Test("an empty change list builds an empty tree")
    @MainActor
    func emptyBuildsEmpty() {
        #expect(SourceControlChangeTree.build([]).isEmpty)
    }
}
#endif
