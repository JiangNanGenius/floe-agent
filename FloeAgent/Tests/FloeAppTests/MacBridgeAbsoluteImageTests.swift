#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloeTools
import FloeWorkspace
@testable import FloeApp

private actor ImageByteReader: MacAbsoluteFileReading {
    enum Mode: Sendable {
        case bytes(Data)
        case unavailable
    }

    nonisolated var maximumChunkBytes: Int { 1_024 * 1_024 }
    private let mode: Mode
    private(set) var paths: [String] = []

    init(_ mode: Mode) { self.mode = mode }

    func readMacAbsoluteFileChunk(
        path: String, offset: Int, limit: Int, expectedIdentity: String?,
        verifySHA256: Bool, context: ToolContext
    ) async throws -> MacAbsoluteFileChunk? {
        paths.append(path)
        switch mode {
        case .unavailable:
            return nil
        case .bytes(let data):
            let identity = String(repeating: "e", count: 64)
            if verifySHA256 {
                return MacAbsoluteFileChunk(data: Data(), byteOffset: data.count,
                    totalBytes: data.count, identity: identity,
                    sha256: FloeDigest.sha256Hex(data))
            }
            let start = min(max(0, offset), data.count)
            let end = min(start + limit, data.count)
            return MacAbsoluteFileChunk(data: data.subdata(in: start..<end),
                byteOffset: end, totalBytes: data.count, identity: identity)
        }
    }
}

@MainActor
private final class InspectRecorder {
    struct Call {
        let base64: String
        let mimeType: String
        let prompt: String
    }
    var calls: [Call] = []
}

@MainActor
@Suite("Absolute Mac image read through image.view and image.inspect")
struct MacBridgeAbsoluteImageTests {
    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-image-abs-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func context(root: URL, allowed: [String] = [], temporary: Bool = false) -> ToolContext {
        ToolContext(runID: UUID(), workspaceRootURL: root,
            allowedWorkspacePaths: allowed, cancellation: CancellationToken(),
            environmentID: "mac-env", temporaryReadOnly: temporary)
    }

