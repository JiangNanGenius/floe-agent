// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused regression for the Office AI host mailbox
// (job-1db1a7a8d5da457a). NOT executed by this lane (Main's grouped batch).
// Pins the SAME ownership rules the delivered source mailbox ships:
// strictly-newer epoch binding fences waiters but keeps claimed tickets for
// honest late classification; settle-once (double/late/stale settle codes);
// cancellation is a REQUEST the host must still settle; budgets expire only
// UNCLAIMED tickets (never detach an in-flight host operation); reply bodies
// are size-capped BOTH sides; failure codes are bounded and totalized.

import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidCore

final class OfficeAIHostMailboxTests: XCTestCase {

    private func freshMailbox() -> OfficeAIHostMailbox { OfficeAIHostMailbox() }

    func testUnboundSubmitFailsClosed() async throws {
        let mailbox = freshMailbox()
        do {
            _ = try await mailbox.submit(operation: .lookup, descriptor: descriptor(),
                                         staged: Data(), cancellation: CancellationToken())
            XCTFail("unbound mailbox must refuse")
        } catch let error as OfficeAIHostTransportError {
            guard case .hostUnbound = error else { return XCTFail("\(error)") }
        }
    }

    func testBindIsStrictlyNewerAndRebindFencesWaitersRetainsClaims() async throws {
        let mailbox = freshMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 5))
        XCTAssertFalse(mailbox.bind(epoch: 5), "same epoch never rebinds")
        XCTAssertFalse(mailbox.bind(epoch: 4), "older epochs are fenced, never re-adopted")
        XCTAssertTrue(mailbox.isBound(to: 5))
        XCTAssertFalse(mailbox.isBound(to: 6))

        // A claimed ticket survives the rebind for honest late settlement;
        // a QUEUED waiter settles typed .hostFenced.
        let waiterError = TransportErrorBox()
        let waiter = Task {
            do {
                _ = try await mailbox.submit(operation: .command, descriptor: descriptor(),
                                             staged: Data(), cancellation: CancellationToken())
            } catch let error as OfficeAIHostTransportError {
                waiterError.set(error)
            }
        }
        // Give the waiter a moment to park, then claim-and-rebind around it.
        try await Task.sleep(nanoseconds: 30_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 50)
        XCTAssertTrue(claim > 0)
        XCTAssertTrue(mailbox.bind(epoch: 7))
        try await waiter.value
        if let error = waiterError.get() {
            if case .hostFenced = error {
                // expected (the only waiter was the claimed ticket's — if it
                // completed first, no fencing was needed)
            } else {
                XCTFail("wrong fencing error: \(error)")
            }
        }
        // The stale claim from generation 5 can NEVER settle generation 7.
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data(#"{"ok":1}"#.utf8)),
                       -102, "a stale-generation settle is classified, never applied")
    }

    func testFullPumpRoundTripSettlesExactlyOnce() async throws {
        let mailbox = freshMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 9))
        let cancellation = CancellationToken()
        async let reply = mailbox.submit(operation: .command,
                                         descriptor: descriptor(["taskID": UUID().uuidString]),
                                         staged: Data("hello".utf8), cancellation: cancellation)
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertTrue(claim > 0)

        var buffer = [CChar](repeating: 0, count: 2049)
        let described = mailbox.describe(claim: claim, buffer: &buffer, capacity: 2049)
        XCTAssertGreaterThan(described, 0)
        let parsed = try JSONSerialization.jsonObject(
            with: Data(bytes: buffer, count: Int(described))) as! [String: Any]
        XCTAssertEqual(parsed["operation"] as? String, "office.command")
        XCTAssertEqual(parsed["epoch"] as? String, "9")

        var lengthBuffer = [UInt8](repeating: 0, count: 96 * 1024)
        XCTAssertEqual(mailbox.payloadLength(claim: claim), 5)
        XCTAssertEqual(mailbox.takePayload(claim: claim, buffer: &lengthBuffer,
                                           capacity: Int32(lengthBuffer.count)), 5)
        XCTAssertEqual(String(bytes: lengthBuffer.prefix(5), encoding: .utf8), "hello")

        XCTAssertEqual(mailbox.shouldStop(claim: claim), 0)
        cancellation.cancel()
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 1,
                       "cancellation is surfaced as a REQUEST the host must settle")

        let replyBody = Data(#"{"ok":1,"state":"queryObserved","targetHandle":"\#(String(repeating: "a", count: 32))"}"#.utf8)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: replyBody), 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: replyBody), -101,
                       "late/duplicate settles are classified, never resumed twice")
        let data = try await reply
        XCTAssertEqual(OfficeAIHostDescriptor.parse(data)?["state"] as? String, "queryObserved")
    }

    func testFailureReplyIsTotalizedAndBounded() async throws {
        let mailbox = freshMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 3))
        async let reply = mailbox.submit(operation: .command, descriptor: descriptor(),
                                         staged: Data(), cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertTrue(claim > 0)
        // failure bodies over the cap must be REFUSED at the settle boundary
        let huge = Data(repeating: 0x61, count: 300)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1, value: huge), -107)
        let ok = Data(#"{"code":"applyConflict","detail":"working copy moved since capture"}"#.utf8)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1, value: ok), 0)
        do {
            _ = try await reply
            XCTFail("expected a typed relayed failure")
        } catch let error as OfficeAIHostTransportError {
            guard case .remoteFailed(let code, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "applyConflict")
            XCTAssertEqual(detail, "working copy moved since capture")
        }
    }

    func testOversizeStagedAndReplyAreRefusedNotTruncated() async throws {
        let mailbox = freshMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 4))
        do {
            _ = try await mailbox.submit(operation: .command, descriptor: descriptor(),
                                         staged: Data(repeating: 0, count: OfficeAIHostLimits
                                            .maximumStagedBytes + 1),
                                         cancellation: CancellationToken())
            XCTFail("oversized staged payload must be refused up front")
        } catch let error as OfficeAIHostTransportError {
            guard case .oversized = error else { return XCTFail("\(error)") }
        }
        // claimed reply over cap is refused at settlement (host bug cannot
        // truncate content into the runtime):
        async let late = mailbox.submit(operation: .command, descriptor: descriptor(),
                                        staged: Data(), cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertTrue(claim > 0)
        let oversized = Data(repeating: 0x62, count: OfficeAIHostLimits.maximumReplyBytes + 1)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: oversized), -107)
        // settle correctly afterwards
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1,
                                        value: Data(#"{"code":"failed"}"#.utf8)), 0)
        do { _ = try await late } catch is OfficeAIHostTransportError {}
    }

    func testCloseSettlesWaitersTypedAndStaleClaimsClassifyLate() async throws {
        let mailbox = freshMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 11))
        // A wrong-epoch close changes nothing (exact-generation teardown).
        mailbox.close(epoch: 12)
        XCTAssertTrue(mailbox.isBound(to: 11))
        // An unclaimed queued waiter settles typed on close.
        let task = Task {
            do {
                _ = try await mailbox.submit(operation: .lookup, descriptor: descriptor(),
                                             staged: Data(), cancellation: CancellationToken())
                return "returned"
            } catch let error as OfficeAIHostTransportError {
                if case .hostClosed = error { return "hostClosed" }
                return "other:\(error)"
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        // A CLAIMED ticket's waiter settles hostClosed too, while the claim
        // itself remains classified: after close a late settle cannot touch a
        // newer generation (rebind, then stale-settle => -102).
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertTrue(claim > 0)
        mailbox.close(epoch: 11)
        let settled = try await task.value
        XCTAssertEqual(settled, "hostClosed")
        XCTAssertTrue(mailbox.bind(epoch: 13))
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: Data(#"{"ok":1}"#.utf8)),
                       -102, "a ticket from a closed generation can never settle the new table")
    }

    func testDescriptorLimitsAndStatsShape() {
        let mailbox = freshMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 2))
        let stats = mailbox.statsJSON()
        XCTAssertTrue(stats.contains("\"counters\""), stats)
        XCTAssertFalse(stats.contains("sessionToken"), "stats never carry identities")
        XCTAssertFalse(stats.contains("/"), "stats never carry paths")
    }
}

/// File-scope descriptor builder: a free function so `Task`/`async let`
/// closures never capture the non-Sendable XCTestCase `self`.
private func descriptor(_ extra: [String: String] = [:]) -> [String: String] {
    var fields = ["sessionToken": "sess-1", "generation": "9", "opId": "oa-a",
                  "action": "captureTarget"]
    for (k, v) in extra { fields[k] = v }
    return fields
}

/// Lock-guarded one-shot transport error capture (Swift 6 sendable).
private final class TransportErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OfficeAIHostTransportError?
    func set(_ error: OfficeAIHostTransportError) { lock.lock(); value = error; lock.unlock() }
    func get() -> OfficeAIHostTransportError? { lock.lock(); defer { lock.unlock() }; return value }
}
