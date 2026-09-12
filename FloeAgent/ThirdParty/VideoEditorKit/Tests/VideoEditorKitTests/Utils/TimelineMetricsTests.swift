import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("TimelineMetricsTests")
struct TimelineMetricsTests {

    // MARK: - Public Methods

    @Test
    func playbackPositionXClampsCurrentTimeInsideTrimmedRange() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 20...80,
            currentTime: 10,
            width: 200,
            handleInset: 4,
            playbackIndicatorWidth: 2
        )

        #expect(abs(metrics.playbackPositionX() - 45) < 0.0001)
    }

    @Test
    func playbackPositionXReturnsMinimumXForZeroDuration() {
        let metrics = TimelineMetrics(
            duration: 0,
            playbackRange: 0...0,
            currentTime: 0,
            width: 200
        )

        #expect(abs(metrics.playbackPositionX() - 2) < 0.0001)
    }

    @Test
    func currentClipTimeSubtractsRangeLowerBound() {
        let metrics = TimelineMetrics(
            duration: 120,
            playbackRange: 30...90,
            currentTime: 45,
            width: 240
        )

        #expect(abs(metrics.currentClipTime() - 15) < 0.0001)
    }

    @Test
    func playbackTimeClampsTouchBeforeRangeStart() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 20...80,
            currentTime: 50,
            width: 200
        )

        #expect(abs(metrics.playbackTime(for: 10) - 20) < 0.0001)
    }

    @Test
    func playbackTimeClampsTouchAfterRangeEnd() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 20...80,
            currentTime: 50,
            width: 200
        )

        #expect(abs(metrics.playbackTime(for: 190) - 80) < 0.0001)
    }

    @Test
    func badgePositionXUsesMeasuredWidthNearLeadingEdge() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 0...100,
            currentTime: 0,
            width: 200
        )

        #expect(abs(metrics.badgePositionX(for: 120) - 60) < 0.0001)
    }

    @Test
    func badgePositionXUsesMeasuredWidthNearTrailingEdge() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 0...100,
            currentTime: 100,
            width: 200
        )

        #expect(abs(metrics.badgePositionX(for: 120) - 140) < 0.0001)
    }

    @Test
    func playbackPositionXReachesTheExactTrimmedUpperBoundOnlyAtTheMaximumTime() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 20...80,
            currentTime: 80,
            width: 200,
            handleInset: 4,
            playbackIndicatorWidth: 2
        )

        #expect(abs(metrics.playbackPositionX() - 155) < 0.0001)
    }

    @Test
    func playbackPositionXReachesTheExactTrimmedLowerBoundOnlyAtTheMinimumTime() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 20...80,
            currentTime: 20,
            width: 200,
            handleInset: 4,
            playbackIndicatorWidth: 2
        )

        #expect(abs(metrics.playbackPositionX() - 45) < 0.0001)
    }

    @Test
    func playbackPositionXMapsThePlaybackMidpointToTheVisibleCenterBetweenTrimHandles() {
        let metrics = TimelineMetrics(
            duration: 100,
            playbackRange: 20...80,
            currentTime: 50,
            width: 200,
            handleInset: 4,
            playbackIndicatorWidth: 2
        )

        #expect(abs(metrics.playbackPositionX() - 100) < 0.0001)
    }

}
