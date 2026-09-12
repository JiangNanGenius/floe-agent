import Testing

@testable import VideoEditorKit

@Suite("TranscriptTimeMapperTests")
struct TranscriptTimeMapperTests {

    // MARK: - Public Methods

    @Test
    func timelineTimeScalesSourceTimeByPlaybackRate() {
        let timelineTime = TranscriptTimeMapper.timelineTime(
            fromSourceTime: 24,
            rate: 2
        )

        #expect(abs(timelineTime - 12) < 0.0001)
    }

    @Test
    func sourceTimeScalesTimelineTimeBackToSourceTime() {
        let sourceTime = TranscriptTimeMapper.sourceTime(
            fromTimelineTime: 12,
            rate: 2
        )

        #expect(abs(sourceTime - 24) < 0.0001)
    }

    @Test
    func projectedTimelineRangeClipsTheSegmentToTheTrimmedSourceRange() {
        let projectedRange = TranscriptTimeMapper.projectedTimelineRange(
            sourceRange: 10...40,
            trimRange: 20...60,
            rate: 2
        )

        #expect(projectedRange == 10...20)
    }

}
