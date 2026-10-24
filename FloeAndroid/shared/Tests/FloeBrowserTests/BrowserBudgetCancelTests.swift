// FloeBrowserTests — budgets, timeouts and cancellation across the session.
// Authored (job-9960651880854093), not executed in this source lane.

import XCTest
import FloeCore
import FloeTools
@testable import FloeBrowser

final class BrowserBudgetCancelTests: XCTestCase {
    func testTextInputIsBoundedAtSixteenKibibytes() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let observed = await harness.center.execute(BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)), in: owner)
        let documentID = observed.page!.documentID
        let big = String(repeating: "x", count: 16 * 1024 + 1)
        let refused = await harness.center.execute(
            BrowserCommand(
                sessionID: sessionID,
                expectedDocumentID: documentID,
                action: .type(.element(ref: "n1", documentID: documentID), text: big, submit: false)
            ),
            in: owner
        )
        XCTAssertEqual(refused.status, .blocked)
        XCTAssertEqual(refused.error?.code, "policy")
        XCTAssertTrue((refused.error?.message ?? "").contains("16 KiB"))
        let evaluations = await harness.renderer.evaluations
        XCTAssertFalse(evaluations.contains { $0.expression.contains("p.perform(") }, "an oversized body must never reach the page")
        _ = session
    }

    func testOversizedScreenshotIsRefusedAsEvidence() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        _ = try await makeNavigatedSession(harness: harness, owner: owner)
        await harness.renderer.overrideScreenshot(bytes: Data(repeating: 9, count: 8 * 1024 * 1024 + 1), width: 100, height: 100)
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        // Session count is capped at one per owner, so `session` is the same
        // object; the screenshot must be refused over 8 MiB.
        _ = session
        let shot = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, action: .screenshot),
            in: owner
        )
        XCTAssertEqual(shot.status, .blocked)
        XCTAssertTrue((shot.error?.message ?? "").contains("8 MiB"))
    }

    func testUncooperativeRendererTimesOutAndLateAnswersAreDropped() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        _ = try await makeNavigatedSession(harness: harness, owner: owner)
        await harness.renderer.setMode(.neverAnswerEvaluations)
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        _ = session
        let result = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, timeoutMilliseconds: 300, action: .observe(cursor: nil)),
            in: owner
        )
        XCTAssertEqual(result.status, .timeout)
        XCTAssertEqual(result.error?.code, "timeout")
    }

    func testWaitHonoursDeadlineThenCancelsAndDocumentChangeFastPath() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        await harness.renderer.setStatus(#"{"readyState":"loading","selectorFound":false,"textFound":false,"idleMilliseconds":0,"revision":0}"#)
        let timed = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, timeoutMilliseconds: 300, action: .wait(.selector("#present"))),
            in: owner
        )
        XCTAssertEqual(timed.status, .timeout)
        XCTAssertEqual(timed.error?.code, "timeout")

        // Cancellation token stops the wait early with a cancelled result.
        let token = CancellationToken()
        let waitTask = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, timeoutMilliseconds: 5_000, action: .wait(.text("never"))), cancellation: token)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        token.cancel()
        let cancelled = await waitTask.value
        XCTAssertEqual(cancelled.status, .failed)
        XCTAssertEqual(cancelled.error?.code, "cancelled")

        // documentChanged resolves as soon as the commit rotates identity.
        await harness.renderer.setStatus(#"{"readyState":"loading","selectorFound":false,"textFound":false,"idleMilliseconds":0,"revision":0}"#)
        let before = await session.tabSnapshots()
        _ = before
        let tabID = before.first!.id
        let changeTask = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, timeoutMilliseconds: 5_000, action: .wait(.documentChanged(from: "old-document"))), cancellation: nil)
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        await harness.center.ingress(.loadCommitted(tabID: tabID))
        let changed = await changeTask.value
        XCTAssertEqual(changed.status, .ok)
    }

    func testRendererUnavailableIsHonestFailureNotSilentSuccess() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        await harness.renderer.setMode(.unavailable)
        _ = try await harness.center.taskSession(for: owner)
        let sessions = await harness.center.activeTaskSessionCount
        // No tab could be created on an unavailable surface, but the session
        // itself exists; protocol info still answers truthfully.
        XCTAssertEqual(sessions, 1)
        let session = await harness.center.session(for: owner.taskID)
        let sessionID = await session!.sessionID
        let tabs = await session!.tabSnapshots()
        XCTAssertTrue(tabs.isEmpty, "createTab rolled back when the renderer refused")
        let info = await session!.execute(BrowserCommand(sessionID: sessionID, action: .protocolInfo))
        XCTAssertEqual(info.status, .ok)
        XCTAssertEqual(info.protocolVersion, "FloeBrowser/1.0")
        let navigate = await session!.execute(BrowserCommand(sessionID: sessionID, action: .navigate(url: "https://example.test")))
        XCTAssertEqual(navigate.status, .stale)
        XCTAssertEqual(navigate.error?.code, "tab")
    }

    func testScrollAndCoordinateBoundsAtSurfaceLevel() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let surface = BrowserToolSurface(center: harness.center, policy: harness.policy)
        let owner = BrowserTestHarness.owner()
        let caller = BrowserToolCaller(conversationID: owner.taskID, runID: UUID(), owner: owner)
        do {
            _ = try await surface.invoke(name: "browser.scroll", caller: caller, arguments: .scroll(tabID: nil, deltaX: nil, deltaY: 20_001))
            XCTFail("scroll bound must be enforced")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("scroll delta"))
        }
        do {
            _ = try await surface.invoke(
                name: "browser.clickPoint",
                caller: caller,
                arguments: .clickPoint(tabID: nil, documentID: "d", x: 10_001, y: 5, screenshotSHA256: String(repeating: "0", count: 64), fallbackReason: "noStructuredTarget")
            )
            XCTFail("coordinate bound must be enforced")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("bounded"))
        }
    }
}

extension FakeRenderer {
    func setMode(_ newMode: Mode) { mode = newMode }
    func setStatus(_ json: String) { statusJSON = json }
    func overrideScreenshot(bytes: Data, width: Int, height: Int) {
        screenshotBytes = bytes
        screenshotPixels = (width, height)
    }
}
