// FloeBrowserTests — download admission, origin fence, caps, hashes, cancel.
// Authored (job-9960651880854093), not executed in this source lane. No
// real networking: the fetcher seam is injected.

import XCTest
import FloeCore
import FloeTools
@testable import FloeBrowser

final class BrowserDownloadTests: XCTestCase {
    private struct Fixture {
        let harness: BrowserTestHarness
        let sink: FakeDownloadSink
        let coordinator: BrowserDownloadCoordinator
        let fetcher: DownloadFetcherProbe
    }

    final class DownloadFetcherProbe: @unchecked Sendable {
        var payload: Data = Data("file-bytes".utf8)
        var failWith: Error?
        // Deterministic mid-flight gate for the owner-release test: when
        // closed, the fetcher streams its FIRST chunk, then parks (fully
        // cancellation-aware, so releaseOwner's cancel is what ends it)
        // before finishing, making the ticket GENUINELY in flight when the
        // test releases the owner. Without the gate a tiny scripted payload
        // can commit before release lands — a scheduling lottery, not a
        // fence test.
        private let lock = NSLock()
        private var gated = false
        func setGated(_ value: Bool) { lock.lock(); gated = value; lock.unlock() }
        var isGated: Bool { lock.lock(); defer { lock.unlock() }; return gated }
        func parkWhileGated() async throws {
            while isGated {
                if Task.isCancelled { throw BrowserDownloadError.cancelled }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if Task.isCancelled { throw BrowserDownloadError.cancelled }
        }
    }

    private func makeFixture(cap: Int = 1024) -> Fixture {
        let harness = BrowserTestHarness.make()
        let sink = FakeDownloadSink()
        let probe = DownloadFetcherProbe()
        let coordinator = BrowserDownloadCoordinator(
            policy: harness.policy,
            sink: sink,
            maximumBytesPerDownload: cap,
            fetcher: { _, send in
                if let failure = probe.failWith { throw failure }
                var offset = 0
                var first = true
                while offset < probe.payload.count {
                    let end = min(offset + 256, probe.payload.count)
                    try await send(probe.payload[offset..<end])
                    offset = end
                    if first {
                        first = false
                        try await probe.parkWhileGated()
                    }
                }
            }
        )
        return Fixture(harness: harness, sink: sink, coordinator: coordinator, fetcher: probe)
    }

    private func tabWithOrigin(fixture: Fixture, owner: BrowserOwnerID, url: String) async throws -> (BrowserTaskSession, UUID) {
        let (session, sessionID) = try await makeNavigatedSession(harness: fixture.harness, owner: owner)
        let tabID = (await session.tabSnapshots()).first!.id
        await fixture.harness.renderer.setTabState(tabID, url: url)
        // Ensure the session's cached surface carries the origin.
        _ = await fixture.harness.center.execute(
            BrowserCommand(sessionID: sessionID, tabID: tabID, action: .observe(cursor: nil)),
            in: owner
        )
        return (session, sessionID)
    }

