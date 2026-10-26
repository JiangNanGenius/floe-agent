// FloeCoreTests — Durable outbox contract for the one-time long-run
// duration advisory: stable ownership identifier (replace-not-stack),
// non-terminal kind semantics, gate mapping, old persisted-data
// compatibility, and honest eviction/diagnostics behavior.

import Foundation
import Testing
@testable import FloeCore

@Suite("TaskNotificationOutbox duration advisory")
struct TaskNotificationDurationAdvisoryTests {
    private func advisory(
        key: String = "job.5B6C7D8E-0000-0000-0000-000000000000",
        title: String = "Task still running",
        body: String = "A long-running task has been executing for 10 minutes and will continue."
    ) -> TaskTerminalEvent {
        .durationAdvisory(
            ownershipKey: key,
            title: title,
            body: body,
            deepLink: BackgroundWorkDeepLink(
                kind: .modelRun, conversationID: UUID(), runID: UUID())
        )
    }

    @Test("The advisory factory binds the stable ownership identifier and never claims a terminal state")
    func factoryIdentity() {
        let event = advisory(key: "job.abc")
        #expect(event.identifier == "duration.advisory.job.abc")
        #expect(event.kind == .durationAdvisory)
        #expect(event.kind.isTerminal == false)
        #expect(event.deepLink.kind == .modelRun)
        // Content bounds apply like every durable alert.
        let long = advisory(title: String(repeating: "长", count: 200), body: String(repeating: "x", count: 400))
        #expect(long.title.count <= TaskNotificationContentBounds.maximumTitleCharacters)
        #expect(long.body.count <= TaskNotificationContentBounds.maximumBodyCharacters)
    }

    @Test("Gate: advisory follows the stage preference; the silent gate blocks it")
    func gateMapping() {
        // The 4-argument legacy construction keeps compiling and defaults
        // the advisory ON (source compatibility for existing gates).
        let legacy = TaskNotificationEventGate(
            notifiesCompleted: true, notifiesFailed: true,
            notifiesCancelled: true, notifiesActionRequired: true)
        #expect(legacy.allows(.durationAdvisory))
        #expect(TaskNotificationEventGate.silent.allows(.durationAdvisory) == false)
        let explicitOff = TaskNotificationEventGate(
            notifiesCompleted: true, notifiesFailed: true,
            notifiesCancelled: true, notifiesActionRequired: true,
            notifiesDurationAdvisory: false)
        #expect(explicitOff.allows(.durationAdvisory) == false)
    }

    @Test("Same ownership key replaces instead of stacking; authorization gates delivery, never drops")
    func enqueueDedupAndAuthorization() {
        var outbox = TaskNotificationOutbox()
        // Blocked authorization: queued durably, never dropped.
        #expect(outbox.enqueue(advisory(key: "job.k1"), canPresent: false) == .queuedForAuthorization)
        #expect(outbox.pendingCount == 1)
        // A repeated publication of the SAME unit of work replaces, so one
        // operation can never stack duplicate alerts.
        #expect(outbox.enqueue(advisory(key: "job.k1", body: "updated"), canPresent: false) == .replacedQueuedEvent)
        #expect(outbox.pendingCount == 1)
        #expect(outbox.pending.first?.body == "updated")
        // A DIFFERENT unit of work stays distinct.
        #expect(outbox.enqueue(advisory(key: "job.k2"), canPresent: false) == .queuedForAuthorization)
        #expect(outbox.pendingCount == 2)
        // With authorization the event presents immediately (not queued).
        #expect(outbox.enqueue(advisory(key: "job.k3"), canPresent: true) == .presentNow)
        #expect(outbox.pendingCount == 2)
        // Flush hands the queued advisories over oldest-first.
        let presentable = outbox.takePresentable(canPresent: true)
        #expect(presentable.map(\.identifier) == ["duration.advisory.job.k1", "duration.advisory.job.k2"])
        #expect(outbox.pendingCount == 0)
    }

