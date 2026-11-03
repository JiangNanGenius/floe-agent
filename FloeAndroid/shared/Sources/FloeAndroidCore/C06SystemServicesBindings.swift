// SPDX-License-Identifier: MPL-2.0
//
// C06 host bridge `floe.system/15`, the trusted App platform mailbox and the
// four ordinary system-service model tools.
//
// Two directions are deliberately separate:
//
//   * Kotlin -> Swift (`SwiftCore.exchange`, schema floe.system/15): the App
//     controller pushes the ACTUAL permission/provider/foreground state and
//     reads the closed capability projection.
//   * Swift -> Kotlin (`C06SystemHostMailbox`): a claimed JSON ticket table
//     implemented over an additive JNI translation unit. The App lane is the
//     only code that touches LocationManager, ContactsContract, the NFC
//     adapter or Health Connect; every ticket carries bounded JSON, no Intent,
//     no provider URI, no raw path and no model-chosen command.
//
// Neither direction is a V3 command, an approval bypass or a guest execution
// route.
import Foundation
import FloeCore
import FloeTools

public enum BridgeV15 {
    public static let version = C06SystemWire.version
    public static let schema = C06SystemWire.schema
    public static let maximumRequestBytes = C06SystemWire.maximumRequestBytes
    public static let maximumResponseBytes = C06SystemWire.maximumResponseBytes
    public static let modelTools = C06SystemWire.modelTools
    public static let operations: [String] = [
        "handshake",
        "c06.capabilities",
        "c06.system.availability",
        "c06.system.status",
    ]
}

// MARK: - Registration

public struct C06SystemToolEnvironment: Sendable {
    public let domain: C06SystemServicesDomain
    public init(domain: C06SystemServicesDomain = .shared) {
        self.domain = domain
    }
}

public func registerC06SystemServicesTools(
    environment: C06SystemToolEnvironment = C06SystemToolEnvironment(),
    registry: ToolRunnerRegistry = .shared
) {
    ToolCatalog.register(C06LocationCurrentTool.self)
    registry.register(AnyAgentTool(C06LocationCurrentTool(domain: environment.domain)).withAvailability {
        C06SystemServicesDomain.availability.snapshot.locationAvailable
    })
    ToolCatalog.register(C06ContactsListTool.self)
    registry.register(AnyAgentTool(C06ContactsListTool(domain: environment.domain)).withAvailability {
        C06SystemServicesDomain.availability.snapshot.contactsAvailable
    })
    ToolCatalog.register(C06NFCReadTool.self)
    registry.register(AnyAgentTool(C06NFCReadTool(domain: environment.domain)).withAvailability {
        let snapshot = C06SystemServicesDomain.availability.snapshot
        return snapshot.coreReady && snapshot.nfc.hardwareAvailable
    })
    ToolCatalog.register(C06HealthReadTool.self)
    registry.register(AnyAgentTool(C06HealthReadTool(domain: environment.domain)).withAvailability {
        C06SystemServicesDomain.availability.snapshot.healthAvailable
    })
}

public func unregisterC06SystemServicesTools(registry: ToolRunnerRegistry = .shared) {
    registry.unregister { C06SystemWire.modelToolNames.contains($0) }
}

// MARK: - Host mailbox status

public enum C06SystemHostStatus {
    public static let ok: Int32 = 0
    public static let staleClaim: Int32 = -101
    public static let generationFenced: Int32 = -102
    public static let shape: Int32 = -105
    public static let oversized: Int32 = -107
    public static let cancelled: Int32 = -109
    public static let notClaimed: Int32 = -110
}

