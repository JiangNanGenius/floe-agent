import XCTest
@testable import FloeBrowser

final class BrowserTabApprovalProofTests: XCTestCase {
    func testFirstApprovalPreparesSessionButRevalidationNeverRecreatesIt() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let before = try await harness.center.approvalSession(for: owner, preparingIfNeeded: false)
        XCTAssertNil(before)
        let prepared = try await harness.center.approvalSession(for: owner, preparingIfNeeded: true)
        let session = try XCTUnwrap(prepared)
        let proof = try await session.approvalTabProof(action: "create", tabID: nil)
        let rechecked = try await harness.center.approvalSession(for: owner, preparingIfNeeded: false)
        XCTAssertTrue(rechecked === session)
        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof, action: .create), in: owner)
        XCTAssertEqual(result.status, .ok)
        await harness.center.discard(conversationID: owner.taskID, notifyHook: false)
        let afterDiscard = try await harness.center.approvalSession(for: owner, preparingIfNeeded: false)
        XCTAssertNil(afterDiscard)
        do {
            _ = try await harness.center.approvalSession(for: owner, preparingIfNeeded: true)
            XCTFail("Approval preparation must not reopen a released session")
        } catch { }
    }

    func testCreateRechecksTheReviewedTabSet() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await harness.center.taskSession(for: owner)
        let proof = try await session.approvalTabProof(action: "create", tabID: nil)
        let command = BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof, action: .create)
        let first = await harness.center.execute(command, in: owner)
        XCTAssertEqual(first.status, .ok)
        let countAfterFirst = (await session.tabSnapshots()).count
        let stale = await harness.center.execute(command, in: owner)
        XCTAssertEqual(stale.status, .stale)
        let countAfterStale = (await session.tabSnapshots()).count
        XCTAssertEqual(countAfterStale, countAfterFirst)
    }

    func testTakeoverRevokesCreateProof() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let session = try await harness.center.taskSession(for: owner)
        let proof = try await session.approvalTabProof(action: "create", tabID: nil)
        await session.setUserControlling(true)
        let result = await harness.center.execute(
            BrowserCommand(sessionID: proof.sessionID, tabApprovalProof: proof, action: .create), in: owner)
        XCTAssertEqual(result.status, .stale)
        let count = (await session.tabSnapshots()).count
        XCTAssertEqual(count, proof.tabCount)
    }

    func testReadOnlyLookupAndUnsupportedActionsNeverCreateSession() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let missing = await harness.center.existingSession(for: owner)
        XCTAssertNil(missing)
        let session = try await harness.center.taskSession(for: owner)
        do {
            _ = try await session.approvalTabProof(action: "close", tabID: nil)
            XCTFail("Closing a tab has no reliable native document proof")
        } catch { }
    }
}
