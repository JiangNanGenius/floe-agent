import Foundation
import Testing

@testable import VideoEditorKit

@Suite("EditorTranscriptRemappingCoordinatorTests")
struct TranscriptRemappingCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func remapDocumentProjectsSegmentAndWordTimelineRanges() throws {
        let segmentID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let wordID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))

        let document = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: segmentID,
                    timeMapping: .init(
                        sourceStartTime: 10,
                        sourceEndTime: 40,
                        timelineStartTime: nil,
                        timelineEndTime: nil
                    ),
                    originalText: "Original segment",
                    editedText: "Edited segment",
                    words: [
                        EditableTranscriptWord(
                            id: wordID,
                            timeMapping: .init(
                                sourceStartTime: 18,
                                sourceEndTime: 24,
                                timelineStartTime: nil,
                                timelineEndTime: nil
                            ),
                            originalText: "Original",
                            editedText: "Edited"
                        )
                    ]
                )
            ]
        )

        let remappedDocument = EditorTranscriptRemappingCoordinator.remap(
            document,
            trimRange: 20...60,
            playbackRate: 2
        )
        let remappedSegment = try #require(remappedDocument?.segments.first)
        let remappedWord = try #require(remappedSegment.words.first)

        #expect(remappedSegment.timeMapping.timelineRange == 10...20)
        #expect(remappedWord.timeMapping.timelineRange == 10...12)
    }

}
