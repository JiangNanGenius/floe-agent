#if canImport(UIKit)
import Foundation
import Crypto
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeTools

extension Notification.Name {
    static let floeCanvasProjectDidChange = Notification.Name("floe.canvas.project.didChange")
}

actor FileCanvasDocumentRepository: CanvasDocumentRepository {
    func project(canvasID: UUID) async throws -> CanvasProject {
        let url = try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: false)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try CanvasProjectCodec.decode(
            Data(contentsOf: url), fallbackID: canvasID, decoder: decoder
        )
    }

    func save(_ project: CanvasProject, expectedRevision: Int64) async throws {
        let url = try WorkspaceCanvasRegistry.projectURL(canvasID: project.id, createDirectory: false)
        let current = try await self.project(canvasID: project.id)
        guard current.revision == expectedRevision else {
            throw FloeError.validationFailed(
                "Canvas revision conflict: expected \(expectedRevision), current \(current.revision)"
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CanvasProjectCodec.encode(project, encoder: encoder).write(to: url, options: .atomic)
    }
}

actor CanvasToolCoordinator {
    private let repository: any CanvasDocumentRepository
    private let assetStore: CreativeAssetStore
    private let jobs: MediaGenerationJobStore
    private let conversationIDForRun: @Sendable (UUID) async throws -> UUID?
    private let generateImage: @Sendable (String, ImageGenerationOptions) async throws -> CanvasAssetReference
    private let submitVideo: @Sendable (
        UUID, UUID, UUID, [UUID], UUID, RemoteVideoRequest
    ) async throws -> MediaGenerationJob

    init(
        repository: any CanvasDocumentRepository,
        assetStore: CreativeAssetStore,
        jobs: MediaGenerationJobStore,
        conversationIDForRun: @escaping @Sendable (UUID) async throws -> UUID?,
        generateImage: @escaping @Sendable (String, ImageGenerationOptions) async throws -> CanvasAssetReference,
        submitVideo: @escaping @Sendable (
            UUID, UUID, UUID, [UUID], UUID, RemoteVideoRequest
        ) async throws -> MediaGenerationJob
    ) {
        self.repository = repository; self.assetStore = assetStore; self.jobs = jobs
        self.conversationIDForRun = conversationIDForRun
        self.generateImage = generateImage; self.submitVideo = submitVideo
    }

    func project(for runID: UUID) async throws -> CanvasProject {
        guard let conversationID = try await conversationIDForRun(runID) else {
            throw FloeError.validationFailed("Canvas run has no owning conversation")
        }
        for summary in WorkspaceCanvasRegistry.summaries() {
            let project = try await repository.project(canvasID: summary.id)
            let sessionConversationIDs = Set(project.assistantSessions.map(\.conversationID))
            if project.agentConversationID == conversationID
                || sessionConversationIDs.contains(conversationID) {
                return project
            }
        }
        throw FloeError.validationFailed("This run is not bound to a canvas")
    }

    func inspect(runID: UUID, documentID: UUID?, selectedNodeIDs: [UUID]) async throws -> CanvasContextSnapshot {
        let activeProject = try await project(for: runID)
        return try CanvasCommandService.snapshot(
            project: activeProject,
            documentID: documentID,
            selectedNodeIDs: selectedNodeIDs
        )
    }

    func apply(runID: UUID, patch: CanvasPatch) async throws -> CanvasOperationResult {
        let current = try await project(for: runID)
        guard current.id == patch.canvasID else {
            throw FloeError.validationFailed("The run cannot modify a different canvas")
        }
        let (updated, result) = try CanvasCommandService.applying(patch, to: current)
        try persistUndoSnapshot(current, token: result.undoToken)
        try await repository.save(updated, expectedRevision: current.revision)
        await notify(canvasID: current.id)
        return result
    }

    func searchAssets(query: String?, kinds: Set<MediaKind>, limit: Int) async throws -> [CreativeAssetRecord] {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await assetStore.allAssets().filter { asset in
            (kinds.isEmpty || kinds.contains(asset.kind))
                && (needle.map { search in
                    search.isEmpty
                        || asset.displayName.lowercased().contains(search)
                        || asset.tags.contains(where: { $0.lowercased().contains(search) })
                } ?? true)
        }.prefix(max(1, min(limit, 50))).map { $0 }
    }

    func insertAsset(
        runID: UUID, assetID: UUID, documentID: UUID?,
        position: CanvasPoint, expectedRevision: Int64
    ) async throws -> CanvasOperationResult {
        let project = try await project(for: runID)
        guard let asset = try await assetStore.asset(id: assetID) else {
            throw FloeError.validationFailed("Asset does not exist")
        }
        let targetDocumentID = documentID ?? project.selectedDocumentID
        let kind: CanvasNodeKind = switch asset.kind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .document: .file
        }
        let reference = CanvasAssetReference(
            id: asset.id, contentHash: asset.contentHash,
            localRelativePath: asset.localRelativePath,
            cloudRecordName: asset.cloudRecordName, mimeType: asset.mimeType,
            byteCount: asset.byteCount, sourceURL: asset.sourceURL,
            license: asset.license
        )
        let patch = CanvasPatch(
            canvasID: project.id, documentID: targetDocumentID,
            expectedRevision: expectedRevision,
            operations: [CanvasPatchOperation(
                kind: .create, nodeKind: kind, text: asset.displayName,
                position: position, asset: reference
            )]
        )
        let result = try await apply(runID: runID, patch: patch)
        try await assetStore.adjustReference(assetID: assetID, by: 1)
        return result
    }

    func generateImageAsset(
        runID: UUID, prompt: String, documentID: UUID?,
        position: CanvasPoint, expectedRevision: Int64,
        aspectRatio: String?
    ) async throws -> CanvasOperationResult {
        let asset = try await generateImage(prompt, ImageGenerationOptions(aspectRatio: aspectRatio))
        return try await insertAsset(
            runID: runID, assetID: asset.id, documentID: documentID,
            position: position, expectedRevision: expectedRevision
        )
    }

    func submitVideoJob(
        runID: UUID, modelID: UUID, prompt: String,
        documentID: UUID?, position: CanvasPoint,
        expectedRevision: Int64, aspectRatio: String?,
        durationSeconds: Int?
    ) async throws -> (CanvasOperationResult, MediaGenerationJob) {
        var project = try await project(for: runID)
        let targetDocumentID = documentID ?? project.selectedDocumentID
        guard let document = project.documents.first(where: { $0.id == targetDocumentID }) else {
            throw FloeError.validationFailed("Canvas document does not exist")
        }
        let resultNodeID = UUID()
        let patch = CanvasPatch(
            canvasID: project.id, documentID: targetDocumentID,
            expectedRevision: expectedRevision,
            operations: [CanvasPatchOperation(
                kind: .create, nodeID: resultNodeID, nodeKind: .generationTask,
                text: "视频生成中：\(prompt)", position: position
            )]
        )
        let result = try await apply(runID: runID, patch: patch)
        project = try await repository.project(canvasID: project.id)
        let job: MediaGenerationJob
        do {
            job = try await submitVideo(
                modelID, project.id, targetDocumentID, [], resultNodeID,
                RemoteVideoRequest(
                    prompt: prompt, modelRemoteID: "",
                    options: VideoGenerationOptions(
                        aspectRatio: aspectRatio, durationSeconds: durationSeconds
                    )
                )
            )
        } catch {
            // Keep the user's prompt and result slot recoverable, but never leave a
            // failed provider submission presented as an active remote job.
            var failed = project
            if let documentIndex = failed.documents.firstIndex(where: { $0.id == document.id }),
               let nodeIndex = failed.documents[documentIndex].nodes.firstIndex(where: { $0.id == resultNodeID }) {
                failed.documents[documentIndex].nodes[nodeIndex].text = "视频提交失败，可重试：\(prompt)"
                failed.documents[documentIndex].nodes[nodeIndex].metadata["generationState"] = "submitFailed"
                failed.revision += 1
                failed.updatedAt = Date()
                try await repository.save(failed, expectedRevision: project.revision)
                await notify(canvasID: project.id)
            }
            throw error
        }
        var update = project
        guard let documentIndex = update.documents.firstIndex(where: { $0.id == document.id }),
              let nodeIndex = update.documents[documentIndex].nodes.firstIndex(where: { $0.id == resultNodeID }) else {
            throw FloeError.storageCorrupted("Generated video node is missing")
        }
        update.documents[documentIndex].nodes[nodeIndex].generationJobID = job.id
        update.revision += 1; update.updatedAt = Date()
        try await repository.save(update, expectedRevision: project.revision)
        await notify(canvasID: project.id)
        return (result, job)
    }

    func mediaJobs(runID: UUID) async throws -> [MediaGenerationJob] {
        let activeProject = try await project(for: runID)
        return try await jobs.jobs(canvasID: activeProject.id)
    }

    private func persistUndoSnapshot(_ project: CanvasProject, token: UUID) throws {
        let canvasURL = try WorkspaceCanvasRegistry.projectURL(canvasID: project.id, createDirectory: true)
        let directory = canvasURL.deletingLastPathComponent().appendingPathComponent("Undo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try CanvasProjectCodec.encode(project, encoder: encoder).write(
            to: directory.appendingPathComponent("\(token.uuidString).json"), options: .atomic
        )
    }

    @MainActor private func notify(canvasID: UUID) {
        NotificationCenter.default.post(
            name: .floeCanvasProjectDidChange, object: nil,
            userInfo: ["canvasID": canvasID]
        )
    }
}

