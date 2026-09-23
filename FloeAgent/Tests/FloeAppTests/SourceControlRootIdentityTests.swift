// FloeAppTests — pinned source-control identity for the IDE pane.
//
// The IDE is opened for one workspace and can stay mounted while the app
// switches to another. Its source-control pane must never stage, commit,
// initialize or switch a repository that the global center now resolves for
// a different workspace, and the lock must render the moment the current
// workspace changes (the decision is observed through WorkspaceCenter, not
// only through the source-control center).
//
// `SourceControlCenter` itself needs the app-lifetime `AppEnvironment` graph
// (private init, live keychain/services), so these tests pin the pure
// identity decision the rendering lock and the mutation guard both use:
// same root => bound, A→B => blocked, nil pin (legacy inspector) => follows
// the global current workspace.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

@Suite("FloeApp.SourceControlRootIdentity")
@MainActor
struct SourceControlRootIdentityTests {
    private let rootA = URL(fileURLWithPath: "/workspaces/A")
    private let rootB = URL(fileURLWithPath: "/workspaces/B")

    @Test("A pinned root matches the same workspace")
    func sameRootMatches() {
        #expect(SourceControlRootIdentity.matches(current: rootA, pinned: rootA))
    }

    @Test("An A→B workspace switch blocks the previously pinned IDE pane")
    func switchFromAToBBlocks() {
        // The pane opened while workspace A was current.
        #expect(SourceControlRootIdentity.matches(current: rootA, pinned: rootA))
        // The app switches to B; A's pane must now be locked before any
        // stage/commit call reaches the Git service.
        #expect(SourceControlRootIdentity.matches(current: rootB, pinned: rootA) == false)
        // Switching back re-binds the same pane.
        #expect(SourceControlRootIdentity.matches(current: rootA, pinned: rootA))
    }

    @Test("An unknown current workspace blocks the pane instead of following a nil root")
    func noCurrentRootBlocksAPinnedPane() {
        #expect(SourceControlRootIdentity.matches(current: nil, pinned: rootA) == false)
    }

    @Test("A nil pin keeps the legacy global behavior")
    func nilPinFollowsGlobalWorkspace() {
        #expect(SourceControlRootIdentity.matches(current: rootA, pinned: nil))
        #expect(SourceControlRootIdentity.matches(current: rootB, pinned: nil))
        #expect(SourceControlRootIdentity.matches(current: nil, pinned: nil))
    }

    @Test("Standardized path forms do not create a second identity")
    func standardizedPathsAreEquivalent() {
        let variant = URL(fileURLWithPath: "/workspaces/A/./B/..")
        #expect(SourceControlRootIdentity.matches(current: variant, pinned: rootA))
        #expect(SourceControlRootIdentity.matches(current: rootA, pinned: variant))
    }

    @Test("A mutation result must not publish into B's pane when the workspace switched during the Git await")
    func writebackAfterAsyncSwitch() async {
        // The mutation has already run against A (the started operation is
        // never retargeted or reverted). The post-await writeback uses the
        // same identity decision, so while the operation is in flight an
        // A→B switch must drop A's snapshot/error and let B refresh instead.
        let startedOn = rootA

        // Snapshot arrives while still on A: publish into the A pane.
        var current = rootA
        #expect(SourceControlRootIdentity.matches(current: current, pinned: startedOn))

        // The user switches workspaces while the Git service is awaited.
        current = rootB
        #expect(SourceControlRootIdentity.matches(current: current, pinned: startedOn) == false)

        // A stale success (errorMessage = nil) must not clear B either: the
        // same gate covers the success path.
        #expect(SourceControlRootIdentity.matches(current: current, pinned: nil))

        // Switching back to A re-arms the pane for A's next refresh.
        current = rootA
        #expect(SourceControlRootIdentity.matches(current: current, pinned: startedOn))
    }
}
#endif
