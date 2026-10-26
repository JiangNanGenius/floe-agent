// FloeAppTests — foreground work session contract + standalone audio owner.
//
// The session controller is driven entirely by injected fakes over the REAL
// FloeCore policy: explicit-foreground start only, honest counts-derived
// states (never a fabricated progress), single-flight due passes, wake
// restores that are metadata-only, and ownership release. The standalone
// audio owner tests pin the second service-level truth: the task audio
// session is owned by the SERVICE for a real run batch — the PiP view is
// not required, and no settings change alone ever starts playback.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import GRDB
@testable import FloeApp

@Suite("FloeApp.BackgroundWorkSession")
@MainActor
struct BackgroundWorkSessionTests {
    private func makeController(
        counts: BackgroundWorkSessionCounts = .init(),
        passRuns: (() async -> Void)? = nil
    ) -> (BackgroundWorkSessionController, Box) {
        let box = Box()
        box.counts = counts
        let controller = BackgroundWorkSessionController(
            countsProvider: { [weak box] in
                if box?.countsFails == true {
                    throw BackgroundWorkSessionCountsUnknownError(component: "tests")
                }
                return box?.counts ?? BackgroundWorkSessionCounts()
            },
            runDuePass: { [weak box] in
                box?.passCount += 1
                await passRuns?()
            },
            onOwnershipChanged: { [weak box] snapshot in
                box?.published.append(snapshot)
            }
        )
        // Default provenance: a real current-process foreground scene with
        // loaded launch preferences; the qualification fakes record calls.
        controller.qualificationContext = { [weak box] in
            (foreground: box?.foreground ?? true, loaded: box?.loaded ?? true)
        }
        controller.submitQualification = { [weak box] (stage: String, progress: Int64) in
            guard let box else { return false }
            box.submitCount += 1
            box.lastStage = stage
            box.lastProgress = progress
            return box.submitAccepts
        }
        controller.updateQualification = { [weak box] (_: String, _: Int64) in
            box?.updateCount += 1
        }
        controller.releaseQualification = { [weak box] in
            box?.releaseCount += 1
        }
        return (controller, box)
     }

    // MARK: - Pure policy

    @Test("Only an explicit foreground user action is start authority; no wake ever auto-acquires")
    func wakeIsNeverAuthority() {
        #expect(BackgroundWorkSessionPolicy.mayStart(origin: .userInterface))
        #expect(!BackgroundWorkSessionPolicy.mayStart(origin: .systemWake))
        #expect(!BackgroundWorkSessionPolicy.mayStart(origin: .automatic))
        for wake in [BackgroundWorkWakeKind.foregroundLaunch,
                     .backgroundRefresh, .downloadRelaunch] {
            #expect(!BackgroundWorkSessionPolicy.mayAutoAcquireContinuedBackground(afterWake: wake))
            #expect(BackgroundWorkSessionPolicy.restoredState(afterWake: wake, previous: .running) == .interrupted)
            #expect(BackgroundWorkSessionPolicy.restoredState(afterWake: wake, previous: .waiting) == .interrupted)
            #expect(BackgroundWorkSessionPolicy.restoredState(afterWake: wake, previous: .armed) == .armed)
            #expect(BackgroundWorkSessionPolicy.restoredState(afterWake: wake, previous: .idle) == .idle)
        }
    }

