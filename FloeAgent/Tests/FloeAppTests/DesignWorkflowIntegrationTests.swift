// FloeAppTests — Design workflow integration: REAL production tool
// invocations end-to-end. Two real decodable PNGs flow
// import → revision payload → propose (payload bound before one CAS) →
// grant-gated adopt (real node asset in the same CAS) → verified export with
// the real image parser, plus replay and changed-request rejection.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import FloeApp
@testable import FloeCore
@testable import FloeTools

private actor FakeCanvasRepository: CanvasDocumentRepository {
    private var projects: [UUID: CanvasProject]
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
        projects[project.id] = project
    }
    func stored(canvasID: UUID) -> CanvasProject? { projects[canvasID] }
}

@Suite("Design workflow tool integration")
@MainActor
struct DesignWorkflowIntegrationTests {
    // Two REAL, distinct, decodable 1x1 PNGs (red / blue).
    private let redPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    private let bluePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private struct Harness {
        let environment: AppEnvironment
        let canvasID: UUID
        let nodeID: UUID
        let repository: FakeCanvasRepository
        let registry: ToolRunnerRegistry
        let outboxURL: URL
        var revision: Int64
    }

    /// Three-node harness used by the project-spec tests.
    private struct MultiNodeHarness {
        let environment: AppEnvironment
        let canvasID: UUID
        let nodeIDs: [UUID]
        let repository: FakeCanvasRepository
        let registry: ToolRunnerRegistry
        var revision: Int64
    }

