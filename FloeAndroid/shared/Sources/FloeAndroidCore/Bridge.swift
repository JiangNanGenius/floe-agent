// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeSharedModels

public enum AndroidBridge {
    public static let version = 1
    public static let maximumBytes = 65_536

    public static func exchange(_ data: Data) -> Data {
        var requestID: String?
        func response(_ object: [String: Any]) -> Data {
            var value = object
            value["version"] = version
            value["requestID"] = requestID
            return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
                ?? Data("{\"version\":1,\"ok\":false,\"error\":\"encoding\"}".utf8)
        }
        guard data.count <= maximumBytes else { return response(["ok": false, "error": "requestTooLarge"]) }
        guard let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return response(["ok": false, "error": "invalidJSON"])
        }
        requestID = request["requestID"] as? String
        guard request["version"] as? Int == version else { return response(["ok": false, "error": "unsupportedVersion"]) }
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
