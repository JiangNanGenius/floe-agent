// FloeBrowserTests — address-bar commit semantics (G04-R2 navigation repair).
// Authored (job-db20e94a68474091) but NOT executed in this source lane; Main's
// unified batch runs them after integration (host-runnable: no UIKit, no
// WebKit, no networking, no device — same discipline as the existing
// FloeBrowserTests doubles).

import XCTest
@testable import FloeBrowser

final class BrowserAddressNavigationTests: XCTestCase {
    /// The live G04-R2 blocker, legacy two-op path: a bare loopback URL must
    /// be refused by the EXACT original policy — but honestly, not silently.
    func testBlockedLoopbackCommitSurfacesHonestFailure() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        await harness.center.bind(to: owner.taskID, owner: owner)
        let session = try await harness.center.taskSession(for: owner)

        await harness.center.setAddressText("http://127.0.0.1:61240/index.html", in: owner.taskID)
        await harness.center.setEditingAddress(false, in: owner.taskID)
        await harness.center.navigateFromAddressBar(in: owner.taskID)

        let navigations = await harness.renderer.navigations
        XCTAssertTrue(navigations.isEmpty, "an ungranted loopback target must never reach the renderer")
        let surface = await session.surfaceState
        XCTAssertEqual(surface, .failed("Loopback and private-network navigation is blocked"))
    }

    /// The draft-carrying single commit operation: the draft parameter — not
    /// any previously stored text — is what reaches the policy and renderer,
    /// and the editing flag clears inside the same session-owned step.
    func testDraftCommitNavigatesWithTheDraftParameter() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        await harness.center.bind(to: owner.taskID, owner: owner)
        let session = try await harness.center.taskSession(for: owner)

        // Stale stored text (an older echo) must NOT decide the target.
        await harness.center.setAddressText("https://stale.example/old", in: owner.taskID)
        await harness.center.setEditingAddress(true, in: owner.taskID)

        let draft = "https://example.test/floe?q=1"
        await harness.center.navigateFromAddressBar(in: owner.taskID, draft: draft)

        let navigations = await harness.renderer.navigations
        XCTAssertEqual(navigations.map { $0.url }, [draft])
        let address = await session.addressText
        XCTAssertEqual(address, draft)
        let editing = await session.isEditingAddress
        XCTAssertFalse(editing, "the draft commit owns the editing-flag clear")
    }

    /// Draft-carrying commit against an ungranted loopback: same honest
    /// failure semantics as the legacy path, still zero renderer traffic.
    func testDraftCommitBlockedLoopbackIsHonestAndSilentOnTheWire() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        await harness.center.bind(to: owner.taskID, owner: owner)
        let session = try await harness.center.taskSession(for: owner)

        await harness.center.navigateFromAddressBar(
            in: owner.taskID, draft: "http://127.0.0.1:61240/index.html")

        let navigations = await harness.renderer.navigations
        XCTAssertTrue(navigations.isEmpty)
        let surface = await session.surfaceState
        XCTAssertEqual(surface, .failed("Loopback and private-network navigation is blocked"))
        let address = await session.addressText
        XCTAssertEqual(address, "http://127.0.0.1:61240/index.html", "the draft stays visible for correction")
    }

    /// A granted preview allocation navigates, and a prior blocked-commit
    /// failure banner cannot linger once the accepted load is owned by the
    /// lifecycle pump.
    func testGrantedPreviewCommitNavigatesAndClearsStaleFailure() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        await harness.center.bind(to: owner.taskID, owner: owner)
        let session = try await harness.center.taskSession(for: owner)

        // First commit: blocked, leaving a failure banner.
        await harness.center.navigateFromAddressBar(
            in: owner.taskID, draft: "http://127.0.0.1:61240/index.html")
        let blockedSurface = await session.surfaceState
        XCTAssertEqual(blockedSurface,
                       .failed("Loopback and private-network navigation is blocked"))

        // Second commit: the exact granted allocation.
        let token = String(repeating: "d", count: 32)
        let url = URL(string: "http://127.0.0.1:45000/\(token)/index.html")!
        harness.policy.authorizePreview(url)
        await harness.center.navigateFromAddressBar(in: owner.taskID, draft: url.absoluteString)

        let navigations = await harness.renderer.navigations
        XCTAssertEqual(navigations.map { $0.url }, [url.absoluteString])
        let acceptedSurface = await session.surfaceState
        XCTAssertEqual(acceptedSurface, .loading)

        // The lifecycle pump then owns the state, exactly like production.
        let tabID = (await session.tabSnapshots()).first!.id
        await harness.center.ingress(.loadFinished(tabID: tabID, url: url.absoluteString, title: "P"))
        let settledSurface = await session.surfaceState
        XCTAssertEqual(settledSurface, .ready)
    }

    /// Legacy nil-draft semantics survive untouched: editing state is NOT
    /// cleared by the commit itself (it stays owned by the separate
    /// setEditingAddress flow).
    func testLegacyNilPathKeepsOriginalEditingSemantics() async throws {
        let harness = BrowserTestHarness.make()
        defer { harness.teardown() }
        let owner = BrowserTestHarness.owner()
        await harness.center.bind(to: owner.taskID, owner: owner)
        let session = try await harness.center.taskSession(for: owner)

        await harness.center.setAddressText("https://example.test/legacy", in: owner.taskID)
        await harness.center.setEditingAddress(true, in: owner.taskID)
        await harness.center.navigateFromAddressBar(in: owner.taskID)

        let navigations = await harness.renderer.navigations
        XCTAssertEqual(navigations.map { $0.url }, ["https://example.test/legacy"])
        let editing = await session.isEditingAddress
        XCTAssertTrue(editing, "the nil-draft commit must not invent an editing clear")
    }
}
