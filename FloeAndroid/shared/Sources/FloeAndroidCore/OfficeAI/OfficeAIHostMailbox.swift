// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — the epoch-fenced trusted-host
// ticket mailbox for the Office AI lane. The reviewed `G04WorkspaceSourceMailbox`
// shape, kept deliberately: Swift owns ONE bounded ticket table per bound root
// epoch; the trusted Kotlin host claims tickets through the exported C ABI,
// performs the ACTUAL App-host work (owner-safe open, precision commands,
// save/export, package inspection, journal push), and settles each claim
// exactly once. Model dispatch has no route here: no V3 handler key, no tool
// name, no bridge payload — only the Core bridge behind its own context/CAS
// fences submits tickets.
//
// Ownership rules enforced HERE, not by trust: a live claim settles ONCE
// (late/duplicate is classified and counted, never resumed twice); a
// stale-generation claim can never settle the current table; cancellation is
// a REQUEST — the ticket stays owned until the host's actual work settles or
// the bounded budget classifies it `hostBudget`; bind/close fence waiters with
// typed errors and keep claimed tickets for honest late-settle classification.
// No timeout detach and no fake completion exist here.

import Foundation
import FloeCore
import FloeTools

public final class OfficeAIHostMailbox: @unchecked Sendable {
    public static let shared = OfficeAIHostMailbox()

    private final class Ticket {
        let claim: Int64
        let operation: String
        let descriptor: Data
        let staged: Data
        let createdEpoch: UInt64
        let deadline: DispatchTime
        var state = 0 // 0 queued, 1 claimed, 2 settled-removed
        var continuation: CheckedContinuation<Data, OfficeAIHostTransportError>?
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

    init() {}

    public var boundEpoch: UInt64 { condition.lock(); defer { condition.unlock() }; return epoch }
    public var isBound: Bool { condition.lock(); defer { condition.unlock() }; return !closed && epoch != 0 }

    /// Readiness and its exact generation in ONE critical section.
    public func isBound(to expectedEpoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0 && epoch == expectedEpoch
    }

    /// Strictly-newer positive epoch only; fences ALL waiters typed while
    /// claimed tickets remain for honest late-settle classification.
    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch != 0, newEpoch > epoch else {
            counters.bindRejections += 1
            condition.unlock()
            return false
        }
        epoch = newEpoch
        closed = false
        var resumes: [CheckedContinuation<Data, OfficeAIHostTransportError>] = []
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
        var resumes: [CheckedContinuation<Data, OfficeAIHostTransportError>] = []
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

