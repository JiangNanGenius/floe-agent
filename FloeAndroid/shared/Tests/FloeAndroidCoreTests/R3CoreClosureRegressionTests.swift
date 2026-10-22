// SPDX-License-Identifier: MPL-2.0
//
// G03-R3 core-closure regression SOURCE (job-3d39b56695c44bd2).
// AUTHORED for the R3 lifecycle repair; the combined qualification compiles
// and executes it later (this lane holds no build authority). Every fixture
// root is synthetic and test-owned; no device, network, model or provider
// call is involved. The assertions exercise the REAL production types and
// ORIGINAL contracts (lane, ingress, authority, cleanup lifecycle) — no
// duplicated fake implementation stands in as the code under test.
//
// Covered failure sequences (Main reviews 2026-10-22):
//  * purge/retry: recovered/ orphan rediscovered ONLY through the durable
//    tombstone ledger with proven ownership; live grants preserved; the
//    ledger (and the durable V36 row) survives until the REAL runtime ACK;
//    truncation/overflow NEVER reports completed; nil readback refuses;
//  * readiness: no-live-authority refusal (absence is never authority),
//    late re-ingress after an admission suspend refused, closed mailbox
//    refused at ingestion, peer facts cannot mix binders, the mapping fact
//    must read back from the engine tree under the CURRENT epoch, and the
//    whole qualification flips false -> real-ingested -> false on loss;
//  * lane: enqueue-before-bind, dedup idempotence, malformed/scope-mismatch/
//    self-UID receipts refuse and RETAIN, generation rebind re-queues
//    claimed work, late settlement under a stale claim is refused;
//  * lifecycle: the V36 row retains until BOTH halves settle, then closes
//    the tombstone through the SAME owned sequence.
import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import FloeCore
import FloePersistence
import FloeAndroidShellTools
import FloeAndroidWorkspaceTools
@testable import FloeAndroidCore

// MARK: - shared lane helpers

private func cleanupJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func lanePayload(_ lane: LinuxRuntimeCleanupLane, claim: Int64) -> Data? {
    let length = lane.payloadLength(claim: claim)
    guard length > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(length))
    let taken = buffer.withUnsafeMutableBufferPointer { ptr in
        lane.takePayload(claim: claim, buffer: ptr.baseAddress, capacity: Int32(ptr.count))
    }
    guard taken == length else { return nil }
    return Data(buffer)
}

