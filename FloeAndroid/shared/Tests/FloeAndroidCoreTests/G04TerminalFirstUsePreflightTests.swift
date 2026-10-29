// SPDX-License-Identifier: MPL-2.0
// Authored focused suite for the RUN-LESS terminal first entry
// (job-e2e7d046b63744cc, Main critical reviews 2026-10-28).
//
// What is proven here, deterministically and without a device, a JNI library
// or a Core composition:
//  * the pure admission rule prepares ONLY on the real gap (five live
//    prerequisites, missing mapping/lease), reuses a warm lane without
//    submitting anything, and never re-imports when the produced facts already
//    live but something else is unqualified;
//  * the pure binding-eligibility rule creates the genuine private-task
//    workspace ONLY for a durable ORDINARY conversation of the exact live
//    generation with no binding and no foreign expectation — a temporary chat,
//    a notes/foreign identity, a dead generation, an unreadable ownership row
//    or an explicit foreign expectation create nothing;
//  * the closed four-key request grammar, the strict reply grammar (exact
//    identity + generation echo, measured hex-64 digests, `shellRegistered`,
//    fail-closed `ownershipReleased`) and the pure ownership-read grammar;
//  * a typed preparation refusal is a HARD refusal: a global capability truth
//    that became ready meanwhile (a concurrent model run) can NOT override a
//    cancelled, fenced, expired or refused preparation of THIS action, so
//    nothing opens late on an identity it no longer owns;
//  * a `ready` echo alone never qualifies — only Core's own live re-read does;
//  * the PHYSICAL settlement boundary Main required, against the REAL
//    `LinuxShellMailbox`: a host `unavailable`/`close_retained` answer while
//    real IO remains live RETAINS the operation lease; a claimed ticket
//    survives a released waiter (budget expiry or cancellation) and still
//    retains; a Root generation fence while claimed RETAINS (a fence is not
//    settlement); the real drained settlement releases EXACTLY once; an
//    unclaimed rejection releases immediately; and an observed host release
//    discharges a retained lease exactly once.
//  * the genuine persisted binding producer on REAL migrated SQLite stores: a
//    fresh ordinary conversation with ZERO workspace/ownership rows gets the
//    canonical `.privateTask` / `PrivateTasks/<conversationID>` row,
//    idempotent and never re-pointed, and a missing conversation row writes
//    nothing.
//
// Isolation: every mailbox assertion runs on a FRESH `LinuxShellMailbox()`
// instance — never `LinuxShellMailbox.shared` — and every store assertion on
// its own `PrivacyTestBed` fixture directory, so no synthetic generation or
// ticket can poison a sibling owner's live lane. Nothing here stops, kills,
// replays, executes or grants anything.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAndroidCore
import FloeAndroidShellTools

// MARK: - Helpers

/// Thread-safe release counter (the release closure is `@Sendable` and runs on
/// a service-owned task).
private final class FirstUseReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Records what one injected observation submit actually saw (the closure is
/// `@Sendable`, so captured mutable state lives in a lock-guarded box).
private final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(operation: String, payload: Data, budget: Int)] = []
    func record(_ operation: String, _ payload: Data, _ budget: Int) {
        lock.lock(); records.append((operation, payload, budget)); lock.unlock()
    }
    var last: (operation: String, payload: Data, budget: Int)? {
        lock.lock(); defer { lock.unlock() }; return records.last
    }
}

/// Records the operation/budget observed by the two injected preparation
/// closures (`@Sendable`, so the state lives behind a lock).
private final class FirstUseSeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: String?
    private var budget: Int?
    func recordOperation(_ value: String) { lock.lock(); operation = value; lock.unlock() }
    func recordBudget(_ value: Int) { lock.lock(); budget = value; lock.unlock() }
    var seenOperation: String? { lock.lock(); defer { lock.unlock() }; return operation }
    var seenBudget: Int? { lock.lock(); defer { lock.unlock() }; return budget }
}

/// Minimal event sink: proves the store emitted nothing while preparing.
private final class FirstUseRecordingSink: G04TerminalEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: Any]] = []
    func emitControl(_ object: [String: Any]) { lock.lock(); stored.append(object); lock.unlock() }
    func emitOutput(sessionToken: String, seq: Int64, bytes: Data) {}
    var controlCount: Int { lock.lock(); defer { lock.unlock() }; return stored.count }
}

private func canonicalUUID(_ seed: String) -> UUID { UUID(uuidString: seed)! }

// UPPER-CASE canonical Core grammar with real A-F hex letters (a digit-only
// fixture passes both Java grammars and therefore misses case bugs).
private let operationID = canonicalUUID("3F2504E0-4F89-11D3-9A0C-0305E82C3301")
private let uiRunID = canonicalUUID("A1B2C3D4-5E6F-4A7B-8C9D-0E1F2A3B4C5D")
private let conversationID = canonicalUUID("0F8FAD5B-D9CB-469F-A165-70867728950E")
private let hex64 = String(repeating: "ab12", count: 16)

