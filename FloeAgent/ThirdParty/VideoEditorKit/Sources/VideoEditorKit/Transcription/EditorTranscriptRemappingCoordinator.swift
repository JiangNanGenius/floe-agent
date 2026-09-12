import Foundation

public enum EditorTranscriptRemappingCoordinator {

    // MARK: - Public Methods

    public static func remap(
        _ document: TranscriptDocument?,
        trimRange: ClosedRange<Double>,
        playbackRate: Float
    ) -> TranscriptDocument? {
        guard let document else { return nil }

        var remappedDocument = document
        remappedDocument.segments = document.segments.map {
            remap(
                $0,
                trimRange: trimRange,
                playbackRate: playbackRate
            )
        }
        return remappedDocument
    }

    public static func remap(
        _ segment: EditableTranscriptSegment,
        trimRange: ClosedRange<Double>,
        playbackRate: Float
    ) -> EditableTranscriptSegment {
        var remappedSegment = segment
        remappedSegment.timeMapping = TranscriptTimeMapper.remapped(
            segment.timeMapping,
            trimRange: trimRange,
            rate: playbackRate
        )
        remappedSegment.words = segment.words.map {
            remap(
                $0,
                trimRange: trimRange,
                playbackRate: playbackRate
            )
        }
        return remappedSegment
    }

    // MARK: - Private Methods

    private static func remap(
        _ word: EditableTranscriptWord,
        trimRange: ClosedRange<Double>,
        playbackRate: Float
    ) -> EditableTranscriptWord {
        var remappedWord = word
        remappedWord.timeMapping = TranscriptTimeMapper.remapped(
            word.timeMapping,
            trimRange: trimRange,
            rate: playbackRate
        )
        return remappedWord
    }

}
