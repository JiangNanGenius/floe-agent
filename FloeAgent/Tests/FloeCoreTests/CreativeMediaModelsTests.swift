import Foundation
import Testing
@testable import FloeCore

@Suite("Creative media contracts")
struct CreativeMediaModelsTests {
    @Test func jobStateIsMonotonicAndTerminal() {
        #expect(MediaGenerationJobState.preparing.canTransition(to: .submitted))
        #expect(MediaGenerationJobState.submitted.canTransition(to: .running))
        #expect(MediaGenerationJobState.running.canTransition(to: .completed))
        #expect(MediaGenerationJobState.completed.canTransition(to: .downloading))
        #expect(MediaGenerationJobState.downloading.canTransition(to: .ready))
        #expect(!MediaGenerationJobState.completed.canTransition(to: .running))
        #expect(!MediaGenerationJobState.ready.canTransition(to: .downloading))
        #expect(MediaGenerationJobState.running.canTransition(to: .failed))
    }

    @Test func officialCatalogHasRequiredFirstPartyFamiliesAndNoSoraPreset() {
        let models = OfficialMediaModelCatalog.models
        #expect(models.contains { $0.provider == .openAI && $0.kind == .image })
        #expect(models.contains { $0.provider == .googleGemini && $0.kind == .video })
        #expect(models.contains { $0.provider == .volcengineArk && $0.kind == .video })
        #expect(models.contains { $0.provider == .alibabaModelStudio && $0.kind == .video })
        #expect(!models.contains { $0.remoteModelID.localizedCaseInsensitiveContains("sora") })
        #expect(Set(models.map(\.id)).count == models.count)
    }

