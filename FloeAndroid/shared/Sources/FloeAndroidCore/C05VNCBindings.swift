// SPDX-License-Identifier: MPL-2.0
//
// C05 VNC host bridge `floe.vnc/11` and the trusted frame JNI ABI.
//
// The JSON channel carries metadata and input events only. Pixels use the
// separate bounded binary lane: acquire -> 64 KiB page reads -> release.
// It is NOT a BridgeV3 command and NOT a model tool. The App host is the
// only caller; the frame lane is additionally fenced by the exact native
// epoch and the App-controller owner token.

import Foundation
import FloeCore
import FloeSSH
import FloeVNC

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

public enum BridgeV11 {
    public static let version = 11
    public static let schema = C05VNCWire.schema
    public static let maximumRequestBytes = C05VNCWire.maximumRequestBytes
    public static let maximumResponseBytes = C05VNCWire.maximumResponseBytes
    public static let modelTools = false
}

public enum C05VNCBridge {
    private final class VNCResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, C05RemoteError>?
        func set(_ result: Result<T, C05RemoteError>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<T, C05RemoteError>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    // MARK: - Entry

    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: C05RemoteError, operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code.rawValue,
                "reason": error.reason,
                "retryable": error.retryable,
                "schema": C05VNCWire.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            if let detail = error.detail { value["detail"] = detail }
            if let category = error.category { value["category"] = category }
            if let stage = error.stage { value["stage"] = stage }
            if let challenge = error.challenge {
                value["challenge"] = challengeJSON(challenge)
            }
            return value
        }
        guard requestData.count <= C05VNCWire.maximumRequestBytes else {
            return failure(C05RemoteError(.invalidRequest, "requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = exactInt(object["version"]),
              version == BridgeV11.version,
              let operation = boundedString(object["operation"], 64) else {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: nil)
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID

        switch operation {
        case "handshake", "c05.vnc.capabilities":
            return run(seconds: 5, operation: operation) {
                await C05VNCDomain.shared.capabilities()
            }.map { capabilities in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "coreReady": capabilities.coreReady,
                    "epoch": capabilities.epoch.map { NSNumber(value: $0) } ?? NSNull(),
                    "credentialGatewayReady": capabilities.credentialGatewayReady,
                    "maximumSessions": capabilities.maximumSessions,
                    "maximumProfiles": capabilities.maximumProfiles,
                    "maximumEndpointsPerProfile": capabilities.maximumEndpointsPerProfile,
                    "maximumInputEvents": capabilities.maximumInputEvents,
                    "maximumTextBytes": capabilities.maximumTextBytes,
                    "maximumCredentialBytes": capabilities.maximumCredentialBytes,
                    "maximumFrameBytes": capabilities.maximumFrameBytes,
                    "maximumLeases": capabilities.maximumLeases,
                    "pixelFormat": capabilities.pixelFormat,
                    "supportsDirect": capabilities.supportsDirect,
                    "supportsSSHTunnel": capabilities.supportsSSHTunnel,
                    "supportsPointer": capabilities.supportsPointer,
                    "supportsKeyboard": capabilities.supportsKeyboard,
                    "supportsWheel": capabilities.supportsWheel,
                    "modelTools": capabilities.modelTools,
                ] as [String: Any]
            }

        case "c05.vnc.profile.save":
            return profileSave(object, operation: operation)

        case "c05.vnc.connect":
            return connect(object, operation: operation)

        case "c05.vnc.status":
            return status(object, operation: operation)

        case "c05.vnc.input":
            return input(object, operation: operation)

        case "c05.vnc.releaseAll":
            return releaseAll(object, operation: operation)

        case "c05.vnc.close":
            return close(object, operation: operation)

        case "c05.vnc.rootStop":
            return rootStop(object, operation: operation)

        case "c05.vnc.credential.save":
            return credentialSave(object, operation: operation)

        case "c05.vnc.credential.probe":
            return credentialProbe(object, operation: operation)

        case "c05.vnc.credential.delete":
            return credentialDelete(object, operation: operation)

        default:
            return failure(C05RemoteError(.unsupportedOperation, "unsupportedOperation"), operation: operation)
        }
    }

    // MARK: - Operations

    private static func profileSave(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let draft = try profileDraft(object["profile"])
            return run(seconds: 20, operation: operation) {
                try await C05VNCDomain.shared.saveVNCOnlyProfile(draft, owner: owner)
            }.map { detail in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "host": hostDetailJSON(detail),
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.invalidRequest, "invalidProfile"), operation: operation)
        }
    }

    private static func connect(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let profileID = try requiredUUID(object["profileID"])
            let endpointID = try optionalUUID(object["endpointID"])
            let sshSessionID = try optionalUUID(object["sshSessionID"])
            return run(seconds: 45, operation: operation) {
                try await C05VNCDomain.shared.connect(
                    profileID: profileID,
                    endpointID: endpointID,
                    sshSessionID: sshSessionID,
                    owner: owner
                )
            }.map { session in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "session": sessionJSON(session),
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func status(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return run(seconds: 8, operation: operation) {
                try await C05VNCDomain.shared.status(sessionID: sessionID, owner: owner)
            }.map { session in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "session": sessionJSON(session),
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func input(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            let events = try inputEvents(object["events"])
            return run(seconds: 10, operation: operation) {
                try await C05VNCDomain.shared.input(
                    sessionID: sessionID,
                    events: events,
                    owner: owner
                )
            }.map { acceptance in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "accepted": acceptance.accepted,
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.invalidRequest, "invalidInput"), operation: operation)
        }
    }

    private static func releaseAll(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return run(seconds: 8, operation: operation) {
                try await C05VNCDomain.shared.releaseAllInput(sessionID: sessionID, owner: owner)
            }.map {
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "released": true,
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func close(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return run(seconds: 20, operation: operation) {
                try await C05VNCDomain.shared.close(sessionID: sessionID, owner: owner)
            }.map { report in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "sessionID": report.sessionID.uuidString,
                    "closed": report.closed,
                    "complete": report.complete,
                    "closedTunnel": report.closedTunnel,
                    "closedSSHSession": report.closedSSHSession,
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func rootStop(_ object: [String: Any], operation: String) -> [String: Any] {
        guard let expected = uint64(object["expectedEpoch"]), expected > 0 else {
            return errorJSON(
                C05RemoteError(.invalidRequest, "invalidNativeEpoch"),
                operation: operation
            )
        }
        return run(seconds: 45, operation: operation) {
            await C05VNCDomain.shared.rootStop(expectedEpoch: expected)
        }.map { report in
            [
                "ok": true,
                "schema": C05VNCWire.schema,
                "operation": operation,
                "drained": report.drained,
                "closedSessions": report.closedSessions,
                "closedTunnels": report.closedTunnels,
                "closedSSHSessions": report.closedSSHSessions,
            ]
        }
    }

    private static func credentialSave(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            guard let referenceObject = object["credential"] as? [String: Any],
                  let account = boundedString(referenceObject["keychainAccount"], 80),
                  let synchronizable = bool(referenceObject["synchronizable"]),
                  let encoded = boundedString(object["secretBase64"], 60_000),
                  let secret = Data(base64Encoded: encoded) else {
                throw C05RemoteError(.credentialInvalid, "invalidCredential")
            }
            return run(seconds: 12, operation: operation) {
                try await C05VNCDomain.shared.saveCredential(
                    account: account,
                    synchronizable: synchronizable,
                    secret: secret,
                    owner: owner
                )
            }.map { reference in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "reference": [
                        "keychainAccount": reference.keychainAccount,
                        "synchronizable": reference.synchronizable,
                    ] as [String: Any],
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.credentialInvalid, "invalidCredential"), operation: operation)
        }
    }

    private static func credentialProbe(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let reference = try credentialReference(object["credential"], requireVNC: false)
            return run(seconds: 8, operation: operation) {
                try await C05VNCDomain.shared.probeCredential(reference)
            }.map { present in
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "present": present,
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.credentialInvalid, "invalidCredential"), operation: operation)
        }
    }

    private static func credentialDelete(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let reference = try credentialReference(object["credential"], requireVNC: false)
            return run(seconds: 8, operation: operation) {
                try await C05VNCDomain.shared.deleteCredential(reference)
            }.map {
                [
                    "ok": true,
                    "schema": C05VNCWire.schema,
                    "operation": operation,
                    "deleted": true,
                ]
            }
        } catch let error as C05RemoteError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RemoteError(.credentialInvalid, "invalidCredential"), operation: operation)
        }
    }

    // MARK: - Async blocking helper

    private struct VNCBlockResult<T: Sendable> {
        let operation: String
        let result: Result<T, C05RemoteError>

        func map(_ transform: (T) -> [String: Any]) -> [String: Any] {
            switch result {
            case .success(let value):
                return transform(value)
            case .failure(let error):
                return C05VNCBridge.errorJSON(error, operation: operation)
            }
        }
    }

    private static func run<T: Sendable>(
        seconds: Double,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) -> VNCBlockResult<T> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = VNCResultBox<T>()
        let task = Task {
            do {
                box.set(.success(try await body()))
            } catch let error as C05RemoteError {
                box.set(.failure(error))
            } catch is CancellationError {
                box.set(.failure(C05RemoteError(.cancelled, "cancelled", retryable: true)))
            } catch {
                box.set(.failure(C05RemoteError(
                    .internalFailure,
                    "vncOperationFailed",
                    retryable: false,
                    detail: error.localizedDescription
                )))
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(Int(max(0.05, seconds) * 1_000))
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            return VNCBlockResult(
                operation: operation,
                result: .failure(C05RemoteError(.timeout, "outcomeMayBeUnknown", retryable: false))
            )
        }
        guard let result = box.get() else {
            return VNCBlockResult(
                operation: operation,
                result: .failure(C05RemoteError(.internalFailure, "missingOperationResult"))
            )
        }
        return VNCBlockResult(operation: operation, result: result)
    }

    // MARK: - Decoding

    private static func owner(_ value: Any?) throws -> C05RemoteOwner {
        guard let object = value as? [String: Any],
              let token = boundedString(object["token"], 128),
              let epoch = uint64(object["nativeEpoch"]) else {
            throw C05RemoteError(.invalidOwner, "missingOwner")
        }
        let taskID = (object["taskID"] as? String).flatMap(UUID.init(uuidString:))
        let temporary = bool(object["temporary"]) ?? false
        let owner = C05RemoteOwner(
            token: token,
            nativeEpoch: epoch,
            taskID: taskID,
            temporary: temporary
        )
        do {
            try owner.validate()
        } catch let error as C05RemoteError {
            throw error
        } catch {
            throw C05RemoteError(.invalidOwner, "invalidOwner")
        }
        return owner
    }

    private static func profileDraft(_ value: Any?) throws -> C05VNCProfileDraft {
        guard let object = value as? [String: Any],
              let displayName = boundedString(object["displayName"], 128),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw C05RemoteError(.invalidProfile, "invalidProfileFields")
        }
        let id: UUID?
        if let raw = object["id"] {
            guard let string = raw as? String, let parsed = UUID(uuidString: string) else {
                throw C05RemoteError(.invalidProfile, "invalidProfileID")
            }
            id = parsed
        } else {
            id = nil
        }
        let deviceKind = boundedString(object["deviceKind"], 32) ?? "unspecified"
        guard let rawEndpoints = object["vncEndpoints"] as? [Any],
              (1...C05VNCWire.maximumEndpointsPerProfile).contains(rawEndpoints.count) else {
            throw C05RemoteError(.invalidProfile, "invalidVNCEndpoints")
        }
        let endpoints = try rawEndpoints.map { raw -> C05VNCEndpointDraft in
            guard let endpoint = raw as? [String: Any],
                  let displayName = boundedString(endpoint["displayName"], 64),
                  let transport = boundedString(endpoint["transport"], 16),
                  let host = boundedString(endpoint["host"], 255),
                  let port = exactInt(endpoint["port"]),
                  (1...65535).contains(port) else {
                throw C05RemoteError(.invalidProfile, "invalidVNCEndpoint")
            }
            var endpointID = UUID()
            if let rawID = endpoint["id"] {
                guard let string = rawID as? String, let parsed = UUID(uuidString: string) else {
                    throw C05RemoteError(.invalidProfile, "invalidVNCEndpointID")
                }
                endpointID = parsed
            }
            let passwordRef: SecretReference?
            if let rawRef = endpoint["passwordRef"] {
                let reference = try credentialReference(rawRef, requireVNC: true)
                passwordRef = SecretReference(
                    keychainAccount: reference.keychainAccount,
                    synchronizable: reference.synchronizable
                )
            } else {
                passwordRef = nil
            }
            return C05VNCEndpointDraft(
                id: endpointID,
                displayName: displayName,
                transport: transport,
                host: host,
                port: port,
                passwordRef: passwordRef
            )
        }
        return C05VNCProfileDraft(
            id: id,
            displayName: displayName,
            deviceKind: deviceKind,
            endpoints: endpoints
        )
    }

    private static func inputEvents(_ value: Any?) throws -> [VNCFloeInputEvent] {
        guard let raw = value as? [Any],
              !raw.isEmpty,
              raw.count <= C05VNCWire.maximumInputEvents else {
            throw C05RemoteError(.invalidRequest, "invalidInputEvents")
        }
        var textBytes = 0
        return try raw.map { item -> VNCFloeInputEvent in
            guard let event = item as? [String: Any],
                  let kind = boundedString(event["kind"], 24) else {
                throw C05RemoteError(.invalidRequest, "invalidInputEvent")
            }
            switch kind {
            case "pointerMove":
                return .pointerMove(
                    x: try requiredInt(event["x"], -1_000_000...1_000_000),
                    y: try requiredInt(event["y"], -1_000_000...1_000_000)
                )
            case "pointerButton":
                guard let buttonName = boundedString(event["button"], 8),
                      let button = VNCFloePointerButton(rawValue: buttonName),
                      let down = bool(event["down"]) else {
                    throw C05RemoteError(.invalidRequest, "invalidPointerButton")
                }
                return .pointerButton(
                    button: button,
                    down: down,
                    x: try requiredInt(event["x"], -1_000_000...1_000_000),
                    y: try requiredInt(event["y"], -1_000_000...1_000_000)
                )
            case "wheel":
                guard let axisName = boundedString(event["axis"], 8),
                      let axis = VNCFloeWheelAxis(rawValue: axisName),
                      let steps = exactInt(event["steps"]),
                      (1...20).contains(steps) else {
                    throw C05RemoteError(.invalidRequest, "invalidWheel")
                }
                return .wheel(
                    axis: axis,
                    steps: steps,
                    x: try requiredInt(event["x"], -1_000_000...1_000_000),
                    y: try requiredInt(event["y"], -1_000_000...1_000_000)
                )
            case "key":
                guard let keysym = uint32(event["keysym"]), keysym > 0,
                      let down = bool(event["down"]) else {
                    throw C05RemoteError(.invalidRequest, "invalidKey")
                }
                return .key(keysym: keysym, down: down)
            case "text":
                guard let text = event["text"] as? String, !text.isEmpty else {
                    throw C05RemoteError(.invalidRequest, "invalidText")
                }
                textBytes += text.utf8.count
                guard textBytes <= C05VNCWire.maximumTextBytes else {
                    throw C05RemoteError(.invalidRequest, "vncTextTooLarge")
                }
                return .text(text)
            default:
                throw C05RemoteError(.invalidRequest, "unsupportedInputEvent")
            }
        }
    }

    private static func credentialReference(
        _ value: Any?,
        requireVNC: Bool
    ) throws -> C05CredentialReference {
        guard let object = value as? [String: Any],
              let account = boundedString(object["keychainAccount"], 80),
              let synchronizable = bool(object["synchronizable"]) else {
            throw C05RemoteError(.credentialInvalid, "invalidCredentialReference")
        }
        if requireVNC {
            guard account.hasPrefix(C05VNCWire.vncCredentialPrefix) else {
                throw C05RemoteError(.credentialInvalid, "invalidVNCReference")
            }
        }
        return C05CredentialReference(
            keychainAccount: account,
            synchronizable: synchronizable
        )
    }

    // MARK: - JSON encoders

    private static func sessionJSON(_ value: C05VNCSessionSnapshot) -> [String: Any] {
        var object: [String: Any] = [
            "id": value.id.uuidString,
            "profileID": value.profileID.uuidString,
            "endpointID": value.endpointID.uuidString,
            "displayName": value.displayName,
            "host": value.host,
            "port": value.port,
            "transport": value.transport,
            "state": value.state,
            "width": value.width,
            "height": value.height,
            "frameRevision": NSNumber(value: value.frameRevision),
            "frameBytes": value.frameBytes,
            "createdAt": ISO8601DateFormatter().string(from: value.createdAt),
            "lastActivityAt": ISO8601DateFormatter().string(from: value.lastActivityAt),
            "sshSessionID": value.sshSessionID?.uuidString ?? NSNull(),
            "tunnelID": value.tunnelID?.uuidString ?? NSNull(),
        ]
        if let failure = value.failure {
            object["failure"] = [
                "code": failure.code,
                "message": failure.message,
                "retryable": failure.retryable,
                "category": failure.category,
                "stage": failure.stage,
            ] as [String: Any]
        } else {
            object["failure"] = NSNull()
        }
        return object
    }

    private static func hostDetailJSON(_ value: C05HostDetail) -> [String: Any] {
        var object = hostSummaryJSON(value.summary)
        object["jumpChain"] = value.jumpChain.map { hop in
            [
                "address": hop.address,
                "port": hop.port,
                "user": hop.user,
                "auth": authJSON(hop.auth),
            ] as [String: Any]
        }
        object["vncEndpoints"] = value.vncEndpoints.map { endpoint -> [String: Any] in
            var json: [String: Any] = [
                "id": endpoint.id.uuidString,
                "displayName": endpoint.displayName,
                "transport": endpoint.transport,
                "host": endpoint.host,
                "port": endpoint.port,
            ]
            if let ref = endpoint.passwordRef {
                json["passwordRef"] = credentialReferenceJSON(ref)
            }
            return json
        }
        object["auxiliaryConnections"] = value.auxiliaryConnections.map { connection -> [String: Any] in
            var json: [String: Any] = [
                "id": connection.id.uuidString,
                "displayName": connection.displayName,
                "kind": connection.kind,
            ]
            if let host = connection.host { json["host"] = host }
            if let port = connection.port { json["port"] = port }
            if let id = connection.bluetoothPeripheralID { json["bluetoothPeripheralID"] = id.uuidString }
            if let value = connection.bluetoothServiceUUID { json["bluetoothServiceUUID"] = value }
            if let value = connection.bluetoothWriteCharacteristicUUID {
                json["bluetoothWriteCharacteristicUUID"] = value
            }
            if let value = connection.bluetoothNotifyCharacteristicUUID {
                json["bluetoothNotifyCharacteristicUUID"] = value
            }
            return json
        }
        return object
    }

    private static func hostSummaryJSON(_ value: C05HostSummary) -> [String: Any] {
        [
            "id": value.id.uuidString,
            "displayName": value.displayName,
            "address": value.address,
            "port": value.port,
            "user": value.user,
            "auth": authJSON(value.auth),
            "deviceKind": value.deviceKind,
            "isRemoteExecutionEnvironment": value.isRemoteExecutionEnvironment,
            "hostKeyPolicy": value.hostKeyPolicy,
            "pinnedFingerprintSHA256": value.pinnedFingerprintSHA256 ?? NSNull(),
            "allowsLegacyAlgorithms": value.allowsLegacyAlgorithms,
            "jumpHopCount": value.jumpHopCount,
            "vncEndpointCount": value.vncEndpointCount,
            "auxiliaryConnectionCount": value.auxiliaryConnectionCount,
        ]
    }

    private static func authJSON(_ value: C05AuthSummary) -> [String: Any] {
        var object: [String: Any] = ["kind": value.kind]
        if let keyType = value.keyType { object["keyType"] = keyType }
        if let credential = value.credential {
            object["credential"] = credentialReferenceJSON(credential)
        }
        return object
    }

    private static func credentialReferenceJSON(_ value: C05CredentialReference) -> [String: Any] {
        [
            "keychainAccount": value.keychainAccount,
            "synchronizable": value.synchronizable,
        ]
    }

    private static func challengeJSON(_ value: C05HostKeyChallenge) -> [String: Any] {
        var object: [String: Any] = [
            "id": value.id.uuidString,
            "profileID": value.profileID.uuidString,
            "address": value.address,
            "port": value.port,
            "keyType": value.keyType,
            "fingerprintSHA256": value.fingerprintSHA256,
            "kind": value.kind.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: value.createdAt),
            "expiresAt": ISO8601DateFormatter().string(from: value.expiresAt),
        ]
        if let expected = value.expectedFingerprintSHA256 {
            object["expectedFingerprintSHA256"] = expected
        }
        return object
    }

    private static func errorJSON(_ error: C05RemoteError, operation: String?) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": error.code.rawValue,
            "reason": error.reason,
            "retryable": error.retryable,
            "schema": C05VNCWire.schema,
        ]
        if let operation { value["operation"] = operation }
        if let detail = error.detail { value["detail"] = detail }
        if let category = error.category { value["category"] = category }
        if let stage = error.stage { value["stage"] = stage }
        if let challenge = error.challenge {
            value["challenge"] = challengeJSON(challenge)
        }
        return value
    }

    // MARK: - Primitive decoders

    private static func boundedString(_ value: Any?, _ maximumBytes: Int) -> String? {
        guard let string = value as? String, !string.isEmpty,
              string.utf8.count <= maximumBytes,
              !string.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return string
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= Double(Int.min),
              doubleValue <= Double(Int.max) else {
            return nil
        }
        return Int(doubleValue)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue > 0,
              doubleValue <= Double(UInt64.max) else {
            return nil
        }
        return UInt64(doubleValue)
    }

    private static func uint32(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue >= 0,
              doubleValue <= Double(UInt32.max) else {
            return nil
        }
        return UInt32(doubleValue)
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func requiredUUID(_ value: Any?) throws -> UUID {
        guard let string = boundedString(value, 64), let id = UUID(uuidString: string) else {
            throw C05RemoteError(.invalidRequest, "invalidIdentifier")
        }
        return id
    }

    private static func optionalUUID(_ value: Any?) throws -> UUID? {
        guard let value else { return nil }
        return try requiredUUID(value)
    }

    private static func requiredInt(_ value: Any?, _ range: ClosedRange<Int>) throws -> Int {
        guard let number = exactInt(value), range.contains(number) else {
            throw C05RemoteError(.invalidRequest, "invalidInteger")
        }
        return number
    }
}