    @Test("State derives from real counts: running needs accepted work, waiting names the blocker")
    func countsDeriveState() {
        let running = BackgroundWorkSessionCounts(liveRuns: 1)
        #expect(BackgroundWorkSessionPolicy.activeState(for: running).state == .running)
        let approvals = BackgroundWorkSessionCounts(pendingApprovals: 2)
        let approvalDecision = BackgroundWorkSessionPolicy.activeState(for: approvals)
        #expect(approvalDecision.state == .waiting)
        #expect(approvalDecision.waitReason == .approvals)
        let envBusy = BackgroundWorkSessionCounts(queuedJobs: 1, heldEnvironmentClaims: 1)
        let busyDecision = BackgroundWorkSessionPolicy.activeState(for: envBusy)
        #expect(busyDecision.waitReason == .environmentBusy)
        // A server owner counts as accepted work (location must not be
        // released while it runs); an armed record with zero counts does not.
        #expect(BackgroundWorkSessionCounts(runningJobs: 1).hasAcceptedWork)
        #expect(!BackgroundWorkSessionCounts().hasAcceptedWork)
        #expect(BackgroundWorkSessionPolicy.shouldReleaseBackgroundLocation(
            counts: BackgroundWorkSessionCounts()))
        #expect(!BackgroundWorkSessionPolicy.shouldReleaseBackgroundLocation(
            counts: BackgroundWorkSessionCounts(heldEnvironmentClaims: 1)))
        // A saved/armed toggle alone is never presented as accepted.
        #expect(!BackgroundWorkSessionPolicy.showsAsAccepted(counts: BackgroundWorkSessionCounts()))
    }

    // MARK: - Controller lifecycle

    @Test("Foreground start runs ONE finite existing pass and then reflects the real counts")
    func startRunsFinitePass() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 2))
        await controller.foregroundStart()
        #expect(box.passCount == 1)
        #expect(controller.snapshot.state == .running)
        #expect(controller.snapshot.counts.liveRuns == 2)
        #expect(controller.snapshot.startedAt != nil)
        #expect(!box.published.isEmpty)
    }

    private final class Box {
        var counts = BackgroundWorkSessionCounts()
        var countsFails = false
        var passCount = 0
        var holdPassOpen = false
        var published: [BackgroundWorkSessionSnapshot] = []
        // Qualification seam record.
        var foreground = true
        var loaded = true
        var submitAccepts = true
        var submitCount = 0
        var updateCount = 0
        var releaseCount = 0
        var lastStage: String?
        var lastProgress: Int64 = -1
    }

    @Test("Concurrent starts coalesce onto one in-flight pass (claim dedupe is the store's own)")
    func singleFlightPass() async {
        let gate = Box()
        gate.holdPassOpen = true
        let controller = BackgroundWorkSessionController(
            countsProvider: { BackgroundWorkSessionCounts() },
            runDuePass: { [weak gate] in
                gate?.passCount += 1
                while gate?.holdPassOpen == true {
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            },
            onOwnershipChanged: { _ in }
        )
        controller.qualificationContext = { (foreground: true, loaded: true) }
        async let first: Void = controller.foregroundStart()
        // Wait until the first pass is actually in flight.
        for _ in 0..<2_000 where gate.passCount == 0 {
            await Task.yield()
        }
        #expect(gate.passCount == 1)
        async let second: Void = controller.foregroundStart()
        for _ in 0..<10 { await Task.yield() }
        gate.holdPassOpen = false
        await first
        await second
        // The second start JOINED the in-flight pass: exactly one physical
        // execution, and the durable atomic claims already fence any other
        // wake's executor — there is no second scheduler.
        #expect(gate.passCount == 1)
    }

    @Test("A waiting session names the real blocker instead of fake progress")
    func waitingReflectsApprovals() async {
        let (controller, box) = makeController(counts: .init(pendingApprovals: 1))
        await controller.foregroundStart()
        #expect(controller.snapshot.state == .waiting)
        #expect(controller.snapshot.waitReason == .approvals)
        // The blocker clears to real running work (counts move), not to a
        // fabricated percent.
        box.counts = BackgroundWorkSessionCounts(liveRuns: 1)
        await controller.refresh()
        #expect(controller.snapshot.state == .running)
        #expect(controller.snapshot.waitReason == nil)
    }

    @Test("Stop keeps a durable armed record and releases session ownership; it never restarts on a wake")
    func stopArmsWithoutAuthority() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 1))
        await controller.foregroundStart()
        box.counts = BackgroundWorkSessionCounts()
        await controller.foregroundStop()
        #expect(controller.snapshot.state == .armed)
        #expect(controller.snapshot.startedAt == nil)
        let stopPublishes = box.published.count
        // A later wake restores metadata only; the armed record survives
        // unchanged and NO pass runs (passCount stays 1).
        await controller.restoreFromPersistence(
            persisted: controller.snapshot, afterWake: .downloadRelaunch)
        #expect(controller.snapshot.state == .armed)
        #expect(box.passCount == 1)
        _ = stopPublishes
    }

    @Test("A persisted running record wakes into interrupted metadata, never into a live session")
    func wakeRestoresInterrupted() async {
        let (controller, box) = makeController()
        let persisted = BackgroundWorkSessionSnapshot(
            state: .waiting,
            waitReason: .approvals,
            counts: BackgroundWorkSessionCounts(pendingApprovals: 3),
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            generation: 7
        )
        await controller.restoreFromPersistence(
            persisted: persisted, afterWake: .backgroundRefresh)
        #expect(controller.snapshot.state == .interrupted)
        #expect(controller.snapshot.waitReason == nil)
        #expect(controller.snapshot.startedAt == nil)
        // The restored record still carries the REAL last counts (honest
        // boundary), and no pass ran.
        #expect(controller.snapshot.counts.pendingApprovals == 3)
        #expect(controller.snapshot.generation == 7)
        #expect(box.passCount == 0)
        // A user action in this process freezes later wake restores.
        await controller.foregroundClear()
        await controller.restoreFromPersistence(
            persisted: persisted, afterWake: .downloadRelaunch)
        #expect(controller.snapshot.state == .idle)
    }

    @Test("Refresh never turns a non-live record into a live one")
    func refreshCannotFabricateLiveness() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 2))
        // Idle with real work elsewhere: counts update, state stays idle.
        await controller.refresh()
        #expect(controller.snapshot.state == .idle)
        #expect(controller.snapshot.counts.liveRuns == 2)
        _ = box
    }

    @Test("The snapshot persists as one atomic object and a corrupt record decodes to nothing")
    func snapshotPersistenceContract() throws {
        let snapshot = BackgroundWorkSessionSnapshot(
            state: .waiting,
            waitReason: .environmentBusy,
            counts: .init(queuedJobs: 1, heldEnvironmentClaims: 1),
            startedAt: Date(timeIntervalSince1970: 5),
            updatedAt: Date(timeIntervalSince1970: 9),
            generation: 3
        )
        let restored = try JSONDecoder().decode(
            BackgroundWorkSessionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        #expect(restored.state == .waiting)
        #expect(restored.waitReason == .environmentBusy)
        #expect(restored.counts == snapshot.counts)
        #expect(restored.startedAt == snapshot.startedAt)
        #expect(restored.generation == 3)
        let partial = try JSONDecoder().decode(
            BackgroundWorkSessionSnapshot.self,
            from: Data("{}".utf8)
        )
        #expect(partial.state == .idle)
        #expect(partial.waitReason == nil)
        #expect(partial.counts == BackgroundWorkSessionCounts())
        #expect(partial.generation == 0)
        #expect(BackgroundWorkSessionSnapshot.settingsKey == "agent.backgroundWorkSession.v1")
    }

    // MARK: - Real qualification lifecycle (BGContinuedProcessing seams)

    @Test("Start is refused without current-process foreground provenance or loaded launch preferences")
    func startRequiresRealProvenance() async {
        let (noForeground, boxA) = makeController(counts: .init(liveRuns: 1))
        boxA.foreground = false
        await noForeground.foregroundStart()
        #expect(noForeground.snapshot.state == .idle)
        #expect(boxA.passCount == 0)
        #expect(boxA.submitCount == 0)

        let (notLoaded, boxB) = makeController(counts: .init(liveRuns: 1))
        boxB.loaded = false
        await notLoaded.foregroundStart()
        #expect(notLoaded.snapshot.state == .idle)
        #expect(boxB.passCount == 0)
        #expect(boxB.submitCount == 0)
    }

    @Test("A live session with admitted work submits the real request; acceptance comes only from the framework callback")
    func qualificationRequestedThenAccepted() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 2))
        await controller.foregroundStart()
        // Submission happened through the seam with a real stage + honest
        // progress, but the display state is REQUESTED, never accepted.
        #expect(box.submitCount == 1)
        #expect(controller.qualification == .requested)
        #expect(box.lastStage?.isEmpty == false)
        #expect(box.lastProgress >= 1 && box.lastProgress <= 95)
        // The real acceptance callback flips it exactly once.
        controller.handleQualificationAccepted()
        #expect(controller.qualification == .accepted)
        // Draining one of two admitted items updates with the REAL ratio.
        box.counts = BackgroundWorkSessionCounts(liveRuns: 1)
        await controller.refresh()
        #expect(box.updateCount >= 1)
        #expect(box.lastProgress == 50)
    }

    @Test("No admitted work means no submission and no perpetual idle task")
    func noIdleQualification() async {
        let (controller, box) = makeController(counts: .init())
        await controller.foregroundStart()
        #expect(box.passCount == 1)
        #expect(controller.snapshot.state == .waiting)
        #expect(controller.snapshot.waitReason == .dueWork)
        #expect(box.submitCount == 0)
        #expect(controller.qualification == .none)
    }

    @Test("Later work joins only an actual live session and mints qualification then")
    func laterWorkJoinsLiveSession() async {
        let (controller, box) = makeController(counts: .init())
        await controller.foregroundStart()
        #expect(box.submitCount == 0)
        box.counts = BackgroundWorkSessionCounts(runningJobs: 1)
        await controller.refresh()
        #expect(box.submitCount == 1)
        #expect(controller.qualification == .requested)
        #expect(controller.snapshot.state == .running)
        // A NON-live record never gains work: stop, then move counts.
        await controller.foregroundStop()
        #expect(box.releaseCount == 1)
        #expect(controller.qualification == .none)
        box.counts = BackgroundWorkSessionCounts(liveRuns: 3)
        await controller.refresh()
        #expect(controller.snapshot.state == .armed)
        #expect(box.submitCount == 1)
    }

    @Test("Drained admitted work releases the owned qualification immediately")
    func drainedWorkReleases() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 1))
        await controller.foregroundStart()
        controller.handleQualificationAccepted()
        #expect(controller.qualification == .accepted)
        box.counts = BackgroundWorkSessionCounts()
        await controller.refresh()
        #expect(box.releaseCount == 1)
        #expect(controller.qualification == .none)
        // The session itself stays live (waiting on due work) — release of
        // the system task is not a stop of the session.
        #expect(controller.snapshot.state == .waiting)
    }

    @Test("Stop releases the owned qualification and fences late acceptance callbacks")
    func stopReleasesAndFences() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 1))
        await controller.foregroundStart()
        controller.handleQualificationAccepted()
        await controller.foregroundStop()
        #expect(box.releaseCount == 1)
        #expect(controller.qualification == .none)
        #expect(controller.snapshot.state == .armed)
        // A late framework acceptance for the stopped session is ignored.
        controller.handleQualificationAccepted()
        #expect(controller.qualification == .none)
    }

    @Test("A refused framework submission keeps the honest foreground-only state")
    func refusedSubmissionStaysForegroundOnly() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 1))
        box.submitAccepts = false
        await controller.foregroundStart()
        #expect(box.submitCount == 1)
        #expect(controller.qualification == .none)
        // Acceptance callbacks without a pending request change nothing.
        controller.handleQualificationAccepted()
        #expect(controller.qualification == .none)
    }

    @Test("Wake restore is metadata-only: it never mints qualification and ignores late acceptance")
    func wakeNeverMintsQualification() async {
        let (controller, box) = makeController()
        let persisted = BackgroundWorkSessionSnapshot(
            state: .running,
            counts: BackgroundWorkSessionCounts(liveRuns: 2),
            startedAt: Date(timeIntervalSince1970: 1),
            generation: 4
        )
        await controller.restoreFromPersistence(
            persisted: persisted, afterWake: .downloadRelaunch)
        #expect(controller.snapshot.state == .interrupted)
        #expect(controller.qualification == .none)
        #expect(box.submitCount == 0)
        // A restored saved flag is not authority: acceptance callbacks in a
        // process where the user never started are ignored.
        controller.handleQualificationAccepted()
        #expect(controller.qualification == .none)
        // Refreshing the restored record cannot fabricate liveness either.
        box.counts = BackgroundWorkSessionCounts(liveRuns: 2)
        await controller.refresh()
        #expect(controller.snapshot.state == .interrupted)
        #expect(box.submitCount == 0)
    }

    @Test("The qualification submission policy is a pure three-fact conjunction")
    func submitPolicyTable() {
        let work = BackgroundWorkSessionCounts(liveRuns: 1)
        #expect(BackgroundWorkSessionPolicy.maySubmitQualification(
            isForegroundActive: true, launchPreferencesLoaded: true, counts: work))
        #expect(!BackgroundWorkSessionPolicy.maySubmitQualification(
            isForegroundActive: false, launchPreferencesLoaded: true, counts: work))
        #expect(!BackgroundWorkSessionPolicy.maySubmitQualification(
            isForegroundActive: true, launchPreferencesLoaded: false, counts: work))
        #expect(!BackgroundWorkSessionPolicy.maySubmitQualification(
            isForegroundActive: true, launchPreferencesLoaded: true,
            counts: BackgroundWorkSessionCounts()))
    }

    // MARK: - Unknown durable facts (failed store reads)

    @Test("A failed durable read is UNKNOWN, never empty: last valid counts/state survive; nothing is released or claimed")
    func failedReadKeepsLastValidCounts() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 2))
        await controller.foregroundStart()
        #expect(controller.snapshot.state == .running)
        #expect(controller.qualification == .requested)
        let publishesBefore = box.published.count
        let updatesBefore = box.updateCount
        let releasesBefore = box.releaseCount
        // The durable counts read starts failing NOW — the real stores may
        // already show zero, but an unreadable queue is UNKNOWN, never the
        // "drained" completion evidence that would release a real
        // qualification or fake a progress ratio.
        box.countsFails = true
        box.counts = BackgroundWorkSessionCounts()
        await controller.refresh()
        #expect(controller.snapshot.counts.liveRuns == 2)
        #expect(controller.snapshot.state == .running)
        #expect(controller.qualification == .requested)
        #expect(box.published.count == publishesBefore)
        #expect(box.updateCount == updatesBefore)
        #expect(box.releaseCount == releasesBefore)
        // The next CONFIRMED read settles the truth honestly.
        box.countsFails = false
        await controller.refresh()
        #expect(box.published.count > publishesBefore)
        #expect(box.releaseCount == releasesBefore + 1)
        #expect(controller.qualification == .none)
        #expect(controller.snapshot.counts == BackgroundWorkSessionCounts())
    }

    @Test("Start on unknown counts defers without minting a session; stop stays honest and keeps the last valid counts")
    func startDeferredAndStopHonestOnUnknownCounts() async {
        let (controller, box) = makeController(counts: .init(liveRuns: 2))
        box.countsFails = true
        await controller.foregroundStart()
        // UNKNOWN facts are no facts: no session state, no publication, no
        // qualification — the finite pass itself still runs (the store's own
        // atomic claims fence every duplicate).
        #expect(controller.snapshot.state == .idle)
        #expect(box.published.isEmpty)
        #expect(box.submitCount == 0)
        #expect(box.passCount == 1)
        // With readable facts again, the explicit start works normally.
        box.countsFails = false
        await controller.foregroundStart()
        #expect(controller.snapshot.state == .running)
        #expect(controller.qualification == .requested)
        // The user's stop is honored even while the durable read fails; the
        // armed record carries the LAST VALID counts, not fabricated zeros.
        box.countsFails = true
        await controller.foregroundStop()
        #expect(controller.snapshot.state == .armed)
        #expect(controller.snapshot.counts.liveRuns == 2)
        #expect(box.releaseCount == 1)
    }

    @Test("The unknown-facts error is a read-path contract only: the persisted snapshot shape is unchanged")
    func unknownErrorIsAdditiveToPersistence() throws {
        // The failure contract is an error thrown by the counts provider —
        // the Codable shape gains nothing. A full legacy-shaped record still
        // decodes exactly as before (backward-compatible fallback).
        let legacy = Data(
            #"{"state":"armed","counts":{"liveRuns":3,"pendingApprovals":0,"runningJobs":0,"queuedJobs":0,"claimedScheduleOccurrences":0,"enabledSchedules":0,"heldEnvironmentClaims":0},"updatedAt":100.0,"generation":2}"#.utf8
        )
        let decoded = try JSONDecoder().decode(BackgroundWorkSessionSnapshot.self, from: legacy)
        #expect(decoded.state == .armed)
        #expect(decoded.counts.liveRuns == 3)
        #expect(decoded.generation == 2)
        #expect(decoded.waitReason == nil)
        // The error names only the failed component (logs, never user copy).
        #expect(BackgroundWorkSessionCountsUnknownError(component: "jobs").component == "jobs")
    }
}

