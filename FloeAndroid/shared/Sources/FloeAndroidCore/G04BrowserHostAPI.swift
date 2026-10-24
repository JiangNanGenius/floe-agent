// SPDX-License-Identifier: MPL-2.0
//
// G04BrowserHostAPI — the bounded trusted C ABI between the Swift browser
// authority and the trusted Kotlin host (BrowserNative.kt +
// floe_browser_jni.cpp). NOTHING in this family is a model command: there
// is no V3 handler key, no bridge payload grammar and no catalog route.
// Only Kotlin bridge code compiled into the App calls these, and the trust
// rules mirror the reviewed SAF source host exactly:
//
//   * ingress may be called ONLY with native-issued identities (serverID /
//     tabID / leaseID UUIDs, the host binding's exact owner triple). Page
//     content, HTTP bodies, tool JSON arguments and projections can NEVER
//     create grants; grants exist only via BrowserURLPolicy instance tables
//     written by LocalPreviewCoordinator.start and Main's service
//     registration.
//   * the pump surface (bind/next/describe/take_payload/complete/is_live/
//     should_stop/close/stats) mirrors `floe_g04_source_*` one-for-one;
//     tickets settle exactly once, cancellation is a REQUEST, and a stale
//     generation can never touch the current table.
//   * synchronous round trips (`policyAllows`, `preview adjudicate`,
//     `readChunk`, `uiQuery`) may block ONLY dedicated JNI threads and are
//     internally bounded: policy is a locked pure-string check; the preview
//     entries hop to the Swift coordinator actor (native file IO + token
//     tables — never a renderer ticket), so the "no synchronous block
//     waiting on a callback that needs the same executor" rule holds. The
//     main looper must never block on `uiCall`/`submit*`: those settle
//     through projection and delivery events.
//
// Status space (additive, disjoint from gateway -1xx, runtime-owner -2xx,
// attachment -3xx, skills-folder -4xx and source-host -5xx):
//   mailbox reuses the reviewed mailbox codes:
//     0 ok; -101 stale claim; -102 generation fenced; -105 shape;
//     -106 bufferTooSmall; -107 oversized value; -108 descriptor invalid;
//     -110 double settle;
//   browser host:
//     -601 notInstalled (no live generation services);
//     -602 unboundEpoch (pump not bound / stale epoch argument);
//     -603 badJSON (malformed trusted payload);
//     -604 unknownOperation (closed grammar violated);
//     -605 hopTimeout (bounded sync round trip exceeded; fail closed);
//     -606 ownerRefused (task/workspace/epoch not admitted for this op);
//     -699 internal.
import Foundation
import FloeCore
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeBrowser

// MARK: - Buffer helpers

private func g04BrowserWrite(_ data: Data, into buffer: UnsafeMutablePointer<CChar>?,
                             capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return -105 }
    guard data.count + 1 <= Int(capacity) else { return -106 }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        memcpy(buffer, base, data.count)
    }
    buffer[data.count] = 0
    return Int32(data.count)
}

private func g04BrowserDecodeObject(_ pointer: UnsafePointer<CChar>?) -> [String: Any]? {
    guard let pointer else { return nil }
    let text = String(cString: pointer)
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
}

/// Boolean tolerant of the bridge's bounded string encoding (the Kotlin
/// helper emits `"editing":"true"` for a closed grammar field; NSNumber is
/// the JSON-native path). Absent or unparseable values are refusals, never
/// silent false-success.
private func g04BrowserBool(_ object: [String: Any], _ key: String) -> Bool? {
    if let number = object[key] as? NSNumber { return number.boolValue }
    if let text = object[key] as? String {
        if text == "true" { return true }
        if text == "false" { return false }
    }
    return nil
}

/// Runs one async closure on the cooperative pool and waits on a DISPATCH
/// semaphore with a hard bound. The awaited work must never depend on a
/// renderer/transport ticket: policy tables, coordinator adjudication and
/// the center's non-awaiting methods qualify; anything that would await the
/// host pump must use the event grammar instead. Never call this from a
/// Swift executor thread.

/// One-shot Sendable carrier for JSON-serializable dictionaries produced
/// inside a `g04BrowserSync` producer Task and consumed exactly once by the
/// waiting JNI bridge thread after the result semaphore fires. The payload
/// is not shared beyond that handoff (same discipline as G04BrowserSyncBox).
private struct G04BrowserJSONObjectBox: @unchecked Sendable {
    let object: [String: Any]
}

