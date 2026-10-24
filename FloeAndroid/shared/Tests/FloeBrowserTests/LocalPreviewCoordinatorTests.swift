// FloeBrowserTests — preview coordinator ownership, operation fences and
// joined teardown. Authored (job-9960651880854093), not executed here.

import XCTest
import FloeCore
@testable import FloeBrowser

final class LocalPreviewCoordinatorTests: XCTestCase {
    private struct Fixture {
        let harness: BrowserTestHarness
        let transport: FakePreviewTransport
        let resource: FakePreviewResource
        let coordinator: LocalPreviewCoordinator
    }

    private func makeFixture(
        deliverHandoff: (@Sendable (BrowserHandoff, Bool) async throws -> Bool)? = nil
    ) -> Fixture {
        let harness = BrowserTestHarness.make(deliverHandoff: deliverHandoff)
        let transport = FakePreviewTransport()
        let resource = FakePreviewResource()
        let coordinator = LocalPreviewCoordinator(
            browser: harness.center,
            transport: transport,
            resource: resource,
            policy: harness.policy
        )
        return Fixture(harness: harness, transport: transport, resource: resource, coordinator: coordinator)
    }

    func testStartServesTokenBoundExactAllocationAndGrantsNavigation() async throws {
        let fixture = makeFixture()
        await fixture.resource.seed(body: "<html>site</html>", at: "site/index.html")
        await fixture.resource.addDirectory("site")
        let owner = BrowserTestHarness.owner()
        let outcome = try await fixture.coordinator.start(owner: owner, relativeRoot: "site", entry: nil)
        let url = URL(string: outcome.url)!
        XCTAssertEqual(outcome.entry, "index.html")
        let token = url.pathComponents[1]
        XCTAssertEqual(token.count, 32)
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertNotNil(url.port)
        // Navigation now passes the policy for this allocation. Preview grants
        // are EXACT to the port+token pair (the frozen BrowserURLPolicyTests
        // semantics: per-allocation, never per-conversation, never a wider
        // fallback): the same port with another token and the same token on
        // another port both stay refused.
        XCTAssertNoThrow(try fixture.harness.policy.validate(outcome.url, conversationID: owner.taskID))
        XCTAssertThrowsError(try fixture.harness.policy.validate(
            "http://127.0.0.1:\(url.port!)/\(String(repeating: "f", count: 32))/index.html",
            conversationID: owner.taskID
        ))
        XCTAssertThrowsError(try fixture.harness.policy.validate(
            "http://127.0.0.1:\(url.port! + 1)/\(token)/index.html",
            conversationID: owner.taskID
        ))
        // The owner session navigated to the staged URL.
        let navigations = await fixture.harness.renderer.navigations
        XCTAssertTrue(navigations.contains { $0.url == outcome.url })
        // The transport is serving the lease with the Swift-minted token.
        let starts = await fixture.transport.starts
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first!.lease.token, token)
        let previewActive = await fixture.coordinator.isPreviewActive(for: owner.taskID)
        XCTAssertTrue(previewActive)
    }

    func testFileAsRootServesParentWithFileAsEntry() async throws {
        let fixture = makeFixture()
        await fixture.resource.seed(body: "<html>page</html>", at: "site/app.html")
        await fixture.resource.addDirectory("site")
        let owner = BrowserTestHarness.owner()
        let outcome = try await fixture.coordinator.start(owner: owner, relativeRoot: "site/app.html", entry: nil)
        XCTAssertTrue(
            outcome.url.contains("app.html"),
            "the file-as-root rule serves the parent with that file as entry: \(outcome.url)"
        )
        XCTAssertEqual(outcome.entry, "app.html")
    }

    func testUnsafeRootIsRejectedBeforeAnyBinding() async throws {
        let fixture = makeFixture()
        let owner = BrowserTestHarness.owner()
        do {
            _ = try await fixture.coordinator.start(owner: owner, relativeRoot: "../outside", entry: nil)
            XCTFail("workspace-escape root must be refused")
        } catch let error as BrowserPreviewError {
            XCTAssertTrue((error.errorDescription ?? "").contains("safe workspace-relative path"))
        }
        let starts = await fixture.transport.starts
        XCTAssertTrue(starts.isEmpty, "refusal must not leak a bound listener")
    }

    func testMissingEntryFailsBeforeBindingAndIsActionable() async throws {
        let fixture = makeFixture()
        await fixture.resource.seed(body: "x", at: "notes.txt")
        let owner = BrowserTestHarness.owner()
        do {
            _ = try await fixture.coordinator.start(owner: owner, relativeRoot: nil, entry: nil)
            XCTFail("no candidate entry should fail honestly")
        } catch let error as BrowserPreviewError {
            XCTAssertTrue((error.errorDescription ?? "").contains("index.html"))
        }
        let starts = await fixture.transport.starts
        let stops = await fixture.transport.stops
        XCTAssertTrue(starts.isEmpty, "entry resolution happens BEFORE binding")
        XCTAssertTrue(stops.isEmpty)
    }

    func testSupersededStartCannotResurrectAStoppedOwner() async throws {
        let fixture = makeFixture()
        await fixture.resource.seed(body: "<html>a</html>", at: "site/index.html")
        await fixture.resource.addDirectory("site")
        let owner = BrowserTestHarness.owner()
        // Make the LISTENER slow so stop() lands mid-start (the original race
        // this fence exists for).
        await fixture.transport.setStartDelay(300_000_000)
        let startTask = Task {
            try await fixture.coordinator.start(owner: owner, relativeRoot: "site", entry: nil)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = await fixture.coordinator.stop(owner: owner.taskID)
        do {
            _ = try await startTask.value
            XCTFail("the in-flight start was already stopped; promotion is fenced")
        } catch let error as BrowserPreviewError {
            XCTAssertEqual(error, .superseded)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let previewActiveAfterSupersede = await fixture.coordinator.isPreviewActive(for: owner.taskID)
        XCTAssertFalse(previewActiveAfterSupersede)
        // Every lease that was ever started was also stopped exactly once
        // (the staging created by the aborted start cleaned up after itself).
        let starts = await fixture.transport.starts
        let stops = await fixture.transport.stops
        for entry in starts {
            XCTAssertTrue(stops.contains(entry.lease.leaseID))
        }
    }

    func testStopOnlyTouchesThatOwnerAndRevokesTheGrant() async throws {
        let fixture = makeFixture()
        await fixture.resource.seed(body: "<html>a</html>", at: "site/index.html")
        await fixture.resource.addDirectory("site")
        let ownerA = BrowserTestHarness.owner()
        let ownerB = BrowserTestHarness.owner()
        let outA = try await fixture.coordinator.start(owner: ownerA, relativeRoot: "site", entry: nil)
        let outB = try await fixture.coordinator.start(owner: ownerB, relativeRoot: "site", entry: nil)
        let leaseAID = await fixture.coordinator.activeLeaseID(for: ownerA.taskID)
        let leaseA = try XCTUnwrap(leaseAID)
        _ = await fixture.coordinator.stop(owner: ownerA.taskID)
        XCTAssertNoThrow(try fixture.harness.policy.validate(outB.url, conversationID: ownerB.taskID))
        XCTAssertThrowsError(try fixture.harness.policy.validate(outA.url, conversationID: ownerA.taskID))
        // And adjudication for A's retired lease is a 404, serving nothing.
        let verdict = await fixture.coordinator.adjudicate(
            leaseID: leaseA,
            requestID: UUID(),
            headerBlock: Data("GET /whatever HTTP/1.1\r\nHost: 127.0.0.1:47000\r\n\r\n".utf8)
        )
        XCTAssertEqual(verdict.statusLine, "404 Not Found")
    }

    func testReleasePreviewStopsExactlyTheOwnersLease() async throws {
        let fixture = makeFixture()
        await fixture.resource.seed(body: "<html>a</html>", at: "site/index.html")
        await fixture.resource.addDirectory("site")
        let owner = BrowserTestHarness.owner()
        _ = try await fixture.coordinator.start(owner: owner, relativeRoot: "site", entry: nil)
        await fixture.coordinator.releasePreview(for: owner.taskID) // what center.ownerReleaseHook drives
        let previewActiveAfterRelease = await fixture.coordinator.isPreviewActive(for: owner.taskID)
        XCTAssertFalse(previewActiveAfterRelease)
        let stops = await fixture.transport.stops
        XCTAssertEqual(stops.count, 1)
    }

    func testReloadRefusesWhenPageNoLongerShowsThePreview() async throws {
        let fixture = makeFixture()
        await fixture.resource.seed(body: "<html>a</html>", at: "site/index.html")
        await fixture.resource.addDirectory("site")
        let owner = BrowserTestHarness.owner()
        let out = try await fixture.coordinator.start(owner: owner, relativeRoot: "site", entry: nil)
        let (session, _) = try await makeNavigatedSession(harness: fixture.harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id

        // The user navigated away: the trusted platform fact is a finished
        // load on this tab (the same ingress channel makeNavigatedSession
        // uses). Reload refuses, not a fake success. Writing only the fake
        // renderer's internal table never reaches the session's cached
        // surface, which is what production actually reads.
        await fixture.harness.center.ingress(.loadFinished(
            tabID: tabID,
            url: "https://elsewhere.test/page",
            title: "Elsewhere"
        ))
        do {
            _ = try await fixture.coordinator.reload(owner: owner)
            XCTFail("must refuse")
        } catch let error as BrowserPreviewError {
            XCTAssertEqual(error, .notShowingPreview)
        }

        // A subpage of the SAME allocation is still this owner's preview:
        let url = URL(string: out.url)!
        let token = url.pathComponents[1]
        await fixture.harness.center.ingress(.loadFinished(
            tabID: tabID,
            url: "http://127.0.0.1:\(url.port!)/\(token)/app/index.html",
            title: "App"
        ))
        let output = try await fixture.coordinator.reload(owner: owner)
        XCTAssertTrue(output.summary.contains("Preview reloaded"))
        let reloads = await fixture.harness.renderer.reloads
        XCTAssertTrue(reloads.contains(tabID))
    }

    func testReloadDuringUserControlReportsRequiresUserActionNotSuccess() async throws {
        let fixture = makeFixture(deliverHandoff: { _, _ in true })
        await fixture.resource.seed(body: "<html>a</html>", at: "site/index.html")
        await fixture.resource.addDirectory("site")
        let owner = BrowserTestHarness.owner()
        _ = try await fixture.coordinator.start(owner: owner, relativeRoot: "site", entry: nil)
        try await fixture.harness.center.requestUserInteraction(reason: "manual step", tabID: nil, runID: nil, in: owner.taskID)
        let output = try await fixture.coordinator.reload(owner: owner)
        XCTAssertTrue(output.requiresUserAction, "needsUser reload is never reported as success")
    }
}

extension FakePreviewTransport {
    func setStartDelay(_ nanoseconds: UInt64) {
        startDelayNanoseconds = nanoseconds
    }
}
