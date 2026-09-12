import Foundation
import Testing

@testable import VideoEditorKit

@Suite("TimeIntervalFormattingTests")
struct TimeIntervalFormattingTests {

    // MARK: - Public Methods

    @Test
    func minuteSecondsFormatsFinitePositiveValues() {
        let interval: TimeInterval = 65

        #expect(interval.minuteSeconds == "01:05")
    }

    @Test
    func minuteSecondsReturnsUnknownForInvalidValues() {
        #expect(TimeInterval.zero.minuteSeconds == "unknown")
        #expect(TimeInterval.infinity.minuteSeconds == "unknown")
    }

    @Test
    func formatterTimeStringFormatsHoursMinutesAndSecondsWhenNeeded() {
        let interval: TimeInterval = 5_422

        #expect(interval.formatterTimeString() == "01:30:22")
    }

    @Test
    func formatterTimeStringFormatsLargeMinuteValuesWithoutHours() {
        let interval: TimeInterval = 1_992

        #expect(interval.formatterTimeString() == "33:12")
    }

    @Test
    func formatterTimeStringFormatsTwoDigitMinutesAndSeconds() {
        let interval: TimeInterval = 71

        #expect(interval.formatterTimeString() == "01:11")
    }

    @Test
    func formatterPreciseTimeStringFormatsFractionalSecondsForEditorDisplays() {
        let interval: TimeInterval = 3.32

        #expect(interval.formatterPreciseTimeString() == "00:03.32")
    }

    @Test
    func formatterPreciseTimeStringRoundsToCentiseconds() {
        let interval: TimeInterval = 3.325

        #expect(interval.formatterPreciseTimeString() == "00:03.33")
    }

    @Test
    func formatterPreciseTimeStringReturnsZeroForInvalidValues() {
        #expect(TimeInterval.zero.formatterPreciseTimeString() == "00:00.00")
        #expect(TimeInterval.infinity.formatterPreciseTimeString() == "00:00.00")
    }

    @Test
    func secondsToTimeClampsNegativeValues() {
        #expect((-3).secondsToTime() == "00:00")
    }

}
