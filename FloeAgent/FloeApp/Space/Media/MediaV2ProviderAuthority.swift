// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkbench

/// Native-issued authority for one provider capability and original revision.
/// It cannot be decoded from a tool payload, a document or a provider result.
@MainActor struct MediaV2ProviderAuthority: Sendable {
    typealias Capability = MediaV2ProviderBridge.Capability
    static let toolName = "studio.media.provider"
    let projectID: UUID
    let revision: Int64
    private let capability: Capability
    private let validateOriginal: @MainActor @Sendable () async throws -> Void

    private init(projectID: UUID, revision: Int64, capability: Capability,
                 validateOriginal: @escaping @MainActor @Sendable () async throws -> Void) {
        self.projectID = projectID; self.revision = revision; self.capability = capability
        self.validateOriginal = validateOriginal
    }

    static func capability(for toolID: String) -> Capability? {
        switch toolID {
        case "image.inpaint", "image.outpaint": .imageEditing
        case "video.transcribe": .transcription
        case "video.translate": .translation
        case "video.voice-separate": .stemSeparation
        default: nil
        }
    }

    func authorize(capability: Capability, projectID: UUID, revision: Int64) async throws {
        try Task.checkCancellation()
        guard self.projectID == projectID, self.revision == revision,
              self.capability == capability else { throw MediaPreparedCoreError.documentChanged }
        try await validateOriginal()
        try Task.checkCancellation()
    }

    static func taskTool(coordinator: StudioCoordinator, context: ToolContext,
                         projectID: UUID, revision: Int64, toolID: String) async throws -> Self {
        guard context.executionToolName == toolName,
              context.allowedToolNames?.contains(toolName) == true,
              context.frozenEffectiveCatalogNames?.contains(toolName) == true,
              context.approvalGrantID != nil, context.approvalOrigin != nil,
              let capability = capability(for: toolID), let environment = coordinator.environment,
              let run = try await environment.runStore.run(id: context.runID),
              let binding = run.executionBinding,
              binding.generation == context.executionBindingGeneration,
              binding.target.environmentID == context.environmentID else {
            throw FloeError.validationFailed("Use the approved studio.media.provider call for provider-backed media edits")
        }
        let names: Set<String> = [toolName]
        let original = try await coordinator.location(projectID, context: context, editing: true, allowedNames: names)
        guard [.image, .drawing, .video].contains(original.record.kind) else { throw PersonalContentError.invalidProject }
        let root = PersonalMediaFactory.mediaRoot(directory: original.url)
        let store = MediaProjectStore(directory: root.appendingPathComponent("Projects", isDirectory: true))
        let authority = Self(projectID: projectID, revision: revision, capability: capability) {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let current = try await coordinator.location(projectID, context: context, editing: true, allowedNames: names)
            guard current.url == original.url, current.record.kind == original.record.kind,
                  let activeRun = try await environment.runStore.run(id: context.runID),
                  activeRun.executionBinding == binding else { throw PersonalContentError.changedDocument }
            let policy = try await SQLiteWorkspaceStore(database: environment.database).taskPolicy(conversationID: activeRun.conversationID)
            guard policy.networkAllowed != false,
                  policy.allowedToolNames?.contains(toolName) != false else {
                throw FloeError.validationFailed("This task does not currently permit the provider media operation")
            }
            try await verify(store: store, projectID: projectID, revision: revision)
        }
        try await authority.authorize(capability: capability, projectID: projectID, revision: revision)
        return authority
    }

    /// Only the .user branch of an explicit native Apply action uses this.
    /// A .model branch must receive taskTool authority and never falls back.
    static func userAction(session: MediaV2Session, capability: Capability) async throws -> Self {
        let projectID = session.id, revision = session.document.revision
        let authority = Self(projectID: projectID, revision: revision, capability: capability) { [weak session] in
            guard let session, session.id == projectID, session.document.revision == revision else {
                throw MediaPreparedCoreError.documentChanged
            }
            try PersonalLibraryFileActions.requireAvailable(projectID)
            try await verify(store: session.store, projectID: projectID, revision: revision)
        }
        try await authority.authorize(capability: capability, projectID: projectID, revision: revision)
        return authority
    }

    private static func verify(store: MediaProjectStore, projectID: UUID, revision: Int64) async throws {
        guard let project = try await store.loadProject(id: projectID), project.id == projectID,
              project.prepared?.revision == revision else { throw MediaPreparedCoreError.documentChanged }
        try MediaPreparedIntegrity.validateEnvelope(project)
    }
}
#endif
