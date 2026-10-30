// SPDX-License-Identifier: MPL-2.0
//
// G07.1 network diagnostics — epoch-fenced trusted-host mailbox.
//
// The SAME reviewed mailbox shape as `OfficeAIHostMailbox` /
// `G04WorkspaceSourceMailbox`: Swift owns ONE bounded ticket table per bound
// root epoch; the trusted Kotlin host claims tickets through the exported C
// ABI, calls the App-owned `PhoneNetworkService.execute(requestJson)` on IO,
// and settles each claim exactly once. Model dispatch has no route here: no
// V3 handler key, no command name, no bridge payload — only the validated
// `network.*` tool request reaches the phone.
//
// Ownership rules enforced HERE, not by trust:
//   * a live claim settles ONCE (late/duplicate is classified, never resumed
//     twice);
//   * a stale-generation claim can never settle the current table;
//   * cancellation is a REQUEST (`shouldStop`); the host must stop its real
//     work and still settle; an unclaimed ticket expires as `hostBudget`;
//   * bind/close fence waiters with typed errors and keep claimed tickets for
//     honest late-settle classification.
//
// Status space (network-diagnostics-owned -8xx; additive and disjoint from
// gateway -1xx, runtime-owner -2xx, attachment -3xx, skills-folder -4xx,
// source host -5xx, network workspace/browser -6xx, run-output/git-trust
// -7xx; audit of all existing Swift/Kotlin C ABI bands at authoring time):
//   0 ok; -101 stale claim; -102 generation fenced; -105 shape;
//   -106 bufferTooSmall; -107 oversized; -108 descriptor invalid;
//   -110 claim not claimed;
//   -801 notInstalled; -802 serviceUnavailable; -803 requestRefused;
//   -804 observationInvalid; -805 hopTimeout; -899 internal.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidNetwork

public enum G07NetworkDiagnosticStatus {
    public static let ok: Int32 = 0
    public static let staleClaim: Int32 = -101
    public static let generationFenced: Int32 = -102
    public static let shape: Int32 = -105
    public static let bufferTooSmall: Int32 = -106
    public static let oversized: Int32 = -107
    public static let descriptorInvalid: Int32 = -108
    public static let notClaimed: Int32 = -110
    public static let notInstalled: Int32 = -801
    public static let serviceUnavailable: Int32 = -802
    public static let requestRefused: Int32 = -803
    public static let observationInvalid: Int32 = -804
    public static let hopTimeout: Int32 = -805
    public static let internalFailure: Int32 = -899
}

public enum G07NetworkHostLimits {
    public static let maximumDescriptorBytes = 2_048
    public static let maximumRequestBytes = NetworkToolLimits.maximumRequestBytes
    public static let maximumObservationBytes = NetworkToolLimits.maximumObservationBytes
    /// Failure replies are `{"code":token,"detail":bounded}` only.
    public static let maximumFailureReplyBytes = 512
    public static let maximumLiveTickets = 16
    public static let maximumRetired = 256
    public static let maximumCodeChars = 64
    public static let maximumDetailChars = 200
    /// The service's own per-operation bounds are <= 30 s; the mailbox adds a
    /// bounded scheduling/settlement margin and never detaches a claimed IO.
    public static let ticketBudgetMillis = 45_000
}

/// Exact task/run/generation ownership recorded with a ticket. Kotlin carries
/// the UUIDs as opaque identity only (no permission decision, no logging);
/// the Swift runtime issued them for this call and rechecks the generation
/// before and after the round trip.
public struct G07NetworkOwner: Sendable, Equatable {
    public let taskID: UUID
    public let runID: UUID
    public let epoch: UInt64

    public init(taskID: UUID, runID: UUID, epoch: UInt64) {
        self.taskID = taskID
        self.runID = runID
        self.epoch = epoch
    }
}

public enum G07NetworkHostTransportError: Error, Sendable, Equatable {
    case hostUnbound
    case hostClosed
    case hostFenced
    case hostBudget
    case saturated
    case oversized
    case cancelled
    case remoteFailed(code: String, detail: String?)
}

