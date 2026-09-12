import Foundation
import Testing

@testable import VideoEditorKit

@Suite("TranscriptDocumentTests")
struct TranscriptDocumentTests {

    // MARK: - Public Methods

    @Test
    func plainTextUsesEditedSegmentsAsParagraphsAndSkipsBlankEntries() {
        let document = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "Hello world",
                    editedText: "  Hello brave world  "
                ),
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 1,
                        sourceEndTime: 2,
                        timelineStartTime: 1,
                        timelineEndTime: 2
                    ),
                    originalText: "Ignored",
                    editedText: "   "
                ),
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 2,
                        sourceEndTime: 3,
                        timelineStartTime: 2,
                        timelineEndTime: 3
                    ),
                    originalText: "Second paragraph",
                    editedText: "Second paragraph"
                ),
            ]
        )

        #expect(document.hasCopyableText)
        #expect(document.plainText == "Hello brave world\n\nSecond paragraph")
    }

    @Test
    func plainTextIsEmptyWhenEverySegmentIsBlank() {
        let document = TranscriptDocument(
            segments: [
                EditableTranscriptSegment(
                    id: UUID(),
                    timeMapping: .init(
                        sourceStartTime: 0,
                        sourceEndTime: 1,
                        timelineStartTime: 0,
                        timelineEndTime: 1
                    ),
                    originalText: "Only blanks",
                    editedText: "\n  "
                )
            ]
        )

        #expect(document.hasCopyableText == false)
        #expect(document.plainText.isEmpty)
    }

}
