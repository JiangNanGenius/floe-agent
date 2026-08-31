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

    @Test func generationPlannerBuildsPromptConfigurationResultGraph() throws {
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
        let prompt = try #require(nodes.first { $0.id == plan.promptNodeID })
        let configuration = try #require(nodes.first { $0.id == plan.configurationNodeID })
        let result = try #require(nodes.first { $0.id == plan.resultNodeID })

        #expect(prompt.kind == .text)
        #expect(prompt.text == "雾中雪山")
        #expect(configuration.kind == .generationTask)
        #expect(configuration.metadata["generationFingerprint"] == "fingerprint")
        #expect(result.kind == .image)
        #expect(result.createdByRunID == runID)
        #expect(Set(plan.sourceNodeIDs) == [source.id, prompt.id])
        #expect(updated.documents[0].connections.contains {
            $0.sourceNodeID == prompt.id && $0.destinationNodeID == configuration.id
                && $0.kind == .source
        })
        #expect(updated.documents[0].connections.contains {
            $0.sourceNodeID == configuration.id && $0.destinationNodeID == result.id
                && $0.kind == .generatedFrom
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

    @Test func generationRetryKeepsConfigurationAndCreatesNewResult() throws {
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
                metadata: ["generationAttemptIndex": "2"]
            ),
            document: document
        )

        #expect(plan.configurationNodeID == configuration.id)
        #expect(plan.resultNodeID != failed.id)
        #expect(plan.operations.contains {
            $0.kind == .create && $0.nodeID == plan.resultNodeID && $0.nodeKind == .image
        })
        #expect(!plan.operations.contains { $0.kind == .delete && $0.nodeID == failed.id })
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
}
