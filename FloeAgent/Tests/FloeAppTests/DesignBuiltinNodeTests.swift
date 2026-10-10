// FloeAppTests — Built-in Canvas source nodes (Markdown/HTML/SVG cards)
// through the REAL production design path.
//
// Regression: WorkspaceCanvasStore.addBuiltinNode(pluginID:) creates a
// `.card` node carrying metadata `builtinPlugin` and stores its typed source
// (markdown/html/svg) in the node TEXT, rendered by builtinNodeContent. The
// design workflow previously rejected those cards ("no retained content to
// freeze") and adopt wrote nothing back. These tests reproduce the exact
// production node structure and drive:
//
//   use-current-node (freeze) → propose (parser-verified) → grant-gated adopt
//   (text written back into the SAME card; kind/metadata/layout preserved) →
//   verified export/reopen
//
// plus the precise unsupported states (panorama builtin, wrong-format
// adoption, non-SVG bytes renamed .svg).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
@testable import FloeCore
@testable import FloeTools

@Suite("Design built-in source node integration")
@MainActor
struct DesignBuiltinNodeTests {
    private struct Harness {
        let canvasID: UUID
        let nodeID: UUID
        let repository: FakeBuiltinRepository
        let registry: ToolRunnerRegistry
        var revision: Int64
    }

    /// Reproduces `WorkspaceCanvasStore.addBuiltinNode(pluginID:)`: a `.card`
    /// (except panorama3D, which is an `.image`) with default text and the
    /// `builtinPlugin` metadata marker.
    private func makeHarness(pluginID: String, text: String) async throws -> Harness {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let canvasID = UUID()
        let nodeID = UUID()
        let kind: CanvasNodeKind = pluginID == "panorama3D" ? .image : .card
        var node = CanvasNode.placeholder(kind: kind, position: CanvasPoint(x: 30, y: 40), zIndex: 1)
        node.id = nodeID
        node.title = "builtin-\(pluginID)"
        node.text = text
        node.size = CanvasSize(width: 300, height: 200)
        node.metadata["builtinPlugin"] = pluginID
        let document = CanvasDocument(id: UUID(), name: "doc", nodes: [node])
        var project = CanvasProject(id: canvasID, name: "builtin-canvas",
                                     documents: [document], selectedDocumentID: document.id)
        project.revision = 1
        let repository = FakeBuiltinRepository(project: project)
        let registry = ToolRunnerRegistry()
        registerDesignAgentTools(
            capabilities: { environment.designAdapterCenter.capabilityRegistry() },
            adapters: environment.designAdapterCenter,
            environment: environment,
            authorize: { _, _ in true },
            repository: repository,
            decisionSink: { _, _, _, _, _ in },
            decisionOutbox: DesignDecisionOutbox(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("design-builtin-outbox-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("outbox.json")),
            registry: registry
        )
        return Harness(canvasID: canvasID, nodeID: nodeID,
                       repository: repository, registry: registry, revision: 1)
    }

    private func run(_ harness: Harness, tool: String, arguments: [String: Any],
                     runID: UUID = UUID(), conversationID: UUID? = nil) async throws -> ToolExecutionOutput {
        let runner = try #require(harness.registry.runner(named: tool))
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return try await runner.run(
            data,
            ToolContext(runID: runID, cancellation: CancellationToken(), conversationID: conversationID)
        )
    }

    private func json(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
    }

    private func writeSource(_ bytes: Data, name: String) throws -> String {
        let root = try FloeArtifactStore.root()
        let relative = "Attachments/it-\(UUID().uuidString.lowercased())-\(name)"
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return relative
    }

    private func currentNode(_ harness: Harness) async throws -> CanvasNode {
        let project = try await harness.repository.project(canvasID: harness.canvasID)
        return try #require(project.documents.first?.nodes.first)
    }

    @discardableResult
    private func freeze(_ harness: inout Harness, operationID: String) async throws
        -> (artifactID: String, revisionID: String, format: String) {
        let output = try await run(harness, tool: "canvas.designUseCurrentNode", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": operationID
        ])
        harness.revision += 1
        let payload = try json(output)
        #expect(payload["usedCurrentNode"] as? Bool == true)
        return (
            try #require(payload["artifactID"] as? String),
            try #require(payload["revisionID"] as? String),
            try #require(payload["format"] as? String)
        )
    }

    private func propose(_ harness: inout Harness, artifactID: String,
                         operationID: String, path: String, summary: String,
                         conversationID: UUID) async throws
        -> (candidateID: String, baseRevisionID: String) {
        let output = try await run(harness, tool: "canvas.designPropose", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": operationID,
            "artifactID": artifactID,
            "payloadRelativePath": path,
            "summary": summary
        ], conversationID: conversationID)
        harness.revision += 1
        let payload = try json(output)
        let design = try #require(payload["design"] as? [String: Any])
        let candidates = try #require(design["candidates"] as? [[String: Any]])
        return (
            try #require(candidates.first?["candidateID"] as? String),
            try #require(candidates.first?["baseRevisionID"] as? String)
        )
    }

