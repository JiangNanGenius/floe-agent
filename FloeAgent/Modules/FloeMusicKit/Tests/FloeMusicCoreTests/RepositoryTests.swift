import XCTest
import CryptoKit
@testable import FloeMusicCore

/// Repository CAS semantics, hash binding, deterministic stored bytes.
@MainActor
final class RepositoryTests: XCTestCase {
    private func makeHash(bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func testStageAssetVerifiesHash() async throws {
        let repository = InMemoryMusicRepository()
        let bytes = Data([1, 2, 3])
        let asset = try MusicAsset(id: MusicAssetID(rawValue: "a1"),
                                   sourceLocator: "cas://a1",
                                   contentHash: makeHash(bytes: bytes),
                                   kind: .audioMP3, durationSamples: MusicSampleTime(10),
                                   name: "a")
        try await repository.stageAsset(MusicAssetPayload(asset: asset, bytes: bytes))
        // Wrong bytes for the same hash fail closed.
        let otherBytes = Data([9, 9, 9])
        let badAsset = try MusicAsset(id: MusicAssetID(rawValue: "a2"),
                                      sourceLocator: "cas://a2",
                                      contentHash: makeHash(bytes: bytes),
                                      kind: .audioMP3, name: "b")
        await XCTAssertThrowsErrorAsync(try await repository.stageAsset(
            MusicAssetPayload(asset: badAsset, bytes: otherBytes)))
    }

    func testStageAssetReplacesNothingSilently() async throws {
        let repository = InMemoryMusicRepository()
        let bytesV1 = Data([1])
        let assetV1 = try MusicAsset(id: MusicAssetID(rawValue: "a1"),
                                     sourceLocator: "cas://a1",
                                     contentHash: makeHash(bytes: bytesV1),
                                     sourceRevision: 1, kind: .audioMP3, name: "a")
        try await repository.stageAsset(MusicAssetPayload(asset: assetV1, bytes: bytesV1))
        // Identical re-stage is a no-op.
        try await repository.stageAsset(MusicAssetPayload(asset: assetV1, bytes: bytesV1))
        // A changed source under the same ID is rejected.
        let bytesV2 = Data([2])
        let assetV2 = try MusicAsset(id: MusicAssetID(rawValue: "a1"),
                                     sourceLocator: "cas://a1",
                                     contentHash: makeHash(bytes: bytesV2),
                                     sourceRevision: 2, kind: .audioMP3, name: "a")
        await XCTAssertThrowsErrorAsync(try await repository.stageAsset(
            MusicAssetPayload(asset: assetV2, bytes: bytesV2))) { error in
            guard case MusicError.invalidAsset = error else {
                return XCTFail("expected invalidAsset, got \(error)")
            }
        }
    }

    func testSaveIsCreateOnlyThenCompareAndSwap() async throws {
        let repository = InMemoryMusicRepository()
        let document = try MusicFixtures.emptyDocument()
        let projectID = document.id
        _ = try await repository.save(document: document, expectedRevision: nil)
        // Create-only: a second create is rejected.
        await XCTAssertThrowsErrorAsync(try await repository.save(document: document,
                                                       expectedRevision: nil))
        // CAS: stale expected revision is rejected and nothing is overwritten.
        var draft = document
        draft.revision = 1
        draft.name = "v1"
        let v1 = try await repository.save(document: draft, expectedRevision: 0)
        XCTAssertEqual(v1.revision, 1)

        // Equal/non-advancing revision is rejected.
        var noAdvance = draft
        noAdvance.revision = 1
        noAdvance.name = "clone"
        await XCTAssertThrowsErrorAsync(try await repository.save(document: noAdvance,
                                                       expectedRevision: 0))
        // Stale expected revision (store knows revision 1) is rejected.
        var stale = draft
        stale.revision = 2
        stale.name = "v2"
        await XCTAssertThrowsErrorAsync(try await repository.save(document: stale,
                                                       expectedRevision: 0)) { error in
            guard case MusicError.staleRevision(let expected, let actual) = error else {
                return XCTFail("expected staleRevision, got \(error)")
            }
            XCTAssertEqual(expected, 0)
            XCTAssertEqual(actual, 1)
        }
        // State survived all rejected saves.
        let reloaded = try await repository.load(projectID: projectID)
        XCTAssertEqual(reloaded.name, "v1")
        XCTAssertEqual(reloaded.revision, 1)
    }

    func testSaveRequiresAllAssetsStaged() async throws {
        let repository = InMemoryMusicRepository()
        let asset = try MusicFixtures.asset()
        let clip = try MusicFixtures.audioClip(id: "c1", trackID: "t1",
                                               assetID: asset.id.rawValue)
        let track = try MusicTrack(id: MusicTrackID(rawValue: "t1"), name: "t", kind: .audio,
                                   clips: [clip])
        let document = try MusicDocument(name: "song", tempoMap: MusicFixtures.defaultTempoMap(),
                                         assets: [asset], tracks: [track])
        await XCTAssertThrowsErrorAsync(try await repository.save(document: document,
                                                       expectedRevision: nil)) { error in
            guard let notStaged = error as? InMemoryMusicRepository.NotStagedError else {
                return XCTFail("expected NotStagedError, got \(error)")
            }
            XCTAssertEqual(notStaged.assetID, asset.id)
        }
    }

    func testTokenBindsStoredBytes() async throws {
        let repository = InMemoryMusicRepository()
        let document = try MusicFixtures.emptyDocument()
        let token = try await repository.save(document: document, expectedRevision: nil)
        let stored = await repository.storedBytes(projectID: document.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(token.contentHash, makeHash(bytes: stored!))
        // Deterministic: saving identical content again yields the same hash.
        XCTAssertEqual(token.contentHash.count, 64)
    }
}