    @Test("Advisories are evictable under queue pressure; action-required events are not")
    func evictionKeepsActionableEvents() {
        var outbox = TaskNotificationOutbox(maximumPendingEvents: 2)
        let actionable = TaskTerminalEvent(
            identifier: "run.action", kind: .actionRequired, title: "Waiting", body: "approval needed",
            deepLink: BackgroundWorkDeepLink(kind: .modelRun, conversationID: UUID(), runID: UUID()))
        _ = outbox.enqueue(actionable, canPresent: false)
        _ = outbox.enqueue(advisory(key: "job.old"), canPresent: false)
        // Pressure evicts the oldest NON-action-required event: an advisory.
        _ = outbox.enqueue(advisory(key: "job.new"), canPresent: false)
        #expect(outbox.pendingCount == 2)
        #expect(outbox.pending.contains { $0.kind == .actionRequired })
        #expect(outbox.droppedEventCount == 1)
        #expect(outbox.lastSchedulingFailure?.identifier == "duration.advisory.job.old")
    }

    @Test("Duration-target metadata round-trips and stays backward compatible")
    func durationTargetMetadata() throws {
        let jobID = UUID(), groupID = UUID(), runID = UUID()
        let event = TaskTerminalEvent.durationAdvisory(
            ownershipKey: "job.\(groupID.uuidString)",
            title: "Task still running",
            body: "body",
            deepLink: BackgroundWorkDeepLink(kind: .modelRun, conversationID: UUID(), runID: runID),
            jobID: jobID,
            advisoryGroupID: groupID
        )
        #expect(event.durationTargetJobID == jobID)
        #expect(event.durationTargetGroupID == groupID)
        #expect(event.durationTargetRunID == runID)
        // Round-trip through the persisted coding.
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TaskTerminalEvent.self, from: data)
        #expect(decoded.durationTargetJobID == jobID)
        #expect(decoded.durationTargetGroupID == groupID)
        #expect(decoded.durationTargetRunID == runID)
        #expect(decoded.kind == .durationAdvisory)
        // An event persisted BEFORE the metadata existed decodes with nil
        // targets (additive optional fields; old bytes carry no new keys).
        let legacy = TaskTerminalEvent(
            identifier: "duration.advisory.job.legacy",
            kind: .durationAdvisory,
            title: "t", body: "b",
            deepLink: BackgroundWorkDeepLink(kind: .modelRun)
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyJSON = try #require(String(data: legacyData, encoding: .utf8))
        // The synthesized encoder omits nil optionals OR writes nulls; both
        // must decode back to nil without error.
        let redecoded = try JSONDecoder().decode(TaskTerminalEvent.self, from: legacyData)
        #expect(redecoded.durationTargetJobID == nil)
        #expect(redecoded.durationTargetGroupID == nil)
        #expect(!legacyJSON.isEmpty)
        // A hand-built OLD-format payload (no metadata keys at all) decodes.
        let oldFormat = Data(#"""
        {"identifier":"duration.advisory.job.old","kind":"durationAdvisory","title":"t","body":"b",
         "createdAt":0,"deepLink":{"kind":"modelRun"}}
        """#.utf8)
        var decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let old = try decoder.decode(TaskTerminalEvent.self, from: oldFormat)
        #expect(old.kind == .durationAdvisory)
        #expect(old.durationTargetJobID == nil)
    }

    @Test("New-kind persistence round-trips; old persisted outboxes still decode")
    func persistenceCompatibility() throws {
        var outbox = TaskNotificationOutbox()
        _ = outbox.enqueue(advisory(key: "job.persist"), canPresent: false)
        let defaults = UserDefaults(suiteName: "TaskNotificationDurationAdvisoryTests.\(UUID().uuidString)")
        let suite = try #require(defaults)
        TaskNotificationOutboxStore.save(outbox, to: suite)
        let loaded = TaskNotificationOutboxStore.load(from: suite)
        #expect(loaded.pending.count == 1)
        #expect(loaded.pending.first?.kind == .durationAdvisory)
        #expect(loaded.pending.first?.identifier == "duration.advisory.job.persist")
        // A v1 outbox persisted BEFORE this kind existed decodes unchanged
        // (the new case is additive; old bytes carry only old kinds).
        var legacy = TaskNotificationOutbox()
        _ = legacy.enqueue(
            .modelRunTerminal(runID: UUID(), conversationID: UUID(), taskName: "Task",
                              kind: .completed, body: "done"),
            canPresent: false)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyJSON = try #require(String(data: legacyData, encoding: .utf8))
        #expect(!legacyJSON.contains("durationAdvisory"))
        let legacyLoaded = try JSONDecoder().decode(TaskNotificationOutbox.self, from: legacyData)
        #expect(legacyLoaded.pending.first?.kind == .completed)
    }
}
