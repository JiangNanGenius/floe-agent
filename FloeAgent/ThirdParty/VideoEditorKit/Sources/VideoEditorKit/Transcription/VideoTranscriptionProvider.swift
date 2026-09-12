import Foundation

/// Protocol adopted by host-provided transcript providers.
public protocol VideoTranscriptionProvider: Sendable {
    func transcribeVideo(input: VideoTranscriptionInput) async throws -> VideoTranscriptionResult
}

/// Extended provider contract used by providers that expose availability and cancellation state.
public protocol VideoTranscriptionComponentProtocol: VideoTranscriptionProvider {
    var state: TranscriptFeatureState { get async }
    func cancelCurrentTranscription() async
    func availabilityError(
        preferredLocale: String?
    ) async -> TranscriptError?
}

extension VideoTranscriptionComponentProtocol {

    public func availabilityError(
        preferredLocale: String?
    ) async -> TranscriptError? {
        nil
    }
}

public struct VideoTranscriptionInput: Hashable, Sendable {

    // MARK: - Public Properties

    /// Stable identifier for the video asset being transcribed.
    public let assetIdentifier: String
    /// Source location of the video to transcribe.
    public let source: VideoTranscriptionSource
    /// Preferred locale requested by the host app, if any.
    public let preferredLocale: String?

    // MARK: - Initializer

    public init(
        assetIdentifier: String,
        source: VideoTranscriptionSource,
        preferredLocale: String?
    ) {
        self.assetIdentifier = assetIdentifier
        self.source = source
        self.preferredLocale = preferredLocale
    }

}

/// Supported source types for transcription input.
public enum VideoTranscriptionSource: Hashable, Sendable {
    case fileURL(URL)
}

/// Result returned by a transcription provider.
public struct VideoTranscriptionResult: Hashable, Sendable {

    // MARK: - Public Properties

    public var segments: [TranscriptionSegment] = []

    // MARK: - Initializer

    public init(segments: [TranscriptionSegment] = []) {
        self.segments = segments
    }

}

/// One transcript segment returned by a provider.
public struct TranscriptionSegment: Identifiable, Hashable, Sendable {

    // MARK: - Public Properties

    public let id: UUID
    public let startTime: Double
    public let endTime: Double
    public let text: String
    public var words: [TranscriptionWord] = []

    // MARK: - Initializer

    public init(
        id: UUID,
        startTime: Double,
        endTime: Double,
        text: String,
        words: [TranscriptionWord] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.words = words
    }

}

/// One timed word returned by a provider.
public struct TranscriptionWord: Identifiable, Hashable, Sendable {

    // MARK: - Public Properties

    public let id: UUID
    public let startTime: Double
    public let endTime: Double
    public let text: String

    // MARK: - Initializer

    public init(
        id: UUID,
        startTime: Double,
        endTime: Double,
        text: String
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }

}