private enum CanvasToolOutput {
    static func make<T: Encodable>(_ value: T, status: Int32 = 0) throws -> ToolExecutionOutput {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: status)
    }
}

private struct CanvasInspectionPage: Encodable {
    struct Node: Encodable {
        var id: UUID; var kind: CanvasNodeKind; var text: String
        var position: CanvasPoint; var size: CanvasSize
        var groupID: UUID?; var isLocked: Bool; var assetID: UUID?
    }
    struct Connection: Encodable {
        var id: UUID; var sourceNodeID: UUID; var destinationNodeID: UUID
        var sourcePort: CanvasConnectionPort?; var destinationPort: CanvasConnectionPort?
        var label: String?
    }
    var canvasID: UUID; var documentID: UUID; var revision: Int64
    var viewport: CanvasViewportState; var selectedNodeIDs: [UUID]
    var nodes: [Node]; var connections: [Connection]
    var hasMoreNodes: Bool; var nextNodeCursor: UUID?
}

private struct CanvasInspectTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var documentID: UUID?; var selectedNodeIDs: [UUID]?
        var afterNodeID: UUID?; var limit: Int?
    }
    static let name = "canvas.inspect"
    static let toolDescription = "Inspect the active canvas, selected nodes and relationships before editing."
    static let parametersJSON = #"{"type":"object","properties":{"documentID":{"type":"string","format":"uuid"},"selectedNodeIDs":{"type":"array","items":{"type":"string","format":"uuid"}},"afterNodeID":{"type":"string","format":"uuid"},"limit":{"type":"integer","minimum":1,"maximum":30}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {
        if let limit = args.limit, !(1...30).contains(limit) {
            throw FloeError.validationFailed("limit must be 1...30")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let snapshot = try await coordinator.inspect(
            runID: context.runID, documentID: args.documentID,
            selectedNodeIDs: args.selectedNodeIDs ?? []
        )
        let selected = Set(snapshot.selectedNodeIDs)
        let related = Set(snapshot.connections.flatMap { connection -> [UUID] in
            guard selected.contains(connection.sourceNodeID)
                    || selected.contains(connection.destinationNodeID) else { return [] }
            return [connection.sourceNodeID, connection.destinationNodeID]
        })
        let ordered = snapshot.nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        let eligible: [CanvasNode]
        if !selected.isEmpty {
            eligible = ordered.filter { selected.contains($0.id) || related.contains($0.id) }
        } else if let cursor = args.afterNodeID {
            eligible = ordered.filter { $0.id.uuidString > cursor.uuidString }
        } else {
            eligible = ordered
        }
        // Tool output has a bounded inline payload. Keep the default page small
        // enough to preserve complete structured nodes instead of truncating JSON.
        let limit = min(args.limit ?? 8, 24)
        let visible = Array(eligible.prefix(limit))
        let visibleIDs = Set(visible.map(\.id))
        let page = CanvasInspectionPage(
            canvasID: snapshot.canvasID, documentID: snapshot.documentID,
            revision: snapshot.revision, viewport: snapshot.viewport,
            selectedNodeIDs: snapshot.selectedNodeIDs,
            nodes: visible.map {
                .init(
                    id: $0.id, kind: $0.kind, text: String($0.text.prefix(180)),
                    position: $0.position, size: $0.size, groupID: $0.groupID,
                    isLocked: $0.isLocked, assetID: $0.asset?.id
                )
            },
            connections: snapshot.connections.compactMap {
                guard visibleIDs.contains($0.sourceNodeID) || visibleIDs.contains($0.destinationNodeID) else {
                    return nil
                }
                return .init(
                    id: $0.id, sourceNodeID: $0.sourceNodeID,
                    destinationNodeID: $0.destinationNodeID,
                    sourcePort: $0.sourcePort, destinationPort: $0.destinationPort,
                    label: $0.label
                )
            },
            hasMoreNodes: eligible.count > visible.count,
            nextNodeCursor: eligible.count > visible.count ? visible.last?.id : nil
        )
        return try CanvasToolOutput.make(page)
    }
}

