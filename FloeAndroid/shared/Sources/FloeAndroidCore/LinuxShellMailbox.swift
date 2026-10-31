// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 — owned native-to-Kotlin Linux shell transport mailbox (job-1bd4fcce5eca4856).
//
// Direction: Swift (the Main App product library, running the ORIGINAL shell
// service/backend) is the REQUESTER; the trusted Kotlin host owns the single
// Binder poller that pumps each queued ticket to the runtime component over
// the frozen RuntimeWire v1 exchange and settles the reply back through this
// bounded C ingress. This mirrors the reviewed SecretRequestMailbox pattern
// (Swift owns the inverse request mailbox; no Swift -> JVM callback, no
// global JNI reference, Kotlin never holds a Swift continuation).
//
// Bounded, transient receipts ONLY:
// * Tickets live in RAM and settle exactly once (completed / failed /
//   fenced). These are NOT durable jobs: the ORIGINAL
//   BackgroundJobStore/BackgroundJobService remain the durable task
//   authority; this file never touches a job DB and persists nothing.
// * Command payloads and outputs stay in memory until settled and are NEVER
//   written to disk, never logged, never included in stats. Stats are typed
//   counters only.
// * Every request payload and every reply frame is bounded by the frozen
//   64 KiB RuntimeWire per-frame limit (`maximumFrameBytes`).
// * Waits are bounded by an explicit per-call budget. A timed-out waiter
//   receives the typed `waitBudgetExpired` error while a CLAIMED ticket stays
//   live until its real settlement or a generation fence — cancellation of a
//   Core-side wait therefore never fabricates a remote stop or exit; the
//   caller (backend/facade) retains ownership for reconciliation.
// * Host ingress (claim/describe/take/complete) is privileged trusted-host
//   surface exported via `@_cdecl` for the Kotlin host only. Model dispatch
//   has no route here: no V3 handler key, no command name, no tool. Binding
//   requires a strictly newer positive native Root epoch (never 0-as-epoch);
//   unbound state fails closed with `notBound`.
//
// Engine pump contract implemented by the trusted Kotlin host (authoritative
// sources: core/runtimeipc RuntimeWire/RuntimeConnection, runtimeapp
// RuntimeKernel/LinuxRuntimeOperations):
//   claim -> RuntimeConnection.exchange(operation, payload, hostRequestID)
//   -> for slow controls (shell.start/input/resize) the host polls
//      operation "request.status" until state completed (complete status=0
//      with the result OBJECT) or failed (complete status=1 with
//      {"code": bounded-code}, plus — for the ORIGINAL failed-start claim
//      only, after the real drain/quiescence and grant close — the optional
//      additive {"failureCode": bounded-token, "recovery": {closed
//      importRestore fields}} pair which this mailbox parses strictly and
//      delivers as the typed `.remoteFailedWithRestore(code:restore:)` evidence case;
//      anything malformed stays the legacy `.remoteFailed(code:)`); direct
//      snapshots (shell.poll) and the urgent
//      stop request (shell.cancel) complete directly from the immediate
//      reply. Nothing is retried blindly: the kernel rejects duplicate
//      request IDs by receipt identity.
//   shell.start may carry the explicit caller `env` object (engine bounds:
//   <=32 entries, engine key shape, no PROOT_*/FLOE_* keys, no HOME/TMPDIR
//   override, no NUL, <=32 KiB combined bytes), plus the trusted closed
//   `leaseRole` and validated `workspaceReuse {mode:"shared", ownerSessionID}`
//   hints (both omitted when nil); its reply carries the optional measured
//   admission facts (runtimeGeneration/workspaceOwner/prepare*/import*).
//   shell.poll replies carry `cancelled` plus the fixed `stopReason` service
//   code alongside state/leaseReleased/exit fields; `workspaceStatus` may be
//   `deferred` only for a released owner terminal.
//   Identity case: owner UUID strings (projectID/runID/conversationID) ride
//   Swift canonical form UNCHANGED; only the transient interface/control
//   request UUIDs may be normalized (lowercase Java canonical) by the host
//   adapter, never owner IDs.
import Foundation
import CoreFoundation
import FloeCore
import FloeAndroidShellTools

// MARK: - Limits

public enum LinuxShellMailboxLimits {
    /// Live (queued-or-claimed) tickets. The engine serializes to ONE
    /// workload, so 32 is generous headroom for concurrent waiters.
    public static let maximumLiveTickets = 32
    /// Frozen RuntimeWire per-frame bound (64 KiB standard JSON).
    public static let maximumFrameBytes = 65_536
    /// Aggregate queued-request byte bound (host baseline).
    public static let maximumQueuedPayloadBytes = 1_048_576
    /// Bounded retirement ring for late/duplicate settlement classification.
    public static let maximumRetired = 256
    /// Bounded reply code string.
    public static let maximumCodeChars = 128
    /// Default bounded wait budgets (milliseconds) per operation.
    ///
    /// `preparationBudgetMillis` bounds ONE `shell.start` wait. The engine
    /// performs whole-runtime recovery, cold rootfs materialization and the
    /// workspace import BEFORE it admits the command, so this is the explicit
    /// bounded PREPARATION budget. It is CANCELLABLE: a cancelled or
    /// timed-out waiter leaves a claimed ticket live (never a fabricated
    /// settlement) so the trusted host pump can stop the pending start via
    /// `shouldStop`/`shell.cancel {requestID}`. It is deliberately separate
    /// from the caller's command timeout, which starts only at real execution
    /// admission (the start reply) and is enforced by the engine from its own
    /// spawn and by the backend's poll loop.
    public static let preparationBudgetMillis = 120_000
    /// Alias retained for existing call sites and authored tests.
    public static let startBudgetMillis = preparationBudgetMillis
    public static let pollBudgetMillis = 15_000
    public static let inputBudgetMillis = 30_000
    public static let resizeBudgetMillis = 15_000
    public static let cancelBudgetMillis = 15_000
}

// MARK: - Mailbox

public final class LinuxShellMailbox: @unchecked Sendable {
    public static let shared = LinuxShellMailbox()

