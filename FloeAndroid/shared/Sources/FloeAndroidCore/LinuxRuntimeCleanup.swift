// SPDX-License-Identifier: MPL-2.0
//
// FloeAndroidCore — LinuxRuntimeCleanup: the typed, BOUNDED Core->host
// runtime-UID workspace-copy cleanup request/receipt lane (G03-R3,
// job-3d39b56695c44bd2).
//
// Why this exists (reused authorities only, NO parallel DB/command system):
// * LinuxShellPump / RuntimeKernel live under a DIFFERENT app UID from Core.
//   The conversation/privacy lifecycle (conversation.delete and
//   privacy.history.clear) removes Core's own trees and the V36-queued
//   private-task directory, but the runtime UID holds workspace copies for
//   the SAME project identity. Core can NEVER unlink another UID's files.
// * The ORIGINAL pattern for Core->host effects is the mailbox/host-work
//   shape (LinuxShellMailbox): bounded in-memory queue, trusted-host claim,
//   typed payload, host-settled receipt. This lane reuses that pattern with
//   cleanup-specific rules:
//   - ENQUEUE works even while the mailbox/transport is unbound or the model
//     admission is fenced: the cleanup/proof channel stays available until
//     REAL settlement (a stranded obligation is worse than a delayed one).
//   - CLAIM requires a bound live generation (never epoch 0).
//   - A receipt only settles its OWN claim under the CURRENT bound epoch.
//     Unknown claim token, stale/foreign epoch, or ANY scope mismatch
//     (requestID/conversationID/projectID/targetEpoch) returns a typed
//     refusal and RETAINS the record for retry — a refusal is never a
//     success and a request is never "completed" merely because Core asked.
//   - Generation re-bind re-queues claimed records (the host pump died with
//     the Binder: the removal MAY have partially happened; the runtime-side
//     handler is idempotent, so the next generation re-claims and re-runs
//     the same scope). Nothing is converted into fake IO drain.
//   - Receipt "cleared" must carry real execution identity: a runtime UID
//     DISTINCT from this process's UID (getuid cross-check), the package
//     certificate digest, package version, binder identity token and an
//     executor proof digest — model JSON can never reach this ABI (the
//     @_cdecl surface is host-only, like every mailbox entry point).
// * Scope binding: cleanup ownership is the ACTUAL conversation/run/session/
//   project/root epoch Core observed (the deletion flow's store-validated
//   `PrivateTasks/<uuid>` shape + LinuxShellProjectMapping's deterministic
//   project identity + the grant session keys/marker runIDs/rootEpochs).
//   No guessed temp roots, no first-project scanning, no dedup double-queue:
//   the same (conversationID, projectID, targetEpoch) scope re-returns its
//   EXISTING requestID (idempotent lifecycle retry after a deferred delete).
//
// Runtime-side handling is a separate lane (Main's next runtime owner
// consumes this exact contract): claim the request, remove the runtime-UID
// copies for the NAMED scope only (the runtime must fail closed on any
// unresolved path), then deliver the receipt through
// `floe_linux_runtime_cleanup_complete`. Core treats "refused" receipts as
// RETAINED obligations (re-queued), never as cleared data.
import Foundation
import CoreFoundation
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Limits + status codes

public enum LinuxRuntimeCleanupLimits {
    /// Live (queued-or-claimed) requests plus the bounded settled ring.
    public static let maximumLiveRequests = 64
    /// Retired settled records / stale claim tokens.
    public static let maximumRetired = 256
    /// One scope payload (bounded identity + <=32 session keys + <=32 runIDs).
    public static let maximumPayloadBytes = 4_096
    /// Aggregate queued bytes bound.
    public static let maximumQueuedBytes = 32_768
    /// Receipt JSON inbound bound.
    public static let maximumReceiptBytes = 4_096
}

public enum LinuxRuntimeCleanupCode {
    public static let ok: Int32 = 0
    public static let invalidArguments: Int32 = -105
    public static let bufferTooSmall: Int32 = -106
}

// MARK: - Typed scope / receipt