private func g04BrowserSync<T: Sendable>(timeoutMillis: Int,
                                         _ body: @escaping @Sendable () async -> T) -> T? {
    let box = G04BrowserSyncBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let value = await body()
        box.set(value)
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + .milliseconds(timeoutMillis)) == .success else {
        return nil
    }
    return box.value
}

private final class G04BrowserSyncBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Mailbox pump (trusted Kotlin engine thread only)

/// Bind the host pump to a strictly-newer LIVE root epoch. 0 = accepted.
@_cdecl("floe_browser_bind")
public func floeBrowserBind(_ epoch: UInt64) -> Int32 {
    guard G02NativeRootEpoch.readback() == epoch,
          G04BrowserHostRegistry.shared.services(epoch: epoch) != nil else { return -102 }
    return G04BrowserMailbox.shared.bind(epoch: epoch) ? 0 : -102
}

/// Block up to `timeoutMillis` for the next host ticket; 0 = none.
@_cdecl("floe_browser_next")
public func floeBrowserNext(_ timeoutMillis: Int32) -> Int64 {
    G04BrowserMailbox.shared.nextClaim(timeoutMillis: timeoutMillis)
}

/// Ticket descriptor JSON into `buffer` (NUL-terminated). -106 = too small.
@_cdecl("floe_browser_describe")
public func floeBrowserDescribe(_ claim: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                _ capacity: Int32) -> Int32 {
    G04BrowserMailbox.shared.describe(claim: claim, buffer: buffer, capacity: capacity)
}

/// Staged downlink byte count for the claim (-101 stale claim).
@_cdecl("floe_browser_payload_length")
public func floeBrowserPayloadLength(_ claim: Int64) -> Int32 {
    G04BrowserMailbox.shared.payloadLength(claim: claim)
}

/// Copy the FULL staged bytes (probe source / evaluate expression / event
/// JSON); the host allocates capacity >= payloadLength.
@_cdecl("floe_browser_take_payload")
public func floeBrowserTakePayload(_ claim: Int64, _ buffer: UnsafeMutablePointer<UInt8>?,
                                   _ capacity: Int32) -> Int32 {
    G04BrowserMailbox.shared.takePayload(claim: claim, buffer: buffer, capacity: capacity)
}

/// 1 = ticket still live for the CURRENT bound generation.
@_cdecl("floe_browser_is_live")
public func floeBrowserIsLive(_ claim: Int64) -> Int32 {
    G04BrowserMailbox.shared.isLive(claim: claim)
}

/// 1 = the owning round trip was abandoned / generation fenced: run the
/// platform stop (WebView cleanup, socket close) and still settle exactly
/// once.
@_cdecl("floe_browser_should_stop")
public func floeBrowserShouldStop(_ claim: Int64) -> Int32 {
    G04BrowserMailbox.shared.shouldStopClaim(claim: claim)
}

/// Settle one claimed ticket ONCE. status 0 = success (value = operation
/// JSON/bytes: {"port":N} transport start, tab-state JSON, evaluate JSON
/// text, screenshot wire JSON, empty for fire operations; event tickets
/// ignore the value); status 1 = typed failure {"code":"<bounded token>"}
/// (frozen vocabulary: cancelled|tabGone|surfaceUnavailable|evaluateFailed|
/// captureFailed|transportBindFailed|localNetworkPermissionDenied|
/// joinTimeout|hostBudget|mailboxSaturated|revoked|io|failed).
@_cdecl("floe_browser_complete")
public func floeBrowserComplete(_ claim: Int64, _ status: Int32,
                                _ value: UnsafePointer<UInt8>?, _ valueLen: Int32) -> Int32 {
    guard status == 0 || status == 1, valueLen >= 0,
          valueLen == 0 || value != nil else { return -105 }
    let data = (valueLen == 0 || value == nil) ? Data() : Data(bytes: value!, count: Int(valueLen))
    return G04BrowserMailbox.shared.complete(claim: claim, status: status, value: data)
}

/// Exact-epoch teardown (the extension's retirement owns the real close;
/// the pump calls this defensively in its own finally path — close is
/// epoch-exact and idempotent).
@_cdecl("floe_browser_close")
public func floeBrowserClose(_ epoch: UInt64) -> Int32 {
    G04BrowserMailbox.shared.close(epoch: epoch)
    return 0
}