private func laneDescribe(_ lane: LinuxRuntimeCleanupLane, claim: Int64) -> [String: Any]? {
    var buffer = [CChar](repeating: 0, count: 8_192)
    let n = buffer.withUnsafeMutableBufferPointer { ptr in
        lane.describe(claim: claim, buffer: ptr.baseAddress, capacity: Int32(ptr.count))
    }
    guard n > 0 else { return nil }
    let data = Data(bytes: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, count: Int(n))
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func laneComplete(_ lane: LinuxRuntimeCleanupLane, claim: Int64,
                          receipt: Data) -> [String: Any]? {
    var buffer = [CChar](repeating: 0, count: 65_536)
    let n = receipt.withUnsafeBytes { raw in
        buffer.withUnsafeMutableBufferPointer { ptr in
            lane.complete(claim: claim, receipt: Data(bytes: raw.baseAddress!, count: raw.count),
                          buffer: ptr.baseAddress, capacity: Int32(ptr.count))
        }
    }
    guard n > 0 else { return nil }
    let data = Data(bytes: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, count: Int(n))
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

/// A cleared receipt echoing the claimed scope exactly (requestID from
/// describe, the rest from the payload), with optional field overrides.
private func clearedReceipt(requestID: String, payload: Data, uid: Int32? = nil,
                            overwrite: [String: Any] = [:]) -> Data {
    let scope = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
    var receipt: [String: Any] = [
        "requestID": requestID,
        "conversationID": scope["conversationID"] as? String ?? "",
        "projectID": scope["projectID"] as? String ?? "",
        "targetEpoch": scope["targetEpoch"] ?? 1,
        "outcome": "cleared",
        "runtimeUID": Int(uid ?? Int32(getuid()) + 1),
        "certificateDigest": String(repeating: "c", count: 64),
        "packageVersion": "0.1.0-test",
        "binderIdentity": "peer-binder-1",
        "executorProofDigest": String(repeating: "e", count: 64),
        "pathsRemoved": 2,
        "bytesFreed": 4_096,
    ]
    for (key, value) in overwrite { receipt[key] = value }
    return cleanupJSON(receipt)
}

private func refusedReceipt(requestID: String, payload: Data, reason: String) -> Data {
    let scope = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
    return cleanupJSON([
        "requestID": requestID,
        "conversationID": scope["conversationID"] as? String ?? "",
        "projectID": scope["projectID"] as? String ?? "",
        "targetEpoch": scope["targetEpoch"] ?? 1,
        "outcome": "refused", "reason": reason,
    ])
}

// MARK: - Lane

final class LinuxRuntimeCleanupLaneR3Tests: XCTestCase {

    private var lane: LinuxRuntimeCleanupLane { LinuxRuntimeCleanupLane.shared }

    override func setUp() {
        super.setUp()
        lane.resetForRebind()
    }

    override func tearDown() {
        lane.resetForRebind()
        super.tearDown()
    }

    private func makeScope(epoch: UInt64 = 7, conversationID: UUID = UUID(),
                           projectID: UUID = UUID()) -> LinuxRuntimeCleanupScope {
        LinuxRuntimeCleanupScope(conversationID: conversationID, projectID: projectID,
                                 targetEpoch: epoch,
                                 workspaceRelativePath: "PrivateTasks/\(conversationID.uuidString)",
                                 evidenceSessionKeys: [String(repeating: "b", count: 32)],
                                 evidenceTruncated: false, provenTotal: 1)
    }

    func testEnqueueWorksUnboundButClaimRequiresGeneration() {
        let id = lane.request(scope: makeScope())
        XCTAssertNotNil(id, "cleanup/proof channels stay available until real settlement (never stranded by unbound admission)")
        XCTAssertEqual(lane.nextClaim(timeoutMillis: 0), -1, "claiming without a bound generation must refuse, never fake")
        XCTAssertTrue(lane.bind(epoch: 9001))
        XCTAssertFalse(lane.bind(epoch: 9001), "same-epoch rebind stays refused (monotonic generation rule)")
        XCTAssertFalse(lane.bind(epoch: 1), "older epoch refused")
        let claim = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertTrue(lane.isLiveClaim(claim))
    }

    func testDedupIsIdempotentPerScope() {
        let scope = makeScope()
        let first = lane.request(scope: scope)
        let second = lane.request(scope: scope)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "a lifecycle retry must never double-queue the same proven scope")
        XCTAssertTrue(lane.bind(epoch: 9002))
        let claim = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(lane.nextClaim(timeoutMillis: 0), 0, "one claim per pending scope")
    }

    func testMalformedReceiptNeverSettlesAndClaimStands() {
        _ = lane.request(scope: makeScope())
        XCTAssertTrue(lane.bind(epoch: 9003))
        let claim = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(claim, 0)
        let reply = laneComplete(lane, claim: claim, receipt: Data("not json".utf8))
        XCTAssertEqual(reply?["code"] as? String, "receiptMalformed")
        XCTAssertTrue(lane.isLiveClaim(claim), "a malformed receipt may not release or settle the claim")
    }

    func testScopeMismatchRefusesAndRetainsForRetry() throws {
        let conversation = UUID()
        let project = UUID()
        _ = lane.request(scope: makeScope(conversationID: conversation, projectID: project))
        XCTAssertTrue(lane.bind(epoch: 9004))
        let claim = lane.nextClaim(timeoutMillis: 0)
        let described = try XCTUnwrap(laneDescribe(lane, claim: claim))
        let payload = try XCTUnwrap(lanePayload(lane, claim: claim))
        let requestID = try XCTUnwrap(described["requestID"] as? String)
        // Same requestID, FOREIGN project identity:
        let reply = laneComplete(lane, claim: claim,
                                 receipt: clearedReceipt(requestID: requestID, payload: payload,
                                                         overwrite: ["projectID": UUID().uuidString]))
        XCTAssertEqual(reply?["code"] as? String, "scopeMismatch")
        // Record RETAINED and re-queued: the same scope comes back claimable
        // with its ORIGINAL (target) project identity.
        let retried = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(retried, 0)
        let again = try XCTUnwrap(lanePayload(lane, claim: retried))
        let againJSON = (try? JSONSerialization.jsonObject(with: again) as? [String: Any]) ?? [:]
        XCTAssertEqual(againJSON["projectID"] as? String, project.uuidString)
    }

    func testClearedReceiptMustProveDistinctRuntimeUID() throws {
        _ = lane.request(scope: makeScope())
        XCTAssertTrue(lane.bind(epoch: 9005))
        let claim = lane.nextClaim(timeoutMillis: 0)
        let described = try XCTUnwrap(laneDescribe(lane, claim: claim))
        let payload = try XCTUnwrap(lanePayload(lane, claim: claim))
        let requestID = try XCTUnwrap(described["requestID"] as? String)
        let selfReply = laneComplete(lane, claim: claim,
                                     receipt: clearedReceipt(requestID: requestID, payload: payload,
                                                            uid: Int32(getuid())))
        XCTAssertEqual(selfReply?["code"] as? String, "identityNotDistinct",
                       "a receipt naming THIS process's UID cannot prove distinct-runtime-UID IO")
        XCTAssertFalse(lane.isSettledCleared(requestID: requestID))
        let good = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(good, 0, "the retained obligation re-queues for retry")
        let goodPayload = try XCTUnwrap(lanePayload(lane, claim: good))
        let okReply = laneComplete(lane, claim: good,
                                   receipt: clearedReceipt(requestID: requestID, payload: goodPayload))
        XCTAssertEqual(okReply?["state"] as? String, "cleared")
        XCTAssertTrue(lane.isSettledCleared(requestID: requestID))
        guard case .settled(let digest) = lane.state(requestID: requestID), !digest.isEmpty else {
            return XCTFail("the settled receipt must carry its read-back digest")
        }
    }

    func testRefusedReceiptKeepsObligationRetrying() throws {
        let id = try XCTUnwrap(lane.request(scope: makeScope()))
        XCTAssertTrue(lane.bind(epoch: 9006))
        let claim = lane.nextClaim(timeoutMillis: 0)
        let described = try XCTUnwrap(laneDescribe(lane, claim: claim))
        let payload = try XCTUnwrap(lanePayload(lane, claim: claim))
        let requestID = try XCTUnwrap(described["requestID"] as? String)
        _ = laneComplete(lane, claim: claim,
                         receipt: refusedReceipt(requestID: requestID, payload: payload, reason: "leaseBusy"))
        XCTAssertEqual(lane.state(requestID: id), .retrying(reason: "leaseBusy"))
        XCTAssertFalse(lane.isSettledCleared(requestID: id),
                       "a runtime refusal is NEVER a cleared workspace")
    }

    func testGenerationRebindRequeuesAndStaleClaimRefuses() throws {
        _ = lane.request(scope: makeScope())
        XCTAssertTrue(lane.bind(epoch: 9007))
        let claim = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(claim, 0)
        let described = try XCTUnwrap(laneDescribe(lane, claim: claim))
        let requestID = try XCTUnwrap(described["requestID"] as? String)
        // Host died with the Binder: the next generation binds; the claimed
        // record re-queues (nothing may assume the removal happened).
        XCTAssertTrue(lane.bind(epoch: 9008))
        XCTAssertEqual(lane.state(requestID: requestID), .queued,
                       "claimed work survives generation rebind as queued, never fabricated settled")
        let late = laneComplete(lane, claim: claim,
                                receipt: clearedReceipt(requestID: requestID,
                                                        payload: Data()))
        XCTAssertEqual(late?["code"] as? String, "staleClaim",
                       "a settlement under a dead claim token never fabricates completion")
        let fresh = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(fresh, 0, "and the obligation remains claimable")
    }

    func testBoundedQueueRejectsOverflow() throws {
        XCTAssertTrue(lane.bind(epoch: 9009))
        for _ in 0..<LinuxRuntimeCleanupLimits.maximumLiveRequests {
            XCTAssertNotNil(lane.request(scope: makeScope()), "unique scopes fill the bounded queue")
        }
        XCTAssertNil(lane.request(scope: makeScope()),
                     "the queue is bounded; saturation is a typed refusal (the caller retains)")
        let stats = (try? JSONSerialization.jsonObject(
            with: Data(lane.statsJSON().utf8)) as? [String: Any]) ?? [:]
        XCTAssertEqual(stats["rejectedSaturated"] as? Int, 1)
    }

    /// Main CLEANUP_CAPACITY_REVIEW (2026-10-22): the 64-slot ceiling bounds
    /// UNSETTLED obligations only. 65 sequential claim+cleared settlements
    /// must NEVER exhaust the lane, dedup keeps answering the settled scope
    /// with its ACK while the ring stands, and live pressure (claimed work)
    /// remains bounded exactly as before.
    func testSequentialSettlementsNeverExhaustTheLane() throws {
        XCTAssertTrue(lane.bind(epoch: 9010))
        for round in 0..<(LinuxRuntimeCleanupLimits.maximumLiveRequests + 1) {
            let scope = makeScope() // ONE fixed scope per round: request, settle, dedup
            guard let id = lane.request(scope: scope) else {
                return XCTFail("round \(round): a settled history must never block a NEW scope")
            }
            let claim = lane.nextClaim(timeoutMillis: 0)
            XCTAssertGreaterThan(claim, 0, "round \(round) claims its own request")
            guard let described = laneDescribe(lane, claim: claim),
                  let payload = lanePayload(lane, claim: claim),
                  let requestID = described["requestID"] as? String else {
                return XCTFail("round \(round) describe/payload")
            }
            XCTAssertEqual(requestID, id)
            let reply = laneComplete(lane, claim: claim,
                                     receipt: clearedReceipt(requestID: requestID, payload: payload))
            XCTAssertEqual(reply?["state"] as? String, "cleared", "round \(round) settles real")
            XCTAssertTrue(lane.isSettledCleared(requestID: requestID))
            // Dedup on the SAME settled scope keeps returning its ACK id while
            // the bounded proof ring stands (lifecycle retry idempotence).
            XCTAssertEqual(lane.request(scope: scope), id, "round \(round): settled scope dedups")
        }
        // Live pressure is still bounded: with everything settled there is no
        // unsettled work, yet 64 UNSETTLED scopes in one generation still
        // refuse the 65th until real settlement.
        XCTAssertTrue(lane.bind(epoch: 9011))
        for _ in 0..<LinuxRuntimeCleanupLimits.maximumLiveRequests {
            XCTAssertNotNil(lane.request(scope: makeScope()))
        }
        XCTAssertNil(lane.request(scope: makeScope()),
                     "unsettled obligations stay capped at the live bound")
        let stats = (try? JSONSerialization.jsonObject(
            with: Data(lane.statsJSON().utf8)) as? [String: Any]) ?? [:]
        XCTAssertEqual(stats["queued"] as? Int, LinuxRuntimeCleanupLimits.maximumLiveRequests,
                       "settled history left the LIVE table: only obligations are queued")
    }

    /// Object-compile repair strictness (job-65502159a2d44e93): receipt
    /// numbers must NEVER settle through a truncating/wrapping NSNumber
    /// bridge. An out-of-Int32 runtime UID (the historical `intValue` path
    /// folded 2^32+5 to 5 and could then PASS the distinctness cross-check
    /// with the WRONG peer identity), a boolean UID, and a non-integral
    /// targetEpoch all classify as malformed: nothing settles, the claim
    /// stands, and the same claim still settles with the honest in-range
    /// receipt afterwards.
    func testReceiptNumbersNeverSettleThroughTruncatingBridges() throws {
        _ = lane.request(scope: makeScope(epoch: 8))
        XCTAssertTrue(lane.bind(epoch: 9012))
        let claim = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(claim, 0)
        let described = try XCTUnwrap(laneDescribe(lane, claim: claim))
        let payload = try XCTUnwrap(lanePayload(lane, claim: claim))
        let requestID = try XCTUnwrap(described["requestID"] as? String)
        let overflow = Int64(UInt32.max) + 5   // == 5 under the old intValue bridge
        let overflowReply = laneComplete(lane, claim: claim,
                                         receipt: clearedReceipt(requestID: requestID, payload: payload,
                                                                 overwrite: ["runtimeUID": overflow]))
        XCTAssertEqual(overflowReply?["code"] as? String, "receiptMalformed",
                       "an out-of-range UID is malformed, never a truncated settlement")
        XCTAssertFalse(lane.isSettledCleared(requestID: requestID))
        let boolReply = laneComplete(lane, claim: claim,
                                     receipt: clearedReceipt(requestID: requestID, payload: payload,
                                                             overwrite: ["runtimeUID": true]))
        XCTAssertEqual(boolReply?["code"] as? String, "receiptMalformed",
                       "a boxed boolean never bridges to a numeric UID")
        let epochReply = laneComplete(lane, claim: claim,
                                      receipt: clearedReceipt(requestID: requestID, payload: payload,
                                                              overwrite: ["targetEpoch": 8.5]))
        XCTAssertEqual(epochReply?["code"] as? String, "receiptMalformed",
                       "a non-integral scope epoch never truncates into a match")
        let negReply = laneComplete(lane, claim: claim,
                                    receipt: clearedReceipt(requestID: requestID, payload: payload,
                                                            overwrite: ["targetEpoch": -1]))
        XCTAssertEqual(negReply?["code"] as? String, "receiptMalformed",
                       "a negative epoch never wraps into a positive settlement")
        XCTAssertTrue(lane.isLiveClaim(claim), "malformed receipts leave the claim standing")
        // Honest path unchanged: the real receipt settles on the same claim.
        let ok = laneComplete(lane, claim: claim,
                              receipt: clearedReceipt(requestID: requestID, payload: payload))
        XCTAssertEqual(ok?["state"] as? String, "cleared")
        XCTAssertTrue(lane.isSettledCleared(requestID: requestID))
    }
}

// MARK: - Readiness ingress

final class LinuxReadinessIngressR3Tests: XCTestCase {

    private var ingress: LinuxReadinessIngress { LinuxReadinessIngress.shared }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The mailbox-only authority shape requires no live bootstrap
        // generation in-process; host composition suites reset theirs.
        try XCTSkipIf(AndroidRuntimeBootstrap.currentPumps() != nil,
                      "bootstrap generation live in-process; mailbox-only authority not determinable")
        ingress.resetForTesting()
        LinuxWorkspaceAuthority.resetPurgeAuthoritiesForTesting()
    }

    override func tearDown() {
        ingress.resetForTesting()
        LinuxWorkspaceAuthority.resetPurgeAuthoritiesForTesting()
        LinuxRuntimeCleanupLane.shared.resetForRebind()
        LinuxShellMailbox.shared.close()
        super.tearDown()
    }

    private func bindFreshEpoch() -> UInt64 {
        let next = LinuxShellMailbox.shared.snapshotForTesting().epoch + 1
        XCTAssertTrue(LinuxShellMailbox.shared.bind(epoch: next))
        return next
    }

    private func rub(epoch: UInt64, binder: String = "peer-binder-1",
                     uid: Int32? = nil, cert: String? = nil) -> LinuxReadinessProof {
        .runtimeUidBoundary(runtimeUID: uid ?? Int32(getuid()) + 1,
                            certificateDigest: cert ?? String(repeating: "a", count: 64),
                            packageVersion: "0.1.0-test", binderIdentity: binder)
    }

    func testNoLiveAuthorityRefusesIngest() {
        // Force the no-authority state: mailbox closed (or epoch 0) with no
        // bootstrap readback => there is NO accepted generation. Absence of
        // conflict is not authority.
        LinuxShellMailbox.shared.close()
        let outcome = ingress.ingest(rub(epoch: 4242), rootEpoch: 4242)
        guard case .refused(let code) = outcome else {
            return XCTFail("no authority must positively refuse, got \(outcome)")
        }
        XCTAssertEqual(code, "noLiveAuthority")
        XCTAssertEqual(ingress.derivedFields(), LinuxShellQualificationFields(),
                       "nothing is ever qualified by default")
    }

    func testForeignEpochRefusedButLiveAccepted() {
        let epoch = bindFreshEpoch()
        guard case .refused(let stale) = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch &+ 1) else {
            return XCTFail("a nonzero epoch above the live authority must refuse")
        }
        XCTAssertEqual(stale, "epochNotLive")
        guard case .accepted = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("the live epoch must be positively accepted")
        }
    }

    func testLateIngressAfterSuspendRefusedResumeReopens() {
        let epoch = bindFreshEpoch()
        guard case .accepted = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("anchor first")
        }
        XCTAssertFalse(ingress.suspendAdmissions(epoch: epoch &+ 5),
                       "suspending a generation that is not live refuses")
        XCTAssertTrue(ingress.suspendAdmissions(epoch: epoch))
        guard case .refused(let code) = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("late callbacks must not re-qualify a suspended generation")
        }
        XCTAssertEqual(code, "admissionSuspended")
        XCTAssertEqual(ingress.derivedFields(), LinuxShellQualificationFields())
        XCTAssertTrue(ingress.resumeAdmissions(epoch: epoch))
        XCTAssertFalse(ingress.resumeAdmissions(epoch: epoch), "resume is exact: once only")
        guard case .accepted = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("an explicit legitimate transition reopens ingestion (facts still must be re-ingested)")
        }
    }

    func testPeerFactsCannotMixBinders() {
        let epoch = bindFreshEpoch()
        // Peer-bound facts refuse BEFORE any anchor exists.
        guard case .refused(let early) = ingress.ingest(
            .rootfsInstalled(receiptDigest: String(repeating: "d", count: 64), rootfsVersion: "rf-1"),
            rootEpoch: epoch) else {
            return XCTFail("rootfs without a verified peer must refuse")
        }
        XCTAssertEqual(early, "peerNotAnchored")
        guard case .accepted = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("boundary anchors the peer")
        }
        // A DIFFERENT binder may never join the qualified tuple.
        guard case .refused(let mix) = ingress.ingest(
            .engineConnected(binderIdentity: "peer-binder-OTHER", engineProtocolVersion: "rw-v1"),
            rootEpoch: epoch) else {
            return XCTFail("cross-peer engineConnected must refuse")
        }
        XCTAssertEqual(mix, "peerBinderMismatch")
        // A swapped boundary PEER (same binder token, other identity fields)
        // is a peer replacement, refused (never silently replaced).
        guard case .refused(let swap) = ingress.ingest(
            rub(epoch: epoch, uid: Int32(getuid()) + 2, cert: String(repeating: "9", count: 64)),
            rootEpoch: epoch) else {
            return XCTFail("boundary peer swap must refuse")
        }
        XCTAssertEqual(swap, "peerBoundaryConflict")
        // The SAME boundary (idempotent) and the same-peer engine fact pass.
        guard case .accepted = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("idempotent boundary re-ingest")
        }
        guard case .accepted = ingress.ingest(
            .engineConnected(binderIdentity: "peer-binder-1", engineProtocolVersion: "rw-v1"),
            rootEpoch: epoch) else {
            return XCTFail("same-peer engineConnected must pass")
        }
    }

    func testClosedMailboxRefusedAtIngestion() {
        let epoch = bindFreshEpoch()
        guard case .accepted = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("anchor")
        }
        LinuxShellMailbox.shared.close()
        guard case .refused(let mb) = ingress.ingest(.mailboxEpoch, rootEpoch: epoch) else {
            return XCTFail("closed mailbox must refuse at INGESTION, not only in derived fields")
        }
        XCTAssertEqual(mb, "mailboxClosed")
        guard case .refused(let lease) = ingress.ingest(
            .leaseAuthorityQualified(receiptDigest: String(repeating: "1", count: 64)),
            rootEpoch: epoch) else {
            return XCTFail("lease without an open mailbox must refuse")
        }
        XCTAssertEqual(lease, "mailboxClosed")
    }

    func testMappingFactReadsEngineReceiptUnderCurrentEpoch() throws {
        let epoch = bindFreshEpoch()
        let root = androidTestFixtureDirectory
            .appendingPathComponent("FloeR3Receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("WorkspaceTransfers/sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let authorityEpoch = epoch
        LinuxWorkspaceAuthority.storageRootOverrideForTesting = root.standardizedFileURL.path
        LinuxWorkspaceAuthority.rootEpochAuthorityForTesting = { authorityEpoch }
        // The mapping receipt lives under the ENGINE's accepted transfer
        // root: install through the production wrapper (first install wins;
        // an earlier composition-class install already satisfies the check).
        if let rootToken = RuntimeStorageRoot(validatingAbsoluteDirectory:
                                                root.standardizedFileURL.path) {
            _ = LinuxWorkspaceAuthority.install(storageRoot: rootToken)
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            LinuxWorkspaceAuthority.resetPurgeAuthoritiesForTesting()
        }

        let sessionKey = String(repeating: "c", count: 32)
        let dir = root.appendingPathComponent("WorkspaceTransfers/sessions/\(sessionKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = WorkspaceOwnerMarker(sessionKey: sessionKey,
                                          grantID: String(repeating: "d", count: 16),
                                          projectID: UUID().uuidString, runID: UUID().uuidString,
                                          rootEpoch: epoch,
                                          createdAtSeconds: Int64(Date().timeIntervalSince1970))
        try marker.writeDurable(to: dir.appendingPathComponent("owner.json").path)
        try marker.markTerminal(at: dir.appendingPathComponent("owner.json").path)
        let index = Data("{\"record\":\"terminalIndex\",\"sessionKey\":\"\(sessionKey)\",\"result\":\"synced\",\"partial\":false}".utf8)
        try index.write(to: dir.appendingPathComponent("index.json"))
        let digest = FloeDigest.sha256Hex(index)

        guard case .accepted = ingress.ingest(rub(epoch: epoch), rootEpoch: epoch) else {
            return XCTFail("anchor")
        }
        // Never a flag: an unknown digest must be read back to exist.
        guard case .refused(let missing) = ingress.ingest(
            .workspaceMappingSynced(receiptDigest: String(repeating: "0", count: 64)),
            rootEpoch: epoch) else {
            return XCTFail("unverified mapping digest must refuse")
        }
        XCTAssertEqual(missing, "mappingReceiptUnreadBack")
        guard case .accepted = ingress.ingest(
            .workspaceMappingSynced(receiptDigest: digest), rootEpoch: epoch) else {
            return XCTFail("a receipt Core reads back must be accepted")
        }
        // The SAME digest under a NEWER generation is an OLD-scope receipt:
        // not current mapping proof.
        let next = bindFreshEpoch()
        guard case .accepted = ingress.ingest(rub(epoch: next), rootEpoch: next) else {
            return XCTFail("re-anchor for the new generation")
        }
        guard case .refused(let stale) = ingress.ingest(
            .workspaceMappingSynced(receiptDigest: digest), rootEpoch: next) else {
            return XCTFail("old-epoch terminal receipt must refuse the new generation")
        }
        XCTAssertEqual(stale, "mappingReceiptEpochMismatch")
        // A REAL current-epoch terminal index whose durable result is NOT
        // "synced" (conflict export) is evidence of a FAILED mapping, never
        // mapping proof.
        let conflictKey = String(repeating: "e", count: 32)
        let conflictDir = root.appendingPathComponent("WorkspaceTransfers/sessions/\(conflictKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: conflictDir, withIntermediateDirectories: true)
        let conflictMarker = WorkspaceOwnerMarker(sessionKey: conflictKey,
                                                  grantID: String(repeating: "f", count: 16),
                                                  projectID: UUID().uuidString, runID: UUID().uuidString,
                                                  rootEpoch: next,
                                                  createdAtSeconds: Int64(Date().timeIntervalSince1970))
        try conflictMarker.writeDurable(to: conflictDir.appendingPathComponent("owner.json").path)
        try conflictMarker.markTerminal(at: conflictDir.appendingPathComponent("owner.json").path)
        let conflictIndex = Data("{\"record\":\"terminalIndex\",\"sessionKey\":\"\(conflictKey)\",\"result\":\"conflict\",\"partial\":true}".utf8)
        try conflictIndex.write(to: conflictDir.appendingPathComponent("index.json"))
        guard case .refused(let notSynced) = ingress.ingest(
            .workspaceMappingSynced(receiptDigest: FloeDigest.sha256Hex(conflictIndex)),
            rootEpoch: next) else {
            return XCTFail("a non-synced terminal receipt must refuse")
        }
        XCTAssertEqual(notSynced, "mappingReceiptNotSynced")
    }

    func testPartialIngressNeverQualifiesAndLossDropsIt() {
        let epoch = bindFreshEpoch()
        let live = LinuxShellLiveReadiness.makeInjected()
        XCTAssertFalse(live.isQualifiedForLinuxShell)
        func accept(_ proof: LinuxReadinessProof) {
            guard case .accepted = ingress.ingest(proof, rootEpoch: epoch) else {
                return XCTFail("ingest \(proof.fieldKind) must pass")
            }
        }
        let binder = "peer-binder-1"
        accept(rub(epoch: epoch, binder: binder))
        accept(.engineConnected(binderIdentity: binder, engineProtocolVersion: "rw-v1"))
        accept(.mailboxEpoch)
        accept(.rootfsInstalled(receiptDigest: String(repeating: "f", count: 64), rootfsVersion: "rf-1"))
        accept(.leaseAuthorityQualified(receiptDigest: String(repeating: "2", count: 64)))
        accept(.singleWorkloadAcknowledged(contractVersion: "single-workload-1"))
        var fields = ingress.derivedFields()
        XCTAssertFalse(fields.workspaceMappingSynced)
        XCTAssertFalse(fields.allFieldsTrue)
        XCTAssertFalse(live.isQualifiedForLinuxShell,
                       "installed/connected alone NEVER qualifies: the engine receipt read-back is missing")
        // Invalidate the anchor: EVERY dependent fact loses its verified
        // peer (no orphan qualification remains).
        XCTAssertTrue(ingress.invalidate(.runtimeUidBoundary, reason: "peerLost"))
        fields = ingress.derivedFields()
        XCTAssertFalse(fields.engineConnected)
        XCTAssertFalse(live.isQualifiedForLinuxShell)
    }

    func testReadinessFieldWireVocabularyIsClosed() {
        // The ABI field set is exactly the seven fields; anything else has
        // no rawValue and refuses (guards the Kotlin wire vocabulary).
        for name in ["runtimeUidBoundary", "engineConnected", "mailboxEpoch", "rootfsInstalled",
                     "workspaceMappingSynced", "leaseAuthorityQualified",
                     "singleWorkloadAcknowledged"] {
            XCTAssertNotNil(LinuxReadinessFieldKind(rawValue: name))
        }
        XCTAssertNil(LinuxReadinessFieldKind(rawValue: "allTrue"))
        XCTAssertNil(LinuxReadinessFieldKind(rawValue: ""))
    }

    /// Trusted-host ABI proof-parse strictness (object-compile repair
    /// job-65502159a2d44e93): the ONLY path that bridges JSON values into
    /// the typed proof must refuse malformed shapes instead of coercing
    /// them. The historical `intValue` bridge truncated 2^32+5 into the
    /// DIFFERENT UID 5 (which would then PASS distinctness and anchor a
    /// wrong peer); a boxed boolean or a numeric token where the contract
    /// demands a string would flow into `String?` only through a lossy
    /// cast. All three refuse with the frozen `proofIncomplete` reply, the
    /// peer stays UNanchored, and the same call with an honest in-range
    /// body accepts.
    func testABIProofParseRefusesTruncatingAndNonStringFields() throws {
        let epoch = bindFreshEpoch()
        func ingest(_ field: String, _ proof: String) -> [String: Any]? {
            var fieldBytes: [CChar] = Array(field.utf8).map { CChar(bitPattern: $0) } + [0]
            var proofBytes: [CChar] = Array(proof.utf8).map { CChar(bitPattern: $0) }
            var buffer = [CChar](repeating: 0, count: 4_096)
            let n = fieldBytes.withUnsafeMutableBufferPointer { fb in
                proofBytes.withUnsafeMutableBufferPointer { pb in
                    buffer.withUnsafeMutableBufferPointer { out in
                        floeLinuxReadinessIngest(fb.baseAddress, epoch, pb.baseAddress,
                                                 Int32(pb.count), out.baseAddress,
                                                 Int32(out.count))
                    }
                }
            }
            guard n > 0 else { return nil }
            let data = Data(bytes: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) },
                            count: Int(n))
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        func boundaryBody(uid: String, version: String = "\"0.1.0-test\"",
                          binder: String = "\"peer-binder-1\"") -> String {
            let cert = String(repeating: "a", count: 64)
            return "{\"runtimeUID\":\(uid),\"certificateDigest\":\"\(cert)\","
                + "\"packageVersion\":\(version),\"binderIdentity\":\(binder)}"
        }
        let overflow = Int64(UInt32.max) + 5   // truncates to 5 via intValue
        guard let overflowReply = ingest("runtimeUidBoundary", boundaryBody(uid: "\(overflow)")) else {
            return XCTFail("overflowing-UID reply missing")
        }
        XCTAssertEqual(overflowReply["code"] as? String, "proofIncomplete",
                       "an out-of-Int32 UID must never anchor a truncated peer")
        // A CF-boolean UID refuses BEFORE any number bridge.
        XCTAssertEqual(ingest("runtimeUidBoundary", boundaryBody(uid: "true"))?["code"] as? String,
                       "proofIncomplete")
        // Numeric tokens where the contract demands string tokens refuse
        // (packageVersion AND binderIdentity are ASCII-token strings).
        XCTAssertEqual(ingest("runtimeUidBoundary",
                              boundaryBody(uid: "\(Int64(Int32(getuid()) + 1))",
                                           version: "7",
                                           binder: "9"))?["code"] as? String,
                       "proofIncomplete")
        // Nothing anchored across the refusals: dependent facts still have
        // no verified peer.
        guard case .refused(let peer) = ingress.ingest(
            .engineConnected(binderIdentity: "peer-binder-1", engineProtocolVersion: "rw-v1"),
            rootEpoch: epoch) else {
            return XCTFail("no refusals may anchor a peer")
        }
        XCTAssertEqual(peer, "peerNotAnchored")
        // The honest in-range body ACCEPTS through the same ABI.
        let goodBody = boundaryBody(uid: "\(Int64(Int32(getuid()) + 1))")
        guard let good = ingest("runtimeUidBoundary", goodBody),
              good["ok"] as? Bool == true,
              good["field"] as? String == "runtimeUidBoundary" else {
            return XCTFail("a well-formed in-range boundary proof must be accepted")
        }
    }
}

