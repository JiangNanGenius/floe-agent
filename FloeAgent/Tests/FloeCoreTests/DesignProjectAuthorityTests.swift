import Foundation
import Testing
@testable import FloeCore

// FloeCoreTests — Canvas-level project brief/spec authority.
//
// The authority lives ON the CanvasProject (no parallel store) and every
// apply is ONE project CAS. These tests exercise: >=3 nodes inheriting in a
// single commit, repeated different payloads, CAS conflicts, unrelated node
// edits not changing the authority, reopen/decode persistence, frozen-run
// preservation and raw DESIGN.md unknown-section preservation.

private actor AuthorityRepository: CanvasDocumentRepository {
    private var projects: [UUID: CanvasProject]
    private var saveCount = 0

    init(project: CanvasProject) { self.projects = [project.id: project] }

    func project(canvasID: UUID) async throws -> CanvasProject {
        guard let project = projects[canvasID] else {
            throw FloeError.validationFailed("missing canvas")
        }
        return project
    }

    func save(_ project: CanvasProject, expectedRevision: Int64) async throws {
        guard let current = projects[project.id], current.revision == expectedRevision else {
            throw FloeError.validationFailed("revision conflict")
        }
        saveCount += 1
        projects[project.id] = project
    }

    func stored(canvasID: UUID) -> CanvasProject? { projects[canvasID] }
    func saves() -> Int { saveCount }

    /// Test-only: adds a node to the first document through the same CAS.
    func addNode(canvasID: UUID, node: CanvasNode, expectedRevision: Int64) async throws {
        guard var project = projects[canvasID], project.revision == expectedRevision else {
            throw FloeError.validationFailed("revision conflict")
        }
        project.documents[0].nodes.append(node)
        project.revision = expectedRevision + 1
        project.updatedAt = Date()
        projects[canvasID] = project
    }
}

@Suite("Design project authority on the Canvas project")
struct DesignProjectAuthorityTests {
    private func makeFixture(nodeCount: Int = 3, withDesignOnFirst: Bool = true) async throws
        -> (canvasID: UUID, nodeIDs: [UUID], repo: AuthorityRepository, service: DesignCanvasService) {
        let canvasID = UUID()
        var nodes: [CanvasNode] = []
        for index in 0..<nodeCount {
            var node = CanvasNode.placeholder(kind: .text, position: CanvasPoint(x: Double(index) * 40, y: 0), zIndex: index)
            node.id = UUID()
            node.text = "node-\(index)"
            nodes.append(node)
        }
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: nodes)
        var project = CanvasProject(id: canvasID, name: "T", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repo = AuthorityRepository(project: project)
        let service = DesignCanvasService(repository: repo)
        if withDesignOnFirst {
            _ = try await service.mutate(
                canvasID: canvasID, nodeID: nodes[0].id,
                expectedRevision: 1, operationID: "op-seed", contentType: .notes
            ) { design in
                DesignWorkflowEngine.updateBrief(DesignBrief(goal: "seed"), in: &design)
            }
        }
        return (canvasID, nodes.map(\.id), repo, service)
    }

    private func spec(_ layout: String) -> DesignSpec {
        DesignSpec(layout: layout, rawMarkdown: "# Custom\n\n## Unknown Section\nkeep me\n")
    }

    @Test func appliesAcrossAllNodesInOneProjectCommit() async throws {
        // Three existing design subdocuments on three nodes.
        let (canvasID, nodeIDs, repo, service) = try await makeFixture(nodeCount: 3)
        // Create design docs on all three via single-node CAS each.
        var revision: Int64 = 2 // fixture created the first design
        for nodeID in nodeIDs.dropFirst() {
            _ = try await service.mutate(
                canvasID: canvasID, nodeID: nodeID,
                expectedRevision: revision, operationID: "op-design-\(nodeID.uuidString)",
                contentType: .notes
            ) { design in
                DesignWorkflowEngine.updateBrief(DesignBrief(goal: "g"), in: &design)
            }
            revision += 1
        }
        let savesBefore = await repo.saves()
        let result = try await service.applyProjectAuthority(
            canvasID: canvasID,
            expectedRevision: revision,
            operationID: "op-spec-A",
            brief: DesignBrief(goal: "project"),
            spec: spec("A"),
            inheritToExistingNodes: true
        )
        // ONE repository save for the whole canvas.
        #expect(await repo.saves() == savesBefore + 1)
        #expect(result.canvasRevision == revision + 1)
        #expect(result.updatedNodeIDs.count == 3)
        #expect(result.skippedNodeIDs.isEmpty)
        #expect(Set(result.authority.inheritedNodeIDs) == Set(nodeIDs.map { $0.uuidString.lowercased() }))
        // Every node carries the payload.
        for nodeID in nodeIDs {
            let design = try #require(try await service.designState(canvasID: canvasID, nodeID: nodeID))
            #expect(design.spec == spec("A"))
            #expect(design.brief?.goal == "project")
        }
    }

