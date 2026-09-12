import Foundation

actor OpenAIWhisperTranscriptionComponent: VideoTranscriptionComponentProtocol {

    struct Configuration: Sendable {

        // MARK: - Public Properties

        let model: String
        let responseFormat: String
        let timestampGranularities: [String]

        // MARK: - Initializer

        init(
            model: String = "whisper-1",
            responseFormat: String = "verbose_json",
            timestampGranularities: [String] = ["segment", "word"]
        ) {
            self.model = model
            self.responseFormat = responseFormat
            self.timestampGranularities = timestampGranularities
        }

    }

    struct Dependencies: Sendable {

        // MARK: - Public Properties

        let extractAudio: @Sendable (URL) async throws -> URL
        let removeExtractedAudio: @Sendable (URL) -> Void
        let createTranscription:
            @Sendable (OpenAIWhisperAPIClient.Request) async throws -> WhisperVerboseTranscriptionResponseDTO
        let mapResponse: @Sendable (WhisperVerboseTranscriptionResponseDTO) -> VideoTranscriptionResult

        // MARK: - Initializer

        init(
            extractAudio: @escaping @Sendable (URL) async throws -> URL,
            removeExtractedAudio: @escaping @Sendable (URL) -> Void,
            createTranscription:
                @escaping @Sendable (OpenAIWhisperAPIClient.Request) async throws ->
                WhisperVerboseTranscriptionResponseDTO,
            mapResponse:
                @escaping @Sendable (WhisperVerboseTranscriptionResponseDTO) ->
                VideoTranscriptionResult
        ) {
            self.extractAudio = extractAudio
            self.removeExtractedAudio = removeExtractedAudio
            self.createTranscription = createTranscription
            self.mapResponse = mapResponse
        }

        init(_ apiKey: String) {
            self.init(
                extractAudio: { url in
                    try await VideoAudioExtractionService().extractAudio(from: url)
                },
                removeExtractedAudio: { url in
                    VideoAudioExtractionService().removeExtractedAudioIfNeeded(at: url)
                },
                createTranscription: { request in
                    try await OpenAIWhisperAPIClient(apiKey: apiKey).createTranscription(request: request)
                },
                mapResponse: { response in
                    OpenAIWhisperResponseMapper().map(response)
                }
            )
        }

    }

    // MARK: - Public Properties

    var state: TranscriptFeatureState {
        currentState
    }

    // MARK: - Private Properties

    private let configuration: Configuration
    private let dependencies: Dependencies

    private var currentState: TranscriptFeatureState = .idle
    private var currentOperationID: UUID?
    private var currentTask: Task<VideoTranscriptionResult, Error>?
    private var currentExtractedAudioURL: URL?

    // MARK: - Initializer

    init(
        _ apiKey: String,
        configuration: Configuration = .init()
    ) {
        self.configuration = configuration
        dependencies = Dependencies(apiKey)
    }

    init(
        _ configuration: Configuration = .init(),
        dependencies: Dependencies
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
    }

    // MARK: - Public Methods

    func transcribeVideo(input: VideoTranscriptionInput) async throws -> VideoTranscriptionResult {
        cancelCurrentTranscriptionIfNeeded(markStateAsCancelled: false)

        let operationID = UUID()
        currentOperationID = operationID
        currentState = .loading

        let configuration = self.configuration
        let dependencies = self.dependencies
        let task = Task<VideoTranscriptionResult, Error> { [weak self] in
            let sourceURL = try Self.videoURL(from: input.source)
            let audioURL = try await dependencies.extractAudio(sourceURL)
            await self?.registerExtractedAudioURL(audioURL, for: operationID)

            let response = try await dependencies.createTranscription(
                .init(
                    audioFileURL: audioURL,
                    model: configuration.model,
                    language: input.preferredLocale,
                    responseFormat: configuration.responseFormat,
                    timestampGranularities: configuration.timestampGranularities
                )
            )

            let result = dependencies.mapResponse(response)
            guard !result.segments.isEmpty else {
                throw TranscriptError.emptyResult
            }

            return result
        }

        currentTask = task

        do {
            let result = try await task.value
            return try finalizeSuccess(result, for: operationID)
        } catch {
            throw finalizeFailure(error, for: operationID)
        }
    }

    func cancelCurrentTranscription() async {
        cancelCurrentTranscriptionIfNeeded(markStateAsCancelled: true)
    }

    // MARK: - Private Methods

    private static func videoURL(from source: VideoTranscriptionSource) throws -> URL {
        switch source {
        case .fileURL(let url):
            guard url.isFileURL else {
                throw TranscriptError.invalidVideoSource
            }

            return url
        }
    }

    private func registerExtractedAudioURL(_ url: URL, for operationID: UUID) {
        guard currentOperationID == operationID else {
            dependencies.removeExtractedAudio(url)
            return
        }

        currentExtractedAudioURL = url
    }

    private func finalizeSuccess(
        _ result: VideoTranscriptionResult,
        for operationID: UUID
    ) throws -> VideoTranscriptionResult {
        cleanupExtractedAudioURL(for: operationID)

        guard currentOperationID == operationID else {
            throw CancellationError()
        }

        currentOperationID = nil
        currentTask = nil
        currentState = .loaded
        return result
    }

    private func finalizeFailure(
        _ error: Error,
        for operationID: UUID
    ) -> Error {
        cleanupExtractedAudioURL(for: operationID)

        guard currentOperationID == operationID else {
            return CancellationError()
        }

        currentOperationID = nil
        currentTask = nil

        let transcriptError = mappedError(from: error)
        currentState = .failed(transcriptError)

        if error is CancellationError {
            return CancellationError()
        }

        return transcriptError
    }

    private func cancelCurrentTranscriptionIfNeeded(markStateAsCancelled: Bool) {
        guard let currentTask else { return }

        let operationID = currentOperationID
        self.currentTask = nil
        currentOperationID = nil
        currentTask.cancel()

        if let operationID {
            cleanupExtractedAudioURL(for: operationID)
        }

        if markStateAsCancelled {
            currentState = .failed(.cancelled)
        }
    }

    private func cleanupExtractedAudioURL(for operationID: UUID) {
        guard currentOperationID == operationID || currentOperationID == nil else { return }
        guard let currentExtractedAudioURL else { return }

        dependencies.removeExtractedAudio(currentExtractedAudioURL)
        self.currentExtractedAudioURL = nil
    }

    private func mappedError(from error: Error) -> TranscriptError {
        switch error {
        case let transcriptError as TranscriptError:
            transcriptError
        case is CancellationError:
            .cancelled
        case let extractionError as VideoAudioExtractionService.ExtractionError:
            mappedExtractionError(extractionError)
        case let clientError as OpenAIWhisperAPIClient.ClientError:
            mappedClientError(clientError)
        default:
            .providerFailure(message: error.localizedDescription)
        }
    }

    private func mappedExtractionError(
        _ error: VideoAudioExtractionService.ExtractionError
    ) -> TranscriptError {
        switch error {
        case .invalidVideoSource:
            .invalidVideoSource
        case .audioTrackNotFound,
            .unableToCreateExportSession,
            .exportFailed:
            .providerFailure(message: error.localizedDescription)
        }
    }

    private func mappedClientError(
        _ error: OpenAIWhisperAPIClient.ClientError
    ) -> TranscriptError {
        switch error {
        case .invalidAudioFileURL:
            .invalidVideoSource
        case .invalidServerResponse,
            .emptyResponseData:
            .providerFailure(message: error.localizedDescription)
        case .unsuccessfulStatusCode(_, let message):
            .providerFailure(message: message ?? error.localizedDescription)
        }
    }

}
