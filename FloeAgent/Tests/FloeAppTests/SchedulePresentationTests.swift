// FloeAppTests — schedule presentation contract.
//
// Pure tests for the values the chat pill, the detail history and the ONE
// aggregate Live Activity show. No store, device or ActivityKit is touched:
// the same selection functions the production views use are exercised.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeApp

@Suite("FloeApp.SchedulePresentation")
struct SchedulePresentationTests {
    private func summary(
        id: UUID = UUID(),
        title: String = "Daily",
        enabled: Bool = true,
        cadence: TaskScheduleCadence = .daily,
        next: Date?,
        started: Int = 0
    ) -> TaskScheduleLinkedSummary {
        TaskScheduleLinkedSummary(
            id: id,
            title: title,
            isEnabled: enabled,
            cadence: cadence,
            nextExpectedAt: next,
            automaticRunsStarted: started,
            originConversationID: UUID())
    }

    @Test("The pill picks the nearest clocked plan and counts the others")
    func capsuleNearest() throws {
        let now = Date(timeIntervalSince1970: 1_704_000_000)
        let later = summary(title: "Later", next: now.addingTimeInterval(7_200), started: 2)
        let sooner = summary(title: "Sooner", next: now.addingTimeInterval(600), started: 4)
        let paused = summary(title: "Paused", enabled: false, next: nil)
        let capsule = try #require(TaskSchedulePresentation.capsule(
            from: [later, paused, sooner], now: now))
        #expect(capsule.title == "Sooner")
        #expect(capsule.nextRun == sooner.nextExpectedAt)
        #expect(capsule.automaticOrdinal == 5)
        #expect(capsule.otherLinkedCount == 2)
        #expect(capsule.isEnabled)
    }

    @Test("A paused or event-driven linked plan gets an honest pill with no countdown")
    func capsuleSpecialStates() throws {
        let now = Date(timeIntervalSince1970: 1_704_100_000)
        let event = TaskScheduleLinkedSummary(
            id: UUID(), title: "After", isEnabled: true, cadence: .afterSuccess,
            nextExpectedAt: nil, automaticRunsStarted: 0, originConversationID: UUID())
        let eventCapsule = try #require(TaskSchedulePresentation.capsule(from: [event], now: now))
        #expect(eventCapsule.isEventDriven)
        #expect(eventCapsule.nextRun == nil)

        let paused = summary(title: "Paused", enabled: false, next: nil)
        // An enabled event-driven plan wins over a paused clocked plan.
        let mixedCapsule = try #require(TaskSchedulePresentation.capsule(
            from: [paused, event], now: now))
        #expect(mixedCapsule.isEnabled)
        #expect(mixedCapsule.isEventDriven)
        // With nothing enabled the paused record still opens its detail.
        let pausedCapsule = try #require(TaskSchedulePresentation.capsule(
            from: [paused], now: now))
        #expect(pausedCapsule.isEnabled == false)
        #expect(pausedCapsule.nextRun == nil)
        #expect(TaskSchedulePresentation.capsule(from: [], now: now) == nil)
    }

    @Test("Manual occurrences never take an automatic ordinal")
    func manualRowsAreDistinct() {
        let manual = TaskScheduleOccurrence(
            id: UUID(), scheduleID: UUID(), scheduledFor: Date(),
            dedupeKey: "manual:\(UUID().uuidString)")
        let automatic = TaskScheduleOccurrence(
            id: UUID(), scheduleID: UUID(), scheduledFor: Date(),
            dedupeKey: "day:2026-10-30")
        #expect(manual.isManualRun)
        #expect(manual.isAutomatic == false)
        #expect(automatic.isAutomatic)
        #expect(TaskSchedulePresentation.occurrenceLabel(manual).contains(
            FloeL10n.isChinese ? "手动" : "Manual"))
        #expect(TaskSchedulePresentation.occurrenceLabel(
            automatic, automaticOrdinal: 7).contains("7"))
    }

    @Test("Automatic ordinals come from the real total, not the preview window")
    func automaticOrdinalsBeyondPreview() {
        let base = Date(timeIntervalSince1970: 1_704_200_000)
        var occurrences: [TaskScheduleOccurrence] = []
        for index in 0..<3 {
            var row = TaskScheduleOccurrence(
                id: TaskScheduleOccurrence.stableID(
                    scheduleID: UUID(), dedupeKey: "day:\(index)"),
                scheduleID: UUID(),
                scheduledFor: base.addingTimeInterval(Double(index)),
                dedupeKey: "day:\(index)")
            row.startedAt = base.addingTimeInterval(Double(index))
            occurrences.append(row)
        }
        var manual = TaskScheduleOccurrence(
            id: UUID(), scheduleID: UUID(), scheduledFor: base,
            dedupeKey: "manual:\(UUID().uuidString)")
        manual.startedAt = base.addingTimeInterval(10)
        occurrences.append(manual)
        let ordinals = TaskSchedulePresentation.automaticOrdinals(
            occurrences: occurrences, totalStartedAutomatic: 60)
        #expect(ordinals[occurrences[0].id] == 58)
        #expect(ordinals[occurrences[1].id] == 59)
        #expect(ordinals[occurrences[2].id] == 60)
        #expect(ordinals[manual.id] == nil)
    }

    @Test("Live Activity projects real runs first, then one bounded planned wait")
    func liveActivityProjection() {
        let now = Date(timeIntervalSince1970: 1_704_300_000)
        let runs = (0..<4).map { index in
            TaskLiveActivityProjection.Candidate(
                runID: UUID(), conversationID: UUID(), title: "Run \(index)",
                stage: "Working", pendingApprovalToolName: nil,
                isAwaitingUserAttention: false,
                startedAt: now.addingTimeInterval(Double(-index)), publishesContent: true)
        }
        let wait = TaskLiveActivityProjection.ScheduledWaitCandidate(
            scheduleID: UUID(), conversationID: UUID(), title: "Planned",
            nextFireAt: now.addingTimeInterval(20 * 60))
        let summary = TaskLiveActivityProjection.ScheduledWaitSummary(
            nearest: wait, totalEnabledCount: 3)
        let snapshot = TaskLiveActivityProjection.snapshot(
            from: runs, scheduledWaits: summary, now: now)
        #expect(snapshot.rows.count == 4)
        #expect(snapshot.rows.prefix(3).allSatisfy { $0.waitingUntil == nil })
        #expect(snapshot.rows.allSatisfy { $0.state != .waiting } == false)
        #expect(snapshot.rows.last?.waitingUntil == wait.nextFireAt)
        #expect(snapshot.rows.last?.state == .waiting)
        #expect(snapshot.rows.last?.id == "schedule:\(wait.scheduleID.uuidString)")
        #expect(snapshot.activeCount == 4)
        #expect(snapshot.scheduledCount == 3)
        try? snapshot.validate()
    }

    @Test("A far-future or stale planned wait never pins a permanent activity")
    func liveActivityWaitHorizon() {
        let now = Date(timeIntervalSince1970: 1_704_400_000)
        let far = TaskLiveActivityProjection.ScheduledWaitCandidate(
            scheduleID: UUID(), conversationID: nil, title: "Far",
            nextFireAt: now.addingTimeInterval(6 * 60 * 60))
        let farSnapshot = TaskLiveActivityProjection.snapshot(
            from: [],
            scheduledWaits: .init(nearest: far, totalEnabledCount: 1),
            now: now)
        #expect(farSnapshot.rows.isEmpty)
        #expect(farSnapshot.scheduledCount == 1)

        let running = TaskLiveActivityProjection.Candidate(
            runID: UUID(), conversationID: UUID(), title: "Run", stage: "Working",
            pendingApprovalToolName: nil, isAwaitingUserAttention: false,
            startedAt: now, publishesContent: true)
        let stale = TaskLiveActivityProjection.ScheduledWaitCandidate(
            scheduleID: UUID(), conversationID: nil, title: "Old",
            nextFireAt: now.addingTimeInterval(-10 * 60))
        let staleSnapshot = TaskLiveActivityProjection.snapshot(
            from: [running],
            scheduledWaits: .init(nearest: stale, totalEnabledCount: 1),
            now: now)
        #expect(staleSnapshot.rows.count == 1)
        #expect(staleSnapshot.rows.first?.waitingUntil == nil)
    }

    @Test("The wait summary only gives clocked plans a countdown")
    func waitSummary() {
        let now = Date(timeIntervalSince1970: 1_704_500_000)
        let origin = UUID()
        let clocked = TaskScheduleRecord(
            title: "Clocked", prompt: "x", cadence: .daily,
            scheduledAt: now.addingTimeInterval(1_800),
            originConversationID: origin)
        let event = TaskScheduleRecord(
            title: "Event", prompt: "x", cadence: .afterSuccess,
            scheduledAt: now, upstreamRunID: UUID())
        let paused = TaskScheduleRecord(
            title: "Paused", prompt: "x", cadence: .daily,
            scheduledAt: now, isEnabled: false)
        let summary = TaskLiveActivityProjection.scheduledWaitSummary(
            schedules: [clocked, event, paused], now: now)
        #expect(summary.nearest?.scheduleID == clocked.id)
        #expect(summary.nearest?.conversationID == origin)
        // Disabled plans do not count; the event-driven enabled plan does.
        #expect(summary.totalEnabledCount == 2)
    }

    @Test("Snapshot validation rejects fabricated or duplicated wait rows")
    func waitValidation() throws {
        let wait = FloeTaskActivitySnapshot.Row.scheduledWait(
            scheduleID: UUID(), conversationID: nil, title: "Planned",
            nextFireAt: Date().addingTimeInterval(600))
        var snapshot = FloeTaskActivitySnapshot(rows: [wait], activeCount: 0, scheduledCount: 1)
        try snapshot.validate()
        let runningWithWait = FloeTaskActivitySnapshot.Row(
            id: "run", title: "Run", state: .running, status: "",
            route: nil, startedAt: Date(), waitingUntil: Date().addingTimeInterval(60))
        #expect(throws: FloeTaskActivitySnapshotError.self) {
            try FloeTaskActivitySnapshot(rows: [runningWithWait]).validate()
        }
        #expect(throws: FloeTaskActivitySnapshotError.self) {
            try FloeTaskActivitySnapshot(rows: [wait, wait]).validate()
        }
        snapshot = FloeTaskActivitySnapshot(rows: [], activeCount: 0, scheduledCount: 100)
        #expect(throws: FloeTaskActivitySnapshotError.self) {
            try snapshot.validate()
        }
    }

    @Test("Older encoded activity state without wait fields still decodes")
    func legacySnapshotDecode() throws {
        let json = #"""
        {"rows":[{"id":"RUN","title":"Task","state":"running","status":"Working","startedAt":756000000}],"activeCount":1}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(FloeTaskActivitySnapshot.self, from: Data(json.utf8))
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.waitingUntil == nil)
        #expect(snapshot.scheduledCount == nil)
        try? snapshot.validate()
    }
}
#endif
