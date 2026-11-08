// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeBiologyCore
import FloeBiologyEngine

/// The Library owns usage/folder barriers; the canonical Biology store owns
/// native revisions and workers. All two-sided changes below execute within
/// that existing barrier. Originals/assets stay in their canonical location.
@MainActor final class BiologyLibraryCoordinator {
    private weak var environment: AppEnvironment?
    private weak var host: BiologyHostServices?
    init(environment: AppEnvironment) { self.environment = environment }
    func bind(host: BiologyHostServices) throws {
        guard self.host == nil || self.host === host else { throw BiologyHostError.changed }
        self.host = host
    }
    var hooks: BiologyLibraryHooks {
        .init(attachCreated: { [weak self] id, context in
            guard let self else { throw BiologyHostError.unavailable }
            try await self.attachCreated(id, context: context)
        }, lifecycle: { [weak self] mutation, context, operation in
            guard let self else { throw BiologyHostError.unavailable }
            return try await self.lifecycle(mutation, context: context, operation: operation)
        })
    }
    private func services() throws -> (AppEnvironment, BiologyHostServices) {
        guard let environment, let host else { throw BiologyHostError.unavailable }
        return (environment, host)
    }
    /// Trusted same-service seam for the permanent-deletion coordinator.
    func permanentDeletionHost() throws -> BiologyHostServices { try services().1 }
    private struct Journal: Codable {
        enum Action: String, Codable { case attach, delete, restore, rename }
        enum Phase: String, Codable { case prepared, nativeCommitted, committed, rolledBack, needsRecovery }
        var schemaVersion = 1
        let projectID: UUID
        let action: Action
        var phase: Phase
        let relativePath: String?
        var nativeTrashID: String?
        var libraryTrashID: UUID?
        var originalTitle: String?
        var intendedTitle: String?
        var updatedAt = Date()
    }
    private func save(_ journal: Journal, host: BiologyHostServices) throws {
        let root = host.root.appendingPathComponent("LibraryRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL else { throw BiologyHostError.changed }
        var current = journal; current.updatedAt = Date()
        let bytes = try JSONEncoder().encode(current)
        guard bytes.count <= 16_384 else { throw BiologyHostError.changed }
        try bytes.write(to: root.appendingPathComponent(journal.projectID.uuidString.lowercased() + ".json"), options: .atomic)
    }
    private func notify(_ id: UUID) {
        NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id)
    }
    private func verify(_ record: PersonalContentRecord, directory: URL) throws {
        guard record.kind == .biology, !record.needsRecovery else { throw BiologyHostError.changed }
        try BiologyOriginalBinding.verify(id: record.id, directory: directory)
    }