    fileprivate final class Ticket: @unchecked Sendable {
        let token: Int64
        // G03-native-integration compile repair 4: Main's bind() generation
        // re-stamp (settlement classification) mutates this field. It stays a
        // lock-guarded Ticket property: written ONLY under the mailbox
        // condition lock inside bind(), never after settle classification.
        var createdEpoch: UInt64
        let operation: String
        let payload: Data
        var state: State
        var continuation: CheckedContinuation<Data, LinuxShellTransportError>?
        /// Weak to avoid mailbox -> ticket -> handle -> mailbox retention.
        /// `complete` marks this handle directly, so a later bounded-ring
        /// eviction can never erase an already observed host-settled fact.
        weak var ownerRequest: LinuxShellMailboxRequest?
        enum State {
            case queued
            case claimed
            case settled
        }
        init(token: Int64, createdEpoch: UInt64, operation: String, payload: Data) {
            self.token = token
            self.createdEpoch = createdEpoch
            self.operation = operation
            self.payload = payload
            self.state = .queued
        }
    }

    private struct Counters {
        var submitted = 0
        var rejectedSaturated = 0
        var rejectedTooLarge = 0
        var rejectedUnbound = 0
        var rejectedClosed = 0
        var claimed = 0
        var completed = 0
        var failed = 0
        var waitBudgetExpired = 0
        var staleClaim = 0
        var lateSettle = 0
        var fenced = 0
        var bindRejections = 0
    }

    private let condition = NSCondition()
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    /// G05-R3 per-ticket HOST-COMPLETION ring: tokens the trusted host actually
    /// completed/failed through `complete`. This is deliberately NOT physical
    /// IO settlement: the pump can answer before reconciliation releases its
    /// grant. `retired` alone cannot distinguish an unclaimed queued retirement
    /// from a host-completed claim; the first-use rule needs both facts plus
    /// the host's later physical-release proof. Bounded exactly like `retired`,
    /// holding tokens only — never payloads, replies, paths or digests.
    private var hostSettled: Set<Int64> = []
    private var hostSettledOrder: [Int64] = []
    private var nextToken: Int64 = 1
    private var queuedBytes = 0
    private var epoch: UInt64 = 0
    private var closed = false
    private var counters = Counters()
    /// Injectable bounded clock/timer for tests (production uses Task.sleep).
    private let sleeper: @Sendable (UInt64) async -> Void

