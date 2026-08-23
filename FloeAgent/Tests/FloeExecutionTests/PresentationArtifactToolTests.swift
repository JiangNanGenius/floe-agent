import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution rich presentation artifacts")
struct PresentationArtifactToolTests {
    private func fixture() throws -> (PresentationArtifactTool, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-presentation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (PresentationArtifactTool(rootURLProvider: { root }), root)
    }

    @Test("advertised tool schema is valid JSON")
    func schemaIsValidJSON() throws {
        let data = try #require(PresentationArtifactTool.parametersJSON.data(using: .utf8))
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(schema["type"] as? String == "object")
        let rootProperties = try #require(schema["properties"] as? [String: Any])
        let series = try #require(rootProperties["series"] as? [String: Any])
        let seriesItems = try #require(series["items"] as? [String: Any])
        let seriesProperties = try #require(seriesItems["properties"] as? [String: Any])
        #expect(Set(seriesProperties.keys) == Set(["name", "points"]))
        #expect(seriesItems["required"] as? [String] == ["name", "points"])
        #expect(seriesItems["additionalProperties"] as? Bool == false)
    }

    @Test("native table is persisted as a digest-addressed rectangular document")
    func table() async throws {
        let (tool, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try await tool.execute(
            .init(kind: .table, title: "结果", columns: ["项目", "值"], rows: [["A", "1"], ["B", "2"]]),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let artifact = try #require(output.artifacts.first)
        #expect(artifact.mimeType == "application/vnd.floe.table+json")
        #expect(artifact.relativePath.hasPrefix("PresentationArtifacts/"))
        let data = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
        #expect(data.count == artifact.byteCount)
        let decoded = try JSONDecoder().decode(PresentationTableDocument.self, from: data)
        #expect(decoded.rows.count == 2)
    }

    @Test("chart rejects non-finite or unbounded data")
    func chartValidation() throws {
        let tool = PresentationArtifactTool(rootURLProvider: { FileManager.default.temporaryDirectory })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(
                kind: .chart,
                chartType: .line,
                series: [.init(name: "bad", points: [.init(label: "x", value: .infinity)])]
            ))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(kind: .table, columns: ["a", "b"], rows: [["only one"]]))
        }
    }

    @Test("interactive HTML receives a no-network CSP and rejects active containers")
    func webSandbox() async throws {
        let (tool, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try await tool.execute(
            .init(kind: .web, title: "交互", html: "<button onclick=\"this.textContent='ok'\">Run</button>"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let artifact = try #require(output.artifacts.first)
        let html = try String(contentsOf: root.appendingPathComponent(artifact.relativePath), encoding: .utf8)
        #expect(html.contains("connect-src 'none'"))
        #expect(html.contains("onclick"))
        #expect(throws: FloeError.self) {
            try tool.validate(.init(kind: .web, html: "<iframe src='https://example.com'></iframe>"))
        }
    }
}
