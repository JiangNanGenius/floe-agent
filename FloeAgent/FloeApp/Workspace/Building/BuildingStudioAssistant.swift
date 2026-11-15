// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeBuildingEditor
import FloeBuildingRecords
import FloeBuildingWorkspace
import FloeCore
import FloeTools

/// The existing studio conversation lifecycle needs an original's identity and
/// title. Verification still runs against that original's own repository.
@MainActor enum StudioAssistantDocument: Identifiable {
    case personal(PersonalContentRecord)
    case building(BuildingStudioMount)
    nonisolated var id: UUID { switch self { case .personal(let p): p.id; case .building(let p): p.id } }
    var title: String { switch self { case .personal(let p): p.title; case .building(let p): p.title } }
    var isMeeting: Bool { if case .personal(let p) = self { return p.kind == .meeting }; return false }
}

@MainActor final class BuildingStudioMount: Identifiable {
    nonisolated let id: UUID
    let title: String
    let context: BuildingEditorToolContext
    let openedAt = Date()
    fileprivate let presenterID: UUID
    fileprivate var retiring = false
    fileprivate var retired = false
    fileprivate var retirement: Task<Void, Error>?

    fileprivate init(id: UUID, title: String, presenterID: UUID, context: BuildingEditorToolContext) {
        self.id = id; self.title = title; self.presenterID = presenterID; self.context = context
    }
    fileprivate var isCurrent: Bool { !retiring && (try? context.nativeDocument) != nil }
}

struct BuildingStudioReference: Encodable {
    let id: UUID
    let title: String
    let kind = "building"
}

@MainActor final class BuildingStudioRegistry {
    private var mounts: [UUID: BuildingStudioMount] = [:]

    var activeIDs: Set<UUID> { Set(mounts.values.filter(\.isCurrent).map(\.id)) }
    func current(_ id: UUID) -> BuildingStudioMount? { mounts[id].flatMap { $0.isCurrent ? $0 : nil } }

    func attach(_ context: BuildingEditorToolContext, directory: URL, presenterID: UUID) throws -> BuildingStudioMount {
        let drawing = try context.nativeDocument
        let parts = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let location = parts.starts(with: home) ? "home/" + parts.dropFirst(home.count).joined(separator: "/") : directory.resolvingSymlinksInPath().standardizedFileURL.path
        // A personal record owns one assistant identity even if the package is
        // copied to another path. CAD-entry projects keep the location-bound
        // identity so two independent CAD documents cannot share a mount.
        let id = context.spaceRecordID
            ?? AppDesignResultPublicationPort.deterministicUUID("floe.building.assistant|\(context.projectID)|\(location)")
        if let previous = mounts[id] {
            guard previous.presenterID == presenterID, previous.isCurrent else { throw PersonalFileAssistantLifecycleError.stopping }
            return previous
        }
        let mount = BuildingStudioMount(id: id, title: drawing.name, presenterID: presenterID, context: context)
        mounts[id] = mount
        return mount
    }

    func verify(_ mount: BuildingStudioMount) throws {
        guard current(mount.id) === mount else { throw PersonalFileAssistantLifecycleError.changed }
    }

    func remove(_ mount: BuildingStudioMount) {
        if mounts[mount.id] === mount { mounts[mount.id] = nil }
        mount.retired = true
    }
}

extension StudioCoordinator {
    /// Fence synchronously, including surprise dismissal. Normal Save/Close or
    /// Reopen waits for the existing run-stop lease before replacing the mount.
    func retireBuildingAssistant(_ mount: BuildingStudioMount) -> Task<Void, Error> {
        if mount.retired { return Task {} }
        if let retirement = mount.retirement { return retirement }
        mount.retiring = true
        let task = Task { @MainActor in
            defer { mount.retirement = nil }
            await settleAssistantPreparation(for: mount.id)
            guard let environment else { throw PersonalContentError.storageUnavailable }
            if let id = try await access.get().assistant(projectID: mount.id) {
                let lease = try await environment.conversationCenter.stopEditorAssistant(conversationID: id, expectedOwner: .file(mount.id))
                lease.finish()
            }
            buildingProjects.remove(mount)
        }
        mount.retirement = task
        return task
    }

    func authorizedBuilding(_ mount: BuildingStudioMount, context: ToolContext, editing: Bool) async throws {
        let conversationID = try await conversation(context, allowedNames: [editing ? "studio.edit" : "studio.read"])
        let authority = try access.get()
        guard let environment, let run = try await environment.runStore.run(id: context.runID),
              run.startedAt >= mount.openedAt,
              try await environment.conversationStore.conversation(id: conversationID)?.editorOwnership == .file(mount.id),
              try await authority.assistantProject(conversationID: conversationID) == mount.id,
              try await authority.canAccess(conversationID: conversationID, projectID: mount.id, editing: editing),
              !editing || context.approvalGrantID != nil else { throw FloeError.unauthorized }
        try await requireAssistantAvailable(conversationID: conversationID)
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try buildingProjects.verify(mount)
    }
}
#endif