/// Narrow submission seam so the tool executor can be exercised with a
/// scripted transport. Production conformance is the mailbox below.
public protocol G07NetworkHostSubmitting: Sendable {
    var boundEpoch: UInt64 { get }
    var isBound: Bool { get }
    func submit(request: NetworkToolRequest, owner: G07NetworkOwner,
                cancellation: CancellationToken) async throws -> Data
}

public final class G07NetworkHostMailbox: @unchecked Sendable {
    public static let shared = G07NetworkHostMailbox()

    private final class Ticket {
        let claim: Int64
        let method: NetworkToolMethod
        let operationID: UUID
        let descriptor: Data
        let staged: Data
        let createdEpoch: UInt64
        let deadline: DispatchTime
        let cancellation: CancellationToken
        var state = 0 // 0 queued, 1 claimed, 2 settled-removed
        var continuation: CheckedContinuation<Data, G07NetworkHostTransportError>?

        init(claim: Int64, method: NetworkToolMethod, operationID: UUID,
             descriptor: Data, staged: Data, epoch: UInt64,
             deadline: DispatchTime, cancellation: CancellationToken) {
            self.claim = claim
            self.method = method
            self.operationID = operationID
            self.descriptor = descriptor
            self.staged = staged
            self.createdEpoch = epoch
            self.deadline = deadline
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

    public init() {}

    public var boundEpoch: UInt64 {
        condition.lock(); defer { condition.unlock() }; return epoch
    }

    public var isBound: Bool {
        condition.lock(); defer { condition.unlock() }; return !closed && epoch != 0
    }

    /// Readiness and its exact generation in ONE critical section.
    public func isBound(to expectedEpoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0 && epoch == expectedEpoch
    }

    /// Strictly-newer positive epoch only. Queued and claimed waiters are
    /// fenced typed; claimed tickets remain classified for late settlement.
    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch != 0, newEpoch > epoch else {
            counters.bindRejections += 1
            condition.unlock()
            return false
        }
        epoch = newEpoch
        closed = false
        var resumes: [CheckedContinuation<Data, G07NetworkHostTransportError>] = []
        for token in queue {
            guard let ticket = tickets[token], ticket.state == 0,
                  let continuation = ticket.continuation else { continue }
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
        var resumes: [CheckedContinuation<Data, G07NetworkHostTransportError>] = []
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

    /// Bridge submission (validated by the `G07NetworkHostSubmitting`
    /// conformance below).
    func submitTicket(request: NetworkToolRequest, owner: G07NetworkOwner,
                      cancellation: CancellationToken) async throws -> Data {
        let staged = request.requestJSON
        guard staged.count <= G07NetworkHostLimits.maximumRequestBytes else {
            throw G07NetworkHostTransportError.oversized
        }
        guard !cancellation.isCancelled else { throw G07NetworkHostTransportError.cancelled }
        return try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            guard !closed, epoch != 0 else {
                counters.unbound += 1
                condition.unlock()
                continuation.resume(throwing: G07NetworkHostTransportError.hostUnbound)
                return
            }
            guard tickets.count < G07NetworkHostLimits.maximumLiveTickets else {
                counters.saturated += 1
                condition.unlock()
                continuation.resume(throwing: G07NetworkHostTransportError.saturated)
                return
            }
            guard owner.epoch == epoch else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: G07NetworkHostTransportError.hostFenced)
                return
            }
            let descriptor = Self.descriptorJSON(request: request, owner: owner)
            guard !descriptor.isEmpty,
                  descriptor.count <= G07NetworkHostLimits.maximumDescriptorBytes else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: G07NetworkHostTransportError.hostFenced)
                return
            }
            counter &+= 1
            let ticket = Ticket(
                claim: counter, method: request.method,
                operationID: request.operationID, descriptor: descriptor,
                staged: staged, epoch: epoch,
                deadline: DispatchTime.now() + .milliseconds(G07NetworkHostLimits.ticketBudgetMillis),
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
        var expired: [CheckedContinuation<Data, G07NetworkHostTransportError>] = []
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
                if ticket.deadline < DispatchTime.now() {
                    expireLocked(head, into: &expired)
                    continue
                }
                ticket.state = 1
                counters.claimed += 1
                claim = head
                break
            }
            if condition.wait(until: deadline) { continue }
            for (pending, ticket) in tickets
                where ticket.state == 0 && ticket.deadline < DispatchTime.now() {
                expireLocked(pending, into: &expired)
            }
            break
        }
        condition.unlock()
        return claim
    }

    /// Ticket descriptor JSON into `buffer` (NUL-terminated). -106 = too small.
    public func describe(claim: Int64, buffer: UnsafeMutablePointer<CChar>?,
                         capacity: Int32) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            condition.unlock()
            return G07NetworkDiagnosticStatus.staleClaim
        }
        let descriptor = ticket.descriptor
        condition.unlock()
        guard descriptor.count <= G07NetworkHostLimits.maximumDescriptorBytes else {
            return G07NetworkDiagnosticStatus.descriptorInvalid
        }
        guard capacity >= 0, let buffer, descriptor.count + 1 <= Int(capacity) else {
            return G07NetworkDiagnosticStatus.bufferTooSmall
        }
        descriptor.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, descriptor.count)
        }
        buffer[descriptor.count] = 0
        return Int32(descriptor.count)
    }

    public func payloadLength(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            return G07NetworkDiagnosticStatus.staleClaim
        }
        guard ticket.staged.count <= G07NetworkHostLimits.maximumRequestBytes else {
            return G07NetworkDiagnosticStatus.oversized
        }
        return Int32(ticket.staged.count)
    }

    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?,
                            capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            return G07NetworkDiagnosticStatus.staleClaim
        }
        guard capacity >= 0, let buffer, capacity >= ticket.staged.count else {
            return G07NetworkDiagnosticStatus.bufferTooSmall
        }
        guard !ticket.staged.isEmpty else { return 0 }
        ticket.staged.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, ticket.staged.count)
        }
        return Int32(ticket.staged.count)
    }

    public func isLive(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.createdEpoch == epoch, !closed else {
            return 0
        }
        return ticket.state == 0 || (ticket.state == 1 && ticket.continuation != nil) ? 1 : 0
    }

    /// 1 = the owning tool call cancelled or the generation fenced: the host
    /// MUST stop its real work and still settle exactly once.
    public func shouldStop(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else { return 1 }
        return ticket.cancellation.isCancelled ? 1 : 0
    }

    /// Settle one claimed ticket with the ACTUAL host outcome, ONCE.
    /// status 0 = success (raw observation JSON <= 256 KiB); status 1 = typed
    /// failure `{"code":"<token>","detail":"<bounded>"}` <= 512 B.
    @discardableResult
    public func complete(claim: Int64, status: Int32, value: Data) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim] else {
            if retired.contains(claim) { counters.lateSettle += 1 }
            condition.unlock()
            return G07NetworkDiagnosticStatus.staleClaim
        }
        guard ticket.state == 1 else {
            condition.unlock()
            return G07NetworkDiagnosticStatus.notClaimed
        }
        guard ticket.createdEpoch == epoch, !closed else {
            counters.lateSettle += 1
            condition.unlock()
            return G07NetworkDiagnosticStatus.generationFenced
        }
        guard status == 0 || status == 1 else {
            condition.unlock()
            return G07NetworkDiagnosticStatus.shape
        }
        if status == 0, value.count > G07NetworkHostLimits.maximumObservationBytes {
            condition.unlock()
            return G07NetworkDiagnosticStatus.oversized
        }
        if status == 1, value.count > G07NetworkHostLimits.maximumFailureReplyBytes {
            condition.unlock()
            return G07NetworkDiagnosticStatus.oversized
        }
        let outcome: Result<Data, G07NetworkHostTransportError>
        if status == 0 {
            outcome = .success(value)
            counters.completed += 1
        } else {
            let failure = Self.failure(from: value)
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

    public func statsJSON() -> String {
        condition.lock()
        let object: [String: Any] = [
            "epoch": epoch,
            "closed": closed,
            "live": tickets.count,
            "queued": queue.count,
            "counters": [
                "submitted": counters.submitted,
                "claimed": counters.claimed,
                "completed": counters.completed,
                "failed": counters.failed,
                "lateSettle": counters.lateSettle,
                "fenced": counters.fenced,
                "saturated": counters.saturated,
                "unbound": counters.unbound,
                "expired": counters.expired,
                "bindRejections": counters.bindRejections,
            ],
        ]
        condition.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"stats\"}"
        }
        return string
    }

    // MARK: - Locked helpers

    private func retireLocked(_ claim: Int64) {
        tickets.removeValue(forKey: claim)
        retired.insert(claim)
        retiredOrder.append(claim)
        while retiredOrder.count > G07NetworkHostLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    private func retireAndCount(_ claim: Int64) {
        condition.lock()
        retireLocked(claim)
        condition.broadcast()
        condition.unlock()
    }

    private func expireLocked(
        _ claim: Int64,
        into expired: inout [CheckedContinuation<Data, G07NetworkHostTransportError>]
    ) {
        guard let ticket = tickets[claim], ticket.state == 0,
              let continuation = ticket.continuation else { return }
        ticket.continuation = nil
        counters.expired += 1
        retireLocked(claim)
        queue.removeAll { $0 == claim }
        expired.append(continuation)
    }

    private struct FailureBody: Decodable {
        let code: String
        let detail: String?
    }

    private static func failure(from data: Data) -> (code: String, detail: String?) {
        guard !data.isEmpty,
              let body = try? JSONDecoder().decode(FailureBody.self, from: data),
              isValidFailureCode(body.code) else {
            return ("internal", nil)
        }
        let detail = body.detail.map { value -> String in
            let cleaned = String(value.filter { character in
                character.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
            })
            return String(cleaned.prefix(G07NetworkHostLimits.maximumDetailChars))
        }
        return (body.code, detail)
    }

    private static func isValidFailureCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= G07NetworkHostLimits.maximumCodeChars,
              let first = code.first, first.isLetter else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-")
        }
    }

    private static func descriptorJSON(request: NetworkToolRequest,
                                       owner: G07NetworkOwner) -> Data {
        let object: [String: Any] = [
            "operation": "network.execute",
            "epoch": String(owner.epoch),
            "method": request.method.rawValue,
            "operationID": request.operationID.uuidString,
            "taskID": owner.taskID.uuidString,
            "runID": owner.runID.uuidString,
            "payloadBytes": request.requestJSON.count,
            "budgetMs": G07NetworkHostLimits.ticketBudgetMillis,
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            return Data()
        }
        return data
    }
}

