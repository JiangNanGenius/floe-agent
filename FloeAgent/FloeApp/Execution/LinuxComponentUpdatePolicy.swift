// FloeApp — Linux component update-needed state.
//
// Phase 2 coordinator requirement: when the installed guest image's runner
// predates the protocol this build expects, the app must surface an explicit
// "component update needed" state — never a silent retry loop against an old
// runner that answers with busy/125 rejections.
//
// The runner version lives in the image manifest (`runner.protocol` /
// `runner.version`), written by the engine's runner-update pipeline. This
// reader decodes those keys tolerantly: an absent field means the image
// predates versioning, which is an update-needed state only when the manifest
// also fails the current qualification record (the engine's verifier already
// owns that), so no false positives appear for the current pinned image.

import Foundation
import FloeCore

enum LinuxComponentUpdatePolicy {
    /// Minimum runner protocol this build's host channel uses. Bump together
    /// with the engine's protocol version when a host feature requires it.
    static let minimumRunnerProtocol = 2

    /// Tolerant view of the optional runner metadata in a manifest JSON.
    private struct RunnerMetadata: Decodable {
        struct Runner: Decodable {
            var version: String?
            var protocolVersion: Int?

            enum CodingKeys: String, CodingKey {
                case version
                case protocolVersion = "protocol"
            }
        }
        var runner: Runner?
    }

    /// nil when no update is required; otherwise the honest user-facing reason.
    static func updateNeededReason(manifestData: Data?) -> String? {
        guard let manifestData else { return nil }
        guard let metadata = try? JSONDecoder().decode(RunnerMetadata.self, from: manifestData) else {
            return nil
        }
        guard let runner = metadata.runner else { return nil }
        if let proto = runner.protocolVersion, proto < minimumRunnerProtocol {
            return String(localized: "environment.backend.update_needed")
        }
        return nil
    }
}
