import Foundation
import Testing

@testable import VideoEditorKit

@Suite("TranscriptWordEditingCoordinatorTests")
struct TranscriptWordEditingCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func reconcileWordsUpdatesEditableWordTextsWhenTheEditedSegmentKeepsTheSameWordCount() {
        let words = [
            EditableTranscriptWord(
                id: UUID(),
                timeMapping: .init(
                    sourceStartTime: 0,
                    sourceEndTime: 0.5,
                    timelineStartTime: 0,
                    timelineEndTime: 0.5
                ),
                originalText: "hello",
                editedText: "hello"
            ),
            EditableTranscriptWord(
                id: UUID(),
                timeMapping: .init(
                    sourceStartTime: 0.5,
                    sourceEndTime: 1,
                    timelineStartTime: 0.5,
                    timelineEndTime: 1
                ),
                originalText: "world",
                editedText: "world"
            ),
        ]

        let reconciledWords = TranscriptWordEditingCoordinator.reconcileWords(
            words,
            with: "Hello, world!"
        )

        #expect(reconciledWords?.map(\.editedText) == ["Hello,", "world!"])
    }

    @Test
    func reconcileWordsRedistributesTokensAcrossExistingWordTimingsWhenTheSentenceIsCompletelyRewritten() {
        let words = [
            EditableTranscriptWord(
                id: UUID(),
                timeMapping: .init(
                    sourceStartTime: 0,
                    sourceEndTime: 0.5,
                    timelineStartTime: 0,
                    timelineEndTime: 0.5
                ),
                originalText: "hello",
                editedText: "hello"
            ),
            EditableTranscriptWord(
                id: UUID(),
                timeMapping: .init(
                    sourceStartTime: 0.5,
                    sourceEndTime: 1,
                    timelineStartTime: 0.5,
                    timelineEndTime: 1
                ),
                originalText: "world",
                editedText: "world"
            ),
        ]

        let reconciledWords = TranscriptWordEditingCoordinator.reconcileWords(
            words,
            with: "greetings from another realm"
        )

        #expect(reconciledWords?.map(\.editedText) == ["greetings from", "another realm"])
    }

    @Test
    func resolvedWordsPreservesManualCaptionsWithoutInventingWordTimings() {
        let segment = EditableTranscriptSegment(
            id: UUID(),
            timeMapping: .init(
                sourceStartTime: 10,
                sourceEndTime: 14,
                timelineStartTime: 2,
                timelineEndTime: 6
            ),
            originalText: "hello world",
            editedText: "greetings brave world"
        )

        let resolvedWords = TranscriptWordEditingCoordinator.resolvedWords(
            for: segment
        )
        #expect(resolvedWords.isEmpty)
    }

}
