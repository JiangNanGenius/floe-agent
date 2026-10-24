// SPDX-License-Identifier: MPL-2.0
//
// G04TerminalHostAPI — the trusted Kotlin-host C ABI for the embedded
// terminal + LSP domain (job-dda32d23d55e4460). Same reviewed shape as the
// G03 `LinuxShellMailbox` and the G04 `G04WorkspaceSourceMailbox`, but an
// INDEPENDENT transport (it must never share their ticket tables):
//
//  * Direction: the trusted App host submits CLOSED actions (control
//    descriptor JSON + an OPTIONAL raw payload channel for document text —
//    full editable text NEVER rides the control envelope) and claims
//    events: bounded control replies/status plus the separate raw PTY
//    output byte channel. Swift-side dispatch runs on the ORIGINAL
//    services (ShellSessionCenter via `G04TerminalStore`,
//    `G04LanguageServerCenter`); nothing here is a V3 handler key, command
//    name, or tool — model dispatch has NO route.
//  * Every bind requires a strictly newer POSITIVE native Root epoch
//    cross-checked against `G02NativeRootEpoch.readback()` (never
//    0-as-epoch); close is exact-epoch; a stale generation can never touch
//    a newer queue and vice versa.
//  * Bounds: control descriptor <=64 KiB, per-event payload <=64 KiB,
//    raw action payload (document text) <=4 MiB, live actions 32, live
//    events 128, aggregate event bytes 2 MiB. Event overflow evicts the
//    OLDEST OUTPUT event only (never a control/reply), counted in stats
//    and visible as an honest `seq` gap to the renderer.
//  * Sessions survive pane reconstruction; `terminalAttach` is a status
//    snapshot, never a navigation/restart/process signal.
import Foundation
import CoreFoundation
import FloeCore
import FloeTools
import FloeAndroidShellTools

// MARK: - Limits

public enum G04TerminalHostLimits {
    public static let maximumFrameBytes = 65_536          // frozen 64 KiB control
    public static let maximumPayloadBytes = 4 * 1024 * 1024  // raw document text (separate channel)
    public static let maximumEventPayloadBytes = 65_536   // one raw output chunk per event
    public static let maximumLiveActions = 32
    public static let maximumLiveEvents = 128
    public static let maximumEventBytes = 2 * 1024 * 1024
    public static let maximumRetired = 256
}

// MARK: - Mailbox

public final class G04TerminalHostMailbox: @unchecked Sendable {
    public static let shared = G04TerminalHostMailbox()

    public struct Event {
        public let token: Int64
        public let createdEpoch: UInt64
        public let controlJSON: Data          // descriptor always present
        public let rawPayload: Data?          // terminal output chunk bytes
    }

    private struct Action {
        let token: Int64
        let createdEpoch: UInt64
        let descriptor: Data
        let payload: Data?
    }

    private let condition = NSCondition()
    private var actions: [Int64: Action] = [:]
    private var actionQueue: [Int64] = []
    private var liveActionCount = 0
    private var dispatchTasks: [Int64: Task<Void, Never>] = [:]
    private var controlOverflow = 0
    private var overflowEvent: Int64?
    private var events: [Int64: Event] = [:]
    private var eventQueue: [Int64] = []
    private var eventBytes = 0
    private var nextToken: Int64 = 1
    private var retired: Set<Int64> = []
    private var retiredOrder: [Int64] = []
    private var epoch: UInt64 = 0
    private var closed = true
    private var counters = (actions: 0, actionRejections: 0, events: 0, evictedOutput: 0,
                            fenced: 0, lateAck: 0, bindRejections: 0)

    // The per-generation domain objects.
    private var store: G04TerminalStore?
    private var servers: G04LanguageServerCenter?
    private var drainTask: Task<Void, Never>?

    private let testHandler: (@Sendable (Data, Data?, UInt64) async -> Void)?
    init(testHandler: (@Sendable (Data, Data?, UInt64) async -> Void)? = nil) {
        self.testHandler = testHandler
    } // Internal synthetic handler; production singleton always uses real dispatch.

    // MARK: Bind / close

