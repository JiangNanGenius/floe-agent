// SPDX-License-Identifier: MPL-2.0
import Foundation

/// The databases and the library index have independent commits. This intent
/// pins native identities before stopping work; a retry reads the actual file
/// commit proof instead of guessing from a missing path or a conversation title.
struct PersonalFileAssistantLifecycleIntent: Codable, Hashable, Sendable, Identifiable {
    enum Action: String, Codable, Sendable { case trash, restore, purge }
    let id: UUID
    let entryID: UUID
    let action: Action
    let rootPath: String
    let relativePath: String
    let members: [PersonalContentRecord]
    let bindings: [StudioAssistantBinding]
    var projectIDs: Set<UUID> { Set(members.map(\.id)) }
}

enum PersonalFileAssistantLifecycleError: Error, LocalizedError {
    case stopping, pending, changed
    var errorDescription: String? {
        switch self {
        case .stopping: IDELanguageRunText.t("任务仍在停止，文件和对话已保留。请稍后重试。", "Work is still stopping. The file and conversation are kept. Try again shortly.")
        case .pending: IDELanguageRunText.t("文件操作尚在收尾，记录已保留。请稍后重试。", "The file operation is still finishing. Its records are kept. Try again shortly.")
        case .changed: IDELanguageRunText.t("文件助手已改变，请重新打开文件后重试。", "The file assistant changed. Reopen the file and try again.")
        }
    }
}

/// A stop lease holds the conversation's existing launch fence through the
/// file commit and its companion cleanup. A timeout never manufactures a lease.
@MainActor final class PersonalFileAssistantStopLease {
    let id: UUID
    private var release: (@MainActor @Sendable () -> Void)?
    init(id: UUID = UUID(), release: @escaping @MainActor @Sendable () -> Void = {}) {
        self.id = id; self.release = release
    }
    func finish() { let operation = release; release = nil; operation?() }
    deinit { if let release { Task { @MainActor in release() } } }
}

/// Production orchestration, also compiled unchanged by the focused host.
/// File operations continue through the library's existing CAS/trash/purge and
/// Biology coordinators. Only the exact bound assistants are stopped/removed.
@MainActor struct PersonalFileAssistantLifecycle {
    typealias Stop = @MainActor @Sendable ([StudioAssistantBinding]) async throws -> PersonalFileAssistantStopLease
    typealias Retire = @MainActor @Sendable ([StudioAssistantBinding]) async throws -> Void
    typealias Purge = @MainActor @Sendable (UUID, UUID) async throws -> Void
    let access: StudioDocumentAccess
    let library: PersonalContentLibrary
    let stop: Stop
    let retire: Retire
    let purge: Purge
    private static var liveEntries: Set<UUID> = []

    func perform<T: Sendable>(action: PersonalFileAssistantLifecycleIntent.Action,
        entryID: UUID, relativePath: String, members: [PersonalContentRecord],
        operation: @MainActor @Sendable (UUID) async throws -> T) async throws -> T {
        // A Restore/Purge click may be the first retry after a successful
        // trash commit whose companion cleanup failed. Settle that exact
        // predecessor now instead of making the user repeat the same click.
        try await reconcile(entryID: entryID)
        guard Self.liveEntries.insert(entryID).inserted else { throw PersonalFileAssistantLifecycleError.pending }
        defer { Self.liveEntries.remove(entryID) }
        let root = await library.root
        let intent = try await access.beginFileLifecycle(action: action, entryID: entryID,
            rootPath: root.path, relativePath: relativePath, members: members)
        var lease: PersonalFileAssistantStopLease?
        defer { lease?.finish() }
        do {
            if action == .trash { try await library.prepareFileAssistantTrashEvent(projectIDs: intent.projectIDs, eventID: entryID) }
            lease = try await stop(intent.bindings)
            try await access.validateFileLifecycle(intent)
            try Task.checkCancellation()
            let result = try await operation(entryID)
            if action == .trash { await library.releaseFileAssistantTrashEvent(projectIDs: intent.projectIDs, eventID: entryID) }
            // Do not check task cancellation after a real file commit.
            try await access.markFileLifecycleCommitted(intent)
            try await settle(intent, leaseID: lease!.id)
            return result
        } catch {
            if action == .trash { await library.releaseFileAssistantTrashEvent(projectIDs: intent.projectIDs, eventID: entryID) }
            // A post-commit error retains the intent. The next reload/retry
            // completes it using the tombstone or the positive purge receipt.
            if (try? await library.fileAssistantCommitState(intent)) == .notCommitted,
               (try? await library.canAbandonFileAssistantIntent(intent)) == true {
                try? await access.finishFileLifecycle(intent)
            }
            throw error
        }
    }

