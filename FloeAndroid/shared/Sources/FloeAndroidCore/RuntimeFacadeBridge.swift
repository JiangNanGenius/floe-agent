// SPDX-License-Identifier: MPL-2.0
//
// RB-1 runtime bootstrap — v3 binder handlers, internal processors and the
// runtime JNI C ABI.
//
// Binding honesty (RB1 handoff): this package registers ONLY the handlers
// truly available from bootstrap —
//   * `system.bootstrap` / `system.shutdown` / `system.lifecycle`
//     (applicationConfiguration/system vocabulary already in the frozen 57/14
//     matrix),
//   * `effect.poll` (floe.effect-cursor/3 pump over real operation receipts),
//   * `event.poll` (floe.event-cursor/3 durable-window + live-consumer pump).
// Every other command keeps its unchanged fail-closed
// `runtimeUnavailable` refusal; no provider/model/task/run/skill/MCP/
// credential handler is registered or advertised before its own package,
// and no fake success service is invented. The Kotlin host never holds a
// Swift continuation: results flow back only through the two poll channels.
//
// Synchronous binder handlers (running on any JNI thread) do ONLY: strict
// envelope field re-read, correlation dedupe lookup, bounded receipt mint,
// bounded mailbox enqueue, immediate receipt JSON return. They never await
// the owner actor, network or SQLite. The `_cdecl` lifecycle ABI follows the
// frozen gateway discipline: bounded ASCII/UTF-8 inputs, exact C-string copy
// out, no JNI in Swift, no global state beyond the bootstrap lifecycle lock.
//
// This source is NOT compiled/executed by the authoring package.
import Foundation

public enum RuntimeFacadeBridge {

    // MARK: - Handler keys

    /// Internal trusted-host lifecycle keys. These are NOT BridgeV3 binder
    /// keys, so a model envelope can never enqueue an internal job.
    public static let internalBootstrapHandlerKey = "internal.system.bootstrap.start"
    public static let internalShutdownHandlerKey = "internal.system.bootstrap.shutdown"

    static var systemBootstrapKey: String {
        BridgeV3.handlerKey(scope: .applicationConfiguration, command: "system.bootstrap")
    }
    static var systemShutdownKey: String {
        BridgeV3.handlerKey(scope: .applicationConfiguration, command: "system.shutdown")
    }
    static var systemLifecycleKey: String {
        BridgeV3.handlerKey(scope: .applicationConfiguration, command: "system.lifecycle")
    }

    /// The exact closed set this generation binds. Main reviews this list;
    /// it must never widen at runtime.
    public static var bootstrapBinderKeys: [String] {
        [systemBootstrapKey, systemShutdownKey, systemLifecycleKey,
         BridgeV3.effectPumpHandlerKey, BridgeV3.runEventPumpHandlerKey]
    }

    // MARK: - Install / uninstall

    static func install(for gen: AndroidRuntimeBootstrap.Generation) {
        // Internal lifecycle processors run the REAL async work. R2: the
        // ACTUAL job correlationID is carried through wait/retire, never a
        // reconstructed name. The closure captures THIS generation's epoch so
        // a late old job can never address a newer owner.
        let generationEpoch = gen.epoch
        gen.registry.register(
            handlerKey: internalBootstrapHandlerKey,
            processor: RuntimeAsyncProcessor { job in
                guard let pumps = AndroidRuntimeBootstrap.currentPumps(),
                      pumps.epoch == generationEpoch,
                      "host:bootstrap:\(generationEpoch)" == job.correlationID else {
                    return .rejected(.notInstalled)
                }
                return await AndroidRuntimeBootstrap.runBootstrapJob(
                    epoch: generationEpoch, correlation: job.correlationID,
                    owner: gen.owner)
            })
        gen.registry.register(
            handlerKey: internalShutdownHandlerKey,
            processor: RuntimeAsyncProcessor { job in
                // A failed-retirement control must remain runnable while the
                // generation is typed `retiring` (R3). The job body verifies
                // the exact receipt/correlation; commands still use
                // `currentPumps()` and stay fenced.
                return await AndroidRuntimeBootstrap.runShutdownJob(
                    epoch: generationEpoch, receipt: job.receipt,
                    correlation: job.correlationID)
            })
        // Async processors for the two model-visible command.submit keys.
        gen.registry.register(handlerKey: systemBootstrapKey,
                              processor: commandProcessor(command: "system.bootstrap",
                                                          epoch: gen.epoch))
        gen.registry.register(handlerKey: systemShutdownKey,
                              processor: commandProcessor(command: "system.shutdown",
                                                          epoch: gen.epoch))
        // Synchronous binder handlers.
        let binder = RuntimeCommandBinder.shared
        binder.register(systemBootstrapKey, makeCommandSubmitHandler(
            scope: .applicationConfiguration, command: "system.bootstrap"))
        binder.register(systemShutdownKey, makeCommandSubmitHandler(
            scope: .applicationConfiguration, command: "system.shutdown"))
        binder.register(systemLifecycleKey, lifecycleHandler)
        binder.register(BridgeV3.effectPumpHandlerKey, effectPollHandler)
        hasInstalledEffectPoll = true
        binder.register(BridgeV3.runEventPumpHandlerKey, eventPollHandler)
    }