private struct CanvasApplyPatchTool: AgentTool {
    struct Arguments: Decodable, Sendable { var patch: CanvasPatch }
    static let name = "canvas.applyPatch"
    static let toolDescription = "Atomically create, edit, connect, group or arrange nodes on the active canvas. Inspect first and pass its exact revision. Deletion is approval-gated."
    static let parametersJSON = #"{"type":"object","properties":{"patch":{"type":"object","properties":{"canvasID":{"type":"string","format":"uuid"},"documentID":{"type":"string","format":"uuid"},"expectedRevision":{"type":"integer"},"operations":{"type":"array","minItems":1,"maxItems":100,"items":{"type":"object","properties":{"id":{"type":"string","format":"uuid"},"kind":{"type":"string","enum":["create","update","delete","connect","disconnect","group","ungroup","arrange"]},"nodeID":{"type":"string","format":"uuid"},"nodeIDs":{"type":"array","items":{"type":"string","format":"uuid"}},"nodeKind":{"type":"string","enum":["text","stickyNote","card","shape","image","video","audio","file","group","generationTask","scene3D"]},"text":{"type":"string"},"position":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"additionalProperties":false},"size":{"type":"object","properties":{"width":{"type":"number"},"height":{"type":"number"}},"required":["width","height"],"additionalProperties":false},"rotation":{"type":"number"},"isLocked":{"type":"boolean"},"shape":{"type":"string","enum":["rectangle","roundedRectangle","ellipse","diamond","triangle"]},"sourceNodeID":{"type":"string","format":"uuid"},"destinationNodeID":{"type":"string","format":"uuid"},"connectionID":{"type":"string","format":"uuid"},"sourcePort":{"type":"string","enum":["top","trailing","bottom","leading"]},"destinationPort":{"type":"string","enum":["top","trailing","bottom","leading"]},"label":{"type":"string"},"arrangement":{"type":"string","enum":["horizontal","vertical"]}},"required":["kind"],"additionalProperties":false}}},"required":["canvasID","documentID","expectedRevision","operations"],"additionalProperties":false}},"required":["patch"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .deletesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {
        guard !args.patch.operations.contains(where: { $0.kind == .delete }) else {
            // Side-effect approval still applies to every patch. This marker
            // keeps destructive intent visible in the tool card/result.
            return
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasToolOutput.make(coordinator.apply(runID: context.runID, patch: args.patch))
    }
}

