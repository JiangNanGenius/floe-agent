// SPDX-License-Identifier: MPL-2.0
//
// C05 RDP host bridge `floe.rdp/17` and the trusted frame JNI ABI.
//
// The JSON channel carries metadata and input events only. Pixels use the
// separate bounded binary lane: acquire -> 64 KiB page reads -> release.
// It is NOT a BridgeV3 command. The App host is the only caller; the frame
// lane is additionally fenced by the exact native epoch and the
// App-controller owner token.

import Foundation
import FloeCore
import FloeRDP
import FloeSSH

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

public enum BridgeV17 {
    public static let version = 17
    public static let schema = C05RDPWire.schema
    public static let maximumRequestBytes = C05RDPWire.maximumRequestBytes
    public static let maximumResponseBytes = C05RDPWire.maximumResponseBytes
    public static let modelTools = C05RDPWire.modelTools
}

public enum C05RDPBridge {
    private final class RDPResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, C05RDPError>?

        func set(_ result: Result<T, C05RDPError>) {
            lock.lock(); value = result; lock.unlock()
        }

        func get() -> Result<T, C05RDPError>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private struct RDPBlockResult<T: Sendable>: Sendable {
        let operation: String
        let result: Result<T, C05RDPError>

        func map(_ transform: (T) -> [String: Any]) -> [String: Any] {
            switch result {
            case .success(let value):
                return transform(value)
            case .failure(let error):
                return C05RDPBridge.errorJSON(error, operation: operation)
            }
        }
    }

    // MARK: - Entry

    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID

        func failure(_ error: C05RDPError, operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code.rawValue,
                "reason": error.reason,
                "retryable": error.retryable,
                "schema": C05RDPWire.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            if let detail = error.detail { value["detail"] = detail }
            if let category = error.category { value["category"] = category }
            if let stage = error.stage { value["stage"] = stage }
            if let challenge = error.challenge { value["challenge"] = challengeJSON(challenge) }
            return value
        }

