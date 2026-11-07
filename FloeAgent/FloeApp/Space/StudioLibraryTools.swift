// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Darwin
import FloeCore
import FloeTools

nonisolated struct StudioLibraryInput: Decodable, Sendable {
    enum Action: String, Decodable, Sendable { case list, detail, recentlyDeleted, delete, restore }
    let action: Action
    let projectID: UUID?
    let expectedIdentity: String?
    let trashEntryID: UUID?
    let offset: Int?
    let limit: Int?
    var isMutation: Bool { action == .delete || action == .restore }
    private struct Field: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    private enum Keys: String, CodingKey { case action, projectID, expectedIdentity, trashEntryID, offset, limit }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Field.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["action", "projectID", "expectedIdentity", "trashEntryID", "offset", "limit"]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown library field; host/workspace paths and permanent delete are not accepted"))
        }
        let c = try decoder.container(keyedBy: Keys.self)
        action = try c.decode(Action.self, forKey: .action); projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        expectedIdentity = try c.decodeIfPresent(String.self, forKey: .expectedIdentity); trashEntryID = try c.decodeIfPresent(UUID.self, forKey: .trashEntryID)
        offset = try c.decodeIfPresent(Int.self, forKey: .offset); limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    }
    func validate() throws {
        switch action {
        case .list, .recentlyDeleted:
            guard projectID == nil, expectedIdentity == nil, trashEntryID == nil,
                  (0...100_000).contains(offset ?? 0), (1...64).contains(limit ?? 32) else { throw FloeError.validationFailed("Library lists accept only offset and limit 1...64") }
        case .detail:
            guard projectID != nil, expectedIdentity == nil, trashEntryID == nil, offset == nil, limit == nil else { throw FloeError.validationFailed("Library detail requires only an authorized projectID") }
        case .delete, .restore:
            guard projectID != nil, let expectedIdentity, expectedIdentity.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  offset == nil, limit == nil, (action == .restore) == (trashEntryID != nil) else {
                throw FloeError.validationFailed("Read a fresh library detail, then use its projectID and expectedIdentity; restore also requires its exact trashEntryID")
            }
        }
    }
}

nonisolated struct StudioLibraryItem: Encodable, Sendable {
    let projectID: UUID
    let kind: PersonalContentKind
    let title: String
    let folders: [String]
    let modifiedAt: Date
    let deletedAt: Date?
    let identity: String
    let trashEntryID: UUID?
    let restoreRequiresParentFolder: Bool
    let needsRecovery: Bool
}

private nonisolated struct StudioLibraryIdentityPin: Encodable {
    let record: PersonalContentRecord
    let manifestSHA256: String
    let directoryIdentity: String
    let trashEpoch: String?
    let direct: PersonalLibraryTrashEntry?
    let parents: [PersonalLibraryTrashEntry]
}

@MainActor enum StudioLibraryActions {
    private struct Original: Sendable { let record: PersonalContentRecord; let item: StudioLibraryItem }
    private struct Page: Encodable {
        let action: String; let items: [StudioLibraryItem]; let total: Int; let nextOffset: Int?
        let scope = "Only native works already bound to this saved task. These project IDs are not workspace file paths."
    }
    private struct Receipt: Encodable { let action: String; let item: StudioLibraryItem; let permanent = false }