    public init(sleeper: (@Sendable (UInt64) async -> Void)? = nil) {
        self.sleeper = sleeper ?? { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) }
    }

    private static let waitPollNanos: UInt64 = 20_000_000

    // MARK: Generation binding (trusted host)

    /// Bind a strictly newer positive native Root epoch. Pending
    /// previous-epoch tickets are fenced (NOT replayed): the runtime process
    /// death/disconnect means their leases stay unreconciled, which callers
    /// must treat as "unknown, retained" (never as stopped or exited).
    /// A CLOSED mailbox reopens ONLY for a strictly newer positive epoch
    /// (the native Root epoch is monotonic per generation), so a new
    /// generation's host pump can bind after `close()`; re-binding the same
    /// or an older epoch stays refused.
    /// Returns false on invalid values (0, stale, equal, refused reopen).
    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch != 0, newEpoch > epoch else {
            counters.bindRejections += 1
            condition.unlock()
            return false
        }
        epoch = newEpoch
        let wasClosed = closed
        closed = false
        var resumes: [(CheckedContinuation<Data, LinuxShellTransportError>, LinuxShellTransportError)] = []
        let pendingQueue = queue
        for token in pendingQueue {
            guard let ticket = tickets[token], ticket.state == .queued else { continue }
            if let continuation = ticket.continuation {
                resumes.append((continuation, .hostFenced))
                ticket.continuation = nil
            }
            retireLocked(token)
        }
        for token in tickets.keys where tickets[token]?.state == .claimed {
            // Claimed work stays observable-but-fenced: the waiter is
            // released with hostFenced; the ticket remains until a real
            // settlement classifies it late (or the ring bounds it).
            if let continuation = tickets[token]?.continuation {
                resumes.append((continuation, .hostFenced))
                tickets[token]?.continuation = nil
            }
            tickets[token]?.createdEpoch = newEpoch  // generation re-stamp for settlement classification
        }
        counters.fenced += 1
        condition.broadcast()
        condition.unlock()
        for (continuation, error) in resumes { continuation.resume(throwing: error) }
        return true
    }

    /// Retire the mailbox for a closing generation (host lifecycle). All
    /// waiters are released `hostFenced`; no work is replayed and running
    /// leases must be reconciled by the new generation's census.
    public func close() {
        condition.lock()
        guard !closed else { condition.unlock(); return }
        closed = true
        var resumes: [(CheckedContinuation<Data, LinuxShellTransportError>, LinuxShellTransportError)] = []
        for (_, ticket) in tickets {
            if let continuation = ticket.continuation {
                resumes.append((continuation, .hostFenced))
                ticket.continuation = nil
            }
        }
        tickets.removeAll()
        queue.removeAll()
        queuedBytes = 0
        counters.fenced += 1
        condition.broadcast()
        condition.unlock()
        for (continuation, error) in resumes { continuation.resume(throwing: error) }
    }

    /// Test/reset hygiene (host re-bootstrap between generations).
    public func resetForRebind() {
        condition.lock()
        closed = false
        epoch = 0
        tickets.removeAll()
        queue.removeAll()
        retired.removeAll()
        retiredOrder.removeAll()
        hostSettled.removeAll()
        hostSettledOrder.removeAll()
        queuedBytes = 0
        condition.unlock()
    }

    // MARK: Swift-side submit (bounded wait)

    /// Enqueue one typed request and wait (bounded) for the host-settled
    /// reply frame. Bounds are checked BEFORE the queue append; any breach is
    /// a typed rejection and nothing reaches the host.
    ///
    /// The continuation this expresses is WAITER completion only: a budget
    /// expiry or a caller cancellation resumes the waiter while a CLAIMED
    /// ticket stays live for its real host settlement. A caller that owns a
    /// grant/receipt across the request must observe the ticket's PHYSICAL
    /// settlement through [beginRequest]'s handle instead of inferring it from
    /// this call's return or throw.
    func submit(operation: String, payload: Data,
                            timeoutMillis: Int) async throws -> Data {
        try await awaitReply(beginRequest(operation: operation, payload: payload),
                             timeoutMillis: timeoutMillis)
    }

    /// Enqueue one typed request and return its settlement handle BEFORE any
    /// wait, so the caller still holds the request's real ownership truth when
    /// the bounded wait later expires or is cancelled. Same bounds and same
    /// typed rejections as [submit]; on a breach nothing reaches the host and
    /// no handle exists.
    func beginRequest(operation: String, payload: Data) throws -> LinuxShellMailboxRequest {
        let token = try enqueue(operation: operation, payload: payload)
        condition.lock()
        let createdEpoch = tickets[token]?.createdEpoch ?? epoch
        let request = LinuxShellMailboxRequest(mailbox: self, token: token, submittedEpoch: createdEpoch)
        // Host claims require a continuation and `awaitReply` cannot start
        // before this handle is returned, so installation cannot lose an early
        // settlement. Direct sticky marking below makes the physical fact
        // independent of the bounded retired/hostSettled rings.
        tickets[token]?.ownerRequest = request
        condition.unlock()
        return request
    }

    /// The SAME bounded wait [submit] always performed, for one handle from
    /// [beginRequest]. Semantics are unchanged: exactly one resume, the budget
    /// watchdog and the cancellation handler below are the original ones.
    func awaitReply(_ request: LinuxShellMailboxRequest, timeoutMillis: Int) async throws -> Data {
        let token = request.token

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, LinuxShellTransportError>) in
                self.condition.lock()
                guard let live = self.tickets[token], live.state != .settled else {
                    self.condition.unlock()
                    continuation.resume(throwing: .hostFenced)
                    return
                }
                live.continuation = continuation
                self.condition.broadcast()
                self.condition.unlock()
                // Bounded wait WITHOUT parking a cooperative thread on a
                // semaphore: a budget watchdog resumes the waiter exactly
                // once when the real settlement has not arrived in time.
                Task { [self] in
                    await expireBudget(token: token, millis: timeoutMillis)
                }
            }
        } onCancel: { [self] in
            // Structural cancellation behaves exactly like the budget path:
            // provably-unclaimed work is retired (and its waiter released
            // once); claimed work stays owned for its real settlement.
            condition.lock()
            var resume: CheckedContinuation<Data, LinuxShellTransportError>?
            if let live = tickets[token], live.state == .queued {
                resume = live.continuation
                live.continuation = nil
                retireLocked(token)
            } else if let live = tickets[token], live.state == .claimed {
                resume = live.continuation
                live.continuation = nil
            }
            if resume != nil { counters.waitBudgetExpired += 1 }
            condition.broadcast()
            condition.unlock()
            resume?.resume(throwing: .waitBudgetExpired)
        }
    }

    // MARK: Per-ticket physical settlement (G05-R3)

    /// The mailbox's own table truth for one submitted token. `.live` means the
    /// mailbox still OWNS the ticket (queued or claimed), so the host may still
    /// be performing the real work; a released waiter never changes this.
    enum TicketTerminalState: Sendable, Equatable {
        case live
        case hostSettled
        case retiredUnclaimed
        /// Gone from the table with no recorded terminal (a generation
        /// fence/close dropped it, or the bounded ring evicted a much older
        /// terminal). Classification of that absence belongs to the handle,
        /// which knows the generation it was submitted under.
        case absent
    }

    func ticketState(token: Int64) -> TicketTerminalState {
        condition.lock()
        defer { condition.unlock() }
        if let ticket = tickets[token], ticket.state != .settled { return .live }
        if hostSettled.contains(token) { return .hostSettled }
        if retired.contains(token) { return .retiredUnclaimed }
        return .absent
    }

    /// The live generation truth a handle needs to classify an `.absent`
    /// ticket. Typed values only.
    func generationSnapshot() -> (epoch: UInt64, closed: Bool) {
        condition.lock()
        defer { condition.unlock() }
        return (epoch, closed)
    }

    /// Bounded wait until the mailbox stops owning this ticket. Amortized
    /// polling on the SAME injectable sleeper as the wait budget (never a
    /// parked cooperative thread). Answers false on budget expiry and changes
    /// NOTHING: a budget never fabricates settlement, never stops remote work
    /// and never detaches ownership.
    func awaitTicketReleased(token: Int64, timeoutMillis: Int) async -> Bool {
        let deadlineNanos = UInt64(max(1, timeoutMillis)) &* 1_000_000
        var waited: UInt64 = 0
        while waited < deadlineNanos {
            if ticketState(token: token) != .live { return true }
            await sleeper(Self.waitPollNanos)
            waited += Self.waitPollNanos
        }
        return ticketState(token: token) != .live
    }

    /// Records the host's real settlement of one claim (under the lock, from
    /// [complete]). Bounded exactly like the `retired` ring; tokens only.
    private func recordHostSettledLocked(_ token: Int64) {
        hostSettled.insert(token)
        hostSettledOrder.append(token)
        while hostSettledOrder.count > LinuxShellMailboxLimits.maximumRetired {
            hostSettled.remove(hostSettledOrder.removeFirst())
        }
    }

    /// Synchronous critical section; host claims require a registered
    /// continuation, so a fast peer cannot settle before the waiter exists.
    private func enqueue(operation: String, payload: Data) throws -> Int64 {
        guard payload.count <= LinuxShellMailboxLimits.maximumFrameBytes else {
            condition.lock(); counters.rejectedTooLarge += 1; condition.unlock()
            throw LinuxShellTransportError.payloadTooLarge
        }
        condition.lock()
        guard !closed else {
            counters.rejectedClosed += 1
            condition.unlock()
            throw LinuxShellTransportError.notBound
        }
        guard epoch != 0 else {
            counters.rejectedUnbound += 1
            condition.unlock()
            throw LinuxShellTransportError.notBound
        }
        guard tickets.count < LinuxShellMailboxLimits.maximumLiveTickets,
              queuedBytes + payload.count <= LinuxShellMailboxLimits.maximumQueuedPayloadBytes else {
            counters.rejectedSaturated += 1
            condition.unlock()
            throw LinuxShellTransportError.saturated
        }
        let token = nextToken
        nextToken += 1
        let ticket = Ticket(token: token, createdEpoch: epoch, operation: operation, payload: payload)
        tickets[token] = ticket
        queue.append(token)
        queuedBytes += payload.count
        counters.submitted += 1
        condition.broadcast()
        condition.unlock()

        return token
    }

    private func waiterFinished(_ token: Int64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return tickets[token] == nil || tickets[token]?.state == .settled
            || tickets[token]?.continuation == nil
    }

    /// Budget watchdog. Amortized polling (never a parked cooperative thread
    /// on a semaphore); the host claim path supplies the real settlement.
    private func expireBudget(token: Int64, millis: Int) async {
        let deadlineNanos = UInt64(max(1, millis)) &* 1_000_000
        var waited: UInt64 = 0
        while waited < deadlineNanos {
            await sleeper(Self.waitPollNanos)
            waited += Self.waitPollNanos
            if waiterFinished(token) { return }   // settled/fenced/resumed elsewhere
        }
        expireWaiter(token)
    }

    private func expireWaiter(_ token: Int64) {
        // Budget expired: release the WAITER, keep the ticket state honestly.
        // A queued ticket provably never reached the host and is retired; a
        // claimed ticket stays for its real settlement (late-settle
        // classification) so no one ever assumes a remote stop or exit.
        condition.lock()
        var resume: CheckedContinuation<Data, LinuxShellTransportError>?
        if let live = tickets[token], live.state == .queued, let continuation = live.continuation {
            live.continuation = nil
            retireLocked(token)
            resume = continuation
            counters.waitBudgetExpired += 1
        } else if let live = tickets[token], live.state == .claimed, let continuation = live.continuation {
            live.continuation = nil
            resume = continuation
            counters.waitBudgetExpired += 1
        }
        condition.broadcast()
        condition.unlock()
        resume?.resume(throwing: .waitBudgetExpired)
    }

    private func retireLocked(_ token: Int64) {
        // Queued payloads are accounted until retirement; a CLAIMED ticket
        // already decremented its payload at claim time.
        if let ticket = tickets[token], ticket.state == .queued {
            queuedBytes = max(0, queuedBytes - ticket.payload.count)
        }
        if let index = queue.firstIndex(of: token) { queue.remove(at: index) }
        tickets.removeValue(forKey: token)
        retired.insert(token)
        retiredOrder.append(token)
        while retiredOrder.count > LinuxShellMailboxLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    // MARK: Host ingress (C ABI)

    /// Non-blocking-with-bounded-wait claim of the oldest queued ticket for
    /// the CURRENT epoch. Returns the claim token or 0 on timeout/none.
    /// This call is the host poller heartbeat; the mailbox never times out a
    /// CLAIMED ticket itself.
    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        condition.lock()
        let boundEpoch = epoch
        guard !closed, boundEpoch != 0 else { condition.unlock(); return -1 }
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutMillis)) / 1000.0)
        while true {
            if let token = queue.first, let ticket = tickets[token],
               ticket.state == .queued, ticket.createdEpoch == boundEpoch,
               ticket.continuation != nil {
                queue.removeFirst()
                ticket.state = .claimed
                // Queued bytes accounted at claim time (the payload may still
                // be taken after the claim until settlement).
                queuedBytes = max(0, queuedBytes - ticket.payload.count)
                counters.claimed += 1
                condition.unlock()
                return token
            }
            if Date() >= deadline {
                condition.unlock()
                return 0
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            if closed { condition.unlock(); return -1 }
        }
    }

    /// Writes `{"operation":"<op>"}` for the claim into the caller buffer.
    public func describe(claim: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        guard let ticket = ticketForClaim(claim) else { return claimErrorCode(claim) }
        guard capacity > 0, let buffer else { return -105 }
        let text = "{\"operation\":\"\(ticket.operation)\"}"
        let bytes = Array(text.utf8)
        guard bytes.count + 1 <= Int(capacity) else { return -106 }
        for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
        return Int32(bytes.count)
    }

    public func payloadLength(claim: Int64) -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        guard let ticket = ticketForClaim(claim) else { return claimErrorCode(claim) }
        return Int32(ticket.payload.count)
    }

    /// Copies the bounded request payload; the buffer must fit it exactly.
    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        guard let ticket = ticketForClaim(claim) else { return claimErrorCode(claim) }
        guard capacity >= 0, let buffer, Int(capacity) >= ticket.payload.count else { return -106 }
        ticket.payload.withUnsafeBytes { raw in
            buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: ticket.payload.count)
        }
        return Int32(ticket.payload.count)
    }

    public func isLive(claim: Int64) -> Int32 {
        condition.lock()
        defer { condition.unlock() }
        guard let ticket = tickets[claim] else { return 0 }
        switch ticket.state {
        case .settled: return 0
        case .queued, .claimed: return ticket.createdEpoch == epoch ? 1 : 2  // 2 = foreign generation
        }
    }

    /// Claimed work outlives a cancelled/timed-out waiter. The host requests
    /// actual remote stop while retaining its work lease and receipt.
    public func shouldStop(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim] else { return 1 }
        return closed || ticket.createdEpoch != epoch || ticket.continuation == nil ? 1 : 0
    }

    /// Settle exactly one claimed ticket. status: 0 = completed (value is
    /// the engine result OBJECT JSON), 1 = failed (value is
    /// {"code":"<bounded-code>"}; since job-150dee8e1ed14ba1 the trusted
    /// host may ALSO settle a failed START with the additive optional pair
    /// "failureCode"+"recovery" carrying the ORIGINAL import transaction's
    /// journal-measured reverse-restore evidence, already identity-bound by
    /// the pump. That pair is parsed STRICTLY (see LinuxShellImportRestore):
    /// a well-formed pair delivers the typed evidence alongside the SAME
    /// code; a missing, foreign or malformed pair delivers the legacy
    /// `.remoteFailed(code:)` byte-identically. Settlement itself never
    /// fails because of the supplementary object — the legacy failed
    /// terminal is never poisoned, and nothing is zeroed or invented.)
    /// Re-validation: live claimed ticket of the
    /// CURRENT epoch, value within the frame bound and a JSON object.
    public func complete(claim: Int64, status: Int32, value: UnsafePointer<UInt8>?, valueLen: Int32) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim] else {
            if retired.contains(claim) { counters.lateSettle += 1; condition.unlock(); return -101 }
            condition.unlock(); return -101
        }
        guard ticket.state == .claimed else {
            counters.lateSettle += 1
            condition.unlock()
            return -109
        }
        guard ticket.createdEpoch == epoch else {
            counters.lateSettle += 1
            condition.unlock()
            return -102
        }
        guard status == 0 || status == 1, let value, valueLen >= 0,
              valueLen <= LinuxShellMailboxLimits.maximumFrameBytes else {
            condition.unlock(); return -105
        }
        let data = Data(bytes: value, count: Int(valueLen))
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            condition.unlock(); return -108
        }
        if status == 1, let code = (object as? [String: Any])?["code"] as? String,
           code.count > LinuxShellMailboxLimits.maximumCodeChars {
            condition.unlock(); return -106
        }
        let continuation = ticket.continuation
        ticket.continuation = nil
        ticket.state = .settled
        tickets.removeValue(forKey: claim)
        if status == 0 { counters.completed += 1 } else { counters.failed += 1 }
        retired.insert(claim)
        retiredOrder.append(claim)
        while retiredOrder.count > LinuxShellMailboxLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
        // The HOST-COMPLETED claim record: this exact claim reached the host
        // and terminated here. Physical IO ownership can still be retained by
        // the pump; the first-use rule separately requires its release proof.
        recordHostSettledLocked(claim)
        let ownerRequest = ticket.ownerRequest
        condition.broadcast()
        condition.unlock()
        // Sticky per-handle truth, marked AFTER dropping the mailbox lock so
        // lock ordering stays acyclic. The continuation resumes after this
        // mark, and a timed-out/cancelled retention observes the same fact.
        ownerRequest?.noteHostSettled()
        if status == 0 {
            continuation?.resume(returning: data)
        } else {
            let frame = object as? [String: Any]
            let code = (frame?["code"] as? String) ?? "operation_failed"
            // Typed failed-start handoff (job-150dee8e1ed14ba1): ONLY a
            // strictly well-formed additive pair becomes the typed evidence
            // case. Absent/foreign/malformed stays the legacy
            // remoteFailed(code:) byte-identically — the settled failure
            // terminal itself can never be poisoned or re-interpreted.
            if ticket.operation == "shell.start",
               let restore = LinuxShellImportRestore.parse(failureCode: frame?["failureCode"],
                                                           recovery: frame?["recovery"]),
               let payload = try? JSONSerialization.jsonObject(with: ticket.payload) as? [String: Any],
               let runText = payload["runID"] as? String,
               UUID(uuidString: runText) == UUID(uuidString: restore.runID) {
                continuation?.resume(throwing: .remoteFailedWithRestore(code: code, restore: restore))
            } else {
                continuation?.resume(throwing: .remoteFailed(code: code))
            }
        }
        return 0
    }

    private func ticketForClaim(_ claim: Int64) -> Ticket? {
        guard let ticket = tickets[claim], ticket.state == .claimed else { return nil }
        return ticket
    }

    private func claimErrorCode(_ claim: Int64) -> Int32 {
        guard let ticket = tickets[claim] else {
            return retired.contains(claim) ? -101 : -101
        }
        if ticket.createdEpoch != epoch { return -102 }
        return ticket.state == .claimed ? -109 : -101  // not claimed (still queued) or settled
    }

    /// Typed counters only — never ticket payloads or engine output.
    public var hasLiveTickets: Bool {
        condition.lock(); defer { condition.unlock() }
        return !tickets.isEmpty
    }

    /// Target-scoped view over the SAME ticket table for the ORIGINAL
    /// conversation-deletion fence and the shell ledger's per-run end
    /// predicate: true only when a live ticket's payload declares this
    /// `runID` (shell.start claims). Session-scoped poll/stop tickets are
    /// necessarily backed by a still-owned engine session, which the caller
    /// checks alongside via `ownedSessions(runID:)`. Tickets of OTHER runs
    /// never appear here, so an unrelated conversation cannot block a
    /// target drain (global `hasLiveTickets` stays reserved for process
    /// retirement gates, which legitimately wait for everything).
    public func hasLiveTickets(runID: UUID) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let target = runID.uuidString
        for ticket in tickets.values {
            guard ticket.operation == "shell.start" else { continue }
            if let object = try? JSONSerialization.jsonObject(with: ticket.payload)
                as? [String: Any],
               (object["runID"] as? String) == target {
                return true
            }
        }
        return false
    }

    public func statsJSON() -> String {
        condition.lock()
        let object: [String: Any] = [
            "live": tickets.count,
            "queued": queue.count,
            "queuedPayloadBytes": max(0, queuedBytes),
            "epoch": epoch,
            "closed": closed,
            "counters": [
                "submitted": counters.submitted,
                "saturated": counters.rejectedSaturated,
                "tooLarge": counters.rejectedTooLarge,
                "unbound": counters.rejectedUnbound,
                "closedRejects": counters.rejectedClosed,
                "claimed": counters.claimed,
                "completed": counters.completed,
                "failed": counters.failed,
                "waitBudgetExpired": counters.waitBudgetExpired,
                "lateSettle": counters.lateSettle,
                "fenced": counters.fenced,
                "bindRejections": counters.bindRejections,
            ],
        ]
        condition.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"stats_encoding\"}"
        }
        return string
    }

    internal func snapshotForTesting() -> (live: Int, queued: Int, epoch: UInt64, closed: Bool) {
        condition.lock()
        defer { condition.unlock() }
        return (tickets.count, queue.count, epoch, closed)
    }
}