// MARK: - Cold BGAppRefresh wake (readiness defer + generation fences)

/// MOCKED-FLOW suite: these drive the coordinator's REAL fenced refresh
/// sequence (`startRefreshGeneration` → `performRefreshWork` →
/// `finishRefreshGeneration`) through its DEBUG seams — the readiness gate,
/// the step trace and the completion sink replace only the OS boundary.
/// Actual `BGAppRefreshTask` delivery, OS expiration firing and the real
/// `setTaskCompleted` call remain device/simulator acceptance owned by Main
/// and are NOT claimed here. The in-process production steps (metadata
/// restore, media maintenance, finite due scan) run against the empty
/// preview store.
@Suite("FloeApp.BackgroundRefreshWake")
@MainActor
struct BackgroundRefreshWakeTests {
    @MainActor
    private final class Recorder {
        var steps: [(taskID: UUID, step: String)] = []
        var completions: [(taskID: UUID, success: Bool)] = []
        var ready = false
        /// Blocks the injected readiness gate while true (deterministic
        /// mid-wait fencing).
        var gateHeld = false

        func steps(for id: UUID) -> [String] {
            steps.filter { $0.taskID == id }.map(\.step)
        }

        func hasReachedReadiness(_ id: UUID) -> Bool {
            steps.contains { $0.taskID == id && $0.step == "readiness" }
        }
    }