    @Test func repeatedDifferentPayloadsApplyAndIdenticalReplayDedupes() async throws {
        let (canvasID, nodeIDs, _, service) = try await makeFixture(nodeCount: 3)
        var revision: Int64 = 2
        for nodeID in nodeIDs.dropFirst() {
            _ = try await service.mutate(
                canvasID: canvasID, nodeID: nodeID, expectedRevision: revision,
                operationID: "op-design-\(nodeID.uuidString)", contentType: .notes
            ) { _ in }
            revision += 1
        }
        let first = try await service.applyProjectAuthority(
            canvasID: canvasID, expectedRevision: revision, operationID: "op-1",
            brief: nil, spec: spec("A"), inheritToExistingNodes: true
        )
        revision = first.canvasRevision
        // A DIFFERENT payload with a new operation must apply.
        let second = try await service.applyProjectAuthority(
            canvasID: canvasID, expectedRevision: revision, operationID: "op-2",
            brief: nil, spec: spec("B"), inheritToExistingNodes: true
        )
        #expect(second.operationReplayed == false)
        #expect(second.canvasRevision == revision + 1)
        for nodeID in nodeIDs {
            let design = try #require(try await service.designState(canvasID: canvasID, nodeID: nodeID))
            #expect(design.spec == spec("B"))
        }
        // Replaying operation op-1 with its ORIGINAL payload A is a true
        // idempotent replay: it returns the current state (B) without
        // rewriting the authority.
        let replayedOld = try await service.applyProjectAuthority(
            canvasID: canvasID, expectedRevision: second.canvasRevision, operationID: "op-1",
            brief: nil, spec: spec("A"), inheritToExistingNodes: true
        )
        #expect(replayedOld.operationReplayed == true)
        #expect(replayedOld.authority.spec == spec("B"))
        let stillB = try #require(try await service.projectAuthority(canvasID: canvasID))
        #expect(stillB.spec == spec("B"))
        // Reusing op-1 with a DIFFERENT payload is a changed request and must
        // be rejected, never silently deduped.
        do {
            _ = try await service.applyProjectAuthority(
                canvasID: canvasID, expectedRevision: second.canvasRevision, operationID: "op-1",
                brief: nil, spec: spec("C"), inheritToExistingNodes: true
            )
            Issue.record("expected changed-payload rejection")
        } catch {
            // expected
        }
        // The identical current payload (same spec, new operation) dedupes
        // without a revision bump.
        let replay = try await service.applyProjectAuthority(
            canvasID: canvasID, expectedRevision: second.canvasRevision, operationID: "op-3",
            brief: nil, spec: spec("B"), inheritToExistingNodes: true
        )
        #expect(replay.operationReplayed == true)
        #expect(replay.canvasRevision == second.canvasRevision)
    }