    /// Native tools create first using their existing deterministic operation
    /// identity. The matching Personal wrapper is attached without allocating
    /// or translating another ID. A retry can complete ownership publication.
    private func attachCreated(_ id: UUID, context: ToolContext) async throws {
        let (app, host) = try services()
        let taskID = try await host.access.task(context, requireCall: true)
        guard let callID = context.toolCallID, context.approvalGrantID != nil,
              let project = try? await host.store.load(id),
              project.createdByOperation?.owner == .init(taskID: taskID, hostRunID: context.runID),
              project.createdByOperation?.requestID == callID else { throw BiologyHostError.changed }
        let library = try await PersonalContentService.shared.library()
        var journal = Journal(projectID: id, action: .attach, phase: .prepared, relativePath: nil)
        try save(journal, host: host)
        do {
            let record = try await library.create(kind: .biology, title: project.title, id: id) { directory, originalID in
                try BiologyOriginalBinding(projectID: originalID).write(to: directory)
            }
            let mounted = try await library.resolve(id)
            guard mounted.record.id == id, mounted.record.kind == .biology,
                  record.relativePath == mounted.record.relativePath else { throw BiologyHostError.changed }
            try verify(mounted.record, directory: mounted.url)
            _ = try await host.access.task(context, requireCall: true)
            try await app.studioCoordinator.access.get().finishCreation(conversationID: taskID, projectID: id)
            journal.phase = .committed; try save(journal, host: host)
            notify(id)
        } catch {
            // No unlink/ID reuse. Imported data or a recoverable wrapper is
            // retained; only an untouched, unpublished allocation can be
            // compensated by the store's recoverable soft deletion.
            _ = try? await host.compensateFailedCreation(id: id, identity: project.createdByOperation)
            journal.phase = .needsRecovery; try? save(journal, host: host)
            throw error
        }
    }
    private func lifecycle(_ mutation: BiologyLibraryMutation, context: ToolContext,
                           operation: @escaping @Sendable () async throws -> ToolExecutionOutput) async throws -> ToolExecutionOutput {
        let (_, host) = try services()
        let id: UUID, restoring: Bool
        switch mutation {
        case .delete(let projectID): id = projectID; restoring = false
        case .restore(let projectID): id = projectID; restoring = true
        }
        let taskID = try await host.access.task(context, requireCall: true)
        guard try await host.access.authority.canAccess(conversationID: taskID, projectID: id, editing: true) else { throw BiologyHostError.readOnly }
        return try await PersonalLibraryFileActions.withBiologyLifecycle(projectID: id, includingDeleted: restoring) { [self] record, directory, library in
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            try verify(record, directory: directory)
            if restoring {
                return try await restoreToolUnderHeldBarrier(record: record, library: library, operation: operation)
            }
            let project = try await host.store.load(id)
            // Do not mutate the source revision behind an approved tool's CAS.
            // A model must stop a worker and reread before issuing deletion.
            guard !project.runs.contains(where: \.isActive) else { throw BiologyHostError.workerNotStopped }
            var journal = Journal(projectID: id, action: .delete, phase: .prepared, relativePath: record.relativePath)
            try save(journal, host: host)
            let output: ToolExecutionOutput
            do {
                output = try await operation()
                guard let deleted = try await host.store.deletedProjects().first(where: { $0.projectID == id }) else { throw BiologyHostError.changed }
                journal.nativeTrashID = deleted.id; journal.phase = .nativeCommitted
                try save(journal, host: host)
            } catch {
                try await rollbackDeletion(&journal, library: library, host: host)
                throw error
            }
            do {
                let entry = try await library.softDelete(record)
                journal.libraryTrashID = entry.id; journal.phase = .committed
                try save(journal, host: host)
                notify(id); return output
            } catch {
                // Check actual committed state before compensation: an atomic
                // metadata write may have succeeded before a later I/O error.
                if let entry = try? await library.recentlyDeleted().first(where: { $0.projectID == id && $0.kind == .work }),
                   try await host.store.deletedProjects().contains(where: { $0.projectID == id }) {
                    journal.libraryTrashID = entry.id; journal.phase = .committed
                    try? save(journal, host: host); notify(id); return output
                }
                try await rollbackDeletion(&journal, library: library, host: host)
                throw error
            }
        }
    }
    private func rollbackDeletion(_ journal: inout Journal, library: PersonalContentLibrary, host: BiologyHostServices) async throws {
        do {
            // Never restore an intentionally deleted wrapper as a side effect
            // of compensating a separate failed native transaction.
            if (try await library.records(includingDeleted: true).first(where: { $0.id == journal.projectID }))?.deletedAt == nil,
               let deleted = try await host.store.deletedProjects().first(where: { $0.projectID == journal.projectID }) {
                try await host.restoreNative(id: journal.projectID, trashID: deleted.id)
            }
            journal.phase = .rolledBack; try save(journal, host: host)
        } catch {
            journal.phase = .needsRecovery; try? save(journal, host: host)
            throw error
        }
    }
    private func restoreToolUnderHeldBarrier(record: PersonalContentRecord, library: PersonalContentLibrary,
                                             operation: @escaping @Sendable () async throws -> ToolExecutionOutput) async throws -> ToolExecutionOutput {
        let (_, host) = try services()
        // A project tool may restore its own work tombstone, never an entire
        // containing folder that could hide unrelated unauthorized originals.
        let entries = try await library.recentlyDeleted().filter { $0.kind == .work && $0.projectID == record.id }
        guard record.deletedAt != nil, entries.count == 1, let entry = entries.first,
              entry.relativePath == record.relativePath else { throw PersonalContentError.restoreParentFirst }
        var journal = Journal(projectID: record.id, action: .restore, phase: .prepared,
            relativePath: record.relativePath, libraryTrashID: entry.id)
        try save(journal, host: host)
        let output: ToolExecutionOutput
        do {
            output = try await operation()
            let project = try await host.store.load(record.id)
            guard project.id == record.id, project.deletedAt == nil else { throw BiologyHostError.changed }
            journal.phase = .nativeCommitted; try save(journal, host: host)
            try await library.restore(entry.id)
            _ = try await library.resolve(record.id)
        } catch {
            if (try? await library.resolve(record.id)) != nil,
               (try? await host.store.load(record.id)) != nil {
                journal.phase = .committed; try? save(journal, host: host); notify(record.id)
                // The operation may have thrown before returning output. Do
                // not invent a tool result; callers can read the real state.
                throw error
            }
            do {
                if let active = try? await host.store.load(record.id), active.deletedAt == nil {
                    guard !active.runs.contains(where: \.isActive) else { throw BiologyHostError.workerNotStopped }
                    try await host.trashPrepared(id: record.id, expectedRevision: active.revision)
                }
                journal.phase = .rolledBack; try save(journal, host: host)
            } catch {
                journal.phase = .needsRecovery; try? save(journal, host: host)
                throw error
            }
            throw error
        }
        journal.phase = .committed; try save(journal, host: host)
        notify(record.id); return output
    }

