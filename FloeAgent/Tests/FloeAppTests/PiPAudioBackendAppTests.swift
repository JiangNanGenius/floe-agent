// Actual Apple decoder/player checks. Run this suite alone so it never
// changes AVAudioSession underneath another audio test.
import XCTest
import AVFoundation
@testable import FloeApp

@MainActor
final class PiPAudioBackendAppTests: XCTestCase {
    func testGeneratedLoopsDecodeAsFiniteNonSilentPCM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pip-audio-decoder-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for sound in PiPAmbientSound.allCases {
            let data = AmbientAudioSynthesizer.wavData(for: sound)
            XCTAssertLessThan(data.count, 1_000_000)
            let url = root.appendingPathComponent(sound.rawValue + ".wav")
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            XCTAssertGreaterThan(file.length, 44_100)
            XCTAssertLessThanOrEqual(file.length, 44_100 * 10)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            ))
            try file.read(into: buffer)
            XCTAssertEqual(Int64(buffer.frameLength), file.length)
            let channels = try XCTUnwrap(buffer.floatChannelData)
            let samples = UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength))
            var energy = 0.0
            var allFinite = true
            var peak: Float = 0
            for sample in samples {
                guard sample.isFinite else { allFinite = false; continue }
                peak = max(peak, abs(sample))
                energy += Double(sample) * Double(sample)
            }
            XCTAssertTrue(allFinite)
            XCTAssertLessThanOrEqual(peak, 1)
            let rms = sqrt(energy / Double(samples.count))
            XCTAssertGreaterThan(rms, 0.001, "The source clip must contain real sound before gain is applied")
            XCTAssertLessThan(rms, 0.9)
        }
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
        XCTAssertTrue(backend.play(sound: .rain, gain: 0))
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
