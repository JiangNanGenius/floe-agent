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