    private func makeCoordinator(_ rec: Recorder) -> BackgroundRunCoordinator {
        let coordinator = BackgroundRunCoordinator(environment: .preview())
        coordinator.refreshWakeStepsForTesting = { taskID, step in
            rec.steps.append((taskID, step))
        }
        coordinator.refreshCompletionsForTesting = { taskID, success in
            rec.completions.append((taskID, success))
        }
        coordinator.refreshReadinessForTesting = {
            // Exit on cancellation too, exactly like the real bounded wait
            // would when the OS tears the wake down mid-poll.
            while rec.gateHeld, !Task.isCancelled {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return rec.ready
        }
        return coordinator
    }

    private func waitUntil(_ check: @MainActor () -> Bool) async {
        for _ in 0..<4_000 where !check() {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 250_000)
        }
    }

    @Test("The generation fence lets exactly one path close each instance; stale generations own nothing")
    func fenceAtMostOncePerGeneration() {
        var fence = BackgroundRefreshGenerationFence()
        let first = UUID()
        let second = UUID()
        #expect(fence.activeID == nil)
        fence.begin(first)
        #expect(fence.owns(first))
        #expect(!fence.owns(second))
        let mutationResult562 = fence.complete(first)
        #expect(mutationResult562)    // the owner path wins
        let mutationResult563 = fence.complete(first)
        #expect(!mutationResult563)   // never a second completion
        fence.begin(second)               // a new delivery takes the slot
        #expect(fence.owns(second))
        #expect(!fence.owns(first))       // the superseded generation owns nothing
        let mutationResult567 = fence.complete(first)
        #expect(!mutationResult567)   // its late body/expiration path is a hard no-op
        let mutationResult568 = fence.complete(second)
        #expect(mutationResult568)
        let mutationResult569 = fence.complete(second)
        #expect(!mutationResult569)
        #expect(fence.activeID == nil)
    }