// MARK: - Transfer purge (explicit trusted authority seams; synthetic roots)

final class LinuxWorkspaceTransferPurgeR3Tests: XCTestCase {

    private var root: URL!
    private let epoch: UInt64 = 5150

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = androidTestFixtureDirectory
            .appendingPathComponent("FloeR3Purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Workspace/PrivateTasks", isDirectory: true),
            withIntermediateDirectories: true)
        let authorityEpoch = epoch
        LinuxWorkspaceAuthority.storageRootOverrideForTesting = root.standardizedFileURL.path
        LinuxWorkspaceAuthority.rootEpochAuthorityForTesting = { authorityEpoch }
        LinuxWorkspaceAuthority.liveSessionProbeForTesting = nil
    }

    override func tearDown() {
        LinuxWorkspaceAuthority.resetPurgeAuthoritiesForTesting()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func project(for conversationID: UUID) -> UUID {
        let canonical = root
            .appendingPathComponent("Workspace/PrivateTasks/\(conversationID.uuidString)", isDirectory: true)
            .standardizedFileURL
        return LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: canonical)
    }

    @discardableResult
    private func makeSession(conversationID: UUID, sessionKey: String, project: UUID? = nil,
                             terminal: Bool = true, runID: UUID = UUID(), staging: Bool = true,
                             recovered: Bool = true) throws -> String {
        let projectID = project ?? self.project(for: conversationID)
        let sessions = root.appendingPathComponent("WorkspaceTransfers/sessions/\(sessionKey)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions.appendingPathComponent("staging", isDirectory: true),
            withIntermediateDirectories: true)
        let marker = WorkspaceOwnerMarker(sessionKey: sessionKey,
                                          grantID: String(repeating: "a", count: 16),
                                          projectID: projectID.uuidString,
                                          runID: runID.uuidString, rootEpoch: epoch,
                                          createdAtSeconds: Int64(Date().timeIntervalSince1970))
        try marker.writeDurable(to: sessions.appendingPathComponent("owner.json").path)
        if terminal {
            try marker.markTerminal(at: sessions.appendingPathComponent("owner.json").path)
        }
        if staging {
            try Data("export copy".utf8).write(to: sessions.appendingPathComponent("staging/file.txt"))
        }
        if recovered {
            let recoveredDir = root.appendingPathComponent("WorkspaceTransfers/recovered/\(sessionKey)",
                                                           isDirectory: true)
            try FileManager.default.createDirectory(at: recoveredDir, withIntermediateDirectories: true)
            try Data("conflict artifact".utf8).write(to: recoveredDir.appendingPathComponent("notes.md"))
        }
        return sessions.path
    }

    private func recoveredPath(_ sessionKey: String) -> String {
        root.appendingPathComponent("WorkspaceTransfers/recovered/\(sessionKey)").path
    }

    private func purge(_ conversationID: UUID, rootEpoch: UInt64? = nil) -> LinuxWorkspaceTransferPurge {
        LinuxWorkspaceAuthority.purgeTargetOwnedTransferState(
            conversationID: conversationID,
            expectedRelativePath: "PrivateTasks/\(conversationID.uuidString)",
            rootEpoch: rootEpoch ?? epoch)
    }

    private func refuseCode(_ result: LinuxWorkspaceTransferPurge) -> String? {
        if case .refused(let code) = result { return code }
        return nil
    }

    func testNilLiveAuthorityRefusesAndTouchesNothing() throws {
        LinuxWorkspaceAuthority.rootEpochAuthorityForTesting = nil // production-shaped: no readback
        let conversation = UUID()
        let session = try makeSession(conversationID: conversation,
                                      sessionKey: String(repeating: "1", count: 32))
        switch purge(conversation, rootEpoch: epoch) {
        case .refused(let code):
            XCTAssertTrue(["epochUnprovable", "epochStale"].contains(code),
                          "nil/foreign live authority must refuse; absence of a readback is NEVER authority, got \(code)")
        default: XCTFail("nil live authority must refuse")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session), "refusal touches nothing")
    }

    func testForeignStaleEpochArgumentRefuses() {
        XCTAssertEqual(refuseCode(purge(UUID(), rootEpoch: epoch &+ 1)), "epochStale")
    }

    func testForeignAndUncertainOwnersArePreserved() throws {
        let target = UUID()
        let other = UUID()
        let targetSession = try makeSession(conversationID: target,
                                            sessionKey: String(repeating: "2", count: 32))
        let foreignSession = try makeSession(conversationID: target,
                                             sessionKey: String(repeating: "3", count: 32),
                                             project: project(for: other)) // FOREIGN project
        let malformed = root.appendingPathComponent("WorkspaceTransfers/sessions/deadbeef", isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        switch purge(target) {
        case .completed(let report):
            XCTAssertEqual(report.provenTotal, 1)
            XCTAssertEqual(report.preservedForeign, 1)
            XCTAssertEqual(report.retainedUncertain, 1)
        default: XCTFail("target-only purge must complete")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetSession),
                       "the proven target tree is removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignSession), "foreign owners survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path), "unknown owners survive")
    }

    func testCrashOrphanIsRediscoveredThroughTheLedger() throws {
        // Simulate the prior crash: the SESSION tree is already gone (marker
        // destroyed) but the recovered/ orphan remains, and the durable
        // ledger records the proven key.
        let conversation = UUID()
        let sessionKey = String(repeating: "4", count: 32)
        let projectID = project(for: conversation)
        let pendingDir = root.appendingPathComponent("WorkspaceTransfers/pending-purge", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        let ledgerPayload: [String: Any] = [
            "version": 1, "conversationID": conversation.uuidString,
            "projectID": projectID.uuidString, "rootEpoch": epoch,
            "sessionKeys": [sessionKey], "pendingKeys": [sessionKey],
            "coreDeletionsSettled": false, "createdAtSeconds": 1,
        ]
        try cleanupJSON(ledgerPayload).write(to: pendingDir.appendingPathComponent("\(conversation.uuidString).json"))
        let recoveredDir = root.appendingPathComponent("WorkspaceTransfers/recovered/\(sessionKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveredDir, withIntermediateDirectories: true)
        try Data("orphan copy".utf8).write(to: recoveredDir.appendingPathComponent("notes.md"))

        switch purge(conversation) {
        case .completed(let report):
            XCTAssertEqual(report.provenTotal, 1, "the LEDGER alone proves the orphan's ownership")
            XCTAssertEqual(report.recoveredDirectoriesPurged, 1)
            XCTAssertTrue(report.ledgerCoreSettled)
        default: XCTFail("ledger-discovered orphan must be purged")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredDir.path))
        // Tombstone stands with coreDeletionsSettled until the runtime ACK.
        let ledger = try XCTUnwrap(LinuxWorkspaceAuthority.pendingPurgeLedger(conversationID: conversation))
        XCTAssertTrue(ledger.coreDeletionsSettled)
        XCTAssertTrue(ledger.pendingKeys.isEmpty)
        // Wrong-epoch settle refuses; the matching epoch settles and removes.
        XCTAssertFalse(LinuxWorkspaceAuthority.settleTargetPurgeLedger(
            conversationID: conversation, projectID: projectID, rootEpoch: epoch &+ 1))
        XCTAssertFalse(LinuxWorkspaceAuthority.settleTargetPurgeLedger(
            conversationID: conversation, projectID: UUID(), rootEpoch: epoch))
        XCTAssertTrue(LinuxWorkspaceAuthority.settleTargetPurgeLedger(
            conversationID: conversation, projectID: projectID, rootEpoch: epoch))
        XCTAssertNil(LinuxWorkspaceAuthority.pendingPurgeLedger(conversationID: conversation))
    }

    func testLiveGrantRetainedThenSettlesOnRetry() throws {
        let conversation = UUID()
        let sessionKey = String(repeating: "5", count: 32)
        let session = try makeSession(conversationID: conversation, sessionKey: sessionKey)
        LinuxWorkspaceAuthority.liveSessionProbeForTesting = { $0 == sessionKey }
        switch purge(conversation) {
        case .retained(_, let reason): XCTAssertEqual(reason, "transferSessionsLive")
        default: XCTFail("unsettled live grant must be retained, never unlinked")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredPath(sessionKey)))
        let ledger = try XCTUnwrap(LinuxWorkspaceAuthority.pendingPurgeLedger(conversationID: conversation))
        XCTAssertEqual(ledger.pendingKeys, [sessionKey])
        // After real settlement the SAME lifecycle pass completes it.
        LinuxWorkspaceAuthority.liveSessionProbeForTesting = nil
        switch purge(conversation) {
        case .completed(let report): XCTAssertEqual(report.provenTotal, 1)
        default: XCTFail("retry must finish the retained target")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveredPath(sessionKey)))
    }

    func testUnreadableLedgerRefusesBeforeAnyEffect() throws {
        let conversation = UUID()
        let session = try makeSession(conversationID: conversation,
                                      sessionKey: String(repeating: "6", count: 32))
        let pendingDir = root.appendingPathComponent("WorkspaceTransfers/pending-purge", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: pendingDir.appendingPathComponent("\(conversation.uuidString).json"))
        XCTAssertEqual(refuseCode(purge(conversation)), "pendingPurgeLedgerUnreadable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session), "refusal touches NOTHING")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pendingDir.appendingPathComponent("\(conversation.uuidString).json").path),
            "an unprovable record is preserved, never overwritten")
    }

    func testShapeMismatchRefuses() {
        let conversation = UUID()
        let other = UUID()
        let result = LinuxWorkspaceAuthority.purgeTargetOwnedTransferState(
            conversationID: conversation,
            expectedRelativePath: "PrivateTasks/\(other.uuidString)",
            rootEpoch: epoch)
        XCTAssertEqual(refuseCode(result), "scopePathShape")
    }
}

