// SPDX-License-Identifier: MPL-2.0
//
// C05 host-only bridge `floe.remote/9`.
//
// Dispatched from the SAME frozen `floe_bridge_exchange` C ABI after the
// existing voice/7 and CAD/8 branches. The caller is the trusted App host
// UI; this channel is NOT a BridgeV3 command, NOT a model tool and does not
// widen any task/run/environment permission. A future model remote-execution
// path must use the ordinary execution authority with its own remote
// approval; nothing here grants guest/local permission or a model path.
//
// Requests/responses are bounded JSON. Secret bodies are accepted only by
// `c05.credential.save` (base64, <=40 KiB) and are written straight into the
// approved Android credential gateway; they are never echoed, logged or
// persisted by this bridge. Host-key fingerprints appear only in explicit
// challenge/approval responses so the user can compare them.

import Foundation
import FloeCore
import FloeSSH

public enum BridgeV9 {
    public static let version = 9
    public static let schema = C05RemoteWire.schema
    public static let maximumRequestBytes = C05RemoteWire.maximumRequestBytes
    public static let maximumResponseBytes = C05RemoteWire.maximumResponseBytes
    public static let modelTools = false
}

public enum C05RemoteBridge {
    private struct SessionStatusBundle: Sendable {
        let session: C05RemoteSessionSnapshot
        let ptys: [C05PTYSnapshot]
        let execs: [C05ExecSnapshot]
        let tunnels: [C05TunnelSnapshot]
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
                "schema": C05RemoteWire.schema,
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
        guard requestData.count <= C05RemoteWire.maximumRequestBytes else {
            return failure(C05RemoteError(.invalidRequest, "requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = exactInt(object["version"]),
              version == BridgeV9.version,
              let operation = boundedString(object["operation"], 64) else {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: nil)
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID

        switch operation {
        case "handshake", "c05.capabilities":
            return capabilities(operation: operation)
        case "c05.profile.list":
            return profileList(object, operation: operation)
        case "c05.profile.get":
            return profileGet(object, operation: operation)
        case "c05.profile.save":
            return profileSave(object, operation: operation)
        case "c05.profile.delete":
            return profileDelete(object, operation: operation)
        case "c05.credential.save":
            return credentialSave(object, operation: operation)
        case "c05.credential.probe":
            return credentialProbe(object, operation: operation)
        case "c05.credential.delete":
            return credentialDelete(object, operation: operation)
        case "c05.connect":
            return connect(object, operation: operation)
        case "c05.session.list":
            return sessionList(object, operation: operation)
        case "c05.session.status":
            return sessionStatus(object, operation: operation)
        case "c05.session.close":
            return sessionClose(object, operation: operation)
        case "c05.hostkey.list":
            return hostKeyList(object, operation: operation)
        case "c05.hostkey.approve":
            return hostKeyApprove(object, operation: operation)
        case "c05.pty.open":
            return ptyOpen(object, operation: operation)
        case "c05.pty.read":
            return ptyRead(object, operation: operation)
        case "c05.pty.write":
            return ptyWrite(object, operation: operation)
        case "c05.pty.resize":
            return ptyResize(object, operation: operation)
        case "c05.pty.close":
            return ptyClose(object, operation: operation)
        case "c05.pty.list":
            return ptyList(object, operation: operation)
        case "c05.exec.start":
            return execStart(object, operation: operation)
        case "c05.exec.read":
            return execRead(object, operation: operation)
        case "c05.exec.cancel":
            return execCancel(object, operation: operation)
        case "c05.exec.release":
            return execRelease(object, operation: operation)
        case "c05.exec.list":
            return execList(object, operation: operation)
        case "c05.tunnel.open":
            return tunnelOpen(object, operation: operation)
        case "c05.tunnel.list":
            return tunnelList(object, operation: operation)
        case "c05.tunnel.status":
            return tunnelStatus(object, operation: operation)
        case "c05.tunnel.close":
            return tunnelClose(object, operation: operation)
        case "c05.cancelAll":
            return cancelAll(object, operation: operation)
        case "c05.rootStop":
            return rootStop(object, operation: operation)
        default:
            return failure(C05RemoteError(.unsupportedOperation, "unsupportedOperation"), operation: operation)
        }
    }

    // MARK: - Operations

    private static func capabilities(operation: String) -> [String: Any] {
        block(seconds: 5, operation: operation) {
            await C05RemoteDomain.shared.capabilities()
        }.map { value in
            [
                "ok": true,
                "coreReady": value.coreReady,
                "epoch": value.epoch.map { NSNumber(value: $0) } ?? NSNull(),
                "credentialGatewayReady": value.credentialGatewayReady,
                "maximumProfiles": value.maximumProfiles,
                "maximumSessions": value.maximumSessions,
                "maximumPTYsPerSession": value.maximumPTYsPerSession,
                "maximumExecsPerSession": value.maximumExecsPerSession,
                "maximumTunnelsPerSession": value.maximumTunnelsPerSession,
                "maximumJumpHops": value.maximumJumpHops,
                "supportsPTY": value.supportsPTY,
                "supportsExec": value.supportsExec,
                "supportsTunnels": value.supportsTunnels,
                "supportsLegacyAlgorithms": value.supportsLegacyAlgorithms,
                "modelTools": value.modelTools,
            ]
        }
    }

    private static func profileList(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.listProfiles(owner: owner)
            }.map { list in
                [
                    "hosts": list.hosts.map(hostSummaryJSON),
                    "unreadableProfileIDs": list.unreadableProfileIDs.map(\.uuidString),
                ]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func profileGet(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let id = try requiredUUID(object["profileID"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.profileDetail(id: id, owner: owner)
            }.map { detail in
                ["host": hostDetailJSON(detail)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func profileSave(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            guard let profileObject = object["profile"] as? [String: Any] else {
                throw C05RemoteError(.invalidRequest, "missingProfile")
            }
            let profile = try C05RemoteProfileCodec.decode(profileObject)
            return block(seconds: 20, operation: operation) {
                try await C05RemoteDomain.shared.saveProfile(profile, owner: owner)
            }.map { detail in
                ["host": hostDetailJSON(detail)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidProfile, "invalidProfile"), operation: operation)
        }
    }

    private static func profileDelete(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let id = try requiredUUID(object["profileID"])
            return block(seconds: 25, operation: operation) {
                try await C05RemoteDomain.shared.deleteProfile(id: id, owner: owner)
            }.map { report in
                [
                    "deleted": report.deleted,
                    "closedSessions": report.closedSessions,
                    "closedTunnels": report.closedTunnels,
                ]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func credentialSave(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let reference = try credentialReference(object["credential"])
            guard let encoded = boundedString(object["secretBase64"], 60_000),
                  let secret = Data(base64Encoded: encoded),
                  !secret.isEmpty,
                  secret.count <= C05RemoteWire.maximumSecretBytes else {
                throw C05RemoteError(.credentialInvalid, "invalidCredentialValue")
            }
            return block(seconds: 20, operation: operation) {
                try await C05RemoteDomain.shared.saveCredential(
                    account: reference.keychainAccount,
                    synchronizable: reference.synchronizable,
                    secret: secret,
                    owner: owner
                )
            }.map { saved in
                ["reference": credentialReferenceJSON(saved)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func credentialProbe(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let reference = try credentialReference(object["credential"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.probeCredential(reference)
            }.map { present in
                ["present": present]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func credentialDelete(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let reference = try credentialReference(object["credential"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.deleteCredential(reference)
                return true
            }.map { _ in ["deleted": true] }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func connect(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let id = try requiredUUID(object["profileID"])
            return block(seconds: 30, operation: operation) {
                try await C05RemoteDomain.shared.connect(profileID: id, owner: owner)
            }.map { session in
                ["session": sessionJSON(session)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func sessionList(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.listSessions(owner: owner)
            }.map { sessions in
                ["sessions": sessions.map(sessionJSON)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func sessionStatus(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let id = try requiredUUID(object["sessionID"])
            return block(seconds: 10, operation: operation) {
                let session = try await C05RemoteDomain.shared.sessionStatus(id: id, owner: owner)
                let ptys = try await C05RemoteDomain.shared.listPTYs(sessionID: id, owner: owner)
                let execs = try await C05RemoteDomain.shared.listExecs(sessionID: id, owner: owner)
                let tunnels = try await C05RemoteDomain.shared.listTunnels(sessionID: id, owner: owner)
                return SessionStatusBundle(session: session, ptys: ptys, execs: execs, tunnels: tunnels)
            }.map { (value: SessionStatusBundle) -> [String: Any] in
                [
                    "session": sessionJSON(value.session),
                    "ptys": value.ptys.map(ptyJSON),
                    "execs": value.execs.map(execJSON),
                    "tunnels": value.tunnels.map(tunnelJSON),
                ]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func sessionClose(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let id = try requiredUUID(object["sessionID"])
            return block(seconds: 25, operation: operation) {
                try await C05RemoteDomain.shared.closeSession(id: id, owner: owner)
            }.map { report in
                [
                    "closed": true,
                    "complete": report.complete,
                    "closedPTYs": report.closedPTYs,
                    "closedExecs": report.closedExecs,
                    "closedTunnels": report.closedTunnels,
                ]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func hostKeyList(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.listHostKeyChallenges(owner: owner)
            }.map { values in
                ["challenges": values.map(challengeJSON)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func hostKeyApprove(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let id = try requiredUUID(object["challengeID"])
            let accept = bool(object["accept"]) ?? false
            let replaceChanged = bool(object["replaceChanged"]) ?? false
            let expected = boundedString(object["expectedFingerprint"], 128)
            return block(seconds: 15, operation: operation) {
                try await C05RemoteDomain.shared.approveHostKey(
                    id: id,
                    accept: accept,
                    replaceChanged: replaceChanged,
                    expectedFingerprint: expected,
                    owner: owner
                )
            }.map { approval in
                var value: [String: Any] = [
                    "trusted": approval.trusted,
                    "changed": approval.changed,
                    "challengeID": approval.challengeID.uuidString,
                ]
                if let fingerprint = approval.fingerprintSHA256 {
                    value["fingerprintSHA256"] = fingerprint
                }
                return value
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func ptyOpen(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            let columns = clampedInt(object["columns"], 20...500, default: 120)
            let rows = clampedInt(object["rows"], 5...200, default: 32)
            let term = boundedString(object["term"], 32)
            return block(seconds: 20, operation: operation) {
                try await C05RemoteDomain.shared.openPTY(
                    sessionID: sessionID,
                    term: term,
                    columns: columns,
                    rows: rows,
                    owner: owner
                )
            }.map { pty in
                ["pty": ptyJSON(pty)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func ptyRead(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let ptyID = try requiredUUID(object["ptyID"])
            let cursor = int64(object["cursor"]) ?? 0
            let maximum = clampedInt(object["maxBytes"], 1...C05RemoteWire.maximumReadBytes, default: 32 * 1_024)
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.readPTY(
                    ptyID: ptyID,
                    cursor: cursor,
                    maxBytes: maximum,
                    owner: owner
                )
            }.map { read in
                let merged = read.chunks.reduce(into: Data()) { value, chunk in value.append(chunk) }
                return [
                    "ptyID": read.ptyID.uuidString,
                    "state": read.state.rawValue,
                    "dataBase64": merged.base64EncodedString(),
                    "bytes": merged.count,
                    "nextCursor": NSNumber(value: read.nextCursor),
                    "lostBytes": NSNumber(value: read.lostBytes),
                    "totalBytes": NSNumber(value: read.totalBytes),
                    "rolledOverBytes": NSNumber(value: read.rolledOverBytes),
                ]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func ptyWrite(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let ptyID = try requiredUUID(object["ptyID"])
            guard let encoded = boundedString(object["dataBase64"], 60_000),
                  let data = Data(base64Encoded: encoded),
                  !data.isEmpty,
                  data.count <= 32 * 1_024 else {
                throw C05RemoteError(.invalidRequest, "invalidPTYWrite")
            }
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.writePTY(ptyID: ptyID, data: data, owner: owner)
            }.map { accepted in
                ["accepted": accepted]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func ptyResize(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let ptyID = try requiredUUID(object["ptyID"])
            let columns = clampedInt(object["columns"], 20...500, default: 120)
            let rows = clampedInt(object["rows"], 5...200, default: 32)
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.resizePTY(
                    ptyID: ptyID, columns: columns, rows: rows, owner: owner)
            }.map { pty in
                ["pty": ptyJSON(pty)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func ptyClose(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let ptyID = try requiredUUID(object["ptyID"])
            return block(seconds: 15, operation: operation) {
                try await C05RemoteDomain.shared.closePTY(ptyID: ptyID, owner: owner)
            }.map { report in
                [
                    "closed": true,
                    "complete": report.complete,
                    "ptyID": ptyID.uuidString,
                ]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func ptyList(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.listPTYs(sessionID: sessionID, owner: owner)
            }.map { values in
                ["ptys": values.map(ptyJSON)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func execStart(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            guard let command = boundedCommandString(
                object["command"], C05RemoteWire.maximumCommandBytes
            ) else {
                throw C05RemoteError(.invalidRequest, "missingCommand")
            }
            return block(seconds: 15, operation: operation) {
                try await C05RemoteDomain.shared.startExec(
                    sessionID: sessionID, command: command, owner: owner)
            }.map { exec in
                ["exec": execJSON(exec)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func execRead(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let execID = try requiredUUID(object["execID"])
            let cursor = int64(object["cursor"]) ?? 0
            let maximum = clampedInt(object["maxBytes"], 1...C05RemoteWire.maximumReadBytes, default: 32 * 1_024)
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.readExec(
                    execID: execID,
                    cursor: cursor,
                    maxBytes: maximum,
                    owner: owner
                )
            }.map { read in
                [
                    "exec": execJSON(read.snapshot),
                    "chunks": read.chunks.map {
                        ["channel": $0.channel, "dataBase64": $0.data.base64EncodedString()]
                    },
                    "nextCursor": NSNumber(value: read.nextCursor),
                    "lostBytes": NSNumber(value: read.lostBytes),
                ]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func execCancel(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let execID = try requiredUUID(object["execID"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.cancelExec(execID: execID, owner: owner)
            }.map { exec in
                ["exec": execJSON(exec)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func execRelease(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let execID = try requiredUUID(object["execID"])
            return block(seconds: 5, operation: operation) {
                try await C05RemoteDomain.shared.releaseExec(execID: execID, owner: owner)
            }.map { released in
                ["released": released]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func execList(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.listExecs(sessionID: sessionID, owner: owner)
            }.map { values in
                ["execs": values.map(execJSON)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func tunnelOpen(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            guard let targetHost = boundedString(object["targetHost"], 255) else {
                throw C05RemoteError(.invalidTarget, "missingTargetHost")
            }
            let targetPort = try requiredInt(object["targetPort"], 1...65535)
            return block(seconds: 15, operation: operation) {
                try await C05RemoteDomain.shared.openTunnel(
                    sessionID: sessionID,
                    targetHost: targetHost,
                    targetPort: targetPort,
                    owner: owner
                )
            }.map { tunnel in
                ["tunnel": tunnelJSON(tunnel)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func tunnelList(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let sessionID = try requiredUUID(object["sessionID"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.listTunnels(sessionID: sessionID, owner: owner)
            }.map { values in
                ["tunnels": values.map(tunnelJSON)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func tunnelStatus(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let tunnelID = try requiredUUID(object["tunnelID"])
            return block(seconds: 10, operation: operation) {
                try await C05RemoteDomain.shared.tunnelStatus(tunnelID: tunnelID, owner: owner)
            }.map { value in
                ["tunnel": tunnelJSON(value)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func tunnelClose(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            let tunnelID = try requiredUUID(object["tunnelID"])
            return block(seconds: 15, operation: operation) {
                try await C05RemoteDomain.shared.closeTunnel(tunnelID: tunnelID, owner: owner)
            }.map { tunnel in
                ["closed": true, "tunnel": tunnelJSON(tunnel)]
            }
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func cancelAll(_ object: [String: Any], operation: String) -> [String: Any] {
        do {
            let owner = try owner(object["owner"])
            return block(seconds: 25, operation: operation) {
                try await C05RemoteDomain.shared.cancelAll(owner: owner)
            }.map(rootStopJSON)
        } catch let error as C05RemoteError {
            return failure(error, operation: operation)
        } catch {
            return failure(C05RemoteError(.invalidRequest, "invalidRequest"), operation: operation)
        }
    }

    private static func rootStop(_ object: [String: Any], operation: String) -> [String: Any] {
        let expected = uint64(object["expectedEpoch"]) ?? 0
        guard expected > 0 else {
            return failure(C05RemoteError(.invalidRequest, "invalidNativeEpoch"), operation: operation)
        }
        return block(seconds: 30, operation: operation) {
            await C05RemoteDomain.shared.rootStop(expectedEpoch: expected)
        }.map(rootStopJSON)
    }

    // MARK: - JSON encoders (never include a secret)

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

    private static func hostDetailJSON(_ value: C05HostDetail) -> [String: Any] {
        var object = hostSummaryJSON(value.summary)
        object["jumpChain"] = value.jumpChain.map { hop in
            [
                "address": hop.address,
                "port": hop.port,
                "user": hop.user,
                "auth": authJSON(hop.auth),
            ]
        }
        object["vncEndpoints"] = value.vncEndpoints.map { endpoint in
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
        object["auxiliaryConnections"] = value.auxiliaryConnections.map { connection in
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

    private static func sessionJSON(_ value: C05RemoteSessionSnapshot) -> [String: Any] {
        [
            "id": value.id.uuidString,
            "profileID": value.profileID.uuidString,
            "displayName": value.displayName,
            "address": value.address,
            "port": value.port,
            "user": value.user,
            "state": value.state.rawValue,
            "transportConnected": value.transportConnected,
            "createdAt": ISO8601DateFormatter().string(from: value.createdAt),
            "lastActivityAt": ISO8601DateFormatter().string(from: value.lastActivityAt),
            "ptyCount": value.ptyCount,
            "execCount": value.execCount,
            "tunnelCount": value.tunnelCount,
        ]
    }

    private static func ptyJSON(_ value: C05PTYSnapshot) -> [String: Any] {
        [
            "id": value.id.uuidString,
            "sessionID": value.sessionID.uuidString,
            "state": value.state.rawValue,
            "columns": value.columns,
            "rows": value.rows,
            "totalBytes": NSNumber(value: value.totalBytes),
            "rolledOverBytes": NSNumber(value: value.rolledOverBytes),
        ]
    }

    private static func execJSON(_ value: C05ExecSnapshot) -> [String: Any] {
        var object: [String: Any] = [
            "id": value.id.uuidString,
            "sessionID": value.sessionID.uuidString,
            "state": value.state.rawValue,
            "stdoutBytes": NSNumber(value: value.stdoutBytes),
            "stderrBytes": NSNumber(value: value.stderrBytes),
            "rolledOverBytes": NSNumber(value: value.rolledOverBytes),
            "remoteOutcomeUnknown": value.remoteOutcomeUnknown,
        ]
        if let exitCode = value.exitCode { object["exitCode"] = Int(exitCode) }
        return object
    }

    private static func tunnelJSON(_ value: C05TunnelSnapshot) -> [String: Any] {
        var object: [String: Any] = [
            "id": value.id.uuidString,
            "sessionID": value.sessionID.uuidString,
            "targetHost": value.targetHost,
            "targetPort": value.targetPort,
            "localHost": value.localHost,
            "state": value.state.rawValue,
            "acceptedConnections": value.acceptedConnections,
            "activeConnections": value.activeConnections,
            "bytesToRemote": NSNumber(value: value.bytesToRemote),
            "bytesFromRemote": NSNumber(value: value.bytesFromRemote),
        ]
        if let port = value.localPort { object["localPort"] = Int(port) }
        if let code = value.lastErrorCode { object["lastErrorCode"] = code }
        return object
    }

    private static func rootStopJSON(_ value: C05RootStopReport) -> [String: Any] {
        [
            "drained": value.drained,
            "closedSessions": value.closedSessions,
            "closedPTYs": value.closedPTYs,
            "closedExecs": value.closedExecs,
            "closedTunnels": value.closedTunnels,
        ]
    }

    // MARK: - Bounded long-operation bridge

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, C05RemoteError>?
        func set(_ result: Result<T, C05RemoteError>) {
            lock.lock(); value = result; lock.unlock()
        }
        func get() -> Result<T, C05RemoteError>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private struct BlockResult<T: Sendable> {
        let operation: String
        let result: Result<T, C05RemoteError>

        func map(_ transform: (T) -> [String: Any]) -> [String: Any] {
            switch result {
            case .success(let value):
                var object = transform(value)
                object["ok"] = true
                object["schema"] = C05RemoteWire.schema
                object["operation"] = operation
                return object
            case .failure(let error):
                return C05RemoteBridge.failure(error, operation: operation)
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
            } catch let error as C05RemoteError {
                box.set(.failure(error))
            } catch is CancellationError {
                box.set(.failure(C05RemoteError(.cancelled, "cancelled", retryable: true)))
            } catch {
                box.set(.failure(C05RemoteError(
                    .internalFailure,
                    "remoteOperationFailed",
                    retryable: false,
                    detail: error.localizedDescription
                )))
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now() + .milliseconds(Int(max(0.05, seconds) * 1_000))
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            return BlockResult(
                operation: operation,
                result: .failure(C05RemoteError(
                    .timeout,
                    "outcomeMayBeUnknown",
                    retryable: false
                ))
            )
        }
        guard let result = box.get() else {
            return BlockResult(
                operation: operation,
                result: .failure(C05RemoteError(.internalFailure, "missingOperationResult"))
            )
        }
        return BlockResult(operation: operation, result: result)
    }

    private static func failure(_ error: C05RemoteError, operation: String?) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": error.code.rawValue,
            "reason": error.reason,
            "retryable": error.retryable,
            "schema": C05RemoteWire.schema,
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

    // MARK: - Request parsing

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

    private static func requiredUUID(_ value: Any?) throws -> UUID {
        guard let string = boundedString(value, 64), let id = UUID(uuidString: string) else {
            throw C05RemoteError(.invalidRequest, "invalidIdentifier")
        }
        return id
    }

    private static func requiredInt(_ value: Any?, _ range: ClosedRange<Int>) throws -> Int {
        guard let number = exactInt(value), range.contains(number) else {
            throw C05RemoteError(.invalidRequest, "invalidInteger")
        }
        return number
    }

    private static func credentialReference(_ value: Any?) throws -> C05CredentialReference {
        guard let object = value as? [String: Any],
              let account = boundedString(object["keychainAccount"], 80),
              account.hasPrefix("floe.ssh."),
              let synchronizable = bool(object["synchronizable"]) else {
            throw C05RemoteError(.credentialInvalid, "invalidCredentialReference")
        }
        return C05CredentialReference(
            keychainAccount: account,
            synchronizable: synchronizable
        )
    }

    private static func boundedString(_ value: Any?, _ maximumBytes: Int) -> String? {
        guard let string = value as? String,
              !string.isEmpty,
              string.utf8.count <= maximumBytes,
              !string.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return string
    }

    /// Shell commands legitimately contain newlines/tabs; only NUL and other
    /// control bytes are refused.
    private static func boundedCommandString(_ value: Any?, _ maximumBytes: Int) -> String? {
        guard let string = value as? String,
              !string.isEmpty,
              string.utf8.count <= maximumBytes,
              !string.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
                      && scalar.value != 9 && scalar.value != 10 && scalar.value != 13
              }) else { return nil }
        return string
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        return number.intValue
    }

    private static func clampedInt(_ value: Any?, _ range: ClosedRange<Int>, default defaultValue: Int) -> Int {
        guard let number = exactInt(value) else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, number))
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        return number.int64Value
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double else { return nil }
        return number.uint64Value
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

// MARK: - Profile request codec

/// Parses the closed profile JSON into the shared `RemoteHostProfile` value.
/// Only the approved credential reference crosses; a secret body never does.
enum C05RemoteProfileCodec {

    static func decode(_ object: [String: Any]) throws -> RemoteHostProfile {
        guard let displayName = trimmedString(object["displayName"], 128),
              let address = trimmedString(object["address"], 255),
              let port = integer(object["port"], 1...65535),
              let user = trimmedString(object["user"], 128),
              let authValue = object["auth"] else {
            throw C05RemoteError(.invalidProfile, "invalidProfileFields")
        }
        let id: UUID
        if let rawID = object["id"] {
            guard let raw = rawID as? String, let parsed = UUID(uuidString: raw) else {
                throw C05RemoteError(.invalidProfile, "invalidProfileID")
            }
            id = parsed
        } else {
            id = UUID()
        }
        let auth = try decodeAuth(authValue)
        let jumpChain = try decodeJumpChain(object["jumpChain"])
        let policy = try decodePolicy(object["hostKeyPolicy"])
        let allowsLegacy = boolean(object["allowsLegacyAlgorithms"]) ?? false
        let deviceKind: RemoteDeviceKind
        if let value = object["deviceKind"] as? String {
            guard let parsed = RemoteDeviceKind(rawValue: value) else {
                throw C05RemoteError(.invalidProfile, "invalidDeviceKind")
            }
            deviceKind = parsed
        } else {
            deviceKind = .unspecified
        }
        let isRemote = boolean(object["isRemoteExecutionEnvironment"]) ?? true
        let vncEndpoints = try decodeVNCEndpoints(object["vncEndpoints"])
        let auxiliary = try decodeAuxiliary(object["auxiliaryConnections"])
        let profile = RemoteHostProfile(
            id: id,
            displayName: displayName,
            address: address,
            port: port,
            user: user,
            auth: auth,
            jumpChain: jumpChain,
            hostKeyPolicy: policy,
            allowsLegacyAlgorithms: allowsLegacy,
            deviceKind: deviceKind,
            isRemoteExecutionEnvironment: isRemote,
            vncEndpoints: vncEndpoints,
            auxiliaryConnections: auxiliary
        )
        do {
            try profile.validate()
        } catch {
            throw C05RemoteError(.invalidProfile, "invalidProfile", detail: error.localizedDescription)
        }
        return profile
    }

    private static func decodeAuth(_ value: Any) throws -> SSHAuthMethod {
        guard let object = value as? [String: Any],
              let kind = object["kind"] as? String else {
            throw C05RemoteError(.invalidProfile, "invalidAuth")
        }
        switch kind {
        case "none":
            return .none
        case "password":
            let reference = try decodeCredential(object["credential"])
            return .password(reference)
        case "importedKey", "deviceGeneratedKey":
            let reference = try decodeCredential(object["credential"])
            guard let keyValue = object["keyType"] as? String,
                  let keyType = SSHAuthMethod.SSHKeyType(rawValue: keyValue) else {
                throw C05RemoteError(.invalidProfile, "invalidKeyType")
            }
            return kind == "importedKey"
                ? .importedKey(reference, keyType: keyType)
                : .deviceGeneratedKey(reference, keyType: keyType)
        default:
            throw C05RemoteError(.invalidProfile, "invalidAuthKind")
        }
    }

    private static func decodeCredential(_ value: Any?) throws -> SecretReference {
        guard let object = value as? [String: Any],
              let account = trimmedString(object["keychainAccount"], 80),
              account.hasPrefix("floe.ssh."),
              let synchronizable = boolean(object["synchronizable"]) else {
            throw C05RemoteError(.credentialInvalid, "invalidCredentialReference")
        }
        return SecretReference(keychainAccount: account, synchronizable: synchronizable)
    }

    private static func decodeVncCredential(_ value: Any?) throws -> SecretReference {
        guard let object = value as? [String: Any],
              let account = trimmedString(object["keychainAccount"], 80),
              // C05 VNC package: a profile reference must never be able to
              // name an SSH/provider credential. VNC reads enforce the same
              // namespace again in C05VNCDomain; this closes the save path.
              account.hasPrefix("floe.vnc."),
              let synchronizable = boolean(object["synchronizable"]) else {
            throw C05RemoteError(.credentialInvalid, "invalidVNCReference")
        }
        return SecretReference(keychainAccount: account, synchronizable: synchronizable)
    }

    private static func decodeJumpChain(_ value: Any?) throws -> [JumpHop] {
        guard let value else { return [] }
        guard let array = value as? [Any], array.count <= C05RemoteWire.maximumJumpHops else {
            throw C05RemoteError(.invalidProfile, "invalidJumpChain")
        }
        return try array.map { item in
            guard let object = item as? [String: Any],
                  let address = trimmedString(object["address"], 255),
                  let port = integer(object["port"], 1...65535),
                  let user = trimmedString(object["user"], 128),
                  let authValue = object["auth"] else {
                throw C05RemoteError(.invalidProfile, "invalidJumpHop")
            }
            return JumpHop(
                address: address,
                port: port,
                user: user,
                auth: try decodeAuth(authValue)
            )
        }
    }

    private static func decodePolicy(_ value: Any?) throws -> HostKeyPolicy {
        guard let object = value as? [String: Any],
              let kind = object["kind"] as? String else {
            throw C05RemoteError(.invalidProfile, "invalidHostKeyPolicy")
        }
        switch kind {
        case "trustOnFirstUse":
            return .trustOnFirstUse
        case "pinned":
            guard let fingerprint = object["fingerprintSHA256"] as? String,
                  SSHHostKeyFingerprint.isValid(fingerprint) else {
                throw C05RemoteError(.invalidProfile, "invalidPinnedFingerprint")
            }
            return .pinned(fingerprintSHA256: SSHHostKeyFingerprint.normalize(fingerprint))
        default:
            throw C05RemoteError(.invalidProfile, "invalidHostKeyPolicy")
        }
    }

    private static func decodeVNCEndpoints(_ value: Any?) throws -> [VNCEndpoint] {
        guard let value else { return [] }
        guard let array = value as? [Any], array.count <= 8 else {
            throw C05RemoteError(.invalidProfile, "invalidVNCEndpoints")
        }
        return try array.map { item in
            guard let object = item as? [String: Any] else {
                throw C05RemoteError(.invalidProfile, "invalidVNCEndpoint")
            }
            let id: UUID
        if let rawID = object["id"] {
            guard let raw = rawID as? String, let parsed = UUID(uuidString: raw) else {
                throw C05RemoteError(.invalidProfile, "invalidProfileID")
            }
            id = parsed
        } else {
            id = UUID()
        }
            let displayName = trimmedString(object["displayName"], 64) ?? "VNC"
            let transportValue = (object["transport"] as? String) ?? VNCTransport.sshTunnel.rawValue
            guard let transport = VNCTransport(rawValue: transportValue) else {
                throw C05RemoteError(.invalidProfile, "invalidVNCTransport")
            }
            let host = (object["host"] as? String) ?? "localhost"
            let port = integer(object["port"], 1...65535) ?? 5900
            let passwordRef: SecretReference?
            if let raw = object["passwordRef"] {
                passwordRef = try decodeVncCredential(raw)
            } else {
                passwordRef = nil
            }
            let endpoint = VNCEndpoint(
                id: id,
                displayName: displayName,
                transport: transport,
                host: host,
                port: port,
                passwordRef: passwordRef
            )
            do {
                try endpoint.validate()
            } catch {
                throw C05RemoteError(.invalidProfile, "invalidVNCEndpoint")
            }
            return endpoint
        }
    }

    private static func decodeAuxiliary(_ value: Any?) throws -> [RemoteAuxiliaryConnection] {
        guard let value else { return [] }
        guard let array = value as? [Any], array.count <= 8 else {
            throw C05RemoteError(.invalidProfile, "invalidAuxiliaryConnections")
        }
        return try array.map { item in
            guard let object = item as? [String: Any],
                  let kindValue = object["kind"] as? String,
                  let kind = RemoteAuxiliaryConnectionKind(rawValue: kindValue),
                  let displayName = trimmedString(object["displayName"], 64) else {
                throw C05RemoteError(.invalidProfile, "invalidAuxiliaryConnection")
            }
            let connection = RemoteAuxiliaryConnection(
                id: (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
                displayName: displayName,
                kind: kind,
                host: object["host"] as? String,
                port: integer(object["port"], 1...65535),
                bluetoothPeripheralID: (object["bluetoothPeripheralID"] as? String).flatMap(UUID.init(uuidString:)),
                bluetoothServiceUUID: object["bluetoothServiceUUID"] as? String,
                bluetoothWriteCharacteristicUUID: object["bluetoothWriteCharacteristicUUID"] as? String,
                bluetoothNotifyCharacteristicUUID: object["bluetoothNotifyCharacteristicUUID"] as? String
            )
            do {
                try connection.validate()
            } catch {
                throw C05RemoteError(.invalidProfile, "invalidAuxiliaryConnection")
            }
            return connection
        }
    }

    private static func trimmedString(_ value: Any?, _ maximumBytes: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return trimmed
    }

    private static func integer(_ value: Any?, _ range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        let converted = number.intValue
        return range.contains(converted) ? converted : nil
    }

    private static func boolean(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}