// MARK: - Per-request settlement handle (G05-R3)

/// ONE submitted request's HOST-COMPLETION truth, handed back by
/// `LinuxShellMailbox.beginRequest` before any wait. Host completion is NOT
/// physical IO settlement: the pump can answer an uncertain reply and keep
/// its grant/reconciliation alive. The first-use ownership rule combines this
/// fact with the host's own physical-release observation.
///
/// Why this exists: `submit`'s continuation expresses WAITER completion only.
/// The original discipline (`expireWaiter`, the cancellation handler and
/// `bind`/`close`) deliberately resumes a waiter while a CLAIMED ticket stays
/// live for its real host settlement — so a service-owned lane that holds a
/// scoped workspace grant and a real `.conversation` receipt across the
/// request must NOT detach them when a wait expires or is cancelled:
///  * `hostSettled` — the trusted host completed/failed THIS exact claim;
///  * `retiredUnclaimed` — retired before any claim, so it provably never
///    reached the host and ownership may be released at once;
///  * `generationFenced` — the generation it was submitted under is closed or
///    replaced. This is NOT physical settlement: owned workers and remote
///    leases stay owned until their real release;
///  * `unknown` — ring/table absence is not physical settlement;
///  * `live` — the mailbox still owns it: keep the grant/receipt, wait again.
/// Tokens and typed states only; never payloads, replies, paths or digests.
public final class LinuxShellMailboxRequest: @unchecked Sendable {

