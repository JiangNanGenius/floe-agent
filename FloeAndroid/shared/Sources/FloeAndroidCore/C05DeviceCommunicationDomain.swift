// SPDX-License-Identifier: MPL-2.0
//
// C05 device communications — Swift authority, trusted tool mailbox and the
// confirmed device profile seam.
//
// The REAL sockets, Android BLE GATT connections and USB serial ports live in
// the Kotlin `:core:devicecommunication` engine, because those platform APIs
// have no Swift Android analogue. This file owns:
//   * the closed `floe.device/14` value/wire surface and device profile
//     persistence over the EXISTING `hosts` rows;
//   * the ONE bounded trusted mailbox through which the ORIGINAL
//     ToolRunnerRegistry model tools submit a concrete operation;
//   * ownership/epoch/approval checks derived from the runtime-issued
//     `ToolContext`, never from model JSON.
//
// It is NOT a BridgeV3 command, NOT a second execution route and never asks
// for a permission. A model tool that needs BLE/USB/LAN access fails with an
// actionable permission error when the user has not already granted it.

import Foundation
import FloeCore
import FloePersistence
import FloeSSH
import FloeTools

// MARK: - Wire identity

public enum C05DeviceWire {
    public static let version = 14
    public static let schema = "floe.device/14"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 48 * 1_024
    public static let maximumProfiles = 64
    public static let maximumConnectionsPerProfile = 8
    public static let maximumDisplayNameBytes = 120
    public static let maximumConnectionNameBytes = 120
    public static let maximumHostBytes = 253
    public static let maximumUuidBytes = 64
    public static let maximumSessions = 4
    public static let modelTools = true
}

public enum C05DeviceErrorCode: String, Sendable, Equatable {
    case runtimeNotInstalled
    case staleEpoch
    case invalidRequest
    case invalidTarget
    case policyDenied
    case localNetworkPermissionRequired
    case permissionRequired
    case permissionDenied
    case bluetoothUnavailable
    case bluetoothDisabled
    case unsupported
    case deviceNotFound
    case driverNotFound
    case connectFailed
    case connectionRefused
    case hostNotFound
    case timedOut
    case ioFailed
    case protocolError
    case operationBusy
    case sessionLimit
    case sessionNotFound
    case sessionClosing
    case cleanupIncomplete
    case responseTooLarge
    case notAttached
    case inputFull
    case cancelled
    case internalFailure
    case profileNotFound
    case profileLimit
    case invalidProfile
    case unsupportedOperation
}

public struct C05DeviceError: Error, Sendable, Equatable {
    public let code: C05DeviceErrorCode
    public let reason: String
    public let retryable: Bool
    public let detail: String?
    public let stage: String?

    public init(
        _ code: C05DeviceErrorCode,
        _ reason: String,
        retryable: Bool = false,
        detail: String? = nil,
        stage: String? = nil
    ) {
        self.code = code
        self.reason = reason
        self.retryable = retryable
        self.detail = detail
        self.stage = stage
    }
}

// MARK: - Value surface

public struct C05DeviceOwner: Sendable, Equatable {
    public let token: String
    public let nativeEpoch: UInt64
    public let taskID: UUID?
    public let approvalGrantID: UUID?
    public let temporary: Bool

    public init(
        token: String,
        nativeEpoch: UInt64,
        taskID: UUID? = nil,
        approvalGrantID: UUID? = nil,
        temporary: Bool = false
    ) {
        self.token = token
        self.nativeEpoch = nativeEpoch
        self.taskID = taskID
        self.approvalGrantID = approvalGrantID
        self.temporary = temporary
    }
}

public struct C05DeviceConnectionDraft: Sendable, Equatable {
    public var id: UUID?
    public var displayName: String
    public var kind: String
    public var host: String?
    public var port: Int?
    public var peripheralAddress: String?
    public var serviceUUID: String?
    public var writeUUID: String?
    public var notifyUUID: String?

    public init(
        id: UUID? = nil,
        displayName: String,
        kind: String,
        host: String? = nil,
        port: Int? = nil,
        peripheralAddress: String? = nil,
        serviceUUID: String? = nil,
        writeUUID: String? = nil,
        notifyUUID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.host = host
        self.port = port
        self.peripheralAddress = peripheralAddress
        self.serviceUUID = serviceUUID
        self.writeUUID = writeUUID
        self.notifyUUID = notifyUUID
    }
}

public struct C05DeviceProfileDraft: Sendable, Equatable {
    public var id: UUID?
    public var displayName: String
    public var connections: [C05DeviceConnectionDraft]

    public init(id: UUID? = nil, displayName: String, connections: [C05DeviceConnectionDraft]) {
        self.id = id
        self.displayName = displayName
        self.connections = connections
    }
}

public struct C05DeviceConnection: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let kind: String
    public let host: String?
    public let port: Int?
    public let peripheralAddress: String?
    public let serviceUUID: String?
    public let writeUUID: String?
    public let notifyUUID: String?
}

public struct C05DeviceProfile: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let displayName: String
    public let connections: [C05DeviceConnection]
}

public struct C05DeviceCapabilities: Sendable, Equatable {
    public let coreReady: Bool
    public let epoch: UInt64?
    public let maximumSessions: Int
    public let maximumProfiles: Int
    public let maximumConnectionsPerProfile: Int
    public let supportsTcp: Bool
    public let supportsTelnet: Bool
    public let supportsBle: Bool
    public let supportsUsb: Bool
    public let modelTools: Bool
}

public struct C05DeviceResolvedConnection: Sendable, Equatable {
    public let kind: String
    public let host: String?
    public let port: Int?
    public let peripheralAddress: String?
    public let serviceUUID: String?
    public let writeUUID: String?
    public let notifyUUID: String?
}

public struct C05DeviceProfileDeleteReport: Sendable, Equatable {
    public let deleted: Bool
    public let remainingConnections: Int
}

// MARK: - Limits and errors

public enum C05DeviceHostLimits {
    public static let maximumDescriptorBytes = 2_048
    public static let maximumRequestBytes = C05DeviceWire.maximumRequestBytes
    public static let maximumReplyBytes = C05DeviceWire.maximumResponseBytes
    public static let maximumFailureReplyBytes = 512
    public static let maximumLiveTickets = 8
    public static let maximumRetired = 128
    public static let maximumCodeCharacters = 64
    public static let maximumDetailCharacters = 200
    public static let ticketBudgetMillis = 30_000
}

