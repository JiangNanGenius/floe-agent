import Foundation
import Testing

@testable import VideoEditorKit

@MainActor
@Suite("EditorViewModelWhisperIntegrationTests", .serialized)
struct EditorViewModelWhisperIntegrationTests {

    // MARK: - Public Methods

    @Test
    func transcribeCurrentVideoWithTheOpenAIWhisperComponentMapsTheResponseIntoATranscriptDraft()
        async throws
    {
        let cleanupRecorder = TranscriptionCleanupRecorder()
        let requestProbe = OpenAIWhisperEditorRequestProbe()
        let extractedAudioURL = URL(fileURLWithPath: "/tmp/editor-openai-whisper-success.m4a")
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
                            .init(id: 0, start: 8, end: 12, text: "ola mundo")
                        ],
                        words: [
                            .init(start: 8, end: 9, word: "ola"),
                            .init(start: 10, end: 12, word: "mundo"),
                        ]
                    )
                },
                mapResponse: { response in
                    OpenAIWhisperResponseMapper().map(response)
                }
            )
        )
        let viewModel = EditorViewModel()
        var video = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )
        video.updateRate(2)
        viewModel.currentVideo = video
        viewModel.configureTranscription(
            provider: component,
            preferredLocale: "pt-BR"
        )

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptState(on: viewModel, equals: .loading)

        let capturedRequest = try #require(await requestProbe.lastRequest())
        #expect(capturedRequest.audioFileURL == extractedAudioURL)
        #expect(capturedRequest.language == "pt-BR")
        #expect(capturedRequest.model == "whisper-1")
        #expect(viewModel.transcriptState == .loading)

        await requestProbe.resume()
        await waitForTranscriptState(on: viewModel, equals: .loaded)

        #expect(await component.state == .loaded)
        #expect(cleanupRecorder.urls == [extractedAudioURL])
        #expect(viewModel.transcriptState == .loaded)
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptDocument == nil)
        #expect(viewModel.transcriptDraftDocument?.segments.first?.originalText == "ola mundo")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.editedText == "ola mundo")
        #expect(viewModel.transcriptDraftDocument?.segments.first?.timeMapping.timelineRange == 4...6)
        #expect(viewModel.transcriptDraftDocument?.segments.first?.words.map(\.editedText) == ["ola", "mundo"])

        viewModel.applyTranscriptChanges()

        #expect(viewModel.transcriptFeatureState == .loaded)
        #expect(viewModel.transcriptDocument == viewModel.transcriptDraftDocument)
    }

    @Test
    func transcribeCurrentVideoWithTheOpenAIWhisperComponentPropagatesProviderFailuresToTheEditorState()
        async
    {
        let cleanupRecorder = TranscriptionCleanupRecorder()
        let extractedAudioURL = URL(fileURLWithPath: "/tmp/editor-openai-whisper-failure.m4a")
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
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )
        viewModel.configureTranscription(
            provider: component,
            preferredLocale: "pt-BR"
        )

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptFailure(on: viewModel)

        #expect(await component.state == .failed(.providerFailure(message: "invalid api key")))
        #expect(cleanupRecorder.urls == [extractedAudioURL])
        #expect(viewModel.transcriptState == .failed(.providerFailure(message: "invalid api key")))
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptDocument == nil)
        #expect(viewModel.transcriptDraftDocument == nil)
    }

    @Test
    func resetTranscriptCancelsTheOpenAIWhisperComponentAndReturnsTheEditorToIdleState() async {
        let cleanupRecorder = TranscriptionCleanupRecorder()
        let startProbe = OpenAIWhisperEditorStartProbe()
        let extractedAudioURL = URL(fileURLWithPath: "/tmp/editor-openai-whisper-cancel.m4a")
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
        let viewModel = EditorViewModel()
        viewModel.currentVideo = Video(
            url: URL(fileURLWithPath: "/tmp/transcription-source.mov"),
            rangeDuration: 0...20
        )
        viewModel.configureTranscription(provider: component)

        viewModel.transcribeCurrentVideo()
        await waitForTranscriptState(on: viewModel, equals: .loading)
        await startProbe.waitUntilStarted()

        viewModel.resetTranscript()
        await waitForComponentState(of: component, equals: .failed(.cancelled))

        #expect(cleanupRecorder.urls == [extractedAudioURL])
        #expect(viewModel.transcriptState == .idle)
        #expect(viewModel.transcriptFeatureState == .idle)
        #expect(viewModel.transcriptDocument == nil)
        #expect(viewModel.transcriptDraftDocument == nil)
    }

}

private final class TranscriptionCleanupRecorder: @unchecked Sendable {

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

private actor OpenAIWhisperEditorRequestProbe {

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

private actor OpenAIWhisperEditorStartProbe {

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

@MainActor
private func waitForTranscriptState(
    on viewModel: EditorViewModel,
    equals expectedState: TranscriptFeatureState
) async {
    for _ in 0..<20 {
        if viewModel.transcriptState == expectedState {
            return
        }

        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func waitForComponentState(
    of component: OpenAIWhisperTranscriptionComponent,
    equals expectedState: TranscriptFeatureState
) async {
    for _ in 0..<50 {
        if await component.state == expectedState {
            return
        }

        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForTranscriptFailure(on viewModel: EditorViewModel) async {
    for _ in 0..<20 {
        if case .failed = viewModel.transcriptState {
            return
        }

        try? await Task.sleep(for: .milliseconds(10))
    }
}