private func c06SysCopyString(
    _ value: String,
    into buffer: UnsafeMutablePointer<CChar>?,
    capacity: Int32
) -> Int32 {
    guard let buffer, capacity > 0 else { return -1 }
    let bytes = Array(value.utf8)
    guard bytes.count < Int(capacity) else { return Int32(bytes.count + 1) }
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

// MARK: - Mailbox

/// Bounded JSON ticket table for Swift -> App system-service operations. One
/// ticket is one closed operation; Kotlin claims it, performs the real
/// platform call and completes it exactly once.
public final class C06SystemHostMailbox: @unchecked Sendable {
    public static let shared = C06SystemHostMailbox()

    public static let maximumTicketBytes = 16 * 1024
    public static let maximumReplyBytes = 48 * 1024

    private final class Ticket {
        let claim: Int64
        let request: Data
        let deadline: Date
        var claimed = false
        var settled = false
        var status: Int32 = 0
        var result = Data()
        init(claim: Int64, request: Data, deadline: Date) {
            self.claim = claim
            self.request = request
            self.deadline = deadline
        }
    }

    private struct Counters {
        var submitted = 0
        var claimed = 0
        var completed = 0
        var failed = 0
        var rejects = 0
        var timeouts = 0
        var disarms = 0
    }

    private let condition = NSCondition()
    private var boundEpoch: UInt64 = 0
    private var bound = false
    private var laneReadyFlag = false
    private var closed = true
    private var tickets: [Int64: Ticket] = [:]
    private var queue: [Int64] = []
    private var nextClaim: Int64 = 1
    private var counters = Counters()

    public init() {}

    public func bind(epoch: UInt64) -> Int32 {
        guard epoch > 0 else { return -1 }
        condition.lock(); defer { condition.unlock() }
        if bound, boundEpoch != epoch {
            // A retired generation may only be replaced after its App lane
            // has acknowledged closure; a live lane never loses its tickets.
            guard !laneReadyFlag else { return -2 }
            tickets.removeAll()
            queue.removeAll()
        }
        boundEpoch = epoch
        bound = true
        laneReadyFlag = false
        closed = false
        return 0
    }

    public func laneReady(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard bound, boundEpoch == epoch else { return -2 }
        laneReadyFlag = true
        condition.broadcast()
        return 0
    }

    public func laneClosed(epoch: UInt64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard boundEpoch == epoch else { return -2 }
        laneReadyFlag = false
        condition.broadcast()
        return 0
    }

    public func closeAll(timeoutMillis: Int32) -> Int32 {
        condition.lock()
        closed = true
        laneReadyFlag = false
        let pending = queue
        queue.removeAll()
        for claim in pending {
            if let ticket = tickets[claim], !ticket.settled {
                ticket.settled = true
                ticket.status = C06SystemHostStatus.cancelled
                counters.failed += 1
            }
        }
        condition.broadcast()
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutMillis)) / 1_000)
        while tickets.values.contains(where: { !$0.settled }) {
            if !condition.wait(until: deadline) { break }
        }
        let unsettled = tickets.values.contains(where: { !$0.settled })
        condition.unlock()
        return unsettled ? -1 : 0
    }

    public func nextClaim(timeoutMillis: Int32) -> Int64 {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(TimeInterval(max(25, timeoutMillis)) / 1_000)
        while queue.isEmpty {
            if closed { return -1 }
            if !condition.wait(until: deadline) { return 0 }
        }
        let claim = queue.removeFirst()
        guard let ticket = tickets[claim], !ticket.settled else {
            return 0
        }
        ticket.claimed = true
        counters.claimed += 1
        return claim
    }

    public func describe(claim: Int64) -> Data? {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim], ticket.claimed, !ticket.settled else { return nil }
        return ticket.request
    }

    public func complete(claim: Int64, status: Int32, data: Data?) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim] else { return C06SystemHostStatus.notClaimed }
        guard ticket.claimed, !ticket.settled else { return C06SystemHostStatus.staleClaim }
        if let data, data.count > C06SystemHostMailbox.maximumReplyBytes {
            counters.rejects += 1
            return C06SystemHostStatus.oversized
        }
        ticket.status = status
        ticket.result = data ?? Data()
        ticket.settled = true
        if status == C06SystemHostStatus.ok {
            counters.completed += 1
        } else if status == C06SystemHostStatus.cancelled {
            counters.failed += 1
        } else {
            counters.failed += 1
        }
        tickets.removeValue(forKey: claim)
        condition.broadcast()
        return 0
    }

    public func shouldStop(claim: Int64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard let ticket = tickets[claim] else { return true }
        return closed || ticket.settled || ticket.deadline < Date()
    }

    public func submit(
        operation: String,
        owner: C06SystemOwner,
        payload: [String: Any],
        timeout: TimeInterval
    ) throws -> [String: Any] {
        var request: [String: Any] = [
            "operation": operation,
            "claimEpoch": owner.nativeEpoch,
            "owner": owner.toJSON(),
        ]
        for (key, value) in payload { request[key] = value }
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) else {
            throw C06SystemError(.internalFailure, "ticketEncodingFailed")
        }
        guard data.count <= C06SystemHostMailbox.maximumTicketBytes else {
            throw C06SystemError(.invalidRequest, "ticketTooLarge")
        }

        condition.lock()
        guard bound, boundEpoch == owner.nativeEpoch else {
            condition.unlock()
            throw C06SystemError(.staleEpoch, "staleNativeEpoch")
        }
        guard laneReadyFlag, !closed else {
            condition.unlock()
            throw C06SystemError(.hostUnavailable, "systemHostLaneUnavailable", retryable: true)
        }
        let claim = nextClaim
        nextClaim += 1
        let deadline = Date().addingTimeInterval(max(1, min(timeout, 90)) + 5)
        let ticket = Ticket(claim: claim, request: data, deadline: deadline)
        tickets[claim] = ticket
        queue.append(claim)
        counters.submitted += 1
        condition.broadcast()
        let waitUntil = deadline
        while !ticket.settled {
            if !condition.wait(until: waitUntil) { break }
        }
        if !ticket.settled {
            ticket.settled = true
            tickets.removeValue(forKey: claim)
            queue.removeAll { $0 == claim }
            counters.timeouts += 1
            condition.unlock()
            throw C06SystemError(.timedOut, "systemHostTimedOut", retryable: true)
        }
        let status = ticket.status
        let result = ticket.result
        condition.unlock()

        guard status == C06SystemHostStatus.ok else {
            switch status {
            case C06SystemHostStatus.generationFenced:
                throw C06SystemError(.staleEpoch, "staleNativeEpoch")
            case C06SystemHostStatus.oversized:
                throw C06SystemError(.responseTooLarge, "providerReplyTooLarge")
            case C06SystemHostStatus.shape:
                throw C06SystemError(.invalidHostReply, "invalidHostRequestShape")
            case C06SystemHostStatus.cancelled:
                throw C06SystemError(.cancelled, "systemHostCancelled")
            default:
                throw C06SystemError(.internalFailure, "systemHostStatus")
            }
        }
        guard !result.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] else {
            throw C06SystemError(.internalFailure, "invalidHostReply")
        }
        if let ok = object["ok"] as? Bool, ok == false {
            throw c06SystemError(from: object)
        }
        return object
    }

    public func descriptor() -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        return [
            "bound": bound,
            "epoch": NSNumber(value: boundEpoch),
            "laneReady": laneReadyFlag,
            "closed": closed,
            "pending": queue.count,
            "submitted": counters.submitted,
            "claimed": counters.claimed,
            "completed": counters.completed,
            "failed": counters.failed,
            "rejects": counters.rejects,
            "timeouts": counters.timeouts,
        ]
    }
}

