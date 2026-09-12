import Foundation
import CoreGraphics
import ImageIO
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

    @Test("crop requires a complete normalized rectangle inside the unit square")
    func cropValidation() async {
        let tool = ImageProcessTool(rootProvider: { nil })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "a.png", operation: "crop", x: 0, y: 0))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "a.png", operation: "crop", x: 0.5, y: 0, cropWidth: 0.75, cropHeight: 1))
        }
        try! tool.validate(.init(path: "a.png", operation: "crop", x: 0.25, y: 0.25, cropWidth: 0.5, cropHeight: 0.5))
    }

    @Test("convert requires a supported target format")
    func convertValidation() async {
        let tool = ImageProcessTool(rootProvider: { nil })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "a.png", operation: "convert"))
        }
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: "a.png", operation: "convert", format: "tiff"))
        }
        try! tool.validate(.init(path: "a.png", operation: "convert", format: "png"))
        try! tool.validate(.init(path: "a.png", operation: "convert", format: "jpeg"))
        try! tool.validate(.init(path: "a.png", operation: "convert", format: "heic"))
    }

    @Test("crop and convert produce real files with expected dimensions and format")
    func cropAndConvertExecution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-image-crop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 200x100 solid-color PNG fixture.
        let context2D = CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let drawing = try #require(context2D)
        drawing.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        drawing.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let source = try #require(drawing.makeImage())
        let sourceURL = root.appendingPathComponent("source.png")
        let dest = try #require(CGImageDestinationCreateWithURL(sourceURL as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, source, nil)
        #expect(CGImageDestinationFinalize(dest))

        let tool = ImageProcessTool(rootProvider: { root })
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())

        let cropped = try await tool.execute(
            .init(path: "source.png", operation: "crop", x: 0, y: 0, cropWidth: 0.5, cropHeight: 1),
            context: context
        )
        #expect(cropped.exitStatus == 0)
        #expect(cropped.summary.contains("source-edited.png"))
        let croppedURL = root.appendingPathComponent("source-edited.png")
        let croppedImage = try #require(
            CGImageSourceCreateWithURL(croppedURL as CFURL, nil).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, nil)
            }
        )
        #expect(croppedImage.width == 100)
        #expect(croppedImage.height == 100)

        let converted = try await tool.execute(
            .init(path: "source.png", operation: "convert", format: "jpeg"),
            context: context
        )
        #expect(converted.exitStatus == 0)
        #expect(converted.summary.contains("source-edited.jpg"))
        let convertedURL = root.appendingPathComponent("source-edited.jpg")
        #expect(FileManager.default.fileExists(atPath: convertedURL.path))
        let convertedType = try #require(
            CGImageSourceCreateWithURL(convertedURL as CFURL, nil).flatMap { CGImageSourceGetType($0) } as String?
        )
        #expect(convertedType == "public.jpeg")
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
