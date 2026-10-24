// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 SAF source transport mailbox — the trusted Kotlin-host execution
// channel for `G04WorkspaceSourceCoordinator.Transport` (the frozen
// `core/safgateway` OS gateway runs provider reads/writes).
//
// This is the SAME reviewed `LinuxShellMailbox` shape the G03 shell ships:
// Swift owns one bounded ticket table per bound root epoch; the trusted
// Kotlin host claims tickets through the exported C ABI, performs the ACTUAL
// ContentResolver IO (cancellable PFD/stream per the frozen gateway
// contract), and settles each claim exactly once. Model dispatch has no
// route here: no V3 handler key, no command name, no bridge payload — only
// the coordinator's journal-validated ticket reaches the host.
//
// Engine pump contract implemented by the trusted Kotlin host:
//   bind(epoch)                    -> strictly newer POSITIVE root epoch, and
//                                     only while that epoch is the live
//                                     native root (`floe_g02_native_root_epoch`
//                                     equality is checked in the export).
//                                     Older generations are fenced, never
//                                     re-adopted.
//   next(timeoutMillis) -> claim   -> blocks up to the budget for the next
//                                     queued ticket; 0 = none (re-arm).
//   describe(claim, buf, cap)      -> ticket descriptor JSON; -106 =
//                                     bufferTooSmall (exact length returned
//                                     on success).
//   payloadLength / takePayload    -> staged `source.write` bytes (0/none
//                                     for read); host allocates cap >= length.
//   isLive / shouldStop            -> settlement classification + the REAL
//                                     cancellation request: when 1, the host
//                                     MUST run its CancellationSignal and
//                                     still settle the claim exactly once.
//   complete(claim, status, ptr)   -> status 0 = success; for `source.read`
//                                     the value is the RAW provider bytes
//                                     (<= 4 MiB — the coordinator hashes them
//                                     ITSELF; a Kotlin digest string is
//                                     never a byte authority); for
//                                     `source.write` an empty value means
//                                     the serialized write settled (the
//                                     coordinator then RE-READS through a
//                                     fresh ticket for its own verification);
//                                     status 1 = typed failure
//                                     {"code":"<bounded-token>"} from the
//                                     frozen gateway vocabulary.
//   close(epoch) / stats           -> exact-generation teardown + typed
//                                     counters (no paths, no bytes).
//
// Ownership rules enforced HERE, not by trust: a live claim settles ONCE
// (late/duplicate is classified and counted, never resumed twice); a
// stale-generation claim can never settle the current table; cancellation is
// a REQUEST — the ticket stays owned until the host's actual IO settles or
// the reviewed deadline classifies it `hostBudget`; bind/close fence waiters
// with typed errors and keep claimed tickets for honest late-settle
// classification. No timeout detach and no fake completion exist here.
import Foundation
import FloeCore
import FloeTools

public enum G04SourceMailboxLimits {
    public static let maximumLiveTickets = 32
    public static let maximumRetired = 256
    /// Coordinator phase budgets (the host claims, then performs real IO).
    public static let readBudgetMillis = 120_000
    public static let writeBudgetMillis = 120_000
    public static let maximumCodeChars = 64
    public static let maximumDescriptorBytes = 2048
}

/// Typed settlement of one host provider attempt.
public enum G04SourceMailboxError: Error, Sendable, Equatable {
    case hostUnbound
    case hostClosed
    case hostFenced
    case saturated
    case remoteFailed(code: String)
    case oversized
}

public final class G04WorkspaceSourceMailbox: @unchecked Sendable {
    public static let shared = G04WorkspaceSourceMailbox()

    private final class Ticket {
        let claim: Int64
        let operation: String       // "source.read" | "source.write"
        let descriptor: Data        // journal-validated identity JSON
        let staged: Data            // write bytes handed DOWN to the host
        let createdEpoch: UInt64
        let deadline: DispatchTime
        var state = 0               // 0 queued, 1 claimed, 2 settled-removed
        var continuation: CheckedContinuation<Data, G04SourceMailboxError>?
        /// The owning coordinator lease's cancellation — surfaced through
        /// shouldStop so the host runs its CancellationSignal honestly.
        let cancellation: CancellationToken
        init(claim: Int64, operation: String, descriptor: Data, staged: Data,
             epoch: UInt64, deadline: DispatchTime, cancellation: CancellationToken) {
            self.claim = claim; self.operation = operation; self.descriptor = descriptor
            self.staged = staged; self.createdEpoch = epoch; self.deadline = deadline
            self.cancellation = cancellation
        }
    }