        guard requestData.count <= C05RDPWire.maximumRequestBytes else {
            return failure(C05RDPError(.invalidRequest, "requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = exactInt(object["version"]),
              version == BridgeV17.version,
              let operation = boundedString(object["operation"], 64) else {
            return failure(C05RDPError(.invalidRequest, "invalidRequest"), operation: nil)
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID

        switch operation {
        case "handshake", "c05.rdp.capabilities":
            return run(seconds: 5, operation: operation) {
                await C05RDPDomain.shared.capabilities()
            }.map { capabilities in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "coreReady": capabilities.coreReady,
                    "epoch": capabilities.epoch.map { NSNumber(value: $0) } ?? NSNull(),
                    "credentialGatewayReady": capabilities.credentialGatewayReady,
                    "runtimeVersion": capabilities.runtimeVersion,
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
                    "supportsCertificateTrust": capabilities.supportsCertificateTrust,
                    "modelTools": capabilities.modelTools,
                ] as [String: Any]
            }

        case "c05.rdp.profile.list":
            return profileList(object, operation: operation)
        case "c05.rdp.profile.detail":
            return profileDetail(object, operation: operation)
        case "c05.rdp.profile.save":
            return profileSave(object, operation: operation)
        case "c05.rdp.profile.delete":
            return profileDelete(object, operation: operation)
        case "c05.rdp.endpoint.delete":
            return endpointDelete(object, operation: operation)
        case "c05.rdp.connect":
            return connect(object, operation: operation)
        case "c05.rdp.status":
            return status(object, operation: operation)
        case "c05.rdp.input":
            return input(object, operation: operation)
        case "c05.rdp.releaseAll":
            return releaseAll(object, operation: operation)
        case "c05.rdp.close":
            return close(object, operation: operation)
        case "c05.rdp.reset":
            return reset(object, operation: operation)
        case "c05.rdp.rootStop":
            return rootStop(object, operation: operation)
        case "c05.rdp.credential.save":
            return credentialSave(object, operation: operation)
        case "c05.rdp.credential.probe":
            return credentialProbe(object, operation: operation)
        case "c05.rdp.credential.delete":
            return credentialDelete(object, operation: operation)
        case "c05.rdp.trust":
            return trust(object, operation: operation)
        case "c05.rdp.trust.revoke":
            return revokeTrust(object, operation: operation)
        default:
            return failure(C05RDPError(.unsupportedOperation, "unsupportedOperation"), operation: operation)
        }
    }

    // MARK: - Profiles

    private static func profileList(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            return run(seconds: 20, operation: operation) {
                try await C05RDPDomain.shared.listProfiles(owner: owner)
            }.map { hosts in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "hosts": hosts.map(hostDetailJSON),
                ]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func profileDetail(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let profileID = try requiredUUID(object["profileID"])
            return run(seconds: 20, operation: operation) {
                try await C05RDPDomain.shared.profileDetail(profileID: profileID, owner: owner)
            }.map { detail in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "host": hostDetailJSON(detail),
                ]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func profileSave(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let draft = try profileDraft(object["profile"])
            return run(seconds: 25, operation: operation) {
                try await C05RDPDomain.shared.saveProfile(draft, owner: owner)
            }.map { detail in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "host": hostDetailJSON(detail),
                ]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidProfile"), operation: operation)
        }
    }

    private static func profileDelete(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let profileID = try requiredUUID(object["profileID"])
            let deleteHost = bool(object["deleteHost"]) ?? false
            return run(seconds: 25, operation: operation) {
                try await C05RDPDomain.shared.deleteProfile(
                    profileID: profileID,
                    deleteHost: deleteHost,
                    owner: owner
                )
            }.map { detail in
                var value: [String: Any] = [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "deleted": true,
                ]
                if let detail { value["host"] = hostDetailJSON(detail) }
                return value
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func endpointDelete(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let profileID = try requiredUUID(object["profileID"])
            let endpointID = try requiredUUID(object["endpointID"])
            return run(seconds: 25, operation: operation) {
                try await C05RDPDomain.shared.deleteEndpoint(
                    profileID: profileID,
                    endpointID: endpointID,
                    owner: owner
                )
            }.map { detail in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "host": hostDetailJSON(detail),
                ]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    // MARK: - Session

    private static func connect(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let profileID = try requiredUUID(object["profileID"])
            let endpointID = try optionalUUID(object["endpointID"])
            return run(seconds: 40, operation: operation) {
                try await C05RDPDomain.shared.connect(
                    profileID: profileID,
                    endpointID: endpointID,
                    owner: owner
                )
            }.map { session in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "session": sessionJSON(session),
                ]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func status(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return run(seconds: 10, operation: operation) {
                try await C05RDPDomain.shared.status(sessionID: sessionID, owner: owner)
            }.map { session in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "session": sessionJSON(session),
                ]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func input(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            let events = try inputEvents(object["events"])
            return run(seconds: 10, operation: operation) {
                try await C05RDPDomain.shared.input(
                    sessionID: sessionID,
                    events: events,
                    owner: owner
                )
            }.map { acceptance in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "accepted": acceptance.accepted,
                ]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidInput"), operation: operation)
        }
    }

    private static func releaseAll(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return run(seconds: 10, operation: operation) {
                try await C05RDPDomain.shared.releaseAllInput(sessionID: sessionID, owner: owner)
                return true
            }.map { _ in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                ] as [String: Any]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func close(_ object: [String: Any], operation: String) -> [String: Any] {
        closeLike(object, operation: operation) { sessionID, owner in
            try await C05RDPDomain.shared.close(sessionID: sessionID, owner: owner)
        }
    }

    private static func reset(_ object: [String: Any], operation: String) -> [String: Any] {
        closeLike(object, operation: operation) { sessionID, owner in
            try await C05RDPDomain.shared.reset(sessionID: sessionID, owner: owner)
        }
    }

    private static func closeLike(
        _ object: [String: Any],
        operation: String,
        _ body: @escaping @Sendable (UUID, C05RemoteOwner) async throws -> C05RDPShutdownReport
    ) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return run(seconds: 15, operation: operation) {
                try await body(sessionID, owner)
            }.map { report in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "sessionID": report.sessionID.uuidString,
                    "closed": report.closed,
                    "complete": report.complete,
                ] as [String: Any]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func rootStop(_ object: [String: Any], operation: String) -> [String: Any] {
        guard let epoch = uint64(object["expectedEpoch"]) else {
            return errorJSON(C05RDPError(.invalidRequest, "invalidEpoch"), operation: operation)
        }
        let result = run(seconds: 15, operation: operation) {
            await C05RDPDomain.shared.rootStop(expectedEpoch: epoch)
        }
        switch result.result {
        case .success(let report):
            return [
                "ok": true,
                "schema": C05RDPWire.schema,
                "operation": operation,
                "drained": report.drained,
                "closedSessions": report.closedSessions,
            ]
        case .failure(let error):
            return errorJSON(error, operation: operation)
        }
    }

    // MARK: - Credentials / trust

    private static func credentialSave(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let reference = try credentialReference(object["credential"], requireRDP: false)
            guard let encoded = boundedString(object["secretBase64"], 60_000),
                  let data = Data(base64Encoded: encoded),
                  !data.isEmpty, data.count <= C05RDPWire.maximumCredentialBytes else {
                throw C05RDPError(.credentialInvalid, "invalidCredentialSize")
            }
            var secret = data
            defer { secret.resetBytes(in: 0..<secret.count) }
            return run(seconds: 20, operation: operation) {
                try await C05RDPDomain.shared.saveCredential(
                    account: reference.keychainAccount,
                    synchronizable: reference.synchronizable,
                    secret: secret,
                    owner: owner
                )
            }.map { saved in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "reference": credentialReferenceJSON(saved),
                ] as [String: Any]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.credentialInvalid, "invalidCredential"), operation: operation)
        }
    }

    private static func credentialProbe(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let reference = try credentialReference(object["credential"], requireRDP: true)
            return run(seconds: 15, operation: operation) {
                try await C05RDPDomain.shared.probeCredential(reference)
            }.map { present in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "present": present,
                ] as [String: Any]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.credentialInvalid, "invalidCredential"), operation: operation)
        }
    }

    private static func credentialDelete(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let reference = try credentialReference(object["credential"], requireRDP: true)
            return run(seconds: 15, operation: operation) {
                try await C05RDPDomain.shared.deleteCredential(reference)
                return true
            }.map { _ in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                ] as [String: Any]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.credentialInvalid, "invalidCredential"), operation: operation)
        }
    }

    private static func trust(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let profileID = try requiredUUID(object["profileID"])
            let endpointID = try requiredUUID(object["endpointID"])
            guard let fingerprint = boundedString(object["fingerprintSHA256"], 96) else {
                throw C05RDPError(.invalidRequest, "invalidFingerprint")
            }
            return run(seconds: 20, operation: operation) {
                try await C05RDPDomain.shared.approveCertificate(
                    profileID: profileID,
                    endpointID: endpointID,
                    fingerprintSHA256: fingerprint,
                    owner: owner
                )
            }.map { report in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "profileID": report.profileID.uuidString,
                    "endpointID": report.endpointID.uuidString,
                    "fingerprintSHA256": report.fingerprintSHA256,
                    "approved": report.approved,
                ] as [String: Any]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func revokeTrust(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let profileID = try requiredUUID(object["profileID"])
            let endpointID = try requiredUUID(object["endpointID"])
            return run(seconds: 20, operation: operation) {
                try await C05RDPDomain.shared.revokeCertificate(
                    profileID: profileID,
                    endpointID: endpointID,
                    owner: owner
                )
            }.map { report in
                [
                    "ok": true,
                    "schema": C05RDPWire.schema,
                    "operation": operation,
                    "profileID": report.profileID.uuidString,
                    "endpointID": report.endpointID.uuidString,
                    "fingerprintSHA256": report.fingerprintSHA256,
                    "approved": report.approved,
                ] as [String: Any]
            }
        } catch let error as C05RDPError {
            return errorJSON(error, operation: operation)
        } catch {
            return errorJSON(C05RDPError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    // MARK: - Timeout runner

    private static func run<T: Sendable>(
        seconds: Double,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) -> RDPBlockResult<T> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = RDPResultBox<T>()
        let task = Task {
            do {
                box.set(.success(try await body()))
            } catch let error as C05RDPError {
                box.set(.failure(error))
            } catch let error as C05RemoteError {
                box.set(.failure(C05RDPDomain.map(error)))
            } catch is CancellationError {
                box.set(.failure(C05RDPError(.cancelled, "cancelled", retryable: true)))
            } catch {
                box.set(.failure(C05RDPError(
                    .internalFailure,
                    "rdpOperationFailed",
                    retryable: false,
                    detail: error.localizedDescription
                )))
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(Int(max(0.05, seconds) * 1_000))
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            return RDPBlockResult(
                operation: operation,
                result: .failure(C05RDPError(.timeout, "outcomeMayBeUnknown", retryable: false))
            )
        }
        guard let result = box.get() else {
            return RDPBlockResult(
                operation: operation,
                result: .failure(C05RDPError(.internalFailure, "missingOperationResult"))
            )
        }
        return RDPBlockResult(operation: operation, result: result)
    }

    // MARK: - JSON encoding

    private static func errorJSON(_ error: C05RDPError, operation: String?) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": error.code.rawValue,
            "reason": error.reason,
            "retryable": error.retryable,
            "schema": C05RDPWire.schema,
        ]
        if let operation { value["operation"] = operation }
        if let detail = error.detail { value["detail"] = detail }
        if let category = error.category { value["category"] = category }
        if let stage = error.stage { value["stage"] = stage }
        if let challenge = error.challenge { value["challenge"] = challengeJSON(challenge) }
        return value
    }

    private static func sessionJSON(_ session: C05RDPSessionSnapshot) -> [String: Any] {
        var value: [String: Any] = [
            "id": session.id.uuidString,
            "profileID": session.profileID.uuidString,
            "endpointID": session.endpointID.uuidString,
            "displayName": session.displayName,
            "host": session.host,
            "port": session.port,
            "username": session.username,
            "domain": session.domain,
            "state": session.state,
            "width": session.width,
            "height": session.height,
            "frameRevision": NSNumber(value: session.frameRevision),
            "frameBytes": session.frameBytes,
            "approvedFingerprintSHA256": session.approvedFingerprintSHA256 ?? NSNull(),
            "certificateChallenge": session.certificateChallenge.map(challengeJSON) ?? NSNull(),
            "createdAt": ISO8601DateFormatter().string(from: session.createdAt),
            "lastActivityAt": ISO8601DateFormatter().string(from: session.lastActivityAt),
            "failure": NSNull(),
        ]
        if let failure = session.failure {
            value["failure"] = [
                "code": failure.code,
                "message": failure.message,
                "retryable": failure.retryable,
                "category": failure.category,
                "stage": failure.stage,
                "fingerprintSHA256": failure.fingerprintSHA256 ?? NSNull(),
            ] as [String: Any]
        }
        return value
    }

    private static func challengeJSON(_ challenge: C05RDPCertificatePrompt) -> [String: Any] {
        var value: [String: Any] = [
            "profileID": challenge.profileID.uuidString,
            "endpointID": challenge.endpointID.uuidString,
            "host": challenge.host,
            "port": challenge.port,
            "fingerprintSHA256": challenge.fingerprintSHA256,
            "subject": challenge.subject,
            "kind": challenge.kind.rawValue,
            "reason": challenge.reason,
            "createdAt": ISO8601DateFormatter().string(from: challenge.createdAt),
            "expiresAt": ISO8601DateFormatter().string(from: challenge.expiresAt),
        ]
        value["notBefore"] = challenge.notBefore.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        value["notAfter"] = challenge.notAfter.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
        return value
    }

    private static func hostDetailJSON(_ detail: C05RDPHostDetail) -> [String: Any] {
        [
            "summary": [
                "id": detail.summary.id.uuidString,
                "displayName": detail.summary.displayName,
                "deviceKind": detail.summary.deviceKind,
                "isRemoteExecutionEnvironment": detail.summary.isRemoteExecutionEnvironment,
                "endpointCount": detail.summary.endpointCount,
            ] as [String: Any],
            "endpoints": detail.endpoints.map { endpoint in
                var value: [String: Any] = [
                    "id": endpoint.id.uuidString,
                    "displayName": endpoint.displayName,
                    "host": endpoint.host,
                    "port": endpoint.port,
                    "username": endpoint.username,
                    "domain": endpoint.domain,
                    "hasPassword": endpoint.hasPassword,
                    "approvedFingerprintSHA256": endpoint.approvedFingerprintSHA256 ?? NSNull(),
                ]
                if let reference = endpoint.passwordRef {
                    value["passwordRef"] = credentialReferenceJSON(reference)
                }
                return value
            },
        ]
    }

    private static func credentialReferenceJSON(_ reference: C05CredentialReference) -> [String: Any] {
        [
            "keychainAccount": reference.keychainAccount,
            "synchronizable": reference.synchronizable,
        ]
    }

    // MARK: - Decoding

    private static func owner(_ value: Any?) throws -> C05RemoteOwner {
        guard let object = value as? [String: Any],
              let token = boundedString(object["token"], 128),
              let epoch = uint64(object["nativeEpoch"]),
              epoch > 0 else {
            throw C05RDPError(.invalidOwner, "invalidOwner")
        }
        let taskID = try optionalUUID(object["taskID"])
        let temporary = bool(object["temporary"]) ?? false
        let owner = C05RemoteOwner(
            token: token,
            nativeEpoch: epoch,
            taskID: taskID,
            temporary: temporary
        )
        do {
            try owner.validate()
        } catch {
            throw C05RDPError(.invalidOwner, "invalidOwner")
        }
        return owner
    }

    private static func profileDraft(_ value: Any?) throws -> C05RDPProfileDraft {
        guard let object = value as? [String: Any],
              let displayName = boundedString(object["displayName"], 128),
              let deviceKind = boundedString(object["deviceKind"], 32) ?? "unspecified",
              let rawEndpoints = object["endpoints"] as? [Any],
              (1...C05RDPWire.maximumEndpointsPerProfile).contains(rawEndpoints.count) else {
            throw C05RDPError(.invalidProfile, "invalidProfile")
        }
        let id = try optionalUUID(object["id"])
        var endpoints: [C05RDPEndpointDraft] = []
        endpoints.reserveCapacity(rawEndpoints.count)
        for raw in rawEndpoints {
            guard let endpoint = raw as? [String: Any],
                  let host = boundedString(endpoint["host"], 255),
                  let username = boundedString(endpoint["username"], 256),
                  let port = exactInt(endpoint["port"]),
                  (1...65535).contains(port),
                  let display = boundedString(endpoint["displayName"], 64) else {
                throw C05RDPError(.invalidProfile, "invalidRDPEndpoint")
            }
            let endpointID = try optionalUUID(endpoint["id"]) ?? UUID()
            let domain = boundedString(endpoint["domain"], 256) ?? ""
            let reference = try optionalSecretReference(endpoint["passwordRef"])
            endpoints.append(C05RDPEndpointDraft(
                id: endpointID,
                displayName: display,
                host: host,
                port: port,
                username: username,
                domain: domain,
                passwordRef: reference
            ))
        }
        return C05RDPProfileDraft(
            id: id,
            displayName: displayName,
            deviceKind: deviceKind,
            endpoints: endpoints
        )
    }

    private static func inputEvents(_ value: Any?) throws -> [RDPFloeInputEvent] {
        guard let array = value as? [Any], !array.isEmpty, array.count <= C05RDPWire.maximumInputEvents else {
            throw C05RDPError(.inputInvalid, "invalidInputBatch")
        }
        var events: [RDPFloeInputEvent] = []
        events.reserveCapacity(array.count)
        var textBytes = 0
        for raw in array {
            guard let object = raw as? [String: Any],
                  let kind = boundedString(object["kind"], 32) else {
                throw C05RDPError(.inputInvalid, "invalidInputEvent")
            }
            switch kind {
            case "pointerMove":
                events.append(.pointerMove(
                    x: try coordinate(object["x"]),
                    y: try coordinate(object["y"])
                ))
            case "pointerButton":
                guard let buttonName = boundedString(object["button"], 16),
                      let button = RDPFloePointerButton(rawValue: buttonName),
                      let down = bool(object["down"]) else {
                    throw C05RDPError(.inputInvalid, "invalidPointerButton")
                }
                events.append(.pointerButton(
                    button: button,
                    down: down,
                    x: try coordinate(object["x"]),
                    y: try coordinate(object["y"])
                ))
            case "wheel":
                guard let up = bool(object["up"]),
                      let steps = exactInt(object["steps"]),
                      (1...20).contains(steps) else {
                    throw C05RDPError(.inputInvalid, "invalidWheel")
                }
                events.append(.wheel(
                    up: up,
                    x: try coordinate(object["x"]),
                    y: try coordinate(object["y"]),
                    steps: UInt32(steps)
                ))
            case "key":
                guard let scancode = exactInt(object["scancode"]),
                      (0...255).contains(scancode),
                      let down = bool(object["down"]) else {
                    throw C05RDPError(.inputInvalid, "invalidKey")
                }
                events.append(.key(
                    scancode: UInt8(scancode),
                    extended: bool(object["extended"]) ?? false,
                    down: down
                ))
            case "namedKey":
                guard let name = boundedString(object["key"], 32),
                      let expanded = RDPFloeKey.namedKeyEvents(name) else {
                    throw C05RDPError(.inputInvalid, "invalidNamedKey")
                }
                events.append(contentsOf: expanded)
            case "modifier":
                guard let name = boundedString(object["modifier"], 32),
                      let down = bool(object["down"]),
                      let expanded = RDPFloeKey.modifierEvents(name, down: down) else {
                    throw C05RDPError(.inputInvalid, "invalidModifier")
                }
                events.append(contentsOf: expanded)
            case "text":
                guard let text = object["text"] as? String,
                      !text.isEmpty,
                      text.utf8.count <= C05RDPWire.maximumTextBytes else {
                    throw C05RDPError(.inputInvalid, "invalidText")
                }
                textBytes += text.utf8.count
                guard textBytes <= C05RDPWire.maximumTextBytes else {
                    throw C05RDPError(.inputInvalid, "rdpTextTooLarge")
                }
                events.append(.text(text))
                if bool(object["submit"]) == true,
                   let returnEvents = RDPFloeKey.namedKeyEvents("return") {
                    events.append(contentsOf: returnEvents)
                }
            default:
                throw C05RDPError(.inputInvalid, "unsupportedInputKind")
            }
        }
        guard !events.isEmpty, events.count <= C05RDPWire.maximumInputEvents else {
            throw C05RDPError(.inputInvalid, "invalidInputBatch")
        }
        return events
    }

    private static func coordinate(_ value: Any?) throws -> UInt16 {
        guard let number = exactInt(value), (0...4_095).contains(number) else {
            throw C05RDPError(.inputInvalid, "invalidCoordinate")
        }
        return UInt16(number)
    }

    private static func optionalSecretReference(_ value: Any?) throws -> SecretReference? {
        guard let value else { return nil }
        let reference = try credentialReference(value, requireRDP: false)
        return SecretReference(
            keychainAccount: reference.keychainAccount,
            synchronizable: reference.synchronizable
        )
    }

    private static func credentialReference(
        _ value: Any?,
        requireRDP: Bool
    ) throws -> C05CredentialReference {
        guard let object = value as? [String: Any],
              let account = boundedString(object["keychainAccount"], 256),
              let synchronizable = bool(object["synchronizable"]) else {
            throw C05RDPError(.credentialInvalid, "invalidCredentialReference")
        }
        if requireRDP {
            guard account.hasPrefix(C05RDPWire.rdpCredentialPrefix) else {
                throw C05RDPError(.credentialInvalid, "rdpCredentialNamespaceRequired")
            }
        }
        return C05CredentialReference(
            keychainAccount: account,
            synchronizable: synchronizable
        )
    }

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

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private static func requiredUUID(_ value: Any?) throws -> UUID {
        guard let string = boundedString(value, 64), let id = UUID(uuidString: string) else {
            throw C05RDPError(.invalidRequest, "invalidIdentifier")
        }
        return id
    }

    private static func optionalUUID(_ value: Any?) throws -> UUID? {
        guard let value else { return nil }
        return try requiredUUID(value)
    }
}

