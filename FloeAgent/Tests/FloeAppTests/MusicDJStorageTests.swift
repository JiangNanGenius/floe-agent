import XCTest
import Foundation
import AVFoundation
import FloeMusicCore
import FloeMusicNative
#if canImport(UIKit)
@testable import FloeApp
#else
@testable import AppMusicStorage
#endif

@MainActor final class MusicDJStorageTests: XCTestCase {
    private func setup() async throws -> (URL, NativeMusicRepository, MusicDocument, MusicDJWorkspace) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MUSIC_DJ_PROOF_OUTPUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeMusicDJStorageTests").path)
            .appendingPathComponent(UUID().uuidString)
        let repository = try NativeMusicRepository(root: root)
        let document = try MusicDocument(name: "Stored DJ original")
        _ = try await repository.save(document: document, expectedRevision: nil, fence: nil)
        let workspace = try MusicDJWorkspace(projectID: document.id, session: MusicDJSession())
        return (root, repository, document, workspace)
    }
    func testRealFileCASAcrossTwoRepositoryInstancesHasExactlyOneWinner() async throws {
        let (root, a, document, base) = try await setup()
        let b = try NativeMusicRepository(root: root)
        let one = try base.editing(document: document, expectedMusicRevision: 0, expectedDJRevision: 0) { try $0.setCrossfader(0.2) }
        let two = try base.editing(document: document, expectedMusicRevision: 0, expectedDJRevision: 0) { try $0.setCrossfader(0.8) }
        let count = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? a.saveDJWorkspace(one, expectedSHA256: nil, expectedMusicRevision: 0)) != nil }
            group.addTask { (try? b.saveDJWorkspace(two, expectedSHA256: nil, expectedMusicRevision: 0)) != nil }
            var wins = 0
            for await result in group { if result { wins += 1 } }
            return wins
        }
        XCTAssertEqual(count, 1)
        let bytes = try Data(contentsOf: root.appendingPathComponent("dj-session.json"))
        let saved = try MusicDJWorkspace.decodeSaved(bytes, projectID: document.id)
        XCTAssertEqual(saved.revision, 1); XCTAssertTrue([0.2, 0.8].contains(saved.session.crossfader))
        let original = try await a.load(projectID: document.id)
        XCTAssertEqual(original, document)
    }
    func testExactFingerprintAndMusicRevisionFenceDoNotClobberSavedSidecar() async throws {
        let (root, repository, document, base) = try await setup()
        let first = try base.editing(document: document, expectedMusicRevision: 0, expectedDJRevision: 0) { _ in }
        let hash = try repository.saveDJWorkspace(first, expectedSHA256: nil, expectedMusicRevision: 0)
        let next = try first.editing(document: document, expectedMusicRevision: 0, expectedDJRevision: 1) { try $0.setCrossfader(0) }
        XCTAssertThrowsError(try repository.saveDJWorkspace(next, expectedSHA256: hash, expectedMusicRevision: 1))
        var changed = first.session; try changed.setMasterGain(0.7)
        let external = try MusicDJWorkspace(projectID: document.id, revision: 1, session: changed)
        let bytes = try JSONEncoder().encode(external), file = root.appendingPathComponent("dj-session.json")
        try bytes.write(to: file, options: .atomic)
        XCTAssertThrowsError(try repository.saveDJWorkspace(next, expectedSHA256: hash, expectedMusicRevision: 0))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testLegacySidecarCASMigratesWithoutDiscardingCueState() async throws {
        let (root, repository, document, base) = try await setup()
        var legacy = base.session; try legacy.setCrossfader(0.25)
        let bytes = try JSONEncoder().encode(legacy), file = root.appendingPathComponent("dj-session.json")
        try bytes.write(to: file)
        let old = try MusicDJWorkspace.decodeSaved(bytes, projectID: document.id)
        let next = try old.editing(document: document, expectedMusicRevision: 0, expectedDJRevision: 0) { try $0.setMasterGain(0.9) }
        _ = try repository.saveDJWorkspace(next, expectedSHA256: MusicAudioPreparation.hashFile(file), expectedMusicRevision: 0)
        let saved = try MusicDJWorkspace.decodeSaved(Data(contentsOf: file), projectID: document.id)
        XCTAssertEqual(saved.revision, 1); XCTAssertEqual(saved.session.crossfader, 0.25); XCTAssertEqual(saved.session.masterGain, 0.9)
    }
    func testRecordedFileStagesIntoSameOriginalAndSurvivesRemovalOfOwnedDuplicate() async throws {
        let (root, repository, document, _) = try await setup()
        let recordings = root.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let source = recordings.appendingPathComponent("recorded-take.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: source, settings: format.settings)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!; pcm.frameLength = 8_192
        for i in 0..<8_192 { for c in 0..<2 { pcm.floatChannelData![c][i] = Float(0.2 * sin(Double(i) * 0.03)) } }
        try writer?.write(from: pcm); writer = nil
        let asset = try MusicAudioPreparation.inspect(url: source)
        try await repository.stageAssetFile(asset, source: source)
        let store = try await MusicProjectStore.open(projectID: document.id, repository: repository)
        let handle = await store.beginSession(ownerToken: "recording")
        let committed = try await store.commit(.init(baseRevision: 0, ops: [.insertAsset(asset)]), as: handle)
        XCTAssertEqual(committed.revision, 1); XCTAssertEqual(committed.assets, [asset])
        let canonical = try await repository.resolvedURL(for: asset)
        XCTAssertEqual(try MusicAudioPreparation.hashFile(canonical), asset.contentHash)
        try FileManager.default.removeItem(at: source)
        let reopened = try await repository.load(projectID: document.id)
        XCTAssertEqual(reopened.assets, [asset]); XCTAssertEqual(try AVAudioFile(forReading: canonical).length, 8_192)
        var collision = asset; collision.contentHash = String(repeating: "a", count: 64)
        do { try await repository.stageAssetFile(collision, source: canonical); XCTFail("wrong source hash accepted") } catch {}
        XCTAssertEqual(try MusicAudioPreparation.hashFile(canonical), asset.contentHash)
    }
    func testResetHasExactSourceCASAndRetainsEveryCorruptByte() async throws {
        let (root, repository, document, _) = try await setup()
        let broken = Data("{unfinished-DJ-original".utf8), file = root.appendingPathComponent("dj-session.json")
        try broken.write(to: file)
        let hash = try MusicAudioPreparation.hashFile(file)
        XCTAssertThrowsError(try repository.resetDJWorkspace(expectedSHA256: String(repeating: "0", count: 64),
            expectedMusicRevision: 0, projectID: document.id))
        XCTAssertEqual(try Data(contentsOf: file), broken)
        let (saved, readbackHash) = try repository.resetDJWorkspace(expectedSHA256: hash, expectedMusicRevision: 0, projectID: document.id)
        XCTAssertEqual(saved.revision, 1); XCTAssertNil(saved.session.deckA.assetID)
        XCTAssertEqual(readbackHash, try MusicAudioPreparation.hashFile(file))
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("DJBackups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), broken)
        XCTAssertEqual(try MusicDJWorkspace.decodeSaved(Data(contentsOf: file), projectID: document.id), saved)
    }

}
