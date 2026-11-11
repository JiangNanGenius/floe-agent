// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeHeavyEditorSupport

/// Converts one `project.observe` tool result into the shared verified image
/// artifact that the runtime's existing visual-evidence flow can attach to a
/// model request. Pure validation plus a content-addressed write: no WK object,
/// view or second render path lives here.
nonisolated enum GISObservationArtifact {
    /// Same retained namespace the CAD model observer uses: these renders are
    /// engineering observations of one exact document revision.
    static let namespace = "EngineeringObservations"
    /// The bundled renderer already caps observation PNGs at 288 KiB; this
    /// hard bound only fences a malfunctioning or compromised engine result.
    static let maximumRenderBytes = 4 * 1_024 * 1_024

    struct Render: Sendable {
        let reference: ToolArtifactReference
        let byteCount: Int
        let sha256: String
    }

    /// Returns nil for ordinary command results without resolving the root.
    /// When the result does carry an observation image, a stale, malformed or
    /// over-bound render throws — a claimed image is never silently dropped.
    static func makeIfPresent(result: EditorJSON, expectedRevision: UInt64, runID: UUID, root: @autoclosure () throws -> URL) throws -> Render? {
        let image = result["result"]["image"]
        guard image != .null else { return nil }
        // The render is bound to the exact revision it was produced from; a
        // stale image never becomes evidence for a newer document state.
        guard result["baseRevision"].number == Double(expectedRevision),
              result["result"]["revision"].number == Double(expectedRevision) else {
            throw HeavyEditorError.revisionConflict
        }
        guard image["mediaType"].string == "image/png",
              let base64 = image["base64"].string, !base64.isEmpty,
              let data = Data(base64Encoded: base64), !data.isEmpty,
              data.count <= maximumRenderBytes,
              ProviderImageEvidencePolicy.sniffedMIME(data) == "image/png" else {
            throw HeavyEditorError.invalidDocument
        }
        let digest = FloeDigest.sha256Hex(data)
        let relative = "\(namespace)/\(runID.uuidString)/\(digest).png"
        let reference = ToolArtifactReference(id: UUID(), relativePath: relative,
            mimeType: "image/png", byteCount: data.count, sha256: digest)
        let root = try root()
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Content-addressed: an identical render of one revision is written once.
        if (try? VerifiedToolImageArtifact.load(reference, root: root)) == nil {
            try data.write(to: url, options: .atomic)
        }
        _ = try VerifiedToolImageArtifact.load(reference, root: root)
        return Render(reference: reference, byteCount: data.count, sha256: digest)
    }

    /// Replaces the inline base64 with the verified artifact identity so the
    /// model-visible text stays bounded; the image itself travels as the
    /// artifact the runtime attaches to the next provider request.
    static func rewriting(_ body: inout [String: EditorJSON], render: Render) {
        guard case .object(var result) = body["result"], case .object(var image) = result["image"] else { return }
        image.removeValue(forKey: "base64")
        image["artifact"] = .string(render.reference.relativePath)
        image["sha256"] = .string(render.sha256)
        image["byteCount"] = .number(Double(render.byteCount))
        image["note"] = .string("The attached image is the actual map render of this exact revision, extent and layer stack. Only a vision-capable model may inspect it; the structured layers/selection fields remain the authority for edits.")
        result["image"] = .object(image)
        body["result"] = .object(result)
    }

    /// The one shared artifact root the runtime's provider delivery loads from.
    static func artifactRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("FloeAgent", isDirectory: true)
    }
}
#endif
