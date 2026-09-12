import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution SVG document")
struct SVGDocumentToolTests {
    @Test("inspect and edit SVG reopens validated output")
    func inspectAndEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("svg-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = ##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80"><rect id="card" width="120" height="80" fill="#3366ff"/><text x="10" y="40">Hello</text></svg>"##
        try Data(source.utf8).write(to: root.appendingPathComponent("source.svg"))
        let tool = SVGDocumentTool()
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())

        let inspected = try await tool.execute(.init(operation: .inspect, path: "source.svg"), context: context)
        #expect(inspected.exitStatus == 0)
        #expect(inspected.summary.contains("viewBox=0 0 120 80"))
        #expect(inspected.summary.contains("#3366ff"))

        let edited = try await tool.execute(
            .init(
                operation: .edit,
                path: "source.svg",
                outputPath: "edited.svg",
                replacements: [.init(old: "#3366ff", new: "#ff6600"), .init(old: "Hello", new: "Floe")]
            ),
            context: context
        )
        #expect(edited.exitStatus == 0)
        #expect(edited.summary.contains("status=saved"))
        let saved = try String(contentsOf: root.appendingPathComponent("edited.svg"), encoding: .utf8)
        #expect(saved.contains("#ff6600"))
        #expect(saved.contains("Floe"))
    }

    @Test("unsafe active SVG content is rejected")
    func rejectsScript() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("svg-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>"#.utf8)
            .write(to: root.appendingPathComponent("unsafe.svg"))
        let output = try await SVGDocumentTool().execute(
            .init(operation: .inspect, path: "unsafe.svg"),
            context: ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("unsafe SVG feature"))
    }
}
