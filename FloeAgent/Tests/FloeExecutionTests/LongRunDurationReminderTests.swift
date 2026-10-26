// FloeExecutionTests — One-time long-run duration advisory monitor
// (LongRunDurationReminder). Virtual-clock coverage required by the new
// time policy: 599 / 600 / 600+ delivers exactly ONE notice, repeated
// ticks and phase-handoff re-begins never reset or duplicate it, terminal
// races never alert after the end, distinct units stay distinct, and the
// monitor's bookkeeping is isolated from sink behavior.

import Foundation
import Testing
import FloeCore
@testable import FloeExecution

/// Deterministic virtual-clock gate: every armed one-shot parks in a
/// continuation; the test decides when "600 s" elapses (release `true`) or
/// simulates a cancelled sleep (release `false`).
private actor VirtualSleepGate {
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private(set) var requested: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async -> Bool {
        requested.append(seconds)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters.append(continuation)
        }
    }

    var waiterCount: Int { waiters.count }

    func releaseAll(_ result: Bool) {
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume(returning: result) }
    }
}

private actor MilestoneCollector {
    private(set) var milestones: [LongRunAdvisoryMilestone] = []
    func add(_ milestone: LongRunAdvisoryMilestone) { milestones.append(milestone) }
    var count: Int { milestones.count }
    var first: LongRunAdvisoryMilestone? { milestones.first }
    var keys: [String] { milestones.map(\.ownershipKey) }
}