/// The EXACT target Core proved owned: the store-validated private-task
/// shape, the deterministic project identity derived from the canonical
/// Core workspace root, and the lifecycle root epoch. The AUTHORITATIVE
/// runtime deletion set is this COMPLETE proven target-project scope
/// (conversationID + projectID + targetEpoch + owned shape) — the runtime
/// lane resolves its own copies by the SAME deterministic project mapping.
/// The session-key evidence arrays are bounded diagnostics from the Core
/// pending ledger (`evidenceTruncated` is honest), NEVER a partial deletion
/// list. Nothing guessed, nothing scanned by path prefix.
public struct LinuxRuntimeCleanupScope: Sendable, Equatable {
    public var conversationID: UUID
    public var projectID: UUID
    public var targetEpoch: UInt64
    /// The ORIGINAL owned shape `PrivateTasks/<conversation uuid>` (already
    /// re-validated by the cleanup admission transaction before queuing).
    public var workspaceRelativePath: String
    /// Up to 16 Core-observed grant session keys for this project (from the
    /// durable pending ledger / marker evidence). Informational only.
    public var evidenceSessionKeys: [String]
    /// True when MORE proven keys existed than the bounded evidence carries
    /// (the durable pending ledger on the Core side keeps the full set).
    public var evidenceTruncated: Bool
    /// The COMPLETE count of proven target-owned sessions Core observed.
    public var provenTotal: Int

    public init(conversationID: UUID, projectID: UUID, targetEpoch: UInt64,
                workspaceRelativePath: String,
                evidenceSessionKeys: [String], evidenceTruncated: Bool, provenTotal: Int) {
        self.conversationID = conversationID
        self.projectID = projectID
        self.targetEpoch = targetEpoch
        self.workspaceRelativePath = workspaceRelativePath
        self.evidenceSessionKeys = Array(evidenceSessionKeys.prefix(16))
        self.evidenceTruncated = evidenceTruncated
        self.provenTotal = provenTotal
    }

    var scopeKey: String { "\(conversationID.uuidString)|\(projectID.uuidString)|\(targetEpoch)" }

    var payloadJSON: Data? {
        let object: [String: Any] = [
            "operation": "runtimeWorkspaceCopies.clear",
            "deletionSet": "targetProjectScope",
            "conversationID": conversationID.uuidString,
            "projectID": projectID.uuidString,
            "targetEpoch": targetEpoch,
            "workspaceRelativePath": workspaceRelativePath,
            "provenTotal": provenTotal,
            "evidenceSessionKeys": evidenceSessionKeys,
            "evidenceTruncated": evidenceTruncated,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= LinuxRuntimeCleanupLimits.maximumPayloadBytes else { return nil }
        return data
    }
}

/// Host-observed execution proof. `cleared` requires EVERY identity field;
/// the lane refuses a cleared receipt whose runtime UID equals this
/// process's UID (the two lanes are distinct UIDs by contract — a
/// same-UID "runtime" claim cannot prove runtime-side IO) or whose digests
/// are malformed.
public enum LinuxRuntimeCleanupReceipt: Sendable, Equatable {
    public struct ExecutionProof: Sendable, Equatable {
        public var runtimeUID: Int32
        public var certificateDigest: String
        public var packageVersion: String
        public var binderIdentity: String
        public var executorProofDigest: String
        public var pathsRemoved: Int64
        public var bytesFreed: Int64
    }
    case cleared(ExecutionProof)
    case refused(reason: String)