    public enum Settlement: String, Sendable, Equatable {
        case live
        case hostSettled
        case retiredUnclaimed
        case generationFenced
        /// Gone without a recorded terminal while the SAME generation is still
        /// live (for example a bounded-ring eviction). Never a release proof.
        case unknown
    }

    private let mailbox: LinuxShellMailbox
    public let token: Int64
    public let submittedEpoch: UInt64
    private let stateLock = NSLock()
    private var stickyHostSettled = false

    init(mailbox: LinuxShellMailbox, token: Int64, submittedEpoch: UInt64) {
        self.mailbox = mailbox
        self.token = token
        self.submittedEpoch = submittedEpoch
    }

    /// Called by `complete` outside the mailbox condition lock. Once this exact
    /// claim completed on the host, later ring eviction/reset cannot falsify it.
    fileprivate func noteHostSettled() {
        stateLock.lock()
        stickyHostSettled = true
        stateLock.unlock()
    }

    private func hasHostSettled() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stickyHostSettled
    }

    public var settlement: Settlement {
        if hasHostSettled() { return .hostSettled }
        switch mailbox.ticketState(token: token) {
        case .live: return .live
        case .hostSettled:
            noteHostSettled()
            return .hostSettled
        case .retiredUnclaimed: return .retiredUnclaimed
        case .absent:
            let generation = mailbox.generationSnapshot()
            return (generation.closed || generation.epoch != submittedEpoch)
                ? .generationFenced : .unknown
        }
    }

    /// The mailbox still owns this ticket: the host may still be performing
    /// the real work. Ownership must be retained.
    public var isLive: Bool { settlement == .live }

    /// Bounded wait for the real transition. True only when the mailbox
    /// stopped owning the ticket within the budget; false changes nothing
    /// (never a fabricated settlement, never a stop, never a detach).
    public func awaitSettled(timeoutMillis: Int) async -> Bool {
        await mailbox.awaitTicketReleased(token: token, timeoutMillis: timeoutMillis)
    }
}