private func c06SystemError(from object: [String: Any]) -> C06SystemError {
    let raw = (object["code"] as? String) ?? "internalFailure"
    let code = C06SystemErrorCode(rawValue: raw) ?? .internalFailure
    let reason = (object["reason"] as? String) ?? code.rawValue
    let retryable = (object["retryable"] as? Bool) ?? false
    let detail = object["detail"] as? String
    return C06SystemError(code, reason, retryable: retryable, detail: detail)
}

// MARK: - Mailbox port

public struct C06SystemHostMailboxPort: C06SystemPlatformPort {
    private let mailbox: C06SystemHostMailbox

    public init(mailbox: C06SystemHostMailbox = .shared) {
        self.mailbox = mailbox
    }

    public func locationFix(owner: C06SystemOwner, timeout: TimeInterval) async throws -> C06LocationFix {
        let reply = try mailbox.submit(
            operation: "location.fix",
            owner: owner,
            payload: [:],
            timeout: timeout + 5
        )
        guard let latitude = c06SysDouble(reply["latitude"]),
              let longitude = c06SysDouble(reply["longitude"]),
              let accuracy = c06SysDouble(reply["accuracyMeters"]),
              let timestampRaw = c06SysString(reply["timestamp"]),
              let precise = reply["precise"] as? Bool else {
            throw C06SystemError(.invalidHostReply, "invalidLocationReply")
        }
        let timestamp = try C06SystemText.parseISO8601(timestampRaw)
        return C06LocationFix(
            latitude: latitude,
            longitude: longitude,
            accuracyMeters: accuracy,
            timestamp: timestamp,
            precise: precise,
            provider: c06SysString(reply["provider"]) ?? "unknown"
        )
    }