    func testSameOriginAdmittedAndStagedCommitIsHashVerified() async throws {
        let fixture = makeFixture()
        defer { fixture.harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await tabWithOrigin(fixture: fixture, owner: owner, url: "https://example.test/report")
        let query = BrowserDownloadQuery(
            tabID: (await session.tabSnapshots()).first!.id,
            owner: owner,
            url: "https://example.test/files/report.csv",
            contentDisposition: "attachment; filename=\"report.csv\"",
            mimeType: "text/csv",
            suggestedContentLength: 11
        )
        let ticket = await fixture.coordinator.admit(query: query, session: session, sessionID: sessionID)
        XCTAssertNotNil(ticket)
        // Wait for the injected fetch + staged commit to settle.
        try await Task.sleep(nanoseconds: 400_000_000)
        let committed = await fixture.sink.committed
        XCTAssertEqual(committed.count, 1)
        let receipt = committed.first!.receipt
        XCTAssertEqual(receipt.byteCount, fixture.fetcher.payload.count)
        XCTAssertEqual(receipt.sha256, FloeDigest.sha256Hex(fixture.fetcher.payload))
        let stagedLeft = await fixture.sink.stagedCount()
        XCTAssertEqual(stagedLeft, 0, "committed staging is removed")
    }

    func testCrossOriginAndUngrantedPrivateTargetsRefused() async throws {
        let fixture = makeFixture()
        defer { fixture.harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await tabWithOrigin(fixture: fixture, owner: owner, url: "https://example.test/page")
        let cross = BrowserDownloadQuery(
            tabID: (await session.tabSnapshots()).first!.id,
            owner: owner,
            url: "https://evil.test/steal.bin"
        )
        let verdictCross = await fixture.coordinator.admit(query: cross, session: session, sessionID: sessionID)
        XCTAssertNil(verdictCross, "a page cannot pull files through a foreign origin")
        let ungranted = BrowserDownloadQuery(
            tabID: (await session.tabSnapshots()).first!.id,
            owner: owner,
            url: "http://127.0.0.1:9/port-scan.bin"
        )
        let verdictLoopback = await fixture.coordinator.admit(query: ungranted, session: session, sessionID: sessionID)
        XCTAssertNil(verdictLoopback, "ungranted loopback is navigation policy, full stop")
        let opens = await fixture.sink.openCount
        XCTAssertEqual(opens, 0, "a refusal must never open staging")
    }

    func testOverCapSuggestedLengthIsRefusedBeforeStaging() async throws {
        let fixture = makeFixture(cap: 512)
        defer { fixture.harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await tabWithOrigin(fixture: fixture, owner: owner, url: "https://example.test/page")
        let query = BrowserDownloadQuery(
            tabID: (await session.tabSnapshots()).first!.id,
            owner: owner,
            url: "https://example.test/big.bin",
            suggestedContentLength: 4096
        )
        let ticket = await fixture.coordinator.admit(query: query, session: session, sessionID: sessionID)
        XCTAssertNil(ticket)
    }

    func testMidStreamOverCapDiscardsStagingAndNeverCommits() async throws {
        // The coordinator floors every cap at 1 KiB (`max(1024, ...)`, the
        // same value the production default 512 MiB path enforces); a smaller
        // fixture cap would be silently clamped and the transfer would finish
        // instead of overflowing. 1024 IS the honored effective cap here.
        let fixture = makeFixture(cap: 1_024)
        defer { fixture.harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await tabWithOrigin(fixture: fixture, owner: owner, url: "https://example.test/page")
        // 256-byte chunks: 4 chunks fit at the 1024 cap; the 5th overflows
        // mid-stream (staging already open with 1024 bytes appended).
        fixture.fetcher.payload = Data(repeating: 1, count: 1_500)
        let query = BrowserDownloadQuery(
            tabID: (await session.tabSnapshots()).first!.id,
            owner: owner,
            url: "https://example.test/water.bin"
        )
        let ticket = await fixture.coordinator.admit(query: query, session: session, sessionID: sessionID)
        XCTAssertNotNil(ticket)
        try await Task.sleep(nanoseconds: 400_000_000)
        let committed = await fixture.sink.committed
        XCTAssertTrue(committed.isEmpty, "over-cap transfer never commits")
        let discarded = await fixture.sink.discarded
        XCTAssertEqual(discarded.count, 1, "staging is thrown away, not left lying around")
    }

    func testFetcherFailureDiscardsStaging() async throws {
        let fixture = makeFixture()
        defer { fixture.harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await tabWithOrigin(fixture: fixture, owner: owner, url: "https://example.test/page")
        fixture.fetcher.failWith = BrowserDownloadError.cancelled
        let query = BrowserDownloadQuery(
            tabID: (await session.tabSnapshots()).first!.id,
            owner: owner,
            url: "https://example.test/x.bin"
        )
        let ticket = await fixture.coordinator.admit(query: query, session: session, sessionID: sessionID)
        XCTAssertNotNil(ticket)
        try await Task.sleep(nanoseconds: 300_000_000)
        let committed = await fixture.sink.committed
        XCTAssertTrue(committed.isEmpty)
        let discarded = await fixture.sink.discarded
        XCTAssertEqual(discarded.count, 1)
    }

    func testOwnerReleaseFencesInFlightTickets() async throws {
        let fixture = makeFixture(cap: 4_096)
        defer { fixture.harness.teardown() }
        let owner = BrowserTestHarness.owner()
        let (session, sessionID) = try await tabWithOrigin(fixture: fixture, owner: owner, url: "https://example.test/page")
        fixture.fetcher.payload = Data(repeating: 2, count: 2_048)
        fixture.fetcher.setGated(true)
        let tabID = (await session.tabSnapshots()).first!.id
        let query = BrowserDownloadQuery(tabID: tabID, owner: owner, url: "https://example.test/stream.bin")
        let admittedTicket = await fixture.coordinator.admit(query: query, session: session, sessionID: sessionID)
        let ticket = try XCTUnwrap(admittedTicket)
        // Owner retires mid-flight (the gate holds the transfer after its
        // first chunk until releaseOwner's cancel ends it): everything
        // staged is discarded and any later callback against the ticket is
        // refused.
        await fixture.coordinator.releaseOwner(taskID: owner.taskID)
        fixture.fetcher.setGated(false)
        try await Task.sleep(nanoseconds: 300_000_000)
        let committed = await fixture.sink.committed
        XCTAssertTrue(committed.isEmpty)
        do {
            _ = try await fixture.coordinator.commit(ticketID: ticket.id)
            XCTFail("a released ticket cannot finalize")
        } catch let error as BrowserDownloadError {
            XCTAssertEqual(error, .unknownTicket)
        }
    }

    func testFileNameSanitizationKeepsOnlyBasenames() {
        let cases: [(String, String, URL, String, String)] = [
            ("plain", "", URL(string: "https://example.test/a/b/report.pdf")!, "application/pdf", "report.pdf"),
            ("path traversal", "attachment; filename=\"../../../../etc/passwd\"", URL(string: "https://example.test/dl")!, "", "passwd"),
            ("backslash", "attachment; filename=\"C:\\\\bad\\\\name.zip\"", URL(string: "https://example.test/dl")!, "", "name.zip"),
            ("empty falls back", "", URL(string: "https://example.test/")!, "application/zip", "download.zip"),
            ("control chars", "attachment; filename=\"ra\t\nute.txt\"", URL(string: "https://example.test/dl")!, "", "raute.txt"),
            ("percent-encoded name", "attachment; filename=\"%e2%82%ac-euro.csv\"", URL(string: "https://example.test/dl")!, "", "€-euro.csv"),
        ]
        for (label, disposition, url, mime, expected) in cases {
            let sanitized = BrowserDownloadCoordinator.sanitizeFileName(
                contentDisposition: disposition,
                url: url,
                mimeType: mime
            )
            XCTAssertEqual(sanitized, expected, label)
            XCTAssertFalse(sanitized.contains("/"))
            XCTAssertFalse(sanitized.contains("\\"))
            XCTAssertFalse(sanitized.hasPrefix("."))
            XCTAssertFalse(sanitized.contains(".."))
        }
    }
}

extension FakeDownloadSink {
    var stagedHandlesRemaining: Int { staged.count }
}