/// The CURRENT mailbox-bound epoch (0 = unbound) as a decimal string inside
/// the positive Int64 JNI range; never a fabricated value.
@_cdecl("floe_browser_bound_epoch")
public func floeBrowserBoundEpoch(_ outBuffer: UnsafeMutablePointer<CChar>?,
                                  _ capacity: Int32) -> Int32 {
    g04BrowserWrite(Data(String(G04BrowserMailbox.shared.boundEpoch).utf8),
                    into: outBuffer, capacity: capacity)
}

/// Typed counters only (no paths, no page bytes, no tokens).
@_cdecl("floe_browser_stats")
public func floeBrowserStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    g04BrowserWrite(Data(G04BrowserMailbox.shared.statsJSON().utf8),
                    into: buffer, capacity: capacity)
}

// MARK: - Trusted host uplinks

/// Push one `BrowserRendererLifecycleEvent` JSON (the ONLY channel that
/// rotates document identities). Fire-and-forget; the center routes by
/// exact tab ownership and drops unknown tabs.
@_cdecl("floe_browser_ingest_event")
public func floeBrowserIngestEvent(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let services = G04BrowserHostRegistry.shared.current else { return -601 }
    guard let object = g04BrowserDecodeObject(json),
          g04BrowserHostEpochMatches(object, epoch: services.epoch),
          let payload = object["event"], JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload),
          let event = try? JSONDecoder().decode(BrowserRendererLifecycleEvent.self, from: data)
    else { return -603 }
    let center = services.center
    Task { await center.ingress(event) }
    return 0
}

/// Synchronous, bounded navigation policy decision for
/// `shouldInterceptRequest` and popup URLs. Returns 1 allow / 0 deny.
/// Pure string/locked-table work: NO actor hop, NO renderer dependency, so
/// it can never deadlock the main looper or a page thread. Fail-closed on
/// every uncertainty (unbound generation = 0).
@_cdecl("floe_browser_policy_allows")
public func floeBrowserPolicyAllows(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let services = G04BrowserHostRegistry.shared.current,
          let object = g04BrowserDecodeObject(json),
          g04BrowserHostEpochMatches(object, epoch: services.epoch),
          let url = object["url"] as? String else { return 0 }
    let taskID = (object["taskID"] as? String).flatMap(UUID.init(uuidString:))
    do {
        _ = try services.policy.validate(url, conversationID: taskID,
                                         allowRegisteredServices: true)
        return 1
    } catch {
        return 0
    }
}

/// Ask Swift about a popup / new-window request. NEVER blocking: the
/// decision arrives as a `ui.popupDecision` delivery event keyed by the
/// host's requestID. The owning task id comes from the host binding.
@_cdecl("floe_browser_popup_query")
public func floeBrowserPopupQuery(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let json, let services = G04BrowserHostRegistry.shared.current else { return -601 }
    let text = String(cString: json)
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          g04BrowserHostEpochMatches(object, epoch: services.epoch),
          let requestID = object["requestID"] as? String,
          let taskRaw = object["taskID"] as? String, let taskID = UUID(uuidString: taskRaw)
    else { return -603 }
    var queryData: Data?
    if let raw = object["query"] as? String { queryData = raw.data(using: .utf8) }
    if queryData == nil, let raw = object["queryJSON"] as? String {
        queryData = raw.data(using: .utf8)
    }
    if queryData == nil, let inline = object["query"] as? [String: Any] {
        queryData = try? JSONSerialization.data(withJSONObject: inline)
    }
    guard let queryData,
          let query = try? JSONDecoder().decode(BrowserPopupQuery.self, from: queryData)
    else { return -603 }
    let center = services.center
    let mailbox = G04BrowserMailbox.shared
    Task {
        let decision = await center.popupDecision(query)
        guard let decisionData = try? JSONEncoder().encode(decision) else { return }
        let payload: [String: String] = [
            "requestID": requestID,
            "decision": String(decoding: decisionData, as: UTF8.self),
        ]
        guard let payloadJSON = try? JSONEncoder().encode(payload) else { return }
        mailbox.submitEvent(.uiPopupDecision, expectedEpoch: services.epoch, conversation: taskID,
                            payload: payloadJSON, coalesceKey: nil)
    }
    return 0
}

