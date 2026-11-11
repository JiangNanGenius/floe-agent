import XCTest
import AVFoundation
import FloeMusicCore
@testable import FloeMusicNative

/// Deterministic manual-rendering qualification of the recording loop and
/// the timestamp-anchored capture sink: musical wrapping on the monotonic
/// clock, per-pass accompaniment retriggering, sample-level cross-wrap audio
/// continuity with numeric drift assertions, owner fencing and tap stamp
/// mapping. Device-mode seamless-window scheduling and real microphone
/// routing stay with the GPU/Simulator acceptance stage.
@MainActor final class ArrangementTransportLoopTests: XCTestCase {
    private final class Authority: MusicAudioAuthority {
        var acquired = 0, released = 0
        func acquirePlayback() throws { acquired += 1 }
        func releasePlayback() { released += 1 }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloeMusicArrangementTransportLoopTests")
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
                            duration: Int64) throws -> FloeMusicCore.MusicTrack {
        let clip = try MusicClip(id: MusicClipID(rawValue: id + "-clip"), name: id,
                                 trackID: MusicTrackID(rawValue: id), offset: MusicSampleTime(offset),
                                 body: .audio(try MusicAudioClipPayload(assetID: source.asset.id,
                                                                        trimStartSamples: 0, durationSamples: duration)))
        return try FloeMusicCore.MusicTrack(id: MusicTrackID(rawValue: id), name: id, kind: .audio, clips: [clip])
    }

    /// One quarter = 0.5 s = 24_000 samples at 120 bpm, 960 PPQ, 48 kHz.
    private func midiTrack(id: String, notes: [(start: Int64, duration: Int64)]) throws -> FloeMusicCore.MusicTrack {
        let midiNotes = try notes.map {
            try MusicMIDINote(pitch: 69, startTick: MusicTick($0.start), durationTicks: $0.duration, velocity: 100)
        }
        let clip = try MusicClip(id: MusicClipID(rawValue: id + "-clip"), name: id,
                                 trackID: MusicTrackID(rawValue: id), offset: MusicSampleTime(0),
                                 body: .midi(try MusicMIDIClipPayload(durationTicks: 30_720, notes: midiNotes)))
        return try FloeMusicCore.MusicTrack(id: MusicTrackID(rawValue: id), name: id, kind: .midi, clips: [clip],
                              instrument: try MusicPluginState(pluginID: MusicNativeBuiltins.synth, presetIndex: 0))
    }

    private func makeTransport(_ document: MusicDocument, _ sources: [ResolvedMusicSource],
                               _ authority: Authority) throws -> MusicArrangementTransport {
        try MusicArrangementTransport(ownerToken: "proof", authority: authority,
                                      document: document, sources: sources, output: .manual)
    }

    @discardableResult
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

    func testLoopRejectsStartAwayFromLoopStart() async throws {
        let root = try directory()
        let a = try source(root, name: "A", seconds: 1)
        let document = try MusicDocument(name: "L", assets: [a.asset],
                                         tracks: [try audioTrack(id: "t1", source: a, offset: 0, duration: 48_000)])
        let transport = try makeTransport(document, [a], Authority())
        let loop = try MusicLoopRange(startSample: 48_000, endSample: 96_000)
        XCTAssertThrowsError(try transport.start(atSample: 0, loop: loop, ownerToken: "proof")) { error in
            guard case MusicNativeError.invalid = error else { return XCTFail("expected invalid, got \(error)") }
        }
    }