// MARK: - Lifecycle (real store + ORIGINAL port + lane ACK)

final class R3WorkspaceCleanupLifecycleTests: XCTestCase {

    private let epoch: UInt64 = 7777

    override func setUp() {
        super.setUp()
        LinuxRuntimeCleanupLane.shared.resetForRebind()
        LinuxWorkspaceAuthority.resetPurgeAuthoritiesForTesting()
    }

    override func tearDown() {
        LinuxRuntimeCleanupLane.shared.resetForRebind()
        LinuxWorkspaceAuthority.resetPurgeAuthoritiesForTesting()
        super.tearDown()
    }

    private func makeSessionFixture(root: URL, conversationID: UUID, sessionKey: String) throws {
        let canonical = root
            .appendingPathComponent("Workspace/PrivateTasks/\(conversationID.uuidString)", isDirectory: true)
            .standardizedFileURL
        let project = LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: canonical)
        let sessions = root.appendingPathComponent("WorkspaceTransfers/sessions/\(sessionKey)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessions.appendingPathComponent("staging", isDirectory: true), withIntermediateDirectories: true)
        let marker = WorkspaceOwnerMarker(sessionKey: sessionKey,
                                          grantID: String(repeating: "7", count: 16),
                                          projectID: project.uuidString, runID: UUID().uuidString,
                                          rootEpoch: epoch,
                                          createdAtSeconds: Int64(Date().timeIntervalSince1970))
        try marker.writeDurable(to: sessions.appendingPathComponent("owner.json").path)
        try marker.markTerminal(at: sessions.appendingPathComponent("owner.json").path)
        try Data("export bytes".utf8).write(to: sessions.appendingPathComponent("staging/data.bin"))
        let recoveredDir = root.appendingPathComponent("WorkspaceTransfers/recovered/\(sessionKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveredDir, withIntermediateDirectories: true)
        try Data("conflict bytes".utf8).write(to: recoveredDir.appendingPathComponent("doc.md"))
    }

    func testRowRetainsUntilRealReceiptThenCompletesAndTombstoneCloses() async throws {
        let stores = try await PrivacyTestBed.stores(name: "r3-ack")
        let conversation = UUID()
        let workspaceID = UUID()
        let sessionKey = String(repeating: "8", count: 32)
        try await PrivacyTestBed.seedWorkspace(stores, workspaceID: workspaceID, conversationID: conversation)
        let ownedDir = stores.directory
            .appendingPathComponent("Workspace/PrivateTasks/\(conversation.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        try Data("task".utf8).write(to: ownedDir.appendingPathComponent("notes.md"))
        try makeSessionFixture(root: stores.directory, conversationID: conversation, sessionKey: sessionKey)

        let rootToken = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: stores.directory.standardizedFileURL.path))
        let cleaning = G02WorkspaceCleaning(root: rootToken)
        LinuxWorkspaceAuthority.storageRootOverrideForTesting = rootToken.path
        let authorityEpoch = epoch
        LinuxWorkspaceAuthority.rootEpochAuthorityForTesting = { authorityEpoch }
        let relative = "PrivateTasks/\(conversation.uuidString)"

        // Pass 1: directory + Core copies go, the row RETAINS (real receipt
        // outstanding), the tombstone ledger stands, the lane owns the scope.
        let first = await ConversationPrivateWorkspaceCleanup.performDetailed(
            workspaceStore: stores.workspaces, cleaning: cleaning,
            workspaceID: workspaceID, relativePath: relative,
            rootEpoch: epoch, conversationID: conversation)
        XCTAssertEqual(first.outcome, .deferred("runtimeCleanupAwaitingReceipt"))
        guard case .queued(let requestID) = first.runtimeHandoff, !requestID.isEmpty else {
            return XCTFail("handoff must be queued with a request id, got \(first.runtimeHandoff)")
        }
        XCTAssertEqual(first.directoryEffect, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDir.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stores.directory.appendingPathComponent("WorkspaceTransfers/sessions/\(sessionKey)").path))
        let queued = try await stores.workspaces.pendingLocalCleanup()
        XCTAssertEqual(queued.map(\.workspaceID), [workspaceID], "the durable row is retained until real ACK")
        XCTAssertNotNil(LinuxWorkspaceAuthority.pendingPurgeLedger(conversationID: conversation))

