import Foundation

/// Supported audio/MIDI asset kinds. `unsupportedRaw` preserves foreign or
/// future asset kinds through decode/re-encode instead of dropping them.
public enum MusicAssetKind: Sendable, Codable, Hashable {
    case audioPCM
    case audioMP3
    case audioM4A
    case midiFile
    case unsupportedRaw(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "audioPCM": self = .audioPCM
        case "audioMP3": self = .audioMP3
        case "audioM4A": self = .audioM4A
        case "midiFile": self = .midiFile
        default: self = .unsupportedRaw(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .audioPCM: try container.encode("audioPCM")
        case .audioMP3: try container.encode("audioMP3")
        case .audioM4A: try container.encode("audioM4A")
        case .midiFile: try container.encode("midiFile")
        case .unsupportedRaw(let raw): try container.encode(raw)
        }
    }
}

/// An immutable, content-addressed source asset (recorded/imported audio,
/// sample, MIDI file). The document references assets by ID; the asset record
/// pins the source locator, the content hash and the source revision so a
/// later re-import or re-render can never silently change what a committed
/// document points at.
public struct MusicAsset: Sendable, Codable, Hashable, Identifiable {
    /// Lowercase hex SHA-256, 64 characters.
    public static let contentHashLength = 64

    public var id: MusicAssetID
    /// Stable logical locator of the source in host storage (opaque to the
    /// core; the persistence adapter defines its meaning).
    public var sourceLocator: String
    /// Hash algorithm, currently only "sha256".
    public var contentHashAlgorithm: String
    public var contentHash: String
    /// Revision of the source at capture time (e.g. host file revision). A
    /// changed source must appear as a new asset ID, never a mutated record.
    public var sourceRevision: Int64
    public var kind: MusicAssetKind
    /// Duration at the project sample rate; 0 when unknown (e.g. unanalysed MIDI).
    public var durationSamples: MusicSampleTime
    /// Display name.
    public var name: String
    /// Free-form origin metadata (import, recording take, AI generation…).
    public var provenance: String

    public init(id: MusicAssetID = MusicAssetID(), sourceLocator: String,
                contentHashAlgorithm: String = "sha256", contentHash: String,
                sourceRevision: Int64 = 0, kind: MusicAssetKind,
                durationSamples: MusicSampleTime = MusicSampleTime(0),
                name: String, provenance: String = "") throws {
        guard !sourceLocator.isEmpty else {
            throw MusicError.invalidAsset(reason: "empty sourceLocator")
        }
        guard contentHashAlgorithm == "sha256" else {
            throw MusicError.invalidAsset(reason: "unsupported contentHashAlgorithm \(contentHashAlgorithm)")
        }
        guard contentHash.count == Self.contentHashLength,
              contentHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw MusicError.invalidAsset(reason: "contentHash must be 64 lowercase hex characters")
        }
        guard sourceRevision >= 0 else {
            throw MusicError.invalidAsset(reason: "negative sourceRevision")
        }
        guard durationSamples.value >= 0 else {
            throw MusicError.invalidAsset(reason: "negative durationSamples")
        }
        self.id = id
        self.sourceLocator = sourceLocator
        self.contentHashAlgorithm = contentHashAlgorithm
        self.contentHash = contentHash
        self.sourceRevision = sourceRevision
        self.kind = kind
        self.durationSamples = durationSamples
        self.name = name
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(MusicAssetID.self, forKey: .id)
        let locator = try c.decode(String.self, forKey: .sourceLocator)
        let algo = try c.decodeIfPresent(String.self, forKey: .contentHashAlgorithm) ?? "sha256"
        let hash = try c.decode(String.self, forKey: .contentHash)
        let rev = try c.decodeIfPresent(Int64.self, forKey: .sourceRevision) ?? 0
        let kind = try c.decode(MusicAssetKind.self, forKey: .kind)
        let dur = try c.decodeIfPresent(MusicSampleTime.self, forKey: .durationSamples) ?? MusicSampleTime(0)
        let name = try c.decode(String.self, forKey: .name)
        let prov = try c.decodeIfPresent(String.self, forKey: .provenance) ?? ""
        do {
            try self.init(id: id, sourceLocator: locator, contentHashAlgorithm: algo,
                          contentHash: hash, sourceRevision: rev, kind: kind,
                          durationSamples: dur, name: name, provenance: prov)
        } catch let error as MusicError {
            throw DecodingError.dataCorruptedError(forKey: .contentHash, in: c,
                                                   debugDescription: error.description)
        }
    }
}