// MARK: - Submission conformance (production path)

extension G07NetworkHostMailbox: G07NetworkHostSubmitting {
    public func submit(request: NetworkToolRequest, owner: G07NetworkOwner,
                       cancellation: CancellationToken) async throws -> Data {
        try await submitTicket(request: request, owner: owner,
                               cancellation: cancellation)
    }
}

// MARK: - Trusted-host C ABI (Kotlin network pump only; NOT a V3 command)

/// Bind the host pump to a strictly-newer LIVE root epoch. 0 = accepted.
@_cdecl("floe_network_diag_bind")
public func floeNetworkDiagBind(_ epoch: UInt64) -> Int32 {
    guard G02NativeRootEpoch.readback() == epoch else {
        return G07NetworkDiagnosticStatus.generationFenced
    }
    guard G07NetworkHostMailbox.shared.bind(epoch: epoch) else {
        return G07NetworkDiagnosticStatus.generationFenced
    }
    G07NetworkComposition.shared.installToolsIfNeeded()
    return G07NetworkDiagnosticStatus.ok
}

/// Block up to `timeoutMillis` for the next ticket; 0 = none.
@_cdecl("floe_network_diag_next")
public func floeNetworkDiagNext(_ timeoutMillis: Int32) -> Int64 {
    G07NetworkHostMailbox.shared.nextClaim(
        timeoutMillis: min(1_000, max(0, timeoutMillis)))
}