extension LinuxShellMailboxRequest: Equatable {
    /// Identity equality: one handle describes exactly one submitted ticket of
    /// exactly one mailbox (never value-equal to another request).
    public static func == (lhs: LinuxShellMailboxRequest, rhs: LinuxShellMailboxRequest) -> Bool {
        lhs.mailbox === rhs.mailbox && lhs.token == rhs.token
    }
}

// MARK: - Typed transport over the mailbox

/// The production `LinuxShellTransport`: typed engine requests <-> frozen
/// RuntimeWire v1 JSON frames (standard JSON objects only; <=64 KiB each).
/// The strict engine field sets are enforced HERE so a malformed typed
/// request never reaches the host. `request.status` polling stays inside the
/// trusted Kotlin pump; this transport only sees the settled result.
public struct MailboxLinuxShellTransport: LinuxShellTransport {
    public struct Budgets: Sendable {
        public var startMillis: Int
        public var pollMillis: Int
        public var inputMillis: Int
        public var resizeMillis: Int
        public var cancelMillis: Int
        public init(startMillis: Int = LinuxShellMailboxLimits.preparationBudgetMillis,
                    pollMillis: Int = LinuxShellMailboxLimits.pollBudgetMillis,
                    inputMillis: Int = LinuxShellMailboxLimits.inputBudgetMillis,
                    resizeMillis: Int = LinuxShellMailboxLimits.resizeBudgetMillis,
                    cancelMillis: Int = LinuxShellMailboxLimits.cancelBudgetMillis) {
            self.startMillis = startMillis
            self.pollMillis = pollMillis
            self.inputMillis = inputMillis
            self.resizeMillis = resizeMillis
            self.cancelMillis = cancelMillis
        }
    }

    public let mailbox: LinuxShellMailbox
    public let budgets: Budgets

    public init(mailbox: LinuxShellMailbox = .shared, budgets: Budgets = Budgets()) {
        self.mailbox = mailbox
        self.budgets = budgets
    }

    public func shellStart(_ request: LinuxShellStartRequest) async throws -> LinuxShellStartReply {
        var payload: [String: Any] = [
            "projectID": request.projectID.uuidString,
            "runID": request.runID.uuidString,
            "command": request.command,
            "cwd": request.cwd,
            "rows": request.rows,
            "columns": request.columns,
            "timeoutSeconds": request.timeoutSeconds,
        ]
        var hostObject: [String: Any] = [:]
        if let owner = request.hostToolCallID {
            // Private Core host metadata, STRIPPED before the runtime wire.
            hostObject["toolCallID"] = owner
        }
        if let operation = request.hostOperationID {
            // G04-R2 UI operation lease identity (trusted host only; same
            // strip-before-wire rule). nil omits the key entirely, so every
            // existing payload — ordinary run AND durable job starts — stays
            // byte-for-byte unchanged.
            hostObject["operationID"] = operation
        }
        if !hostObject.isEmpty { payload["host"] = hostObject }
        // G07.3A engine admission: the trusted caller's closed workload role
        // and validated same-workspace hint. They are PRIVATE host data (never
        // model/env/command text) and ride the top-level wire keys the actual
        // runtime `start` validates. nil OMITS each key so every legacy
        // start payload stays byte-for-byte unchanged (the runtime keeps its
        // historical Agent default for an absent role).
        if let role = request.hostLeaseRole {
            payload["leaseRole"] = role.rawValue
        }
        if let reuse = request.workspaceReuse {
            payload["workspaceReuse"] = try Self.workspaceReuseObject(reuse)
        }
        if let conversationID = request.conversationID {
            payload["conversationID"] = conversationID.uuidString
        }
        if let environmentID = request.environmentID, !environmentID.isEmpty {
            payload["environmentID"] = environmentID
        }
        // G03-R3 stdin EOF (job-c012c50e636f4fbb contract, forwarded by Main
        // 2026-10-22): the trusted caller's explicit one-shot delivery mode
        // rides as the engine's closed-set token. nil OMITS the key (never
        // null); the applied Kotlin defaults an absent key to "pty", so
        // interactive paths are byte-for-byte unchanged.
        if let stdinDelivery = request.stdinDelivery {
            payload["stdinDelivery"] = stdinDelivery.rawValue
        }
        // Explicit caller env rides UNCHANGED (bounds already validated by
        // the backend against the engine rules; re-checked here so no call
        // path can smuggle an out-of-bound map past the typed seam). The
        // Main process environment and stored credentials never enter here.
        if !request.environment.isEmpty {
            guard LinuxShellStartRequest.environmentRefusal(request.environment) == nil else {
                throw LinuxShellTransportError.payloadTooLarge
            }
            payload["env"] = request.environment
        }
        let reply = try await mailbox.submit(operation: "shell.start",
                                             payload: try Self.jsonData(payload),
                                             timeoutMillis: budgets.startMillis)
        let object = try Self.jsonObject(reply)
        guard let sessionID = object["sessionID"] as? String, !sessionID.isEmpty,
              let environmentID = object["environmentID"] as? String, !environmentID.isEmpty else {
            throw LinuxShellTransportError.replyMalformed
        }
        // G07.3A start reply metadata (all ADDITIVE and OPTIONAL). The actual
        // runtime `start` reports the measured admission facts this session
        // really observed; an absent key (legacy engine) stays nil and is
        // NEVER replaced by a fabricated false/zero. A present but malformed
        // value fails closed instead of silently inventing truth.
        let runtimeGeneration = try Self.optionalBoundedToken(
            object, key: "runtimeGeneration", maximumBytes: 128)
        let workspaceOwner = try Self.optionalStrictBool(object, key: "workspaceOwner")
        let prepareReused = try Self.optionalStrictBool(object, key: "prepareReused")
        let prepareMillis = try Self.optionalNonNegativeInt64(object, key: "prepareMillis")
        let prepareCopiedBytes = try Self.optionalNonNegativeInt64(object, key: "prepareCopiedBytes")
        let importMillis = try Self.optionalNonNegativeInt64(object, key: "importMillis")
        let importedEntries = try Self.optionalNonNegativeInt64(object, key: "importedEntries")
        return LinuxShellStartReply(
            sessionID: sessionID, environmentID: environmentID,
            runtimeGeneration: runtimeGeneration, workspaceOwner: workspaceOwner,
            prepareReused: prepareReused, prepareMillis: prepareMillis,
            prepareCopiedBytes: prepareCopiedBytes, importMillis: importMillis,
            importedEntries: importedEntries)
    }

