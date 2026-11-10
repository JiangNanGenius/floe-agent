// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Explicit execution route for M55 `video.voice-separate`. Both routes
/// produce the same two verified stems and use the same atomic document
/// commit; nothing here invents separation quality guarantees.
public struct AudioVoiceSeparationSelection: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// A compatible local CoreML waveform bundle already installed in the
        /// shared ModelArtifactStore (capability `audio.separate.vocals`).
        case localModel
        /// The user-configured Music.AI route for this App.
        case musicAI
    }
    public var mode: Mode
    /// Required for `.localModel`: the installed artifact ID. Ignored (and
    /// refused when supplied) for `.musicAI`.
    public var modelID: String?
    public init(mode: Mode, modelID: String? = nil) { self.mode = mode; self.modelID = modelID }
    public func validate() throws {
        guard mode == .localModel ? (modelID.map(AudioVoiceSeparationSelection.safeID) ?? true) : modelID == nil else {
            throw AudioPCMProcessingError.invalidInput("voice separation route/model selection is inconsistent")
        }
    }
    public static func safeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
    }
}
