import XCTest
import AVFoundation
import FloeMusicCore
@testable import FloeMusicNative

/// Deterministic, manual-rendering qualification of the arrangement recording
/// transport: a nonzero playhead start, accompaniment that obeys the shared
/// mute/solo rule, MIDI scheduling against the same output clock the session
/// records with, keep-alive past content end while recording, and owner
/// fencing. Device-mode audio latency/audibility stays with GPU-integration
/// acceptance.
@MainActor final class ArrangementTransportTests: XCTestCase {
    private final class Authority: MusicAudioAuthority {
        var acquired = 0, released = 0
        func acquirePlayback() throws { acquired += 1 }
        func releasePlayback() { released += 1 }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloeMusicArrangementTransportTests")
        let url = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(_ root: URL, name: String, frequency: Double = 220,
                        seconds: Double = 4, rate: Double = 48_000) throws -> ResolvedMusicSource {
        let url = root.appendingPathComponent(name + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        let total = Int(seconds * rate)
        var position = 0
        while position < total {
            let count = min(4_096, total - position)
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                let value = Float(0.2 * sin(2 * .pi * frequency * Double(position + i) / rate))
                for channel in 0..<2 { buffer.floatChannelData![channel][i] = value }
            }
            try file?.write(from: buffer)
            position += count
        }
        file = nil
        return .init(asset: try MusicAudioPreparation.inspect(url: url), url: url)
    }

    private func audioTrack(id: String, source: ResolvedMusicSource, offset: Int64,
                            duration: Int64, muted: Bool = false, soloed: Bool = false,
                            gain: Double = 1, pan: Double = 0) throws -> FloeMusicCore.MusicTrack {
        let clip = try MusicClip(id: MusicClipID(rawValue: id + "-clip"), name: id,
                                 trackID: MusicTrackID(rawValue: id), offset: MusicSampleTime(offset),
                                 body: .audio(try MusicAudioClipPayload(assetID: source.asset.id,
                                                                        trimStartSamples: 0, durationSamples: duration,
                                                                        gain: gain, pan: pan)))
        return try FloeMusicCore.MusicTrack(id: MusicTrackID(rawValue: id), name: id, kind: .audio, clips: [clip],
                              strip: MusicStripSettings(muted: muted, soloed: soloed))
    }

    /// One quarter = 0.5 s = 24_000 samples at 120 bpm, 960 PPQ, 48 kHz.
    private func midiTrack(id: String, notes: [(start: Int64, duration: Int64)],
                           preset: Int = 0, offset: Int64 = 0, durationTicks: Int64 = 30_720) throws -> FloeMusicCore.MusicTrack {
        let midiNotes = try notes.map {
            try MusicMIDINote(pitch: 69, startTick: MusicTick($0.start), durationTicks: $0.duration, velocity: 100)
        }
        let clip = try MusicClip(id: MusicClipID(rawValue: id + "-clip"), name: id,
                                 trackID: MusicTrackID(rawValue: id), offset: MusicSampleTime(offset),
                                 body: .midi(try MusicMIDIClipPayload(durationTicks: durationTicks, notes: midiNotes)))
        return try FloeMusicCore.MusicTrack(id: MusicTrackID(rawValue: id), name: id, kind: .midi, clips: [clip],
                              instrument: try MusicPluginState(pluginID: MusicNativeBuiltins.synth, presetIndex: preset))
    }

    private func makeTransport(_ document: MusicDocument, _ sources: [ResolvedMusicSource],
                           _ authority: Authority) throws -> MusicArrangementTransport {
        try MusicArrangementTransport(ownerToken: "proof", authority: authority,
                                      document: document, sources: sources, output: .manual)
    }

    private func render(_ transport: MusicArrangementTransport, blocks: Int, frames: AVAudioFrameCount = 1_024) throws -> [Float] {
        var result: [Float] = []
        for _ in 0..<blocks {
            let buffer = try transport.renderOffline(frames: frames, ownerToken: "proof")
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return result
    }

    private func magnitude(_ samples: [Float], frequency: Double = 440) -> Double {
        var real = 0.0, imaginary = 0.0
        for (i, value) in samples.enumerated() {
            let angle = 2 * .pi * frequency * Double(i) / 48_000
            real += Double(value) * cos(angle)
            imaginary += Double(value) * sin(angle)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count))
    }

