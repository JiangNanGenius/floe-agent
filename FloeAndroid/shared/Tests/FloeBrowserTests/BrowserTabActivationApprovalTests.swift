import XCTest
import FloeCore
@testable import FloeBrowser

/// Behavior of the one-use, native-identity tab approval for `activate` and
/// `close`. The proof is captured from live session state (never from page
/// JavaScript or model arguments) and is rechecked immediately before the
/// exact tab action runs.
final class BrowserTabActivationApprovalTests: XCTestCase {
    private func makeSession(
        _ harness: BrowserTestHarness,
        owner: BrowserOwnerID,
        tabs: Int
    ) async throws -> BrowserTaskSession {
        let session = try await harness.center.taskSession(for: owner)
        for _ in 1..<tabs {
            _ = await session.createTab()
        }
        let snapshots = await session.tabSnapshots()
        XCTAssertEqual(snapshots.count, tabs)
        return session
    }

    func testPendingNavigationCannotBeReviewedOrExecuted() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let tabs = await session.tabSnapshots()
        let target = tabs[0].id
        let proof = try await session.approvalTabProof(action: "activate", tabID: target)
        await harness.center.ingress(.loadStarted(tabID: target))
        for operation in ["activate", "close"] {
            do {
                _ = try await session.approvalTabProof(action: operation, tabID: target)
                XCTFail("An in-flight navigation cannot be reviewed")
            } catch { }
        }
        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof, action: .activateTab(target)),
            in: owner)
        XCTAssertEqual(result.status, .stale)
        let active = await session.activeTabID
        XCTAssertEqual(active, tabs[1].id)
    }

    func testUncertainNavigationCannotBeReviewed() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let target = (await session.tabSnapshots())[0].id
        await harness.center.ingress(.loadStarted(tabID: target))
        await harness.center.ingress(.loadFailed(tabID: target, errorDomain: "FloeLifecycle",
            errorCode: -699, errorDescription: "Event state uncertain"))
        for operation in ["activate", "close"] {
            do {
                _ = try await session.approvalTabProof(action: operation, tabID: target)
                XCTFail("An uncertain navigation cannot be reviewed")
            } catch { }
        }
    }

    func testLifecycleGapRejectsReviewAndRevokesExistingProof() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let tabs = await session.tabSnapshots()
        let target = tabs[0].id
        let proof = try await session.approvalTabProof(action: "close", tabID: target)
        BrowserLifecycleHealth.shared.markGap(epoch: owner.rootEpoch, tabID: target)
        defer { BrowserLifecycleHealth.shared.clearGap(epoch: owner.rootEpoch, tabID: target) }
        for operation in ["activate", "close"] {
            do {
                _ = try await session.approvalTabProof(action: operation, tabID: target)
                XCTFail("A page with a lifecycle gap cannot be reviewed")
            } catch { }
        }
        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof, action: .closeTab(target)),
            in: owner)
        XCTAssertEqual(result.status, .stale)
        let remaining = await session.tabSnapshots()
        XCTAssertEqual(remaining.count, 2)
    }

    func testActivateProofBindsExactNativeTargetAndRejectsReplay() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let tabs = await session.tabSnapshots()
        let target = tabs[0].id
        XCTAssertFalse(tabs[0].isActive)

        let proof = try await session.approvalTabProof(action: "activate", tabID: target)
        let proofSessionID = await session.sessionID
        XCTAssertEqual(proof.operation, "activate")
        XCTAssertEqual(proof.tabID, target)
        XCTAssertEqual(proof.owner, owner)
        XCTAssertEqual(proof.sessionID, proofSessionID)
        XCTAssertEqual(proof.activeTabID, tabs[1].id)
        XCTAssertEqual(proof.tabIDs, tabs.map(\.id))

        let command = BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                                     action: .activateTab(target))
        let result = await harness.center.execute(command, in: owner)
        XCTAssertEqual(result.status, .ok)
        let activeAfter = await session.activeTabID
        XCTAssertEqual(activeAfter, target)

        // The exact same reviewed proof is single-use: once the reviewed
        // active-tab state no longer exists, the replay is stale and the
        // selection is unchanged.
        let replay = await harness.center.execute(command, in: owner)
        XCTAssertEqual(replay.status, .stale)
        XCTAssertEqual(replay.error?.code, "approval-changed")
        let activeAfterReplay = await session.activeTabID
        XCTAssertEqual(activeAfterReplay, target)
        let countAfterReplay = (await session.tabSnapshots()).count
        XCTAssertEqual(countAfterReplay, 2)
    }

    func testActivateProofNeverRetargetsAnotherTab() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 3)
        let tabs = await session.tabSnapshots()
        let reviewed = tabs[0].id
        let active = tabs[2].id
        let proof = try await session.approvalTabProof(action: "activate", tabID: reviewed)

        // A forged/re-targeted command for another tab is refused; the
        // reviewed target is never substituted.
        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                           action: .activateTab(active)),
            in: owner)
        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.error?.code, "approval-changed")
        let currentActive = await session.activeTabID
        XCTAssertEqual(currentActive, active)
    }

    func testApprovedTabOrderIsRecheckedBeforeActivation() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 3)
        let tabs = await session.tabSnapshots()
        let proof = try await session.approvalTabProof(action: "activate", tabID: tabs[0].id)
        let wrongOrder = BrowserTabApprovalProof(
            owner: proof.owner, sessionID: proof.sessionID, operation: proof.operation,
            tabID: proof.tabID, activeTabID: proof.activeTabID, documentID: proof.documentID,
            navigationRevision: proof.navigationRevision, url: proof.url, title: proof.title,
            tabCount: proof.tabCount, maximumTabs: proof.maximumTabs, tabIDs: Array(proof.tabIDs.reversed()))
        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: wrongOrder,
                           action: .activateTab(tabs[0].id)), in: owner)
        XCTAssertEqual(result.status, .stale)
        let active = await session.activeTabID
        XCTAssertEqual(active, tabs[2].id)
    }

    func testActivateProofRejectsTargetDocumentChange() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let tabs = await session.tabSnapshots()
        let target = tabs[0].id
        let active = tabs[1].id
        let proof = try await session.approvalTabProof(action: "activate", tabID: target)
        let reviewedDocument = proof.documentID

        // A native navigation commit rotates the target document identity.
        await harness.center.ingress(.loadStarted(tabID: target))
        await harness.center.ingress(.loadCommitted(tabID: target))
        await harness.center.ingress(.loadFinished(tabID: target,
            url: "https://changed.example.test/", title: "Changed"))
        let currentTabs = await session.tabs
        let current = currentTabs.first(where: { $0.id == target })
        XCTAssertNotEqual(current?.documentID, reviewedDocument)

        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                           action: .activateTab(target)),
            in: owner)
        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.error?.code, "approval-changed")
        let activeAfter = await session.activeTabID
        XCTAssertEqual(activeAfter, active)
    }

    func testActivateProofRejectsChangedTargetSurfaceAndTakeover() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let tabs = await session.tabSnapshots()
        let target = tabs[0].id
        let active = tabs[1].id
        await harness.center.ingress(.loadFinished(tabID: target,
            url: "https://reviewed.example.test/", title: "Reviewed"))
        let proof = try await session.approvalTabProof(action: "activate", tabID: target)
        XCTAssertEqual(proof.url, "https://reviewed.example.test/")
        XCTAssertEqual(proof.title, "Reviewed")

        // The surfacing facts shown to the reviewer changed: the approval is
        // no longer for the same visible target.
        await harness.center.ingress(.loadFinished(tabID: target,
            url: "https://reviewed.example.test/", title: "Changed after review"))
        let changed = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                           action: .activateTab(target)),
            in: owner)
        XCTAssertEqual(changed.status, .stale)
        let activeAfterChange = await session.activeTabID
        XCTAssertEqual(activeAfterChange, active)

        // User takeover invalidates the reviewed approval even when the tab
        // state itself is unchanged.
        let fresh = try await session.approvalTabProof(action: "activate", tabID: target)
        await session.setUserControlling(true)
        let taken = await harness.center.execute(
            BrowserCommand(sessionID: fresh.sessionID, tabApprovalProof: fresh,
                           action: .activateTab(target)),
            in: owner)
        XCTAssertEqual(taken.status, .stale)
        let activeAfterTakeover = await session.activeTabID
        XCTAssertEqual(activeAfterTakeover, active)
    }

    func testCloseProofClosesOnlyTheReviewedTabAndRejectsReplay() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 3)
        let tabs = await session.tabSnapshots()
        let target = tabs[0].id
        let active = tabs[2].id
        let proof = try await session.approvalTabProof(action: "close", tabID: target)
        XCTAssertEqual(proof.operation, "close")
        XCTAssertEqual(proof.tabID, target)

        let command = BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                                     action: .closeTab(target))
        let result = await harness.center.execute(command, in: owner)
        XCTAssertEqual(result.status, .ok)
        let after = await session.tabSnapshots()
        XCTAssertEqual(after.count, 2)
        XCTAssertFalse(after.contains(where: { $0.id == target }))
        let activeAfter = await session.activeTabID
        XCTAssertEqual(activeAfter, active)

        let replay = await harness.center.execute(command, in: owner)
        XCTAssertEqual(replay.status, .stale)
        XCTAssertEqual(replay.error?.code, "approval-changed")
        let countAfterReplay = (await session.tabSnapshots()).count
        XCTAssertEqual(countAfterReplay, 2)
    }

    func testCloseProofRejectsAlreadyClosedTargetAndLastTab() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let tabs = await session.tabSnapshots()
        let target = tabs[0].id
        let active = tabs[1].id
        let proof = try await session.approvalTabProof(action: "close", tabID: target)

        // A close proof can never be replayed as another operation on the
        // same tab.
        let wrongAction = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                           action: .activateTab(target)),
            in: owner)
        XCTAssertEqual(wrongAction.status, .stale)
        XCTAssertEqual(wrongAction.error?.code, "approval-changed")
        let activeAfterWrongAction = await session.activeTabID
        XCTAssertEqual(activeAfterWrongAction, active)
        let countAfterWrongAction = (await session.tabSnapshots()).count
        XCTAssertEqual(countAfterWrongAction, 2)

        // The target genuinely disappeared after review; the proof must not
        // close a substitute tab.
        await session.close(target)
        let afterClose = await session.tabSnapshots()
        XCTAssertEqual(afterClose.count, 1)
        let stale = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                           action: .closeTab(target)),
            in: owner)
        XCTAssertEqual(stale.status, .stale)
        let countAfterStale = (await session.tabSnapshots()).count
        XCTAssertEqual(countAfterStale, 1)

        let only = afterClose[0].id
        do {
            _ = try await session.approvalTabProof(action: "close", tabID: only)
            XCTFail("The last remaining tab cannot be reviewed for closing")
        } catch { }
    }

    func testProofsAreBoundToTheirOwnSessionAndOwner() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let ownerA = BrowserTestHarness.owner()
        let ownerB = BrowserTestHarness.owner()
        let sessionA = try await makeSession(harness, owner: ownerA, tabs: 2)
        let sessionB = try await makeSession(harness, owner: ownerB, tabs: 2)
        let tabsA = await sessionA.tabSnapshots()
        let tabsB = await sessionB.tabSnapshots()
        let proof = try await sessionA.approvalTabProof(action: "close", tabID: tabsA[0].id)

        // A proof from another session can never act on B's browser, even if
        // a same-shaped tab ID/state is presented.
        let crossOwner = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                           action: .closeTab(tabsB[0].id)),
            in: ownerB)
        XCTAssertEqual(crossOwner.status, .stale)
        let countB = (await sessionB.tabSnapshots()).count
        let countA = (await sessionA.tabSnapshots()).count
        XCTAssertEqual(countB, 2)
        XCTAssertEqual(countA, 2)

        // A fabricated owner on an otherwise valid session proof is refused.
        let forged = BrowserTabApprovalProof(
            owner: ownerB, sessionID: proof.sessionID, operation: proof.operation,
            tabID: proof.tabID, activeTabID: proof.activeTabID, documentID: proof.documentID,
            navigationRevision: proof.navigationRevision, url: proof.url, title: proof.title,
            tabCount: proof.tabCount, maximumTabs: proof.maximumTabs, tabIDs: proof.tabIDs)
        let forgedResult = await harness.center.execute(
            BrowserCommand(sessionID: forged.sessionID, tabApprovalProof: forged,
                           action: .closeTab(tabsA[0].id)),
            in: ownerA)
        XCTAssertEqual(forgedResult.status, .stale)
        let countAAfterForged = (await sessionA.tabSnapshots()).count
        XCTAssertEqual(countAAfterForged, 2)

        // A proof that names a different native session (same owner and tab
        // shape) is refused without touching the live session.
        let wrongSession = BrowserTabApprovalProof(
            owner: ownerA, sessionID: UUID(), operation: proof.operation,
            tabID: proof.tabID, activeTabID: proof.activeTabID, documentID: proof.documentID,
            navigationRevision: proof.navigationRevision, url: proof.url, title: proof.title,
            tabCount: proof.tabCount, maximumTabs: proof.maximumTabs, tabIDs: proof.tabIDs)
        let wrongSessionResult = await harness.center.execute(
            BrowserCommand(sessionID: wrongSession.sessionID, tabApprovalProof: wrongSession,
                           action: .closeTab(tabsA[0].id)),
            in: ownerA)
        XCTAssertEqual(wrongSessionResult.status, .stale)
        let countAAfterWrongSession = (await sessionA.tabSnapshots()).count
        XCTAssertEqual(countAAfterWrongSession, 2)
    }

    func testProofCannotResurrectAReleasedSession() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await makeSession(harness, owner: owner, tabs: 2)
        let tabs = await session.tabSnapshots()
        let proof = try await session.approvalTabProof(action: "activate", tabID: tabs[0].id)

        await harness.center.discard(conversationID: owner.taskID, notifyHook: false)
        let discarded = await harness.center.session(for: owner.taskID)
        XCTAssertNil(discarded)
        let activeSessions = await harness.center.activeTaskSessionCount
        XCTAssertEqual(activeSessions, 0)

        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof,
                           action: .activateTab(tabs[0].id)),
            in: owner)
        XCTAssertEqual(result.status, .stale)
        let recreated = await harness.center.session(for: owner.taskID)
        XCTAssertNil(recreated)
        let activeAfter = await harness.center.activeTaskSessionCount
        XCTAssertEqual(activeAfter, 0)
    }

    func testInvalidReviewTargetsAreRefused() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await harness.center.taskSession(for: owner)
        let activeOptional = await session.activeTabID
        let active = try XCTUnwrap(activeOptional)

        do {
            _ = try await session.approvalTabProof(action: "activate", tabID: active)
            XCTFail("An already-active tab has no reviewable activation")
        } catch { }
        do {
            _ = try await session.approvalTabProof(action: "close", tabID: active)
            XCTFail("The last browser tab cannot be reviewed for closing")
        } catch { }
        do {
            _ = try await session.approvalTabProof(action: "close", tabID: UUID())
            XCTFail("An unknown tab identity cannot be reviewed")
        } catch { }
        do {
            _ = try await session.approvalTabProof(action: "delete", tabID: nil)
            XCTFail("An unknown tab operation cannot be reviewed")
        } catch { }
    }

    func testCreateApprovalStillRequiresACompleteRevalidatedProof() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await harness.center.taskSession(for: owner)
        let before = (await session.tabSnapshots()).count
        let proof = try await session.approvalTabProof(action: "create", tabID: nil)
        XCTAssertEqual(proof.operation, "create")
        XCTAssertNil(proof.tabID)

        // An activation proof can never be presented as a create proof.
        let wrongOperation = BrowserTabApprovalProof(
            owner: proof.owner, sessionID: proof.sessionID, operation: "activate",
            tabID: nil, activeTabID: proof.activeTabID, documentID: nil,
            navigationRevision: nil, url: nil, title: nil, tabCount: proof.tabCount,
            maximumTabs: proof.maximumTabs, tabIDs: proof.tabIDs)
        let refused = await harness.center.execute(
            BrowserCommand(sessionID: wrongOperation.sessionID, tabApprovalProof: wrongOperation,
                           action: .create),
            in: owner)
        XCTAssertEqual(refused.status, .stale)
        let countAfterRefusal = (await session.tabSnapshots()).count
        XCTAssertEqual(countAfterRefusal, before)

        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof, action: .create),
            in: owner)
        XCTAssertEqual(result.status, .ok)
        let countAfterCreate = (await session.tabSnapshots()).count
        XCTAssertEqual(countAfterCreate, before + 1)
    }
}
