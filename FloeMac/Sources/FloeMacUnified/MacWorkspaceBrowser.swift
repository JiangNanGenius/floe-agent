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

    /// Mirrors the iPad task-browser bound; older unused task sessions are
    /// stopped and evicted past this count.
    static let taskSessionLimit = 6

    private var generalSession: MacBrowserSession?
    private var taskSessions: [UUID: MacBrowserSession] = [:]
    private var taskRecency: [UUID] = []
    private let restoreStore: MacBrowserRestoreStore
    private let survivingOwnerIDs: () -> Set<UUID>
    private var downloadObservation: AnyCancellable?

    /// User-invoked downloads for the workbench browser surface.
    let downloads: MacBrowserDownloadController

    @Published private(set) var presentRequest: Request?
    @Published private(set) var returnRequest: UUID?
    #if FLOE_MAC_HOST_SMOKE
    /// Observable mirror of the workbench destination for UnifiedMacSmoke.
    @Published var isPresented = false
    #endif

    init(storeDirectory: URL? = nil, survivingOwnerIDs: @escaping () -> Set<UUID> = { Set() },
         admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        self.survivingOwnerIDs = survivingOwnerIDs
        self.restoreStore = MacBrowserRestoreStore(directory: storeDirectory)
        self.downloads = MacBrowserDownloadController(admitWork: admitWork)
        downloadObservation = downloads.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Session for an owner conversation; nil is the shared general session
    /// used outside a saved task. Materializes lazily and recency-orders the
    /// task sessions without ever reusing one task's session for another.
    /// Materialization is always user-initiated (opening the browser), so a
    /// new task session restores the persisted page URL here — never during
    /// startup on its own.
    func session(for owner: UUID?, restorePage: Bool = true) -> MacBrowserSession {
        guard let owner else {
            if let generalSession { return generalSession }
            let session = MacBrowserSession()
            generalSession = session
            return session
        }
        if let existing = taskSessions[owner] {
            touch(owner)
            return existing
        }
        while taskRecency.count >= Self.taskSessionLimit, let evicted = taskRecency.first {
            taskRecency.removeFirst()
            let session = taskSessions.removeValue(forKey: evicted)
            downloads.discard(owner: evicted)
            session?.stop()
        }
        let session = MacBrowserSession()
        taskSessions[owner] = session
        touch(owner)
        attachPageCommitHook(session, owner: owner)
        if restorePage, let restored = restoreStore.record(for: owner) {
            session.open(restored)
        }
        return session
    }

    /// The task-bound session for smoke and diagnostics; nil only for owners
    /// that never presented.
    func existingTaskSession(for owner: UUID) -> MacBrowserSession? { taskSessions[owner] }

    func discard(owner: UUID) {
        taskRecency.removeAll { $0 == owner }
        taskSessions.removeValue(forKey: owner)?.stop()
        restoreStore.remove(owner: owner)
        downloads.discard(owner: owner)
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
    /// owner: isolated session, user-invoked download affordance and that
    /// owner's live transfer state/result only. `MacWorkspaceRootView` only
    /// swaps in this factory for its previous bare initializer call.
    func makeWorkbenchView(
        owner: UUID?,
        onReturn: (() -> Void)? = nil,
        onOpenExternal: ((URL) -> Void)? = nil
    ) -> MacBrowserWorkbenchView {
        let session = session(for: owner)
        return MacBrowserWorkbenchView(
            session: session,
            onReturn: onReturn,
            onOpenExternal: onOpenExternal,
            download: downloads.snapshot(for: owner),
            savedDownload: downloads.saved(for: owner),
            downloadError: downloads.error(for: owner),
            onDownload: { [weak self, weak session] in
                guard let session else { return }
                self?.downloads.startDownload(for: session, owner: owner, in: NSApp.keyWindow)
            },
            onCancelDownload: { [weak self] in self?.downloads.cancel($0) },
            onRevealDownload: { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        )
    }

    func reset() {
        downloads.cancelAll()
        flushPageHistory()
        generalSession?.stop()
        generalSession = nil
        for session in taskSessions.values { session.stop() }
        taskSessions.removeAll()
        taskRecency.removeAll()
        presentRequest = nil
        returnRequest = nil
        #if FLOE_MAC_HOST_SMOKE
        isPresented = false
        #endif
    }

    func flushPageHistory() {
        restoreStore.flush()
    }

    /// Persists the safe URL-only record whenever this task's browser commits
    /// a page, so a later return (even after an app restart) can restore it.
    private func attachPageCommitHook(_ session: MacBrowserSession, owner: UUID) {
        session.onPageCommit = { [weak self, weak session] url in
            guard let self, let session, taskSessions[owner] === session, let url else { return }
            restoreStore.setRecord(url, for: owner, survivingOwnerIDs: survivingOwnerIDs)
        }
    }

    private func touch(_ owner: UUID) {
        taskRecency.removeAll { $0 == owner }
        taskRecency.append(owner)
    }
}
