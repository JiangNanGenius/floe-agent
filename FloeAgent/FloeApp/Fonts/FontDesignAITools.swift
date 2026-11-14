// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeFontKit
import FloeHeavyEditorSupport
import FloeHeavyEditorsHostAdapter

/// A process service, with no presenter or visible WK view. Every invocation
/// receives a separate controller and task-bound lease of the same durable
/// FontDesign original. Settings windows keep their own UI coordinators.
@MainActor final class FontDesignAIHost {
    static let names: Set<String> = ["font.create", "font.describe", "font.query", "font.invoke", "font.import", "font.export"]
    private weak var environment: AppEnvironment?
    private let library = FontDesignLibrary.shared
    private var access: StudioDocumentAccess?
    private var preparing: [UUID: Task<UUID, Error>] = [:]
    private var deletingDesigns = Set<UUID>()
    init(environment: AppEnvironment) { self.environment = environment }

    lazy var bridge = HeavyEditorToolBridge(
        grant: { [weak self] context in guard let self else { throw FontDesignError.unavailable }; return try await self.grant(context) },
        open: { [weak self] id, action, context, authorize in
            guard let self else { throw FontDesignError.unavailable }
            return try await self.open(id, action: action, context: context, authorize: authorize)
        },
        create: { [weak self] request, context, authorize in
            guard let self else { throw FontDesignError.unavailable }
            return try await self.create(request, context: context, authorize: authorize)
        },
        resolveFile: { [weak self] fileID, context in
            guard let self, let environment = await self.environment else { throw FontDesignError.unavailable }
            return try await HeavyEditorTaskFileResolver.resolve(fileID, context: context, environment: environment,
                allowedExtensions: ["ttf", "otf", "woff", "woff2", "ufo", "designspace", "zip", "svg", "floefont"],
                maximumBytes: 128 * 1024 * 1024, validate: { try await self.require(context, designID: nil, editing: false) })
        })