public enum C05DeviceHostStatus {
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

public enum C05DeviceHostError: Error, Sendable, Equatable {
    case hostUnbound
    case hostClosed
    case hostFenced
    case hostBudget
    case saturated
    case oversized
    case cancelled
    case approvalRequired
    case remoteFailed(code: String, detail: String?)
}

// MARK: - Trusted host mailbox

public protocol C05DeviceHostSubmitting: Sendable {
    var boundEpoch: UInt64 { get }
    var isBound: Bool { get }
    func submit(
        operation: String,
        request: Data,
        owner: C05DeviceOwner,
        requiresApproval: Bool,
        cancellation: CancellationToken
    ) async throws -> Data
}

public final class C05DeviceHostMailbox: C05DeviceHostSubmitting, @unchecked Sendable {
    public static let shared = C05DeviceHostMailbox()

    private final class Ticket: @unchecked Sendable {
        let claim: Int64
        let operation: String
        let descriptor: Data
        let payload: Data
        let createdEpoch: UInt64
        let deadline: DispatchTime
        let cancellation: CancellationToken
        var state = 0 // 0 queued, 1 claimed, 2 settled
        var continuation: CheckedContinuation<Data, C05DeviceHostError>?

        init(
            claim: Int64,
            operation: String,
            descriptor: Data,
            payload: Data,
            epoch: UInt64,
            deadline: DispatchTime,
            cancellation: CancellationToken
        ) {
            self.claim = claim
            self.operation = operation
            self.descriptor = descriptor
            self.payload = payload
            self.createdEpoch = epoch
            self.deadline = deadline
            self.cancellation = cancellation
        }
    }

    private struct Counters {
        var submitted = 0
        var claimed = 0
        var completed = 0
        var failed = 0
        var lateSettle = 0
        var fenced = 0
        var saturated = 0
        var unbound = 0
        var expired = 0
        var bindRejections = 0
        var refusedByApproval = 0
    }

    private let condition = NSCondition()
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var counter: Int64 = 0
    private var epoch: UInt64 = 0
    private var closed = true
    private var counters = Counters()

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
        var resumes: [CheckedContinuation<Data, C05DeviceHostError>] = []
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
        var resumes: [CheckedContinuation<Data, C05DeviceHostError>] = []
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

    public func submit(
        operation: String,
        request: Data,
        owner: C05DeviceOwner,
        requiresApproval: Bool,
        cancellation: CancellationToken
    ) async throws -> Data {
        guard request.count <= C05DeviceHostLimits.maximumRequestBytes else {
            throw C05DeviceHostError.oversized
        }
        guard !cancellation.isCancelled else { throw C05DeviceHostError.cancelled }
        if requiresApproval, owner.approvalGrantID == nil {
            throw C05DeviceHostError.approvalRequired
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, C05DeviceHostError>) in
            condition.lock()
            guard !closed, epoch != 0 else {
                counters.unbound += 1
                condition.unlock()
                continuation.resume(throwing: .hostUnbound)
                return
            }
            guard tickets.count < C05DeviceHostLimits.maximumLiveTickets else {
                counters.saturated += 1
                condition.unlock()
                continuation.resume(throwing: .saturated)
                return
            }
            guard owner.nativeEpoch == epoch else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: .hostFenced)
                return
            }
            guard let descriptor = Self.descriptorJSON(operation: operation, owner: owner,
                                                       payloadBytes: request.count),
                  descriptor.count <= C05DeviceHostLimits.maximumDescriptorBytes else {
                counters.fenced += 1
                condition.unlock()
                continuation.resume(throwing: .hostFenced)
                return
            }
            counter &+= 1
            let ticket = Ticket(
                claim: counter,
                operation: operation,
                descriptor: descriptor,
                payload: request,
                epoch: epoch,
                deadline: DispatchTime.now()
                    + .milliseconds(C05DeviceHostLimits.ticketBudgetMillis),
                cancellation: cancellation
            )
            ticket.continuation = continuation
            tickets[counter] = ticket
            queue.append(counter)
            counters.submitted += 1
            condition.broadcast()
            condition.unlock()
        }
    }

    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        var expired: [CheckedContinuation<Data, C05DeviceHostError>] = []
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
            return C05DeviceHostStatus.staleClaim
        }
        let descriptor = ticket.descriptor
        condition.unlock()
        guard descriptor.count <= C05DeviceHostLimits.maximumDescriptorBytes else {
            return C05DeviceHostStatus.descriptorInvalid
        }
        guard capacity >= 0, let buffer, descriptor.count + 1 <= Int(capacity) else {
            return C05DeviceHostStatus.bufferTooSmall
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
            return C05DeviceHostStatus.staleClaim
        }
        guard ticket.payload.count <= C05DeviceHostLimits.maximumRequestBytes else {
            return C05DeviceHostStatus.oversized
        }
        return Int32(ticket.payload.count)
    }

    public func takePayload(claim: Int64, buffer: UnsafeMutablePointer<UInt8>?,
                            capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.state == 1,
              ticket.createdEpoch == epoch, !closed else {
            return C05DeviceHostStatus.staleClaim
        }
        guard capacity >= 0, let buffer, capacity >= ticket.payload.count else {
            return C05DeviceHostStatus.bufferTooSmall
        }
        guard !ticket.payload.isEmpty else { return 0 }
        ticket.payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, ticket.payload.count)
        }
        return Int32(ticket.payload.count)
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
        return ticket.cancellation.isCancelled || ticket.deadline < DispatchTime.now() ? 1 : 0
    }

    @discardableResult
    public func complete(claim: Int64, status: Int32, value: Data) -> Int32 {
        condition.lock()
        guard let ticket = tickets[claim] else {
            if retired.contains(claim) { counters.lateSettle += 1 }
            condition.unlock()
            return C05DeviceHostStatus.staleClaim
        }
        guard ticket.state == 1 else {
            condition.unlock()
            return C05DeviceHostStatus.notClaimed
        }
        guard ticket.createdEpoch == epoch, !closed else {
            counters.lateSettle += 1
            condition.unlock()
            return C05DeviceHostStatus.generationFenced
        }
        guard status == 0 || status == 1 else {
            condition.unlock()
            return C05DeviceHostStatus.shape
        }
        if status == 0, value.count > C05DeviceHostLimits.maximumReplyBytes {
            condition.unlock()
            return C05DeviceHostStatus.oversized
        }
        if status == 1, value.count > C05DeviceHostLimits.maximumFailureReplyBytes {
            condition.unlock()
            return C05DeviceHostStatus.oversized
        }
        let continuation = ticket.continuation
        ticket.continuation = nil
        ticket.state = 2
        let outcome: Result<Data, C05DeviceHostError>
        if status == 0 {
            outcome = .success(value)
            counters.completed += 1
        } else {
            let failure = Self.failure(from: value)
            outcome = .failure(.remoteFailed(code: failure.code, detail: failure.detail))
            counters.failed += 1
        }
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
                "refusedByApproval": counters.refusedByApproval,
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
        while retiredOrder.count > C05DeviceHostLimits.maximumRetired {
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
        into expired: inout [CheckedContinuation<Data, C05DeviceHostError>]
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
              isValidCode(body.code) else {
            return ("internal", nil)
        }
        let detail = body.detail.map { value -> String in
            let cleaned = String(value.filter { character in
                character.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
            })
            return String(cleaned.prefix(C05DeviceHostLimits.maximumDetailCharacters))
        }
        return (body.code, detail)
    }

    private static func isValidCode(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= C05DeviceHostLimits.maximumCodeCharacters,
              let first = code.first, first.isLetter else { return false }
        return code.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-")
        }
    }

    private static func descriptorJSON(
        operation: String,
        owner: C05DeviceOwner,
        payloadBytes: Int
    ) -> Data? {
        var object: [String: Any] = [
            "version": 1,
            "operation": operation,
            "epoch": String(owner.nativeEpoch),
            "payloadBytes": payloadBytes,
            "budgetMs": C05DeviceHostLimits.ticketBudgetMillis,
        ]
        if let taskID = owner.taskID { object["taskID"] = taskID.uuidString }
        if let approval = owner.approvalGrantID { object["approvalGrantID"] = approval.uuidString }
        object["ownerToken"] = owner.token
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            return nil
        }
        return data
    }
}