    @Test("A cold refresh wake defers honestly before readiness: no metadata claim, no due scan, exactly one failed completion")
    func coldWakeDefersBeforeReadiness() async {
        let rec = Recorder()
        let coordinator = makeCoordinator(rec)
        rec.ready = false
        let id = coordinator.beginRefreshWakeForTesting()
        await coordinator.awaitRefreshWorkForTesting()
        #expect(rec.steps(for: id) == ["readiness", "deferred:automationReadyDeadline"])
        #expect(rec.completions.count == 1)
        #expect(rec.completions.first?.taskID == id)
        #expect(rec.completions.first?.success == false)
        #expect(coordinator.activeRefreshGenerationIDForTesting == nil)
    }

    @Test("Once ready the same wake restores metadata, runs the real maintenance and ONE finite existing due pass, completing true")
    func readyWakeRunsFullSequenceOnce() async {
        let rec = Recorder()
        let coordinator = makeCoordinator(rec)
        rec.ready = true
        let id = coordinator.beginRefreshWakeForTesting()
        await coordinator.awaitRefreshWorkForTesting()
        #expect(rec.steps(for: id) == ["readiness", "restore", "maintenance", "dueScan"])
        #expect(rec.completions.count == 1)
        #expect(rec.completions.first?.taskID == id)
        #expect(rec.completions.first?.success == true)
        #expect(coordinator.activeRefreshGenerationIDForTesting == nil)
    }