private func readyFrame(epoch: UInt64 = 7,
                        operation: UUID = operationID,
                        ui: UUID = uiRunID,
                        conversation: UUID = conversationID,
                        indexDigest: String = hex64,
                        leaseDigest: String = hex64,
                        shellRegistered: Bool = true,
                        ownershipReleased: Bool? = true) -> Data {
    var object: [String: Any] = [
        "status": "ready",
        "rootEpoch": epoch,
        "operationID": operation.uuidString,
        "uiRunID": ui.uuidString,
        "conversationID": conversation.uuidString,
        "workspaceIndexDigest": indexDigest,
        "leaseProofDigest": leaseDigest,
    ]
    // A missing / non-bool `shellRegistered` or `ownershipReleased` must be
    // refused or fail closed, so those cases omit the key entirely.
    if shellRegistered { object["shellRegistered"] = true }
    if let ownershipReleased { object["ownershipReleased"] = ownershipReleased }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func unavailableFrame(reason: String, epoch: UInt64 = 7,
                              ownershipReleased: Bool? = false) -> Data {
    var object: [String: Any] = [
        "status": "unavailable", "rootEpoch": epoch,
        "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
        "conversationID": conversationID.uuidString, "reason": reason,
    ]
    if let ownershipReleased { object["ownershipReleased"] = ownershipReleased }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func allFields(_ mapping: Bool, _ lease: Bool,
                       prerequisites: Bool = true) -> LinuxShellQualificationFields {
    var fields = LinuxShellQualificationFields()
    fields.runtimeUidBoundaryVerified = prerequisites
    fields.engineConnected = prerequisites
    fields.mailboxEpochBound = prerequisites
    fields.rootfsQualified = prerequisites
    fields.singleWorkloadContractAcknowledged = prerequisites
    fields.workspaceMappingSynced = mapping
    fields.leaseAuthorityQualified = lease
    return fields
}

// MARK: - Suite

final class G04TerminalFirstUsePreflightTests: XCTestCase {

    // MARK: Pure readiness rule

    func testWarmQualifiedLaneSkipsAndPreparesNothing() {
        XCTAssertEqual(G04TerminalFirstUseRule.decision(fields: allFields(true, true),
                                                       capabilityQualified: true),
                       .skipAlreadyQualified)
    }

    func testLivePrerequisitesWithMissingProducedFactsPrepare() {
        XCTAssertEqual(G04TerminalFirstUseRule.decision(fields: allFields(false, false),
                                                       capabilityQualified: false), .prepare)
        XCTAssertEqual(G04TerminalFirstUseRule.decision(fields: allFields(true, false),
                                                       capabilityQualified: false), .prepare)
        XCTAssertEqual(G04TerminalFirstUseRule.decision(fields: allFields(false, true),
                                                       capabilityQualified: false), .prepare)
    }

    func testEveryMissingPrerequisiteRefusesInsteadOfPreparing() {
        // Mapping/lease are what a preflight PRODUCES, so they must not gate
        // it — but each of the FIVE consumed facts must.
        var noUid = allFields(false, false); noUid.runtimeUidBoundaryVerified = false
        var noEngine = allFields(false, false); noEngine.engineConnected = false
        var noMailbox = allFields(false, false); noMailbox.mailboxEpochBound = false
        var noRootfs = allFields(false, false); noRootfs.rootfsQualified = false
        var noWorkload = allFields(false, false); noWorkload.singleWorkloadContractAcknowledged = false
        for fields in [allFields(false, false, prerequisites: false),
                       noUid, noEngine, noMailbox, noRootfs, noWorkload] {
            XCTAssertEqual(G04TerminalFirstUseRule.decision(fields: fields,
                                                           capabilityQualified: false),
                           .refuse(.prerequisitesUnverified))
        }
    }

    func testProducedFactsWithoutCapabilityNeverReimport() {
        XCTAssertEqual(G04TerminalFirstUseRule.decision(fields: allFields(true, true),
                                                       capabilityQualified: false),
                       .refuse(.capabilityNotQualified))
    }

    // MARK: Pure binding eligibility

    func testOnlyAFreshOrdinaryTaskOfTheLiveGenerationMayCreateABinding() {
        func eligibility(persisted: Bool = true, ordinary: Bool = true, live: Bool = true,
                         known: Bool = true, bound: Bool = false, foreign: Bool = false)
            -> G04TerminalFirstUseRule.BindingEligibility {
            G04TerminalFirstUseRule.bindingEligibility(
                conversationPersisted: persisted, purposeOrdinary: ordinary, generationLive: live,
                bindingKnown: known, alreadyBound: bound, foreignWorkspaceExpectation: foreign)
        }
        XCTAssertEqual(eligibility(), .eligible)
        XCTAssertEqual(eligibility(persisted: false, ordinary: false), .notEligible)  // temporary chat
        XCTAssertEqual(eligibility(ordinary: false), .notEligible)                   // notes/foreign
        XCTAssertEqual(eligibility(live: false), .notEligible)                       // dead generation
        XCTAssertEqual(eligibility(known: false), .notEligible)                      // unreadable row
        XCTAssertEqual(eligibility(foreign: true), .notEligible)                     // foreign expect
        // An already-bound task is never re-pointed, whatever else is true.
        XCTAssertEqual(eligibility(bound: true), .alreadyBound)
        XCTAssertEqual(eligibility(bound: true, foreign: true), .notEligible)
    }

    // MARK: Closed request grammars

    func testRequestIsTheClosedFourKeyShapeAndDeterministic() throws {
        let first = try XCTUnwrap(G04TerminalFirstUseRequest.payload(
            operationID: operationID, uiRunID: uiRunID, conversationID: conversationID, rootEpoch: 7))
        let second = try XCTUnwrap(G04TerminalFirstUseRequest.payload(
            operationID: operationID, uiRunID: uiRunID, conversationID: conversationID, rootEpoch: 7))
        XCTAssertEqual(first, second)                       // sortedKeys: byte-stable
        let object = try XCTUnwrap(try? JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(Set(object.keys), G04TerminalFirstUseRequest.closedKeys)
        XCTAssertEqual(object.keys.count, 4)
        XCTAssertEqual(object["operationID"] as? String, operationID.uuidString)
        XCTAssertEqual(object["uiRunID"] as? String, uiRunID.uuidString)
        XCTAssertEqual(object["conversationID"] as? String, conversationID.uuidString)
        XCTAssertEqual((object["rootEpoch"] as? NSNumber)?.uint64Value, 7)
        // No environment, no command, no path, no model/provider field, and
        // never a `runID` key: a UI identity must not look like a model run.
        XCTAssertNil(object["environmentID"])
        XCTAssertNil(object["runID"])
        XCTAssertNil(object["command"])
        XCTAssertNil(G04TerminalFirstUseRequest.payload(operationID: operationID, uiRunID: uiRunID,
                                                       conversationID: conversationID, rootEpoch: 0))
        XCTAssertEqual(G04TerminalFirstUseRequest.operation, "host.terminalWorkspacePreflight")
        // The ownership read shares the closed shape but is a distinct lane.
        XCTAssertEqual(G04TerminalFirstUseOwnershipQuery.closedKeys,
                       G04TerminalFirstUseRequest.closedKeys)
        XCTAssertEqual(G04TerminalFirstUseOwnershipQuery.operation, "host.terminalPreflightOwnership")
        XCTAssertNotEqual(G04TerminalFirstUseOwnershipQuery.operation,
                          G04TerminalFirstUseRequest.operation)
    }

    // MARK: Strict reply grammar

    private func parseReply(_ data: Data) -> G04TerminalFirstUseReply.Outcome {
        G04TerminalFirstUseReply.parse(data,
                                       maximumFrameBytes: LinuxShellMailboxLimits.maximumFrameBytes,
                                       expectedEpoch: 7,
                                       operationID: operationID,
                                       uiRunID: uiRunID,
                                       conversationID: conversationID)
    }

    func testReadyReplyRequiresExactIdentityGenerationAndMeasuredDigests() {
        guard case .ready(let index, let lease, let released) = parseReply(readyFrame()) else {
            return XCTFail("a fully fenced ready frame must parse as ready")
        }
        XCTAssertEqual(index, hex64)
        XCTAssertEqual(lease, hex64)
        XCTAssertTrue(released)
        // Generation and identity fences win over any status string.
        XCTAssertEqual(parseReply(readyFrame(epoch: 8)), .malformed(.replyIdentityMismatch))
        XCTAssertEqual(parseReply(readyFrame(operation: UUID())), .malformed(.replyIdentityMismatch))
        XCTAssertEqual(parseReply(readyFrame(ui: UUID())), .malformed(.replyIdentityMismatch))
        XCTAssertEqual(parseReply(readyFrame(conversation: UUID())), .malformed(.replyIdentityMismatch))
        // Unmeasured / missing evidence is never a success.
        XCTAssertEqual(parseReply(readyFrame(indexDigest: "not-a-digest")), .malformed(.replyMalformed))
        XCTAssertEqual(parseReply(readyFrame(leaseDigest: String(repeating: "a", count: 63))),
                       .malformed(.replyMalformed))
        XCTAssertEqual(parseReply(readyFrame(shellRegistered: false)), .malformed(.replyMalformed))
        let huge = Data(count: LinuxShellMailboxLimits.maximumFrameBytes + 1)
        XCTAssertEqual(parseReply(huge), .malformed(.replyMalformed))
        XCTAssertEqual(parseReply(Data("not json".utf8)), .malformed(.replyMalformed))
    }

    func testPhysicalSettlementFactIsStrictAndFailsClosed() {
        // An omitted or non-bool fact is NOT a release: an older or foreign
        // host can never discharge a lease by omission.
        guard case .ready(_, _, let omitted) = parseReply(readyFrame(ownershipReleased: nil)) else {
            return XCTFail("ready frame without the fact must still parse")
        }
        XCTAssertFalse(omitted)
        guard case .ready(_, _, let assertedFalse) = parseReply(readyFrame(ownershipReleased: false)) else {
            return XCTFail("ready frame with a false fact must still parse")
        }
        XCTAssertFalse(assertedFalse)
        guard case .refused(let detail, let refusedReleased) =
            parseReply(unavailableFrame(reason: "close_retained")) else {
            return XCTFail("an unavailable frame must parse as refused")
        }
        XCTAssertEqual(detail, "close_retained")
        XCTAssertFalse(refusedReleased)
        guard case .refused(_, let settledReleased) =
            parseReply(unavailableFrame(reason: "mapping_unsynced", ownershipReleased: true)) else {
            return XCTFail("an unavailable frame must parse as refused")
        }
        XCTAssertTrue(settledReleased)
    }

    func testHostRefusalsStayBoundedTokens() {
        XCTAssertEqual(parseReply(unavailableFrame(reason: "prerequisites_unverified")),
                       .refused(detail: "prerequisites_unverified", ownershipReleased: false))
        // Free text (a host filesystem message) never rides the reason.
        XCTAssertEqual(parseReply(unavailableFrame(reason: "No such file or directory")),
                       .refused(detail: "hostUnavailable", ownershipReleased: false))
        XCTAssertEqual(parseReply(unavailableFrame(reason: String(repeating: "x", count: 33))),
                       .refused(detail: "hostUnavailable", ownershipReleased: false))
        let cancelled = try! JSONSerialization.data(withJSONObject: [
            "status": "cancelled", "rootEpoch": 7, "ownershipReleased": false,
            "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
            "conversationID": conversationID.uuidString,
        ] as [String: Any], options: [.sortedKeys])
        XCTAssertEqual(parseReply(cancelled), .cancelled(ownershipReleased: false))
        let unknown = try! JSONSerialization.data(withJSONObject: [
            "status": "maybe", "rootEpoch": 7,
            "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
            "conversationID": conversationID.uuidString,
        ] as [String: Any], options: [.sortedKeys])
        XCTAssertEqual(parseReply(unknown), .malformed(.replyMalformed))
    }

    func testOwnershipReadParseIsStrictAndFailClosed() {
        func parse(_ object: [String: Any]) -> G04TerminalFirstUseOwnershipQuery.Answer {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return G04TerminalFirstUseOwnershipQuery.parse(
                data, maximumFrameBytes: LinuxShellMailboxLimits.maximumFrameBytes,
                operationID: operationID, uiRunID: uiRunID,
                conversationID: conversationID, queryEpoch: 3)
        }
        // BOTH answers require exact identity + ENTRY epoch correlation. A
        // bare released/owned frame is not physical evidence for this request.
        let released = ["status": "released", "rootEpoch": 9, "queryEpoch": 3,
                        "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
                        "conversationID": conversationID.uuidString] as [String: Any]
        XCTAssertEqual(parse(released), .released)
        XCTAssertEqual(parse(["status": "released", "rootEpoch": 9]), .unobservable)
        XCTAssertEqual(parse(["status": "owned", "rootEpoch": 9]), .unobservable)
        XCTAssertEqual(parse(["status": "owned", "rootEpoch": 9, "queryEpoch": 3,
                              "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
                              "conversationID": conversationID.uuidString]), .owned)
        XCTAssertEqual(parse(["status": "owned", "rootEpoch": 9, "queryEpoch": 4,
                              "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
                              "conversationID": conversationID.uuidString]), .unobservable)
        XCTAssertEqual(parse(["status": "owned", "rootEpoch": 9, "queryEpoch": 3,
                              "operationID": UUID().uuidString, "uiRunID": uiRunID.uuidString,
                              "conversationID": conversationID.uuidString]), .unobservable)
        var foreignReleased = released
        foreignReleased["operationID"] = UUID().uuidString
        XCTAssertEqual(parse(foreignReleased), .unobservable)
        // A cancelled/refused/garbage answer is never a release.
        XCTAssertEqual(parse(["status": "cancelled", "rootEpoch": 9]), .unobservable)
        XCTAssertEqual(parse(["status": "unavailable", "rootEpoch": 9, "reason": "request_invalid"]),
                       .unobservable)
        XCTAssertEqual(parse(["rootEpoch": 9]), .unobservable)
    }

    // MARK: Pure release rule

    func testOnlyProvenPhysicalEndReleases() {
        typealias Rule = G04TerminalFirstUseReleaseRule
        // Nothing was ever submitted, or the ticket was retired before any host
        // claim: provably no host ownership.
        XCTAssertEqual(Rule.decision(settlement: nil, hostOwnershipReleased: false), .releaseNow)
        XCTAssertEqual(Rule.decision(settlement: .retiredUnclaimed, hostOwnershipReleased: false),
                       .releaseNow)
        // A completed claim releases ONLY on the host's own asserted fact.
        XCTAssertEqual(Rule.decision(settlement: .hostSettled, hostOwnershipReleased: true), .releaseNow)
        XCTAssertEqual(Rule.decision(settlement: .hostSettled, hostOwnershipReleased: false),
                       .retainAndObserve)
        // Everything else retains, whatever the reply said.
        for state in [LinuxShellMailboxRequest.Settlement.live, .generationFenced, .unknown] {
            XCTAssertEqual(Rule.decision(settlement: state, hostOwnershipReleased: false),
                           .retainAndObserve, "state \(state) must retain")
            XCTAssertEqual(Rule.decision(settlement: state, hostOwnershipReleased: true),
                           .retainAndObserve, "state \(state) must retain even with a fact")
        }
    }

    // MARK: Caller admission (hard refusal)

    private func outcome(_ code: G04TerminalFirstUseCode?, _ kind: G04TerminalFirstUse.Outcome.Kind,
                         detail: String? = nil) -> G04TerminalFirstUse.Outcome {
        G04TerminalFirstUse.Outcome(kind: kind, code: code, detail: detail,
                                    request: nil, hostOwnershipReleased: false)
    }

    func testCancelledOrFencedPreparationIsAHardRefusalEvenWhenGlobalBecomesQualified() {
        // Main review 2026-10-28: a concurrent model run may qualify the lane
        // while THIS action's lease was cancelled or its generation moved. The
        // global truth must NOT override the typed refusal, or the terminal
        // would open late on an identity this action no longer owns.
        for code in [G04TerminalFirstUseCode.leaseCancelled, .generationMoved] {
            let refused = outcome(code, .refused)
            XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(outcome: refused,
                                                               capabilityQualified: true),
                           .refuse(.retired, token: code.rawValue))
            XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(outcome: refused,
                                                               capabilityQualified: false),
                           .refuse(.retired, token: code.rawValue))
        }
        // A budget expiry keeps the claimed ticket owned and still refuses.
        XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(outcome: outcome(.budgetExpired, .refused),
                                                           capabilityQualified: true),
                       .refuse(.engineUnqualified, token: "budgetExpired"))
        // A genuine binding failure maps onto the ORIGINAL unbound truth.
        XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(outcome: outcome(.workspaceBindingFailed, .refused),
                                                           capabilityQualified: true),
                       .refuse(.workspaceUnbound, token: "workspaceBindingFailed"))
        // A host refusal keeps the host's own bounded token visible.
        XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(
            outcome: outcome(.hostUnavailable, .refused, detail: "mapping_unsynced"),
            capabilityQualified: true),
            .refuse(.engineUnqualified, token: "mapping_unsynced"))
    }

    func testOnlyOwnLiveQualificationProceeds() {
        XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(outcome: outcome(nil, .qualified),
                                                           capabilityQualified: true), .proceed)
        // Defensive second read: a lane that went unqualified again never opens.
        XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(outcome: outcome(nil, .qualified),
                                                           capabilityQualified: false),
                       .refuse(.engineUnqualified, token: "unqualifiedAfterPreflight"))
        XCTAssertEqual(G04TerminalFirstUseAdmission.verdict(
            outcome: outcome(nil, .skippedAlreadyQualified), capabilityQualified: true), .proceed)
    }

    // MARK: The executor (injected seams; real defaults untouched)

    /// A mailbox bound to `epoch` plus a scripted fake host that claims the
    /// next ticket and settles it with `frame` — the REAL mailbox lifecycle,
    /// no JNI.
    private func makeMailboxWithFakeHost(epoch: UInt64 = 7, status: Int32 = 0, frame: Data)
        -> (LinuxShellMailbox, Task<Void, Never>) {
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: epoch))
        let host = Task.detached {
            let claim = mailbox.nextClaim(timeoutMillis: 5_000)
            guard claim > 0 else { return }
            _ = frame.withUnsafeBytes { raw in
                mailbox.complete(claim: claim, status: status,
                                 value: raw.bindMemory(to: UInt8.self).baseAddress,
                                 valueLen: Int32(frame.count))
            }
        }
        return (mailbox, host)
    }

    func testWarmExecutorSubmitsNothing() async {
        let begins = FirstUseReleaseCounter()
        let result = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 7 }, readiness: { .skipAlreadyQualified },
            beginRequest: { _, _ in begins.increment(); throw LinuxShellTransportError.notBound },
            awaitReply: { _, _ in Data() },
            ownStateQualified: { true })
        XCTAssertEqual(result.kind, .skippedAlreadyQualified)
        XCTAssertEqual(begins.value, 0)                     // no redundant import
        XCTAssertTrue(result.isReady)
        XCTAssertNil(result.request)
        XCTAssertEqual(result.releaseDecision, .releaseNow)  // nothing was ever owned
    }

    func testPrerequisiteAndGenerationRefusalsSubmitNothing() async {
        let begins = FirstUseReleaseCounter()
        let refusing: @Sendable (String, Data) throws -> LinuxShellMailboxRequest = { _, _ in
            begins.increment(); throw LinuxShellTransportError.notBound
        }
        let noPrerequisites = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 7 }, readiness: { .refuse(.prerequisitesUnverified) },
            beginRequest: refusing, awaitReply: { _, _ in Data() }, ownStateQualified: { true })
        XCTAssertEqual(noPrerequisites.code, .prerequisitesUnverified)
        let wrongGeneration = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 8 }, readiness: { .prepare },
            beginRequest: refusing, awaitReply: { _, _ in Data() }, ownStateQualified: { true })
        XCTAssertEqual(wrongGeneration.code, .epochNotLive)
        let zeroEpoch = await G04TerminalFirstUse.prepare(
            epoch: 0, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 0 }, readiness: { .prepare },
            beginRequest: refusing, awaitReply: { _, _ in Data() }, ownStateQualified: { true })
        XCTAssertEqual(zeroEpoch.code, .epochNotLive)
        XCTAssertEqual(begins.value, 0)
    }

    func testReadyEchoAloneNeverQualifies() async {
        let (mailbox, host) = makeMailboxWithFakeHost(frame: readyFrame())
        let seen = FirstUseSeenBox()
        let unqualified = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 7 }, readiness: { .prepare },
            beginRequest: { operation, payload in
                seen.recordOperation(operation)
                // The submitted bytes are the closed request itself.
                let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
                XCTAssertEqual(object?["operationID"] as? String, operationID.uuidString)
                XCTAssertEqual(object?["uiRunID"] as? String, uiRunID.uuidString)
                XCTAssertEqual((object?["rootEpoch"] as? NSNumber)?.uint64Value, 7)
                XCTAssertNil(object?["runID"])
                return try mailbox.beginRequest(operation: operation, payload: payload)
            },
            awaitReply: { request, budget in
                seen.recordBudget(budget)
                return try await mailbox.awaitReply(request, timeoutMillis: budget)
            },
            ownStateQualified: { false })
        await host.value
        XCTAssertEqual(seen.seenOperation, "host.terminalWorkspacePreflight")
        XCTAssertEqual(seen.seenBudget, G04TerminalFirstUse.preflightBudgetMillis)
        XCTAssertEqual(unqualified.code, .unqualifiedAfterPreflight)
        XCTAssertFalse(unqualified.isReady)
        // The claim really settled and the host asserted the release, so this
        // refusal discharges the lease instead of leaking it.
        XCTAssertEqual(unqualified.releaseDecision, .releaseNow)
        mailbox.close()
    }

    func testQualifiedPathReadsOwnLiveStateAndDischargesOwnership() async {
        let (mailbox, host) = makeMailboxWithFakeHost(frame: readyFrame())
        let result = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 7 }, readiness: { .prepare },
            beginRequest: { try mailbox.beginRequest(operation: $0, payload: $1) },
            awaitReply: { try await mailbox.awaitReply($0, timeoutMillis: $1) },
            ownStateQualified: { true })
        await host.value
        XCTAssertEqual(result.kind, .qualified)
        XCTAssertTrue(result.hostOwnershipReleased)
        XCTAssertEqual(result.releaseDecision, .releaseNow)
        mailbox.close()
    }

    func testEnqueueFailuresCarryNoOwnershipAndWaitFailuresKeepTheTicket() async {
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        // Enqueue-stage refusals: no ticket exists, so nothing can be owned.
        let unbound = LinuxShellMailbox()                  // never bound
        let notBound = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 7 }, readiness: { .prepare },
            beginRequest: { try unbound.beginRequest(operation: $0, payload: $1) },
            awaitReply: { try await unbound.awaitReply($0, timeoutMillis: $1) },
            ownStateQualified: { true })
        XCTAssertEqual(notBound.code, .engineUnbound)
        XCTAssertNil(notBound.request)
        XCTAssertEqual(notBound.releaseDecision, .releaseNow)

        // Wait-stage failure with a CLAIMED ticket: the handle must survive the
        // throw, or the lease would be detached while real IO is in flight.
        let request = try! mailbox.beginRequest(operation: G04TerminalFirstUseRequest.operation,
                                               payload: Data("{}".utf8))
        let waiter = Task { try? await mailbox.awaitReply(request, timeoutMillis: 60_000) }
        var claim: Int64 = 0
        var waited = 0
        while claim == 0 && waited < 4_000 {
            claim = mailbox.nextClaim(timeoutMillis: 20)
            waited += 25
            if claim == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertGreaterThan(claim, 0)
        waiter.cancel()
        _ = await waiter.value
        let expired = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 7 }, readiness: { .prepare },
            beginRequest: { _, _ in request },
            awaitReply: { _, _ in throw LinuxShellTransportError.waitBudgetExpired },
            ownStateQualified: { true })
        XCTAssertEqual(expired.code, .budgetExpired)
        XCTAssertNotNil(expired.request)
        XCTAssertEqual(expired.releaseDecision, .retainAndObserve)
        mailbox.close()
    }

    func testTransportFailureMapping() async {
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        let request = try! mailbox.beginRequest(operation: G04TerminalFirstUseRequest.operation,
                                               payload: Data("{}".utf8))
        let cases: [(LinuxShellTransportError, G04TerminalFirstUseCode)] = [
            (.hostFenced, .engineFenced),
            (.waitBudgetExpired, .budgetExpired),
            (.replyMalformed, .replyMalformed),
            (.remoteFailed(code: "runtime_unavailable"), .hostUnavailable),
            (.saturated, .mailboxSaturated),
            (.payloadTooLarge, .payloadTooLarge),
        ]
        for (error, expected) in cases {
            let result = await G04TerminalFirstUse.prepare(
                epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
                liveEpoch: { 7 }, readiness: { .prepare },
                beginRequest: { _, _ in request },
                awaitReply: { _, _ in throw error },
                ownStateQualified: { true })
            XCTAssertEqual(result.code, expected, "mapping for \(error)")
            XCTAssertFalse(result.isReady)
            // The ticket exists, so ownership stays observable and retained.
            // (This fake seam leaves it queued; the production waiter-release
            // path retires a queued ticket, which then releases immediately.)
            XCTAssertNotNil(result.request)
            XCTAssertEqual(result.releaseDecision, .retainAndObserve)
        }
        mailbox.close()
    }

    // MARK: REAL mailbox physical-settlement boundary

    func testUncertainHostAnswerWhileIoIsLiveRetainsUntilObservedRelease() async throws {
        // The exact production boundary Main named: the host answers
        // unavailable / close_retained (so the claim is COMPLETED) while its own
        // reconciliation still owns real import/export IO. Driven through the
        // REAL executor seams over a REAL mailbox, so the outcome's request
        // handle and physical-ownership fact are the production values.
        let frame = unavailableFrame(reason: "close_retained", ownershipReleased: false)
        let (mailbox, host) = makeMailboxWithFakeHost(frame: frame)
        let counter = FirstUseReleaseCounter()
        let result = await G04TerminalFirstUse.prepare(
            epoch: 7, conversationID: conversationID, operationID: operationID, uiRunID: uiRunID,
            liveEpoch: { 7 }, readiness: { .prepare },
            beginRequest: { try mailbox.beginRequest(operation: $0, payload: $1) },
            awaitReply: { try await mailbox.awaitReply($0, timeoutMillis: $1) },
            ownStateQualified: { true })
        await host.value
        XCTAssertEqual(result.code, .hostUnavailable)
        XCTAssertEqual(result.detail, "close_retained")
        XCTAssertFalse(result.hostOwnershipReleased)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.settlement, .hostSettled)     // the claim completed…
        XCTAssertEqual(result.releaseDecision, .retainAndObserve)

        let ownership = G04TerminalFirstUseOwnership(
            request: request,
            hostOwnershipReleased: result.hostOwnershipReleased) {
            counter.increment()
        }
        // …but physical IO is NOT proven finished, so the lease stays attached.
        XCTAssertTrue(ownership.mustRetain)
        XCTAssertEqual(ownership.decision, .retainAndObserve)
        XCTAssertEqual(counter.value, 0)

        // An "owned" observation keeps it; a cancelled waiter keeps it too.
        let retention = Task {
            await ownership.settleByObservation(pollMillis: 5) { .owned }
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(counter.value, 0)
        retention.cancel()
        _ = await retention.value
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(ownership.mustRetain)

        // The host's own table reporting this exact identity released is the
        // ONLY discharge, and it happens exactly once.
        let observed = await ownership.settleByObservation(pollMillis: 5) { .released }
        XCTAssertEqual(observed, .released)
        XCTAssertEqual(counter.value, 1)
        let repeatReleaseAfterObservedDischarge = await ownership.releaseOnce()
        XCTAssertFalse(repeatReleaseAfterObservedDischarge)
        XCTAssertEqual(counter.value, 1)
        mailbox.close()
    }

    func testClaimedTicketSurvivesAReleasedWaiterAndReleasesExactlyOnce() async throws {
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        let counter = FirstUseReleaseCounter()
        let request = try mailbox.beginRequest(operation: G04TerminalFirstUseRequest.operation,
                                              payload: Data("{}".utf8))
        let ownership = G04TerminalFirstUseOwnership(request: request, hostOwnershipReleased: false) {
            counter.increment()
        }
        let waiter = Task { try? await mailbox.awaitReply(request, timeoutMillis: 60_000) }
        var claim: Int64 = 0
        var waited = 0
        while claim == 0 && waited < 4_000 {
            claim = mailbox.nextClaim(timeoutMillis: 20)
            waited += 25
            if claim == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertGreaterThan(claim, 0)
        waiter.cancel()
        _ = await waiter.value
        // WAITER completion is NOT settlement.
        XCTAssertEqual(request.settlement, .live)
        XCTAssertTrue(ownership.mustRetain)
        let settledWhileClaimLive = await request.awaitSettled(timeoutMillis: 120)
        XCTAssertFalse(settledWhileClaimLive)
        XCTAssertEqual(counter.value, 0)
        // The exact pre-registration race: even an exact `released` table
        // answer cannot release while the ORIGINAL claim is still live and no
        // `owned` entry was ever observed. Empty can mean "not registered yet".
        let prematureAbsence = Task {
            await ownership.settleByObservation(pollMillis: 5) { .released }
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        prematureAbsence.cancel()
        let prematureAbsenceOutcome = await prematureAbsence.value
        XCTAssertEqual(prematureAbsenceOutcome, .unobservable)
        XCTAssertEqual(counter.value, 0)
        // The host later really settles the claim. Without its asserted
        // physical fact (this waiter was released before any reply) the lease
        // STILL retains — a completed claim alone is not settlement — and only
        // the observed host release discharges it, exactly once.
        let frame = readyFrame()
        XCTAssertEqual(frame.withUnsafeBytes { raw in
            mailbox.complete(claim: claim, status: 0,
                             value: raw.bindMemory(to: UInt8.self).baseAddress,
                             valueLen: Int32(frame.count))
        }, 0)
        XCTAssertEqual(request.settlement, .hostSettled)
        XCTAssertTrue(ownership.mustRetain)
        // Sticky per-handle host completion survives bounded-ring/table reset;
        // physical release still needs the host's OWN observed discharge.
        mailbox.resetForRebind()
        XCTAssertEqual(request.settlement, .hostSettled)
        let observedReleaseAfterReset = await ownership.settleByObservation(pollMillis: 5) { .released }
        XCTAssertEqual(observedReleaseAfterReset, .released)
        XCTAssertEqual(counter.value, 1)
        let repeatReleaseAfterSettledDischarge = await ownership.releaseOnce()
        XCTAssertFalse(repeatReleaseAfterSettledDischarge)
        XCTAssertEqual(counter.value, 1)
        mailbox.close()
    }

    func testGenerationFenceWhileClaimedRetains() async throws {
        // `close()` drops claimed tickets, and the ORIGINAL fence contract says
        // owned workers are NOT ended and remote leases stay owned until real
        // release. So a fence must NOT discharge the lease.
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        let counter = FirstUseReleaseCounter()
        let request = try mailbox.beginRequest(operation: G04TerminalFirstUseRequest.operation,
                                              payload: Data("{}".utf8))
        let waiter = Task { try? await mailbox.awaitReply(request, timeoutMillis: 60_000) }
        var claim: Int64 = 0
        var waited = 0
        while claim == 0 && waited < 4_000 {
            claim = mailbox.nextClaim(timeoutMillis: 20)
            waited += 25
            if claim == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertGreaterThan(claim, 0)
        mailbox.close()
        _ = await waiter.value
        XCTAssertEqual(request.settlement, .generationFenced)
        let ownership = G04TerminalFirstUseOwnership(request: request, hostOwnershipReleased: false) {
            counter.increment()
        }
        XCTAssertTrue(ownership.mustRetain)
        let retention = Task { await ownership.settleByObservation(pollMillis: 5) { .unobservable } }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(counter.value, 0, "a fence is not settlement")
        retention.cancel()
        _ = await retention.value
        XCTAssertEqual(counter.value, 0)
        // Even after a fence, an empty table alone can still be the original
        // request's pre-registration state; it must not release.
        let emptyAbsence = Task { await ownership.settleByObservation(pollMillis: 5) { .released } }
        try await Task.sleep(nanoseconds: 60_000_000)
        emptyAbsence.cancel()
        _ = await emptyAbsence.value
        XCTAssertEqual(counter.value, 0)
        // The host first proves this exact entry really existed, then its
        // drained removal is positive same-entry physical-settlement evidence.
        let ownedObservation = Task { await ownership.settleByObservation(pollMillis: 5) { .owned } }
        try await Task.sleep(nanoseconds: 60_000_000)
        ownedObservation.cancel()
        _ = await ownedObservation.value
        XCTAssertEqual(counter.value, 0)
        let releasedAfterOwnedProof = await ownership.settleByObservation(pollMillis: 5) { .released }
        XCTAssertEqual(releasedAfterOwnedProof, .released)
        XCTAssertEqual(counter.value, 1)
    }

    func testUnclaimedRetirementReleasesImmediately() async throws {
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        let counter = FirstUseReleaseCounter()
        let request = try mailbox.beginRequest(operation: G04TerminalFirstUseRequest.operation,
                                              payload: Data("{}".utf8))
        let ownership = G04TerminalFirstUseOwnership(request: request, hostOwnershipReleased: false) {
            counter.increment()
        }
        // Budget expiry while still QUEUED: provably never dispatched.
        do { _ = try await mailbox.awaitReply(request, timeoutMillis: 30) } catch { }
        XCTAssertEqual(request.settlement, .retiredUnclaimed)
        XCTAssertFalse(ownership.mustRetain)
        let releasedWithoutClaim = await ownership.settleByObservation(pollMillis: 5) { .unobservable }
        XCTAssertEqual(releasedWithoutClaim, .released)
        XCTAssertEqual(counter.value, 1)
        let repeatReleaseAfterImmediateDischarge = await ownership.releaseOnce()
        XCTAssertFalse(repeatReleaseAfterImmediateDischarge)
        XCTAssertEqual(counter.value, 1)
        mailbox.close()
    }

    func testOwnershipWithoutARequestNeverRetains() async {
        let counter = FirstUseReleaseCounter()
        let ownership = G04TerminalFirstUseOwnership(request: nil, hostOwnershipReleased: false) {
            counter.increment()
        }
        XCTAssertFalse(ownership.mustRetain)
        let firstRelease = await ownership.releaseOnce()
        XCTAssertTrue(firstRelease)
        XCTAssertEqual(counter.value, 1)
        let secondRelease = await ownership.releaseOnce()
        XCTAssertFalse(secondRelease)
        XCTAssertEqual(counter.value, 1)
    }

    func testObserveOwnershipUsesTheRealParserAndFailsClosed() async throws {
        let released = try JSONSerialization.data(withJSONObject: [
            "status": "released", "rootEpoch": 9, "queryEpoch": 7,
            "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
            "conversationID": conversationID.uuidString,
        ] as [String: Any], options: [.sortedKeys])
        let owned = try JSONSerialization.data(withJSONObject: [
            "status": "owned", "rootEpoch": 9, "queryEpoch": 7,
            "operationID": operationID.uuidString, "uiRunID": uiRunID.uuidString,
            "conversationID": conversationID.uuidString,
        ] as [String: Any], options: [.sortedKeys])
        let foreign = try JSONSerialization.data(withJSONObject: [
            "status": "owned", "rootEpoch": 9, "queryEpoch": 7,
            "operationID": UUID().uuidString, "uiRunID": uiRunID.uuidString,
            "conversationID": conversationID.uuidString,
        ] as [String: Any], options: [.sortedKeys])
        let box = ObservationBox()
        func submitter(_ frame: Data) -> @Sendable (String, Data, Int) async throws -> Data {
            { operation, payload, budget in
                box.record(operation, payload, budget)
                return frame
            }
        }
        let releasedAnswer = await G04TerminalFirstUse.observeOwnership(
            operationID: operationID, uiRunID: uiRunID, conversationID: conversationID,
            queryEpoch: 7, submit: submitter(released))
        XCTAssertEqual(releasedAnswer, .released)
        let seen = try XCTUnwrap(box.last)
        XCTAssertEqual(seen.operation, "host.terminalPreflightOwnership")
        XCTAssertEqual(seen.budget, G04TerminalFirstUse.ownershipQueryBudgetMillis)
        // The query carries the ENTRY epoch (not the live one) and the exact
        // identity; it never carries a command, a path or an environment.
        let object = try XCTUnwrap(
            try? JSONSerialization.jsonObject(with: seen.payload) as? [String: Any])
        XCTAssertEqual((object["rootEpoch"] as? NSNumber)?.uint64Value, 7)
        XCTAssertEqual(object["operationID"] as? String, operationID.uuidString)
        XCTAssertEqual(object["uiRunID"] as? String, uiRunID.uuidString)
        XCTAssertEqual(object["conversationID"] as? String, conversationID.uuidString)
        XCTAssertEqual(object.keys.count, 4)
        let ownedAnswer = await G04TerminalFirstUse.observeOwnership(
            operationID: operationID, uiRunID: uiRunID, conversationID: conversationID,
            queryEpoch: 7, submit: submitter(owned))
        XCTAssertEqual(ownedAnswer, .owned)
        // A foreign identity echo is never a truth about THIS preparation.
        let foreignAnswer = await G04TerminalFirstUse.observeOwnership(
            operationID: operationID, uiRunID: uiRunID, conversationID: conversationID,
            queryEpoch: 7, submit: submitter(foreign))
        XCTAssertEqual(foreignAnswer, .unobservable)
        // A thrown transport error is unobservable, i.e. retain.
        let thrownAnswer = await G04TerminalFirstUse.observeOwnership(
            operationID: operationID, uiRunID: uiRunID, conversationID: conversationID,
            queryEpoch: 7, submit: { _, _, _ in throw LinuxShellTransportError.notBound })
        XCTAssertEqual(thrownAnswer, .unobservable)
        // An unusable identity produces no request at all and stays retained.
        let staleEpochAnswer = await G04TerminalFirstUse.observeOwnership(
            operationID: operationID, uiRunID: uiRunID, conversationID: conversationID,
            queryEpoch: 0, submit: submitter(released))
        XCTAssertEqual(staleEpochAnswer, .unobservable)
    }

    // MARK: ORIGINAL stop/drain ownership boundary

    func testOriginalDrainWaitsForFirstEntryReceiptUntilPhysicalObservationReleases() async throws {
        let bindings = RuntimeFacadeLinuxBindings()
        let mailbox = LinuxShellMailbox()
        XCTAssertTrue(mailbox.bind(epoch: 7))
        // Production registers this guard immediately after operation
        // registration, BEFORE any SQLite/host await can complete.
        bindings.retainFirstEntryOwnership(operationID)
        let payload = try XCTUnwrap(G04TerminalFirstUseRequest.payload(
            operationID: operationID, uiRunID: uiRunID,
            conversationID: conversationID, rootEpoch: 7))
        let request = try mailbox.beginRequest(
            operation: G04TerminalFirstUseRequest.operation, payload: payload)
        let waiter = Task { try? await mailbox.awaitReply(request, timeoutMillis: 60_000) }
        var claim: Int64 = 0
        var waited = 0
        while claim == 0 && waited < 4_000 {
            claim = mailbox.nextClaim(timeoutMillis: 20)
            waited += 25
            if claim == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertGreaterThan(claim, 0)
        let drainedWhileTicketClaimed = await bindings.isDrained(mailbox: mailbox)
        XCTAssertFalse(drainedWhileTicketClaimed)
        // Host answers close_retained: the MAILBOX claim completes, but the
        // pump still owns its real reconciliation. This is not physical end.
        let frame = unavailableFrame(reason: "close_retained", ownershipReleased: false)
        XCTAssertEqual(frame.withUnsafeBytes { raw in
            mailbox.complete(claim: claim, status: 0,
                             value: raw.bindMemory(to: UInt8.self).baseAddress,
                             valueLen: Int32(frame.count))
        }, 0)
        _ = await waiter.value
        XCTAssertEqual(request.settlement, .hostSettled)
        let counter = FirstUseReleaseCounter()
        let ownership = G04TerminalFirstUseOwnership(
            request: request, hostOwnershipReleased: false) {
            counter.increment()
            bindings.releaseFirstEntryOwnership(operationID)
        }
        // No mailbox ticket remains, yet the ORIGINAL drain still sees the
        // exact retained conversation receipt and may NOT fence the channel.
        let drainedWhileReceiptRetained = await bindings.isDrained(mailbox: mailbox)
        XCTAssertFalse(drainedWhileReceiptRetained)
        let retained = Task { await ownership.settleByObservation(pollMillis: 5) { .owned } }
        try await Task.sleep(nanoseconds: 60_000_000)
        retained.cancel()
        let retainedObservationOutcome = await retained.value
        XCTAssertEqual(retainedObservationOutcome, .unobservable)
        XCTAssertEqual(counter.value, 0)
        let drainedDuringObservation = await bindings.isDrained(mailbox: mailbox)
        XCTAssertFalse(drainedDuringObservation)
        // Real same-entry drained removal releases the operation receipt once;
        // only NOW can the original drain/fence finish and close observation.
        let observedPhysicalRelease = await ownership.settleByObservation(pollMillis: 5) { .released }
        XCTAssertEqual(observedPhysicalRelease, .released)
        XCTAssertEqual(counter.value, 1)
        let drainedAfterRelease = await bindings.isDrained(mailbox: mailbox)
        XCTAssertTrue(drainedAfterRelease)
        let repeatReleaseAfterDrainDischarge = await ownership.releaseOnce()
        XCTAssertFalse(repeatReleaseAfterDrainDischarge)
        XCTAssertEqual(counter.value, 1)
        mailbox.close()
    }

    // MARK: Genuine persisted binding producer (real migrated stores)

    func testFreshOrdinaryTaskGetsTheCanonicalPrivateTaskBindingRunLess() async throws {
        let stores = try await PrivacyTestBed.stores(name: "terminal-first-entry")
        let conversation = try await PrivacyTestBed.seedConversation(stores, title: "  Weekly report  ")
        // The actual fresh-task shape: an ordinary conversation row and ZERO
        // workspace/ownership rows (the production conversation store is built
        // with bindsNewConversationsToDefaultWorkspace = false).
        let ownershipRows = try await PrivacyTestBed.count(
            stores.database,
            "SELECT COUNT(*) FROM conversation_workspace_ownership WHERE conversation_id = ?",
            [conversation.uuidString])
        XCTAssertEqual(ownershipRows, 0)
        let workspaceIDBeforeEnsure = try await stores.workspaces.workspaceID(conversationID: conversation)
        XCTAssertNil(workspaceIDBeforeEnsure)

        // The SAME canonical operation the D14 workspace.activate command uses,
        // with this lane's own title projection. No run, no provider, no model.
        let ensured = try await stores.workspaces.ensureWorkspace(
            conversationID: conversation,
            title: G04TerminalFirstUse.canonicalWorkspaceTitle("  Weekly report  "))
        XCTAssertEqual(ensured.kind, .privateTask)
        XCTAssertEqual(ensured.internalRelativePath, "PrivateTasks/\(conversation.uuidString)")
        XCTAssertEqual(ensured.name, "Weekly report")
        let workspaceIDAfterEnsure = try await stores.workspaces.workspaceID(conversationID: conversation)
        XCTAssertEqual(workspaceIDAfterEnsure, ensured.id)
        let after = try await PrivacyTestBed.count(
            stores.database,
            "SELECT COUNT(*) FROM conversation_workspace_ownership WHERE conversation_id = ?",
            [conversation.uuidString])
        XCTAssertEqual(after, 1)

        // Idempotent: a second explicit action returns the SAME binding and
        // never re-points or renames it.
        let again = try await stores.workspaces.ensureWorkspace(conversationID: conversation,
                                                               title: "Something else")
        XCTAssertEqual(again.id, ensured.id)
        XCTAssertEqual(again.name, "Weekly report")
        let stillOne = try await PrivacyTestBed.count(
            stores.database,
            "SELECT COUNT(*) FROM conversation_workspace_ownership WHERE conversation_id = ?",
            [conversation.uuidString])
        XCTAssertEqual(stillOne, 1)
    }

    func testAMissingConversationRowWritesNothing() async throws {
        let stores = try await PrivacyTestBed.stores(name: "terminal-first-entry-missing")
        let workspacesBefore = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM workspaces")
        let missing = UUID()
        do {
            _ = try await stores.workspaces.ensureWorkspace(conversationID: missing, title: "x")
            XCTFail("a conversation that does not exist must not gain a workspace")
        } catch {
            // The store's own transaction rolled back: no row, no partial write.
        }
        let workspaceIDForMissing = try await stores.workspaces.workspaceID(conversationID: missing)
        XCTAssertNil(workspaceIDForMissing)
        let workspacesAfter = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM workspaces")
        XCTAssertEqual(workspacesAfter, workspacesBefore)
    }

    func testCanonicalTitleProjectionIsBoundedAndNeverInvented() {
        XCTAssertEqual(G04TerminalFirstUse.canonicalWorkspaceTitle("  Weekly report  "), "Weekly report")
        XCTAssertEqual(G04TerminalFirstUse.canonicalWorkspaceTitle("   "), "Chat")
        XCTAssertEqual(G04TerminalFirstUse.canonicalWorkspaceTitle(""), "Chat")
        let long = String(repeating: "a", count: 120)
        XCTAssertEqual(G04TerminalFirstUse.canonicalWorkspaceTitle(long),
                       String(repeating: "a", count: 80))
    }

    // MARK: Store-level fail-closed shape

    func testUnknownTaskIdentityPreparesNothingAndEmitsNothing() async {
        // No installed composition / no persisted row for a foreign identity:
        // the preparation is inert (`.proceed`), retains no ownership and emits
        // no control event, so the ORIGINAL admission produces its ORIGINAL
        // honest refusal instead of a newly invented one.
        let sink = FirstUseRecordingSink()
        let store = G04TerminalStore(epoch: 7, sink: sink)
        let verdict = await store.prepareFirstEntry(conversationID: UUID(), expectedWorkspaceID: nil)
        XCTAssertEqual(verdict, .proceed)
        let retained = await store.firstEntryRetentionCount
        XCTAssertEqual(retained, 0)
        XCTAssertEqual(sink.controlCount, 0)
    }
}
