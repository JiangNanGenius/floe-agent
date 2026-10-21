// FloeApp — Suggested system-trigger timing for one scheduled plan.
//
// SPDX-License-Identifier: MPL-2.0
//
// Foundation-only helper shared by the setup sheet and its App-host tests.
// The stored plan time is never mutated; this only derives the moment a
// system "Specific Time" automation should fire so it never lands before the
// plan's real due instant.

import Foundation

enum TaskScheduleAutomationTiming {
    /// The plan's anchor wall-clock rounded UP to the next whole minute.
    ///
    /// An anchor that already sits exactly on a whole minute is returned
    /// unchanged. Any positive fraction of a minute — whole seconds or only
    /// sub-second nanoseconds — rounds up to the next minute, with every
    /// carry (hour, day, weekday, month, year) resolved by `Calendar` rather
    /// than manual arithmetic. The result stays a real `Date` in the same
    /// timeline; formatting it with the plan's anchor calendar reproduces the
    /// intended wall clock in the plan's anchor time zone.
    ///
    /// - Parameters:
    ///   - scheduledAt: the stored plan anchor instant; never mutated.
    ///   - calendar: the plan's anchor calendar (see
    ///     `TaskSchedulePlanner.calendar(for:)`).
    static func roundedUpWholeMinute(
        for scheduledAt: Date,
        calendar: Calendar
    ) -> Date {
        // Keep the actual minute occurrence. Reconstructing wall-clock
        // components can choose the FIRST repeated hour when the input is
        // in the SECOND one at a daylight-saving transition, moving the
        // suggestion backwards by an hour.
        guard let minute = calendar.dateInterval(of: .minute, for: scheduledAt)
        else { return scheduledAt }
        return scheduledAt == minute.start ? scheduledAt : minute.end
    }
}
