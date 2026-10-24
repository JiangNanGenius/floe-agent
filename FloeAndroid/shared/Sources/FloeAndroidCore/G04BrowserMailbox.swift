// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 browser host mailbox — the trusted Kotlin-host execution channel for
// the Swift-owned browser renderer port, loopback preview transport, and the
// one-way UI deliveries (projections, popup decisions, download signals,
// tool/command replies).
//
// This is the SAME reviewed `G04WorkspaceSourceMailbox` shape the G04 SAF
// lane ships (itself the LinuxShellMailbox shape): Swift owns one bounded
// ticket table per bound root epoch; the trusted Kotlin host claims tickets
// through the exported C ABI, performs the ACTUAL platform IO (WebView on the
// main looper, loopback sockets on transport threads), and settles each claim
// exactly once. Model dispatch has no route here: no V3 handler key, no
// command name, no bridge payload — only the service's own ticket reaches the
// host. Page content can never mint or settle a ticket.
//
// Engine pump contract implemented by the trusted Kotlin host:
//   bind(epoch)                     -> strictly newer POSITIVE root epoch,
//                                      only while that epoch is the live
//                                      native root (checked in the export).
//   next(timeoutMillis) -> claim    -> blocks up to the budget for the next
//                                      queued ticket; 0 = none (re-arm).
//   describe(claim, buf, cap)       -> ticket descriptor JSON; -106 =
//                                      bufferTooSmall (exact length on
//                                      success).
//   payloadLength / takePayload     -> staged downlink bytes (the probe
//                                      install source for `renderer.create-
//                                      Tab`, the built expression for
//                                      `renderer.evaluate`, the projection/
//                                      delivery JSON for event tickets).
//   isLive / shouldStop             -> settlement classification + the REAL
//                                      cancellation request: when 1 the host
//                                      must stop its platform work and still
//                                      settle the claim exactly once.
//   complete(claim, status, bytes)  -> status 0 = success (value bytes per
//                                      the operation contract); status 1 =
//                                      typed failure {"code": "<token>"}.
//                                      For event tickets settlement merely
//                                      frees the claim (status is counted,
//                                      nothing awaits it).
//   close(epoch) / stats            -> exact-generation teardown + typed
//                                      counters (no paths, no page bytes).
//
// Ownership rules enforced HERE, not by trust: a live claim settles ONCE
// (late/duplicate is classified and counted, never resumed twice); a
// stale-generation claim can never settle the current table; cancellation is
// a REQUEST — the ticket stays owned until the host's actual platform work
// settles or the reviewed budget classifies an UNCLAIMED ticket `hostBudget`.
// There is no timeout detach of claimed IO: the Swift session's own
// `BrowserRaceGate` bounds what AGENTS wait, while the mailbox keeps the
// claim honest for late-settle classification. No fake completion exists.
import Foundation
import FloeCore
import FloeTools

/// Closed ticket vocabulary. Kotlin pattern-matches `operation` from the
/// descriptor; anything unknown to the host is settled as a typed failure —
/// never executed with page-supplied semantics.
public enum G04BrowserTicketKind: String, Sendable, Codable, CaseIterable {
    // Awaitable downlink (Swift waits for the host answer).
    case rendererCreateTab = "renderer.createTab"
    case rendererDestroyTab = "renderer.destroyTab"
    case rendererNavigate = "renderer.navigate"
    case rendererGoBack = "renderer.goBack"
    case rendererGoForward = "renderer.goForward"
    case rendererReload = "renderer.reload"
    case rendererStopLoading = "renderer.stopLoading"
    case rendererState = "renderer.state"
    case rendererEvaluate = "renderer.evaluate"
    case rendererScreenshot = "renderer.screenshot"
    case rendererRelease = "renderer.release"
    case transportStart = "transport.start"
    case transportStop = "transport.stop"
    // One-way downlink events (fire-and-forget; the host frees the claim).
    case uiProjection = "ui.projection"
    case uiPopupDecision = "ui.popupDecision"
    case uiDownloadSignal = "ui.downloadSignal"
    case uiToolResult = "ui.toolResult"
    case uiCommandResult = "ui.commandResult"

