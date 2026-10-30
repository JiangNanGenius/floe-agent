// SPDX-License-Identifier: MPL-2.0
//
// Authored-only regressions for the G07.1 network diagnostics lane.
// NOT executed by this lane (Main runs the combined batch). The mailbox and
// executor run against synthetic observation JSON; no sockets, no Android
// runtime, no device, no real network target and no credentials.
import XCTest
import Foundation
import FloeCore
import FloeTools
import FloeAndroidNetwork
@testable import FloeAndroidCore

final class G07NetworkDiagnosticsTests: XCTestCase {

    private let operationID = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
    private let taskID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let runID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!

    // MARK: - Mailbox ownership

    func testUnboundMailboxRefusesSubmission() async {
        let mailbox = G07NetworkHostMailbox()
        do {
            _ = try await mailbox.submit(
                request: try NetworkToolRequest.status(operationID: operationID),
                owner: G07NetworkOwner(taskID: taskID, runID: runID, epoch: 1),
                cancellation: CancellationToken())
            XCTFail("unbound mailbox must refuse")
        } catch let error as G07NetworkHostTransportError {
            XCTAssertEqual(error, .hostUnbound)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testBindIsStrictlyNewerAndNeverReusesEpoch() {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 5))
        XCTAssertTrue(mailbox.isBound(to: 5))
        XCTAssertFalse(mailbox.isBound(to: 6))
        XCTAssertFalse(mailbox.bind(epoch: 5))
        XCTAssertFalse(mailbox.bind(epoch: 4))
        XCTAssertTrue(mailbox.bind(epoch: 6))
        XCTAssertEqual(mailbox.boundEpoch, 6)
    }