    func register() throws { try bridge.register(kinds: [.font]) }
    func typedServiceStorePaths() async throws -> [String: String] {
        [TypedMutationContract.nativeFontLibraryStoreKey: try await library.containerDirectory().path]
    }
    private func authority() async throws -> StudioDocumentAccess {
        if let access { return access }
        let value = try StudioDocumentAccess(root: await library.taskAuthorityDirectory())
        access = value; return value
    }
    private func grant(_ context: ToolContext) async throws -> HeavyEditorTaskGrant {
        guard let environment else { throw FontDesignError.unavailable }
        let conversationID = try await environment.studioCoordinator.savedConversation(context)
        let ids = Set(try await authority().projectIDs(conversationID: conversationID))
        let actual = Set(try await library.list().map(\.id))
        return .init(enabledKinds: [.font], projects: ids.intersection(actual), canCreate: true, readOnly: false)
    }
    private func require(_ context: ToolContext, designID: UUID?, editing: Bool) async throws {
        guard let environment else { throw FontDesignError.unavailable }
        let conversationID = try await environment.studioCoordinator.conversation(context, allowedNames: Self.names)
        let root = try await library.containerDirectory().standardizedFileURL.resolvingSymlinksInPath().path
        guard context.serviceStorePaths[TypedMutationContract.nativeFontLibraryStoreKey] == root else { throw HeavyEditorError.wrongDocument }
        if let designID {
            guard try await authority().canAccess(conversationID: conversationID, projectID: designID, editing: editing) else { throw HeavyEditorError.wrongDocument }
            _ = try await library.project(designID)
        }
        try Task.checkCancellation(); try context.cancellation.throwIfCancelled()
    }
    private func create(_ request: HeavyEditorCreationRequest, context: ToolContext,
                        authorize: @escaping HeavyEditorCallAuthorization) async throws -> UUID {
        guard request.kind == .font, let conversationID = context.conversationID else { throw HeavyEditorError.wrongDocument }
        try await require(context, designID: nil, editing: true); try await authorize()
        let authority = try await authority()
        let digest = FontDesignLibrary.digest(try EditorJSON.array([.string("font"), .string(request.title)]).data())
        let id = try await authority.reserveCreation(operationKey: "font:\(conversationID.uuidString):\(request.requestID)", digest: digest)
        _ = try await library.createForTask(id: id, title: request.title, authorize: { [self] in
            try await self.require(context, designID: nil, editing: true); try await authorize()
        })
        try await require(context, designID: nil, editing: true); try await authorize()
        try await authority.finishCreation(conversationID: conversationID, projectID: id)
        return id
    }
    private func open(_ id: UUID, action: HeavyEditorToolAction, context: ToolContext,
                      authorize: @escaping HeavyEditorCallAuthorization) async throws -> HeavyEditorToolLease {
        try await require(context, designID: id, editing: !action.isReadOnly); try await authorize()
        // A read never initializes/imports a pending UI source. Settings must
        // finish that explicit source edit before the assistant can inspect it.
        if let _ = try await library.sourceForImport(id) { throw FontDesignError.invalidProject }
        let directory = try await library.directory(for: id)
        let scope = FontDesignAIScope(designID: id, library: library)
        let hooks = HeavyEditorHostHooks(authorize: { [self] request in
            try await authorize(); try await require(context, designID: id, editing: request.access != .read)
            try await scope.authorize(request)
        }, didSave: { _ in }, export: { [self] documentID, artifact in
            try await scope.export(documentID: documentID, artifact: artifact, authorize: {
                try await authorize(); try await self.require(context, designID: id, editing: true)
            })
        })
        let controller = try await FontWorkbench.open(directory: directory, documentID: id, owner: .fontLibrary(id), hooks: hooks)
        do { try await controller.waitUntilReady() }
        catch { await controller.endPresentation(); throw error }
        let model = HeavyEditorModelLease(controller: controller, authorize: { [self] request in
            try await require(context, designID: id, editing: request.access != .read)
            try await library.authorize(request, designID: id)
        }, release: { await controller.endPresentation() })
        return HeavyEditorToolLease(model: model, complete: { [self] result, realContext in
            try await authorize(); try await require(realContext, designID: id, editing: !action.isReadOnly)
            let revision = await controller.document.revision
            try await library.requireRevision(designID: id, revision: revision)
            var outputs: [RunOutputFile] = [], links: [EditorJSON] = []
            for (index, receipt) in result["exports"].array.enumerated() {
                guard let fileID = receipt["fileID"].string else { throw FontDesignError.invalidOutput }
                let item = try await library.verifiedOutput(designID: id, fileID: fileID, sourceRevision: revision)
                guard item.output.receipt.sha256 == receipt["sha256"].string,
                      item.output.receipt.byteCount == Int(receipt["byteCount"].number ?? -1) else { throw FontDesignError.invalidOutput }
                try await authorize(); try await require(realContext, designID: id, editing: true)
                let request = RunOutputSnapshotRequest(producerTool: "font.export", slot: "font-\(index)",
                    commit: .init(sourceURL: item.url, sha256: item.output.receipt.sha256, byteCount: item.output.receipt.byteCount,
                        displayName: item.output.receipt.name, mimeType: item.output.mediaType,
                        uti: UTType(filenameExtension: item.url.pathExtension)?.identifier))
                let output = try await personalPreviewOffMain { try RunOutputSnapshotStore.publish(request, using: realContext) }
                try await authorize(); try await require(realContext, designID: id, editing: true)
                guard case .verified = RunOutputSnapshotStore.verify(output) else { throw FontDesignError.invalidOutput }
                outputs.append(output)
                links.append(.object(["managedFileID": .string(fileID), "fileID": .string("output:\(output.runID.uuidString):\(output.outputID)"),
                    "sha256": .string(output.sha256), "byteCount": .number(Double(output.byteCount)), "name": .string(output.displayName)]))
            }
            var value = result.object
            if !links.isEmpty { value["exports"] = .array(links) }
            if action == .describe, let environment = await self.environment {
                value["inputs"] = try await HeavyEditorTaskFileResolver.inventory(context: realContext, environment: environment,
                    allowedExtensions: ["ttf", "otf", "woff", "woff2", "ufo", "designspace", "zip", "svg", "floefont"], validate: {
                        try await self.require(realContext, designID: id, editing: false)
                    })
            }
            let text = try EditorJSON.object(value).text()
            return ToolExecutionOutput(digesting: text, exitStatus: 0, outputFiles: outputs, capturedOutput: text)
        })
    }

    /// Settings is the native binding source. This does not create a Space
    /// record or share its selection/undo/controller with another window.
    func assistant(for designID: UUID) async throws -> UUID {
        guard !deletingDesigns.contains(designID) else { throw FontDesignError.invalidProject }
        if let task = preparing[designID] { return try await task.value }
        let task = Task { @MainActor [self] in try await prepareAssistant(designID) }
        preparing[designID] = task; defer { preparing[designID] = nil }
        return try await task.value
    }