/// Forward one WebView DownloadListener fact (tab/URL/User-Agent/
/// Content-Disposition/MIME/length) into the Swift download authority.
/// Swift OWNS the entire fetch (FloeTransport streaming, cap + running
/// SHA-256, staged verified commit) — Kotlin performs NO network IO and NO
/// file writes. Fire-and-forget; progress/commit/failure surface as
/// `ui.downloadSignal` events.
@_cdecl("floe_browser_download_request")
public func floeBrowserDownloadRequest(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let json, let services = G04BrowserHostRegistry.shared.current else { return -601 }
    let text = String(cString: json)
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          g04BrowserHostEpochMatches(object, epoch: services.epoch),
          let taskRaw = object["taskID"] as? String, let taskID = UUID(uuidString: taskRaw),
          let requestID = object["requestID"] as? String,
          let url = object["url"] as? String, !url.isEmpty,
          let tabRaw = object["tabID"] as? String, let tabID = UUID(uuidString: tabRaw)
    else { return -603 }
    let downloads = services.downloads
    let center = services.center
    Task {
        func refused(_ code: String) {
            G04BrowserProjectionSink.downloadSignal([
                "kind": "refused", "requestID": requestID, "code": code,
            ], conversation: taskID, epoch: services.epoch)
        }
        guard let session = await center.session(for: taskID) else {
            refused("sessionMissing")
            return
        }
        let owner = await session.owner
        guard owner.taskID == taskID else {
            refused("ownerRefused")
            return
        }
        let sessionID = await session.sessionID
        let query = BrowserDownloadQuery(
            tabID: tabID, owner: owner, url: url,
            userAgent: object["userAgent"] as? String ?? "",
            contentDisposition: object["contentDisposition"] as? String ?? "",
            mimeType: object["mimeType"] as? String ?? "",
            suggestedContentLength: (object["contentLength"] as? NSNumber)?.int64Value)
        // Downloads need no caller: ownership comes from the session
        // binding, never from the forwarded fact.
        let ticket = await downloads.admit(query: query, session: session,
                                          sessionID: sessionID)
        if ticket == nil {
            refused("policyRefused")
        }
    }
    return 0
}