    /// Native File-menu deletion. The caller already holds the Library's
    /// active/usage/folder barrier and passes its frozen selected original.
    @discardableResult func deleteUnderHeldBarrier(record: PersonalContentRecord, directory: URL,
                                                   library: PersonalContentLibrary) async throws -> PersonalLibraryTrashEntry {
        let (_, host) = try services()
        try verify(record, directory: directory)
        var journal = Journal(projectID: record.id, action: .delete, phase: .prepared, relativePath: record.relativePath)
        try save(journal, host: host)
        do {
            let revision = try await host.prepareForLibraryDeletion(id: record.id)
            try Task.checkCancellation()
            try await host.trashPrepared(id: record.id, expectedRevision: revision)
            guard let deleted = try await host.store.deletedProjects().first(where: { $0.projectID == record.id }) else { throw BiologyHostError.changed }
            journal.nativeTrashID = deleted.id; journal.phase = .nativeCommitted; try save(journal, host: host)
            let entry = try await library.softDelete(record)
            journal.libraryTrashID = entry.id; journal.phase = .committed; try save(journal, host: host)
            notify(record.id); return entry
        } catch {
            if let entry = try? await library.recentlyDeleted().first(where: { $0.projectID == record.id && $0.kind == .work }),
               try await host.store.deletedProjects().contains(where: { $0.projectID == record.id }) {
                journal.libraryTrashID = entry.id; journal.phase = .committed
                try? save(journal, host: host); notify(record.id); return entry
            }
            try await rollbackDeletion(&journal, library: library, host: host)
            throw error
        }
    }
    func restoreUnderHeldBarrier(record: PersonalContentRecord, directory: URL,
                                library: PersonalContentLibrary, entry: PersonalLibraryTrashEntry) async throws {
        let (_, host) = try services()
        try verify(record, directory: directory)
        guard entry.kind == .work, entry.projectID == record.id, entry.relativePath == record.relativePath,
              try await library.recentlyDeleted().contains(entry) else { throw BiologyHostError.changed }
        _ = try await restoreToolUnderHeldBarrier(record: record, library: library) {
            guard let deleted = try await host.store.deletedProjects().first(where: { $0.projectID == record.id }) else { throw BiologyHostError.changed }
            try await host.restoreNative(id: record.id, trashID: deleted.id)
            return ToolExecutionOutput(digesting: "Restored", exitStatus: 0)
        }
    }

