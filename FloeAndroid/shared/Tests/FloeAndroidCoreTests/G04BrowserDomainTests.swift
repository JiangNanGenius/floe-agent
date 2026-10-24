// SPDX-License-Identifier: MPL-2.0
//
// G04BrowserDomainTests — deterministic host-side behavior for the browser
// composition mailbox: strict epoch binding, exactly-once claim settlement,
// cancellation-as-request with honest late-settle classification, bounded
// saturation, projection coalescing, and the renderer/transport proxy
// mappings onto the module's typed errors. The "host pump" here is the test
// itself driving `nextClaim/complete` — the same contract Main's Kotlin
// engine thread implements, so these are REAL flow tests, not mocks of a
// mock. No device, no WebView, no network.
import XCTest
import FloeCore
import FloeTools
import FloeBrowser
@testable import FloeAndroidCore

/// Monotonic per-test epochs for the process-singleton mailbox. `bind` only
/// accepts strictly newer values, so each test derives its epoch from the
/// CURRENT bound epoch and class order can never starve a bind.
private func bindFreshEpoch(_ mailbox: G04BrowserMailbox, file: StaticString = #filePath,
                            line: UInt = #line) -> UInt64 {
    let epoch = mailbox.boundEpoch == 0 ? 1 : mailbox.boundEpoch + 1_000
    XCTAssertTrue(mailbox.bind(epoch: epoch), file: file, line: line)
    return epoch
}

final class G04BrowserDomainTests: XCTestCase {

    // MARK: - Epoch binding

