// FloeBrowserTests — owner fences, epochs, workspace binding churn.
// Authored (job-9960651880854093), not executed in this source lane.

import XCTest
import FloeCore
@testable import FloeBrowser

/// Sendable mid-test admission flip for `ownerAuthority` (the trusted
/// closure runs on the session center's executor; a bare captured `var`
/// is illegal under Swift 6 concurrency and the actor keeps the exact
/// read-time semantics: false before the flip, true after).
private actor AdmissionFlag {
    private var value = false
    func set(_ newValue: Bool) { value = newValue }
    func get() -> Bool { value }
}

final class BrowserOwnershipFenceTests: XCTestCase {
    func testReleasedOwnerIsPermanentlyRefusedUntilTrustedReactivation() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let first = try await harness.center.taskSession(for: owner)
        let firstID = await first.sessionID
        let initialGeneration = await harness.center.generation(for: owner.taskID)
        XCTAssertEqual(initialGeneration, 0)

        // Explicit owner release.
        await harness.center.discard(conversationID: owner.taskID)

        // A tool-path call is refused forever (no elapsed-time expiry).
        do {
            _ = try await harness.center.taskSession(for: owner)
            XCTFail("released owner must be refused")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("released"))
        }

        // Late completion from the OLD session is fenced, not re-admitted.
        let late = await harness.center.execute(
            BrowserCommand(sessionID: firstID, action: .protocolInfo),
            in: owner
        )
        XCTAssertEqual(late.status, .stale)
        XCTAssertEqual(late.error?.code, "session")

        // Only the trusted restore path reactivates: new generation, new sessionID.
        let second = try await harness.center.restoreSession(owner: owner)
        let secondID = await second.sessionID
        XCTAssertNotEqual(secondID, firstID)
        let generation = await harness.center.generation(for: owner.taskID)
        XCTAssertGreaterThan(generation, 0)
    }

    func testAdmittedRunLiftsFenceWithoutCreatingTheOldSession() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        _ = try await harness.center.taskSession(for: owner)
        await harness.center.discard(conversationID: owner.taskID)
        let absentSession = await harness.center.session(for: owner.taskID)
        XCTAssertNil(absentSession)

        // The runtime admits a new authorized run: the fence lifts and THIS
        // run's own tool call may create a session.
        let runID = UUID()
        await harness.center.recordOwnerRun(conversationID: owner.taskID, runID: runID)
        let session = try await harness.center.taskSession(for: owner)
        let tabs = await session.tabSnapshots()
        XCTAssertEqual(tabs.count, 1, "a newly admitted session starts with exactly one tab")
        let recorded = await harness.center.recordedOwnerRun(for: owner.taskID)
        XCTAssertEqual(recorded, runID)
    }

    func testWorkspaceBindingChangeReleasesTheOldOwnerFirst() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let task = UUID()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let ownerA = BrowserOwnerID(taskID: task, workspaceID: workspaceA, rootEpoch: 7)
        let ownerB = BrowserOwnerID(taskID: task, workspaceID: workspaceB, rootEpoch: 8)
        let sessionA = try await harness.center.taskSession(for: ownerA)
        let sessionAID = await sessionA.sessionID

        // Same conversation, different binding: taskSession refuses to reuse.
        do {
            _ = try await harness.center.taskSession(for: ownerB)
            XCTFail("a different workspace binding must not reuse the old session")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("different workspace"))
        }

        // The trusted rebind fences A and admits B under a new session.
        await harness.center.bind(to: task, owner: ownerB)
        let sessionB = try await harness.center.taskSession(for: ownerB)
        let sessionBID = await sessionB.sessionID
        XCTAssertNotEqual(sessionAID, sessionBID)

        // Any late command carrying the old sessionID is stale forever.
        let late = await harness.center.execute(
            BrowserCommand(sessionID: sessionAID, action: .protocolInfo),
            in: ownerB
        )
        XCTAssertEqual(late.status, .stale)
    }

    func testOwnerAuthorityRefusalBlocksAdmissionAndRebind() async throws {
        let admission = AdmissionFlag()
        let harness = BrowserTestHarness.make(ownerAuthority: { _ in await admission.get() })
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        do {
            _ = try await harness.center.taskSession(for: owner)
            XCTFail("unadmitted owner must not create a session")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("admitted"))
        }
        // Trusted bind while unadmitted stays inert (no session created).
        await harness.center.bind(to: owner.taskID, owner: owner)
        let absentSession = await harness.center.session(for: owner.taskID)
        XCTAssertNil(absentSession)
        await admission.set(true)
        await harness.center.bind(to: owner.taskID, owner: owner)
        let session = await harness.center.session(for: owner.taskID)
        XCTAssertNotNil(session)
    }

    func testCommandProtocolVersionFence() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await harness.center.taskSession(for: owner)
        let sessionID = await session.sessionID
        let wrongVersion = await harness.center.execute(
            BrowserCommand(version: 2, sessionID: sessionID, action: .protocolInfo),
            in: owner
        )
        XCTAssertEqual(wrongVersion.status, .failed)
        XCTAssertEqual(wrongVersion.error?.code, "version")
        let wrongSession = await harness.center.execute(
            BrowserCommand(sessionID: UUID(), action: .protocolInfo),
            in: owner
        )
        XCTAssertEqual(wrongSession.status, .stale)
    }

    func testRegistryCapacityOnlyEvictsIdleUnclaimedOwners() async throws {
        let harness = BrowserTestHarness.make(maximumSessions: 2)
        defer { harness.teardown() }
        let a = BrowserTestHarness.owner()
        let b = BrowserTestHarness.owner()
        let c = BrowserTestHarness.owner()
        _ = try await harness.center.taskSession(for: a)
        _ = try await harness.center.taskSession(for: b)
        // Both are freshly active: a third must be REFUSED (the 6-hour idle
        // cutoff prevents pressure alone from silently evicting busy owners).
        do {
            _ = try await harness.center.taskSession(for: c)
            XCTFail("capacity pressure alone must not admit or evict")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("Too many task browsers"))
        }
        let count = await harness.center.activeTaskSessionCount
        XCTAssertEqual(count, 2)
    }

    func testReleaseResetsSurfaceAndDestroysEveryRendererTab() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await harness.center.taskSession(for: owner)
        let second = await session.createTab()
        XCTAssertNotNil(second)
        await harness.center.discard(conversationID: owner.taskID)
        let created = await harness.renderer.createdTabs
        let destroyed = await harness.renderer.destroyedTabs
        XCTAssertEqual(Set(destroyed), Set(created))
        let released = await session.isReleased
        XCTAssertTrue(released)
        let surface = await session.surfaceState
        XCTAssertEqual(surface, .unbound)
    }
}
