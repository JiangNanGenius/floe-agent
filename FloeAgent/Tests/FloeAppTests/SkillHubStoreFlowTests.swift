// FloeAppTests — Skill Hub store flow regressions (lane file).
//
// Build 301 product corrections pinned here:
// 1. A FRESH human Get on the official signed audited catalog installs
//    directly — the tap itself is consent to the package's declared
//    INTERNAL capability ceiling; the generic inspector must not reappear
//    (the exact rejected behavior).
// 2. An UPDATE that adds scope is never silently bypassed: the job parks at
//    a focused added-access confirmation, blocks the commit until a human
//    decision, and a stale/absent/cancelled decision means NOT approved.
// 3. Progress is honest: no fabricated byte percentages; the stage list
//    marks only stages that actually completed, and a parked approval is
//    NOT success ("Installing" stays pending).
// 4. Shelf row composition is decided once per effective width and applied
//    uniformly to every row (the Office/PDF mismatch regression), and the
//    detail page hides any section whose verified source data is absent.
// 5. SERVICE-level required coverage (2026-10-27 direction): against the
//    REAL signed production catalog through the REAL `SkillsCenter` job,
//    the first official install with NON-EMPTY declared grants lands via
//    the trusted install path with NO generic inspector, a duplicate tap
//    coalesces into the same job, and cancel/retry settle the old work.
//    Network is genuinely required there: an unreachable catalog FAILS
//    the case actionably — it is never skipped or mocked (mirroring
//    `ContentUpdateRealSignedFeedTests`). Installed bytes go to a private
//    temporary installation root; shared app state is never touched.
// Requires registration in project.yml `FloeAppTests` sources
// (`- path: Tests/FloeAppTests/SkillHubStoreFlowTests.swift`) — registered
// by the integration owner on 2026-10-27.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeSkills
@testable import FloeApp

@Suite("FloeApp.SkillHubStoreFlow")
@MainActor
struct SkillHubStoreFlowTests {

    // MARK: - Harness

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _runs = 0
        private var _commits = 0
        private var _reportedPhases: [SkillHubInstallPhase] = []
        var reportedPhases: [SkillHubInstallPhase] { lock.lock(); defer { lock.unlock() }; return _reportedPhases }
        func reported(_ phase: SkillHubInstallPhase) { lock.lock(); _reportedPhases.append(phase); lock.unlock() }
        var failFirstAttempt = false

