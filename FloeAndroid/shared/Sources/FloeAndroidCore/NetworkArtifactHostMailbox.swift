// SPDX-License-Identifier: MPL-2.0
//
// G07.3B saved-artifact mailbox.
//
// Same reviewed shape as `G07NetworkHostMailbox`: ONE bounded ticket table per
// bound root epoch; the trusted Kotlin host claims tickets through the
// exported C ABI, reads an App-private saved summary and settles exactly once.
// There is no V3 handler and no model route: only the validated
// `network.pcapAnalyze` / `network.coverageSummary` request reaches the host.
//
// Status space (artifact-owned -9xx; generic claim statuses reuse -10x):
//   0 ok; -101 stale claim; -102 generation fenced; -105 shape;
//   -106 bufferTooSmall; -107 oversized; -108 descriptor invalid;
//   -110 not claimed; -901 notInstalled; -902 unavailable;
//   -903 requestRefused; -904 replyInvalid; -999 internal.
import Foundation
import FloeCore
import FloeAndroidNetwork

public enum G073NetworkArtifactStatus {
    public static let ok: Int32 = 0
    public static let staleClaim: Int32 = -101
    public static let generationFenced: Int32 = -102
    public static let shape: Int32 = -105
    public static let bufferTooSmall: Int32 = -106
    public static let oversized: Int32 = -107
    public static let descriptorInvalid: Int32 = -108
    public static let notClaimed: Int32 = -110
    public static let notInstalled: Int32 = -901
    public static let unavailable: Int32 = -902
    public static let requestRefused: Int32 = -903
    public static let replyInvalid: Int32 = -904
    public static let internalFailure: Int32 = -999
}

public enum G073NetworkArtifactHostLimits {
    public static let maximumDescriptorBytes = 2_048
    public static let maximumRequestBytes = NetworkArtifactLimits.maximumRequestBytes
    public static let maximumReplyBytes = NetworkArtifactLimits.maximumReplyBytes
    public static let maximumFailureReplyBytes = 512
    public static let maximumLiveTickets = 8
    public static let maximumRetired = 128
    public static let maximumCodeChars = 64
    public static let maximumDetailChars = 200
    public static let ticketBudgetMillis = 15_000
}

public struct G073NetworkArtifactOwner: Sendable, Equatable {
    public let taskID: UUID
    public let runID: UUID
    public let epoch: UInt64
    /// SHA-256 of the runtime-issued workspace root, or nil for no workspace.
    /// It is an opaque fingerprint, never a host path.
    public let workspaceFingerprint: String?

    public init(taskID: UUID, runID: UUID, epoch: UInt64,
                workspaceFingerprint: String? = nil) {
        self.taskID = taskID
        self.runID = runID
        self.epoch = epoch
        self.workspaceFingerprint = workspaceFingerprint
    }
}

public enum G073NetworkArtifactTransportError: Error, Sendable, Equatable {
    case hostUnbound
    case hostClosed
    case hostFenced
    case hostBudget
    case saturated
    case oversized
    case cancelled
    case remoteFailed(code: String, detail: String?)
}

public protocol G073NetworkArtifactHostSubmitting: Sendable {
    var boundEpoch: UInt64 { get }
    var isBound: Bool { get }
    func submit(request: NetworkArtifactToolRequest, owner: G073NetworkArtifactOwner,
                cancellation: CancellationToken) async throws -> Data
}

public final class G073NetworkArtifactHostMailbox: @unchecked Sendable {
    public static let shared = G073NetworkArtifactHostMailbox()

    private final class Ticket {
        let claim: Int64
        let method: NetworkArtifactToolMethod
        let operationID: UUID
        let descriptor: Data
        let staged: Data
        let createdEpoch: UInt64
        let deadline: DispatchTime
        let cancellation: CancellationToken
        var state = 0 // 0 queued, 1 claimed, 2 settled
        var continuation: CheckedContinuation<Data, G073NetworkArtifactTransportError>?