    private let condition = NSCondition()
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var counter: Int64 = 0
    private var epoch: UInt64 = 0
    private var closed = true
    private var counters = (submitted: 0, claimed: 0, completed: 0, failed: 0,
                            lateSettle: 0, fenced: 0, saturated: 0, unbound: 0,
                            expired: 0, bindRejections: 0)

    private init() {}

    public var boundEpoch: UInt64 { condition.lock(); defer { condition.unlock() }; return epoch }
    public var isBound: Bool { condition.lock(); defer { condition.unlock() }; return !closed && epoch != 0 }

    /// Observe readiness and its exact generation in ONE critical section.
    /// Independent isBound/boundEpoch reads could straddle close/rebind.
    func isBound(to expectedEpoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0 && epoch == expectedEpoch
    }

    /// Strictly-newer positive epoch only; fences ALL waiters with the typed
    /// `.hostFenced` while claimed tickets remain for honest late-settle
    /// classification. Returns false (and changes nothing) otherwise.
    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch != 0, newEpoch > epoch else {
            counters.bindRejections += 1
            condition.unlock()
            return false
        }
        epoch = newEpoch
        closed = false
        var resumes: [CheckedContinuation<Data, G04SourceMailboxError>] = []
        for token in queue {
            guard let ticket = tickets[token], ticket.state == 0, let continuation = ticket.continuation
            else { continue }
            ticket.continuation = nil
            resumes.append(continuation)
            retireLocked(token)
        }
        queue.removeAll()
        for ticket in tickets.values where ticket.state == 1 {
            if let continuation = ticket.continuation {
                ticket.continuation = nil
                resumes.append(continuation)
            }
        }
        counters.fenced += resumes.count
        condition.broadcast()
        condition.unlock()
        for continuation in resumes { continuation.resume(throwing: .hostFenced) }
        return true
    }

    /// Exact-generation teardown: new submissions refuse, waiters settle
    /// typed, claimed tickets remain for honest late classification.
    public func close(epoch closing: UInt64) {
        condition.lock()
        guard closing == epoch, epoch != 0 else { condition.unlock(); return }
        closed = true
        var resumes: [CheckedContinuation<Data, G04SourceMailboxError>] = []
        for token in queue {
            if let ticket = tickets[token], let continuation = ticket.continuation {
                ticket.continuation = nil
                resumes.append(continuation)
            }
            retireLocked(token)
        }
        queue.removeAll()
        for ticket in tickets.values where ticket.state == 1 {
            if let continuation = ticket.continuation {
                ticket.continuation = nil
                resumes.append(continuation)
            }
        }
        condition.broadcast()
        condition.unlock()
        for continuation in resumes { continuation.resume(throwing: .hostClosed) }
    }

    /// Coordinator submission. `descriptor` carries the journal-validated
    /// identity (never a model/bridge payload); `staged` is the replacement
    /// bytes for `source.write` (empty for read).
    public func submit(operation: String, descriptor: [String: String],
                       staged: Data, cancellation: CancellationToken) async throws -> Data {
        guard operation == "source.read" || operation == "source.write" else {
            throw G04SourceMailboxError.hostUnbound
        }
        guard staged.count <= G04WorkspaceSourceCoordinator.maximumSourceBytes else {
            throw G04SourceMailboxError.oversized
        }
        guard !cancellation.isCancelled else { throw G04SourceMailboxError.hostFenced }
        let payload = (try? JSONSerialization.data(withJSONObject: descriptor,
                                                    options: [.sortedKeys])) ?? Data("{}".utf8)
        return try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            guard !closed, epoch != 0 else {
                counters.unbound += 1
                condition.unlock()
                continuation.resume(throwing: G04SourceMailboxError.hostUnbound)
                return
            }
            guard tickets.count < G04SourceMailboxLimits.maximumLiveTickets else {
                counters.saturated += 1
                condition.unlock()
                continuation.resume(throwing: G04SourceMailboxError.saturated)
                return
            }
            counter &+= 1
            let ticket = Ticket(
                claim: counter, operation: operation, descriptor: payload, staged: staged,
                epoch: epoch,
                deadline: DispatchTime.now() + .milliseconds(
                    operation == "source.read" ? G04SourceMailboxLimits.readBudgetMillis
                        : G04SourceMailboxLimits.writeBudgetMillis),
                cancellation: cancellation)
            ticket.continuation = continuation
            tickets[counter] = ticket
            queue.append(counter)
            counters.submitted += 1
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Host claims the next queued ticket within the budget. 0 = none.
    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        var expired: [CheckedContinuation<Data, G04SourceMailboxError>] = []
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

    /// Settle one claimed ticket with the ACTUAL host IO outcome, ONCE.
    /// `value` is raw provider bytes for a successful `source.read`; an empty
    /// Data for `source.write` success; a JSON `{"code":"<token>"}` failure.
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
        if ticket.operation == "source.read", status == 0,
           value.count > G04WorkspaceSourceCoordinator.maximumSourceBytes {
            condition.unlock()
            return -107
        }
        let outcome: Result<Data, G04SourceMailboxError>
        if status == 0 {
            outcome = .success(value)
            counters.completed += 1
        } else {
            let object = (try? JSONSerialization.jsonObject(with: value)) as? [String: Any]
            let raw = object?["code"] as? String
            let code = (raw.map { !$0.isEmpty && $0.count <= G04SourceMailboxLimits.maximumCodeChars } ?? false)
                ? raw! : "providerFailed"
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
        object["operation"] = ticket.operation
        object["epoch"] = String(ticket.createdEpoch)
        condition.unlock()
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= G04SourceMailboxLimits.maximumDescriptorBytes else { return -108 }
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
        return ticket.state == 0 || (ticket.state == 1 && ticket.continuation != nil) ? 1 : 0
    }

    /// 1 = the owning lease cancelled or the generation fenced: the host MUST
    /// stop the actual transfer (CancellationSignal) and still settle exactly
    /// once. Never a Swift-side detach-on-timeout.
    public func shouldStop(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else { return 1 }
        return ticket.cancellation.isCancelled ? 1 : 0
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
            ],
        ]
        condition.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{\"error\":\"stats\"}" }
        return string
    }

    // MARK: - Locked helpers

    private func retireLocked(_ claim: Int64) {
        tickets.removeValue(forKey: claim)
        retired.insert(claim)
        retiredOrder.append(claim)
        while retiredOrder.count > G04SourceMailboxLimits.maximumRetired {
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
                              into expired: inout [CheckedContinuation<Data, G04SourceMailboxError>]) {
        guard let ticket = tickets[claim], ticket.state == 0, let continuation = ticket.continuation
        else { return }
        ticket.continuation = nil
        counters.expired += 1
        retireLocked(claim)
        queue.removeAll { $0 == claim }
        expired.append(continuation)
    }
}