// MARK: - Profile persistence

public protocol C05DeviceProfileStoring: Sendable {
    func hosts() async throws -> [RemoteHostStore.StoredHost]
    func host(id: UUID) async throws -> RemoteHostStore.StoredHost?
    func saveHost(_ host: RemoteHostStore.StoredHost) async throws
    func deleteHost(id: UUID) async throws
}

extension RemoteHostStore: C05DeviceProfileStoring {}

public enum C05DeviceProductionWiring {
    public static func readiness() -> (ready: Bool, epoch: UInt64?) {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            return (false, nil)
        }
        return (true, composition.epoch)
    }

    public static func store(epoch: UInt64) throws -> RemoteHostStore {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C05DeviceError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C05DeviceError(.staleEpoch, "staleNativeEpoch")
        }
        return RemoteHostStore(database: composition.cluster.database)
    }
}

/// The exact Android BLE address bridge. The shared `RemoteAuxiliaryConnection`
/// value predates Android and stores a CoreBluetooth UUID; Android exposes a
/// MAC address. A saved Bluetooth connection therefore stores the MAC in the
/// optional `host` field and a deterministic UUID projection in
/// `bluetoothPeripheralID` so the existing value (and its validator) remains
/// intact. No pairing, secret or identity is derived from this projection.
public enum C05DeviceBLEAddress {
    private static let macRegex = try! NSRegularExpression(
        pattern: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
    )

    public static func isValid(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return macRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    public static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return isValid(value) ? value : nil
    }

    public static func uuid(from mac: String) -> UUID? {
        guard let normalized = normalized(mac) else { return nil }
        let hex = normalized.replacingOccurrences(of: ":", with: "")
        let padded = hex + String(repeating: "0", count: 32 - hex.count)
        let formatted = String(
            format: "%@-%@-%@-%@-%@",
            String(padded.prefix(8)),
            String(padded.dropFirst(8).prefix(4)),
            String(padded.dropFirst(12).prefix(4)),
            String(padded.dropFirst(16).prefix(4)),
            String(padded.dropFirst(20).prefix(12))
        )
        return UUID(uuidString: formatted)
    }

    public static func mac(from uuid: UUID) -> String? {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 12 else { return nil }
        let first = String(hex.prefix(12)).uppercased()
        var pairs: [String] = []
        var index = first.startIndex
        while index < first.endIndex {
            let end = first.index(index, offsetBy: 2)
            pairs.append(String(first[index..<end]))
            index = end
        }
        return pairs.joined(separator: ":")
    }
}

public enum C05DeviceGATTUUID {
    private static let full = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )

    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        switch value.count {
        case 4:
            guard value.allSatisfy({ $0.isHexDigit }) else { return nil }
            return "0000\(value.lowercased())-0000-1000-8000-00805f9b34fb"
        case 8:
            guard value.allSatisfy({ $0.isHexDigit }) else { return nil }
            return "\(value.lowercased())-0000-1000-8000-00805f9b34fb"
        case 36:
            guard full.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil,
                  UUID(uuidString: value) != nil else { return nil }
            return value.lowercased()
        default:
            return nil
        }
    }
}

private extension Character {
    var isHexDigit: Bool {
        self >= "0" && self <= "9" || self >= "a" && self <= "f" || self >= "A" && self <= "F"
    }
}

// MARK: - Device profile domain

