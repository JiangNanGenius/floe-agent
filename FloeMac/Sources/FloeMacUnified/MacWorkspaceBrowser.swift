// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import FloeMacToolbox
import Foundation
import SwiftUI

/// One persisted page-restore record. Only a single sanitized http(s) URL is
/// kept: no cookies, no credentials, no form or POST data, no page state.
struct MacBrowserRestoreRecord: Codable, Equatable {
    var owner: UUID
    var url: String
    var updatedAt: TimeInterval
}

/// Persists the last committed page URL per owning task so the workbench
/// browser can put the page back when the user returns after an app restart.
/// Records are URL-only, capped, pruned to surviving tasks and written
/// atomically; a record is only ever loaded when the user reopens that
/// task's browser, never driving navigation by itself.
///
/// Init never prunes: the workspace task list is not prepared yet when the
/// controller is created, and an empty surviving snapshot must not wipe the
/// archive. Stale records are removed lazily by `setRecord`/`remove` and are
/// bounded in any case by the record cap.
@MainActor
final class MacBrowserRestoreStore {
    nonisolated private static let recordLimit = 64
    nonisolated private static let urlByteLimit = 8_192
    nonisolated private static let archiveByteLimit = 1_048_576

    private let directory: URL?
    private var records: [UUID: MacBrowserRestoreRecord] = [:]
    private var dirty = false
    private var readFailed = false
    private var deferredWrite: Task<Void, Never>?

    init(directory: URL?) {
        self.directory = directory
        guard let directory else { return }
        do {
            if try !Self.checkDirectory(directory) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                _ = try Self.checkDirectory(directory)
                return
            }
            let archive = directory.appendingPathComponent("restore.json")
            guard let bytes = try Self.readFile(archive, limit: Self.archiveByteLimit) else { return }
            let decoded = try JSONDecoder().decode([MacBrowserRestoreRecord].self, from: bytes)
            // Dedup by owner (newest wins) and bound the parsed set before it
            // enters memory; a duplicated or oversized archive must never
            // trap or bloat the store.
            var merged: [UUID: MacBrowserRestoreRecord] = [:]
            let now = Date().timeIntervalSince1970
            for record in decoded.prefix(Self.recordLimit * 4) {
                guard record.updatedAt <= now + 60, record.updatedAt >= 0,
                      let url = Self.sanitizedURL(record.url) else { continue }
                let clean = MacBrowserRestoreRecord(owner: record.owner, url: url.absoluteString,
                                                    updatedAt: record.updatedAt)
                if let existing = merged[record.owner], existing.updatedAt >= clean.updatedAt { continue }
                merged[record.owner] = clean
            }
            if merged.count > Self.recordLimit {
                records = Dictionary(uniqueKeysWithValues: merged
                    .sorted { $0.value.updatedAt > $1.value.updatedAt }
                    .prefix(Self.recordLimit).map { ($0.key, $0.value) })
            } else {
                records = merged
            }
        } catch {
            // An unreadable archive stays in place for recovery; restore is
            // best-effort and never blocks browsing.
            readFailed = true
        }
    }

    func record(for owner: UUID) -> URL? {
        guard let raw = records[owner]?.url else { return nil }
        return Self.sanitizedURL(raw)
    }

    /// Stores the sanitized URL for a task that is alive right now. The
    /// owner is inserted into the keep set before pruning so it can never
    /// drop its own record; an empty surviving snapshot means the workspace
    /// is not prepared or already gone, in which case pruning is skipped
    /// entirely rather than trusting an incomplete list.
    func setRecord(_ url: URL, for owner: UUID, survivingOwnerIDs: () -> Set<UUID>) {
        guard let cleaned = Self.sanitizedURL(url.absoluteString) else { return }
        var keep = survivingOwnerIDs()
        if keep.isEmpty {
            keep = Set(records.keys)
        }
        keep.insert(owner)
        records[owner] = MacBrowserRestoreRecord(owner: owner, url: cleaned.absoluteString,
                                                 updatedAt: Date().timeIntervalSince1970)
        prune(keeping: keep)
        if records.count > Self.recordLimit,
           let oldest = records.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            records.removeValue(forKey: oldest)
        }
        scheduleWrite()
    }

    func remove(owner: UUID) {
        guard records.removeValue(forKey: owner) != nil else { return }
        scheduleWrite()
    }

    /// Drops records whose task no longer exists. Only called with a
    /// trustworthy surviving snapshot.
    func prune(keeping surviving: Set<UUID>) {
        let stale = records.keys.filter { !surviving.contains($0) }
        guard !stale.isEmpty else { return }
        for owner in stale { records.removeValue(forKey: owner) }
        scheduleWrite()
    }

    func flush() {
        deferredWrite?.cancel()
        deferredWrite = nil
        guard dirty, !readFailed, let directory else { return }
        let snapshot = Array(records.values)
        dirty = false
        if !Self.write(snapshot, to: directory) {
            dirty = true
            readFailed = true
        }
    }

    private func scheduleWrite() {
        guard directory != nil, !readFailed else { return }
        dirty = true
        deferredWrite?.cancel()
        deferredWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    /// URL-only record rules: the shared navigation guard (plain http(s),
    /// host, no embedded credentials) plus an absolute cap. The entire query
    /// and fragment are stripped — OAuth `code` values and cookie-like data
    /// have no reliable parameter names, so no query parameter is kept.
    nonisolated static func sanitizedURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= urlByteLimit,
              let url = URL(string: raw), MacBrowserAddress.allows(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        guard let cleaned = components.url, MacBrowserAddress.allows(cleaned) else { return nil }
        return cleaned
    }

    nonisolated private static func pruneForLimit(_ snapshot: [MacBrowserRestoreRecord]) -> [MacBrowserRestoreRecord] {
        guard snapshot.count > recordLimit else { return snapshot }
        return snapshot.sorted { $0.updatedAt > $1.updatedAt }.prefix(recordLimit).map { $0 }
    }

    nonisolated private static func write(_ snapshot: [MacBrowserRestoreRecord], to directory: URL) -> Bool {
        do {
            let archive = directory.appendingPathComponent("restore.json")
            let bytes = try JSONEncoder().encode(pruneForLimit(snapshot))
            guard bytes.count <= archiveByteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: archive, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
            return true
        } catch {
            return false
        }
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    nonisolated private static func checkDirectory(_ directory: URL) throws -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadNoPermission)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        return true
    }
}

