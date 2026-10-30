// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the bounded native-to-Kotlin Linux shell
// transport mailbox (job-1bd4fcce5eca4856). The "host" below is the SAME
// Swift mailbox API the trusted Kotlin pump drives over JNI (claim ->
// describe -> takePayload -> RuntimeWire exchange -> complete); nothing
// here crosses Binder or touches a device. NOT executed by the authoring
// job; Main compiles it with the added test target.
import XCTest
import Foundation
import FloeCore
@testable import FloeAndroidCore
import FloeAndroidShellTools

final class LinuxShellMailboxTests: XCTestCase {

    private func makeMailbox() -> (LinuxShellMailbox, MailboxLinuxShellTransport) {
        let mailbox = LinuxShellMailbox(sleeper: { nanoseconds in
            try? await Task.sleep(nanoseconds: min(nanoseconds, 1_000_000))
        })
        let budgets = MailboxLinuxShellTransport.Budgets(startMillis: 2_000, pollMillis: 2_000,
                                                         inputMillis: 2_000, resizeMillis: 2_000,
                                                         cancelMillis: 2_000)
        return (mailbox, MailboxLinuxShellTransport(mailbox: mailbox, budgets: budgets))
    }

    private func startRequest(command: String = "echo hi",
                              environment: [String: String] = [:]) -> LinuxShellStartRequest {
        LinuxShellStartRequest(projectID: UUID(), runID: UUID(), conversationID: UUID(),
                               environmentID: "linux.local", command: command, cwd: ".",
                               environment: environment,
                               rows: 24, columns: 80, timeoutSeconds: 5)
    }

