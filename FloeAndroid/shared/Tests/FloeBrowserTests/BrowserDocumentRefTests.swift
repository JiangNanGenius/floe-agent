// FloeBrowserTests — document/reference fences, event buffers, takeover gate.
// Authored (job-9960651880854093), not executed in this source lane.

import XCTest
import FloeCore
@testable import FloeBrowser

final class BrowserDocumentRefTests: XCTestCase {
    func testNavigationCommitRotatesDocumentAndFencesOldRefs() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabs = await session.tabSnapshots()
        let tabID = tabs.first!.id

        let observed = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)),
            in: owner
        )
        XCTAssertEqual(observed.status, .ok)
        let documentID = observed.page?.documentID
        XCTAssertFalse(documentID?.isEmpty ?? true)

        // An action bound to the OLD document is refused after commit.
        let stale = await harness.center.execute(
            BrowserCommand(
                sessionID: sessionID,
                tabID: tabID,
                expectedDocumentID: "previous-document",
                action: .click(.element(ref: "n1", documentID: "previous-document"))
            ),
            in: owner
        )
        XCTAssertEqual(stale.status, .stale)
        XCTAssertEqual(stale.error?.code, "document")

        // A new commit (page navigation) rotates the identity again.
        await harness.center.ingress(.loadCommitted(tabID: tabID))
        let after = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)),
            in: owner
        )
        XCTAssertNotEqual(after.page?.documentID, documentID)

        // And the ref expression the renderer receives carries the CURRENT
        // session document ID, never page-chosen text.
        await harness.renderer.setTabState(tabID, url: "https://example.test/feed")
        let clicked = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .click(.element(ref: "n1", documentID: after.page!.documentID))),
            in: owner
        )
        XCTAssertEqual(clicked.status, .ok)
        let evaluations = await harness.renderer.evaluations
        let performCall = evaluations.last { $0.expression.contains("p.perform(") }
        XCTAssertNotNil(performCall)
        XCTAssertTrue(performCall!.expression.contains(after.page!.documentID))
        XCTAssertTrue(performCall!.expression.contains("\"n1\""))
    }

    func testLoadFailureSurfacesAsFailedStateAndNetworkEvent() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.center.ingress(.loadFailed(tabID: tabID, errorDomain: "NSURLErrorDomain", errorCode: -1009, errorDescription: "not connected"))
        let surface = await session.surfaceState
        if case .failed(let detail) = surface {
            XCTAssertTrue(detail.contains("-1009"))
        } else {
            XCTFail("load failure must surface as .failed, got \(surface)")
        }
        let events = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .events(afterSequence: 0, limit: 50)),
            in: owner
        )
        XCTAssertTrue(events.events.contains { $0.method == "Network.loadingFailed" && $0.detail == "NSURLErrorDomain:-1009" })
    }

    func testTakeoverGateAllowsReadsAndFencesEveryMutationIncludingQueued() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id

        // Snapshot the current document for action binding.
        let observed = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)),
            in: owner
        )
        let documentID = observed.page!.documentID

        // Begin user control through the receipt path.
        await harness.center.takeControl(in: owner.taskID)
        let controlling = await session.isUserControlling
        XCTAssertTrue(controlling)

        // Reads remain allowed.
        let read = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)),
            in: owner
        )
        XCTAssertEqual(read.status, .ok)

        // Mutations refuse with needsUser/takeover.
        let mutation = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, expectedDocumentID: documentID, action: .click(.element(ref: "n1", documentID: documentID))),
            in: owner
        )
        XCTAssertEqual(mutation.status, .needsUser)
        XCTAssertEqual(mutation.error?.code, "takeover")

        // Return control, then prove a mutation QUEUED behind slow work is
        // fenced by the CURRENT flag at execution time (never at enqueue).
        await session.setUserControlling(false)
        await harness.renderer.setEvaluateDelay(250_000_000) // 250ms in-flight hold
        let first = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, action: .click(.element(ref: "n1", documentID: documentID))))
        }
        try await Task.sleep(nanoseconds: 60_000_000) // first action owns the gate
        let queued = Task {
            await session.execute(BrowserCommand(sessionID: sessionID, action: .scroll(deltaX: 0, deltaY: 100)))
        }
        try await Task.sleep(nanoseconds: 40_000_000) // queued action is now gated
        await session.setUserControlling(true)
        let firstResult = await first.value
        let queuedResult = await queued.value
        XCTAssertEqual(firstResult.status, .ok, "an action already executing when control transfers completes honestly")
        XCTAssertEqual(queuedResult.status, .needsUser)
        XCTAssertEqual(queuedResult.error?.code, "takeover")
    }

    func testInvalidateDocumentsForHandoffClearsEvidence() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let shot = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, action: .screenshot),
            in: owner
        )
        XCTAssertEqual(shot.status, .ok)
        XCTAssertNotNil(shot.page?.screenshotArtifact)
        let before = shot.page!.documentID
        await session.invalidateDocumentsForHandoff()
        let after = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, action: .observe(cursor: nil)),
            in: owner
        )
        XCTAssertNotEqual(after.page?.documentID, before)
        // Visual-text click now refuses: regions are gone with the evidence.
        let visual = await harness.center.execute(
            BrowserCommand(
                sessionID: sessionID,
                expectedDocumentID: after.page?.documentID,
                visualEvidenceSHA256: shot.page!.screenshotArtifact!.sha256.lowercased(),
                visualFallbackReason: "insufficientStructuredInformation",
                action: .click(.visualText(reference: "text-1"))
            ),
            in: owner
        )
        XCTAssertEqual(visual.status, .blocked)
        XCTAssertEqual(visual.error?.code, "policy")
    }

    func testEventBuffersAndDetailAreBounded() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        // Drive more lifecycle events than the per-tab cap (256).
        for index in 0..<300 {
            await harness.center.ingress(.loadFailed(tabID: tabID, errorDomain: "d" + String(repeating: "x", count: 600), errorCode: index, errorDescription: "boom"))
        }
        let events = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .events(afterSequence: 0, limit: 100)),
            in: owner
        )
        XCTAssertLessThanOrEqual(events.events.count, 100) // bounded result page
        let all = await session.tabEvents(tabID: tabID)
        XCTAssertLessThanOrEqual(all.count, 256)
        XCTAssertTrue(all.allSatisfy { ($0.detail?.count ?? 0) <= 512 })
        XCTAssertTrue(all.contains { ($0.detail?.count ?? 0) == 512 }, "long details must be truncated at 512")
        XCTAssertGreaterThan(all.first!.sequence, 1, "the FIFO retention dropped the oldest events")
        // Sequences strictly increase and paging floor works.
        let sequences = events.events.map(\.sequence)
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(events.nextEventSequence, sequences.last)
    }

    func testObservePaginationCursor() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await makeNavigatedSession(harness: harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        let node = #"{"ref":"n1","role":"button","name":"","text":"Go","value":null,"state":{},"bounds":{"x":1,"y":2,"width":3,"height":4}}"#
        await harness.renderer.nodes("[\(node),\(node)]", nextCursor: 40)
        let pageOne = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: 0)),
            in: owner
        )
        XCTAssertEqual(pageOne.page?.nodes.count, 2)
        XCTAssertEqual(pageOne.page?.nextCursor, 40)
        let pageTwo = await harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: 40)),
            in: owner
        )
        XCTAssertEqual(pageTwo.status, .ok)
    }
}

extension BrowserTaskSession {
    func tabEvents(tabID: UUID) -> [BrowserProtocolEvent] {
        tabs.first(where: { $0.id == tabID })?.events ?? []
    }
}
