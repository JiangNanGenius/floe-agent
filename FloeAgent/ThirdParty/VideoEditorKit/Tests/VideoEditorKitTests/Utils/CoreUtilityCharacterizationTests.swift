import Foundation
import Testing

@testable import VideoEditorKit

@Suite("CoreUtilityCharacterizationTests")
struct CoreUtilityCharacterizationTests {

    // MARK: - Public Methods

    @Test
    func minutesSecondsMillisecondsFormatsFiniteValuesAndClampsInvalidOnes() {
        #expect(TimeInterval(65.43).minutesSecondsMilliseconds == "01:05:43")
        #expect(TimeInterval(-1).minutesSecondsMilliseconds == "00:00:00")
        #expect(TimeInterval.infinity.minutesSecondsMilliseconds == "00:00:00")
    }

    @Test
    func playbackTimeMappingClampsSourceRangesAndNormalizesInvalidRates() {
        let scaledRange = PlaybackTimeMapping.scaledTimelineRange(
            sourceRange: -10...150,
            rate: 2,
            originalDuration: 100
        )

        let sourceTime = PlaybackTimeMapping.sourceTime(
            forTimelineTime: -5,
            rate: 0,
            originalDuration: 100
        )

        let timelineTime = PlaybackTimeMapping.timelineTime(
            fromSourceTime: 30,
            rate: 0
        )

        #expect(abs(scaledRange.lowerBound - 0) < 0.0001)
        #expect(abs(scaledRange.upperBound - 50) < 0.0001)
        #expect(abs(sourceTime - 0) < 0.0001)
        #expect(abs(timelineTime - 30) < 0.0001)
    }

    @Test
    func timelineMetricsFallsBackToRangeStartWhenWidthIsInvalid() {
        let metrics = TimelineMetrics(
            duration: 120,
            playbackRange: 30...80,
            currentTime: 50,
            width: 0
        )

        #expect(abs(metrics.playbackTime(for: 75) - 30) < 0.0001)
    }

    @Test
    func timelineMetricsUsesRangeStartWhenTheVisibleRangeCollapses() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 30...30,
            currentTime: 50,
            width: 200
        )

        #expect(abs(metrics.playbackPositionX() - 60) < 0.0001)
    }

}
