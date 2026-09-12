import Foundation
import Testing

@testable import VideoEditorKit

@Suite("OpenAIWhisperAPIClientTests")
struct OpenAIWhisperAPIClientTests {

    // MARK: - Public Methods

    @Test
    func createTranscriptionSendsMultipartRequestAndDecodesVerboseJSON() async throws {
        let audioURL = try TestFixtures.createTemporaryAudio()
        let endpoint = try #require(URL(string: "https://api.openai.com/v1/audio/transcriptions"))
        let session = RecordingHTTPSession(
            result: .success(
                (
                    Data(
                        """
                        {
                          "task": "transcribe",
                          "language": "portuguese",
                          "duration": 1.2,
                          "text": "ola mundo",
                          "segments": [
                            { "id": 0, "start": 0.0, "end": 0.8, "text": " ola mundo" }
                          ],
                          "words": [
                            { "start": 0.0, "end": 0.3, "word": "ola" },
                            { "start": 0.4, "end": 0.8, "word": "mundo" }
                          ]
                        }
                        """.utf8
                    ),
                    try #require(
                        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                    )
                )
            )
        )
        let builder = OpenAIWhisperMultipartFormDataBuilder("Boundary-Test")
        let client = OpenAIWhisperAPIClient(
            apiKey: "test-key",
            session: session,
            endpoint: endpoint,
            multipartBuilder: builder
        )

        defer { FileManager.default.removeIfExists(for: audioURL) }

        let response = try await client.createTranscription(
            request: .init(
                audioFileURL: audioURL,
                language: "pt-BR"
            )
        )

        let capturedRequest = try #require(await session.recordedRequest())
        let authorizationHeader = try #require(capturedRequest.value(forHTTPHeaderField: "Authorization"))
        let contentTypeHeader = try #require(capturedRequest.value(forHTTPHeaderField: "Content-Type"))
        let requestBody = try #require(capturedRequest.httpBody)

        #expect(capturedRequest.httpMethod == "POST")
        #expect(capturedRequest.url == endpoint)
        #expect(authorizationHeader == "Bearer test-key")
        #expect(contentTypeHeader == builder.contentTypeHeaderValue)
        #expect(body(requestBody, contains: "name=\"model\""))
        #expect(body(requestBody, contains: "whisper-1"))
        #expect(body(requestBody, contains: "name=\"response_format\""))
        #expect(body(requestBody, contains: "verbose_json"))
        #expect(body(requestBody, contains: "name=\"language\""))
        #expect(body(requestBody, contains: "pt"))
        #expect(body(requestBody, contains: "pt-BR") == false)
        #expect(body(requestBody, contains: "name=\"timestamp_granularities[]\""))
        #expect(body(requestBody, contains: "segment"))
        #expect(body(requestBody, contains: "word"))
        #expect(body(requestBody, contains: "filename=\"\(audioURL.lastPathComponent)\""))

