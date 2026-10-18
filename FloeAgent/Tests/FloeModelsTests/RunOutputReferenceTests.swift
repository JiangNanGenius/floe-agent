import Foundation
import Testing
import FloeModels

@Suite("FloeModels.RunOutputReference")
struct RunOutputReferenceTests {
    @Test("Legacy results do not turn evidence into deliverables")
    func legacyResultsHaveNoOutputs() throws {
        let json = Data(#"{"callID":"old","status":"ok","outputSummary":"created=report.pdf","outputDigest":"","artifacts":[{"id":"5D6B14D0-3092-44D6-9254-41C54E12E32F","relativePath":"BrowserArtifacts/evidence.png","mimeType":"image/png","byteCount":3,"sha256":"abc"}]}"#.utf8)
        let result = try JSONDecoder().decode(ToolResult.self, from: json)
        #expect(result.artifacts.count == 1)
        #expect(result.outputFiles.isEmpty)
    }

    @Test("Output metadata survives summary clipping and Codable transport")
    func outputMetadataSurvivesTransport() throws {
        let runID = UUID()
        let outputID = UUID()
        let reference = ToolArtifactReference(
            id: outputID,
            relativePath: "RunOutputs/\(runID.uuidString)/\(outputID.uuidString)/报告.xlsx",
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            byteCount: 123,
            sha256: String(repeating: "a", count: 64)
        )
        let original = ToolResult(callID: "publish", status: .ok,
                                  outputSummary: String(repeating: "文", count: 10_000),
                                  outputDigest: "digest", outputFiles: [reference])
        let result = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(original))
        #expect(result.outputSummary.count == 4096)
        #expect(result.outputFiles == [reference])
        #expect(result.artifacts.isEmpty)
        #expect(result == original)
    }
}