    var isEvent: Bool {
        switch self {
        case .uiProjection, .uiPopupDecision, .uiDownloadSignal, .uiToolResult, .uiCommandResult:
            return true
        default:
            return false
        }
    }
}

public enum G04BrowserMailboxLimits {
    public static let maximumLiveTickets = 256
    /// One owner's outstanding platform round trips are bounded tightly so
    /// one saturated task can never starve the shared table.
    public static let maximumLivePerConversation = 24
    public static let maximumRetired = 2048
    public static let maximumEventTickets = 128
    public static let maximumCodeChars = 96
    public static let maximumDescriptorBytes = 4096
    /// Probe install source is ~15 KiB; expressions are bounded by the
    /// session's own caps. The staged downlink ceiling covers both with
    /// margin while remaining far below any "buffer whole bodies" shape.
    public static let maximumStagedBytes = 256 * 1024
    /// Completion ceilings (host -> Swift): evaluate JSON text.
    public static let maximumCompletionBytes = 2 * 1024 * 1024
    /// Screenshot completion ceiling mirrors the module's 8 MiB bound.
    public static let maximumScreenshotBytes = 9 * 1024 * 1024
    public static let defaultBudgetMillis = 30_000
}

/// Typed settlement of one host platform attempt.
public enum G04BrowserMailboxError: Error, Sendable, Equatable {
    case hostUnbound
    case hostFenced
    case saturated
    case oversized
    case remoteFailed(code: String)
}

public final class G04BrowserMailbox: @unchecked Sendable {
    public static let shared = G04BrowserMailbox()

    private final class Ticket {
        let claim: Int64
        let operation: G04BrowserTicketKind
        /// The owning conversation for the per-owner live bound and for the
        /// host's routing of the claim (descriptor carries the same value).
        let conversation: UUID
        /// Mutable ONLY for the documented coalesced replace-in-place path,
        /// and only while the mailbox condition lock is held.
        var descriptor: Data
        var staged: Data
        let createdEpoch: UInt64
        let deadline: DispatchTime
        /// Awaitable tickets carry the caller's cancellation so the host can
        /// observe `shouldStop` while it still settles exactly once. Event
        /// tickets never await and use `nil`.
        let cancellation: CancellationToken?
        /// Event coalescing key ("ui.projection" keeps only the latest
        /// pending payload per conversation; delivery events are keyed by
        /// their own request identity).
        let coalesceKey: String?
        var state = 0 // 0 queued, 1 claimed, 2 settled-removed
        var continuation: CheckedContinuation<Data, G04BrowserMailboxError>?
        init(claim: Int64, operation: G04BrowserTicketKind, conversation: UUID,
             descriptor: Data,
             staged: Data, epoch: UInt64, deadline: DispatchTime,
             cancellation: CancellationToken?, coalesceKey: String?) {
            self.claim = claim; self.operation = operation; self.conversation = conversation
            self.descriptor = descriptor
            self.staged = staged; self.createdEpoch = epoch; self.deadline = deadline
            self.cancellation = cancellation; self.coalesceKey = coalesceKey
        }
    }

    private let condition = NSCondition()
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    /// Coalescing index for event tickets: key -> claim currently queued.
    private var eventByCoalesceKey: [String: Int64] = [:]
    private var counter: Int64 = 0
    private var epoch: UInt64 = 0
    private var closed = true
    private var counters = (submitted: 0, claimed: 0, completed: 0, failed: 0,
                            lateSettle: 0, fenced: 0, saturated: 0, unbound: 0,
                            expired: 0, bindRejections: 0, coalesced: 0,
                            eventDropped: 0)

