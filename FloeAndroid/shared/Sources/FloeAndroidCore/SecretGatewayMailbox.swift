// RB2-REPAIR PRIVATE CANDIDATE MIRROR (job-ffa06be4f2d34ac4, 2026-10-19).
// Preimage: FloeAndroid/shared/Sources/FloeAndroidCore/SecretGatewayMailbox.swift
// (regular published gateway file) SHA-256 64f28bf9bbb973d9c29460498e4908a723c7
// c0636dbed8502777c32c5fecfdc1 — byte-identical baseline; every change below is
// MAIN_AUTHORIZED ADDITIVE ONLY per MAIN_GATEWAY_PHYSICAL_LIFETIME_API_GAP_
// 20261019.json: the existing CRUD semantics, error cases, reference
// namespaces, C/JNI ABI, watchdog/cancel/bind/complete decisions and all
// frozen behavior are preserved EXACTLY; this mirror only adds per-operation
// physical-lifetime records, an opt-in observation seam, and the receipt
// plumbing on new methods. NO live/root write is performed by this package;
// future Main serialized publication replaces the overlay copy atomically and
// appends PROVENANCE (see repair REPORT §symlinks). On upstream drift the
// narrow delta patch (patches/MAILBOX-PHYSICAL.delta.patch) must be rebased
// onto the CURRENT bytes; never overwrite with this full file to satisfy a
// stale hash.
// SPDX-License-Identifier: MPL-2.0
// SPDX-License-Identifier: MPL-2.0
//
// Product-UID credential gateway — P1 Swift request mailbox.
//
// Direction A (Main-approved rev4): Swift owns the inverse request mailbox and
// the single heartbeat watchdog; the Android Application owns one dedicated
// Kotlin poller that claims, describes, reserves, checks and submits exactly
// one store operation per claim over JNI. There is no Swift -> JVM callback,
// no global JNI reference and no AttachCurrentThread on this path.
//
// This file is the complete mailbox/ABI candidate. It is NOT compiled by the
// source-authoring package that produced it; see the private HANDOFF.md for
// the separately serialized qualification package.
import Foundation
import Dispatch

// MARK: - Public typed surface

/// Typed fail-closed errors for the product credential gateway. The frozen
/// `SecretGatewayError` (CredentialBackend.swift) stays unchanged; this enum
/// is the richer surface used by the mailbox and by later facade packages.
public enum IntentRejection: String, Error, Equatable, Sendable {
    case unknownToken
    case consumed
    case expired
    case routeMismatch
    case subjectMismatch
    case envelopeDivergence
    case createConflict
    case baseRevisionConflict
    case intentSaturated
}

public enum SecretBackendError: Error, Equatable, Sendable {
    case invalidReference
    case invalidValue
    case corruptRecord
    case authenticationFailed
    case keyUnavailable
    case keyStoreFailure
    case storageFailure
    case deleteFailed
    case deviceLocked
    /// Reserved by the original contract; unreachable for the current key
    /// generation (no user-authentication-bound keys).
    case authRequired
    case dispatcherCancelled
    case dispatcherReplaced
    case gatewayClosed
    case mailboxSaturated
    case dispatcherUnresponsive
    case backendBusy
    case quarantined
    case abandoned
    case generationFailure
    case intentRejected(IntentRejection)
    case `internal`
}

/// Ingress subject kinds. The closed vocabulary is enforced by the vault; a
/// provider ID is never accepted as an MCP identity.
///
/// MC-WEBSEARCH-3 (MAIN_WEB_SEARCH_SECURE_INGRESS_DECISION_20261019.json):
/// `webSearchSave` is the Main-authorized additive closed kind for the
/// secure web-search Set ingress. The App binder rejects providerSave/
/// mcpSave for the web-search save capability; unrelated subjects can never
/// consume a web-search token (vault cross-subject rules).
public enum SubjectKind: String, Sendable, CaseIterable {
    case providerSave
    case mcpSave
    case webSearchSave
}

public enum SecretOperation: String, Sendable {
    case read
    case write
    case delete
}

/// Route binding supplied to the handler by the host route registry. It is
/// non-secret; only token+generation equality is checked by the vault.
public struct RouteBinding: Equatable, Sendable {
    public let token: String
    public let generation: UInt64
    public init(token: String, generation: UInt64) {
        self.token = token
        self.generation = generation
    }
}

/// Optional base CAS metadata carried by a save intent. The CAS itself is a
/// handler step, never part of the vault.
public struct SaveIntentBaseRevision: Equatable, Sendable {
    public let resourceID: String
    public let version: String
    public init(resourceID: String, version: String) {
        self.resourceID = resourceID
        self.version = version
    }
}

/// Bounds live in exactly one Swift file (this one). Kotlin owns the matching
/// dispatcher-side constants in SecretGatewayDispatcher.kt.
public enum SecretGatewayLimits {
    public static let maximumQueue = 32
    public static let maximumPermits = 16
    public static let maximumPendingPayloadBytes = 262_144
    public static let maximumSecretBytes = 65_536
    public static let maximumDescriptorBytes = 512
    public static let heartbeatStaleMillis: UInt64 = 5_000
    public static let watchdogStaleMillis: UInt64 = 10_000
    public static let watchdogTickMillis: UInt64 = 1_000
    public static let backendProgressWindowMillis: UInt64 = 10_000
    public static let canonicalReferenceLogicalBytes = 71
    public static let canonicalReferenceCapacity = 72
    public static let ingressTokenLogicalBytes = 39
    public static let ingressTokenCapacity = 40
}

// MARK: - Reference and identity checks

enum SecretGatewayIdentity {
    private static let referencePrefix = "ref:v1:"
    private static let tokenPrefix = "int:v1:"