// MARK: - Trusted frame JNI ABI

/// Negative status space (disjoint from the JSON bridge):
/// -101 unknown session/lease, -102 stale epoch, -105 invalid argument,
/// -106 buffer too small, -107 oversize, -108 encoding, -109 lease limit,
/// -110 no frame yet, -111 invalid offset.
private let c05VNCFrameStatusInvalidArgument: Int32 = -105
private let c05VNCFrameStatusBufferTooSmall: Int32 = -106
private let c05VNCFrameStatusOversize: Int32 = -107
private let c05VNCFrameStatusEncoding: Int32 = -108
private let c05VNCFrameStatusLeaseLimit: Int32 = -109
private let c05VNCFrameStatusNoFrame: Int32 = -110
private let c05VNCFrameStatusInvalidOffset: Int32 = -111
private let c05VNCFrameStatusUnknown: Int32 = -101
private let c05VNCFrameStatusStale: Int32 = -102

private func c05VNCEncodeJSON(_ object: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return nil
    }
    return data
}

private func c05VNCCopyJSON(
    _ data: Data,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let buffer, capacity > 0, data.count + 1 <= Int(capacity) else {
        return c05VNCFrameStatusBufferTooSmall
    }
    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: data.count))
    buffer[data.count] = 0
    return Int32(data.count)
}