    /// Bridge submission (validated by `OfficeAIHostTransport` conformance).
    func submitTicket(operation: OfficeAIHostOperation, descriptor: Data, staged: Data,
                      cancellation: CancellationToken) async throws -> Data {
        guard staged.count <= OfficeAIHostLimits.maximumStagedBytes else {
            throw OfficeAIHostTransportError.oversized
        }
        guard !cancellation.isCancelled else { throw OfficeAIHostTransportError.hostFenced }
        return try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            guard !closed, epoch != 0 else {
                counters.unbound += 1
                condition.unlock()
                continuation.resume(throwing: OfficeAIHostTransportError.hostUnbound)
                return
            }
            guard tickets.count < OfficeAIHostLimits.maximumLiveTickets else {
                counters.saturated += 1
                condition.unlock()
                continuation.resume(throwing: OfficeAIHostTransportError.saturated)
                return
            }
            counter &+= 1
            let ticket = Ticket(
                claim: counter, operation: operation.rawValue, descriptor: descriptor,
                staged: staged, epoch: epoch,
                deadline: DispatchTime.now() + .milliseconds(
                    OfficeAIHostLimits.budgetMillis(for: operation)),
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
        var expired: [CheckedContinuation<Data, OfficeAIHostTransportError>] = []
        defer {
            for continuation in expired { continuation.resume(throwing: .hostBudget) }
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
    /// status 0 = success (raw reply JSON); status 1 = typed failure
    /// `{"code":"<bounded-token>","detail":"<bounded>"}`.
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
        if status == 0, value.count > OfficeAIHostLimits.maximumReplyBytes {
            condition.unlock()
            return -107
        }
        if status == 1, value.count > OfficeAIHostLimits.maximumFailureReplyBytes {
            condition.unlock()
            return -107
        }
        let outcome: Result<Data, OfficeAIHostTransportError>
        if status == 0 {
            outcome = .success(value)
            counters.completed += 1
        } else {
            let failure = OfficeAIHostDescriptor.failure(from: value)
            outcome = .failure(.remoteFailed(code: failure.code, detail: failure.detail))
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
        object[OfficeAIHostField.operation] = ticket.operation
        object[OfficeAIHostField.epoch] = String(ticket.createdEpoch)
        condition.unlock()
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= OfficeAIHostLimits.maximumDescriptorBytes else { return -108 }
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

    /// 1 = the owning operation cancelled or the generation fenced: the host
    /// MUST stop its real work and still settle exactly once.
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
        while retiredOrder.count > OfficeAIHostLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    private func retireAndCount(_ claim: Int64) {
        condition.lock()
        retireLocked(claim)
        condition.broadcast()
        condition.unlock()
    }

    private func expireLocked(_ claim: Int64,
                              into expired: inout [CheckedContinuation<Data, OfficeAIHostTransportError>]) {
        guard let ticket = tickets[claim], ticket.state == 0, let continuation = ticket.continuation
        else { return }
        ticket.continuation = nil
        counters.expired += 1
        retireLocked(claim)
        queue.removeAll { $0 == claim }
        expired.append(continuation)
    }
}

// MARK: - Transport conformance (production path used by the bridge)

extension OfficeAIHostMailbox: OfficeAIHostTransport {
    public func submit(operation: OfficeAIHostOperation, descriptor: [String: String],
                       staged: Data, cancellation: CancellationToken) async throws -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: descriptor,
                                                    options: [.sortedKeys])) ?? Data("{}".utf8)
        return try await submitTicket(operation: operation, descriptor: payload,
                                      staged: staged, cancellation: cancellation)
    }
}

// MARK: - Trusted host C ABI (Kotlin Office AI pump only; NOT a V3 command)

/// Bind the host pump to a strictly-newer LIVE root epoch. 0 = accepted.
@_cdecl("floe_office_ai_bind")
public func floeOfficeAIBind(_ epoch: UInt64) -> Int32 {
    guard G02NativeRootEpoch.readback() == epoch else { return -102 }
    guard OfficeAIHostMailbox.shared.bind(epoch: epoch) else { return -102 }
    // Successful live-generation bind is the install point for the
    // two-sided tool registration (isAvailable rides the bound state).
    OfficeAIComposition.shared.installToolIfNeeded()
    return 0
}

/// Block up to `timeoutMillis` for the next ticket; 0 = none.
@_cdecl("floe_office_ai_next")
public func floeOfficeAINext(_ timeoutMillis: Int32) -> Int64 {
    OfficeAIHostMailbox.shared.nextClaim(timeoutMillis: timeoutMillis)
}

/// Ticket descriptor JSON into `buffer` (NUL-terminated). -106 = too small.
@_cdecl("floe_office_ai_describe")
public func floeOfficeAIDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                 _ capacity: Int32) -> Int32 {
    OfficeAIHostMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

/// Staged parameter-byte count (0 when the ticket carries none; -101 stale).
@_cdecl("floe_office_ai_payload_length")
public func floeOfficeAIPayloadLength(_ claim: Int64) -> Int32 {
    OfficeAIHostMailbox.shared.payloadLength(claim: claim)
}

/// Copy the FULL staged bytes; the host allocates capacity >= payload_length.
@_cdecl("floe_office_ai_take_payload")
public func floeOfficeAITakePayload(_ claim: Int64, _ buffer: UnsafeMutablePointer<UInt8>?,
                                    _ capacity: Int32) -> Int32 {
    OfficeAIHostMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

/// 1 = ticket still live for the CURRENT bound generation.
@_cdecl("floe_office_ai_is_live")
public func floeOfficeAIIsLive(_ claim: Int64) -> Int32 {
    OfficeAIHostMailbox.shared.isLive(claim: claim)
}

/// 1 = the owning operation cancelled / generation fenced: stop the real
/// work, then still settle exactly once.
@_cdecl("floe_office_ai_should_stop")
public func floeOfficeAIShouldStop(_ claim: Int64) -> Int32 {
    OfficeAIHostMailbox.shared.shouldStop(claim: claim)
}

/// Settle one claimed ticket ONCE. status 0 = success (raw reply JSON,
/// <= 1 MiB); status 1 = typed failure {"code":token,"detail":bounded} <= 256 B.
@_cdecl("floe_office_ai_complete")
public func floeOfficeAIComplete(_ claim: Int64, _ status: Int32,
                                 _ value: UnsafePointer<UInt8>?, _ valueLen: Int32) -> Int32 {
    guard status == 0 || status == 1, valueLen >= 0,
          valueLen == 0 || value != nil else { return -105 }
    let data = (valueLen == 0 || value == nil) ? Data() : Data(bytes: value!, count: Int(valueLen))
    return OfficeAIHostMailbox.shared.complete(claim: claim, status: status, value: data)
}

/// Exact-epoch teardown (generation retirement).
@_cdecl("floe_office_ai_close")
public func floeOfficeAIClose(_ epoch: UInt64) -> Int32 {
    OfficeAIHostMailbox.shared.close(epoch: epoch)
    OfficeAIComposition.shared.retireContextsForClosingGeneration()
    return 0
}

/// Typed counters only (no paths, bytes, identities or content).
@_cdecl("floe_office_ai_stats")
public func floeOfficeAIStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    let text = OfficeAIHostMailbox.shared.statsJSON()
    guard let buffer, capacity > 0 else { return -105 }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -106 }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
