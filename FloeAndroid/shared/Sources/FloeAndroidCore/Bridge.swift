// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeModels

public enum AndroidBridge {
    public static let version = 1
    public static let maximumBytes = 65_536

    public static func exchange(_ data: Data) -> Data {
        var requestID: String?
        func response(_ object: [String: Any], stampVersion: Int = version) -> Data {
            var value = object
            value["version"] = stampVersion
            value["requestID"] = requestID
            return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
                ?? Data("{\"version\":1,\"ok\":false,\"error\":\"encoding\"}".utf8)
        }
        guard data.count <= maximumBytes else { return response(["ok": false, "error": "requestTooLarge"]) }
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return response(["ok": false, "error": "invalidJSON"])
        }
        requestID = request["requestID"] as? String
        // Append-only dispatch: version 1 keeps the exact frozen G01 path
        // below; version 2 adds the typed command/event envelope seam
        // (BridgeEnvelope.swift); version 3 adds the explicit integer wire
        // branch with launch/lifecycle/config/run scopes and the async
        // operation-effect cursor (BridgeEnvelopeV3.swift). Any other
        // version fails closed. v1 and v2 behavior is unchanged.
        let requestVersion = request["version"] as? Int
        guard requestVersion == version || requestVersion == BridgeV2.version
                || requestVersion == BridgeV3.version
                || requestVersion == BridgeV4.version else {
            return response(["ok": false, "error": "unsupportedVersion"])
        }
        if requestVersion == BridgeV2.version {
            return response(BridgeV2.handle(request: request, requestID: requestID),
                            stampVersion: BridgeV2.version)
        }
        if requestVersion == BridgeV3.version {
            return response(BridgeV3.handle(request: request, requestID: requestID),
                            stampVersion: BridgeV3.version)
        }
        if requestVersion == BridgeV4.version {
            // Additive G06 Notes channel: same C ABI, dedicated action/event
            // schema, no task/run/provider authority. v1/v2/v3 bytes below
            // remain unchanged.
            let object = BridgeV4.handle(requestData: data, fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= BridgeV4.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV4.version)
            }
            return response(object, stampVersion: BridgeV4.version)
        }
        switch request["operation"] as? String {
        case "handshake":
            return response(["ok": true, "core": "FloeAndroidCore", "sharedModels": ["TaskPolicy"],
                             "operations": ["handshake", "policy.inspect"], "localLLM": false])
        case "policy.inspect":
            guard let object = request["policy"], JSONSerialization.isValidJSONObject(object),
                  let encoded = try? JSONSerialization.data(withJSONObject: object),
                  let policy = try? JSONDecoder().decode(DraftTaskPolicy.self, from: encoded) else {
                return response(["ok": false, "error": "invalidPolicy"])
            }
            // These decisions execute the exact iOS TaskPolicy.swift implementation.
            return response(["ok": true, "approvalMode": policy.approvalMode.rawValue,
                             "recoveryPolicy": policy.recoveryPolicy.rawValue,
                             "notificationPolicy": policy.notificationPolicy.rawValue,
                             "notifySuccess": policy.notificationPolicy.shouldNotifyTerminal(succeeded: true),
                             "notifyFailure": policy.notificationPolicy.shouldNotifyTerminal(succeeded: false),
                             "notifyCancellation": policy.notificationPolicy.shouldNotifyCancellation,
                             "notifyApproval": policy.notificationPolicy.shouldNotifyApproval,
                             "echo": request["echo"] as? String ?? ""])
        default: return response(["ok": false, "error": "unsupportedOperation"])
        }
    }
}

@_cdecl("floe_bridge_exchange")
public func floeBridgeExchange(_ request: UnsafePointer<CChar>?) -> UnsafePointer<CChar>? {
    guard let request else { return nil }
    let length = strnlen(request, AndroidBridge.maximumBytes + 1)
    let data = Data(bytes: request, count: length)
    let response = AndroidBridge.exchange(data)
    let output = UnsafeMutablePointer<CChar>.allocate(capacity: response.count + 1)
    response.copyBytes(to: UnsafeMutableRawBufferPointer(start: output, count: response.count))
    output[response.count] = 0
    return UnsafePointer(output)
}

@_cdecl("floe_bridge_free")
public func floeBridgeFree(_ response: UnsafePointer<CChar>?) {
    UnsafeMutablePointer(mutating: response)?.deallocate()
}