        init(claim: Int64, method: NetworkArtifactToolMethod, operationID: UUID,
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

    public func isBound(to expectedEpoch: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0 && epoch == expectedEpoch
    }

    public func bind(epoch newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch != 0, newEpoch > epoch else {
            counters.bindRejections += 1
            condition.unlock()
            return false
        }
        epoch = newEpoch
        closed = false
        var resumes: [CheckedContinuation<Data, G073NetworkArtifactTransportError>] = []
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

    public func close(epoch closing: UInt64) {
        condition.lock()
        guard closing == epoch, epoch != 0 else { condition.unlock(); return }
        closed = true
        var resumes: [CheckedContinuation<Data, G073NetworkArtifactTransportError>] = []
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

    func submitTicket(request: NetworkArtifactToolRequest, owner: G073NetworkArtifactOwner,
                      cancellation: CancellationToken) async throws -> Data {
        let staged = request.requestJSON
        guard staged.count <= G073NetworkArtifactHostLimits.maximumRequestBytes else {
            throw G073NetworkArtifactTransportError.oversized
        }
        guard !cancellation.isCancelled else { throw G073NetworkArtifactTransportError.cancelled }
        return try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            guard !closed, epoch != 0 else {
                counters.unbound += 1
                condition.unlock()
                continuation.resume(throwing: .hostUnbound)
                return
            }
            guard tickets.count < G073NetworkArtifactHostLimits.maximumLiveTickets else {
                counters.saturated += 1
                condition.unlock()
                continuation.resume(throwing: .saturated)
                return
            }
            guard owner.epoch == epoch else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: .hostFenced)
                return
            }
            let descriptor = Self.descriptorJSON(request: request, owner: owner)
            guard !descriptor.isEmpty,
                  descriptor.count <= G073NetworkArtifactHostLimits.maximumDescriptorBytes else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: .hostFenced)
                return
            }
            counter &+= 1
            let ticket = Ticket(
                claim: counter, method: request.method, operationID: request.operationID,
                descriptor: descriptor, staged: staged, epoch: epoch,
                deadline: DispatchTime.now() + .milliseconds(G073NetworkArtifactHostLimits.ticketBudgetMillis),
                cancellation: cancellation)
            ticket.continuation = continuation
            tickets[counter] = ticket
            queue.append(counter)
            counters.submitted += 1
            condition.broadcast()
            condition.unlock()
        }
    }

    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        var expired: [CheckedContinuation<Data, G073NetworkArtifactTransportError>] = []
        defer { for continuation in expired { continuation.resume(throwing: .hostBudget) } }
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

    public func describe(claim: Int64, buffer: UnsafeMutablePointer<CChar>?,
                         capacity: Int32) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            condition.unlock()
            return G073NetworkArtifactStatus.staleClaim
        }
        let descriptor = ticket.descriptor
        condition.unlock()
        guard descriptor.count <= G073NetworkArtifactHostLimits.maximumDescriptorBytes else {
            return G073NetworkArtifactStatus.descriptorInvalid
        }
        guard capacity >= 0, let buffer, descriptor.count + 1 <= Int(capacity) else {
            return G073NetworkArtifactStatus.bufferTooSmall
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
            return G073NetworkArtifactStatus.staleClaim
        }
        guard ticket.staged.count <= G073NetworkArtifactHostLimits.maximumRequestBytes else {
            return G073NetworkArtifactStatus.oversized
        }
        return Int32(ticket.staged.count)
    }

    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?,
                            capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            return G073NetworkArtifactStatus.staleClaim
        }
        guard capacity >= 0, let buffer, capacity >= ticket.staged.count else {
            return G073NetworkArtifactStatus.bufferTooSmall
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
        guard let ticket = tickets[claim], ticket.createdEpoch == epoch, !closed else { return 0 }
        return ticket.state == 0 || (ticket.state == 1 && ticket.continuation != nil) ? 1 : 0
    }

    public func shouldStop(claim: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else { return 1 }
        return ticket.cancellation.isCancelled ? 1 : 0
    }

    @discardableResult
    public func complete(claim: Int64, status: Int32, value: Data) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim] else {
            if retired.contains(claim) { counters.lateSettle += 1 }
            condition.unlock()
            return G073NetworkArtifactStatus.staleClaim
        }
        guard ticket.state == 1 else {
            condition.unlock()
            return G073NetworkArtifactStatus.notClaimed
        }
        guard ticket.createdEpoch == epoch, !closed else {
            counters.lateSettle += 1
            condition.unlock()
            return G073NetworkArtifactStatus.generationFenced
        }
        guard status == 0 || status == 1 else {
            condition.unlock()
            return G073NetworkArtifactStatus.shape
        }
        if status == 0, value.count > G073NetworkArtifactHostLimits.maximumReplyBytes {
            condition.unlock()
            return G073NetworkArtifactStatus.oversized
        }
        if status == 1, value.count > G073NetworkArtifactHostLimits.maximumFailureReplyBytes {
            condition.unlock()
            return G073NetworkArtifactStatus.oversized
        }
        let outcome: Result<Data, G073NetworkArtifactTransportError>
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

    private func retireLocked(_ claim: Int64) {
        tickets.removeValue(forKey: claim)
        retired.insert(claim)
        retiredOrder.append(claim)
        while retiredOrder.count > G073NetworkArtifactHostLimits.maximumRetired {
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
        into expired: inout [CheckedContinuation<Data, G073NetworkArtifactTransportError>]
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
            return String(cleaned.prefix(G073NetworkArtifactHostLimits.maximumDetailChars))
        }
        return (body.code, detail)
    }

    private static func isValidFailureCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= G073NetworkArtifactHostLimits.maximumCodeChars,
              let first = code.first, first.isLetter else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-")
        }
    }

    private static func descriptorJSON(request: NetworkArtifactToolRequest,
                                       owner: G073NetworkArtifactOwner) -> Data {
        let object: [String: Any] = [
            "operation": "networkArtifact.execute",
            "epoch": String(owner.epoch),
            "method": request.method.rawValue,
            "operationID": request.operationID.uuidString,
            "taskID": owner.taskID.uuidString,
            "runID": owner.runID.uuidString,
            "payloadBytes": request.requestJSON.count,
            "budgetMs": G073NetworkArtifactHostLimits.ticketBudgetMillis,
            "workspace": owner.workspaceFingerprint ?? "",
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            return Data()
        }
        return data
    }
}

