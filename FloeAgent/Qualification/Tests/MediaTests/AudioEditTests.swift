import Foundation
import Testing
import AVFoundation
import FloeCore
import FloeTools
import FloeMedia

@Suite("Bounded audio editing")
struct AudioEditTests {
    private func writeAudio(_ url: URL, frames: Int = 96000, channels: UInt32 = 1, value: Float = 0.4, tailOnly: Bool = false) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192))
        var offset = 0
        while offset < frames {
            buffer.frameLength = UInt32(min(8192, frames - offset))
            for channel in 0..<Int(channels) {
                for index in 0..<Int(buffer.frameLength) {
                    buffer.floatChannelData![channel][index] = tailOnly && offset + index < frames - 4800 ? 0 : value
                }
            }
            try file.write(from: buffer); offset += Int(buffer.frameLength)
        }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func trimFadesAndBothMixGainsReachRealSamples() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try writeAudio(root.appendingPathComponent("input.wav"))
        try writeAudio(root.appendingPathComponent("mix.wav"), value: 0.2)
        let original = try FloeDigest.sha256Hex(ofFileAt: root.appendingPathComponent("input.wav"))
        let engine = AudioEngine(rootProvider: { root })
        _ = try await engine.edit(path: "input.wav", outputPath: "out.wav", operations: ["start":0.25,"end":0.75,"gain":0.5,"mixGain":0.25,"fadeIn":0.1], fadeOutSeconds: 0.1, mixPath: "mix.wav")
        let output = try AVAudioFile(forReading: root.appendingPathComponent("out.wav"))
        #expect(output.length == 24000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 24000))
        try output.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect(abs(samples[0] - 0.05) < 0.001)
        #expect(abs(samples[12000] - 0.25) < 0.001)
        #expect(abs(samples[23999] - 0.05) < 0.001)
        #expect(try FloeDigest.sha256Hex(ofFileAt: root.appendingPathComponent("input.wav")) == original)
    }

    @Test func invalidEditsPreserveFilesAndStayInsideWorkspace() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try writeAudio(root.appendingPathComponent("input.wav"))
        try writeAudio(root.appendingPathComponent("stereo.wav"), channels: 2)
        let original = try Data(contentsOf: root.appendingPathComponent("input.wav"))
        let engine = AudioEngine(rootProvider: { root })
        await #expect(throws: (any Error).self) { try await engine.edit(path: "input.wav", outputPath: "input.wav", operations: [:], fadeOutSeconds: nil, mixPath: nil) }
        await #expect(throws: (any Error).self) { try await engine.edit(path: "input.wav", outputPath: "../escaped.wav", operations: [:], fadeOutSeconds: nil, mixPath: nil) }
        await #expect(throws: (any Error).self) { try await engine.edit(path: "input.wav", outputPath: "out.wav", operations: ["gain":.nan], fadeOutSeconds: nil, mixPath: nil) }
        await #expect(throws: (any Error).self) { try await engine.edit(path: "input.wav", outputPath: "out.wav", operations: [:], fadeOutSeconds: nil, mixPath: "stereo.wav") }
        #expect(try Data(contentsOf: root.appendingPathComponent("input.wav")) == original)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out.wav").path))
    }

    @Test func fullFileInspectionAndRunningCancellationAreBounded() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        try writeAudio(root.appendingPathComponent("long.wav"), frames: 10010000, value: 0.5, tailOnly: true)
        let engine = AudioEngine(rootProvider: { root })
        let info = try await engine.inspect(path: "long.wav")
        #expect(abs(info.peak - 0.5) < 0.001)
        #expect(info.rms > 0)
        let retained = Data("existing output".utf8)
        try retained.write(to: root.appendingPathComponent("out.wav"))
        let token = CancellationToken()
        let task = Task.detached { try await engine.edit(path: "long.wav", outputPath: "out.wav", operations: [:], fadeOutSeconds: nil, mixPath: nil, cancellation: token) }
        let deadline = Date().addingTimeInterval(5)
        var started = false
        while Date() < deadline {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".floe-audio-edit-") }) { started = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        token.cancel()
        #expect(started)
        do { _ = try await task.value; Issue.record("Running audio edit ignored cancellation") }
        catch FloeError.cancelled {} catch { Issue.record("Unexpected audio error: \(error)") }
        #expect(try Data(contentsOf: root.appendingPathComponent("out.wav")) == retained)
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".floe-audio-edit-") }))
    }
}
