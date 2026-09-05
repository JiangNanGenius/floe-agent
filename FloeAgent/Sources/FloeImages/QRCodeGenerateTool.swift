// FloeImages — image.qrGenerate agent tool.
//
// Generates a QR code PNG locally with Core Image. Complements
// image.scanBarcode (decode) with the missing encode direction.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

#if canImport(CoreImage)
import CoreImage
/// Generates a QR code image into the workspace.
public struct QRCodeGenerateTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var content: String
        public var size: Int?
        public var correctionLevel: String?
        public var outputPath: String?

        public init(
            content: String,
            size: Int? = nil,
            correctionLevel: String? = nil,
            outputPath: String? = nil
        ) {
            self.content = content
            self.size = size
            self.correctionLevel = correctionLevel
            self.outputPath = outputPath
        }
    }

    public static let name = "image.qrGenerate"
    public static let toolDescription =
        "Generate a QR code PNG locally (Core Image, no network). content is the exact payload to encode (max 2000 bytes); size is the output edge in pixels (default 512, max 2048); correctionLevel L/M/Q/H (default M). Writes a new workspace file and returns its path."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "content": {"type": "string", "description": "Payload to encode (URL, text, Wi-Fi string, ...), max 2000 bytes"},
        "size": {"type": "integer", "description": "Output edge in pixels (default 512, max 2048)"},
        "correctionLevel": {"type": "string", "enum": ["L", "M", "Q", "H"], "description": "Error correction level (default M)"},
        "outputPath": {"type": "string", "description": "Workspace-relative PNG path; defaults to QRCode/qr-<id>.png"}
      },
      "required": ["content"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    private let rootProvider: @Sendable () -> URL?

    public init(rootProvider: @escaping @Sendable () -> URL?) {
        self.rootProvider = rootProvider
    }

    public func validate(_ args: Arguments) throws {
        guard !args.content.isEmpty, args.content.utf8.count <= 2_000 else {
            throw FloeError.validationFailed("content must be 1-2000 bytes")
        }
        if let size = args.size, !(16...2_048).contains(size) {
            throw FloeError.validationFailed("size must be 16-2048 px")
        }
        if let level = args.correctionLevel, !["L", "M", "Q", "H"].contains(level.uppercased()) {
            throw FloeError.validationFailed("correctionLevel must be L, M, Q or H")
        }
        if let outputPath = args.outputPath {
            let path = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !path.split(separator: "/").contains("..") else {
                throw FloeError.validationFailed("outputPath must be workspace-relative")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let root = context.workspaceRootURL ?? rootProvider() else {
            return Self.output("status=error error=No workspace is open", exitStatus: 2)
        }
        do {
            let size = args.size ?? 512
            let level = (args.correctionLevel ?? "M").uppercased()
            guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
                throw FloeError.internalError("QR generator is unavailable")
            }
            filter.setValue(Data(args.content.utf8), forKey: "inputMessage")
            filter.setValue(level, forKey: "inputCorrectionLevel")
            guard let ciImage = filter.outputImage else {
                throw FloeError.internalError("QR code could not be generated")
            }
            let scale = CGFloat(size) / ciImage.extent.width
            let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let ciContext = CIContext()
            guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else {
                throw FloeError.internalError("QR code could not be rendered")
            }
            let relativePath: String
            if let outputPath = args.outputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !outputPath.isEmpty {
                relativePath = outputPath
            } else {
                relativePath = "QRCode/qr-\(UUID().uuidString).png"
            }
            try context.authorizeWorkspacePath(relativePath)
            let guarder = WorkspacePathGuard(rootURL: root)
            let url = try guarder.resolve(relativePath)
            try guarder.assertWritable(url)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw FloeError.validationFailed("Output already exists: \(relativePath)")
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw FloeError.internalError("Could not create image destination")
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw FloeError.internalError("Could not write QR image")
            }
            let bytes = (try? Data(contentsOf: url).count) ?? 0
            return Self.output(
                "status=ok output=\(relativePath) size=\(size) correctionLevel=\(level) bytes=\(bytes)",
                exitStatus: 0
            )
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}
#endif