    struct Selection: Sendable {
        let record: PersonalContentRecord
        let directory: URL
    }
    /// File-menu Rename is one explicit native edit, coordinated with its
    /// existing selected-original barrier. A wrapper-only alias would be
    /// overwritten by the next canonical title projection.
    func renameUnderHeldBarrier(record: PersonalContentRecord, directory: URL,
                                library: PersonalContentLibrary, title: String) async throws {
        let (_, host) = try services()
        try verify(record, directory: directory)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 4_096 else { throw PersonalContentError.invalidName }
        let original = try await host.store.load(record.id)
        var journal = Journal(projectID: record.id, action: .rename, phase: .prepared,
            relativePath: record.relativePath, originalTitle: original.title, intendedTitle: title)
        try save(journal, host: host)
        var committedRevision: UInt64?
        do {
            try Task.checkCancellation()
            let saved = try await host.store.update(record.id, expectedRevision: original.revision) { $0.title = title }
            committedRevision = saved.revision
            journal.phase = .nativeCommitted; try save(journal, host: host)
            try await library.markChanged(record.id, title: title)
            let mounted = try await library.resolve(record.id)
            guard mounted.record.title == title, try await host.store.load(record.id).title == title else { throw BiologyHostError.changed }
            journal.phase = .committed; try save(journal, host: host); notify(record.id)
        } catch {
            let originalError = error
            if (try? await library.resolve(record.id).record.title) == title,
               (try? await host.store.load(record.id).title) == title {
                journal.phase = .committed; try? save(journal, host: host); notify(record.id); return
            }
            do {
                if let committedRevision {
                    let current = try await host.store.load(record.id)
                    guard current.revision == committedRevision, current.title == title else { throw BiologyHostError.changed }
                    _ = try await host.store.update(record.id, expectedRevision: committedRevision) { $0.title = original.title }
                }
                journal.phase = .rolledBack; try save(journal, host: host)
            } catch {
                journal.phase = .needsRecovery; try? save(journal, host: host); throw error
            }
            throw originalError
        }
    }
    /// Folder menus retain ONE original atomic Library tombstone/restore.
    /// Root calls this only inside its already-held subtree usage barrier,
    /// around that existing Library operation. It never creates child work
    /// tombstones or recursively enters a second usage barrier.
    func withNativeLifecycleUnderHeldBarrier<Value: Sendable>(selections: [Selection],
        restoring: Bool, library: PersonalContentLibrary,
        operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        let (_, host) = try services()
        guard Set(selections.map { $0.record.id }).count == selections.count else { throw BiologyHostError.changed }
        var journals: [UUID: Journal] = [:]
        var wasNativeDeleted = Set<UUID>()
        do {
            for selection in selections {
                try Task.checkCancellation()
                try verify(selection.record, directory: selection.directory)
                let id = selection.record.id
                var journal = Journal(projectID: id, action: restoring ? .restore : .delete,
                    phase: .prepared, relativePath: selection.record.relativePath)
                try save(journal, host: host); journals[id] = journal
                if restoring {
                    if let deleted = try await host.store.deletedProjects().first(where: { $0.projectID == id }) {
                        wasNativeDeleted.insert(id)
                        journal.nativeTrashID = deleted.id
                        try await host.restoreNative(id: id, trashID: deleted.id)
                    } else {
                        _ = try await host.store.load(id) // No missing-original fallback.
                    }
                } else {
                    let revision = try await host.prepareForLibraryDeletion(id: id)
                    try Task.checkCancellation()
                    try await host.trashPrepared(id: id, expectedRevision: revision)
                    guard let deleted = try await host.store.deletedProjects().first(where: { $0.projectID == id }) else { throw BiologyHostError.changed }
                    journal.nativeTrashID = deleted.id
                }
                journal.phase = .nativeCommitted; journals[id] = journal; try save(journal, host: host)
            }
            let value = try await operation()
            let records = try await library.records(includingDeleted: true)
            for selection in selections {
                let id = selection.record.id
                guard let current = records.first(where: { $0.id == id }), current.kind == .biology,
                      current.relativePath == selection.record.relativePath else { throw BiologyHostError.changed }
                if current.deletedAt != nil {
                    // Restoring a folder does not undo a separate child
                    // tombstone. Keep that child's canonical original deleted.
                    if let active = try? await host.store.load(id) {
                        guard !active.runs.contains(where: \.isActive) else { throw BiologyHostError.workerNotStopped }
                        try await host.trashPrepared(id: id, expectedRevision: active.revision)
                    }
                    guard try await host.store.deletedProjects().contains(where: { $0.projectID == id }) else { throw BiologyHostError.changed }
                } else {
                    guard restoring, (try? await host.store.load(id)) != nil else { throw BiologyHostError.changed }
                }
                if var journal = journals[id] { journal.phase = .committed; try save(journal, host: host) }
                notify(id)
            }
            return value
        } catch {
            let original = error
            // Read the real wrapper state, including a parent tombstone, before
            // reversing any native commit. No metadata guess may delete data.
            do {
                let records = try await library.records(includingDeleted: true)
                for selection in selections.reversed() {
                    let id = selection.record.id
                    guard var journal = journals[id] else { continue }
                    guard let current = records.first(where: { $0.id == id }), current.kind == .biology,
                          current.relativePath == selection.record.relativePath else { throw BiologyHostError.changed }
                    if current.deletedAt == nil {
                        if let deleted = try await host.store.deletedProjects().first(where: { $0.projectID == id }) {
                            try await host.restoreNative(id: id, trashID: deleted.id)
                        }
                    } else if restoring && wasNativeDeleted.contains(id), let active = try? await host.store.load(id) {
                        guard !active.runs.contains(where: \.isActive) else { throw BiologyHostError.workerNotStopped }
                        try await host.trashPrepared(id: id, expectedRevision: active.revision)
                    }
                    journal.phase = .rolledBack; try save(journal, host: host)
                }
            } catch {
                for var journal in journals.values { journal.phase = .needsRecovery; try? save(journal, host: host) }
                throw error
            }
            throw original
        }
    }
}
#endif