    static func perform(_ input: StudioLibraryInput, environment: AppEnvironment, authorizedIDs: Set<UUID>, context: ToolContext,
        authorize: @escaping @MainActor @Sendable (UUID?, Bool) async throws -> Void) async throws -> ToolExecutionOutput {
        try input.validate(); try context.cancellation.throwIfCancelled(); try await authorize(input.projectID, input.isMutation)
        let library = try await PersonalContentService.shared.library()
        if input.action == .list || input.action == .recentlyDeleted {
            let records = try await library.records(includingDeleted: true).filter {
                authorizedIDs.contains($0.id) && (input.action == .recentlyDeleted ? $0.deletedAt != nil : $0.deletedAt == nil)
            }
            let offset = input.offset ?? 0, limit = input.limit ?? 32
            guard offset <= records.count else { throw FloeError.validationFailed("Library offset exceeds this authorized list") }
            let end = min(records.count, offset + limit)
            var items: [StudioLibraryItem] = []
            for record in records[offset..<end] {
                try context.cancellation.throwIfCancelled(); try await authorize(record.id, false)
                items.append(try await original(id: record.id, library: library, checkAvailability: true).item)
            }
            try await authorize(nil, false); try context.cancellation.throwIfCancelled()
            return try StudioToolOutput.make(Page(action: input.action.rawValue, items: items, total: records.count,
                nextOffset: end < records.count ? end : nil))
        }
        guard let id = input.projectID, authorizedIDs.contains(id) else { throw FloeError.validationFailed("This task has no binding to that native work") }
        let selected = try await original(id: id, library: library, checkAvailability: true)
        try await authorize(id, input.isMutation); try context.cancellation.throwIfCancelled()
        if input.action == .detail { return try StudioToolOutput.make(Receipt(action: "detail", item: selected.item)) }
        guard input.expectedIdentity == selected.item.identity else { throw PersonalContentError.changedDocument }
        let verify: @MainActor @Sendable () async throws -> Void = {
            try context.cancellation.throwIfCancelled(); try await authorize(id, true)
            let current = try await original(id: id, library: library, checkAvailability: false)
            guard current.item.identity == selected.item.identity else { throw PersonalContentError.changedDocument }
            try context.cancellation.throwIfCancelled()
        }
        if input.action == .delete {
            guard selected.record.deletedAt == nil else { throw PersonalContentError.deleted }
            try await PersonalLibraryFileActions.delete(selected.record, environment: environment, library: library, validateSource: verify)
        } else {
            guard selected.record.deletedAt != nil else { throw PersonalContentError.changedDocument }
            guard !selected.item.restoreRequiresParentFolder else { throw PersonalContentError.restoreParentFirst }
            guard let entry = try await library.recentlyDeleted().first(where: {
                $0.kind == .work && $0.id == input.trashEntryID && $0.projectID == id && $0.id == selected.item.trashEntryID
            }) else { throw PersonalContentError.changedDocument }
            try await PersonalLibraryFileActions.restore(entry, environment: environment, library: library, validateSource: verify)
        }
        let result = try await original(id: id, library: library, checkAvailability: true)
        return try StudioToolOutput.make(Receipt(action: input.action.rawValue, item: result.item))
    }

    /// Reads the real wrapper descriptor without opening/migrating any editor.
    /// The hash is an identity/CAS pin, never a permission or path grant.
    private static func original(id: UUID, library: PersonalContentLibrary, checkAvailability: Bool) async throws -> Original {
        if checkAvailability { try PersonalLibraryFileActions.requireAvailable(id) }
        let root = await library.root
        let trashEpoch = try await personalPreviewOffMain { () -> PersonalPreviewFile? in
            let url = root.appendingPathComponent(PersonalLibraryTrashStore.fileName)
            if !FileManager.default.fileExists(atPath: url.path) { return nil }
            return try PersonalPreviewFile(root: root, url: url, maximumBytes: 4 * 1_024 * 1_024)
        }
        guard let record = try await library.records(includingDeleted: true).first(where: { $0.id == id }) else { throw PersonalContentError.missingDocument }
        let directory = try await library.confined(root.appendingPathComponent(record.relativePath))
        let entries = try await library.recentlyDeleted()
        let direct = entries.first { $0.kind == .work && $0.projectID == id && $0.relativePath == record.relativePath && $0.contentKind == record.kind }
        let parents = entries.filter { $0.kind == .folder && record.folders.starts(with: $0.relativePath.split(separator: "/").map(String.init)) }
        if record.kind == .biology { try BiologyOriginalBinding.verify(id: id, directory: directory) }
        let token = try await personalPreviewOffMain {
            let file = try PersonalPreviewFile(root: root, url: directory.appendingPathComponent("FloeProject.json"), maximumBytes: 64 * 1_024)
            let bytes = try file.data(), stored = try JSONDecoder().decode(PersonalContentRecord.self, from: bytes)
            guard stored.id == id, stored.kind == record.kind, stored.schemaVersion == 1 else { throw PersonalContentError.invalidProject }
            var information = stat()
            guard lstat(directory.path, &information) == 0, (information.st_mode & S_IFMT) == S_IFDIR else { throw PersonalContentError.changedDocument }
            let directoryIdentity = "\(information.st_dev):\(information.st_ino)"
            // The existing atomic trash-index identity is also a lifecycle
            // epoch: delete -> restore cannot make an old delete pin valid again.
            if let trashEpoch { try trashEpoch.validate() }
            else if FileManager.default.fileExists(atPath: root.appendingPathComponent(PersonalLibraryTrashStore.fileName).path) { throw PersonalContentError.changedDocument }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let pin = try encoder.encode(StudioLibraryIdentityPin(record: record, manifestSHA256: previewHash(bytes),
                directoryIdentity: directoryIdentity, trashEpoch: trashEpoch?.identity.token, direct: direct,
                parents: parents.sorted { $0.id.uuidString < $1.id.uuidString }))
            try file.validate(); return previewHash(pin)
        }
        if checkAvailability { try PersonalLibraryFileActions.requireAvailable(id) }
        return .init(record: record, item: .init(projectID: id, kind: record.kind, title: record.title, folders: record.folders,
            modifiedAt: record.modifiedAt, deletedAt: record.deletedAt, identity: token, trashEntryID: direct?.id,
            restoreRequiresParentFolder: !parents.isEmpty, needsRecovery: record.needsRecovery))
    }
}