// MARK: - Coordinator transport over the mailbox

/// The production transport: typed tickets <-> host-executed frozen-gateway
/// IO. The coordinator RE-HASHES every settled read itself; a Kotlin digest
/// string is never a byte authority.
public struct G04WorkspaceSourceMailboxTransport: G04WorkspaceSourceCoordinator.Transport {
    public init() {}

    /// Dispatch readiness is the PUMP's, not the object's: tickets execute
    /// only while the trusted host pump is bound to THIS exact live root
    /// epoch (`floe_g04_source_bind`). A closed or stale-generation mailbox
    /// cannot dispatch provider IO, so provider-touching entries must answer
    /// the typed transportNotBound before queueing anything.
    public func isDispatchReady(rootEpoch: UInt64) async -> Bool {
        let mailbox = G04WorkspaceSourceMailbox.shared
        return mailbox.isBound(to: rootEpoch)
    }

    public func readSource(taskID: UUID, workspaceID: UUID, logicalPath: String,
                           sourceReference: String, sourceDocumentID: String?,
                           maxBytes: Int, cancellation: CancellationToken) async throws -> Data {
        var descriptor: [String: String] = [
            "taskID": taskID.uuidString, "workspaceID": workspaceID.uuidString,
            "logicalPath": logicalPath, "sourceReference": sourceReference,
            "maxBytes": String(maxBytes),
        ]
        if let sourceDocumentID { descriptor["sourceDocumentID"] = sourceDocumentID }
        do {
            return try await G04WorkspaceSourceMailbox.shared.submit(
                operation: "source.read", descriptor: descriptor,
                staged: Data(), cancellation: cancellation)
        } catch let error as G04SourceMailboxError {
            throw Self.relay(error)
        }
    }

    public func writeSource(taskID: UUID, workspaceID: UUID, logicalPath: String,
                            sourceReference: String, sourceDocumentID: String?,
                            bytes: Data, cancellation: CancellationToken) async throws {
        var descriptor: [String: String] = [
            "taskID": taskID.uuidString, "workspaceID": workspaceID.uuidString,
            "logicalPath": logicalPath, "sourceReference": sourceReference,
            "byteCount": String(bytes.count), "sha256": FloeDigest.sha256Hex(bytes),
        ]
        if let sourceDocumentID { descriptor["sourceDocumentID"] = sourceDocumentID }
        do {
            _ = try await G04WorkspaceSourceMailbox.shared.submit(
                operation: "source.write", descriptor: descriptor,
                staged: bytes, cancellation: cancellation)
        } catch let error as G04SourceMailboxError {
            throw Self.relay(error)
        }
    }

