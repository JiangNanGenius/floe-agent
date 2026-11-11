// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeElectronicsCore
import CryptoKit
import Darwin
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramExchange
import FloePrintCore
import FloeLaTeXCore

nonisolated enum PersonalFileAction: String, Sendable { case move, duplicate, share }
nonisolated enum PersonalFileActionError: Error, LocalizedError {
    case busy, closeFirst, unsupported, tooLarge, changed
    case moveRecovery(String)
    case deletionRecovery(String)
    var errorDescription: String? {
        switch self {
        case .busy: IDELanguageRunText.t("正在处理这个文件，请稍后重试。", "This file is being processed. Try again shortly.")
        case .closeFirst: IDELanguageRunText.t("请先保存并关闭这个作品，再整理文件。", "Save and close this work before organizing its files.")
        case .unsupported: IDELanguageRunText.t("请在作品编辑器中导出副本，原件会保留。", "Export a copy from the work editor. The original will be kept.")
        case .tooLarge: IDELanguageRunText.t("这个工程超过文件菜单的大小限制，请在编辑器中导出。", "This project exceeds the file-menu size limit. Export it from the editor.")
        case .changed: IDELanguageRunText.t("文件已改变，请刷新后重试。", "The file changed. Refresh and try again.")
        case .moveRecovery(let location): IDELanguageRunText.t("移动记录未完成，文件保留在：", "The move record could not be completed. The file is kept at: ") + location
        case .deletionRecovery(let reason): IDELanguageRunText.t("永久删除未完成，可在回收站中重试。", "Permanent deletion did not finish. Retry in Trash.") + "\n" + reason
        }
    }
}

nonisolated struct PersonalLibraryTrashRestoreResult: Sendable {
    struct Failure: Sendable { let entry: PersonalLibraryTrashEntry; let message: String }
    var restored: [UUID] = []
    var failed: [Failure] = []
}