    /// Never retries the destructive file operation itself. Uncommitted work
    /// is released only when the exact originals are still known; committed
    /// work gets its idempotent companion cleanup. Unknown data stays intact.
    func reconcile(entryID: UUID? = nil) async throws {
        var failed = false
        let root = await library.root
        for intent in try await access.pendingFileLifecycles(entryID: entryID) where !Self.liveEntries.contains(intent.entryID) {
            guard intent.rootPath == root.path else { failed = true; continue }
            guard Self.liveEntries.insert(intent.entryID).inserted else { continue }
            do {
                switch try await library.fileAssistantCommitState(intent) {
                case .committed:
                    let lease = try await stop(intent.bindings)
                    defer { lease.finish() }
                    try await access.markFileLifecycleCommitted(intent)
                    try await settle(intent, leaseID: lease.id)
                case .notCommitted:
                    if try await library.canAbandonFileAssistantIntent(intent) {
                        try await access.finishFileLifecycle(intent)
                    }
                case .unknown: failed = true
                }
            } catch { failed = true }
            Self.liveEntries.remove(intent.entryID)
        }
        if failed { throw PersonalFileAssistantLifecycleError.pending }
    }

    private func settle(_ intent: PersonalFileAssistantLifecycleIntent, leaseID: UUID) async throws {
        try await access.validateFileLifecycle(intent)
        if intent.action == .purge {
            for binding in intent.bindings {
                // A prior successful cleanup may already have acknowledged
                // this binding. A successor is never interpreted as that ack.
                guard let current = try await access.assistant(projectID: binding.projectID) else { continue }
                guard current == binding.conversationID else { throw PersonalFileAssistantLifecycleError.changed }
                try await purge(binding.conversationID, leaseID)
                try await access.finishPurgedAssistant(binding)
            }
            try await access.revokePurgedFileAuthority(projectIDs: intent.projectIDs)
        } else {
            try await retire(intent.bindings)
        }
        // Keep the positive file proof until the access-side journal is gone.
        // A crash after this ack merely leaves a harmless receipt to compact.
        try await access.finishFileLifecycle(intent)
        if intent.action == .purge { try await library.acknowledgeFileAssistantPurge(entryID: intent.entryID) }
    }
}

extension PersonalContentLibrary {
    enum FileAssistantCommitState: Equatable { case notCommitted, committed, unknown }

    func fileAssistantCommitState(_ intent: PersonalFileAssistantLifecycleIntent) throws -> FileAssistantCommitState {
        guard root.path == intent.rootPath else { return .unknown }
        let state = try PersonalLibraryTrashStore.read(root: root)
        let entry = state.entries.first { $0.id == intent.entryID && $0.relativePath == intent.relativePath }
        switch intent.action {
        case .trash:
            if entry != nil { return .committed }
        case .restore:
            if entry != nil { return .notCommitted }
        case .purge:
            if state.assistantPurgeReceipts?.contains(where: {
                $0.entryID == intent.entryID && $0.relativePath == intent.relativePath && Set($0.projectIDs) == intent.projectIDs
            }) == true { return .committed }
            if entry != nil { return .notCommitted }
            return .unknown // Absence is not a physical-removal receipt.
        }
        let current = try records(includingDeleted: true)
        guard intent.members.allSatisfy({ original in
            current.contains { $0.id == original.id && $0.relativePath == original.relativePath && $0.kind == original.kind && $0.deletedAt == nil }
        }) else { return .unknown }
        // Empty folder restoration is proven by its still-owned directory.
        if intent.members.isEmpty {
            _ = try PersonalLibraryTrashStore.folder(root: root,
                components: PersonalLibraryTrashStore.components(intent.relativePath))
        }
        return intent.action == .restore ? .committed : .notCommitted
    }

    func canAbandonFileAssistantIntent(_ intent: PersonalFileAssistantLifecycleIntent) throws -> Bool {
        if intent.action != .purge { return true }
        return try !permanentDeletionPendingIDs().contains(intent.entryID)
    }

    func acknowledgeFileAssistantPurge(entryID: UUID) throws {
        try PersonalLibraryTrashStore.locked(root: root) {
            var state = try PersonalLibraryTrashStore.read(root: root)
            guard state.assistantPurgeReceipts?.contains(where: { $0.entryID == entryID }) == true else { return }
            state.assistantPurgeReceipts?.removeAll { $0.entryID == entryID }
            try PersonalLibraryTrashStore.write(state, root: root)
        }
    }
}