private struct CanvasAssetSearchTool: AgentTool {
    struct Arguments: Decodable, Sendable { var query: String?; var kinds: [String]?; var limit: Int? }
    static let name = "canvas.assetSearch"
    static let toolDescription = "Search the user's material library for assets that can be inserted into the canvas."
    static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string"},"kinds":{"type":"array","items":{"type":"string","enum":["image","video","audio","document"]}},"limit":{"type":"integer","minimum":1,"maximum":50}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let kinds = Set((args.kinds ?? []).compactMap(MediaKind.init(rawValue:)))
        return try await CanvasToolOutput.make(coordinator.searchAssets(
            query: args.query, kinds: kinds, limit: args.limit ?? 20
        ))
    }
}

private struct CanvasAssetInsertTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var assetID: UUID; var documentID: UUID?; var position: CanvasPoint
        var expectedRevision: Int64
    }
    static let name = "canvas.assetInsert"
    static let toolDescription = "Insert an existing material-library asset into the active canvas."
    static let parametersJSON = #"{"type":"object","properties":{"assetID":{"type":"string","format":"uuid"},"documentID":{"type":"string","format":"uuid"},"position":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"additionalProperties":false},"expectedRevision":{"type":"integer"}},"required":["assetID","position","expectedRevision"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasToolOutput.make(coordinator.insertAsset(
            runID: context.runID, assetID: args.assetID,
            documentID: args.documentID, position: args.position,
            expectedRevision: args.expectedRevision
        ))
    }
}