    private func png(width: Int = 40, height: Int = 20) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
            .pngData { renderer in
                UIColor.systemRed.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: width, height: height))
                UIColor.systemBlue.setFill()
                renderer.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
            }
    }

    private func pdf(pages: Int = 2) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 220, height: 120)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            for page in 1...pages {
                renderer.beginPage()
                ("PDF page \(page) 图片" as NSString).draw(
                    at: CGPoint(x: 12, y: 12),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
            }
        }
    }

    @Test("image.view returns a verified artifact from an absolute cross-workspace path")
    func imageViewAbsolutePath() async throws {
        let workspace = try makeRoot("workspace")
        let artifacts = try makeRoot("artifacts")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let bytes = png()
        let reader = ImageByteReader(.bytes(bytes))
        let tool = LocalImageViewTool(
            artifactRootProvider: { artifacts }, macAbsoluteReader: reader)
        let path = "/Users/fixture/Pictures/跨 工作区/截图 1.png"

        let output = try await tool.execute(.init(path: path), context: context(root: workspace))

        let artifact = try #require(output.artifacts.first)
        #expect(artifact.mimeType == "image/png")
        let verified = try VerifiedToolImageArtifact.load(artifact, root: artifacts)
        #expect(verified.data.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
        let receipt = try #require(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        #expect(receipt["source"] as? String == path)
        #expect(receipt["mimeType"] as? String == "image/png")
        let pixels = try #require(receipt["sourcePixels"] as? [String: Any])
        #expect(pixels["width"] as? Int == 40)
        #expect(pixels["height"] as? Int == 20)
        let paths = await reader.paths
        #expect(paths.contains(path))
    }

    @Test("image.inspect sends actual absolute image bytes to the vision route")
    func imageInspectAbsoluteImage() async throws {
        let workspace = try makeRoot("inspect")
        let artifacts = try makeRoot("inspect-artifacts")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let recorder = InspectRecorder()
        let reader = ImageByteReader(.bytes(png()))
        let tool = RemoteImageInspectTool(
            inspect: { base64, mimeType, prompt in
                recorder.calls.append(.init(base64: base64, mimeType: mimeType, prompt: prompt))
                return .success("A blue and red rectangle.")
            },
            artifactRootProvider: { artifacts },
            macAbsoluteReader: reader)
        let path = "/Users/fixture/Desktop/图表 最终.png"

        let output = try await tool.execute(
            .init(path: path, question: "What colors are visible?"),
            context: context(root: workspace))

        #expect(output.summary.contains("AI visual inspection of \(path)"))
        #expect(output.summary.contains("A blue and red rectangle."))
        let call = try #require(recorder.calls.first)
        #expect(call.mimeType == "image/jpeg")
        #expect(Data(base64Encoded: call.base64)?.starts(with: Data([0xFF, 0xD8])) == true)
        #expect(call.prompt.contains("What colors are visible?"))
        #expect(call.prompt.contains("Source: \(path)"))
    }

    @Test("image.inspect renders a chosen page from an absolute PDF")
    func imageInspectAbsolutePDFPage() async throws {
        let workspace = try makeRoot("pdf")
        let artifacts = try makeRoot("pdf-artifacts")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let recorder = InspectRecorder()
        let reader = ImageByteReader(.bytes(pdf(pages: 2)))
        let tool = RemoteImageInspectTool(
            inspect: { base64, mimeType, prompt in
                recorder.calls.append(.init(base64: base64, mimeType: mimeType, prompt: prompt))
                return .success("Page two contains a heading.")
            },
            artifactRootProvider: { artifacts },
            macAbsoluteReader: reader)
        let path = "/Users/fixture/Documents/报告 最终.pdf"

        let output = try await tool.execute(
            .init(path: path, question: "What is on this page?", page: 2),
            context: context(root: workspace))

        #expect(output.summary.contains("AI visual inspection of \(path) page 2/2"))
        let call = try #require(recorder.calls.first)
        #expect(call.mimeType == "image/jpeg")
        #expect(call.prompt.contains("page 2/2"))
    }

    @Test("An unavailable Mac target is an explicit error, not a workspace fallback")
    func unavailableTargetFailsClosed() async throws {
        let workspace = try makeRoot("unavailable")
        let artifacts = try makeRoot("unavailable-artifacts")
        defer {
            try? FileManager.default.removeItem(at: workspace)
            try? FileManager.default.removeItem(at: artifacts)
        }
        let reader = ImageByteReader(.unavailable)
        let tool = LocalImageViewTool(
            artifactRootProvider: { artifacts }, macAbsoluteReader: reader)
        let path = "/Users/fixture/Pictures/outside.png"

        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(.init(path: path), context: context(root: workspace))
        }
        let paths = await reader.paths
        #expect(paths == [path])
    }

    @Test("Relative-only construction keeps rejecting absolute image paths")
    func relativeOnlyToolRejectsAbsolutePath() throws {
        let tool = RemoteImageInspectTool(
            inspect: { _, _, _ in .success("unused") },
            macAbsoluteReader: nil)
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "/Users/fixture/Pictures/outside.png", question: "x"))
        }
        #expect(throws: FloeError.self) {
            try LocalImageViewTool(macAbsoluteReader: nil)
                .validate(.init(path: "/Users/fixture/Pictures/outside.png"))
        }
    }

    @Test("Scoped and temporary contexts deny absolute image reads before transport")
    func imageAuthorityCeilings() async throws {
        let workspace = try makeRoot("image-scope")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let reader = ImageByteReader(.bytes(png()))
        let tool = LocalImageViewTool(macAbsoluteReader: reader)
        let path = "/Users/fixture/Pictures/outside.png"

        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(.init(path: path),
                context: context(root: workspace, allowed: ["output"]))
        }
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(.init(path: path),
                context: context(root: workspace, temporary: true))
        }
        let paths = await reader.paths
        #expect(paths.isEmpty)
    }
}
#endif