public actor C05DeviceDomain {
    public static let shared = C05DeviceDomain(
        storeProvider: { epoch in try C05DeviceProductionWiring.store(epoch: epoch) },
        epochProvider: { C05DeviceProductionWiring.readiness().epoch }
    )

    private let storeProvider: @Sendable (UInt64) throws -> C05DeviceProfileStoring
    private let epochProvider: @Sendable () -> UInt64?

    public init(
        storeProvider: @escaping @Sendable (UInt64) throws -> C05DeviceProfileStoring,
        epochProvider: @escaping @Sendable () -> UInt64?
    ) {
        self.storeProvider = storeProvider
        self.epochProvider = epochProvider
    }

    public func capabilities() -> C05DeviceCapabilities {
        let epoch = epochProvider()
        return C05DeviceCapabilities(
            coreReady: epoch != nil,
            epoch: epoch,
            maximumSessions: C05DeviceWire.maximumSessions,
            maximumProfiles: C05DeviceWire.maximumProfiles,
            maximumConnectionsPerProfile: C05DeviceWire.maximumConnectionsPerProfile,
            supportsTcp: true,
            supportsTelnet: true,
            supportsBle: true,
            supportsUsb: true,
            modelTools: C05DeviceWire.modelTools
        )
    }

    public func listProfiles(owner: C05DeviceOwner) async throws -> [C05DeviceProfile] {
        let store = try stores(owner: owner)
        let rows = try await store.hosts()
        var result: [C05DeviceProfile] = []
        for row in rows.prefix(C05DeviceWire.maximumProfiles) {
            guard let profile = try? RemoteHostProfile(stored: row) else { continue }
            if let mapped = deviceProfile(from: profile) { result.append(mapped) }
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func saveProfile(
        _ draft: C05DeviceProfileDraft,
        owner: C05DeviceOwner
    ) async throws -> C05DeviceProfile {
        let store = try stores(owner: owner)
        try validateDraft(draft)
        let id = draft.id ?? UUID()
        let existingRow = try await store.host(id: id)
        if existingRow == nil, try await store.hosts().count >= C05DeviceWire.maximumProfiles {
            throw C05DeviceError(.profileLimit, "profileLimitReached")
        }
        let profile: RemoteHostProfile
        if let row = existingRow {
            guard let decoded = try? RemoteHostProfile(stored: row) else {
                throw C05DeviceError(.invalidProfile, "invalidStoredProfile")
            }
            profile = decoded
        } else {
            profile = RemoteHostProfile(
                id: id,
                displayName: draft.displayName,
                address: "",
                port: 22,
                user: "",
                auth: .none,
                deviceKind: .appliance,
                isRemoteExecutionEnvironment: false
            )
        }
        var updated = profile
        updated.displayName = draft.displayName
        updated.auxiliaryConnections = try draft.connections.map { connection in
            try makeAuxiliary(connection)
        }
        try updated.validate()
        try await store.saveHost(updated.storedHost())
        guard let mapped = deviceProfile(from: updated) else {
            throw C05DeviceError(.invalidProfile, "deviceProfileHasNoConnections")
        }
        return mapped
    }

    public func deleteProfile(
        id: UUID,
        owner: C05DeviceOwner
    ) async throws -> C05DeviceProfileDeleteReport {
        let store = try stores(owner: owner)
        guard let row = try await store.host(id: id) else {
            throw C05DeviceError(.profileNotFound, "profileNotFound")
        }
        guard let profile = try? RemoteHostProfile(stored: row) else {
            throw C05DeviceError(.invalidProfile, "invalidStoredProfile")
        }
        let remaining = profile.auxiliaryConnections.count
        let hasOtherProfileData = profile.auth != .none ||
            !profile.jumpChain.isEmpty ||
            !profile.vncEndpoints.isEmpty
        if hasOtherProfileData {
            var updated = profile
            updated.auxiliaryConnections = []
            try await store.saveHost(updated.storedHost())
        } else {
            try await store.deleteHost(id: id)
        }
        return C05DeviceProfileDeleteReport(deleted: true, remainingConnections: remaining)
    }

    public func resolveConnection(
        hostID: UUID,
        connectionID: UUID,
        owner: C05DeviceOwner
    ) async throws -> C05DeviceResolvedConnection {
        let store = try stores(owner: owner)
        guard let row = try await store.host(id: hostID),
              let profile = try? RemoteHostProfile(stored: row),
              let connection = profile.auxiliaryConnections.first(where: { $0.id == connectionID }) else {
            throw C05DeviceError(.deviceNotFound, "savedDeviceConnectionMissing")
        }
        switch connection.kind {
        case .tcp, .telnet:
            guard let host = connection.host, let port = connection.port else {
                throw C05DeviceError(.invalidProfile, "invalidSavedConnection")
            }
            return C05DeviceResolvedConnection(
                kind: connection.kind.rawValue,
                host: host,
                port: port,
                peripheralAddress: nil,
                serviceUUID: nil,
                writeUUID: nil,
                notifyUUID: nil
            )
        case .bluetoothSerial:
            guard let address = bleAddress(for: connection),
                  let service = connection.bluetoothServiceUUID,
                  let write = connection.bluetoothWriteCharacteristicUUID else {
                throw C05DeviceError(.invalidProfile, "invalidSavedBleConnection")
            }
            return C05DeviceResolvedConnection(
                kind: "bluetoothSerial",
                host: nil,
                port: nil,
                peripheralAddress: address,
                serviceUUID: service,
                writeUUID: write,
                notifyUUID: connection.bluetoothNotifyCharacteristicUUID
            )
        }
    }

    private func stores(owner: C05DeviceOwner) throws -> C05DeviceProfileStoring {
        guard !owner.token.isEmpty, owner.token.utf8.count <= 128 else {
            throw C05DeviceError(.invalidRequest, "invalidOwner")
        }
        guard !owner.temporary else {
            throw C05DeviceError(.permissionRequired, "temporaryOwnerCannotManageDevices")
        }
        guard let live = epochProvider(), live != 0, owner.nativeEpoch == live else {
            throw C05DeviceError(.staleEpoch, "staleNativeEpoch", retryable: true)
        }
        return try storeProvider(live)
    }

    private func validateDraft(_ draft: C05DeviceProfileDraft) throws {
        guard !draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.displayName.utf8.count <= C05DeviceWire.maximumDisplayNameBytes,
              !draft.displayName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C05DeviceError(.invalidProfile, "invalidDisplayName")
        }
        guard !draft.connections.isEmpty,
              draft.connections.count <= C05DeviceWire.maximumConnectionsPerProfile else {
            throw C05DeviceError(.invalidProfile, "invalidConnectionCount")
        }
        var ids: Set<UUID> = []
        for connection in draft.connections {
            guard !connection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  connection.displayName.utf8.count <= C05DeviceWire.maximumConnectionNameBytes else {
                throw C05DeviceError(.invalidProfile, "invalidConnectionName")
            }
            let id = connection.id ?? UUID()
            guard ids.insert(id).inserted else {
                throw C05DeviceError(.invalidProfile, "duplicateConnectionID")
            }
            switch connection.kind {
            case "tcp", "telnet":
                guard let host = connection.host, isValidHost(host),
                      let port = connection.port, (1...65_535).contains(port) else {
                    throw C05DeviceError(.invalidTarget, "invalidSavedTarget")
                }
            case "bluetoothSerial":
                guard let address = connection.peripheralAddress,
                      C05DeviceBLEAddress.isValid(address),
                      C05DeviceGATTUUID.normalize(connection.serviceUUID) != nil,
                      C05DeviceGATTUUID.normalize(connection.writeUUID) != nil,
                      connection.notifyUUID == nil ||
                        C05DeviceGATTUUID.normalize(connection.notifyUUID) != nil else {
                    throw C05DeviceError(.invalidProfile, "invalidSavedBleConnection")
                }
            default:
                throw C05DeviceError(.invalidProfile, "unsupportedSavedConnectionKind")
            }
        }
    }

    private func makeAuxiliary(
        _ connection: C05DeviceConnectionDraft
    ) throws -> RemoteAuxiliaryConnection {
        let id = connection.id ?? UUID()
        switch connection.kind {
        case "tcp", "telnet":
            guard let host = connection.host, isValidHost(host),
                  let port = connection.port, (1...65_535).contains(port) else {
                throw C05DeviceError(.invalidTarget, "invalidSavedTarget")
            }
            return RemoteAuxiliaryConnection(
                id: id,
                displayName: connection.displayName,
                kind: connection.kind == "telnet" ? .telnet : .tcp,
                host: host,
                port: port
            )
        case "bluetoothSerial":
            guard let address = connection.peripheralAddress,
                  let normalizedAddress = C05DeviceBLEAddress.normalized(address),
                  let peripheral = C05DeviceBLEAddress.uuid(from: normalizedAddress),
                  let service = C05DeviceGATTUUID.normalize(connection.serviceUUID),
                  let write = C05DeviceGATTUUID.normalize(connection.writeUUID) else {
                throw C05DeviceError(.invalidProfile, "invalidSavedBleConnection")
            }
            var notify: String?
            if let rawNotify = connection.notifyUUID, !rawNotify.isEmpty {
                guard let normalizedNotify = C05DeviceGATTUUID.normalize(rawNotify) else {
                    throw C05DeviceError(.invalidProfile, "invalidSavedBleConnection")
                }
                notify = normalizedNotify
            }
            return RemoteAuxiliaryConnection(
                id: id,
                displayName: connection.displayName,
                kind: .bluetoothSerial,
                host: normalizedAddress,
                bluetoothPeripheralID: peripheral,
                bluetoothServiceUUID: service,
                bluetoothWriteCharacteristicUUID: write,
                bluetoothNotifyCharacteristicUUID: notify
            )
        default:
            throw C05DeviceError(.invalidProfile, "unsupportedSavedConnectionKind")
        }
    }

    private func deviceProfile(from profile: RemoteHostProfile) -> C05DeviceProfile? {
        let connections: [C05DeviceConnection] = profile.auxiliaryConnections.compactMap { connection in
            switch connection.kind {
            case .tcp, .telnet:
                guard let host = connection.host, let port = connection.port else { return nil }
                return C05DeviceConnection(
                    id: connection.id,
                    displayName: connection.displayName,
                    kind: connection.kind.rawValue,
                    host: host,
                    port: port,
                    peripheralAddress: nil,
                    serviceUUID: nil,
                    writeUUID: nil,
                    notifyUUID: nil
                )
            case .bluetoothSerial:
                guard let address = bleAddress(for: connection) else { return nil }
                return C05DeviceConnection(
                    id: connection.id,
                    displayName: connection.displayName,
                    kind: connection.kind.rawValue,
                    host: nil,
                    port: nil,
                    peripheralAddress: address,
                    serviceUUID: connection.bluetoothServiceUUID,
                    writeUUID: connection.bluetoothWriteCharacteristicUUID,
                    notifyUUID: connection.bluetoothNotifyCharacteristicUUID
                )
            }
        }
        guard !connections.isEmpty else { return nil }
        return C05DeviceProfile(
            id: profile.id,
            displayName: profile.displayName,
            connections: connections
        )
    }

    private func bleAddress(for connection: RemoteAuxiliaryConnection) -> String? {
        if let host = connection.host, C05DeviceBLEAddress.isValid(host) {
            return C05DeviceBLEAddress.normalized(host)
        }
        guard let peripheral = connection.bluetoothPeripheralID else { return nil }
        return C05DeviceBLEAddress.mac(from: peripheral)
    }

    private func isValidHost(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= C05DeviceWire.maximumHostBytes else {
            return false
        }
        if value.contains(":") {
            return value.range(of: "^[0-9A-Fa-f:.%A-Za-z0-9_-]+$", options: .regularExpression) != nil
        }
        return value.range(
            of: "^[A-Za-z0-9_](?:[A-Za-z0-9_.-]{0,251}[A-Za-z0-9_])?$",
            options: .regularExpression
        ) != nil
    }
}

// MARK: - Model tool environment

public struct C05DeviceToolEnvironment: Sendable {
    public let mailbox: C05DeviceHostMailbox
    public let domain: C05DeviceDomain
    public let currentEpoch: @Sendable () -> UInt64?

    public init(
        mailbox: C05DeviceHostMailbox = .shared,
        domain: C05DeviceDomain = .shared,
        currentEpoch: @escaping @Sendable () -> UInt64? = {
            C05DeviceProductionWiring.readiness().epoch
        }
    ) {
        self.mailbox = mailbox
        self.domain = domain
        self.currentEpoch = currentEpoch
    }

    public static let production = C05DeviceToolEnvironment()

    public var isAvailable: Bool {
        guard let live = currentEpoch(), live != 0 else { return false }
        return mailbox.isBound && mailbox.boundEpoch == live
    }
}

private enum C05DeviceToolSupport {
    static func owner(
        _ context: ToolContext,
        environment: C05DeviceToolEnvironment
    ) throws -> C05DeviceOwner {
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed(
                "Device connections are unavailable in temporary chat; open a task to use them"
            )
        }
        guard let taskID = context.conversationID else {
            throw FloeError.validationFailed("Device connections require a task-owned run")
        }
        guard let live = environment.currentEpoch(), live != 0,
              environment.mailbox.isBound, environment.mailbox.boundEpoch == live else {
            throw FloeError.invalidConfiguration(
                "Device connections are unavailable for the current runtime generation"
            )
        }
        return C05DeviceOwner(
            token: "tool." + context.runID.uuidString,
            nativeEpoch: live,
            taskID: taskID,
            approvalGrantID: context.approvalGrantID,
            temporary: false
        )
    }

    static func request(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              data.count <= C05DeviceHostLimits.maximumRequestBytes else {
            throw FloeError.validationFailed("The device request is too large")
        }
        return data
    }

    static func submit(
        operation: String,
        request: Data,
        owner: C05DeviceOwner,
        requiresApproval: Bool,
        environment: C05DeviceToolEnvironment,
        context: ToolContext
    ) async throws -> [String: Any] {
        try context.cancellation.throwIfCancelled()
        if requiresApproval, context.approvalGrantID == nil {
            throw FloeError.validationFailed("This device action requires approval")
        }
        let data: Data
        do {
            data = try await environment.mailbox.submit(
                operation: operation,
                request: request,
                owner: owner,
                requiresApproval: requiresApproval,
                cancellation: context.cancellation
            )
        } catch let error as C05DeviceHostError {
            throw map(error)
        } catch {
            if context.cancellation.isCancelled { throw FloeError.cancelled }
            throw FloeError.internalError("Device operation failed")
        }
        try context.cancellation.throwIfCancelled()
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FloeError.internalError("The device host returned an invalid reply")
        }
        guard (raw["ok"] as? Bool) == true else {
            let code = boundedString(raw["code"]) ?? "internalFailure"
            throw mapRemote(code: code)
        }
        return raw
    }

    static func output(_ object: [String: Any]) throws -> ToolExecutionOutput {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return ToolExecutionOutput(digesting: "{\"status\":\"failed\"}", exitStatus: 1)
        }
        return ToolExecutionOutput(digesting: text, exitStatus: 0)
    }

    static func failure(_ error: Error) -> ToolExecutionOutput {
        let message: String
        if let error = error as? FloeError {
            message = error.localizedDescription
        } else if let error = error as? C05DeviceError {
            message = modelMessage(for: error.code)
        } else {
            message = "The device operation could not be completed"
        }
        return ToolExecutionOutput(
            digesting: "{\"status\":\"failed\",\"message\":\(jsonString(message))}",
            exitStatus: 1
        )
    }

    static func map(_ error: C05DeviceHostError) -> FloeError {
        switch error {
        case .hostUnbound, .hostClosed, .hostFenced:
            return .invalidConfiguration("Device connections are unavailable for this runtime generation")
        case .hostBudget:
            return .validationFailed("The device operation timed out")
        case .saturated:
            return .validationFailed("Too many device operations are already running; retry shortly")
        case .oversized:
            return .validationFailed("The device request exceeded its bounded size")
        case .cancelled:
            return .cancelled
        case .approvalRequired:
            return .validationFailed("This device action requires approval")
        case .remoteFailed(let code, _):
            return mapRemote(code: code)
        }
    }

    static func mapRemote(code: String) -> FloeError {
        switch code {
        case "cancelled": return .cancelled
        case "staleEpoch", "runtimeNotInstalled":
            return .invalidConfiguration("The device runtime restarted; retry")
        case "permissionRequired", "permissionDenied",
             "localNetworkPermissionRequired", "bluetoothDisabled":
            return .validationFailed(
                "Allow the required nearby/USB/local-network access in the App first; nothing was sent"
            )
        case "deviceNotFound", "sessionNotFound":
            return .notFound("The device or session is no longer available")
        case "sessionLimit":
            return .validationFailed("Close an active device session first")
        case "responseTooLarge":
            return .validationFailed("The device reply was too large; read a smaller amount")
        case "timedOut", "connectFailed", "connectionRefused", "hostNotFound", "ioFailed":
            return .validationFailed("The device operation failed; check the target and retry")
        case "invalidRequest", "invalidTarget", "invalidProfile":
            return .validationFailed("Check the device details and try again")
        case "unsupported":
            return .validationFailed("This device does not support that connection type")
        case "driverNotFound":
            return .validationFailed("No supported USB serial driver matched this device")
        case "operationBusy":
            return .validationFailed("Another device operation is still running; retry shortly")
        default:
            return .internalError("The device operation failed")
        }
    }

    static func modelMessage(for code: C05DeviceErrorCode) -> String {
        switch code {
        case .permissionRequired, .permissionDenied:
            return "Allow the required device access in the App first; nothing was sent"
        case .bluetoothDisabled:
            return "Turn on Bluetooth, then retry"
        case .localNetworkPermissionRequired:
            return "Allow local network access in the App first; nothing was sent"
        case .staleEpoch:
            return "The device runtime restarted; retry"
        case .cancelled:
            return "The device operation was cancelled"
        default:
            return "The device operation could not be completed"
        }
    }

    static func boundedString(_ value: Any?, max: Int = 200) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return String(text.prefix(max))
    }

    static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}

