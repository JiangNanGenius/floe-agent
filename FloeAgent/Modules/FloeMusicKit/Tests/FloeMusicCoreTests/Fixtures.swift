import Foundation
import CryptoKit
@testable import FloeMusicCore

enum MusicFixtures {
    /// Hash of deterministic model-fixture bytes. These bytes model an asset
    /// identity; they are not a playable MP3 and are never used in audio tests.
    static func hexHash(_ seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func asset(id: String = "asset-1", name: String = "take-1",
                      kind: MusicAssetKind = .audioMP3,
                      durationSamples: Int64 = 4_000_000,
                      hash: String? = nil) throws -> MusicAsset {
        try MusicAsset(id: MusicAssetID(rawValue: id),
                       sourceLocator: "cas://music/\(id)",
                       contentHash: hash ?? hexHash(id),
                       kind: kind, durationSamples: MusicSampleTime(durationSamples),
                       name: name, provenance: "fixture")
    }

    static func defaultTempoMap() throws -> MusicTempoMap {
        try MusicTempoMap(ticksPerQuarter: 960, sampleRate: 48_000,
                          segments: [try MusicTempoSegment(startTick: MusicTick(0), bpm: 120,
                                                           beatsPerBar: 4, beatUnit: 4)])
    }

    static func emptyDocument(name: String = "song") throws -> MusicDocument {
        try MusicDocument(id: MusicProjectID(rawValue: "project-1"), name: name,
                          tempoMap: defaultTempoMap())
    }

    static func audioClip(id: String, trackID: String, assetID: String,
                          offset: Int64 = 0, duration: Int64 = 100_000,
                          fadeIn: Int64 = 0, fadeOut: Int64 = 0) throws -> MusicClip {
        try MusicClip(id: MusicClipID(rawValue: id), name: id,
                      trackID: MusicTrackID(rawValue: trackID),
                      offset: MusicSampleTime(offset),
                      body: .audio(try MusicAudioClipPayload(
                        assetID: MusicAssetID(rawValue: assetID),
                        trimStartSamples: 0, durationSamples: duration,
                        fadeInSamples: fadeIn, fadeOutSamples: fadeOut)))
    }

    static func midiNote(pitch: Int = 60, start: Int64 = 0, duration: Int64 = 480,
                         velocity: Int = 100) throws -> MusicMIDINote {
        try MusicMIDINote(pitch: pitch, startTick: MusicTick(start),
                          durationTicks: duration, velocity: velocity)
    }

    static func midiClip(id: String, trackID: String, offset: Int64 = 0,
                         durationTicks: Int64 = 1_920,
                         notes: [MusicMIDINote]) throws -> MusicClip {
        try MusicClip(id: MusicClipID(rawValue: id), name: id,
                      trackID: MusicTrackID(rawValue: trackID),
                      offset: MusicSampleTime(offset),
                      body: .midi(try MusicMIDIClipPayload(durationTicks: durationTicks,
                                                           notes: notes)))
    }
}

/// Materializes deterministic fixture blobs before exercising the real strict
/// repository. Model/transaction tests need valid staged hashes; audio tests
/// use actual encoded media and a separate file adapter.
actor FixtureMusicRepository: MusicRepository {
    private let base = InMemoryMusicRepository()
    func stageAsset(_ payload: MusicAssetPayload) async throws { try await base.stageAsset(payload) }
    func save(document: MusicDocument, expectedRevision: Int64?, fence: MusicCommitFence?) async throws -> MusicRevisionToken {
        for asset in document.assets {
            try await base.stageAsset(MusicAssetPayload(asset: asset, bytes: Data(asset.id.rawValue.utf8)))
        }
        return try await base.save(document: document, expectedRevision: expectedRevision, fence: fence)
    }
    func load(projectID: MusicProjectID) async throws -> MusicDocument { try await base.load(projectID: projectID) }
    func assetPayload(assetID: MusicAssetID) async throws -> MusicAssetPayload? { try await base.assetPayload(assetID: assetID) }
}