    /// Strictly-newer positive epoch, live-Root-epoch cross-checked by the
    /// export below. Creates the ONE store/center for the generation and
    /// fences the previous one (pending actions are NOT replayed; sessions
    /// of the old generation were already fenced by the original lifecycle).
    func bind(newEpoch: UInt64) -> Bool {
        condition.lock()
        guard newEpoch != 0, newEpoch > epoch else {
            counters.bindRejections += 1
            condition.unlock()
            return false
        }
        let retiringStore = store
        let retiringServers = servers
        let oldDispatch = Array(dispatchTasks.values)
        dispatchTasks.removeAll()
        epoch = newEpoch
        closed = false
        // Fence outstanding actions of the previous generation.
        for token in Array(actions.keys) {
            actions.removeValue(forKey: token)
            retireLocked(token)
        }
        actionQueue.removeAll()
        liveActionCount = 0
        counters.fenced += 1
        for token in Array(events.keys) { retiredEventLocked(token) }
        let sink = G04TerminalMailboxSink(mailbox: self, epoch: newEpoch)
        let storeValue = G04TerminalStore(epoch: newEpoch, sink: sink)
        let serversValue = G04LanguageServerCenter(epoch: newEpoch, sink: sink)
        store = storeValue
        servers = serversValue
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            await self?.drainLoop(epoch: newEpoch)
        }
        condition.broadcast()
        condition.unlock()
        oldDispatch.forEach { $0.cancel() }
        Task { await retiringStore?.retire(); await retiringServers?.retireAll(reason: "generation-replaced") }
        // Load-on-Root-bind: the persisted language choices preload into the
        // new generation's center (durable read on the ORIGINAL settings
        // authority; a no-op until a live composition exists).
        Task { await serversValue.preloadSettings() }
        emitControl(["type": "hostBound", "epoch": newEpoch], expectedEpoch: newEpoch)
        return true
    }

    /// Exact-epoch teardown. The FENCE (new actions refuse, undelivered
    /// events drop, drain stops) lands synchronously; the ORIGINAL session
    /// retirement (engine stop REQUESTS retained by the backend
    /// reconciliation — never claimed as proven stops) runs detached.
    @discardableResult
    func close(closingEpoch: UInt64) -> Bool {
        condition.lock()
        guard closingEpoch == epoch, epoch != 0, !closed else {
            condition.unlock()
            return false
        }
        closed = true
        let retiringStore = store
        let retiringServers = servers
        let activeDispatch = Array(dispatchTasks.values)
        dispatchTasks.removeAll()
        store = nil
        servers = nil
        drainTask?.cancel()
        drainTask = nil
        for token in Array(actions.keys) {
            actions.removeValue(forKey: token)
            retireLocked(token)
        }
        actionQueue.removeAll()
        liveActionCount = 0
        for token in Array(events.keys) { retiredEventLocked(token) }
        counters.fenced += 1
        condition.broadcast()
        condition.unlock()
        activeDispatch.forEach { $0.cancel() }
        Task {
            await retiringStore?.retire()
            await retiringServers?.retireAll(reason: "generation-retired")
        }
        return true
    }

    // MARK: Actions (host -> Swift)

    /// The trusted host submits one closed action. Returns the action token
    /// (for stats) or a negative bound code BEFORE anything is queued.
    func submitAction(descriptor: Data, payload: Data?) -> Int64 {
        guard descriptor.count <= G04TerminalHostLimits.maximumFrameBytes else {
            condition.lock(); counters.actionRejections += 1; condition.unlock()
            return -106
        }
        guard payload == nil || payload!.count <= G04TerminalHostLimits.maximumPayloadBytes else {
            condition.lock(); counters.actionRejections += 1; condition.unlock()
            return -107
        }
        condition.lock()
        guard !closed, epoch != 0 else {
            counters.actionRejections += 1
            condition.unlock()
            return -101
        }
        guard liveActionCount < G04TerminalHostLimits.maximumLiveActions else {
            counters.actionRejections += 1
            condition.unlock()
            return -108
        }
        let token = nextToken
        nextToken += 1
        actions[token] = Action(token: token, createdEpoch: epoch, descriptor: descriptor, payload: payload)
        actionQueue.append(token)
        liveActionCount += 1
        counters.actions += 1
        condition.broadcast()
        condition.unlock()
        return token
    }

    /// Claims the oldest queued action for the drain loop (blocking with a
    /// bounded wait so the task can re-check generation).
    private func nextAction(timeoutMillis: Int32) -> Action? {
        condition.lock(); defer { condition.unlock() }
        guard !closed, epoch != 0 else { return nil }
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutMillis)) / 1000)
        while true {
            if let head = actionQueue.first, let action = actions[head], action.createdEpoch == epoch {
                actionQueue.removeFirst()
                // Queued AND executing actions consume the same capacity.
                return action
            }
            if closed || Date() >= deadline { return nil }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func finishAction(_ action: Action) {
        condition.lock(); defer { condition.unlock() }
        dispatchTasks.removeValue(forKey: action.token)
        if actions.removeValue(forKey: action.token) != nil {
            liveActionCount = max(0, liveActionCount - 1)
            retireLocked(action.token)
            condition.broadcast()
        }
    }

    private func drainLoop(epoch boundEpoch: UInt64) async {
        let backgroundControls: Set<String> = ["terminalOpen", "terminalClose", "runDraft",
            "lspEnsure", "lspShutdown", "lspSetLanguageEnabled"]
        while !Task.isCancelled {
            let alive = condition.g04Locked { !closed && epoch == boundEpoch }
            guard alive else { return }
            guard let action = nextAction(timeoutMillis: 200) else { continue }
            let kind = (try? JSONSerialization.jsonObject(with: action.descriptor) as? [String: Any])?["action"] as? String
            if let kind, backgroundControls.contains(kind) {
                // A language server's initialization must not hold terminal
                // keystrokes behind a 120-second handshake. Independent
                // controls stay bounded by maximumLiveActions; native session
                // actors and original ownership still fence their effects.
                let admitted = condition.g04Locked { () -> Bool in
                    guard !closed, epoch == action.createdEpoch else { return false }
                    dispatchTasks[action.token] = Task { [weak self] in
                        guard let self else { return }
                        await self.dispatch(descriptor: action.descriptor, payload: action.payload, epoch: action.createdEpoch)
                        self.finishAction(action)
                    }
                    return true
                }
                if !admitted {
                    finishAction(action)
                    continue
                }
            } else {
                await dispatch(descriptor: action.descriptor, payload: action.payload, epoch: action.createdEpoch)
                finishAction(action)
            }
        }
    }

    // MARK: Dispatch (closed action grammar; unknown refuses fail-closed)

    private func dispatch(descriptor: Data, payload: Data?, epoch actionEpoch: UInt64) async {
        func emitControl(_ value: [String: Any]) { self.emitControl(value, expectedEpoch: actionEpoch) }
        let (currentStore, currentServers, alive) = condition.g04Locked {
            (store, servers, !closed && epoch == actionEpoch)
        }
        guard alive, let object = try? JSONSerialization.jsonObject(with: descriptor) as? [String: Any],
              let kind = object["action"] as? String,
              let requestID = object["requestID"] as? String else {
            return
        }
        if let testHandler { await testHandler(descriptor, payload, actionEpoch); return }
        guard let store = currentStore else { return }
        switch kind {
        case "capabilities":
            let conversation = uuid(object["conversationID"])
            var reply: [String: Any] = [
                "type": "actionReply", "requestID": requestID, "ok": true,
                "qualified": RuntimeFacadeLinuxBindings.shared.isCapabilityQualified,
                "attached": G04TerminalRuntimeRegistry.shared.currentAuthority != nil,
                "languages": G04LanguageServerCatalog.servers.map { $0.languageID },
                "runLanguages": G04LanguageRunPolicy.supportedLanguageIDs,
            ]
            if let conversation {
                reply["conversationID"] = conversation.uuidString
            }
            // ACTUAL persisted settings + live server states ride the same
            // bounded capabilities answer (the host must never show a cold
            // catalog-only list as availability after an install/qualification).
            if let servers = currentServers,
               let payload = await servers.capabilityPayload(conversationID: conversation),
               let extra = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                for (key, value) in extra { reply[key] = value }
            } else {
                reply["settingsKnown"] = false
            }
            emitControl(reply)
        case "terminalOpen":
            guard let conversation = uuid(object["conversationID"]) else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidConversation"]); return
            }
            await store.open(conversationID: conversation,
                             workspaceID: uuid(object["workspaceID"]),
                             purpose: .interactive, command: "", cwd: ".",
                             columns: int(object["columns"]) ?? 80,
                             rows: int(object["rows"]) ?? 24,
                             requestID: requestID)
        case "terminalInput":
            guard let token = object["sessionToken"] as? String,
                  let encoded = object["data"] as? String,
                  let bytes = Data(base64Encoded: encoded),
                  bytes.count <= G04TerminalHostLimits.maximumFrameBytes else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidPayload"]); return
            }
            await store.input(sessionToken: token, bytes: bytes, requestID: requestID)
        case "terminalInterrupt":
            guard let token = object["sessionToken"] as? String else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidPayload"]); return
            }
            await store.interrupt(sessionToken: token, requestID: requestID)
        case "terminalResize":
            guard let token = object["sessionToken"] as? String else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidPayload"]); return
            }
            await store.resize(sessionToken: token, columns: int(object["columns"]) ?? 80,
                               rows: int(object["rows"]) ?? 24, requestID: requestID)
        case "terminalAttach":
            guard let token = object["sessionToken"] as? String else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidPayload"]); return
            }
            await store.attach(sessionToken: token, requestID: requestID)
        case "terminalClose":
            guard let token = object["sessionToken"] as? String else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidPayload"]); return
            }
            await store.close(sessionToken: token, requestID: requestID)
        case "terminalStatus":
            guard let conversation = uuid(object["conversationID"]) else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidConversation"]); return
            }
            await store.statusSnapshot(conversationID: conversation, requestID: requestID)
        case "runDraft":
            guard let conversation = uuid(object["conversationID"]),
                  let relativePath = object["relativePath"] as? String,
                  let language = object["language"] as? String else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidPayload"]); return
            }
            await store.runDraft(conversationID: conversation, workspaceID: uuid(object["workspaceID"]),
                                 relativePath: relativePath, languageID: language, requestID: requestID)
        case "lspEnsure", "lspSetLanguageEnabled":
            guard let servers = currentServers else { return }
            if kind == "lspEnsure" {
                guard let conversation = uuid(object["conversationID"]),
                      let language = object["language"] as? String else {
                    emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                                 "code": "invalidPayload"]); return
                }
                await servers.ensureServer(conversationID: conversation, workspaceID: uuid(object["workspaceID"]),
                                           language: language, requestID: requestID)
            } else {
                guard let language = object["language"] as? String else {
                    emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                                 "code": "invalidPayload"]); return
                }
                // STRICT bool: a missing or non-bool "enabled" is an honest
                // invalidType refusal, never a coerced default that could
                // persist the wrong user choice durably.
                guard let enabled = strictBool(object["enabled"]) else {
                    emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                                 "code": "invalidType", "reason": "enabled"]); return
                }
                await servers.setLanguageEnabled(language: language, enabled: enabled,
                                                 requestID: requestID)
            }
        case "lspOpenDocument", "lspChangeDocument", "lspCloseDocument", "lspCompletion",
             "lspCancel", "lspShutdown":
            guard let servers = currentServers,
                  let conversation = uuid(object["conversationID"]),
                  let language = object["language"] as? String,
                  let documentID = uuid(object["documentID"]) ?? (kind == "lspCancel" || kind == "lspShutdown" ? UUID() : nil)
            else {
                emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                             "code": "invalidPayload"]); return
            }
            let revision = object["revision"] as? String ?? ""
            var text: String?
            if kind == "lspOpenDocument" || kind == "lspChangeDocument" {
                // The document text rides the RAW payload channel (never the
                // control envelope); the descriptor must declare its exact
                // byte count + SHA-256 and the bytes must match, else the
                // action refuses before touching the server.
                guard let payload,
                      let declared = int(object["textByteCount"]),
                      let declaredDigest = object["textSHA256"] as? String,
                      payload.count == declared,
                      FloeDigest.sha256Hex(payload) == declaredDigest,
                      let synced = String(data: payload, encoding: .utf8) else {
                    emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                                 "code": "invalidTextPayload"]); return
                }
                text = synced
            }
            await servers.route(documentAction: kind, conversationID: conversation,
                                workspaceID: uuid(object["workspaceID"]), language: language,
                                documentID: documentID, expectedRevision: revision,
                                text: text, line: int(object["line"]), character: int(object["character"]),
                                hostRequestID: requestID, cancelTarget: object["cancelTarget"] as? String)
        default:
            emitControl(["type": "actionReply", "requestID": requestID, "ok": false,
                         "code": "unknownAction"])
        }
    }

    // MARK: Events (Swift -> host)

    /// One control event (JSON object; the export refuses oversized frames
    /// BEFORE queueing — a control event that cannot fit is a bug at the
    /// producer, so the refusal is counted and surfaced in stats).
    func emitControl(_ object: [String: Any], expectedEpoch: UInt64? = nil) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= G04TerminalHostLimits.maximumFrameBytes else {
            condition.lock(); counters.actionRejections += 1; condition.unlock()
            return
        }
        enqueue(payload: nil, control: data, expectedEpoch: expectedEpoch)
    }

    /// One raw PTY output chunk. Oversized chunks are split into <=64 KiB
    /// events with monotonic `seq` so the renderer never sees a truncated
    /// frame boundary it cannot detect.
    func emitOutput(sessionToken: String, seq: Int64, bytes: Data, expectedEpoch: UInt64? = nil) {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + G04TerminalHostLimits.maximumEventPayloadBytes, bytes.count)
            let chunk = bytes.subdata(in: offset..<end)
            offset = end
            let descriptor: [String: Any] = [
                "type": "terminalOutput", "sessionToken": sessionToken,
                "seq": seq, "chunkBytes": chunk.count, "lastChunk": offset == bytes.count,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
            else { continue }
            enqueue(payload: chunk, control: data, expectedEpoch: expectedEpoch)
        }
    }

    private func enqueue(payload: Data?, control: Data, expectedEpoch: UInt64?) {
        condition.lock(); defer { condition.unlock() }
        guard !closed, epoch != 0, expectedEpoch == nil || expectedEpoch == epoch else { return }
        // Reserve one event/256 bytes for a single explicit overflow marker.
        // Claimed events remain counted, so a paused consumer cannot create
        // an unbounded control queue. Control events are never evicted.
        while events.count + 1 > G04TerminalHostLimits.maximumLiveEvents - 1 ||
              eventBytes + control.count + (payload?.count ?? 0) > G04TerminalHostLimits.maximumEventBytes - 256 {
            guard let victim = eventQueue.first(where: { events[$0]?.rawPayload != nil }) else {
                if payload != nil { counters.evictedOutput += 1; return }
                controlOverflow += 1
                if overflowEvent == nil {
                    let marker = Data("{\"type\":\"hostEventOverflow\"}".utf8)
                    let token = nextToken; nextToken += 1
                    events[token] = Event(token: token, createdEpoch: epoch, controlJSON: marker, rawPayload: nil)
                    overflowEvent = token; eventQueue.append(token); eventBytes += marker.count
                    counters.events += 1; condition.broadcast()
                }
                return
            }
            retiredEventLocked(victim); counters.evictedOutput += 1
        }
        // Allocate under this lock. The old token closure recursively locked
        // NSCondition and deadlocked the very first hostBound publication.
        let token = nextToken; nextToken += 1
        events[token] = Event(token: token, createdEpoch: epoch, controlJSON: control, rawPayload: payload)
        eventQueue.append(token); eventBytes += control.count + (payload?.count ?? 0)
        counters.events += 1; condition.broadcast()
    }

    /// Non-blocking-with-bounded-wait claim of the oldest event for the
    /// CURRENT generation. 0 = none; -1 = closed. A claimed event stays in
    /// the byte accounting until `ack` (or a fence), so the host cannot
    /// outrun the bound by holding claims; foreign-generation events are
    /// retired, never delivered.
    public func nextEvent(timeoutMillis: Int32) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        guard !closed, epoch != 0 else { return -1 }
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, timeoutMillis)) / 1000.0)
        while true {
            if let head = eventQueue.first {
                if let event = events[head], event.createdEpoch == epoch {
                    eventQueue.removeFirst()
                    return head
                }
                // Foreign/absent head: drop it from the queue (and retire
                // if it is still a live map entry of an old generation).
                eventQueue.removeFirst()
                retiredEventLocked(head)
                continue
            }
            if Date() >= deadline { return 0 }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
            if closed { return -1 }
        }
    }

    public func describe(event: Int64, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let value = events[event], value.createdEpoch == epoch, !closed else { return -101 }
        guard capacity > 0, let buffer, value.controlJSON.count + 1 <= Int(capacity) else { return -106 }
        value.controlJSON.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(buffer, base, value.controlJSON.count)
        }
        buffer[value.controlJSON.count] = 0
        return Int32(value.controlJSON.count)
    }

    public func eventPayloadLength(event: Int64) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let value = events[event], value.createdEpoch == epoch, !closed else { return -101 }
        return Int32(value.rawPayload?.count ?? 0)
    }

    public func takeEventPayload(event: Int64, buffer: UnsafeMutablePointer<UInt8>?, capacity: Int32) -> Int32 {
        condition.lock(); defer { condition.unlock() }
        guard let value = events[event], value.createdEpoch == epoch, !closed else { return -101 }
        let payload = value.rawPayload ?? Data()
        guard capacity >= 0, let buffer, Int(capacity) >= payload.count else { return -106 }
        if !payload.isEmpty {
            payload.withUnsafeBytes { raw in
                buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: payload.count)
            }
        }
        return Int32(payload.count)
    }

    /// The host finished processing one claimed event; frees the slot.
    public func ack(event: Int64) -> Int32 {
        condition.lock()
        guard events[event] != nil else {
            if retired.contains(event) { counters.lateAck += 1 }
            condition.unlock()
            return -101
        }
        retiredEventLocked(event)
        condition.broadcast()
        condition.unlock()
        return 0
    }

    /// Removes one event (claimed-and-acked, evicted, or fenced). The byte
    /// accounting is subtracted EXACTLY once here — claims do not subtract.
    private func retiredEventLocked(_ token: Int64) {
        if overflowEvent == token { overflowEvent = nil }
        if let value = events.removeValue(forKey: token) {
            eventBytes = max(0, eventBytes - value.controlJSON.count - (value.rawPayload?.count ?? 0))
        }
        eventQueue.removeAll { $0 == token }
        retired.insert(token)
        retiredOrder.append(token)
        while retiredOrder.count > G04TerminalHostLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    private func retireLocked(_ token: Int64) {
        retired.insert(token)
        retiredOrder.append(token)
        while retiredOrder.count > G04TerminalHostLimits.maximumRetired {
            retired.remove(retiredOrder.removeFirst())
        }
    }

    public var isBound: Bool {
        condition.lock(); defer { condition.unlock() }
        return !closed && epoch != 0
    }

    public func statsJSON() -> String {
        condition.lock()
        let object: [String: Any] = [
            "epoch": epoch, "closed": closed,
            "liveActions": liveActionCount, "liveEvents": events.count, "eventBytes": eventBytes,
            "counters": [
                "actions": counters.actions, "actionRejections": counters.actionRejections,
                "events": counters.events, "evictedOutput": counters.evictedOutput, "controlOverflow": controlOverflow,
                "fenced": counters.fenced, "lateAck": counters.lateAck,
                "bindRejections": counters.bindRejections,
            ],
        ]
        condition.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"error\":\"stats\"}" }
        return text
    }
}

