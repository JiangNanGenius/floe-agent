// FloeApp — Native tab model for the unified workspace IDE.
//
// SPDX-License-Identifier: MPL-2.0
//
// The IDE has one native Swift/UIKit text editor behind the `code` tab
// (there is no Web/Monaco text kernel). Text/code files live as native
// buffers of that single code tab; PDF/Office and the remaining routed kinds
// (CAD/image/media/Quick Look) get their own typed outer tabs, so an
// Office/PDF initial path lands directly in its typed surface instead of a
// transient empty code page.
//
// Text routing stays authoritative: an Office/PDF/CAD/image path can never
// become a code tab, so the native editor never sees bytes it would decode
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

/// Pure decision for the IDE surface's Office open loader: when must the
/// owning surface resolve and open the tab's document into its session?
/// Keeping this pure lets focused tests pin the exact contract that prevents
/// both failure modes it guards against: mounting a surface without ever
/// opening the session (the Build 227 endless "正在打开文档…" spinner, where the
/// session stayed `.idle` and no watchdog was ever armed), and re-opening a
/// live or recoverable session (which would tear down its controller and
/// abandon its retained editing copy).
enum IDEOfficeOpenDecision: Equatable {
    /// No controller is mounted: the session was never opened, was cleanly
    /// released, or was re-armed after a pre-mount failure. The loader must
    /// resolve and open now — nothing else moves this surface off the opening
    /// state, and no open watchdog exists until a controller mounts.
    case openNow
    /// A controller already owns this document: loading, ready, or a failed
    /// session whose retained working copy the recovery action owns. The
    /// loader must not re-open — readiness, the open watchdog and recovery
    /// are already owned elsewhere.
    case alreadyOwned

    /// The mounted controller is the only truthful owner signal. It exists
    /// through every settled phase (including `.failed` with a retained
    /// working copy), while `nil` covers "never opened", "released" and
    /// "re-armed after a pre-mount failure" — the three states that need the
    /// loader's open.
    static func decide(controllerMounted: Bool) -> IDEOfficeOpenDecision {
        controllerMounted ? .alreadyOwned : .openNow
    }
}

/// Pure decision for closing an Office tab (typed outer tab): a clean
/// read-only preview closes immediately; anything holding user changes hands
/// the save/discard/cancel decision to the user. Keeping this pure lets
/// focused tests pin the close policy without an engine or a simulator.
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
    /// Stages a cloud/network document into a private read-only snapshot for
    /// this tab's open. Ownership is per tab: `RemoteFilePreviewCopy.store`
    /// deletes its previous staged directory, so one shared store would let a
    /// second remote Office tab delete the first tab's active staged file.
    let remotePreview = RemoteFilePreviewCopy()

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
        // The staged cloud/network snapshot only feeds the open; once the
        // session is released it is dead weight, and keeping per-tab stores
        // alive after close would leak one temp directory per remote tab.
        remotePreview.clear()
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
        case .codeEditor:
            // Text/code opens a native buffer in the single code tab when the
            // IDE view appears; the outer tab is only the container.
            activeTabID = Self.codeTabID
        default:
            // Office, PDF and every other typed document opens its own typed
            // outer tab immediately: there is no Web workbench to forward to,
            // and the first frame must never be a transient empty code page.
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
            // A text file stays inside the code tab's native editor: the pane
            // opens a buffer for it, so this outer tab is only the container.
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