    private init() {}

    public var boundEpoch: UInt64 { condition.lock(); defer { condition.unlock() }; return epoch }
    public var isBound: Bool { condition.lock(); defer { condition.unlock() }; return !closed && epoch != 0 }

    /// Strictly-newer positive epoch only; fences ALL waiters with the typed
    /// `.hostFenced` while claimed tickets move to the retired ring for
    /// honest late-settle classification. Returns false (and changes
    /// nothing) otherwise.
    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch != 0, newEpoch > epoch else {
            counters.bindRejections += 1
            condition.unlock()
            return false
        }
        epoch = newEpoch
        closed = false
        var resumes: [CheckedContinuation<Data, G04BrowserMailboxError>] = []
        for token in queue {
            guard let ticket = tickets[token], ticket.state == 0, let continuation = ticket.continuation
            else { continue }
            ticket.continuation = nil
            resumes.append(continuation)
            retireLocked(token)
        }
        queue.removeAll()
        eventByCoalesceKey.removeAll()
        for ticket in tickets.values where ticket.state == 1 {
            counters.fenced += 1
            if let continuation = ticket.continuation {
                ticket.continuation = nil
                resumes.append(continuation)
            }
            retireLocked(ticket.claim)
        }
        tickets.removeAll()
        counters.submitted = 0
        counters.claimed = 0
        counters.completed = 0
        counters.failed = 0
        counters.lateSettle = 0
        counters.fenced = 0
        counters.saturated = 0
        counters.unbound = 0
        counters.expired = 0
        counters.bindRejections = 0
        counters.coalesced = 0
        counters.eventDropped = 0
        condition.broadcast()
        condition.unlock()
        for continuation in resumes { continuation.resume(throwing: .hostFenced) }
        return true
    }

    /// Exact-generation teardown. Every waiter settles typed and every
    /// claimed ticket moves to the retired ring for late-settle
    /// classification — there is no silent detach.
    public func close(epoch closing: UInt64) {
        condition.lock()
        guard !closed, epoch == closing else { condition.unlock(); return }
        closed = true
        var resumes: [CheckedContinuation<Data, G04BrowserMailboxError>] = []
        for token in queue {
            guard let ticket = tickets[token], ticket.state == 0, let continuation = ticket.continuation
            else { continue }
            ticket.continuation = nil
            resumes.append(continuation)
            retireLocked(token)
        }
        queue.removeAll()
        eventByCoalesceKey.removeAll()
        for ticket in tickets.values {
            counters.fenced += 1
            if let continuation = ticket.continuation {
                ticket.continuation = nil
                resumes.append(continuation)
            }
        }
        tickets.removeAll()
        condition.broadcast()
        condition.unlock()
        for continuation in resumes { continuation.resume(throwing: .hostFenced) }
    }

    // MARK: - Awaitable downlink (renderer / transport)

    /// Submit one awaitable platform ticket and wait for the host's ACTUAL
    /// settlement. `cancellation` is a REQUEST surfaced through `shouldStop`;
    /// the ticket remains owned until settled or the generation closes.
    public func submit(_ operation: G04BrowserTicketKind,
                       expectedEpoch: UInt64,
                       conversation: UUID,
                       descriptor: [String: String],
                       staged: Data,
                       budgetMillis: Int,
                       cancellation: CancellationToken?) async throws -> Data {
        guard !operation.isEvent else { throw G04BrowserMailboxError.hostUnbound }
        guard staged.count <= G04BrowserMailboxLimits.maximumStagedBytes else {
            throw G04BrowserMailboxError.oversized
        }
        if cancellation?.isCancelled == true { throw G04BrowserMailboxError.hostFenced }
        // describe() supplies the actual admitted epoch; do not duplicate
        // its descriptor codec here. Admission below checks the caller's
        // immutable epoch before this request can enter that generation.
        var object = descriptor
        object["operation"] = operation.rawValue
        object["conversationID"] = conversation.uuidString
        let payload = (try? JSONSerialization.data(withJSONObject: object,
                                                   options: [.sortedKeys])) ?? Data("{}".utf8)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                condition.lock()
                guard !closed, epoch != 0 else {
                    counters.unbound += 1
                    condition.unlock()
                    continuation.resume(throwing: G04BrowserMailboxError.hostUnbound)
                    return
                }
                guard expectedEpoch > 0, expectedEpoch == epoch else {
                    condition.unlock()
                    continuation.resume(throwing: G04BrowserMailboxError.hostFenced)
                    return
                }
                let liveForOwner = tickets.values.reduce(0) { total, ticket in
                    guard ticket.conversation == conversation, !ticket.operation.isEvent,
                          ticket.state <= 1 else { return total }
                    return total + 1
                }
                guard tickets.count < G04BrowserMailboxLimits.maximumLiveTickets,
                      liveForOwner < G04BrowserMailboxLimits.maximumLivePerConversation
                else {
                    counters.saturated += 1
                    condition.unlock()
                    continuation.resume(throwing: G04BrowserMailboxError.saturated)
                    return
                }
                counter &+= 1
                let ticket = Ticket(
                    claim: counter, operation: operation, conversation: conversation,
                    descriptor: payload, staged: staged,
                    epoch: epoch,
                    deadline: DispatchTime.now() + .milliseconds(max(250, budgetMillis)),
                    cancellation: cancellation, coalesceKey: nil)
                ticket.continuation = continuation
                tickets[counter] = ticket
                queue.append(counter)
                counters.submitted += 1
                condition.broadcast()
                condition.unlock()
            }
        } onCancel: {
            // Cancellation is a request only: it reaches the host through
            // `shouldStop` (the ticket's own token), never by detaching the
            // continuation or faking a value.
            cancellation?.cancel()
        }
    }

    // MARK: - One-way downlink events

    /// Queue one delivery event. Coalescing keys replace the newest pending
    /// payload for the SAME key (projections: latest truth only, ordered by
    /// emission point). A full event ring drops the OLDEST pending event for
    /// a different key and counts the drop honestly (a stale projection is
    /// worthless; a dropped popup/tool reply surfaces as an un-answered
    /// request on the Kotlin side — never a silent success).
    public func submitEvent(_ operation: G04BrowserTicketKind,
                            expectedEpoch: UInt64,
                            conversation: UUID,
                            payload: Data,
                            coalesceKey: String?) {
        precondition(operation.isEvent, "awaitable kinds use submit")
        condition.lock()
        guard !closed, epoch != 0, expectedEpoch == epoch else {
            counters.unbound += 1
            condition.unlock()
            return
        }
        let descriptor: [String: Any] = [
            "operation": operation.rawValue,
            "conversationID": conversation.uuidString,
            "epoch": String(epoch),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: descriptor,
                                                options: [.sortedKeys])) ?? Data("{}".utf8)
        let key = coalesceKey.map { "\(operation.rawValue)|\($0)" }
        if let key, let existing = eventByCoalesceKey[key],
           let old = tickets[existing], old.state == 0 {
            // Replace-in-place: the queue slot stays, only the payload and
            // descriptor update, preserving FIFO emission order per key while
            // keeping only the newest truth.
            old.descriptor = data
            old.staged = payload
            counters.coalesced += 1
            condition.unlock()
            return
        }
        if key == nil {
            let pendingEvents = tickets.values.reduce(0) { total, ticket in
                total + (ticket.operation.isEvent && ticket.state == 0 ? 1 : 0)
            }
            if pendingEvents >= G04BrowserMailboxLimits.maximumEventTickets {
                // Drop the OLDEST non-coalescing pending event and admit the
                // newest (delivery events are fresher by construction).
                if let oldest = queue.first(where: { token in
                    guard let ticket = tickets[token], ticket.operation.isEvent,
                          ticket.state == 0, ticket.coalesceKey == nil else { return false }
                    return true
                }) {
                    queue.removeAll { $0 == oldest }
                    tickets.removeValue(forKey: oldest)
                    counters.eventDropped += 1
                    counters.saturated += 1
                } else {
                    counters.eventDropped += 1
                    condition.unlock()
                    return
                }
            }
        }
        guard tickets.count < G04BrowserMailboxLimits.maximumLiveTickets else {
            counters.saturated += 1
            condition.unlock()
            return
        }
        counter &+= 1
        let ticket = Ticket(
            claim: counter, operation: operation, conversation: conversation,
            descriptor: data, staged: payload,
            epoch: epoch,
            deadline: .distantFuture,
            cancellation: nil, coalesceKey: key)
        tickets[counter] = ticket
        queue.append(counter)
        if let key { eventByCoalesceKey[key] = counter }
        counters.submitted += 1
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Host pump surface

    /// Host claims the next queued ticket within the budget. 0 = none.
    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        var expired: [CheckedContinuation<Data, G04BrowserMailboxError>] = []
        defer {
            for continuation in expired { continuation.resume(throwing: .remoteFailed(code: "hostBudget")) }
        }
        condition.lock()
        let deadline = Date(timeIntervalSinceNow: Double(max(0, Int(max(0, timeoutMillis)))) / 1000)
        var claim: Int64 = 0
        while true {
            if closed || epoch == 0 { break }
            if let head = queue.first {
                queue.removeFirst()
                guard let ticket = tickets[head], ticket.state == 0 else { continue }
                if ticket.deadline < DispatchTime.now() { expireLocked(head, into: &expired); continue }
                ticket.state = 1
                counters.claimed += 1
                claim = head
                break
            }
            if condition.wait(until: deadline) { continue }
            for (pending, ticket) in tickets where ticket.state == 0 && ticket.deadline < DispatchTime.now() {
                expireLocked(pending, into: &expired)
            }
            break
        }
        condition.unlock()
        return claim
    }

    /// Settle one claimed ticket with the ACTUAL host outcome, ONCE.
    /// `value` is the operation-specific success payload; on failure it is a
    /// JSON `{"code":"<bounded token>"}` from the frozen vocabulary.
    @discardableResult
    public func complete(claim: Int64, status: Int32, value: Data) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim] else {
            if retired.contains(claim) { counters.lateSettle += 1 }
            condition.unlock()
            return -101
        }
        guard ticket.state == 1 else { condition.unlock(); return -110 }
        guard ticket.createdEpoch == epoch, !closed else {
            counters.lateSettle += 1
            condition.unlock()
            return -102
        }
        guard status == 0 || status == 1 else { condition.unlock(); return -105 }
        let ceiling = ticket.operation == .rendererScreenshot
            ? G04BrowserMailboxLimits.maximumScreenshotBytes
            : G04BrowserMailboxLimits.maximumCompletionBytes
        if status == 0, value.count > ceiling {
            condition.unlock()
            return -107
        }
        // Event tickets: settlement merely frees the claim.
        if ticket.operation.isEvent {
            if let key = ticket.coalesceKey { eventByCoalesceKey.removeValue(forKey: key) }
            ticket.state = 2
            condition.unlock()
            retireAndCount(claim)
            counters.completed += 1
            return 0
        }
        let outcome: Result<Data, G04BrowserMailboxError>
        if status == 0 {
            outcome = .success(value)
            counters.completed += 1
        } else {
            let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any]
            let raw = object?["code"] as? String
            let code = (raw.map { !$0.isEmpty && $0.count <= G04BrowserMailboxLimits.maximumCodeChars } ?? false)
                ? raw! : "platformFailed"
            outcome = .failure(.remoteFailed(code: code))
            counters.failed += 1
        }
        let continuation = ticket.continuation
        ticket.continuation = nil
        ticket.state = 2
        condition.unlock()
        retireAndCount(claim)
        switch outcome {
        case .success(let data): continuation?.resume(returning: data)
        case .failure(let error): continuation?.resume(throwing: error)
        }
        return 0
    }

    public func describe(claim: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim], ticket.state == 1, ticket.createdEpoch == epoch, !closed
        else { condition.unlock(); return -101 }
        var object = (try? JSONSerialization.jsonObject(with: ticket.descriptor)) as? [String: Any] ?? [:]
        object["epoch"] = String(ticket.createdEpoch)
        condition.unlock()
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= G04BrowserMailboxLimits.maximumDescriptorBytes else { return -108 }
        guard capacity >= 0, let buffer, data.count + 1 <= Int(capacity) else { return -106 }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, data.count)
        }
        buffer[data.count] = 0
        return Int32(data.count)
    }

    public func payloadLength(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1, ticket.createdEpoch == epoch, !closed
        else { return -101 }
        return Int32(ticket.staged.count)
    }

    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1, ticket.createdEpoch == epoch, !closed
        else { return -101 }
        guard let buffer, capacity >= ticket.staged.count else { return -106 }
        guard !ticket.staged.isEmpty else { return 0 }
        ticket.staged.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, ticket.staged.count)
        }
        return Int32(ticket.staged.count)
    }

    public func isLive(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.createdEpoch == epoch, !closed else { return 0 }
        return ticket.state == 0 || (ticket.state == 1 && (ticket.operation.isEvent || ticket.continuation != nil)) ? 1 : 0
    }

    /// 1 = the owning round trip was abandoned/cancelled or the generation
    /// fenced: the host MUST stop the platform work and still settle exactly
    /// once. Never a Swift-side detach-on-timeout.
    public func shouldStopClaim(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else { return 1 }
        return ticket.cancellation?.isCancelled == true ? 1 : 0
    }

    public func statsJSON() -> String {
        condition.lock()
        let object: [String: Any] = [
            "epoch": epoch, "closed": closed, "live": tickets.count, "queued": queue.count,
            "counters": [
                "submitted": counters.submitted, "claimed": counters.claimed,
                "completed": counters.completed, "failed": counters.failed,
                "lateSettle": counters.lateSettle, "fenced": counters.fenced,
                "saturated": counters.saturated, "unbound": counters.unbound,
                "expired": counters.expired, "bindRejections": counters.bindRejections,
                "coalesced": counters.coalesced, "eventDropped": counters.eventDropped,
            ],
        ]
        condition.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{\"error\":\"stats\"}" }
        return string
    }

    // MARK: - Locked helpers

    private func retireLocked(_ claim: Int64) {
        if let ticket = tickets[claim], let key = ticket.coalesceKey,
           eventByCoalesceKey[key] == claim {
            eventByCoalesceKey.removeValue(forKey: key)
        }
        tickets.removeValue(forKey: claim)
        retired.insert(claim)
        retiredOrder.append(claim)
        while retiredOrder.count > G04BrowserMailboxLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    /// Move a ticket to the retired ring OUTSIDE the caller's lock hold so
    /// the resume ordering stays: mutate under lock, resume after unlock.
    private func retireAndCount(_ claim: Int64) {
        condition.lock()
        retireLocked(claim)
        condition.broadcast()
        condition.unlock()
    }

    private func expireLocked(_ claim: Int64,
                              into expired: inout [CheckedContinuation<Data, G04BrowserMailboxError>]) {
        guard let ticket = tickets[claim], ticket.state == 0, let continuation = ticket.continuation
        else { return }
        ticket.continuation = nil
        if let key = ticket.coalesceKey { eventByCoalesceKey.removeValue(forKey: key) }
        counters.expired += 1
        retireLocked(claim)
        queue.removeAll { $0 == claim }
        expired.append(continuation)
    }
}