    private func adopt(_ harness: inout Harness, candidateID: String,
                       baseRevisionID: String, operationID: String,
                       conversationID: UUID) async throws -> [String: Any] {
        let grantID = await DesignAdoptionAuthorization.shared.issue(
            canvasID: harness.canvasID, nodeID: harness.nodeID,
            candidateID: candidateID, baselineRevisionID: baseRevisionID
        )
        let output = try await run(harness, tool: "canvas.designAdopt", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": operationID,
            "candidateID": candidateID,
            "mode": "updateOriginal",
            "baselineRevisionID": baseRevisionID,
            "grantID": grantID
        ], conversationID: conversationID)
        harness.revision += 1
        let payload = try json(output)
        let design = try #require(payload["design"] as? [String: Any])
        let candidates = design["candidates"] as? [[String: Any]] ?? []
        #expect(candidates.first?["status"] as? String == "adopted")
        return design
    }

    private let markdownSource = "# 设计说明\n\n这是画布上现有的 **Markdown** 内容。\n"
    private let htmlSource = "<html><body><h1>Title</h1><p>Hello <b>built-in</b></p></body></html>"
    private let svgSource = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>"#
    private let proposedMarkdown = "# 更新\n\n新的 Markdown 正文。\n"
    private let proposedHTML = "<html><body><h1>Updated</h1></body></html>"
    private let proposedSVG = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5"/></svg>"#

    // MARK: - Freeze

    @Test func markdownBuiltinFreezesAsNotes() async throws {
        var harness = try await makeHarness(pluginID: "markdown", text: markdownSource)
        let frozen = try await freeze(&harness, operationID: "op-builtin-md-freeze")
        #expect(frozen.format == "md")
        let state = try await json(run(harness, tool: "canvas.designGetState", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString
        ]))
        let design = try #require(state["design"] as? [String: Any])
        #expect(design["contentType"] as? String == "notes")
        let artifacts = try #require(design["artifacts"] as? [[String: Any]])
        #expect(artifacts.count == 1)
        // Mutable card text and metadata are untouched by the freeze.
        let node = try await currentNode(harness)
        #expect(node.text == markdownSource)
        #expect(node.kind == .card)
        #expect(node.metadata["builtinPlugin"] == "markdown")
    }

    @Test func htmlAndSVGBuiltinsFreezeWithRecordedFormats() async throws {
        var htmlHarness = try await makeHarness(pluginID: "html", text: htmlSource)
        let htmlFrozen = try await freeze(&htmlHarness, operationID: "op-builtin-html-freeze")
        #expect(htmlFrozen.format == "html")

        var svgHarness = try await makeHarness(pluginID: "svg", text: svgSource)
        let svgFrozen = try await freeze(&svgHarness, operationID: "op-builtin-svg-freeze")
        #expect(svgFrozen.format == "svg")

        let state = try await json(run(svgHarness, tool: "canvas.designGetState", arguments: [
            "canvasID": svgHarness.canvasID.uuidString,
            "nodeID": svgHarness.nodeID.uuidString
        ]))
        let design = try #require(state["design"] as? [String: Any])
        #expect(design["contentType"] as? String == "webpage")
    }

    @Test func panoramaBuiltinWithoutAssetFailsExplicitly() async throws {
        let harness = try await makeHarness(pluginID: "panorama3D", text: "Panorama")
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "canvas.designUseCurrentNode", arguments: [
                "canvasID": harness.canvasID.uuidString,
                "nodeID": harness.nodeID.uuidString,
                "expectedRevision": harness.revision,
                "operationID": "op-builtin-panorama"
            ])
        }
    }

    @Test func emptyBuiltinCardFailsExplicitly() async throws {
        let harness = try await makeHarness(pluginID: "markdown", text: "   \n ")
        await #expect(throws: (any Error).self) {
            _ = try await run(harness, tool: "canvas.designUseCurrentNode", arguments: [
                "canvasID": harness.canvasID.uuidString,
                "nodeID": harness.nodeID.uuidString,
                "expectedRevision": harness.revision,
                "operationID": "op-builtin-empty"
            ])
        }
    }

    // MARK: - Freeze → propose → adopt → export/reopen

    @Test func markdownBuiltinFullLoopAdoptsIntoSameCardAndExports() async throws {
        var harness = try await makeHarness(pluginID: "markdown", text: markdownSource)
        let conversationID = UUID()
        let frozen = try await freeze(&harness, operationID: "op-md-freeze")
        let proposedPath = try writeSource(Data(proposedMarkdown.utf8), name: "proposed.md")
        let candidate = try await propose(&harness, artifactID: frozen.artifactID,
                                          operationID: "op-md-propose", path: proposedPath,
                                          summary: "updated markdown", conversationID: conversationID)
        let adoptedDesign = try await adopt(&harness, candidateID: candidate.candidateID,
                                            baseRevisionID: candidate.baseRevisionID,
                                            operationID: "op-md-adopt", conversationID: conversationID)
        // The SAME card now renders the adopted text via the original path;
        // kind/metadata/layout are preserved.
        let node = try await currentNode(harness)
        #expect(node.text == proposedMarkdown)
        #expect(node.kind == .card)
        #expect(node.metadata["builtinPlugin"] == "markdown")
        #expect(node.position == CanvasPoint(x: 30, y: 40))
        #expect(node.size == CanvasSize(width: 300, height: 200))
        #expect(node.title == "builtin-markdown")
        #expect(node.asset == nil)
        // Verified export/reopen in the recorded md format.
        let adoptedArtifacts = adoptedDesign["artifacts"] as? [[String: Any]] ?? []
        let currentRevisionID = try #require(adoptedArtifacts.first?["currentRevisionID"] as? String)
        let exportOutput = try await run(harness, tool: "canvas.designExportRevision", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "artifactID": frozen.artifactID,
            "revisionID": currentRevisionID
        ])
        let exportJSON = try json(exportOutput)
        #expect(exportJSON["verified"] as? Bool == true)
        #expect(exportJSON["format"] as? String == "md")
        #expect(exportJSON["contentSHA256"] as? String == FloeDigest.sha256Hex(Data(proposedMarkdown.utf8)))

        // 6. Restore the ORIGINAL frozen revision: the same card text goes
        //    back through the original render path; kind/metadata/layout stay.
        let restoreOutput = try await run(harness, tool: "canvas.designRestore", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "expectedRevision": harness.revision,
            "operationID": "op-md-restore",
            "artifactID": frozen.artifactID,
            "revisionID": frozen.revisionID
        ], conversationID: conversationID)
        #expect(restoreOutput.exitStatus == 0)
        let restoredNode = try await currentNode(harness)
        #expect(restoredNode.text == markdownSource)
        #expect(restoredNode.kind == .card)
        #expect(restoredNode.metadata["builtinPlugin"] == "markdown")
        #expect(restoredNode.position == CanvasPoint(x: 30, y: 40))
        #expect(restoredNode.size == CanvasSize(width: 300, height: 200))
        #expect(restoredNode.title == "builtin-markdown")
        #expect(restoredNode.asset == nil)
    }

    @Test func htmlBuiltinFullLoopAdoptsAndExports() async throws {
        var harness = try await makeHarness(pluginID: "html", text: htmlSource)
        let conversationID = UUID()
        let frozen = try await freeze(&harness, operationID: "op-html-freeze")
        let proposedPath = try writeSource(Data(proposedHTML.utf8), name: "proposed.html")
        let candidate = try await propose(&harness, artifactID: frozen.artifactID,
                                          operationID: "op-html-propose", path: proposedPath,
                                          summary: "updated html", conversationID: conversationID)
        let adoptedDesign = try await adopt(&harness, candidateID: candidate.candidateID,
                                            baseRevisionID: candidate.baseRevisionID,
                                            operationID: "op-html-adopt", conversationID: conversationID)
        let node = try await currentNode(harness)
        #expect(node.text == proposedHTML)
        #expect(node.kind == .card)
        #expect(node.metadata["builtinPlugin"] == "html")
        let adoptedArtifacts = adoptedDesign["artifacts"] as? [[String: Any]] ?? []
        let currentRevisionID = try #require(adoptedArtifacts.first?["currentRevisionID"] as? String)
        let exportOutput = try await run(harness, tool: "canvas.designExportRevision", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "artifactID": frozen.artifactID,
            "revisionID": currentRevisionID
        ])
        let exportJSON = try json(exportOutput)
        #expect(exportJSON["verified"] as? Bool == true)
        #expect(exportJSON["format"] as? String == "html")
    }

    @Test func svgBuiltinFullLoopAdoptsAndExports() async throws {
        var harness = try await makeHarness(pluginID: "svg", text: svgSource)
        let conversationID = UUID()
        let frozen = try await freeze(&harness, operationID: "op-svg-freeze")
        let proposedPath = try writeSource(Data(proposedSVG.utf8), name: "proposed.svg")
        let candidate = try await propose(&harness, artifactID: frozen.artifactID,
                                          operationID: "op-svg-propose", path: proposedPath,
                                          summary: "updated svg", conversationID: conversationID)
        let adoptedDesign = try await adopt(&harness, candidateID: candidate.candidateID,
                                            baseRevisionID: candidate.baseRevisionID,
                                            operationID: "op-svg-adopt", conversationID: conversationID)
        let node = try await currentNode(harness)
        #expect(node.text == proposedSVG)
        #expect(node.kind == .card)
        #expect(node.metadata["builtinPlugin"] == "svg")
        let adoptedArtifacts = adoptedDesign["artifacts"] as? [[String: Any]] ?? []
        let currentRevisionID = try #require(adoptedArtifacts.first?["currentRevisionID"] as? String)
        let exportOutput = try await run(harness, tool: "canvas.designExportRevision", arguments: [
            "canvasID": harness.canvasID.uuidString,
            "nodeID": harness.nodeID.uuidString,
            "artifactID": frozen.artifactID,
            "revisionID": currentRevisionID
        ])
        let exportJSON = try json(exportOutput)
        #expect(exportJSON["verified"] as? Bool == true)
        #expect(exportJSON["format"] as? String == "svg")
    }

    // MARK: - Format compatibility is enforced

    @Test func nonSVGBytesRenamedSvgAreRejectedAtPropose() async throws {
        var harness = try await makeHarness(pluginID: "svg", text: svgSource)
        let frozen = try await freeze(&harness, operationID: "op-svg-bad-freeze")
        let bogusPath = try writeSource(Data("<html>not svg</html>".utf8), name: "bogus.svg")
        await #expect(throws: (any Error).self) {
            _ = try await propose(&harness, artifactID: frozen.artifactID,
                                  operationID: "op-svg-bad-propose", path: bogusPath,
                                  summary: "spoofed svg", conversationID: UUID())
        }
    }

    @Test func markdownCardRejectsHTMLCandidate() async throws {
        var harness = try await makeHarness(pluginID: "markdown", text: markdownSource)
        let frozen = try await freeze(&harness, operationID: "op-md-conflict-freeze")
        // The notes adapter must reject .html bytes at propose (format gate),
        // so HTML can never silently become a Markdown note.
        let htmlPath = try writeSource(Data(htmlSource.utf8), name: "wrong.html")
        await #expect(throws: (any Error).self) {
            _ = try await propose(&harness, artifactID: frozen.artifactID,
                                  operationID: "op-md-conflict-propose", path: htmlPath,
                                  summary: "html into markdown", conversationID: UUID())
        }
        let node = try await currentNode(harness)
        #expect(node.text == markdownSource)
    }
}

/// Minimal in-memory Canvas repository for the built-in node fixtures.
private actor FakeBuiltinRepository: CanvasDocumentRepository {
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
}
#endif