/// Typed UI operation from the trusted panel (owner triple comes from the
/// host binding only; nothing here accepts model content). Fire-and-forget
/// except the closed SYNC grammar in `floe_browser_ui_query`. Returns 0 when
/// the operation was dispatched; typed refusals otherwise.
@_cdecl("floe_browser_ui_call")
public func floeBrowserUICall(_ json: UnsafePointer<CChar>?) -> Int32 {
    guard let json, let services = G04BrowserHostRegistry.shared.current else { return -601 }
    let text = String(cString: json)
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let operation = object["op"] as? String,
          let taskRaw = object["taskID"] as? String, let taskID = UUID(uuidString: taskRaw)
    else { return -603 }
    guard let rawEpoch = object["rootEpoch"] as? String,
          let expectedEpoch = UInt64(rawEpoch), expectedEpoch > 0,
          String(expectedEpoch) == rawEpoch, expectedEpoch == services.epoch else { return -606 }
    let center = services.center
    let preview = services.preview
    let downloads = services.downloads
    let routing = G04BrowserHostRegistry.shared.currentRouting

    func ownerFromBinding() -> BrowserOwnerID? {
        guard let workspaceRaw = object["workspaceID"] as? String,
              let workspaceID = UUID(uuidString: workspaceRaw),
              let epochRaw = object["rootEpoch"] as? String,
              let epoch = UInt64(epochRaw), epoch > 0
        else { return nil }
        return BrowserOwnerID(taskID: taskID, workspaceID: workspaceID, rootEpoch: epoch)
    }

    switch operation {
    case "bind":
        guard let owner = ownerFromBinding() else { return -606 }
        Task { await center.bind(to: taskID, owner: owner) }
        return 0
    case "unbind":
        // Presentation only: unbinding the VISIBLE surface never stops any
        // task's renderers or previews.
        Task { await center.unbindVisible(if: taskID) }
        return 0
    case "takeControl":
        Task { await center.takeControl(in: taskID) }
        return 0
    case "returnToAgent":
        guard let receiptIDRaw = object["receiptID"] as? String,
              let receiptID = UUID(uuidString: receiptIDRaw) else { return -603 }
        guard let continueTask = g04BrowserBool(object, "continueTask") else { return -603 }
        Task {
            // The outcome (delivered / mismatch / failed) lands in the next
            // projection: handoffError and handoffNeedsContinue are the UI
            // truth and the durable receipt is kept on failure.
            _ = await center.returnToAgent(receiptID: receiptID, continueTask: continueTask)
        }
        return 0
    case "dismissPanel":
        Task {
            do { try await center.requestPanelDismissal(conversationID: taskID) } catch {}
        }
        return 0
    case "setAddressText":
        guard let address = object["text"] as? String else { return -603 }
        Task { await center.setAddressText(address, in: taskID) }
        return 0
    case "setEditingAddress":
        guard let editing = g04BrowserBool(object, "editing") else { return -603 }
        Task { await center.setEditingAddress(editing, in: taskID) }
        return 0
    case "navigateAddressBar":
        Task { await center.navigateFromAddressBar(in: taskID) }
        return 0
    case "reload":
        Task { await center.reloadVisibleTab(in: taskID) }
        return 0
    case "goBack":
        Task { await center.goBackVisibleTab(in: taskID) }
        return 0
    case "goForward":
        Task { await center.goForwardVisibleTab(in: taskID) }
        return 0
    case "createTab":
        Task { _ = await center.createTab(in: taskID) }
        return 0
    case "activateTab", "closeTab":
        guard let tabRaw = object["tabID"] as? String, let tabID = UUID(uuidString: tabRaw)
        else { return -603 }
        if operation == "activateTab" {
            Task { await center.activate(tabID, in: taskID) }
        } else {
            Task { await center.close(tabID, in: taskID) }
        }
        return 0
    case "previewFile":
        guard let owner = ownerFromBinding(),
              let requestID = object["requestID"] as? String,
              let argsJSON = object["argsJSON"] as? String else { return -603 }
        Task {
            // Explicit user preview may restore THIS owner's session,
            // but background completion must never select its panel over a
            // subsequently selected task. Visible binding belongs to UI.
            do { _ = try await center.restoreSession(owner: owner) }
            catch {
                G04BrowserHostAPI.emitToolError(requestID: requestID, taskID: taskID, epoch: services.epoch)
                return
            }
            await G04BrowserHostAPI.submitTool(name: "preview.start", argsJSON: argsJSON,
                                               requestID: requestID, taskID: taskID,
                                               routing: routing, epoch: services.epoch)
        }
        return 0
    case "toolSubmit":
        guard let requestID = object["requestID"] as? String,
              let toolName = object["toolName"] as? String,
              let argsJSON = object["argsJSON"] as? String else { return -603 }
        Task {
            await G04BrowserHostAPI.submitTool(name: toolName, argsJSON: argsJSON,
                                               requestID: requestID, taskID: taskID,
                                               routing: routing, epoch: services.epoch)
        }
        return 0
    case "commandSubmit":
        guard let requestID = object["requestID"] as? String,
              let commandJSON = object["commandJSON"] as? String,
              let commandData = commandJSON.data(using: .utf8),
              var command = try? JSONDecoder().decode(BrowserCommand.self, from: commandData),
              let owner = ownerFromBinding() else { return -603 }
        let boundEpoch = owner.rootEpoch
        Task {
            guard G04BrowserMailbox.shared.boundEpoch == boundEpoch else {
                G04BrowserHostAPI.emitCommandError(requestID: requestID, taskID: taskID,
                                                   code: "unboundEpoch", epoch: boundEpoch)
                return
            }
            // The session identity is minted NATIVELY here: the host cannot
            // choose or reuse a sessionID through this path.
            if let session = await center.session(for: taskID) {
                command.sessionID = await session.sessionID
            } else {
                G04BrowserHostAPI.emitCommandError(requestID: requestID, taskID: taskID,
                                                   code: "sessionMissing", epoch: boundEpoch)
                return
            }
            let result = await center.execute(command, in: owner)
            G04BrowserHostAPI.emitCommandResult(requestID: requestID, taskID: taskID,
                                                result: result, epoch: boundEpoch)
        }
        return 0
    case "discardTask":
        // Explicit task deletion / privacy clear / leave-route hook:
        // fence + stop previews + cancel downloads + release renderers
        // (the center's discard drives the ownerReleaseHook which routes
        // preview release + download owner release).
        Task {
            await center.discard(conversationID: taskID, notifyHook: true)
            _ = await downloads.activeTicketCount // settled bookkeeping only
            G04BrowserHandoffBridge.shared.clearRun(for: taskID)
        }
        return 0
    case "stopPreview":
        Task { _ = await preview.stop(owner: taskID) }
        return 0
    default:
        return -604
    }
}