// MARK: - Trusted frame JNI ABI

/// Negative status space (disjoint from the JSON bridge):
/// -101 unknown session/lease, -102 stale epoch, -105 invalid argument,
/// -106 buffer too small, -107 oversize, -108 encoding, -109 lease limit,
/// -110 no frame yet, -111 invalid offset, -112 not connected.
private let c05RDPFrameStatusInvalidArgument: Int32 = -105
private let c05RDPFrameStatusBufferTooSmall: Int32 = -106
private let c05RDPFrameStatusOversize: Int32 = -107
private let c05RDPFrameStatusEncoding: Int32 = -108
private let c05RDPFrameStatusLeaseLimit: Int32 = -109
private let c05RDPFrameStatusNoFrame: Int32 = -110
private let c05RDPFrameStatusInvalidOffset: Int32 = -111
private let c05RDPFrameStatusUnknown: Int32 = -101
private let c05RDPFrameStatusStale: Int32 = -102

private func c05RDPEncodeJSON(_ object: [String: Any]) -> Data? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return nil
    }
    return data
}

private func c05RDPCopyJSON(
    _ data: Data,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard let buffer, capacity > 0, data.count + 1 <= Int(capacity) else {
        return c05RDPFrameStatusBufferTooSmall
    }
    data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: data.count))
    buffer[data.count] = 0
    return Int32(data.count)
}