    @Test func imageCatalogSeparatesResolutionFromQuality() throws {
        let openAI = try #require(OfficialMediaModelCatalog.models.first {
            $0.remoteModelID == "gpt-image-2"
        })
        #expect(openAI.supportedResolutions == ["1K"])
        #expect(openAI.supportedQualities == ["low", "medium", "high"])
        #expect(openAI.defaultQuality == "medium")

        let ark = try #require(OfficialMediaModelCatalog.models.first {
            $0.remoteModelID == "doubao-seedream-4-0-250828"
        })
        #expect(ark.supportedResolutions == ["1K", "2K", "4K"])
        #expect(ark.supportedQualities.isEmpty)
        #expect(ark.defaultResolution == "2K")
    }

    @Test func canvasSchemaRoundTripsTypedNodesAndConnections() throws {
        let source = CanvasNode(
            kind: .text, text: "prompt",
            position: .init(x: 100, y: 100), size: .init(width: 280, height: 160)
        )
        let result = CanvasNode(
            kind: .generationTask, title: "Generating",
            position: .init(x: 460, y: 100), size: .init(width: 320, height: 220)
        )
        let document = CanvasDocument(
            name: "Canvas 1", nodes: [source, result],
            connections: [.init(
                sourceNodeID: source.id,
                destinationNodeID: result.id,
                kind: .generatedFrom,
                sourcePort: .trailing,
                destinationPort: .leading
            )]
        )
        let project = CanvasProject(
            id: UUID(), name: "Private", documents: [document], selectedDocumentID: document.id
        )
        let decoded = try JSONDecoder().decode(CanvasProject.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
        #expect(decoded.schemaVersion == CanvasProject.currentSchemaVersion)
        #expect(decoded.documents[0].connections[0].sourcePort == .trailing)
        #expect(decoded.documents[0].connections[0].destinationPort == .leading)
    }

    @Test func legacyProjectBindsSelectedAssistantConversationToSelectedCanvas() throws {
        let projectID = UUID(), documentID = UUID(), conversationID = UUID(), sessionID = UUID()
        let data = Data("""
        {
          "id":"\(projectID.uuidString)",
          "schemaVersion":6,
          "name":"Legacy",
          "documents":[{"id":"\(documentID.uuidString)","name":"画布 1"}],
          "selectedDocumentID":"\(documentID.uuidString)",
          "agentConversationID":"\(conversationID.uuidString)",
          "assistantSessions":[{
            "id":"\(sessionID.uuidString)",
            "conversationID":"\(conversationID.uuidString)",
            "title":"旧会话",
            "createdAt":0,
            "updatedAt":0
          }],
          "selectedAssistantSessionID":"\(sessionID.uuidString)"
        }
        """.utf8)

        let project = try CanvasProjectCodec.decode(data)
        #expect(project.schemaVersion == CanvasProject.currentSchemaVersion)
        #expect(project.agentConversationIDsByDocument[documentID] == conversationID)
    }

    @Test func projectRoundTripPreservesIndependentCanvasConversations() throws {
        let first = CanvasDocument(name: "画布 1")
        let second = CanvasDocument(name: "画布 2")
        let firstConversationID = UUID()
        let secondConversationID = UUID()
        let project = CanvasProject(
            id: UUID(),
            name: "Bound",
            documents: [first, second],
            selectedDocumentID: second.id,
            agentConversationID: secondConversationID,
            agentConversationIDsByDocument: [
                first.id: firstConversationID,
                second.id: secondConversationID
            ]
        )

        let decoded = try CanvasProjectCodec.decode(CanvasProjectCodec.encode(project))
        #expect(decoded.agentConversationIDsByDocument[first.id] == firstConversationID)
        #expect(decoded.agentConversationIDsByDocument[second.id] == secondConversationID)
        #expect(decoded.agentConversationID == secondConversationID)
    }

    @Test func miniMapGeometryCentersLetterboxingAndRoundTripsPoints() {
        let document = CanvasDocument(name: "Empty")
        let geometry = CanvasMiniMapGeometry(
            document: document,
            viewportCenter: CanvasPoint(x: 500, y: 350),
            viewportSize: CanvasSize(width: 1_000, height: 700),
            mapSize: CanvasSize(width: 200, height: 100),
            padding: 0
        )
        let mappedCenter = geometry.mapPoint(CanvasPoint(x: 500, y: 350))
        #expect(abs(mappedCenter.x - 100) < 0.001)
        #expect(abs(mappedCenter.y - 50) < 0.001)
        #expect(geometry.mapOffset.x > 0)
        #expect(abs(geometry.mapOffset.y) < 0.001)

        let source = CanvasPoint(x: 125, y: 620)
        let roundTrip = geometry.canvasPoint(geometry.mapPoint(source))
        #expect(abs(roundTrip.x - source.x) < 0.001)
        #expect(abs(roundTrip.y - source.y) < 0.001)
    }

    @Test func miniMapGeometryIncludesDistantNodesAndStrokes() {
        let node = CanvasNode(
            kind: .card,
            position: CanvasPoint(x: 2_000, y: -900),
            size: CanvasSize(width: 400, height: 200)
        )
        let stroke = CanvasStroke(points: [CanvasPoint(x: -1_500, y: 1_200)])
        let document = CanvasDocument(name: "Large", nodes: [node], strokes: [stroke])
        let geometry = CanvasMiniMapGeometry(
            document: document,
            viewportCenter: .init(x: 0, y: 0),
            viewportSize: .init(width: 1_000, height: 700),
            mapSize: .init(width: 180, height: 112)
        )

        let mappedNode = geometry.mapPoint(node.position)
        let mappedStroke = geometry.mapPoint(stroke.points[0])
        #expect((0...180).contains(mappedNode.x))
        #expect((0...112).contains(mappedNode.y))
        #expect((0...180).contains(mappedStroke.x))
        #expect((0...112).contains(mappedStroke.y))
    }

    @Test func legacyConnectionWithoutPortsRemainsReadable() throws {
        let sourceID = UUID(), destinationID = UUID()
        let data = Data("""
        {
          "id":"\(UUID().uuidString)",
          "sourceNodeID":"\(sourceID.uuidString)",
          "destinationNodeID":"\(destinationID.uuidString)",
          "kind":"arrow"
        }
        """.utf8)

        let connection = try JSONDecoder().decode(CanvasConnection.self, from: data)
        #expect(connection.sourcePort == nil)
        #expect(connection.destinationPort == nil)
    }

    @Test func canvasSchemaRoundTripsNative3DDirectorScene() throws {
        var scene = CanvasScene3D.starter()
        scene.name = "产品导演台"
        scene.objects.append(CanvasSceneObject(
            name: "背景球",
            kind: .sphere,
            position: .init(x: 1.5, y: 0.8, z: -0.5),
            rotation: .init(x: 0, y: 35, z: 0),
            scale: .init(x: 0.7, y: 0.7, z: 0.7),
            colorHex: "#7C5CFC",
            roughness: 0.2,
            metallic: true
        ))
        let node = CanvasNode(
            kind: .scene3D,
            title: "产品镜头",
            position: .init(x: 180, y: 140),
            size: .init(width: 420, height: 300),
            scene3D: scene
        )
        let document = CanvasDocument(name: "导演台", nodes: [node])
        let project = CanvasProject(
            id: UUID(),
            name: "3D 测试",
            documents: [document],
            selectedDocumentID: document.id
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(CanvasProject.self, from: data)
        #expect(decoded == project)
        #expect(decoded.documents[0].nodes[0].scene3D?.objects.count == 2)
        #expect(decoded.schemaVersion == CanvasProject.currentSchemaVersion)
    }

    @Test func canvasPatchIsAtomicRevisionCheckedAndConnectsCreatedNodes() throws {
        let document = CanvasDocument(name: "Canvas")
        let project = CanvasProject(
            id: UUID(), name: "Patch", documents: [document],
            selectedDocumentID: document.id, revision: 7
        )
        let sourceID = UUID(), resultID = UUID(), connectionID = UUID()
        let patch = CanvasPatch(
            canvasID: project.id, documentID: document.id, expectedRevision: 7,
            operations: [
                CanvasPatchOperation(
                    kind: .create, nodeID: sourceID, nodeKind: .text,
                    text: "Prompt", position: .init(x: 100, y: 100)
                ),
                CanvasPatchOperation(
                    kind: .create, nodeID: resultID, nodeKind: .card,
                    text: "Result", position: .init(x: 460, y: 100)
                ),
                CanvasPatchOperation(
                    kind: .connect, sourceNodeID: sourceID,
                    destinationNodeID: resultID, connectionID: connectionID,
                    connectionKind: .generatedFrom,
                    sourcePort: .trailing, destinationPort: .leading,
                    label: "AI result"
                )
            ]
        )
        let (updated, result) = try CanvasCommandService.applying(patch, to: project)
        #expect(updated.revision == 8)
        #expect(Set(result.changedNodeIDs) == [sourceID, resultID])
        #expect(result.changedConnectionIDs == [connectionID])
        #expect(updated.documents[0].connections[0].sourcePort == .trailing)
        #expect(updated.documents[0].connections[0].kind == .generatedFrom)

        var stale = patch
        stale.expectedRevision = 6
        #expect(throws: FloeError.self) {
            _ = try CanvasCommandService.applying(stale, to: project)
        }
    }

    @Test func invalidCanvasPatchDoesNotPartiallyMutateInput() throws {
        let existing = CanvasNode.placeholder(kind: .card, position: .init(x: 0, y: 0))
        let document = CanvasDocument(name: "Canvas", nodes: [existing])
        let project = CanvasProject(
            id: UUID(), name: "Atomic", documents: [document],
            selectedDocumentID: document.id
        )
        let patch = CanvasPatch(
            canvasID: project.id, documentID: document.id, expectedRevision: 0,
            operations: [
                CanvasPatchOperation(
                    kind: .update, nodeID: existing.id, text: "changed"
                ),
                CanvasPatchOperation(
                    kind: .connect, sourceNodeID: existing.id,
                    destinationNodeID: UUID()
                )
            ]
        )
        #expect(throws: FloeError.self) {
            _ = try CanvasCommandService.applying(patch, to: project)
        }
        #expect(project.documents[0].nodes[0].text == existing.text)
        #expect(project.revision == 0)
    }

    @Test func canvasArrangeUsesGraphDepthAvoidsOverlapAndPreservesLockedNodes() throws {
        var prompt = CanvasNode.placeholder(kind: .text, position: .init(x: 500, y: 400))
        prompt.size = .init(width: 260, height: 150)
        var configuration = CanvasNode.placeholder(
            kind: .generationTask, position: .init(x: 120, y: 80)
        )
        configuration.size = .init(width: 340, height: 210)
        var result = CanvasNode.placeholder(kind: .image, position: .init(x: 240, y: 900))
        result.size = .init(width: 320, height: 260)
        var lockedNote = CanvasNode.placeholder(kind: .stickyNote, position: .init(x: 900, y: 75))
        lockedNote.isLocked = true
        let originalLockedPosition = lockedNote.position
        let document = CanvasDocument(
            name: "Canvas",
            nodes: [result, lockedNote, configuration, prompt],
            connections: [
                CanvasConnection(sourceNodeID: prompt.id, destinationNodeID: configuration.id),
                CanvasConnection(sourceNodeID: configuration.id, destinationNodeID: result.id)
            ]
        )
        let project = CanvasProject(
            id: UUID(), name: "Arrange", documents: [document],
            selectedDocumentID: document.id
        )
        let patch = CanvasPatch(
            canvasID: project.id, documentID: document.id, expectedRevision: 0,
            operations: [CanvasPatchOperation(
                kind: .arrange,
                nodeIDs: [prompt.id, configuration.id, result.id, lockedNote.id],
                arrangement: "horizontal"
            )]
        )

        let (updated, operation) = try CanvasCommandService.applying(patch, to: project)
        let nodes = updated.documents[0].nodes
        let arrangedPrompt = try #require(nodes.first { $0.id == prompt.id })
        let arrangedConfiguration = try #require(nodes.first { $0.id == configuration.id })
        let arrangedResult = try #require(nodes.first { $0.id == result.id })
        let preservedNote = try #require(nodes.first { $0.id == lockedNote.id })

        #expect(arrangedConfiguration.position.x - configuration.size.width / 2
            >= arrangedPrompt.position.x + prompt.size.width / 2 + 96)
        #expect(arrangedResult.position.x - result.size.width / 2
            >= arrangedConfiguration.position.x + configuration.size.width / 2 + 96)
        #expect(preservedNote.position == originalLockedPosition)
        #expect(Set(operation.changedNodeIDs) == [prompt.id, configuration.id, result.id])
    }

    @Test func canvasGroupCreatesMovableContainerAndUngroupRemovesIt() throws {
        let first = CanvasNode.placeholder(kind: .card, position: .init(x: 100, y: 120))
        let second = CanvasNode.placeholder(kind: .stickyNote, position: .init(x: 420, y: 180))
        let document = CanvasDocument(name: "Canvas", nodes: [first, second])
        let project = CanvasProject(
            id: UUID(), name: "Groups", documents: [document],
            selectedDocumentID: document.id
        )
        let groupID = UUID()
        let groupPatch = CanvasPatch(
            canvasID: project.id, documentID: document.id, expectedRevision: 0,
            operations: [CanvasPatchOperation(
                kind: .group, nodeID: groupID, nodeIDs: [first.id, second.id]
            )]
        )
        let (grouped, _) = try CanvasCommandService.applying(groupPatch, to: project)
        let container = try #require(grouped.documents[0].nodes.first { $0.id == groupID })
        #expect(container.kind == .group)
        #expect(grouped.documents[0].nodes.filter { $0.groupID == groupID }.count == 2)

        let originalFirst = try #require(
            grouped.documents[0].nodes.first { $0.id == first.id }
        )
        let oldFirstPosition = originalFirst.position
        let movedPosition = CanvasPoint(
            x: container.position.x + 75, y: container.position.y - 30
        )
        let movePatch = CanvasPatch(
            canvasID: grouped.id, documentID: document.id,
            expectedRevision: grouped.revision,
            operations: [CanvasPatchOperation(
                kind: .update, nodeID: groupID, position: movedPosition
            )]
        )
        let (moved, _) = try CanvasCommandService.applying(movePatch, to: grouped)
        let movedFirst = try #require(moved.documents[0].nodes.first { $0.id == first.id })
        #expect(movedFirst.position.x == oldFirstPosition.x + 75)
        #expect(movedFirst.position.y == oldFirstPosition.y - 30)

        let ungroupPatch = CanvasPatch(
            canvasID: moved.id, documentID: document.id,
            expectedRevision: moved.revision,
            operations: [CanvasPatchOperation(kind: .ungroup, nodeID: groupID)]
        )
        let (ungrouped, _) = try CanvasCommandService.applying(ungroupPatch, to: moved)
        #expect(!ungrouped.documents[0].nodes.contains { $0.id == groupID })
        #expect(ungrouped.documents[0].nodes.allSatisfy { $0.groupID == nil })
    }

    @Test func legacyCanvasDecodesIntoCanonicalStoreWithoutLosingGeometry() throws {
        let fallbackID = UUID()
        let nodeID = UUID()
        let documentID = UUID()
        let legacy = """
        {
          "schemaVersion": 2,
          "name": "Legacy board",
          "selectedDocumentID": "\(documentID.uuidString)",
          "documents": [{
            "id": "\(documentID.uuidString)",
            "name": "Canvas 1",
            "nodes": [{
              "id": "\(nodeID.uuidString)",
              "kind": "text",
              "text": "preserved",
              "x": 123.5,
              "y": -44,
              "width": 320,
              "height": 180,
              "licenseStatus": "cleared"
            }],
            "strokes": []
          }]
        }
        """

        let project = try CanvasProjectCodec.decode(
            Data(legacy.utf8),
            fallbackID: fallbackID
        )
        guard let node = project.documents.first?.nodes.first else {
            throw FloeError.validationFailed("Legacy node was not restored")
        }

        #expect(project.id == fallbackID)
        #expect(project.schemaVersion == CanvasProject.currentSchemaVersion)
        #expect(node.id == nodeID)
        #expect(node.position == CanvasPoint(x: 123.5, y: -44))
        #expect(node.size == CanvasSize(width: 320, height: 180))
        #expect(node.text == "preserved")
        #expect(node.licenseStatus == "cleared")
        #expect(project.documents[0].connections.isEmpty)

        let canonical = try CanvasProjectCodec.encode(project)
        guard let object = try JSONSerialization.jsonObject(with: canonical) as? [String: Any],
              let documents = object["documents"] as? [[String: Any]],
              let firstDocument = documents.first,
              let nodes = firstDocument["nodes"] as? [[String: Any]],
              let encodedNode = nodes.first else {
            throw FloeError.validationFailed("Canonical canvas JSON was incomplete")
        }
        #expect(object["id"] as? String == fallbackID.uuidString)
        #expect(encodedNode["position"] != nil)
        #expect(encodedNode["size"] != nil)
        #expect(encodedNode["x"] == nil)
        #expect(encodedNode["width"] == nil)
    }

    @Test func generationPlannerKeepsPromptInConfigurationByDefault() throws {
        let source = CanvasNode(
            kind: .image, position: .init(x: 80, y: 120),
            size: .init(width: 240, height: 180)
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source])
        let runID = UUID()
        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: "  雾中雪山  ",
                sourceNodeIDs: [source.id],
                resultPosition: .init(x: 920, y: 240),
                createdByRunID: runID,
                metadata: ["generationFingerprint": "fingerprint"]
            ),
            document: document
        )
        let project = CanvasProject(
            id: UUID(), name: "Generation", documents: [document],
            selectedDocumentID: document.id
        )
        let patch = CanvasPatch(
            canvasID: project.id, documentID: document.id,
            expectedRevision: project.revision, operations: plan.operations
        )
        let (updated, _) = try CanvasCommandService.applying(patch, to: project)
        let nodes = updated.documents[0].nodes
        let configuration = try #require(nodes.first { $0.id == plan.configurationNodeID })
        let result = try #require(nodes.first { $0.id == plan.resultNodeID })

        #expect(plan.promptNodeID == configuration.id)
        #expect(!nodes.contains { $0.metadata["generationRole"] == "prompt" })
        #expect(configuration.kind == .generationTask)
        #expect(configuration.metadata["generationPrompt"] == "雾中雪山")
        #expect(configuration.metadata["generationFingerprint"] == "fingerprint")
        #expect(result.kind == .image)
        #expect(result.metadata["artifactOrigin"] == "generated")
        #expect(result.createdByRunID == runID)
        #expect(Set(plan.sourceNodeIDs) == [source.id])
        #expect(updated.documents[0].connections.contains {
            $0.sourceNodeID == configuration.id && $0.destinationNodeID == result.id
                && $0.kind == .generatedFrom
        })
    }

    @Test func oneReferenceAndCountFourCreatesFourAlignedIndependentResults() throws {
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 96),
            size: .init(width: 240, height: 180),
            asset: CanvasAssetReference(localRelativePath: "Materials/reference.png")
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source])
        let project = CanvasProject(
            id: UUID(), name: "Generation", documents: [document],
            selectedDocumentID: document.id, revision: 41
        )
        let attemptID = "four-output-attempt"
        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: "以参考图生成四个版本",
                sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 96),
                resultCount: 4,
                createdByRunID: UUID(),
                metadata: ["generationAttemptID": attemptID]
            ),
            document: document
        )

        #expect(plan.resultNodeIDs.count == 4)
        #expect(Set(plan.resultNodeIDs).count == 4)
        #expect(plan.resultPositions.count == 4)
        #expect(Set(plan.resultPositions.map(\.x)).count == 1)
        #expect(plan.resultPositions.allSatisfy {
            $0.x.truncatingRemainder(dividingBy: 24) == 0
                && $0.y.truncatingRemainder(dividingBy: 24) == 0
        })
        for pair in zip(plan.resultPositions, plan.resultPositions.dropFirst()) {
            #expect(pair.1.y - pair.0.y >= 260 + 48)
        }

        let preparedPatch = CanvasPatch(
            canvasID: project.id, documentID: document.id,
            expectedRevision: project.revision, operations: plan.operations
        )
        var (prepared, _) = try CanvasCommandService.applying(preparedPatch, to: project)
        let preparedDocument = prepared.documents[0]
        #expect(preparedDocument.nodes.first { $0.id == source.id }?.position == source.position)
        #expect(preparedDocument.connections.filter {
            $0.kind == .source && $0.sourceNodeID == source.id
                && $0.destinationNodeID == plan.configurationNodeID
        }.count == 1)
        #expect(preparedDocument.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == plan.configurationNodeID
                && plan.resultNodeIDs.contains($0.destinationNodeID)
        }.count == 4)
        #expect(plan.resultNodeIDs.allSatisfy { id in
            preparedDocument.nodes.contains { $0.id == id && $0.kind == .image }
        })

        let outputIDs = try CanvasGenerationOutputContract.resultNodeIDs(
            expectedCount: 4,
            actualCount: 4,
            preparedResultNodeIDs: plan.resultNodeIDs
        )
        let assets = (0..<4).map { index in
            CanvasAssetReference(
                contentHash: "result-\(index)",
                localRelativePath: "Materials/result-\(index).png"
            )
        }
        prepared.viewports[document.id] = .init(center: .init(x: 10, y: 20), scale: 0.8)
        prepared.revision += 1 // Simulate an unrelated in-flight canvas save.
        let completionPatch = try CanvasGenerationCommitPlanner.patch(
            project: prepared,
            documentID: document.id,
            configurationNodeID: plan.configurationNodeID,
            resultNodeIDs: plan.resultNodeIDs,
            generationAttemptID: attemptID,
            operations: zip(outputIDs, assets).map { resultID, asset in
                CanvasPatchOperation(
                    kind: .update, nodeID: resultID, nodeKind: .image,
                    text: "生成图片", asset: asset,
                    metadata: ["generationState": "ready"]
                )
            }
        )
        let (completed, _) = try CanvasCommandService.applying(completionPatch, to: prepared)
        let completedDocument = completed.documents[0]
        #expect(outputIDs.allSatisfy { id in
            completedDocument.nodes.first { $0.id == id }?.asset != nil
        })
        #expect(completedDocument.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == plan.configurationNodeID
        }.count == 4)

        let secondPlan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "以参考图生成四个版本",
                sourceNodeIDs: [source.id], resultPosition: .init(x: 900, y: 96),
                resultCount: 4
            ),
            document: document
        )
        #expect(secondPlan.resultPositions == plan.resultPositions)
    }

    @Test func completionAtomicallyRepairsEdgesEditedWhileProviderWasRunning() throws {
        let attemptID = "edge-repair-attempt"
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 96),
            size: .init(width: 240, height: 180)
        )
        let redirectedSource = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 384),
            size: .init(width: 240, height: 180)
        )
        let unrelatedTask = CanvasNode(
            kind: .generationTask,
            position: .init(x: 480, y: 720),
            size: .init(width: 340, height: 210)
        )
        let staleResult = CanvasNode(
            kind: .image,
            position: .init(x: 1_320, y: 720),
            size: .init(width: 320, height: 260)
        )
        let document = CanvasDocument(
            name: "Canvas",
            nodes: [source, redirectedSource, unrelatedTask, staleResult]
        )
        let project = CanvasProject(
            id: UUID(),
            name: "Atomic edge repair",
            documents: [document],
            selectedDocumentID: document.id,
            revision: 50
        )
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: "以唯一显式参考图生成四张",
                sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 96),
                resultCount: 4,
                metadata: [
                    "generationAttemptID": attemptID,
                    "generationState": CanvasGenerationTaskState.running.rawValue
                ]
            ),
            document: document
        )
        let preparedPatch = CanvasPatch(
            canvasID: project.id,
            documentID: document.id,
            expectedRevision: project.revision,
            operations: graph.operations
        )
        var (editedWhileWaiting, _) = try CanvasCommandService.applying(
            preparedPatch,
            to: project
        )
        let documentIndex = try #require(editedWhileWaiting.documents.firstIndex {
            $0.id == document.id
        })

        // Simulate interactive topology edits after the provider request left
        // the process: remove the declared source/result edges and redirect
        // both sides to unrelated nodes without changing the attempt token.
        editedWhileWaiting.documents[documentIndex].connections.removeAll { connection in
            (connection.kind == .source
                && connection.destinationNodeID == graph.configurationNodeID)
                || (connection.kind == .generatedFrom
                    && connection.sourceNodeID == graph.configurationNodeID
                    && connection.destinationNodeID == graph.resultNodeIDs[1])
        }
        editedWhileWaiting.documents[documentIndex].connections.append(contentsOf: [
            CanvasConnection(
                sourceNodeID: redirectedSource.id,
                destinationNodeID: graph.configurationNodeID,
                kind: .source
            ),
            CanvasConnection(
                sourceNodeID: graph.configurationNodeID,
                destinationNodeID: staleResult.id,
                kind: .generatedFrom
            ),
            CanvasConnection(
                sourceNodeID: unrelatedTask.id,
                destinationNodeID: graph.resultNodeIDs[2],
                kind: .generatedFrom
            )
        ])
        editedWhileWaiting.revision += 1

        let completionPatch = try CanvasGenerationCommitPlanner.patch(
            project: editedWhileWaiting,
            documentID: document.id,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            sourceNodeIDs: graph.sourceNodeIDs,
            generationAttemptID: attemptID,
            operations: [CanvasPatchOperation(
                kind: .update,
                nodeID: graph.configurationNodeID,
                metadata: ["generationState": CanvasGenerationTaskState.ready.rawValue]
            )] + graph.resultNodeIDs.map { resultNodeID in
                CanvasPatchOperation(
                    kind: .update,
                    nodeID: resultNodeID,
                    metadata: ["generationState": CanvasGenerationTaskState.ready.rawValue]
                )
            }
        )
        let (completed, result) = try CanvasCommandService.applying(
            completionPatch,
            to: editedWhileWaiting
        )
        #expect(result.previousRevision == editedWhileWaiting.revision)
        #expect(result.revision == editedWhileWaiting.revision + 1)
        let completedDocument = try #require(completed.documents.first {
            $0.id == document.id
        })
        let sourceEdges = completedDocument.connections.filter {
            $0.kind == .source && $0.destinationNodeID == graph.configurationNodeID
        }
        #expect(sourceEdges.count == 1)
        #expect(sourceEdges.first?.sourceNodeID == source.id)
        let resultEdges = completedDocument.connections.filter {
            $0.kind == .generatedFrom
                && ($0.sourceNodeID == graph.configurationNodeID
                    || graph.resultNodeIDs.contains($0.destinationNodeID))
        }
        #expect(resultEdges.count == 4)
        #expect(resultEdges.allSatisfy {
            $0.sourceNodeID == graph.configurationNodeID
        })
        #expect(Set(resultEdges.map(\.destinationNodeID)) == Set(graph.resultNodeIDs))
        let sourceList = graph.sourceNodeIDs.map(\.uuidString).joined(separator: ",")
        let resultList = graph.resultNodeIDs.map(\.uuidString).joined(separator: ",")
        let task = try #require(completedDocument.nodes.first {
            $0.id == graph.configurationNodeID
        })
        #expect(task.metadata["generationSourceNodeIDs"] == sourceList)
        #expect(task.metadata["generationResultNodeIDs"] == resultList)
        #expect(graph.resultNodeIDs.allSatisfy { resultNodeID in
            completedDocument.nodes.first { $0.id == resultNodeID }?.metadata[
                "generationSourceNodeIDs"
            ] == sourceList
                && completedDocument.nodes.first { $0.id == resultNodeID }?.metadata[
                    "generationResultNodeIDs"
                ] == resultList
        })
    }

    @Test func cancellationUpdatesTaskAndFourResultsInOneRevision() throws {
        let oldAttemptID = "running-attempt"
        let cancelledAttemptID = "cancelled-attempt"
        let task = CanvasNode(
            kind: .generationTask,
            position: .init(x: 480, y: 96),
            size: .init(width: 340, height: 210),
            metadata: [
                "generationAttemptID": oldAttemptID,
                "generationState": CanvasGenerationTaskState.running.rawValue,
                "generationError": "old error",
                "generationErrorDetail": "old detail"
            ]
        )
        let results = (0..<4).map { index in
            CanvasNode(
                kind: .image,
                position: .init(x: 900, y: 96 + Double(index) * 312),
                size: .init(width: 320, height: 260),
                metadata: [
                    "generationAttemptID": oldAttemptID,
                    "generationState": CanvasGenerationTaskState.running.rawValue,
                    "generationError": "old error",
                    "generationErrorDetail": "old detail"
                ]
            )
        }
        let document = CanvasDocument(name: "Canvas", nodes: [task] + results)
        let project = CanvasProject(
            id: UUID(),
            name: "Cancellation",
            documents: [document],
            selectedDocumentID: document.id,
            revision: 72
        )
        let nodeIDs = [task.id] + results.map(\.id)
        let operations = CanvasGenerationCancellationPlanner.operations(
            nodeIDs: nodeIDs,
            cancelledAttemptID: cancelledAttemptID
        )
        #expect(operations.count == 5)
        let patch = CanvasPatch(
            canvasID: project.id,
            documentID: document.id,
            expectedRevision: project.revision,
            operations: operations
        )
        let (cancelled, result) = try CanvasCommandService.applying(patch, to: project)
        #expect(result.previousRevision == 72)
        #expect(result.revision == 73)
        #expect(Set(result.changedNodeIDs) == Set(nodeIDs))
        let cancelledDocument = try #require(cancelled.documents.first)
        #expect(nodeIDs.allSatisfy { nodeID in
            guard let node = cancelledDocument.nodes.first(where: { $0.id == nodeID }) else {
                return false
            }
            return node.metadata["generationAttemptID"] == cancelledAttemptID
                && node.metadata["generationState"]
                    == CanvasGenerationTaskState.cancelled.rawValue
                && node.metadata["generationError"] == ""
                && node.metadata["generationErrorDetail"] == ""
        })
    }

    @Test func imageOutputCountMismatchFailsBeforeResultIndexing() throws {
        let resultIDs = (0..<4).map { _ in UUID() }
        #expect(throws: FloeError.self) {
            _ = try CanvasGenerationOutputContract.resultNodeIDs(
                expectedCount: 4,
                actualCount: 0,
                preparedResultNodeIDs: resultIDs
            )
        }
        #expect(throws: FloeError.self) {
            _ = try CanvasGenerationOutputContract.resultNodeIDs(
                expectedCount: 4,
                actualCount: 3,
                preparedResultNodeIDs: resultIDs
            )
        }
        #expect(throws: FloeError.self) {
            _ = try CanvasGenerationOutputContract.resultNodeIDs(
                expectedCount: 4,
                actualCount: 5,
                preparedResultNodeIDs: resultIDs
            )
        }
    }

    @Test func retryKeepsOnlyFourCurrentResultEdgesAndPreservesPriorAssets() throws {
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 96),
            size: .init(width: 240, height: 180),
            asset: CanvasAssetReference(localRelativePath: "Materials/reference.png")
        )
        let replacementSource = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 408),
            size: .init(width: 240, height: 180),
            asset: CanvasAssetReference(localRelativePath: "Materials/replacement.png")
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source, replacementSource])
        let project = CanvasProject(
            id: UUID(), name: "Retry", documents: [document],
            selectedDocumentID: document.id
        )
        let first = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "第一批四张", sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 96), resultCount: 4,
                metadata: [
                    "generationAttemptID": "first-attempt",
                    "generationState": CanvasGenerationTaskState.running.rawValue
                ]
            ),
            document: document
        )
        let firstPatch = CanvasPatch(
            canvasID: project.id, documentID: document.id,
            expectedRevision: project.revision, operations: first.operations
        )
        let (prepared, _) = try CanvasCommandService.applying(firstPatch, to: project)
        let firstAssets = Dictionary(uniqueKeysWithValues: first.resultNodeIDs.enumerated().map {
            index, resultID in
            (resultID, CanvasAssetReference(
                contentHash: "first-result-\(index)",
                localRelativePath: "Materials/first-result-\(index).png"
            ))
        })
        let completedPatch = try CanvasGenerationCommitPlanner.patch(
            project: prepared,
            documentID: document.id,
            configurationNodeID: first.configurationNodeID,
            resultNodeIDs: first.resultNodeIDs,
            generationAttemptID: "first-attempt",
            operations: first.resultNodeIDs.map { resultID in
                CanvasPatchOperation(
                    kind: .update, nodeID: resultID, nodeKind: .image,
                    asset: firstAssets[resultID],
                    metadata: ["generationState": CanvasGenerationTaskState.ready.rawValue]
                )
            } + [CanvasPatchOperation(
                kind: .update, nodeID: first.configurationNodeID,
                metadata: ["generationState": CanvasGenerationTaskState.ready.rawValue]
            )]
        )
        let (completed, _) = try CanvasCommandService.applying(completedPatch, to: prepared)
        let completedDocument = try #require(completed.documents.first)

        let retry = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "第二批四张", sourceNodeIDs: [replacementSource.id],
                resultPosition: .init(x: 900, y: 96),
                existingConfigurationNodeID: first.configurationNodeID,
                resultCount: 4,
                metadata: [
                    "generationAttemptID": "second-attempt",
                    "generationState": CanvasGenerationTaskState.running.rawValue
                ]
            ),
            document: completedDocument
        )
        #expect(Set(retry.resultNodeIDs).isDisjoint(with: Set(first.resultNodeIDs)))
        #expect(retry.operations.filter { $0.kind == .disconnect }.count == 5)
        #expect(!retry.operations.contains { $0.kind == .delete })

        let retryPatch = CanvasPatch(
            canvasID: completed.id, documentID: document.id,
            expectedRevision: completed.revision, operations: retry.operations
        )
        let (retried, _) = try CanvasCommandService.applying(retryPatch, to: completed)
        let retriedDocument = try #require(retried.documents.first)
        let resultEdges = retriedDocument.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == first.configurationNodeID
        }
        #expect(resultEdges.count == 4)
        #expect(Set(resultEdges.map(\.destinationNodeID)) == Set(retry.resultNodeIDs))
        let sourceEdges = retriedDocument.connections.filter {
            $0.kind == .source && $0.destinationNodeID == first.configurationNodeID
        }
        #expect(sourceEdges.count == 1)
        #expect(sourceEdges.first?.sourceNodeID == replacementSource.id)
        #expect(first.resultNodeIDs.allSatisfy { resultID in
            retriedDocument.nodes.first { $0.id == resultID }?.asset == firstAssets[resultID]
        })
        #expect(retriedDocument.nodes.contains { $0.id == source.id && $0.asset == source.asset })
        let retriedTask = try #require(retriedDocument.nodes.first {
            $0.id == first.configurationNodeID
        })
        let persistedResultIDs = Set(
            (retriedTask.metadata["generationResultNodeIDs"] ?? "")
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        )
        #expect(persistedResultIDs == Set(retry.resultNodeIDs))
        #expect(retriedTask.metadata["generationSourceNodeIDs"] == replacementSource.id.uuidString)
    }

    @Test func generationLayoutAvoidsSameRunImportedNodesWithoutMovingThem() throws {
        let runID = UUID()
        let source = CanvasNode(
            kind: .text, text: "产品构思",
            position: .init(x: 96, y: 96), size: .init(width: 240, height: 160)
        )
        let initialDocument = CanvasDocument(name: "Canvas", nodes: [source])
        let initialProject = CanvasProject(
            id: UUID(), name: "Layout", documents: [initialDocument],
            selectedDocumentID: initialDocument.id
        )
        let imports = (0..<4).map { index in
            CanvasPatchOperation(
                kind: .create, nodeID: UUID(), nodeKind: .image,
                position: .init(x: 480, y: 96 + Double(index) * 312),
                size: .init(width: 240, height: 180),
                createdByRunID: runID,
                metadata: ["artifactOrigin": "imported"]
            )
        }
        let importPatch = CanvasPatch(
            canvasID: initialProject.id,
            documentID: initialDocument.id,
            expectedRevision: initialProject.revision,
            operations: imports
        )
        let (withImports, _) = try CanvasCommandService.applying(
            importPatch, to: initialProject
        )
        let document = withImports.documents[0]
        let importedPositions = Dictionary(uniqueKeysWithValues: document.nodes
            .filter { $0.createdByRunID == runID }
            .map { ($0.id, $0.position) })

        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "生成四张产品图",
                sourceNodeIDs: [source.id], resultPosition: .init(x: 900, y: 96),
                resultCount: 4, createdByRunID: runID
            ),
            document: document
        )
        let generationPatch = CanvasPatch(
            canvasID: withImports.id,
            documentID: document.id,
            expectedRevision: withImports.revision,
            operations: plan.operations
        )
        let (updated, _) = try CanvasCommandService.applying(
            generationPatch, to: withImports
        )

        #expect(updated.documents[0].nodes.filter { importedPositions[$0.id] != nil }
            .allSatisfy { importedPositions[$0.id] == $0.position })
        #expect(Set(plan.resultPositions.map(\.x)).count == 1)
        #expect(plan.resultPositions.allSatisfy {
            $0.x.truncatingRemainder(dividingBy: 24) == 0
                && $0.y.truncatingRemainder(dividingBy: 24) == 0
        })
        let configurationPosition = try #require(plan.operations.first {
            $0.nodeID == plan.configurationNodeID
        }?.position)
        #expect((plan.resultPositions.first?.x ?? 0) > configurationPosition.x)
    }

    @Test func generationCommitRebasesOntoLatestCanvasRevision() throws {
        let attemptID = "attempt-current"
        let document = CanvasDocument(name: "Canvas")
        let project = CanvasProject(
            id: UUID(), name: "Generation", documents: [document],
            selectedDocumentID: document.id, revision: 28
        )
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: "雾中雪山",
                resultPosition: .init(x: 900, y: 200),
                metadata: [
                    "generationAttemptID": attemptID,
                    "generationState": "running"
                ]
            ),
            document: document
        )
        let preparedPatch = CanvasPatch(
            canvasID: project.id,
            documentID: document.id,
            expectedRevision: project.revision,
            operations: graph.operations
        )
        var (current, _) = try CanvasCommandService.applying(preparedPatch, to: project)
        #expect(current.revision == 29)

        let viewport = CanvasViewportState(center: .init(x: 44, y: 72), scale: 0.65)
        current.viewports[document.id] = viewport
        current.revision += 1

        let completionPatch = try CanvasGenerationCommitPlanner.patch(
            project: current,
            documentID: document.id,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            generationAttemptID: attemptID,
            operations: [
                CanvasPatchOperation(
                    kind: .update,
                    nodeID: graph.configurationNodeID,
                    metadata: ["generationState": "ready"]
                ),
                CanvasPatchOperation(
                    kind: .update,
                    nodeID: graph.resultNodeID,
                    metadata: ["generationState": "ready"]
                )
            ]
        )
        #expect(completionPatch.expectedRevision == 30)
        let (committed, result) = try CanvasCommandService.applying(
            completionPatch,
            to: current
        )

        #expect(result.previousRevision == 30)
        #expect(result.revision == 31)
        #expect(committed.viewports[document.id] == viewport)
        #expect(committed.documents[0].nodes.first {
            $0.id == graph.configurationNodeID
        }?.metadata["generationState"] == "ready")
        #expect(committed.documents[0].nodes.first {
            $0.id == graph.resultNodeID
        }?.metadata["generationState"] == "ready")
    }

    @Test func oldGenerationAttemptCannotOverwriteNewAttempt() throws {
        let oldAttemptID = "attempt-old"
        let newAttemptID = "attempt-new"
        let document = CanvasDocument(name: "Canvas")
        let project = CanvasProject(
            id: UUID(), name: "Generation", documents: [document],
            selectedDocumentID: document.id, revision: 10
        )
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .video,
                prompt: "清晨海岸",
                resultPosition: .init(x: 900, y: 200),
                metadata: [
                    "generationAttemptID": oldAttemptID,
                    "generationState": "running"
                ]
            ),
            document: document
        )
        let preparedPatch = CanvasPatch(
            canvasID: project.id,
            documentID: document.id,
            expectedRevision: project.revision,
            operations: graph.operations
        )
        var (superseded, _) = try CanvasCommandService.applying(preparedPatch, to: project)
        let documentIndex = try #require(
            superseded.documents.firstIndex(where: { $0.id == document.id })
        )
        for nodeID in [graph.configurationNodeID, graph.resultNodeID] {
            let nodeIndex = try #require(
                superseded.documents[documentIndex].nodes.firstIndex(where: { $0.id == nodeID })
            )
            superseded.documents[documentIndex].nodes[nodeIndex]
                .metadata["generationAttemptID"] = newAttemptID
        }
        superseded.revision += 1

        #expect(throws: FloeError.validationFailed(
            "Canvas generation attempt was superseded before its local result was committed"
        )) {
            _ = try CanvasGenerationCommitPlanner.patch(
                project: superseded,
                documentID: document.id,
                configurationNodeID: graph.configurationNodeID,
                resultNodeIDs: graph.resultNodeIDs,
                generationAttemptID: oldAttemptID,
                operations: [CanvasPatchOperation(
                    kind: .update,
                    nodeID: graph.resultNodeID,
                    metadata: ["generationState": "ready"]
                )]
            )
        }

        let currentPatch = try CanvasGenerationCommitPlanner.patch(
            project: superseded,
            documentID: document.id,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            generationAttemptID: newAttemptID,
            operations: [CanvasPatchOperation(
                kind: .update,
                nodeID: graph.resultNodeID,
                metadata: ["generationState": "submitted"]
            )]
        )
        #expect(currentPatch.expectedRevision == superseded.revision)
    }

    @Test func editingConfigurationSupersedesDelayedFourImageResponse() throws {
        let oldAttemptID = "attempt-four-images-in-flight"
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 100, y: 100),
            size: .init(width: 240, height: 180),
            asset: CanvasAssetReference(localRelativePath: "Materials/reference.png")
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source])
        let project = CanvasProject(
            id: UUID(), name: "Generation", documents: [document],
            selectedDocumentID: document.id, revision: 20
        )
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: "基于参考图生成四张",
                sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 100),
                resultCount: 4,
                metadata: [
                    "generationAttemptID": oldAttemptID,
                    "generationState": CanvasGenerationTaskState.running.rawValue
                ]
            ),
            document: document
        )
        let preparedPatch = CanvasPatch(
            canvasID: project.id,
            documentID: document.id,
            expectedRevision: project.revision,
            operations: graph.operations
        )
        let (prepared, _) = try CanvasCommandService.applying(preparedPatch, to: project)
        let preparedDocument = try #require(prepared.documents.first)

        #expect(CanvasGenerationAttemptValidator.isActive(
            document: preparedDocument,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            generationAttemptID: oldAttemptID
        ))

        // A delayed four-image response is not current if even one prepared
        // result node has already been claimed by another attempt.
        var partiallySuperseded = preparedDocument
        let lastResultID = try #require(graph.resultNodeIDs.last)
        let lastResultIndex = try #require(
            partiallySuperseded.nodes.firstIndex(where: { $0.id == lastResultID })
        )
        partiallySuperseded.nodes[lastResultIndex]
            .metadata["generationAttemptID"] = "replacement-attempt"
        #expect(!CanvasGenerationAttemptValidator.matches(
            document: partiallySuperseded,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            generationAttemptID: oldAttemptID
        ))

        let configuration = try #require(preparedDocument.nodes.first {
            $0.id == graph.configurationNodeID
        })
        var revisedMetadata = configuration.metadata
        revisedMetadata["generationState"] = CanvasGenerationTaskState.configured.rawValue
        let edit = try CanvasGenerationConfigurationPlanner.plan(
            kind: .image,
            prompt: "基于参考图生成四张夜景版本",
            sourceNodeIDs: [source.id],
            position: configuration.position,
            existingConfigurationNodeID: configuration.id,
            metadata: revisedMetadata,
            document: preparedDocument
        )
        let editPatch = CanvasPatch(
            canvasID: prepared.id,
            documentID: document.id,
            expectedRevision: prepared.revision,
            operations: edit.operations
        )
        let (edited, _) = try CanvasCommandService.applying(editPatch, to: prepared)
        let editedDocument = try #require(edited.documents.first)
        let editedConfiguration = try #require(editedDocument.nodes.first {
            $0.id == graph.configurationNodeID
        })

        #expect(editedConfiguration.metadata["generationAttemptID"] != oldAttemptID)
        #expect(editedConfiguration.metadata["generationState"]
            == CanvasGenerationTaskState.configured.rawValue)
        #expect(!CanvasGenerationAttemptValidator.isActive(
            document: editedDocument,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            generationAttemptID: oldAttemptID
        ))
        #expect(editedDocument.connections.filter {
            $0.sourceNodeID == graph.configurationNodeID
                && $0.kind == .generatedFrom
                && graph.resultNodeIDs.contains($0.destinationNodeID)
        }.count == 4)
    }

    @Test func nonPrimarySupersessionBlocksOldFourImageSuccessAndFailureCommits() throws {
        let attemptID = "four-image-attempt"
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 100, y: 100), size: .init(width: 240, height: 180)
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source])
        let project = CanvasProject(
            id: UUID(), name: "Generation", documents: [document],
            selectedDocumentID: document.id
        )
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "生成四张", sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 100), resultCount: 4,
                metadata: [
                    "generationAttemptID": attemptID,
                    "generationState": CanvasGenerationTaskState.running.rawValue
                ]
            ),
            document: document
        )
        let preparePatch = CanvasPatch(
            canvasID: project.id, documentID: document.id,
            expectedRevision: project.revision, operations: graph.operations
        )
        let (prepared, _) = try CanvasCommandService.applying(preparePatch, to: project)
        #expect(graph.resultNodeIDs.count == 4)

        let successOperations = graph.resultNodeIDs.map { resultID in
            CanvasPatchOperation(
                kind: .update, nodeID: resultID,
                metadata: ["generationState": CanvasGenerationTaskState.ready.rawValue]
            )
        }
        let failureOperations = [CanvasPatchOperation(
            kind: .update, nodeID: graph.configurationNodeID,
            metadata: ["generationState": CanvasGenerationTaskState.failed.rawValue]
        )] + graph.resultNodeIDs.map { resultID in
            CanvasPatchOperation(
                kind: .update, nodeID: resultID,
                metadata: ["generationState": CanvasGenerationTaskState.failed.rawValue]
            )
        }

        for resultIndex in 1..<graph.resultNodeIDs.count {
            var superseded = prepared
            let documentIndex = try #require(
                superseded.documents.firstIndex(where: { $0.id == document.id })
            )
            let resultID = graph.resultNodeIDs[resultIndex]
            let nodeIndex = try #require(
                superseded.documents[documentIndex].nodes.firstIndex(where: { $0.id == resultID })
            )
            superseded.documents[documentIndex].nodes[nodeIndex]
                .metadata["generationAttemptID"] = "replacement-\(resultIndex)"
            superseded.revision += 1

            #expect(CanvasGenerationAttemptValidator.isActive(
                document: superseded.documents[documentIndex],
                configurationNodeID: graph.configurationNodeID,
                resultNodeIDs: [graph.resultNodeID],
                generationAttemptID: attemptID
            ))
            #expect(throws: FloeError.validationFailed(
                "Canvas generation attempt was superseded before its local result was committed"
            )) {
                _ = try CanvasGenerationCommitPlanner.patch(
                    project: superseded,
                    documentID: document.id,
                    configurationNodeID: graph.configurationNodeID,
                    resultNodeIDs: graph.resultNodeIDs,
                    generationAttemptID: attemptID,
                    operations: successOperations
                )
            }
            #expect(throws: FloeError.validationFailed(
                "Canvas generation attempt was superseded before its local result was committed"
            )) {
                _ = try CanvasGenerationCommitPlanner.patch(
                    project: superseded,
                    documentID: document.id,
                    configurationNodeID: graph.configurationNodeID,
                    resultNodeIDs: graph.resultNodeIDs,
                    generationAttemptID: attemptID,
                    operations: failureOperations
                )
            }
        }
    }

    @Test func delayedProviderErrorCannotMarkEditedFourImageTaskFailed() throws {
        let oldAttemptID = "attempt-four-images-error"
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 100, y: 100),
            size: .init(width: 240, height: 180)
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source])
        let project = CanvasProject(
            id: UUID(), name: "Generation", documents: [document],
            selectedDocumentID: document.id
        )
        let graph = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: "生成四张白天版本",
                sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 100),
                resultCount: 4,
                metadata: [
                    "generationAttemptID": oldAttemptID,
                    "generationState": CanvasGenerationTaskState.running.rawValue
                ]
            ),
            document: document
        )
        let preparePatch = CanvasPatch(
            canvasID: project.id,
            documentID: document.id,
            expectedRevision: project.revision,
            operations: graph.operations
        )
        let (prepared, _) = try CanvasCommandService.applying(preparePatch, to: project)
        let preparedDocument = try #require(prepared.documents.first)
        let configuration = try #require(preparedDocument.nodes.first {
            $0.id == graph.configurationNodeID
        })
        let edit = try CanvasGenerationConfigurationPlanner.plan(
            kind: .image,
            prompt: "生成四张夜景版本",
            sourceNodeIDs: [source.id],
            position: configuration.position,
            existingConfigurationNodeID: configuration.id,
            metadata: configuration.metadata,
            document: preparedDocument
        )
        let editPatch = CanvasPatch(
            canvasID: prepared.id,
            documentID: document.id,
            expectedRevision: prepared.revision,
            operations: edit.operations
        )
        let (edited, _) = try CanvasCommandService.applying(editPatch, to: prepared)
        let editedDocument = try #require(edited.documents.first)

        // The provider's delayed error follows the same ownership gate as a
        // success. It cannot apply a failure patch to the newly configured task.
        #expect(!CanvasGenerationAttemptValidator.isActive(
            document: editedDocument,
            configurationNodeID: graph.configurationNodeID,
            resultNodeIDs: graph.resultNodeIDs,
            generationAttemptID: oldAttemptID
        ))
        #expect(throws: FloeError.validationFailed(
            "Canvas generation attempt was superseded before its local result was committed"
        )) {
            _ = try CanvasGenerationCommitPlanner.patch(
                project: edited,
                documentID: document.id,
                configurationNodeID: graph.configurationNodeID,
                resultNodeIDs: graph.resultNodeIDs,
                generationAttemptID: oldAttemptID,
                operations: [CanvasPatchOperation(
                    kind: .update,
                    nodeID: graph.configurationNodeID,
                    metadata: [
                        "generationState": CanvasGenerationTaskState.failed.rawValue,
                        "generationError": "late provider error"
                    ]
                )]
            )
        }
        #expect(editedDocument.nodes.first { $0.id == graph.configurationNodeID }?
            .metadata["generationState"] == CanvasGenerationTaskState.configured.rawValue)
    }

    @Test func generationConfigurationCreatesOnlyOneNodeAndTypedSourceEdges() throws {
        let source = CanvasNode(
            kind: .text, text: "清晨海边的构思",
            position: .init(x: 100, y: 100), size: .init(width: 280, height: 160)
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source])
        let plan = try CanvasGenerationConfigurationPlanner.plan(
            kind: .image,
            prompt: "产品主视觉",
            sourceNodeIDs: [source.id],
            position: .init(x: 520, y: 100),
            existingConfigurationNodeID: nil,
            metadata: [:],
            document: document
        )
        let creates = plan.operations.filter { $0.kind == .create }
        #expect(creates.count == 1)
        #expect(creates.first?.nodeKind == .generationTask)
        #expect(creates.first?.metadata?["generationPrompt"] == "产品主视觉")
        #expect(plan.operations.contains {
            $0.kind == .connect && $0.connectionKind == .source
                && $0.sourceNodeID == source.id
                && $0.destinationNodeID == plan.configurationNodeID
        })
        #expect(!plan.operations.contains {
            $0.nodeKind == .text || $0.nodeKind == .image || $0.nodeKind == .video
        })
    }

    @Test func generationPlannerReusesVisibleGenerationNodes() throws {
        let prompt = CanvasNode(
            kind: .text, text: "产品在清晨海边",
            position: .init(x: 100, y: 100), size: .init(width: 280, height: 160)
        )
        let configuration = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 500, y: 100), size: .init(width: 320, height: 200)
        )
        let result = CanvasNode(
            kind: .image, text: "图片生成中",
            position: .init(x: 900, y: 100), size: .init(width: 320, height: 260)
        )
        let document = CanvasDocument(name: "Canvas", nodes: [prompt, configuration, result])
        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: prompt.text,
                sourceNodeIDs: [prompt.id], resultPosition: result.position,
                existingConfigurationNodeID: configuration.id,
                reusableResultNodeID: result.id
            ),
            document: document
        )

        #expect(plan.promptNodeID == prompt.id)
        #expect(plan.configurationNodeID == configuration.id)
        #expect(plan.resultNodeID == result.id)
        #expect(!plan.operations.contains { $0.kind == .create })
    }

    @Test func generationRetryReusesFailedResultNode() throws {
        let prompt = CanvasNode(
            kind: .text, text: "海边产品照",
            position: .init(x: 100, y: 100), size: .init(width: 280, height: 160)
        )
        let configuration = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 500, y: 100), size: .init(width: 320, height: 200),
            metadata: ["generationState": "failed", "generationAttemptIndex": "1"]
        )
        let failed = CanvasNode(
            kind: .image, text: "生成失败",
            position: .init(x: 900, y: 100), size: .init(width: 320, height: 260),
            metadata: ["generationState": "failed"]
        )
        let document = CanvasDocument(name: "Canvas", nodes: [prompt, configuration, failed])
        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image,
                prompt: prompt.text,
                sourceNodeIDs: [prompt.id],
                resultPosition: .init(x: 1_300, y: 100),
                existingConfigurationNodeID: configuration.id,
                reusableResultNodeID: failed.id,
                metadata: ["generationAttemptIndex": "2"]
            ),
            document: document
        )

        #expect(plan.configurationNodeID == configuration.id)
        #expect(plan.resultNodeID == failed.id)
        #expect(plan.operations.contains {
            $0.kind == .update && $0.nodeID == failed.id
        })
        #expect(!plan.operations.contains { $0.kind == .delete && $0.nodeID == failed.id })
    }

    @Test func existingGenerationTaskNeverSynthesizesPromptNode() throws {
        let source = CanvasNode(
            kind: .image, position: .init(x: 80, y: 100),
            size: .init(width: 240, height: 180)
        )
        let configuration = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 500, y: 100), size: .init(width: 320, height: 200)
        )
        let result = CanvasNode(
            kind: .image, text: "图片生成中",
            position: .init(x: 900, y: 100), size: .init(width: 320, height: 260)
        )
        let document = CanvasDocument(name: "Canvas", nodes: [source, configuration, result])
        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "任务内保存的提示词",
                sourceNodeIDs: [source.id], resultPosition: result.position,
                existingConfigurationNodeID: configuration.id,
                reusableResultNodeID: result.id,
                createsPromptNodeWhenMissing: false
            ),
            document: document
        )

        #expect(plan.configurationNodeID == configuration.id)
        #expect(plan.resultNodeID == result.id)
        #expect(plan.sourceNodeIDs == [source.id])
        #expect(!plan.operations.contains { $0.kind == .create })
        #expect(!plan.operations.contains {
            $0.kind == .connect && $0.sourceNodeID == configuration.id
                && $0.destinationNodeID == configuration.id
        })
    }

    @Test func generationContextUsesOnlySourceEdgesAndTerminatesCycles() {
        let note = UUID(), reference = UUID(), task = UUID(), narrative = UUID()
        let connections = [
            CanvasConnection(sourceNodeID: note, destinationNodeID: reference, kind: .source),
            CanvasConnection(sourceNodeID: reference, destinationNodeID: task, kind: .source),
            CanvasConnection(sourceNodeID: task, destinationNodeID: note, kind: .source),
            CanvasConnection(sourceNodeID: narrative, destinationNodeID: task, kind: .arrow)
        ]

        let resolved = CanvasGenerationContextResolver.nodeIDs(
            selectedIDs: [task], connections: connections
        )

        #expect(resolved == [note, reference, task])
        #expect(!resolved.contains(narrative))
    }

    @Test func savedGenerationContextRecoversTypedEdgesMetadataAndImagePrompts() throws {
        let concept = CanvasNode(
            kind: .text, text: "保留山谷构图",
            position: .init(x: 0, y: 0), size: .init(width: 240, height: 160)
        )
        let linkedImage = CanvasNode(
            kind: .image,
            position: .init(x: 288, y: 0), size: .init(width: 240, height: 180),
            metadata: ["generationPrompt": "清晨薄雾与暖色侧光"]
        )
        let metadataImage = CanvasNode(
            kind: .image,
            position: .init(x: 288, y: 240), size: .init(width: 240, height: 180),
            metadata: ["generationPrompt": "木屋与远山"]
        )
        let configuration = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 600, y: 0), size: .init(width: 340, height: 210),
            metadata: CanvasGenerationConfiguration(
                kind: .image, prompt: "生成新版本", modelID: nil,
                aspectRatio: "16:9", sourceNodeIDs: [metadataImage.id]
            ).metadata
        )
        let oldResult = CanvasNode(
            kind: .image, text: "旧结果",
            position: .init(x: 1_000, y: 0), size: .init(width: 320, height: 260),
            metadata: ["generationPrompt": "不得回流的旧结果提示词"]
        )
        let narrative = CanvasNode(
            kind: .text, text: "普通箭头说明，不是生成输入",
            position: .init(x: 0, y: 400), size: .init(width: 240, height: 160)
        )
        let document = CanvasDocument(
            name: "Canvas",
            nodes: [concept, linkedImage, metadataImage, configuration, oldResult, narrative],
            connections: [
                CanvasConnection(
                    sourceNodeID: concept.id, destinationNodeID: linkedImage.id, kind: .source
                ),
                CanvasConnection(
                    sourceNodeID: linkedImage.id,
                    destinationNodeID: configuration.id,
                    kind: .source
                ),
                CanvasConnection(
                    sourceNodeID: narrative.id,
                    destinationNodeID: configuration.id,
                    kind: .arrow
                ),
                CanvasConnection(
                    sourceNodeID: configuration.id,
                    destinationNodeID: oldResult.id,
                    kind: .generatedFrom
                )
            ]
        )

        let resolved = try CanvasGenerationContextResolver.resolvedNodeIDs(
            requestedIDs: nil,
            configurationNodeID: configuration.id,
            document: document
        )
        #expect(Set(resolved) == Set([concept.id, linkedImage.id, metadataImage.id]))
        #expect(!resolved.contains(oldResult.id))
        #expect(!resolved.contains(narrative.id))

        let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let context = CanvasGenerationContextResolver.contextText(
            nodes: resolved.compactMap { nodesByID[$0] },
            excluding: "生成新版本"
        )
        #expect(context.contains("保留山谷构图"))
        #expect(context.contains("Reference image original prompt: 清晨薄雾与暖色侧光"))
        #expect(context.contains("Reference image original prompt: 木屋与远山"))
        #expect(!context.contains { $0.contains("旧结果") || $0.contains("普通箭头") })
    }

    @Test func explicitGenerationSourcesReplaceSavedContextThroughPlanningChain() throws {
        let oldConcept = CanvasNode(
            kind: .text, text: "旧构思",
            position: .init(x: 0, y: 0), size: .init(width: 240, height: 160)
        )
        let oldReference = CanvasNode(
            kind: .image,
            position: .init(x: 288, y: 0), size: .init(width: 240, height: 180)
        )
        let replacementConcept = CanvasNode(
            kind: .text, text: "新构思",
            position: .init(x: 0, y: 320), size: .init(width: 240, height: 160)
        )
        let replacementReference = CanvasNode(
            kind: .image,
            position: .init(x: 288, y: 320), size: .init(width: 240, height: 180)
        )
        let configuration = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 600, y: 0), size: .init(width: 340, height: 210),
            metadata: ["generationSourceNodeIDs": oldReference.id.uuidString]
        )
        let document = CanvasDocument(
            name: "Canvas",
            nodes: [
                oldConcept, oldReference, replacementConcept,
                replacementReference, configuration
            ],
            connections: [
                CanvasConnection(
                    sourceNodeID: oldConcept.id,
                    destinationNodeID: oldReference.id,
                    kind: .source
                ),
                CanvasConnection(
                    sourceNodeID: oldReference.id,
                    destinationNodeID: configuration.id,
                    kind: .source
                ),
                CanvasConnection(
                    sourceNodeID: replacementConcept.id,
                    destinationNodeID: replacementReference.id,
                    kind: .source
                )
            ]
        )

        let resolved = try CanvasGenerationContextResolver.resolvedNodeIDs(
            requestedIDs: [replacementReference.id],
            configurationNodeID: configuration.id,
            document: document
        )
        #expect(Set(resolved) == Set([replacementConcept.id, replacementReference.id]))
        #expect(!resolved.contains(oldConcept.id))
        #expect(!resolved.contains(oldReference.id))

        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "生成替代版本",
                sourceNodeIDs: resolved, resultPosition: .init(x: 1_000, y: 0),
                existingConfigurationNodeID: configuration.id,
                createsPromptNodeWhenMissing: false
            ),
            document: document
        )
        let project = CanvasProject(
            id: UUID(), name: "Explicit replacement", documents: [document],
            selectedDocumentID: document.id
        )
        let patch = CanvasPatch(
            canvasID: project.id, documentID: document.id,
            expectedRevision: project.revision, operations: plan.operations
        )
        let (updated, _) = try CanvasCommandService.applying(patch, to: project)
        let updatedDocument = try #require(updated.documents.first)
        let persistedSources = updatedDocument.connections.filter {
            $0.kind == .source && $0.destinationNodeID == configuration.id
        }
        #expect(persistedSources.count == resolved.count)
        #expect(Set(persistedSources.map(\.sourceNodeID)) == Set(resolved))
        let updatedTask = try #require(updatedDocument.nodes.first {
            $0.id == configuration.id
        })
        let persistedSourceIDs = Set(
            (updatedTask.metadata["generationSourceNodeIDs"] ?? "")
                .split(separator: ",")
                .compactMap { UUID(uuidString: String($0)) }
        )
        #expect(persistedSourceIDs == Set(resolved))
    }

    @Test func explicitEmptyGenerationSourcesClearSavedContextThroughPlanningChain() throws {
        let oldReference = CanvasNode(
            kind: .image,
            position: .init(x: 96, y: 96), size: .init(width: 240, height: 180)
        )
        let configuration = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 480, y: 96), size: .init(width: 340, height: 210),
            metadata: ["generationSourceNodeIDs": oldReference.id.uuidString]
        )
        let document = CanvasDocument(
            name: "Canvas", nodes: [oldReference, configuration],
            connections: [CanvasConnection(
                sourceNodeID: oldReference.id,
                destinationNodeID: configuration.id,
                kind: .source
            )]
        )

        let resolved = try CanvasGenerationContextResolver.resolvedNodeIDs(
            requestedIDs: [],
            configurationNodeID: configuration.id,
            document: document
        )
        #expect(resolved.isEmpty)

        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: "不使用参考图生成",
                sourceNodeIDs: resolved, resultPosition: .init(x: 900, y: 96),
                existingConfigurationNodeID: configuration.id,
                createsPromptNodeWhenMissing: false
            ),
            document: document
        )
        let project = CanvasProject(
            id: UUID(), name: "Explicit clear", documents: [document],
            selectedDocumentID: document.id
        )
        let patch = CanvasPatch(
            canvasID: project.id, documentID: document.id,
            expectedRevision: project.revision, operations: plan.operations
        )
        let (updated, _) = try CanvasCommandService.applying(patch, to: project)
        let updatedDocument = try #require(updated.documents.first)
        #expect(!updatedDocument.connections.contains {
            $0.kind == .source && $0.destinationNodeID == configuration.id
        })
        let updatedTask = try #require(updatedDocument.nodes.first {
            $0.id == configuration.id
        })
        #expect(updatedTask.metadata["generationSourceNodeIDs"] == "")
    }

    @Test func canvasCommandServiceCanonicalizesGenerationSourcesAtTheSharedBoundary() throws {
        let firstSource = CanvasNode(
            kind: .image,
            position: .init(x: 80, y: 80), size: .init(width: 240, height: 180)
        )
        let secondSource = CanvasNode(
            kind: .image,
            position: .init(x: 80, y: 360), size: .init(width: 240, height: 180)
        )
        let task = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 480, y: 80), size: .init(width: 340, height: 210),
            metadata: [
                "generationSourceNodeIDs": [firstSource.id, secondSource.id]
                    .sorted { $0.uuidString < $1.uuidString }
                    .map(\.uuidString)
                    .joined(separator: ",")
            ]
        )
        let result = CanvasNode(
            kind: .image,
            position: .init(x: 900, y: 80), size: .init(width: 320, height: 260)
        )
        let legacySourceID = UUID()
        let legacyTask = CanvasNode(
            kind: .generationTask, text: "Legacy metadata only",
            position: .init(x: 480, y: 520), size: .init(width: 340, height: 210),
            metadata: ["generationSourceNodeIDs": legacySourceID.uuidString]
        )
        let firstEdge = CanvasConnection(
            sourceNodeID: firstSource.id, destinationNodeID: task.id,
            kind: .source, sourcePort: .trailing, destinationPort: .leading
        )
        let secondEdge = CanvasConnection(
            sourceNodeID: secondSource.id, destinationNodeID: task.id,
            kind: .source, sourcePort: .trailing, destinationPort: .leading
        )
        let resultEdge = CanvasConnection(
            sourceNodeID: task.id, destinationNodeID: result.id,
            kind: .generatedFrom, sourcePort: .trailing, destinationPort: .leading
        )
        let document = CanvasDocument(
            name: "Canonical sources",
            nodes: [firstSource, secondSource, task, result, legacyTask],
            connections: [firstEdge, secondEdge, resultEdge]
        )
        var project = CanvasProject(
            id: UUID(), name: "Shared boundary", documents: [document],
            selectedDocumentID: document.id
        )

        func apply(_ operations: [CanvasPatchOperation]) throws -> CanvasOperationResult {
            let (updated, operationResult) = try CanvasCommandService.applying(
                CanvasPatch(
                    canvasID: project.id,
                    documentID: document.id,
                    expectedRevision: project.revision,
                    operations: operations
                ),
                to: project
            )
            project = updated
            return operationResult
        }
        func currentDocument() throws -> CanvasDocument {
            try #require(project.documents.first(where: { $0.id == document.id }))
        }
        func currentTask() throws -> CanvasNode {
            try #require(currentDocument().nodes.first(where: { $0.id == task.id }))
        }

        // A direct disconnect (including an agent-authored operation) keeps the
        // remaining source and records the task in the same operation result.
        let firstDisconnect = try apply([
            CanvasPatchOperation(kind: .disconnect, connectionID: firstEdge.id)
        ])
        #expect(firstDisconnect.changedNodeIDs.contains(task.id))
        #expect(try currentTask().metadata["generationSourceNodeIDs"]
            == secondSource.id.uuidString)

        // Node deletion removes its incident edge implicitly. The shared
        // boundary still detects the topology change and clears the fallback.
        let sourceDeletion = try apply([
            CanvasPatchOperation(kind: .delete, nodeID: secondSource.id)
        ])
        #expect(sourceDeletion.changedNodeIDs.contains(task.id))
        #expect(try currentTask().metadata["generationSourceNodeIDs"] == "")

        // Connecting and then reversing a typed source edge exercises both
        // directions without relying on any app-private UI planner.
        let replacementEdgeID = UUID()
        let sourceConnect = try apply([
            CanvasPatchOperation(
                kind: .connect,
                sourceNodeID: firstSource.id,
                destinationNodeID: task.id,
                connectionID: replacementEdgeID,
                connectionKind: .source,
                sourcePort: .trailing,
                destinationPort: .leading
            )
        ])
        #expect(sourceConnect.changedNodeIDs.contains(task.id))
        #expect(try currentTask().metadata["generationSourceNodeIDs"]
            == firstSource.id.uuidString)

        let sourceReverse = try apply([
            CanvasPatchOperation(kind: .disconnect, connectionID: replacementEdgeID),
            CanvasPatchOperation(
                kind: .connect,
                sourceNodeID: task.id,
                destinationNodeID: firstSource.id,
                connectionID: replacementEdgeID,
                connectionKind: .source,
                sourcePort: .leading,
                destinationPort: .trailing
            )
        ])
        #expect(sourceReverse.changedNodeIDs.contains(task.id))
        #expect(try currentTask().metadata["generationSourceNodeIDs"] == "")
        #expect(try currentDocument().connections.contains {
            $0.id == replacementEdgeID
                && $0.kind == .source
                && $0.sourceNodeID == task.id
                && $0.destinationNodeID == firstSource.id
        })
        #expect(try currentDocument().connections.contains {
            $0.id == resultEdge.id && $0.kind == .generatedFrom
        })

        // No source edge ever changed for this legacy task, so its metadata-only
        // fallback must remain available for old documents.
        #expect(try currentDocument().nodes.first(where: { $0.id == legacyTask.id })?
            .metadata["generationSourceNodeIDs"] == legacySourceID.uuidString)
    }

    @Test func ordinaryEdgeDoesNotReplaceExplicitGenerationSourceEdge() throws {
        let source = CanvasNode(
            kind: .text, text: "明确引用",
            position: .init(x: 80, y: 100), size: .init(width: 240, height: 180)
        )
        let task = CanvasNode(
            kind: .generationTask, text: "图片生成",
            position: .init(x: 500, y: 100), size: .init(width: 320, height: 200)
        )
        let ordinary = CanvasConnection(
            sourceNodeID: source.id, destinationNodeID: task.id, kind: .arrow
        )
        let document = CanvasDocument(
            name: "Canvas", nodes: [source, task], connections: [ordinary]
        )

        let plan = try CanvasGenerationGraphPlanner.plan(
            request: CanvasGenerationGraphRequest(
                kind: .image, prompt: source.text, sourceNodeIDs: [source.id],
                resultPosition: .init(x: 900, y: 100),
                existingConfigurationNodeID: task.id,
                createsPromptNodeWhenMissing: false
            ),
            document: document
        )

        #expect(plan.operations.contains {
            $0.kind == .connect && $0.connectionKind == .source
                && $0.sourceNodeID == source.id && $0.destinationNodeID == task.id
        })
    }

    @Test func canvasSyncReducerConvergesForOutOfOrderEqualRevision() {
        let canvasID = UUID(), entityID = UUID()
        let a = CanvasSyncOperation(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            canvasID: canvasID, entityKind: .node, entityID: entityID,
            mutation: .upsert, revision: 8, payload: Data("old".utf8)
        )
        let b = CanvasSyncOperation(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            canvasID: canvasID, entityKind: .node, entityID: entityID,
            mutation: .delete, revision: 8
        )
        #expect(CanvasSyncReducer.newest(a, b) == CanvasSyncReducer.newest(b, a))
        #expect(CanvasSyncReducer.newest(a, b).mutation == .delete)
    }

    @Test func generationConfigurationRoundTripsThroughLegacyMetadata() throws {
        let modelID = UUID()
        let sourceID = UUID()
        let configuration = CanvasGenerationConfiguration(
            kind: .image, prompt: "misty mountain product shot",
            modelID: modelID, aspectRatio: "16:9", resolution: "2K",
            quality: "high", count: 3, sourceNodeIDs: [sourceID]
        )

        let decoded = try #require(CanvasGenerationConfiguration(metadata: configuration.metadata))
        #expect(decoded == configuration)
    }

    @Test func configuredGenerationTaskRequiresExplicitStart() {
        let node = CanvasNode(
            kind: .generationTask, text: "Image generation",
            position: .init(x: 0, y: 0), size: .init(width: 320, height: 200),
            metadata: [
                "generationPrompt": "a quiet lake",
                "generationKind": "image",
                "generationState": "configured"
            ]
        )

        #expect(node.generationTaskState == .configured)
        #expect(node.generationTaskState.canStart)
        #expect(!node.generationTaskState.isRunning)
    }

    @Test func generationTaskStateReadsLegacyFailureAndRunningValues() {
        var node = CanvasNode(
            kind: .generationTask, position: .init(x: 0, y: 0),
            size: .init(width: 320, height: 200),
            metadata: ["generationState": "submitFailed"]
        )
        #expect(node.generationTaskState == .failed)
        #expect(node.generationTaskState.canStart)

        node.metadata["generationState"] = "downloading"
        #expect(node.generationTaskState == .downloading)
        #expect(node.generationTaskState.isRunning)
    }
}
