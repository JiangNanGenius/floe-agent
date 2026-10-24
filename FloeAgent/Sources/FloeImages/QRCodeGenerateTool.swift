// FloeImages — image.qr.generate agent tool.
//
// Generates a QR code PNG locally with Core Image. Complements
// image.barcode.scan (decode) with the missing encode direction.

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

    public static let name = "image.qr.generate"
    public static let toolDescription =
        "Generate a QR code PNG locally (Core Image, no network). content is the exact payload to encode (max 2000 bytes); size is the output edge in pixels (default 512, max 2048); correctionLevel L/M/Q/H (default M). Writes a new workspace file, publishes it as this run's stable chat output so the answer shows the image directly, and returns its path."
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
    /// Run-output artifact root used by the S3-D snapshot publisher.
    /// Production resolves the app-owned artifact store; tests inject a
    /// deterministic scratch root (same seam convention as the other
    /// publishers' optional artifact root).
    private let artifactRootProvider: @Sendable () -> URL?

    public init(
        rootProvider: @escaping @Sendable () -> URL?,
        artifactRootProvider: @escaping @Sendable () -> URL? = { try? FloeArtifactStore.root() }
    ) {
        self.rootProvider = rootProvider
        self.artifactRootProvider = artifactRootProvider
    }

    /// Stable logical output slot: this tool publishes exactly one image
    /// per call. Retries of the SAME call with the SAME bytes replay the
    /// same identity idempotently; a different output under one call/slot
    /// conflicts honestly (never a silent duplicate or overwrite).
    static let outputSlot = "image"

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
            // S3-D: measure the committed bytes at this boundary (streamed
            // digest, never a whole-file load) and publish the PNG into the
            // run's stable snapshot namespace so the existing receipt
            // transport — runtime seal → durable toolResult event → the
            // chat run-output file card — returns the image to the answer.
            let sha256 = try FloeDigest.sha256Hex(
                ofFileAt: url,
                isCancelled: { context.cancellation.isCancelled }
            )
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let bytes = values.fileSize, bytes >= 0 else {
                return Self.output(
                    "status=error error=QR output is not a regular file; the original is preserved at output=\(relativePath)",
                    exitStatus: 2
                )
            }
            let baseSummary = "status=ok output=\(relativePath) size=\(size) correctionLevel=\(level) bytes=\(bytes)"
            switch Self.runOutputBinding(context) {
            case .legacyDirect, .temporaryExempt:
                // Genuine legacy direct use and temporary (ephemeral) runs
                // keep the old workspace-only result: no durable run output
                // exists for them by policy, and none is faked.
                return Self.output(baseSummary, exitStatus: 0)
            case .partiallyBound:
                return Self.output(
                    "status=error error=run output publication requires both the tool-call and task binding; the QR image is preserved at output=\(relativePath)",
                    exitStatus: 2
                )
            case .required:
                do {
                    let published = try RunOutputSnapshotStore.publish(
                        RunOutputSnapshotRequest(
                            producerTool: Self.name,
                            slot: Self.outputSlot,
                            commit: RunOutputCommit(
                                sourceURL: url,
                                sha256: sha256,
                                byteCount: bytes,
                                displayName: url.lastPathComponent,
                                mimeType: "image/png",
                                uti: UTType.png.identifier
                            )
                        ),
                        using: context,
                        artifactRoot: artifactRootProvider()
                    )
                    return ToolExecutionOutput(
                        digesting: baseSummary + " published=\(published.displayName)",
                        exitStatus: 0,
                        outputFiles: [published]
                    )
                } catch let error as RunOutputSnapshotError {
                    // The workspace original is never deleted here; only the
                    // receipt outcome changes, and the failure is observable.
                    return Self.output(
                        "status=error error=\(Self.publicationMessage(error)); the QR image is preserved at output=\(relativePath)",
                        exitStatus: 2
                    )
                }
            }
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }

    /// S3-D binding state at the producer commit boundary — the same fixed
    /// policy the other native publishers apply (see `URLDownloadTool`):
    /// a fully bound run MUST publish or fail observably; a genuine
    /// unbound/legacy or temporary context keeps the legacy result; a
    /// partially bound context fails honestly instead of silently skipping.
    enum RunOutputBinding: Equatable {
        case required
        case legacyDirect
        case temporaryExempt
        case partiallyBound
    }

    static func runOutputBinding(_ context: ToolContext) -> RunOutputBinding {
        let hasCall = context.toolCallID?.isEmpty == false
        let hasTask = context.conversationID != nil
        if !hasCall && !hasTask { return .legacyDirect }
        if hasCall != hasTask { return .partiallyBound }
        if context.temporaryReadOnly { return .temporaryExempt }
        return .required
    }

    /// Path-free labels for typed publication failures.
    static func publicationMessage(_ error: RunOutputSnapshotError) -> String {
        switch error {
        case .bindingMissing: return "run output publication failed (unbound)"
        case .policyRefused: return "run output publication refused by policy"
        case .identityInvalid: return "run output publication failed (invalid identity)"
        case .sourceUnavailable: return "run output publication failed (source unavailable)"
        case .commitIdentityStale: return "run output publication failed (stale commit identity)"
        case .conflict(let name): return "run output publication failed (conflict: \(name))"
        case .overCap: return "run output publication failed (over cap)"
        case .snapshotAliased: return "run output publication failed (aliased snapshot)"
        case .ioFailure: return "run output publication failed (storage)"
        }
    }
}
#endif
