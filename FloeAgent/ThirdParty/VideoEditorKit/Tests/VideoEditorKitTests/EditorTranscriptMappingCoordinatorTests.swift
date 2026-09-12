import Foundation
import Testing

@testable import VideoEditorKit

@Suite("EditorTranscriptMappingCoordinatorTests")
struct EditorTranscriptMappingCoordinatorTests {

    // MARK: - Public Methods

    @Test
    func makeDocumentMapsProviderSegmentsIntoEditableTranscriptContent() {
        let segmentID = UUID()
        let wordID = UUID()
        let result = VideoTranscriptionResult(
            segments: [
                TranscriptionSegment(
                    id: segmentID,
                    startTime: 8,
                    endTime: 12,
                    text: "hello world",
                    words: [
                        TranscriptionWord(
                            id: wordID,
                            startTime: 8,
                            endTime: 9,
                            text: "hello"
                        )
                    ]
                )
            ]
        )

        let document = EditorTranscriptMappingCoordinator.makeDocument(
            from: result,
            overlayPosition: .top,
            overlaySize: .large,
            trimRange: 0...20,
            playbackRate: 2
        )

        #expect(document.overlayPosition == .top)
        #expect(document.overlaySize == .large)
        #expect(document.segments.count == 1)
        #expect(document.segments.first?.id == segmentID)
        #expect(document.segments.first?.timeMapping.timelineRange == 4...6)
        #expect(document.segments.first?.words.first?.id == wordID)
        #expect(document.segments.first?.words.first?.timeMapping.timelineRange == 4...4.5)
    }

}