// MARK: - Model tools

public enum C05DeviceToolNames {
    public static let all = [
        "device.status",
        "device.open",
        "device.exchange",
        "device.close",
        "device.bleScan",
        "device.usbList",
    ]
}

public struct C05DeviceStatusTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var sessionID: String? }
    public static let name = "device.status"
    public static let toolDescription = "List this run's live TCP/Telnet/BLE/USB device sessions, or inspect one exact sessionID. Device bytes never cross this call; it reads metadata only."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string","maxLength":64}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let environment: C05DeviceToolEnvironment
    public init(environment: C05DeviceToolEnvironment = .production) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        if let id = args.sessionID, UUID(uuidString: id) == nil {
            throw FloeError.validationFailed("sessionID must be a UUID")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try validate(args)
            let owner = try C05DeviceToolSupport.owner(context, environment: environment)
            var request: [String: Any] = [:]
            if let id = args.sessionID { request["sessionID"] = id }
            let reply = try await C05DeviceToolSupport.submit(
                operation: "status",
                request: try C05DeviceToolSupport.request(request),
                owner: owner,
                requiresApproval: false,
                environment: environment,
                context: context
            )
            return try C05DeviceToolSupport.output(reply)
        } catch {
            return C05DeviceToolSupport.failure(error)
        }
    }
}