@MainActor final class PersonalShareArtifact: Identifiable {
    nonisolated let id = UUID()
    let url: URL
    private let directory: URL
    private var finished = false
    init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    func finish() {
        guard !finished else { return }; finished = true
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A token belongs to one visible editor or one awaited AI operation. Releasing
/// an older token cannot release another editor's ownership of the original.
@MainActor final class PersonalLibraryUsageLease {
    nonisolated let projectID: UUID
    nonisolated let token: UUID
    private var released = false
    fileprivate init(projectID: UUID, token: UUID) { self.projectID = projectID; self.token = token }
    func release() {
        guard !released else { return }; released = true
        PersonalLibraryFileActions.releaseUse(id: projectID, token: token)
    }
    deinit {
        let id = projectID, token = token
        Task { @MainActor in PersonalLibraryFileActions.releaseUse(id: id, token: token) }
    }
}

/// Narrow native menu operations. A process-local barrier prevents a new
/// document/CAD owner from reopening an old path during a supported move.
/// Other feature types retain their existing roots and running services.
@MainActor enum PersonalLibraryFileActions {
    private static var active: Set<UUID> = []
    private static let files = PersonalLibraryFileIO()
    private static var uses: [UUID: [UUID: URL]] = [:]
    private static var folderBarriers: [UUID: URL] = [:]

    static func acquireUse(id: UUID, directory: URL, libraryRoot: URL? = nil) throws -> PersonalLibraryUsageLease {
        try requireAvailable(id)
        let location = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard !folderBarriers.values.contains(where: { location.path == $0.path || location.path.hasPrefix($0.path + "/") }) else { throw PersonalFileActionError.busy }
        try PersonalLibraryTrashStore.requireActive(root: try libraryRoot ?? PersonalContentLibrary.applicationRoot(), directory: location, id: id)
        let token = UUID(); uses[id, default: [:]][token] = location
        return PersonalLibraryUsageLease(projectID: id, token: token)
    }
    fileprivate static func releaseUse(id: UUID, token: UUID) {
        uses[id]?.removeValue(forKey: token)
        if uses[id]?.isEmpty == true { uses.removeValue(forKey: id) }
    }

    /// Both native Biology storage and its organizational wrapper are changed
    /// under the library's existing exclusion boundary. The callback receives
    /// a verified current record, never a model-provided native path.
    static func withBiologyLifecycle<T: Sendable>(projectID: UUID, includingDeleted: Bool = false,
        operation: @escaping @MainActor @Sendable (PersonalContentRecord, URL, PersonalContentLibrary) async throws -> T) async throws -> T {
        try begin(projectID); defer { active.remove(projectID) }
        guard uses[projectID]?.isEmpty != false else { throw PersonalFileActionError.closeFirst }
        let library = try await PersonalContentService.shared.library()
        let record: PersonalContentRecord
        if includingDeleted {
            guard let item = try await library.records(includingDeleted: true).first(where: { $0.id == projectID }) else {
                throw PersonalContentError.missingDocument
            }
            record = item
        } else { record = try await library.resolve(projectID).record }
        guard record.kind == .biology else { throw PersonalContentError.invalidProject }
        let root = await library.root
        let directory = try await library.confined(root.appendingPathComponent(record.relativePath))
        guard !folderBarriers.values.contains(where: {
            directory.path == $0.path || directory.path.hasPrefix($0.path + "/")
        }) else { throw PersonalFileActionError.busy }
        try BiologyOriginalBinding.verify(id: projectID, directory: directory)
        try Task.checkCancellation()
        return try await operation(record, directory, library)
    }

    @discardableResult static func delete(_ selection: PersonalContentRecord, environment: AppEnvironment?,
                       library suppliedLibrary: PersonalContentLibrary? = nil,
                       validateSource: @MainActor @Sendable () async throws -> Void = {}) async throws -> PersonalLibraryTrashEntry {
        try begin(selection.id); defer { active.remove(selection.id) }
        let library: PersonalContentLibrary
        if let suppliedLibrary { library = suppliedLibrary } else { library = try await PersonalContentService.shared.library() }
        let value = try await library.resolve(selection.id)
        guard value.record.relativePath == selection.relativePath, value.record.kind == selection.kind,
              value.record.modifiedAt == selection.modifiedAt else { throw PersonalFileActionError.changed }
        defer { changed(selection.id) }
        return try await withFileAssistantLifecycle(action: .trash, entryID: UUID(), relativePath: selection.relativePath,
            members: [value.record], environment: environment, library: library) { eventID in
            // The assistant's awaited tool releases its own lease when its
            // invocation really drains. Visible editors remain protected.
            guard uses[selection.id]?.isEmpty != false else { throw PersonalFileActionError.closeFirst }
            try await validateSource()
            try await prepareForDeletion(value.record, directory: value.url, environment: environment)
            try await validateSource()
            try Task.checkCancellation()
            if selection.kind == .biology {
                guard let environment else { throw PersonalContentError.storageUnavailable }
                let lifecycle = try await environment.biologyComposition.libraryLifecycle()
                return try await lifecycle.deleteUnderHeldBarrier(record: value.record, directory: value.url, library: library)
            }
            return try await library.softDelete(selection, eventID: eventID)
        }
    }

    @discardableResult static func deleteFolder(_ selection: PersonalLibraryFolder, environment: AppEnvironment?,
                             library suppliedLibrary: PersonalContentLibrary? = nil) async throws -> PersonalLibraryTrashEntry {
        let library: PersonalContentLibrary
        if let suppliedLibrary { library = suppliedLibrary } else { library = try await PersonalContentService.shared.library() }
        let root = await library.root
        let folder = try PersonalLibraryTrashStore.folder(root: root, components: selection.components)
        guard folder.identity == selection.resourceIdentity else { throw PersonalFileActionError.changed }
        guard !folderBarriers.values.contains(where: { folder.url.path == $0.path || folder.url.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(folder.url.path + "/") }) else { throw PersonalFileActionError.closeFirst }
        let barrier = UUID(); folderBarriers[barrier] = folder.url
        defer { folderBarriers.removeValue(forKey: barrier) }
        let members = try await library.records(includingDeleted: true).filter { $0.folders.starts(with: selection.components) }
        let ids = Set(members.map(\.id))
        guard active.isDisjoint(with: ids) else { throw PersonalFileActionError.busy }
        active.formUnion(ids); defer { active.subtract(ids) }
        defer { changed(UUID()) }
        return try await withFileAssistantLifecycle(action: .trash, entryID: UUID(), relativePath: selection.relativePath,
            members: members.filter { $0.deletedAt == nil }, environment: environment, library: library) { eventID in
            guard !uses.values.flatMap({ $0.values }).contains(where: { $0.path == folder.url.path || $0.path.hasPrefix(folder.url.path + "/") }) else {
                throw PersonalFileActionError.closeFirst
            }
            for record in members where record.deletedAt == nil {
                try Task.checkCancellation()
                try await prepareForDeletion(record, directory: root.appendingPathComponent(record.relativePath), environment: environment)
            }
            try Task.checkCancellation()
            let biology = members.filter { $0.kind == .biology && $0.deletedAt == nil }
            if !biology.isEmpty {
                guard let environment else { throw PersonalContentError.storageUnavailable }
                let lifecycle = try await environment.biologyComposition.libraryLifecycle()
                return try await lifecycle.withNativeLifecycleUnderHeldBarrier(selections: biology.map {
                    .init(record: $0, directory: root.appendingPathComponent($0.relativePath))
                }, restoring: false, library: library) {
                    try await library.softDeleteFolder(selection, expectedProjectIDs: ids, eventID: eventID)
                }
            }
            return try await library.softDeleteFolder(selection, expectedProjectIDs: ids, eventID: eventID)
        }
    }

    /// The native confirmation freezes this choice. Model tools retain their
    /// separate recoverable-delete / approved-permanent-delete contracts.
    static func deleteFromFiles(_ item: PersonalLibrarySelectionItem, usingTrash: Bool,
        environment: AppEnvironment?, library suppliedLibrary: PersonalContentLibrary? = nil) async throws {
        let library: PersonalContentLibrary
        if let suppliedLibrary { library = suppliedLibrary } else { library = try await PersonalContentService.shared.library() }
        let entry: PersonalLibraryTrashEntry
        switch item {
        case .work(let record): entry = try await delete(record, environment: environment, library: library)
        case .folder(let folder): entry = try await deleteFolder(folder, environment: environment, library: library)
        }
        guard !usingTrash else { return }
        do {
            // Bind physical removal to the exact tombstone just committed;
            // never re-query by pathname and accidentally remove a successor.
            let plans = try await permanentDeletionPlans([entry], environment: environment, library: library)
            for plan in plans { _ = try await permanentlyDelete(plan, environment: environment, library: library) }
        } catch { throw PersonalFileActionError.deletionRecovery(error.localizedDescription) }
    }

    static func restoreBatch(_ entries: [PersonalLibraryTrashEntry], environment: AppEnvironment?,
        library: PersonalContentLibrary? = nil) async -> PersonalLibraryTrashRestoreResult {
        var result = PersonalLibraryTrashRestoreResult()
        // Restore selected parents first, then independently deleted children.
        let ordered = entries.sorted {
            let left = $0.relativePath.split(separator: "/").count
            let right = $1.relativePath.split(separator: "/").count
            return left == right ? $0.relativePath < $1.relativePath : left < right
        }
        for entry in ordered {
            do {
                try Task.checkCancellation()
                try await restore(entry, environment: environment, library: library)
                result.restored.append(entry.id)
            } catch { result.failed.append(.init(entry: entry, message: error.localizedDescription)) }
        }
        return result
    }

    static func restore(_ entry: PersonalLibraryTrashEntry, environment: AppEnvironment?,
                        library suppliedLibrary: PersonalContentLibrary? = nil,
                        validateSource: @escaping @MainActor @Sendable () async throws -> Void = {}) async throws {
        let library: PersonalContentLibrary
        if let suppliedLibrary { library = suppliedLibrary } else { library = try await PersonalContentService.shared.library() }
        guard try await library.recentlyDeleted().contains(entry) else { throw PersonalFileActionError.changed }
        let root = await library.root
        let directory = try await library.confined(root.appendingPathComponent(entry.relativePath))
        let components = try PersonalLibraryTrashStore.components(entry.relativePath)
        let members = try await library.records(includingDeleted: true).filter {
            entry.kind == .folder ? $0.folders.starts(with: components) : $0.id == entry.projectID
        }
        let ids = Set(members.map(\.id))
        guard active.isDisjoint(with: ids), ids.allSatisfy({ uses[$0]?.isEmpty != false }),
              !folderBarriers.values.contains(where: { directory.path == $0.path || directory.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(directory.path + "/") }) else {
            throw PersonalFileActionError.busy
        }
        active.formUnion(ids)
        let barrier = UUID(); folderBarriers[barrier] = directory
        defer { active.subtract(ids); folderBarriers.removeValue(forKey: barrier) }
        var afterRestore = try PersonalLibraryTrashStore.read(root: root)
        afterRestore.entries.removeAll { $0.id == entry.id }
        let restoringMembers = members.filter { afterRestore.deletionDate(projectID: $0.id, path: $0.relativePath) == nil }
        defer { changed(entry.projectID ?? entry.id) }
        try await withFileAssistantLifecycle(action: .restore, entryID: entry.id, relativePath: entry.relativePath,
            members: restoringMembers, environment: environment, library: library) { _ in
            try await validateSource(); try Task.checkCancellation()
            let biology = restoringMembers.filter { $0.kind == .biology }
            if !biology.isEmpty {
                guard let environment else { throw PersonalContentError.storageUnavailable }
                let lifecycle = try await environment.biologyComposition.libraryLifecycle()
                try await lifecycle.withNativeLifecycleUnderHeldBarrier(selections: biology.map {
                    .init(record: $0, directory: root.appendingPathComponent($0.relativePath))
                }, restoring: true, library: library) {
                    try await validateSource(); try Task.checkCancellation()
                    try await library.restore(entry.id)
                }
            } else {
                try await validateSource(); try Task.checkCancellation()
                try await library.restore(entry.id)
            }
        }
    }

    /// One confirmation source for UI and the existing task-bound tool. The
    /// canonical Biology coordinator adds real native CAS snapshots as needed.
    static func permanentDeletionPlans(_ entries: [PersonalLibraryTrashEntry], environment: AppEnvironment?,
        library suppliedLibrary: PersonalContentLibrary? = nil) async throws -> [PersonalPermanentDeletePlan] {
        let library: PersonalContentLibrary
        if let suppliedLibrary { library = suppliedLibrary } else { library = try await PersonalContentService.shared.library() }
        guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count else { throw PersonalPermanentDeleteError.changed }
        let roots = entries.filter { entry in !entries.contains { parent in
            parent.kind == .folder && parent.id != entry.id && entry.relativePath.hasPrefix(parent.relativePath + "/")
        } }
        var proposals: [PersonalPermanentDeletePlan] = []
        // The storage transaction bounds one proposal to 128 entries. Large
        // Select All operations retain that bound without capping selection.
        for start in stride(from: 0, to: roots.count, by: 128) {
            try Task.checkCancellation()
            proposals += try await library.permanentDeletionProposals(Array(roots[start..<min(start + 128, roots.count)]))
        }
        guard proposals.contains(where: { $0.members.contains(where: { $0.kind == .biology }) }) else { return proposals }
        guard let environment else { throw PersonalContentError.storageUnavailable }
        let lifecycle = try await environment.biologyComposition.libraryLifecycle()
        return try await lifecycle.permanentDeletionPlans(proposals, library: library)
    }

    /// Only already-trashed originals, with the confirmation's exact entry/tree
    /// snapshots. The existing owner/session barriers stay held through commit.
    static func permanentlyDelete(_ plan: PersonalPermanentDeletePlan, environment: AppEnvironment?,
        library suppliedLibrary: PersonalContentLibrary? = nil,
        validateSource: @escaping @MainActor @Sendable () async throws -> Void = {}) async throws -> PersonalPermanentDeleteReceipt {
        let library: PersonalContentLibrary
        if let suppliedLibrary { library = suppliedLibrary } else { library = try await PersonalContentService.shared.library() }
        let root = await library.root
        let locations = plan.protectedRelativePaths.map { root.appendingPathComponent($0).standardizedFileURL }
        let ids = Set(plan.members.map(\.id) + (plan.entry.projectID.map { [$0] } ?? []))
        guard active.isDisjoint(with: ids),
              !locations.contains(where: { location in
                  folderBarriers.values.contains { location.path == $0.path || location.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(location.path + "/") }
              }) else { throw PersonalFileActionError.closeFirst }
        active.formUnion(ids)
        let barriers = locations.map { location -> UUID in let id = UUID(); folderBarriers[id] = location; return id }
        defer { active.subtract(ids); for id in barriers { folderBarriers.removeValue(forKey: id) } }
        defer { for id in ids { changed(id) }; changed(plan.entry.id) }
        return try await withFileAssistantLifecycle(action: .purge, entryID: plan.entry.id,
            relativePath: plan.entry.relativePath, members: plan.members, environment: environment, library: library) { _ in
            guard ids.allSatisfy({ uses[$0]?.isEmpty != false }),
                  !locations.contains(where: { location in
                      uses.values.flatMap({ $0.values }).contains { $0.path == location.path || $0.path.hasPrefix(location.path + "/") }
                  }) else { throw PersonalFileActionError.closeFirst }
            try await validateSource(); try Task.checkCancellation()
            if plan.requiresPreparation {
                for record in plan.members {
                    try await prepareForDeletion(record, directory: root.appendingPathComponent(record.relativePath), environment: environment,
                        permanentPlan: plan)
                }
            } else {
                // The owned journal was created only after preparation.
                for record in plan.members {
                    switch record.kind {
                    case .printing: try PrintProjectSession.requireIdleForDeletion(id: record.id)
                    case .manufacturing: try ManufacturingSessions.requireIdleForDeletion(id: record.id)
                    case .music: try MusicProjectSession.requireIdleForDeletion(id: record.id)
                    case .image, .drawing, .video: try MediaV2Session.requireIdleForDeletion(id: record.id)
                    case .document:
                        try PersonalTextDocument.requireClosedForFileAction(projectID: record.id)
                        try PersonalOfficeDocument.requireClosedForFileAction(projectID: record.id)
                    default: break
                    }
                }
            }
            try await validateSource(); try Task.checkCancellation()
            if plan.members.contains(where: { $0.kind == .biology }) {
                guard let environment else { throw PersonalContentError.storageUnavailable }
                let lifecycle = try await environment.biologyComposition.libraryLifecycle()
                return try await lifecycle.permanentlyDeleteUnderHeldBarrier(plan, library: library)
            }
            return try await library.permanentlyDelete(plan)
        }
    }

    private static func withFileAssistantLifecycle<T: Sendable>(action: PersonalFileAssistantLifecycleIntent.Action,
        entryID: UUID, relativePath: String, members: [PersonalContentRecord], environment: AppEnvironment?,
        library: PersonalContentLibrary, operation: @MainActor @Sendable (UUID) async throws -> T) async throws -> T {
        guard let environment else { return try await operation(entryID) }
        let lifecycle = try environment.studioCoordinator.fileAssistantLifecycle(library: library)
        do {
            let value = try await lifecycle.perform(action: action, entryID: entryID, relativePath: relativePath,
                members: members, operation: operation)
            await environment.conversationCenter.reload()
            return value
        } catch {
            // The file may already be committed with companion cleanup still
            // pending. Read durable truth, never resurrect a hidden original.
            await environment.conversationCenter.reload()
            throw error
        }
    }
    static func permanentlyDeleteBatch(_ plans: [PersonalPermanentDeletePlan], environment: AppEnvironment?,
        library: PersonalContentLibrary? = nil) async -> PersonalPermanentDeleteBatchResult {
        var result = PersonalPermanentDeleteBatchResult()
        for plan in plans {
            do { result.deleted.append(try await permanentlyDelete(plan, environment: environment, library: library)) }
            catch {
                let code = (error as? PersonalPermanentDeleteError)?.rawValue ?? (error is CancellationError ? "cancelled" : "unavailable")
                result.failed.append(.init(entryID: plan.id, code: code, message: error.localizedDescription))
            }
        }
        return result
    }

    /// Batch deletion reuses the same guarded per-item operations instead of a
    /// fused path: revision/active-document/task/sidecar checks stay identical
    /// to single deletion. Failures never abort the remaining items and never
    /// hide them; undeleted originals stay visible for the user to handle.
    static func deleteBatch(_ items: [PersonalLibrarySelectionItem], environment: AppEnvironment?,
                            library: PersonalContentLibrary? = nil, usingTrash: Bool = true) async -> PersonalLibraryBatchDeleteResult {
        var result = PersonalLibraryBatchDeleteResult()
        // Defense in depth: the selection model already deduplicated; redo it
        // here so no caller can double-visit an absorbed descendant.
        for item in PersonalLibrarySelectionModel.deduplicated(items) {
            do {
                try Task.checkCancellation()
                try await deleteFromFiles(item, usingTrash: usingTrash, environment: environment, library: library)
                result.deleted.append(item)
            } catch {
                result.failed.append(.init(item: item, message: error.localizedDescription))
            }
        }
        if !result.deleted.isEmpty { changed(UUID()) }
        return result
    }

    /// Native lifecycle callers must still own the exact file's exclusion
    /// boundary. This is not a model/tool permission or an expired run grant.
    static func requireHeldFileAction(_ id: UUID) throws {
        guard active.contains(id) else { throw PersonalFileActionError.changed }
    }

    private static func prepareForDeletion(_ record: PersonalContentRecord, directory: URL, environment: AppEnvironment?,
        permanentPlan: PersonalPermanentDeletePlan? = nil) async throws {
        switch record.kind {
        case .document:
            try PersonalTextDocument.requireClosedForFileAction(projectID: record.id)
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: record.id)
        case .cad2D, .cad3D: try PersonalCADSessions.prepareForLibraryMove(id: record.id, directory: directory)
        case .printing: try PrintProjectSession.requireIdleForDeletion(id: record.id)
        case .manufacturing: try ManufacturingSessions.requireIdleForDeletion(id: record.id)
        case .music: try MusicProjectSession.requireIdleForDeletion(id: record.id)
        case .electronics: try await ElectronicsProjectSession.prepareForFileAction(id: record.id, directory: directory)
        case .geography: try await GISProjectSession.prepareForFileAction(id: record.id, directory: directory)
        case .image, .drawing, .video: try MediaV2Session.requireIdleForDeletion(id: record.id)
        case .meeting: try await MeetingProjectSession.prepareForDeletion(id: record.id)
        case .chemistry:
            guard let environment else { throw PersonalContentError.storageUnavailable }
            try await ChemistryProjectSession.prepareForLibraryDeletion(record: record, directory: directory,
                environment: environment, permanentPlan: permanentPlan)
        case .biology: break // The same held barrier wraps native stop/trash and the atomic Library commit above.
        case .canvas: try await CanvasHostSessions.shared.requireIdleForDeletion(canvasID: record.id, directory: directory)
        case .diagram, .latex: break // The editor/AI usage lease owns all writes.
        }
    }
    static func requireAvailable(_ id: UUID) throws {
        guard !active.contains(id) else { throw PersonalFileActionError.busy }
    }
    static func supports(_ action: PersonalFileAction, kind: PersonalContentKind) -> Bool {
        switch action {
        case .move: [.document, .cad2D, .cad3D, .biology, .latex, .electronics, .geography].contains(kind)
        case .duplicate: [.document, .printing, .latex, .electronics, .geography].contains(kind)
        case .share: [.document, .diagram, .printing, .latex, .electronics, .geography].contains(kind)
        }
    }
    static func limitation(_ action: PersonalFileAction, kind: PersonalContentKind) -> String {
        if action == .move {
            return IDELanguageRunText.t("这个类型暂不能在文件菜单中移动。请先在编辑器导出副本，原件和正在进行的工作会保留。", "This type cannot be moved from the file menu yet. Export a copy from its editor; the original and ongoing work will be kept.")
        }
        return IDELanguageRunText.t("这个类型需要在编辑器中导出副本。", "Export a copy of this type from its editor.")
    }

    static func move(_ selection: PersonalContentRecord, to folders: [String]) async throws -> PersonalContentRecord {
        guard supports(.move, kind: selection.kind) else { throw PersonalFileActionError.unsupported }
        try begin(selection.id); defer { active.remove(selection.id) }
        let library = try await PersonalContentService.shared.library(), source = try await library.resolve(selection.id)
        guard source.record.relativePath == selection.relativePath, source.record.kind == selection.kind else { throw PersonalFileActionError.changed }
        switch source.record.kind {
        case .geography:
            guard uses[selection.id]?.isEmpty != false else { throw PersonalFileActionError.closeFirst }
            try await GISProjectSession.prepareForFileAction(id: selection.id, directory: source.url)
            _ = try await personalPreviewOffMain { try GISProjectOriginal.read(id: selection.id, directory: source.url) }
        case .electronics:
            guard uses[selection.id]?.isEmpty != false else { throw PersonalFileActionError.closeFirst }
            try await ElectronicsProjectSession.prepareForFileAction(id: selection.id, directory: source.url)
            _ = try await EDAProjectStore(root: checkedChildDirectory("Electronics", under: source.url), projectID: selection.id, readOnly: true).load()
        case .latex:
            guard uses[selection.id]?.isEmpty != false else {throw PersonalFileActionError.closeFirst}
            let manifest=try await LaTeXProjectStore(root:source.url.appendingPathComponent("LaTeX")).manifest()
            guard manifest.id==selection.id,manifest.owner == .init(kind:.space,id:selection.id) else {throw PersonalFileActionError.changed}
        case .biology:
            guard uses[selection.id]?.isEmpty != false else { throw PersonalFileActionError.closeFirst }
            try BiologyOriginalBinding.verify(id: selection.id, directory: source.url)
        case .document:
            try PersonalTextDocument.requireClosedForFileAction(projectID: selection.id)
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: selection.id)
        case .cad2D, .cad3D:
            try PersonalCADSessions.prepareForLibraryMove(id: selection.id, directory: source.url)
        default: throw PersonalFileActionError.unsupported
        }
        try Task.checkCancellation()
        let result = try await library.move(selection.id, to: folders, expectedRelativePath: source.record.relativePath)
        changed(result.id)
        return result
    }

