import Foundation
import Testing

@testable import VideoEditorKit

@Suite("OpenAIWhisperTranscriptionComponentTests")
struct OpenAIWhisperTranscriptionComponentTests {

    // MARK: - Public Methods

    @Test
    func transcribeVideoTransitionsFromLoadingToLoadedAndCleansTheExtractedAudio() async throws {
        let cleanupRecorder = CleanupRecorder()
        let requestProbe = RequestProbe()
        let extractedAudioURL = URL(fileURLWithPath: "/tmp/openai-whisper-component-audio.m4a")
        let component = OpenAIWhisperTranscriptionComponent(
            dependencies: .init(
                extractAudio: { _ in extractedAudioURL },
                removeExtractedAudio: { cleanupRecorder.remove($0) },
                createTranscription: { request in
                    await requestProbe.record(request)
                    await requestProbe.waitForResume()
                    return WhisperVerboseTranscriptionResponseDTO(
                        text: "ola mundo",
                        segments: [
                            .init(id: 0, start: 0, end: 2, text: "ola mundo")
                        ],
                        words: [
                            .init(start: 0, end: 0.8, word: "ola"),
                            .init(start: 1, end: 2, word: "mundo"),
                        ]
                    )
                },
                mapResponse: { response in
                    OpenAIWhisperResponseMapper().map(response)
                }
            )
        )

        let transcriptionTask = Task {
            try await component.transcribeVideo(
                input: .init(
                    assetIdentifier: "asset-id",
                    source: .fileURL(URL(fileURLWithPath: "/tmp/source.mov")),
                    preferredLocale: "pt-BR"
                )
            )
        }

        await waitForState(of: component, equals: .loading)

        let capturedRequest = try #require(await requestProbe.lastRequest())
        #expect(capturedRequest.audioFileURL == extractedAudioURL)
        #expect(capturedRequest.language == "pt-BR")
        #expect(capturedRequest.model == "whisper-1")
        #expect(capturedRequest.responseFormat == "verbose_json")
        #expect(capturedRequest.timestampGranularities == ["segment", "word"])

        await requestProbe.resume()

        let result = try await transcriptionTask.value

        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "ola mundo")
        #expect(result.segments[0].words.map(\.text) == ["ola", "mundo"])
        #expect(await component.state == .loaded)
        #expect(cleanupRecorder.urls == [extractedAudioURL])
    }

    @Test
    func transcribeVideoTransitionsToFailedWhenTheClientFailsAndCleansTheExtractedAudio() async {
        let cleanupRecorder = CleanupRecorder()
        let extractedAudioURL = URL(fileURLWithPath: "/tmp/openai-whisper-component-failure-audio.m4a")
        let component = OpenAIWhisperTranscriptionComponent(
            dependencies: .init(
                extractAudio: { _ in extractedAudioURL },
                removeExtractedAudio: { cleanupRecorder.remove($0) },
                createTranscription: { _ in
                    throw OpenAIWhisperAPIClient.ClientError.unsuccessfulStatusCode(
                        401,
                        "invalid api key"
                    )
                },
                mapResponse: { response in
                    OpenAIWhisperResponseMapper().map(response)
                }
            )
        )

        do {
            _ = try await component.transcribeVideo(
                input: .init(
                    assetIdentifier: "asset-id",
                    source: .fileURL(URL(fileURLWithPath: "/tmp/source.mov")),
                    preferredLocale: "pt-BR"
                )
            )
            Issue.record("Expected the component to fail when the client returns an HTTP error.")
        } catch let error as TranscriptError {
            #expect(error == .providerFailure(message: "invalid api key"))
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(await component.state == .failed(.providerFailure(message: "invalid api key")))
        #expect(cleanupRecorder.urls == [extractedAudioURL])
    }

    @Test
    func cancelCurrentTranscriptionCancelsTheInFlightOperationAndCleansTheExtractedAudio() async {
        let cleanupRecorder = CleanupRecorder()
        let startProbe = StartProbe()
        let extractedAudioURL = URL(fileURLWithPath: "/tmp/openai-whisper-component-cancel-audio.m4a")
        let component = OpenAIWhisperTranscriptionComponent(
            dependencies: .init(
                extractAudio: { _ in extractedAudioURL },
                removeExtractedAudio: { cleanupRecorder.remove($0) },
                createTranscription: { _ in
                    await startProbe.markStarted()
                    try await Task.sleep(for: .seconds(60))
                    return WhisperVerboseTranscriptionResponseDTO(text: "never finishes")
                },
                mapResponse: { response in
                    OpenAIWhisperResponseMapper().map(response)
                }
            )
        )

        let transcriptionTask = Task {
            try await component.transcribeVideo(
                input: .init(
                    assetIdentifier: "asset-id",
                    source: .fileURL(URL(fileURLWithPath: "/tmp/source.mov")),
                    preferredLocale: nil
                )
            )
        }

        await waitForState(of: component, equals: .loading)
        await startProbe.waitUntilStarted()
        await component.cancelCurrentTranscription()

        do {
            _ = try await transcriptionTask.value
            Issue.record("Expected the transcription task to be cancelled.")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(await component.state == .failed(.cancelled))
        #expect(cleanupRecorder.urls == [extractedAudioURL])
    }

    @Test
    func transcribeVideoFailsWithInvalidVideoSourceForRemoteURLs() async {
        guard let remoteVideoURL = URL(string: "https://example.com/video.mov") else {
            Issue.record("Expected the non-file video URL fixture to be valid.")
            return
        }

        let component = OpenAIWhisperTranscriptionComponent(
            dependencies: .init(
                extractAudio: { _ in
                    Issue.record("The extractor should not be called for an invalid source.")
                    return URL(fileURLWithPath: "/tmp/unreachable.m4a")
                },
                removeExtractedAudio: { _ in },
                createTranscription: { _ in
                    Issue.record("The API client should not be called for an invalid source.")
                    return WhisperVerboseTranscriptionResponseDTO(text: "")
                },
                mapResponse: { _ in
                    VideoTranscriptionResult()
                }
            )
        )

        do {
            _ = try await component.transcribeVideo(
                input: .init(
                    assetIdentifier: "asset-id",
                    source: .fileURL(remoteVideoURL),
                    preferredLocale: nil
                )
            )
            Issue.record("Expected the component to reject a non-file video URL.")
        } catch let error as TranscriptError {
            #expect(error == .invalidVideoSource)
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(await component.state == .failed(.invalidVideoSource))
    }

    // MARK: - Private Methods

    private func waitForState(
        of component: OpenAIWhisperTranscriptionComponent,
        equals expectedState: TranscriptFeatureState
    ) async {
        for _ in 0..<50 {
            if await component.state == expectedState {
                return
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        Issue.record("Timed out waiting for component state \(expectedState).")
    }

}

private final class CleanupRecorder: @unchecked Sendable {

    // MARK: - Private Properties

    private let lock = NSLock()
    private var recordedURLs = [URL]()

    // MARK: - Public Properties

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    // MARK: - Public Methods

    func remove(_ url: URL) {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }

}

private actor RequestProbe {

    // MARK: - Private Properties

    private var requests = [OpenAIWhisperAPIClient.Request]()
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasResumed = false

    // MARK: - Public Methods

    func record(_ request: OpenAIWhisperAPIClient.Request) {
        requests.append(request)
    }

    func waitForResume() async {
        guard hasResumed == false else { return }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        hasResumed = true
        continuation?.resume()
        continuation = nil
    }

    func lastRequest() -> OpenAIWhisperAPIClient.Request? {
        requests.last
    }

}

private actor StartProbe {

    // MARK: - Private Properties

    private var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    // MARK: - Public Methods

    func markStarted() {
        hasStarted = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilStarted() async {
        guard hasStarted == false else { return }

        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

}