    @Test func staleRevisionConflictsAndUnrelatedNodeEditDoesNotChangeAuthority() async throws {
        let (canvasID, nodeIDs, _, service) = try await makeFixture(nodeCount: 3)
        var revision: Int64 = 2
        for nodeID in nodeIDs.dropFirst() {
            _ = try await service.mutate(
                canvasID: canvasID, nodeID: nodeID, expectedRevision: revision,
                operationID: "op-design-\(nodeID.uuidString)", contentType: .notes
            ) { _ in }
            revision += 1
        }
        let applied = try await service.applyProjectAuthority(
            canvasID: canvasID, expectedRevision: revision, operationID: "op-spec",
            brief: nil, spec: spec("A"), inheritToExistingNodes: true
        )
        // Unrelated node edit: add feedback on node 2 (metadata-only change).
        _ = try await service.mutate(
            canvasID: canvasID, nodeID: nodeIDs[2], expectedRevision: applied.canvasRevision,
            operationID: "op-unrelated"
        ) { design in
            if let artifactID = design.artifacts.first?.id {
                _ = try? DesignWorkflowEngine.addFeedback(
                    in: &design, artifactID: artifactID,
                    anchor: .objectID("x"), comment: "unrelated", author: .user
                )
            } else {
                DesignWorkflowEngine.updateBrief(DesignBrief(goal: "unrelated"), in: &design)
            }
        }
        // The authority is unchanged by the unrelated edit.
        let authority = try #require(try await service.projectAuthority(canvasID: canvasID))
        #expect(authority.spec == spec("A"))
        #expect(authority.contentSHA256 == applied.authority.contentSHA256)
        // A stale expected revision still conflicts.
        do {
            _ = try await service.applyProjectAuthority(
                canvasID: canvasID, expectedRevision: applied.canvasRevision,
                operationID: "op-stale", brief: nil, spec: spec("C"), inheritToExistingNodes: true
            )
            Issue.record("expected revision conflict")
        } catch {
            // expected
        }
    }

    @Test func newNodesInheritAndReopenPersistsAndFrozenRunPreserved() async throws {
        let (canvasID, nodeIDs, repo, service) = try await makeFixture(nodeCount: 3)
        var revision: Int64 = 2
        for nodeID in nodeIDs.dropFirst() {
            _ = try await service.mutate(
                canvasID: canvasID, nodeID: nodeID, expectedRevision: revision,
                operationID: "op-design-\(nodeID.uuidString)", contentType: .notes
            ) { _ in }
            revision += 1
        }
        // Freeze a run on node 0 BEFORE the authority exists for it.
        _ = try await service.mutate(
            canvasID: canvasID, nodeID: nodeIDs[0], expectedRevision: revision,
            operationID: "op-freeze"
        ) { design in
            _ = DesignWorkflowEngine.freezeRun(operationID: "run-1", in: &design)
        }
        revision += 1
        let applied = try await service.applyProjectAuthority(
            canvasID: canvasID, expectedRevision: revision, operationID: "op-spec",
            brief: DesignBrief(goal: "project"), spec: spec("A"), inheritToExistingNodes: true
        )
        // The frozen run record is untouched by propagation.
        let frozenNode = try #require(try await service.designState(canvasID: canvasID, nodeID: nodeIDs[0]))
        #expect(frozenNode.frozenRun?.operationID == "run-1")
        #expect(frozenNode.spec == spec("A"))
        // A NEW node's design subdocument inherits the authority.
        var freshNode = CanvasNode.placeholder(kind: .text, position: CanvasPoint(x: 400, y: 0), zIndex: 9)
        freshNode.id = UUID()
        try await repo.addNode(canvasID: canvasID, node: freshNode, expectedRevision: applied.canvasRevision)
        _ = try await service.mutate(
            canvasID: canvasID, nodeID: freshNode.id,
            expectedRevision: applied.canvasRevision + 1, operationID: "op-fresh",
            contentType: .notes
        ) { _ in
            // No body edit: the fresh subdocument must carry inherited values.
        }
        let fresh = try #require(try await service.designState(canvasID: canvasID, nodeID: freshNode.id))
        #expect(fresh.spec == spec("A"))
        #expect(fresh.brief?.goal == "project")
        let stored = try #require(await repo.stored(canvasID: canvasID))
        #expect(stored.designProjectAuthority?.spec == spec("A"))
        #expect(stored.designProjectAuthority?.contentSHA256 == applied.authority.contentSHA256)
        // Reopen: a fresh service over the same repository decodes the same
        // authority (rawMarkdown/unknown sections preserved).
        let reopened = DesignCanvasService(repository: repo)
        let reopenedAuthority = try #require(try await reopened.projectAuthority(canvasID: canvasID))
        #expect(reopenedAuthority.spec?.rawMarkdown == spec("A").rawMarkdown)
    }
}
