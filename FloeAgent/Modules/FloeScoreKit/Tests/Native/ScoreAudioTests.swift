// SPDX-License-Identifier: MPL-2.0
import AVFoundation
import Foundation
import Testing
import FloeHeavyEditorSupport
@testable import FloeScoreKit

private actor StopCounter { var count = 0; func increment() { count += 1 } }
struct ScoreAudioTests {
    private func performance(pitch: Double = 69) -> EditorJSON {
        .object(["format": .string("floe.score.performance/1"), "duration": .number(1),
            "events": .array([.object(["start": .number(0), "duration": .number(0.8),
                "pitch": .number(pitch), "velocity": .number(100), "volume": .number(1),
                "program": .number(0), "percussion": .bool(false)])])])
    }
    @Test func generatedWAVDecodesAndContainsTunedAudio() throws {
        let data = try ScoreReferenceAudio.renderWAV(performance())
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeScoreAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("A4-reference.wav")
        try data.write(to: url)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 22_050)
        #expect(file.length >= 22_050)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let from = 4_410, to = 15_435
        var zeroCrossings = 0
        var energy: Double = 0
        for index in from..<to {
            energy += Double(samples[index] * samples[index])
            if index > from, samples[index - 1] < 0, samples[index] >= 0 { zeroCrossings += 1 }
        }
        let estimatedHz = Double(zeroCrossings) / (Double(to - from) / 22_050)
        #expect(estimatedHz > 436 && estimatedHz < 444)
        #expect(energy / Double(to - from) > 0.001)
    }
    @Test func invalidEventCannotAllocateOrSynthesize() throws {
        #expect(throws: (any Error).self) { try ScoreReferenceAudio.renderWAV(performance(pitch: 999)) }
        #expect(throws: (any Error).self) {
            try ScoreReferenceAudio.renderWAV(.object(["format": .string("floe.score.performance/1"), "duration": .number(901), "events": .array([])]))
        }
    }
    @Test func playbackAdapterOnlyExposesFixedOperation() async throws {
        let adapter = ScorePlaybackAdapter(transport: { value in value })
        #expect(adapter.nativeExtension.operations == ["score.transport"])
        let result = try await adapter.nativeExtension.run("score.transport", .object(["action": .string("status")]))
        #expect(result["action"].string == "status")
        await #expect(throws: (any Error).self) { try await adapter.nativeExtension.run("arbitrary.operation", .null) }
    }
    @Test func cancellationAndClosingStopOnlyTheInjectedOwner() async throws {
        let counter = StopCounter()
        let adapter = ScorePlaybackAdapter(transport: { _ in .null }, stop: { await counter.increment() })
        await adapter.nativeExtension.cancel?("score.playback.control")
        await adapter.nativeExtension.presentationClosed?()
        #expect(await counter.count == 2)
    }

}
