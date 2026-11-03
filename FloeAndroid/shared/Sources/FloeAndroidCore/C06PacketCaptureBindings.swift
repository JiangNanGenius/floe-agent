// SPDX-License-Identifier: MPL-2.0
//
// C06 host-only bridge `floe.capture/10`.
//
// The App's Kotlin capture host is the only caller. It sends typed owner/limit
// and state snapshots; it never sends packet bytes, a file path, a model
// command or a root executable. The bridge validates the closed vocabulary and
// monotonic session contract; real capture/forwarding stays in the App host.
import Foundation

public enum BridgeV10 {
    public static let version = C06CaptureWire.version
    public static let schema = C06CaptureWire.schema
    public static let maximumRequestBytes = C06CaptureWire.maximumRequestBytes
    public static let maximumResponseBytes = C06CaptureWire.maximumResponseBytes
}

public enum C06PacketCaptureBridge {
    public static func handle(requestData: Data,
                              fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: C06CaptureError, operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code,
                "reason": error.reason,
                "schema": C06CaptureWire.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            return value
        }
        func success(_ fields: [String: Any], operation: String) -> [String: Any] {
            var value = fields
            value["ok"] = true
            value["schema"] = C06CaptureWire.schema
            value["operation"] = operation
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C06CaptureWire.maximumRequestBytes else {
            return failure(.requestTooLarge, operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any],
              let version = c06Int(object["version"]),
              version == C06CaptureWire.version,
              let operation = c06String(object["operation"], maxBytes: 64) else {
            return failure(.invalidRequest, operation: nil)
        }
        requestID = c06String(object["requestID"], maxBytes: 256) ?? requestID
        do {
            switch operation {
            case "handshake":
                return success(handshake(), operation: operation)
            case "c06.capture.begin":
                let request = try C06CaptureRequest.parse(object["request"])
                let snapshot = try C06CaptureRegistry.shared.begin(request)
                return success([
                    "sessionId": snapshot.sessionID,
                    "state": snapshot.wire,
                    "request": request.wire,
                ], operation: operation)
            case "c06.capture.update":
                let snapshot = try C06CaptureSnapshot.parse(object["state"])
                let accepted = try C06CaptureRegistry.shared.update(snapshot)
                return success(["state": accepted.wire], operation: operation)
            case "c06.capture.finish":
                let snapshot = try C06CaptureSnapshot.parse(object["state"])
                let terminal = try C06CaptureRegistry.shared.finish(snapshot)
                return success(["state": terminal.wire], operation: operation)
            case "c06.capture.status":
                if let sessionID = c06String(object["sessionId"], maxBytes: 64) {
                    guard let snapshot = C06CaptureRegistry.shared.snapshot(sessionID: sessionID) else {
                        throw C06CaptureError.staleSession
                    }
                    return success(["state": snapshot.wire], operation: operation)
                }
                return success([
                    "active": C06CaptureRegistry.shared.activeSnapshots().map(\.wire),
                    "activeCount": C06CaptureRegistry.shared.activeCount(),
                ], operation: operation)
            case "c06.capture.cancelAll":
                return success([
                    "cancelled": C06CaptureRegistry.shared.cancelAll(),
                ], operation: operation)
            default:
                return failure(.unsupportedOperation, operation: operation)
            }
        } catch let error as C06CaptureError {
            return failure(error, operation: operation)
        } catch {
            return failure(.invalidRequest, operation: operation)
        }
    }

    private static func handshake() -> [String: Any] {
        [
            "version": C06CaptureWire.version,
            "schema": C06CaptureWire.schema,
            "operations": C06CaptureWire.operations,
            "modes": C06CaptureMode.allCases.map(\.rawValue),
            "phases": [
                "consentRequired", "starting", "running", "stopping",
                "finalizing", "completed", "failed", "unsupported", "cancelled",
            ],
            "limits": [
                "vpnDurationMillis": C06CaptureLimits.vpnDurationMillis,
                "rootDurationMillis": C06CaptureLimits.rootDurationMillis,
                "maximumBytes": C06CaptureLimits.maximumBytes,
                "maximumPackets": C06CaptureLimits.maximumPackets,
                "maximumOwnerBytes": C06CaptureLimits.maximumOwnerBytes,
                "maximumLimitations": C06CaptureLimits.maximumLimitations,
            ],
            "rootHelpers": [
                "tcpdump-v1": [
                    "interface": "any",
                    "sourceBound": true,
                    "downloadedByApp": false,
                ],
            ],
            "privacy": [
                "encryptedTrafficForwardedUnchanged": true,
                "tlsMitm": false,
                "automaticUpload": false,
            ],
        ]
    }
}