    private func makeMultiNodeHarness() async throws -> MultiNodeHarness {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let canvasID = UUID()
        var nodes: [CanvasNode] = []
        for index in 0..<3 {
            var node = CanvasNode.placeholder(kind: .image, position: CanvasPoint(x: Double(index) * 60, y: 0), zIndex: index)
            node.id = UUID()
            node.title = "Hero-\(index)"
            nodes.append(node)
        }
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: nodes)
        var project = CanvasProject(id: canvasID, name: "多节点", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repository = FakeCanvasRepository(project: project)
        let registry = ToolRunnerRegistry()
        registerDesignAgentTools(
            capabilities: { environment.designAdapterCenter.capabilityRegistry() },
            adapters: environment.designAdapterCenter,
            environment: environment,
            authorize: { _, _ in true },
            repository: repository,
            decisionOutbox: DesignDecisionOutbox(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("design-multi-outbox-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("outbox.json")),
            registry: registry
        )
        return MultiNodeHarness(
            environment: environment, canvasID: canvasID, nodeIDs: nodes.map(\.id),
            repository: repository, registry: registry, revision: 1
        )
    }

    private func makeHarness(
        sink: (@MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void)? = nil
    ) async throws -> Harness {
        let environment = AppEnvironment.preview()
        // Apply schema migrations on the fixture database (async, never a
        // blocking bridge on the main actor).
        try await environment.database.migrate()
        let canvasID = UUID()
        let nodeID = UUID()
        var node = CanvasNode.placeholder(kind: .image, position: CanvasPoint(x: 10, y: 20), zIndex: 2)
        node.id = nodeID
        node.title = "Hero"
        node.size = CanvasSize(width: 320, height: 240)
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
        var project = CanvasProject(id: canvasID, name: "画布1-fixture", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repository = FakeCanvasRepository(project: project)
        let registry = ToolRunnerRegistry()
        let outboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("design-it-outbox-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("outbox.json")
        registerDesignAgentTools(
            capabilities: { environment.designAdapterCenter.capabilityRegistry() },
            adapters: environment.designAdapterCenter,
            environment: environment,
            authorize: { _, _ in true },
            repository: repository,
            decisionSink: sink ?? { _, _, _, _, _ in },
            decisionOutbox: DesignDecisionOutbox(fileURL: outboxURL),
            registry: registry
        )
        return Harness(
            environment: environment,
            canvasID: canvasID,
            nodeID: nodeID,
            repository: repository,
            registry: registry,
            outboxURL: outboxURL,
            revision: 1
        )
    }

    private func run(
        registry: ToolRunnerRegistry,
        tool: String,
        arguments: [String: Any],
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        let runner = try #require(registry.runner(named: tool))
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await runner.run(data, context)
    }

    private func harnessWithTextNode(text: String) async throws
        -> (harness: Harness, environment: AppEnvironment, repository: FakeCanvasRepository) {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let canvasID = UUID()
        let nodeID = UUID()
        var node = CanvasNode.placeholder(kind: .text, position: CanvasPoint(x: 0, y: 0), zIndex: 0)
        node.id = nodeID
        node.title = "Markdown"
        node.text = text
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
        var project = CanvasProject(id: canvasID, name: "画布1", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repository = FakeCanvasRepository(project: project)
        let registry = ToolRunnerRegistry()
        let outboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("design-cn-outbox-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("outbox.json")
        registerDesignAgentTools(
            capabilities: { environment.designAdapterCenter.capabilityRegistry() },
            adapters: environment.designAdapterCenter,
            environment: environment,
            authorize: { _, _ in true },
            repository: repository,
            decisionOutbox: DesignDecisionOutbox(fileURL: outboxURL),
            registry: registry
        )
        return (Harness(environment: environment, canvasID: canvasID, nodeID: nodeID,
                        repository: repository, registry: registry,
                        outboxURL: outboxURL, revision: 1), environment, repository)
    }

    private func run(
        _ harness: Harness,
        tool: String,
        arguments: [String: Any],
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        let runner = try #require(harness.registry.runner(named: tool))
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await runner.run(data, context)
    }

    private func context(runID: UUID = UUID(), conversationID: UUID? = nil) -> ToolContext {
        ToolContext(runID: runID, cancellation: CancellationToken(), conversationID: conversationID)
    }

    private func writeArtifactPNG(_ bytes: Data) throws -> String {
        let root = try FloeArtifactStore.root()
        let name = "Attachments/it-\(UUID().uuidString.lowercased()).png"
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return name
    }

    @Test func imageEndToEndViaProductionTools() async throws {
        var harness = try await makeHarness()
        let conversationID = UUID()
        // 1. Create the design subdocument.
        var output = try await run(harness, tool: "canvas.designCreate", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-create",
            "contentType": "image",
            "goal": "fixture"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        // 2. Import the red PNG through the real adapter.
        let importPath = try writeArtifactPNG(redPNG)
        output = try await run(harness, tool: "canvas.designImportSource", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-import",
            "sourceRelativePath": importPath,
            "displayName": "hero"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        let importJSON = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        let artifactID = try #require(importJSON["artifactID"] as? String)
        #expect(importJSON["contentSHA256"] as? String == FloeDigest.sha256Hex(redPNG))
        // Replay the import: same operation, same result, no duplicate state.
        let replayed = try await run(harness, tool: "canvas.designImportSource", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-import",
            "sourceRelativePath": importPath,
            "displayName": "hero"
        ], context: context(conversationID: conversationID))
        let replayJSON = try JSONSerialization.jsonObject(with: Data(replayed.summary.utf8)) as! [String: Any]
        #expect(replayJSON["artifactID"] as? String == artifactID)
        // 3. Propose the blue PNG: payload bound before one CAS.
        let proposePath = try writeArtifactPNG(bluePNG)
        output = try await run(harness, tool: "canvas.designPropose", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-propose",
            "artifactID": artifactID,
            "payloadRelativePath": proposePath,
            "summary": "blue variant"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        let proposeJSON = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        let design = try #require(proposeJSON["design"] as? [String: Any])
        let candidates = try #require(design["candidates"] as? [[String: Any]])
        let candidateID = try #require(candidates.first?["candidateID"] as? String)
        // The proposed revision must carry the payload pointer (production
        // binding), otherwise adopt/export cannot see real bytes.
        let artifacts = try #require(design["artifacts"] as? [[String: Any]])
        let artifact = try #require(artifacts.first { ($0["artifactID"] as? String) == artifactID })
        let revisions = try #require(artifact["revisionCount"] as? Int)
        #expect(revisions == 2)
        // 4. Grant-gated adoption through the shared action path.
        let grantID = await DesignAdoptionAuthorization.shared.issue(
            canvasID: harness.canvasID, nodeID: harness.nodeID,
            candidateID: candidateID,
            baselineRevisionID: candidates.first?["baseRevisionID"] as? String ?? ""
        )
        output = try await run(harness, tool: "canvas.designAdopt", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-adopt",
            "candidateID": candidateID,
            "mode": "updateOriginal",
            "baselineRevisionID": candidates.first?["baseRevisionID"] as? String ?? "",
            "grantID": grantID
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        let adoptJSON = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        let adoptedDesign = try #require(adoptJSON["design"] as? [String: Any])
        let adoptedCandidates = adoptedDesign["candidates"] as? [[String: Any]] ?? []
        #expect(adoptedCandidates.first?["status"] as? String == "adopted")
        // The ACTUAL node now references the adopted bytes; layout preserved.
        let project = try await harness.repository.project(canvasID: harness.canvasID)
        let node = try #require(project.documents.first?.nodes.first)
        #expect(node.asset?.byteCount == Int64(bluePNG.count))
        #expect(node.position == CanvasPoint(x: 10, y: 20))
        #expect(node.size == CanvasSize(width: 320, height: 240))
        #expect(node.title == "Hero")
        // 5. Verified export: recorded format, real reopen parser.
        let adoptedArtifacts = adoptedDesign["artifacts"] as? [[String: Any]] ?? []
        let current = try #require(adoptedArtifacts.first?["currentRevisionID"] as? String)
        output = try await run(harness, tool: "canvas.designExportRevision", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "artifactID": artifactID,
            "revisionID": current
        ], context: context(conversationID: conversationID))
        let exportJSON = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        #expect(exportJSON["verified"] as? Bool == true)
        #expect(exportJSON["contentSHA256"] as? String == FloeDigest.sha256Hex(bluePNG))
        // 6. Changed-request replay is rejected before side effects.
        await #expect(throws: (any Error).self) {
            _ = try await self.run(harness, tool: "canvas.designImportSource", arguments: [
                "canvasID": harness.canvasID.uuidString,
                "nodeID": harness.nodeID.uuidString,
                "expectedRevision": harness.revision,
                "operationID": "op-import", // same op, different bytes
                "sourceRelativePath": proposePath,
                "displayName": "hero"
            ], context: self.context(conversationID: conversationID))
        }
    }

    @Test func webpageCaptureFailsClosedWithoutExactTaskBinding() async throws {
        let environment = AppEnvironment.preview()
        let port = BrowserPageCapturePort(environment: environment)
        await #expect(throws: (any Error).self) {
            _ = try await port.capturePage(conversationID: UUID(), runID: UUID())
        }
    }

    // MARK: - Durable decision windows (defect 1)

    private actor DeliveryCounter {
        private(set) var deliveries: [(candidateID: UUID, decision: String)] = []
        func record(_ candidateID: UUID, _ decision: String) { deliveries.append((candidateID, decision)) }
        func count() -> Int { deliveries.count }
    }

    /// Seeds design → import → propose through the REAL production tools and
    /// returns the candidate identity.
    private func seedCandidate(
        _ harness: inout Harness,
        conversationID: UUID?
    ) async throws -> (artifactID: String, candidateID: String, baseRevisionID: String) {
        _ = try await run(harness, tool: "canvas.designCreate", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-create",
            "contentType": "image",
            "goal": "fixture"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        let importPath = try writeArtifactPNG(redPNG)
        let imported = try await run(harness, tool: "canvas.designImportSource", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-import",
            "sourceRelativePath": importPath,
            "displayName": "hero"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        let importJSON = try JSONSerialization.jsonObject(with: Data(imported.summary.utf8)) as! [String: Any]
        let artifactID = try #require(importJSON["artifactID"] as? String)
        let proposePath = try writeArtifactPNG(bluePNG)
        let proposed = try await run(harness, tool: "canvas.designPropose", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-propose",
            "artifactID": artifactID,
            "payloadRelativePath": proposePath,
            "summary": "blue variant"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        let proposeJSON = try JSONSerialization.jsonObject(with: Data(proposed.summary.utf8)) as! [String: Any]
        let design = try #require(proposeJSON["design"] as? [String: Any])
        let candidates = try #require(design["candidates"] as? [[String: Any]])
        let candidateID = try #require(candidates.first?["candidateID"] as? String)
        let baseRevisionID = try #require(candidates.first?["baseRevisionID"] as? String)
        return (artifactID, candidateID, baseRevisionID)
    }

    @Test func deliveryFailureLeavesDurableIntentAndReconcileDeliversExactlyOnce() async throws {
        let failingSink: @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void = { _, _, _, _, _ in
            throw FloeError.internalError("durable ingress unavailable")
        }
        var harness = try await makeHarness(sink: failingSink)
        let conversationID = UUID()
        let seeded = try await seedCandidate(&harness, conversationID: conversationID)
        let grantID = await DesignAdoptionAuthorization.shared.issue(
            canvasID: harness.canvasID, nodeID: harness.nodeID,
            candidateID: seeded.candidateID, baselineRevisionID: seeded.baseRevisionID
        )
        let output = try await run(harness, tool: "canvas.designAdopt", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-adopt",
            "candidateID": seeded.candidateID,
            "mode": "updateOriginal",
            "baselineRevisionID": seeded.baseRevisionID,
            "grantID": grantID
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        // The adoption committed, but delivery FAILED: the tool reports the
        // pending decision instead of a false "delivered".
        let adoptJSON = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        #expect(adoptJSON["decisionDelivered"] as? Bool == false)
        #expect(adoptJSON["decisionDeliveryPending"] as? Bool == true)
        let design = try #require(adoptJSON["design"] as? [String: Any])
        let candidates = design["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.first?["status"] as? String == "adopted")
        // The grant was consumed once for the committed transaction.
        let grantStillValid = await DesignAdoptionAuthorization.shared.validate(
            id: grantID, canvasID: harness.canvasID, nodeID: harness.nodeID,
            candidateID: seeded.candidateID, baselineRevisionID: seeded.baseRevisionID
        )
        #expect(grantStillValid == false)
        // The durable intent survived with the EXACT node/decision target.
        let reopened = DesignDecisionOutbox(fileURL: harness.outboxURL)
        let pending = await reopened.pendingIntents()
        #expect(pending.count == 1)
        let intent = try #require(pending.first)
        #expect(intent.nodeID == harness.nodeID.uuidString.lowercased())
        #expect(intent.candidateID == seeded.candidateID)
        #expect(intent.conversationID == conversationID.uuidString.lowercased())
        #expect(intent.decision == "adopted")
        #expect(intent.mode == "updateOriginal")
        #expect(intent.baseRevisionID == seeded.baseRevisionID)
        #expect(intent.expectedCanvasRevision == harness.revision - 1)
        // Relaunch reconcile delivers EXACTLY once and acknowledges.
        let repository = harness.repository
        let counter = DeliveryCounter()
        let deliver: @Sendable (DesignDecisionIntent, String) async throws -> Void = { intent, decision in
            await counter.record(UUID(uuidString: intent.candidateID) ?? UUID(), decision)
        }
        await reopened.reconcile(
            terminalDecision: { intent in
                guard let canvasID = UUID(uuidString: intent.canvasID),
                      let nodeID = UUID(uuidString: intent.nodeID) else { return .unavailable }
                let service = DesignCanvasService(repository: repository)
                guard let design = try? await service.designState(canvasID: canvasID, nodeID: nodeID) else {
                    return .unavailable
                }
                guard design.hasApplied(operationID: intent.operationID),
                      let candidate = design.candidate(intent.candidateID) else { return .notCommitted }
                if let base = intent.baseRevisionID, candidate.baseRevisionID != base { return .notCommitted }
                return candidate.status == .adopted ? .committed("adopted") : .notCommitted
            },
            deliver: deliver
        )
        #expect(await counter.count() == 1)
        let afterReconcile = DesignDecisionOutbox(fileURL: harness.outboxURL)
        #expect(await afterReconcile.pendingIntents().isEmpty)
        // A second reconcile never re-delivers.
        await afterReconcile.reconcile(
            terminalDecision: { _ in .committed("adopted") },
            deliver: deliver
        )
        #expect(await counter.count() == 1)
    }

    @Test func missingOriginCandidateStaysPendingWithoutCurrentChatFallback() async throws {
        var harness = try await makeHarness()
        // Proposed WITHOUT an originating conversation: no fallback exists.
        let seeded = try await seedCandidate(&harness, conversationID: nil)
        let grantID = await DesignAdoptionAuthorization.shared.issue(
            canvasID: harness.canvasID, nodeID: harness.nodeID,
            candidateID: seeded.candidateID, baselineRevisionID: seeded.baseRevisionID
        )
        do {
            _ = try await run(harness, tool: "canvas.designAdopt", arguments: [
                "canvasID": harness.canvasID.uuidString,
                "nodeID": harness.nodeID.uuidString,
                "expectedRevision": harness.revision,
                "operationID": "op-adopt-no-origin",
                "candidateID": seeded.candidateID,
                "mode": "updateOriginal",
                "baselineRevisionID": seeded.baseRevisionID,
                "grantID": grantID
            ], context: context(conversationID: UUID()))
            Issue.record("expected missing-origin failure")
        } catch {
            #expect(error.localizedDescription.contains("no originating task"))
        }
        // Candidate stays pending; the real node content is unchanged (the
        // import registers a revision but never applies content before
        // adoption — the node still has no asset); grant intact.
        let project = try await harness.repository.project(canvasID: harness.canvasID)
        let node = try #require(project.documents.first?.nodes.first)
        #expect(node.asset == nil)
        let state = try await run(harness, tool: "canvas.designGetState", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString
        ], context: context(conversationID: nil))
        let stateJSON = try JSONSerialization.jsonObject(with: Data(state.summary.utf8)) as! [String: Any]
        let design = try #require(stateJSON["design"] as? [String: Any])
        let candidates = design["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.first?["status"] as? String == "pending")
        let grantValid = await DesignAdoptionAuthorization.shared.validate(
            id: grantID, canvasID: harness.canvasID, nodeID: harness.nodeID,
            candidateID: seeded.candidateID, baselineRevisionID: seeded.baseRevisionID
        )
        #expect(grantValid)
    }

    // MARK: - Canvas project spec authority (defect 2)

    @Test func projectSpecToolAppliesAcrossNodesAtomicallyAndDedupes() async throws {
        var harness = try await makeMultiNodeHarness()
        let conversationID = UUID()
        for (index, nodeID) in harness.nodeIDs.enumerated() {
            _ = try await run(registry: harness.registry, tool: "canvas.designCreate", arguments: [
                "canvasID": harness.canvasID.uuidString,
                "nodeID": nodeID.uuidString,
                "expectedRevision": harness.revision,
                "operationID": "op-create-\(index)",
                "contentType": "image",
                "goal": "g"
            ], context: context(conversationID: conversationID))
            harness.revision += 1
        }
        // Apply project spec A across all three nodes in ONE project CAS.
        var output = try await run(registry: harness.registry, tool: "canvas.designSetProjectSpec", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "spec-A",
            "palette": ["#101010", "#f5f5f5"],
            "layout": "A"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        var payload = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        #expect(payload["updatedNodeCount"] as? Int == 3)
        #expect(payload["operationReplayed"] as? Bool == false)
        let identityA = try #require(payload["contentSHA256"] as? String)
        // Every node's design subdocument carries the same spec payload.
        var specSHAs: Set<String> = []
        for nodeID in harness.nodeIDs {
            let state = try await run(registry: harness.registry, tool: "canvas.designGetState", arguments: [
                "canvasID": harness.canvasID.uuidString,
                "nodeID": nodeID.uuidString
            ], context: context(conversationID: conversationID))
            let stateJSON = try JSONSerialization.jsonObject(with: Data(state.summary.utf8)) as! [String: Any]
            let design = try #require(stateJSON["design"] as? [String: Any])
            let spec = try #require(design["spec"] as? [String: Any])
            specSHAs.insert(try #require(spec["sha256"] as? String))
        }
        #expect(specSHAs.count == 1)
        // The project authority reads back with all three nodes recorded.
        let authorityOutput = try await run(registry: harness.registry, tool: "canvas.designGetProjectSpec", arguments: [
            "canvasID": harness.canvasID.uuidString
        ], context: context(conversationID: conversationID))
        let authorityJSON = try JSONSerialization.jsonObject(with: Data(authorityOutput.summary.utf8)) as! [String: Any]
        #expect(authorityJSON["configured"] as? Bool == true)
        #expect(authorityJSON["contentSHA256"] as? String == identityA)
        #expect((authorityJSON["inheritedNodeIDs"] as? [String])?.count == 3)
        // The identical payload under a new operation dedupes: no revision bump.
        output = try await run(registry: harness.registry, tool: "canvas.designSetProjectSpec", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "spec-A-replay",
            "palette": ["#101010", "#f5f5f5"],
            "layout": "A"
        ], context: context(conversationID: conversationID))
        payload = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        #expect(payload["operationReplayed"] as? Bool == true)
        #expect((payload["canvasRevision"] as? NSNumber)?.int64Value == harness.revision)
        // A DIFFERENT payload applies and reaches every node again.
        output = try await run(registry: harness.registry, tool: "canvas.designSetProjectSpec", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "spec-B",
            "palette": ["#000000"],
            "layout": "B"
        ], context: context(conversationID: conversationID))
        harness.revision += 1
        payload = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        #expect(payload["operationReplayed"] as? Bool == false)
        #expect(payload["contentSHA256"] as? String != identityA)
        let nodeZero = try await run(registry: harness.registry, tool: "canvas.designGetState", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeIDs[0].uuidString
        ], context: context(conversationID: conversationID))
        let nodeZeroJSON = try JSONSerialization.jsonObject(with: Data(nodeZero.summary.utf8)) as! [String: Any]
        let nodeZeroDesign = try #require(nodeZeroJSON["design"] as? [String: Any])
        let nodeZeroSpec = try #require(nodeZeroDesign["spec"] as? [String: Any])
        #expect(nodeZeroSpec["layout"] as? String == "B")
    }

    // MARK: - Use current node (defect 3)

    @Test func useCurrentNodeFreezesExistingTextAndReportsUnavailableReasons() async throws {
        let text = "# 设计说明\n\n这是画布上现有的 Markdown 内容。"
        var (harness, _, _) = try await harnessWithTextNode(text: text)
        let output = try await run(harness, tool: "canvas.designUseCurrentNode", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-current-1"
        ], context: context(conversationID: nil))
        harness.revision += 1
        let payload = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as! [String: Any]
        #expect(payload["usedCurrentNode"] as? Bool == true)
        #expect(payload["format"] as? String == "md")
        #expect(payload["byteCount"] as? Int == text.utf8.count)
        #expect(payload["contentSHA256"] as? String == FloeDigest.sha256Hex(Data(text.utf8)))
        // The frozen revision is a real retained revision on the artifact, and
        // the mutable node text is untouched.
        let state = try await run(harness, tool: "canvas.designGetState", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString
        ], context: context(conversationID: nil))
        let stateJSON = try JSONSerialization.jsonObject(with: Data(state.summary.utf8)) as! [String: Any]
        let design = try #require(stateJSON["design"] as? [String: Any])
        let artifacts = try #require(design["artifacts"] as? [[String: Any]])
        #expect(artifacts.count == 1)
        let project = try await harness.repository.project(canvasID: harness.canvasID)
        #expect(project.documents.first?.nodes.first?.text == text)
        // Replay with the identical content returns the recorded revision.
        let replay = try await run(harness, tool: "canvas.designUseCurrentNode", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-current-1"
        ], context: context(conversationID: nil))
        let replayJSON = try JSONSerialization.jsonObject(with: Data(replay.summary.utf8)) as! [String: Any]
        #expect(replayJSON["operationReplayed"] as? Bool == true)
        #expect(replayJSON["revisionID"] as? String == payload["revisionID"] as? String)
        // Empty node → precise unavailable reason.
        let (emptyHarness, _, _) = try await harnessWithTextNode(text: "")
        do {
            _ = try await run(emptyHarness, tool: "canvas.designUseCurrentNode", arguments: [
                "canvasID": emptyHarness.canvasID.uuidString,
                "nodeID": emptyHarness.nodeID.uuidString,
                "expectedRevision": emptyHarness.revision,
                "operationID": "op-current-empty"
            ], context: context(conversationID: nil))
            Issue.record("expected empty-node failure")
        } catch {
            #expect(error.localizedDescription.contains("no text content"))
        }
        // Unbound CAD node → precise unavailable reason.
        let cadHarness = try await makeCadNodeHarness()
        do {
            _ = try await run(cadHarness, tool: "canvas.designUseCurrentNode", arguments: [
                "canvasID": cadHarness.canvasID.uuidString,
                "nodeID": cadHarness.nodeID.uuidString,
                "expectedRevision": cadHarness.revision,
                "operationID": "op-current-cad"
            ], context: context(conversationID: nil))
            Issue.record("expected unbound CAD failure")
        } catch {
            #expect(error.localizedDescription.contains("no retained content"))
        }
    }

    private func makeCadNodeHarness() async throws -> Harness {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let canvasID = UUID()
        let nodeID = UUID()
        var node = CanvasNode.placeholder(kind: .scene3D, position: CanvasPoint(x: 0, y: 0), zIndex: 0)
        node.id = nodeID
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
        var project = CanvasProject(id: canvasID, name: "cad", documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repository = FakeCanvasRepository(project: project)
        let registry = ToolRunnerRegistry()
        let outboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("design-cad-outbox-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("outbox.json")
        registerDesignAgentTools(
            capabilities: { environment.designAdapterCenter.capabilityRegistry() },
            adapters: environment.designAdapterCenter,
            environment: environment,
            authorize: { _, _ in true },
            repository: repository,
            decisionOutbox: DesignDecisionOutbox(fileURL: outboxURL),
            registry: registry
        )
        return Harness(environment: environment, canvasID: canvasID, nodeID: nodeID,
                       repository: repository, registry: registry,
                       outboxURL: outboxURL, revision: 1)
    }
}
#endif
