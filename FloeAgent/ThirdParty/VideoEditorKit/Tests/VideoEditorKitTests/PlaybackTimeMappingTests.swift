import Testing

@testable import VideoEditorKit

@Suite("PlaybackTimeMappingTests")
struct PlaybackTimeMappingTests {

    // MARK: - Public Methods

    @Test
    func timelineTimePreservingSourcePositionMapsToNewRate() {
        let mappedTime = PlaybackTimeMapping.timelineTimePreservingSourcePosition(
            timelineTime: 24,
            previousRate: 1,
            newRate: 2,
            newRange: 0...50,
            originalDuration: 100
        )

        #expect(abs(mappedTime - 12) < 0.0001)
    }

    @Test
    func timelineTimePreservingSourcePositionStaysFixedWhenSlowingDown() {
        let mappedTime = PlaybackTimeMapping.timelineTimePreservingSourcePosition(
            timelineTime: 12,
            previousRate: 2,
            newRate: 0.5,
            newRange: 0...200,
            originalDuration: 100
        )

        #expect(abs(mappedTime - 48) < 0.0001)
    }

    @Test
    func scaledTimelineRangeDividesSourceRangeByRate() {
        let scaledRange = PlaybackTimeMapping.scaledTimelineRange(
            sourceRange: 20...80,
            rate: 2,
            originalDuration: 100
        )

        #expect(abs(scaledRange.lowerBound - 10) < 0.0001)
        #expect(abs(scaledRange.upperBound - 40) < 0.0001)
    }

}
