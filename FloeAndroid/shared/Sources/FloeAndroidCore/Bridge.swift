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
                || requestVersion == BridgeV19.version
                || requestVersion == BridgeV20.version
                || requestVersion == BridgeV10.version
                || requestVersion == BridgeV11.version
                || requestVersion == BridgeV12.version
                || requestVersion == BridgeV13.version
                || requestVersion == BridgeV14.version
                || requestVersion == BridgeV15.version
                || requestVersion == BridgeV16.version
                || requestVersion == BridgeV17.version
                || requestVersion == BridgeV18.version
                || requestVersion == BridgeV22.version
                || requestVersion == BridgeV21.version
                || requestVersion == BridgeV24.version
                || requestVersion == BridgeV23.version
                || requestVersion == BridgeV25.version else {
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
        if requestVersion == BridgeV19.version {
            // Additive C02 host-only execution-target channel. It exposes the
            // durable per-task target, explicit migration and host-key
            // approval. It is not a model tool and does not grant SSH/local
            // execution; model commands still use the ordinary exec.shell
            // authority and its remote approval.
            guard let composition = G02RuntimeComposition.shared.installedComposition,
                  composition.epoch == G02NativeRootEpoch.readback(),
                  let target = composition.executionTargets else {
                return response(["ok": false, "error": "notInstalled"],
                                stampVersion: BridgeV19.version)
            }
            let object = target.bridge.handle(requestData: data,
                                              fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C02ExecutionTargetWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV19.version)
            }
            return response(object, stampVersion: BridgeV19.version)
        }
        if requestVersion == BridgeV20.version {
            // Additive C02 host-only tool-result channel. It pages one task's
            // already-redacted captured results for the existing tool-history
            // detail entry; it is not a model tool, grants no permission and
            // never accepts a path. Model retrieval uses the registered
            // `tools.readResult` runner with its trusted ToolContext.
            guard let runtime = C02ToolResultIntegration.current else {
                let object: [String: Any] = [
                    "ok": false,
                    "code": "notInstalled",
                    "message": "Tool result retention is not bound for this runtime generation.",
                    "retryable": false,
                    "schema": C02ToolResultWire.schema,
                ]
                return response(object, stampVersion: BridgeV20.version)
            }
            let object = runtime.handle(requestData: data,
                                        fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C02ToolResultWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV20.version)
            }
            return response(object, stampVersion: BridgeV20.version)
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
        if requestVersion == BridgeV15.version {
            // Additive C06 host-services channel: real permission/provider/
            // foreground projections and the closed system-service mailbox
            // capability check. Platform data never crosses this JSON channel
            // except bounded tickets/replies over the reverse mailbox; model
            // tools use the ordinary registry. V1-V14 branches above are
            // byte-identical; V16 remains below.
            let object = C06SystemBridge.handle(requestData: data,
                                                fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C06SystemWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV15.version)
            }
            return response(object, stampVersion: BridgeV15.version)
        }
        if requestVersion == BridgeV16.version {
            // Additive C07 host-only data-exchange channel: backup/restore
            // staging, bounded chunk transfer, portable note export and the
            // restore journal. No model tool, V3 command, SAF/network grant
            // or live database/WAL is copied. V1-V14 branches above remain
            // byte-identical.
            let object = C07DataExchangeBridge.handle(requestData: data,
                                                      fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C07DataExchangeWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV16.version)
            }
            return response(object, stampVersion: BridgeV16.version)
        }
        if requestVersion == BridgeV17.version {
            // Additive C05 host-only RDP channel: original-profile RDP
            // endpoints, explicit certificate fingerprint decisions, real
            // FreeRDP sessions, bounded input and the frame metadata lane.
            // No model tool, V3 command, SSH/SPICE fallback or pixel payload
            // crosses this JSON channel. V1-V16 branches above remain
            // byte-identical.
            let object = C05RDPBridge.handle(requestData: data,
                                             fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C05RDPWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV17.version)
            }
            return response(object, stampVersion: BridgeV17.version)
        }
        if requestVersion == BridgeV23.version {
            // Additive C02 host-only MCP guided-setup channel. It exposes
            // explicit project/environment facts, template staging, bounded
            // dependency jobs, the C01 service lane and the ORIGINAL MCP
            // client/domain verification/save. No model tool, credential,
            // raw path or absolute workspace path crosses this ABI. V1-V18
            // branches above remain byte-identical.
            guard let runtime = C02MCPSetupIntegration.current else {
                return response(["ok": false, "error": "mcpSetupUnavailable"],
                                stampVersion: BridgeV23.version)
            }
            let object = C02MCPSetupBridge.handle(
                requestData: data,
                fallbackRequestID: requestID,
                runtime: runtime.bridge)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= BridgeV23.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV23.version)
            }
            return response(object, stampVersion: BridgeV23.version)
        }
        if requestVersion == BridgeV18.version {
            // Additive C05 host-only SFTP channel: real remote directory
            // browsing and owned upload/download lanes over the existing
            // Citadel SSH/known-host/credential services. No model tool, V3
            // command, guest/local permission or local path alias.
            let object = C05SFTPBridge.handle(requestData: data,
                                              fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C05SFTPWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV18.version)
            }
            return response(object, stampVersion: BridgeV18.version)
        }
        if requestVersion == BridgeV22.version {
            // Additive C05 host-only desktop-assist channel: secret-free
            // secure-credential-card metadata and the settings-side one-time
            // card write/delete. Model typing stays on the ordinary
            // vnc/rdp.typeCredential tool path; OCR stays inside the task's
            // Linux environment. V1-V18 branches above remain byte-identical.
            let object = C05DesktopAssistBridge.handle(requestData: data,
                                                       fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C05DesktopAssistWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV22.version)
            }
            return response(object, stampVersion: BridgeV22.version)
        }
        if requestVersion == BridgeV21.version {
            // Additive C02 host-only task-continuity channel: recoverable
            // storage pause plus the canonical question/approval wait
            // identity. It never answers a question or approval; those stay
            // on their original commands. No model tool, no V3 command.
            let object = C02TaskContinuityRuntimeHost.handle(
                requestData: data, fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= C02TaskContinuityWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV21.version)
            }
            return response(object, stampVersion: BridgeV21.version)
        }
        if requestVersion == BridgeV24.version {
            // Additive C07 host-only App-entry policy channel: strict floe://
            // route parsing and bounded share/open descriptor validation. No
            // file, network, store, task, schedule, approval or credential
            // operation; the platform host owns Intent admission and grants.
            // V1-V23 branches above remain byte-identical.
            let object = C07AppEntryBridge.handle(requestData: data,
                                                  fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= BridgeV24.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV24.version)
            }
            return response(object, stampVersion: BridgeV24.version)
        }
        if requestVersion == BridgeV25.version {
            // Additive G04 host-only archive document channel: bounded
            // listing, confirmed extract/decompress with real progress and
            // cancellation, bounded entry preview and preview-staging
            // discard over the ORIGINAL G04 workspace lease. No model tool,
            // no V3 command, no file authority crosses this ABI. V1-V24
            // branches above remain byte-identical.
            let object = G04ArchiveBridge.handle(requestData: data,
                                                 fallbackRequestID: requestID)
            let encoded = (try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]))
                ?? Data(#"{"ok":false,"error":"encoding"}"#.utf8)
            guard encoded.count <= G04ArchiveWire.maximumResponseBytes else {
                return response(["ok": false, "error": "responseTooLarge"],
                                stampVersion: BridgeV25.version)
            }
            return response(object, stampVersion: BridgeV25.version)
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