    /// Command ingress + run-event ingress. The read-only `effect.poll`
    /// handler deliberately REMAINS bound once installed: R1 needs closed/
    /// failed generation terminals to stay readable through the actual v3
    /// entry after the real DB close. It can never admit a command.
    static func uninstall() {
        let binder = RuntimeCommandBinder.shared
        for key in [systemBootstrapKey, systemShutdownKey, systemLifecycleKey,
                    BridgeV3.runEventPumpHandlerKey] {
            binder.unregister(key)
        }
    }

    /// Test-only full restore (the frozen pre-bootstrap `effectPumpUnbound`
    /// refusal must be observable again between suites).
    static func uninstallAllForTesting() {
        let binder = RuntimeCommandBinder.shared
        for key in bootstrapBinderKeys {
            binder.unregister(key)
        }
        hasInstalledEffectPoll = false
    }

    // MARK: - command.submit handlers (validate + enqueue + immediate receipt)

    private static func makeCommandSubmitHandler(scope: BridgeV3.Scope,
                                                 command: String)
        -> RuntimeCommandBinder.Handler {
        let binderKey = BridgeV3.handlerKey(scope: scope, command: command)
        return { data in
            // The envelope was already structurally validated by BridgeV3
            // before dispatch; re-read only the stable identity fields.
            guard let envelope = Self.parseObject(data),
                  let correlation = envelope["correlationID"] as? String,
                  !correlation.isEmpty else {
                return Self.errorJSON(error: "invalidEnvelope",
                                      reason: "malformedAfterValidation")
            }
            // R4: lifecycle commands never accept a payload that pretends to
            // choose a host root/owner/generation or an unknown lifecycle
            // field. An empty payload object is harmless; anything else is
            // refused BEFORE minting a receipt (no fake success, no ignored
            // root mutation).
            if command == "system.bootstrap" || command == "system.shutdown" {
                if !Self.lifecyclePayloadAllowed(envelope) {
                    return Self.errorJSON(error: "invalidEnvelope",
                                          reason: "invalidLifecyclePayload")
                }
            }
            guard let pumps = AndroidRuntimeBootstrap.currentPumps() else {
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: "bootstrapNotInstalled")
            }
            if pumps.mailbox.isAdmissionFenced {
                // Drain/close fence at the accepted boundary (M3): refuse
                // NEW admissions without minting a useless receipt stream.
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.alreadyDraining.rawValue)
            }
            // Correlation dedupe FIRST (no second receipt mint).
            if let existing = pumps.mailbox.liveReceipt(correlationID: correlation) {
                return Self.receiptJSON(correlation: correlation, receipt: existing)
            }
            guard let receipt = pumps.effects.register(correlationID: correlation)
            else {
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.receiptSaturated.rawValue)
            }
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: binderKey,
                command: command,
                scope: scope,
                configurationScope: "system",
                receipt: receipt,
                envelope: data)
            switch pumps.mailbox.submit(job) {
            case .queued:
                return Self.receiptJSON(correlation: correlation, receipt: receipt)
            case .duplicate(let existing):
                // Dedupe replays the ORIGINAL receipt only; the duplicate's
                // own fresh stream settled typed `duplicateCorrelation`.
                return Self.receiptJSON(correlation: correlation, receipt: existing)
            case .rejected(let code):
                // The mailbox already terminalised the stream with the typed
                // rejection; the response carries no receipt.
                return Self.errorJSON(error: "runtimeUnavailable", reason: code.rawValue)
            }
        }
    }

    /// `system.lifecycle` answers from the lock-only snapshot IMMEDIATELY:
    /// separate typed facts (gateway / owned store / domain) with no mailbox
    /// round trip and no fabricated readiness.
    private static let lifecycleHandler: RuntimeCommandBinder.Handler = { data in
        guard let envelope = Self.parseObject(data),
              let correlation = envelope["correlationID"] as? String else {
            return Self.errorJSON(error: "invalidEnvelope",
                                  reason: "malformedAfterValidation")
        }
        let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
        guard let statusObject = Self.parseData(Data(status.utf8)) else {
            return Self.errorJSON(error: "runtimeUnavailable", reason: "statusEncoding")
        }
        return Self.finalize([
            "ok": true,
            "schema": BridgeV3.commandSchema,
            "correlationID": correlation,
            "lifecycle": statusObject,
        ]) ?? Self.errorJSON(error: "runtimeUnavailable", reason: "frameBudgetExceeded")
    }

    // MARK: - effect.poll handler (floe.effect-cursor/3)

    /// The v3 `effect.poll` handler. Routing order is significant:
    /// 1. the CURRENT generation's pump (live, even if retiring),
    /// 2. the bounded retired-terminal registry (closed/failed generations),
    /// 3. the frozen pre-bootstrap `effectPumpUnbound` refusal.
    /// A stale receipt is never routed into the new pump.
    ///
    /// Carrier integration (Main decision 2026-10-19): the handler PEEKS a
    /// page already selected within the ACTUAL encoded effect-body budget,
    /// encodes the complete frame, and only then ACKNOWLEDGES delivery.
    /// A failed serialization can therefore never mark effects as read and
    /// can never allow an unread terminal result to be evicted; the consumer
    /// simply retries the same cursor.
    private static let effectPollHandler: RuntimeCommandBinder.Handler = { data in
        guard let envelope = Self.parseObject(data),
              let correlation = envelope["correlationID"] as? String,
              let effect = envelope["effect"] as? [String: Any],
              let receipt = effect["operationReceiptID"] as? String,
              let sequence = effect["sequence"] as? Int,
              sequence >= 0 else {
            return Self.errorJSON(error: "invalidEnvelope",
                                  reason: "malformedEffectCursor")
        }
        if let pumps = AndroidRuntimeBootstrap.currentEffectPumps() {
            switch pumps.effects.peekPage(
                receipt: receipt, afterSequence: sequence,
                bodyBudgetBytes: Self.effectBodyBudget(correlationID: correlation,
                                                       receipt: receipt,
                                                       afterSequence: sequence)) {
            case .expired:
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.effectReceiptExpired.rawValue)
            case .page(let effects, let nextSequence, let hasMore, let resync):
                // Zero-progress is a typed refusal, never an empty page that
                // claims more: the consumer must reconcile, not spin.
                if effects.isEmpty, hasMore {
                    return Self.errorJSON(error: "runtimeUnavailable",
                                          reason: RuntimeFacadeCode.frameBudgetExceeded.rawValue)
                }
                if let frame = Self.effectPageJSON(correlation: correlation,
                                                   receipt: receipt,
                                                   effects: effects,
                                                   nextSequence: nextSequence,
                                                   hasMore: hasMore, resync: resync) {
                    // Delivery boundary: the frame crossed serialization and
                    // fits the wire. NOW the read cursor advances.
                    pumps.effects.acknowledge(receipt: receipt,
                                              throughSequence: nextSequence)
                    return frame
                }
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.frameBudgetExceeded.rawValue)
            case .notFound:
                break   // fall through to the retired route
            }
        }
        let retired = RuntimeRetiredEffectRegistry.shared
        // A just-closed generation's pump remains addressable until its
        // anchor terminal settles; this is still read-only and bounded.
        if let pending = retired.pollPending(
            receipt: receipt, afterSequence: sequence,
            bodyBudgetBytes: Self.effectBodyBudget(correlationID: correlation,
                                                   receipt: receipt,
                                                   afterSequence: sequence)) {
            switch pending {
            case .expired:
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.effectReceiptExpired.rawValue)
            case .page(let effects, let nextSequence, let hasMore, let resync):
                if let frame = Self.effectPageJSON(correlation: correlation,
                                                   receipt: receipt,
                                                   effects: effects,
                                                   nextSequence: nextSequence,
                                                   hasMore: hasMore, resync: resync) {
                    _ = retired.acknowledgePending(receipt: receipt,
                                                   throughSequence: nextSequence)
                    return frame
                }
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.frameBudgetExceeded.rawValue)
            case .notFound:
                break
            }
        }
        if hasInstalledEffectPoll || !retired.isEmpty {
            switch retired.poll(receipt: receipt, afterSequence: sequence,
                                bodyBudgetBytes: Self.effectBodyBudget(
                                    correlationID: correlation, receipt: receipt,
                                    afterSequence: sequence)) {
            case .expired:
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.effectReceiptExpired.rawValue)
            case .notFound:
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.effectReceiptNotFound.rawValue)
            case .page(let effects, let nextSequence, let hasMore, let resync):
                if let frame = Self.effectPageJSON(correlation: correlation,
                                                   receipt: receipt,
                                                   effects: effects,
                                                   nextSequence: nextSequence,
                                                   hasMore: hasMore, resync: resync) {
                    return frame
                }
                return Self.errorJSON(error: "runtimeUnavailable",
                                      reason: RuntimeFacadeCode.frameBudgetExceeded.rawValue)
            }
        }
        return Self.errorJSON(error: "runtimeUnavailable",
                              reason: "effectPumpUnbound")
    }

    /// Worst-case cursor width for the overhead derivation: the consumer
    /// cursor is bounded by retained sequences, and `sequenceDigits` uses the
    /// response cursor plus the pump's frozen per-receipt caps.
    static func effectBodyBudget(correlationID: String, receipt: String,
                                 afterSequence: Int) -> Int {
        let digits = max(1, afterSequence).description.count
            + FacadeEffectPump.Limits.maximumEffectsPerReceipt.description.count
            + FacadeEffectPump.Limits.sequenceDigitHeadroom
        return FacadeFrameBudget.effectBodyBudgetBytes(
            correlationID: correlationID, receipt: receipt,
            sequenceDigits: digits)
    }

    /// Composer-facing budget: the ACTUAL encoded bytes a domain processor
    /// may plan for when composing a typed page/value result for a live
    /// receipt, derived from the complete wire overhead (page budget minus
    /// the exact effect-frame wrapper and exchange stamp margin), never a
    /// fixed 16 KiB guess. nil for unknown receipts.
    public static func availablePayloadBodyBytes(correlationID: String,
                                                 receipt: String) -> Int? {
        let digits = FacadeEffectPump.Limits.sequenceDigitHeadroom
            + FacadeEffectPump.Limits.maximumEffectsPerReceipt.description.count
        let overhead = FacadeFrameBudget.effectFrameOverheadBytes(
            correlationID: correlationID, receipt: receipt,
            sequenceDigits: max(1, digits))
        guard overhead != Int.max else { return nil }
        return max(0, FacadeFrameBudget.pageBudgetBytes - overhead)
    }

    private static func effectPageJSON(correlation: String, receipt: String,
                                       effects: [RuntimeEffectItem],
                                       nextSequence: Int, hasMore: Bool,
                                       resync: Bool) -> Data? {
        let objects = effects.map { $0.jsonObject }
        return Self.finalizeWithin([
            "ok": true,
            "schema": BridgeV3.effectSchema,
            "correlationID": correlation,
            "cursor": ["operationReceiptID": receipt, "sequence": nextSequence],
            "effects": objects,
            "hasMore": hasMore,
            "resyncRequired": resync,
        ], pageBudgetBytes: FacadeFrameBudget.pageBudgetBytes,
           outerMarginBytes: correlation.utf8.count + 64)
    }

    // MARK: - event.poll handler (floe.event-cursor/3)

    private static let eventPollHandler: RuntimeCommandBinder.Handler = { data in
        guard let envelope = Self.parseObject(data),
              let correlation = envelope["correlationID"] as? String,
              let owner = envelope["owner"] as? [String: Any],
              let runRaw = owner["runID"] as? String,
              let runID = UUID(uuidString: runRaw),
              let cursor = envelope["cursor"] as? [String: Any],
              let sequence = cursor["sequence"] as? Int,
              sequence >= 0 else {
            return Self.errorJSON(error: "invalidEnvelope",
                                  reason: "malformedEventCursor")
        }
        guard let pumps = AndroidRuntimeBootstrap.currentPumps() else {
            return Self.errorJSON(error: "runtimeUnavailable",
                                  reason: "eventPumpUnbound")
        }
        // Durable pages come from the ORIGINAL append-only run event store via
        // the bounded window; no window exists => explicit notAttached state,
        // never synthesized events. Live frames exist only while a real run
        // track task (RB4) attaches a consumer; until then the honest
        // "noConsumer" is reported.
        let durable = pumps.events.pollDurable(runID: runID, afterSequence: sequence,
                                               budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        let live = pumps.events.takeLatestLive(runID: runID,
                                               budgetBytes: 16_384)
        let resync = (durable["resyncRequired"] as? Bool == true)
            || (live["resyncRequired"] as? Bool == true)
        return Self.finalize([
            "ok": true,
            "schema": BridgeV3.runEventSchema,
            "correlationID": correlation,
            "cursor": ["runID": runID.uuidString, "sequence": sequence],
            "durable": durable,
            "live": live,
            "resyncRequired": resync,
        ]) ?? Self.errorJSON(error: "runtimeUnavailable",
                             reason: "frameBudgetExceeded")
    }

    // MARK: - v3 command processors (async; registered by install)

    /// The async executor for the two bound command.submit keys.
    static func commandProcessor(command: String,
                                 epoch: UInt64) -> RuntimeAsyncProcessor {
        RuntimeAsyncProcessor { job in
            switch command {
            case "system.bootstrap":
                // Model-visible CONFIRM only: the trusted root can only
                // arrive through the JNI owner seam. Return accepted only if
                // THIS generation's post-state is still committed.
                guard AndroidRuntimeBootstrap.confirmCommitted(
                    expectedEpoch: epoch) else {
                    return .failed(.notInstalled)
                }
                return .accepted(detail: ["confirm": "alreadyCommitted",
                                          "ownedStoreReady": "true",
                                          "domainRuntimeReady": "false"])
            case "system.shutdown":
                // R4: the public job's OWN receipt is the control receipt; it
                // is settled by the mailbox only after the real DB close.
                return await AndroidRuntimeBootstrap.runPublicShutdown(
                    job: job, expectedEpoch: epoch)
            default:
                // Defense in depth: no other command reaches this registry.
                return .rejected(.domainNotBound)
            }
        }
    }

    /// R4: an empty payload object (or no payload) is allowed; any other
    /// payload for a trusted lifecycle command is refused because it pretends
    /// to influence host root/owner/generation authority.
    static func lifecyclePayloadAllowed(_ envelope: [String: Any]) -> Bool {
        guard let payload = envelope["payload"] else { return true }
        guard let object = payload as? [String: Any] else { return false }
        return object.isEmpty
    }

    // MARK: - JSON helpers

    static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func parseData(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    static func receiptJSON(correlation: String, receipt: String) -> Data {
        // Queue receipt payload ONLY: correlationID + operationReceiptID.
        // No conversation/run/environment/job identity can appear here.
        finalize([
            "ok": true,
            "schema": BridgeV3.commandSchema,
            "correlationID": correlation,
            "queued": true,
            "operationReceiptID": receipt,
        ]) ?? Data("{\"ok\":false,\"error\":\"runtimeUnavailable\",\"reason\":\"frameBudgetExceeded\"}".utf8)
    }

    static func errorJSON(error: String, reason: String) -> Data {
        finalize(["ok": false, "error": error, "reason": reason])
            ?? Data("{\"ok\":false,\"error\":\"runtimeUnavailable\"}".utf8)
    }

    static func finalize(_ object: [String: Any]) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              data.count <= BridgeV3.maximumBytes else {
            return nil
        }
        return data
    }

    /// Carrier integration: strict page-budget finalization. The frame must
    /// (1) serialize, (2) fit the normal 48 KiB page target, and (3) keep
    /// room for the outer `AndroidBridge.exchange` stamp under the frozen
    /// 64 KiB hard bound. `nil` means NOTHING was delivered: the caller must
    /// answer a typed error and must NOT acknowledge the read cursor.
    static func finalizeWithin(_ object: [String: Any],
                               pageBudgetBytes: Int,
                               outerMarginBytes: Int) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            return nil
        }
        // The Kotlin consumer re-encodes each element canonically and
        // enforces its own 48 KiB page / 64 KiB frame limits on THOSE sizes
        // (e.g. it does not escape `/` while Foundation does). A frame is
        // therefore deliverable only if BOTH encodings fit the page target,
        // and the wire bytes plus the outer stamp fit the frozen 64 KiB
        // bound. Never disable either budget.
        let canonical = FacadeFrameBudget.canonicalSerializedBytes(object) ?? Int.max
        guard data.count <= pageBudgetBytes, canonical <= pageBudgetBytes else {
            return nil
        }
        let (sum, overflow) = data.count.addingReportingOverflow(outerMarginBytes)
        guard !overflow, sum <= BridgeV3.maximumBytes else { return nil }
        return data
    }

    /// True after a generation installed the read-only effect route. Kept
    /// process-lifetime so a receipt poll in the tiny interval between
    /// generation release and terminal observation answers typed notFound
    /// rather than pretending the route was never installed.
    nonisolated(unsafe) static var hasInstalledEffectPoll = false
}