        // Host: bind, claim, deliver the REAL cleared receipt.
        let lane = LinuxRuntimeCleanupLane.shared
        XCTAssertTrue(lane.bind(epoch: 9500))
        let claim = lane.nextClaim(timeoutMillis: 0)
        XCTAssertGreaterThan(claim, 0)
        let described = try XCTUnwrap(laneDescribe(lane, claim: claim))
        XCTAssertEqual(described["requestID"] as? String, requestID)
        let payload = try XCTUnwrap(lanePayload(lane, claim: claim))
        let scopeObject = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        XCTAssertEqual(scopeObject["conversationID"] as? String, conversation.uuidString)
        XCTAssertEqual(scopeObject["deletionSet"] as? String, "targetProjectScope",
                       "the AUTHORITATIVE deletion set is the complete proven project scope")
        let settled = laneComplete(lane, claim: claim,
                                   receipt: clearedReceipt(requestID: requestID, payload: payload))
        XCTAssertEqual(settled?["state"] as? String, "cleared")
        XCTAssertTrue(lane.isSettledCleared(requestID: requestID))

        // Pass 2 (owned retry): the row finalizes and the tombstone closes.
        let second = await ConversationPrivateWorkspaceCleanup.performDetailed(
            workspaceStore: stores.workspaces, cleaning: cleaning,
            workspaceID: workspaceID, relativePath: relative,
            rootEpoch: epoch, conversationID: conversation)
        XCTAssertEqual(second.outcome, .removed)
        guard case .settled(let digest) = second.runtimeHandoff, !digest.isEmpty else {
            return XCTFail("the settled receipt must surface with its digest")
        }
        let remaining = try await stores.workspaces.pendingLocalCleanup()
        XCTAssertTrue(remaining.isEmpty, "queue completion happens ONLY after BOTH halves settle")
        XCTAssertNil(LinuxWorkspaceAuthority.pendingPurgeLedger(conversationID: conversation))
    }

    func testRuntimeRefusalKeepsRowAndRequeues() async throws {
        let stores = try await PrivacyTestBed.stores(name: "r3-refuse")
        let conversation = UUID()
        let workspaceID = UUID()
        let sessionKey = String(repeating: "9", count: 32)
        try await PrivacyTestBed.seedWorkspace(stores, workspaceID: workspaceID, conversationID: conversation)
        let ownedDir = stores.directory
            .appendingPathComponent("Workspace/PrivateTasks/\(conversation.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ownedDir, withIntermediateDirectories: true)
        try makeSessionFixture(root: stores.directory, conversationID: conversation, sessionKey: sessionKey)
        let rootToken = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: stores.directory.standardizedFileURL.path))
        let cleaning = G02WorkspaceCleaning(root: rootToken)
        LinuxWorkspaceAuthority.storageRootOverrideForTesting = rootToken.path
        let authorityEpoch = epoch
        LinuxWorkspaceAuthority.rootEpochAuthorityForTesting = { authorityEpoch }
        let relative = "PrivateTasks/\(conversation.uuidString)"

        let first = await ConversationPrivateWorkspaceCleanup.performDetailed(
            workspaceStore: stores.workspaces, cleaning: cleaning,
            workspaceID: workspaceID, relativePath: relative,
            rootEpoch: epoch, conversationID: conversation)
        guard case .queued(let requestID) = first.runtimeHandoff else {
            return XCTFail("awaiting receipt expected")
        }
        let lane = LinuxRuntimeCleanupLane.shared
        XCTAssertTrue(lane.bind(epoch: 9600))
        let claim = lane.nextClaim(timeoutMillis: 0)
        let payload = try XCTUnwrap(lanePayload(lane, claim: claim))
        _ = laneComplete(lane, claim: claim,
                         receipt: refusedReceipt(requestID: requestID, payload: payload,
                                                 reason: "workspaceBusy"))
        XCTAssertEqual(lane.state(requestID: requestID), .retrying(reason: "workspaceBusy"))
        let retry = await ConversationPrivateWorkspaceCleanup.performDetailed(
            workspaceStore: stores.workspaces, cleaning: cleaning,
            workspaceID: workspaceID, relativePath: relative,
            rootEpoch: epoch, conversationID: conversation)
        XCTAssertEqual(retry.outcome, .deferred("runtimeCleanupRetrying"),
                       "a runtime refusal is never success; the durable row stays")
        let queued = try await stores.workspaces.pendingLocalCleanup()
        XCTAssertEqual(queued.map(\.workspaceID), [workspaceID])
    }

    func testNoEvidenceCompletesLegacyStyle() async throws {
        let stores = try await PrivacyTestBed.stores(name: "r3-clean")
        let conversation = UUID()
        let workspaceID = UUID()
        try await PrivacyTestBed.seedWorkspace(stores, workspaceID: workspaceID, conversationID: conversation)
        let rootToken = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: stores.directory.standardizedFileURL.path))
        let cleaning = G02WorkspaceCleaning(root: rootToken)
        LinuxWorkspaceAuthority.storageRootOverrideForTesting = rootToken.path
        let authorityEpoch = epoch
        LinuxWorkspaceAuthority.rootEpochAuthorityForTesting = { authorityEpoch }
        let report = await ConversationPrivateWorkspaceCleanup.performDetailed(
            workspaceStore: stores.workspaces, cleaning: cleaning,
            workspaceID: workspaceID, relativePath: "PrivateTasks/\(conversation.uuidString)",
            rootEpoch: epoch, conversationID: conversation)
        XCTAssertEqual(report.outcome, .absent)
        XCTAssertEqual(report.runtimeHandoff, .notApplicable)
        let queued = try await stores.workspaces.pendingLocalCleanup()
        XCTAssertTrue(queued.isEmpty)
        XCTAssertTrue(LinuxRuntimeCleanupLane.shared.statsJSON().contains("\"enqueued\":0"))
    }
}