private func c05VNCStatus(_ error: C05VNCFrameBroker.BrokerError) -> Int32 {
    switch error {
    case .staleEpoch:
        return c05VNCFrameStatusStale
    case .unknownSession, .unknownLease:
        return c05VNCFrameStatusUnknown
    case .leaseLimit:
        return c05VNCFrameStatusLeaseLimit
    case .noFrame:
        return c05VNCFrameStatusNoFrame
    case .invalidOffset:
        return c05VNCFrameStatusInvalidOffset
    case .bufferTooSmall:
        return c05VNCFrameStatusBufferTooSmall
    }
}

/// Acquire an immutable frame lease and return its bounded metadata JSON.
/// Request/response carry no pixel bytes; the caller reads 64 KiB pages via
/// `floe_vnc_frame_read` and releases the lease explicitly.
@_cdecl("floe_vnc_frame_acquire")
public func floeVNCFrameAcquire(
    _ epoch: UInt64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ sessionID: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0, let ownerToken, let sessionID else {
        return c05VNCFrameStatusInvalidArgument
    }
    let ownerLength = strnlen(ownerToken, 129)
    let sessionLength = strnlen(sessionID, 65)
    guard ownerLength > 0, ownerLength <= 128, sessionLength == 36 else {
        return c05VNCFrameStatusInvalidArgument
    }
    let owner = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(ownerToken), count: ownerLength), as: UTF8.self)
    let sessionString = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(sessionID), count: sessionLength), as: UTF8.self)
    guard let sessionUUID = UUID(uuidString: sessionString) else {
        return c05VNCFrameStatusInvalidArgument
    }
    do {
        let result = try C05VNCFrameBroker.shared.acquire(
            epoch: epoch,
            ownerToken: owner,
            sessionID: sessionUUID
        )
        let frame = result.frame
        let metadata: [String: Any] = [
            "ok": true,
            "schema": C05VNCWire.schema,
            "leaseID": result.leaseID,
            "sessionID": sessionUUID.uuidString,
            "width": frame.width,
            "height": frame.height,
            "stride": frame.stride,
            "format": VNCFloeFrame.pixelFormat,
            "byteCount": frame.byteCount,
            "revision": NSNumber(value: frame.revision),
        ]
        guard let encoded = c05VNCEncodeJSON(metadata) else {
            C05VNCFrameBroker.shared.release(epoch: epoch, leaseID: result.leaseID)
            return c05VNCFrameStatusEncoding
        }
        return c05VNCCopyJSON(encoded, buffer, capacity)
    } catch let error as C05VNCFrameBroker.BrokerError {
        return c05VNCStatus(error)
    } catch {
        return c05VNCFrameStatusUnknown
    }
}