    public func contactsScan(
        owner: C06SystemOwner,
        query: String?,
        field: C06ContactField,
        scanToken: String?,
        offset: Int,
        limit: Int
    ) async throws -> C06ContactScanPage {
        var payload: [String: Any] = [
            "field": field.rawValue,
            "offset": offset,
            "limit": limit,
        ]
        if let query { payload["query"] = query }
        if let scanToken { payload["scanToken"] = scanToken }
        let reply = try mailbox.submit(
            operation: "contacts.scan",
            owner: owner,
            payload: payload,
            timeout: 25
        )
        guard let token = c06SysString(reply["scanToken"]),
              let rawRows = reply["rows"] as? [[String: Any]],
              let totalCount = c06SysInt(reply["totalCount"]),
              let truncated = reply["truncated"] as? Bool else {
            throw C06SystemError(.invalidHostReply, "invalidContactsReply")
        }
        let rows = try rawRows.map { value -> C06ContactRecord in
            guard let id = c06SysString(value["id"]),
                  let name = c06SysString(value["displayName"]) else {
                throw C06SystemError(.invalidHostReply, "invalidContactRow")
            }
            return C06ContactRecord(
                id: id,
                displayName: name,
                organization: c06SysString(value["organization"]) ?? "",
                phones: value["phones"] as? [String] ?? [],
                emails: value["emails"] as? [String] ?? []
            )
        }
        let nextOffset = c06SysInt(reply["nextOffset"])
        return C06ContactScanPage(
            scanToken: token,
            rows: rows,
            totalCount: totalCount,
            truncated: truncated,
            nextOffset: nextOffset
        )
    }

    public func nfcRead(owner: C06SystemOwner, timeout: TimeInterval) async throws -> C06NFCReadResult {
        let reply = try mailbox.submit(
            operation: "nfc.read",
            owner: owner,
            payload: ["timeoutSeconds": Int(timeout.rounded())],
            timeout: timeout + 10
        )
        let rawRecords = reply["records"] as? [[String: Any]] ?? []
        let records = rawRecords.map { value -> C06NFCRecord in
            C06NFCRecord(
                index: c06SysInt(value["index"]) ?? 0,
                tnf: c06SysInt(value["tnf"]) ?? 0,
                typeText: c06SysString(value["type"]) ?? "",
                identifier: c06SysString(value["id"]) ?? "",
                kind: c06SysString(value["kind"]) ?? "unknown",
                value: c06SysString(value["value"]),
                payloadBytes: c06SysInt(value["payloadBytes"]) ?? 0,
                payloadSHA256Prefix: c06SysString(value["payloadSHA256"]) ?? "",
                truncated: (value["truncated"] as? Bool) ?? false
            )
        }
        return C06NFCReadResult(
            records: records,
            rawBytes: c06SysInt(reply["rawBytes"]) ?? 0,
            writable: (reply["writable"] as? Bool) ?? false,
            techList: reply["techList"] as? [String] ?? [],
            truncated: (reply["truncated"] as? Bool) ?? false,
            elapsedMilliseconds: c06SysInt(reply["elapsedMs"]) ?? 0
        )
    }