    /// Strict canonical gateway reference: exactly 71 UTF-8 bytes
    /// (`ref:v1:` + 64 lowercase hex). The backend's generic alphabet is
    /// deliberately NOT used here; strictness lives in the product layer.
    static func isCanonicalReference(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == SecretGatewayLimits.canonicalReferenceLogicalBytes,
              value.hasPrefix(referencePrefix) else { return false }
        let hexStart = value.index(value.startIndex, offsetBy: referencePrefix.count)
        let hex = value[hexStart...]
        guard hex.count == 64 else { return false }
        return hex.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    /// Strict ingress handle: exactly 39 UTF-8 bytes (`int:v1:` + 32 lowercase
    /// hex). Capacity including the NUL terminator is 40.
    static func isCanonicalIngressToken(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == SecretGatewayLimits.ingressTokenLogicalBytes,
              value.hasPrefix(tokenPrefix) else { return false }
        let hexStart = value.index(value.startIndex, offsetBy: tokenPrefix.count)
        let hex = value[hexStart...]
        guard hex.count == 32 else { return false }
        return hex.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

// MARK: - Mailbox

/// Single process-wide inverse request mailbox + heartbeat watchdog.
///
/// Lock discipline: every mutable field is guarded by `condition`. Caller
/// continuations are resumed only OUTSIDE the lock. One watchdog thread waits
/// on the same condition variable and never resumes a caller twice.
public final class SecretRequestMailbox: @unchecked Sendable {
    public static let shared = SecretRequestMailbox()

    private enum RetiredReason: UInt8 {
        case resolved
        case cancelled
        case replaced
        case closed
        case watchdog
    }

    private struct Retired {
        let epoch: UInt64
        let reason: RetiredReason
    }

    private final class WatchdogHandle: @unchecked Sendable {
        let semaphore: DispatchSemaphore
        weak var mailbox: SecretRequestMailbox?
        init(semaphore: DispatchSemaphore, mailbox: SecretRequestMailbox) {
            self.semaphore = semaphore
            self.mailbox = mailbox
        }
    }

    private struct Counters {
        var saturated = 0
        var backendBusy = 0
        var dispatcherCapacityRejects = 0
        var droppedCanceled = 0
        var skippedNoEffect = 0
        var watchdogSettled = 0
        var effectCommitted = 0
        var effectFailed = 0
        var effectUnknown = 0
        var rejectedStale = 0
        var rejectedMismatch = 0
        var abandoned = 0
        var abandonedUnsettleable = 0
        var generationFailed = 0
        var settledRebind = 0
        var settledClosed = 0
        var exhausted = 0
    }

    fileprivate final class Ticket: @unchecked Sendable {
        enum State {
            case draft
            case queued
            case claimed
            case callerSettledExecutionOutstanding
            case resolved
            case cancelled
        }

        let token: Int64
        let createdEpoch: UInt64
        let op: SecretOperation
        let reference: String
        var state: State = .draft
        var payload: Data?
        var continuation: CheckedContinuation<Data?, Error>?
        var permitHeld = false
        var unknownEffectRecorded = false

        init(token: Int64, createdEpoch: UInt64, op: SecretOperation,
             reference: String, payload: Data?) {
            self.token = token
            self.createdEpoch = createdEpoch
            self.op = op
            self.reference = reference
            self.payload = payload
        }
    }

    private let condition = NSCondition()
    private var bound = false
    private var closed = true
    private var epoch: UInt64 = 0
    private var nextToken: Int64 = 1
    private var queue: [Int64] = []
    private var tickets: [Int64: Ticket] = [:]
    private var retired: [Int64: Retired] = [:]
    private var retiredOrder: [Int64] = []
    private var permitsHeld = 0
    private var queuedPayloadBytes = 0
    private var lastHeartbeat: UInt64 = 0
    private var lastProgress: UInt64 = 0
    private var lastWatchdogAt: UInt64 = 0
    private var readyAcked = false
    private var counters = Counters()

    // MARK: RB2-REPAIR additive — per-operation physical lifetime records
    // (Main-authorized 2026-10-19; MC-R4). One record exists per OBSERVED
    // operation between publish-accept and the authoritative terminal truth
    // (a real host complete(), or provable never-dispatch removal). Logical
    // retirement of the ticket (watchdog caller-settle, cancel-after-claim,
    // bind .claimed removal, remove()/close) NEVER settles a physical record:
    // the record is exactly the thing the caller cannot infer from statsJSON,
    // global counters, or durable intent. Bounded; opt-in per call.
    private struct PhysicalRecord {
        enum State {
            case queued
            case claimedOutstanding
            case settled(status: Int32)
            case neverDispatched(reason: PhysicalNeverDispatchedReason)
        }
        var state: State
        let epoch: UInt64
        let kind: PhysicalOperationKind
        let reference: String
    }
    private var physicalRecords: [Int64: PhysicalRecord] = [:]
    private var physicalOrder: [Int64] = []
    private static let maximumPhysicalRecords = 512

    // MARK: MC-CAPACITY-2 physical-settlement waiters
    //
    // `awaitPhysicalSettlement` subscribers keyed by claim. A waiter is
    // registered ONLY while the record is non-terminal and is resumed
    // EXACTLY ONCE with the terminal snapshot (or `.notRecorded` on mailbox
    // reset), always OUTSIDE `condition` (Main requiredSemantics:
    // notification atomic with the snapshot/registration transition,
    // callbacks outside locks). The retired 20 ms poll is replaced by this
    // push channel; cancellation performs a lock-protected removal and
    // resumes the removed waiter with the CURRENT snapshot honestly (when
    // the terminal transition already claimed the waiter, cancellation finds
    // nothing and the transition's value wins — exactly-once delivery).
    private typealias PhysicalWaiter = CheckedContinuation<PhysicalOperationSnapshot, Never>
    private struct PhysicalWaiterEntry {
        let id: Int64
        let continuation: PhysicalWaiter
    }
    private var physicalWaiters: [Int64: [PhysicalWaiterEntry]] = [:]
    private var nextPhysicalWaiterID: Int64 = 1

    /// Pop every waiter registered for `claim`. Must be called with
    /// `condition` held; the RETURNED continuations are resumed by the
    /// caller only AFTER the lock is released, each with the SAME terminal
    /// snapshot value (atomic with the state transition that produced it).
    private func takePhysicalWaitersLocked(claim: Int64) -> [PhysicalWaiterEntry] {
        let waiters = physicalWaiters[claim] ?? []
        physicalWaiters.removeValue(forKey: claim)
        return waiters
    }

    private static func physicalKind(for op: SecretOperation) -> PhysicalOperationKind {
        switch op {
        case .read: return .read
        case .write: return .write
        case .delete: return .delete
        }
    }

    // Test-tunable copies of the production constants. Production never calls
    // the configuration helpers; the values above remain authoritative.
    private var heartbeatStaleMillis = SecretGatewayLimits.heartbeatStaleMillis
    private var watchdogStaleMillis = SecretGatewayLimits.watchdogStaleMillis
    private var watchdogTickMillis = SecretGatewayLimits.watchdogTickMillis
    private var backendProgressWindowMillis = SecretGatewayLimits.backendProgressWindowMillis
    private var clockOverride: (() -> UInt64)?

    private var watchdogThread: Thread?
    private var watchdogExit: DispatchSemaphore?
    private var watchdogRunning = false
    private var watchdogStop = false

    private init() {}

    // MARK: Clock

    private func nowLocked() -> UInt64 {
        if let clockOverride { return clockOverride() }
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    // MARK: Ticket creation / publication

    private func makeTicket(op: SecretOperation, reference: String,
                            payload: Data?) throws -> Ticket {
        condition.lock()
        defer { condition.unlock() }
        if nextToken == Int64.max {
            counters.exhausted += 1
            throw SecretBackendError.backendBusy
        }
        let token = nextToken
        nextToken += 1
        return Ticket(token: token, createdEpoch: epoch, op: op,
                      reference: reference, payload: payload)
    }

    private func publish(_ ticket: Ticket,
                         continuation: CheckedContinuation<Data?, Error>,
                         onQueued: ((Bool) -> Void)? = nil) {
        var failure: Error?
        var didQueue = false
        var physicalTracked = false
        condition.lock()
        if ticket.state == .cancelled {
            failure = CancellationError()
        } else if closed {
            failure = SecretBackendError.gatewayClosed
        } else if !bound {
            failure = SecretBackendError.dispatcherUnresponsive
        } else if ticket.createdEpoch != epoch {
            failure = SecretBackendError.dispatcherReplaced
        } else {
            let now = nowLocked()
            if now >= lastHeartbeat && now - lastHeartbeat > heartbeatStaleMillis {
                failure = SecretBackendError.dispatcherUnresponsive
            } else if permitsHeld >= SecretGatewayLimits.maximumPermits,
                      now >= lastProgress,
                      now - lastProgress > backendProgressWindowMillis {
                counters.backendBusy += 1
                failure = SecretBackendError.backendBusy
            } else if queue.count >= SecretGatewayLimits.maximumQueue {
                counters.saturated += 1
                failure = SecretBackendError.mailboxSaturated
            } else if let payload = ticket.payload,
                      queuedPayloadBytes + payload.count
                        > SecretGatewayLimits.maximumPendingPayloadBytes {
                counters.saturated += 1
                failure = SecretBackendError.mailboxSaturated
            } else {
                // MC-CAPACITY-2: when the caller asked for the individual
                // physical observation seam, the bounded record MUST be
                // retained BEFORE the ticket mutates to .queued. If the
                // ledger cannot retain it (all 512 records still awaiting
                // consumer acknowledgement), the observed publish refuses
                // TRUTHFULLY here — BEFORE queue/dispatch/effect — with the
                // frozen saturation vocabulary. The ticket never enters the
                // queue: there is nothing to cancel, claim or settle, and
                // the absence of a receipt is itself the per-attempt proof
                // of no dispatch. Unobserved (legacy) CRUD never reaches
                // this path and is byte-for-byte unchanged.
                if onQueued != nil && !registerPhysicalLocked(ticket: ticket) {
                    counters.saturated += 1
                    failure = SecretBackendError.mailboxSaturated
                } else {
                    ticket.state = .queued
                    ticket.continuation = continuation
                    tickets[ticket.token] = ticket
                    queue.append(ticket.token)
                    queuedPayloadBytes += ticket.payload?.count ?? 0
                    if onQueued != nil {
                        physicalTracked = true
                        didQueue = true
                    }
                    condition.broadcast()
                }
            }
        }
        if failure != nil {
            zeroPayloadLocked(ticket)
        }
        condition.unlock()
        if let failure {
            continuation.resume(throwing: failure)
        }
        // RB2-REPAIR additive: the receipt callback runs OUTSIDE the
        // condition (Main requiredSemantics) exactly once, on queue-accept.
        if didQueue {
            onQueued?(physicalTracked)
        }
    }

    // MARK: Cancellation

    /// Called by `withTaskCancellationHandler` on any thread. A queued ticket
    /// is removed and its payload zeroed (provably no effect). A claimed
    /// ticket becomes CALLER_SETTLED_EXECUTION_OUTSTANDING: the caller is
    /// resumed once with CancellationError while its permit and execution
    /// bookkeeping remain until a real completion/explicit remove.
    private func cancel(_ ticket: Ticket) {
        var resume: CheckedContinuation<Data?, Error>?
        var physicalResumes: [(waiters: [PhysicalWaiterEntry], snapshot: PhysicalOperationSnapshot)] = []
        condition.lock()
        switch ticket.state {
        case .draft:
            ticket.state = .cancelled
            zeroPayloadLocked(ticket)
            resume = ticket.continuation
            ticket.continuation = nil
        case .queued:
            if let index = queue.firstIndex(of: ticket.token) {
                queue.remove(at: index)
            }
            queuedPayloadBytes -= ticket.payload?.count ?? 0
            if queuedPayloadBytes < 0 { queuedPayloadBytes = 0 }
            ticket.state = .cancelled
            zeroPayloadLocked(ticket)
            counters.droppedCanceled += 1
            addRetiredLocked(token: ticket.token, epoch: ticket.createdEpoch, reason: .cancelled)
            tickets.removeValue(forKey: ticket.token)
            let waiters = markPhysicalNeverDispatchedLocked(
                token: ticket.token, reason: .cancelledBeforeClaim)
            if !waiters.isEmpty {
                physicalResumes.append((waiters, .neverDispatched(reason: .cancelledBeforeClaim)))
            }
            resume = ticket.continuation
            ticket.continuation = nil
        case .claimed:
            ticket.state = .callerSettledExecutionOutstanding
            markUnknownLocked(ticket)
            resume = ticket.continuation
            ticket.continuation = nil
        case .callerSettledExecutionOutstanding, .resolved, .cancelled:
            break
        }
        condition.broadcast()
        condition.unlock()
        if let resume {
            resume.resume(throwing: CancellationError())
        }
        for entry in physicalResumes {
            for waiter in entry.waiters {
                waiter.continuation.resume(returning: entry.snapshot)
            }
        }
    }

    // MARK: Bind / remove

    /// Bind a strictly newer epoch. Prior-epoch pending tickets are settled
    /// exactly once with `dispatcherReplaced`; queued payloads are zeroed and
    /// claimed permits are released. Already-caller-settled execution records
    /// stay until their real completion arrives (which then reports -102).
    @discardableResult
    public func bind(epoch newEpoch: UInt64) -> Int32 {
        guard newEpoch != 0, newEpoch > epoch else { return -105 }
        var resumes: [(CheckedContinuation<Data?, Error>, Error)] = []
        var physicalResumes: [(waiters: [PhysicalWaiterEntry], snapshot: PhysicalOperationSnapshot)] = []
        condition.lock()
        for ticket in Array(tickets.values) {
            switch ticket.state {
            case .queued:
                if let index = queue.firstIndex(of: ticket.token) {
                    queue.remove(at: index)
                }
                queuedPayloadBytes -= ticket.payload?.count ?? 0
                zeroPayloadLocked(ticket)
                ticket.state = .resolved
                if let continuation = ticket.continuation {
                    resumes.append((continuation, SecretBackendError.dispatcherReplaced))
                    ticket.continuation = nil
                }
                tickets.removeValue(forKey: ticket.token)
                addRetiredLocked(token: ticket.token, epoch: ticket.createdEpoch, reason: .replaced)
                let waiters = markPhysicalNeverDispatchedLocked(
                    token: ticket.token, reason: .replacedBeforeClaim)
                if !waiters.isEmpty {
                    physicalResumes.append((waiters, .neverDispatched(reason: .replacedBeforeClaim)))
                }
                counters.settledRebind += 1
            case .claimed:
                if let continuation = ticket.continuation {
                    resumes.append((continuation, SecretBackendError.dispatcherReplaced))
                    ticket.continuation = nil
                }
                ticket.state = .callerSettledExecutionOutstanding
                zeroPayloadLocked(ticket)
                if ticket.permitHeld {
                    ticket.permitHeld = false
                    permitsHeld = max(0, permitsHeld - 1)
                }
                markUnknownLocked(ticket)
                addRetiredLocked(token: ticket.token, epoch: ticket.createdEpoch, reason: .replaced)
                tickets.removeValue(forKey: ticket.token)
                counters.settledRebind += 1
            case .callerSettledExecutionOutstanding:
                // Caller already resumed; keep the execution record so a late
                // completion is rejected as -102 and its permit can be freed.
                break
            case .draft, .resolved, .cancelled:
                break
            }
        }
        if queuedPayloadBytes < 0 { queuedPayloadBytes = 0 }
        queue.removeAll()
        self.epoch = newEpoch
        bound = true
        closed = false
        readyAcked = false
        let now = nowLocked()
        lastHeartbeat = now
        lastProgress = now
        condition.broadcast()
        startWatchdogLocked()
        condition.unlock()
        for (continuation, error) in resumes {
            continuation.resume(throwing: error)
        }
        for entry in physicalResumes {
            for waiter in entry.waiters {
                waiter.continuation.resume(returning: entry.snapshot)
            }
        }
        return 0
    }

    /// Close the mailbox: settle every pending caller with `gatewayClosed`,
    /// zero payloads, stop the watchdog. `await` then returns -104. Active
    /// leases are owned by the vault and are not force-expired here. Execution
    /// records already settled by a caller are retained so a late authoritative
    /// completion can still classify the effect.
    @discardableResult
    public func remove() -> Int32 {
        var resumes: [(CheckedContinuation<Data?, Error>, Error)] = []
        var physicalResumes: [(waiters: [PhysicalWaiterEntry], snapshot: PhysicalOperationSnapshot)] = []
        condition.lock()
        closed = true
        bound = false
        readyAcked = false
        for ticket in Array(tickets.values) {
            switch ticket.state {
            case .queued:
                if let index = queue.firstIndex(of: ticket.token) {
                    queue.remove(at: index)
                }
                queuedPayloadBytes -= ticket.payload?.count ?? 0
                zeroPayloadLocked(ticket)
                ticket.state = .resolved
                if let continuation = ticket.continuation {
                    resumes.append((continuation, SecretBackendError.gatewayClosed))
                    ticket.continuation = nil
                }
                tickets.removeValue(forKey: ticket.token)
                addRetiredLocked(token: ticket.token, epoch: ticket.createdEpoch, reason: .closed)
                let waiters = markPhysicalNeverDispatchedLocked(
                    token: ticket.token, reason: .closedBeforeClaim)
                if !waiters.isEmpty {
                    physicalResumes.append((waiters, .neverDispatched(reason: .closedBeforeClaim)))
                }
                counters.settledClosed += 1
            case .claimed:
                if let continuation = ticket.continuation {
                    resumes.append((continuation, SecretBackendError.gatewayClosed))
                    ticket.continuation = nil
                }
                ticket.state = .callerSettledExecutionOutstanding
                zeroPayloadLocked(ticket)
                markUnknownLocked(ticket)
                counters.settledClosed += 1
            case .callerSettledExecutionOutstanding:
                zeroPayloadLocked(ticket)
                markUnknownLocked(ticket)
            case .draft, .resolved, .cancelled:
                break
            }
            if ticket.permitHeld {
                ticket.permitHeld = false
                permitsHeld = max(0, permitsHeld - 1)
            }
        }
        if queuedPayloadBytes < 0 { queuedPayloadBytes = 0 }
        queue.removeAll()
        permitsHeld = 0
        condition.broadcast()
        condition.unlock()
        stopWatchdog()
        for (continuation, error) in resumes {
            continuation.resume(throwing: error)
        }
        for entry in physicalResumes {
            for waiter in entry.waiters {
                waiter.continuation.resume(returning: entry.snapshot)
            }
        }
        return 0
    }

    // MARK: Await / claim

    /// Poller-thread claim. Blocks for the full remaining timeout whenever no
    /// claim can be handed out (empty queue OR permits exhausted); every
    /// return refreshes the poller heartbeat and runs the amortized LIVE-slot
    /// sweep (execution-linked tickets are never time-swept).
    public func awaitClaim(timeoutMillis: Int32) -> Int64 {
        guard timeoutMillis >= 0 else { return -105 }
        var result: Int64 = 0
        condition.lock()
        defer { condition.unlock() }
        // The poll deadline is ACTUAL elapsed monotonic time, never the
        // injectable business clock. The business clock governs heartbeat,
        // progress and vault expiry (deterministic in tests); reusing it here
        // would make a frozen test clock wait forever. Each wake recomputes
        // the remaining real interval, so early spurious wakeups cannot
        // extend or truncate the contract.
        let timeoutNanos = UInt64(timeoutMillis) * 1_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanos
        while true {
            let now = nowLocked()
            lastHeartbeat = now
            if closed || !bound {
                return -104
            }
            SecretSaveIntentVault.shared.sweepExpired(at: now)
            if permitsHeld < SecretGatewayLimits.maximumPermits,
               let index = queue.firstIndex(where: { token in
                   guard let ticket = tickets[token] else { return false }
                   return ticket.state == .queued && ticket.createdEpoch == epoch
               }) {
                let token = queue.remove(at: index)
                guard let ticket = tickets[token] else { continue }
                ticket.state = .claimed
                ticket.permitHeld = true
                permitsHeld += 1
                advancePhysicalClaimedLocked(token: token)
                queuedPayloadBytes -= ticket.payload?.count ?? 0
                if queuedPayloadBytes < 0 { queuedPayloadBytes = 0 }
                readyAcked = true
                lastProgress = now
                condition.broadcast()
                result = token
                return result
            }
            let monotonicNow = DispatchTime.now().uptimeNanoseconds
            let remainingNanos = deadline > monotonicNow ? deadline - monotonicNow : 0
            if remainingNanos == 0 {
                readyAcked = true
                return 0
            }
            _ = condition.wait(
                until: Date(timeIntervalSinceNow: Double(remainingNanos) / 1_000_000_000))
        }
    }

    // MARK: Claim inspection / completion

    public func describe(claim: Int64, buffer: UnsafeMutablePointer<CChar>?,
                         capacity: Int32) -> Int32 {
        guard claim > 0 else { return -100 }
        var descriptor: String?
        var code: Int32 = 0
        condition.lock()
        if let ticket = tickets[claim] {
            if ticket.createdEpoch != epoch {
                code = -102
            } else if ticket.state != .claimed && ticket.state != .callerSettledExecutionOutstanding {
                code = -100
            } else {
                descriptor = "{\"op\":\"\(ticket.op.rawValue)\",\"reference\":\"\(ticket.reference)\"}"
            }
        } else if closed {
            code = -104
        } else if let retired = retired[claim] {
            code = retired.epoch == epoch ? -101 : -102
            if code == -100 { code = -101 }
        } else {
            code = -100
            counters.rejectedStale += 1
        }
        condition.unlock()
        if code != 0 { return code }
        guard let descriptor else { return -100 }
        return copyCString(descriptor, buffer: buffer, capacity: capacity)
    }

    public func payloadLength(claim: Int64) -> Int32 {
        guard claim > 0 else { return -100 }
        condition.lock()
        defer { condition.unlock() }
        guard let ticket = tickets[claim] else {
            if closed { return -104 }
            if let retired = retired[claim] { return retired.epoch == epoch ? -101 : -102 }
            return -100
        }
        if ticket.createdEpoch != epoch { return -102 }
        if ticket.state == .callerSettledExecutionOutstanding { return -103 }
        guard ticket.state == .claimed, ticket.op == .write, let payload = ticket.payload else {
            return -107
        }
        return Int32(payload.count)
    }

    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?,
                            capacity: Int32) -> Int32 {
        guard claim > 0 else { return -100 }
        condition.lock()
        defer { condition.unlock() }
        guard let ticket = tickets[claim] else {
            if closed { return -104 }
            if let retired = retired[claim] { return retired.epoch == epoch ? -101 : -102 }
            return -100
        }
        if ticket.createdEpoch != epoch { return -102 }
        if ticket.state == .callerSettledExecutionOutstanding {
            if var payload = ticket.payload {
                payload.resetBytes(in: 0..<payload.count)
                ticket.payload = nil
            }
            return -103
        }
        guard ticket.state == .claimed, ticket.op == .write, var payload = ticket.payload else {
            return -107
        }
        let count = payload.count
        if count > 0 {
            guard let buffer else { return -105 }
            guard capacity >= Int32(count) else { return -106 }
            payload.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    buffer.update(from: base.assumingMemoryBound(to: UInt8.self), count: count)
                }
            }
        }
        payload.resetBytes(in: 0..<count)
        ticket.payload = nil
        return Int32(count)
    }

    public func isLive(claim: Int64) -> Int32 {
        guard claim > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.createdEpoch == epoch,
              ticket.state == .claimed else { return 0 }
        return 1
    }

    /// Exactly one terminal completion. Value/status validation happens before
    /// any state transition; an invalid combination returns -105 NON-TERMINAL.
    /// -103 accepts an already-settled caller's execution record and classifies
    /// its effect from the authoritative status. Swift copies the value under
    /// the lock and resumes the caller outside it.
    public func complete(claim: Int64, status: Int32,
                         value: UnsafePointer<UInt8>?, valueLen: Int32) -> Int32 {
        guard claim > 0 else { return -100 }
        let statusIsKnown = (status >= 1 && status <= 4)
            || (status >= -16 && status <= -1)
        guard statusIsKnown else { return -105 }
        let shapeIsValid: Bool
        if status == 1 {
            shapeIsValid = valueLen >= 0 && valueLen <= Int32(SecretGatewayLimits.maximumSecretBytes)
                && (valueLen == 0 || value != nil)
        } else {
            shapeIsValid = value == nil && valueLen == 0
        }
        guard shapeIsValid else { return -105 }

        var resume: CheckedContinuation<Data?, Error>?
        var result: Data?
        var resultError: Error?
        var code: Int32 = -100
        var physicalResumes: [(waiters: [PhysicalWaiterEntry], snapshot: PhysicalOperationSnapshot)] = []
        condition.lock()
        if let ticket = tickets[claim] {
            if ticket.createdEpoch != epoch {
                // A late completion from a replaced generation. The
                // authoritative result is rejected, but the execution record
                // (and its permit, if any) can now be released.
                if ticket.state == .claimed, let continuation = ticket.continuation {
                    // Defensive: a live caller must never be lost even if a
                    // ticket somehow survives into a newer epoch.
                    resume = continuation
                    ticket.continuation = nil
                    resultError = SecretBackendError.dispatcherReplaced
                }
                if ticket.state == .callerSettledExecutionOutstanding
                    || ticket.state == .claimed {
                    if ticket.permitHeld {
                        ticket.permitHeld = false
                        permitsHeld = max(0, permitsHeld - 1)
                    }
                    markUnknownLocked(ticket)
                    tickets.removeValue(forKey: claim)
                }
                let waiters = physicalSettleLocked(claim: claim, status: status)
                if !waiters.isEmpty {
                    physicalResumes.append((waiters, .settled(status: status)))
                }
                counters.rejectedMismatch += 1
                code = -102
            } else {
                // GWS-7: a positive completion status is valid only for the
                // actual claimed operation. A wrong positive pair is -105 and
                // remains NON-TERMINAL: no state, permit, continuation or
                // effect accounting changes, so the same one-fallback protocol
                // applies. Negative statuses keep their reviewed handling.
                let positiveMismatch: Bool
                if ticket.state == .claimed
                    || ticket.state == .callerSettledExecutionOutstanding {
                    switch (ticket.op, status) {
                    case (.read, 1), (.read, 2), (.write, 3), (.delete, 4):
                        positiveMismatch = false
                    default:
                        positiveMismatch = status > 0
                    }
                } else {
                    positiveMismatch = false
                }
                if positiveMismatch {
                    code = -105
                } else {
                    switch ticket.state {
                    case .claimed:
                        ticket.state = .resolved
                        if status == 1 {
                            if valueLen > 0, let value {
                                result = Data(bytes: UnsafeRawPointer(value), count: Int(valueLen))
                            } else {
                                result = Data()
                            }
                        } else if status >= 2 {
                            result = nil
                        } else {
                            resultError = errorForStatus(status)
                        }
                        if ticket.permitHeld {
                            ticket.permitHeld = false
                            permitsHeld = max(0, permitsHeld - 1)
                        }
                        zeroPayloadLocked(ticket)
                        resume = ticket.continuation
                        ticket.continuation = nil
                        tickets.removeValue(forKey: claim)
                        addRetiredLocked(token: claim, epoch: ticket.createdEpoch, reason: .resolved)
                        recordEffectLocked(status: status, ticket: ticket)
                        let settledWaiters = physicalSettleLocked(claim: claim, status: status)
                        if !settledWaiters.isEmpty {
                            physicalResumes.append((settledWaiters, .settled(status: status)))
                        }
                        lastProgress = nowLocked()
                        code = 0
                    case .callerSettledExecutionOutstanding:
                        ticket.state = .resolved
                        if ticket.permitHeld {
                            ticket.permitHeld = false
                            permitsHeld = max(0, permitsHeld - 1)
                        }
                        zeroPayloadLocked(ticket)
                        tickets.removeValue(forKey: claim)
                        addRetiredLocked(token: claim, epoch: ticket.createdEpoch, reason: .resolved)
                        recordEffectLocked(status: status, ticket: ticket)
                        let lateWaiters = physicalSettleLocked(claim: claim, status: status)
                        if !lateWaiters.isEmpty {
                            physicalResumes.append((lateWaiters, .settled(status: status)))
                        }
                        lastProgress = nowLocked()
                        code = -103
                    case .queued, .draft, .cancelled, .resolved:
                        counters.rejectedStale += 1
                        code = -100
                    }
                }
            }
        } else if closed {
            code = -104
        } else if let retired = retired[claim] {
            // RB2-REPAIR additive: a real host completion arriving for a
            // logically retired ticket STILL settles the physical record —
            // this is exactly the "owned physical record must survive logical
            // retirement / old-generation complete" requirement. Records for
            // never-claimed tickets are already terminal; settle only
            // transitions an outstanding record (one-time, exact identity).
            let retiredWaiters = physicalSettleLocked(claim: claim, status: status)
            if !retiredWaiters.isEmpty {
                physicalResumes.append((retiredWaiters, .settled(status: status)))
            }
            if retired.epoch != epoch {
                counters.rejectedMismatch += 1
                code = -102
            } else {
                counters.rejectedStale += 1
                code = -101
            }
        } else {
            counters.rejectedStale += 1
            code = -100
        }
        condition.broadcast()
        condition.unlock()
        if let resume {
            if let resultError {
                resume.resume(throwing: resultError)
            } else {
                resume.resume(returning: result)
            }
        }
        for entry in physicalResumes {
            for waiter in entry.waiters {
                waiter.continuation.resume(returning: entry.snapshot)
            }
        }
        return code
    }

    // MARK: Effect classification / retirement

    private func errorForStatus(_ status: Int32) -> SecretBackendError {
        switch status {
        case -1: return .invalidReference
        case -2: return .invalidValue
        case -3: return .corruptRecord
        case -4: return .authenticationFailed
        case -5: return .keyUnavailable
        case -6: return .keyStoreFailure
        case -7: return .storageFailure
        case -8: return .deleteFailed
        case -9: return .deviceLocked
        case -10: return .authRequired
        case -11: return .dispatcherCancelled
        case -12: return .internal
        case -13: return .dispatcherCancelled
        case -14: return .abandoned
        case -15: return .quarantined
        case -16: return .backendBusy
        default: return .internal
        }
    }

    private func markUnknownLocked(_ ticket: Ticket) {
        guard !ticket.unknownEffectRecorded else { return }
        ticket.unknownEffectRecorded = true
        counters.effectUnknown += 1
    }

    /// Per-ticket classification. Only the SAME ticket that previously
    /// contributed an unknown effect may decrement that contribution. A late
    /// completion for canceled B therefore cannot erase watchdog-unknown A.
    ///
    /// Rev4 clarification: -14 abandonment can be emitted after a real store
    /// completion failed to cross JNI; the status alone cannot prove no effect.
    /// It therefore counts as effectUnknown (abandoned remains a separate
    /// diagnostic). Only -13 is an explicit skipped-before-submit proof, and
    /// queue-never-claimed removals are known no-effect.
    private func recordEffectLocked(status: Int32, ticket: Ticket) {
        if ticket.unknownEffectRecorded {
            ticket.unknownEffectRecorded = false
            counters.effectUnknown = max(0, counters.effectUnknown - 1)
        }
        switch status {
        case 1, 3, 4:
            counters.effectCommitted += 1
        case 2:
            break
        case -11, -12, -14:
            counters.effectUnknown += 1
        case -1, -2, -9, -13, -15:
            counters.skippedNoEffect += 1
        case -16:
            counters.dispatcherCapacityRejects += 1
        default:
            counters.effectFailed += 1
        }
        if status == -14 {
            counters.abandoned += 1
        }
    }

    private func zeroPayloadLocked(_ ticket: Ticket) {
        if var payload = ticket.payload {
            payload.resetBytes(in: 0..<payload.count)
        }
        ticket.payload = nil
    }

    private func addRetiredLocked(token: Int64, epoch: UInt64, reason: RetiredReason) {
        retired[token] = Retired(epoch: epoch, reason: reason)
        retiredOrder.append(token)
        while retiredOrder.count > 128 {
            let oldest = retiredOrder.removeFirst()
            retired.removeValue(forKey: oldest)
        }
    }

    // MARK: Watchdog

    private func startWatchdogLocked() {
        if watchdogRunning { return }
        let semaphore = DispatchSemaphore(value: 0)
        watchdogStop = false
        watchdogRunning = true
        watchdogExit = semaphore
        let handle = WatchdogHandle(semaphore: semaphore, mailbox: self)
        let thread = Thread { [handle] in
            handle.mailbox?.runWatchdog(semaphore: handle.semaphore)
        }
        thread.name = "floe-secret-watchdog"
        watchdogThread = thread
        thread.start()
    }

    private func stopWatchdog() {
        let semaphore: DispatchSemaphore?
        condition.lock()
        watchdogStop = true
        semaphore = watchdogExit
        condition.broadcast()
        condition.unlock()
        _ = semaphore?.wait(timeout: .now() + .seconds(2))
        condition.lock()
        watchdogRunning = false
        watchdogThread = nil
        watchdogExit = nil
        condition.unlock()
    }

    private func runWatchdog(semaphore: DispatchSemaphore) {
        while true {
            var resumes: [(CheckedContinuation<Data?, Error>, Error)] = []
            condition.lock()
            if watchdogStop {
                watchdogRunning = false
                condition.unlock()
                semaphore.signal()
                return
            }
            let now = nowLocked()
            if bound && now >= lastHeartbeat && now - lastHeartbeat > watchdogStaleMillis {
                var didSettle = false
                var physicalResumes: [(waiters: [PhysicalWaiterEntry], snapshot: PhysicalOperationSnapshot)] = []
                if !queue.isEmpty {
                    let tokens = queue
                    queue.removeAll()
                    queuedPayloadBytes = 0
                    for token in tokens {
                        guard let ticket = tickets.removeValue(forKey: token),
                              let continuation = ticket.continuation else { continue }
                        ticket.continuation = nil
                        ticket.state = .resolved
                        zeroPayloadLocked(ticket)
                        addRetiredLocked(token: token, epoch: ticket.createdEpoch, reason: .watchdog)
                        let waiters = markPhysicalNeverDispatchedLocked(
                            token: token, reason: .watchdogDrainedQueued)
                        if !waiters.isEmpty {
                            physicalResumes.append(
                                (waiters, .neverDispatched(reason: .watchdogDrainedQueued)))
                        }
                        resumes.append((continuation, SecretBackendError.dispatcherUnresponsive))
                        counters.watchdogSettled += 1
                        didSettle = true
                    }
                }
                for ticket in tickets.values where ticket.state == .claimed {
                    guard let continuation = ticket.continuation else { continue }
                    ticket.continuation = nil
                    ticket.state = .callerSettledExecutionOutstanding
                    zeroPayloadLocked(ticket)
                    markUnknownLocked(ticket)
                    resumes.append((continuation, SecretBackendError.dispatcherUnresponsive))
                    counters.watchdogSettled += 1
                    didSettle = true
                }
                if didSettle {
                    lastWatchdogAt = now
                }
                if !physicalResumes.isEmpty {
                    condition.unlock()
                    for entry in physicalResumes {
                        for waiter in entry.waiters {
                            waiter.continuation.resume(returning: entry.snapshot)
                        }
                    }
                    condition.lock()
                    if watchdogStop {
                        watchdogRunning = false
                        condition.unlock()
                        semaphore.signal()
                        return
                    }
                }
            }
            if !resumes.isEmpty {
                condition.unlock()
                for (continuation, error) in resumes {
                    continuation.resume(throwing: error)
                }
                condition.lock()
                if watchdogStop {
                    watchdogRunning = false
                    condition.unlock()
                    semaphore.signal()
                    return
                }
            }
            let tick = watchdogTickMillis
            _ = condition.wait(until: Date(timeIntervalSinceNow: Double(tick) / 1_000))
            condition.unlock()
        }
    }

    // MARK: Diagnostics

    public func statsJSON() -> String {
        let vault = SecretSaveIntentVault.shared.statsSnapshot()
        condition.lock()
        let now = nowLocked()
        let queued = queue.count
        let permits = permitsHeld
        let pendingBytes = queuedPayloadBytes
        let callerOutstanding = tickets.values.filter {
            $0.state == .callerSettledExecutionOutstanding
        }.count
        let epochValue = epoch
        let boundValue = bound
        let ready = readyAcked
        let heartbeatAge: Int = lastHeartbeat == 0 ? -1 : Int(max(0, now - lastHeartbeat))
        let running = watchdogRunning
        let lastWatchdog = lastWatchdogAt
        let counts = counters
        condition.unlock()

        let object: [String: Any] = [
            "epoch": epochValue,
            "bound": boundValue,
            "readyAcked": ready,
            "heartbeatAgeMillis": heartbeatAge,
            "watchdogRunning": running,
            "lastWatchdogAt": lastWatchdog,
            "queued": queued,
            "permitsHeld": permits,
            "pendingPayloadBytes": pendingBytes,
            "callerSettledOutstanding": callerOutstanding,
            "intentsLive": vault.intentsLive,
            "leasesActive": vault.leasesActive,
            "leasesCloseFailed": vault.leasesCloseFailed,
            "counters": [
                "saturated": counts.saturated,
                "backendBusy": counts.backendBusy,
                "dispatcherCapacityRejects": counts.dispatcherCapacityRejects,
                "droppedCanceled": counts.droppedCanceled,
                "skippedNoEffect": counts.skippedNoEffect,
                "watchdogSettled": counts.watchdogSettled,
                "effectCommitted": counts.effectCommitted,
                "effectFailed": counts.effectFailed,
                "effectUnknown": counts.effectUnknown,
                "rejectedStale": counts.rejectedStale,
                "rejectedMismatch": counts.rejectedMismatch,
                "abandoned": counts.abandoned,
                "abandonedUnsettleable": counts.abandonedUnsettleable,
                "generationFailed": counts.generationFailed,
                "settledRebind": counts.settledRebind,
                "settledClosed": counts.settledClosed,
                "exhausted": counts.exhausted,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"stats_encoding\"}"
        }
        return string
    }

    // MARK: Test-only control (never used by production code)

    internal func configureForTesting(clock: (() -> UInt64)? = nil,
                                      heartbeatStaleMillis: UInt64? = nil,
                                      watchdogStaleMillis: UInt64? = nil,
                                      watchdogTickMillis: UInt64? = nil,
                                      backendProgressWindowMillis: UInt64? = nil) {
        condition.lock()
        if let clock { self.clockOverride = clock }
        if let value = heartbeatStaleMillis { self.heartbeatStaleMillis = value }
        if let value = watchdogStaleMillis { self.watchdogStaleMillis = value }
        if let value = watchdogTickMillis { self.watchdogTickMillis = value }
        if let value = backendProgressWindowMillis {
            self.backendProgressWindowMillis = value
        }
        condition.unlock()
    }

    internal func resetForTesting() {
        condition.lock()
        watchdogStop = true
        let semaphore = watchdogExit
        condition.broadcast()
        condition.unlock()
        _ = semaphore?.wait(timeout: .now() + .seconds(2))
        var resumes: [CheckedContinuation<Data?, Error>] = []
        condition.lock()
        for ticket in tickets.values {
            if let continuation = ticket.continuation {
                resumes.append(continuation)
                ticket.continuation = nil
            }
            zeroPayloadLocked(ticket)
        }
        tickets.removeAll()
        queue.removeAll()
        retired.removeAll()
        retiredOrder.removeAll()
        permitsHeld = 0
        queuedPayloadBytes = 0
        bound = false
        closed = true
        epoch = 0
        nextToken = 1
        lastHeartbeat = 0
        lastProgress = 0
        lastWatchdogAt = 0
        readyAcked = false
        watchdogRunning = false
        watchdogThread = nil
        watchdogExit = nil
        watchdogStop = false
        counters = Counters()
        heartbeatStaleMillis = SecretGatewayLimits.heartbeatStaleMillis
        watchdogStaleMillis = SecretGatewayLimits.watchdogStaleMillis
        watchdogTickMillis = SecretGatewayLimits.watchdogTickMillis
        backendProgressWindowMillis = SecretGatewayLimits.backendProgressWindowMillis
        clockOverride = nil
        physicalRecords.removeAll()
        physicalOrder.removeAll()
        // MC-CAPACITY-2: every pending settlement subscriber learns the
        // honest non-evidence value; the durable ledger + restart drain own
        // recovery from a full reset.
        let physicalWaiters = takeAllPhysicalWaitersLocked()
        condition.unlock()
        for continuation in resumes {
            continuation.resume(throwing: SecretBackendError.gatewayClosed)
        }
        for waiter in physicalWaiters {
            waiter.continuation.resume(returning: .notRecorded)
        }
    }

    // MARK: RB2-REPAIR additive physical-lifetime API (Main-authorized)

    /// Synchronous snapshot of the individual physical truth for one
    /// observed claim. `.notRecorded` means NO physical proof is available
    /// for this claim (never queued, capacity-untracked, resolved by the
    /// consumer, or the mailbox was reset) — callers must treat it as
    /// honest non-evidence, NEVER as settlement.
    public func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
        condition.lock()
        defer { condition.unlock() }
        guard let record = physicalRecords[claim] else { return .notRecorded }
        switch record.state {
        case .queued: return .queued
        case .claimedOutstanding: return .claimedOutstanding
        case .settled(let status): return .settled(status: status)
        case .neverDispatched(let reason): return .neverDispatched(reason: reason)
        }
    }

    /// Consumer release of a TERMINAL record (settled/neverDispatched) to
    /// keep the ledger bounded. Never removes an outstanding record: an
    /// owner cannot destroy its own settlement signal. Returns false for
    /// outstanding records, true once the record is (or already was) absent.
    @discardableResult
    public func resolvePhysical(claim: Int64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let record = physicalRecords[claim] else { return true }
        switch record.state {
        case .settled, .neverDispatched:
            physicalRecords.removeValue(forKey: claim)
            physicalOrder.removeAll { $0 == claim }
            return true
        case .queued, .claimedOutstanding:
            return false
        }
    }

    /// RB2-REPAIR additive (MC-CAPACITY-2 completed): the actual-settlement
    /// SUBSCRIPTION for one observed claim. Returns ONLY terminal individual
    /// truth (`settled`/`neverDispatched`) — or `.notRecorded` when no record
    /// exists, the consumer already resolved it, or the mailbox was reset.
    /// It never manufactures a timeout result: the CALLER controls the wait
    /// and cancellation returns the current snapshot honestly.
    ///
    /// Notification-based (the retired 20 ms/50 Hz poll is gone): the waiter
    /// is registered atomically under `condition` while the record is
    /// non-terminal and is resumed EXACTLY ONCE, OUTSIDE the lock, with the
    /// same terminal snapshot value the state transition produced — so a
    /// completion racing the subscription cannot be lost (queued-cancel,
    /// claim-then-complete, watchdog drain, old-generation rebind completion,
    /// duplicate completion and RootStop reset each wake waiters at most
    /// once with that transition's value).
    public func awaitPhysicalSettlement(claim: Int64,
                                        pollNanoseconds: UInt64 = 20_000_000)
        async -> PhysicalOperationSnapshot
    {
        // `pollNanoseconds` is retained in the signature for source
        // compatibility with the parent package; the notification channel
        // makes it unused.
        _ = pollNanoseconds
        let box = PhysicalSubscriptionBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.lock()
                if case .cancelled = box.state {
                    let snapshot = Self.currentSnapshotLocked(
                        physicalRecords: physicalRecords, claim: claim)
                    condition.unlock()
                    continuation.resume(returning: snapshot)
                    return
                }
                guard let record = physicalRecords[claim] else {
                    // Main repair (job-059dc09dd7bd48f1): the subscription
                    // state transition happens UNDER the same lock that
                    // guards cancellation; only the continuation resume is
                    // outside. A racing onCancel therefore observes
                    // `.resumed` and never double-delivers.
                    box.state = .resumed
                    condition.unlock()
                    continuation.resume(returning: .notRecorded)
                    return
                }
                switch record.state {
                case .settled(let status):
                    box.state = .resumed
                    condition.unlock()
                    continuation.resume(returning: .settled(status: status))
                case .neverDispatched(let reason):
                    box.state = .resumed
                    condition.unlock()
                    continuation.resume(returning: .neverDispatched(reason: reason))
                case .queued, .claimedOutstanding:
                    if nextPhysicalWaiterID == Int64.max {
                        nextPhysicalWaiterID = 1
                    }
                    let id = nextPhysicalWaiterID
                    nextPhysicalWaiterID += 1
                    physicalWaiters[claim, default: []].append(
                        PhysicalWaiterEntry(id: id, continuation: continuation))
                    box.state = .registered(id: id)
                    condition.unlock()
                }
            }
        } onCancel: { [condition] in
            // Lock-protected removal handshake (see MARK note above).
            condition.lock()
            switch box.state {
            case .pending:
                // Subscription has not registered yet: flag it so the
                // synchronous registration path returns the current snapshot
                // instead of subscribing a cancelled task.
                box.state = .cancelled
                condition.unlock()
            case .registered(let id):
                box.state = .resumed
                var removed: PhysicalWaiterEntry?
                if var entries = physicalWaiters[claim],
                   let index = entries.firstIndex(where: { $0.id == id }) {
                    removed = entries.remove(at: index)
                    if entries.isEmpty {
                        physicalWaiters.removeValue(forKey: claim)
                    } else {
                        physicalWaiters[claim] = entries
                    }
                }
                let snapshot = Self.currentSnapshotLocked(
                    physicalRecords: physicalRecords, claim: claim)
                condition.unlock()
                // `removed` is nil exactly when a terminal transition already
                // claimed the waiter: that transition's value is delivered
                // instead — exactly-once either way.
                removed?.continuation.resume(returning: snapshot)
            case .cancelled, .resumed:
                condition.unlock()
            }
        }
    }

    /// Current snapshot helper shared by the subscription and cancellation
    /// paths. MUST be called with `condition` held.
    private static func currentSnapshotLocked(
        physicalRecords: [Int64: PhysicalRecord],
        claim: Int64
    ) -> PhysicalOperationSnapshot {
        guard let record = physicalRecords[claim] else { return .notRecorded }
        switch record.state {
        case .queued: return .queued
        case .claimedOutstanding: return .claimedOutstanding
        case .settled(let status): return .settled(status: status)
        case .neverDispatched(let reason): return .neverDispatched(reason: reason)
        }
    }

    /// Cancellation-vs-registration state machine for ONE
    /// `awaitPhysicalSettlement` call. `condition` guards all transitions.
    private final class PhysicalSubscriptionBox: @unchecked Sendable {
        enum State {
            case pending
            case cancelled
            case registered(id: Int64)
            case resumed
        }
        var state: State = .pending
    }

    /// MC-CAPACITY-2: register the per-operation record, or refuse.
    ///
    /// A record is removed ONLY by the consumer's explicit `resolvePhysical`
    /// (terminal-only acknowledgement) or a full mailbox reset — NEVER by
    /// mailbox eviction. The previous first-terminal-eviction could drop an
    /// UNACKNOWLEDGED settlement proof and strand the owner in permanent
    /// unobserved quarantine. When the ledger is full of records whose
    /// proofs are still owed to consumers, registration refuses (false) and
    /// the observed publish fails BEFORE queueing (see `publish`).
    private func registerPhysicalLocked(ticket: Ticket) -> Bool {
        if physicalRecords[ticket.token] != nil { return true }
        guard physicalRecords.count < Self.maximumPhysicalRecords else {
            return false // capacity exhausted: refuse BEFORE queue/dispatch
        }
        physicalRecords[ticket.token] = PhysicalRecord(
            state: .queued,
            epoch: ticket.createdEpoch,
            kind: Self.physicalKind(for: ticket.op),
            reference: ticket.reference
        )
        physicalOrder.append(ticket.token)
        return true
    }

    private func advancePhysicalClaimedLocked(token: Int64) {
        guard var record = physicalRecords[token] else { return }
        switch record.state {
        case .queued:
            record.state = .claimedOutstanding
            physicalRecords[token] = record
        case .claimedOutstanding, .settled, .neverDispatched:
            break
        }
    }

    /// Queued-cancel / bind-remove / close / watchdog-drain settle a QUEUED
    /// record as neverDispatched. MC-CAPACITY-2: returns the waiters to
    /// resume OUTSIDE the lock (each receives
    /// `.neverDispatched(reason)`); claimed records are untouched (the
    /// physical execution may still complete) and terminal records stay
    /// one-time terminal.
    private func markPhysicalNeverDispatchedLocked(
        token: Int64,
        reason: PhysicalNeverDispatchedReason
    ) -> [PhysicalWaiterEntry] {
        guard var record = physicalRecords[token] else { return [] }
        switch record.state {
        case .queued:
            record.state = .neverDispatched(reason: reason)
            physicalRecords[token] = record
            return takePhysicalWaitersLocked(claim: token)
        case .claimedOutstanding, .settled, .neverDispatched:
            // Claimed work is NOT never-dispatched; logical retirement never
            // manufactures physical absence. Terminal records stay terminal.
            return []
        }
    }

    /// The one-time real host completion. Returns the waiters to resume
    /// OUTSIDE the lock (each receives `.settled(status)`); duplicate or
    /// retired-generation completions cannot re-settle an already-terminal
    /// record and therefore wake nobody.
    private func physicalSettleLocked(claim: Int64, status: Int32) -> [PhysicalWaiterEntry] {
        guard var record = physicalRecords[claim] else { return [] }
        switch record.state {
        case .queued, .claimedOutstanding:
            record.state = .settled(status: status)
            physicalRecords[claim] = record
            return takePhysicalWaitersLocked(claim: claim)
        case .settled, .neverDispatched:
            break // one-time terminal; a duplicate completion cannot re-settle
        }
        return []
    }

    /// Reset (RootStop/test): every waiter learns the honest non-evidence
    /// value `.notRecorded` — the durable ledger + restart drain owns
    /// recovery from here. Returns all waiters to resume outside the lock.
    private func takeAllPhysicalWaitersLocked() -> [PhysicalWaiterEntry] {
        var all: [PhysicalWaiterEntry] = []
        for claim in Array(physicalWaiters.keys) {
            all.append(contentsOf: takePhysicalWaitersLocked(claim: claim))
        }
        physicalWaiters.removeAll()
        return all
    }
}

