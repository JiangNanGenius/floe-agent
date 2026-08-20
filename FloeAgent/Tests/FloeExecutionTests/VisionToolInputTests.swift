import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution workspace vision inputs")
struct VisionToolInputTests {
    @Test("OCR accepts a workspace path without requiring model-generated base64")
    func ocrWorkspacePath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vision-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("attached.png"))

        let tool = OCRTool()
        let arguments = OCRTool.Arguments(path: "attached.png")
        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(
                runID: UUID(),
                workspaceRootURL: root,
                cancellation: CancellationToken()
            )
        )

        #expect(!output.summary.contains("No task workspace"))
        #expect(!output.summary.contains("valid base64"))
    }

    @Test("OCR rejects ambiguous inputs")
    func ocrRejectsAmbiguousInput() {
        let tool = OCRTool()
        #expect(throws: FloeError.self) {
            try tool.validate(.init(imageBase64: "aGVsbG8=", path: "attached.png"))
        }
    }
}
