// SPDX-License-Identifier: MPL-2.0
//
// G04BrowserHostTests — the C ABI's fail-closed contract. With NO installed
// composition and NO bound pump (the exact state of a host before Main's
// mount, or after every retirement), every export must answer a typed
// refusal or an honest unavailability verdict — never a success string, a
// fabricated epoch, or a stale projection. These tests pin the trust
// boundaries the Kotlin bridge relies on.
import XCTest
import FloeCore
import FloeTools
import FloeBrowser
@testable import FloeAndroidCore

final class G04BrowserHostTests: XCTestCase {

    private func withCString(_ text: String, _ body: (UnsafePointer<CChar>) -> Int32) -> Int32 {
        text.withCString { body($0) }
    }

    func testLateWebViewCallbacksCannotUseAnotherRootOrImplicitCurrentEpoch() {
        let old: [String: Any] = ["rootEpoch": "410", "url": "https://example.invalid/"]
        XCTAssertTrue(g04BrowserHostEpochMatches(old, epoch: 410))
        XCTAssertFalse(g04BrowserHostEpochMatches(old, epoch: 411))
        XCTAssertFalse(g04BrowserHostEpochMatches(["url": "https://example.invalid/"], epoch: 411))
        XCTAssertFalse(g04BrowserHostEpochMatches(["rootEpoch": 411], epoch: 411))
        XCTAssertFalse(g04BrowserHostEpochMatches(["rootEpoch": "0411"], epoch: 411))
        XCTAssertFalse(g04BrowserHostEpochMatches(["rootEpoch": "0"], epoch: 0))
    }

    // MARK: - Pump binding

    func testBindRefusesWithoutLiveServicesAndFabricatedEpochs() {
        let mailbox = G04BrowserMailbox.shared
        // The export requires the NATIVE root epoch readback AND registered
        // services for the same value. In a unit-test process neither
        // exists, so every epoch — including the mailbox's own — is
        // refused. This is the fail-closed proof for -102.
        XCTAssertEqual(floeBrowserBind(0), -102)
        XCTAssertEqual(floeBrowserBind(1), -102)
        XCTAssertEqual(floeBrowserBind(UInt64(Date().timeIntervalSince1970)), -102)
        XCTAssertEqual(floeBrowserBind(mailbox.boundEpoch == 0 ? 7 : mailbox.boundEpoch), -102)
        // close is idempotent and never throws.
        XCTAssertEqual(floeBrowserClose(999_999), 0)
        XCTAssertEqual(floeBrowserServicesLive(999_999), -602)
    }

    // MARK: - Uplink grammar without services

    func testUplinksFailClosedWhenNoGenerationIsInstalled() {
        // Direct mailbox calls are still bound to the mailbox itself:
        // claims of nonexistent tickets are typed, not crashes.
        XCTAssertEqual(floeBrowserComplete(-5, 0, nil, 0), -101) // stale claim
        XCTAssertEqual(floeBrowserComplete(12345, 2, nil, 0), -105) // bad status
        XCTAssertEqual(floeBrowserComplete(12345, 0, nil, 0), -101)
        XCTAssertEqual(floeBrowserDescribe(12345, nil, 0), -101)
        XCTAssertEqual(floeBrowserIsLive(12345), 0)
        XCTAssertEqual(floeBrowserShouldStop(12345), 1)
        XCTAssertEqual(floeBrowserPayloadLength(12345), -101)

        let badJSON = floeBrowserIngestEvent(nil)
        XCTAssertEqual(badJSON, -601) // no services at all
        XCTAssertEqual(withCString(#"{"loadCommitted":{"tabID":"bad-uuid"}}"#) {
            floeBrowserIngestEvent($0)
        }, -601)
        // policyAllows answers 0 (deny) for everything while unbound —
        // including public URLs — because the generation is not there to
        // own the grant tables.
        XCTAssertEqual(withCString(#"{"url":"https://example.com"}"#) {
            floeBrowserPolicyAllows($0)
        }, 0)
        XCTAssertEqual(withCString(#"{"url":"javascript:alert(1)"}"#) {
            floeBrowserPolicyAllows($0)
        }, 0)
        XCTAssertEqual(floeBrowserUIQuery(nil, nil, 4096, 1000), -105)
        XCTAssertEqual(floeBrowserUICall(nil), -601)
        XCTAssertEqual(floeBrowserPopupQuery(nil), -601)
        XCTAssertEqual(floeBrowserDownloadRequest(nil), -601)
        XCTAssertEqual(floeBrowserRecoverHandoff(nil, nil, 5), -603)
    }

    // MARK: - Bound epoch + stats readbacks