    /// Strict parse. Returns the scope fields alongside the typed outcome,
    /// or nil for ANY malformed shape (a malformed receipt NEVER settles).
    static func parse(_ data: Data) -> (scope: (requestID: String, conversationID: String,
                                                projectID: String, targetEpoch: UInt64),
                                        receipt: LinuxRuntimeCleanupReceipt)? {
        guard data.count <= LinuxRuntimeCleanupLimits.maximumReceiptBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let requestID = object["requestID"] as? String,
              requestID.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              let conversationID = object["conversationID"] as? String,
              conversationID.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                                   options: .regularExpression) != nil,
              let projectID = object["projectID"] as? String,
              projectID.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                              options: .regularExpression) != nil,
              let epochNumber = object["targetEpoch"] as? NSNumber,
              let epoch = Self.exactInt64(epochNumber), epoch > 0 else { return nil }
        let scope = (requestID, conversationID, projectID, UInt64(epoch))
        switch object["outcome"] as? String {
        case "refused":
            let reason = (object["reason"] as? String ?? "runtimeRefused")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty, reason.utf8.count <= 64,
                  reason.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }) else { return nil }
            return (scope, .refused(reason: reason))
        case "cleared":
            guard let uidNumber = object["runtimeUID"] as? NSNumber,
                  let uid = Self.exactInt32(uidNumber),
                  let cert = object["certificateDigest"] as? String,
                  cert.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let version = object["packageVersion"] as? String,
                  asciiToken(version, maximum: 96),
                  let binder = object["binderIdentity"] as? String,
                  asciiToken(binder, maximum: 128),
                  let proof = object["executorProofDigest"] as? String,
                  proof.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let removedNumber = object["pathsRemoved"] as? NSNumber,
                  let removed = Self.exactInt64(removedNumber), removed >= 0,
                  let freedNumber = object["bytesFreed"] as? NSNumber,
                  let freed = Self.exactInt64(freedNumber), freed >= 0 else { return nil }
            return (scope, .cleared(ExecutionProof(
                runtimeUID: uid,
                certificateDigest: cert,
                packageVersion: version,
                binderIdentity: binder,
                executorProofDigest: proof,
                pathsRemoved: removed,
                bytesFreed: freed)))
        default:
            return nil
        }
    }

    private static func asciiToken(_ text: String, maximum: Int) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximum else { return false }
        return text.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    /// Exact JSON-number → Int64 extraction following the module's proven
    /// canonical classification (G02DomainBinder.designValue): a CF boolean
    /// is refused BEFORE any number bridge, integer encodings use
    /// `int64Value` exactly, unsigned encodings must fit Int64, and a
    /// floating encoding is accepted ONLY when finite and integral within
    /// exact-integer range. Unknown encodings refuse — a receipt number is
    /// NEVER bridged through `uint64Value`/`doubleValue` into a different
    /// value (negative wrap or truncation must not settle anything).
    private static func exactInt64(_ number: NSNumber) -> Int64? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        switch String(cString: number.objCType) {
        case "c", "i", "s", "l", "q":
            return number.int64Value
        case "C", "I", "S", "L", "Q":
            let unsigned = number.uint64Value
            guard unsigned <= UInt64(Int64.max) else { return nil }
            return Int64(unsigned)
        case "f", "d":
            let value = number.doubleValue
            guard value.isFinite, value == value.rounded(),
                  abs(value) <= 9_007_199_254_740_991 else { return nil }
            return number.int64Value
        default:
            return nil
        }
    }

    /// The peer runtime UID: a non-negative exact integer inside Int32
    /// (the lane's frozen ExecutionProof type). Out-of-range or non-exact
    /// numbers REFUSE as malformed instead of truncating into a DIFFERENT
    /// UID that could then pass the distinctness cross-check. The
    /// same-UID identity refusal in `complete` stays authoritative.
    private static func exactInt32(_ number: NSNumber) -> Int32? {
        guard let value = exactInt64(number),
              value >= 0, value <= Int64(Int32.max) else { return nil }
        return Int32(value)
    }
}

// MARK: - Lane state

public enum LinuxRuntimeCleanupRequestState: Sendable, Equatable {
    case queued
    case retrying(reason: String)
    case claimed(claimToken: Int64)
    case settled(receiptDigest: String)
    case unknown
}

/// The bounded mailbox-pattern lane. Process-global like the shell mailbox
/// (one accepted generation at a time).
public final class LinuxRuntimeCleanupLane: @unchecked Sendable {
    public static let shared = LinuxRuntimeCleanupLane()

    fileprivate final class Request: @unchecked Sendable {
        let id: String                 // 32-hex request id (Core-minted)
        let scope: LinuxRuntimeCleanupScope
        let payload: Data
        enum LaneState {
            case queued
            case claimed
        }
        var state: LaneState = .queued
        var claimToken: Int64 = 0
        var lastRefusal: String?
        init(id: String, scope: LinuxRuntimeCleanupScope, payload: Data) {
            self.id = id
            self.scope = scope
            self.payload = payload
        }
    }

    private struct Counters {
        var enqueued = 0
        var dedupHits = 0
        var rejectedSaturated = 0
        var rejectedMalformed = 0
        var claims = 0
        var requeuedAfterGeneration = 0
        var settledCleared = 0
        var runtimeRefusalsRetained = 0
        var refusedStaleClaim = 0
        var refusedUnknown = 0
        var refusedScopeMismatch = 0
        var refusedIdentity = 0
        var refusedUnbound = 0
    }