// MARK: - Sink adapter

/// The domain-side view over the mailbox egress. The store/server actors
/// never see ticket internals.
public struct G04TerminalMailboxSink: G04TerminalEventSink {
    let mailbox: G04TerminalHostMailbox
    let epoch: UInt64
    public init(mailbox: G04TerminalHostMailbox, epoch: UInt64) { self.mailbox = mailbox; self.epoch = epoch }
    public func emitControl(_ object: [String: Any]) { mailbox.emitControl(object, expectedEpoch: epoch) }
    public func emitOutput(sessionToken: String, seq: Int64, bytes: Data) {
        mailbox.emitOutput(sessionToken: sessionToken, seq: seq, bytes: bytes, expectedEpoch: epoch)
    }
}

// MARK: - Helpers

private func uuid(_ value: Any?) -> UUID? {
    guard let text = value as? String else { return nil }
    guard let parsed = UUID(uuidString: text), text.lowercased() == parsed.uuidString.lowercased() else { return nil }
    return parsed
}

private func int(_ value: Any?) -> Int? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
    return nil
}

/// TRUE JSON bool only (bridged NSNumber backed by CFBoolean). Numbers/
/// strings never coerce, so a durable settings write cannot be minted from
/// a malformed descriptor.
private func strictBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

// MARK: - Trusted host C ABI (Kotlin terminal/LSP pump only; NOT a V3 command)