/// Copy one bounded page of an acquired frame. Returns the copied byte count,
/// 0 at the end of the frame, or a negative status.
@_cdecl("floe_vnc_frame_read")
public func floeVNCFrameRead(
    _ epoch: UInt64,
    _ leaseID: UnsafePointer<CChar>?,
    _ offset: Int64,
    _ target: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0, let leaseID, let target,
          offset >= 0, capacity > 0, capacity <= 65_536 else {
        return c05VNCFrameStatusInvalidArgument
    }
    let leaseLength = strnlen(leaseID, 65)
    guard leaseLength == 36 else { return c05VNCFrameStatusInvalidArgument }
    let lease = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(leaseID), count: leaseLength), as: UTF8.self)
    guard let offsetValue = Int(exactly: offset) else {
        return c05VNCFrameStatusInvalidOffset
    }
    do {
        let data = try C05VNCFrameBroker.shared.read(
            epoch: epoch,
            leaseID: lease,
            offset: offsetValue,
            capacity: Int(capacity)
        )
        guard !data.isEmpty else { return 0 }
        data.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return }
            memcpy(target, source, data.count)
        }
        return Int32(data.count)
    } catch let error as C05VNCFrameBroker.BrokerError {
        return c05VNCStatus(error)
    } catch {
        return c05VNCFrameStatusUnknown
    }
}

/// Idempotent release of one frame lease.
@_cdecl("floe_vnc_frame_release")
public func floeVNCFrameRelease(
    _ epoch: UInt64,
    _ leaseID: UnsafePointer<CChar>?
) -> Int32 {
    guard epoch > 0, let leaseID else { return c05VNCFrameStatusInvalidArgument }
    let leaseLength = strnlen(leaseID, 65)
    guard leaseLength == 36 else { return c05VNCFrameStatusInvalidArgument }
    let lease = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(leaseID), count: leaseLength), as: UTF8.self)
    C05VNCFrameBroker.shared.release(epoch: epoch, leaseID: lease)
    return 0
}
