// SPDX-License-Identifier: MPL-2.0
import XCTest
import AVFoundation
import CryptoKit
@preconcurrency import WhisperKit
@testable import FloeNotesNativeQualification

/// Separate opt-in scheme: downloads the pinned small multilingual model and performs real inference.
/// Generated speech is a reproducible pipeline check, not a claim about human mixed-language accuracy.
@MainActor final class WhisperInferenceTests: XCTestCase {
    func testPinnedWhisperTranscribesBilingualFixtureWithoutAppleFallback() async throws {
        let started = Date()
        try await WhisperModelStore.shared.install { completed, total in
            print("Whisper verified download: \(completed)/\(total) bytes")
        }
        let (lease, folder) = try await WhisperModelStore.shared.acquire()
        var kit: WhisperKit?
        do {
            let loadedAt = Date()
            let runtime = try await WhisperKit(WhisperKitConfig(modelFolder: folder.appendingPathComponent("model").path,
                tokenizerFolder: folder.appendingPathComponent("tokenizer"), verbose: false, prewarm: false, load: true, download: false))
            kit = runtime
            let loadSeconds = Date().timeIntervalSince(loadedAt)
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mixed-zh-en", withExtension: "wav"))
            let bytes = try Data(contentsOf: url)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            XCTAssertLessThanOrEqual(duration, 25)
            let samples = try SpeechAudioChunk.read(asset: asset, track: track, start: 0, duration: duration)
            let inferenceAt = Date()
            let result = try await runtime.transcribe(audioArray: samples, decodeOptions: DecodingOptions(
                detectLanguage: true, skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true))
            let inferenceSeconds = Date().timeIntervalSince(inferenceAt)
            let segments = result.flatMap(\.segments)
            let text = segments.map(\.text).joined(separator: " ")
            let normalized = text.lowercased().replacingOccurrences(of: " ", with: "")
            XCTAssertFalse(segments.isEmpty)
            XCTAssertTrue(normalized.contains("opportunitycost"), text)
            XCTAssertTrue(normalized.contains("机会成本") || normalized.contains("機會成本"), text)
            XCTAssertTrue(normalized.contains("internationaltrade"), text)
            XCTAssertTrue(segments.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && Double($0.end) <= duration + 1 })
            let evidence: [String: Any] = [
                "fixture": "Apple system synthesized Mandarin-English, not human speech",
                "fixtureSHA256": hash, "audioSeconds": duration, "loadSeconds": loadSeconds,
                "inferenceSeconds": inferenceSeconds, "totalSeconds": Date().timeIntervalSince(started),
                "transcript": text, "segmentCount": segments.count, "backend": "WhisperKit direct, no Apple fallback",
                "platform": ProcessInfo.processInfo.operatingSystemVersionString,
                "memoryEvidence": "Peak memory not measured by this test; real-device profiling remains required"
            ]
            let report = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            report.name = "Whisper bilingual inference evidence"; report.lifetime = .keepAlways; add(report)
            await runtime.unloadModels(); kit = nil
            await WhisperModelStore.shared.release(lease)
        } catch {
            if let kit { await kit.unloadModels() }
            await WhisperModelStore.shared.release(lease)
            throw error
        }
    }
}
