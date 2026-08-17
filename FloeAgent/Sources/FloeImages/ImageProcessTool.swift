// FloeImages — image.process agent tool.
//
// Reads a workspace image, applies a bounded Core Image operation (resize or
// rotate), and writes the result back as a new file. The source is never
// mutated. Unsupported operations (mask/composite/watermark/… ) are not
// exposed — the local pipeline surfaces them honestly as unavailable.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

#if canImport(CoreImage)
/// Processes a workspace image with a bounded operation.
public struct ImageProcessTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var operation: String
        public var width: Int?
        public var height: Int?
        public var degrees: Double?
        public var quality: Double?
        public var outputPath: String?

        public init(
            path: String, operation: String, width: Int? = nil, height: Int? = nil,
            degrees: Double? = nil, quality: Double? = nil, outputPath: String? = nil
        ) {
            self.path = path
            self.operation = operation
            self.width = width
            self.height = height
            self.degrees = degrees
            self.quality = quality
            self.outputPath = outputPath
        }
    }

    public static let name = "image.process"
    public static let toolDescription =
        "Process a workspace image with resize or rotate (Core Image, fully local). Writes the result to a new file and returns its path. The source is never modified."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to the source image"},
        "operation": {"type": "string", "description": "\"resize\" or \"rotate\""},
        "width": {"type": "integer", "description": "Target width in pixels (resize)"},
        "height": {"type": "integer", "description": "Target height in pixels (resize)"},
        "degrees": {"type": "number", "description": "Rotation angle in degrees (rotate)"},
        "quality": {"type": "number", "description": "JPEG export quality 0..1 (default 0.85)"},
        "outputPath": {"type": "string", "description": "Workspace-relative output path; defaults to <name>-edited.<ext>"}
      },
      "required": ["path", "operation"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let rootProvider: @Sendable () -> URL?
    private let pipeline: ImagePipeline

    public init(rootProvider: @escaping @Sendable () -> URL?, pipeline: ImagePipeline = ImagePipeline()) {
        self.rootProvider = rootProvider
        self.pipeline = pipeline
    }

    public func validate(_ args: Arguments) throws {
        guard !args.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("path must not be empty")
        }
        let op = args.operation.lowercased()
        guard op == "resize" || op == "rotate" else {
            throw FloeError.validationFailed("operation must be \"resize\" or \"rotate\"")
        }
        if op == "resize" {
            guard args.width != nil || args.height != nil else {
                throw FloeError.validationFailed("resize requires width and/or height")
            }
            for dimension in [args.width, args.height].compactMap({ $0 }) {
                guard (1...16_384).contains(dimension) else {
                    throw FloeError.validationFailed("resize dimensions must be 1-16384 px")
                }
            }
        }
        if op == "rotate", args.degrees == nil {
            throw FloeError.validationFailed("rotate requires degrees")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        guard let root = context.workspaceRootURL ?? rootProvider() else {
            return Self.output("status=error error=No workspace is open", exitStatus: 2)
        }

        do {
            try context.authorizeWorkspacePath(args.path)
            let pathGuard = WorkspacePathGuard(rootURL: root)
            let sourceURL = try pathGuard.resolve(args.path)
            try pathGuard.assertReadableSize(sourceURL)
            let source = try Self.loadCGImage(from: sourceURL)
            let op = args.operation.lowercased()
            let operation: ImageOperation
            if op == "resize" {
                let width = args.width ?? max(1, Int(
                    (Double(args.height ?? source.height) * Double(source.width)
                        / Double(max(1, source.height))).rounded()
                ))
                let height = args.height ?? max(1, Int(
                    (Double(args.width ?? source.width) * Double(source.height)
                        / Double(max(1, source.width))).rounded()
                ))
                operation = .resize(width: width, height: height, preserveAspect: true)
            } else {
                operation = .rotate(degrees: args.degrees ?? 0)
            }
            let output = try pipeline.apply(operation, to: source)

            let outputRelativePath = Self.outputRelativePath(
                sourcePath: args.path, outputPath: args.outputPath
            )
            try context.authorizeWorkspacePath(outputRelativePath)
            let outputURL = try pathGuard.resolve(outputRelativePath)
            try pathGuard.assertWritable(outputURL)
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw FloeError.validationFailed("Output already exists: \(outputRelativePath)")
            }
            try Self.saveCGImage(output, to: outputURL, quality: args.quality ?? 0.85)
            return Self.output("status=ok output=\(outputRelativePath)", exitStatus: 0)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    // MARK: - File IO

    private static func loadCGImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FloeError.internalError("Could not load image: \(url.lastPathComponent)")
        }
        return image
    }

    private static func saveCGImage(_ image: CGImage, to url: URL, quality: Double) throws {
        let ext = url.pathExtension.lowercased()
        let type: UTType = ext == "png" || ext == "heic" ? .png : .jpeg
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FloeError.internalError("Could not create image destination")
        }
        let clamped = min(1, max(0, quality))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: clamped] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FloeError.internalError("Could not write image")
        }
    }

    private static func outputRelativePath(sourcePath: String, outputPath: String?) -> String {
        if let outputPath, !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputPath
        }
        let source = sourcePath as NSString
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        let base = source.deletingPathExtension
        return base + "-edited." + ext
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

/// Registers the image processing tool against the workspace root.
@discardableResult
public func registerImageTools(
    registry: ToolRunnerRegistry = .shared,
    rootProvider: @escaping @Sendable () -> URL?
) -> (@Sendable () -> URL?) {
    ToolCatalog.register(ImageProcessTool.self)
    registry.register(ImageProcessTool(rootProvider: rootProvider))
    return rootProvider
}
#endif
