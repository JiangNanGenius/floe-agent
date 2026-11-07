// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeEnvironments
import FloeBiologyCore
import FloeBiologyEngine
import FloeBiologyHostAdapter

/// Native-original checks and real task grants remain separate. Native UI
/// receives its mounted original; model calls additionally need the persisted
/// Studio grant, actual owning run, and the effective runtime tool ceiling.
@MainActor final class BiologyHostAccess {
    private weak var environment: AppEnvironment?
    let authority: StudioDocumentAccess
    private let runs: any RunStore
    private let conversations: any ConversationStore
    private let environments: EnvironmentRegistry?
    private let libraryProvider: @MainActor @Sendable () async throws -> PersonalContentLibrary
    private let libraryRoot: URL?
    private struct MetadataSync {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var metadataSync: [UUID: MetadataSync] = [:]
    convenience init(environment: AppEnvironment) throws {
        try self.init(runs: environment.runStore, conversations: environment.conversationStore,
            authority: environment.studioCoordinator.access.get(), environments: environment.environmentRegistry)
        self.environment = environment
    }
    init(runs: any RunStore, conversations: any ConversationStore, authority: StudioDocumentAccess,
         environments: EnvironmentRegistry? = nil, libraryRoot: URL? = nil,
         library: @escaping @MainActor @Sendable () async throws -> PersonalContentLibrary = { try await PersonalContentService.shared.library() }) {
        self.runs = runs; self.conversations = conversations; self.authority = authority
        self.environments = environments; self.libraryProvider = library; self.libraryRoot = libraryRoot
    }
    func app() throws -> AppEnvironment {
        guard let environment else { throw BiologyHostError.unavailable }
        return environment
    }
    func location(_ id: UUID) async throws -> (record: PersonalContentRecord, url: URL) {
        try PersonalLibraryFileActions.requireAvailable(id)
        let value = try await libraryProvider().resolve(id)
        guard value.record.kind.rawValue == "biology", value.record.id == id else { throw BiologyHostError.changed }
        try PersonalLibraryFileActions.requireAvailable(id)
        return value
    }
    func task(_ context: ToolContext, requireCall: Bool) async throws -> UUID {
        try Task.checkCancellation(); try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly, context.childExecution == nil,
              let id = context.conversationID,
              let run = try await runs.run(id: context.runID),
              run.conversationID == id, run.endedAt == nil,
              let conversation = try await conversations.conversation(id: id),
              conversation.purpose == .ordinary else { throw BiologyHostError.unavailable }
        if requireCall {
            guard let name = context.executionToolName, name.hasPrefix("biology."),
                  context.allowedToolNames?.contains(name) != false,
                  context.frozenEffectiveCatalogNames?.contains(name) != false,
                  let call = context.toolCallID, !call.isEmpty else { throw BiologyHostError.changed }
        }
        try context.cancellation.throwIfCancelled()
        return id
    }
    func grant(_ context: ToolContext) async throws -> BiologyTaskGrant {
        let taskID = try await task(context, requireCall: context.executionToolName?.hasPrefix("biology.") == true)
        let ids = Set(try await authority.projectIDs(conversationID: taskID))
        let records = try await libraryProvider().records(includingDeleted: true)
        let biology = Set(records.filter { $0.kind.rawValue == "biology" && ids.contains($0.id) }.map(\.id))
        // Mixed read/write projects are checked per-target at dispatch below.
        // A writable sibling must never turn a read-only original writable.
        var writable = false
        for id in biology where !writable { writable = try await authority.canAccess(conversationID: taskID, projectID: id, editing: true) }
        let readOnly = !writable && !biology.isEmpty
        return .init(projects: biology, canCreate: !readOnly, readOnly: readOnly)
    }
    func validateTargets(_ value: BiologyJSON, name: String, context: ToolContext) async throws -> Set<UUID> {
        let taskID = try await task(context, requireCall: true)
        var ids = Set<UUID>()
        for key in ["projectID", "sourceProjectID"] {
            guard let raw = value[key]?.string else { continue }
            guard let id = UUID(uuidString: raw),
                  try await authority.canAccess(conversationID: taskID, projectID: id,
                    editing: key == "projectID" && !BiologyToolSchemas.readOnlyNames.contains(name)) else { throw BiologyHostError.readOnly }
            ids.insert(id)
        }
        if ["biology.create", "biology.importProject"].contains(name), context.approvalGrantID == nil {
            throw FloeError.validationFailed("The task's existing creation approval is required")
        }
        try context.cancellation.throwIfCancelled()
        return ids
    }
    func permit(_ access: BiologyAccess) async throws {
        let scope = BiologyHostOperation.scope
        if access.projectID == nil {
            switch access.action {
            case .create: guard scope?.canCreate == true else { throw BiologyHostError.readOnly }
            case .list: guard scope != nil else { throw BiologyHostError.unavailable }
            case .edit: guard scope?.recoveringNativeWorkers == true else { throw BiologyHostError.unavailable }
            default: throw BiologyHostError.unavailable
            }
            return
        }
        guard let id = access.projectID else { throw BiologyHostError.unavailable }
        if let scope, !scope.recoveringNativeWorkers, !scope.projects.contains(id) { throw BiologyHostError.readOnly }
        if scope?.lifecycle == true || access.action == .restore {
            let records = try await libraryProvider().records(includingDeleted: true)
            guard records.contains(where: { $0.id == id && $0.kind.rawValue == "biology" }) else { throw BiologyHostError.changed }
        } else { _ = try await location(id) }
    }
    func acquire(_ ids: Set<UUID>) async throws -> [PersonalLibraryUsageLease] {
        var leases: [PersonalLibraryUsageLease] = []
        do {
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                let value = try await location(id)
                leases.append(try PersonalLibraryFileActions.acquireUse(id: id, directory: value.url, libraryRoot: libraryRoot))
            }
            return leases
        } catch { for lease in leases { lease.release() }; throw error }
    }
    /// A derived Library projection of the canonical native commit. Serial
    /// per original, reread after each write, and protected by the SAME usage
    /// barrier as every other File operation. It cannot become document or
    /// execution authority and never changes a wrapper's identity/location.
    func synchronizeMetadata(_ ids: Set<UUID>, store: BiologyProjectStore) async throws {
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            while let prior = metadataSync[id] {
                _ = try? await prior.task.value
                if metadataSync[id]?.id == prior.id { metadataSync[id] = nil }
            }
            let operationID = UUID()
            let task = Task { @MainActor [self] in
                let value = try await location(id)
                let lease = try PersonalLibraryFileActions.acquireUse(id: id, directory: value.url, libraryRoot: libraryRoot)
                defer { lease.release() }
                let library = try await libraryProvider()
                for _ in 0..<4 {
                    try Task.checkCancellation()
                    let project = try await store.load(id)
                    let current = try await library.resolve(id)
                    guard current.record.kind == .biology else { throw BiologyHostError.changed }
                    try BiologyOriginalBinding.verify(id: id, directory: current.url)
                    if current.record.title != project.title || current.record.modifiedAt < project.modifiedAt {
                        try await library.markChanged(id, title: project.title)
                    }
                    if try await store.load(id).revision == project.revision { return }
                }
                throw BiologyHostError.changed
            }
            metadataSync[id] = MetadataSync(id: operationID, task: task)
            do {
                try await task.value
                if metadataSync[id]?.id == operationID { metadataSync[id] = nil }
            } catch {
                if metadataSync[id]?.id == operationID { metadataSync[id] = nil }
                throw error
            }
        }
    }
    func fileEnvironment(_ context: BiologyFileContext, writing: Bool) async throws -> String {
        _ = try await location(context.projectID)
        guard let owner = context.owner else { return "native.local" }
        guard let run = try await runs.run(id: owner.hostRunID),
              run.conversationID == owner.taskID,
              try await authority.canAccess(conversationID: owner.taskID, projectID: context.projectID, editing: writing),
              let binding = run.executionBinding, let environments, let record = await environments.record(id: binding.target.environmentID),
              record.state != .deleting, !record.requiresRebuild, record.pendingRuntimeResetID == nil else { throw BiologyHostError.changed }
        return binding.target.environmentID
    }
}
#endif
