// SPDX-License-Identifier: MPL-2.0
//
// C05 device communication host bridge `floe.device/14` plus the trusted
// mailbox C ABI.
//
// The JSON channel carries device PROFILE metadata and capabilities only.
// Live terminal/device bytes stay in the App-owned Kotlin engine lane; no
// bulk base64 or binary paging crosses this channel. It is NOT a BridgeV3
// command, NOT a model route and does not widen any task/environment
// permission. Model tools use the bounded mailbox in
// C05DeviceCommunicationDomain.swift and derive authority from ToolContext.
//
// Requests/responses are bounded JSON. No secret body, fingerprint, host path
// or raw platform exception appears here.

import Foundation
import FloeCore
import FloeTools

public enum BridgeV14 {
    public static let version = C05DeviceWire.version
    public static let schema = C05DeviceWire.schema
    public static let maximumRequestBytes = C05DeviceWire.maximumRequestBytes
    public static let maximumResponseBytes = C05DeviceWire.maximumResponseBytes
    public static let modelTools = C05DeviceWire.modelTools
}

public enum C05DeviceBridge {
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, C05DeviceError>?
        func set(_ result: Result<T, C05DeviceError>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<T, C05DeviceError>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private struct BlockResult<T: Sendable> {
        let operation: String
        let result: Result<T, C05DeviceError>

        func map(_ transform: (T) -> [String: Any]) -> [String: Any] {
            switch result {
            case .success(let value):
                var object = transform(value)
                object["ok"] = true
                object["schema"] = C05DeviceWire.schema
                object["operation"] = operation
                return object
            case .failure(let error):
                return C05DeviceBridge.failure(error, operation: operation)
            }
        }
    }

    private static func block<T: Sendable>(
        seconds: Double,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) -> BlockResult<T> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task {
            do {
                box.set(.success(try await body()))
            } catch let error as C05DeviceError {
                box.set(.failure(error))
            } catch is CancellationError {
                box.set(.failure(C05DeviceError(.cancelled, "cancelled", retryable: true)))
            } catch {
                box.set(.failure(C05DeviceError(
                    .internalFailure,
                    "deviceOperationFailed",
                    retryable: false
                )))
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(Int(max(0.05, seconds) * 1_000))
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            return BlockResult(
                operation: operation,
                result: .failure(C05DeviceError(.timedOut, "deviceBridgeTimedOut", retryable: true))
            )
        }
        guard let result = box.get() else {
            return BlockResult(
                operation: operation,
                result: .failure(C05DeviceError(.internalFailure, "missingOperationResult"))
            )
        }
        return BlockResult(operation: operation, result: result)
    }

    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        guard requestData.count <= C05DeviceWire.maximumRequestBytes else {
            return failure(C05DeviceError(.invalidRequest, "requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = strictInt(object["version"]),
              version == BridgeV14.version,
              let operation = boundedString(object["operation"], 64) else {
            return failure(C05DeviceError(.invalidRequest, "invalidRequest"), operation: nil)
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID
        switch operation {
        case "handshake", "c05.device.capabilities":
            return block(seconds: 5, operation: operation) {
                C05DeviceDomain.shared.capabilities()
            }.map { capabilities in
                [
                    "coreReady": capabilities.coreReady,
                    "epoch": capabilities.epoch.map { NSNumber(value: $0) } ?? NSNull(),
                    "maximumSessions": capabilities.maximumSessions,
                    "maximumProfiles": capabilities.maximumProfiles,
                    "maximumConnectionsPerProfile": capabilities.maximumConnectionsPerProfile,
                    "supportsTcp": capabilities.supportsTcp,
                    "supportsTelnet": capabilities.supportsTelnet,
                    "supportsBle": capabilities.supportsBle,
                    "supportsUsb": capabilities.supportsUsb,
                    "modelTools": capabilities.modelTools,
                ] as [String: Any]
            }
        case "c05.device.profile.list":
            guard let owner = owner(object) else {
                return failure(C05DeviceError(.invalidRequest, "invalidOwner"), operation: operation)
            }
            return block(seconds: 8, operation: operation) {
                try await C05DeviceDomain.shared.listProfiles(owner: owner)
            }.map { profiles in
                ["profiles": profiles.map(profileJSON)]
            }
        case "c05.device.profile.save":
            guard let owner = owner(object),
                  let profileObject = object["profile"] as? [String: Any],
                  let draft = parseDraft(profileObject) else {
                return failure(C05DeviceError(.invalidRequest, "invalidProfile"), operation: operation)
            }
            return block(seconds: 8, operation: operation) {
                try await C05DeviceDomain.shared.saveProfile(draft, owner: owner)
            }.map { profile in
                ["profile": profileJSON(profile)]
            }
        case "c05.device.profile.delete":
            guard let owner = owner(object),
                  let id = uuid(object["profileID"]) else {
                return failure(C05DeviceError(.invalidRequest, "invalidProfileID"), operation: operation)
            }
            return block(seconds: 8, operation: operation) {
                try await C05DeviceDomain.shared.deleteProfile(id: id, owner: owner)
            }.map { report in
                [
                    "deleted": report.deleted,
                    "remainingConnections": report.remainingConnections,
                ]
            }
        default:
            return failure(C05DeviceError(.unsupportedOperation, "unsupportedOperation"),
                           operation: operation)
        }
    }

    // MARK: - Parsing

    private static func owner(_ object: [String: Any]) -> C05DeviceOwner? {
        guard let owner = object["owner"] as? [String: Any],
              let token = boundedString(owner["token"], 128),
              let epoch = strictUInt64(owner["nativeEpoch"]), epoch != 0 else {
            return nil
        }
        return C05DeviceOwner(
            token: token,
            nativeEpoch: epoch,
            taskID: uuid(owner["taskID"]),
            approvalGrantID: nil,
            temporary: (owner["temporary"] as? Bool) ?? false
        )
    }

    private static func parseDraft(_ object: [String: Any]) -> C05DeviceProfileDraft? {
        guard let displayName = boundedString(object["displayName"], 120),
              let rawConnections = object["connections"] as? [[String: Any]],
              rawConnections.count <= C05DeviceWire.maximumConnectionsPerProfile,
              !rawConnections.isEmpty else {
            return nil
        }
        var connections: [C05DeviceConnectionDraft] = []
        for raw in rawConnections {
            guard let connectionName = boundedString(raw["displayName"], 120),
                  let kind = boundedString(raw["kind"], 32) else {
                return nil
            }
            connections.append(C05DeviceConnectionDraft(
                id: uuid(raw["id"]),
                displayName: connectionName,
                kind: kind,
                host: boundedString(raw["host"], Int(C05DeviceWire.maximumHostBytes)),
                port: strictInt(raw["port"]),
                peripheralAddress: boundedString(raw["peripheralAddress"], 17),
                serviceUUID: boundedString(raw["serviceUUID"], 64),
                writeUUID: boundedString(raw["writeUUID"], 64),
                notifyUUID: boundedString(raw["notifyUUID"], 64)
            ))
        }
        return C05DeviceProfileDraft(
            id: uuid(object["id"]),
            displayName: displayName,
            connections: connections
        )
    }

    private static func profileJSON(_ profile: C05DeviceProfile) -> [String: Any] {
        [
            "id": profile.id.uuidString,
            "displayName": profile.displayName,
            "connections": profile.connections.map { connection in
                var object: [String: Any] = [
                    "id": connection.id.uuidString,
                    "displayName": connection.displayName,
                    "kind": connection.kind,
                ]
                if let host = connection.host { object["host"] = host }
                if let port = connection.port { object["port"] = port }
                if let address = connection.peripheralAddress {
                    object["peripheralAddress"] = address
                }
                if let service = connection.serviceUUID { object["serviceUUID"] = service }
                if let write = connection.writeUUID { object["writeUUID"] = write }
                if let notify = connection.notifyUUID { object["notifyUUID"] = notify }
                return object
            },
        ]
    }

    private static func failure(_ error: C05DeviceError, operation: String?) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": error.code.rawValue,
            "reason": error.reason,
            "retryable": error.retryable,
            "schema": C05DeviceWire.schema,
        ]
        if let operation { value["operation"] = operation }
        if let detail = error.detail { value["detail"] = boundedDetail(detail) }
        if let stage = error.stage { value["stage"] = stage }
        return value
    }

    private static func boundedDetail(_ value: String) -> String {
        let cleaned = String(value.filter { character in
            character.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
        })
        return String(cleaned.prefix(C05DeviceHostLimits.maximumDetailCharacters))
    }
}


// MARK: - Strict bounded JSON helpers

private func boundedString(_ value: Any?, _ maximumBytes: Int) -> String? {
    guard let text = value as? String, !text.isEmpty,
          text.utf8.count <= maximumBytes else { return nil }
    return text
}

private func strictInt(_ value: Any?) -> Int? {
    if let text = value as? String { return Int(text) }
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double.rounded(.towardZero) == double,
          double >= Double(Int32.min), double <= Double(Int32.max) else { return nil }
    return number.intValue
}

private func strictUInt64(_ value: Any?) -> UInt64? {
    if let text = value as? String { return UInt64(text) }
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double >= 0, double <= Double(UInt32.max),
          double.rounded(.towardZero) == double else { return nil }
    return number.uint64Value
}

private func uuid(_ value: Any?) -> UUID? {
    guard let text = value as? String else { return nil }
    return UUID(uuidString: text)
}

// MARK: - Trusted mailbox C ABI

@_cdecl("floe_device_bind")
public func floeDeviceBind(_ epoch: UInt64) -> Int32 {
    guard epoch != 0, G02NativeRootEpoch.readback() == epoch else {
        return C05DeviceHostStatus.generationFenced
    }
    guard C05DeviceHostMailbox.shared.bind(epoch: epoch) else {
        return C05DeviceHostStatus.generationFenced
    }
    C05DeviceToolComposition.shared.installIfNeeded()
    return C05DeviceHostStatus.ok
}

@_cdecl("floe_device_next")
public func floeDeviceNext(_ timeoutMillis: Int32) -> Int64 {
    C05DeviceHostMailbox.shared.nextClaim(timeoutMillis: min(1_000, max(0, timeoutMillis)))
}

@_cdecl("floe_device_describe")
public func floeDeviceDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32) -> Int32 {
    C05DeviceHostMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_device_payload_length")
public func floeDevicePayloadLength(_ claim: Int64) -> Int32 {
    C05DeviceHostMailbox.shared.payloadLength(claim: claim)
}

@_cdecl("floe_device_take_payload")
public func floeDeviceTakePayload(_ claim: Int64,
                                  _ buffer: UnsafeMutablePointer<UInt8>?,
                                  _ capacity: Int32) -> Int32 {
    C05DeviceHostMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_device_is_live")
public func floeDeviceIsLive(_ claim: Int64) -> Int32 {
    C05DeviceHostMailbox.shared.isLive(claim: claim)
}

@_cdecl("floe_device_should_stop")
public func floeDeviceShouldStop(_ claim: Int64) -> Int32 {
    C05DeviceHostMailbox.shared.shouldStop(claim: claim)
}

@_cdecl("floe_device_complete")
public func floeDeviceComplete(_ claim: Int64, _ status: Int32,
                               _ value: UnsafePointer<UInt8>?,
                               _ valueLen: Int32) -> Int32 {
    guard status == 0 || status == 1, valueLen >= 0,
          valueLen == 0 || value != nil else {
        return C05DeviceHostStatus.shape
    }
    let data = valueLen == 0 ? Data() : Data(bytes: value!, count: Int(valueLen))
    return C05DeviceHostMailbox.shared.complete(claim: claim, status: status, value: data)
}

@_cdecl("floe_device_close")
public func floeDeviceClose(_ epoch: UInt64) -> Int32 {
    C05DeviceHostMailbox.shared.close(epoch: epoch)
    C05DeviceToolComposition.shared.uninstall()
    return C05DeviceHostStatus.ok
}

@_cdecl("floe_device_stats")
public func floeDeviceStats(_ buffer: UnsafeMutablePointer<CChar>?,
                            _ capacity: Int32) -> Int32 {
    floeDeviceCopyCString(C05DeviceHostMailbox.shared.statsJSON(),
                          buffer: buffer, capacity: capacity)
}

@_cdecl("floe_device_readiness")
public func floeDeviceReadiness(_ buffer: UnsafeMutablePointer<CChar>?,
                                _ capacity: Int32) -> Int32 {
    floeDeviceCopyCString(C05DeviceToolComposition.shared.readinessJSON(),
                          buffer: buffer, capacity: capacity)
}

private func floeDeviceCopyCString(_ value: String,
                                   buffer: UnsafeMutablePointer<CChar>?,
                                   capacity: Int32) -> Int32 {
    guard capacity >= 0, let buffer else { return C05DeviceHostStatus.shape }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else {
        return C05DeviceHostStatus.bufferTooSmall
    }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
