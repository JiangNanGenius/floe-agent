// FloeApp — Agent-facing remote image generation tool.

#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeCore
import FloeModels
import FloeProviders
import FloeTools

struct RemoteImageGenerateTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var prompt: String
        var count: Int?
        var size: String?
    }

    static let name = "image.generate"
    static let toolDescription =
        "Generate images with the image model configured in Settings. Use this for user requests to draw, create, or render an image. Returns durable image artifacts; do not substitute SVG/HTML/Python when this tool is available."
    static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "prompt": {"type": "string", "description": "Detailed description of the image to create"},
        "count": {"type": "integer", "minimum": 1, "maximum": 4, "description": "Number of images; default 1"},
        "size": {"type": "string", "description": "Optional provider-supported size such as 1024x1024"}
      },
      "required": ["prompt"],
      "additionalProperties": false
    }
    """#
    static let riskLabels: Set<RiskLabel> = [.sendsDataToProvider, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let generate: @MainActor @Sendable (String, Int, String?) async throws -> [AttachmentRef]

    init(center: FilesCenter) {
        self.generate = { prompt, count, size in
            try await center.performRemoteImage(
                operation: .generate,
                prompt: prompt,
                count: count,
                size: size
            )
        }
    }

    func validate(_ args: Arguments) throws {
        guard !args.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("prompt must not be empty")
        }
        guard (1...4).contains(args.count ?? 1) else {
            throw FloeError.validationFailed("count must be 1...4")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let attachments = try await generate(
            args.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            args.count ?? 1,
            args.size
        )
        let artifacts = attachments.compactMap { attachment -> ToolArtifactReference? in
            guard let relative = attachment.relativePath else { return nil }
            return ToolArtifactReference(
                id: attachment.id,
                relativePath: "GeneratedImages/\(relative)",
                mimeType: attachment.uti.contains("png") ? "image/png" : "image/jpeg",
                byteCount: attachment.byteCount,
                sha256: attachment.sha256
            )
        }
        let summary = attachments.map { attachment in
            "\(attachment.displayName) [attachment:\(attachment.id.uuidString)]"
        }.joined(separator: "\n")
        let summaryDigest = SHA256.hash(data: Data(summary.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(
            summary: summary.isEmpty ? "No image was returned" : summary,
            fullOutputSHA256: summaryDigest,
            exitStatus: attachments.isEmpty ? 2 : 0,
            artifacts: artifacts
        )
    }
}

func registerRemoteImageTools(center: FilesCenter, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(RemoteImageGenerateTool.self)
    registry.register(RemoteImageGenerateTool(center: center))
}
#endif