    func testRecordingTransportAdvancesFromNonzeroStartAndSoundsInTime() async throws {
        let root = try directory()
        let a = try source(root, name: "A")
        let document = try MusicDocument(name: "Arrange", assets: [a.asset],
                                         tracks: [try audioTrack(id: "t1", source: a, offset: 0, duration: 4 * 48_000)])
        let authority = Authority()
        let transport = try makeTransport(document, [a], authority)
        try transport.start(atSample: 48_000, ownerToken: "proof") // 1 s into the clip
        let first = try transport.snapshot(ownerToken: "proof")
        XCTAssertTrue(first.running)
        XCTAssertEqual(first.positionSamples, 48_000)
        XCTAssertEqual(first.contentEndSamples, 4 * 48_000)
        let pcm = try render(transport, blocks: 8)
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), 48_000 + 8 * 1_024)
        XCTAssertGreaterThan(magnitude(pcm, frequency: 220), 0.1) // already mid-clip, in time
        try transport.stop(ownerToken: "proof")
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), 48_000 + 8 * 1_024)
        XCTAssertFalse(try transport.snapshot(ownerToken: "proof").running)
        XCTAssertEqual(authority.acquired, 0)
        XCTAssertEqual(authority.released, 0)
        try transport.close(ownerToken: "proof")
    }

    func testEmptyProjectStillAdvancesRecordingClock() async throws {
        let document = try MusicDocument(name: "Empty")
        let transport = try makeTransport(document, [], Authority())
        try transport.start(atSample: 240_000, ownerToken: "proof")
        try transport.markRecording(true, ownerToken: "proof")
        _ = try render(transport, blocks: 4)
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), 240_000 + 4 * 1_024)
        XCTAssertTrue(try transport.snapshot(ownerToken: "proof").running)
        try transport.close(ownerToken: "proof")
    }

    /// One-second segments must chain without gaps: from a 1 s start inside an
    /// 8 s clip, four seconds of PCM cross the 2 s/3 s/4 s/5 s boundaries and
    /// every block must still carry the sine (no silent run, first samples
    /// already mid-tone, absolute playhead exact).


    /// One-second segments must chain without gaps: from a 1 s start inside an
    /// 8 s clip, four seconds of PCM cross the 2 s/3 s/4 s/5 s boundaries and
    /// every block must still carry the sine (no silent run, first samples
    /// already mid-tone, absolute playhead exact).


    /// A clip later on the timeline stays silent until the shared output
    /// clock reaches its offset, then sounds without swallowing the earlier
    /// clip's content.
    func testLaterClipStartsWhenPlayheadReachesItsOffset() async throws {
        let root = try directory()
        let a = try source(root, name: "ClipA", frequency: 220, seconds: 1)
        let b = try source(root, name: "ClipB", frequency: 330, seconds: 1)
        let document = try MusicDocument(name: "Two clips", assets: [a.asset, b.asset],
                                         tracks: [try audioTrack(id: "ta", source: a, offset: 0, duration: 48_000),
                                                  try audioTrack(id: "tb", source: b, offset: 96_000, duration: 48_000)])
        let transport = try makeTransport(document, [a, b], Authority())
        try transport.start(atSample: 0, ownerToken: "proof")
        let pcm = try render(transport, blocks: 140) // ≈ 2.99 s
        XCTAssertGreaterThan(magnitude(Array(pcm[0..<48_000]), frequency: 220), 0.1)
        XCTAssertLessThan(magnitude(Array(pcm[48_000..<96_000]), frequency: 330), 0.02)
        XCTAssertGreaterThan(magnitude(Array(pcm[100_000...]), frequency: 330), 0.1)
        try transport.close(ownerToken: "proof")
    }

    func testSustainedNoteRetriggersWhenRecordingStartsMidNote() async throws {
        // Note spans absolute [24_000, 120_000); starting at 72_000 must sound.
        let track = try midiTrack(id: "midi", notes: [(start: 960, duration: 4_800)])
        let document = try MusicDocument(name: "Retrigger", tracks: [track])
        let transport = try makeTransport(document, [], Authority())
        try transport.start(atSample: 72_000, ownerToken: "proof")
        let pcm = try render(transport, blocks: 8)
        XCTAssertGreaterThan(magnitude(pcm, frequency: 440), 0.02)
        try transport.close(ownerToken: "proof")
    }

    func testKeepAliveRecordingContinuesPastContentEndThenPlainPlaybackStops() async throws {
        let root = try directory()
        let a = try source(root, name: "Short", seconds: 0.5)
        let document = try MusicDocument(name: "End", assets: [a.asset],
                                         tracks: [try audioTrack(id: "t1", source: a, offset: 0, duration: 24_000)])
        let transport = try makeTransport(document, [a], Authority())
        try transport.start(atSample: 0, ownerToken: "proof")
        try transport.markRecording(true, ownerToken: "proof")
        _ = try render(transport, blocks: 40) // 40_960 > content end 24_000
        XCTAssertTrue(try transport.snapshot(ownerToken: "proof").running)
        XCTAssertGreaterThanOrEqual(try transport.absolutePosition(ownerToken: "proof"), 40_000)
        try transport.markRecording(false, ownerToken: "proof")
        XCTAssertFalse(try transport.snapshot(ownerToken: "proof").running)
        try transport.close(ownerToken: "proof")
    }

    func testOwnerTokenIsEnforcedOnEveryEntryPoint() async throws {
        let root = try directory()
        let a = try source(root, name: "Owner", seconds: 1)
        let document = try MusicDocument(name: "Owner", assets: [a.asset],
                                         tracks: [try audioTrack(id: "t1", source: a, offset: 0, duration: 48_000)])
        let transport = try makeTransport(document, [a], Authority())
        XCTAssertThrowsError(try transport.start(atSample: 0, ownerToken: "other"))
        try transport.start(atSample: 0, ownerToken: "proof")
        XCTAssertThrowsError(try transport.absolutePosition(ownerToken: "other"))
        XCTAssertThrowsError(try transport.renderOffline(frames: 1_024, ownerToken: "other"))
        XCTAssertThrowsError(try transport.stop(ownerToken: "other"))
        XCTAssertThrowsError(try transport.close(ownerToken: "other"))
        try transport.stop(ownerToken: "proof")
        try transport.close(ownerToken: "proof")
        XCTAssertThrowsError(try transport.snapshot(ownerToken: "proof"))
    }

    func testUnsupportedRoutingIsExplicitAtCreation() async throws {
        let root = try directory()
        let a = try source(root, name: "Routed", seconds: 1)
        var track = try audioTrack(id: "t1", source: a, offset: 0, duration: 48_000)
        _ = track
        track.sends = [try MusicTrackSend(busID: MusicBus.MusicBusID(rawValue: "aux"), gain: 1)]
        let document = try MusicDocument(name: "Routed", assets: [a.asset], tracks: [track],
                                         buses: [try MusicBus(id: MusicBus.MusicBusID(rawValue: "aux"), name: "aux")])
        XCTAssertThrowsError(try makeTransport(document, [a], Authority())) { error in
            guard case MusicNativeError.unsupported = error else { return XCTFail("expected unsupported, got \(error)") }
        }
    }

    func testAccompanimentHonorsMuteAndSolo() async throws {
        let root = try directory()
        let open = try source(root, name: "Open", frequency: 220)
        let muted = try source(root, name: "Muted", frequency: 660)
        let document = try MusicDocument(name: "Mute solo", assets: [open.asset, muted.asset],
                                         tracks: [try audioTrack(id: "open", source: open, offset: 0, duration: 2 * 48_000),
                                                  try audioTrack(id: "muted", source: muted, offset: 0, duration: 2 * 48_000, muted: true)])
        let transport = try makeTransport(document, [open, muted], Authority())
        try transport.start(atSample: 0, ownerToken: "proof")
        let pcm = try render(transport, blocks: 24)
        XCTAssertGreaterThan(magnitude(pcm, frequency: 220), 0.1)
        XCTAssertLessThan(magnitude(pcm, frequency: 660), 0.02)
        try transport.close(ownerToken: "proof")

        let solo = try source(root, name: "Solo", frequency: 330)
        let soloDocument = try MusicDocument(name: "Solo", assets: [open.asset, solo.asset],
                                             tracks: [try audioTrack(id: "open", source: open, offset: 0, duration: 2 * 48_000),
                                                      try audioTrack(id: "solo", source: solo, offset: 0, duration: 2 * 48_000, soloed: true)])
        let soloTransport = try makeTransport(soloDocument, [open, solo], Authority())
        try soloTransport.start(atSample: 0, ownerToken: "proof")
        let soloPCM = try render(soloTransport, blocks: 24)
        XCTAssertGreaterThan(magnitude(soloPCM, frequency: 330), 0.1)
        XCTAssertLessThan(magnitude(soloPCM, frequency: 220), 0.02)
        try soloTransport.close(ownerToken: "proof")
    }

    func testRecordedNoteAlignmentUsesSameClockFromNonzeroStart() async throws {
        let root = try directory()
        // Note: absolute [72_000, 96_000) — i.e. relative [24_000, 48_000)
        // after a 48_000 (1 s) recording start; A4 = 440 Hz sine preset.
        let track = try midiTrack(id: "midi", notes: [(start: 2_880, duration: 960)])
        let document = try MusicDocument(name: "Notes", tracks: [track])
        let transport = try makeTransport(document, [], Authority())
        try transport.start(atSample: 48_000, ownerToken: "proof")
        try transport.markRecording(true, ownerToken: "proof")
        let pcm = try render(transport, blocks: 48) // 48_000 → 96_000
        let before = Array(pcm[0..<23_000])
        let during = Array(pcm[23_000..<48_000])
        XCTAssertEqual(rms(before), 0, accuracy: 1e-4)
        XCTAssertGreaterThan(magnitude(during, frequency: 440), 0.02)
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), 97_152) // 48 × 1_024
        try transport.close(ownerToken: "proof")
    }

    func testLongClipStaysContinuousAcrossSegmentBoundariesFromNonzeroStart() async throws {
        let root = try directory()
        let a = try source(root, name: "Long", frequency: 220, seconds: 8)
        let document = try MusicDocument(name: "Long", assets: [a.asset],
                                         tracks: [try audioTrack(id: "t1", source: a, offset: 0, duration: 8 * 48_000)])
        let transport = try makeTransport(document, [a], Authority())
        try transport.start(atSample: 48_000, ownerToken: "proof")
        let pcm = try render(transport, blocks: 192) // ≈ 4.1 s, three boundaries crossed
        XCTAssertEqual(pcm.count, 192 * 1_024)
        var zeroRun = 0, maxZeroRun = 0
        for sample in pcm {
            zeroRun = sample == 0 ? zeroRun + 1 : 0
            maxZeroRun = max(maxZeroRun, zeroRun)
        }
        XCTAssertLessThan(maxZeroRun, 16, "no gap at segment boundaries, longest silence \(maxZeroRun)")
        for block in 0..<192 {
            let peak = pcm[block * 1_024..<(block + 1) * 1_024].map { abs(Double($0)) }.max() ?? 0
            XCTAssertGreaterThan(peak, 0.05, "block \(block) carries the tone across its boundary")
        }
        XCTAssertGreaterThan(magnitude(Array(pcm.prefix(24_000)), frequency: 220), 0.1)
        XCTAssertGreaterThan(magnitude(Array(pcm.suffix(24_000)), frequency: 220), 0.1)
        // Nonzero-start alignment is sample-exact: the first rendered frames
        // carry the source file from its 1 s position, not from zero.
        let file = try AVAudioFile(forReading: a.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = 48_000
        let reference = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_048)!
        try file.read(into: reference, frameCount: 2_048)
        let expected = Array(UnsafeBufferPointer(start: reference.floatChannelData![0], count: 2_048))
        for index in 0..<2_048 {
            XCTAssertEqual(Double(pcm[index]), Double(expected[index]), accuracy: 1e-4,
                           "sample \(index) plays the file at its timeline position")
        }
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), 48_000 + 192 * 1_024)
        try transport.close(ownerToken: "proof")
    }

    func testNonzeroClipFadesRequireOfflineRendering() async throws {
        let root = try directory()
        let a = try source(root, name: "Fade", seconds: 1)
        let fades: [(Int64, Int64)] = [(240, 0), (0, 480)]
        for (fadeIn, fadeOut) in fades {
            var track = try audioTrack(id: "fade", source: a, offset: 0, duration: 48_000)
            guard case .audio(var payload) = track.clips[0].body else { return XCTFail("expected audio") }
            payload.fadeInSamples = fadeIn
            payload.fadeOutSamples = fadeOut
            track.clips[0].body = .audio(payload)
            let document = try MusicDocument(name: "Fades", assets: [a.asset], tracks: [track])
            XCTAssertThrowsError(try makeTransport(document, [a], Authority())) { error in
                guard case MusicNativeError.unsupported = error else {
                    return XCTFail("expected unsupported fade, got \(error)")
                }
            }
        }
    }

}