/// Synchronous bounded query for the closed SYNC grammar:
///   {"op":"consumePanelRequest","taskID":...} -> {"present":bool, ...}
///   {"op":"projection","taskID":...}          -> current BrowserProjection
///   {"op":"previewState","taskID":...}        -> {"active":bool,...}
/// These never await the renderer, so a dedicated JNI thread may block on
/// them within the bound. A timeout is an honest typed refusal (-605),
/// never a stale success.
@_cdecl("floe_browser_ui_query")
public func floeBrowserUIQuery(_ json: UnsafePointer<CChar>?,
                               _ outBuffer: UnsafeMutablePointer<CChar>?,
                               _ capacity: Int32,
                               _ timeoutMillis: Int32) -> Int32 {
    guard json != nil, outBuffer != nil, capacity > 0 else { return -105 }
    guard let services = G04BrowserHostRegistry.shared.current,
          let object = g04BrowserDecodeObject(json),
          let operation = object["op"] as? String,
          let taskRaw = object["taskID"] as? String, let taskID = UUID(uuidString: taskRaw)
    else { return -603 }
    guard let rawEpoch = object["rootEpoch"] as? String,
          let expectedEpoch = UInt64(rawEpoch), expectedEpoch > 0,
          String(expectedEpoch) == rawEpoch, expectedEpoch == services.epoch else { return -606 }
    let timeout = max(250, min(Int(timeoutMillis), 5_000))
    switch operation {
    case "consumePanelRequest", "pendingPanelRequest":
        let outcomeBox: G04BrowserJSONObjectBox? = g04BrowserSync(timeoutMillis: timeout) { () -> G04BrowserJSONObjectBox in
            let request: BrowserPanelRequest?
            if operation == "consumePanelRequest" {
                request = await services.center.consumePendingPanelRequest(for: taskID)
            } else {
                request = await services.center.pendingPanelRequest(for: taskID)
            }
            guard let request, request.conversationID == taskID,
                  let encoded = try? JSONEncoder().encode(request),
                  var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            else { return G04BrowserJSONObjectBox(object: ["present": false]) }
            object["present"] = true
            return G04BrowserJSONObjectBox(object: object)
        }
        guard let outcome = outcomeBox?.object, JSONSerialization.isValidJSONObject(outcome),
              let encoded = try? JSONSerialization.data(withJSONObject: outcome) else { return -605 }
        return g04BrowserWrite(encoded, into: outBuffer, capacity: capacity)
    case "projection":
        guard let projection: BrowserProjection = g04BrowserSync(timeoutMillis: timeout, {
            await services.center.projection()
        }), let encoded = try? JSONEncoder().encode(projection) else { return -605 }
        return g04BrowserWrite(encoded, into: outBuffer, capacity: capacity)
    case "previewState":
        let stateBox: G04BrowserJSONObjectBox? = g04BrowserSync(timeoutMillis: timeout) { () -> G04BrowserJSONObjectBox in
            let active = await services.preview.isPreviewActive(for: taskID)
            let lease = await services.preview.activeLeaseID(for: taskID)
            var out: [String: Any] = ["active": active]
            if let lease { out["leaseID"] = lease.uuidString }
            return G04BrowserJSONObjectBox(object: out)
        }
        guard let state = stateBox?.object, JSONSerialization.isValidJSONObject(state),
              let encoded = try? JSONSerialization.data(withJSONObject: state) else { return -605 }
        return g04BrowserWrite(encoded, into: outBuffer, capacity: capacity)
    default:
        return -604
    }
}