    public func healthSamples(
        owner: C06SystemOwner,
        metric: C06HealthMetric,
        start: Date,
        end: Date,
        limit: Int,
        pageToken: String?
    ) async throws -> C06HealthPage {
        var payload: [String: Any] = [
            "metric": metric.rawValue,
            "start": C06SystemText.iso8601(start),
            "end": C06SystemText.iso8601(end),
            "limit": limit,
        ]
        if let pageToken { payload["pageToken"] = pageToken }
        let reply = try mailbox.submit(
            operation: "health.samples",
            owner: owner,
            payload: payload,
            timeout: 30
        )
        guard let rawRows = reply["rows"] as? [[String: Any]] else {
            throw C06SystemError(.invalidHostReply, "invalidHealthReply")
        }
        let rows = try rawRows.map { value -> C06HealthSampleRow in
            guard let rowMetric = c06SysString(value["metric"]),
                  let startRaw = c06SysString(value["start"]),
                  let endRaw = c06SysString(value["end"]) else {
                throw C06SystemError(.invalidHostReply, "invalidHealthRow")
            }
            return C06HealthSampleRow(
                metric: rowMetric,
                start: try C06SystemText.parseISO8601(startRaw),
                end: try C06SystemText.parseISO8601(endRaw),
                value: c06SysDouble(value["value"]),
                unit: c06SysString(value["unit"]) ?? metric.unit,
                detail: c06SysString(value["detail"])
            )
        }
        return C06HealthPage(
            rows: rows,
            nextPageToken: c06SysString(reply["nextPageToken"]),
            totalScanned: c06SysInt(reply["totalScanned"]) ?? rows.count,
            truncated: (reply["truncated"] as? Bool) ?? false
        )
    }

    public func healthAggregate(
        owner: C06SystemOwner,
        metric: C06HealthMetric,
        aggregation: C06HealthAggregation,
        start: Date,
        end: Date
    ) async throws -> C06HealthAggregateResult {
        let reply = try mailbox.submit(
            operation: "health.aggregate",
            owner: owner,
            payload: [
                "metric": metric.rawValue,
                "aggregation": aggregation.rawValue,
                "start": C06SystemText.iso8601(start),
                "end": C06SystemText.iso8601(end),
            ],
            timeout: 30
        )
        guard let replyMetric = c06SysString(reply["metric"]),
              let replyAggregation = c06SysString(reply["aggregation"]) else {
            throw C06SystemError(.invalidHostReply, "invalidHealthAggregate")
        }
        return C06HealthAggregateResult(
            metric: replyMetric,
            aggregation: replyAggregation,
            value: c06SysDouble(reply["value"]),
            unit: c06SysString(reply["unit"]) ?? metric.unit,
            recordCount: c06SysInt(reply["recordCount"]) ?? 0,
            start: start,
            end: end,
            detail: c06SysString(reply["detail"])
        )
    }
}

private func c06SysString(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    return value
}

private func c06SysDouble(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) }
    return nil
}

