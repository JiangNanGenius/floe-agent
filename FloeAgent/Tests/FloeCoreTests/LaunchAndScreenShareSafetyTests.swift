import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore launch and screen-share safety")
struct LaunchAndScreenShareSafetyTests {
    @Test("Scoped invalidation rejects only stale work for that conversation")
    func scopedLaunchInvalidation() {
        var fence = LaunchEpochFence()
        let firstID = UUID()
        let secondID = UUID()
        let stale = fence.issue(scope: firstID)
        let unrelated = fence.issue(scope: secondID)

        fence.invalidate(scope: firstID)

        #expect(!fence.isValid(stale))
        #expect(fence.isValid(unrelated))
        #expect(fence.isValid(fence.issue(scope: firstID)))
    }

    @Test("Global invalidation rejects every launch issued before clear-history")
    func globalLaunchInvalidation() {
        var fence = LaunchEpochFence()
        let scoped = fence.issue(scope: UUID())
        let unscoped = fence.issue()

        fence.invalidateAll()

        #expect(!fence.isValid(scoped))
        #expect(!fence.isValid(unscoped))
        #expect(fence.isValid(fence.issue()))
    }

    @Test("Launch recovery interrupts only ownerless runs from an earlier process")
    func launchRunRecoveryPolicy() {
        let cutoff = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(LaunchRunRecoveryPolicy.shouldInterrupt(
            startedAt: cutoff.addingTimeInterval(-1),
            currentProcessCutoff: cutoff,
            hasLiveOwner: false
        ))
        #expect(!LaunchRunRecoveryPolicy.shouldInterrupt(
            startedAt: cutoff,
            currentProcessCutoff: cutoff,
            hasLiveOwner: false
        ))
        #expect(!LaunchRunRecoveryPolicy.shouldInterrupt(
            startedAt: cutoff.addingTimeInterval(-1),
            currentProcessCutoff: cutoff,
            hasLiveOwner: true
        ))
    }

    @Test("Screen-share frames require an active, current schema heartbeat")
    func screenShareFreshness() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(ScreenShareSessionState(sessionID: UUID(), isActive: true, updatedAt: now).isFresh(at: now))
        #expect(!ScreenShareSessionState(
            sessionID: UUID(), isActive: false, updatedAt: now
        ).isFresh(at: now))
        #expect(!ScreenShareSessionState(
            sessionID: UUID(), isActive: true,
            updatedAt: now.addingTimeInterval(-ScreenShareSessionState.maximumFrameAge - 0.1)
        ).isFresh(at: now))
        #expect(!ScreenShareSessionState(
            sessionID: UUID(), isActive: true, updatedAt: now,
            schemaVersion: ScreenShareSessionState.schemaVersion + 1
        ).isFresh(at: now))
    }
}