// MARK: - C ABI (runtime lifecycle seam)

private func runtimeCopyCString(_ value: String, buffer: UnsafeMutablePointer<CChar>?,
                                capacity: Int32) -> Int32 {
    guard capacity >= 0 else { return RuntimeFacadeStatus.invalidArguments }
    guard let buffer else { return RuntimeFacadeStatus.invalidArguments }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return RuntimeFacadeStatus.bufferTooSmall }
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
    return Int32(bytes.count)
}

private func runtimeReadCString(_ pointer: UnsafePointer<CChar>?, limit: Int) -> String? {
    guard let pointer else { return nil }
    let length = strnlen(pointer, limit)
    guard length > 0, length < limit else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: length),
                  as: UTF8.self)
}

@_cdecl("floe_runtime_owner_start")
public func floeRuntimeOwnerStart(_ rootPath: UnsafePointer<CChar>?,
                                  _ ownerToken: UnsafePointer<CChar>?,
                                  _ epoch: UInt64,
                                  _ outReceipt: UnsafeMutablePointer<CChar>?,
                                  _ outCap: Int32) -> Int32 {
    guard let root = runtimeReadCString(rootPath, limit: 4097),
          let token = runtimeReadCString(ownerToken, limit: 65) else {
        return RuntimeFacadeStatus.invalidArguments
    }
    switch AndroidRuntimeBootstrap.start(rootPath: root, ownerToken: token,
                                         epoch: epoch) {
    case .accepted(let receipt):
        let written = runtimeCopyCString(receipt, buffer: outReceipt, capacity: outCap)
        return written < 0 ? written : RuntimeFacadeStatus.ok
    case .idempotent(let receipt):
        let written = runtimeCopyCString(receipt, buffer: outReceipt, capacity: outCap)
        return written < 0 ? written : RuntimeFacadeStatus.idempotentOk
    case .rejected(let code):
        return RuntimeFacadeStatus.code(for: code)
    }
}

