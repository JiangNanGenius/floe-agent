enum TranscriptToolFooterAction: Equatable {
    case transcribe
    case retry
    case apply

    // MARK: - Public Properties

    var title: String {
        switch self {
        case .transcribe:
            VideoEditorStrings.transcriptRetry
        case .retry:
            VideoEditorStrings.transcriptRetryFailure
        case .apply:
            VideoEditorStrings.apply
        }
    }
}

enum TranscriptToolFooterActionResolver {

    // MARK: - Public Methods

    static func resolve(
        isTranscriptionAvailable: Bool,
        transcriptState: TranscriptFeatureState,
        document: TranscriptDocument?
    ) -> TranscriptToolFooterAction? {
        switch transcriptState {
        case .idle:
            return isTranscriptionAvailable ? .transcribe : nil
        case .loading:
            return nil
        case .loaded:
            if let document, document.segments.isEmpty == false {
                return .apply
            }

            return isTranscriptionAvailable ? .transcribe : nil
        case .failed(let error):
            return isRetryable(error) ? .retry : nil
        }
    }

    // MARK: - Private Methods

    private static func isRetryable(_ error: TranscriptError) -> Bool {
        switch error {
        case .providerNotConfigured, .unavailable:
            false
        case .invalidVideoSource, .emptyResult, .cancelled, .providerFailure:
            true
        }
    }

}
