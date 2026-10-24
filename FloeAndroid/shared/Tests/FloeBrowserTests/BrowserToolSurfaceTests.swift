// FloeBrowserTests — the frozen tool surface: owner/ceiling/validation
// parity with the iOS originals. Authored (job-9960651880854093), not
// executed in this source lane.

import XCTest
import FloeCore
import FloeTools
@testable import FloeBrowser

/// Sendable handoff-delivery tally for the injected `deliverHandoff`
/// closure (it runs on the session center's executor; capturing a stack
/// `var` is illegal under Swift 6 concurrency). Records exactly the same
/// deliveries the original `delivered += 1` did.
private actor DeliveryTally {
    private var count = 0
    func record() { count += 1 }
    func value() -> Int { count }
}

final class BrowserToolSurfaceTests: XCTestCase {
    private func caller(_ owner: BrowserOwnerID, run: UUID = UUID()) -> BrowserToolCaller {
        BrowserToolCaller(conversationID: owner.taskID, runID: run, owner: owner)
    }

    func testFrozenNamesAreComplete() {
        XCTAssertEqual(
            BrowserToolSurface.frozenToolNames,
            [
                "browser.panel", "browser.tabs", "browser.tab", "browser.events", "browser.wait",
                "browser.navigate", "browser.observe", "browser.screenshot", "browser.clickVisualText",
                "browser.click", "browser.clickPoint", "browser.type", "browser.scroll",
                "preview.start", "preview.reload", "preview.stop",
            ]
        )
    }

    func testUnknownToolAndOwnerCeilings() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let surface = BrowserToolSurface(center: harness.center, policy: harness.policy)
        let owner = BrowserTestHarness.owner()