    /// Claim + drain one ticket on the "host" side, returning (operation, payload JSON).
    private func claimOne(_ mailbox: LinuxShellMailbox) throws -> (claim: Int64, operation: String, payload: [String: Any]) {
        let claim = mailbox.nextClaim(timeoutMillis: 2_000)
        XCTAssertGreaterThan(claim, 0)
        var buffer = [CChar](repeating: 0, count: 128)
        let written = mailbox.describe(claim: claim, buffer: &buffer, capacity: 128)
        XCTAssertGreaterThan(written, 0)
        let described = try XCTUnwrap(String(cString: buffer))
        let operation = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(described.utf8))) as? [String: Any])?["operation"] as? String)
        let length = mailbox.payloadLength(claim: claim)
        var payloadBuffer = [UInt8](repeating: 0, count: Int(max(0, length)))
        if length > 0 {
            XCTAssertEqual(mailbox.takePayload(claim: claim, buffer: &payloadBuffer, capacity: length), length)
        }
        let object = try JSONSerialization.jsonObject(with: Data(payloadBuffer)) as? [String: Any] ?? [:]
        return (claim, operation, object)
    }

    // MARK: - Fail-closed defaults and epochs

    func testUnboundMailboxFailsClosed() async {
        let (_, transport) = makeMailbox()
        do {
            _ = try await transport.shellStart(startRequest())
            XCTFail("expected notBound")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .notBound)
        } catch { XCTFail("unexpected \(error)") }
    }

    func testBindRejectsZeroStaleAndEqualEpochs() {
        let (mailbox, _) = makeMailbox()
        XCTAssertFalse(mailbox.bind(epoch: 0))
        XCTAssertTrue(mailbox.bind(epoch: 5))
        XCTAssertFalse(mailbox.bind(epoch: 5))
        XCTAssertFalse(mailbox.bind(epoch: 4))
        XCTAssertTrue(mailbox.bind(epoch: 6))
    }

    func testRebindFencesPendingWaiters() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 1))
        // Swift 6 region isolation: a plain local var may not cross into a
        // concurrently executing Task; capture through a lock-guarded box and
        // build the request OUTSIDE the closure (same shape as the sibling
        // replyTask fixtures above).
        let errorBox = StartErrorBox()
        let request = startRequest()
        let waiter = Task {
            do { _ = try await transport.shellStart(request) }
            catch let error as LinuxShellTransportError { errorBox.set(error) }
        }
        // Give the waiter a moment to register, then rebind a new generation.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(mailbox.bind(epoch: 2))
        _ = try await waiter.value
        XCTAssertEqual(errorBox.value, .hostFenced)
    }

    // MARK: - Round trips

    func testStartRoundTripCarriesStrictEngineFields() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        let request = startRequest()
        let replyTask = Task { try await transport.shellStart(request) }
        let host = try claimOne(mailbox)
        XCTAssertEqual(host.operation, "shell.start")
        XCTAssertEqual(Set(host.payload.keys),
                       ["projectID", "runID", "conversationID", "environmentID", "command", "cwd", "rows", "columns", "timeoutSeconds"],
                       "engine shell.start strict field set (no env when empty)")
        XCTAssertEqual(host.payload["runID"] as? String, request.runID.uuidString)
        XCTAssertEqual(host.payload["conversationID"] as? String, request.conversationID?.uuidString)
        var resultBuffer = Data(#"{"sessionID":"lease-1","environmentID":"linux.local"}"#.utf8)
        resultBuffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(resultBuffer.count)), 0)
        }
        let reply = try await replyTask.value
        XCTAssertEqual(reply.sessionID, "lease-1")
        XCTAssertEqual(reply.environmentID, "linux.local")
    }

    func testStartCarriesExplicitEnvUnchangedAndRejectsReservedKeys() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 18))
        // Explicit caller env rides the payload UNCHANGED.
        let request = startRequest(environment: ["BUILD_MODE": "debug", "CC": "gcc"])
        let replyTask = Task { try await transport.shellStart(request) }
        let host = try claimOne(mailbox)
        XCTAssertEqual(Set(host.payload.keys).subtracting(["env"]).sorted(),
                       ["columns", "command", "conversationID", "cwd", "environmentID", "projectID", "rows", "runID", "timeoutSeconds"])
        let env = try XCTUnwrap(host.payload["env"] as? [String: Any])
        XCTAssertEqual(env["BUILD_MODE"] as? String, "debug", "owner-supplied env must not be rewritten by the mailbox")
        XCTAssertEqual(env["CC"] as? String, "gcc")
        var resultBuffer = Data(#"{"sessionID":"lease-env","environmentID":"linux.local"}"#.utf8)
        resultBuffer.withUnsafeBytes { raw in
            mailbox.complete(claim: host.claim, status: 0, value: raw.bindMemory(to: UInt8.self).baseAddress!, valueLen: Int32(resultBuffer.count))
        }
        _ = try await replyTask.value
        // A reserved key cannot pass the typed seam even if a caller tries.
        do {
            _ = try await transport.shellStart(startRequest(environment: ["FLOE_SECRET": "x"]))
            XCTFail("reserved env key must be refused before queueing")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .payloadTooLarge)
        }
    }

    // MARK: - G07.3A trusted role/reuse + measured admission metadata

    private func settleStart(_ mailbox: LinuxShellMailbox,
                             transport: MailboxLinuxShellTransport,
                             request: LinuxShellStartRequest,
                             reply: String) async throws -> LinuxShellStartReply {
        let replyTask = Task { try await transport.shellStart(request) }
        let host = try claimOne(mailbox)
        XCTAssertEqual(host.operation, "shell.start")
        var buffer = Data(reply.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        return try await replyTask.value
    }

    private func settlePoll(_ mailbox: LinuxShellMailbox,
                            transport: MailboxLinuxShellTransport,
                            reply: String) async throws -> LinuxShellPollReply {
        let replyTask = Task {
            try await transport.shellPoll(LinuxShellPollRequest(sessionID: "lease-1", cursor: 0,
                                                                maxBytes: 16_384))
        }
        let host = try claimOne(mailbox)
        XCTAssertEqual(host.operation, "shell.poll")
        var buffer = Data(reply.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        return try await replyTask.value
    }

    private func interactiveReuseRequest(_ owner: String) -> LinuxShellStartRequest {
        LinuxShellStartRequest(
            projectID: UUID(), runID: UUID(), conversationID: UUID(),
            environmentID: "linux.local", command: "exec /bin/sh", cwd: ".",
            environment: [:], rows: 24, columns: 80, timeoutSeconds: 30,
            hostLeaseRole: .interactive,
            workspaceReuse: .shared(ownerSessionID: owner))
    }

    /// The real mailbox ingress (claim -> describe -> takePayload -> complete)
    /// carries the trusted role/reuse on ONE interactive start, and the same
    /// round trip decodes every measured admission fact the runtime reports.
    func testInteractiveReuseStartCarriesTrustedWireAndDecodesMeasuredMetadata() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 30))
        let owner = UUID().uuidString
        let request = interactiveReuseRequest(owner)
        let replyTask = Task { try await transport.shellStart(request) }
        let host = try claimOne(mailbox)
        XCTAssertEqual(host.operation, "shell.start")
        XCTAssertEqual(host.payload["leaseRole"] as? String, "interactive")
        let reuse = try XCTUnwrap(host.payload["workspaceReuse"] as? [String: Any])
        XCTAssertEqual(reuse["mode"] as? String, "shared")
        XCTAssertEqual(reuse["ownerSessionID"] as? String, owner,
                       "the trusted owner identity rides unchanged (never normalized)")
        var buffer = Data("""
        {"sessionID":"lease-reuse","environmentID":"linux.local",
         "runtimeGeneration":"00112233445566778899aabbccddeeff",
         "workspaceOwner":false,"prepareReused":true,
         "prepareMillis":120,"prepareCopiedBytes":4096,
         "importMillis":0,"importedEntries":12}
        """.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        let reply = try await replyTask.value
        XCTAssertEqual(reply.sessionID, "lease-reuse")
        XCTAssertEqual(reply.environmentID, "linux.local")
        XCTAssertEqual(reply.runtimeGeneration, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(reply.workspaceOwner, false, "a participant is not the owner")
        XCTAssertEqual(reply.prepareReused, true)
        XCTAssertEqual(reply.prepareMillis, 120)
        XCTAssertEqual(reply.prepareCopiedBytes, 4_096)
        XCTAssertEqual(reply.importMillis, 0, "a measured zero import is a real fact, not a missing one")
        XCTAssertEqual(reply.importedEntries, 12)
    }

    /// A legacy start payload stays byte-for-byte shaped as before: nil role
    /// and nil reuse keys are OMITTED, never encoded as null/default values.
    func testLegacyStartPayloadStillOmitsRoleAndReuseKeys() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 31))
        let request = startRequest()
        let replyTask = Task { try await transport.shellStart(request) }
        let host = try claimOne(mailbox)
        XCTAssertNil(host.payload["leaseRole"])
        XCTAssertNil(host.payload["workspaceReuse"])
        XCTAssertEqual(Set(host.payload.keys).sorted(),
                       ["columns", "command", "conversationID", "cwd", "environmentID",
                        "projectID", "rows", "runID", "timeoutSeconds"])
        var buffer = Data(#"{"sessionID":"lease-legacy","environmentID":"linux.local"}"#.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        let reply = try await replyTask.value
        XCTAssertNil(reply.runtimeGeneration)
        XCTAssertNil(reply.workspaceOwner, "absence must not be fabricated as a boolean")
        XCTAssertNil(reply.prepareReused, "absence must not be fabricated as a boolean")
        XCTAssertNil(reply.prepareMillis)
        XCTAssertNil(reply.prepareCopiedBytes)
        XCTAssertNil(reply.importMillis)
        XCTAssertNil(reply.importedEntries)
    }

    /// A present-but-malformed optional admission fact fails closed instead
    /// of being silently dropped or coerced (bool-as-number, fractional or
    /// negative counters, empty generation).
    func testMalformedStartReplyMetadataFailsClosed() async throws {
        let base = #""sessionID":"lease-bad","environmentID":"linux.local""#
        let malformed = [
            "{" + base + #","runtimeGeneration":""}"#,
            "{" + base + #","runtimeGeneration":42}"#,
            "{" + base + #","workspaceOwner":"true"}"#,
            "{" + base + #","prepareReused":1}"#,
            "{" + base + #","prepareMillis":-1}"#,
            "{" + base + #","prepareMillis":1.5}"#,
            "{" + base + #","prepareCopiedBytes":"4096"}"#,
            "{" + base + #","importedEntries":true}"#,
        ]
        for (index, json) in malformed.enumerated() {
            let (mailbox, transport) = makeMailbox()
            XCTAssertTrue(mailbox.bind(epoch: UInt64(40 + index)))
            do {
                _ = try await settleStart(mailbox, transport: transport,
                                          request: startRequest(), reply: json)
                XCTFail("malformed optional metadata must be refused: \(json)")
            } catch let error as LinuxShellTransportError {
                XCTAssertEqual(error, .replyMalformed, "case \(index): \(json)")
            }
        }
    }

    /// A same-workspace hint that violates the runtime's closed shape is
    /// refused BEFORE queueing; it is never dropped (which would silently
    /// start a fresh owner and re-import over live guest files).
    func testMalformedWorkspaceReuseHintIsRefusedBeforeQueueing() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 32))
        let malformed = [
            LinuxShellWorkspaceReuse(mode: "exclusive", ownerSessionID: "owner-A"),
            LinuxShellWorkspaceReuse(mode: "", ownerSessionID: "owner-A"),
            LinuxShellWorkspaceReuse(mode: "shared", ownerSessionID: ""),
            LinuxShellWorkspaceReuse(mode: "shared", ownerSessionID: "owner\nA"),
        ]
        for (index, reuse) in malformed.enumerated() {
            var request = startRequest()
            request.hostLeaseRole = .interactive
            request.workspaceReuse = reuse
            do {
                _ = try await transport.shellStart(request)
                XCTFail("malformed workspaceReuse must be refused: case \(index)")
            } catch let error as LinuxShellTransportError {
                XCTAssertEqual(error, .payloadTooLarge, "case \(index)")
            }
        }
        XCTAssertEqual(mailbox.snapshotForTesting().live, 0,
                       "a refused hint never reached the host queue")
    }

    /// A hint the runtime cannot prove is a typed FAILED start: the hint is
    /// sent unchanged, the failure is surfaced, and nothing is retried as a
    /// silent fresh owner (which would re-import over live guest files).
    func testRuntimeRefusedWorkspaceHintFailsClosedWithoutFallback() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 35))
        let owner = UUID().uuidString
        // Build the request BEFORE the sending closure so the Task captures
        // only Sendable values (the XCTestCase instance is not Sendable).
        let request = interactiveReuseRequest(owner)
        let replyTask = Task { try await transport.shellStart(request) }
        let host = try claimOne(mailbox)
        let reuse = try XCTUnwrap(host.payload["workspaceReuse"] as? [String: Any])
        XCTAssertEqual(reuse["ownerSessionID"] as? String, owner,
                       "the exact hint must reach the runtime unchanged")
        var buffer = Data(#"{"code":"workspaceOwnerUnavailable"}"#.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 1,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        do {
            _ = try await replyTask.value
            XCTFail("a refused reuse hint must fail closed")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .remoteFailed(code: "workspaceOwnerUnavailable"))
        }
        XCTAssertEqual(mailbox.snapshotForTesting().live, 0)
        XCTAssertEqual(mailbox.nextClaim(timeoutMillis: 0), 0,
                       "a refused hint is never replayed as a fresh-owner start")
    }

    /// `deferred` is a real shared-export outcome accepted only for a
    /// RELEASED terminal carrying the runtime's typed owner fact. The owner
    /// reports true; a participant reports false (another live session owns
    /// the export). It is not an exit, not a saved workspace and never
    /// relaxes the lease/process proof.
    func testPollAcceptsDeferredOnlyWithReleasedTerminalAndTypedOwnerFact() async throws {
        let base = #""sessionID":"lease-1","state":"terminated","outputBase64":"","cursor":4,"gapBytes":0,"more":false,"droppedBytes":0,"leaseReleased":true,"cancelled":false"#
        let cases = [
            "{" + base + #","workspaceStatus":"deferred","workspaceOwner":true}"#,
            "{" + base + #","workspaceStatus":"deferred","workspaceOwner":false}"#,
        ]
        for (index, json) in cases.enumerated() {
            let (mailbox, transport) = makeMailbox()
            XCTAssertTrue(mailbox.bind(epoch: UInt64(33 + index)))
            let page = try await settlePoll(mailbox, transport: transport, reply: json)
            XCTAssertEqual(page.workspaceStatus, "deferred")
            XCTAssertTrue(page.leaseReleased)
            XCTAssertFalse(page.cancelled)
            XCTAssertNil(page.exitCode, "a deferred export is not a fabricated exit")
            XCTAssertNil(page.stopReason)
        }
    }

    func testPollRejectsDeferredWithoutReleasedOwnerOrWithUnknownStatus() async throws {
        let base = #""sessionID":"lease-1","state":"terminated","outputBase64":"","cursor":4,"gapBytes":0,"more":false,"droppedBytes":0"#
        let malformed = [
            "{" + base + #","leaseReleased":true,"workspaceStatus":"deferred"}"#,
            "{" + base + #","leaseReleased":false,"workspaceStatus":"deferred","workspaceOwner":true}"#,
            "{" + base + #","leaseReleased":true,"workspaceStatus":"pending"}"#,
            "{" + base + #","leaseReleased":true,"workspaceStatus":"deferred","workspaceOwner":1}"#,
        ]
        for (index, json) in malformed.enumerated() {
            let (mailbox, transport) = makeMailbox()
            XCTAssertTrue(mailbox.bind(epoch: UInt64(50 + index)))
            do {
                _ = try await settlePoll(mailbox, transport: transport, reply: json)
                XCTFail("invalid deferred poll must be refused: case \(index)")
            } catch let error as LinuxShellTransportError {
                XCTAssertEqual(error, .replyMalformed, "case \(index): \(json)")
            }
        }
    }

    func testPollDecodesStopTruthFields() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 19))
        let replyTask = Task {
            try await transport.shellPoll(LinuxShellPollRequest(sessionID: "lease-1", cursor: 0, maxBytes: 16_384))
        }
        let host = try claimOne(mailbox)
        var buffer = Data(#"{"sessionID":"lease-1","state":"terminated","outputBase64":"","cursor":7,"gapBytes":0,"more":false,"droppedBytes":0,"leaseReleased":true,"cancelled":true,"stopReason":"timeout","exitCode":0,"termSig":15,"waitErrno":0}"#.utf8)
        buffer.withUnsafeBytes { raw in
            mailbox.complete(claim: host.claim, status: 0, value: raw.bindMemory(to: UInt8.self).baseAddress!, valueLen: Int32(buffer.count))
        }
        let page = try await replyTask.value
        XCTAssertTrue(page.cancelled, "a stopped remote is not an exited process")
        XCTAssertEqual(page.stopReason, "timeout")
        XCTAssertEqual(page.termSig, 15)
    }

    func testPollDecodesMergedBase64PageHonestly() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 8))
        let merged = Data("stdout and stderr mixed\r\n".utf8)
        let replyTask = Task {
            try await transport.shellPoll(LinuxShellPollRequest(sessionID: "lease-1", cursor: 0, maxBytes: 16_384))
        }
        let host = try claimOne(mailbox)
        XCTAssertEqual(host.operation, "shell.poll")
        let json = """
        {"sessionID":"lease-1","state":"terminated","outputBase64":"\(merged.base64EncodedString())",
         "cursor":25,"gapBytes":3,"more":false,"droppedBytes":3,"leaseReleased":true,
         "exitCode":0,"termSig":0,"waitErrno":0}
        """
        var buffer = Data(json.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        let page = try await replyTask.value
        XCTAssertEqual(page.mergedOutput, merged)
        XCTAssertEqual(page.cursor, 25)
        XCTAssertEqual(page.gapBytes, 3)
        XCTAssertEqual(page.droppedBytes, 3)
        XCTAssertEqual(page.state, .terminated)
        XCTAssertTrue(page.leaseReleased)
        XCTAssertEqual(page.exitCode, 0)
    }

    func testPollRejectsMissingTerminalFields() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 9))
        let replyTask = Task {
            try await transport.shellPoll(LinuxShellPollRequest(sessionID: "lease-1", cursor: 0, maxBytes: 16_384))
        }
        let host = try claimOne(mailbox)
        var buffer = Data(#"{"sessionID":"lease-1","cursor":0}"#.utf8)   // no state/leaseReleased
        buffer.withUnsafeBytes { raw in
            _ = mailbox.complete(claim: host.claim, status: 0,
                                 value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                 valueLen: Int32(buffer.count))
        }
        do {
            _ = try await replyTask.value
            XCTFail("expected replyMalformed")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .replyMalformed)
        }
    }

    func testFailedReceiptMapsToTypedRemoteFailure() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 10))
        let replyTask = Task {
            try await transport.shellCancel(LinuxShellCancelRequest(sessionID: "lease-9"))
        }
        let host = try claimOne(mailbox)
        XCTAssertEqual(host.operation, "shell.cancel")
        XCTAssertEqual(host.payload.keys.sorted(), ["sessionID"])
        var buffer = Data(#"{"code":"operation_failed"}"#.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 1,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        do {
            _ = try await replyTask.value
            XCTFail("expected remoteFailed")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .remoteFailed(code: "operation_failed"))
        }
    }

    // MARK: - Bounds

    func testOversizedRequestRejectedBeforeQueueing() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 11))
        do {
            _ = try await transport.shellStart(startRequest(command: String(repeating: "a", count: 200_000)))
            XCTFail("expected payloadTooLarge")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .payloadTooLarge)
        }
        XCTAssertEqual(mailbox.snapshotForTesting().live, 0)
    }

    func testStdinChunkAndCursorBoundsAreEnforcedTyped() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 12))
        do {
            _ = try await transport.shellInput(LinuxShellInputRequest(sessionID: "s", bytes: Data(repeating: 7, count: 20_000)))
            XCTFail("expected payloadTooLarge")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .payloadTooLarge)
        }
        do {
            _ = try await transport.shellPoll(LinuxShellPollRequest(sessionID: "s", cursor: UInt64(Int64.max) + 1, maxBytes: 100))
            XCTFail("expected payloadTooLarge for cursor beyond engine Long bound")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .payloadTooLarge)
        }
        XCTAssertEqual(mailbox.snapshotForTesting().live, 0)
    }

    func testSaturatedMailboxRejectsPromptly() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 13))
        let budgets = MailboxLinuxShellTransport.Budgets(startMillis: 400, pollMillis: 400,
                                                         inputMillis: 400, resizeMillis: 400,
                                                         cancelMillis: 400)
        let slowTransport = MailboxLinuxShellTransport(mailbox: mailbox, budgets: budgets)
        var fillers: [Task<Void, Never>] = []
        for _ in 0..<LinuxShellMailboxLimits.maximumLiveTickets {
            fillers.append(Task {
                _ = try? await slowTransport.shellPoll(LinuxShellPollRequest(sessionID: "s", cursor: 0, maxBytes: 1))
            })
        }
        // Let the fills register before probing the bound — deterministically
        // (Task start is lazy; a fixed nap raced the 400 ms budgets and the
        // probe could legally find a freed slot as a late-expiring filler).
        var registered = false
        let registerDeadline = Date().addingTimeInterval(0.25)
        while Date() < registerDeadline {
            if mailbox.snapshotForTesting().live >= LinuxShellMailboxLimits.maximumLiveTickets {
                registered = true
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(registered,
                      "all fillers must register inside their budgets before the bound is probed")
        do {
            _ = try await slowTransport.shellPoll(LinuxShellPollRequest(sessionID: "overflow", cursor: 0, maxBytes: 1))
            XCTFail("expected saturated")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .saturated)
        }
        for filler in fillers { await filler.value }   // budget expiry drains them
    }

    // MARK: - Settlement honesty

    func testWaitBudgetExpiryRetiresQueuedButKeepsClaimedTicket() async throws {
        let (mailbox, _) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 14))
        // Queued + never claimed: waiter expires and the ticket provably
        // never reached the host, so it retires.
        do {
            _ = try await mailbox.submit(operation: "shell.poll",
                                         payload: Data("{}".utf8), timeoutMillis: 30)
            XCTFail("expected waitBudgetExpired")
        } catch let error as LinuxShellTransportError {
            XCTAssertEqual(error, .waitBudgetExpired)
        }
        XCTAssertEqual(mailbox.snapshotForTesting().live, 0)
        // Claimed + waiter expires: the ticket STAYS until its real
        // settlement — nobody may assume a stop or an exit.
        let waiter = Task {
            try? await mailbox.submit(operation: "shell.start",
                                      payload: Data(#"{"command":"x"}"#.utf8), timeoutMillis: 40)
        }
        let claim = mailbox.nextClaim(timeoutMillis: 1_000)
        XCTAssertGreaterThan(claim, 0)
        _ = try await waiter.value
        XCTAssertEqual(mailbox.snapshotForTesting().live, 1)
        XCTAssertEqual(mailbox.isLive(claim: claim), 1)
        var buffer = Data(#"{"sessionID":"lease-x","environmentID":"linux.local"}"#.utf8)
        buffer.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(buffer.count)), 0)
        }
        XCTAssertEqual(mailbox.snapshotForTesting().live, 0)
        XCTAssertEqual(mailbox.isLive(claim: claim), 0)
    }

    func testClaimNoneWhenEmpty() {
        let (mailbox, _) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 15))
        let claim = mailbox.nextClaim(timeoutMillis: 0)
        XCTAssertEqual(claim, 0)   // nothing queued
    }

    func testNonJSONCompletionIsRejectedAndClaimStaysLive() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 16))
        let replyTask = Task {
            try? await transport.shellCancel(LinuxShellCancelRequest(sessionID: "lease-1"))
        }
        let host = try claimOne(mailbox)
        var buffer = Data("definitely-not-json".utf8)
        var rejected: Int32 = 0
        buffer.withUnsafeBytes { raw in
            rejected = mailbox.complete(claim: host.claim, status: 0,
                                        value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                        valueLen: Int32(buffer.count))
        }
        XCTAssertEqual(rejected, -108)
        XCTAssertEqual(mailbox.isLive(claim: host.claim), 1)
        var ok = Data(#"{"state":"stop_requested"}"#.utf8)
        ok.withUnsafeBytes { raw in
            XCTAssertEqual(mailbox.complete(claim: host.claim, status: 0,
                                            value: raw.bindMemory(to: UInt8.self).baseAddress!,
                                            valueLen: Int32(ok.count)), 0)
        }
        let settled = await replyTask.value
        let reply = try XCTUnwrap(settled)
        XCTAssertEqual(reply.state, "stop_requested")
    }

    // MARK: - Privacy of the bounded receipts

    func testStatsNeverIncludePayloadBytes() async throws {
        let (mailbox, transport) = makeMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 17))
        let sentinelRequest = startRequest(command: "SENTINEL-PAYLOAD-BYTES")
        _ = Task { try? await transport.shellStart(sentinelRequest) }
        let host = try claimOne(mailbox)
        let stats = mailbox.statsJSON()
        XCTAssertFalse(stats.contains("SENTINEL-PAYLOAD-BYTES"))
        XCTAssertFalse(stats.contains("echo"))
        _ = host
    }
}

/// Lock-guarded typed-error capture for the rebind-fence waiter (Swift 6
/// region-isolation-safe).
private final class StartErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: LinuxShellTransportError?
    var value: LinuxShellTransportError? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ error: LinuxShellTransportError) { lock.lock(); stored = error; lock.unlock() }
}