public struct C05DeviceOpenTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var kind: String
        public var hostID: String?
        public var connectionID: String?
        public var host: String?
        public var port: Int?
        public var address: String?
        public var serviceUUID: String?
        public var writeUUID: String?
        public var notifyUUID: String?
        public var readUUID: String?
        public var deviceName: String?
        public var portIndex: Int?
        public var baudRate: Int?
        public var dataBits: Int?
        public var stopBits: Int?
        public var parity: String?
    }
    public static let name = "device.open"
    public static let toolDescription = "Open a run-scoped real TCP, Telnet, BLE GATT or USB serial session. Use a saved hostID+connectionID from the saved connection list, or explicit kind+details the user supplied. Explicit details are temporary and never saved. Permissions must already be granted by the user; this tool never opens a permission dialog. Sessions close when idle for 30 minutes."
    public static let parametersJSON = #"{"type":"object","properties":{"kind":{"type":"string","enum":["tcp","telnet","ble","usb"]},"hostID":{"type":"string","format":"uuid"},"connectionID":{"type":"string","format":"uuid"},"host":{"type":"string","maxLength":253},"port":{"type":"integer","minimum":1,"maximum":65535},"address":{"type":"string","maxLength":17},"serviceUUID":{"type":"string","maxLength":64},"writeUUID":{"type":"string","maxLength":64},"notifyUUID":{"type":"string","maxLength":64},"readUUID":{"type":"string","maxLength":64},"deviceName":{"type":"string","maxLength":256},"portIndex":{"type":"integer","minimum":0,"maximum":15},"baudRate":{"type":"integer","minimum":50,"maximum":4000000},"dataBits":{"type":"integer","minimum":5,"maximum":8},"stopBits":{"type":"integer","minimum":1,"maximum":2},"parity":{"type":"string","enum":["none","odd","even","mark","space"]}},"required":["kind"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let environment: C05DeviceToolEnvironment
    public init(environment: C05DeviceToolEnvironment = .production) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard ["tcp", "telnet", "ble", "usb"].contains(args.kind) else {
            throw FloeError.validationFailed("Unsupported device kind")
        }
        let saved = args.hostID != nil || args.connectionID != nil
        if saved {
            guard args.hostID.flatMap(UUID.init(uuidString:)) != nil,
                  args.connectionID.flatMap(UUID.init(uuidString:)) != nil else {
                throw FloeError.validationFailed("Saved device use requires UUID hostID and connectionID")
            }
            return
        }
        switch args.kind {
        case "tcp", "telnet":
            guard args.host?.isEmpty == false, let port = args.port, (1...65_535).contains(port) else {
                throw FloeError.validationFailed("TCP/Telnet needs a host and port")
            }
        case "ble":
            guard args.address?.isEmpty == false,
                  args.serviceUUID?.isEmpty == false,
                  args.writeUUID?.isEmpty == false else {
                throw FloeError.validationFailed("BLE needs address, service and write characteristic")
            }
        case "usb":
            guard args.deviceName?.isEmpty == false else {
                throw FloeError.validationFailed("USB serial needs an attached deviceName")
            }
        default:
            throw FloeError.validationFailed("Unsupported device kind")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try validate(args)
            let owner = try C05DeviceToolSupport.owner(context, environment: environment)
            let request = try await resolvedRequest(args, owner: owner)
            let reply = try await C05DeviceToolSupport.submit(
                operation: "open",
                request: try C05DeviceToolSupport.request(request),
                owner: owner,
                requiresApproval: true,
                environment: environment,
                context: context
            )
            return try C05DeviceToolSupport.output(reply)
        } catch {
            return C05DeviceToolSupport.failure(error)
        }
    }

    private func resolvedRequest(
        _ args: Arguments,
        owner: C05DeviceOwner
    ) async throws -> [String: Any] {
        if let hostID = args.hostID.flatMap(UUID.init(uuidString:)),
           let connectionID = args.connectionID.flatMap(UUID.init(uuidString:)) {
            let resolved = try await environment.domain.resolveConnection(
                hostID: hostID,
                connectionID: connectionID,
                owner: owner
            )
            switch resolved.kind {
            case "tcp", "telnet":
                return [
                    "kind": resolved.kind,
                    "host": resolved.host ?? "",
                    "port": resolved.port ?? 0,
                ]
            case "bluetoothSerial":
                var request: [String: Any] = [
                    "kind": "ble",
                    "address": resolved.peripheralAddress ?? "",
                    "serviceUUID": resolved.serviceUUID ?? "",
                    "writeUUID": resolved.writeUUID ?? "",
                ]
                if let notify = resolved.notifyUUID { request["notifyUUID"] = notify }
                return request
            default:
                throw FloeError.validationFailed("Unsupported saved device connection")
            }
        }
        switch args.kind {
        case "tcp", "telnet":
            return ["kind": args.kind, "host": args.host ?? "", "port": args.port ?? 0]
        case "ble":
            var request: [String: Any] = [
                "kind": "ble",
                "address": args.address ?? "",
                "serviceUUID": args.serviceUUID ?? "",
                "writeUUID": args.writeUUID ?? "",
            ]
            if let notify = args.notifyUUID, !notify.isEmpty { request["notifyUUID"] = notify }
            if let read = args.readUUID, !read.isEmpty { request["readUUID"] = read }
            return request
        case "usb":
            var request: [String: Any] = [
                "kind": "usb",
                "deviceName": args.deviceName ?? "",
            ]
            if let portIndex = args.portIndex { request["portIndex"] = portIndex }
            if let baud = args.baudRate { request["baudRate"] = baud }
            if let bits = args.dataBits { request["dataBits"] = bits }
            if let stop = args.stopBits { request["stopBits"] = stop }
            if let parity = args.parity { request["parity"] = parity }
            return request
        default:
            throw FloeError.validationFailed("Unsupported device kind")
        }
    }
}

