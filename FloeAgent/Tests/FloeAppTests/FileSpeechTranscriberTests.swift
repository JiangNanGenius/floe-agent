// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation
import AVFoundation
import Testing
@testable import FloeApp

/// Real file reader, chunk loop and runtime lease; no microphone, model
/// weights, Apple Speech authorization or cloud provider is used.
@Suite("Enhanced file speech no-speech handling", .serialized)
struct FileSpeechTranscriberTests {
    private enum Step: Sendable { case empty, words(String), decoderFailure }
    private enum ModelFailure: Error, Sendable { case decoder, unexpectedDecode }
    private struct ModelStats: Sendable {
        let sampleCounts: [Int]
        let energies: [Float]
        let unmounts: Int
    }

    private actor Model: SpeechRecognitionModelInstance {
        nonisolated let identity = "file-speech-scripted-model"
        private var steps: [Step]
        private var sampleCounts: [Int] = []
        private var energies: [Float] = []
        private var unmounts = 0
        init(_ steps: [Step]) { self.steps = steps }

        func transcribe(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [String] {
            throw ModelFailure.unexpectedDecode
        }

        func transcribeTimed(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [SpeechRecognitionTimedSegment] {
            try Task.checkCancellation()
            sampleCounts.append(audio.count)
            energies.append(audio.reduce(0) { $0 + $1 * $1 } / Float(max(1, audio.count)))
            guard !steps.isEmpty else { throw ModelFailure.unexpectedDecode }
            switch steps.removeFirst() {
            case .empty: return []
            case .decoderFailure: throw ModelFailure.decoder
            case .words(let text):
                return [.init(start: 0.2, end: 0.8, text: text,
                    words: [.init(start: 0.2, end: 0.8, text: text)])]
            }
        }

        func unmount() async { unmounts += 1 }
        func stats() -> ModelStats { .init(sampleCounts: sampleCounts, energies: energies, unmounts: unmounts) }
    }

    private actor Loader {
        let model: Model
        private var loads = 0
        private var releases = 0
        init(model: Model) { self.model = model }
        func load() -> SpeechRecognitionRuntime.Loaded {
            loads += 1
            return .init(model: model, leaseID: UUID())
        }
        func release() { releases += 1 }
        func stats() -> (loads: Int, releases: Int) { (loads, releases) }
    }

    private struct Fixture: Sendable {
        let model: Model
        let loader: Loader
        let runtime: SpeechRecognitionRuntime
        let transcriber: FileSpeechTranscriber
    }

    private func fixture(_ steps: [Step]) -> Fixture {
        let model = Model(steps), loader = Loader(model: model)
        let runtime = SpeechRecognitionRuntime(dependencies: .init(
            installedIdentity: { model.identity }, load: { await loader.load() },
            releaseLease: { _ in await loader.release() }, installResidencyHook: { _ in }))
        return Fixture(model: model, loader: loader, runtime: runtime,
                       transcriber: FileSpeechTranscriber(runtime: runtime))
    }

    /// Energetic synthetic PCM deliberately passes the production energy
    /// gate. A silent fixture would skip the model and miss this regression.
    private func audio(seconds: Int) throws -> (root: URL, url: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileSpeech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("synthetic.wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            let count = seconds * 16_000
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<count {
                samples[index] = Float(sin(Double(index) * .pi * 2 * 220 / 16_000)) * 0.2
            }
            try file.write(from: buffer)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return (root, url)
    }

    @Test func energeticNoSpeechEndsEmptyAndNextFileReusesHealthyEnhancedLease() async throws {
        let input = try audio(seconds: 1)
        defer { try? FileManager.default.removeItem(at: input.root) }
        let f = fixture([.empty, .words("next file")])
        do {
            _ = try await f.transcriber.transcribeResult(url: input.url, language: .english, allowAppleFallback: false)
            Issue.record("An entirely wordless file must report FileSpeechError.empty.")
        } catch let error as FileSpeechError {
            guard case .empty = error else { Issue.record("No-speech was reported as \(String(describing: error))."); return }
        }
        let first = await f.model.stats()
        #expect(first.sampleCounts == [16_000])
        #expect(first.energies.allSatisfy { $0 >= 0.000_01 })
        #expect(first.unmounts == 0)
        let next = try await f.transcriber.transcribeResult(url: input.url, language: .english, allowAppleFallback: false)
        #expect(next.engine == .enhanced)
        #expect(next.segments.map(\.text) == ["next file"])
        let residency = await f.loader.stats()
        #expect(residency.loads == 1 && residency.releases == 0)
        let reused = await f.model.stats()
        #expect(reused.unmounts == 0)
        await f.runtime.setForeground(false)
    }

    @Test func emptyEnhancedWindowContinuesToLaterWordsOnTheSameEngine() async throws {
        let input = try audio(seconds: 26)
        defer { try? FileManager.default.removeItem(at: input.root) }
        let f = fixture([.empty, .words("later window")])
        let result = try await f.transcriber.transcribeResult(url: input.url, language: .english, allowAppleFallback: false)
        #expect(result.engine == .enhanced)
        let segment = try #require(result.segments.first)
        #expect(result.segments.count == 1 && segment.text == "later window")
        #expect(abs(segment.start - 25.2) < 0.000_001 && abs(segment.end - 25.8) < 0.000_001)
        let word = try #require(segment.words.first)
        #expect(segment.words.count == 1 && abs(word.start - 25.2) < 0.000_001)
        let stats = await f.model.stats()
        #expect(stats.sampleCounts == [400_000, 16_000])
        #expect(stats.energies.allSatisfy { $0 >= 0.000_01 })
        #expect(stats.unmounts == 0)
        await f.runtime.setForeground(false)
    }

    @Test func emptyEnhancedTailPreservesPreviouslyRecognizedWordsAndTiming() async throws {
        let input = try audio(seconds: 26)
        defer { try? FileManager.default.removeItem(at: input.root) }
        let f = fixture([.words("first window"), .empty])
        let result = try await f.transcriber.transcribeResult(url: input.url, language: .english, allowAppleFallback: false)
        #expect(result.engine == .enhanced)
        let segment = try #require(result.segments.first)
        #expect(result.segments.count == 1 && segment.text == "first window")
        #expect(abs(segment.start - 0.2) < 0.000_001 && abs(segment.end - 0.8) < 0.000_001)
        let word = try #require(segment.words.first)
        #expect(word.text == "first window" && abs(word.start - 0.2) < 0.000_001)
        let stats = await f.model.stats()
        #expect(stats.sampleCounts == [400_000, 16_000])
        #expect(stats.energies.allSatisfy { $0 >= 0.000_01 })
        #expect(stats.unmounts == 0)
        await f.runtime.setForeground(false)
    }

    @Test func realEnhancedDecoderErrorStillFailsAndRetiresTheLease() async throws {
        let input = try audio(seconds: 26)
        defer { try? FileManager.default.removeItem(at: input.root) }
        let f = fixture([.words("before failure"), .decoderFailure])
        do {
            _ = try await f.transcriber.transcribeResult(url: input.url, language: .english, allowAppleFallback: false)
            Issue.record("A real decoder error must not become an empty successful result.")
        } catch let error as FileSpeechError {
            guard case .unavailable = error else { Issue.record("Decoder failure was reported as \(String(describing: error))."); return }
        }
        let stats = await f.model.stats(), residency = await f.loader.stats()
        #expect(stats.sampleCounts == [400_000, 16_000])
        #expect(stats.energies.allSatisfy { $0 >= 0.000_01 })
        #expect(stats.unmounts == 1)
        #expect(residency.loads == 1 && residency.releases == 1)
        await f.runtime.setForeground(false)
    }
}
#endif
