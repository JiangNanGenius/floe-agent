#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
@testable import FloeCore
import FloeModels
import FloePersistence
import FloeTools

private struct CanvasInspectionPayload: Decodable {
    struct Connection: Decodable {
        var id: UUID
        var sourceNodeID: UUID
        var destinationNodeID: UUID
        var kind: CanvasConnectionKind
    }

    var canvasID: UUID
    var documentID: UUID
    var revision: Int64
    var connections: [Connection]
}

private struct CanvasApplyOperationsPayload: Encodable {
    var patch: CanvasPatch
}

private actor CanvasGeneratedAssetLifecycleProbe {
    struct Snapshot: Sendable {
        var marked: [[UUID]]
        var discarded: [[UUID]]
    }

    private var marked: [[UUID]] = []
    private var discarded: [[UUID]] = []

    func recordMarked(_ assets: [CanvasAssetReference]) {
        marked.append(assets.map(\.id))
    }

    func recordDiscarded(_ assets: [CanvasAssetReference]) {
        discarded.append(assets.map(\.id))
    }

    func snapshot() -> Snapshot {
        Snapshot(marked: marked, discarded: discarded)
    }
}

private actor CanvasSaveStartBarrier {
    private let participantCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        if waiters.count + 1 == participantCount {
            let blocked = waiters
            waiters.removeAll()
            for waiter in blocked { waiter.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private enum CanvasSaveRaceResult: Sendable {
    case saved
    case revisionConflict
    case unexpected(String)
}

private struct CanvasGenerationFixture {
    var canvasID: UUID
    var runID: UUID
    var sourceNodeID: UUID
    var initialProject: CanvasProject
    var coordinator: CanvasToolCoordinator
}

@Suite("Canvas agent tool contracts")
struct CanvasAgentToolContractTests {
    @MainActor
    @Test("App bootstrap exposes only paired native descriptors and executable runners")
    func appToolRegistryIsBidirectional() throws {
        let environment = AppEnvironment.preview()
        defer { withExtendedLifetime(environment) {} }
        let registry = ToolRunnerRegistry.shared
        let executable = registry.allDescriptors.filter { !$0.name.hasPrefix("mcp.") }
        let declared = ToolCatalog.allDescriptors.filter { !$0.name.hasPrefix("mcp.") }
        #expect(Set(executable.map(\.name)) == Set(declared.map(\.name)))
        for descriptor in executable {
            #expect(registry.runner(named: descriptor.name) != nil)
            #expect(!descriptor.toolDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let schema = try JSONSerialization.jsonObject(with: Data(descriptor.parametersJSON.utf8))
            #expect(schema is [String: Any])
        }
        for name in ["vnc.connect", "vnc.observe", "vnc.click", "vnc.typeText", "vnc.disconnect",
                     "workspace.appendFile", "workspace.replaceText", "network.dnsLookup", "network.tcpProbe"] {
            #expect(registry.runner(named: name) != nil)
        }
        for removed in ["canvas.inspect", "canvas.applyPatch", "canvas.generateMedia", "canvas.mediaStatus"] {
            #expect(registry.descriptor(named: removed) == nil)
        }
    }

    @MainActor
    @Test("canvas.generate schema matches exact source replacement semantics")
    func generateSchemaDescribesExactSourceReplacement() throws {
        let registry = ToolRunnerRegistry()
        registerCanvasAgentTools(
            environment: AppEnvironment.preview(),
            registry: registry
        )
        let descriptor = try #require(
            registry.descriptor(named: "canvas.generate")
        )
        let data = try #require(
            descriptor.parametersJSON.data(using: .utf8)
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let properties = try #require(root["properties"] as? [String: Any])
        let sourceSchema = try #require(
            properties["sourceNodeIDs"] as? [String: Any]
        )
        let sourceDescription = try #require(
            sourceSchema["description"] as? String
        )

        #expect(sourceDescription.contains("Omit this property to inherit"))
        #expect(sourceDescription.contains("replaces the complete source set"))
        #expect(sourceDescription.contains("empty array clears it"))
        #expect(!sourceDescription.contains("merged with"))
        #expect(descriptor.toolDescription.contains("provide [] to clear it"))
    }

    @MainActor
    @Test("Process-wide file CAS allows only one same-revision writer")
    func processWideFileCASRejectsOneConcurrentWriter() async throws {
        let canvasID = UUID()
        defer { try? WorkspaceCanvasRegistry.delete(canvasID: canvasID) }
        try WorkspaceCanvasRegistry.createIfNeeded(
            canvasID: canvasID,
            name: "CAS race",
            workspaceID: nil
        )

        let firstRepository = FileCanvasDocumentRepository()
        let secondRepository = FileCanvasDocumentRepository()
        let initial = try await firstRepository.project(canvasID: canvasID)
        var firstCandidate = initial
        firstCandidate.name = "First candidate"
        firstCandidate.revision += 1
        var secondCandidate = initial
        secondCandidate.name = "Second candidate"
        secondCandidate.revision += 1
        let barrier = CanvasSaveStartBarrier(participantCount: 2)

        let results = await withTaskGroup(
            of: CanvasSaveRaceResult.self,
            returning: [CanvasSaveRaceResult].self
        ) { group in
            for (repository, candidate) in [
                (firstRepository, firstCandidate),
                (secondRepository, secondCandidate)
            ] {
                group.addTask {
                    await barrier.wait()
                    do {
                        try await repository.save(
                            candidate,
                            expectedRevision: initial.revision
                        )
                        return .saved
                    } catch {
                        if CanvasProjectFileWriter.isRevisionConflict(error) {
                            return .revisionConflict
                        }
                        return .unexpected(error.localizedDescription)
                    }
                }
            }
            var values: [CanvasSaveRaceResult] = []
            for await value in group { values.append(value) }
            return values
        }

        #expect(results.filter {
            if case .saved = $0 { return true }
            return false
        }.count == 1)
        #expect(results.filter {
            if case .revisionConflict = $0 { return true }
            return false
        }.count == 1)
        #expect(!results.contains {
            if case .unexpected = $0 { return true }
            return false
        })
        let saved = try await firstRepository.project(canvasID: canvasID)
        #expect(saved.revision == initial.revision + 1)
        #expect([firstCandidate.name, secondCandidate.name].contains(saved.name))
    }

    @MainActor
    @Test("A stale visible-canvas write cannot erase a four-result agent commit")
    func staleVisibleCanvasWritePreservesAgentTopology() async throws {
        let canvasID = UUID()
        defer { try? WorkspaceCanvasRegistry.delete(canvasID: canvasID) }
        try WorkspaceCanvasRegistry.createIfNeeded(
            canvasID: canvasID,
            name: "CAS topology",
            workspaceID: nil
        )

        let repository = FileCanvasDocumentRepository()
        let initial = try await repository.project(canvasID: canvasID)
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 96),
            size: .init(width: 240, height: 180)
        )
        var base = initial
        let documentIndex = try #require(base.documents.firstIndex {
            $0.id == base.selectedDocumentID
        })
        base.documents[documentIndex].nodes.append(source)
        base.revision += 1
        try await repository.save(base, expectedRevision: initial.revision)

        let attemptID = "cas-four-image-attempt"
        let configuration = CanvasGenerationConfiguration(
            kind: .image,
            prompt: "基于一张参考图生成四张",
            modelID: nil,
            aspectRatio: "1:1",
            count: 4,
            sourceNodeIDs: [source.id]
        )
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: configuration.prompt,
                sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 96),
                resultCount: 4,
                metadata: [
                    "generationAttemptID": attemptID,
                    "generationState": CanvasGenerationTaskState.running.rawValue
                ]
            ),
            document: base.documents[documentIndex]
        )
        let preparePatch = CanvasPatch(
            canvasID: canvasID,
            documentID: base.selectedDocumentID,
            expectedRevision: base.revision,
            operations: graph.operations
        )
        let (prepared, _) = try CanvasCommandService.applying(preparePatch, to: base)
        try await repository.save(prepared, expectedRevision: base.revision)

        // This is the candidate a visible store prepared from revision N
        // before the agent completed. Its expected revision remains N.
        var staleVisibleCandidate = prepared
        staleVisibleCandidate.viewports[prepared.selectedDocumentID] = .init(
            center: .init(x: 321, y: 654),
            scale: 0.75
        )
        staleVisibleCandidate.revision += 1
        let assets = (0..<4).map { index in
            CanvasAssetReference(
                contentHash: "cas-topology-\(index)",
                localRelativePath: "Materials/cas-topology-\(index).png",
                mimeType: "image/png",
                byteCount: 1
            )
        }
        let commitPlan = try CanvasSavedImageBatchCommitPlanner.plan(
            configurationNodeID: graph.configurationNodeID,
            preparedResultNodeIDs: graph.resultNodeIDs,
            assets: assets,
            configuration: configuration,
            sourceNodeIDs: graph.sourceNodeIDs,
            generationAttemptID: attemptID
        )
        let completionPatch = try CanvasGenerationCommitPlanner.patch(
            project: prepared,
            documentID: prepared.selectedDocumentID,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            sourceNodeIDs: graph.sourceNodeIDs,
            generationAttemptID: attemptID,
            operations: commitPlan.operations
        )
        let (completed, _) = try CanvasCommandService.applying(
            completionPatch,
            to: prepared
        )
        try await repository.save(
            completed,
            expectedRevision: prepared.revision
        )

        // The UI and repository call this same process-wide writer. Its stale
        // N -> N+1 candidate must be rejected instead of replacing the agent's
        // already-installed N+1 graph.
        let projectURL = try WorkspaceCanvasRegistry.projectURL(
            canvasID: canvasID,
            createDirectory: false
        )
        var staleWriteRejected = false
        do {
            try CanvasProjectFileWriter.shared.compareAndSwap(
                staleVisibleCandidate,
                at: projectURL,
                expectedRevision: prepared.revision
            )
        } catch {
            staleWriteRejected = CanvasProjectFileWriter.isRevisionConflict(error)
        }
        #expect(staleWriteRejected)
        let saved = try await repository.project(canvasID: canvasID)
        let document = try #require(saved.documents.first {
            $0.id == saved.selectedDocumentID
        })
        #expect(saved.revision == completed.revision)
        let sourceEdges = document.connections.filter {
            $0.kind == .source
                && $0.destinationNodeID == graph.configurationNodeID
        }
        let resultEdges = document.connections.filter {
            $0.kind == .generatedFrom
                && $0.sourceNodeID == graph.configurationNodeID
        }
        #expect(sourceEdges.count == 1)
        #expect(sourceEdges.first?.sourceNodeID == source.id)
        #expect(resultEdges.count == 4)
        #expect(Set(resultEdges.map(\.destinationNodeID)) == Set(graph.resultNodeIDs))
        let resultList = graph.resultNodeIDs.map(\.uuidString).joined(separator: ",")
        let sourceList = source.id.uuidString
        let task = try #require(document.nodes.first {
            $0.id == graph.configurationNodeID
        })
        #expect(task.metadata["generationResultNodeIDs"] == resultList)
        #expect(task.metadata["generationSourceNodeIDs"] == sourceList)
        #expect(graph.resultNodeIDs.allSatisfy { resultID in
            guard let result = document.nodes.first(where: { $0.id == resultID }) else {
                return false
            }
            return result.asset != nil
                && result.metadata["generationResultNodeIDs"] == resultList
                && result.metadata["generationSourceNodeIDs"] == sourceList
        })
    }

    @Test("Canvas inspection serializes typed connection semantics")
    func inspectionConnectionIncludesKind() throws {
        let connection = CanvasInspectionPage.Connection(
            id: UUID(),
            sourceNodeID: UUID(),
            destinationNodeID: UUID(),
            kind: .source,
            sourcePort: .trailing,
            destinationPort: .leading,
            label: "生成输入"
        )
        let data = try JSONEncoder().encode(connection)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["kind"] as? String == CanvasConnectionKind.source.rawValue)
    }

    @MainActor
    @Test("File round trip and canvas inspection preserve one source plus four result edges")
    func fileRoundTripAndToolInspectionPreserveFourResultRelationships() async throws {
        let canvasID = UUID()
        defer { try? WorkspaceCanvasRegistry.delete(canvasID: canvasID) }

        try WorkspaceCanvasRegistry.createIfNeeded(
            canvasID: canvasID,
            name: "Relationship round trip",
            workspaceID: nil
        )

        let repository = FileCanvasDocumentRepository()
        let initial = try await repository.project(canvasID: canvasID)
        let documentID = initial.selectedDocumentID
        let reference = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 96),
            size: .init(width: 240, height: 180)
        )
        let configuration = CanvasNode(
            kind: .generationTask,
            title: "Generate four",
            position: .init(x: 480, y: 96),
            size: .init(width: 320, height: 220)
        )
        let results = (0..<4).map { index in
            CanvasNode(
                kind: .image,
                title: "Result \(index + 1)",
                position: .init(x: 912, y: 96 + Double(index * 288)),
                size: .init(width: 320, height: 240)
            )
        }
        let sourceConnection = CanvasConnection(
            sourceNodeID: reference.id,
            destinationNodeID: configuration.id,
            kind: .source,
            sourcePort: .trailing,
            destinationPort: .leading
        )
        let resultConnections = results.map { result in
            CanvasConnection(
                sourceNodeID: configuration.id,
                destinationNodeID: result.id,
                kind: .generatedFrom,
                sourcePort: .trailing,
                destinationPort: .leading
            )
        }
        var persisted = initial
        persisted.documents = [CanvasDocument(
            id: documentID,
            name: "Canvas 1",
            nodes: [reference, configuration] + results,
            connections: [sourceConnection] + resultConnections
        )]
        persisted.revision = initial.revision + 1

        // This is the production file repository: save uses the canonical
        // CanvasProject codec and an atomic file replacement, while project
        // reloads that file through the same codec used by the app.
        try await repository.save(persisted, expectedRevision: initial.revision)
        let reloaded = try await repository.project(canvasID: canvasID)
        let reloadedConnections = try #require(reloaded.documents.first?.connections)
        #expect(reloadedConnections.count == 5)
        #expect(reloadedConnections.filter { $0.kind == .source }.count == 1)
        #expect(reloadedConnections.filter { $0.kind == .generatedFrom }.count == 4)

        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let runID = UUID()
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(.init(
            id: conversationID,
            title: "Canvas relationship round trip",
            createdAt: Date(),
            updatedAt: Date()
        ))
        try await environment.runStore.saveRun(.init(
            id: runID,
            conversationID: conversationID,
            state: "preparing",
            goal: "Inspect persisted canvas relationships",
            startedAt: Date()
        ))
        try await CanvasRunContextStore(database: environment.database).save(.init(
            runID: runID,
            conversationID: conversationID,
            canvasID: canvasID,
            documentID: documentID,
            selectedNodeIDs: [],
            projectRevision: reloaded.revision
        ))
        let registry = ToolRunnerRegistry()
        registerCanvasAgentTools(environment: environment, registry: registry)

        for toolName in ["canvas.getState"] {
            let runner = try #require(registry.runner(named: toolName))
            let output = try await runner.execute(
                argumentsJSON: Data(#"{"limit":30}"#.utf8),
                context: ToolContext(runID: runID, cancellation: CancellationToken())
            )
            let page = try JSONDecoder().decode(
                CanvasInspectionPayload.self,
                from: Data(output.summary.utf8)
            )
            #expect(page.canvasID == canvasID)
            #expect(page.documentID == documentID)
            #expect(page.revision == reloaded.revision)
            #expect(page.connections.count == 5)
            let sources = page.connections.filter { $0.kind == .source }
            #expect(sources.count == 1)
            #expect(sources.first?.sourceNodeID == reference.id)
            #expect(sources.first?.destinationNodeID == configuration.id)

            let generated = page.connections.filter { $0.kind == .generatedFrom }
            #expect(generated.count == 4)
            #expect(generated.allSatisfy { $0.sourceNodeID == configuration.id })
            #expect(Set(generated.map(\.destinationNodeID)) == Set(results.map(\.id)))
            #expect(Set(generated.map(\.destinationNodeID)).count == 4)
        }
    }

    @MainActor
    @Test("canvas.applyOperations source disconnect atomically updates generation fallback")
    func agentSourceDisconnectKeepsGenerationMetadataCanonical() async throws {
        let canvasID = UUID()
        defer { try? WorkspaceCanvasRegistry.delete(canvasID: canvasID) }
        try WorkspaceCanvasRegistry.createIfNeeded(
            canvasID: canvasID,
            name: "Agent source disconnect",
            workspaceID: nil
        )

        let repository = FileCanvasDocumentRepository()
        let initial = try await repository.project(canvasID: canvasID)
        let documentID = initial.selectedDocumentID
        let firstSource = CanvasNode(
            kind: .image,
            position: .init(x: 80, y: 80), size: .init(width: 240, height: 180)
        )
        let secondSource = CanvasNode(
            kind: .image,
            position: .init(x: 80, y: 360), size: .init(width: 240, height: 180)
        )
        let expectedSources = [firstSource.id, secondSource.id]
            .sorted { $0.uuidString < $1.uuidString }
        let task = CanvasNode(
            kind: .generationTask,
            title: "Generate four",
            position: .init(x: 480, y: 80),
            size: .init(width: 340, height: 210),
            metadata: [
                "generationPrompt": "Generate four variants",
                "generationSourceNodeIDs": expectedSources
                    .map(\.uuidString)
                    .joined(separator: ",")
            ]
        )
        let results = (0..<4).map { index in
            CanvasNode(
                kind: .image,
                title: "Result \(index + 1)",
                position: .init(x: 900, y: 80 + Double(index * 280)),
                size: .init(width: 320, height: 260)
            )
        }
        let sourceEdges = [firstSource, secondSource].map { source in
            CanvasConnection(
                sourceNodeID: source.id,
                destinationNodeID: task.id,
                kind: .source,
                sourcePort: .trailing,
                destinationPort: .leading
            )
        }
        let resultEdges = results.map { result in
            CanvasConnection(
                sourceNodeID: task.id,
                destinationNodeID: result.id,
                kind: .generatedFrom,
                sourcePort: .trailing,
                destinationPort: .leading
            )
        }
        var persisted = initial
        persisted.documents = [CanvasDocument(
            id: documentID,
            name: "Canvas 1",
            nodes: [firstSource, secondSource, task] + results,
            connections: sourceEdges + resultEdges
        )]
        persisted.revision = initial.revision + 1
        try await repository.save(persisted, expectedRevision: initial.revision)

        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let runID = UUID()
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(.init(
            id: conversationID,
            title: "Agent source disconnect",
            createdAt: Date(),
            updatedAt: Date()
        ))
        try await environment.runStore.saveRun(.init(
            id: runID,
            conversationID: conversationID,
            state: "preparing",
            goal: "Disconnect generation references",
            startedAt: Date(),
            conversationMode: "chat"
        ))
        try await CanvasRunContextStore(database: environment.database).save(.init(
            runID: runID,
            conversationID: conversationID,
            canvasID: canvasID,
            documentID: documentID,
            selectedNodeIDs: [],
            projectRevision: persisted.revision
        ))
        let registry = ToolRunnerRegistry()
        registerCanvasAgentTools(environment: environment, registry: registry)
        let inspectRunner = try #require(registry.runner(named: "canvas.getState"))
        let applyRunner = try #require(registry.runner(named: "canvas.applyOperations"))
        let context = ToolContext(runID: runID, cancellation: CancellationToken())

        let initialInspection = try await inspectRunner.execute(
            argumentsJSON: Data(#"{"limit":30}"#.utf8),
            context: context
        )
        let initialPage = try JSONDecoder().decode(
            CanvasInspectionPayload.self,
            from: Data(initialInspection.summary.utf8)
        )
        let firstConnectionID = try #require(initialPage.connections.first {
            $0.kind == .source && $0.sourceNodeID == firstSource.id
        }?.id)
        _ = try await applyRunner.execute(
            argumentsJSON: try JSONEncoder().encode(CanvasApplyOperationsPayload(
                patch: CanvasPatch(
                    canvasID: canvasID,
                    documentID: documentID,
                    expectedRevision: initialPage.revision,
                    operations: [CanvasPatchOperation(
                        kind: .disconnect,
                        connectionID: firstConnectionID
                    )]
                )
            )),
            context: context
        )

        let afterFirst = try await repository.project(canvasID: canvasID)
        let afterFirstDocument = try #require(afterFirst.documents.first {
            $0.id == documentID
        })
        #expect(afterFirst.revision == initialPage.revision + 1)
        #expect(afterFirstDocument.connections.filter {
            $0.kind == .source && $0.destinationNodeID == task.id
        }.map(\.sourceNodeID) == [secondSource.id])
        #expect(afterFirstDocument.nodes.first(where: { $0.id == task.id })?
            .metadata["generationSourceNodeIDs"] == secondSource.id.uuidString)
        #expect(afterFirstDocument.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == task.id
        }.count == 4)

        // Inspect again so the second disconnect uses the connection identity
        // and revision actually returned by the production tool path.
        let secondInspection = try await inspectRunner.execute(
            argumentsJSON: Data(#"{"limit":30}"#.utf8),
            context: context
        )
        let secondPage = try JSONDecoder().decode(
            CanvasInspectionPayload.self,
            from: Data(secondInspection.summary.utf8)
        )
        let lastConnectionID = try #require(secondPage.connections.first {
            $0.kind == .source && $0.sourceNodeID == secondSource.id
        }?.id)
        _ = try await applyRunner.execute(
            argumentsJSON: try JSONEncoder().encode(CanvasApplyOperationsPayload(
                patch: CanvasPatch(
                    canvasID: canvasID,
                    documentID: documentID,
                    expectedRevision: secondPage.revision,
                    operations: [CanvasPatchOperation(
                        kind: .disconnect,
                        connectionID: lastConnectionID
                    )]
                )
            )),
            context: context
        )

        let finalProject = try await repository.project(canvasID: canvasID)
        let finalDocument = try #require(finalProject.documents.first {
            $0.id == documentID
        })
        #expect(finalProject.revision == secondPage.revision + 1)
        #expect(!finalDocument.connections.contains {
            $0.kind == .source && $0.destinationNodeID == task.id
        })
        #expect(finalDocument.nodes.first(where: { $0.id == task.id })?
            .metadata["generationSourceNodeIDs"] == "")
        #expect(finalDocument.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == task.id
        }.count == 4)
        #expect(try CanvasGenerationContextResolver.resolvedNodeIDs(
            requestedIDs: nil,
            configurationNodeID: task.id,
            document: finalDocument
        ).isEmpty)
    }

    @MainActor
    @Test("Generated image assets settle only after an active canvas commit")
    func generatedImageAssetsSettleAfterCommitAndDiscardOtherwise() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        var canvasIDs: [UUID] = []
        defer {
            for canvasID in canvasIDs {
                try? WorkspaceCanvasRegistry.delete(canvasID: canvasID)
            }
        }

        let committedAssets = generatedAssets(count: 4, prefix: "committed")
        let committedProbe = CanvasGeneratedAssetLifecycleProbe()
        let committed = try await generationFixture(
            environment: environment,
            assets: committedAssets,
            probe: committedProbe,
            mutatePreparedEdges: true
        )
        canvasIDs.append(committed.canvasID)
        let outcome = try await generateImageBatch(committed)
        #expect(outcome.resultNodeIDs.count == 4)
        #expect(Set(outcome.resultNodeIDs).count == 4)
        let committedProject = try await FileCanvasDocumentRepository()
            .project(canvasID: committed.canvasID)
        let committedDocument = try #require(
            committedProject.documents.first(where: {
                $0.id == committed.initialProject.selectedDocumentID
            })
        )
        let task = try #require(committedDocument.nodes.first(where: {
            $0.id == outcome.configurationNodeID
        }))
        let resultNodes = outcome.resultNodeIDs.compactMap { resultID in
            committedDocument.nodes.first(where: { $0.id == resultID })
        }
        #expect(resultNodes.count == 4)
        #expect(Set(resultNodes.compactMap { $0.asset?.id }) == Set(committedAssets.map(\.id)))
        let resultList = outcome.resultNodeIDs.map(\.uuidString).joined(separator: ",")
        let sourceList = committed.sourceNodeID.uuidString
        #expect(task.metadata["generationResultNodeIDs"] == resultList)
        #expect(task.metadata["generationSourceNodeIDs"] == sourceList)
        #expect(resultNodes.allSatisfy {
            $0.metadata["generationResultNodeIDs"] == resultList
                && $0.metadata["generationSourceNodeIDs"] == sourceList
        })
        let generatedEdges = committedDocument.connections.filter {
            $0.kind == .generatedFrom
                && $0.sourceNodeID == outcome.configurationNodeID
        }
        #expect(generatedEdges.count == 4)
        #expect(Set(generatedEdges.map(\.destinationNodeID)) == Set(outcome.resultNodeIDs))
        let sourceEdges = committedDocument.connections.filter {
            $0.kind == .source
                && $0.destinationNodeID == outcome.configurationNodeID
        }
        #expect(sourceEdges.count == 1)
        #expect(sourceEdges.first?.sourceNodeID == committed.sourceNodeID)
        let resultGroupIDs = Set(resultNodes.compactMap(\.groupID))
        let groupID = try #require(resultGroupIDs.first)
        #expect(resultGroupIDs.count == 1)
        #expect(task.metadata["generationGroupID"] == groupID.uuidString)
        #expect(committedDocument.nodes.contains {
            $0.id == groupID && $0.kind == .group
        })
        #expect(Set(resultNodes.map { $0.position.x }).count == 1)
        #expect(Set(resultNodes.map { $0.position.y }).count == 4)
        let committedSnapshot = await committedProbe.snapshot()
        #expect(committedSnapshot.marked == [committedAssets.map(\.id)])
        #expect(committedSnapshot.discarded.isEmpty)

        let shortAssets = generatedAssets(count: 3, prefix: "short")
        let shortProbe = CanvasGeneratedAssetLifecycleProbe()
        let short = try await generationFixture(
            environment: environment,
            assets: shortAssets,
            probe: shortProbe
        )
        canvasIDs.append(short.canvasID)
        var rejectedShortBatch = false
        do {
            _ = try await generateImageBatch(short)
        } catch {
            rejectedShortBatch = true
        }
        #expect(rejectedShortBatch)
        let shortSnapshot = await shortProbe.snapshot()
        #expect(shortSnapshot.marked.isEmpty)
        #expect(shortSnapshot.discarded == [shortAssets.map(\.id)])

        let supersededAssets = generatedAssets(count: 4, prefix: "superseded")
        let supersededProbe = CanvasGeneratedAssetLifecycleProbe()
        let superseded = try await generationFixture(
            environment: environment,
            assets: supersededAssets,
            probe: supersededProbe,
            supersedeSecondResult: true
        )
        canvasIDs.append(superseded.canvasID)
        var rejectedSupersededBatch = false
        do {
            _ = try await generateImageBatch(superseded)
        } catch {
            rejectedSupersededBatch = true
        }
        #expect(rejectedSupersededBatch)
        let supersededSnapshot = await supersededProbe.snapshot()
        #expect(supersededSnapshot.marked.isEmpty)
        #expect(supersededSnapshot.discarded == [supersededAssets.map(\.id)])

        let missingSourceProbe = CanvasGeneratedAssetLifecycleProbe()
        let missingSource = try await generationFixture(
            environment: environment,
            assets: [],
            probe: missingSourceProbe,
            deleteSourceBeforeFailure: true
        )
        canvasIDs.append(missingSource.canvasID)
        var rejectedMissingSource = false
        do {
            _ = try await generateImageBatch(missingSource)
        } catch {
            rejectedMissingSource = true
        }
        #expect(rejectedMissingSource)
        let missingSourceProject = try await FileCanvasDocumentRepository()
            .project(canvasID: missingSource.canvasID)
        let missingSourceDocument = try #require(
            missingSourceProject.documents.first(where: {
                $0.id == missingSource.initialProject.selectedDocumentID
            })
        )
        #expect(!missingSourceDocument.nodes.contains {
            $0.id == missingSource.sourceNodeID
        })
        let failedTask = try #require(missingSourceDocument.nodes.first {
            $0.kind == .generationTask
                && $0.createdByRunID == missingSource.runID
        })
        let failedResultIDs = failedTask.metadata["generationResultNodeIDs"]?
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) } ?? []
        #expect(failedResultIDs.count == 4)
        #expect(failedTask.metadata["generationState"]
            == CanvasGenerationTaskState.failed.rawValue)
        #expect(failedTask.metadata["generationError"]?.isEmpty == false)
        #expect(failedResultIDs.allSatisfy { resultID in
            guard let result = missingSourceDocument.nodes.first(where: {
                $0.id == resultID
            }) else { return false }
            return result.metadata["generationState"]
                    == CanvasGenerationTaskState.failed.rawValue
                && result.metadata["generationError"]?.isEmpty == false
        })
        #expect(!missingSourceDocument.connections.contains {
            $0.kind == .source && $0.destinationNodeID == failedTask.id
        })
        let missingSourceSnapshot = await missingSourceProbe.snapshot()
        #expect(missingSourceSnapshot.marked.isEmpty)
        #expect(missingSourceSnapshot.discarded.isEmpty)

        let videoProbe = CanvasGeneratedAssetLifecycleProbe()
        let video = try await generationFixture(
            environment: environment,
            assets: [],
            probe: videoProbe
        )
        canvasIDs.append(video.canvasID)
        var rejectedVideo = false
        do {
            _ = try await video.coordinator.generateMedia(
                runID: video.runID,
                kind: .video,
                modelID: UUID(),
                prompt: "Synthetic video failure",
                documentID: video.initialProject.selectedDocumentID,
                sourceNodeIDs: [],
                configurationNodeID: nil,
                position: .init(x: 720, y: 120),
                expectedRevision: video.initialProject.revision,
                aspectRatio: nil,
                quality: nil,
                count: 1,
                durationSeconds: 5
            )
        } catch {
            rejectedVideo = true
        }
        #expect(rejectedVideo)
        let videoSnapshot = await videoProbe.snapshot()
        #expect(videoSnapshot.marked.isEmpty)
        #expect(videoSnapshot.discarded.isEmpty)
    }

    @MainActor
    private func generationFixture(
        environment: AppEnvironment,
        assets: [CanvasAssetReference],
        probe: CanvasGeneratedAssetLifecycleProbe,
        supersedeSecondResult: Bool = false,
        mutatePreparedEdges: Bool = false,
        deleteSourceBeforeFailure: Bool = false
    ) async throws -> CanvasGenerationFixture {
        let canvasID = UUID()
        let runID = UUID()
        let conversationID = UUID()
        try WorkspaceCanvasRegistry.createIfNeeded(
            canvasID: canvasID,
            name: "Generated asset lifecycle",
            workspaceID: nil
        )
        let repository = FileCanvasDocumentRepository()
        var initialProject = try await repository.project(canvasID: canvasID)
        let sourceNode = CanvasNode(
            kind: .text,
            text: "Explicit generation context",
            position: .init(x: 120, y: 120),
            size: .init(width: 280, height: 160)
        )
        guard let documentIndex = initialProject.documents.firstIndex(where: {
            $0.id == initialProject.selectedDocumentID
        }) else {
            throw FloeError.internalError("Initial canvas document is missing")
        }
        let initialRevision = initialProject.revision
        initialProject.documents[documentIndex].nodes.append(sourceNode)
        initialProject.revision += 1
        initialProject.updatedAt = Date()
        try await repository.save(initialProject, expectedRevision: initialRevision)
        try await environment.conversationStore.saveConversation(.init(
            id: conversationID,
            title: "Generated asset lifecycle",
            createdAt: Date(),
            updatedAt: Date()
        ))
        try await environment.runStore.saveRun(.init(
            id: runID,
            conversationID: conversationID,
            state: "preparing",
            goal: "Generate media",
            startedAt: Date()
        ))
        let runContexts = CanvasRunContextStore(database: environment.database)
        try await runContexts.save(.init(
            runID: runID,
            conversationID: conversationID,
            canvasID: canvasID,
            documentID: initialProject.selectedDocumentID,
            selectedNodeIDs: [],
            projectRevision: initialProject.revision
        ))
        let coordinator = CanvasToolCoordinator(
            repository: repository,
            assetStore: environment.creativeAssetStore,
            assetIngestion: CreativeAssetIngestionService(
                assetStore: environment.creativeAssetStore
            ),
            jobs: MediaGenerationJobStore(database: environment.database),
            runContexts: runContexts,
            conversationIDForRun: { _ in conversationID },
            generateImages: { _, _, _, _, _ in
                if supersedeSecondResult || mutatePreparedEdges
                    || deleteSourceBeforeFailure {
                    var current = try await repository.project(canvasID: canvasID)
                    guard let documentIndex = current.documents.firstIndex(where: {
                        $0.id == current.selectedDocumentID
                    }),
                    let configuration = current.documents[documentIndex].nodes.first(where: {
                        $0.kind == .generationTask && $0.createdByRunID == runID
                    }) else {
                        throw FloeError.internalError("Prepared generation graph is missing")
                    }
                    let resultIDs = configuration.metadata["generationResultNodeIDs"]?
                        .split(separator: ",")
                        .compactMap { UUID(uuidString: String($0)) } ?? []
                    guard resultIDs.count >= 2,
                          let resultIndex = current.documents[documentIndex].nodes.firstIndex(where: {
                              $0.id == resultIDs[1]
                          }) else {
                        throw FloeError.internalError("Second generated result is missing")
                    }
                    let expectedRevision = current.revision
                    if supersedeSecondResult {
                        current.documents[documentIndex].nodes[resultIndex]
                            .metadata["generationAttemptID"] = UUID().uuidString
                    }
                    if mutatePreparedEdges {
                        let redirectedSource = CanvasNode(
                            kind: .text,
                            text: "Unrelated context added while provider was running",
                            position: .init(x: 120, y: 480),
                            size: .init(width: 280, height: 160)
                        )
                        let staleResult = CanvasNode(
                            kind: .image,
                            position: .init(x: 1_200, y: 1_200),
                            size: .init(width: 320, height: 260)
                        )
                        current.documents[documentIndex].nodes.append(contentsOf: [
                            redirectedSource,
                            staleResult
                        ])
                        current.documents[documentIndex].connections.removeAll { connection in
                            (connection.kind == .source
                                && connection.destinationNodeID == configuration.id)
                                || (connection.kind == .generatedFrom
                                    && connection.sourceNodeID == configuration.id
                                    && connection.destinationNodeID == resultIDs[1])
                        }
                        current.documents[documentIndex].connections.append(contentsOf: [
                            CanvasConnection(
                                sourceNodeID: redirectedSource.id,
                                destinationNodeID: configuration.id,
                                kind: .source
                            ),
                            CanvasConnection(
                                sourceNodeID: configuration.id,
                                destinationNodeID: staleResult.id,
                                kind: .generatedFrom
                            )
                        ])
                    }
                    if deleteSourceBeforeFailure {
                        current.documents[documentIndex].nodes.removeAll {
                            $0.id == sourceNode.id
                        }
                        current.documents[documentIndex].connections.removeAll {
                            $0.sourceNodeID == sourceNode.id
                                || $0.destinationNodeID == sourceNode.id
                        }
                    }
                    current.revision += 1
                    current.updatedAt = Date()
                    try await repository.save(current, expectedRevision: expectedRevision)
                    if deleteSourceBeforeFailure {
                        throw FloeError.internalError(
                            "Synthetic provider failure after source deletion"
                        )
                    }
                }
                return ReservedGeneratedImageBatch(
                    reservationID: UUID(),
                    assets: assets
                )
            },
            markGeneratedAssetsReferenced: { batch in
                await probe.recordMarked(batch.assets)
            },
            discardUnreferencedGeneratedAssets: { batch in
                await probe.recordDiscarded(batch.assets)
            },
            submitVideo: { _, _, _, _, _, _ in
                throw FloeError.internalError("Synthetic video submission failure")
            }
        )
        return CanvasGenerationFixture(
            canvasID: canvasID,
            runID: runID,
            sourceNodeID: sourceNode.id,
            initialProject: initialProject,
            coordinator: coordinator
        )
    }

    private func generatedAssets(count: Int, prefix: String) -> [CanvasAssetReference] {
        (0..<count).map { index in
            CanvasAssetReference(
                contentHash: "\(prefix)-\(index)",
                mimeType: "image/png",
                byteCount: 1
            )
        }
    }

    private func generateImageBatch(
        _ fixture: CanvasGenerationFixture
    ) async throws -> CanvasGenerationOutcome {
        try await fixture.coordinator.generateMedia(
            runID: fixture.runID,
            kind: .image,
            modelID: nil,
            prompt: "Generate four images",
            documentID: fixture.initialProject.selectedDocumentID,
            sourceNodeIDs: [fixture.sourceNodeID],
            configurationNodeID: nil,
            position: .init(x: 720, y: 120),
            expectedRevision: fixture.initialProject.revision,
            aspectRatio: "1:1",
            quality: nil,
            count: 4,
            durationSeconds: nil
        )
    }
}
#endif
