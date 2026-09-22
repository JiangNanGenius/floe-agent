// FloeCoreTests — Shared background-work contract.
//
// Covers the pieces the app layer reads but cannot unit-test cheaply: the
// completion dwell + generation-safe teardown decision, the opt-in status PiP
// release gate, the durable background-work record and its deep-link identity,
// and the bounded guest metrics parsers.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.BackgroundSurfaceCompletion")
struct BackgroundSurfaceCompletionTests {

    @Test("Success holds the surface for the 3 second dwell")
    func successDwells() {
        let plan = BackgroundSurfaceCompletionPolicy.plan(
            succeeded: true,
            retainsSurfaceOnFailure: true,
            generation: 7
        )
        #expect(plan.disposition == .dwellThenTearDown)
        #expect(plan.delay == 3)
        #expect(BackgroundSurfaceCompletionPolicy.successDwell == 3)
        #expect(plan.generation == 7)
    }

    @Test("Failure with a retentive run family keeps the surface for recovery")
    func failureIsRetained() {
        let plan = BackgroundSurfaceCompletionPolicy.plan(
            succeeded: false,
            retainsSurfaceOnFailure: true,
            generation: 2
        )
        #expect(plan.disposition == .retainForRecovery)
        #expect(plan.delay == 0)
    }

    @Test("One-shot work tears down immediately on failure")
    func oneShotFailureTearsDown() {
        let plan = BackgroundSurfaceCompletionPolicy.plan(
            succeeded: false,
            retainsSurfaceOnFailure: false,
            generation: 1
        )
        #expect(plan.disposition == .tearDownImmediately)
    }

    @Test("A delayed teardown is valid only for the current generation")
    func generationGuardsTeardown() {
        #expect(BackgroundSurfaceCompletionPolicy.teardownIsCurrent(
            scheduledGeneration: 4, currentGeneration: 4
        ))
        // A newer run bumped the generation: the stale timer must not close
        // the surface that now belongs to the new run.
        #expect(!BackgroundSurfaceCompletionPolicy.teardownIsCurrent(
            scheduledGeneration: 4, currentGeneration: 5
        ))
    }
}

@Suite("FloeCore.StatusPiPReleaseGate")
struct StatusPiPReleaseGateTests {

    @Test("A PiP choice degrades to standard processing when the gate is off")
    func pipDegradesWhenDisabled() {
        #expect(StatusPiPReleaseGate.effectivePreference(
            .pictureInPicture, statusPiPEnabled: false
        ) == .standard)
    }

    @Test("Every other preference is honored regardless of the gate")
    func otherPreferencesUnchanged() {
        #expect(StatusPiPReleaseGate.effectivePreference(
            .pictureInPicture, statusPiPEnabled: true
        ) == .pictureInPicture)
        #expect(StatusPiPReleaseGate.effectivePreference(
            .standard, statusPiPEnabled: false
        ) == .standard)
        #expect(StatusPiPReleaseGate.effectivePreference(
            .screenShare, statusPiPEnabled: false
        ) == .screenShare)
        #expect(StatusPiPReleaseGate.effectivePreference(
            .screenShare, statusPiPEnabled: true
        ) == .screenShare)
    }
}

@Suite("FloeCore.BackgroundWorkModel")
struct BackgroundWorkModelTests {

    @Test("Terminal and unfinished classification is exhaustive")
    func stateClassification() {
        #expect(BackgroundWorkState.completed.isTerminal)
        #expect(BackgroundWorkState.failed.isTerminal)
        #expect(BackgroundWorkState.interrupted.isTerminal)
        #expect(BackgroundWorkState.cancelled.isTerminal)
        #expect(!BackgroundWorkState.queued.isTerminal)
        #expect(!BackgroundWorkState.running.isTerminal)
        #expect(!BackgroundWorkState.completing.isTerminal)
        #expect(!BackgroundWorkState.suspended.isTerminal)
        // Unfinished work stays actionable; a completed/cancelled run does not.
        #expect(BackgroundWorkState.failed.isUnfinished)
        #expect(BackgroundWorkState.suspended.isUnfinished)
        #expect(BackgroundWorkState.interrupted.isUnfinished)
        #expect(!BackgroundWorkState.completed.isUnfinished)
        #expect(!BackgroundWorkState.cancelled.isUnfinished)
        #expect(BackgroundWorkInterruption.checkpointed.offersRecovery)
        #expect(BackgroundWorkInterruption.terminatedBySystem.offersRecovery)
        #expect(!BackgroundWorkInterruption.none.offersRecovery)
    }