extension StudioCoordinator {
    func nativeLibrary(_ input: StudioLibraryInput, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environment else { throw PersonalContentError.storageUnavailable }
        let names: Set<String> = [StudioLibraryTool.name]
        let conversation = try await self.conversation(context, allowedNames: names), authority = try access.get()
        if input.isMutation, context.approvalGrantID == nil { throw FloeError.validationFailed("The task's existing approval grant is required for delete or restore") }
        let ids = Set(try await authority.projectIDs(conversationID: conversation))
        return try await StudioLibraryActions.perform(input, environment: environment, authorizedIDs: ids, context: context,
            authorize: { @MainActor id, editing in
                guard try await self.conversation(context, allowedNames: names) == conversation else { throw PersonalContentError.changedDocument }
                if let id, !(try await authority.canAccess(conversationID: conversation, projectID: id, editing: editing)) {
                    throw FloeError.validationFailed("This task has no binding to that native work")
                }
            })
    }
}

struct StudioLibraryTool: AgentTool {
    typealias Arguments = StudioLibraryInput
    static let name = "studio.library"
    static let toolDescription = "List/detail native Personal Library works already authorized to this task, or inspect Recently Deleted. Native projectID is not a workspace path. Actions list/recentlyDeleted accept offset/limit; detail requires projectID. To recoverably delete, first read detail then delete {projectID,expectedIdentity:item.identity}; restore requires that deleted detail's exact projectID, expectedIdentity and trashEntryID. Only a work tombstone is restored; a deleted containing folder must be restored in Files first. Existing editor/save/service/Biology barriers apply. No permanent delete, path argument, global selection or expansion of project authority. Delete/restore retain the ordinary destructive approval policy."
    static let parametersJSON = #"{"type":"object","additionalProperties":false,"required":["action"],"properties":{"action":{"type":"string","enum":["list","detail","recentlyDeleted","delete","restore"]},"projectID":{"type":"string","format":"uuid"},"expectedIdentity":{"type":"string","pattern":"^[a-f0-9]{64}$"},"trashEntryID":{"type":"string","format":"uuid"},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64}}}"#
    static let riskLabels: Set<RiskLabel> = [.deletesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    static let requiresHostScope = false
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    let coordinator: StudioCoordinator
    func validate(_ args: Arguments) throws { try args.validate() }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try args.validate()
        if !args.isMutation { return try await coordinator.nativeLibrary(args, context: context) }
        let worker = Task { try await coordinator.nativeLibrary(args, context: context) }
        let monitor = Task {
            while !Task.isCancelled {
                if context.cancellation.isCancelled { worker.cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        defer { monitor.cancel() }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
#endif