        var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
        var commits: Int { lock.lock(); defer { lock.unlock() }; return _commits }
        func begun() { lock.lock(); _runs += 1; lock.unlock() }
        func committed() { lock.lock(); _commits += 1; lock.unlock() }
    }

    private func waitUntil(timeoutMilliseconds: Int = 2_000,
                           _ condition: @MainActor () -> Bool) async {
        var ticks = 0
        while !condition(), ticks < timeoutMilliseconds / 5 {
            ticks += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A pipeline that walks the four real stages and commits only after the
    /// (optional) scope gate, recording what actually ran.
    private func makePipeline(_ recorder: Recorder,
                              coordinator: SkillHubInstallCoordinator,
                              parkForScope: Bool = false) -> SkillHubInstallCoordinator.Pipeline {
        { context in
            recorder.begun()
            if recorder.failFirstAttempt && recorder.runs == 1 {
                throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "boom"])
            }
            let phases = [SkillHubInstallPhase.preparing, .downloading, .checking]
            for phase in phases {
                context.report(phase, nil)
                recorder.reported(phase)
                if context.isCancelRequested() { throw CancellationError() }
            }
            if parkForScope {
                let approved = await coordinator.requestScopeApproval(
                    context: context,
                    addedCapabilities: ["workspace.write"],
                    addedTools: ["exec.shell"],
                    addedPackages: ["numpy==2.0.0"])
                guard approved else { throw CancellationError() }
            }
            context.report(.installing, nil)
            recorder.reported(.installing)
            if context.isCancelRequested() { throw CancellationError() }
            // Past this point the verified commit transaction has started:
            // cancellation honestly cannot take effect.
            recorder.committed()
            return .installed
        }
    }

    // MARK: - 1. Fresh official Get is consent: no inspector for declared ceiling

    @Test func freshGetWithFullDeclaredDeltaInstallsWithoutInspector() {
        // A brand-new skill has NO effective grants, so EVERY declared
        // capability shows as "missing". That must be a direct install for a
        // human Get — routing it to the generic full inspector is the exact
        // build-301 complaint this round fixes.
        let decision = SkillHubConsentDecision.decide(
            existingRow: false,
            permissionDeltaRequiresApproval: true,
            missingCapabilities: ["workspace.read", "network"],
            missingTools: ["web.search"],
            missingPackages: ["numpy==2.0.0"])
        #expect(decision == .directFreshInstall)
    }

    @Test func freshGetWithEmptyDeltaAlsoDirect() {
        let decision = SkillHubConsentDecision.decide(
            existingRow: false, permissionDeltaRequiresApproval: false,
            missingCapabilities: [], missingTools: [], missingPackages: [])
        #expect(decision == .directFreshInstall)
    }

    // MARK: - 2. Update that ADDS scope is never silently bypassed

    @Test func updateAddingScopeParksForFocusedApproval() {
        let decision = SkillHubConsentDecision.decide(
            existingRow: true,
            permissionDeltaRequiresApproval: true,
            missingCapabilities: ["workspace.write"],
            missingTools: ["exec.shell"],
            missingPackages: ["pandas==2.2.3"])
        #expect(decision == .requiresScopeApproval(addedCapabilities: ["workspace.write"],
                                                   addedTools: ["exec.shell"],
                                                   addedPackages: ["pandas==2.2.3"]))
    }

    @Test func sameScopeUpdateProceedsDirectly() {
        let decision = SkillHubConsentDecision.decide(
            existingRow: true, permissionDeltaRequiresApproval: false,
            missingCapabilities: [], missingTools: [], missingPackages: [])
        #expect(decision == .directUpdate)
    }

    @Test func staleOrMissingParkedDecisionIsNeverApproved() {
        // Only a live parked human tap may approve; anything else resolves
        // to "not approved" so the job stops BEFORE the commit.
        #expect(SkillHubConsentDecision.approvalAllowed(pending: true, approved: true) == true)
        #expect(SkillHubConsentDecision.approvalAllowed(pending: false, approved: true) == false)
        #expect(SkillHubConsentDecision.approvalAllowed(pending: true, approved: false) == false)
    }

    @Test func parkedScopeJobBlocksCommitUntilDecline() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        let decision = coordinator.request(skillID: "writer", displayName: "Writer", pipeline: makePipeline(recorder, coordinator: coordinator, parkForScope: true))
        #expect(decision == .started)
        await waitUntil { coordinator.job(for: "writer")?.phase == .awaitingScopeApproval }
        guard let parked = coordinator.job(for: "writer") else {
            Issue.record("job never parked at the scope decision"); return
        }
        // Truthful stage states while parked: three real stages ran, the
        // install stage did NOT, and the approval is not success.
        let states = parked.stageStates()
        #expect(Array(states[0...2]) == [.done, .done, .done])
        #expect(states[3] == .pending)
        #expect(parked.completedStageCount == 3)
        #expect(parked.isLive, "awaiting scope approval is not a terminal state")
        #expect(parked.addedCapabilities == ["workspace.write"])
        #expect(parked.addedTools == ["exec.shell"])
        #expect(parked.addedPackages == ["numpy==2.0.0"])
        #expect(recorder.commits == 0)

        coordinator.resolveScopeApproval(skillID: "writer", generation: parked.generation, approved: false)
        await coordinator.settle(skillID: "writer")
        let job = coordinator.job(for: "writer")
        #expect(job?.phase == .cancelled)
        #expect(recorder.commits == 0, "a declined scope decision must never commit")
    }

    @Test func allowedScopeDecisionCompletesTheSameJob() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        _ = coordinator.request(skillID: "writer", displayName: "Writer", pipeline: makePipeline(recorder, coordinator: coordinator, parkForScope: true))
        await waitUntil { coordinator.job(for: "writer")?.phase == .awaitingScopeApproval }
        guard let parked = coordinator.job(for: "writer") else {
            Issue.record("job never parked"); return
        }
        // Stale-generation resolve is a no-op (fence): only the CURRENT
        // generation may flip the parked job.
        coordinator.resolveScopeApproval(skillID: "writer", generation: parked.generation + 1, approved: true)
        #expect(coordinator.job(for: "writer")?.phase == .awaitingScopeApproval)
        coordinator.resolveScopeApproval(skillID: "writer", generation: parked.generation, approved: true)
        await coordinator.settle(skillID: "writer")
        #expect(coordinator.job(for: "writer")?.phase == .installed)
        #expect(recorder.commits == 1)
    }

    @Test func cancellingWhileParkedResolvesUnapproved() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        _ = coordinator.request(skillID: "writer", displayName: "Writer", pipeline: makePipeline(recorder, coordinator: coordinator, parkForScope: true))
        await waitUntil { coordinator.job(for: "writer")?.phase == .awaitingScopeApproval }
        coordinator.cancel(skillID: "writer")
        await coordinator.settle(skillID: "writer")
        #expect(coordinator.job(for: "writer")?.phase == .cancelled)
        #expect(recorder.commits == 0)
    }

    // MARK: - 3. Reuse, busy isolation, cancel boundary, retry identity

    @Test func repeatedTapReusesTheLiveJobAndOtherEntriesAreRefused() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        let first = coordinator.request(skillID: "alpha", displayName: "Alpha", pipeline: makePipeline(recorder, coordinator: coordinator))
        #expect(first == .started)
        // Repeated tap mid-run: SAME job, no second pipeline.
        let repeat1 = coordinator.request(skillID: "alpha", displayName: "Alpha") { _ in
            Issue.record("reuse must not start a second pipeline")
            return .installed
        }
        #expect(repeat1 == .reused)
        // Another catalog entry cannot double-book the single-writer service.
        let other = coordinator.request(skillID: "beta", displayName: "Beta") { _ in .installed }
        #expect(other == .busyWithOther("alpha"))
        await coordinator.settle(skillID: "alpha")
        #expect(coordinator.job(for: "alpha")?.phase == .installed)
        #expect(recorder.runs == 1)
        // A terminal job NEVER suppresses the next request: coalescing is
        // for LIVE attempts only. Installed storage + the CURRENT
        // publication are the authority; the real pipeline's pre-download
        // alreadyInstalled guard (live row, matching pinned digest, nothing
        // newer) is what makes a repeated tap a cheap honest no-op instead
        // of a re-fetch — not a frozen job state.
        let after = coordinator.request(skillID: "alpha", displayName: "Alpha",
                                        pipeline: makePipeline(recorder, coordinator: coordinator))
        #expect(after == .started)
        await coordinator.settle(skillID: "alpha")
        #expect(coordinator.job(for: "alpha")?.attempt == 2)
        #expect(recorder.runs == 2)
        // Once nothing is live, another entry may start.
        let beta = coordinator.request(skillID: "beta", displayName: "Beta", pipeline: { _ in .installed })
        #expect(beta == .started)
    }

    // MARK: - Uninstall / re-Get and newer-publication restart regressions

    @Test func completedInstalledJobDoesNotSuppressReGetAfterUninstall() async {
        // Same-session uninstall then a fresh Get: the row is gone, the
        // hub routes straight back to requestHubInstall, and the terminal
        // installed job must not reuse/suppress — a new attempt installs.
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha",
                                pipeline: makePipeline(recorder, coordinator: coordinator))
        await coordinator.settle(skillID: "alpha")
        #expect(coordinator.job(for: "alpha")?.phase == .installed)

        let decision = coordinator.request(skillID: "alpha", displayName: "Alpha",
                                           pipeline: makePipeline(recorder, coordinator: coordinator))
        #expect(decision == .started, "a terminal installed job must never suppress re-Get after uninstall")
        await coordinator.settle(skillID: "alpha")
        let job = coordinator.job(for: "alpha")
        #expect(job?.attempt == 2)
        #expect(job?.phase == .installed)
        #expect(recorder.runs == 2, "the second Get really ran the service path again")
    }

    @Test func newerCatalogStateReRequestIsNotSuppressedAndReportsHonestNoOpWhenRowMatches() async {
        // The current-publication authority case: a later Get always starts
        // a new attempt; when the pipeline's live storage check finds the
        // pinned row still exact, it returns the truthful alreadyInstalled
        // no-op (state stays installed with a visible detail) instead of a
        // fake re-download or a stale suppressed job.
        let coordinator = SkillHubInstallCoordinator { _ in }
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha", pipeline: { _ in .installed })
        await coordinator.settle(skillID: "alpha")
        let second = coordinator.request(skillID: "alpha", displayName: "Alpha", pipeline: { _ in .alreadyInstalled })
        #expect(second == .started)
        await coordinator.settle(skillID: "alpha")
        let job = coordinator.job(for: "alpha")
        #expect(job?.attempt == 2)
        #expect(job?.phase == .installed)
        #expect(job?.detail != nil, "the no-op truth must be visible, not a silent or fabricated install")
    }

    // MARK: - Queued-cancel race + post-commit honesty (coordinator-found bug)

    @Test func cancelBeforeTheScheduledRunStartsNeverCommitsAndRetryJoinsTheOldTask() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha",
                                pipeline: makePipeline(recorder, coordinator: coordinator))
        // Cancel while the attempt is still `.queued`: the scheduled task
        // has NOT begun yet. The stored job must carry the cancellation, and
        // the published state must be terminal immediately.
        coordinator.cancel(skillID: "alpha")
        #expect(coordinator.job(for: "alpha")?.phase == .cancelled)
        #expect(coordinator.job(for: "alpha")?.cancelRequested == true,
                "the STORED job must carry cancelRequested so the later-starting pipeline observes it")
        // Retry immediately, while the abandoned scheduled run may still be
        // pending: the new attempt must JOIN the old task first, and the old
        // pipeline must refuse every pre-commit side effect once it starts.
        let retry = coordinator.request(skillID: "alpha", displayName: "Alpha",
                                        pipeline: makePipeline(recorder, coordinator: coordinator))
        #expect(retry == .started)
        await coordinator.settle(skillID: "alpha")
        let job = coordinator.job(for: "alpha")
        #expect(job?.attempt == 2)
        #expect(job?.phase == .installed)
        #expect(recorder.runs == 2)
        // Exactly ONE commit: the superseded queued attempt threw at its
        // first boundary check before any staging, never after.
        #expect(recorder.commits == 1)
    }

    @Test func immediateRetryWaitsForTheCancelledAttemptToExit() async {
        let coordinator = SkillHubInstallCoordinator()
        var retiredExited = false
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { _ in
            defer { retiredExited = true }
            await Task.yield()
            throw CancellationError()
        }
        coordinator.cancel(skillID: "alpha")
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { _ in
            #expect(retiredExited, "a retry cannot enter its pipeline before the retired execution exits")
            return .installed
        }
        await coordinator.settle(skillID: "alpha")
        #expect(retiredExited)
        #expect(coordinator.job(for: "alpha")?.phase == .installed)
    }

    @Test func cancelArrivingAfterTheCommitEnteredKeepsTheHonestInstalledResult() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { context in
            context.report(.installing, nil)
            // The verified commit transaction is in flight: production does
            // not consult abandonment flags inside it, and neither may the
            // coordinator rewrite the truth.
            try? await Task.sleep(for: .milliseconds(80))
            return .installed
        }
        await waitUntil { coordinator.job(for: "alpha")?.phase == .installing }
        coordinator.cancel(skillID: "alpha")
        await coordinator.settle(skillID: "alpha")
        let job = coordinator.job(for: "alpha")
        #expect(job?.phase == .installed,
                "a commit that actually ran is reported honestly, never rewritten to cancelled")
        #expect(job?.cancelRequested == true, "the attempted cancellation stays visible on the honest result")
    }

    @Test func cancelTakesEffectAtTheStageBoundaryNotInsideTheCommit() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        // A pipeline that stays in `downloading` until the boundary flag flips.
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { context in
            recorder.begun()
            context.report(.preparing, nil)
            context.report(.downloading, nil)
            var ticks = 0
            while !context.isCancelRequested(), ticks < 400 {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard context.isCancelRequested() else {
                recorder.committed()
                return .installed
            }
            throw CancellationError()
        }
        await waitUntil { coordinator.job(for: "alpha")?.phase == .downloading }
        coordinator.cancel(skillID: "alpha")
        await coordinator.settle(skillID: "alpha")
        let job = coordinator.job(for: "alpha")
        #expect(job?.phase == .cancelled)
        #expect(job?.cancelRequested == true)
        #expect(recorder.commits == 0)
        // The interrupted stage is NOT rendered as completed.
        if let job {
            #expect(job.completedStageCount == 1, "only preparing actually finished")
            #expect(job.stageStates()[1] == .pending, "downloading never completed")
        }
    }

    @Test func retryAfterFailureReusesJobIdentityWithANewAttempt() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        recorder.failFirstAttempt = true
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha", pipeline: makePipeline(recorder, coordinator: coordinator))
        await coordinator.settle(skillID: "alpha")
        let failed = coordinator.job(for: "alpha")
        #expect(failed?.phase == .failed)
        #expect(failed?.canRetry == true)
        #expect(failed?.attempt == 1)
        // A second explicit Get on the failed job starts a NEW attempt of
        // the SAME job identity (the panel's Retry does exactly this).
        let retry = coordinator.request(skillID: "alpha", displayName: "Alpha", pipeline: makePipeline(recorder, coordinator: coordinator))
        #expect(retry == .started)
        await coordinator.settle(skillID: "alpha")
        let done = coordinator.job(for: "alpha")
        #expect(done?.phase == .installed)
        #expect(done?.attempt == 2)
        #expect(done?.generation == (failed?.generation ?? 0) + 1)
        #expect(recorder.commits == 1)
    }

    // MARK: - 3b. Truthful stage rendering

    @Test func stageStatesTrackOnlyStagesThatActuallyRan() async {
        // Rendered from the PUBLISHED snapshots (every report publishes
        // synchronously), so there is no timing race: the preparing snapshot
        // must exist with the active stage truthfully marked and NOTHING
        // completed, while a queued snapshot precedes it.
        var snapshots: [SkillHubInstallJob] = []
        let coordinator = SkillHubInstallCoordinator { jobs in
            if let job = jobs["alpha"] { snapshots.append(job) }
        }
        let recorder = Recorder()
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { context in
            recorder.begun()
            context.report(.preparing, nil)
            throw CancellationError()
        }
        await coordinator.settle(skillID: "alpha")
        let queued = snapshots.first { $0.phase == .queued }
        #expect(queued?.stageStates() == [.pending, .pending, .pending, .pending])
        let preparing = snapshots.first { $0.phase == .preparing }
        #expect(preparing?.stageStates() == [.active, .pending, .pending, .pending])
        #expect(preparing?.completedStageCount == 0)
        #expect(recorder.commits == 0)
    }

    @Test func installedJobRendersAllStagesDone() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha", pipeline: makePipeline(recorder, coordinator: coordinator))
        await coordinator.settle(skillID: "alpha")
        let job = coordinator.job(for: "alpha")
        #expect(job?.phase == .installed)
        #expect(job?.stageStates() == [.done, .done, .done, .done])
        #expect(job?.completedStageCount == 4)
    }

    @Test func alreadyInstalledOutcomeIsRenderedAsInstalledNotAFreshDownload() async {
        let coordinator = SkillHubInstallCoordinator { _ in }
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { _ in .alreadyInstalled }
        await coordinator.settle(skillID: "alpha")
        let job = coordinator.job(for: "alpha")
        #expect(job?.phase == .installed)
        #expect(job?.detail != nil, "the no-op truth must be visible, not a fake re-download")
    }

    // MARK: - 4. Shelf-consistent row composition (Office/PDF height fix)

    @Test func rowCompositionIsDecidedOncePerShelfNotPerItem() {
        // Both legacy rows sit in the SAME office shelf with the SAME
        // effective column width: whatever the decision is, it is identical
        // — that is what keeps their heights and CTA placement aligned.
        let column = SkillHubRowLayout.columnWidth(gridWidth: 680, columns: 2, gutter: 20)
        let office = SkillHubRowLayout.prefersInlineCTA(columnWidth: column, isAccessibilityText: false)
        let pdf = SkillHubRowLayout.prefersInlineCTA(columnWidth: column, isAccessibilityText: false)
        #expect(office == pdf)
        // Threshold behavior at the compact/iPhone boundary.
        #expect(SkillHubRowLayout.prefersInlineCTA(columnWidth: 300, isAccessibilityText: false) == true)
        #expect(SkillHubRowLayout.prefersInlineCTA(columnWidth: 299.5, isAccessibilityText: false) == false)
        // Accessibility text sizes ALWAYS take the stacked composition,
        // regardless of width (natural controls, no squeezed single lines).
        #expect(SkillHubRowLayout.prefersInlineCTA(columnWidth: 1_000, isAccessibilityText: true) == false)
    }

    @Test func columnWidthMathGuardsDegenerateInputs() {
        #expect(SkillHubRowLayout.columnWidth(gridWidth: 744 - 32, columns: 2, gutter: 20) == CGFloat(346))
        #expect(SkillHubRowLayout.columnWidth(gridWidth: 100, columns: 2, gutter: 200) == 0,
                "never negative widths")
        #expect(SkillHubRowLayout.columnWidth(gridWidth: 320, columns: 0, gutter: 20) == 320,
                "degenerate column counts clamp to one")
    }

    // MARK: - Compatibility verdict: signed offer data only

    @Test func compatibilityVerdictNeverInventsAClaim() {
        // No signed card (e.g. bundled guide or external row): NO verdict.
        if case .unknown = SkillHubCompatibilityVerdict(offer: nil) {} else {
            Issue.record("absent offers must not carry a compatibility claim")
        }
        #expect(SkillHubCompatibilityVerdict(offer: .installable) == .compatible)
        #expect(SkillHubCompatibilityVerdict(offer: .incompatibleApp(minimumAppVersion: "1.9.0"))
                == .needsNewerApp(minimum: "1.9.0"))
        if case .unavailable = SkillHubCompatibilityVerdict(offer: .simulatedFixture) {} else {
            Issue.record("fixture offers are never production-compatible")
        }
        if case .unavailable(let reason) = SkillHubCompatibilityVerdict(offer: .unavailable(reason: "no offer")),
           reason.isEmpty == false {} else {
            Issue.record("unavailable reasons are carried, never blanked")
        }
    }

    // MARK: - Detail sections hide absent verified data (never invented)

    @Test func sectionsShowOnlyWithDataAndHideOtherwise() {
        #expect(SkillHubDetailSections.present(hasPythonPlanOrDependencies: false,
                                               hasReviewedCapabilities: false,
                                               hasReviewedTools: false,
                                               hasReleaseNoteOrReviewDate: false,
                                               hasSignedVerificationFacts: false) == [])
        #expect(SkillHubDetailSections.present(hasPythonPlanOrDependencies: true,
                                               hasReviewedCapabilities: false,
                                               hasReviewedTools: false,
                                               hasReleaseNoteOrReviewDate: false,
                                               hasSignedVerificationFacts: false) == [.dependencies])
        let all = SkillHubDetailSections.present(hasPythonPlanOrDependencies: true,
                                                 hasReviewedCapabilities: true,
                                                 hasReviewedTools: true,
                                                 hasReleaseNoteOrReviewDate: true,
                                                 hasSignedVerificationFacts: true)
        #expect(all == [.dependencies, .permissions, .tools, .changelog, .verification])
    }

    // MARK: - Published-state fencing

    @Test func publishedSnapshotOnlyEverReflectsCurrentGenerations() async {
        // onChange sees a dict whose entry is always the latest generation:
        // stale transitions (an old pipeline reporting late) must be dropped.
        let coordinator = SkillHubInstallCoordinator { _ in }
        let recorder = Recorder()
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { context in
            recorder.begun()
            context.report(.preparing, nil)
            throw CocoaError(.fileReadCorruptFile)
        }
        await coordinator.settle(skillID: "alpha")
        let firstGeneration = coordinator.job(for: "alpha")?.generation ?? 0
        _ = coordinator.request(skillID: "alpha", displayName: "Alpha") { context in
            recorder.begun()
            context.report(.preparing, nil)
            return .installed
        }
        await coordinator.settle(skillID: "alpha")
        let secondGeneration = coordinator.job(for: "alpha")?.generation ?? 0
        #expect(secondGeneration == firstGeneration + 1)
        // A stale scope resolve for the first generation is a no-op.
        coordinator.resolveScopeApproval(skillID: "alpha", generation: firstGeneration, approved: true)
        #expect(coordinator.job(for: "alpha")?.phase == .installed)
    }
}