    @Test("Metrics clamp progress and never invent a GPU")
    func metricsAreBounded() {
        let clamped = BackgroundWorkMetrics(
            emulatorCPUFraction: 1.8,
            guestCPUFraction: -0.4,
            networkRxKB: -12,
            networkTxKB: 5
        )
        #expect(clamped.emulatorCPUFraction == 1)
        #expect(clamped.guestCPUFraction == 0)
        #expect(clamped.networkRxKB == 0)
        #expect(clamped.networkTxKB == 5)
        // No measurable value yet: nil renders as "—", never 0.
        #expect(clamped.guestMemoryUsedMB == nil)
        #expect(clamped.gpu == .unavailableNativeOnly)

        let snapshot = BackgroundWorkSnapshot(
            id: UUID(),
            kind: .modelRun,
            title: "t",
            progress: 42,
            deepLink: BackgroundWorkDeepLink(kind: .modelRun)
        )
        #expect(snapshot.progress == 1)
        #expect(snapshot.activeCommandCount == 0)
    }

    @Test("Elapsed time labels are stable and human readable")
    func elapsedLabels() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = BackgroundWorkSnapshot(
            id: UUID(),
            kind: .linuxSession,
            title: "env",
            startedAt: start,
            deepLink: BackgroundWorkDeepLink(kind: .linuxSession, environmentID: "env")
        )
        #expect(snapshot.elapsedSeconds(now: start.addingTimeInterval(59)) == 59)
        #expect(snapshot.elapsedTimeLabel(now: start.addingTimeInterval(59)) == "0:59")
        #expect(snapshot.elapsedTimeLabel(now: start.addingTimeInterval(3_723)) == "1:02:03")
    }

    @Test("Environment-keyed work ids are deterministic and distinct")
    func stableWorkIdentity() {
        let first = BackgroundWorkSnapshot.stableID(for: "env-1")
        let second = BackgroundWorkSnapshot.stableID(for: "env-1")
        let other = BackgroundWorkSnapshot.stableID(for: "env-2")
        #expect(first == second)
        #expect(first != other)
    }
}

@Suite("FloeCore.BackgroundWorkDeepLink")
struct BackgroundWorkDeepLinkTests {

    @Test("A model run payload round-trips its identity")
    func modelRunRoundTrip() {
        let conversationID = UUID()
        let runID = UUID()
        let link = BackgroundWorkDeepLink(
            kind: .modelRun,
            conversationID: conversationID,
            runID: runID
        )
        let parsed = BackgroundWorkDeepLink.parse(link.userInfo)
        #expect(parsed == link)
        #expect(parsed?.conversationID == conversationID)
        #expect(parsed?.runID == runID)
    }

    @Test("A Linux payload carries the environment and service identity")
    func linuxPayloadRoundTrip() {
        let jobID = UUID()
        let link = BackgroundWorkDeepLink(
            kind: .linuxService,
            environmentID: "env-9",
            serviceJobID: jobID
        )
        let parsed = BackgroundWorkDeepLink.parse(link.userInfo)
        #expect(parsed == link)
        #expect(parsed?.environmentID == "env-9")
        #expect(parsed?.serviceJobID == jobID)
        #expect(parsed?.kind == .linuxService)
    }

    @Test("Legacy notifications without a kind still route to their conversation")
    func legacyConversationOnly() {
        let conversationID = UUID()
        let parsed = BackgroundWorkDeepLink.parse(["conversationID": conversationID.uuidString])
        #expect(parsed?.kind == .modelRun)
        #expect(parsed?.conversationID == conversationID)
    }

    @Test("Unknown or empty payloads never invent a destination")
    func rejectsUnknownPayloads() {
        #expect(BackgroundWorkDeepLink.parse([:]) == nil)
        #expect(BackgroundWorkDeepLink.parse(["workKind": "somethingElse"]) == nil)
        #expect(BackgroundWorkDeepLink.parse(["workKind": "linuxSession"])?.environmentID == nil)
        #expect(BackgroundWorkDeepLink.parse([
            "workKind": "modelRun", "conversationID": "not-a-uuid"
        ])?.conversationID == nil)
    }
}

@Suite("FloeCore.BackgroundWorkRegistry")
struct BackgroundWorkRegistryTests {

    private func snapshot(
        id: UUID,
        title: String = "run",
        startedAt: Date = Date()
    ) -> BackgroundWorkSnapshot {
        BackgroundWorkSnapshot(
            id: id,
            kind: .modelRun,
            title: title,
            startedAt: startedAt,
            deepLink: BackgroundWorkDeepLink(kind: .modelRun, runID: id)
        )
    }