    static func relay(_ error: G04SourceMailboxError) -> G04SourceCoordinatorError {
        switch error {
        case .hostUnbound, .hostClosed, .hostFenced: return .transportNotBound
        case .saturated: return .transitionRefused("mailboxSaturated")
        case .oversized: return .tooLarge(limit: G04WorkspaceSourceCoordinator.maximumSourceBytes)
        case .remoteFailed(let code):
            return code == "hostBudget" || code == "mailboxSaturated"
                ? .transitionRefused(code) : .providerFailed(code: code)
        }
    }
}

// MARK: - Trusted host C ABI (Kotlin SAF pump only; NOT a V3 command)

/// Bind the host pump to a strictly-newer LIVE root epoch. 0 = accepted.
@_cdecl("floe_g04_source_bind")
public func floeG04SourceBind(_ epoch: UInt64) -> Int32 {
    guard G02NativeRootEpoch.readback() == epoch else { return -102 }
    return G04WorkspaceSourceMailbox.shared.bind(epoch: epoch) ? 0 : -102
}

/// Block up to `timeoutMillis` for the next provider ticket; 0 = none.
@_cdecl("floe_g04_source_next")
public func floeG04SourceNext(_ timeoutMillis: Int32) -> Int64 {
    G04WorkspaceSourceMailbox.shared.nextClaim(timeoutMillis: timeoutMillis)
}

/// Ticket descriptor JSON into `buffer` (NUL-terminated). -106 = too small.
@_cdecl("floe_g04_source_describe")
public func floeG04SourceDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                  _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

/// Staged write-byte count for `source.write` (0 for read; -101 stale claim).
@_cdecl("floe_g04_source_payload_length")
public func floeG04SourcePayloadLength(_ claim: Int64) -> Int32 {
    G04WorkspaceSourceMailbox.shared.payloadLength(claim: claim)
}

/// Copy the FULL staged bytes; the host allocates capacity >= payloadLength.
@_cdecl("floe_g04_source_take_payload")
public func floeG04SourceTakePayload(_ claim: Int64, _ buffer: UnsafeMutablePointer<UInt8>?,
                                     _ capacity: Int32) -> Int32 {
    G04WorkspaceSourceMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

/// 1 = ticket still live for the CURRENT bound generation.
@_cdecl("floe_g04_source_is_live")
public func floeG04SourceIsLive(_ claim: Int64) -> Int32 {
    G04WorkspaceSourceMailbox.shared.isLive(claim: claim)
}

/// 1 = the owning coordinator lease cancelled / generation fenced: run the
/// gateway CancellationSignal, then still settle exactly once.
@_cdecl("floe_g04_source_should_stop")
public func floeG04SourceShouldStop(_ claim: Int64) -> Int32 {
    G04WorkspaceSourceMailbox.shared.shouldStop(claim: claim)
}

/// Settle one claimed ticket ONCE. status 0 = success (value = raw provider
/// bytes for `source.read`; empty length for `source.write`); status 1 =
/// typed failure {"code": frozen gateway token: revoked|grantMissing|
/// rePickRequired|readOnly|unsupported|cancelled|conflict|notFound|
/// ambiguousIdentity|sizeLimit|providerOffline|io|failed|hostBudget|
/// mailboxSaturated}.
@_cdecl("floe_g04_source_complete")
public func floeG04SourceComplete(_ claim: Int64, _ status: Int32,
                                  _ value: UnsafePointer<UInt8>?, _ valueLen: Int32) -> Int32 {
    guard status == 0 || status == 1, valueLen >= 0,
          valueLen == 0 || value != nil else { return -105 }
    let data = (valueLen == 0 || value == nil) ? Data() : Data(bytes: value!, count: Int(valueLen))
    return G04WorkspaceSourceMailbox.shared.complete(claim: claim, status: status, value: data)
}

/// Exact-epoch teardown (generation retirement).
@_cdecl("floe_g04_source_close")
public func floeG04SourceClose(_ epoch: UInt64) -> Int32 {
    G04WorkspaceSourceMailbox.shared.close(epoch: epoch)
    return 0
}

/// Typed counters only (no paths, no bytes, no identities).
@_cdecl("floe_g04_source_stats")
public func floeG04SourceStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    let text = G04WorkspaceSourceMailbox.shared.statsJSON()
    guard let buffer, capacity > 0 else { return -105 }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -106 }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