    func testBindRejectsZeroEqualAndOlderEpochs() {
        let mailbox = G04BrowserMailbox.shared
        XCTAssertFalse(mailbox.bind(epoch: 0))          // zero is refused
        if mailbox.boundEpoch > 0 {
            XCTAssertFalse(mailbox.bind(epoch: mailbox.boundEpoch)) // equal refused
            XCTAssertFalse(mailbox.bind(epoch: mailbox.boundEpoch - 1)) // older refused
        }
        let epoch = bindFreshEpoch(mailbox)
        XCTAssertEqual(mailbox.boundEpoch, epoch)
        XCTAssertTrue(mailbox.isBound)
        mailbox.close(epoch: epoch)
        XCTAssertFalse(mailbox.isBound)
        // A closed mailbox rejects submits typed and never blocks.
        let expectation = expectation(description: "unbound")
        Task {
            do {
                _ = try await mailbox.submit(.rendererReload, expectedEpoch: mailbox.boundEpoch, conversation: UUID(),
                                             descriptor: ["tabID": UUID().uuidString],
                                             staged: Data(), budgetMillis: 1_000,
                                             cancellation: nil)
                XCTFail("unbound submit must refuse")
            } catch {
                XCTAssertEqual(error as? G04BrowserMailboxError, .hostUnbound)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    func testOldEpochCannotEnqueueEventsOrRendererWorkIntoNewRoot() async {
        let mailbox = G04BrowserMailbox.shared
        let old = bindFreshEpoch(mailbox)
        mailbox.close(epoch: old)
        let current = bindFreshEpoch(mailbox)
        defer { mailbox.close(epoch: current) }
        let task = UUID()
        mailbox.submitEvent(.uiProjection, expectedEpoch: old, conversation: task,
                            payload: Data("old".utf8), coalesceKey: task.uuidString)
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 20), 0)
        do {
            _ = try await mailbox.submit(.rendererReload, expectedEpoch: old, conversation: task,
                                         descriptor: [:], staged: Data(), budgetMillis: 500, cancellation: nil)
            XCTFail("late old-root work must refuse before dispatch")
        } catch { XCTAssertEqual(error as? G04BrowserMailboxError, .hostFenced) }
        mailbox.submitEvent(.uiProjection, expectedEpoch: current, conversation: task,
                            payload: Data("current".utf8), coalesceKey: task.uuidString)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data()), 0)
    }

    // MARK: - Claim lifecycle

    func testAwaitableTicketSettlesExactlyOnce() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        defer { G04BrowserMailbox.shared.close(epoch: epoch) }
        let mailbox = G04BrowserMailbox.shared
        let conversation = UUID()
        let tab = UUID()

        async let answer = mailbox.submit(.rendererState, expectedEpoch: mailbox.boundEpoch, conversation: conversation,
                                          descriptor: ["tabID": tab.uuidString],
                                          staged: Data(), budgetMillis: 5_000,
                                          cancellation: nil)
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)

        var buffer = [CChar](repeating: 0, count: 4096)
        let written = mailbox.describe(claim: claim, buffer: &buffer,
                                       capacity: Int32(buffer.count))
        XCTAssertGreaterThan(written, 0)
        let described = String(cString: buffer)
        XCTAssertTrue(described.contains("\"operation\":\"renderer.state\""))
        XCTAssertTrue(described.contains(tab.uuidString))
        XCTAssertTrue(described.contains("\"epoch\":\"\(epoch)\""))

        // Not yet settled: still live.
        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        let body = Data(#"{"url":null,"title":null,"isLoading":false,"viewportWidth":1024,"viewportHeight":768,"scrollX":0,"scrollY":0}"#.utf8)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: body), 0)
        // A second settle of the same claim is refused (exactly-once): the settled
        // claim is already retired, so complete() classifies it as a typed late
        // settle (-101) and counts it, never re-delivering the continuation.
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data()), -101)

        let value = try await answer
        let state = try JSONDecoder().decode(BrowserRendererTabState.self, from: value)
        XCTAssertEqual(state.viewportWidth, 1024)
    }

    func testCancellationIsARequestNotADetach() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        defer { G04BrowserMailbox.shared.close(epoch: epoch) }
        let mailbox = G04BrowserMailbox.shared
        let token = CancellationToken()
        let conversation = UUID()

        async let answer = mailbox.submit(.rendererNavigate, expectedEpoch: mailbox.boundEpoch, conversation: conversation,
                                          descriptor: ["tabID": UUID().uuidString,
                                                       "url": "https://example.com"],
                                          staged: Data(), budgetMillis: 10_000,
                                          cancellation: token)
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.shouldStopClaim(claim: claim), 0)
        token.cancel()
        // Cancellation does NOT detach: the ticket remains live and the host
        // must still settle exactly once.
        XCTAssertEqual(mailbox.shouldStopClaim(claim: claim), 1)
        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1,
                                       value: Data(#"{"code":"cancelled"}"#.utf8)), 0)
        do {
            _ = try await answer
            XCTFail("cancelled attempt must surface the typed refusal")
        } catch let error as G04BrowserMailboxError {
            XCTAssertEqual(error, .remoteFailed(code: "cancelled"))
        }
    }

    func testStaleGenerationClaimCannotResurrectTheNewTable() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        let mailbox = G04BrowserMailbox.shared
        let conversation = UUID()

        async let answer = mailbox.submit(.rendererReload, expectedEpoch: mailbox.boundEpoch, conversation: conversation,
                                          descriptor: ["tabID": UUID().uuidString],
                                          staged: Data(), budgetMillis: 30_000,
                                          cancellation: nil)
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        // A newer generation rebinds: old waiters settle fenced, the old
        // claim is retired for honest late-settle classification only.
        let newer = mailbox.boundEpoch + 1
        XCTAssertTrue(mailbox.bind(epoch: newer))
        defer { mailbox.close(epoch: newer) }
        do {
            _ = try await answer
            XCTFail("rebind must fence the awaiting generation")
        } catch let error as G04BrowserMailboxError {
            XCTAssertEqual(error, .hostFenced)
        }
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data()), -101)
        XCTAssertTrue(mailbox.statsJSON().contains("lateSettle"))
    }

    func testUnclaimedTicketExpiresTyped() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        defer { G04BrowserMailbox.shared.close(epoch: epoch) }
        let mailbox = G04BrowserMailbox.shared
        async let answer = mailbox.submit(.rendererGoBack, expectedEpoch: mailbox.boundEpoch, conversation: UUID(),
                                          descriptor: ["tabID": UUID().uuidString],
                                          staged: Data(), budgetMillis: 250,
                                          cancellation: nil)
        // Expiry is driven by the pump: a claim attempt AFTER the budget
        // classifies the stale queued ticket and settles its waiter typed.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0)
        do {
            _ = try await answer
            XCTFail("unclaimed ticket must expire")
        } catch let error as G04BrowserMailboxError {
            XCTAssertEqual(error, .remoteFailed(code: "hostBudget"))
        }
        XCTAssertTrue(mailbox.statsJSON().contains("\"expired\":1"))
    }

    func testPerConversationSaturationRefusesTyped() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        defer { G04BrowserMailbox.shared.close(epoch: epoch) }
        let mailbox = G04BrowserMailbox.shared
        let conversation = UUID()

        // 1) Queue the per-owner bound WITHOUT claiming; each detached
        //    submit settles exactly once (claim completed below).
        let filled = G04BrowserMailboxLimits.maximumLivePerConversation
        let done = DispatchSemaphore(value: 0)
        for _ in 0..<filled {
            Task.detached {
                _ = try? await mailbox.submit(.rendererStopLoading, expectedEpoch: mailbox.boundEpoch,
                                              conversation: conversation,
                                              descriptor: ["tabID": UUID().uuidString],
                                              staged: Data(),
                                              budgetMillis: 60_000,
                                              cancellation: nil)
                done.signal()
            }
        }
        // 2) The pump claims them one by one and NEVER settles: they stay
        //    live against the per-owner bound.
        var claims: [Int64] = []
        var guardCount = 0
        while claims.count < filled, guardCount < 200 {
            guardCount += 1
            let claim = mailbox.nextClaim(timeoutMillis: 1_000)
            if claim > 0 { claims.append(claim) }
        }
        XCTAssertEqual(claims.count, filled)

        // 3) One more for the SAME conversation is refused typed.
        let saturated = expectation(description: "saturated")
        Task.detached {
            do {
                _ = try await mailbox.submit(.rendererStopLoading, expectedEpoch: mailbox.boundEpoch,
                                             conversation: conversation,
                                             descriptor: ["tabID": UUID().uuidString],
                                             staged: Data(),
                                             budgetMillis: 60_000,
                                             cancellation: nil)
                XCTFail("bound must refuse the next ticket")
            } catch G04BrowserMailboxError.saturated {
                saturated.fulfill()
            } catch {
                XCTFail("expected saturated, got \(error)")
            }
        }
        await fulfillment(of: [saturated], timeout: 5)

        // A DIFFERENT conversation is unaffected by this owner's bound.
        let other = expectation(description: "other accepted")
        Task.detached {
            do {
                _ = try await mailbox.submit(.rendererStopLoading, expectedEpoch: mailbox.boundEpoch,
                                             conversation: UUID(),
                                             descriptor: ["tabID": UUID().uuidString],
                                             staged: Data(),
                                             budgetMillis: 60_000,
                                             cancellation: nil)
                other.fulfill()
            } catch {
                XCTFail("other conversation must be accepted: \(error)")
            }
        }
        // 4) Settle everything so the `other` waiter answers too.
        for claim in claims {
            XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data()), 0)
        }
        let otherClaim = mailbox.nextClaim(timeoutMillis: 2_000)
        if otherClaim > 0 {
            mailbox.complete(claim: otherClaim, status: 0, value: Data())
        }
        await fulfillment(of: [other], timeout: 5)
        for _ in 0..<filled {
            XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        }
    }

    // MARK: - Renderer / transport proxy mappings

    func testRendererProxyMapsTypedRefusalsAndStagesFullPayloads() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        defer { G04BrowserMailbox.shared.close(epoch: epoch) }
        let mailbox = G04BrowserMailbox.shared
        let owner = BrowserOwnerID(taskID: UUID(), workspaceID: UUID(), rootEpoch: epoch)
        let proxy = G04BrowserRendererProxy(owner: owner)

        // Typed host failure -> renderer .failed; never a placeholder image.
        async let shot = proxy.captureScreenshot(tabID: owner.taskID)
        var claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1,
                                       value: Data(#"{"code":"surfaceUnavailable"}"#.utf8)), 0)
        do {
            _ = try await shot
            XCTFail("typed refusal must propagate")
        } catch let error as BrowserRendererError {
            XCTAssertEqual(error, .failed("surfaceUnavailable"))
        }

        // createTab stages the probe source VERBATIM (no truncate-then-ok).
        let probe = String(repeating: "__floe", count: 1_000) // 6_000 bytes
        async let created = proxy.createTab(tabID: owner.taskID, probeSource: probe)
        claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        let length = mailbox.payloadLength(claim: claim)
        XCTAssertEqual(Int(length), probe.utf8.count)
        var buffer = [UInt8](repeating: 0, count: Int(length))
        XCTAssertEqual(mailbox.takePayload(claim: claim, buffer: &buffer,
                                           capacity: Int32(length)), Int32(length))
        XCTAssertEqual(String(bytes: buffer, encoding: .utf8), probe)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data()), 0)
        try await created

        // transport.start: OS port answer decodes; permission denial fails
        // the start typed (never a bound socket presented anyway).
        let transport = G04BrowserPreviewTransportProxy(epoch: epoch)
        async let started = transport.start(lease: BrowserPreviewLeaseRequest(
            leaseID: UUID(), token: String(repeating: "a", count: 32)))
        claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0,
                                        value: Data(#"{"port":53124}"#.utf8)), 0)
        let endpoint = try await started
        XCTAssertEqual(endpoint.port, 53124)

        async let denied = transport.start(lease: BrowserPreviewLeaseRequest(
            leaseID: UUID(), token: String(repeating: "b", count: 32)))
        claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1,
                                       value: Data(#"{"code":"localNetworkPermissionDenied"}"#.utf8)), 0)
        do {
            _ = try await denied
            XCTFail("permission denial must fail the start typed")
        } catch let error as BrowserPreviewTransportError {
            if case .startFailed(let reason) = error {
                XCTAssertTrue(reason.contains("local network permission"), reason)
            } else {
                XCTFail("expected startFailed")
            }
        }
    }

    func testGenerationCloseFencesProxiesAsReleased() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        let mailbox = G04BrowserMailbox.shared
        let owner = BrowserOwnerID(taskID: UUID(), workspaceID: UUID(), rootEpoch: epoch)
        let proxy = G04BrowserRendererProxy(owner: owner)
        async let state = proxy.state(tabID: owner.taskID)
        XCTAssertGreaterThan(mailbox.nextClaim(timeoutMillis: 2_000), 0)
        // Root stop with a claim still outstanding: the waiter settles
        // typed-released; the claim itself is retired for late classification.
        mailbox.close(epoch: epoch)
        do {
            _ = try await state
            XCTFail("closed generation must refuse")
        } catch let error as BrowserRendererError {
            XCTAssertEqual(error, .released)
        }
    }

    // MARK: - Projection coalescing

    func testProjectionCoalescingKeepsNewestPerConversation() async throws {
        let epoch = bindFreshEpoch(G04BrowserMailbox.shared)
        defer { G04BrowserMailbox.shared.close(epoch: epoch) }
        let mailbox = G04BrowserMailbox.shared
        let task = UUID()
        var first = BrowserProjection()
        first.visibleTaskID = task
        first.addressText = "first"
        var second = first
        second.addressText = "second"
        mailbox.submitEvent(.uiProjection, expectedEpoch: mailbox.boundEpoch, conversation: task,
                            payload: try JSONEncoder().encode(first),
                            coalesceKey: task.uuidString)
        mailbox.submitEvent(.uiProjection, expectedEpoch: mailbox.boundEpoch, conversation: task,
                            payload: try JSONEncoder().encode(second),
                            coalesceKey: task.uuidString)
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        let length = mailbox.payloadLength(claim: claim)
        var buffer = [UInt8](repeating: 0, count: Int(length))
        XCTAssertEqual(mailbox.takePayload(claim: claim, buffer: &buffer,
                                           capacity: Int32(length)), Int32(length))
        let delivered = try JSONDecoder().decode(BrowserProjection.self,
                                                 from: Data(buffer))
        XCTAssertEqual(delivered.addressText, "second")
        // Settlement of an event merely frees the claim.
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data()), 0)
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 100), 0)
    }

    // MARK: - Argument codec (closed per-name grammar)

    func testCodecAcceptsOriginalModelShapes() throws {
        let panel = try G04BrowserToolArgumentsCodec.decode(
            name: "browser.panel",
            json: #"{"action":"requestUser","reason":"log in","tabID":"\#(UUID().uuidString)"}"#)
        if case .panel(let action, let reason, _) = panel {
            XCTAssertEqual(action, "requestUser")
            XCTAssertEqual(reason, "log in")
        } else { XCTFail("panel shape") }

        let point = try G04BrowserToolArgumentsCodec.decode(
            name: "browser.clickPoint",
            json: #"{"documentID":"doc-1","x":12,"y":800,"screenshotSHA256":"\#(String(repeating: "a", count: 64))","fallbackReason":"noStructuredTarget"}"#)
        if case .clickPoint(_, let documentID, let x, let y, _, let fallback) = point {
            XCTAssertEqual(documentID, "doc-1")
            XCTAssertEqual(x, 12)
            XCTAssertEqual(y, 800)
            XCTAssertEqual(fallback, "noStructuredTarget")
        } else { XCTFail("clickPoint shape") }

        if case .previewStart(let root, let entry) = try G04BrowserToolArgumentsCodec.decode(
            name: "preview.start", json: #"{"root":"site"}"#) {
            XCTAssertEqual(root, "site")
            XCTAssertNil(entry)
        } else { XCTFail("previewStart shape") }

        _ = try G04BrowserToolArgumentsCodec.decode(name: "browser.tabs", json: "{}")
        _ = try G04BrowserToolArgumentsCodec.decode(name: "preview.reload", json: "{}")
    }

    func testCodecRefusesMissingAndWronglyTypedFields() {
        // Missing required arguments.
        XCTAssertThrowsError(try G04BrowserToolArgumentsCodec.decode(
            name: "browser.tab", json: "{}"))
        XCTAssertThrowsError(try G04BrowserToolArgumentsCodec.decode(
            name: "browser.navigate", json: #"{"tabID":"x"}"#))
        // Wrong JSON types.
        XCTAssertThrowsError(try G04BrowserToolArgumentsCodec.decode(
            name: "browser.navigate", json: #"{"url":123}"#))
        // Not a browser/preview tool.
        XCTAssertThrowsError(try G04BrowserToolArgumentsCodec.decode(
            name: "exec.shell", json: "{}"))
    }

    // MARK: - Handoff message (original text, field-for-field)

    func testHandoffMessageKeepsOriginalContract() {
        let session = UUID()
        let tab = UUID()
        let event = BrowserHandoff(id: UUID(), conversationID: UUID(), runID: UUID(),
                                   sessionID: session, tabID: tab, returning: true,
                                   pageAddress: "https://example.com/page")
        let text = G04BrowserHandoffMessage.text(event)
        XCTAssertTrue(text.hasPrefix("Browser control was returned by the user."))
        XCTAssertTrue(text.contains("Session: \(session)"))
        XCTAssertTrue(text.contains("Tab: \(tab)"))
        XCTAssertTrue(text.contains("Page (without query or credentials): https://example.com/page"))
        XCTAssertTrue(text.contains("This notification conveys no new permissions."))
    }

    func testHandoffDeliveryFailsClosedWithoutALiveComposition() async {
        // No installed composition in a unit-test process: the deliverer
        // must throw the original typed configuration refusal, never
        // fabricate a run or return `true` from a placeholder.
        let event = BrowserHandoff(id: UUID(), conversationID: UUID(), runID: nil,
                                   sessionID: UUID())
        do {
            _ = try await G04BrowserHandoffDeliverer.deliver(event, shouldContinue: true)
            XCTFail("unbound delivery must refuse")
        } catch {
            XCTAssertTrue(String(describing: error).contains("invalidConfiguration")
                          || error is FloeError)
        }
    }
}