/// Synchronous preview adjudication for the dumb loopback transport (the
/// dedicated connection thread ONLY). `serverID` is the Swift lease UUID;
/// `requestID` the per-connection UUID; the raw header block returns to the
/// Swift `LocalPreviewServer` untouched. Unknown/stopped leases answer an
/// honest 404 verdict.
@_cdecl("floe_browser_preview_adjudicate")
public func floeBrowserPreviewAdjudicate(_ serverJSON: UnsafePointer<CChar>?,
                                         _ requestJSON: UnsafePointer<CChar>?,
                                         _ header: UnsafePointer<UInt8>?,
                                         _ headerLen: Int32,
                                         _ outBuffer: UnsafeMutablePointer<CChar>?,
                                         _ capacity: Int32) -> Int32 {
    guard let serverJSON, let requestJSON, let outBuffer, capacity > 0 else { return -105 }
    guard let services = G04BrowserHostRegistry.shared.current else {
        return g04BrowserWrite(Data(G04BrowserHostAPI.unavailableVerdictJSON.utf8),
                               into: outBuffer, capacity: capacity)
    }
    guard let serverID = UUID(uuidString: String(cString: serverJSON)),
          let requestID = UUID(uuidString: String(cString: requestJSON)),
          headerLen >= 0, headerLen == 0 || header != nil else { return -105 }
    let headerBlock = (headerLen == 0 || header == nil)
        ? Data() : Data(bytes: header!, count: Int(headerLen))
    let verdict: BrowserPreviewVerdict? = g04BrowserSync(timeoutMillis: 15_000) {
        await services.preview.adjudicate(leaseID: serverID, requestID: requestID,
                                          headerBlock: headerBlock)
    }
    guard let verdict else {
        // The bounded hop timed out: fail closed with an honest 503 that
        // names NO resource and grants nothing.
        return g04BrowserWrite(Data(G04BrowserHostAPI.unavailableVerdictJSON.utf8),
                               into: outBuffer, capacity: capacity)
    }
    guard let encoded = try? JSONEncoder().encode(verdict) else { return -699 }
    return g04BrowserWrite(encoded, into: outBuffer, capacity: capacity)
}

/// Next bounded slice of an admitted preview body. Empty (0) means
/// done/retired — never a partial success presented as complete.
@_cdecl("floe_browser_preview_read_chunk")
public func floeBrowserPreviewReadChunk(_ serverJSON: UnsafePointer<CChar>?,
                                        _ requestJSON: UnsafePointer<CChar>?,
                                        _ offset: Int32,
                                        _ outBuffer: UnsafeMutablePointer<UInt8>?,
                                        _ capacity: Int32) -> Int32 {
    guard let serverJSON, let requestJSON, let outBuffer, capacity > 0 else { return -105 }
    guard let services = G04BrowserHostRegistry.shared.current else { return -601 }
    guard let serverID = UUID(uuidString: String(cString: serverJSON)),
          let requestID = UUID(uuidString: String(cString: requestJSON)),
          offset >= 0 else { return -105 }
    let chunk: Data? = g04BrowserSync(timeoutMillis: 15_000) {
        await services.preview.readChunk(leaseID: serverID, requestID: requestID,
                                         offset: Int(offset))
    }
    guard let chunk else { return -605 }
    guard chunk.count <= Int(capacity) else {
        // Capacity below the admitted slice: refuse rather than truncate
        // into a "complete" body. The pump allocates 64 KiB; the server
        // never emits larger slices.
        return -107
    }
    if !chunk.isEmpty {
        chunk.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(outBuffer, base, chunk.count)
        }
    }
    return Int32(chunk.count)
}

/// Main's run-state observer entry for cold recovery: re-deliver the exact
/// recorded returning receipt for THIS conversation/run pair only.
@_cdecl("floe_browser_recover_handoff")
public func floeBrowserRecoverHandoff(_ taskJSON: UnsafePointer<CChar>?,
                                      _ runJSON: UnsafePointer<CChar>?,
                                      _ epoch: UInt64) -> Int32 {
    guard let taskJSON, let runJSON,
          let taskID = UUID(uuidString: String(cString: taskJSON)),
          let runID = UUID(uuidString: String(cString: runJSON)) else { return -603 }
    return G04BrowserHandoffBridge.shared.recover(conversationID: taskID, runID: runID,
                                                  expectedEpoch: epoch) ? 0 : -602
}

/// Liveness probe for the App's explicit preview-start broker flow: returns
/// 0 only while THIS epoch's composition is live. It stores NO permission
/// state and never prompts; the actual grant flow is the existing
/// LocalNetworkAccessBroker -> the `transport.start` ticket.
@_cdecl("floe_browser_services_live")
public func floeBrowserServicesLive(_ epoch: UInt64) -> Int32 {
    G04BrowserHostRegistry.shared.services(epoch: epoch) != nil ? 0 : -602
}