/// Owns the workbench browser surface of the Agent window. Browser state is
/// bound to the task it was opened from, mirroring the iPad model: every
/// owner conversation gets its own isolated session (its own non-persistent
/// store, so pages and cookies never leak across tasks), returning to the
/// same task preserves that task's page, and opening the browser from a
/// different task can never show a prior task's content. The task draft is
/// owned by the existing draft store and is untouched by browsing.
///
/// The last committed page URL per task is persisted (URL-only) so an app
/// restart can put the page back when the user reopens that task's browser;
/// nothing navigates on startup by itself. Downloads are user-invoked from
/// the browser chrome and land only where the user saves them; download
/// state is scoped to the task that started it and is cancelled when that
/// task goes away.
///
/// Requests are nonce-tagged so a menu drive or a repeated link open is
/// observed even when the URL repeats.
@MainActor
final class MacBrowserWorkbenchController: ObservableObject {
    enum Presentation: Equatable {
        case empty, url(URL)
    }

    struct Request: Equatable {
        let presentation: Presentation
        let nonce: UUID
    }

    /// Raise-the-workbench routing for one task owner (model takeover or the
    /// first user input). Equatable so the root view can `.onChange` on it;
    /// the nonce makes a repeated request for the same owner observable.
    struct TaskPresentRequest: Equatable {
        let owner: UUID
        let nonce: UUID
    }

    private var generalSession: MacBrowserSession?
    private let restoreStore: MacBrowserRestoreStore
    private var downloadObservation: AnyCancellable?
    private var taskToolsObservation: AnyCancellable?

    /// User-invoked downloads for the workbench browser surface.
    let downloads: MacBrowserDownloadController

    /// Task/session-bound model browser lane: owns every task-owned session,
    /// the compiled `browser.*` tools and their per-run bundle. The workbench
    /// surface renders the active tab of the exact session the tools drive.
    let taskTools: MacTaskBrowserTools

    @Published private(set) var presentRequest: Request?
    @Published private(set) var returnRequest: UUID?
    /// Raised when a model run hands this task's browser to the user (or the
    /// user takes over): the root view routes the workbench to this owner and
    /// the session enters user control. Never carries page data.
    @Published private(set) var taskPresentRequest: TaskPresentRequest?
    #if FLOE_MAC_HOST_SMOKE
    /// Observable mirror of the workbench destination for UnifiedMacSmoke.
    @Published var isPresented = false
    #endif