    func testBoundEpochAndStatsAlwaysRender() {
        var buffer = [CChar](repeating: 0, count: 32)
        let written = floeBrowserBoundEpoch(&buffer, Int32(buffer.count))
        XCTAssertGreaterThan(written, 0)
        let text = String(cString: buffer)
        XCTAssertNotNil(UInt64(text))
        // Too-small capacity is a typed refusal, never a truncation.
        var tiny = [CChar](repeating: 0, count: 1)
        XCTAssertEqual(floeBrowserBoundEpoch(&tiny, 1), -106)
        // Stats renders the full closed counter vocabulary.
        var stats = [CChar](repeating: 0, count: 4096)
        let statsLength = floeBrowserStats(&stats, Int32(stats.count))
        XCTAssertGreaterThan(statsLength, 0)
        let statsText = String(cString: stats)
        for key in ["lateSettle", "fenced", "saturated", "unbound", "expired",
                    "bindRejections", "coalesced", "eventDropped"] {
            XCTAssertTrue(statsText.contains(key), "stats must expose \(key)")
        }
    }

    // MARK: - Preview adjudication honesty (no services)

    func testPreviewAdjudicateWritesHonestUnavailableVerdict() {
        let server = UUID()
        let request = UUID()
        var out = [CChar](repeating: 0, count: 8192)
        let written = server.uuidString.withCString { serverPtr in
            request.uuidString.withCString { requestPtr in
                floeBrowserPreviewAdjudicate(serverPtr, requestPtr, nil, 0,
                                             &out, Int32(out.count))
            }
        }
        XCTAssertGreaterThan(written, 0)
        let verdictText = String(cString: out)
        XCTAssertTrue(verdictText.contains("503 Service Unavailable"))
        XCTAssertTrue(verdictText.contains("Connection"))
        // The chunk field must decode as empty base64 and bodyLength 0:
        // a transport must never read a phantom body.
        struct Wire: Decodable {
            let statusLine: String
            let headers: [BrowserPreviewHeader]
            let bodyLength: Int
            let chunk: String
        }
        guard let data = verdictText.data(using: .utf8),
              let verdict = try? JSONDecoder().decode(Wire.self, from: data) else {
            return XCTFail("adjudicate answer must decode: \(verdictText)")
        }
        XCTAssertEqual(verdict.statusLine, "503 Service Unavailable")
        XCTAssertEqual(verdict.bodyLength, 0)
        XCTAssertTrue(verdict.chunk.isEmpty)
        // readChunk without services is typed, never zero-means-complete.
        var chunkBuffer = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(server.uuidString.withCString { s in
            request.uuidString.withCString { r in
                floeBrowserPreviewReadChunk(s, r, 0, &chunkBuffer, 64)
            }
        }, -601)
    }

    // MARK: - Owner authority + ladder fail-closed

    func testOwnerAuthorityAndLadderRefuseWithoutComposition() async {
        let owner = BrowserOwnerID(taskID: UUID(), workspaceID: UUID(), rootEpoch: 42)
        let admitted = await G04BrowserOwnerAuthority.revalidate(owner: owner)
        XCTAssertFalse(admitted)
    }

    // MARK: - Handoff bridge epoch exactness

    func testHandoffRecoverRequiresExactLiveEpoch() {
        let bridge = G04BrowserHandoffBridge.shared
        // Nothing registered in this process: recover is a typed false, and
        // recording a run without a center never crashes the mirror.
        XCTAssertFalse(bridge.recover(conversationID: UUID(), runID: UUID(),
                                      expectedEpoch: 123))
        bridge.recordOwnerRun(conversationID: UUID(), runID: UUID())
        XCTAssertNotNil(bridge.recordedRun(for: { () -> UUID in
            let id = UUID()
            bridge.recordOwnerRun(conversationID: id, runID: UUID())
            return id
        }()))
        bridge.unregister(epoch: 123) // stale epoch unregister is a no-op
    }

    // MARK: - Mailbox-backed event routing

    func testEventDeliveryWithoutPumpIsCountedNotCrashed() throws {
        let mailbox = G04BrowserMailbox.shared
        // Closed mailbox (default at process start or after the last close):
        // events are counted unbound and never delivered to a dead table.
        if mailbox.isBound { mailbox.close(epoch: mailbox.boundEpoch) }
        func unboundCount() -> Int {
            guard let data = mailbox.statsJSON().data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let counters = object["counters"] as? [String: Any],
                  let value = counters["unbound"] as? Int else { return -1 }
            return value
        }
        let before = unboundCount()
        mailbox.submitEvent(.uiProjection, expectedEpoch: mailbox.boundEpoch, conversation: UUID(),
                            payload: Data("{}".utf8), coalesceKey: "x")
        XCTAssertEqual(unboundCount(), before + 1)
    }

    // MARK: - Codec <-> frozen surface vocabulary

    func testFrozenNamesMatchTheModuleSurface() {
        XCTAssertEqual(G04BrowserToolNames.all, BrowserToolSurface.frozenToolNames)
    }
}