    private let condition = NSCondition()
    /// LIVE (queued-or-claimed) obligations only. A settled receipt LEAVES
    /// this table (capacity fix, Main CLEANUP_CAPACITY_REVIEW 2026-10-22):
    /// the 64-slot ceiling bounds UNSETTLED obligations only, so sequential
    /// clearing can never exhaust the lane, and unsettled obligations are
    /// never evicted. ABI/JSON shapes are unchanged.
    private var requests: [String: Request] = [:]
    private struct SettledRecord {
        let scopeKey: String
        let targetEpoch: UInt64
        let digest: String
    }
    /// ACK PROOF ring: the most recent 256 cleared receipts stay readable
    /// (`state`/`status` report `.settled`) and their scopes dedup; the
    /// OLDEST settled ACK is dropped at the ring bound (late-settlement
    /// classification window), never an unsettled obligation. Total memory
    /// stays bounded at 64 live + 256 settled = 320 records.
    private var settledRecords: [String: SettledRecord] = [:]
    private var scopeIndex: [String: String] = [:]   // scopeKey -> requestID (live or settled)
    private var order: [String] = []                 // FIFO of queued ids
    private var settledOrder: [String] = []          // bounded settled ring
    private var retiredClaims: Set<Int64> = []
    private var retiredClaimOrder: [Int64] = []
    private var nextClaim: Int64 = 1
    private var boundEpoch: UInt64 = 0
    private var queuedBytes = 0
    /// The generation-owned lifecycle trigger (installed by the G02
    /// composition's cleanup-sweep path). A REAL cleared receipt fires it
    /// once so the ORIGINAL durable V36 retry sweep can finalize the
    /// retained row promptly instead of waiting for the next launch.
    /// Cleared on any generation rebind; the consumer re-installs for its
    /// own generation. Nothing else settles work: this only RE-DRIVES the
    /// existing owned retry path (no polling, no parallel system).
    private var settlementTrigger: (@Sendable () -> Void)?
    private var settlementTriggerEpoch: UInt64 = 0
    private var counters = Counters()

    init() {}

    // MARK: Generation (trusted host only; model admission fences never touch this)

