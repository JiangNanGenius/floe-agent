import XCTest
import AVFoundation
import FloeMusicCore
@testable import FloeMusicNative

@MainActor final class DJTransportTests: XCTestCase {
    private final class Authority: MusicAudioAuthority {
        var acquired = 0, released = 0
        func acquirePlayback() throws { acquired += 1 }
        func releasePlayback() { released += 1 }
    }
    private func directory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["MUSIC_DJ_PROOF_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeMusicDJTests")
        let url = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func source(_ root: URL, name: String, frequency: Double = 220, rate: Double = 48_000,
                        seconds: Double = 4, channels: AVAudioChannelCount = 2, beatBPM: Double? = nil) throws -> ResolvedMusicSource {
        let url = root.appendingPathComponent(name + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        let total = Int(seconds * rate); var position = 0
        while position < total {
            let count = min(4_096, total - position); buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                let t = Double(position + i) / rate
                var value = 0.2 * sin(2 * .pi * frequency * t)
                if let beatBPM {
                    let phase = t.truncatingRemainder(dividingBy: 60 / beatBPM)
                    value *= phase < 0.04 ? exp(-phase * 80) : 0
                }
                for channel in 0..<Int(channels) { buffer.floatChannelData![channel][i] = Float(value) }
            }
            try file?.write(from: buffer); position += count
        }
        file = nil
        let asset = try MusicAudioPreparation.inspect(url: url)
        return .init(asset: asset, url: url)
    }
    private func setup(_ a: ResolvedMusicSource, _ b: ResolvedMusicSource? = nil) async throws
        -> (MusicDJTransport, MusicDJSession, Authority, [MusicDJPreparedSource]) {
        let assets = [a.asset] + (b.map { [$0.asset] } ?? [])
        var session = try MusicDJSession(assets: assets, crossfader: 0)
        try session.loadDeck(.a, asset: a.asset); try session.setPlaying(.a, true)
        if let b { try session.loadDeck(.b, asset: b.asset); try session.setPlaying(.b, true) }
        var prepared = [try await MusicDJPreparedSource.prepare(a, projectSampleRate: 48_000)]
        if let b { prepared.append(try await MusicDJPreparedSource.prepare(b, projectSampleRate: 48_000)) }
        let authority = Authority()
        let transport = try MusicDJTransport(ownerToken: "proof", authority: authority, output: .manual)
        try transport.apply(session, prepared: prepared, ownerToken: "proof")
        return (transport, session, authority, prepared)
    }
    private func audio(_ transport: MusicDJTransport, blocks: Int = 16) async throws -> [Float] {
        var result: [Float] = []
        for _ in 0..<blocks {
            let buffer = try transport.renderOffline(frames: 1_024, ownerToken: "proof")
            result.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            await Task.yield()
        }
        return result
    }
    private func rms(_ samples: [Float]) -> Double { sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(samples.count)) }
    private func magnitude(_ samples: [Float], frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0
        for (i, value) in samples.enumerated() {
            let angle = 2 * Double.pi * frequency * Double(i) / 48_000
            real += Double(value) * cos(angle); imaginary += Double(value) * sin(angle)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }

    func testTwoRealFilesMixAndFaderDoesNotRewind() async throws {
        let root = try directory(), a = try source(root, name: "A"), b = try source(root, name: "B", frequency: 660)
        let (transport, initial, authority, _) = try await setup(a, b)
        defer { try? transport.close(ownerToken: "proof") }
        let first = try await audio(transport)
        XCTAssertGreaterThan(magnitude(first, frequency: 220), 0.17)
        XCTAssertLessThan(magnitude(first, frequency: 660), 0.02)
        let before = try transport.snapshot(ownerToken: "proof")
        var next = initial; try next.setCrossfader(1)
        try transport.apply(next, ownerToken: "proof")
        let second = try await audio(transport)
        XCTAssertGreaterThan(magnitude(Array(second.suffix(8_192)), frequency: 660), 0.17)
        XCTAssertLessThan(magnitude(Array(second.suffix(8_192)), frequency: 220), 0.02)
        let after = try transport.snapshot(ownerToken: "proof")
        XCTAssertGreaterThan(after.deckA.positionSamples, before.deckA.positionSamples)
        XCTAssertGreaterThan(after.deckB.positionSamples, before.deckB.positionSamples)
        XCTAssertEqual(authority.acquired, 0); XCTAssertEqual(authority.released, 0)
    }

    func testRateActuallyChangesPCMAndKeyLockPreservesPitch() async throws {
        let root = try directory(), a = try source(root, name: "Rate", seconds: 10)
        let (transport, initial, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        var next = initial; try next.setRate(.a, rate: 1.5)
        try transport.apply(next, ownerToken: "proof")
        let shifted = try await audio(transport, blocks: 24)
        XCTAssertGreaterThan(magnitude(Array(shifted.suffix(16_384)), frequency: 330), 0.12)
        try next.setKeyLocked(.a, true)
        try transport.apply(next, ownerToken: "proof")
        _ = try await audio(transport, blocks: 16)
        let locked = try await audio(transport, blocks: 24)
        XCTAssertGreaterThan(magnitude(Array(locked.suffix(16_384)), frequency: 220), 0.08)
        XCTAssertLessThan(magnitude(Array(locked.suffix(16_384)), frequency: 330), 0.03)
    }

    func testLoopStreamsPastSourceEndAndSeekUsesRealClock() async throws {
        let root = try directory(), a = try source(root, name: "Loop", seconds: 2)
        let (transport, initial, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        var next = initial; try next.setBeatGrid(.a, bpm: 120, firstBeatSample: 0, beatCount: 4)
        try next.setLoop(.a, startBeat: 1, lengthBeats: 1)
        try transport.apply(next, ownerToken: "proof")
        let data = try await audio(transport, blocks: 160)
        XCTAssertGreaterThan(rms(Array(data.suffix(16_384))), 0.1)
        let position = try transport.snapshot(ownerToken: "proof").deckA.positionSamples
        XCTAssertGreaterThanOrEqual(position, 24_000); XCTAssertLessThan(position, 48_000)
        try next.exitLoop(.a); try next.seek(.a, sample: 60_000)
        try transport.apply(next, ownerToken: "proof")
        _ = try await audio(transport, blocks: 4)
        XCTAssertGreaterThanOrEqual(try transport.snapshot(ownerToken: "proof").deckA.positionSamples, 60_000)
    }

    func testMono44100SourceConvertsAtMixerToProjectClock() async throws {
        let root = try directory(), a = try source(root, name: "Mono", rate: 44_100, channels: 1)
        let (transport, _, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        let samples = try await audio(transport, blocks: 24)
        XCTAssertGreaterThan(magnitude(samples, frequency: 220), 0.1)
        let position = try transport.snapshot(ownerToken: "proof").deckA.positionSamples
        XCTAssertEqual(Double(position), 24_576, accuracy: 4_096)
    }

    func testOwnerStopAndCloseFenceTransport() async throws {
        let root = try directory(), a = try source(root, name: "Owner")
        let (transport, _, _, _) = try await setup(a)
        _ = try await audio(transport, blocks: 4)
        XCTAssertThrowsError(try transport.stop(ownerToken: "other"))
        try transport.stop(ownerToken: "proof")
        let stopped = try transport.snapshot(ownerToken: "proof")
        XCTAssertFalse(stopped.running); XCTAssertFalse(stopped.deckA.playing)
        XCTAssertGreaterThan(stopped.deckA.positionSamples, 0)
        XCTAssertThrowsError(try transport.renderOffline(frames: 1_024, ownerToken: "proof"))
        try transport.close(ownerToken: "proof")
        XCTAssertThrowsError(try transport.snapshot(ownerToken: "proof"))
    }

    func testExplicitSeekIntentSeparatesCapturedStateFromMixerChange() async throws {
        let root = try directory(), a = try source(root, name: "Intent")
        let (transport, initial, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        XCTAssertEqual(try transport.snapshot(ownerToken: "proof").deckA.positionSamples, 0)
        _ = try await audio(transport, blocks: 16)
        let before = try transport.snapshot(ownerToken: "proof").deckA.positionSamples
        var next = initial
        next.deckA.playheadSamples = 123 // captured UI state, explicitly not a seek
        try next.setMasterGain(0.8)
        try transport.apply(next, seeking: [], ownerToken: "proof")
        XCTAssertEqual(try transport.snapshot(ownerToken: "proof").deckA.positionSamples, before)
        next.deckA.playheadSamples = 48_000
        try transport.apply(next, seeking: [.a], ownerToken: "proof")
        XCTAssertEqual(try transport.snapshot(ownerToken: "proof").deckA.positionSamples, 48_000)
    }

    func testPreparedSourceDetectsChangedBytesBeforeGraph() async throws {
        let root = try directory(), a = try source(root, name: "Changed")
        let prepared = try await MusicDJPreparedSource.prepare(a, projectSampleRate: 48_000)
        let handle = try FileHandle(forWritingTo: a.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        let transport = try MusicDJTransport(ownerToken: "proof", authority: Authority(), output: .manual)
        defer { try? transport.close(ownerToken: "proof") }
        var session = try MusicDJSession(assets: [a.asset]); try session.loadDeck(.a, asset: a.asset)
        XCTAssertThrowsError(try transport.apply(session, prepared: [prepared], ownerToken: "proof"))
    }

    func testBeatAnalysisUsesActualPulseAudioAndLeavesSilenceUnknown() async throws {
        let root = try directory()
        for bpm in [100.0, 120.0] {
            let a = try source(root, name: "Pulse\(bpm)", seconds: 12, beatBPM: bpm)
            let prepared = try await MusicDJPreparedSource.prepare(a, projectSampleRate: 48_000)
            let estimate = try await MusicDJBeatAnalysis.analyze(prepared, projectSampleRate: 48_000)
            XCTAssertNotNil(estimate.bpm); XCTAssertEqual(estimate.bpm ?? 0, bpm, accuracy: 1)
            XCTAssertGreaterThan(estimate.confidence, 0.8)
            XCTAssertEqual(estimate.assetContentHash, a.asset.contentHash)
        }
        let quiet = try source(root, name: "Silence", frequency: 0, seconds: 5)
        let prepared = try await MusicDJPreparedSource.prepare(quiet, projectSampleRate: 48_000)
        let estimate = try await MusicDJBeatAnalysis.analyze(prepared, projectSampleRate: 48_000)
        XCTAssertNil(estimate.bpm); XCTAssertEqual(estimate.confidence, 0)
    }

    func testPreparationCancellationCannotProduceAcceptedSource() async throws {
        let root = try directory(), a = try source(root, name: "Cancelled")
        let task = Task { try await MusicDJPreparedSource.prepare(a, projectSampleRate: 48_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled preparation accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRecordedMixIsActualGraphPCMAndDurableFile() async throws {
        let root = try directory(), a = try source(root, name: "RecA"), b = try source(root, name: "RecB", frequency: 660)
        let (transport, initial, _, _) = try await setup(a, b)
        defer { try? transport.close(ownerToken: "proof") }
        let document = try MusicDocument(name: "Recorded mix", assets: [a.asset, b.asset])
        let lease = try MusicRenderLease(document: document, ownerToken: "proof")
        let destination = root.appendingPathComponent("mix.caf")
        try await transport.startRecording(document: document, lease: lease, destination: destination, ownerToken: "proof")
        for index in 0..<32 {
            if index == 16 { var next = initial; try next.setCrossfader(1); try transport.apply(next, ownerToken: "proof") }
            _ = try transport.renderOffline(frames: 1_024, ownerToken: "proof")
            try await transport.drainRecording(ownerToken: "proof")
            await Task.yield()
        }
        let receipt = try await transport.finishRecording(ownerToken: "proof")
        XCTAssertFalse(receipt.recovered); XCTAssertEqual(receipt.file, destination)
        XCTAssertEqual(receipt.frames, 32_768); XCTAssertEqual(receipt.sampleRate, 48_000)
        XCTAssertEqual(receipt.sha256, try MusicAudioPreparation.hashFile(destination))
        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.length, receipt.frames)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        XCTAssertGreaterThan(magnitude(Array(samples.prefix(12_000)), frequency: 220), 0.17)
        XCTAssertGreaterThan(magnitude(Array(samples.suffix(12_000)), frequency: 660), 0.17)
        XCTAssertFalse(transport.isRecording)
        XCTAssertEqual(try MusicAudioPreparation.hashFile(a.url), a.asset.contentHash)
    }

    func testInvalidatedRecordingLeaseRecoversAudioInsteadOfDiscarding() async throws {
        let root = try directory(), a = try source(root, name: "Recover")
        let (transport, _, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        let document = try MusicDocument(name: "Original", assets: [a.asset])
        let lease = try MusicRenderLease(document: document, ownerToken: "proof"), destination = root.appendingPathComponent("cancelled.caf")
        try await transport.startRecording(document: document, lease: lease, destination: destination, ownerToken: "proof")
        _ = try transport.renderOffline(frames: 4_096, ownerToken: "proof")
        try await transport.drainRecording(ownerToken: "proof")
        lease.invalidate()
        let receipt = try await transport.finishRecording(ownerToken: "proof")
        XCTAssertTrue(receipt.recovered); XCTAssertTrue(receipt.file.lastPathComponent.hasPrefix("recovery-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try AVAudioFile(forReading: receipt.file).length, 4_096)
        XCTAssertEqual(receipt.sha256, try MusicAudioPreparation.hashFile(receipt.file))
    }

    func testRecordingBudgetStopsAtValidPrefixAndDoesNotClobberDestination() async throws {
        let root = try directory(), a = try source(root, name: "BudgetSource")
        let (transport, _, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        let document = try MusicDocument(name: "Budget", assets: [a.asset])
        let lease = try MusicRenderLease(document: document, ownerToken: "proof"), destination = root.appendingPathComponent("budget.caf")
        try await transport.startRecording(document: document, lease: lease, destination: destination, maximumBytes: 65_536, ownerToken: "proof")
        for _ in 0..<12 {
            _ = try transport.renderOffline(frames: 1_024, ownerToken: "proof")
            try await transport.drainRecording(ownerToken: "proof")
        }
        let receipt = try await transport.finishRecording(ownerToken: "proof")
        XCTAssertTrue(receipt.recovered); XCTAssertEqual(receipt.frames, 8_192)
        XCTAssertNotNil(receipt.diagnostic); XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try AVAudioFile(forReading: receipt.file).length, receipt.frames)
    }

    func testStopPreservesRecordingAndCloseRequiresFinalization() async throws {
        let root = try directory(), a = try source(root, name: "StopRecording")
        let (transport, _, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        let document = try MusicDocument(name: "Stop", assets: [a.asset])
        try await transport.startRecording(document: document, lease: MusicRenderLease(document: document, ownerToken: "proof"),
            destination: root.appendingPathComponent("stopped.caf"), ownerToken: "proof")
        _ = try transport.renderOffline(frames: 1_024, ownerToken: "proof")
        XCTAssertThrowsError(try transport.close(ownerToken: "proof"))
        try transport.stop(ownerToken: "proof")
        let receipt = try await transport.finishRecording(ownerToken: "proof")
        XCTAssertEqual(receipt.frames, 1_024); XCTAssertFalse(receipt.recovered)
        try transport.close(ownerToken: "proof")
    }

    func testRecordingRejectsForeignProjectAndEmptyTakeLeavesNoOutput() async throws {
        let root = try directory(), a = try source(root, name: "Foreign")
        let (transport, _, _, _) = try await setup(a)
        defer { try? transport.close(ownerToken: "proof") }
        let foreign = try MusicDocument(name: "Different project")
        do {
            try await transport.startRecording(document: foreign, lease: MusicRenderLease(document: foreign, ownerToken: "proof"),
                destination: root.appendingPathComponent("foreign.caf"), ownerToken: "proof")
            XCTFail("foreign assets accepted")
        } catch {}
        let document = try MusicDocument(name: "Empty take", assets: [a.asset]), destination = root.appendingPathComponent("empty.caf")
        try await transport.startRecording(document: document, lease: MusicRenderLease(document: document, ownerToken: "proof"),
            destination: destination, ownerToken: "proof")
        do { _ = try await transport.finishRecording(ownerToken: "proof"); XCTFail("empty take saved") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(transport.isRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".") }.isEmpty)
    }

    func testWAVExportUsesSameKeyLockedGraphAndExactDuration() async throws {
        let root = try directory(), a = try source(root, name: "ExportSource", seconds: 5)
        var session = try MusicDJSession(assets: [a.asset], crossfader: 0)
        try session.loadDeck(.a, asset: a.asset); try session.setPlaying(.a, true)
        try session.setRate(.a, rate: 1.5); try session.setKeyLocked(.a, true)
        let document = try MusicDocument(name: "Export", assets: [a.asset])
        let prepared = try await MusicDJPreparedSource.prepare(a, projectSampleRate: 48_000)
        let destination = root.appendingPathComponent("exported-keylock.wav")
        let receipt = try await MusicDJExport.render(session: session, document: document,
            lease: MusicRenderLease(document: document, ownerToken: "proof"), prepared: [prepared], frames: 72_000, destination: destination)
        XCTAssertEqual(receipt.frames, 72_000); XCTAssertFalse(receipt.recovered)
        XCTAssertEqual(receipt.sha256, try MusicAudioPreparation.hashFile(destination))
        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.length, 72_000); XCTAssertEqual(file.processingFormat.sampleRate, 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 72_000)!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 72_000)).suffix(48_000)
        XCTAssertGreaterThan(magnitude(Array(samples), frequency: 220), 0.1)
        XCTAssertLessThan(magnitude(Array(samples), frequency: 330), 0.03)
    }

    func testInterruptedExportReturnsRecoverablePrefixAndKeepsDestinationAbsent() async throws {
        let root = try directory(), a = try source(root, name: "InterruptedExport")
        var session = try MusicDJSession(assets: [a.asset], crossfader: 0)
        try session.loadDeck(.a, asset: a.asset); try session.setPlaying(.a, true)
        let document = try MusicDocument(name: "Cancel export", assets: [a.asset])
        let prepared = try await MusicDJPreparedSource.prepare(a, projectSampleRate: 48_000)
        let lease = try MusicRenderLease(document: document, ownerToken: "proof"), destination = root.appendingPathComponent("unfinished.wav")
        do {
            _ = try await MusicDJExport.render(session: session, document: document, lease: lease, prepared: [prepared],
                frames: 48_000, destination: destination, onProgress: { _ in lease.invalidate() })
            XCTFail("invalidated export completed")
        } catch let failure as MusicDJExportFailure {
            let recovery = try XCTUnwrap(failure.recovery)
            XCTAssertTrue(recovery.recovered); XCTAssertEqual(recovery.frames, 4_096)
            XCTAssertEqual(recovery.file.pathExtension, "wav")
            XCTAssertEqual(try AVAudioFile(forReading: recovery.file).length, recovery.frames)
            XCTAssertEqual(recovery.sha256, try MusicAudioPreparation.hashFile(recovery.file))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testActualDJWAVPassesExistingMP3EncoderAndIndependentDecoder() async throws {
        let root = try directory(), a = try source(root, name: "MP3Source", seconds: 3)
        var session = try MusicDJSession(assets: [a.asset], crossfader: 0)
        try session.loadDeck(.a, asset: a.asset); try session.setPlaying(.a, true)
        let document = try MusicDocument(name: "DJ MP3", assets: [a.asset])
        let prepared = try await MusicDJPreparedSource.prepare(a, projectSampleRate: 48_000)
        let wav = root.appendingPathComponent("dj-real-mix.wav"), output = root.appendingPathComponent("dj-real-mix.mp3")
        let lease = try MusicRenderLease(document: document, ownerToken: "proof")
        _ = try await MusicDJExport.render(session: session, document: document, lease: lease,
            prepared: [prepared], frames: 72_000, destination: wav)
        let encoded = try await MusicMP3Exporter().encode(wav: wav, destination: output, document: document, lease: lease)
        XCTAssertEqual(encoded, output)
        let decoded = try AVAudioFile(forReading: encoded, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(decoded.processingFormat.sampleRate, 48_000); XCTAssertEqual(decoded.processingFormat.channelCount, 2)
        XCTAssertEqual(Double(decoded.length) / 48_000, 1.5, accuracy: 0.05)
        let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 48_000)!
        try decoded.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        XCTAssertGreaterThan(magnitude(samples, frequency: 220), 0.15)
        XCTAssertGreaterThan(try Data(contentsOf: encoded).count, 20_000)
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 72_000)
    }

}
