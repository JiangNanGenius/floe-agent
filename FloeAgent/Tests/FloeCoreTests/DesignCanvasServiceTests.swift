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

// MARK: - Whole-project adoption (real node content in ONE CAS)

@Suite("Design whole-project adoption")
struct DesignCanvasProjectMutationTests {
    private func makeFixture(text: String = "old content") throws -> (canvasID: UUID, nodeID: UUID, repo: InMemoryCanvasRepository, service: DesignCanvasService) {
        let canvasID = UUID()
        let nodeID = UUID()
        var node = CanvasNode.placeholder(kind: .text, position: CanvasPoint(x: 10, y: 20), zIndex: 3)
        node.id = nodeID
        node.title = "Original"
        node.text = text
        node.size = CanvasSize(width: 300, height: 200)
        node.rotation = 5
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
        var project = CanvasProject(id: canvasID, name: "T", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repo = InMemoryCanvasRepository(project: project)
        let service = DesignCanvasService(repository: repo)
        return (canvasID, nodeID, repo, service)
    }

    @Test func adoptionUpdatesRealNodeTextInSameCommit() async throws {
        let (canvasID, nodeID, repo, service) = try makeFixture()
        // Create design + artifact + candidate via the normal flow.
        var snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: 1,
            operationID: "op-create", contentType: .notes
        ) { design in
            DesignWorkflowEngine.updateBrief(DesignBrief(goal: "g"), in: &design)
        }
        let artifact = DesignArtifact(contentType: .notes, canvasNodeID: nodeID.uuidString.lowercased(), identity: .init(name: "a", positionX: 0, positionY: 0, width: 0, height: 0))
        snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-artifact"
        ) { design in
            DesignWorkflowEngine.addArtifact(artifact, to: &design)
        }
        let baseSHA = FloeDigest.sha256Hex(Data("old content".utf8))
        snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-rev"
        ) { design in
            _ = try DesignWorkflowEngine.registerRevision(in: &design, artifactID: artifact.id, contentSHA256: baseSHA, origin: .importFile)
        }
        let proposedSHA = FloeDigest.sha256Hex(Data("new content".utf8))
        snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-propose"
        ) { design in
            _ = try DesignWorkflowEngine.proposeCandidate(
                in: &design, artifactID: artifact.id,
                proposedContentSHA256: proposedSHA, summary: "s"
            )
        }
        let candidateID = try #require(snapshot.design?.candidates.first?.id)
        // Adopt with REAL node content in ONE commit.
        let adopted = try await service.mutateProject(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-adopt"
        ) { project, design in
            _ = try DesignWorkflowEngine.adoptCandidate(in: &design, candidateID: candidateID, mode: .updateOriginal)
            guard let d = project.documents.firstIndex(where: { $0.nodes.contains(where: { $0.id == nodeID }) }),
                  let n = project.documents[d].nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            project.documents[d].nodes[n].text = "new content"
        }
        #expect(adopted.canvasRevision == snapshot.canvasRevision + 1)
        let project = try await repo.project(canvasID: canvasID)
        let node = try #require(project.documents.first?.nodes.first)
        // Real content AND metadata advanced together.
        #expect(node.text == "new content")
        #expect(node.title == "Original")
        #expect(node.position == .init(x: 10, y: 20))
        #expect(node.size == .init(width: 300, height: 200))
        #expect(node.rotation == 5)
        #expect(node.zIndex == 3)
        let design = try #require(adopted.design)
        #expect(design.candidate(candidateID)?.status == .adopted)
    }

    @Test func variantCreatesActualNodeAndReplaySkipsContentWork() async throws {
        let (canvasID, nodeID, repo, service) = try makeFixture()
        var snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: 1,
            operationID: "op-create", contentType: .notes
        ) { design in
            DesignWorkflowEngine.updateBrief(DesignBrief(goal: "g"), in: &design)
        }
        let artifact = DesignArtifact(contentType: .notes, canvasNodeID: nodeID.uuidString.lowercased(), identity: .init(name: "a", positionX: 0, positionY: 0, width: 0, height: 0))
        snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-artifact"
        ) { design in
            DesignWorkflowEngine.addArtifact(artifact, to: &design)
        }
        let baseSHA = FloeDigest.sha256Hex(Data("old".utf8))
        snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-rev"
        ) { design in
            _ = try DesignWorkflowEngine.registerRevision(in: &design, artifactID: artifact.id, contentSHA256: baseSHA, origin: .importFile)
        }
        let proposedSHA = FloeDigest.sha256Hex(Data("variant content".utf8))
        snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-propose"
        ) { design in
            _ = try DesignWorkflowEngine.proposeCandidate(
                in: &design, artifactID: artifact.id,
                proposedContentSHA256: proposedSHA, summary: "s"
            )
        }
        let candidateID = try #require(snapshot.design?.candidates.first?.id)
        let adopted = try await service.mutateProject(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: snapshot.canvasRevision,
            operationID: "op-variant"
        ) { project, design in
            _ = try DesignWorkflowEngine.adoptCandidate(in: &design, candidateID: candidateID, mode: .variant)
            guard let d = project.documents.firstIndex(where: { $0.nodes.contains(where: { $0.id == nodeID }) }),
                  let n = project.documents[d].nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            var variant = project.documents[d].nodes[n]
            variant.id = UUID()
            variant.text = "variant content"
            project.documents[d].nodes.append(variant)
        }
        let project = try await repo.project(canvasID: canvasID)
        #expect(project.documents.first?.nodes.count == 2)
        // Replay returns before content work and without a revision bump.
        let replay = try await service.mutateProject(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: adopted.canvasRevision,
            operationID: "op-variant"
        ) { project, _ in
            project.documents[0].nodes.removeAll() // must never run
        }
        #expect(replay.operationReplayed)
        #expect(replay.canvasRevision == adopted.canvasRevision)
        let after = try await repo.project(canvasID: canvasID)
        #expect(after.documents.first?.nodes.count == 2)
    }
}

