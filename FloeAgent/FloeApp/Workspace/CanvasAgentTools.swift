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

struct CanvasGenerationOutcome: Encodable {
    var canvasID: UUID
    var documentID: UUID
    var revision: Int64
    var promptNodeID: UUID
    var configurationNodeID: UUID
    var resultNodeIDs: [UUID]
    var jobID: UUID?
    var state: String
    var reused: Bool
}

struct CanvasAssetImportOutcome: Encodable {
    var assetID: UUID
    var nodeID: UUID
    var canvasID: UUID
    var documentID: UUID
    var revision: Int64
    var contentHash: String
}

actor CanvasToolCoordinator {
    private let repository: any CanvasDocumentRepository
    private let assetStore: CreativeAssetStore
    private let assetIngestion: CreativeAssetIngestionService
    private let jobs: MediaGenerationJobStore
    private let runContexts: CanvasRunContextStore
    private let conversationIDForRun: @Sendable (UUID) async throws -> UUID?
    private let generateImages: @Sendable (
        String, ImageGenerationOptions, [Data], UUID?
    ) async throws -> [CanvasAssetReference]
    private let submitVideo: @Sendable (
        UUID, UUID, UUID, [UUID], UUID, RemoteVideoRequest
    ) async throws -> MediaGenerationJob

    init(
        repository: any CanvasDocumentRepository,
        assetStore: CreativeAssetStore,
        assetIngestion: CreativeAssetIngestionService,
        jobs: MediaGenerationJobStore,
        runContexts: CanvasRunContextStore,
        conversationIDForRun: @escaping @Sendable (UUID) async throws -> UUID?,
        generateImages: @escaping @Sendable (
            String, ImageGenerationOptions, [Data], UUID?
        ) async throws -> [CanvasAssetReference],
        submitVideo: @escaping @Sendable (
            UUID, UUID, UUID, [UUID], UUID, RemoteVideoRequest
        ) async throws -> MediaGenerationJob
    ) {
        self.repository = repository; self.assetStore = assetStore
        self.assetIngestion = assetIngestion; self.jobs = jobs
        self.runContexts = runContexts
        self.conversationIDForRun = conversationIDForRun
        self.generateImages = generateImages; self.submitVideo = submitVideo
    }

    func project(for runID: UUID) async throws -> CanvasProject {
        if let context = try await runContexts.context(runID: runID) {
            return try await repository.project(canvasID: context.canvasID)
        }
        // Compatibility for interrupted runs created before schema v32. New
        // runs always resolve in O(1) through canvas_run_contexts.
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
        let persisted = try await runContexts.context(runID: runID)
        return try CanvasCommandService.snapshot(
            project: activeProject,
            documentID: documentID ?? persisted?.documentID,
            selectedNodeIDs: selectedNodeIDs.isEmpty
                ? (persisted?.selectedNodeIDs ?? []) : selectedNodeIDs
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

    func importAsset(
        runID: UUID, url: URL, displayName: String?, license: String?,
        documentID: UUID?, position: CanvasPoint, expectedRevision: Int64
    ) async throws -> CanvasAssetImportOutcome {
        let asset = try await assetIngestion.importRemoteImage(
            from: url, displayName: displayName, license: license
        )
        let result = try await insertAsset(
            runID: runID, assetID: asset.id, documentID: documentID,
            position: position, expectedRevision: expectedRevision
        )
        return CanvasAssetImportOutcome(
            assetID: asset.id,
            nodeID: result.changedNodeIDs.first ?? asset.id,
            canvasID: result.canvasID,
            documentID: result.documentID,
            revision: result.revision,
            contentHash: asset.contentHash
        )
    }

    func generateMedia(
        runID: UUID, kind: CanvasGenerationGraphKind, modelID: UUID?,
        prompt: String, documentID: UUID?, sourceNodeIDs: [UUID]?,
        configurationNodeID: UUID?, position: CanvasPoint,
        expectedRevision: Int64, aspectRatio: String?, quality: String?,
        count: Int, durationSeconds: Int?
    ) async throws -> CanvasGenerationOutcome {
        let activeProject = try await project(for: runID)
        let persisted = try await runContexts.context(runID: runID)
        let targetDocumentID = documentID ?? persisted?.documentID ?? activeProject.selectedDocumentID
        guard let document = activeProject.documents.first(where: { $0.id == targetDocumentID }) else {
            throw FloeError.validationFailed("Canvas document does not exist")
        }
        let sources = sourceNodeIDs ?? persisted?.selectedNodeIDs ?? []
        let availableNodeIDs = Set(document.nodes.map(\.id))
        let missingSourceIDs = Set(sources).subtracting(availableNodeIDs)
        guard missingSourceIDs.isEmpty else {
            throw FloeError.validationFailed(
                "Generation references missing canvas nodes: \(missingSourceIDs.map(\.uuidString).sorted().joined(separator: ", "))"
            )
        }
        let fingerprint = generationFingerprint(
            kind: kind, prompt: prompt, modelID: modelID,
            sourceNodeIDs: sources, aspectRatio: aspectRatio,
            quality: quality, count: count, durationSeconds: durationSeconds
        )
        if let existing = document.nodes.first(where: {
            $0.kind == .generationTask
                && $0.createdByRunID == runID
                && $0.metadata["generationRequestKey"] == fingerprint
        }) {
            let state = existing.metadata["generationState"] ?? "unknown"
            if ["failed", "submitFailed"].contains(state) {
                throw FloeError.validationFailed(
                    "This generation already failed in the current run. Change the request or retry its configuration node in a new user turn."
                )
            }
            let resultIDs = existing.metadata["generationResultNodeIDs"]?
                .split(separator: ",").compactMap { UUID(uuidString: String($0)) } ?? []
            return CanvasGenerationOutcome(
                canvasID: activeProject.id, documentID: targetDocumentID,
                revision: activeProject.revision,
                promptNodeID: UUID(uuidString: existing.metadata["generationPromptNodeID"] ?? "") ?? existing.id,
                configurationNodeID: existing.id, resultNodeIDs: resultIDs,
                jobID: resultIDs.compactMap { id in
                    document.nodes.first(where: { $0.id == id })?.generationJobID
                }.first,
                state: state, reused: true
            )
        }
        if let previousAttempt = document.nodes.first(where: {
            $0.kind == .generationTask && $0.createdByRunID == runID
        }) {
            let state = previousAttempt.metadata["generationState"] ?? "unknown"
            throw FloeError.validationFailed(
                "This user turn already submitted a canvas generation (\(state)). Do not generate again automatically; ask the user to retry from configuration node \(previousAttempt.id.uuidString)."
            )
        }
        guard activeProject.revision == expectedRevision else {
            throw FloeError.validationFailed(
                "Canvas revision conflict: expected \(expectedRevision), current \(activeProject.revision)"
            )
        }
        var graphMetadata = generationMetadata(
            kind: kind, prompt: prompt, modelID: modelID,
            aspectRatio: aspectRatio, quality: quality,
            count: count, durationSeconds: durationSeconds,
            fingerprint: fingerprint, state: "running"
        )
        graphMetadata["generationAttemptID"] = UUID().uuidString
        graphMetadata["generationAttemptIndex"] = "1"
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: kind, prompt: prompt, sourceNodeIDs: sources,
                resultPosition: position,
                existingConfigurationNodeID: configurationNodeID,
                createdByRunID: runID, metadata: graphMetadata
            ),
            document: document
        )
        var preparedMetadata = graphMetadata
        preparedMetadata["generationPromptNodeID"] = graph.promptNodeID.uuidString
        preparedMetadata["generationResultNodeIDs"] = graph.resultNodeID.uuidString
        var operations = graph.operations
        operations.append(CanvasPatchOperation(
            kind: .update, nodeID: graph.configurationNodeID,
            metadata: preparedMetadata
        ))
        let prepared = try await apply(runID: runID, patch: CanvasPatch(
            canvasID: activeProject.id, documentID: targetDocumentID,
            expectedRevision: expectedRevision, operations: operations
        ))

        do {
            if kind == .image {
                let referenceData = try sourceImageData(
                    sourceNodeIDs: sources, document: document
                )
                let assets = try await generateImages(
                    providerPrompt(prompt: prompt, sourceNodeIDs: sources, document: document),
                    ImageGenerationOptions(
                        aspectRatio: aspectRatio, quality: quality,
                        count: max(1, min(count, 4))
                    ),
                    referenceData, modelID
                )
                guard !assets.isEmpty else {
                    throw FloeError.internalError("Image provider returned no assets")
                }
                var resultIDs = [graph.resultNodeID]
                var resultOperations: [CanvasPatchOperation] = []
                for (index, asset) in assets.enumerated() {
                    let resultID: UUID
                    if index == 0 {
                        resultID = graph.resultNodeID
                        resultOperations.append(CanvasPatchOperation(
                            kind: .update, nodeID: resultID, nodeKind: .image,
                            text: "生成图片", asset: asset,
                            metadata: graphMetadata.merging([
                                "generationState": "ready",
                                "imageGroupPrimary": "true"
                            ]) { _, new in new }
                        ))
                    } else {
                        resultID = UUID(); resultIDs.append(resultID)
                        resultOperations.append(CanvasPatchOperation(
                            kind: .create, nodeID: resultID, nodeKind: .image,
                            text: "生成图片",
                            position: .init(
                                x: position.x + Double(index) * 54,
                                y: position.y + Double(index) * 42
                            ),
                            size: .init(width: 320, height: 260), asset: asset,
                            createdByRunID: runID,
                            metadata: graphMetadata.merging([
                                "generationState": "ready",
                                "imageGroupPrimary": "false"
                            ]) { _, new in new }
                        ))
                        resultOperations.append(CanvasPatchOperation(
                            kind: .connect,
                            sourceNodeID: graph.configurationNodeID,
                            destinationNodeID: resultID,
                            connectionKind: .generatedFrom,
                            sourcePort: .trailing, destinationPort: .leading,
                            label: "生成结果"
                        ))
                    }
                }
                resultOperations.append(CanvasPatchOperation(
                    kind: .update, nodeID: graph.configurationNodeID,
                    metadata: [
                        "generationState": "ready",
                        "generationResultNodeIDs": resultIDs.map(\.uuidString).joined(separator: ",")
                    ]
                ))
                let completed = try await apply(runID: runID, patch: CanvasPatch(
                    canvasID: activeProject.id, documentID: targetDocumentID,
                    expectedRevision: prepared.revision, operations: resultOperations
                ))
                for asset in assets {
                    try await assetStore.adjustReference(assetID: asset.id, by: 1)
                }
                return CanvasGenerationOutcome(
                    canvasID: activeProject.id, documentID: targetDocumentID,
                    revision: completed.revision, promptNodeID: graph.promptNodeID,
                    configurationNodeID: graph.configurationNodeID,
                    resultNodeIDs: resultIDs, jobID: nil, state: "ready", reused: false
                )
            }

            guard let modelID else {
                throw FloeError.validationFailed("video generation requires modelID")
            }
            let job = try await submitVideo(
                modelID, activeProject.id, targetDocumentID,
                graph.sourceNodeIDs, graph.resultNodeID,
                RemoteVideoRequest(
                    prompt: providerPrompt(prompt: prompt, sourceNodeIDs: sources, document: document),
                    modelRemoteID: "",
                    options: VideoGenerationOptions(
                        aspectRatio: aspectRatio, resolution: quality,
                        durationSeconds: durationSeconds
                    )
                )
            )
            let submitted = try await apply(runID: runID, patch: CanvasPatch(
                canvasID: activeProject.id, documentID: targetDocumentID,
                expectedRevision: prepared.revision,
                operations: [
                    CanvasPatchOperation(
                        kind: .update, nodeID: graph.resultNodeID,
                        generationJobID: job.id,
                        metadata: ["generationState": "submitted"]
                    ),
                    CanvasPatchOperation(
                        kind: .update, nodeID: graph.configurationNodeID,
                        metadata: ["generationState": "submitted"]
                    )
                ]
            ))
            return CanvasGenerationOutcome(
                canvasID: activeProject.id, documentID: targetDocumentID,
                revision: submitted.revision, promptNodeID: graph.promptNodeID,
                configurationNodeID: graph.configurationNodeID,
                resultNodeIDs: [graph.resultNodeID], jobID: job.id,
                state: "submitted", reused: false
            )
        } catch {
            try? await markGenerationFailed(
                runID: runID, canvasID: activeProject.id,
                documentID: targetDocumentID,
                configurationNodeID: graph.configurationNodeID,
                resultNodeID: graph.resultNodeID,
                message: error.localizedDescription
            )
            throw error
        }
    }

    private func markGenerationFailed(
        runID: UUID, canvasID: UUID, documentID: UUID,
        configurationNodeID: UUID, resultNodeID: UUID, message: String
    ) async throws {
        let current = try await repository.project(canvasID: canvasID)
        _ = try await apply(runID: runID, patch: CanvasPatch(
            canvasID: canvasID, documentID: documentID,
            expectedRevision: current.revision,
            operations: [
                CanvasPatchOperation(
                    kind: .update, nodeID: configurationNodeID,
                    metadata: ["generationState": "failed", "generationError": message]
                ),
                CanvasPatchOperation(
                    kind: .update, nodeID: resultNodeID,
                    text: "生成失败，可从配置节点重试",
                    metadata: ["generationState": "failed", "generationError": message]
                )
            ]
        ))
    }

    private func generationFingerprint(
        kind: CanvasGenerationGraphKind, prompt: String, modelID: UUID?,
        sourceNodeIDs: [UUID], aspectRatio: String?, quality: String?,
        count: Int, durationSeconds: Int?
    ) -> String {
        let canonical = [
            kind.rawValue, prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID?.uuidString ?? "", sourceNodeIDs.map(\.uuidString).sorted().joined(separator: ","),
            aspectRatio ?? "", quality ?? "", String(count), durationSeconds.map(String.init) ?? ""
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func generationMetadata(
        kind: CanvasGenerationGraphKind, prompt: String, modelID: UUID?,
        aspectRatio: String?, quality: String?, count: Int,
        durationSeconds: Int?, fingerprint: String, state: String
    ) -> [String: String] {
        [
            "generationKind": kind.rawValue,
            "generationPrompt": prompt,
            "generationModelID": modelID?.uuidString ?? "",
            "generationAspectRatio": aspectRatio ?? "",
            "generationQuality": quality ?? "",
            "generationCount": String(count),
            "generationDurationSeconds": durationSeconds.map(String.init) ?? "",
            "generationRequestKey": fingerprint,
            "generationState": state
        ]
    }

    private func providerPrompt(
        prompt: String, sourceNodeIDs: [UUID], document: CanvasDocument
    ) -> String {
        let sourceSet = Set(sourceNodeIDs)
        let context = document.nodes.compactMap { node -> String? in
            guard sourceSet.contains(node.id), [.text, .stickyNote, .card].contains(node.kind) else {
                return nil
            }
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || text == prompt ? nil : text
        }
        return context.isEmpty ? prompt : "\(prompt)\n\n画布文字引用：\n\(context.joined(separator: "\n"))"
    }

    private func sourceImageData(
        sourceNodeIDs: [UUID], document: CanvasDocument
    ) throws -> [Data] {
        let sourceSet = Set(sourceNodeIDs)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appendingPathComponent("FloeAgent", isDirectory: true)
        let requestedImages = document.nodes.filter {
            sourceSet.contains($0.id) && $0.kind == .image
        }
        return try requestedImages.map { node in
            guard let relative = node.asset?.localRelativePath,
                  !relative.contains("..") else {
                throw FloeError.validationFailed(
                    "Reference image \(node.id.uuidString) is not stored locally. Import it before generation."
                )
            }
            let url = support.appendingPathComponent(relative).standardizedFileURL
            guard url.path.hasPrefix(support.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw FloeError.validationFailed(
                    "Reference image \(node.id.uuidString) is missing locally. Re-import it before generation."
                )
            }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }
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
    static let name = "canvas.getState"
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
    static let name = "canvas.applyOperations"
    static let toolDescription = "Atomically create, edit, connect, group or arrange nodes on the active canvas. Inspect first and pass its exact revision. Deletion is approval-gated."
    static let parametersJSON = #"{"type":"object","properties":{"patch":{"type":"object","properties":{"canvasID":{"type":"string","format":"uuid"},"documentID":{"type":"string","format":"uuid"},"expectedRevision":{"type":"integer"},"operations":{"type":"array","minItems":1,"maxItems":100,"items":{"type":"object","properties":{"id":{"type":"string","format":"uuid"},"kind":{"type":"string","enum":["create","update","delete","connect","disconnect","group","ungroup","arrange"]},"nodeID":{"type":"string","format":"uuid"},"nodeIDs":{"type":"array","items":{"type":"string","format":"uuid"}},"nodeKind":{"type":"string","enum":["text","stickyNote","card","shape","image","video","audio","file","group","generationTask","scene3D"]},"text":{"type":"string"},"position":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"additionalProperties":false},"size":{"type":"object","properties":{"width":{"type":"number"},"height":{"type":"number"}},"required":["width","height"],"additionalProperties":false},"rotation":{"type":"number"},"isLocked":{"type":"boolean"},"shape":{"type":"string","enum":["rectangle","roundedRectangle","ellipse","diamond","triangle"]},"sourceNodeID":{"type":"string","format":"uuid"},"destinationNodeID":{"type":"string","format":"uuid"},"connectionID":{"type":"string","format":"uuid"},"sourcePort":{"type":"string","enum":["top","trailing","bottom","leading"]},"destinationPort":{"type":"string","enum":["top","trailing","bottom","leading"]},"label":{"type":"string"},"arrangement":{"type":"string","enum":["horizontal","vertical"]}},"required":["kind"],"additionalProperties":false}}},"required":["canvasID","documentID","expectedRevision","operations"],"additionalProperties":false}},"required":["patch"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {
        guard !args.patch.operations.contains(where: { $0.kind == .delete }) else {
            throw FloeError.validationFailed("Use canvas.delete for destructive operations")
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

private struct CanvasAssetImportTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var url: String
        var displayName: String?
        var license: String?
        var documentID: UUID?
        var position: CanvasPoint
        var expectedRevision: Int64
    }
    static let name = "canvas.assetImport"
    static let toolDescription = "Download one public HTTPS image into the material library, persist it locally, and insert it as a visible image node before using it as a generation reference."
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","format":"uri"},"displayName":{"type":"string"},"license":{"type":"string"},"documentID":{"type":"string","format":"uuid"},"position":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"additionalProperties":false},"expectedRevision":{"type":"integer"}},"required":["url","position","expectedRevision"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {
        guard let url = URL(string: args.url),
              CreativeAssetIngestionService.isSafePublicHTTPSURL(url) else {
            throw FloeError.validationFailed("url must be a public HTTPS image URL")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let url = URL(string: args.url) else {
            throw FloeError.validationFailed("Invalid image URL")
        }
        return try await CanvasToolOutput.make(coordinator.importAsset(
            runID: context.runID,
            url: url,
            displayName: args.displayName,
            license: args.license,
            documentID: args.documentID,
            position: args.position,
            expectedRevision: args.expectedRevision
        ))
    }
}

private struct CanvasGenerateMediaTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var kind: String; var prompt: String; var modelID: UUID?
        var documentID: UUID?; var sourceNodeIDs: [UUID]?
        var configurationNodeID: UUID?; var position: CanvasPoint
        var expectedRevision: Int64; var aspectRatio: String?
        var quality: String?; var count: Int?; var durationSeconds: Int?
    }
    static let name = "canvas.generate"
    static let toolDescription = "Generate media through the canonical canvas workflow. It creates or reuses a visible prompt node, a generation-configuration node, and connected image/video results. Inspect first and pass the exact revision."
    static let parametersJSON = #"{"type":"object","properties":{"kind":{"type":"string","enum":["image","video"]},"prompt":{"type":"string"},"modelID":{"type":"string","format":"uuid"},"documentID":{"type":"string","format":"uuid"},"sourceNodeIDs":{"type":"array","items":{"type":"string","format":"uuid"}},"configurationNodeID":{"type":"string","format":"uuid"},"position":{"type":"object","description":"Preferred position of the first result node; prompt and configuration nodes are placed to its left.","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"],"additionalProperties":false},"expectedRevision":{"type":"integer"},"aspectRatio":{"type":"string"},"quality":{"type":"string"},"count":{"type":"integer","minimum":1,"maximum":4},"durationSeconds":{"type":"integer","minimum":1,"maximum":30}},"required":["kind","prompt","position","expectedRevision"],"additionalProperties":false}"#
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
        if let count = args.count, !(1...4).contains(count) {
            throw FloeError.validationFailed("count must be 1...4")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasToolOutput.make(coordinator.generateMedia(
            runID: context.runID,
            kind: args.kind == "image" ? .image : .video,
            modelID: args.modelID, prompt: args.prompt,
            documentID: args.documentID, sourceNodeIDs: args.sourceNodeIDs,
            configurationNodeID: args.configurationNodeID,
            position: args.position, expectedRevision: args.expectedRevision,
            aspectRatio: args.aspectRatio, quality: args.quality,
            count: args.count ?? 1, durationSeconds: args.durationSeconds
        ))
    }
}

private struct CanvasMediaStatusTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "canvas.generationStatus"
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

private struct CanvasDeleteTool: AgentTool {
    typealias Arguments = CanvasApplyPatchTool.Arguments
    static let name = "canvas.delete"
    static let toolDescription = "Delete nodes from the active canvas using an exact inspected revision. This is always approval-gated."
    static let parametersJSON = CanvasApplyPatchTool.parametersJSON
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .deletesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {
        guard !args.patch.operations.isEmpty,
              args.patch.operations.allSatisfy({ $0.kind == .delete }) else {
            throw FloeError.validationFailed("canvas.delete accepts delete operations only")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasToolOutput.make(coordinator.apply(runID: context.runID, patch: args.patch))
    }
}

// Recovered checkpoints keep the exact tool name that was originally
// dispatched. Register legacy names internally, but exclude them from the
// current canvas capability ceiling so models see only one canonical API.
private struct LegacyCanvasInspectTool: AgentTool {
    typealias Arguments = CanvasInspectTool.Arguments
    static let name = "canvas.inspect"
    static let toolDescription = CanvasInspectTool.toolDescription
    static let parametersJSON = CanvasInspectTool.parametersJSON
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws { try CanvasInspectTool(coordinator: coordinator).validate(args) }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasInspectTool(coordinator: coordinator).execute(args, context: context)
    }
}

private struct LegacyCanvasApplyPatchTool: AgentTool {
    typealias Arguments = CanvasApplyPatchTool.Arguments
    static let name = "canvas.applyPatch"
    static let toolDescription = CanvasApplyPatchTool.toolDescription
    static let parametersJSON = CanvasApplyPatchTool.parametersJSON
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData, .deletesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .internalState
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasToolOutput.make(coordinator.apply(runID: context.runID, patch: args.patch))
    }
}

