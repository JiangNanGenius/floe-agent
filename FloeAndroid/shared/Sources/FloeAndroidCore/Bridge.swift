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
                || requestVersion == BridgeV4.version
                || requestVersion == BridgeV5.version
                || requestVersion == BridgeV6.version
                || requestVersion == BridgeV7.version
                || requestVersion == BridgeV8.version
                || requestVersion == BridgeV9.version
                || requestVersion == BridgeV10.version
                || requestVersion == BridgeV11.version
                || requestVersion == BridgeV12.version
                || requestVersion == BridgeV13.version
                || requestVersion == BridgeV14.version else {
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
        if requestVersion == BridgeV5.version {
            // Additive G09 creative channel: Canvas/media project storage.
            // Same C ABI, host-only closed actions, no task/run/provider
            // authority. v1-v4 bytes above remain unchanged.
            let object = BridgeV5.handle(requestData: data, fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= BridgeV5.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV5.version)
            }
            return response(object, stampVersion: BridgeV5.version)
        }
        if requestVersion == BridgeV6.version {
            // Additive G09-R2 channel: typed video read/apply plus the
            // closed generation/design vocabulary (typed unavailable until
            // their real modules exist). Same C ABI, host-only, no model
            // tool. v1-v5 bytes above remain unchanged.
            let object = BridgeV6Handler.handle(requestData: data,
                                                fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= BridgeV6.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV6.version)
            }
            return response(object, stampVersion: BridgeV6.version)
        }
        if requestVersion == BridgeV7.version {
            // Additive C03 voice channel: capabilities, bounded cloud ASR/TTS
            // lifecycle and timed subtitle write-back. Same C ABI, host-only,
            // no model tool; v1-v6 bytes above remain unchanged.
            let object = C03VoiceBridge.handle(requestData: data,
                                               fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= BridgeV7.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV7.version)
            }
            return response(object, stampVersion: BridgeV7.version)
        }
        if requestVersion == BridgeV8.version {
            // Additive C04A host-only CAD/3D viewer contract: session/resource
            // grants, rendered-frame readiness, PNG capture receipts and the
            // C04B .floecad package validator. No model tool, no file bytes.
            // v1-v7 bytes above remain unchanged.
            let object = C04CadBridge.handle(requestData: data,
                                             fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C04CadWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV8.version)
            }
            return response(object, stampVersion: BridgeV8.version)
        }
        if requestVersion == BridgeV9.version {
            // Additive C05 host-only SSH remote channel: profile/credential
            // management, explicit host-key decisions, sessions, PTYs,
            // bounded exec and loopback tunnels. No model tool, no V3
            // command, no guest/local permission.
            let object = C05RemoteBridge.handle(requestData: data,
                                                fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C05RemoteWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV9.version)
            }
            return response(object, stampVersion: BridgeV9.version)
        }
        if requestVersion == BridgeV10.version {
            // Additive C06 host-only live-capture contract: owner/limit
            // validation and monotonic session snapshots. No packet bytes,
            // file path, model command or root executable crosses this ABI.
            let object = C06PacketCaptureBridge.handle(requestData: data,
                                                       fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= BridgeV10.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV10.version)
            }
            return response(object, stampVersion: BridgeV10.version)
        }
        if requestVersion == BridgeV11.version {
            // Additive C05 VNC host-only channel: profile/credential namespaced
            // VNC endpoints, real RFB sessions and metadata/input. Pixels use
            // the separate trusted frame JNI lane. No model tool, no V3
            // command, no guest/local permission.
            let object = C05VNCBridge.handle(requestData: data,
                                             fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C05VNCWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV11.version)
            }
            return response(object, stampVersion: BridgeV11.version)
        }
        if requestVersion == BridgeV12.version {
            // Additive C06 host-only generic mail channel: IMAP/POP3 + SMTP
            // account settings, read/search/body, attachment staging and the
            // declared mutation/send operations over the App-owned platform
            // TLS lane. Model tools use the ordinary registry separately; the
            // V1-V10 branches above are byte-identical.
            let object = C06MailBridge.handle(requestData: data,
                                              fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C06MailWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV12.version)
            }
            return response(object, stampVersion: BridgeV12.version)
        }
        if requestVersion == BridgeV13.version {
            // Additive C06 system-calendar/todo channel: real permission and
            // provider state pushed by the trusted App host, plus App-local
            // todo CRUD/reminder plans over the ONE original database. The
            // CalendarContract write itself travels the reverse provider
            // mailbox; model tools use the ordinary registry. V1-V12 branches
            // above are byte-identical.
            let object = C06CalendarBridge.handle(requestData: data,
                                                  fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C06CalendarWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV13.version)
            }
            return response(object, stampVersion: BridgeV13.version)
        }
        if requestVersion == BridgeV14.version {
            // Additive C05 host-only device-profile channel: saved
            // TCP/Telnet/BLE endpoint metadata and capabilities over the
            // EXISTING hosts rows. Live device bytes stay in the App-owned
            // Kotlin engine lane; no session body crosses this JSON channel.
            // No model route, no V3 command, no permission grant.
            let object = C05DeviceBridge.handle(requestData: data,
                                                fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C05DeviceWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV14.version)
            }
            return response(object, stampVersion: BridgeV14.version)
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