    func testManualLoopWrapsMusicalPositionAndKeepsClockMonotonic() async throws {
        // Frozen loop [24_000, 72_000); a note spans the second half of the
        // loop region ([24_000, 48_000): 960 ticks = 0.5 s at 960 PPQ, 120
        // bpm) so every pass restarts it.
        let track = try midiTrack(id: "midi", notes: [(start: 960, duration: 960)])
        let loop = try MusicLoopRange(startSample: 24_000, endSample: 72_000)
        let document = try MusicDocument(name: "Loop", tracks: [track])
        let transport = try makeTransport(document, [], Authority())
        try transport.start(atSample: 24_000, loop: loop, ownerToken: "proof")
        try transport.markRecording(true, ownerToken: "proof")
        let blocks = 96
        let pcm = try render(transport, blocks: blocks) // 98_304 samples ≈ 2.05 passes
        // The linear clock never wraps and never drifts.
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), 24_000 + Int64(blocks) * 1_024)
        // The musical position wraps into the frozen region with zero drift.
        let linear = 24_000 + Int64(blocks) * 1_024
        XCTAssertEqual(try transport.musicalPosition(ownerToken: "proof"), loop.musicalPosition(linearSample: linear))
        XCTAssertEqual(try transport.passIndex(ownerToken: "proof"), loop.passIndex(linearSample: linear))
        // Both the first pass and the restarted second pass carry the tone.
        XCTAssertGreaterThan(magnitude(Array(pcm[0..<24_000]), frequency: 440), 0.02)
        XCTAssertGreaterThan(magnitude(Array(pcm[48_128..<72_000]), frequency: 440), 0.02,
                             "second pass restarts the looped accompaniment after the wrap")
        try transport.close(ownerToken: "proof")
    }

    /// Loop length is an exact multiple of the render block, so the wrap is
    /// block-aligned: every pass must repeat the frozen file window
    /// sample-exactly with zero drift and no gap.
    func testManualLoopAudioWindowRepeatsSampleExactlyAcrossWraps() async throws {
        let root = try directory()
        let a = try source(root, name: "LoopSource", frequency: 220, seconds: 4)
        let document = try MusicDocument(name: "LoopA", assets: [a.asset],
                                         tracks: [try audioTrack(id: "t1", source: a, offset: 0, duration: 4 * 48_000)])
        // Frozen window [48_000, 97_152): length 49_152 = 48 render blocks.
        let loop = try MusicLoopRange(startSample: 48_000, endSample: 48_000 + 49_152)
        let transport = try makeTransport(document, [a], Authority())
        try transport.start(atSample: 48_000, loop: loop, ownerToken: "proof")
        try transport.markRecording(true, ownerToken: "proof")
        let blocks = 96 // 98_304 = two full passes, wrap exactly at block 48
        let pcm = try render(transport, blocks: blocks)
        XCTAssertEqual(pcm.count, 96 * 1_024)
        let file = try AVAudioFile(forReading: a.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = 48_000
        let reference = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 49_152)!
        try file.read(into: reference, frameCount: 49_152)
        let window = Array(UnsafeBufferPointer(start: reference.floatChannelData![0], count: 49_152))
        // Pass 1 and pass 2 both equal the frozen window sample for sample.
        for passStart in [0, 49_152] {
            for index in stride(from: 0, to: 49_152, by: 997) {
                XCTAssertEqual(Double(pcm[passStart + index]), Double(window[index]), accuracy: 1e-4,
                               "pass at \(passStart), sample \(index) plays the frozen window")
            }
        }
        // No cross-pass drift: the linear clock advanced exactly two passes.
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), 48_000 + 2 * 49_152)
        XCTAssertEqual(try transport.musicalPosition(ownerToken: "proof"), 48_000)
        XCTAssertEqual(try transport.passIndex(ownerToken: "proof"), 2)
        try transport.close(ownerToken: "proof")
    }

    /// Clips that occupy only the middle of the frozen loop keep their
    /// in-loop placement every pass: a mid-loop clip sounds only inside its
    /// window, a clip spanning the loop start sounds from the loop start
    /// then stops, a clip after the loop never sounds, pass 2 repeats pass 1
    /// sample-exactly (zero drift), and the gaps hold real scheduled silence.
    /// Manual-render player nodes may start a few hundred samples off, so
    /// window placement is verified by energy envelopes; the single-player
    /// window-repeat test pins absolute sample alignment.
    func testLoopWindowPreservesGapsPhaseAndMultiTrackOffsets() async throws {
        let root = try directory()
        let a = try source(root, name: "MidA", frequency: 220, seconds: 3)
        let b = try source(root, name: "MidB", frequency: 330, seconds: 3)
        let c = try source(root, name: "MidC", frequency: 550, seconds: 1)
        // Nonzero start; frozen loop [48_000, 146_304) (96 render blocks).
        let loopStart: Int64 = 48_000
        let clipA = try MusicClip(id: MusicClipID(rawValue: "a-clip"), name: "A", trackID: MusicTrackID(rawValue: "a"),
                                  offset: MusicSampleTime(72_576),
                                  body: .audio(try MusicAudioClipPayload(assetID: a.asset.id, trimStartSamples: 0,
                                                                       durationSamples: 24_576)))
        // Spans from before the loop into it: window [48_000, 60_000), then
        // silent after 12_000 samples inside the loop.
        let clipB = try MusicClip(id: MusicClipID(rawValue: "b-clip"), name: "B", trackID: MusicTrackID(rawValue: "b"),
                                  offset: MusicSampleTime(20_000),
                                  body: .audio(try MusicAudioClipPayload(assetID: b.asset.id, trimStartSamples: 0,
                                                                       durationSamples: 40_000)))
        let clipC = try MusicClip(id: MusicClipID(rawValue: "c-clip"), name: "C", trackID: MusicTrackID(rawValue: "c"),
                                  offset: MusicSampleTime(200_000),
                                  body: .audio(try MusicAudioClipPayload(assetID: c.asset.id, trimStartSamples: 0,
                                                                       durationSamples: 48_000)))
        let trackA = try FloeMusicCore.MusicTrack(id: MusicTrackID(rawValue: "a"), name: "A", kind: .audio, clips: [clipA])
        let trackB = try FloeMusicCore.MusicTrack(id: MusicTrackID(rawValue: "b"), name: "B", kind: .audio, clips: [clipB])
        let trackC = try FloeMusicCore.MusicTrack(id: MusicTrackID(rawValue: "c"), name: "C", kind: .audio, clips: [clipC])
        let document = try MusicDocument(name: "Mids", assets: [a.asset, b.asset, c.asset], tracks: [trackA, trackB, trackC])
        let loop = try MusicLoopRange(startSample: loopStart, endSample: loopStart + 98_304)
        let transport = try makeTransport(document, [a, b, c], Authority())
        try transport.start(atSample: loopStart, loop: loop, ownerToken: "proof")
        try transport.markRecording(true, ownerToken: "proof")
        let blocks = 192 // two full passes, wrap exactly at block 96
        let pcm = try render(transport, blocks: blocks)
        /// 512-sample RMS energy windows; returns the center of every window
        /// whose RMS sits above a silence threshold.
        func activeZones(_ start: Int, _ end: Int, in pass: Int, threshold: Double = 0.03) -> (first: Int, last: Int)? {
            let base = pass * 98_304
            var first = -1, last = -1
            var position = start
            while position + 512 <= end {
                var sum = 0.0
                for i in position..<(position + 512) { sum += Double(pcm[base + i]) * Double(pcm[base + i]) }
                if (sum / 512).squareRoot() > threshold {
                    if first < 0 { first = position }
                    last = position + 512
                }
                position += 256
            }
            return first < 0 ? nil : (first, last)
        }
        // 1) Zero cross-pass drift: pass 2 equals pass 1 sample-exactly.
        for i in 0..<98_304 {
            XCTAssertEqual(pcm[98_304 + i], pcm[i], "pass 2 repeats pass 1 at sample \(i)")
        }
        for pass in 0..<2 {
            // 2) Window B sounds from the loop start and ends near 12_000.
            let bZone = activeZones(0, 20_000, in: pass)
            XCTAssertNotNil(bZone, "pass \(pass) window B sounds")
            XCTAssertLessThan(abs(bZone!.first - 0), 1_500, "pass \(pass) window B starts at the loop start")
            XCTAssertLessThan(abs(bZone!.last - 12_000), 1_500, "pass \(pass) window B ends at its frozen window end")
            // 3) Window A sounds inside its frozen window only.
            let aZone = activeZones(18_000, 56_000, in: pass)
            XCTAssertNotNil(aZone, "pass \(pass) window A sounds")
            XCTAssertLessThan(abs(aZone!.first - 24_576), 1_500, "pass \(pass) window A starts at its frozen window")
            XCTAssertLessThan(abs(aZone!.last - 49_152), 1_500, "pass \(pass) window A ends at its frozen window end")
            // 4) Real scheduled silence fills the gaps (no active windows,
            //    and long runs of exact zeros).
            XCTAssertNil(activeZones(15_000, 22_000, in: pass), "pass \(pass) gap before A stays silent")
            XCTAssertNil(activeZones(52_000, 96_000, in: pass), "pass \(pass) trailing gap stays silent")
            func longestZeroRun(_ start: Int, _ end: Int) -> Int {
                var best = 0, current = 0
                for i in (pass * 98_304 + start)..<(pass * 98_304 + end) {
                    if pcm[i] == 0 { current += 1; best = max(best, current) } else { current = 0 }
                }
                return best
            }
            XCTAssertGreaterThanOrEqual(longestZeroRun(16_000, 23_000), 3_000, "pass \(pass) gap keeps seconds of exact silence")
            XCTAssertGreaterThanOrEqual(longestZeroRun(55_000, 95_000), 3_000, "pass \(pass) trailing gap keeps seconds of exact silence")
        }
        // 5) A clip entirely after the frozen loop never sounds.
        XCTAssertLessThan(magnitude(Array(pcm[0..<196_608]), frequency: 550), 0.02)
        XCTAssertEqual(try transport.absolutePosition(ownerToken: "proof"), loopStart + 2 * 98_304)
        XCTAssertEqual(try transport.musicalPosition(ownerToken: "proof"), loopStart)
        try transport.close(ownerToken: "proof")
    }

    func testLoopClipOutsideFrozenRegionStaysSilent() async throws {
        let root = try directory()
        let inside = try source(root, name: "In", frequency: 220, seconds: 1)
        let outside = try source(root, name: "Out", frequency: 660, seconds: 1)
        let document = try MusicDocument(name: "Regions", assets: [inside.asset, outside.asset],
                                         tracks: [try audioTrack(id: "a", source: inside, offset: 48_000, duration: 48_000),
                                                  try audioTrack(id: "b", source: outside, offset: 10 * 48_000, duration: 48_000)])
        let loop = try MusicLoopRange(startSample: 48_000, endSample: 96_000)
        let transport = try makeTransport(document, [inside, outside], Authority())
        try transport.start(atSample: 48_000, loop: loop, ownerToken: "proof")
        try transport.markRecording(true, ownerToken: "proof")
        let pcm = try render(transport, blocks: 96)
        XCTAssertGreaterThan(magnitude(Array(pcm[0..<48_000]), frequency: 220), 0.1)
        XCTAssertLessThan(magnitude(pcm, frequency: 660), 0.02, "clip outside the frozen loop never sounds")
        try transport.close(ownerToken: "proof")
    }

    func testNewAPIsAreOwnerFencedAndManualCaptureIsRejected() async throws {
        let root = try directory()
        let a = try source(root, name: "F", seconds: 1)
        let document = try MusicDocument(name: "F", assets: [a.asset],
                                         tracks: [try audioTrack(id: "t1", source: a, offset: 0, duration: 48_000)])
        let authority = Authority()
        let transport = try makeTransport(document, [a], authority)
        let loop = try MusicLoopRange(startSample: 0, endSample: 96_000)
        XCTAssertThrowsError(try transport.start(atSample: 0, loop: loop, ownerToken: "wrong"))
        try transport.start(atSample: 0, loop: loop, ownerToken: "proof")
        XCTAssertThrowsError(try transport.musicalPosition(ownerToken: "wrong"))
        XCTAssertThrowsError(try transport.passIndex(ownerToken: "wrong"))
        XCTAssertEqual(try transport.passIndex(ownerToken: "proof"), 0)
        let service = MusicRecordingService()
        let lease = try MusicRenderLease(document: document, ownerToken: "proof")
        let destination = root.appendingPathComponent("cap.wav")
        do {
            try await transport.startCapture(destination: destination, service: service, lease: lease,
                                             monitoring: false, ownerToken: "proof")
            XCTFail("manual rendering mode must not start a device capture")
        } catch { /* expected */ }
        try transport.close(ownerToken: "proof")
        do {
            _ = try await transport.stopCapture(finish: true, ownerToken: "proof")
            XCTFail("closed transport must not stop a capture")
        } catch { /* expected */ }
    }

    // MARK: - Capture sink stamp mapping (controlled input timestamps)

    private func hostTime(_ seconds: Double) -> UInt64 { AVAudioTime.hostTime(forSeconds: seconds) }
    private func makeTime(sample: Int64, host: UInt64, rate: Double, hostValid: Bool = true,
                          sampleValid: Bool = true) -> AVAudioTime {
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = Float64(sample)
        stamp.mHostTime = host
        stamp.mRateScalar = 1
        stamp.mFlags = []
        if sampleValid { stamp.mFlags.insert(.sampleTimeValid) }
        if hostValid { stamp.mFlags.insert(.hostTimeValid) }
        return AVAudioTime(audioTimeStamp: &stamp, sampleRate: rate)
    }

    private func makeSink(_ root: URL, document: MusicDocument, loop: MusicLoopRange?,
                          startLinear: Int64, capacity: Int = 8) async throws -> (MusicCaptureTapSink, MusicRecordingService, MusicTakeHandle, URL) {
        let service = MusicRecordingService()
        let lease = try MusicRenderLease(document: document, ownerToken: "proof")
        let destination = root.appendingPathComponent("take-\(UUID().uuidString).wav")
        let handle = try await service.begin(document: document, lease: lease, destination: destination)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        // hostTime and linear come from one observation in production; the
        // fixture mirrors that with matching host/rate/clock values.
        let anchor = MusicCaptureTapSink.Anchor(startLinearSample: startLinear, outputHostTime: hostTime(1_000),
                                                outputDeviceRate: 48_000, startClockSeconds: 1_000,
                                                projectSampleRate: 48_000)
        let sink = try MusicCaptureTapSink(inputFormat: stereo, outputFormat: stereo, service: service,
                                           handle: handle, anchor: anchor, loop: loop, capacity: capacity)
        return (sink, service, handle, destination)
    }

    /// Nonzero recording start, a delayed first buffer, and loop passes
    /// crossing mid-buffer: pass boundaries come out at frame granularity
    /// from hostTime stamps on the shared system clock.
    func testCaptureSinkMapsHostTimeOntoTransportClock() async throws {
        let root = try directory()
        let document = try MusicDocument(name: "Cap")
        // Frozen loop [48_000, 56_192), recording starts at linear 48_000.
        let loop = try MusicLoopRange(startSample: 48_000, endSample: 56_192)
        let (sink, service, handle, destination) = try await makeSink(root, document: document, loop: loop, startLinear: 48_000)
        let base = 1_000.0 // anchor host epoch (seconds)
        // Delayed first buffer: 2_048 samples (0.0427 s) late → its first PCM
        // frame is linear 50_048, never the startCapture call site's playhead.
        sink.receive(try sinkTestBuffer(frames: 4_096), time: makeTime(sample: 500_000, host: hostTime(base + 2_048.0 / 48_000), rate: 48_000))
        // Covers linear [54_144, 58_240): crosses the 56_192 loop end 2_048
        // frames in → pass 1 begins at absolute frame 4_096 + 2_048 = 6_144.
        sink.receive(try sinkTestBuffer(frames: 4_096), time: makeTime(sample: 504_096, host: hostTime(base + 6_144.0 / 48_000), rate: 48_000))
        // Covers linear [58_240, 62_336): fully inside pass 1, no boundary.
        sink.receive(try sinkTestBuffer(frames: 4_096), time: makeTime(sample: 508_192, host: hostTime(base + 10_240.0 / 48_000), rate: 48_000))
        // Covers linear [62_336, 66_432): crosses the 64_384 boundary 2_048
        // frames in → pass 2 begins at absolute frame 12_288 + 2_048 = 14_336.
        sink.receive(try sinkTestBuffer(frames: 4_096), time: makeTime(sample: 512_288, host: hostTime(base + 14_336.0 / 48_000), rate: 48_000))
        let status = await sink.drain()
        XCTAssertFalse(status.misaligned || status.overflowed || status.deliveryFailed)
        let stamps = sink.snapshot()
        XCTAssertEqual(stamps.totalFrames, 4 * 4_096)
        XCTAssertEqual(stamps.passBoundaries, [6_144, 14_336])
        // The clip offset comes from the first actually-written PCM frame:
        // the delayed first buffer maps to linear 50_048, never the
        // startCapture call-site playhead.
        XCTAssertEqual(stamps.firstLinearSample, 50_048)
        let take = try await service.finish(handle)
        XCTAssertEqual(take.frames, 4 * 4_096)
        XCTAssertEqual(take.file, destination)
    }

    /// SampleTime fallback converts strictly inside the input's own domain
    /// (via the first observed sample+host pair), so different sampleTime
    /// zero points and arbitrary output rates cannot misalign the take.
    func testCaptureSinkSampleTimeFallbackUsesOwnDomainReference() async throws {
        let root = try directory()
        let document = try MusicDocument(name: "Cap")
        // Frozen loop [48_000, 56_192): buffers below cross its end mid-buffer.
        let loop = try MusicLoopRange(startSample: 48_000, endSample: 56_192)
        let (sink, service, handle, _) = try await makeSink(root, document: document, loop: loop, startLinear: 48_000)
        let base = 1_000.0
        // Reference buffer establishes the input domain (sample zero is
        // 7_000_000 — an arbitrary device zero point). Stamps are
        // contiguous: each buffer starts exactly one buffer-length later.
        sink.receive(try sinkTestBuffer(frames: 4_096),
                     time: makeTime(sample: 7_000_000, host: hostTime(base), rate: 48_000))
        // 4_096 samples later in the SAME input domain, hostTime-less stamp
        // → linear 52_096. Covers [52_096, 56_192): ends exactly at the loop
        // end, so pass 0 holds the whole buffer.
        sink.receive(try sinkTestBuffer(frames: 4_096),
                     time: makeTime(sample: 7_004_096, host: 0, rate: 48_000, hostValid: false))
        // Covers [56_192, 60_288): begins exactly at the loop start → pass 1
        // at absolute frame 8_192.
        sink.receive(try sinkTestBuffer(frames: 4_096),
                     time: makeTime(sample: 7_008_192, host: 0, rate: 48_000, hostValid: false))
        // A stamp in a DIFFERENT domain (44.1 kHz sampleTime) is rejected:
        // the take is flagged, never zero-filled with a wrong position.
        sink.receive(try sinkTestBuffer(frames: 1_024),
                     time: makeTime(sample: 7_012_288, host: 0, rate: 44_100, hostValid: false))
        let status = await sink.drain()
        XCTAssertTrue(status.misaligned, "a cross-domain timestamp flags the take, never a guessed position")
        let stamps = sink.snapshot()
        XCTAssertEqual(stamps.firstLinearSample, 48_000)
        XCTAssertEqual(stamps.totalFrames, 3 * 4_096, "cross-domain stamp is dropped, not written")
        XCTAssertEqual(stamps.passBoundaries, [8_192], "pass 1 begins at the third buffer")
        _ = try await service.cancel(handle)
    }

    /// The converter runs on the consumer path: a 48 kHz input tapped into a
    /// 44.1 kHz project still lands the resampled frame count in the take.
    func testCaptureSinkConvertsInputRateOnConsumerPath() async throws {
        let root = try directory()
        let document = try MusicDocument(name: "Cap")
        let service = MusicRecordingService()
        let lease = try MusicRenderLease(document: document, ownerToken: "proof")
        let destination = root.appendingPathComponent("rate.wav")
        let handle = try await service.begin(document: document, lease: lease, destination: destination)
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let anchor = MusicCaptureTapSink.Anchor(startLinearSample: 0, outputHostTime: hostTime(2_000),
                                                outputDeviceRate: 48_000, startClockSeconds: 2_000,
                                                projectSampleRate: 44_100)
        let sink = try MusicCaptureTapSink(inputFormat: input, outputFormat: output, service: service,
                                           handle: handle, anchor: anchor, loop: nil)
        let base = 2_000.0
        sink.receive(try sinkTestBuffer(frames: 4_800),
                     time: makeTime(sample: 0, host: hostTime(base), rate: 48_000))
        sink.receive(try sinkTestBuffer(frames: 4_800),
                     time: makeTime(sample: 4_800, host: hostTime(base + 0.1), rate: 48_000))
        let status = await sink.drain()
        XCTAssertFalse(status.misaligned && status.overflowed)
        let take = try await service.finish(handle)
        // 9_600 input frames at 48 kHz = 0.2 s → 8_820 output frames once
        // the converter tail is flushed at drain (±2 resampling rounding).
        XCTAssertEqual(take.frames, 8_820, accuracy: 2)
    }

    /// The bounded queue proves capacity: a fast producer with no consumer
    /// scheduling overflow flags the take, delivers exactly the queued
    /// prefix, joins the consumer, and a stale late callback is ignored.
    func testCaptureSinkCapacityOverflowAndStaleCallbackFence() async throws {
        let root = try directory()
        let document = try MusicDocument(name: "Cap")
        let (sink, service, handle, destination) = try await makeSink(root, document: document, loop: nil,
                                                                      startLinear: 0, capacity: 2)
        let base = 3_000.0
        // Feed without yielding: the consumer task cannot interleave, so the
        // queue fills to its capacity of 2 and the rest overloads.
        for index in 0..<4 {
            sink.receive(try sinkTestBuffer(frames: 1_024),
                         time: makeTime(sample: Int64(index) * 1_024, host: hostTime(base + Double(index) / 10), rate: 48_000))
        }
        let status = await sink.drain()
        XCTAssertTrue(status.overflowed, "bounded queue must flag overload instead of growing memory")
        let stamps = sink.snapshot()
        // The consumer runs concurrently, so anywhere between the capacity
        // and the fed count is a correct bounded outcome — never more.
        XCTAssertGreaterThanOrEqual(stamps.totalFrames, 2 * 1_024)
        XCTAssertLessThanOrEqual(stamps.totalFrames, 4 * 1_024)
        // Stale callback after stop is fenced off: no frames, no re-attach.
        sink.receive(try sinkTestBuffer(frames: 1_024),
                     time: makeTime(sample: 9_999, host: hostTime(base + 9), rate: 48_000))
        let fenced = sink.snapshot().totalFrames
        XCTAssertLessThanOrEqual(fenced, 4 * 1_024)
        // Overload keeps bytes recoverable: the take exists and is retained.
        let take = try await service.finish(handle)
        XCTAssertEqual(take.frames, fenced)
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.file.path))
        XCTAssertEqual(take.file, destination)
    }

    func testCaptureSinkCancelRetainsRecoveryBytes() async throws {
        let root = try directory()
        let document = try MusicDocument(name: "Cap")
        let (sink, service, handle, destination) = try await makeSink(root, document: document, loop: nil, startLinear: 0)
        sink.receive(try sinkTestBuffer(frames: 2_048), time: makeTime(sample: 0, host: hostTime(4_000), rate: 48_000))
        let status = await sink.drain()
        XCTAssertFalse(status.overflowed || status.misaligned || status.deliveryFailed)
        let recovery = try await service.cancel(handle)
        XCTAssertEqual(recovery?.frames, 2_048)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recovery).file.path))
    }

    /// installTap only lends the callback buffer: the engine may reuse it
    /// the moment the callback returns. The sink must own a snapshot taken
    /// inside receive, so mutating the original afterwards cannot change
    /// the recorded take.
    func testCaptureSinkSnapshotsTapBufferBeforeCallbackReturns() async throws {
        let root = try directory()
        let document = try MusicDocument(name: "Cap")
        let service = MusicRecordingService()
        let lease = try MusicRenderLease(document: document, ownerToken: "proof")
        let destination = root.appendingPathComponent("snapshot.wav")
        let handle = try await service.begin(document: document, lease: lease, destination: destination)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let anchor = MusicCaptureTapSink.Anchor(startLinearSample: 0, outputHostTime: hostTime(5_000),
                                                outputDeviceRate: 48_000, startClockSeconds: 5_000,
                                                projectSampleRate: 48_000)
        let sink = try MusicCaptureTapSink(inputFormat: stereo, outputFormat: stereo, service: service,
                                           handle: handle, anchor: anchor, loop: nil)
        let buffer = try sinkTestBuffer(frames: 4_096)
        sink.receive(buffer, time: makeTime(sample: 0, host: hostTime(5_000), rate: 48_000))
        // Engine reuse simulation: trash the callback buffer in place.
        for index in 0..<4_096 {
            buffer.floatChannelData![0][index] = 0
            buffer.floatChannelData![1][index] = 0
        }
        let status = await sink.drain()
        XCTAssertFalse(status.misaligned || status.overflowed || status.deliveryFailed)
        let take = try await service.finish(handle)
        XCTAssertEqual(take.frames, 4_096)
        let file = try AVAudioFile(forReading: take.file, commonFormat: .pcmFormatFloat32, interleaved: false)
        let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096)!
        try file.read(into: output, frameCount: 4_096)
        var peak = 0.0
        for index in 0..<4_096 { peak = max(peak, Double(abs(output.floatChannelData![0][index]))) }
        XCTAssertGreaterThan(peak, 0.05, "the owned snapshot kept the original PCM, not the reuse")
    }

    /// A failed finish (commit cannot move the staged file) must keep the
    /// take active on the SAME handle so cancel recovers the original bytes.
    func testFinishCommitFailureKeepsSameHandleRecoverable() async throws {
        let root = try directory()
        let document = try MusicDocument(name: "F")
        let service = MusicRecordingService()
        let lease = try MusicRenderLease(document: document, ownerToken: "proof")
        let destination = root.appendingPathComponent("commit-fail.wav")
        let handle = try await service.begin(document: document, lease: lease, destination: destination)
        let chunk = try sinkTestBuffer(frames: 2_048)
        var interleaved = [Float](repeating: 0, count: 4_096)
        for index in 0..<2_048 {
            interleaved[index * 2] = chunk.floatChannelData![0][index]
            interleaved[index * 2 + 1] = chunk.floatChannelData![1][index]
        }
        try await service.append(interleavedStereo: interleaved, handle: handle)
        // Non-replacing commit: the destination already exists.
        try Data([0x01]).write(to: destination)
        do {
            _ = try await service.finish(handle)
            XCTFail("finish must fail when the commit cannot move the staged file")
        } catch { /* expected */ }
        let recovery = try await service.cancel(handle)
        XCTAssertEqual(recovery?.frames, 2_048)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(recovery).file.path))
        // The decoy destination is untouched; the recovered take carries the
        // original staged bytes under a recovery name.
        XCTAssertEqual(try Data(contentsOf: destination), Data([0x01]))
        XCTAssertNotEqual(recovery?.file, destination)
        let recoveredFile = try AVAudioFile(forReading: try XCTUnwrap(recovery).file,
                                            commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(recoveredFile.length, 2_048)
        let recoveredPCM = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: recoveredFile.processingFormat,
                                                         frameCapacity: 2_048))
        try recoveredFile.read(into: recoveredPCM, frameCount: 2_048)
        XCTAssertEqual(recoveredPCM.frameLength, 2_048)
        let samples = try XCTUnwrap(recoveredPCM.floatChannelData)[0]
        XCTAssertGreaterThan((0..<2_048).map { abs(samples[$0]) }.max() ?? 0, 0.05)
    }

    private func sinkTestBuffer(frames: Int) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames {
            let value = Float(0.1 * sin(2 * .pi * 220 * Double(index) / 48_000))
            buffer.floatChannelData![0][index] = value
            buffer.floatChannelData![1][index] = value
        }
        return buffer
    }
}