private struct LegacyCanvasGenerateMediaTool: AgentTool {
    typealias Arguments = CanvasGenerateMediaTool.Arguments
    static let name = "canvas.generateMedia"
    static let toolDescription = CanvasGenerateMediaTool.toolDescription
    static let parametersJSON = CanvasGenerateMediaTool.parametersJSON
    static let riskLabels = CanvasGenerateMediaTool.riskLabels
    static let isSideEffecting = true
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws { try CanvasGenerateMediaTool(coordinator: coordinator).validate(args) }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasGenerateMediaTool(coordinator: coordinator).execute(args, context: context)
    }
}

private struct LegacyCanvasMediaStatusTool: AgentTool {
    typealias Arguments = CanvasMediaStatusTool.Arguments
    static let name = "canvas.mediaStatus"
    static let toolDescription = CanvasMediaStatusTool.toolDescription
    static let parametersJSON = CanvasMediaStatusTool.parametersJSON
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let coordinator: CanvasToolCoordinator
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await CanvasMediaStatusTool(coordinator: coordinator).execute(args, context: context)
    }
}

@MainActor
func registerCanvasAgentTools(environment: AppEnvironment, registry: ToolRunnerRegistry = .shared) {
    let assetIngestion = CreativeAssetIngestionService(assetStore: environment.creativeAssetStore)
    let coordinator = CanvasToolCoordinator(
        repository: FileCanvasDocumentRepository(),
        assetStore: environment.creativeAssetStore,
        assetIngestion: assetIngestion,
        jobs: MediaGenerationJobStore(database: environment.database),
        runContexts: CanvasRunContextStore(database: environment.database),
        conversationIDForRun: { [runStore = environment.runStore] runID in
            try await runStore.run(id: runID)?.conversationID
        },
        generateImages: { [weak environment] prompt, options, sourceImages, modelID in
            guard let environment else { throw FloeError.internalError("Canvas environment unavailable") }
            return try await environment.mediaGenerationService.generateImages(
                prompt: prompt,
                options: options,
                sourceImages: sourceImages,
                modelID: modelID
            )
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
    ToolCatalog.register(CanvasDeleteTool.self); registry.register(CanvasDeleteTool(coordinator: coordinator))
    ToolCatalog.register(CanvasAssetSearchTool.self); registry.register(CanvasAssetSearchTool(coordinator: coordinator))
    ToolCatalog.register(CanvasAssetInsertTool.self); registry.register(CanvasAssetInsertTool(coordinator: coordinator))
    ToolCatalog.register(CanvasAssetImportTool.self); registry.register(CanvasAssetImportTool(coordinator: coordinator))
    ToolCatalog.register(CanvasGenerateMediaTool.self); registry.register(CanvasGenerateMediaTool(coordinator: coordinator))
    ToolCatalog.register(CanvasMediaStatusTool.self); registry.register(CanvasMediaStatusTool(coordinator: coordinator))
    ToolCatalog.register(LegacyCanvasInspectTool.self); registry.register(LegacyCanvasInspectTool(coordinator: coordinator))
    ToolCatalog.register(LegacyCanvasApplyPatchTool.self); registry.register(LegacyCanvasApplyPatchTool(coordinator: coordinator))
    ToolCatalog.register(LegacyCanvasGenerateMediaTool.self); registry.register(LegacyCanvasGenerateMediaTool(coordinator: coordinator))
    ToolCatalog.register(LegacyCanvasMediaStatusTool.self); registry.register(LegacyCanvasMediaStatusTool(coordinator: coordinator))
}
#endif
