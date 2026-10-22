// FloeCore — Content-scoped voice playback evidence, never diagnostic logging.

import Foundation

/// Playback is distinct from generation. Only text whose audio actually
/// finished playing belongs here; queued or merely synthesized audio does not.
/// The full answer remains in the ordinary conversation history. A bounded
/// tail supplies context after interruption without duplicating that history.
public struct VoicePlaybackReceipt: Codable, Sendable, Equatable, Hashable {
    public enum Status: String, Codable, Sendable, Hashable {
        case completed
        case interrupted
    }

    public static let payloadKey = "voicePlayback"
    public static let maximumTailCharacters = 2_000
    public let version: Int
    public let runID: UUID
    public let status: Status
    public let spokenCharacterCount: Int
    public let spokenTextTail: String

    public init(runID: UUID, status: Status, spokenText: String) {
        self.version = 1
        self.runID = runID
        self.status = status
        self.spokenCharacterCount = spokenText.count
        self.spokenTextTail = String(spokenText.suffix(Self.maximumTailCharacters))
    }

    /// Stable wrapper for an append-only run `.status` event.
    public func eventPayloadJSON() throws -> String {
        let data = try JSONEncoder().encode([Self.payloadKey: self])
        return String(decoding: data, as: UTF8.self)
    }

    public static func fromEventPayloadJSON(_ json: String) -> Self? {
        guard let decoded = try? JSONDecoder().decode(
            [String: Self].self, from: Data(json.utf8)
        )[payloadKey], decoded.version == 1,
              decoded.spokenCharacterCount >= 0,
              decoded.spokenTextTail.count <= maximumTailCharacters,
              decoded.spokenCharacterCount >= decoded.spokenTextTail.count else {
            return nil
        }
        return decoded
    }
}