private func c05RDPStatus(_ error: C05RDPFrameBroker.BrokerError) -> Int32 {
    switch error {
    case .staleEpoch: return c05RDPFrameStatusStale
    case .unknownSession, .unknownLease: return c05RDPFrameStatusUnknown
    case .leaseLimit: return c05RDPFrameStatusLeaseLimit
    case .noFrame: return c05RDPFrameStatusNoFrame
    case .notConnected: return c05RDPFrameStatusNoFrame
    case .invalidOffset, .bufferTooSmall: return c05RDPFrameStatusInvalidArgument
    }
}

/// Acquire an immutable frame lease and return its bounded metadata JSON.
/// Request/response carry no pixel bytes; the caller reads 64 KiB pages via
/// `floe_rdp_frame_read` and releases the lease explicitly.
@_cdecl("floe_rdp_frame_acquire")
public func floeRDPFrameAcquire(
    _ epoch: UInt64,
    _ ownerToken: UnsafePointer<CChar>?,
    _ sessionID: UnsafePointer<CChar>?,
    _ buffer: UnsafeMutablePointer<CChar>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0, let ownerToken, let sessionID else {
        return c05RDPFrameStatusInvalidArgument
    }
    let ownerLength = strnlen(ownerToken, 129)
    let sessionLength = strnlen(sessionID, 65)
    guard ownerLength > 0, ownerLength <= 128, sessionLength == 36 else {
        return c05RDPFrameStatusInvalidArgument
    }
    let owner = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(ownerToken), count: ownerLength), as: UTF8.self)
    let sessionString = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(sessionID), count: sessionLength), as: UTF8.self)
    guard let sessionUUID = UUID(uuidString: sessionString) else {
        return c05RDPFrameStatusInvalidArgument
    }
    do {
        let result = try C05RDPFrameBroker.shared.acquire(
            epoch: epoch,
            ownerToken: owner,
            sessionID: sessionUUID
        )
        let frame = result.frame
        let metadata: [String: Any] = [
            "ok": true,
            "schema": C05RDPWire.schema,
            "leaseID": result.leaseID,
            "sessionID": sessionUUID.uuidString,
            "width": frame.width,
            "height": frame.height,
            "stride": frame.stride,
            "format": RDPFloeFrame.pixelFormat,
            "byteCount": frame.byteCount,
            "revision": NSNumber(value: frame.revision),
        ]
        guard let encoded = c05RDPEncodeJSON(metadata) else {
            C05RDPFrameBroker.shared.release(epoch: epoch, leaseID: result.leaseID)
            return c05RDPFrameStatusEncoding
        }
        return c05RDPCopyJSON(encoded, buffer, capacity)
    } catch let error as C05RDPFrameBroker.BrokerError {
        return c05RDPStatus(error)
    } catch {
        return c05RDPFrameStatusUnknown
    }
}