public struct C05DeviceExchangeTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var sessionID: String
        public var text: String?
        public var base64: String?
        public var appendNewline: Bool?
        public var waitSeconds: Double?
        public var maxOutputBytes: Int?
    }
    public static let name = "device.exchange"
    public static let toolDescription = "Send text or base64 bytes to one of this run's device sessions and read a bounded reply. Omit both payloads to read pending data. The device reply is text when it is valid UTF-8, otherwise base64. BLE/USB binary bodies stay bounded; no shell or interpreter is involved."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string","maxLength":64},"text":{"type":"string","maxLength":32768},"base64":{"type":"string","maxLength":43692},"appendNewline":{"type":"boolean"},"waitSeconds":{"type":"number","minimum":0,"maximum":30},"maxOutputBytes":{"type":"integer","minimum":1,"maximum":24576}},"required":["sessionID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .executesRemoteCommand]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let environment: C05DeviceToolEnvironment
    public init(environment: C05DeviceToolEnvironment = .production) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.sessionID) != nil else {
            throw FloeError.validationFailed("sessionID must be a UUID")
        }
        guard !(args.text != nil && args.base64 != nil) else {
            throw FloeError.validationFailed("Use text or base64, not both")
        }
        if let base64 = args.base64, Data(base64Encoded: base64) == nil {
            throw FloeError.validationFailed("base64 is invalid")
        }
        if let text = args.text, text.utf8.count > 32 * 1_024 {
            throw FloeError.validationFailed("Device text is too long")
        }
        if let max = args.maxOutputBytes, !(1...24_576).contains(max) {
            throw FloeError.validationFailed("maxOutputBytes is out of range")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try validate(args)
            let owner = try C05DeviceToolSupport.owner(context, environment: environment)
            var request: [String: Any] = ["sessionID": args.sessionID]
            if let text = args.text { request["text"] = text }
            if let base64 = args.base64 { request["base64"] = base64 }
            if args.appendNewline == true { request["appendNewline"] = true }
            if let wait = args.waitSeconds {
                request["waitMillis"] = Int(min(max(wait, 0), 30) * 1_000)
            }
            if let max = args.maxOutputBytes { request["maxBytes"] = max }
            let reply = try await C05DeviceToolSupport.submit(
                operation: "exchange",
                request: try C05DeviceToolSupport.request(request),
                owner: owner,
                requiresApproval: true,
                environment: environment,
                context: context
            )
            return try C05DeviceToolSupport.output(reply)
        } catch {
            return C05DeviceToolSupport.failure(error)
        }
    }
}