    @Test("Expiration during the readiness wait fences its own generation: completed once, and nothing is claimed afterwards")
    func expirationDuringReadinessStopsClaims() async {
        let rec = Recorder()
        let coordinator = makeCoordinator(rec)
        rec.ready = true
        rec.gateHeld = true
        let id = coordinator.beginRefreshWakeForTesting()
        await waitUntil { rec.hasReachedReadiness(id) }
        #expect(rec.hasReachedReadiness(id))
        // The OS expiration path fires for THIS generation while its body is
        // parked in the readiness wait: it cancels its own work and completes
        // its own task exactly once.
        coordinator.expireRefreshGenerationForTesting(taskID: id)
        #expect(rec.completions.count == 1)
        #expect(rec.completions.first?.success == false)
        #expect(coordinator.activeRefreshGenerationIDForTesting == nil)
        rec.gateHeld = false
        await coordinator.awaitRefreshWorkForTesting()
        // After the gate the body sees its generation closed/cancelled: it
        // must NOT restore, maintain, scan or complete a second time.
        let bodySteps = rec.steps(for: id)
        #expect(bodySteps.first == "readiness")
        #expect(!bodySteps.contains("restore"))
        #expect(!bodySteps.contains("maintenance"))
        #expect(!bodySteps.contains("dueScan"))
        #expect(rec.completions.count == 1)
    }

    @Test("A superseded generation's late expiration cannot cancel or complete the newer refresh; the newer still finishes normally")
    func staleGenerationCannotTouchNewer() async {
        let rec = Recorder()
        let coordinator = makeCoordinator(rec)
        rec.ready = true
        rec.gateHeld = true
        let first = coordinator.beginRefreshWakeForTesting()
        await waitUntil { rec.hasReachedReadiness(first) }
        #expect(rec.hasReachedReadiness(first))
        // A new delivery supersedes the first: the FIRST generation's slot
        // and own task close exactly once here, and its body is cancelled.
        let second = coordinator.beginRefreshWakeForTesting()
        #expect(second != first)
        #expect(coordinator.activeRefreshGenerationIDForTesting == second)
        #expect(rec.completions.count == 1)
        #expect(rec.completions.first?.taskID == first)
        #expect(rec.completions.first?.success == false)
        // The stale instance's OS expiration finally fires. It must not
        // cancel or complete the NEW generation.
        coordinator.expireRefreshGenerationForTesting(taskID: first)
        #expect(coordinator.activeRefreshGenerationIDForTesting == second)
        #expect(rec.completions.count == 1)
        // Release the gate: the stale body defers without claiming; the
        // newer generation runs its full sequence and completes true.
        rec.gateHeld = false
        await coordinator.awaitRefreshWorkForTesting()
        let firstSteps = rec.steps(for: first)
        #expect(!firstSteps.contains("restore"))
        #expect(!firstSteps.contains("dueScan"))
        let secondSteps = rec.steps(for: second)
        #expect(secondSteps.first == "readiness")
        #expect(secondSteps.last == "dueScan")
        #expect(rec.completions.count == 2)
        let secondCompletion = rec.completions.dropFirst().first
        #expect(secondCompletion?.taskID == second)
        #expect(secondCompletion?.success == true)
        #expect(coordinator.activeRefreshGenerationIDForTesting == nil)
    }
}