/// Ticket descriptor JSON into `buffer` (NUL-terminated). -106 = too small.
@_cdecl("floe_network_diag_describe")
public func floeNetworkDiagDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                    _ capacity: Int32) -> Int32 {
    G07NetworkHostMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

/// Staged request byte count (-101 stale claim).
@_cdecl("floe_network_diag_payload_length")
public func floeNetworkDiagPayloadLength(_ claim: Int64) -> Int32 {
    G07NetworkHostMailbox.shared.payloadLength(claim: claim)
}

/// Copy the FULL staged request; host allocates capacity >= payload_length.
@_cdecl("floe_network_diag_take_payload")
public func floeNetworkDiagTakePayload(_ claim: Int64,
                                       _ buffer: UnsafeMutablePointer<UInt8>?,
                                       _ capacity: Int32) -> Int32 {
    G07NetworkHostMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

/// 1 = ticket still live for the CURRENT bound generation.
@_cdecl("floe_network_diag_is_live")
public func floeNetworkDiagIsLive(_ claim: Int64) -> Int32 {
    G07NetworkHostMailbox.shared.isLive(claim: claim)
}

/// 1 = cancelled/fenced: stop real work, then still settle exactly once.
@_cdecl("floe_network_diag_should_stop")
public func floeNetworkDiagShouldStop(_ claim: Int64) -> Int32 {
    G07NetworkHostMailbox.shared.shouldStop(claim: claim)
}

/// Settle one claimed ticket ONCE. status 0 = success observation JSON
/// (<= 256 KiB); status 1 = typed failure (<= 512 B).
@_cdecl("floe_network_diag_complete")
public func floeNetworkDiagComplete(_ claim: Int64, _ status: Int32,
                                    _ value: UnsafePointer<UInt8>?,
                                    _ valueLen: Int32) -> Int32 {
    guard status == 0 || status == 1, valueLen >= 0,
          valueLen == 0 || value != nil else {
        return G07NetworkDiagnosticStatus.shape
    }
    let data = valueLen == 0 ? Data() : Data(bytes: value!, count: Int(valueLen))
    return G07NetworkHostMailbox.shared.complete(claim: claim, status: status, value: data)
}

/// Exact-epoch teardown (generation retirement).
@_cdecl("floe_network_diag_close")
public func floeNetworkDiagClose(_ epoch: UInt64) -> Int32 {
    G07NetworkHostMailbox.shared.close(epoch: epoch)
    return G07NetworkDiagnosticStatus.ok
}

/// Typed counters only (no targets, paths, ids or payloads).
@_cdecl("floe_network_diag_stats")
public func floeNetworkDiagStats(_ buffer: UnsafeMutablePointer<CChar>?,
                                 _ capacity: Int32) -> Int32 {
    floeG07CopyCString(G07NetworkHostMailbox.shared.statsJSON(),
                       buffer: buffer, capacity: capacity)
}

/// Actual readiness/capability report (bound epoch, registered tools).
@_cdecl("floe_network_diag_readiness")
public func floeNetworkDiagReadiness(_ buffer: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    floeG07CopyCString(G07NetworkComposition.shared.readinessJSON(),
                       buffer: buffer, capacity: capacity)
}

/// Shared bounded ASCII copy for this lane's two readbacks.
func floeG07CopyCString(_ value: String, buffer: UnsafeMutablePointer<CChar>?,
                        capacity: Int32) -> Int32 {
    guard capacity >= 0, let buffer else { return G07NetworkDiagnosticStatus.shape }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else {
        return G07NetworkDiagnosticStatus.bufferTooSmall
    }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