// MARK: - Canvas-owned workspace binding

@Suite("Design workspace binding")
struct DesignWorkspaceBindingTests {
    @Test func bindCopiesBytesAndRejectsTraversal() throws {
        let canvasID = UUID()
        let nodeID = UUID()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("bind-source-\(UUID().uuidString).txt")
        try Data("office-bytes".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        let binding = try DesignWorkspace.bind(
            canvasID: canvasID, nodeID: nodeID, sourceFile: source, format: "docx"
        )
        #expect(binding.relativeDocumentPath == "docs/\(nodeID.uuidString.lowercased()).docx")
        let written = try Data(contentsOf: URL(fileURLWithPath: binding.documentAbsolutePath))
        #expect(written == Data("office-bytes".utf8))
        // Round trip: adopted bytes replace the bound document.
        try DesignWorkspace.write(bytes: Data("adopted".utf8), to: binding)
        #expect(try Data(contentsOf: URL(fileURLWithPath: binding.documentAbsolutePath)) == Data("adopted".utf8))
        // Traversal is rejected.
        #expect(throws: DesignWorkspaceBindingError.invalidRelativePath("../escape.txt")) {
            guard let root = DesignWorkspace.root(canvasID: canvasID) else {
                throw DesignWorkspaceBindingError.invalidRelativePath("no root")
            }
            _ = try DesignWorkspace.contained(relativePath: "../escape.txt", in: root)
        }
        // Per-canvas isolation: a second canvas has its own root.
        let other = try DesignWorkspace.bind(
            canvasID: UUID(), nodeID: nodeID, sourceFile: source, format: "docx"
        )
        #expect(other.workspaceRootPath != binding.workspaceRootPath)
    }

    @Test func bindingPersistsThroughDesignCAS() async throws {
        let canvasID = UUID()
        let nodeID = UUID()
        var node = CanvasNode.placeholder(kind: .file, position: CanvasPoint(x: 0, y: 0), zIndex: 0)
        node.id = nodeID
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
        var project = CanvasProject(id: canvasID, name: "T", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repo = InMemoryCanvasRepository(project: project)
        let service = DesignCanvasService(repository: repo)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("bind-source-\(UUID().uuidString).txt")
        try Data("cad-bytes".utf8).write(to: source, options: .atomic)
        defer { try? FileManager.default.removeItem(at: source) }
        let binding = try DesignWorkspace.bind(
            canvasID: canvasID, nodeID: nodeID, sourceFile: source, format: "floecad"
        )
        let snapshot = try await service.mutate(
            canvasID: canvasID, nodeID: nodeID, expectedRevision: 1, operationID: "op-bind"
        ) { design in
            design.workspaceBinding = binding
        }
        let restored = try #require(snapshot.design?.workspaceBinding)
        #expect(restored == binding)
        // Replay-safe: binding survives a second read.
        let again = try await service.designState(canvasID: canvasID, nodeID: nodeID)
        #expect(again?.workspaceBinding == binding)
    }
}