// MARK: - Standalone task-audio owner (service, not the PiP view)

@MainActor
private final class SessionFakeAmbient: PiPAmbientPlaying {
    private(set) var isPlaying = false
    private(set) var playCount = 0
    private(set) var stopCount = 0
    func play(sound: PiPAmbientSound, gain: Double) -> Bool {
        playCount += 1
        isPlaying = true
        return true
    }
    func setGain(_ gain: Double) {}
    func pause() { isPlaying = false }
    func resume() -> Bool { isPlaying = true; return true }
    func stop() { stopCount += 1; isPlaying = false }
}

@MainActor
private final class SessionFakeSpeech: PiPSpeechPlaying {
    let isSpeaking = false
    func speak(text: String, volume: Double, completion: @escaping @MainActor () -> Void) -> Bool { false }
    func stopAll() {}
}

@MainActor
private final class SessionFakeCue: PiPCuePlaying {
    let isPlaying = false
    func playCue(volume: Double, completion: @escaping @MainActor () -> Void) -> Bool { false }
    func stop() {}
}

@MainActor
private final class SessionFakeSession: PiPAudioSessionControlling {
    var canReleaseSession: (@MainActor () -> Bool)?
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    var isExternalOutputPresent = true
    func activate() throws { activateCount += 1 }
    func adoptActivation() { activateCount += 1 }
    func deactivateIfOwned() { deactivateCount += 1 }
}

@Suite("FloeApp.StandaloneTaskAudioOwner")
@MainActor
struct StandaloneTaskAudioOwnerTests {
    private func makeService() -> (PiPAudioService, SessionFakeAmbient, SessionFakeSession) {
        let ambient = SessionFakeAmbient()
        let session = SessionFakeSession()
        let service = PiPAudioService(
            ambient: ambient,
            speech: SessionFakeSpeech(),
            cue: SessionFakeCue(),
            session: session
        )
        return (service, ambient, session)
    }

    @Test("The audio capability owns the service session for a real task batch WITHOUT any PiP surface")
    func standaloneOwnsWithoutPiP() {
        let (service, ambient, session) = makeService()
        // No settings-only start: applying preferences never creates the
        // owner (the upgrade never auto-plays).
        service.applyPreferences(PiPAudioPreferences())
        #expect(!service.isTaskOwnerActive)
        #expect(ambient.playCount == 0)
        // A real run batch under the capability starts the owner.
        service.handleStandaloneAudioOwnerChanged(true)
        #expect(service.isTaskOwnerActive)
        #expect(service.isStandaloneAudioOwnerActive)
        #expect(!service.isPiPSurfaceOwnerActive)
        #expect(ambient.playCount == 1)
        #expect(session.activateCount >= 1)
        // Stopping it releases the loop and the session lease.
        service.handleStandaloneAudioOwnerChanged(false)
        #expect(!service.isTaskOwnerActive)
        #expect(ambient.stopCount >= 1)
        #expect(session.deactivateCount == 1)
    }

    @Test("Surface handover keeps ONE continuous owner generation")
    func ownerHandoverKeepsLoop() {
        let (service, ambient, _) = makeService()
        service.handleStandaloneAudioOwnerChanged(true)
        let playsAfterStandalone = ambient.playCount
        // The PiP surface arrives for the same batch: the combined owner
        // does not restart, duplicate or stop the loop.
        service.handleTaskPiPActiveChanged(true)
        #expect(service.isTaskOwnerActive)
        #expect(service.isPiPSurfaceOwnerActive)
        #expect(ambient.playCount == playsAfterStandalone)
        // The surface closes while the batch (standalone) keeps working:
        // the loop persists — the task owns it, not the view.
        service.handleTaskPiPActiveChanged(false)
        #expect(service.isTaskOwnerActive)
        #expect(!service.isPiPSurfaceOwnerActive)
        #expect(ambient.isPlaying)
        // Only the last owner ending stops the loop.
        service.handleStandaloneAudioOwnerChanged(false)
        #expect(!service.isTaskOwnerActive)
        #expect(!ambient.isPlaying)
    }