extension G073NetworkArtifactHostMailbox: G073NetworkArtifactHostSubmitting {
    public func submit(request: NetworkArtifactToolRequest, owner: G073NetworkArtifactOwner,
                       cancellation: CancellationToken) async throws -> Data {
        try await submitTicket(request: request, owner: owner, cancellation: cancellation)
    }
}

// MARK: - Trusted-host C ABI (Kotlin artifact pump only; NOT a V3 command)

@_cdecl("floe_network_artifact_bind")
public func floeNetworkArtifactBind(_ epoch: UInt64) -> Int32 {
    guard G02NativeRootEpoch.readback() == epoch else {
        return G073NetworkArtifactStatus.generationFenced
    }
    guard G073NetworkArtifactHostMailbox.shared.bind(epoch: epoch) else {
        return G073NetworkArtifactStatus.generationFenced
    }
    G073NetworkArtifactComposition.shared.installToolsIfNeeded()
    return G073NetworkArtifactStatus.ok
}

@_cdecl("floe_network_artifact_next")
public func floeNetworkArtifactNext(_ timeoutMillis: Int32) -> Int64 {
    G073NetworkArtifactHostMailbox.shared.nextClaim(
        timeoutMillis: min(1_000, max(0, timeoutMillis)))
}

@_cdecl("floe_network_artifact_describe")
public func floeNetworkArtifactDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                        _ capacity: Int32) -> Int32 {
    G073NetworkArtifactHostMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_network_artifact_payload_length")
public func floeNetworkArtifactPayloadLength(_ claim: Int64) -> Int32 {
    G073NetworkArtifactHostMailbox.shared.payloadLength(claim: claim)
}

@_cdecl("floe_network_artifact_take_payload")
public func floeNetworkArtifactTakePayload(_ claim: Int64,
                                           _ buffer: UnsafeMutablePointer<UInt8>?,
                                           _ capacity: Int32) -> Int32 {
    G073NetworkArtifactHostMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_network_artifact_is_live")
public func floeNetworkArtifactIsLive(_ claim: Int64) -> Int32 {
    G073NetworkArtifactHostMailbox.shared.isLive(claim: claim)
}

@_cdecl("floe_network_artifact_should_stop")
public func floeNetworkArtifactShouldStop(_ claim: Int64) -> Int32 {
    G073NetworkArtifactHostMailbox.shared.shouldStop(claim: claim)
}

@_cdecl("floe_network_artifact_complete")
public func floeNetworkArtifactComplete(_ claim: Int64, _ status: Int32,
                                        _ value: UnsafePointer<UInt8>?,
                                        _ valueLen: Int32) -> Int32 {
    guard status == 0 || status == 1, valueLen >= 0,
          valueLen == 0 || value != nil else {
        return G073NetworkArtifactStatus.shape
    }
    let data = valueLen == 0 ? Data() : Data(bytes: value!, count: Int(valueLen))
    return G073NetworkArtifactHostMailbox.shared.complete(claim: claim, status: status, value: data)
}

@_cdecl("floe_network_artifact_close")
public func floeNetworkArtifactClose(_ epoch: UInt64) -> Int32 {
    G073NetworkArtifactHostMailbox.shared.close(epoch: epoch)
    return G073NetworkArtifactStatus.ok
}

@_cdecl("floe_network_artifact_stats")
public func floeNetworkArtifactStats(_ buffer: UnsafeMutablePointer<CChar>?,
                                     _ capacity: Int32) -> Int32 {
    floeG073CopyCString(G073NetworkArtifactHostMailbox.shared.statsJSON(),
                        buffer: buffer, capacity: capacity)
}

@_cdecl("floe_network_artifact_readiness")
public func floeNetworkArtifactReadiness(_ buffer: UnsafeMutablePointer<CChar>?,
                                         _ capacity: Int32) -> Int32 {
    floeG073CopyCString(G073NetworkArtifactComposition.shared.readinessJSON(),
                        buffer: buffer, capacity: capacity)
}

func floeG073CopyCString(_ value: String, buffer: UnsafeMutablePointer<CChar>?,
                         capacity: Int32) -> Int32 {
    guard capacity >= 0, let buffer else { return G073NetworkArtifactStatus.shape }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else {
        return G073NetworkArtifactStatus.bufferTooSmall
    }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