    @Test("Records are readable, ordered and removable")
    func registerReadAndRemove() async {
        let registry = BackgroundWorkRegistry()
        let first = UUID()
        let second = UUID()
        let now = Date()
        await registry.register(snapshot(id: second, title: "second", startedAt: now))
        await registry.register(snapshot(id: first, title: "first", startedAt: now.addingTimeInterval(-5)))

        #expect(await registry.snapshot(id: first)?.title == "first")
        #expect(await registry.allSnapshots().map(\.id) == [first, second])

        await registry.remove(id: first)
        #expect(await registry.snapshot(id: first) == nil)
        #expect(await registry.allSnapshots().count == 1)
    }

    @Test("Finishing records the terminal state and keeps it for recovery")
    func finishKeepsTerminalRecord() async {
        let registry = BackgroundWorkRegistry()
        let id = UUID()
        await registry.register(snapshot(id: id))
        await registry.finish(id: id, state: .failed, interruption: .checkpointed, progressText: "失败")

        let failed = await registry.snapshot(id: id)
        #expect(failed?.state == .failed)
        #expect(failed?.interruption == .checkpointed)
        #expect(failed?.progressText == "失败")
        // A failed record stays readable until the owner removes it: the deep
        // link and the recovery surface depend on it.
        #expect(await registry.snapshot(id: id) != nil)

        await registry.finish(id: id, state: .completed)
        let completed = await registry.snapshot(id: id)
        #expect(completed?.state == .completed)
        #expect(completed?.progress == 1)
    }

    @Test("Observers receive the current set and later changes")
    func streamPublishesSnapshots() async {
        let registry = BackgroundWorkRegistry()
        let id = UUID()
        var iterator = await registry.snapshots().makeAsyncIterator()
        #expect(await iterator.next()?.isEmpty == true)

        await registry.register(snapshot(id: id, title: "live"))
        let published = await iterator.next()
        #expect(published?.first?.title == "live")
    }
}

@Suite("FloeCore.GuestProcParsers")
struct GuestProcParserTests {

    @Test("Aggregate CPU busy time excludes idle and iowait")
    func procStatBusy() {
        let sample = GuestProcStatParser.aggregateSample("""
        cpu  100 0 50 800 50 0 0 0 0 0
        cpu0 50 0 25 400 25 0 0 0 0 0
        """)
        #expect(sample?.totalJiffies == 1000)
        #expect(sample?.busyJiffies == 150)
        #expect(GuestProcStatParser.aggregateSample("not a proc stat") == nil)
        #expect(GuestProcStatParser.aggregateSample("cpu  a b c") == nil)
    }

    @Test("Memory used is derived from MemAvailable, never guessed")
    func memInfo() {
        let sample = GuestMemInfoParser.parse("""
        MemTotal:        1048576 kB
        MemFree:          200000 kB
        MemAvailable:     600000 kB
        """)
        #expect(sample?.totalKB == 1_048_576)
        #expect(sample?.availableKB == 600_000)
        #expect(sample?.usedKB == 448_576)
        #expect(GuestMemInfoParser.megabytes(sample?.usedKB ?? 0) == 438)
        // Missing MemAvailable: used stays unknown, not zero-guessed.
        let legacy = GuestMemInfoParser.parse("MemTotal: 2048 kB")
        #expect(legacy?.usedKB == 2048)
        #expect(GuestMemInfoParser.parse("no fields here") == nil)
    }

    @Test("Network counters sum real interfaces and skip loopback")
    func netDev() {
        let counters = GuestNetDevParser.aggregateCounters("""
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo: 999999 0 0 0 0 0 0 0 999999 0 0 0 0 0 0 0
          eth0:  2048 10 0 0 0 0 0 0  1024 8 0 0 0 0 0 0
        """)
        #expect(counters.rxBytes == 2048)
        #expect(counters.txBytes == 1024)
        #expect(GuestNetDevParser.aggregateCounters("garbage").rxBytes == 0)
    }

    @Test("CPU fractions need a measurable window and stay inside 0...1")
    func deltas() {
        #expect(GuestResourceDeltas.fraction(busyDelta: 50, totalDelta: 100) == 0.5)
        #expect(GuestResourceDeltas.fraction(busyDelta: 100, totalDelta: 100) == 1)
        #expect(GuestResourceDeltas.fraction(busyDelta: 0, totalDelta: 0) == nil)
        #expect(GuestResourceDeltas.fraction(busyDelta: 0, totalDelta: 50) == 0)
    }
}