private func c06SysInt(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

// MARK: - Bridge

public enum C06SystemBridge {
    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func fail(_ error: C06SystemError, operation: String?) -> [String: Any] {
            var value = failure(error, operation: operation)
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C06SystemWire.maximumRequestBytes else {
            return fail(C06SystemError(.invalidRequest, "requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = c06SysInt(object["version"]),
              version == BridgeV15.version,
              let operation = c06SysString(object["operation"]) else {
            return fail(C06SystemError(.invalidRequest, "invalidRequest"), operation: nil)
        }
        requestID = c06SysString(object["requestID"]) ?? requestID

        do {
            switch operation {
            case "handshake", "c06.capabilities":
                return reply(capabilitiesJSON(), operation: operation, requestID: requestID)
            case "c06.system.availability":
                return reply(try handleAvailability(object), operation: operation, requestID: requestID)
            case "c06.system.status":
                return reply(statusJSON(), operation: operation, requestID: requestID)
            default:
                throw C06SystemError(.unsupportedOperation, "unsupportedOperation")
            }
        } catch let error as C06SystemError {
            return fail(error, operation: operation)
        } catch {
            return fail(C06SystemError(.internalFailure, "systemBridgeFailed"), operation: operation)
        }
    }

    private static func capabilitiesJSON() -> [String: Any] {
        [
            "ok": true,
            "schema": C06SystemWire.schema,
            "version": BridgeV15.version,
            "capabilities": statusJSON(),
            "limits": [
                "maximumContactScan": C06SystemWire.maximumContactScan,
                "maximumContactLimit": C06SystemWire.maximumContactLimit,
                "maximumHealthDays": C06SystemWire.maximumHealthDays,
                "maximumHealthLimit": C06SystemWire.maximumHealthLimit,
                "maximumNFCRecords": C06SystemWire.maximumNFCRecords,
                "maximumNFCBytes": C06SystemWire.maximumNFCBytes,
                "minimumNFCTimeoutSeconds": C06SystemWire.minimumNFCTimeoutSeconds,
                "maximumNFCTimeoutSeconds": C06SystemWire.maximumNFCTimeoutSeconds,
                "locationTimeoutSeconds": C06SystemWire.locationTimeoutSeconds,
            ],
            "modelTools": C06SystemWire.modelTools,
            "modelToolNames": C06SystemWire.modelToolNames,
        ]
    }

    private static func statusJSON() -> [String: Any] {
        let snapshot = C06SystemServicesDomain.availability.snapshot
        return [
            "coreReady": snapshot.coreReady,
            "foreground": snapshot.foreground,
            "revision": snapshot.revision,
            "epoch": snapshot.epoch.map { NSNumber(value: $0) } ?? NSNull(),
            "location": [
                "hardwareAvailable": snapshot.location.hardwareAvailable,
                "servicesEnabled": snapshot.location.servicesEnabled,
                "permission": snapshot.location.permission.rawValue,
                "precise": snapshot.location.precise,
                "available": snapshot.locationAvailable,
            ],
            "contacts": [
                "providerAvailable": snapshot.contacts.providerAvailable,
                "permission": snapshot.contacts.permission.rawValue,
                "available": snapshot.contactsAvailable,
            ],
            "nfc": [
                "hardwareAvailable": snapshot.nfc.hardwareAvailable,
                "enabled": snapshot.nfc.enabled,
                "available": snapshot.nfcAvailable,
            ],
            "health": [
                "providerStatus": snapshot.health.providerStatus.rawValue,
                "grantedMetrics": Array(snapshot.health.grantedMetrics).sorted(),
                "available": snapshot.healthAvailable,
            ],
        ]
    }

    private static func handleAvailability(_ object: [String: Any]) throws -> [String: Any] {
        guard let owner = try? C06SystemOwner.parse(object["owner"]),
              let revision = c06SysInt64(object["revision"]),
              let foreground = object["foreground"] as? Bool,
              let location = object["location"] as? [String: Any],
              let contacts = object["contacts"] as? [String: Any],
              let nfc = object["nfc"] as? [String: Any],
              let health = object["health"] as? [String: Any] else {
            throw C06SystemError(.invalidRequest, "invalidAvailability")
        }
        guard let locationPermission = c06SysString(location["permission"]).flatMap(C06SystemPermission.init(rawValue:)),
              let contactsPermission = c06SysString(contacts["permission"]).flatMap(C06SystemPermission.init(rawValue:)),
              let providerStatus = c06SysString(health["providerStatus"]).flatMap(C06HealthProviderStatus.init(rawValue:)) else {
            throw C06SystemError(.invalidRequest, "invalidAvailabilityState")
        }
        let granted = Set((health["grantedMetrics"] as? [String]) ?? [])
        let snapshot = C06SystemAvailabilitySnapshot(
            coreReady: true,
            foreground: foreground,
            revision: revision,
            epoch: owner.nativeEpoch,
            location: C06LocationAvailability(
                hardwareAvailable: (location["hardwareAvailable"] as? Bool) ?? false,
                servicesEnabled: (location["servicesEnabled"] as? Bool) ?? false,
                permission: locationPermission,
                precise: (location["precise"] as? Bool) ?? false
            ),
            contacts: C06ContactsAvailability(
                providerAvailable: (contacts["providerAvailable"] as? Bool) ?? false,
                permission: contactsPermission
            ),
            nfc: C06NFCAvailability(
                hardwareAvailable: (nfc["hardwareAvailable"] as? Bool) ?? false,
                enabled: (nfc["enabled"] as? Bool) ?? false
            ),
            health: C06HealthAvailability(
                providerStatus: providerStatus,
                grantedMetrics: granted
            )
        )
        C06SystemServicesDomain.availability.update(snapshot, epoch: owner.nativeEpoch)
        return [
            "ok": true,
            "schema": C06SystemWire.schema,
            "revision": revision,
            "locationAvailable": C06SystemServicesDomain.availability.snapshot.locationAvailable,
            "contactsAvailable": C06SystemServicesDomain.availability.snapshot.contactsAvailable,
            "nfcAvailable": C06SystemServicesDomain.availability.snapshot.nfcAvailable,
            "healthAvailable": C06SystemServicesDomain.availability.snapshot.healthAvailable,
        ]
    }

    private static func reply(_ value: [String: Any], operation: String,
                              requestID: String?) -> [String: Any] {
        var object = value
        object["ok"] = object["ok"] ?? true
        object["operation"] = operation
        object["schema"] = C06SystemWire.schema
        if let requestID { object["requestID"] = requestID }
        guard JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              encoded.count <= C06SystemWire.maximumResponseBytes else {
            return failure(C06SystemError(.responseTooLarge, "responseTooLarge"), operation: operation)
        }
        return object
    }

    private static func failure(_ error: C06SystemError, operation: String?) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": error.code.rawValue,
            "reason": error.reason,
            "retryable": error.retryable,
            "schema": C06SystemWire.schema,
        ]
        if let operation { value["operation"] = operation }
        if let detail = error.detail { value["detail"] = detail }
        return value
    }
}

private func c06SysInt64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
}

// MARK: - C ABI (JNI translation unit)

@_cdecl("floe_system_host_bind")
public func floeSystemHostBind(_ epoch: UInt64) -> Int32 {
    C06SystemHostMailbox.shared.bind(epoch: epoch)
}

@_cdecl("floe_system_host_lane_ready")
public func floeSystemHostLaneReady(_ epoch: UInt64) -> Int32 {
    C06SystemHostMailbox.shared.laneReady(epoch: epoch)
}

@_cdecl("floe_system_host_lane_closed")
public func floeSystemHostLaneClosed(_ epoch: UInt64) -> Int32 {
    C06SystemHostMailbox.shared.laneClosed(epoch: epoch)
}

@_cdecl("floe_system_host_next")
public func floeSystemHostNext(_ timeoutMillis: Int32) -> Int64 {
    C06SystemHostMailbox.shared.nextClaim(timeoutMillis: timeoutMillis)
}

@_cdecl("floe_system_host_describe")
public func floeSystemHostDescribe(
    _ claim: Int64,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let data = C06SystemHostMailbox.shared.describe(claim: claim),
          let text = String(data: data, encoding: .utf8) else {
        return -1
    }
    return c06SysCopyString(text, into: buffer, capacity: capacity)
}

@_cdecl("floe_system_host_complete")
public func floeSystemHostComplete(
    _ claim: Int64,
    _ status: Int32,
    _ buffer: UnsafePointer<CChar>?,
    _ length: Int32
) -> Int32 {
    if length < 0 { return C06SystemHostStatus.shape }
    let data: Data?
    if let buffer, length > 0 {
        data = Data(bytes: buffer, count: Int(length))
    } else {
        data = nil
    }
    return C06SystemHostMailbox.shared.complete(claim: claim, status: status, data: data)
}

@_cdecl("floe_system_host_should_stop")
public func floeSystemHostShouldStop(_ claim: Int64) -> Int32 {
    C06SystemHostMailbox.shared.shouldStop(claim: claim) ? 1 : 0
}

@_cdecl("floe_system_host_close_all")
public func floeSystemHostCloseAll(_ timeoutMillis: Int32) -> Int32 {
    C06SystemHostMailbox.shared.closeAll(timeoutMillis: timeoutMillis)
}

@_cdecl("floe_system_host_stats")
public func floeSystemHostStats(
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    let object = C06SystemHostMailbox.shared.descriptor()
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return -1
    }
    return c06SysCopyString(text, into: buffer, capacity: capacity)
}
