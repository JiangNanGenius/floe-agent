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
            connections: [.init(sourceNodeID: source.id, destinationNodeID: result.id, kind: .generatedFrom)]
        )
        let project = CanvasProject(
            id: UUID(), name: "Private", documents: [document], selectedDocumentID: document.id
        )
        let decoded = try JSONDecoder().decode(CanvasProject.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
        #expect(decoded.schemaVersion == CanvasProject.currentSchemaVersion)
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
        #expect(decoded.schemaVersion == 5)
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
