// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
@testable import FloeProviders

private actor DeepSeekFixtureHTTP: ASRHTTPTransport {
    let response: ASRHTTPResponse
    let wait: Bool
    private(set) var requests: [(URLRequest, Data)] = []
    init(_ response: ASRHTTPResponse = .init(statusCode: 200, body: Data(#"{"text":"hello","duration_ms":1000}"#.utf8)), wait: Bool = false) {
        self.response = response
        self.wait = wait
    }
    func perform(_ request: URLRequest, body: Data) async throws -> ASRHTTPResponse {
        requests.append((request, body))
        if wait { try await Task.sleep(for: .seconds(60)) }
        return response
    }
}

private final class DeepSeekAudioURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "Authorization")
        guard request.url == DeepSeekSpeechAPI.ttsURL, request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Content-Type") == "application/json", key?.hasPrefix("Bearer fixture-") == true else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        if key == "Bearer fixture-wait" { return }
        let audio = key == "Bearer fixture-empty" ? Data() : key == "Bearer fixture-odd"
            ? Data([1, 2, 3]) : Data([1, 2, 3, 4, 5, 6])
        let mime = key == "Bearer fixture-json" ? "application/json" : "application/octet-stream"
        let headers = ["Content-Type": mime, "Content-Length": String(key == "Bearer fixture-short" ? 28 : audio.count)]
        let response = HTTPURLResponse(url: DeepSeekSpeechAPI.ttsURL, statusCode: key == "Bearer fixture-quota" ? 429 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: audio)
        if key == "Bearer fixture-cut" { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class DeepSeekSpeechTests: XCTestCase, @unchecked Sendable {
    private func wav(seconds: Int = 1, rate: Int = 8_000, channels: Int = 1) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        let frames = seconds * rate, size = frames * channels * 2
        var data = Data("RIFF".utf8); data += le(UInt32(size + 36)); data += Data("WAVEfmt ".utf8)
        data += le(UInt32(16)); data += le(UInt16(1)); data += le(UInt16(channels)); data += le(UInt32(rate))
        data += le(UInt32(rate * channels * 2)); data += le(UInt16(channels * 2)); data += le(UInt16(16))
        data += Data("data".utf8); data += le(UInt32(size)); data += Data(repeating: 0, count: size)
        return data
    }

    private func asr(_ data: Data, profile: ASRProfile = .deepSeek()) -> ASRFileTranscriptionRequest {
        .init(profile: profile, audio: data, filename: "untrusted-title.mp3", mimeType: "audio/mpeg",
              languages: ["en"], sourceDurationSeconds: nil, streamsResponse: true, enableSpeakerAttribution: true)
    }

    func testRecognitionIsFileOnlyAndSendsOnlyTheVerifiedAudio() async throws {
        let profile = ASRProfile.deepSeek()
        XCTAssertTrue(try ASRAdapterFactory.fileAdapter(for: profile) is DeepSeekTranscriptionAdapter)
        XCTAssertNil(try ASRAdapterFactory.liveAdapter(for: profile))
        XCTAssertFalse(profile.fileCapabilities.supportsFileStreaming)
        let fixture = DeepSeekFixtureHTTP(), data = wav(rate: 24_000, channels: 2)
        let result = try await DeepSeekTranscriptionAdapter(transport: fixture).transcribe(asr(data), credential: "fixture-asr")
        XCTAssertEqual(result.text, "hello"); XCTAssertTrue(result.segments.isEmpty); XCTAssertEqual(result.timing, .sourceSpanOnly)
        let requests = await fixture.requests
        let (post, body) = try XCTUnwrap(requests.first)
        XCTAssertEqual(post.url, DeepSeekSpeechAPI.asrURL); XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-asr")
        let boundary = try XCTUnwrap(post.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last)
        let head = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        XCTAssertEqual(body, head + data + Data("\r\n--\(boundary)--\r\n".utf8))
    }

    func testSilentRecognitionChunkDoesNotFailARecording() async throws {
        let response = ASRHTTPResponse(statusCode: 200, body: Data(#"{"text":" ","duration_ms":1000}"#.utf8))
        let adapter = DeepSeekTranscriptionAdapter(transport: DeepSeekFixtureHTTP(response))
        let result = try await adapter.transcribe(asr(wav()), credential: "fixture-asr")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.timing, .sourceSpanOnly)
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testRecognitionRejectsWrongOriginFormatAndLimitsBeforeSending() async throws {
        let fixture = DeepSeekFixtureHTTP(), adapter = DeepSeekTranscriptionAdapter(transport: fixture)
        var wrong = ASRProfile.deepSeek(); wrong.fileEndpoint = "https://other.example/v1/tools/asr"
        var live = ASRProfile.deepSeek(); live.liveModelID = "stream"
        for request in [asr(wav(), profile: wrong), asr(wav(), profile: live), asr(wav(seconds: 121)),
                        asr(wav(rate: 12_000)), asr(Data(wav().dropLast())), asr(Data("ID3music".utf8)),
                        asr(Data(repeating: 0, count: DeepSeekSpeechAPI.maximumFileBytes + 1))] {
            do { _ = try await adapter.transcribe(request, credential: "fixture-asr"); XCTFail("expected invalid input") }
            catch let error as ASRTranscriptionError { guard case .invalidConfiguration = error else { XCTFail("\(error)"); continue } }
        }
        let calls = await fixture.requests.count; XCTAssertEqual(calls, 0)
        _ = try await adapter.transcribe(asr(wav(seconds: 120)), credential: "fixture-asr")
        let accepted = await fixture.requests.count; XCTAssertEqual(accepted, 1)
    }

    func testOggOpusUsesAudibleDurationAndRejectsTruncatedFiles() async throws {
        func page(_ payload: Data, flags: UInt8, sequence: UInt32, granule: UInt64) -> Data {
            var data = Data("OggS".utf8) + Data([0, flags])
            for value in [granule.littleEndian] { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
            data += Data([1, 0, 0, 0]); withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
            data += Data([0, 0, 0, 0, 1, UInt8(payload.count)]); data += payload; return data
        }
        let header = page(Data("OpusHead".utf8) + Data([1, 2, 56, 1, 128, 187, 0, 0, 0, 0, 0]), flags: 2, sequence: 0, granule: 0)
        let tags = page(Data("OpusTags".utf8) + Data(repeating: 0, count: 8), flags: 0, sequence: 1, granule: 0)
        let file = header + tags + page(Data([0xf8, 0xff, 0xfe]), flags: 4, sequence: 2, granule: 48_312)
        let fixture = DeepSeekFixtureHTTP(), adapter = DeepSeekTranscriptionAdapter(transport: fixture)
        _ = try await adapter.transcribe(asr(file), credential: "fixture-asr")
        let chain = try DeepSeekTranscriptionAdapter.inspectFile(file + file)
        XCTAssertEqual(chain.durationSeconds, 2, accuracy: 0.0001)
        XCTAssertThrowsError(try DeepSeekTranscriptionAdapter.inspectFile(
            header + tags + page(Data([0xf8, 0xff, 0xfe]), flags: 4, sequence: 4, granule: 48_312)))
        do { _ = try await adapter.transcribe(asr(Data(file.dropLast())), credential: "fixture-asr"); XCTFail("truncated Ogg") }
        catch let error as ASRTranscriptionError { guard case .invalidConfiguration = error else { return XCTFail("\(error)") } }
        let calls = await fixture.requests; XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(calls[0].1.range(of: Data("audio/ogg".utf8)))
    }

    func testRecognitionErrorsAndCancellation() async throws {
        for (response, expected) in [(ASRHTTPResponse(statusCode: 429, body: Data()), ASRTranscriptionError.quotaOrRateLimited),
                                      (.init(statusCode: 200, body: Data("{}".utf8)), .providerRejected),
                                      (.init(statusCode: 200, body: Data(), url: URL(string: "https://other.example")), .providerRejected)] {
            let adapter = DeepSeekTranscriptionAdapter(transport: DeepSeekFixtureHTTP(response))
            do { _ = try await adapter.transcribe(asr(wav()), credential: "fixture-asr"); XCTFail("unexpected success") }
            catch let error as ASRTranscriptionError { XCTAssertEqual(error, expected) }
        }
        let fixture = DeepSeekFixtureHTTP(wait: true), request = asr(wav())
        let task = Task { try await DeepSeekTranscriptionAdapter(transport: fixture).transcribe(request, credential: "fixture-asr") }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled recognition succeeded") } catch is CancellationError {}
    }

    private func tts(_ text: String = "你好", voice: String = "stella") -> TTSSynthesisRequest {
        .init(provider: .deepSeek, billingRoute: .payAsYouGo, modelID: "", voiceID: voice, text: text,
              speechRateRatio: 1.5, language: "ja")
    }
    private func service() -> TTSSpeechService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeepSeekAudioURLProtocol.self]
        return TTSSpeechService(session: URLSession(configuration: config))
    }

    func testSynthesisUsesOnlyOfficialFieldsAndEnforcesBothVoiceAndBillingLimits() throws {
        let router = service()
        XCTAssertTrue(router.provider(for: tts()) is DeepSeekSpeechAdapter)
        XCTAssertEqual(router.builtinVoices(for: .deepSeek).map(\.voiceID), ["stella", "tide"])
        for voice in ["stella", "tide"] {
            let fields = try JSONDecoder().decode([String: String].self, from: DeepSeekSpeechAdapter.body(for: tts(voice: voice)))
            XCTAssertEqual(fields, ["text": "你好", "voice_id": voice, "format": "pcm"])
        }
        XCTAssertNoThrow(try DeepSeekSpeechAdapter.body(for: tts(String(repeating: "字", count: 5_000))))
        XCTAssertThrowsError(try DeepSeekSpeechAdapter.body(for: tts(String(repeating: "字", count: 5_001))))
        // Tangut is ideographic but is not a Han character.
        XCTAssertNoThrow(try DeepSeekSpeechAdapter.body(for: tts(String(repeating: "𗀀", count: 10_000))))
        XCTAssertThrowsError(try DeepSeekSpeechAdapter.body(for: tts(" ", voice: "tide")))
        XCTAssertThrowsError(try DeepSeekSpeechAdapter.body(for: tts(voice: "unknown")))
    }

    func testSynthesisProducesOrdered24kPCMAndAFinalOnlyForCompleteAudio() async throws {
        let router = service()
        var frames = [TTSAudioChunk]()
        for try await chunk in router.synthesize(tts(), credential: "fixture-ok") { frames.append(chunk) }
        XCTAssertEqual(frames.map(\.sequence), Array(frames.indices))
        XCTAssertEqual(frames.map(\.sampleRate), [24_000, 24_000])
        XCTAssertEqual(frames.first?.pcm, Data([1, 2, 3, 4, 5, 6])); XCTAssertEqual(frames.last?.isFinal, true)
        for key in ["odd", "short", "empty", "cut", "json", "quota"] {
            var finished = false
            do {
                for try await chunk in router.synthesize(tts(), credential: "fixture-" + key) { finished = finished || chunk.isFinal }
                XCTFail("unexpected successful end for \(key)")
            } catch let error as TTSSynthesisError {
                if key == "quota" { XCTAssertEqual(error, .quotaOrRateLimited(provider: .deepSeek, route: .payAsYouGo, logID: nil)) }
            }
            XCTAssertFalse(finished)
        }
    }

    func testSynthesisCancellationTerminatesTheConsumer() async throws {
        let stream = service().synthesize(tts(), credential: "fixture-wait")
        let task = Task { for try await _ in stream {} }
        task.cancel()
        do { try await task.value; XCTFail("cancelled synthesis succeeded") }
        catch let error as TTSSynthesisError { XCTAssertEqual(error, .cancelled) }
    }
}
