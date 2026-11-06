// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Testing
import FloeManufacturingCore
import FloeMusicCore
import FloeMusicNative
@testable import FloeApp

@Suite("Native studio runtime", .serialized)
@MainActor
struct NativeStudioRuntimeTests {
    @Test func rebuiltManufacturingEngineCalculatesAndReopensItsOwnResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-manufacturing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let study = ManufacturingStudy.shaft()
        let result = try await ManufacturingService().calculate(study)
        #expect(result.inputSHA256 == (try study.fingerprint()))
        #expect(result.result.capabilities.contains("cylinder-domain-field-v1"))
        try result.result.validate(for: study)
        let archive = root.appendingPathComponent("result.floemanufacturing")
        try ManufacturingArchive.save(study: study, artifact: result, to: archive)
        let reopened = try ManufacturingArchive.open(archive)
        #expect(reopened.0.id == study.id)
        #expect(reopened.1.inputSHA256 == result.inputSHA256)
    }

    @Test func musicRepositoryAndNativeSynthProduceAudibleWAVAndMP3() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-music-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NativeMusicRepository(root: root)
        let trackID = MusicTrackID()
        let note = try MusicMIDINote(pitch: 60, startTick: .init(0), durationTicks: 480, velocity: 100)
        let clip = try MusicClip(name: "C4", trackID: trackID, offset: .init(0),
            body: .midi(.init(durationTicks: 960, notes: [note])))
        let track = try FloeMusicCore.MusicTrack(id: trackID, name: "Piano", kind: .midi, clips: [clip],
            instrument: .init(pluginID: MusicNativeBuiltins.synth))
        let document = try MusicDocument(name: "Native synth", tracks: [track])
        _ = try await repository.save(document: document, expectedRevision: nil, fence: nil)
        let reopened = try await repository.load(projectID: document.id)
        #expect(reopened.tracks.first?.clips.first?.id == clip.id)
        let lease = try MusicRenderLease(document: reopened, ownerToken: "native-runtime-test")
        let wav = root.appendingPathComponent("mix.wav")
        let receipt = try await MusicOfflineRenderer().render(document: reopened, sources: [], destination: wav, lease: lease)
        #expect(receipt.frames > 0)
        let audio = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4_096))
        try audio.read(into: buffer)
        let channels = try #require(buffer.floatChannelData)
        let energy = (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(channels[0][$1] * channels[0][$1]) }
        #expect(energy > 0.0001)
        let encoded = try await MusicMP3Exporter().encode(wav: wav, destination: root.appendingPathComponent("mix.mp3"),
            document: reopened, lease: lease)
        #expect(try encoded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > 100)
    }

    @Test func printProjectCommitsARealResultAndRejectsStaleSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-print-project-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let disk = PrintProjectDisk(root: root)
        let initial = PrintProjectDocument(projectID: id)
        try await disk.create(initial)
        let session = try await PrintProjectSession.open(id: id, directory: root)
        await session.addCube()
        #expect(session.triangleCount == 12)
        let result = try await session.sliceAndWait()
        let reopened = try await disk.load()
        #expect(reopened.projectID == id)
        #expect(reopened.resultLayerCount ?? 0 > 0)
        #expect(try await disk.resultURL(reopened) == result)
        do {
            _ = try await disk.commit(initial, expectedRevision: initial.revision)
            Issue.record("A stale writer replaced committed print settings.")
        } catch PersonalContentError.changedDocument {}
        let after = try await disk.load()
        #expect(after.resultFingerprint == reopened.resultFingerprint)
        #expect(after.meshAsset == reopened.meshAsset)
    }
}
#endif
