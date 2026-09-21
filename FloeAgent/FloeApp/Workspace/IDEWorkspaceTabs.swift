// FloeApp — Native tab model for the unified workspace IDE.
//
// SPDX-License-Identifier: MPL-2.0
//
// The IDE is one CodeBlitz workbench. Its internal editor tabs own text/code
// AND PDF/Office documents (custom document component, native overlay clipped
// to the reported rectangle) — those never appear in this native strip. The
// strip only hosts the code container plus typed viewers for the remaining
// routed kinds (CAD/image/media/Quick Look).
//
// Text routing stays authoritative: an Office/PDF/CAD/image path can never
// become a code tab, so the web workbench never sees bytes it would decode
// and write back as UTF-8.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeWorkspace

enum IDEWorkspaceTabKind: String, Equatable {
    case code
    case office
    case document

    var systemImage: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .office: "doc.richtext"
        case .document: "doc.text.magnifyingglass"
        }
    }
}

/// Pure decision for closing an Office tab (native strip tab or an internal
/// CodeBlitz document tab): a clean read-only preview closes immediately;
/// anything holding user changes hands the save/discard/cancel decision to
/// the user. Keeping this pure lets focused tests pin the close policy
/// without an engine or a simulator.
enum IDEOfficeCloseDecision: Equatable {
    /// No changes at stake — close (release the session) right away.
    case closeImmediately
    /// Unsaved changes exist — the user chooses save / discard / cancel.
    case askUser

    /// - Parameters:
    ///   - readOnly: whether the session is still a read-only preview.
    ///   - hasUncommittedChanges: edits not yet written back to the original.
    ///   - isReady: whether an editable engine session is live right now.
    static func decide(readOnly: Bool, hasUncommittedChanges: Bool, isReady: Bool) -> IDEOfficeCloseDecision {
        if hasUncommittedChanges { return .askUser }
        // An editable session (settled or still settling) may hold
        // engine-side edits that have not been reported yet; closing must
        // never silently drop them.
        if !readOnly { return .askUser }
        return .closeImmediately
    }
}

@MainActor
final class IDEWorkspaceTab: ObservableObject, @MainActor Identifiable {
    let relativePath: String
    let kind: IDEWorkspaceTabKind
    /// One Office session per Office tab. The embedded preview and the
    /// in-tab editor both read this same object, so there is exactly one
    /// working copy, one save receipt and one conflict baseline per document.
    let officeSession: OfficeFileSession?

    var id: String { relativePath }
    var title: String { (relativePath as NSString).lastPathComponent }

    init(relativePath: String, kind: IDEWorkspaceTabKind) {
        self.relativePath = relativePath
        self.kind = kind
        self.officeSession = kind == .office ? OfficeFileSession() : nil
    }

    /// True while this tab owns changes that a close would lose.
    var hasUnsavedChanges: Bool {
        guard let officeSession else { return false }
        return IDEOfficeCloseDecision.decide(
            readOnly: officeSession.readOnly,
            hasUncommittedChanges: officeSession.hasUncommittedChanges,
            isReady: officeSession.phase == .ready
        ) == .askUser
    }

    func release() async {
        await officeSession?.release()
    }
}

@MainActor
final class IDEWorkspaceTabStore: ObservableObject {
    @Published private(set) var tabs: [IDEWorkspaceTab] = []
    @Published var activeTabID: String?
    static let codeTabID = "__floe_code__"

    init(initialRelativePath: String?) {
        tabs = [codeTab(active: true)]
        guard let initialRelativePath, !initialRelativePath.isEmpty else {
            activeTabID = Self.codeTabID
            return
        }
        switch WorkspaceFileRouter.destination(for: initialRelativePath) {
        case .codeEditor, .officeEditor:
            // Office documents are internal CodeBlitz tabs; the IDE view
            // forwards the initial path once the workbench is ready.
            activeTabID = Self.codeTabID
        case .documentViewer where WorkspaceTextPolicy.isPDFPath(initialRelativePath):
            // PDFs are internal CodeBlitz tabs as well.
            activeTabID = Self.codeTabID
        default:
            _ = open(relativePath: initialRelativePath)
        }
    }

    private func codeTab(active: Bool) -> IDEWorkspaceTab {
        IDEWorkspaceTab(relativePath: Self.codeTabID, kind: .code)
    }

    var activeTab: IDEWorkspaceTab? {
        guard let activeTabID else { return tabs.first }
        return tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    /// Opens (or activates) the routed tab for a path. Returns the tab, or nil
    /// when the path must not be opened in the IDE at all.
    @discardableResult
    func open(relativePath: String) -> IDEWorkspaceTab? {
        let kind: IDEWorkspaceTabKind
        switch WorkspaceFileRouter.destination(for: relativePath) {
        case .codeEditor:
            // A text file stays inside the web workbench's own tab strip;
            // the native code tab is the container for that surface.
            activeTabID = Self.codeTabID
            return tabs.first { $0.id == Self.codeTabID }
        case .officeEditor:
            kind = .office
        case .documentViewer, .cadViewer, .imageViewer, .mediaEditor, .archiveBrowser, .quickLook:
            kind = .document
        }
        if let existing = tabs.first(where: { $0.id == relativePath }) {
            activeTabID = existing.id
            return existing
        }
        let tab = IDEWorkspaceTab(relativePath: relativePath, kind: kind)
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func activate(_ id: String) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func close(_ id: String) async {
        guard id != Self.codeTabID, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tabs.remove(at: index)
        if activeTabID == id {
            let neighbour = tabs.indices.contains(index) ? tabs[index] : tabs.last
            activeTabID = neighbour?.id ?? Self.codeTabID
        }
        await tab.release()
    }

    func releaseAll() async {
        for tab in tabs where tab.kind == .office { await tab.release() }
    }

    func contains(_ relativePath: String) -> Bool {
        tabs.contains { $0.id == relativePath }
    }
}
#endif