/// RB1-R5: trusted stop carries the exact accepted owner epoch + token. The
/// ABI is intentionally additive (source is unpublished): a stale or
/// proof-less caller cannot stop a newer owner.
@_cdecl("floe_runtime_owner_stop")
public func floeRuntimeOwnerStop(_ expectedEpoch: UInt64,
                                 _ ownerToken: UnsafePointer<CChar>?,
                                 _ outReceipt: UnsafeMutablePointer<CChar>?,
                                 _ outCap: Int32) -> Int32 {
    guard expectedEpoch > 0,
          let token = runtimeReadCString(ownerToken, limit: 65) else {
        return RuntimeFacadeStatus.invalidArguments
    }
    switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: expectedEpoch,
                                            ownerToken: token) {
    case .accepted(let receipt):
        let written = runtimeCopyCString(receipt, buffer: outReceipt, capacity: outCap)
        return written < 0 ? written : RuntimeFacadeStatus.ok
    case .idempotent(let receipt):
        let written = runtimeCopyCString(receipt, buffer: outReceipt, capacity: outCap)
        return written < 0 ? written : RuntimeFacadeStatus.idempotentOk
    case .rejected(let code):
        return RuntimeFacadeStatus.code(for: code)
    }
}

@_cdecl("floe_runtime_status")
public func floeRuntimeStatus(_ buffer: UnsafeMutablePointer<CChar>?,
                              _ capacity: Int32) -> Int32 {
    runtimeCopyCString(AndroidRuntimeBootstrap.statusSnapshotJSON(),
                       buffer: buffer, capacity: capacity)
}