// MARK: - AndroidSecretGateway implementation

/// The gateway registered in the existing fail-closed `SecretGatewayRegistry`.
/// Every call validates identity and health BEFORE creating a ticket; no call
/// blocks and no JNI is touched from Swift.
public final class MailboxSecretGateway: AndroidSecretGateway, @unchecked Sendable {
    public static let shared = MailboxSecretGateway()
    private let mailbox = SecretRequestMailbox.shared

    private init() {}

    public func read(reference: String) async throws -> Data? {
        try await perform(op: .read, reference: reference, payload: nil)
    }

    public func write(reference: String, value: Data) async throws {
        _ = try await perform(op: .write, reference: reference, payload: value)
    }

    public func delete(reference: String) async throws {
        _ = try await perform(op: .delete, reference: reference, payload: nil)
    }

    private func perform(op: SecretOperation, reference: String,
                         payload: Data?) async throws -> Data? {
        guard SecretGatewayIdentity.isCanonicalReference(reference) else {
            throw SecretBackendError.invalidReference
        }
        if op == .write {
            guard let payload else { throw SecretBackendError.invalidValue }
            guard payload.count <= SecretGatewayLimits.maximumSecretBytes else {
                throw SecretBackendError.invalidValue
            }
        }
        let ticket = try mailbox.makeTicketForGateway(op: op, reference: reference,
                                                      payload: payload)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                mailbox.publishForGateway(ticket, continuation: continuation)
            }
        }, onCancel: {
            mailbox.cancelForGateway(ticket)
        })
    }

    // MARK: RB2-REPAIR additive — observed variants (Main-authorized)

    private func performObserved(op: SecretOperation, reference: String,
                                 payload: Data?,
                                 onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws -> Data?
    {
        // Pre-ticket validation is the EXACT existing perform rule (frozen
        // semantics: invalidReference/invalidValue create no ticket at all).
        guard SecretGatewayIdentity.isCanonicalReference(reference) else {
            throw SecretBackendError.invalidReference
        }
        if op == .write {
            guard let payload else { throw SecretBackendError.invalidValue }
            guard payload.count <= SecretGatewayLimits.maximumSecretBytes else {
                throw SecretBackendError.invalidValue
            }
        }
        let ticket = try mailbox.makeTicketForGateway(op: op, reference: reference,
                                                      payload: payload)
        let delivery: ((Bool) -> Void)?
        if let onQueued {
            delivery = { tracked in
                onQueued(PhysicalOperationReceipt(
                    claim: ticket.token,
                    epoch: ticket.createdEpoch,
                    reference: reference,
                    kind: Self.kind(for: op),
                    tracked: tracked
                ))
            }
        } else {
            delivery = nil
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                mailbox.publishForGateway(ticket, continuation: continuation,
                                          onQueued: delivery)
            }
        }, onCancel: {
            mailbox.cancelForGateway(ticket)
        })
    }

    static func kind(for op: SecretOperation) -> PhysicalOperationKind {
        switch op {
        case .read: return .read
        case .write: return .write
        case .delete: return .delete
        }
    }

    public func readObserved(reference: String,
                             onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws -> Data?
    {
        try await performObserved(op: .read, reference: reference, payload: nil,
                                  onQueued: onQueued)
    }

    public func writeObserved(reference: String, value: Data,
                              onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws
    {
        _ = try await performObserved(op: .write, reference: reference, payload: value,
                                      onQueued: onQueued)
    }

    public func deleteObserved(reference: String,
                               onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?)
        async throws
    {
        _ = try await performObserved(op: .delete, reference: reference, payload: nil,
                                      onQueued: onQueued)
    }

    public func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot {
        mailbox.physicalSnapshot(claim: claim)
    }

    @discardableResult
    public func resolvePhysical(claim: Int64) -> Bool {
        mailbox.resolvePhysical(claim: claim)
    }

    public func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot {
        await mailbox.awaitPhysicalSettlement(claim: claim)
    }
}

extension MailboxSecretGateway: PhysicalObservingSecretGateway {}

// Internal bridges keep the ticket type private to the mailbox file while
// still letting the gateway create/publish/cancel it.
extension SecretRequestMailbox {
    fileprivate func makeTicketForGateway(op: SecretOperation, reference: String,
                                          payload: Data?) throws -> Ticket {
        try makeTicket(op: op, reference: reference, payload: payload)
    }

    fileprivate func publishForGateway(_ ticket: Ticket,
                                       continuation: CheckedContinuation<Data?, Error>,
                                       onQueued: ((Bool) -> Void)? = nil) {
        publish(ticket, continuation: continuation, onQueued: onQueued)
    }

    fileprivate func cancelForGateway(_ ticket: Ticket) {
        cancel(ticket)
    }
}

// MARK: - C ABI

private func copyCString(_ value: String, buffer: UnsafeMutablePointer<CChar>?,
                         capacity: Int32) -> Int32 {
    guard capacity >= 0 else { return -105 }
    guard let buffer else { return -105 }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -106 }
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

@_cdecl("floe_secret_mailbox_bind")
public func floeSecretMailboxBind(_ epoch: UInt64) -> Int32 {
    SecretRequestMailbox.shared.bind(epoch: epoch)
}

@_cdecl("floe_secret_mailbox_await")
public func floeSecretMailboxAwait(_ timeoutMillis: Int32) -> Int64 {
    SecretRequestMailbox.shared.awaitClaim(timeoutMillis: timeoutMillis)
}

@_cdecl("floe_secret_mailbox_describe")
public func floeSecretMailboxDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                      _ capacity: Int32) -> Int32 {
    SecretRequestMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_secret_mailbox_payload_length")
public func floeSecretMailboxPayloadLength(_ claim: Int64) -> Int32 {
    SecretRequestMailbox.shared.payloadLength(claim: claim)
}

@_cdecl("floe_secret_mailbox_take_payload")
public func floeSecretMailboxTakePayload(_ claim: Int64,
                                         _ buffer: UnsafeMutablePointer<UInt8>?,
                                         _ capacity: Int32) -> Int32 {
    SecretRequestMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_secret_mailbox_is_live")
public func floeSecretMailboxIsLive(_ claim: Int64) -> Int32 {
    SecretRequestMailbox.shared.isLive(claim: claim)
}

@_cdecl("floe_secret_mailbox_complete")
public func floeSecretMailboxComplete(_ claim: Int64, _ status: Int32,
                                      _ value: UnsafePointer<UInt8>?,
                                      _ valueLen: Int32) -> Int32 {
    SecretRequestMailbox.shared.complete(claim: claim, status: status,
                                         value: value, valueLen: valueLen)
}

@_cdecl("floe_secret_mailbox_stats")
public func floeSecretMailboxStats(_ buffer: UnsafeMutablePointer<CChar>?,
                                   _ capacity: Int32) -> Int32 {
    copyCString(SecretRequestMailbox.shared.statsJSON(), buffer: buffer, capacity: capacity)
}

@_cdecl("floe_secret_gateway_install")
public func floeSecretGatewayInstall() -> Int32 {
    let mailbox = SecretRequestMailbox.shared
    guard mailbox.isBoundAndOpen else { return -104 }
    SecretGatewayRegistry.shared.register(MailboxSecretGateway.shared)
    return 0
}

@_cdecl("floe_secret_gateway_remove")
public func floeSecretGatewayRemove() -> Int32 {
    SecretGatewayRegistry.shared.unregister()
    SecretRequestMailbox.shared.remove()
    return 0
}

extension SecretRequestMailbox {
    fileprivate var isBoundAndOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return bound && !closed
    }
}