        #expect(response.text == "ola mundo")
        #expect(response.segments.count == 1)
        #expect(response.words.count == 2)
        #expect(response.segments.first?.start == 0)
        #expect(response.words.last?.word == "mundo")
    }

    @Test
    func createTranscriptionOmitsLanguageWhenNotProvided() async throws {
        let audioURL = try TestFixtures.createTemporaryAudio()
        let endpoint = try #require(URL(string: "https://api.openai.com/v1/audio/transcriptions"))
        let session = RecordingHTTPSession(
            result: .success(
                (
                    Data(#"{"text":"hello","segments":[],"words":[]}"#.utf8),
                    try #require(
                        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                    )
                )
            )
        )
        let client = OpenAIWhisperAPIClient(
            apiKey: "test-key",
            session: session,
            endpoint: endpoint
        )

        defer { FileManager.default.removeIfExists(for: audioURL) }

        _ = try await client.createTranscription(
            request: .init(
                audioFileURL: audioURL,
                language: nil
            )
        )

        let capturedRequest = try #require(await session.recordedRequest())
        let requestBody = try #require(capturedRequest.httpBody)

        #expect(body(requestBody, contains: "name=\"language\"") == false)
    }

    @Test
    func createTranscriptionNormalizesThreeLetterLanguageCodesToISO6391() async throws {
        let audioURL = try TestFixtures.createTemporaryAudio()
        let endpoint = try #require(URL(string: "https://api.openai.com/v1/audio/transcriptions"))
        let session = RecordingHTTPSession(
            result: .success(
                (
                    Data(#"{"text":"hello","segments":[],"words":[]}"#.utf8),
                    try #require(
                        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                    )
                )
            )
        )
        let client = OpenAIWhisperAPIClient(
            apiKey: "test-key",
            session: session,
            endpoint: endpoint
        )

        defer { FileManager.default.removeIfExists(for: audioURL) }

        _ = try await client.createTranscription(
            request: .init(
                audioFileURL: audioURL,
                language: "eng-br"
            )
        )

        let capturedRequest = try #require(await session.recordedRequest())
        let requestBody = try #require(capturedRequest.httpBody)

        #expect(body(requestBody, contains: "name=\"language\""))
        #expect(body(requestBody, contains: "en"))
        #expect(body(requestBody, contains: "eng-br") == false)
    }

    @Test
    func createTranscriptionOmitsInvalidLanguageCodesInsteadOfSendingAnUnsupportedValue() async throws {
        let audioURL = try TestFixtures.createTemporaryAudio()
        let endpoint = try #require(URL(string: "https://api.openai.com/v1/audio/transcriptions"))
        let session = RecordingHTTPSession(
            result: .success(
                (
                    Data(#"{"text":"hello","segments":[],"words":[]}"#.utf8),
                    try #require(
                        HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)
                    )
                )
            )
        )
        let client = OpenAIWhisperAPIClient(
            apiKey: "test-key",
            session: session,
            endpoint: endpoint
        )

        defer { FileManager.default.removeIfExists(for: audioURL) }

        _ = try await client.createTranscription(
            request: .init(
                audioFileURL: audioURL,
                language: "invalid-language"
            )
        )

        let capturedRequest = try #require(await session.recordedRequest())
        let requestBody = try #require(capturedRequest.httpBody)

        #expect(body(requestBody, contains: "name=\"language\"") == false)
        #expect(body(requestBody, contains: "invalid-language") == false)
    }

    @Test
    func createTranscriptionFailsForNonSuccessStatusCodes() async throws {
        let audioURL = try TestFixtures.createTemporaryAudio()
        let endpoint = try #require(URL(string: "https://api.openai.com/v1/audio/transcriptions"))
        let session = RecordingHTTPSession(
            result: .success(
                (
                    Data(#"{"error":{"message":"invalid api key"}}"#.utf8),
                    try #require(
                        HTTPURLResponse(url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil)
                    )
                )
            )
        )
        let client = OpenAIWhisperAPIClient(
            apiKey: "bad-key",
            session: session,
            endpoint: endpoint
        )

        defer { FileManager.default.removeIfExists(for: audioURL) }

        do {
            _ = try await client.createTranscription(request: .init(audioFileURL: audioURL))
            Issue.record("Expected the client to fail for a non-success HTTP response.")
        } catch let error as OpenAIWhisperAPIClient.ClientError {
            #expect(error == .unsuccessfulStatusCode(401, "invalid api key"))
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test
    func createTranscriptionRejectsNonFileAudioURLs() async {
        guard let remoteAudioURL = URL(string: "https://example.com/audio.m4a") else {
            Issue.record("Expected the non-file audio URL fixture to be valid.")
            return
        }

        let session = RecordingHTTPSession(
            result: .failure(CocoaError(.fileNoSuchFile))
        )
        let client = OpenAIWhisperAPIClient(
            apiKey: "test-key",
            session: session
        )

        do {
            _ = try await client.createTranscription(
                request: .init(
                    audioFileURL: remoteAudioURL
                )
            )
            Issue.record("Expected the client to reject non-file audio URLs.")
        } catch let error as OpenAIWhisperAPIClient.ClientError {
            #expect(error == .invalidAudioFileURL)
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Methods

    private func body(_ data: Data, contains snippet: String) -> Bool {
        data.range(of: Data(snippet.utf8)) != nil
    }

}

private actor RecordingHTTPSession: HTTPSession {

    // MARK: - Private Properties

    private let result: Result<(Data, URLResponse), Error>
    private var requests = [URLRequest]()

    // MARK: - Initializer

    init(result: Result<(Data, URLResponse), Error>) {
        self.result = result
    }

    // MARK: - Public Methods

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try result.get()
    }

    func recordedRequest() -> URLRequest? {
        requests.last
    }

}