/// Suspends each sink invocation at a test-controlled point BEFORE the
/// delivery-fence check, making the fire → end → fence ordering
/// deterministic instead of a comment-level promise.
private actor SinkEnterGate {
    private(set) var enteredCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        enteredCount += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

@Suite("Long-run duration reminder")
struct LongRunDurationReminderTests {
    /// Bounded poll: the monitor's bookkeeping hops through actors, so
    /// assertions wait for real settlement instead of racing it.
    private func waitFor(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    @Test("599 = nothing, 600 = exactly one advisory, 600+ and re-begins never repeat it")
    func oneAdvisoryAtThreshold() async {
        let gate = VirtualSleepGate()
        let collector = MilestoneCollector()
        let conversation = UUID(), runID = UUID(), jobID = UUID(), group = UUID()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        await reminder.begin(key: "job.phase", conversationID: conversation, runID: runID,
                             jobID: jobID, advisoryGroupID: group, label: "exec.shell")
        // The 599-second state: the threshold sleep is still pending and
        // nothing was delivered.
        #expect(await waitFor { await gate.waiterCount == 1 })
        #expect(await collector.count == 0)
        #expect(await reminder.armedCount == 1)
        // The monotonic wait requested is exactly the policy threshold.
        #expect(await gate.requested == [600])
        // 600 elapsed: ONE advisory, carrying only runtime-issued identity.
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 1 })
        let milestone = await collector.first
        #expect(milestone?.ownershipKey == "job.phase")
        #expect(milestone?.conversationID == conversation)
        #expect(milestone?.runID == runID)
        #expect(milestone?.jobID == jobID)
        #expect(milestone?.advisoryGroupID == group)
        #expect(milestone?.label == "exec.shell")
        #expect(milestone?.thresholdSeconds == 600)
        // 600+: repeated ticks and a phase-handoff re-begin never produce a
        // second advisory and never arm a new timer for the fired key.
        await gate.releaseAll(true)
        await reminder.begin(key: "job.phase", conversationID: conversation, runID: runID,
                             jobID: UUID(), advisoryGroupID: group, label: "exec.shell")
        #expect(await gate.waiterCount == 0)
        #expect(await reminder.armedCount == 0)
        #expect(await reminder.hasFired(key: "job.phase"))
        await gate.releaseAll(true)
        #expect(await collector.count == 1)
    }

    @Test("Idempotent begin keeps the ORIGINAL threshold: a phase handoff never postpones the advisory")
    func beginNeverResetsThreshold() async {
        let gate = VirtualSleepGate()
        let collector = MilestoneCollector()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        let group = UUID()
        // Phase 1 arms the group key; phases 2 and 3 re-begin the SAME key.
        await reminder.begin(key: "job.\(group.uuidString)", conversationID: nil, runID: nil,
                             jobID: UUID(), advisoryGroupID: group, label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 1 })
        await reminder.begin(key: "job.\(group.uuidString)", conversationID: nil, runID: nil,
                             jobID: UUID(), advisoryGroupID: group, label: "exec.shell")
        await reminder.begin(key: "job.\(group.uuidString)", conversationID: nil, runID: nil,
                             jobID: UUID(), advisoryGroupID: group, label: "exec.shell")
        // Exactly one timer exists and it still measures from phase 1: the
        // requested sleep happened once, at the original threshold.
        #expect(await gate.waiterCount == 1)
        #expect(await gate.requested == [600])
        #expect(await reminder.armedCount == 1)
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 1 })
        #expect(await collector.keys == ["job.\(group.uuidString)"])
    }

    @Test("Terminal before the threshold: end() disarms and a late elapsed sleep never alerts")
    func endBeforeFirePreventsAdvisory() async {
        let gate = VirtualSleepGate()
        let collector = MilestoneCollector()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        await reminder.begin(key: "job.done", conversationID: nil, runID: nil,
                             jobID: UUID(), label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 1 })
        await reminder.end(key: "job.done")
        #expect(await reminder.armedCount == 0)
        // The unit finished first; the elapsed threshold must not alert.
        await gate.releaseAll(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 0)
        #expect(await reminder.hasFired(key: "job.done") == false)
        // A never-fired key may arm again (a distinct later unit of work).
        await reminder.begin(key: "job.done", conversationID: nil, runID: nil,
                             jobID: UUID(), label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 1 })
    }

    @Test("A fired key never re-arms: end-after-fire cannot make the advisory deliverable again")
    func firedKeyNeverRearms() async {
        let gate = VirtualSleepGate()
        let collector = MilestoneCollector()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        await reminder.begin(key: "job.fired", conversationID: nil, runID: nil,
                             jobID: UUID(), label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 1 })
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 1 })
        await reminder.end(key: "job.fired")
        await reminder.begin(key: "job.fired", conversationID: nil, runID: nil,
                             jobID: UUID(), label: "exec.shell")
        #expect(await gate.waiterCount == 0)
        #expect(await reminder.armedCount == 0)
        await gate.releaseAll(true)
        #expect(await collector.count == 1)
    }

    @Test("A cancelled sleep (torn-down task) never fires")
    func cancelledSleepNeverFires() async {
        let gate = VirtualSleepGate()
        let collector = MilestoneCollector()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        await reminder.begin(key: "job.cancelled", conversationID: nil, runID: nil,
                             jobID: UUID(), label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 1 })
        await reminder.end(key: "job.cancelled")
        await gate.releaseAll(false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 0)
    }

    @Test("Distinct ownership keys stay distinct")
    func distinctKeysAreIndependent() async {
        let gate = VirtualSleepGate()
        let collector = MilestoneCollector()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        await reminder.begin(key: "job.A", conversationID: nil, runID: nil, jobID: UUID(), label: "exec.shell")
        await reminder.begin(key: "shell.run.token", conversationID: nil, runID: UUID(), jobID: nil, label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 2 })
        #expect(await reminder.armedCount == 2)
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 2 })
        #expect(Set(await collector.keys) == Set(["job.A", "shell.run.token"]))
    }

    @Test("Invalid configured thresholds fall back to the policy default instead of disabling or spamming")
    func invalidThresholdFallsBackToDefault() async {
        let gate = VirtualSleepGate()
        let collector = MilestoneCollector()
        // The monitors MUST stay retained for the whole test: their armed
        // tasks hold only weak references, so a released monitor could never
        // fire and the virtual clock release would observe nothing.
        var retained: [LongRunDurationReminder] = []
        for invalid in [TimeInterval.infinity, -1, 0, .nan] {
            let reminder = LongRunDurationReminder(
                threshold: invalid,
                sink: { milestone, fence in
                    if await fence() { await collector.add(milestone) }
                },
                sleeper: { seconds in await gate.sleep(seconds) }
            )
            retained.append(reminder)
            await reminder.begin(key: "job.\(UUID().uuidString)", conversationID: nil, runID: nil,
                                 jobID: UUID(), label: "exec.shell")
        }
        #expect(await waitFor { await gate.waiterCount == 4 })
        #expect(await gate.requested == Array(repeating: LongRunDurationReminder.defaultThresholdSeconds, count: 4))
        await gate.releaseAll(true)
        #expect(await waitFor { await collector.count == 4 })
        #expect(await collector.milestones.allSatisfy { $0.thresholdSeconds == 600 })
        #expect(retained.count == 4)
    }

    @Test("Delivery fence: an end processed before the sink's fence check cancels the delivery")
    func fenceCancelsLateDelivery() async {
        let gate = VirtualSleepGate()
        let enterGate = SinkEnterGate()
        let collector = MilestoneCollector()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                // Deterministic interleave: the sink suspends HERE (after
                // the fire, before the fence check) until the test has
                // processed end(key).
                await enterGate.enter()
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        await reminder.begin(key: "shell.run.token", conversationID: nil, runID: UUID(),
                             jobID: nil, label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 1 })
        await gate.releaseAll(true)
        // The advisory fired and the sink is suspended before its fence
        // check; the unit of work now ends (the foreground run returned).
        #expect(await waitFor { await enterGate.enteredCount == 1 })
        await reminder.end(key: "shell.run.token")
        await enterGate.releaseAll()
        // The fence is closed: the delivery is cancelled, nothing alerts
        // after the actual end, and the key stays fired (never re-arms).
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await collector.count == 0)
        #expect(await reminder.hasFired(key: "shell.run.token"))
        #expect(await reminder.activeDeliveryCount == 0)
        #expect(await reminder.workIsActive(key: "shell.run.token") == false)
        await reminder.begin(key: "shell.run.token", conversationID: nil, runID: UUID(),
                             jobID: nil, label: "exec.shell")
        #expect(await gate.waiterCount == 0)
    }

    @Test("Delivery fence open: the advisory is delivered exactly once and the fence closes afterwards")
    func fenceOpenDeliversOnce() async {
        let gate = VirtualSleepGate()
        let enterGate = SinkEnterGate()
        let collector = MilestoneCollector()
        let reminder = LongRunDurationReminder(
            threshold: 600,
            sink: { milestone, fence in
                await enterGate.enter()
                if await fence() { await collector.add(milestone) }
            },
            sleeper: { seconds in await gate.sleep(seconds) }
        )
        await reminder.begin(key: "job.live", conversationID: nil, runID: nil,
                             jobID: UUID(), label: "exec.shell")
        #expect(await waitFor { await gate.waiterCount == 1 })
        await gate.releaseAll(true)
        #expect(await waitFor { await enterGate.enteredCount == 1 })
        #expect(await reminder.activeDeliveryCount == 1)
        await enterGate.releaseAll()
        #expect(await waitFor { await collector.count == 1 })
        // After the delivery completes, the fence closes on its own.
        #expect(await waitFor { await reminder.activeDeliveryCount == 0 })
        #expect(await reminder.hasFired(key: "job.live"))
        // A queued advisory can still be delivered while its command works,
        // although the one-shot sink itself has already finished.
        #expect(await reminder.workIsActive(key: "job.live"))
        await reminder.end(key: "job.live")
        #expect(await reminder.workIsActive(key: "job.live") == false)
    }
}
