import Foundation
import Testing
@testable import FloeCore

private actor InMemoryCanvasRepository: CanvasDocumentRepository {
    private var projects: [UUID: CanvasProject]

    init(project: CanvasProject) {
        self.projects = [project.id: project]
    }

    func project(canvasID: UUID) async throws -> CanvasProject {
        guard let project = projects[canvasID] else {
            throw FloeError.validationFailed("missing canvas")
        }
        return project
    }

    func save(_ project: CanvasProject, expectedRevision: Int64) async throws {
        guard let current = projects[project.id] else {
            throw FloeError.validationFailed("missing canvas")
        }
        guard current.revision == expectedRevision else {
            throw FloeError.validationFailed("revision conflict")
        }
        projects[project.id] = project
    }

    func stored(canvasID: UUID) -> CanvasProject? { projects[canvasID] }
}

@Suite("Design on the Canvas authority")
struct DesignCanvasServiceTests {
    private func makeProject(nodeKind: CanvasNodeKind = .card) -> (CanvasProject, UUID) {
        let canvasID = UUID()
        let nodeID = UUID()
        var node = CanvasNode.placeholder(kind: nodeKind, position: CanvasPoint(x: 0, y: 0), zIndex: 0)
        node.id = nodeID
        let document = CanvasDocument(id: UUID(), name: "Doc", nodes: [node])
        let project = CanvasProject(
            id: canvasID, name: "Canvas",
            documents: [document], selectedDocumentID: document.id,
            revision: 5
        )
        return (project, nodeID)
    }

    @Test func explicitContentTypeIsStoredNotNodeKindFallback() async throws {
        let (project, nodeID) = makeProject(nodeKind: .card)
        let repository = InMemoryCanvasRepository(project: project)
        let service = DesignCanvasService(repository: repository)
        let snapshot = try await service.mutate(
            canvasID: project.id, nodeID: nodeID,
            expectedRevision: 5, operationID: "op-create",
            contentType: .presentation
        ) { design in
            DesignWorkflowEngine.updateBrief(DesignBrief(goal: "Q4"), in: &design)
        }
        #expect(snapshot.design?.contentType == .presentation)
        let stored = await repository.stored(canvasID: project.id)
        let raw = stored?.documents.first?.nodes.first?.metadata[DesignCanvasMetadata.key]
        let decoded = try DesignCanvasMetadata.decode(raw, nodeID: nodeID.uuidString.lowercased())
        #expect(decoded?.contentType == .presentation)
        #expect(decoded?.brief?.goal == "Q4")
    }

    @Test func replayReturnsBeforeRevisionConflict() async throws {
        let (project, nodeID) = makeProject()
        let repository = InMemoryCanvasRepository(project: project)
        let service = DesignCanvasService(repository: repository)
        let first = try await service.mutate(
            canvasID: project.id, nodeID: nodeID,
            expectedRevision: 5, operationID: "op-1"
        ) { design in
            DesignWorkflowEngine.updateBrief(DesignBrief(goal: "A"), in: &design)
        }
        #expect(first.canvasRevision == 6)
        #expect(first.operationReplayed == false)

        // Replaying the original request with the original expected revision
        // must return the stored state, not conflict.
        let replayed = try await service.mutate(
            canvasID: project.id, nodeID: nodeID,
            expectedRevision: 5, operationID: "op-1"
        ) { design in
            DesignWorkflowEngine.updateBrief(DesignBrief(goal: "A-again"), in: &design)
        }
        #expect(replayed.operationReplayed == true)
        #expect(replayed.canvasRevision == 6)
        #expect(replayed.design?.brief?.goal == "A")

        // A genuinely new operation against a stale revision still conflicts.
        do {
            _ = try await service.mutate(
                canvasID: project.id, nodeID: nodeID,
                expectedRevision: 5, operationID: "op-2"
            ) { design in
                DesignWorkflowEngine.updateBrief(DesignBrief(goal: "B"), in: &design)
            }
            Issue.record("expected revision conflict")
        } catch {
            // expected
        }
    }

    @Test func authorizationDeniesForeignCanvas() async throws {
        let (project, nodeID) = makeProject()
        let repository = InMemoryCanvasRepository(project: project)
        let foreignCanvas = UUID()
        let service = DesignCanvasService(repository: repository) { runID, canvasID in
            runID != nil && canvasID == project.id
        }
        // Authorized run on the bound canvas succeeds.
        _ = try await service.mutate(
            runID: UUID(), canvasID: project.id, nodeID: nodeID,
            expectedRevision: 5, operationID: "op-auth"
        ) { design in
            DesignWorkflowEngine.updateBrief(DesignBrief(goal: "ok"), in: &design)
        }
        // Unauthorized/foreign access fails closed.
        do {
            _ = try await service.snapshot(runID: UUID(), canvasID: foreignCanvas, nodeID: nodeID)
            Issue.record("expected authorization failure")
        } catch {
            // expected
        }
        do {
            _ = try await service.snapshot(runID: nil, canvasID: project.id, nodeID: nodeID)
            Issue.record("expected authorization failure for missing run")
        } catch {
            // expected
        }
    }

    @Test func bindingMismatchFailsClosed() async throws {
        let (project, nodeID) = makeProject()
        var tampered = project
        let foreign = DesignWorkflowEngine.createProject(nodeID: "someone-else", contentType: .image)
        let raw = try DesignCanvasMetadata.encode(foreign)
        tampered.documents[0].nodes[0].metadata[DesignCanvasMetadata.key] = raw
        let repository = InMemoryCanvasRepository(project: tampered)
        let service = DesignCanvasService(repository: repository)
        do {
            _ = try await service.snapshot(canvasID: project.id, nodeID: nodeID)
            Issue.record("expected binding mismatch")
        } catch {
            // expected
        }
    }

}
