// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// An explicitly selected rebuild, including the bytes needed to accompany it.
/// This value is supplied by the host's resource/rebuild workflow, never decoded
/// from a game project. It changes no permissions, CSP or native API exposure.
/// Hash verification establishes identity; the distributor still reviews the
/// companion's completeness and original licenses before offering the runtime.
public struct GameTIC80RebuiltRuntime: Sendable {
    public let revision: String
    public let jsSHA256: String
    public let wasmSHA256: String
    public let sourceSHA256: String
    public let sourceCompanion: Data

    public init(revision: String, jsSHA256: String, wasmSHA256: String,
                sourceCompanion: Data, sourceSHA256: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-".utf8)
        guard !revision.isEmpty, revision.utf8.count <= 80,
              revision.utf8.allSatisfy({ allowed.contains($0) }) else {
            throw NarrativeAdapterError.invalidProject("rebuilt TIC-80 revision")
        }
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        guard digest(jsSHA256), digest(wasmSHA256), digest(sourceSHA256),
              !sourceCompanion.isEmpty, sourceCompanion.count <= 128 * 1024 * 1024,
              GameDigest.sha256(sourceCompanion) == sourceSHA256 else {
            throw NarrativeAdapterError.resourceChanged("rebuilt TIC-80 identity/source companion")
        }
        self.revision = revision
        self.jsSHA256 = jsSHA256
        self.wasmSHA256 = wasmSHA256
        self.sourceSHA256 = sourceSHA256
        self.sourceCompanion = sourceCompanion
    }
}
