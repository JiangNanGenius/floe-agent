import AVFoundation
import CryptoKit
import XCTest
import FloeMusicCore
@testable import FloeMusicNative

@MainActor
final class MusicPresetAudioTests: XCTestCase {
    private final class Authority: MusicAudioAuthority {
        var acquisitions = 0
        func acquirePlayback() throws { acquisitions += 1 }
        func releasePlayback() {}
    }

    private func folder() throws -> URL {
        let root = ProcessInfo.processInfo.environment["FLOE_MUSIC_PRESET_EVIDENCE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = root.appendingPathComponent("presets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func document(_ preset: Int, note: Int = 60, parameters: [String: Double] = [:]) throws -> MusicDocument {
        let trackID = MusicTrackID()
        let note = try MusicMIDINote(pitch: note, startTick: MusicTick(0), durationTicks: 1920, velocity: 110)
        let clip = try MusicClip(trackID: trackID, offset: MusicSampleTime(0),
                                 body: .midi(MusicMIDIClipPayload(durationTicks: 1920, notes: [note])))
        let track = try MusicTrack(id: trackID, name: "Synth", kind: .midi, clips: [clip],
                                   instrument: MusicPluginState(pluginID: MusicNativeBuiltins.synth,
                                                                presetIndex: preset, parameters: parameters))
        return try MusicDocument(name: "Preset \(preset)", tracks: [track])
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }

    private func zeroCrossings(_ samples: ArraySlice<Float>) -> Double {
        var count = 0
        for i in samples.indices.dropFirst() where (samples[i - 1] >= 0) != (samples[i] >= 0) { count += 1 }
        return Double(count) / Double(max(1, samples.count))
    }

    func testLegacyResolutionAndInvalidStateAreExplicit() throws {
        for index in [0, 1] {
            let patch = try MusicSynthPatch.resolve(preset: index, overrides: [:])
            XCTAssertEqual(patch.waveform, index)
            XCTAssertEqual(patch.parameters["attack"], 0.008)
            XCTAssertEqual(patch.parameters["decay"], 0.08)
            XCTAssertEqual(patch.parameters["sustain"], 0.75)
            XCTAssertEqual(patch.parameters["release"], 0.08)
            XCTAssertEqual(patch.gain, 1)
        }
        XCTAssertThrowsError(try MusicSynthPatch.resolve(preset: 999, overrides: [:]))
        let invalidParameters: [[String: Double]] = [["attack": -0.1], ["release": .infinity], ["gain": 1.01],
                                          ["waveform": 0.5], ["fmIndex": .nan], ["unknown": 1],
                                          ["fixedNote": 60.5], ["highpass": 8000, "lowpass": 1000]]
        for invalid in invalidParameters {
            XCTAssertThrowsError(try MusicSynthPatch.resolve(preset: 2, overrides: invalid))
        }
    }

    func testAllPresetsRenderAudibleFiniteDistinctAudio() async throws {
        let root = try folder()
        defer { if ProcessInfo.processInfo.environment["FLOE_MUSIC_PRESET_EVIDENCE"] == nil { try? FileManager.default.removeItem(at: root) } }
        var digests = Set<String>()
        var report: [[String: Any]] = []
        for entry in MusicPresetCatalog.all {
            let doc = try document(entry.index)
            let destination = root.appendingPathComponent(String(format: "%02d.wav", entry.index))
            let lease = try MusicRenderLease(document: doc, ownerToken: "preset-test")
            let receipt = try await MusicOfflineRenderer().render(document: doc, sources: [], destination: destination,
                                                                  lease: lease, tailFrames: 48_000)
            XCTAssertEqual(receipt.frames, 96_000)
            let pcm = try samples(destination)
            XCTAssertTrue(pcm.allSatisfy(\.isFinite), "preset \(entry.index)")
            let peak = pcm.map { abs($0) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.001, "inaudible preset \(entry.index)")
            XCTAssertLessThan(peak, 1, "clipping preset \(entry.index)")
            let power = rms(pcm[0..<48_000])
            XCTAssertGreaterThan(power, 0.0001, "silent preset \(entry.index)")
            let digest = pcm.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
            XCTAssertTrue(digests.insert(digest).inserted, "duplicate PCM for \(entry.index)")
            report.append(["index": entry.index, "name": entry.nameEN, "rms": power, "peak": peak,
                           "pcmSHA256": digest, "fileSHA256": receipt.sha256, "frames": receipt.frames])
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("AUDIO-METRICS.json"))
    }

    func testLiveConstructionAndSavedOfflineStateShareResolverAndOverrides() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let authority = Authority()
        for index in [0, 1, 2, 9, 17, 31, 40] {
            let overrides = ["attack": 0.02, "release": 0.12, "gain": 0.55]
            let patch = try MusicSynthPatch.resolve(preset: index, overrides: overrides)
            let live = try MusicLiveInstrument(ownerToken: "test", authority: authority, preset: index, parameters: overrides)
            XCTAssertEqual(live.presetIndex, index)
            XCTAssertEqual(live.resolvedParameters, patch.parameters)
            live.stop()
            let original = try document(index, parameters: overrides)
            let saved = try JSONDecoder().decode(MusicDocument.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(saved.tracks[0].instrument?.parameters, overrides)
            let destination = root.appendingPathComponent("\(index).wav")
            _ = try await MusicOfflineRenderer().render(document: saved, sources: [], destination: destination,
                                                        lease: MusicRenderLease(document: saved, ownerToken: "test"), tailFrames: 24_000)
            XCTAssertGreaterThan(rms(try samples(destination)[0..<48_000]), 0.0001)
        }
        XCTAssertEqual(authority.acquisitions, 0, "construction must not acquire audio playback")
        let silent = try document(2, parameters: ["gain": 0])
        let destination = root.appendingPathComponent("silent.wav")
        _ = try await MusicOfflineRenderer().render(document: silent, sources: [], destination: destination,
                                                    lease: MusicRenderLease(document: silent, ownerToken: "test"), tailFrames: 0)
        XCTAssertEqual(rms(try samples(destination)[...]), 0)
    }

    func testElectronicKitProducesDifferentKickSnareAndHatSpectra() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var crossing: [Int: Double] = [:]
        for pitch in [36, 38, 42] {
            let doc = try document(MusicPresetCatalog.electronicDrumKitIndex, note: pitch)
            let destination = root.appendingPathComponent("\(pitch).wav")
            _ = try await MusicOfflineRenderer().render(document: doc, sources: [], destination: destination,
                                                        lease: MusicRenderLease(document: doc, ownerToken: "kit"), tailFrames: 0)
            let pcm = try samples(destination)
            XCTAssertGreaterThan(rms(pcm[0..<4_800]), 0.0001)
            crossing[pitch] = zeroCrossings(pcm[128..<2_048])
            XCTAssertLessThan(rms(pcm[40_000..<48_000]), 0.0001, "one-shot pitch \(pitch) must decay without note off")
        }
        XCTAssertGreaterThan(crossing[38]!, crossing[36]! * 5)
        XCTAssertGreaterThan(crossing[42]!, crossing[38]! * 1.3)
    }

    func testMessagePathRetainsPolyphonyPedalReleaseAndAllOff() throws {
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let bank = try MusicSynthBank(engine: engine, format: format, parameters: ["release": 0.03])
        defer { bank.allOff(); engine.stop() }
        engine.connect(bank.mixer, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try engine.start()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        func render(_ frames: Int) throws -> [Float] {
            var result: [Float] = []
            while result.count < frames {
                let count = AVAudioFrameCount(min(512, frames - result.count))
                XCTAssertEqual(try engine.renderOffline(count, to: buffer), .success)
                let channel = try XCTUnwrap(buffer.floatChannelData?[0])
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
            return result
        }
        try bank.receive(.sustain(true), owner: "keyboard")
        for note in UInt8(48)...UInt8(59) { try bank.receive(.noteOn(note: note, velocity: 110, channel: 0), owner: "keyboard") }
        let chord = try render(4_800)
        XCTAssertGreaterThan(rms(chord[...]), 0.01)
        XCTAssertLessThan(chord.map { abs($0) }.max()!, 1)
        for note in UInt8(48)...UInt8(59) { try bank.receive(.noteOff(note: note, channel: 0), owner: "keyboard") }
        XCTAssertGreaterThan(rms(try render(4_800)[...]), 0.01, "pedal must retain released notes")
        try bank.receive(.sustain(false), owner: "keyboard")
        let release = try render(24_000)
        XCTAssertLessThan(rms(release[20_000..<24_000]), 0.0001)
        try bank.receive(.noteOn(note: 60, velocity: 100, channel: 0), owner: "keyboard")
        _ = try render(2_048)
        try bank.receive(.pitchBend(.infinity), owner: "keyboard")
        try bank.receive(.modulation(.nan), owner: "keyboard")
        try bank.receive(.allNotesOff, owner: "keyboard")
        XCTAssertEqual(rms(try render(2_048)[...]), 0)
    }

    func testInvalidationDuringRenderingCannotLeaveOutput() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let doc = try document(31)
        let lease = try MusicRenderLease(document: doc, ownerToken: "cancel")
        let destination = root.appendingPathComponent("cancelled.wav")
        do {
            _ = try await MusicOfflineRenderer().render(document: doc, sources: [], destination: destination,
                                                        lease: lease, tailFrames: 48_000,
                                                        onProgress: { if $0 >= 1_024 { lease.invalidate() } })
            XCTFail("invalidated render committed")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