    /// Uses ConversationCenter's existing stop/join fence. The durable library
    /// intent lets the same cleanup finish after an interruption, without
    /// reviving the draft or touching a separately installed font.
    func removeDesign(_ project: FontDesignProject) async throws {
        guard deletingDesigns.insert(project.id).inserted else { throw FontDesignError.unavailable }
        defer { deletingDesigns.remove(project.id) }
        if let task = preparing[project.id] { task.cancel(); _ = try? await task.value }
        guard let environment else { throw FontDesignError.unavailable }
        let access = try await authority()
        let assistantID = try await access.assistant(projectID: project.id)
        let bindings = assistantID.map { [StudioAssistantBinding(projectID: project.id, conversationID: $0)] } ?? []
        let lease = try await environment.conversationCenter.stopFileAssistants(bindings)
        defer { lease.finish() }
        let intent = try await library.stageDeletion(project, assistantID: assistantID)
        try await finishRemoval(intent, access: access, lease: lease, environment: environment)
    }

    func resumePendingDeletions() async throws {
        guard let environment else { throw FontDesignError.unavailable }
        for intent in try await library.pendingDeletions() where deletingDesigns.insert(intent.designID).inserted {
            defer { deletingDesigns.remove(intent.designID) }
            let access = try await authority()
            let current = try await access.assistant(projectID: intent.designID)
            guard current == nil || current == intent.assistantID else { throw FontDesignError.invalidProject }
            let bindings = intent.assistantID.map { [StudioAssistantBinding(projectID: intent.designID, conversationID: $0)] } ?? []
            let lease = try await environment.conversationCenter.stopFileAssistants(bindings)
            defer { lease.finish() }
            try await finishRemoval(intent, access: access, lease: lease, environment: environment)
        }
    }

    private func finishRemoval(_ intent: FontDesignDeletion, access: StudioDocumentAccess,
                               lease: PersonalFileAssistantStopLease, environment: AppEnvironment) async throws {
        if let id = intent.assistantID {
            try await environment.conversationCenter.deleteConversation(id: id, fileLifecycleToken: lease.id,
                includeEditorHistory: false)
            try await access.finishPurgedAssistant(.init(projectID: intent.designID, conversationID: id))
        }
        try await access.revokeDeletedFontAuthority(projectID: intent.designID)
        try await library.finishDeletion(intent)
        StorageDiagnosticService.shared.invalidate(.other("fontStore"))
    }
    private func prepareAssistant(_ designID: UUID) async throws -> UUID {
        guard let environment else { throw FontDesignError.unavailable }
        try await environment.ensureDurableAutomationReady()
        let project = try await library.project(designID), authority = try await authority()
        let workspace = SQLiteWorkspaceStore(database: environment.database)
        let id: UUID
        if let bound = try await authority.assistant(projectID: designID),
           let existing = try await environment.conversationStore.conversation(id: bound), existing.purpose == .ordinary {
            id = bound
        } else {
            id = UUID(); let now = Date()
            do {
                try await environment.conversationStore.saveConversation(.init(id: id,
                    title: FontDesignText.t("字体助手 · ", "Typeface assistant · ") + project.title,
                    createdAt: now, updatedAt: now, titleOrigin: .manual))
                _ = try await workspace.ensureWorkspace(conversationID: id, title: project.title)
                try await authority.bindAssistant(conversationID: id, projectID: designID)
            } catch { try? await environment.conversationStore.deleteConversation(id: id); throw error }
        }
        _ = try await workspace.ensureWorkspace(conversationID: id, title: project.title)
        try await environment.conversationStore.setArchived(id: id, archived: true)
        await environment.conversationCenter.authoringConversationBecameVisible(id)
        try await workspace.saveTaskPolicy(.init(conversationID: id, approvalMode: TaskApprovalMode.automatic.rawValue,
            networkAllowed: true, browserControlAllowed: false, uploadAllowed: false, credentialsAllowed: false, remoteExecutionAllowed: false))
        environment.conversationCenter.taskPolicyDidChange(conversationID: id)
        return id
    }
}

private actor FontDesignAIScope {
    let designID: UUID
    let library: FontDesignLibrary
    var exportRevision: UInt64?
    init(designID: UUID, library: FontDesignLibrary) { self.designID = designID; self.library = library }
    func authorize(_ request: HeavyEditorAccessRequest) async throws {
        try await library.authorize(request, designID: designID)
        if request.access == .exportFile { exportRevision = request.revision }
    }
    func export(documentID: UUID, artifact: HeavyEditorArtifact,
                authorize: @escaping HeavyEditorCallAuthorization) async throws -> HeavyEditorExportReceipt {
        guard documentID == designID, let exportRevision else { throw HeavyEditorError.wrongDocument }
        return try await library.export(designID: designID, sourceRevision: exportRevision, artifact: artifact, authorize: authorize)
    }
}
#endif