    public func shellPoll(_ request: LinuxShellPollRequest) async throws -> LinuxShellPollReply {
        guard request.maxBytes >= 1, request.maxBytes <= 16_384 else {
            throw LinuxShellTransportError.payloadTooLarge   // engine page bound
        }
        guard request.cursor <= UInt64(Int64.max) else {
            throw LinuxShellTransportError.payloadTooLarge   // engine Long bound
        }
        let payload: [String: Any] = [
            "sessionID": request.sessionID,
            "cursor": request.cursor,
            "maxBytes": request.maxBytes,
        ]
        let reply = try await mailbox.submit(operation: "shell.poll",
                                             payload: try Self.jsonData(payload),
                                             timeoutMillis: budgets.pollMillis)
        let object = try Self.jsonObject(reply)
        guard let sessionID = object["sessionID"] as? String, sessionID == request.sessionID,
              let cursor = Self.intValue(object["cursor"]), cursor >= 0,
              let stateRaw = object["state"] as? String,
              let leaseReleased = object["leaseReleased"] as? Bool else {
            throw LinuxShellTransportError.replyMalformed
        }
        let output: Data
        if let base64 = object["outputBase64"] as? String, !base64.isEmpty {
            // Engine NO_WRAP standard base64 of the MERGED PTY bytes.
            guard let decoded = Data(base64Encoded: base64) else {
                throw LinuxShellTransportError.replyMalformed
            }
            output = decoded
        } else {
            output = Data()
        }
        var poll = LinuxShellPollReply(
            sessionID: sessionID,
            mergedOutput: output,
            cursor: UInt64(cursor),
            gapBytes: Self.intValue(object["gapBytes"]) ?? 0,
            more: (object["more"] as? Bool) ?? false,
            droppedBytes: max(0, Self.intValue(object["droppedBytes"]) ?? 0),
            state: LinuxShellSessionState(raw: stateRaw),
            leaseReleased: leaseReleased,
            cancelled: (object["cancelled"] as? Bool) ?? false,
            stopReason: object["stopReason"] as? String,
            exitCode: Self.int32Value(object["exitCode"]),
            termSig: Self.int32Value(object["termSig"]),
            waitErrno: Self.int32Value(object["waitErrno"]),
            workspaceStatus: leaseReleased ? object["workspaceStatus"] as? String : nil,
            workspaceRecoveryRef: leaseReleased ? object["workspaceRecoveryRef"] as? String : nil)
        if let state = poll.workspaceStatus,
           !["synced", "conflict", "aborted", "error", "unknown", "deferred"].contains(state) {
            throw LinuxShellTransportError.replyMalformed
        }
        // G07.3A deferred shared export: `deferred` is honest only after the
        // engine proved THIS session's real terminal (leaseReleased) and the
        // runtime attached a typed ownership fact. The owner reports
        // workspaceOwner=true; a participant reports false (the export is
        // owned by another live session). An absent/non-boolean owner is
        // malformed — never read as a saved workspace, a fake exit, or a
        // relaxable lease.
        if object["workspaceStatus"] as? String == "deferred" {
            guard leaseReleased,
                  Self.strictBool(object["workspaceOwner"]) != nil else {
                throw LinuxShellTransportError.replyMalformed
            }
        }
        if let ref = poll.workspaceRecoveryRef,
           ref.range(of: "^[0-9a-f]{32}$", options: .regularExpression) == nil {
            throw LinuxShellTransportError.replyMalformed
        }
        // OPTIONAL bounded recovery projection (additive metadata). A
        // missing object parses as nil (legacy results keep working with
        // NO fabricated zero); a malformed supplementary object is dropped
        // to nil rather than poisoning the poll contract itself.
        if leaseReleased {
            poll.workspaceRecovery = LinuxShellWorkspaceRecovery.parse(object["workspaceRecovery"])
        }
        return poll
    }

    public func shellInput(_ request: LinuxShellInputRequest) async throws -> LinuxShellInputReply {
        guard request.bytes.count <= 16_384 else {
            throw LinuxShellTransportError.payloadTooLarge   // engine stdin chunk bound
        }
        let payload: [String: Any] = [
            "sessionID": request.sessionID,
            "inputBase64": request.bytes.base64EncodedString(),
        ]
        let reply = try await mailbox.submit(operation: "shell.input",
                                             payload: try Self.jsonData(payload),
                                             timeoutMillis: budgets.inputMillis)
        let object = try Self.jsonObject(reply)
        guard let accepted = Self.intValue(object["acceptedBytes"]), accepted >= 0 else {
            throw LinuxShellTransportError.replyMalformed
        }
        return LinuxShellInputReply(acceptedBytes: accepted,
                                    partial: (object["partial"] as? Bool) ?? false,
                                    errnoCode: Self.int32Value(object["errno"]),
                                    // G03-R3 stdin EOF additive decode (tolerant
                                    // optional casts: data pages and pre-field
                                    // engines simply omit these keys; the value
                                    // is never invented here).
                                    stdinEof: object["stdinEof"] as? String,
                                    stdinEofReason: object["reason"] as? String)
    }