        do {
            _ = try await surface.invoke(name: "browser.teleport", caller: caller(owner), arguments: .tabs)
            XCTFail("unknown tool must be refused")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("Unknown browser tool"))
        }

        // No runtime conversation -> the durable browser is refused (never
        // "the browser that happens to be visible").
        let anonymous = BrowserToolCaller(conversationID: nil, owner: owner)
        do {
            _ = try await surface.invoke(name: "browser.tabs", caller: anonymous, arguments: .tabs)
            XCTFail("nil owner must be refused")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("task-owned run"))
        }

        // Temporary chat ceiling unchanged.
        let temporary = BrowserToolCaller(
            conversationID: owner.taskID,
            runID: UUID(),
            temporaryReadOnly: true,
            publicWebOnly: false,
            owner: owner
        )
        do {
            _ = try await surface.invoke(name: "browser.tabs", caller: temporary, arguments: .tabs)
            XCTFail("temporary chat cannot open a durable browser")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("Temporary chat"))
        }

        // Owner triple must match the runtime conversation exactly.
        let mismatched = BrowserToolCaller(conversationID: owner.taskID, runID: UUID(), owner: BrowserTestHarness.owner())
        do {
            _ = try await surface.invoke(name: "browser.tabs", caller: mismatched, arguments: .tabs)
            XCTFail("a different task's binding must not drive this browser")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("ownership binding"))
        }
    }

    func testHandoffRunAttributionRules() throws {
        let owner = UUID()
        let parentRun = UUID()
        let ownRun = UUID()
        let main = BrowserToolCaller(conversationID: owner, runID: ownRun, owner: BrowserOwnerID(taskID: owner, workspaceID: UUID(), rootEpoch: 1))
        XCTAssertEqual(try BrowserToolSurface.handoffRun(for: main, owner: owner), ownRun)

        let child = BrowserToolCaller.Child(rootTaskID: owner, parentRunID: parentRun, depth: 1)
        let childCaller = BrowserToolCaller(conversationID: owner, runID: ownRun, childExecution: child, owner: main.owner)
        XCTAssertEqual(try BrowserToolSurface.handoffRun(for: childCaller, owner: owner), parentRun, "the ORIGINAL parent run, never the newest")

        let nested = BrowserToolCaller.Child(rootTaskID: owner, parentRunID: parentRun, depth: 2)
        let nestedCaller = BrowserToolCaller(conversationID: owner, runID: ownRun, childExecution: nested, owner: main.owner)
        XCTAssertThrowsError(try BrowserToolSurface.handoffRun(for: nestedCaller, owner: owner))

        let foreign = BrowserToolCaller.Child(rootTaskID: UUID(), parentRunID: parentRun, depth: 1)
        let foreignCaller = BrowserToolCaller(conversationID: owner, runID: ownRun, childExecution: foreign, owner: main.owner)
        XCTAssertThrowsError(try BrowserToolSurface.handoffRun(for: foreignCaller, owner: owner))
    }

    func testNavigationValidationHappensBeforeDispatch() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let surface = BrowserToolSurface(center: harness.center, policy: harness.policy)
        let owner = BrowserTestHarness.owner()
        // Ungranted loopback (page cannot mint a grant) is refused even
        // before any session work starts.
        do {
            _ = try await surface.invoke(
                name: "browser.navigate",
                caller: caller(owner),
                arguments: .navigate(url: "http://127.0.0.1:9999/x", tabID: nil)
            )
            XCTFail("private navigation must be blocked")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("http and https") || (error.errorDescription ?? "").contains("private-network"))
        }
    }

    func testResultEnvelopeMatchesOriginalRunPath() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let surface = BrowserToolSurface(center: harness.center, policy: harness.policy)
        let owner = BrowserTestHarness.owner()
        let output = try await surface.invoke(name: "browser.tabs", caller: caller(owner), arguments: .tabs)
        // The BrowserResult JSON is the summary; never truncated mid-field.
        let decoded = try JSONDecoder().decode(BrowserResult.self, from: Data(output.summary.utf8))
        XCTAssertEqual(decoded.status, .ok)
        XCTAssertNotNil(decoded.page?.tabs)
        XCTAssertEqual(output.fullOutputSHA256, FloeDigest.sha256Hex(Data(output.summary.utf8)))
        XCTAssertEqual(output.summary.count <= BrowserToolSurface.summaryCeilingCharacters, true)

        // Failure statuses throw validation with the native message. The
        // envelope must reflect ACTUAL live tab ownership: the original run
        // path activates only tabs this task owns and then observes exactly
        // that tab, so activating a foreign/unknown tab surfaces the stale
        // tab refusal — the active tab is never silently substituted.
        _ = await harness.center.session(for: owner.taskID)
        do {
            _ = try await surface.invoke(
                name: "browser.tab",
                caller: caller(owner),
                arguments: .tab(action: "activate", tabID: UUID())
            )
            XCTFail("activating a tab the task does not own must keep the original stale refusal")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("Browser tab is no longer available"))
        }
    }

    func testEventsAndWaitArgumentBounds() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let surface = BrowserToolSurface(center: harness.center, policy: harness.policy)
        let owner = BrowserTestHarness.owner()
        do {
            _ = try await surface.invoke(name: "browser.events", caller: caller(owner), arguments: .events(tabID: nil, afterSequence: nil, limit: 51))
            XCTFail("limit bound")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("limit"))
        }
        do {
            _ = try await surface.invoke(name: "browser.events", caller: caller(owner), arguments: .events(tabID: nil, afterSequence: -1, limit: nil))
            XCTFail("afterSequence bound")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("afterSequence"))
        }
        do {
            _ = try await surface.invoke(name: "browser.wait", caller: caller(owner), arguments: .wait(tabID: nil, condition: "selector", value: nil, quietMilliseconds: nil, timeoutMilliseconds: nil))
            XCTFail("value required")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("requires value"))
        }
        do {
            _ = try await surface.invoke(name: "browser.wait", caller: caller(owner), arguments: .wait(tabID: nil, condition: "idle", value: nil, quietMilliseconds: 50, timeoutMilliseconds: nil))
            XCTFail("quiet bound")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("quietMilliseconds"))
        }
    }

    func testClickVisualTextArgumentGrammar() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let surface = BrowserToolSurface(center: harness.center, policy: harness.policy)
        let owner = BrowserTestHarness.owner()
        do {
            _ = try await surface.invoke(
                name: "browser.clickVisualText",
                caller: caller(owner),
                arguments: .clickVisualText(tabID: nil, documentID: "doc", reference: "n7", screenshotSHA256: String(repeating: "a", count: 64))
            )
            XCTFail("only text-N references are accepted")
        } catch let error as BrowserToolError {
            XCTAssertTrue((error.errorDescription ?? "").contains("text-N"))
        }
    }

    func testPanelRequestAndHideDispatch() async throws {
        let delivered = DeliveryTally()
        let harness = BrowserTestHarness.make { _, _ in
            await delivered.record()
            return true
        }
        defer { harness.teardown() }
        let surface = BrowserToolSurface(center: harness.center, policy: harness.policy)
        let owner = BrowserTestHarness.owner()
        _ = try await makeNavigatedSession(harness: harness, owner: owner)
        let output = try await surface.invoke(
            name: "browser.panel",
            caller: caller(owner),
            arguments: .panel(action: "requestUser", reason: "finish the captcha", tabID: nil)
        )
        XCTAssertTrue(output.summary.contains("The user controls this task's browser"))
        XCTAssertFalse(output.requiresUserAction)
        let digest = FloeDigest.sha256Hex(Data("finish the captcha".utf8))
        XCTAssertEqual(output.fullOutputSHA256, digest)

        // hide on a user-controlled visible panel is refused (original rule).
        await harness.center.bind(to: owner.taskID, owner: owner)
        do {
            _ = try await surface.invoke(name: "browser.panel", caller: caller(owner), arguments: .panel(action: "hide", reason: nil, tabID: nil))
            XCTFail("hide must wait for control to return")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("return browser control"))
        }
        _ = await harness.center.returnToAgent(continueTask: false)
        _ = try await surface.invoke(name: "browser.panel", caller: caller(owner), arguments: .panel(action: "hide", reason: nil, tabID: nil))
        let projection = await harness.center.projection()
        XCTAssertEqual(projection.presentationRequest?.show, false)
        let deliveredCount = await delivered.value()
        XCTAssertEqual(deliveredCount, 1)
    }
}
