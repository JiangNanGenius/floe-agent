// Actual Apple decoder/player checks. Run this suite alone so it never
// changes AVAudioSession underneath another audio test.
import XCTest
import AVFoundation
@testable import FloeApp

@MainActor
final class PiPAudioBackendAppTests: XCTestCase {
    /// The bundled meditation loop is a real App resource: decode it through
    /// Apple's audio stack, prove it is finite, non-silent and bounded, and
    /// measure that the wrap step stays inside the loop's natural
    /// sample-to-sample variation. This is waveform continuity, not a
    /// listening test; subjective seam acceptance belongs to the primary.
    func testBundledMeditationLoopDecodesAndWrapsContinuously() throws {
        let url = try XCTUnwrap(
            AVPiPAmbientPlayer.bundledURL(for: .meditation),
            "PiPAmbientMeditation.wav is missing from the app bundle; regenerate the project so the project.yml Resources/Audio entry applies"
        )
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length) / 48_000, 60.0, accuracy: 0.001)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        XCTAssertEqual(Int64(buffer.frameLength), file.length)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let frameCount = Int(buffer.frameLength)
        let left = UnsafeBufferPointer(start: channels[0], count: frameCount)
        let right = UnsafeBufferPointer(start: channels[1], count: frameCount)
        XCTAssertTrue(left.allSatisfy { $0.isFinite })
        XCTAssertTrue(right.allSatisfy { $0.isFinite })

        var peak: Float = 0
        var energy = 0.0
        var steps = [Float](repeating: 0, count: frameCount - 1)
        for index in 1..<frameCount {
            let sample = left[index]
            peak = max(peak, abs(sample))
            energy += Double(sample) * Double(sample)
            steps[index - 1] = abs(sample - left[index - 1])
        }
        XCTAssertLessThanOrEqual(peak, 0.95)
        let rms = sqrt(energy / Double(frameCount))
        XCTAssertGreaterThan(rms, 0.01, "The loop must carry real audio before gain is applied")
        XCTAssertLessThan(rms, 0.5)

        steps.sort()
        let p999 = steps[Int(Double(steps.count) * 0.999)]
        let wrapStep = abs(left[0] - left[frameCount - 1])
        XCTAssertLessThanOrEqual(
            wrapStep,
            p999,
            "The loop wrap must stay inside the natural sample-to-sample variation"
        )
    }

    /// The retained attention cue still decodes as finite mono PCM.
    func testAttentionCueDecodesAsFiniteNonSilentPCM() throws {
        let data = AmbientAudioSynthesizer.cueWavData()
        XCTAssertEqual(data.count, 44 + AmbientAudioSynthesizer.cueSampleCount * 2)
        XCTAssertLessThan(data.count, 64_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pip-cue-decoder-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cue.wav")
        try data.write(to: url, options: .atomic)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.length, AVAudioFramePosition(AmbientAudioSynthesizer.cueSampleCount))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
        XCTAssertTrue(samples.allSatisfy { $0.isFinite })
        var energy = 0.0
        for sample in samples { energy += Double(sample) * Double(sample) }
        let rms = sqrt(energy / Double(samples.count))
        XCTAssertGreaterThan(rms, 0.001)
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 0, 1)
    }

    func testRealAmbientBackendKeepsPlayingAtZeroAndAcceptsLiveGainChanges() async throws {
        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        let backend = AVPiPAmbientPlayer()
        defer {
            backend.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try session.setActive(true)
        XCTAssertNotNil(
            AVPiPAmbientPlayer.bundledURL(for: .meditation),
            "The bundled meditation loop must ship with the app"
        )
        XCTAssertTrue(backend.play(sound: .meditation, gain: 0))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(backend.isPlaying, "Zero output gain must not pause the actual AVAudioPlayer")
        backend.setGain(0.01)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(backend.isPlaying)
        backend.setGain(0)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(backend.isPlaying)
        backend.pause()
        XCTAssertFalse(backend.isPlaying)
        XCTAssertTrue(backend.resume())
        XCTAssertTrue(backend.isPlaying)
        backend.stop()
        XCTAssertFalse(backend.isPlaying)
    }
}