    static func duplicate(_ selection: PersonalContentRecord, title: String, to folders: [String]) async throws -> PersonalContentRecord {
        guard supports(.duplicate, kind: selection.kind) else { throw PersonalFileActionError.unsupported }
        try begin(selection.id); defer { active.remove(selection.id) }
        let library = try await PersonalContentService.shared.library(), source = try await library.resolve(selection.id)
        guard source.record.relativePath == selection.relativePath, source.record.kind == selection.kind else { throw PersonalFileActionError.changed }
        let result: PersonalContentRecord
        if source.record.kind == .geography {
            let saved = try await personalPreviewOffMain { try GISProjectOriginal.read(id: selection.id, directory: source.url) }
            result = try await library.create(kind: .geography, title: title, in: folders) { directory, id in
                try await GISProjectOriginal.copy(saved, to: directory, id: id, title: title)
                try saved.validate(); try await verifyLocation(selection.id, expected: source.record.relativePath)
                try writeCopyReceipt(directory: directory, source: source.record, newID: id, revision: saved.sha256)
            }
        } else if source.record.kind == .latex {
            let store=try LaTeXProjectStore(root:source.url.appendingPathComponent("LaTeX")),snapshot=try await store.snapshot()
            do {
                guard snapshot.manifest.id==selection.id,snapshot.manifest.owner == .init(kind:.space,id:selection.id) else {throw PersonalFileActionError.changed}
                result=try await library.create(kind:.latex,title:title,in:folders) {directory,id in
                    var files=[String:Data]()
                    for entry in snapshot.manifest.files {
                        let data=try Data(contentsOf:LaTeXPath.child(entry.path,root:snapshot.sourceRoot))
                        guard LaTeXDigest.hash(data)==entry.sha256 else {throw PersonalFileActionError.changed};files[entry.path]=data
                    }
                    _ = try LaTeXProjectStore.create(root:directory.appendingPathComponent("LaTeX"),id:id,owner:.init(kind:.space,id:id),title:title,files:files,mainFile:snapshot.manifest.mainFile,engine:snapshot.manifest.engine)
                    try await verifyLocation(selection.id,expected:source.record.relativePath)
                    try writeCopyReceipt(directory:directory,source:source.record,newID:id,revision:String(snapshot.manifest.revision))
                }
                try await store.releaseSnapshot(snapshot)
            } catch {try? await store.releaseSnapshot(snapshot);throw error}
        } else if source.record.kind == .electronics {
            let store = try EDAProjectStore(root: checkedChildDirectory("Electronics", under: source.url), projectID: selection.id, readOnly: true)
            let saved = try await store.load()
            result = try await library.create(kind: .electronics, title: title, in: folders) { directory, id in
                var copy = saved.project
                copy.id = id; copy.title = title; copy.revision = 0; copy.createdAt = Date(); copy.modifiedAt = copy.createdAt
                for board in copy.boards.indices { for zone in copy.boards[board].zones.indices {
                    copy.boards[board].zones[zone].filledPolygons = []; copy.boards[board].zones[zone].fillRevision = nil
                    copy.boards[board].zones[zone].fillState = nil
                } }
                _ = try await EDAProjectStore.create(root: directory.appendingPathComponent("Electronics"), project: copy)
                guard try await store.load().digest == saved.digest else { throw PersonalFileActionError.changed }
                try await verifyLocation(selection.id, expected: source.record.relativePath)
                try writeCopyReceipt(directory: directory, source: source.record, newID: id, revision: String(saved.project.revision))
            }
        } else if source.record.kind == .document {
            try PersonalTextDocument.requireClosedForFileAction(projectID: selection.id)
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: selection.id)
            let original = try await PersonalContentService.shared.originalFile(selection.id)
            guard original.deletingLastPathComponent().standardizedFileURL == (try checkedChildDirectory("Original", under: source.url)) else { throw PersonalContentError.invalidProject }
            let io = files
            result = try await library.create(kind: .document, title: title, in: folders) { directory, id in
                let target = directory.appendingPathComponent("Original", isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                let receipt = try await io.copyRegular(original, to: target.appendingPathComponent(original.lastPathComponent))
                try await verifyLocation(selection.id, expected: source.record.relativePath)
                try writeCopyReceipt(directory: directory, source: source.record, newID: id, revision: receipt)
            }
        } else {
            let disk = PrintProjectDisk(root: try checkedChildDirectory("Printing", under: source.url)), frozen = try await disk.load()
            guard frozen.projectID == source.record.id else { throw PersonalFileActionError.changed }
            result = try await library.create(kind: .printing, title: title, in: folders) { directory, id in
                _ = try await copyEditablePrint(frozen, from: disk, to: directory.appendingPathComponent("Printing"), newID: id)
                guard try await disk.load().revision == frozen.revision else { throw PersonalFileActionError.changed }
                try await verifyLocation(selection.id, expected: source.record.relativePath)
                try writeCopyReceipt(directory: directory, source: source.record, newID: id, revision: "print:\(frozen.revision)")
            }
        }
        changed(result.id)
        return result
    }