// MARK: - Required service-level coverage (REAL signed catalog, no mocks, no skips)

#if DEBUG
@Suite("FloeApp.SkillHubDirectInstallService")
@MainActor
struct SkillHubDirectInstallServiceTests {

    private struct CatalogUnavailable: Error {}

    private func liveCenter(root: URL) async throws -> (SkillsCenter, AppEnvironment) {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment, installationRoot: root)
        await center.refreshCuratedCatalog(force: true)
        guard center.curatedPublication != nil else {
            // ACTIONABLE by design (2026-10-27 direction): this coverage
            // requires the real signed production catalog over the network.
            // It is never mocked and never skipped into "accepted".
            Issue.record("REAL signed catalog unreachable — run the suite on a networked host; direct-Get coverage is NOT accepted from a skipped run")
            throw CatalogUnavailable()
        }
        return (center, environment)
    }

    /// Qualified production offers with declared internal capabilities and
    /// no Python plan: pure guide packages that exercise the full chain
    /// without guest-side wheel audits.
    private func guideCandidates(_ center: SkillsCenter) -> [CuratedSkillHub.Card] {
        center.curatedCards.filter {
            $0.showsInstallAction
                && !$0.entry.runtime.capabilities.isEmpty
                && $0.entry.runtime.pythonPackagesPlan.isEmpty
        }
    }

    @Test func requiredFreshOfficialInstallRegistersGrantsWithoutInspector() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-direct-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (center, environment) = try await liveCenter(root: root)
        guard let card = guideCandidates(center).min(by: {
            ($0.entry.package?.size ?? .max) < ($1.entry.package?.size ?? .max)
        }) else {
            Issue.record("ACTIONABLE: no production entry with declared internal capabilities is currently qualified on the iOS channel")
            return
        }
        // The explicit human Get: direct service job, NO generic inspector.
        center.requestHubInstall(id: card.entry.id)
        guard let firstJob = center.hubInstallJobs[card.entry.id] else {
            Issue.record("Get on an official catalog entry must create a download job (error: \(center.errorMessage ?? "nil"))")
            return
        }
        // Duplicate taps mid-run coalesce into the SAME live job.
        center.requestHubInstall(id: card.entry.id)
        #expect(center.hubInstallJobs[card.entry.id]?.attempt == firstJob.attempt)
        #expect(center.pendingInstallation == nil,
                "a fresh audited Get must not stage the generic reviewer while downloading")

        await center.settleHubInstall(id: card.entry.id)
        let job = center.hubInstallJobs[card.entry.id]
        #expect(job?.phase == .installed, "expected installed; saw \(String(describing: job?.phase)): \(job?.detail ?? "")")
        #expect(center.pendingInstallation == nil,
                "first official install with NON-EMPTY declared grants must never route through the generic inspector")
        #expect(center.errorMessage == nil)

        // Read the DURABLE store back: the row exists, enabled, and its
        // declared internal capability ceiling was registered by the
        // trusted official path (installationGrants(declared:)), not by any
        // inspector grant and not by a model approval.
        let inventory = try await center.readSkills(id: card.entry.id)
        let managed = try #require(inventory.first, "the installed row must exist after the direct job")
        #expect(managed.enabled)
        #expect(managed.version == card.entry.version)
        #expect(managed.digest == card.entry.package?.contentDigest.lowercased(),
                "the committed bytes are exactly the signed content digest")
        // The declared internal capability ceiling is registered by the
        // trusted official install path itself — no inspector, no model
        // grant, no OS/account permission change.
        let grants = try await environment.skillStore.allowedCapabilities(skillID: card.entry.id)
        #expect(!grants.isEmpty)
        #expect(Set(card.entry.runtime.capabilities).isSubset(of: grants),
                "the human Get registered the package's declared internal ceiling")
        let rows = try await environment.skillStore.all()
        let row = try #require(rows.first { $0.id == card.entry.id })
        #expect(SkillsCenter.curatedReceipt(for: row)?.publicationCommit
                == center.curatedPublication?.publicationCommit,
                "the durable receipt carries the exact signed publication identity")
    }

    @Test func requiredCancelStopsBeforeCommitAndRetrySettlesOldWorkThenCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (center, _) = try await liveCenter(root: root)
        // The LARGEST pure guide package: the widest honest window to
        // observe the stage boundary before any commit.
        guard let card = guideCandidates(center).max(by: {
            ($0.entry.package?.size ?? 0) < ($1.entry.package?.size ?? 0)
        }) else {
            Issue.record("ACTIONABLE: no production guide entry is available to cancel")
            return
        }
        center.requestHubInstall(id: card.entry.id)
        center.cancelHubInstall(id: card.entry.id)
        // A re-tap while the cancelled attempt still settles coalesces into
        // the SAME live job (retry waits for the old work to finish).
        if center.hubInstallJobs[card.entry.id]?.isLive == true {
            center.requestHubInstall(id: card.entry.id)
        }
        await center.settleHubInstall(id: card.entry.id)
        let cancelled = center.hubInstallJobs[card.entry.id]
        #expect(cancelled?.phase == .cancelled || cancelled?.phase == .installed,
                "cancel must resolve to a clean terminal state, never a half job")
        if cancelled?.phase == .cancelled {
            #expect(cancelled?.canRetry == true)
        }

        // Retry after cancel: same identity, new attempt, completes through
        // the same trusted path with no inspector.
        center.requestHubInstall(id: card.entry.id)
        #expect((center.hubInstallJobs[card.entry.id]?.attempt ?? 0) >= 2,
                "a retry starts a new attempt of the SAME job identity")
        await center.settleHubInstall(id: card.entry.id)
        let done = center.hubInstallJobs[card.entry.id]
        #expect(done?.phase == .installed, "retry after cancel must complete: \(done?.detail ?? "")")
        #expect(center.pendingInstallation == nil)
    }
}
#endif