    @Test("A stale terminal callback cannot stop a newer owner")
    func generationGuardsLateCallbacks() {
        let (service, _, _) = makeService()
        service.handleStandaloneAudioOwnerChanged(true)
        let firstGenerationOwner = service.isTaskOwnerActive
        #expect(firstGenerationOwner)
        // The batch terminates, then a NEW batch starts. A repeated stale
        // batch-terminal report for the old owner must not touch the new one.
        service.handleRunBatchTerminal()
        service.handleRunStarted()
        #expect(service.isTaskOwnerActive)
    }
}

// MARK: - Pass cancellation fences at the actual claim → launch seam

/// These tests drive the REAL `executeScheduleOccurrence` route (production
/// claim → revalidate → settle writes against an isolated SQLite ledger)
/// through the coordinator's DEBUG driver. They prove an explicit session
/// Stop or expired-refresh cancellation can neither claim a fresh occurrence
/// while its pass is already cancelled, nor launch a new agent after the
/// claim: the claimed instance settles honestly as cancelled and the
/// predetermined run identity stays empty. Only the launch-boundary pause is
/// a seam; real background scheduling and OS wake behavior remain device
/// acceptance owned by Main.
@Suite("FloeApp.SchedulePassCancellation")
@MainActor
struct SchedulePassCancellationTests {
    @MainActor
    private final class LaunchBoundaryBox {
        var entered = false
        var released = false
    }

    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        // The isolated in-memory graph is genuinely launched for the
        // production readiness layers; no shared service roots are touched.
        environment.markIsolatedLaunchReadyForTesting()
        return environment
    }

    private func seedModel(_ environment: AppEnvironment) async throws -> ModelProfile {
        let configuration = ModelConfigurationStore(database: environment.database)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://pass-cancellation-fence.example/v1")!)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "pass-cancellation-fence-model",
            displayName: "Pass Cancellation Fence Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools])
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        await environment.conversationCenter.reload()
        return model
    }

    @Test("A cancelled pass never claims: the instance stays pending for the next wake")
    func cancelledPassNeverClaims() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let schedule = TaskScheduleRecord(
            title: "Cancel fence check",
            prompt: "Do not launch",
            workspaceID: nil,
            cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60),
            isEnabled: true,
            modelID: nil)
        try await store.save(schedule)
        let key = "manual:\(UUID().uuidString)"
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: key),
            scheduleID: schedule.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: key)
        _ = try await store.enqueueOccurrence(occurrence)
        let coordinator = environment.backgroundRunCoordinator
        // Cancel the pass BEFORE it ever starts (a Stop/expiration that
        // landed while the occurrence was still pending). The pre-claim
        // fence must refuse without touching the row.
        let pass = Task {
            await coordinator.executeScheduleOccurrenceForTesting(
                occurrence, schedule: schedule, store: store)
        }
        pass.cancel()
        let result = await pass.value
        #expect(result == .passCancelledBeforeClaim)
        let row = try await store.occurrence(id: occurrence.id)
        #expect(row?.state == .pending)
    }

    @Test("A Stop landing after the claim but before launch starts no new agent and settles the claimed instance as cancelled")
    func cancellationAfterClaimBlocksLaunch() async throws {
        let environment = try await makeEnvironment()
        let model = try await seedModel(environment)
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let schedule = TaskScheduleRecord(
            title: "Cancel fence check",
            prompt: "Must not launch",
            workspaceID: nil,
            cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60),
            isEnabled: true,
            modelID: model.id)
        try await store.save(schedule)
        let key = "manual:\(UUID().uuidString)"
        let occurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: key),
            scheduleID: schedule.id,
            scheduledFor: Date().addingTimeInterval(-60),
            dedupeKey: key)
        _ = try await store.enqueueOccurrence(occurrence)
        let coordinator = environment.backgroundRunCoordinator
        let box = LaunchBoundaryBox()
        coordinator.occurrencePrelaunchBarrierForTesting = {
            box.entered = true
            while !box.released {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        let pass = Task {
            await coordinator.executeScheduleOccurrenceForTesting(
                occurrence, schedule: schedule, store: store)
        }
        for _ in 0..<4_000 where !box.entered {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 250_000)
        }
        #expect(box.entered)
        // The atomic claim and all pre-launch revalidation succeeded (the
        // pass is paused at the launch boundary); now the Stop/expiration
        // lands.
        pass.cancel()
        box.released = true
        let result = await pass.value
        coordinator.occurrencePrelaunchBarrierForTesting = nil
        #expect(result == .cancelledBeforeLaunch)
        // The claimed instance is settled honestly as cancelled…
        let row = try await store.occurrence(id: occurrence.id)
        #expect(row?.state == .cancelled)
        // …and NO new durable run was launched at the predetermined identity.
        let runID = TaskScheduleOccurrence.stableID(
            scheduleID: schedule.id, dedupeKey: "run:\(occurrence.id.uuidString)")
        let launched = try await environment.runStore.run(id: runID)
        #expect(launched == nil)
    }
}
#endif