    public func shellResize(_ request: LinuxShellResizeRequest) async throws -> LinuxShellResizeReply {
        guard request.rows >= 1, request.rows <= 512,
              request.columns >= 1, request.columns <= 512 else {
            throw LinuxShellTransportError.payloadTooLarge   // engine resize bound
        }
        let payload: [String: Any] = [
            "sessionID": request.sessionID,
            "rows": request.rows,
            "columns": request.columns,
        ]
        let reply = try await mailbox.submit(operation: "shell.resize",
                                             payload: try Self.jsonData(payload),
                                             timeoutMillis: budgets.resizeMillis)
        let object = try Self.jsonObject(reply)
        guard let resized = object["resized"] as? Bool else {
            throw LinuxShellTransportError.replyMalformed
        }
        return LinuxShellResizeReply(resized: resized)
    }

    public func shellCancel(_ request: LinuxShellCancelRequest) async throws -> LinuxShellCancelReply {
        let payload: [String: Any] = ["sessionID": request.sessionID]
        // Exact sessionID only: the engine refuses to stop another workload
        // (validateCancellation), and "stop_requested" is NOT a proven stop.
        let reply = try await mailbox.submit(operation: "shell.cancel",
                                             payload: try Self.jsonData(payload),
                                             timeoutMillis: budgets.cancelMillis)
        let object = try Self.jsonObject(reply)
        guard let state = object["state"] as? String else {
            throw LinuxShellTransportError.replyMalformed
        }
        return LinuxShellCancelReply(state: state)
    }

    // MARK: JSON helpers (standard JSON only, bounded frames)

    /// Validates the SAME trusted same-workspace hint the runtime `start`
    /// accepts: the closed mode `shared` and, when present, a non-empty
    /// bounded owner identity. A malformed hint is REFUSED here instead of
    /// being dropped — dropping it would silently start a fresh owner and
    /// re-import over a live participant's guest tree.
    static func workspaceReuseObject(_ reuse: LinuxShellWorkspaceReuse) throws -> [String: Any] {
        guard reuse.mode == "shared" else {
            throw LinuxShellTransportError.payloadTooLarge
        }
        var object: [String: Any] = ["mode": reuse.mode]
        if let owner = reuse.ownerSessionID {
            guard Self.isBoundedToken(owner, maximumBytes: 128) else {
                throw LinuxShellTransportError.payloadTooLarge
            }
            object["ownerSessionID"] = owner
        }
        return object
    }

    /// Optional bounded printable token: absent → nil; present but empty,
    /// oversized or containing control/whitespace bytes → malformed.
    static func optionalBoundedToken(_ object: [String: Any], key: String,
                                     maximumBytes: Int) throws -> String? {
        guard let raw = object[key] else { return nil }
        guard let value = raw as? String, Self.isBoundedToken(value, maximumBytes: maximumBytes) else {
            throw LinuxShellTransportError.replyMalformed
        }
        return value
    }

    private static func isBoundedToken(_ value: String, maximumBytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else { return false }
        return value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    /// Optional real JSON boolean. NSNumber `intValue`-style bridging would
    /// turn a malformed `1` into `true`; only the CFBoolean type qualifies.
    static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func optionalStrictBool(_ object: [String: Any], key: String) throws -> Bool? {
        guard let raw = object[key] else { return nil }
        guard let value = Self.strictBool(raw) else {
            throw LinuxShellTransportError.replyMalformed
        }
        return value
    }

    /// Optional exact non-negative integer (the same trust idiom as the strict
    /// recovery counters: no Bool, no fraction, no negative). Absence stays
    /// nil; a malformed value fails closed.
    static func optionalNonNegativeInt64(_ object: [String: Any], key: String) throws -> Int64? {
        guard let raw = object[key] else { return nil }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw LinuxShellTransportError.replyMalformed
        }
        let integer = number.int64Value
        guard integer >= 0,
              number.compare(NSNumber(value: integer)) == .orderedSame else {
            throw LinuxShellTransportError.replyMalformed
        }
        return integer
    }

    static func jsonData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= LinuxShellMailboxLimits.maximumFrameBytes else {
            throw LinuxShellTransportError.payloadTooLarge
        }
        return data
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw LinuxShellTransportError.replyMalformed
        }
        return dictionary
    }

    static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    static func int32Value(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber { return number.int32Value }
        return nil
    }
}

// MARK: - C ABI (trusted Kotlin host only)

@_cdecl("floe_linux_shell_mailbox_bind")
public func floeLinuxShellMailboxBind(_ epoch: UInt64) -> Int32 {
    LinuxShellMailbox.shared.bind(epoch: epoch) ? 0 : -105
}

@_cdecl("floe_linux_shell_mailbox_next")
public func floeLinuxShellMailboxNext(_ timeoutMillis: Int32) -> Int64 {
    LinuxShellMailbox.shared.nextClaim(timeoutMillis: timeoutMillis)
}

@_cdecl("floe_linux_shell_mailbox_describe")
public func floeLinuxShellMailboxDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                          _ capacity: Int32) -> Int32 {
    LinuxShellMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_linux_shell_mailbox_payload_length")
public func floeLinuxShellMailboxPayloadLength(_ claim: Int64) -> Int32 {
    LinuxShellMailbox.shared.payloadLength(claim: claim)
}

@_cdecl("floe_linux_shell_mailbox_take_payload")
public func floeLinuxShellMailboxTakePayload(_ claim: Int64, _ buffer: UnsafeMutablePointer<UInt8>?,
                                             _ capacity: Int32) -> Int32 {
    LinuxShellMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_linux_shell_mailbox_is_live")
public func floeLinuxShellMailboxIsLive(_ claim: Int64) -> Int32 {
    LinuxShellMailbox.shared.isLive(claim: claim)
}

@_cdecl("floe_linux_shell_mailbox_should_stop")
public func floeLinuxShellMailboxShouldStop(_ claim: Int64) -> Int32 {
    LinuxShellMailbox.shared.shouldStop(claim: claim)
}

@_cdecl("floe_linux_shell_mailbox_complete")
public func floeLinuxShellMailboxComplete(_ claim: Int64, _ status: Int32,
                                          _ value: UnsafePointer<UInt8>?,
                                          _ valueLen: Int32) -> Int32 {
    LinuxShellMailbox.shared.complete(claim: claim, status: status, value: value, valueLen: valueLen)
}

@_cdecl("floe_linux_shell_mailbox_close")
public func floeLinuxShellMailboxClose() -> Int32 {
    LinuxShellMailbox.shared.close()
    return 0
}

@_cdecl("floe_linux_shell_mailbox_stats")
public func floeLinuxShellMailboxStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    let text = LinuxShellMailbox.shared.statsJSON()
    guard let buffer, capacity > 0 else { return -105 }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -106 }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