@_cdecl("floe_g04_terminal_bind")
public func floeG04TerminalBind(_ epoch: UInt64) -> Int32 {
    guard G02NativeRootEpoch.readback() == epoch else { return -102 }
    return G04TerminalHostMailbox.shared.bind(newEpoch: epoch) ? 0 : -105
}

@_cdecl("floe_g04_terminal_submit_action")
public func floeG04TerminalSubmitAction(_ descriptor: UnsafePointer<UInt8>?, _ descriptorLen: Int32,
                                        _ payload: UnsafePointer<UInt8>?, _ payloadLen: Int32) -> Int64 {
    guard descriptorLen > 0, descriptorLen <= G04TerminalHostLimits.maximumFrameBytes, let descriptor else {
        return -105
    }
    let descriptorData = Data(bytes: descriptor, count: Int(descriptorLen))
    let payloadData: Data?
    if payloadLen > 0 {
        guard payloadLen <= G04TerminalHostLimits.maximumPayloadBytes, let payload else { return -106 }
        payloadData = Data(bytes: payload, count: Int(payloadLen))
    } else {
        payloadData = nil
    }
    return G04TerminalHostMailbox.shared.submitAction(descriptor: descriptorData, payload: payloadData)
}

@_cdecl("floe_g04_terminal_next_event")
public func floeG04TerminalNextEvent(_ timeoutMillis: Int32) -> Int64 {
    G04TerminalHostMailbox.shared.nextEvent(timeoutMillis: timeoutMillis)
}

