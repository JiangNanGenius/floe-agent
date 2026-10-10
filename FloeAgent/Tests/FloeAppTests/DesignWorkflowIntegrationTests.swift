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

    private func makeHarness() async throws -> Harness {
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
}
#endif
