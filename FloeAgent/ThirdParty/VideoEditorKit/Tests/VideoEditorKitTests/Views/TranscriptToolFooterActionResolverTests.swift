import Foundation
import Testing

@testable import VideoEditorKit

@Suite("TranscriptToolFooterActionResolverTests")
struct TranscriptToolFooterActionResolverTests {

    // MARK: - Public Methods

    @Test
    func idleStateUsesTranscribeWhenProviderIsAvailable() {
        let action = TranscriptToolFooterActionResolver.resolve(
            isTranscriptionAvailable: true,
            transcriptState: .idle,
            document: nil
        )

        #expect(action == .transcribe)
    }

    @Test
    func loadedStateUsesApplyWhenTimedSegmentsExist() {
        let action = TranscriptToolFooterActionResolver.resolve(
            isTranscriptionAvailable: true,
            transcriptState: .loaded,
            document: TranscriptDocument(
                segments: [
                    EditableTranscriptSegment(
                        id: UUID(),
                        timeMapping: .init(sourceStartTime: 0, sourceEndTime: 1),
                        originalText: "Hello",
                        editedText: "Hello"
                    )
                ]
            )
        )

        #expect(action == .apply)
    }

    @Test
    func loadedStateFallsBackToTranscribeWhenNoSegmentsExist() {
        let action = TranscriptToolFooterActionResolver.resolve(
            isTranscriptionAvailable: true,
            transcriptState: .loaded,
            document: TranscriptDocument(segments: [])
        )

        #expect(action == .transcribe)
    }

    @Test
    func retryableFailureUsesRetryAction() {
        let action = TranscriptToolFooterActionResolver.resolve(
            isTranscriptionAvailable: true,
            transcriptState: .failed(.providerFailure(message: "boom")),
            document: nil
        )

        #expect(action == .retry)
    }

    @Test
    func nonRetryableFailureHidesTheFooterAction() {
        let action = TranscriptToolFooterActionResolver.resolve(
            isTranscriptionAvailable: false,
            transcriptState: .failed(.providerNotConfigured),
            document: nil
        )

        #expect(action == nil)
    }

}
