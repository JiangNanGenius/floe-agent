// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD

/// Result metadata for the bundled, on-device path tracer. No shell payloads.
nonisolated enum CADOfflineRenderCommands {
    // Kept only so older saved PBRT receipts remain readable.
    static let revision = CADPBRTSceneExporter.backendRevision
    static func receipt(sceneSHA256: String, imageSHA256: String, samples: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["backend": CADNativeSceneExporter.backendID,
            "revision": CADNativeSceneExporter.backendRevision, "sceneSHA256": sceneSHA256,
            "imageSHA256": imageSHA256, "samples": samples], options: .sortedKeys)
    }
}