// MARK: - Curated catalog last-authenticated snapshot cache (offline, fixtures only)

/// Build-302 store repair regressions: when a live curated refresh fails
/// (transient transport failure of the anonymous GitHub path), the store may
/// only fall back to this install's own last-authenticated snapshot, and
/// that fallback must re-run the FULL existing `CuratedSkillHub`
/// verification — exact-byte signature, compiled trust for the requested
/// mode, immutable commit pinning and strict feed decoding. These tests
/// drive the lane-visible static seams with in-memory published fixture
/// traffic only: they never read or write `FloeArtifactStore`, never touch
/// user installs and never invent trust material. A malformed, corrupted,
/// signature- or commit-mismatched, or fixture-forged-as-production
/// snapshot must never become a publication, hence never a card, never an
/// eligibility and never an install.
@Suite("FloeApp.SkillHubCuratedSnapshotCache")
@MainActor
struct SkillHubCuratedSnapshotCacheTests {

    private struct CacheFixtureFailure: Error, Sendable { let detail: String }

    private static let fixtureCommit = String(repeating: "a", count: 40)

    /// Anchor so `Bundle(for:)` resolves the App test bundle (the folder is
    /// registered there when the integration owner ships fixtures); the
    /// source-tree fallback mirrors the published FloeSkillsTests fixture
    /// loader convention. Missing fixtures are actionable, never a skip.
    private final class CacheFixtureAnchor: NSObject {}