// MARK: - Shared submission grammar

enum G04BrowserHostAPI {
    /// A 503 that names no resource and grants nothing (mirrors the pump's
    /// honest transport-local error).
    static let unavailableVerdictJSON =
        #"{"requestID":"00000000-0000-0000-0000-000000000000","statusLine":"503 Service Unavailable","headers":[{"name":"Content-Type","value":"text/plain; charset=utf-8"},{"name":"Content-Length","value":"0"},{"name":"Cache-Control","value":"no-store"},{"name":"X-Content-Type-Options","value":"nosniff"},{"name":"Connection","value":"close"}],"bodyLength":0,"bodyStart":0,"chunk":""}"#

    static func submitTool(name: String, argsJSON: String, requestID: String,
                           taskID: UUID, routing: G04BrowserToolRouting?, epoch: UInt64) async {
        let mailbox = G04BrowserMailbox.shared
        func emit(_ object: [String: Any]) {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            mailbox.submitEvent(.uiToolResult, expectedEpoch: epoch, conversation: taskID,
                                payload: data, coalesceKey: nil)
        }
        guard let routing else {
            emit(["requestID": requestID, "ok": false,
                  "summary": "The browser generation is not installed.",
                  "requiresUserAction": false, "errorCode": "notInstalled"])
            return
        }
        guard G04BrowserToolNames.all.contains(name) else {
            emit(["requestID": requestID, "ok": false,
                  "summary": "Unknown browser tool '\(name)'.",
                  "requiresUserAction": false, "errorCode": "unknownTool"])
            return
        }
        do {
            let caller = try await routing.makeUICaller(taskID: taskID)
            let arguments = try G04BrowserToolArgumentsCodec.decode(name: name, json: argsJSON)
            let output = try await routing.surface.invoke(name: name, caller: caller,
                                                          arguments: arguments,
                                                          cancellation: nil)
            emit(["requestID": requestID, "ok": true,
                  "summary": output.summary,
                  "requiresUserAction": output.requiresUserAction])
        } catch {
            emit(["requestID": requestID, "ok": false,
                  "summary": error.localizedDescription,
                  "requiresUserAction": false,
                  "errorCode": "refused"])
        }
    }

    static func emitToolError(requestID: String, taskID: UUID, epoch: UInt64) {
        let envelope: [String: Any] = ["requestID": requestID, "ok": false,
            "summary": "The browser is unavailable.", "requiresUserAction": false, "errorCode": "refused"]
        guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        G04BrowserMailbox.shared.submitEvent(.uiToolResult, expectedEpoch: epoch, conversation: taskID,
                                             payload: payload, coalesceKey: nil)
    }

    static func emitCommandResult(requestID: String, taskID: UUID,
                                  result: BrowserResult, epoch: UInt64) {
        let mailbox = G04BrowserMailbox.shared
        guard let resultData = try? JSONEncoder().encode(result) else { return }
        let envelope: [String: String] = [
            "requestID": requestID,
            "result": String(decoding: resultData, as: UTF8.self),
        ]
        guard let payload = try? JSONEncoder().encode(envelope) else { return }
        mailbox.submitEvent(.uiCommandResult, expectedEpoch: epoch, conversation: taskID,
                            payload: payload, coalesceKey: nil)
    }

    static func emitCommandError(requestID: String, taskID: UUID, code: String, epoch: UInt64) {
        let mailbox = G04BrowserMailbox.shared
        let envelope: [String: String] = ["requestID": requestID, "error": code]
        guard let payload = try? JSONEncoder().encode(envelope) else { return }
        mailbox.submitEvent(.uiCommandResult, expectedEpoch: epoch, conversation: taskID,
                            payload: payload, coalesceKey: nil)
    }
}

/// Host callbacks carry their immutable binding epoch; a current-registry
/// lookup alone must never relabel an old WebView event as a new Root.
func g04BrowserHostEpochMatches(_ object: [String: Any], epoch: UInt64) -> Bool {
    guard epoch > 0, let raw = object["rootEpoch"] as? String,
          let value = UInt64(raw), value == epoch, String(value) == raw else { return false }
    return true
}
