// FloeModelsTests — Explicit selected-schedule execution targeting.
//
// `TaskSchedulePlanner.selectedRunTarget` decides WHICH logical occurrence an
// explicit "run this schedule now" caller (Shortcuts automation bound to one
// selected schedule) addresses. It must coalesce exactly like the background
// pass (most recent due fire time), give a deterministic occurrence identity
// (duplicate callbacks collapse on one row), and refuse event-armed
// after-success schedules, which the clock can never materialize.

import Foundation
import Testing
@testable import FloeModels

@Suite("FloeModels.TaskSchedulePlanner.SelectedRunTarget")
struct TaskSchedulePlannerSelectedRunTargetTests {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14T22:13:20Z

    @Test("A past one-shot targets its anchor with the constant key")
    func oneShotPast() throws {
        let record = TaskScheduleRecord(
            title: "Once", prompt: "p", cadence: .once,
            scheduledAt: anchor.addingTimeInterval(-120))
        let now = anchor
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: record, now: now))
        #expect(target.fireTime == anchor.addingTimeInterval(-120))
        #expect(target.dedupeKey == "once")
        #expect(target.occurrenceID == TaskScheduleOccurrence.stableID(
            scheduleID: record.id, dedupeKey: "once"))
    }

    @Test("A future one-shot has no execution target yet")
    func oneShotFuture() {
        let record = TaskScheduleRecord(
            title: "Once", prompt: "p", cadence: .once, scheduledAt: anchor)
        #expect(TaskSchedulePlanner.selectedRunTarget(
            record: record, now: anchor.addingTimeInterval(-1)) == nil)
    }

    @Test("A daily schedule targets the most recent due day bucket")
    func dailyCoalescesToMostRecentDue() throws {
        var record = TaskScheduleRecord(
            title: "Daily", prompt: "p", cadence: .daily,
            scheduledAt: anchor.addingTimeInterval(-3 * 86_400))
        record.anchorTimezone = "UTC"
        let now = anchor.addingTimeInterval(36 * 3_600)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: record, now: now))
        #expect(target.dedupeKey.hasPrefix("day:"))
        // The chosen bucket is the LATEST due fire time, never an old one.
        #expect(target.fireTime <= now)
        let expectedKey = TaskSchedulePlanner.dedupeKey(
            for: target.fireTime, record: record)
        #expect(target.occurrenceID == TaskScheduleOccurrence.stableID(
            scheduleID: record.id, dedupeKey: expectedKey))
    }

    @Test("An interval schedule targets the latest elapsed multiple")
    func intervalLatestMultiple() {
        let record = TaskScheduleRecord(
            title: "Interval", prompt: "p", cadence: .interval,
            scheduledAt: anchor, intervalSeconds: 3_600)
        let now = anchor.addingTimeInterval(2.5 * 3_600)
        let target = TaskSchedulePlanner.selectedRunTarget(record: record, now: now)
        #expect(target?.fireTime == anchor.addingTimeInterval(2 * 3_600))
        #expect(target?.dedupeKey
            == "epoch:\(Int(anchor.addingTimeInterval(2 * 3_600).timeIntervalSince1970))")
    }

    @Test("An after-success schedule is event-armed and has no time-based target")
    func afterSuccessHasNoClockTarget() {
        let record = TaskScheduleRecord(
            title: "Chain", prompt: "p", cadence: .afterSuccess,
            scheduledAt: anchor.addingTimeInterval(-60), upstreamRunID: UUID())
        #expect(TaskSchedulePlanner.selectedRunTarget(
            record: record, now: anchor.addingTimeInterval(3_600)) == nil)
    }

    @Test("The same schedule and clock always address the same occurrence")
    func deterministicIdentity() {
        let record = TaskScheduleRecord(
            title: "Daily", prompt: "p", cadence: .daily,
            scheduledAt: anchor.addingTimeInterval(-86_400), anchorTimezone: "UTC")
        let now = anchor
        let first = TaskSchedulePlanner.selectedRunTarget(record: record, now: now)
        let second = TaskSchedulePlanner.selectedRunTarget(record: record, now: now)
        #expect(first?.occurrenceID == second?.occurrenceID)
        #expect(first?.occurrenceID != nil)
        // A DIFFERENT schedule never addresses the same row.
        let other = TaskScheduleRecord(
            title: "Daily 2", prompt: "p", cadence: .daily,
            scheduledAt: anchor.addingTimeInterval(-86_400), anchorTimezone: "UTC")
        let foreign = TaskSchedulePlanner.selectedRunTarget(record: other, now: now)
        #expect(foreign?.occurrenceID != first?.occurrenceID)
    }
}
