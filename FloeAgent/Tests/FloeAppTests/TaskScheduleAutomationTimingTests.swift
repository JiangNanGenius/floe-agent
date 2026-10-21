// FloeAppTests — Suggested system-trigger timing contract.
//
// These tests exercise the REAL production helper
// (`TaskScheduleAutomationTiming.roundedUpWholeMinute`); the expected values
// below are fixed calendar facts, not a mirrored re-implementation. The
// round-up must preserve the weekday across ordinary hour boundaries, roll
// the day only when the round-up truly crosses midnight, keep an exact
// minute unchanged, catch sub-second fractions, and honor the plan's anchor
// calendar rather than the device zone.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.TaskScheduleAutomationTiming")
struct TaskScheduleAutomationTimingTests {

    private func makeCalendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .current
        return calendar
    }

    private func makeDate(
        _ calendar: Calendar,
        year: Int, month: Int, day: Int,
        hour: Int, minute: Int, second: Int = 0, nanosecond: Int = 0
    ) -> Date {
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second,
            nanosecond: nanosecond)
        return calendar.date(from: components)!
    }

    private func parts(
        _ calendar: Calendar, _ date: Date
    ) -> [Int] {
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, c.nanosecond!]
    }

    @Test("Ordinary same-hour fraction rounds up to the next minute")
    func sameHourRoundsUp() {
        let utc = makeCalendar("UTC")
        let anchor = makeDate(utc, year: 2026, month: 3, day: 7, hour: 8, minute: 30, second: 45)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(for: anchor, calendar: utc)
        #expect(parts(utc, rounded) == [2026, 3, 7, 8, 31, 0, 0])
    }

    @Test("12:59 rounds up to 13:00 on the SAME weekday")
    func hourRolloverKeepsWeekday() {
        // 2026-03-07 is a Saturday; a 12:59:30 round-up crosses an hour but
        // not midnight, so the day must not move.
        let utc = makeCalendar("UTC")
        let anchor = makeDate(utc, year: 2026, month: 3, day: 7, hour: 12, minute: 59, second: 30)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(for: anchor, calendar: utc)
        #expect(parts(utc, rounded) == [2026, 3, 7, 13, 0, 0, 0])
        #expect(utc.component(.weekday, from: rounded) == utc.component(.weekday, from: anchor))
    }

    @Test("Saturday 23:59 rounds up across midnight into Sunday")
    func midnightRolloverAdvancesDay() {
        // 2026-03-07 is a Saturday; rounding 23:59:30 up must land on
        // Sunday 2026-03-08 00:00, with the weekday shifted by the calendar.
        let utc = makeCalendar("UTC")
        let anchor = makeDate(utc, year: 2026, month: 3, day: 7, hour: 23, minute: 59, second: 30)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(for: anchor, calendar: utc)
        #expect(parts(utc, rounded) == [2026, 3, 8, 0, 0, 0, 0])
        #expect(utc.component(.weekday, from: rounded) == 1)  // Sunday
    }

    @Test("An anchor already on an exact whole minute stays unchanged")
    func exactMinuteIsUnchanged() {
        let utc = makeCalendar("UTC")
        let anchor = makeDate(utc, year: 2026, month: 3, day: 7, hour: 8, minute: 30)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(for: anchor, calendar: utc)
        #expect(rounded == anchor)
        #expect(parts(utc, rounded) == [2026, 3, 7, 8, 30, 0, 0])
    }

    @Test("A sub-second fraction after an exact minute still rounds up")
    func subsecondFractionRoundsUp() {
        let utc = makeCalendar("UTC")
        // Whole-second reading is 0; only the nanosecond fraction is positive.
        let anchor = makeDate(
            utc, year: 2026, month: 3, day: 7,
            hour: 8, minute: 30, second: 0, nanosecond: 500_000_000)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(for: anchor, calendar: utc)
        #expect(parts(utc, rounded) == [2026, 3, 7, 8, 31, 0, 0])
    }

    @Test("The anchor calendar's zone, not the device zone, defines the wall clock")
    func anchorZoneDefinesWallClock() {
        // Plan anchored in Kiritimati (+14): 2026-03-08 09:30:45 local.
        let kiritimati = makeCalendar("Pacific/Kiritimati")
        let anchor = makeDate(
            kiritimati, year: 2026, month: 3, day: 8, hour: 9, minute: 30, second: 45)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(
            for: anchor, calendar: kiritimati)
        // The suggested moment reads 09:31 in the anchor zone ...
        #expect(parts(kiritimati, rounded) == [2026, 3, 8, 9, 31, 0, 0])
        // ... and the same instant is a different wall clock in UTC, proving
        // the helper honored the anchor calendar instead of the device zone.
        let utc = makeCalendar("UTC")
        #expect(parts(utc, rounded) == [2026, 3, 7, 19, 31, 0, 0])
    }

    @Test("The second repeated hour never rounds backwards into the first")
    func repeatedHourKeepsItsActualOccurrence() {
        let utc = makeCalendar("UTC")
        let newYork = makeCalendar("America/New_York")
        let anchor = makeDate(utc, year: 2026, month: 11, day: 1, hour: 6, minute: 30, second: 30)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(for: anchor, calendar: newYork)
        #expect(rounded >= anchor)
        #expect(parts(utc, rounded) == [2026, 11, 1, 6, 31, 0, 0])
    }

    @Test("A minute crossing the spring clock gap keeps the actual next instant")
    func springGapMovesForward() {
        let utc = makeCalendar("UTC")
        let newYork = makeCalendar("America/New_York")
        let anchor = makeDate(utc, year: 2026, month: 3, day: 8, hour: 6, minute: 59, second: 30)
        let rounded = TaskScheduleAutomationTiming.roundedUpWholeMinute(for: anchor, calendar: newYork)
        #expect(parts(utc, rounded) == [2026, 3, 8, 7, 0, 0, 0])
        #expect(newYork.component(.hour, from: rounded) == 3)
    }
}
#endif