    static func share(_ selection: PersonalContentRecord) async throws -> PersonalShareArtifact {
        guard supports(.share, kind: selection.kind) else { throw PersonalFileActionError.unsupported }
        try begin(selection.id); defer { active.remove(selection.id) }
        let library = try await PersonalContentService.shared.library(), source = try await library.resolve(selection.id)
        guard source.record.relativePath == selection.relativePath, source.record.kind == selection.kind else { throw PersonalFileActionError.changed }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("floe-personal-share-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var adopted = false
        defer { if !adopted { try? FileManager.default.removeItem(at: directory) } }
        let url: URL
        switch source.record.kind {
        case .geography:
            let saved = try await personalPreviewOffMain { try GISProjectOriginal.read(id: selection.id, directory: source.url) }
            let bytes = try GISProjectOriginal.projectData(saved)
            url = directory.appendingPathComponent(safeName(source.record.title) + ".floegis")
            try bytes.write(to: url, options: .withoutOverwriting)
            try saved.validate()
        case .electronics:
            let store = try EDAProjectStore(root: checkedChildDirectory("Electronics", under: source.url), projectID: selection.id, readOnly: true)
            let saved = try await store.load(), bundle = try EDAExchange.export(saved.project, format: .project)
            guard let file = bundle.files.first else { throw PersonalContentError.invalidProject }
            url = directory.appendingPathComponent(safeName(source.record.title) + ".floeeda")
            try file.data.write(to: url, options: .atomic)
            guard try await store.load().digest == saved.digest else { throw PersonalFileActionError.changed }
        case .latex:
            let store=try LaTeXProjectStore(root:source.url.appendingPathComponent("LaTeX")),snapshot=try await store.snapshot()
            url=directory.appendingPathComponent(safeName(source.record.title)+".zip")
            do {try LaTeXProjectArchive.export(snapshot,to:url);try await store.releaseSnapshot(snapshot)}catch {try? await store.releaseSnapshot(snapshot);throw error}
        case .document:
            try PersonalTextDocument.requireClosedForFileAction(projectID: selection.id)
            try PersonalOfficeDocument.requireClosedForFileAction(projectID: selection.id)
            let original = try await PersonalContentService.shared.originalFile(selection.id)
            guard original.deletingLastPathComponent().standardizedFileURL == (try checkedChildDirectory("Original", under: source.url)) else { throw PersonalContentError.invalidProject }
            url = directory.appendingPathComponent(original.lastPathComponent)
            _ = try await files.copyRegular(original, to: url)
        case .diagram:
            let documentRoot = try checkedChildDirectory("Diagram", under: source.url)
            let assetRoot = try checkedChildDirectory("Assets", under: source.url)
            let repository = try FileDiagramRepository(directory: documentRoot)
            let frozen = try await repository.load(selection.id)
            guard frozen.id == selection.id, frozen.assets.count <= 2_000,
                  frozen.assets.allSatisfy({ $0.byteCount >= 0 && $0.byteCount <= 64 * 1_024 * 1_024 }),
                  frozen.assets.reduce(Int64(0), { $0 + Int64($1.byteCount) }) <= 128 * 1_024 * 1_024 else { throw PersonalFileActionError.tooLarge }
            let assets = try FileDiagramAssets(directory: assetRoot)
            let output = try await DiagramExchange.export(frozen, format: .floemap, assets: assets)
            guard output.data.count <= PersonalLibraryFileIO.maximumBytes,
                  try await repository.load(selection.id).revision == frozen.revision else { throw PersonalFileActionError.changed }
            url = directory.appendingPathComponent(safeName(source.record.title) + ".floemap")
            try output.data.write(to: url, options: .atomic)
        case .printing:
            let disk = PrintProjectDisk(root: try checkedChildDirectory("Printing", under: source.url)), frozen = try await disk.load()
            guard frozen.projectID == selection.id else { throw PersonalFileActionError.changed }
            let package = directory.appendingPathComponent("EditablePrint", isDirectory: true)
            _ = try await copyEditablePrint(frozen, from: disk, to: package.appendingPathComponent("Printing"), newID: frozen.projectID)
            struct Envelope: Encodable { let format = "org.floe.print.editable"; let version = 1; let projectID: UUID; let sourceRevision: UInt64 }
            try JSONEncoder().encode(Envelope(projectID: frozen.projectID, sourceRevision: frozen.revision))
                .write(to: package.appendingPathComponent("print-project.json"), options: .atomic)
            url = directory.appendingPathComponent(safeName(source.record.title) + ".floeprint.zip")
            try await files.zipDirectory(package, to: url)
            try FileManager.default.removeItem(at: package)
            guard try await disk.load().revision == frozen.revision else { throw PersonalFileActionError.changed }
        default: throw PersonalFileActionError.unsupported
        }
        try await verifyLocation(selection.id, expected: source.record.relativePath)
        try Task.checkCancellation()
        adopted = true
        return .init(url: url, directory: directory)
    }

    private static func copyEditablePrint(_ frozen: PrintProjectDocument, from source: PrintProjectDisk, to root: URL, newID: UUID) async throws -> PrintProjectDocument {
        let disk = PrintProjectDisk(root: root)
        let plates = frozen.plates ?? [.init(id: frozen.plateID, name: "Plate 1")]
        guard !plates.isEmpty, plates.count <= 32, Set(plates.map(\.id)).count == plates.count else { throw PrintError.invalidMesh }
        let rebase = newID != frozen.projectID
        let mapping = Dictionary(uniqueKeysWithValues: plates.map { ($0.id, rebase ? UUID() : $0.id) })
        var next = frozen; next.projectID = newID; next.revision = rebase ? 0 : frozen.revision
        guard let selectedPlate = mapping[frozen.plateID] else { throw PrintError.invalidMesh }
        next.plateID = selectedPlate
        next.plates = plates.map { .init(id: mapping[$0.id]!, name: $0.name) }
        next.resultAsset = nil; next.resultFingerprint = nil; next.resultLayerCount = nil
        var objects = frozen.objects ?? frozen.meshAsset.map { [.init(plateID: frozen.plateID, name: frozen.meshName ?? "Model", meshAsset: $0)] } ?? []
        guard objects.count <= 200 else { throw PrintError.sizeLimit }
        var stored = Set<String>(), bytes = 0
        let sourceRoot = source.root
        for index in objects.indices {
            try Task.checkCancellation()
            guard let plate = mapping[objects[index].plateID] else { throw PrintError.invalidMesh }
            try checkRegularAsset(objects[index].meshAsset, under: sourceRoot)
            let mesh = try await source.meshAsset(objects[index].meshAsset)
            if stored.insert(objects[index].meshAsset).inserted { bytes += mesh.positions.count * 4 }
            guard bytes <= PersonalLibraryFileIO.maximumBytes else { throw PersonalFileActionError.tooLarge }
            objects[index].meshAsset = try await disk.storeMesh(mesh)
            objects[index].plateID = plate
            if rebase { objects[index].id = UUID() }
        }
        if let provenance = frozen.sourceSnapshot {
            try checkRegularAsset(provenance.geometryAsset, under: sourceRoot)
            let mesh = try await source.meshAsset(provenance.geometryAsset)
            if stored.insert(provenance.geometryAsset).inserted { bytes += mesh.positions.count * 4 }
            guard bytes <= PersonalLibraryFileIO.maximumBytes,
                  try await disk.storeMesh(mesh) == provenance.geometryAsset else { throw PrintError.invalidMesh }
        }
        next.objects = objects
        next.meshAsset = objects.first(where: { $0.plateID == next.plateID })?.meshAsset
        next.meshName = objects.first(where: { $0.plateID == next.plateID })?.name
        try await disk.create(next)
        let verified = try await disk.load()
        guard verified.projectID == newID, verified.objects?.count == objects.count else { throw PrintError.invalidMesh }
        return verified
    }
    private static func verifyLocation(_ id: UUID, expected: String) async throws {
        try Task.checkCancellation()
        guard try await PersonalContentService.shared.library().resolve(id).record.relativePath == expected else { throw PersonalFileActionError.changed }
    }
    private static func begin(_ id: UUID) throws { guard active.insert(id).inserted else { throw PersonalFileActionError.busy } }
    private nonisolated static func checkedChildDirectory(_ name: String, under root: URL) throws -> URL {
        let parent = root.standardizedFileURL.resolvingSymlinksInPath(), child = parent.appendingPathComponent(name)
        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              child.resolvingSymlinksInPath() == child else { throw PersonalContentError.invalidProject }
        return child
    }
    private nonisolated static func checkRegularAsset(_ name: String, under root: URL) throws {
        guard name == (name as NSString).lastPathComponent, !name.hasPrefix("."), !name.contains("\\") else { throw PrintError.invalidMesh }
        let asset = root.appendingPathComponent(name)
        let values = try asset.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              asset.standardizedFileURL.resolvingSymlinksInPath() == asset.standardizedFileURL else { throw PrintError.invalidMesh }
    }
    private static func changed(_ id: UUID) { NotificationCenter.default.post(name: .floeStudioDocumentDidChange, object: id) }
    private nonisolated static func writeCopyReceipt(directory: URL, source: PersonalContentRecord, newID: UUID, revision: String) throws {
        struct Receipt: Encodable { let format = "org.floe.library.copy"; let sourceProjectID: UUID; let projectID: UUID; let sourceRevision: String; let date: Date }
        try JSONEncoder().encode(Receipt(sourceProjectID: source.id, projectID: newID, sourceRevision: revision, date: Date()))
            .write(to: directory.appendingPathComponent("LibraryCopy.json"), options: .atomic)
    }
    private static func safeName(_ value: String) -> String {
        let name = String(value.prefix(120)).replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: ":", with: " ").components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Floe" : name
    }
}