public struct C05DeviceCloseTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var sessionID: String }
    public static let name = "device.close"
    public static let toolDescription = "Close one device session opened by this run. The engine closes the socket/GATT connection/USB port and reports whether every owned resource really closed."
    public static let parametersJSON = #"{"type":"object","properties":{"sessionID":{"type":"string","maxLength":64}},"required":["sessionID"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating
    public static let requiresHostScope = false

    private let environment: C05DeviceToolEnvironment
    public init(environment: C05DeviceToolEnvironment = .production) { self.environment = environment }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.sessionID) != nil else {
            throw FloeError.validationFailed("sessionID must be a UUID")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            try validate(args)
            let owner = try C05DeviceToolSupport.owner(context, environment: environment)
            let reply = try await C05DeviceToolSupport.submit(
                operation: "close",
                request: try C05DeviceToolSupport.request(["sessionID": args.sessionID]),
                owner: owner,
                requiresApproval: true,
                environment: environment,
                context: context
            )
            return try C05DeviceToolSupport.output(reply)
        } catch {
            return C05DeviceToolSupport.failure(error)
        }
    }
}

public struct C05DeviceBleScanTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var durationSeconds: Double? }
    public static let name = "device.bleScan"
    public static let toolDescription = "Scan nearby Bluetooth Low Energy peripherals for a serial-style GATT connection and return bounded address/name/RSSI results. It does not pair, save, connect or ask for permission; Nearby devices access must already be granted."
    public static let parametersJSON = #"{"type":"object","properties":{"durationSeconds":{"type":"number","minimum":1,"maximum":15}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let environment: C05DeviceToolEnvironment
    public init(environment: C05DeviceToolEnvironment = .production) { self.environment = environment }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            let owner = try C05DeviceToolSupport.owner(context, environment: environment)
            let millis = Int(min(max(args.durationSeconds ?? 5, 1), 15) * 1_000)
            let reply = try await C05DeviceToolSupport.submit(
                operation: "bleScan",
                request: try C05DeviceToolSupport.request(["durationMillis": millis]),
                owner: owner,
                requiresApproval: false,
                environment: environment,
                context: context
            )
            return try C05DeviceToolSupport.output(reply)
        } catch {
            return C05DeviceToolSupport.failure(error)
        }
    }
}

public struct C05DeviceUsbListTool: AgentTool {
    public struct Arguments: Decodable, Sendable {}
    public static let name = "device.usbList"
    public static let toolDescription = "List attached USB serial devices with driver and permission state. It never requests USB permission; the user must allow the exact device in the App. No device is opened."
    public static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let requiresHostScope = false

    private let environment: C05DeviceToolEnvironment
    public init(environment: C05DeviceToolEnvironment = .production) { self.environment = environment }

    public func validate(_ args: Arguments) throws {}

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        do {
            let owner = try C05DeviceToolSupport.owner(context, environment: environment)
            let reply = try await C05DeviceToolSupport.submit(
                operation: "usbList",
                request: try C05DeviceToolSupport.request([:]),
                owner: owner,
                requiresApproval: false,
                environment: environment,
                context: context
            )
            return try C05DeviceToolSupport.output(reply)
        } catch {
            return C05DeviceToolSupport.failure(error)
        }
    }
}

public func registerC05DeviceTools(
    environment: C05DeviceToolEnvironment = .production,
    registry: ToolRunnerRegistry = .shared
) {
    func add<T: AgentTool>(_ tool: T) {
        ToolCatalog.register(T.self)
        registry.register(AnyAgentTool(tool).withAvailability {
            environment.isAvailable
        })
    }
    add(C05DeviceStatusTool(environment: environment))
    add(C05DeviceOpenTool(environment: environment))
    add(C05DeviceExchangeTool(environment: environment))
    add(C05DeviceCloseTool(environment: environment))
    add(C05DeviceBleScanTool(environment: environment))
    add(C05DeviceUsbListTool(environment: environment))
}

public func unregisterC05DeviceTools(registry: ToolRunnerRegistry = .shared) {
    registry.unregister { C05DeviceToolNames.all.contains($0) }
}

// MARK: - Tool composition

public final class C05DeviceToolComposition: @unchecked Sendable {
    public static let shared = C05DeviceToolComposition()

    private let lock = NSLock()
    private var installed = false
    private let environment = C05DeviceToolEnvironment.production

    private init() {}

    public var isInstalled: Bool {
        lock.lock(); defer { lock.unlock() }; return installed
    }

    public func installIfNeeded() {
        lock.lock()
        guard !installed else { lock.unlock(); return }
        installed = true
        lock.unlock()
        registerC05DeviceTools(environment: environment)
    }

    public func uninstall() {
        lock.lock()
        guard installed else { lock.unlock(); return }
        installed = false
        lock.unlock()
        unregisterC05DeviceTools()
    }

    public func readinessJSON() -> String {
        let visible = C05DeviceToolNames.all.filter {
            ToolRunnerRegistry.shared.descriptor(named: $0) != nil
        }
        let object: [String: Any] = [
            "version": 1,
            "tool": "device",
            "installed": isInstalled,
            "bound": environment.mailbox.isBound,
            "epoch": environment.mailbox.boundEpoch,
            "available": environment.isAvailable,
            "toolCount": visible.count,
            "registered": visible,
            "expected": C05DeviceToolNames.all,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"readiness\"}"
        }
        return text
    }
}
