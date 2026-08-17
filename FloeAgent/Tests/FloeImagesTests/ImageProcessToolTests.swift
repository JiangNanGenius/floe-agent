import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeImages

@Suite("FloeImages.ImageProcess")
struct ImageProcessToolTests {

    @Test("descriptor is mutating and file-touching")
    func descriptorContract() {
        #expect(ImageProcessTool.name == "image.process")
        #expect(ImageProcessTool.isSideEffecting)
        #expect(ImageProcessTool.riskLabels == [.readsFiles, .writesFiles])
    }

    @Test("resize without dimensions is rejected")
    func resizeValidation() async {
        let tool = ImageProcessTool(rootProvider: { nil })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "a.png", operation: "resize"))
        }
    }

    @Test("rotate without degrees is rejected")
    func rotateValidation() async {
        let tool = ImageProcessTool(rootProvider: { nil })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "a.png", operation: "rotate"))
        }
    }

    @Test("unknown operation is rejected")
    func unknownOperation() async {
        let tool = ImageProcessTool(rootProvider: { nil })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "a.png", operation: "watermark"))
        }
    }

    @Test("image paths cannot escape the workspace or task ceiling")
    func workspaceBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-image-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ImageProcessTool(rootProvider: { root })
        let context = ToolContext(
            runID: UUID(),
            workspaceRootURL: root,
            allowedWorkspacePaths: ["images"],
            cancellation: CancellationToken()
        )

        let traversal = try await tool.execute(
            .init(path: "../outside.png", operation: "rotate", degrees: 90),
            context: context
        )
        #expect(traversal.exitStatus == 2)

        let outOfScope = try await tool.execute(
            .init(path: "outside.png", operation: "rotate", degrees: 90),
            context: context
        )
        #expect(outOfScope.exitStatus == 2)
    }
}