private actor PersonalLibraryFileIO {
    nonisolated static let maximumBytes = 128 * 1_024 * 1_024
    func copyRegular(_ source: URL, to target: URL) throws -> String { try Self.copyBounded(source, to: target) }
    /// A bounded descriptor copy, not a path-recursive project clone. Original
    /// bytes stay intact; cancellation removes only our incomplete output.
    private nonisolated static func copyBounded(_ source: URL, to target: URL) throws -> String {
        try Task.checkCancellation()
        guard source.isFileURL, target.isFileURL else { throw PersonalFileActionError.changed }
        let input = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else { throw PersonalFileActionError.changed }
        defer { Darwin.close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0, before.st_size <= Int64(Self.maximumBytes) else { throw PersonalFileActionError.tooLarge }
        let output = Darwin.open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw PersonalFileActionError.changed }
        var completed = false
        defer { Darwin.close(output); if !completed { try? FileManager.default.removeItem(at: target) } }
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024), total = 0, hash = SHA256()
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, count <= Self.maximumBytes - total else { throw PersonalFileActionError.tooLarge }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count)); hash.update(data: chunk); total += count
            try chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw PersonalContentError.storageUnavailable }
                    offset += written
                }
            }
        }
        var after = stat(), path = stat()
        guard fstat(input, &after) == 0, lstat(source.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_size == Int64(total),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              path.st_dev == after.st_dev, path.st_ino == after.st_ino, (path.st_mode & S_IFMT) == S_IFREG,
              path.st_size == after.st_size, path.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              path.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw PersonalFileActionError.changed }
        guard fsync(output) == 0 else { throw PersonalContentError.storageUnavailable }
        completed = true
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func zipDirectory(_ directory: URL, to output: URL) throws {
        try Task.checkCancellation()
        var coordinationError: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { archive in
            result = Result { _ = try Self.copyBounded(archive, to: output) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw PersonalContentError.storageUnavailable }
        try result.get(); try Task.checkCancellation()
    }
}
#endif