@_cdecl("floe_g04_terminal_describe")
public func floeG04TerminalDescribe(_ event: Int64, _ buffer: UnsafeMutablePointer<CChar>?,
                                    _ capacity: Int32) -> Int32 {
    G04TerminalHostMailbox.shared.describe(event: event, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_terminal_payload_length")
public func floeG04TerminalPayloadLength(_ event: Int64) -> Int32 {
    G04TerminalHostMailbox.shared.eventPayloadLength(event: event)
}

@_cdecl("floe_g04_terminal_take_payload")
public func floeG04TerminalTakePayload(_ event: Int64, _ buffer: UnsafeMutablePointer<UInt8>?,
                                       _ capacity: Int32) -> Int32 {
    G04TerminalHostMailbox.shared.takeEventPayload(event: event, buffer: buffer, capacity: capacity)
}

@_cdecl("floe_g04_terminal_ack")
public func floeG04TerminalAck(_ event: Int64) -> Int32 {
    G04TerminalHostMailbox.shared.ack(event: event)
}

@_cdecl("floe_g04_terminal_close")
public func floeG04TerminalClose(_ epoch: UInt64) -> Int32 {
    // Exact-epoch synchronous fence; session retirement continues detached
    // under the ORIGINAL engine reconciliation ownership (a stop REQUEST is
    // never claimed here as a proven stop).
    G04TerminalHostMailbox.shared.close(closingEpoch: epoch) ? 0 : -102
}

@_cdecl("floe_g04_terminal_stats")
public func floeG04TerminalStats(_ buffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    let text = G04TerminalHostMailbox.shared.statsJSON()
    guard let buffer, capacity > 0 else { return -105 }
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return -106 }
    for (index, byte) in bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}