    func testFullClaimRoundTripSettlesExactlyOnce() async throws {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 9))
        let cancellation = CancellationToken()
        let request = try NetworkToolRequest.ping(
            host: "example.com", count: 4, timeoutMs: 1_000, operationID: operationID)
        let owner = G07NetworkOwner(taskID: taskID, runID: runID, epoch: 9)
        async let reply = mailbox.submit(
            request: request, owner: owner, cancellation: cancellation)
        try await Task.sleep(nanoseconds: 20_000_000)

        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)

        var descriptorBuffer = [CChar](repeating: 0, count: 2_049)
        let descriptorLength = mailbox.describe(
            claim: claim, buffer: &descriptorBuffer, capacity: 2_048)
        XCTAssertGreaterThan(descriptorLength, 0)
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(bytes: descriptorBuffer, count: Int(descriptorLength)))
            as? [String: Any])
        XCTAssertEqual(descriptor["operation"] as? String, "network.execute")
        XCTAssertEqual(descriptor["epoch"] as? String, "9")
        XCTAssertEqual(descriptor["method"] as? String, "network.ping")
        XCTAssertEqual(descriptor["operationID"] as? String, operationID.uuidString)
        XCTAssertEqual(descriptor["taskID"] as? String, taskID.uuidString)
        XCTAssertEqual(descriptor["runID"] as? String, runID.uuidString)
        XCTAssertEqual(descriptor["payloadBytes"] as? Int, request.requestJSON.count)

        XCTAssertEqual(mailbox.payloadLength(claim: claim), Int32(request.requestJSON.count))
        var payload = [UInt8](repeating: 0, count: request.requestJSON.count)
        let copied = mailbox.takePayload(
            claim: claim, buffer: &payload, capacity: Int32(payload.count))
        XCTAssertEqual(copied, Int32(request.requestJSON.count))
        XCTAssertEqual(Data(payload), request.requestJSON)

        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 0)
        cancellation.cancel()
        XCTAssertEqual(mailbox.shouldStop(claim: claim), 1)

        let observation = statusObservation(for: request)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: observation), 0)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: observation), -101,
                       "late/duplicate settles are classified, never resumed twice")
        let data = try await reply
        XCTAssertEqual(data, observation)
    }

    func testRebindFencesWaitersAndStaleClaimCannotSettle() async throws {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 11))
        let request = try NetworkToolRequest.status(operationID: operationID)
        let owner = G07NetworkOwner(taskID: taskID, runID: runID, epoch: 11)
        async let reply = mailbox.submit(
            request: request, owner: owner, cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertTrue(mailbox.bind(epoch: 12))
        do {
            _ = try await reply
            XCTFail("a rebound generation must fence the waiter")
        } catch let error as G07NetworkHostTransportError {
            XCTAssertEqual(error, .hostFenced)
        }
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 0, value: statusObservation(for: request)), -102)
    }

    func testFailureReplyIsDecodedAndBounded() async throws {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 13))
        let request = try NetworkToolRequest.tcpProbe(
            host: "example.com", port: 443, timeoutMs: 1_000, operationID: operationID)
        let owner = G07NetworkOwner(taskID: taskID, runID: runID, epoch: 13)
        async let reply = mailbox.submit(
            request: request, owner: owner,
            cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        let hugeFailure = Data(repeating: 0x61, count: 513)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1, value: hugeFailure), -107)
        let failure = Data(#"{"code":"timeout","detail":"bounded"}"#.utf8)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 1, value: failure), 0)
        do {
            _ = try await reply
            XCTFail("expected typed remote failure")
        } catch let error as G07NetworkHostTransportError {
            XCTAssertEqual(error, .remoteFailed(code: "timeout", detail: "bounded"))
        }
    }

    func testOversizedObservationIsRefusedNotTruncated() async throws {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 14))
        let request = try NetworkToolRequest.status(operationID: operationID)
        let owner = G07NetworkOwner(taskID: taskID, runID: runID, epoch: 14)
        async let reply = mailbox.submit(
            request: request, owner: owner,
            cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        let oversized = Data(repeating: 0x62,
                             count: G07NetworkHostLimits.maximumObservationBytes + 1)
        XCTAssertEqual(mailbox.complete(claim: claim, status: 0, value: oversized), -107)
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 1, value: Data(#"{"code":"internal"}"#.utf8)), 0)
        do { _ = try await reply } catch is G07NetworkHostTransportError {}
    }

    func testCloseSettlesWaitersTypedAndRejectsLateSettle() async throws {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 15))
        let request = try NetworkToolRequest.status(operationID: operationID)
        let owner = G07NetworkOwner(taskID: taskID, runID: runID, epoch: 15)
        async let reply = mailbox.submit(
            request: request, owner: owner,
            cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        mailbox.close(epoch: 15)
        do {
            _ = try await reply
            XCTFail("close must settle the waiter")
        } catch let error as G07NetworkHostTransportError {
            XCTAssertEqual(error, .hostClosed)
        }
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 0, value: statusObservation(for: request)), -102)
        XCTAssertTrue(mailbox.bind(epoch: 16))
    }

    func testCancelledBeforeSubmitIsTyped() async throws {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 17))
        let cancellation = CancellationToken()
        cancellation.cancel()
        do {
            _ = try await mailbox.submit(
                request: try NetworkToolRequest.status(operationID: operationID),
                owner: G07NetworkOwner(taskID: taskID, runID: runID, epoch: 17),
                cancellation: cancellation)
            XCTFail("cancelled submission must be refused")
        } catch let error as G07NetworkHostTransportError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testStatsNeverCarryTargetsOrIdentities() async throws {
        let mailbox = G07NetworkHostMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 18))
        let request = try NetworkToolRequest.dnsLookup(
            host: "very-secret-host.example", recordType: nil, timeoutMs: nil,
            operationID: operationID)
        let owner = G07NetworkOwner(taskID: taskID, runID: runID, epoch: 18)
        async let reply = mailbox.submit(
            request: request, owner: owner,
            cancellation: CancellationToken())
        try await Task.sleep(nanoseconds: 20_000_000)
        let claim = mailbox.nextClaim(timeoutMillis: 100)
        XCTAssertGreaterThan(claim, 0)
        let stats = mailbox.statsJSON()
        XCTAssertFalse(stats.contains("very-secret-host"), stats)
        XCTAssertFalse(stats.contains(taskID.uuidString), stats)
        XCTAssertFalse(stats.contains("/"), stats)
        XCTAssertEqual(mailbox.complete(
            claim: claim, status: 1, value: Data(#"{"code":"cancelled"}"#.utf8)), 0)
        do { _ = try await reply } catch is G07NetworkHostTransportError {}
    }

    // MARK: - Executor ownership / availability

    func testExecutorRefusesTemporaryChatBeforeAnySubmission() async throws {
        let host = FakeNetworkHost(epoch: 21, bound: true)
        let executor = G07NetworkToolExecutor(host: host, currentEpoch: { 21 })
        let request = try NetworkToolRequest.status(operationID: operationID)
        var context = ToolContext(runID: runID, cancellation: CancellationToken(),
                                  conversationID: taskID)
        context.temporaryReadOnly = true
        do {
            _ = try await executor.execute(request: request, context: context)
            XCTFail("temporary chat must be refused")
        } catch let error as FloeError {
            guard case .validationFailed(let detail) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertTrue(detail.contains("temporary"), detail)
        }
        XCTAssertTrue(host.recordedSubmissions().isEmpty)

        context.temporaryReadOnly = false
        context.publicWebOnly = true
        do {
            _ = try await executor.execute(request: request, context: context)
            XCTFail("public-web-only run must be refused")
        } catch let error as FloeError {
            guard case .validationFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(host.recordedSubmissions().isEmpty)
    }

    func testExecutorRequiresTaskOwnedRunAndLiveGeneration() async throws {
        let host = FakeNetworkHost(epoch: 22, bound: true)
        let executor = G07NetworkToolExecutor(host: host, currentEpoch: { 22 })
        let request = try NetworkToolRequest.status(operationID: operationID)

        let noTask = ToolContext(runID: runID, cancellation: CancellationToken())
        do {
            _ = try await executor.execute(request: request, context: noTask)
            XCTFail("missing conversation must be refused")
        } catch let error as FloeError {
            guard case .validationFailed = error else { return XCTFail("\(error)") }
        }

        let stale = G07NetworkToolExecutor(host: host, currentEpoch: { 23 })
        do {
            _ = try await stale.execute(
                request: request,
                context: ToolContext(runID: runID, cancellation: CancellationToken(),
                                     conversationID: taskID))
            XCTFail("stale generation must be refused")
        } catch let error as FloeError {
            guard case .invalidConfiguration = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(host.recordedSubmissions().isEmpty)
    }

    func testExecutorSubmitsTaskRunEpochAndReturnsHostBytes() async throws {
        let host = FakeNetworkHost(epoch: 24, bound: true)
        let executor = G07NetworkToolExecutor(host: host, currentEpoch: { 24 })
        let request = try NetworkToolRequest.status(operationID: operationID)
        host.reply = { request in statusObservation(for: request) }
        let context = ToolContext(runID: runID, cancellation: CancellationToken(),
                                  conversationID: taskID)
        let data = try await executor.execute(request: request, context: context)
        XCTAssertEqual(data, statusObservation(for: request))
        let submissions = host.recordedSubmissions()
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.owner.taskID, taskID)
        XCTAssertEqual(submissions.first?.owner.runID, runID)
        XCTAssertEqual(submissions.first?.owner.epoch, 24)
    }

    func testExecutorMapsTypedRemoteFailuresWithoutTargetText() async throws {
        let host = FakeNetworkHost(epoch: 25, bound: true)
        host.failure = .remoteFailed(code: "timeout", detail: "secret.example:443")
        let executor = G07NetworkToolExecutor(host: host, currentEpoch: { 25 })
        do {
            _ = try await executor.execute(
                request: try NetworkToolRequest.tcpProbe(
                    host: "secret.example", port: 443, timeoutMs: 1_000),
                context: ToolContext(runID: runID, cancellation: CancellationToken(),
                                     conversationID: taskID))
            XCTFail("expected a typed timeout failure")
        } catch let error as FloeError {
            XCTAssertEqual(error, .validationFailed("Network diagnostics timed out"))
            XCTAssertFalse(error.reason.contains("secret.example"), error.reason)
        }
    }

    // MARK: - Registration / metadata

    func testRegistrationPublishesSixHonestReadOnlyDescriptors() async throws {
        let registry = ToolRunnerRegistry()
        let executor = ScriptedNetworkExecutor()
        executor.reply = { request in statusObservation(for: request) }
        let names = registerNetworkTools(executor: executor, registry: registry)
        XCTAssertEqual(Set(names), Set(NetworkToolNames.all))
        for name in NetworkToolNames.all {
            let descriptor = try XCTUnwrap(registry.descriptor(named: name), name)
            XCTAssertEqual(descriptor.riskLabels, [.networkAccess])
            XCTAssertFalse(descriptor.isSideEffecting)
            XCTAssertEqual(descriptor.effect, .readOnly)
            XCTAssertFalse(descriptor.requiresHostScope)
            XCTAssertEqual(descriptor.executionBoundary, .any)
            XCTAssertTrue(descriptor.parametersJSON.contains("additionalProperties"))
        }
        let runner = try XCTUnwrap(registry.runner(named: "network.status"))
        let output = try await runner.execute(
            argumentsJSON: Data("{}".utf8),
            context: ToolContext(runID: runID, cancellation: CancellationToken(),
                                 conversationID: taskID))
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(output.summary.utf8)) as? [String: Any])
        XCTAssertEqual(summary["version"] as? Int, 1)
        XCTAssertEqual(summary["method"] as? String, "network.status")
        XCTAssertEqual(summary["source"] as? String, "phone")
        XCTAssertEqual(summary["status"] as? String, "ok")
        let operationID = try XCTUnwrap(summary["operationID"] as? String)
        XCTAssertNotNil(UUID(uuidString: operationID))
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertEqual(output.fullOutputSHA256.count, 64)
    }

    func testUnavailableExecutorHidesEveryRunner() {
        let registry = ToolRunnerRegistry()
        let executor = ScriptedNetworkExecutor()
        executor.available = false
        _ = registerNetworkTools(executor: executor, registry: registry)
        XCTAssertTrue(registry.allDescriptors.isEmpty)
        for name in NetworkToolNames.all {
            XCTAssertNil(registry.runner(named: name), name)
            XCTAssertNil(registry.descriptor(named: name), name)
        }
    }

    func testCompositionReadinessIsHonestWhileUnbound() throws {
        G07NetworkComposition.shared.installToolsIfNeeded()
        let json = G07NetworkComposition.shared.readinessJSON()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["tool"] as? String, "network")
        XCTAssertEqual(object["bound"] as? Bool, false)
        XCTAssertEqual(object["available"] as? Bool, false)
        XCTAssertEqual(object["reason"] as? String, "mailboxClosed")
        XCTAssertEqual((object["expected"] as? [String])?.count, 6)
        XCTAssertEqual((object["registered"] as? [String])?.isEmpty, true)
        XCTAssertEqual(floeNetworkDiagBind(9_999_999), -102,
                       "a bind without the LIVE native root epoch must fail closed")
    }

    // MARK: - Fake host / executor

    private final class FakeNetworkHost: G07NetworkHostSubmitting, @unchecked Sendable {
        struct Submission {
            let request: NetworkToolRequest
            let owner: G07NetworkOwner
        }
        private let lock = NSLock()
        private let epoch: UInt64
        private let bound: Bool
        private var submissions: [Submission] = []
        var reply: (@Sendable (NetworkToolRequest) -> Data)?
        var failure: G07NetworkHostTransportError?

        init(epoch: UInt64, bound: Bool) {
            self.epoch = epoch
            self.bound = bound
        }

        var boundEpoch: UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
        var isBound: Bool { lock.lock(); defer { lock.unlock() }; return bound }

        func submit(request: NetworkToolRequest, owner: G07NetworkOwner,
                    cancellation: CancellationToken) async throws -> Data {
            let (failure, reply) = lock.withLock {
                submissions.append(Submission(request: request, owner: owner))
                return (self.failure, self.reply)
            }
            if let failure { throw failure }
            guard let reply else { throw G07NetworkHostTransportError.hostUnbound }
            return reply(request)
        }

        func recordedSubmissions() -> [Submission] {
            lock.lock(); defer { lock.unlock() }; return submissions
        }
    }

    private final class ScriptedNetworkExecutor: NetworkHostExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var availableValue = true
        private var replyHandler: (@Sendable (NetworkToolRequest) -> Data)?
        private var calls: [NetworkToolRequest] = []

        var available: Bool {
            get { lock.lock(); defer { lock.unlock() }; return availableValue }
            set { lock.lock(); availableValue = newValue; lock.unlock() }
        }

        var reply: (@Sendable (NetworkToolRequest) -> Data)? {
            get { lock.lock(); defer { lock.unlock() }; return replyHandler }
            set { lock.lock(); replyHandler = newValue; lock.unlock() }
        }

        var isAvailable: Bool { available }

        func execute(request: NetworkToolRequest,
                     context: ToolContext) async throws -> Data {
            let handler = lock.withLock {
                calls.append(request)
                return replyHandler
            }
            guard let handler else { throw FloeError.internalError("no fixture") }
            return handler(request)
        }
    }
}

// MARK: - Shared synthetic observation

private func statusObservation(for request: NetworkToolRequest) -> Data {
    Data("""
    {"version":1,"operationID":"\(request.operationID.uuidString)",
    "method":"\(request.method.rawValue)","source":"phone","status":"ok",
    "measuredAt":"2026-10-30T02:00:00Z",
    "network":{"available":true,"transports":["WIFI"],"typeName":"WIFI",
    "interfaceName":"wlan0","vpn":false,"validated":true,
    "captivePortal":false,"metered":false},
    "observations":{"activeNetwork":true,"validated":true},
    "limitations":[]}
    """.utf8)
}