    init(storeDirectory: URL? = nil, survivingOwnerIDs: @escaping () -> Set<UUID> = { Set() },
         admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        let restoreStore = MacBrowserRestoreStore(directory: storeDirectory)
        self.restoreStore = restoreStore
        self.downloads = MacBrowserDownloadController(admitWork: admitWork)
        self.taskTools = MacTaskBrowserTools(
            restore: .init(
                record: { owner in restoreStore.record(for: owner) },
                setRecord: { url, owner in
                    restoreStore.setRecord(url, for: owner, survivingOwnerIDs: survivingOwnerIDs)
                },
                remove: { owner in restoreStore.remove(owner: owner) }
            )
        )
        self.taskTools.downloads = downloads
        // Wire the presentation hook only after every stored property is
        // initialized; a weak self capture is not allowed in an escaping
        // closure passed to the member initializer above.
        self.taskTools.presentBrowser = { [weak self] owner in self?.presentTaskBrowser(owner: owner) }
        downloadObservation = downloads.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
        taskToolsObservation = taskTools.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Raises the workbench browser for this owner (model takeover or first
    /// user input); the root view consumes `taskPresentRequest`.
    func presentTaskBrowser(owner: UUID) {
        taskPresentRequest = TaskPresentRequest(owner: owner, nonce: UUID())
    }

    /// The task-owned session for this owner; materializes for a user-opened
    /// browser and restores the last committed page (URL-only record).
    @discardableResult
    func taskSession(for owner: UUID?) -> MacTaskBrowserSession? {
        guard let owner else { return nil }
        return taskTools.ensureSession(for: owner)
    }

    /// Opens a chat-supplied http(s) link in this task's own browser session
    /// (the same session model tools drive). Opening a link is a user action:
    /// it takes control from a model run first, exactly like typing in the
    /// address bar.
    func openTaskURL(_ url: URL, owner: UUID?) {
        guard let owner, MacBrowserAddress.allows(url) else { return }
        let session = taskTools.ensureSession(for: owner)
        session.userNavigate(to: url.absoluteString)
    }

    func generalBrowser() -> MacBrowserSession {
        if let generalSession { return generalSession }
        let session = MacBrowserSession()
        generalSession = session
        return session
    }

    func discard(owner: UUID) {
        taskTools.retireSession(for: owner)
    }

    /// Show the browser workbench without changing the page.
    func present() {
        presentRequest = Request(presentation: .empty, nonce: UUID())
    }

    /// Show the browser workbench and navigate to a chat-supplied link; the
    /// scheme guard stays authoritative for the final navigation.
    func present(url: URL) {
        presentRequest = Request(presentation: .url(url), nonce: UUID())
    }

    /// Ask the workbench to return to the destination it was opened from.
    func returnToTask() {
        returnRequest = UUID()
    }

    /// Builds the fully wired workbench browser surface for the current
    /// owner. A task owner renders the task-owned session (`MacTaskBrowserTools`)
    /// — the exact WKWebView/tab session the compiled browser tools drive, with
    /// tab strip, control-status banner and the per-owner download state; the
    /// general (non-task) browser keeps the existing toolbox session surface.
    /// `MacWorkspaceRootView` only swaps in this factory for its previous
    /// bare initializer call.
    func makeWorkbenchView(
        owner: UUID?,
        onReturn: (() -> Void)? = nil,
        onOpenExternal: ((URL) -> Void)? = nil,
        expanded: Bool = false,
        onToggleExpansion: (() -> Void)? = nil
    ) -> MacBrowserWorkbenchView {
        if let owner {
            let task = taskTools.ensureSession(for: owner)
            return makeTaskWorkbenchView(
                task, owner: owner, onReturn: onReturn, onOpenExternal: onOpenExternal,
                expanded: expanded, onToggleExpansion: onToggleExpansion
            )
        }
        let session = generalBrowser()
        return MacBrowserWorkbenchView(
            session: session,
            onReturn: onReturn,
            onOpenExternal: onOpenExternal,
            download: downloads.snapshot(for: owner),
            savedDownload: downloads.saved(for: owner),
            downloadError: downloads.error(for: owner),
            onDownload: { [weak self, weak session] in
                guard let session else { return }
                self?.downloads.startDownload(page: session.page, owner: owner, in: NSApp.keyWindow)
            },
            onCancelDownload: { [weak self] in self?.downloads.cancel($0) },
            onRevealDownload: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        )
    }

    /// Task-owner surface: chrome snapshot + actions around the session's
    /// active tab. User chrome actions pass through the session's user-input
    /// gate, which hands control from a model run before the page changes.
    private func makeTaskWorkbenchView(
        _ task: MacTaskBrowserSession,
        owner: UUID,
        onReturn: (() -> Void)?,
        onOpenExternal: ((URL) -> Void)?,
        expanded: Bool,
        onToggleExpansion: (() -> Void)?
    ) -> MacBrowserWorkbenchView {
        let state = ownerDownloadState(owner: owner, session: task)
        let actions = MacTaskBrowserActions(
            onSubmitAddress: { [weak task] in task?.userNavigate(to: $0) },
            onGoBack: { [weak task] in task?.userGoBack() },
            onGoForward: { [weak task] in task?.userGoForward() },
            onReloadOrStop: { [weak task] in task?.userReloadOrStop() },
            onReturnControl: { [weak task] in
                task?.endUserControl()
                onReturn?()
            },
            expanded: expanded,
            onToggleExpansion: onToggleExpansion
        )
        let tabStrip = FloeBrowserTabStrip(tabs: task.tabs.map { tab in
            let title = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(id: tab.id, title: title.isEmpty ? (tab.webView.url?.host ?? "") : title,
                         active: tab.id == task.activeTabID)
        }, onOpen: { [weak task] in task?.userCreateTab() },
           onSelect: { [weak task] in task?.userActivateTab($0) },
           onClose: { [weak task] in task?.userCloseTab($0) })
        return MacBrowserWorkbenchView(
            session: generalBrowser(),
            onReturn: onReturn,
            onOpenExternal: onOpenExternal,
            download: state.active,
            savedDownload: state.saved,
            downloadError: state.error,
            onDownload: { [weak self, weak task] in
                guard let task, let page = task.activeWebView else { return }
                // A user-initiated page download is a human gesture: it takes
                // control from a model run exactly like the address bar.
                task.registerUserInput(reason: "You started using this browser")
                self?.downloads.startDownload(page: page, owner: owner, in: NSApp.keyWindow)
            },
            onCancelDownload: { [weak self, weak task] id in
                if self?.downloads.snapshot(for: owner)?.id == id {
                    self?.downloads.cancel(id)
                } else {
                    task?.downloads.cancel(id)
                }
            },
            onRevealDownload: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            taskChrome: taskChrome(for: task),
            taskPage: task.activeWebView,
            taskActions: actions,
            taskTabStrip: AnyView(tabStrip)
        )
    }

    /// Merges the user Save-panel transfer state with the task-owned model
    /// download state for this owner; an active transfer wins over results.
    private func ownerDownloadState(
        owner: UUID?, session: MacTaskBrowserSession?
    ) -> (active: MacBrowserDownloadSnapshot?, saved: MacBrowserSavedDownload?, error: String?) {
        if let active = downloads.snapshot(for: owner) {
            return (active, downloads.saved(for: owner), downloads.error(for: owner))
        }
        if let session {
            if let progress = session.downloadProgress {
                return (progress, nil, nil)
            }
            switch session.downloadOutcome {
            case .saved(let saved):
                return (nil, saved, nil)
            case .error(let message):
                return (nil, nil, message)
            case nil:
                break
            }
        }
        return (nil, downloads.saved(for: owner), downloads.error(for: owner))
    }

    private func taskChrome(for session: MacTaskBrowserSession) -> MacTaskBrowserChrome {
        let status: MacBrowserControlStatus
        if session.isUserControlling {
            let message: String
            if case .needsUser(let reason) = session.surfaceState {
                message = reason
            } else {
                message = "User takeover is active"
            }
            status = .userControlling(message: message)
        } else if session.hasModelControlHolder {
            status = .modelActive
        } else {
            status = .idle
        }
        return MacTaskBrowserChrome(
            address: session.address,
            canGoBack: session.canGoBack,
            canGoForward: session.canGoForward,
            isLoading: session.isLoading,
            currentURL: session.activeWebView?.url,
            tabs: session.tabs.map {
                MacBrowserTabInfo(
                    id: $0.id,
                    title: $0.webView.title ?? "",
                    isActive: $0.id == session.activeTabID,
                    isLoading: $0.webView.isLoading
                )
            },
            controlStatus: status,
            modelActivityDetail: modelActivityLabel(session.lastModelActivity)
        )
    }

    /// Publicly safe label of the last model action for the status strip:
    /// a verb plus the target's visible label; never page text, typed
    /// content, credentials or coordinates.
    private func modelActivityLabel(_ activity: MacBrowserModelActivity?) -> String? {
        guard let activity else { return nil }
        let verb: String
        switch activity.kind {
        case .observing: verb = "Observing the page"
        case .navigating: verb = "Navigating"
        case .clicking: verb = "Clicking"
        case .typing: verb = "Typing"
        case .scrolling: verb = "Scrolling"
        case .waiting: verb = "Waiting for the page"
        case .downloading: verb = "Downloading"
        }
        return activity.detail.map { "\(verb) '\($0)'" } ?? verb
    }

    func reset() {
        downloads.cancelAll()
        taskTools.retireAllSessions()
        flushPageHistory()
        generalSession?.stop()
        generalSession = nil
        presentRequest = nil
        returnRequest = nil
        taskPresentRequest = nil
        #if FLOE_MAC_HOST_SMOKE
        isPresented = false
        #endif
    }

    func flushPageHistory() {
        restoreStore.flush()
    }

}
