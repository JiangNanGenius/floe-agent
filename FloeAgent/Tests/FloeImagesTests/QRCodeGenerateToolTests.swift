import Foundation
import CoreGraphics
import ImageIO
import Testing
import FloeCore
import FloeTools
@testable import FloeImages

@Suite("FloeImages.QRCodeGenerate")
struct QRCodeGenerateToolTests {

    @Test("descriptor is mutating and file-writing")
    func descriptorContract() {
        #expect(QRCodeGenerateTool.name == "image.qrGenerate")
        #expect(QRCodeGenerateTool.isSideEffecting)
        #expect(QRCodeGenerateTool.riskLabels == [.writesFiles])
    }

    @Test("validation enforces content, size, level and safe paths")
    func validation() {
        let tool = QRCodeGenerateTool(rootProvider: { nil })
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: String(repeating: "x", count: 2_001))) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "hi", size: 4_096)) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "hi", correctionLevel: "X")) }
        #expect(throws: FloeError.self) { try tool.validate(.init(content: "hi", outputPath: "../out.png")) }
        try! tool.validate(.init(content: "https://floe.example", size: 256, correctionLevel: "h"))
    }

    @Test("generation writes a decodable PNG of the requested size")
    func generation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-qr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = QRCodeGenerateTool(rootProvider: { root })
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())

        let output = try await tool.execute(
            .init(content: "https://floe.example/qr", size: 256, outputPath: "codes/site.png"),
            context: context
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("codes/site.png"))
        let url = root.appendingPathComponent("codes/site.png")
        let image = try #require(
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, nil)
            }
        )
        #expect(image.width == 256)
        #expect(image.height == 256)

        // Existing destinations are never overwritten.
        let second = try await tool.execute(
            .init(content: "again", outputPath: "codes/site.png"),
            context: context
        )
        #expect(second.exitStatus == 2)
    }
}