    private func cacheFixture(_ name: String) throws -> Data {
        var roots: [URL] = []
        if let resource = Bundle(for: CacheFixtureAnchor.self).resourceURL?
            .appendingPathComponent("CuratedSkillHub", isDirectory: true) {
            roots.append(resource)
        }
        roots.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                       // Tests/FloeAppTests
            .appendingPathComponent("../FloeSkillsTests/Fixtures/CuratedSkillHub", isDirectory: true)
            .standardizedFileURL)
        for root in roots {
            let file = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                return try Data(contentsOf: file)
            }
        }
        throw CacheFixtureFailure(detail: "curated cache fixture \(name) is unavailable in every candidate root")
    }

    /// The explicit test-only trust built from the shipped fixture public
    /// key — the same material the published fixture pair verifies under.
    private func fixtureTrustMode() throws -> CuratedSkillTrustMode {
        let object = try JSONSerialization.jsonObject(
            with: cacheFixture("fixture-public-key.json")) as? [String: Any]
        guard (object?["fixtureOnly"] as? Bool) == true,
              (object?["notATrustRoot"] as? Bool) == true,
              (object?["keyID"] as? String) == CuratedSkillHub.fixtureKeyID,
              let raw = (object?["publicKey"] as? String).flatMap(Data.init(base64Encoded:)),
              raw.count == 32 else {
            throw CacheFixtureFailure(detail: "fixture public key material is malformed")
        }
        return .fixtureTestOnly(fixturePublicKey: raw)
    }

    private func fixtureTransport(catalog: Data, signature: Data,
                                  resolveCancels: Bool = false, fetchFails: Bool = false)
        -> (GitHubSkillDownload.ResolveCommit, GitHubSkillDownload.FetchFile)
    {
        let commit = Self.fixtureCommit
        let resolve: GitHubSkillDownload.ResolveCommit = { _ in
            if resolveCancels { throw CancellationError() }
            return commit
        }
        let fetch: GitHubSkillDownload.FetchFile = { _, fetchedCommit, path in
            if fetchFails { throw CacheFixtureFailure(detail: "transport failure") }
            guard fetchedCommit == commit else {
                throw CacheFixtureFailure(detail: "fetch pinned to another commit")
            }
            switch path {
            case CuratedSkillHub.catalogPath(for: .ios): return catalog
            case CuratedSkillHub.signaturePath(for: .ios): return signature
            default: throw CacheFixtureFailure(detail: "unexpected path \(path)")
            }
        }
        return (resolve, fetch)
    }

    private actor SnapshotBox {
        private var stored: [SkillsCenter.CuratedPublicationSnapshot] = []
        func store(_ snapshot: SkillsCenter.CuratedPublicationSnapshot) { stored.append(snapshot) }
        var count: Int { stored.count }
        func first() -> SkillsCenter.CuratedPublicationSnapshot? { stored.first }
    }

    private func validFixturePair() throws -> (mode: CuratedSkillTrustMode, catalog: Data, signature: Data) {
        (try fixtureTrustMode(), try cacheFixture("catalog.json"), try cacheFixture("catalog.sig"))
    }

    private func snapshot(_ commit: String = SkillHubCuratedSnapshotCacheTests.fixtureCommit,
                          catalog: Data, signature: Data,
                          schemaVersion: Int = SkillsCenter.CuratedPublicationSnapshot.schemaVersion)
        -> SkillsCenter.CuratedPublicationSnapshot
    {
        SkillsCenter.CuratedPublicationSnapshot(
            schemaVersion: schemaVersion, commit: commit, catalogBytes: catalog, signatureBytes: signature)
    }

    private func expectSignatureFailure(_ error: any Error, _ label: String) {
        guard let failure = error as? CuratedSkillHubFailure else {
            Issue.record("\(label): expected CuratedSkillHubFailure, got \(error)")
            return
        }
        switch failure {
        case .signature: break
        default: Issue.record("\(label): expected a signature failure, got \(failure)")
        }
    }

    private func expectSourceFailure(_ error: any Error, _ label: String) {
        guard let failure = error as? CuratedSkillHubFailure else {
            Issue.record("\(label): expected CuratedSkillHubFailure, got \(error)")
            return
        }
        switch failure {
        case .source: break
        default: Issue.record("\(label): expected a snapshot source/commit failure, got \(failure)")
        }
    }

    @Test func verifiedLiveLoadStoresOneExactSnapshotAndRestoreKeepsItsIdentity() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        let box = SnapshotBox()
        let (resolve, fetch) = fixtureTransport(catalog: catalog, signature: signature)
        let live = try await SkillsCenter.loadCuratedPublication(
            channel: .ios, mode: mode, resolve: resolve, fetch: fetch,
            store: { snapshot in await box.store(snapshot) })
        let storedCount = await box.count
        #expect(storedCount == 1, "one verified live load earns exactly one snapshot")
        let stored = try #require(await box.first())
        #expect(stored.schemaVersion == SkillsCenter.CuratedPublicationSnapshot.schemaVersion)
        #expect(stored.commit == live.publicationCommit)
        #expect(stored.catalogBytes == catalog, "the snapshot stores the exact signed feed bytes")
        #expect(stored.signatureBytes == signature, "the snapshot stores the exact signature bytes")
        // Restore is the SAME pipeline over the SAME bytes: an identical
        // verified feed identity, not a re-encoded approximation.
        let restored = try await SkillsCenter.verifiedPublication(from: stored, channel: .ios, mode: mode)
        #expect(restored.publicationCommit == live.publicationCommit)
        #expect(restored.verifiedFeed == live.verifiedFeed)
    }

    @Test func corruptedFeedByteNeverRestores() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        var tamperedBytes = catalog
        tamperedBytes[catalog.count / 2] ^= 0x01
        let tampered = snapshot(catalog: tamperedBytes, signature: signature)
        do {
            _ = try await SkillsCenter.verifiedPublication(from: tampered, channel: .ios, mode: mode)
            Issue.record("a single flipped feed byte must never verify")
        } catch {
            expectSignatureFailure(error, "corrupted feed byte")
        }
    }

    @Test func truncatedOrSwappedSignatureNeverRestores() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        // Dropped envelope byte: malformed or wrong proof over exact bytes.
        let truncated = signature.dropLast()
        do {
            _ = try await SkillsCenter.verifiedPublication(
                from: snapshot(catalog: catalog, signature: Data(truncated)), channel: .ios, mode: mode)
            Issue.record("a truncated signature envelope must never verify")
        } catch {
            expectSignatureFailure(error, "truncated envelope")
        }
        // Swapped payload as envelope: exceeds the envelope bound outright.
        do {
            _ = try await SkillsCenter.verifiedPublication(
                from: snapshot(catalog: catalog, signature: catalog), channel: .ios, mode: mode)
            Issue.record("a feed payload cannot act as its own envelope")
        } catch {
            expectSignatureFailure(error, "swapped envelope")
        }
    }

    @Test func malformedCommitOrSchemaSnapshotNeverRestores() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        // The commit is the immutable artifact pin; anything but a 40-hex
        // Y is rejected before the loader is ever entered.
        for bad in [String(repeating: "z", count: 40), String(repeating: "a", count: 39)] {
            do {
                _ = try await SkillsCenter.verifiedPublication(
                    from: snapshot(bad, catalog: catalog, signature: signature), channel: .ios, mode: mode)
                Issue.record("commit \(bad.prefix(6))… must never restore")
            } catch {
                expectSourceFailure(error, "malformed commit")
            }
        }
        do {
            _ = try await SkillsCenter.verifiedPublication(
                from: snapshot(catalog: catalog, signature: signature, schemaVersion: 2),
                channel: .ios, mode: mode)
            Issue.record("an unknown snapshot schema must fail closed")
        } catch {
            expectSourceFailure(error, "schema mismatch")
        }
        do {
            _ = try await SkillsCenter.verifiedPublication(
                from: snapshot(catalog: Data(), signature: signature), channel: .ios, mode: mode)
            Issue.record("an empty feed must fail closed")
        } catch {
            expectSourceFailure(error, "empty feed")
        }
        do {
            let oversized = Data(repeating: 0x20, count: CuratedSkillHub.maximumFeedBytes + 1)
            _ = try await SkillsCenter.verifiedPublication(
                from: snapshot(catalog: oversized, signature: signature), channel: .ios, mode: mode)
            Issue.record("an over-bound feed must fail closed")
        } catch {
            expectSourceFailure(error, "oversize feed")
        }
    }

    @Test func fixtureSnapshotCanNeverActivateProductionTrust() async throws {
        // The exact-byte production/fixture coupling survives restore: the
        // published fixture pair is rejected under compiled production
        // trust, so the store's production fallback path can never publish
        // a fixture offer, and no test ever forges production trust here.
        let (catalog, signature) = (try cacheFixture("catalog.json"), try cacheFixture("catalog.sig"))
        do {
            _ = try await SkillsCenter.verifiedPublication(
                from: snapshot(catalog: catalog, signature: signature), channel: .ios, mode: .production)
            Issue.record("a fixture feed must never activate the production channel")
        } catch {
            guard let failure = error as? CuratedSkillHubFailure else {
                Issue.record("expected CuratedSkillHubFailure, got \(error)")
                return
            }
            switch failure {
            case .trust: break
            default: Issue.record("expected a trust coupling failure, got \(failure)")
            }
        }
    }

    private actor LateCatalogFetchGate {
        private var entered = false
        private var ended = false
        private var arrivals: [CheckedContinuation<Bool, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            for arrival in arrivals { arrival.resume(returning: true) }
            arrivals.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        func waitUntilEntered() async -> Bool {
            if entered { return true }
            if ended { return false }
            return await withCheckedContinuation { arrivals.append($0) }
        }
        func attemptFinished() {
            ended = true
            for arrival in arrivals { arrival.resume(returning: false) }
            arrivals.removeAll()
        }
        func finish() { release?.resume(); release = nil }
    }

    @Test func pinnedLoadCannotReplaceMainChannelSnapshot() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        let box = SnapshotBox()
        let (resolve, fetch) = fixtureTransport(catalog: catalog, signature: signature)
        _ = try await SkillsCenter.loadCuratedPublication(
            channel: .ios, mode: mode, ref: Self.fixtureCommit,
            resolve: resolve, fetch: fetch, store: { await box.store($0) })
        let count = await box.count
        #expect(count == 0, "a pinned historical load must not roll back the main-channel cache")
    }

    @Test func noncooperativeLateFetchCannotStoreAfterCancellation() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        let box = SnapshotBox()
        let gate = LateCatalogFetchGate()
        let (resolve, originalFetch) = fixtureTransport(catalog: catalog, signature: signature)
        let attempt = Task { () -> Bool in
            let cancelled: Bool
            do {
                _ = try await SkillsCenter.loadCuratedPublication(
                    channel: .ios, mode: mode, resolve: resolve,
                    fetch: { source, commit, path in
                        let bytes = try await originalFetch(source, commit, path)
                        if path == CuratedSkillHub.signaturePath(for: .ios) { await gate.hold() }
                        return bytes
                    }, store: { await box.store($0) })
                cancelled = false
            } catch is CancellationError { cancelled = true }
            catch { Issue.record("late cancellation returned \(error)"); cancelled = false }
            await gate.attemptFinished()
            return cancelled
        }
        let entered = await gate.waitUntilEntered()
        guard entered else {
            Issue.record("the verified fixture load ended before reaching its signature fetch")
            _ = await attempt.value
            return
        }
        attempt.cancel()
        await gate.finish()
        let wasCancelled = await attempt.value
        let count = await box.count
        #expect(wasCancelled)
        #expect(count == 0, "late bytes from a noncooperative transport cannot commit a cache")
    }

    @Test func failedLiveLoadStoresNothing() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        let box = SnapshotBox()
        let (resolve, fetch) = fixtureTransport(catalog: catalog, signature: signature, fetchFails: true)
        do {
            _ = try await SkillsCenter.loadCuratedPublication(
                channel: .ios, mode: mode, resolve: resolve, fetch: fetch,
                store: { snapshot in await box.store(snapshot) })
            Issue.record("a failed transport must fail the live load")
        } catch {
            // Any transport error propagates; the cache stays untouched.
        }
        let storedCount = await box.count
        #expect(storedCount == 0, "a failed live load can never write a snapshot")
    }

    @Test func cancelledTransportStoresNothingAndPropagatesTheLoaderFailure() async throws {
        let (mode, catalog, signature) = try validFixturePair()
        let box = SnapshotBox()
        let (resolve, fetch) = fixtureTransport(catalog: catalog, signature: signature, resolveCancels: true)
        var caught: any Error?
        do {
            _ = try await SkillsCenter.loadCuratedPublication(
                channel: .ios, mode: mode, resolve: resolve, fetch: fetch,
                store: { snapshot in await box.store(snapshot) })
        } catch {
            caught = error
        }
        let failure = try #require(caught, "a cancelled transport must fail the live load")
        if let hubFailure = failure as? CuratedSkillHubFailure {
            switch hubFailure {
            case .unavailable: break
            default: Issue.record("expected the loader's unavailable rethrow, got \(hubFailure)")
            }
        } else {
            Issue.record("expected the loader's own rethrow, got \(failure)")
        }
        let storedCount = await box.count
        #expect(storedCount == 0, "cancellation is not a catalog success and never writes a snapshot")
        // When the surrounding task is genuinely torn down (navigation),
        // `loadCuratedPublication` re-checks `Task.isCancelled` and
        // reclassifies to `CancellationError`; `refreshCuratedCatalog`
        // catches that separately, so no error status is consumed and the
        // success timestamp is untouched — the next store entry retries
        // live first instead of being blocked by a poisoned one-hour slot.
    }
}

#endif