/// Copy one bounded page of an acquired frame. Returns the copied byte count,
/// 0 at the end of the frame, or a negative status.
@_cdecl("floe_rdp_frame_read")
public func floeRDPFrameRead(
    _ epoch: UInt64,
    _ leaseID: UnsafePointer<CChar>?,
    _ offset: Int64,
    _ target: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    guard epoch > 0, let leaseID, let target,
          offset >= 0, capacity > 0, capacity <= 65_536 else {
        return c05RDPFrameStatusInvalidArgument
    }
    let leaseLength = strnlen(leaseID, 65)
    guard leaseLength == 36 else { return c05RDPFrameStatusInvalidArgument }
    let lease = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(leaseID), count: leaseLength), as: UTF8.self)
    guard let offsetValue = Int(exactly: offset) else {
        return c05RDPFrameStatusInvalidOffset
    }
    do {
        let data = try C05RDPFrameBroker.shared.read(
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
    } catch let error as C05RDPFrameBroker.BrokerError {
        return c05RDPStatus(error)
    } catch {
        return c05RDPFrameStatusUnknown
    }
}

/// Idempotent release of one frame lease.
@_cdecl("floe_rdp_frame_release")
public func floeRDPFrameRelease(
    _ epoch: UInt64,
    _ leaseID: UnsafePointer<CChar>?
) -> Int32 {
    guard epoch > 0, let leaseID else { return c05RDPFrameStatusInvalidArgument }
    let leaseLength = strnlen(leaseID, 65)
    guard leaseLength == 36 else { return c05RDPFrameStatusInvalidArgument }
    let lease = String(decoding: UnsafeRawBufferPointer(
        start: UnsafeRawPointer(leaseID), count: leaseLength), as: UTF8.self)
    C05RDPFrameBroker.shared.release(epoch: epoch, leaseID: lease)
    return 0
}
