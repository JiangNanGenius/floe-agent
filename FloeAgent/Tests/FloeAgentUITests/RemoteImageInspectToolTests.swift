import Foundation
import CryptoKit
import Testing
import UIKit
import FloeCore
import FloeTools
@testable import FloeApp

@Suite("AI visual inspection tool")
@MainActor
struct RemoteImageInspectToolTests {
    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    @Test("Workspace images receive semantic AI inspection")
    func workspaceImageInspection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try tinyPNG.write(to: root.appendingPathComponent("diagram.png"))

        let tool = RemoteImageInspectTool { _, mimeType, prompt in
            #expect(mimeType == "image/jpeg")
            #expect(prompt.contains("Explain the arrows"))
            return .success("The diagram contains two connected boxes and a directional arrow.")
        }
        let output = try await tool.execute(
            .init(path: "diagram.png", question: "Explain the arrows"),
            context: .init(
                runID: UUID(),
                workspaceRootURL: root,
                cancellation: CancellationToken()
            )
        )

        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("two connected boxes"))
        #expect(output.summary.contains("untrusted evidence"))
    }

    @Test("Browser screenshots require and verify the producing digest")
    func browserArtifactDigest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("BrowserArtifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try tinyPNG.write(to: directory.appendingPathComponent("viewport.png"))
        let digest = SHA256.hash(data: tinyPNG).map { String(format: "%02x", $0) }.joined()

        let tool = RemoteImageInspectTool(
            inspect: { _, _, _ in .success("A browser page showing a disabled Submit button.") },
            artifactRootProvider: { root }
        )
        #expect(throws: FloeError.self) {
            try tool.validate(.init(
                path: "BrowserArtifacts/viewport.png",
                question: "What blocks submission?"
            ))
        }

        let output = try await tool.execute(
            .init(
                path: "BrowserArtifacts/viewport.png",
                question: "What blocks submission?",
                sha256: digest
            ),
            context: .init(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.summary.contains("disabled Submit button"))
    }

    @Test("GeneratedImages inside the task workspace are not confused with app artifacts")
    func workspaceGeneratedImage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("GeneratedImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try tinyPNG.write(to: directory.appendingPathComponent("result.png"))

        let tool = RemoteImageInspectTool { _, _, _ in
            .success("A generated landscape with a lake and mountains.")
        }
        let output = try await tool.execute(
            .init(path: "GeneratedImages/result.png", question: "Describe the scene"),
            context: .init(
                runID: UUID(),
                workspaceRootURL: root,
                cancellation: CancellationToken()
            )
        )
        #expect(output.summary.contains("lake and mountains"))
    }

    @Test("Retained CAD views and animation frames can reach the configured vision helper",
          arguments: ["CADViewportArtifacts", "CADAnimationFrames", "EngineeringObservations"])
    func cadArtifactInspection(namespace: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let relative = "\(namespace)/\(UUID().uuidString)/view.png"
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try tinyPNG.write(to: target)
        let digest = FloeDigest.sha256Hex(tinyPNG)
        var inspections = 0
        let tool = RemoteImageInspectTool(inspect: { base64, mime, prompt in
            inspections += 1
            #expect(mime == "image/jpeg")
            #expect(Data(base64Encoded: base64)?.isEmpty == false)
            #expect(prompt.contains(relative))
            return .success("The captured bracket has two visible holes.")
        }, artifactRootProvider: { root })
        let args = RemoteImageInspectTool.Arguments(
            path: relative, question: "Count the visible holes", sha256: digest)
        try tool.validate(args)
        let output = try await tool.execute(args,
            context: .init(runID: UUID(), cancellation: CancellationToken()))
        #expect(inspections == 1)
        #expect(output.summary.contains("two visible holes"))
        #expect(output.capturedOutput == output.summary)
        #expect(try Data(contentsOf: target) == tinyPNG)
    }

    @Test("CAD artifact proof and containment failures never invoke the vision helper")
    func cadArtifactIdentityFailures() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let directory = root.appendingPathComponent("CADAnimationFrames/run")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try tinyPNG.write(to: directory.appendingPathComponent("frame.png"))
        try tinyPNG.write(to: outside.appendingPathComponent("outside.png"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.png"),
                                                   withDestinationURL: outside.appendingPathComponent("outside.png"))
        var inspections = 0
        let tool = RemoteImageInspectTool(inspect: { _, _, _ in
            inspections += 1
            return .success("Must not be called")
        }, artifactRootProvider: { root })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "CADAnimationFrames/run/frame.png", question: "Inspect"))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "CADAnimationFrames/run/../frame.png", question: "Inspect",
                                   sha256: FloeDigest.sha256Hex(tinyPNG)))
        }
        for (path, digest) in [
            ("CADAnimationFrames/run/frame.png", String(repeating: "0", count: 64)),
            ("CADAnimationFrames/run/escape.png", FloeDigest.sha256Hex(tinyPNG))
        ] {
            await #expect(throws: FloeError.self) {
                try await tool.execute(.init(path: path, question: "Inspect", sha256: digest),
                    context: .init(runID: UUID(), cancellation: CancellationToken()))
            }
        }
        #expect(inspections == 0)
    }

    @Test("A long inspection remains complete and available to result paging")
    func completeInspectionResult() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try tinyPNG.write(to: root.appendingPathComponent("diagram.png"))
        let description = String(repeating: "可见孔位与边缘。", count: 800) + "INSPECTION_TAIL_379"
        let tool = RemoteImageInspectTool { _, _, _ in .success(description) }
        let output = try await tool.execute(.init(path: "diagram.png", question: "Describe all visible details"),
            context: .init(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken()))
        #expect(output.summaryTruncated)
        #expect(!output.summary.contains("INSPECTION_TAIL_379"))
        let complete = try #require(output.capturedOutput)
        #expect(complete.contains(description))
        #expect(complete.hasSuffix("INSPECTION_TAIL_379"))
        #expect(!output.capturedOutputTruncated)
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(complete.utf8)))
    }

    @Test("PDF pages are rendered before AI inspection")
    func pdfPageInspection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            "Page one".draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
            context.beginPage()
            "Page two chart".draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
        try data.write(to: root.appendingPathComponent("report.pdf"))

        let tool = RemoteImageInspectTool { _, mimeType, prompt in
            #expect(mimeType == "image/jpeg")
            #expect(prompt.contains("report.pdf page 2/2"))
            return .success("Page two contains a chart with an upward trend.")
        }
        let output = try await tool.execute(
            .init(path: "report.pdf", question: "Summarize the chart", page: 2),
            context: .init(
                runID: UUID(),
                workspaceRootURL: root,
                cancellation: CancellationToken()
            )
        )
        #expect(output.summary.contains("page 2/2"))
        #expect(output.summary.contains("upward trend"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-inspect-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