    /// Strictly-newer positive epoch rebind (same monotonic rule as the
    /// shell mailbox). CLAIMED records return to the queue: the previous
    /// generation's pump may have died without delivering a receipt, and
    /// the only honest state is "unknown, retained, retryable". Their old
    /// claim tokens become stale (a late receipt under them is refused; the
    /// record is retained).
    @discardableResult
    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard newEpoch != 0, newEpoch > boundEpoch else { return false }
        boundEpoch = newEpoch
        // A trigger owned by an OLDER epoch never qualifies for this
        // generation; equal-epoch sticky installs (sweep-before-bind) stay.
        if settlementTriggerEpoch != newEpoch {
            settlementTrigger = nil
            settlementTriggerEpoch = 0
        }
        for request in requests.values where request.state == .claimed {
            retireClaimLocked(request.claimToken)
            request.claimToken = 0
            request.state = .queued
            order.append(request.id)
            queuedBytes += request.payload.count
            counters.requeuedAfterGeneration += 1
        }
        condition.broadcast()
        return true
    }

    public var liveEpoch: UInt64 {
        condition.lock(); defer { condition.unlock() }
        return boundEpoch
    }

    // MARK: Core-side issue (idempotent per scope)

    /// Enqueues (or re-returns the existing) request for the proven scope.
    /// Works unbound; returns nil only on malformed scope or saturation —
    /// the caller MUST then retain its durable records (a refused enqueue
    /// is never a cleanup and never drops the obligation silently).
    public func request(scope: LinuxRuntimeCleanupScope) -> String? {
        guard scope.targetEpoch != 0,
              scope.workspaceRelativePath == "PrivateTasks/\(scope.conversationID.uuidString)",
              let payload = scope.payloadJSON else {
            condition.lock(); counters.rejectedMalformed += 1; condition.unlock()
            return nil
        }
        let key = scope.scopeKey
        condition.lock()
        defer { condition.unlock() }
        if let existing = scopeIndex[key] {
            counters.dedupHits += 1
            return existing
        }
        guard requests.count < LinuxRuntimeCleanupLimits.maximumLiveRequests,
              queuedBytes + payload.count <= LinuxRuntimeCleanupLimits.maximumQueuedBytes else {
            counters.rejectedSaturated += 1
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...UInt8.max) }
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        let request = Request(id: id, scope: scope, payload: payload)
        requests[id] = request
        scopeIndex[key] = id
        order.append(id)
        queuedBytes += payload.count
        counters.enqueued += 1
        condition.broadcast()
        return id
    }

    public func state(requestID: String) -> LinuxRuntimeCleanupRequestState {
        condition.lock(); defer { condition.unlock() }
        if let settled = settledRecords[requestID] {
            return .settled(receiptDigest: settled.digest)
        }
        guard let request = requests[requestID] else { return .unknown }
        switch request.state {
        case .queued:
            if let reason = request.lastRefusal { return .retrying(reason: reason) }
            return .queued
        case .claimed:
            return .claimed(claimToken: request.claimToken)
        }
    }

    /// True only when the scope is proven cleared by a REAL settled receipt.
    public func isSettledCleared(requestID: String) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return settledRecords[requestID] != nil
    }

    // MARK: Host ingress

    /// Bounded claim of one queued request for the CURRENT bound generation.
    /// >0 = claim token, 0 = none/timeout, -1 = lane unbound. Never
    /// fabricates a claim.
    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        guard boundEpoch != 0 else { return -1 }
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutMillis)) / 1000.0)
        while true {
            if let id = order.first, let request = requests[id], request.state == .queued {
                order.removeFirst()
                request.state = .claimed
                request.claimToken = nextClaim
                nextClaim += 1
                queuedBytes = max(0, queuedBytes - request.payload.count)
                counters.claims += 1
                return request.claimToken
            }
            if Date() >= deadline { return 0 }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            if boundEpoch == 0 { return -1 }
        }
    }

    public func isLiveClaim(_ claim: Int64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let id = liveClaimOwner(claim) else { return false }
        return requests[id]?.state == .claimed && requests[id]?.claimToken == claim
    }

    /// {"requestID","operation","targetEpoch","boundEpoch"} for the claim.
    public func describe(claim: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        condition.lock()
        guard let id = liveClaimOwner(claim), let request = requests[id],
              request.state == .claimed, request.claimToken == claim else {
            condition.unlock()
            return cleanupError(retiredClaims.contains(claim) ? "staleClaim" : "unknownClaim",
                                buffer: buffer, capacity: capacity)
        }
        condition.unlock()
        return cleanupReply([
            "ok": true,
            "requestID": request.id,
            "operation": "runtimeWorkspaceCopies.clear",
            "targetEpoch": request.scope.targetEpoch,
            "boundEpoch": liveEpoch,
        ], buffer: buffer, capacity: capacity)
    }

    public func payloadLength(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let id = liveClaimOwner(claim), let request = requests[id],
              request.state == .claimed, request.claimToken == claim else { return -1 }
        return Int32(request.payload.count)
    }

    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let id = liveClaimOwner(claim), let request = requests[id],
              request.state == .claimed, request.claimToken == claim else { return -1 }
        guard capacity >= 0, let buffer, Int(capacity) >= request.payload.count else { return -2 }
        request.payload.withUnsafeBytes { raw in
            buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: request.payload.count)
        }
        return Int32(request.payload.count)
    }

    /// Settle one claim with the typed receipt. Returns a bounded reply:
    /// `{"ok":true,"state":"cleared"|"retrying"}` or
    /// `{"ok":false,"code":...}`. ANY refusal retains the record.
    public func complete(claim: Int64, receipt: Data,
                         buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        var responseObject: [String: Any]?
        var responseErrorCode: String?
        condition.lock()
        if boundEpoch == 0 {
            counters.refusedUnbound += 1
            responseErrorCode = "laneUnbound"
        } else if let id = liveClaimOwner(claim), let request = requests[id],
                  request.state == .claimed, request.claimToken == claim {
            if let parsed = LinuxRuntimeCleanupReceipt.parse(receipt) {
                let (scopeFields, outcome) = parsed
                if scopeFields.requestID != request.id
                    || scopeFields.conversationID != request.scope.conversationID.uuidString
                    || scopeFields.projectID != request.scope.projectID.uuidString
                    || scopeFields.targetEpoch != request.scope.targetEpoch {
                    // Scope/epoch mismatch: refuse and RE-QUEUE the record.
                    counters.refusedScopeMismatch += 1
                    requeueLocked(request)
                    responseErrorCode = "scopeMismatch"
                } else {
                    switch outcome {
                    case .cleared(let proof):
                        if Int32(getuid()) == proof.runtimeUID {
                            // Same-UID claim cannot prove runtime-side IO for
                            // the distinct runtime lane. Refusal + retention.
                            counters.refusedIdentity += 1
                            requeueLocked(request)
                            responseErrorCode = "identityNotDistinct"
                        } else {
                            let canonical: [String: Any] = ["requestID": request.id,
                                             "conversationID": request.scope.conversationID.uuidString,
                                             "projectID": request.scope.projectID.uuidString,
                                             "targetEpoch": request.scope.targetEpoch,
                                             "runtimeUID": proof.runtimeUID,
                                             "certificateDigest": proof.certificateDigest,
                                             "packageVersion": proof.packageVersion,
                                             "binderIdentity": proof.binderIdentity,
                                             "executorProofDigest": proof.executorProofDigest,
                                             "pathsRemoved": proof.pathsRemoved,
                                             "bytesFreed": proof.bytesFreed]
                            if JSONSerialization.isValidJSONObject(canonical),
                               let data = try? JSONSerialization.data(withJSONObject: canonical,
                                                                       options: [.sortedKeys]) {
                                let settledDigest = FloeDigest.sha256Hex(data)
                                // Leave the LIVE table: the settled ACK lives
                                // in the bounded proof ring (capacity fix —
                                // the 64-slot ceiling bounds UNSETTLED work
                                // only). The scope keeps deduping to this id
                                // while the ACK stands.
                                request.claimToken = 0
                                let scopeKey = request.scope.scopeKey
                                requests.removeValue(forKey: request.id)
                                settledRecords[request.id] = SettledRecord(scopeKey: scopeKey,
                                                                           targetEpoch: request.scope.targetEpoch,
                                                                           digest: settledDigest)
                                retireClaimLocked(claim)
                                counters.settledCleared += 1
                                trackSettledLocked(request.id)
                                responseObject = ["ok": true, "state": "cleared",
                                                  "receiptDigest": settledDigest]
                            } else {
                                counters.rejectedMalformed += 1
                                requeueLocked(request)
                                responseErrorCode = "receiptCanonicalFailed"
                            }
                        }
                    case .refused(let reason):
                        // Honest runtime refusal: the obligation RETAINS and
                        // re-queues (never a cleared workspace).
                        counters.runtimeRefusalsRetained += 1
                        request.lastRefusal = reason
                        requeueLocked(request)
                        retireClaimLocked(claim)
                        responseObject = ["ok": true, "state": "retrying", "reason": reason]
                    }
                }
            } else {
                // Malformed receipts never settle anything; the claim stands
                // for its real settlement or a generation rebind.
                counters.rejectedMalformed += 1
                responseErrorCode = "receiptMalformed"
            }
        } else {
            if retiredClaims.contains(claim) { counters.refusedStaleClaim += 1 }
            else { counters.refusedUnknown += 1 }
            responseErrorCode = retiredClaims.contains(claim) ? "staleClaim" : "unknownClaim"
        }
        let fireSettlement = responseObject?["state"] as? String == "cleared"
        var trigger: (@Sendable () -> Void)?
        if fireSettlement, settlementTriggerEpoch == boundEpoch {
            trigger = settlementTrigger
        }
        condition.broadcast()
        condition.unlock()
        // The retained V36 row finalizes through the ORIGINAL owned retry
        // sweep: re-drive it once per real cleared receipt (generation
        // -fenced inside the consumer). Never a poll, never a fake settle.
        trigger?()
        if let responseObject {
            return cleanupReply(responseObject, buffer: buffer, capacity: capacity)
        }
        return cleanupError(responseErrorCode ?? "internal", buffer: buffer, capacity: capacity)
    }

    /// Install the lifecycle trigger keyed to an epoch (the G02 owned
    /// cleanup-sweep path does this once per generation). The trigger is
    /// STICKY-BY-EPOCH: the sweep can run before the host binds the lane
    /// generation, so installation does not require a current bind; a
    /// cleared receipt fires it only while the lane's bound epoch equals the
    /// trigger epoch. A rebind to a DIFFERENT epoch replaces ownership
    /// (the newer generation's sweep re-installs for its own epoch).
    public func installSettlementTrigger(epoch: UInt64, _ body: @escaping @Sendable () -> Void) {
        condition.lock()
        guard epoch != 0 else { condition.unlock(); return }
        settlementTrigger = body
        settlementTriggerEpoch = epoch
        condition.unlock()
    }

    public func statsJSON() -> String {
        condition.lock(); defer { condition.unlock() }
        var queued = 0, claimed = 0
        for request in requests.values {
            switch request.state {
            case .queued: queued += 1
            case .claimed: claimed += 1
            }
        }
        let settled = settledRecords.count
        let object: [String: Any] = [
            "boundEpoch": boundEpoch,
            "queued": queued, "claimed": claimed, "settled": settled,
            "enqueued": counters.enqueued, "dedupHits": counters.dedupHits,
            "rejectedSaturated": counters.rejectedSaturated,
            "rejectedMalformed": counters.rejectedMalformed,
            "claims": counters.claims,
            "requeuedAfterGeneration": counters.requeuedAfterGeneration,
            "settledCleared": counters.settledCleared,
            "runtimeRefusalsRetained": counters.runtimeRefusalsRetained,
            "refusedStaleClaim": counters.refusedStaleClaim,
            "refusedUnknown": counters.refusedUnknown,
            "refusedScopeMismatch": counters.refusedScopeMismatch,
            "refusedIdentity": counters.refusedIdentity,
            "refusedUnbound": counters.refusedUnbound,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{\"error\":\"stats_encoding\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Full state for one request (lifecycle/host readback; settled digest
    /// only after a REAL receipt).
    public func statusJSON(requestID: String) -> String {
        condition.lock(); defer { condition.unlock() }
        if let settled = settledRecords[requestID] {
            var object: [String: Any] = ["ok": true, "requestID": requestID,
                                         "targetEpoch": settled.targetEpoch,
                                         "state": "settled",
                                         "receiptDigest": settled.digest]
            guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                         options: [.sortedKeys]) else {
                return "{\"ok\":false,\"state\":\"unknown\"}"
            }
            _ = object
            return String(decoding: data, as: UTF8.self)
        }
        guard let request = requests[requestID] else {
            return "{\"ok\":false,\"state\":\"unknown\"}"
        }
        var object: [String: Any] = ["ok": true, "requestID": request.id,
                                     "targetEpoch": request.scope.targetEpoch]
        switch request.state {
        case .queued:
            object["state"] = request.lastRefusal == nil ? "queued" : "retrying"
            if let reason = request.lastRefusal { object["reason"] = reason }
        case .claimed:
            object["state"] = "claimed"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{\"ok\":false,\"state\":\"unknown\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Internals (condition held)

    private func liveClaimOwner(_ claim: Int64) -> String? {
        for request in requests.values where request.state == .claimed && request.claimToken == claim {
            return request.id
        }
        return nil
    }

    private func requeueLocked(_ request: Request) {
        guard request.state == .claimed else { return }
        request.state = .queued
        request.claimToken = 0
        order.append(request.id)
        queuedBytes += request.payload.count
    }

    private func retireClaimLocked(_ claim: Int64) {
        retiredClaims.insert(claim)
        retiredClaimOrder.append(claim)
        while retiredClaimOrder.count > LinuxRuntimeCleanupLimits.maximumRetired {
            retiredClaims.remove(retiredClaimOrder.removeFirst())
        }
    }

    /// Test/reset hygiene (host re-bootstrap between generations; mirrors
    /// LinuxShellMailbox.resetForRebind).
    internal func resetForRebind() {
        condition.lock()
        requests.removeAll()
        settledRecords.removeAll()
        scopeIndex.removeAll()
        order.removeAll()
        settledOrder.removeAll()
        retiredClaims.removeAll()
        retiredClaimOrder.removeAll()
        queuedBytes = 0
        boundEpoch = 0
        nextClaim = 1
        settlementTrigger = nil
        settlementTriggerEpoch = 0
        counters = Counters()
        condition.broadcast()
        condition.unlock()
    }

    /// Settled ACK ring bookkeeping (called with the condition held): the
    /// ring bounds at maximumRetired (256) and drops the OLDEST settled
    /// receipt first. Unsettled obligations (queued/claimed) are NEVER
    /// touched here — eviction only ever forgets an already-cleared ACK's
    /// late-settlement window, exactly the frozen ring semantics.
    private func trackSettledLocked(_ id: String) {
        settledOrder.append(id)
        while settledOrder.count > LinuxRuntimeCleanupLimits.maximumRetired {
            dropSettledLocked(settledOrder.removeFirst())
        }
    }

    private func dropSettledLocked(_ id: String) {
        if let settled = settledRecords.removeValue(forKey: id) {
            // Only drop the dedup entry while it still points at THIS id.
            if scopeIndex[settled.scopeKey] == id {
                scopeIndex.removeValue(forKey: settled.scopeKey)
            }
        }
    }
}

// MARK: - reply/error helpers

private func cleanupReply(_ object: [String: Any], buffer: UnsafeMutablePointer<CChar>?,
                          capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return LinuxRuntimeCleanupCode.invalidArguments }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          data.count + 1 <= Int(capacity) else {
        return LinuxRuntimeCleanupCode.bufferTooSmall
    }
    for (index, byte) in data.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[data.count] = 0
    return Int32(data.count)
}

private func cleanupError(_ code: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
    cleanupReply(["ok": false, "code": String(code.prefix(64))], buffer: buffer, capacity: capacity)
}

private func cleanupCString(_ pointer: UnsafePointer<CChar>?, maximum: Int) -> String? {
    guard let pointer else { return nil }
    var bytes: [UInt8] = []
    var index = 0
    while index < maximum {
        let byte = UInt8(bitPattern: pointer[index])
        if byte == 0 { break }
        bytes.append(byte)
        index += 1
    }
    guard index < maximum, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
    return text
}

// MARK: - Trusted-host C ABI (JNI; never a model route)

/// Bind the cleanup lane to the accepted native Root epoch (strictly newer
/// positive; same monotonic rule as the shell mailbox). Re-binds RE-QUEUE
/// claimed records honestly. 0 => refused.
@_cdecl("floe_linux_runtime_cleanup_bind")
public func floeLinuxRuntimeCleanupBind(_ epoch: UInt64) -> Int32 {
    LinuxRuntimeCleanupLane.shared.bind(epoch: epoch)
        ? LinuxRuntimeCleanupCode.ok : LinuxRuntimeCleanupCode.invalidArguments
}

/// Claim one queued cleanup request (bounded wait). >0 = claim token,
/// 0 = none/timeout, -1 = lane unbound, -2 = invalid bound.
@_cdecl("floe_linux_runtime_cleanup_next")
public func floeLinuxRuntimeCleanupNext(_ timeoutMillis: Int32) -> Int64 {
    guard timeoutMillis >= 0, timeoutMillis <= 60_000 else { return -2 }
    return LinuxRuntimeCleanupLane.shared.nextClaim(timeoutMillis: timeoutMillis)
}

@_cdecl("floe_linux_runtime_cleanup_describe")
public func floeLinuxRuntimeCleanupDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                            _ capacity: Int32) -> Int32 {
    LinuxRuntimeCleanupLane.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_linux_runtime_cleanup_payload_length")
public func floeLinuxRuntimeCleanupPayloadLength(_ claim: Int64) -> Int32 {
    LinuxRuntimeCleanupLane.shared.payloadLength(claim: claim)
}

@_cdecl("floe_linux_runtime_cleanup_take_payload")
public func floeLinuxRuntimeCleanupTakePayload(_ claim: Int64, _ buffer: UnsafeMutablePointer<UInt8>?,
                                               _ capacity: Int32) -> Int32 {
    LinuxRuntimeCleanupLane.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_linux_runtime_cleanup_is_live")
public func floeLinuxRuntimeCleanupIsLive(_ claim: Int64) -> Int32 {
    LinuxRuntimeCleanupLane.shared.isLiveClaim(claim) ? 1 : 0
}

/// Settle a claim with the typed receipt JSON. The lane copies nothing from
/// the caller buffer after return; the caller may free the bytes as soon as
/// this call returns (the claim/record state only advances on a VALID
/// settlement; timeout/cancellation/Binder loss NEVER becomes drain).
@_cdecl("floe_linux_runtime_cleanup_complete")
public func floeLinuxRuntimeCleanupComplete(_ claim: Int64, _ receiptJson: UnsafePointer<CChar>?,
                                            _ receiptLen: Int32, _ buffer: UnsafeMutablePointer<CChar>?,
                                            _ capacity: Int32) -> Int32 {
    guard claim > 0, receiptLen > 0,
          receiptLen <= Int32(LinuxRuntimeCleanupLimits.maximumReceiptBytes),
          let receiptJson else {
        return cleanupError("invalidArguments", buffer: buffer, capacity: capacity)
    }
    let data = Data(bytes: receiptJson, count: Int(receiptLen))
    return LinuxRuntimeCleanupLane.shared.complete(claim: claim, receipt: data,
                                                   buffer: buffer, capacity: capacity)
}

/// Lifecycle/host readback for one request id.
@_cdecl("floe_linux_runtime_cleanup_status")
public func floeLinuxRuntimeCleanupStatus(_ requestID: UnsafePointer<CChar>?,
                                          _ buffer: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    guard let text = cleanupCString(requestID, maximum: 40),
          text.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
          let buffer, capacity > 0 else { return LinuxRuntimeCleanupCode.invalidArguments }
    let json = LinuxRuntimeCleanupLane.shared.statusJSON(requestID: text)
    let bytes = Array(json.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return LinuxRuntimeCleanupCode.bufferTooSmall }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

/// Typed counts only (never payload/paths).
@_cdecl("floe_linux_runtime_cleanup_stats")
public func floeLinuxRuntimeCleanupStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return LinuxRuntimeCleanupCode.invalidArguments }
    let bytes = Array(LinuxRuntimeCleanupLane.shared.statsJSON().utf8)
    guard bytes.count + 1 <= Int(capacity) else { return LinuxRuntimeCleanupCode.bufferTooSmall }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