private struct CanvasGenerateMediaTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var kind: String; var prompt: String; var modelID: UUID?
        var documentID: UUID?; var position: CanvasPoint
        var expectedRevision: Int64; var aspectRatio: String?
        var durationSeconds: Int?
    }
    static let name = "canvas.generateMedia"
    static let toolDescription = "Generate an image or submit a durable video job and insert its result/task node. This may incur provider charges and requires approval."
    static let parametersJSON = #"{"type":"object","properties":{"kind":{"type":"string","enum":["image","video"]},"prompt":{"type":"string"},"modelID":{"type":"string","format":"uuid"},"documentID":{"type":"string","format":"uuid"},"position":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"additionalProperties":false},"expectedRevision":{"type":"integer"},"aspectRatio":{"type":"string"},"durationSeconds":{"type":"integer","minimum":1,"maximum":30}},"required":["kind","prompt","position","expectedRevision"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess, .sendsDataToProvider, .persistsPersonalData]
    static let isSideEffecting = true
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {
        guard ["image", "video"].contains(args.kind), !args.prompt.isEmpty else {
            throw FloeError.validationFailed("kind and prompt are required")
        }
        if args.kind == "video", args.modelID == nil {
            throw FloeError.validationFailed("video generation requires modelID")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        if args.kind == "image" {
            return try await CanvasToolOutput.make(coordinator.generateImageAsset(
                runID: context.runID, prompt: args.prompt,
                documentID: args.documentID, position: args.position,
                expectedRevision: args.expectedRevision, aspectRatio: args.aspectRatio
            ))
        }
        let (result, job) = try await coordinator.submitVideoJob(
            runID: context.runID, modelID: args.modelID!, prompt: args.prompt,
            documentID: args.documentID, position: args.position,
            expectedRevision: args.expectedRevision, aspectRatio: args.aspectRatio,
            durationSeconds: args.durationSeconds
        )
        return try CanvasToolOutput.make(["revision": String(result.revision), "jobID": job.id.uuidString, "state": job.state.rawValue])
    }
}

private struct CanvasMediaStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "canvas.mediaStatus"
    static let toolDescription = "Read durable image/video generation job status for the active canvas."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasToolOutput.make(coordinator.mediaJobs(runID: context.runID))
    }
}

@MainActor
func registerCanvasAgentTools(environment: AppEnvironment, registry: ToolRunnerRegistry = .shared) {
    let coordinator = CanvasToolCoordinator(
        repository: FileCanvasDocumentRepository(),
        assetStore: environment.creativeAssetStore,
        jobs: MediaGenerationJobStore(database: environment.database),
        conversationIDForRun: { [runStore = environment.runStore] runID in
            try await runStore.run(id: runID)?.conversationID
        },
        generateImage: { [weak environment] prompt, options in
            guard let environment else { throw FloeError.internalError("Canvas environment unavailable") }
            return try await environment.mediaGenerationService.generateImage(prompt: prompt, options: options)
        },
        submitVideo: { [weak environment] modelID, canvasID, documentID, sources, resultID, request in
            guard let environment else { throw FloeError.internalError("Canvas environment unavailable") }
            guard let model = try await environment.configurationStore.model(id: modelID) else {
                throw FloeError.invalidConfiguration("Video model is unavailable")
            }
            var resolvedRequest = request
            resolvedRequest.modelRemoteID = model.remoteModelID
            return try await environment.mediaGenerationService.submitVideo(
                modelID: modelID, canvasID: canvasID, documentID: documentID,
                sourceNodeIDs: sources, resultNodeID: resultID, request: resolvedRequest
            )
        }
    )
    ToolCatalog.register(CanvasInspectTool.self); registry.register(CanvasInspectTool(coordinator: coordinator))
    ToolCatalog.register(CanvasApplyPatchTool.self); registry.register(CanvasApplyPatchTool(coordinator: coordinator))
    ToolCatalog.register(CanvasAssetSearchTool.self); registry.register(CanvasAssetSearchTool(coordinator: coordinator))
    ToolCatalog.register(CanvasAssetInsertTool.self); registry.register(CanvasAssetInsertTool(coordinator: coordinator))
    ToolCatalog.register(CanvasGenerateMediaTool.self); registry.register(CanvasGenerateMediaTool(coordinator: coordinator))
    ToolCatalog.register(CanvasMediaStatusTool.self); registry.register(CanvasMediaStatusTool(coordinator: coordinator))
}
#endif
