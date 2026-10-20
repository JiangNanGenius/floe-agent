// SPDX-License-Identifier: MPL-2.0
//
// G02 temporary session (RB5 successor, actual-qualification revision) —
// v3 binder + processor composition for EXACTLY the three existing
// temporary rules of the frozen matrix:
//
//   temp.start   scope launch               (create intent; NO taskID)
//   temp.end     scope conversationLifecycle (real hosted taskID +
//                 revision session.<conversationID>/<incarnation>)
//   temp.keep    scope conversationLifecycle (same revision authority)
//
// No new commands, scope labels, configuration labels or effect kinds are
// introduced. The temporary domain owns this installation surface only: it
// never edits the reviewed RB1 bootstrap/mailbox/pump internals, never
// touches `event.poll` / `effect.poll`, and never re-registers sibling
// keys.
//
// TMP-NAV-2 (Main mandatory repair, this revision): the `temp.end`
// synchronous submit handler performs the ADMISSION FENCE itself — under
// the lock-only `TemporaryNavigationGate`, before the receipt returns and
// with zero awaits, zero SQLite and zero mailbox hops. This fences queued
// starts, late saves/launches and in-flight-Keep commits BEFORE any next
// route command can be admitted, even while the mailbox worker is blocked
// behind an in-flight Keep. The authoritative typed acknowledgement
// `value.navigationFence` {admitted:true, conversationID, incarnationID,
// requestCorrelationID, epoch, reason} rides the SAME receipt's effect
// stream as a non-terminal `prepared` stage immediately after successful
// enqueue. The queue receipt itself is NEVER an ack; a `prepared`/terminal
// WITHOUT the exact typed fence object is never an ack; `refused` never is.
// Exact `alreadyAbsent` / `alreadyRetired` certifications come from the
// same lock and are therefore authoritative. Actual store close, run
// cancellation and drain follow asynchronously through the real owned
// services; the host can route after the fence admission, without waiting
// for the whole cancellation drain.
//
// G02 production composition (this revision): `G02TemporaryDomainExtension`
// implements the frozen `G02DomainExtension` seam and attaches INSIDE the
// owned install over the accepted generation: the SAME owner, epoch,
// `DatabaseManager`, schema-46 cluster, the real binder/typed effect
// carrier, the ORIGINAL ephemeral bundles, the ORIGINAL run domain actor
// behind the production port adapter, and the trusted host model route.
// It registers nothing until the ordinary base installed; a failed attach
// self-rolls-back (no binder keys, no processors, no static state) and
// never gates the ordinary graph. Readiness for `temporaryDomain` becomes
// true ONLY through the frozen rule: the real extension attached AND the
// three actual keys bound (G02Readiness).
import Foundation
import FloeCore
import FloePersistence
import FloeTools

public enum TemporaryDomainFacade {

    // MARK: Registry (one live domain per accepted epoch)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: (epoch: UInt64,
                                                  domain: FacadeTemporaryDomain,
                                                  gate: TemporaryNavigationGate)?

    static func install(_ entry: (epoch: UInt64,
                                  domain: FacadeTemporaryDomain,
                                  gate: TemporaryNavigationGate)) {
        lock.lock(); live = entry; lock.unlock()
    }

    public static func current(epoch: UInt64) -> FacadeTemporaryDomain? {
        lock.lock(); defer { lock.unlock() }
        guard let live, live.epoch == epoch else { return nil }
        return live.domain
    }

    static func currentGate(epoch: UInt64) -> TemporaryNavigationGate? {
        lock.lock(); defer { lock.unlock() }
        guard let live, live.epoch == epoch else { return nil }
        return live.gate
    }

    /// Test/integration reset. Never called by a wire path.
    internal static func clearForTesting() {
        lock.lock(); live = nil; lock.unlock()
    }

    // MARK: Handler keys (computed with the LIVE frozen helper)

    public enum HandlerPlan {
        public struct Binding: Sendable, Equatable {
            public let handlerKey: String
            public let command: String
            public let scope: BridgeV3.Scope
            public let configurationScope: String?
            public let serviceMethod: String
            public let integrationNote: String
        }

        public static var bindings: [Binding] {
            [
                Binding(
                    handlerKey: BridgeV3.handlerKey(scope: .launch, command: "temp.start"),
                    command: "temp.start", scope: .launch, configurationScope: nil,
                    serviceMethod: "FacadeTemporaryDomain.start",
                    integrationNote: "create intent, no owner/revision (frozen matrix rule); closed payload {draft, preferredModelID}; hosted UUID + fresh incarnation minted by the Swift domain AFTER the RAM session is committed and surface ONLY in the async prepared effect + accepted value; queue receipt is correlation+operationReceiptID only; accepted value carries rootEpoch = the ACTUAL native root epoch"),
                Binding(
                    handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                    command: "temp.end"),
                    command: "temp.end", scope: .conversationLifecycle,
                    configurationScope: nil,
                    serviceMethod: "FacadeTemporaryDomain.end",
                    integrationNote: "real hosted taskID + revision session.<conversationID>/<incarnation>; TMP-NAV-2 synchronous admission in the submit handler: exact identity/root validation + commit-fence flip + slot tombstone + pending-start fencing under the lock BEFORE the receipt returns, then the typed value.navigationFence admitted acknowledgement rides the same receipt stream as a non-terminal prepared stage; actual store close / explicit run-service cancel dispatch / exact-session draft clear follow asynchronously and settle the accepted terminal {session ended, endRoute newTask, endState}; refused admissions never acknowledge; exact alreadyAbsent/alreadyRetired certifications are authoritative"),
                Binding(
                    handlerKey: BridgeV3.handlerKey(scope: .conversationLifecycle,
                                                    command: "temp.keep"),
                    command: "temp.keep", scope: .conversationLifecycle,
                    configurationScope: nil,
                    serviceMethod: "FacadeTemporaryDomain.keep",
                    integrationNote: "current incarnation only; beginPromotion across all three original ephemeral stores freezes the watermark; ONE original ConversationPromoter transaction under the TMP-COMMIT-1 commit-boundary fence (allowsCommit/beginFinalCommit/finishFinalCommit — discard linearizes against the ACTUAL SQLite COMMIT); prepared{conversationID} only after the real atomic commit; completePromotion forwards the tail once; pre-commit failure aborts with RAM intact and retryable; post-commit failure returns the truthful tailPending outcome with the durable id and resumes the failed gateway step once; repeat Keep after committed receipt is alreadyCommitted with NO second DB work; a navigation-tombstoned session never resurrects"),
            ]
        }
    }

    // MARK: - Install (trusted host bootstrap glue / extension attach)

    /// Registers EXACTLY the three temporary binder keys + processors over
    /// the reviewed generation components, with the REAL run port, the ONE
    /// owner `DatabaseManager` and the same generation's durable store
    /// cluster. Unregistered optional ports keep their typed conservative
    /// semantics inside the domain (never a noop substitution).
    @discardableResult
    public static func install(components: TemporaryDomainComponents,
                               registry: RuntimeDomainRegistry) -> Bool {
        let domain = FacadeTemporaryDomain(components: components)
        let entry = (epoch: components.epoch, domain: domain,
                     gate: components.gate)
        install(entry)
        let binder = RuntimeCommandBinder.shared
        var boundKeys: [String] = []
        for binding in HandlerPlan.bindings {
            binder.register(binding.handlerKey,
                            makeSubmitHandler(binding: binding,
                                              epoch: components.epoch))
            registry.register(handlerKey: binding.handlerKey,
                              processor: makeProcessor(binding: binding,
                                                       epoch: components.epoch))
            boundKeys.append(binding.handlerKey)
        }
        // Self-rollback support: remember exactly what THIS install bound.
        lock.lock(); installedKeys = boundKeys; lock.unlock()
        return true
    }

    nonisolated(unsafe) private static var installedKeys: [String] = []

    /// Removes only this package's keys. RB1/RB3/RB4 keys are untouched.
    public static func uninstall() {
        let binder = RuntimeCommandBinder.shared
        lock.lock()
        let keys = installedKeys
        installedKeys = []
        lock.unlock()
        for key in keys {
            binder.unregister(key)
        }
        clearForTesting()
    }

    // MARK: - Synchronous submit handlers

    private static func makeSubmitHandler(binding: HandlerPlan.Binding,
                                          epoch: UInt64)
        -> RuntimeCommandBinder.Handler {
        let handlerKey = binding.handlerKey
        let command = binding.command
        let scope = binding.scope
        return { data in
            // BridgeV3 already structurally validated this envelope (scope/
            // command matrix rule, owner roles, revision presence, 64 KiB,
            // UTF-8, zero UUID, correlation shape). Re-read ONLY the stable
            // identity fields (reviewed RB1 pattern).
            guard let envelope = parseObject(data),
                  let correlation = envelope["correlationID"] as? String,
                  !correlation.isEmpty else {
                return errorJSON(error: "invalidEnvelope",
                                 reason: "malformedAfterValidation")
            }
            guard let pumps = AndroidRuntimeBootstrap.currentPumps(),
                  pumps.epoch == epoch, pumps.storeReady else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: "temporaryDomainNotInstalled")
            }
            if pumps.mailbox.isAdmissionFenced {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.alreadyDraining.rawValue)
            }
            guard let gate = currentGate(epoch: epoch) else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: "temporaryDomainNotInstalled")
            }

            // ---- temp.start: ticket BEFORE submit. A navigation that
            // lands while the job is queued fences the ticket, so the
            // processor cannot commit a RAM session after the App already
            // navigated away.
            if command == "temp.start" {
                gate.issueStartTicket(correlation: correlation)
            }

            // ---- temp.end synchronous admission (TMP-NAV-2). Decided
            // under the gate lock, here, BEFORE the receipt returns.
            var endAdmission: TemporaryEndAdmission?
            if command == "temp.end" {
                if let identity = Self.hostedIdentity(from: envelope) {
                    endAdmission = gate.admitEnd(conversationID: identity.conversationID,
                                                 incarnation: identity.incarnation,
                                                 correlation: correlation)
                }
                // Unparseable identity: NO fence (the processor refuses
                // pre-effect exactly like every other malformed state).
            }

            // Correlation dedupe FIRST (never a second receipt mint). A
            // duplicate answer carries no second fence and no second ack.
            if let existing = pumps.mailbox.liveReceipt(correlationID: correlation) {
                if command == "temp.start" { gate.releaseStartTicket(correlation: correlation) }
                return receiptJSON(correlation: correlation, receipt: existing)
            }
            guard let receipt = pumps.effects.register(correlationID: correlation)
            else {
                if command == "temp.start" { gate.releaseStartTicket(correlation: correlation) }
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.receiptSaturated.rawValue)
            }
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: handlerKey,
                command: command,
                scope: scope,
                configurationScope: binding.configurationScope,
                receipt: receipt,
                envelope: data)
            switch pumps.mailbox.submit(job) {
            case .queued:
                // The fence ALREADY landed synchronously for admitted
                // decisions. Emit the authoritative typed acknowledgement
                // on the SAME receipt stream — a NON-terminal `prepared`
                // stage carrying the exact value object. This is what the
                // host routes on; the terminal settles later after the
                // real async cleanup. A failed ack append NEVER invalidates
                // the fence: the accepted terminal then carries the
                // identical navigationFence object (see processor).
                if let admission = endAdmission, let reason = admission.admittedReason {
                    let ack = TemporaryNavigationFenceAck(
                        conversationID: admission.ackConversationID,
                        incarnationID: admission.ackIncarnationID,
                        requestCorrelationID: correlation,
                        epoch: epoch,
                        reason: reason)
                    pumps.effects.append(receipt: receipt, kind: .prepared,
                                         detail: ["navigation": "fenceAdmitted"],
                                         page: nil, value: ack.valueObject())
                }
                return receiptJSON(correlation: correlation, receipt: receipt)
            case .duplicate(let existing):
                // Same correlation: the ORIGINAL receipt's stream already
                // carries (or will carry) the one ack; no second append.
                return receiptJSON(correlation: correlation, receipt: existing)
            case .rejected(let code):
                if command == "temp.start" { gate.releaseStartTicket(correlation: correlation) }
                return errorJSON(error: "runtimeUnavailable", reason: code.rawValue)
            }
        }
    }

    private static func receiptJSON(correlation: String, receipt: String) -> Data {
        // Queue receipt ONLY: correlationID + operationReceiptID. No
        // hosted conversation id, no incarnation, no outcome — those are
        // domain truths minted later, async, after real RAM acceptance.
        RuntimeFacadeBridge.finalize([
            "ok": true,
            "schema": BridgeV3.commandSchema,
            "correlationID": correlation,
            "queued": true,
            "operationReceiptID": receipt,
        ]) ?? Data("{\"ok\":false,\"error\":\"runtimeUnavailable\",\"reason\":\"frameBudgetExceeded\"}".utf8)
    }

    private static func errorJSON(error: String, reason: String) -> Data {
        RuntimeFacadeBridge.finalize(["ok": false, "error": error, "reason": reason])
            ?? Data("{\"ok\":false,\"error\":\"runtimeUnavailable\"}".utf8)
    }

    private static func parseObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Async processors (mailbox jobs)

    private static func makeProcessor(binding: HandlerPlan.Binding,
                                      epoch: UInt64) -> RuntimeAsyncProcessor {
        let command = binding.command
        return RuntimeAsyncProcessor { job in
            guard let domain = current(epoch: epoch),
                  let gate = currentGate(epoch: epoch) else {
                // A retired/newer generation never accepts a stale job.
                return RuntimeCommandResult(kind: .rejected, code: .notInstalled)
            }
            guard let envelopeObject = parseObject(job.envelope) else {
                return RuntimeCommandResult(kind: .rejected, code: .ordinaryRuntimeBlocked,
                                            detail: ["error": "invalidState",
                                                     "reason": "payloadInvalid"])
            }
            var reply: TemporaryDomainReply
            switch command {
            case "temp.start":
                reply = await domain.start(envelope: envelopeObject,
                                           receipt: job.receipt,
                                           correlation: job.correlationID)
            case "temp.end":
                // The synchronous handler already decided admission for
                // wired submits (authoritative). Re-derive nothing: consume
                // the recorded decision; the trusted direct path (no
                // recorded decision) admits freshly here, still synchronously
                // under the same gate lock before the actor touches stores.
                guard let identity = Self.hostedIdentity(from: envelopeObject) else {
                    reply = TemporaryDomainReply(.rejected(
                        TemporaryDomainError(.invalidState, .payloadInvalid)))
                    break
                }
                let decision = gate.decision(correlation: job.correlationID)
                    ?? gate.admitEnd(conversationID: identity.conversationID,
                                     incarnation: identity.incarnation,
                                     correlation: job.correlationID)
                await domain.recordAdmissionForProcessor(
                    endState: decision.admittedReason ?? "refused")
                switch decision {
                case .refused(let error):
                    // The processor must STILL settle the terminal honestly
                    // (the receipt was queued). No cleanup, no tombstone was
                    // produced by a refused admission.
                    reply = await domain.endRefused(error: error)
                case .fenced, .alreadyRetired, .alreadyAbsent:
                    reply = await domain.end(conversationID: identity.conversationID,
                                             incarnation: identity.incarnation,
                                             correlation: job.correlationID)
                    // Belt-and-braces: if the prepared ack could not be
                    // appended synchronously (frame pressure), carry the
                    // identical authoritative object on the terminal.
                    if reply.acceptedValueObject != nil,
                       case .mutationAccepted = reply.outcome,
                       decision.isAdmitted {
                        let ack = TemporaryNavigationFenceAck(
                            conversationID: decision.ackConversationID,
                            incarnationID: decision.ackIncarnationID,
                            requestCorrelationID: job.correlationID,
                            epoch: epoch,
                            reason: decision.admittedReason ?? "fenced")
                        reply = TemporaryDomainReply(reply.withNavigationFence(ack))
                    }
                }
            case "temp.keep":
                // Late Keep admission: a tombstoned/replaced tuple is
                // refused BEFORE touching stores (the commit-boundary fence
                // inside the promoter transaction remains the durable
                // authority for an ALREADY-in-flight promotion).
                guard let identity = Self.hostedIdentity(from: envelopeObject) else {
                    reply = TemporaryDomainReply(.rejected(
                        TemporaryDomainError(.invalidState, .payloadInvalid)))
                    break
                }
                if gate.blocksOperations(conversationID: identity.conversationID,
                                         incarnation: identity.incarnation) {
                    reply = TemporaryDomainReply(.rejected(
                        TemporaryDomainError(.sessionDiscarded, .tombstonedDiscarded)))
                    break
                }
                reply = await domain.keep(conversationID: identity.conversationID,
                                          incarnation: identity.incarnation,
                                          idempotencyKey: UUID(),
                                          receipt: job.receipt,
                                          correlation: job.correlationID)
            default:
                // Defense in depth: nothing else routes here.
                reply = TemporaryDomainReply(.rejected(
                    TemporaryDomainError(.internalError, .internal)))
            }
            return reply.commandResult()
        }
    }

    /// One hosted identity extracted from an ALREADY grammar-validated
    /// conversationLifecycle envelope: taskID UUID + revision
    /// {resourceID == "session.<taskID>", version == incarnation UUID}.
    static func hostedIdentity(from envelope: [String: Any])
        -> (conversationID: UUID, incarnation: UUID)? {
        guard let owner = envelope["owner"] as? [String: Any],
              let taskRaw = owner["taskID"] as? String,
              let conversationID = UUID(uuidString: taskRaw),
              let revision = envelope["revision"] as? [String: Any],
              let resourceID = revision["resourceID"] as? String,
              let version = revision["version"] as? String,
              let incarnation = UUID(uuidString: version),
              resourceID == TemporarySessionRevision.resourceID(
                conversationID: conversationID)
        else { return nil }
        return (conversationID, incarnation)
    }

    // MARK: - Trusted host lifecycle seam (NOT a command)

    /// The typed `system.lifecycle` integration for the temporary domain.
    /// The trusted host glue forwards foreground/background/inactive/lock/
    /// rotation/view-reconstruction observations with the CURRENT accepted
    /// epoch. Hints NEVER discard a session, cancel a run or claim
    /// navigation (TMP-NAV-DISCARD negative); only an actual `temp.end`
    /// issued by the host UI BEFORE the next route's commands ends one.
    public static func noteHostLifecycleHint(
        _ hint: TemporaryHostLifecycleHint, epoch: UInt64) -> TemporaryLifecycleAck {
        // Synchronous and lock-only: the published live identity is the
        // preserved fact (TMP-NAV-DISCARD negative: a hint NEVER discards,
        // cancels or navigates). No actor hop, no await.
        guard let gate = currentGate(epoch: epoch),
              let identity = gate.liveIdentity() else { return .noSession }
        return .preserved(conversationID: identity.conversationID,
                          incarnation: identity.incarnation)
    }

    /// Graceful-generation retirement hook bound into the RootStop path
    /// BEFORE the drain loop (the G02 extension seam invokes it):
    /// synchronously retires the gate (fence + tombstone + pending-start
    /// fencing), then tombstones the live session — DISCARD, NEVER an
    /// implicit Keep — and dispatches explicit cancellation for its owned
    /// runs. An in-flight Keep mailbox job settles truthfully on its own;
    /// its attached `.conversation` owned-work token keeps the RB1 drain
    /// gate honest until the real final writes finish. No timeout detach
    /// anywhere in this package.
    public static func beginGenerationRetirement(epoch: UInt64) async {
        guard let domain = current(epoch: epoch),
              let gate = currentGate(epoch: epoch) else { return }
        // Synchronous admission fence + discard first (never auto-Keep),
        // then the async store close / explicit run-cancel dispatch; the
        // binder ingress is removed ONLY after the instance retired, so no
        // late temp command can reach a half-retired graph.
        gate.retire()
        await domain.beginGenerationRetirement()
        uninstall()
    }

    /// Read-only typed status for the trusted host glue (never a wire
    /// surface).
    public static func status(epoch: UInt64) async -> FacadeTemporaryDomain.StatusSnapshot? {
        guard let domain = current(epoch: epoch) else { return nil }
        return await domain.status()
    }
}

// MARK: - Ack helper projections (closed shapes)

extension TemporaryEndAdmission {
    /// The identity the authoritative ack carries. Absence certifies the
    /// requested hosted conversation with the incarnation the App holds —
    /// for alreadyAbsent there is no incarnation truth beyond the request
    /// itself, which the App matches against its own ref.
    var ackConversationID: UUID {
        switch self {
        case .fenced(let cid, _), .alreadyRetired(let cid, _),
             .alreadyAbsent(let cid): return cid
        case .refused: return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
    }
    var ackIncarnationID: UUID {
        switch self {
        case .fenced(_, let inc), .alreadyRetired(_, let inc): return inc
        case .alreadyAbsent: return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        case .refused: return UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
    }
}

extension TemporaryDomainReply {
    /// Adds the authoritative navigationFence object to an accepted value
    /// carrier (terminal fallback when the synchronous prepared ack could
    /// not be appended). Rejected/failed outcomes are returned unchanged.
    func withNavigationFence(_ ack: TemporaryNavigationFenceAck)
        -> TemporaryDomainReply.Outcome {
        guard case .mutationAccepted(let detail, let value) = outcome,
              case .object(var pairs) = value else { return outcome }
        pairs["navigationFence"] = .object(ack.navigationFencePairs())
        return .mutationAccepted(detail: detail, value: .object(pairs))
    }
}

extension TemporaryNavigationFenceAck {
    func navigationFencePairs() -> [String: DesignJSONValue] {
        [
            "admitted": .bool(true),
            "conversationID": .string(conversationID.uuidString),
            "incarnationID": .string(incarnationID.uuidString),
            "requestCorrelationID": .string(requestCorrelationID),
            "epoch": .integer(Int64(epoch)),
            "reason": .string(reason),
        ]
    }
}

// MARK: - G02 production extension (temporary domain package)

/// The REAL optional-domain extension for the temporary chat package,
/// registered in the pre-bootstrap idle window and attached INSIDE the
/// owned install. Binds ONLY actual services of the accepted generation:
/// the same cluster DatabaseManager/durable stores, the generation's
/// effects pump + registry, the live run domain behind the production port
/// adapter, the trusted model route over the real ModelConfigurationStore,
/// and the D1 provider-readiness view. Every constructor input is the
/// CURRENT live API — never a fixed epoch, never a second DB, never a noop.
final class G02TemporaryDomainExtension: G02DomainExtension {

    let id = G02DomainExtensionKey.temporary
    let domains: [G02DomainKey] = [.temporaryDomain]

    init() {}

    func expectedHandlerKeys(for domain: G02DomainKey) -> [String] {
        domain == .temporaryDomain
            ? TemporaryDomainFacade.HandlerPlan.bindings.map { $0.handlerKey }
            : []
    }

    func attach(to installed: G02InstalledComposition,
                       gen: AndroidRuntimeBootstrap.Generation) async -> Bool {
        let epoch = gen.epoch
        // Refuse a double attach for the same epoch (idempotent installs
        // must never rebind handlers over the live ones).
        if TemporaryDomainFacade.current(epoch: epoch) != nil { return false }
        guard let runPair = RunDomainFacade.current(epoch: epoch) else {
            return false   // the ordinary run domain is not live: honest fail-closed
        }
        let runDomain = runPair.0

        // The synchronous navigation gate for THIS generation.
        let gate = TemporaryNavigationGate(epoch: epoch)

        // Production port: the ONLY implementation composes the documented
        // live `start(query:conversationTitle:receipt:conversationID:
        // bundleOverride:)` seam. Cancel dispatches the ORIGINAL service
        // close for the exact run; live observation is the run domain's own
        // ownership map. Never a noop, never a timeout detach.
        let launch: RuntimeFacadeTemporaryRunAdapter.Launch = {
            query, title, receipt, conversationID, bundle in
            await runDomain.start(query: query, conversationTitle: title,
                                  receipt: receipt, conversationID: conversationID,
                                  bundleOverride: bundle)
        }
        let cancel: RuntimeFacadeTemporaryRunAdapter.Cancel = { runID, _ in
            await runDomain.dispatchTemporaryRunCancel(runID: runID)
        }
        let hasLive: RuntimeFacadeTemporaryRunAdapter.HasLive = { runID, _ in
            await runDomain.hasLiveTemporaryRun(runID: runID)
        }
        // Trusted model route: the REAL configured default/selected model
        // over the same `ModelConfigurationStore` the ordinary UI uses.
        // preferredModelID is honored when provided. nil answers typed
        // needsConfiguration{modelRouteUnresolved} — never a guess, never a
        // first-provider pick, never a local model.
        let modelStore = installed.cluster.modelConfigurationStore
        _ = installed.credentialResolver   // the ordinary run lane owns
                                           // credential admission; the
                                           // temporary route names the pair
                                           // only (see modelRoute above).
        let modelRoute: RuntimeFacadeTemporaryRunAdapter.ModelRoute = { preferred in
            // NEVER a first-provider guess and never a local model: the
            // explicit preferred id (the UI's current selection rides the
            // temp.start payload), else the persisted DEFAULT AGENT model,
            // else a typed nil -> needsConfiguration{modelRouteUnresolved}.
            // The named pair is then PROVEN by the real resolveSelected
            // admission inside start (enabled rows, provider match, wire
            // protocol, no local inference).
            if let preferred {
                guard let model = try? await modelStore.model(id: preferred),
                      model.isEnabled,
                      let provider = try? await modelStore.provider(id: model.providerID),
                      provider.isEnabled else { return nil }
                return (model.providerID, model.id)
            }
            guard let preferences = try? await modelStore.preferences(),
                  let defaultID = preferences.defaultAgentModelID,
                  let model = try? await modelStore.model(id: defaultID),
                  model.isEnabled,
                  let provider = try? await modelStore.provider(id: model.providerID),
                  provider.isEnabled else { return nil }
            return (model.providerID, model.id)
        }

        // D1 availability: the REAL provider-readiness view (same semantics
        // as capability.tools.list: enabled provider whose credential
        // resolves or needs none) consulted per session start.
        let availability: TemporaryWebSearchAvailabilityProviding =
            G02TemporaryWebSearchAvailability(facade: installed.modelConfigurationFacade)

        let components = TemporaryDomainComponents(
            epoch: epoch,
            gate: gate,
            effects: gen.effects,
            database: installed.cluster.database,
            durableConversations: installed.cluster.conversationStore,
            durableRuns: installed.cluster.runStore,
            durableRunningInputs: installed.cluster.runningInputStore,
            toolRegistry: installed.runComponents.registry,
            runPort: RuntimeFacadeTemporaryRunAdapter(
                epoch: epoch, launch: launch, cancel: cancel,
                hasLive: hasLive, modelRoute: modelRoute),
            webSearchAvailability: availability,
            hostSurface: nil)   // documented nil: the App feature layer owns
                                // the RAM composer draft under the exact
                                // hosted id/incarnation and clears it on the
                                // matching typed callbacks.

        guard TemporaryDomainFacade.install(components: components,
                                            registry: gen.registry) else {
            return false
        }
        return true
    }

    func beginRetirement(epoch: UInt64) async {
        guard TemporaryDomainFacade.current(epoch: epoch) != nil else {
            return   // never retire another generation's graph
        }
        await TemporaryDomainFacade.beginGenerationRetirement(epoch: epoch)
        TemporaryDomainFacade.uninstall()
    }

    func isTemporaryConversation(_ conversationID: UUID,
                                        epoch: UInt64) async -> Bool {
        guard let gate = TemporaryDomainFacade.currentGate(epoch: epoch) else {
            return false
        }
        return gate.liveIdentity()?.conversationID == conversationID
    }
}

/// The trusted-host registration hook the RB1 bootstrap calls exactly once
/// in the pre-bootstrap idle window. Ordinary product then installs
/// INDEPENDENTLY of this optional graph; an attach failure is honest,
/// non-gating and self-rolled-back.
enum G02TemporaryDomainRegistration {
    static func registerIfNeeded() {
        // registerExtension refuses while a generation is installing or
        // live; repeated calls are therefore naturally idempotent.
        _ = G02RuntimeComposition.shared.registerExtension(
            G02TemporaryDomainExtension())
    }
}

/// Real provider-readiness view for the two provider-backed public web
/// search tools — the SAME closed semantics `capability.tools.list` uses
/// (RB2 `WebSearchProviderState`): an enabled provider whose credential
/// resolves (or needs none). Never a fabricated ready state.
struct G02TemporaryWebSearchAvailability: TemporaryWebSearchAvailabilityProviding {
    private let facade: ModelConfigurationFacade

    init(facade: ModelConfigurationFacade) {
        self.facade = facade
    }

    func isConfigured(toolName: String) async -> Bool {
        guard TemporaryChatToolPolicy.providerBackedWebSearchToolNames
            .contains(toolName) else {
            // Non-provider-backed public web tools (web.fetch) need no
            // provider: availability is not their gate.
            return true
        }
        do {
            let reply = try await facade.getWebSearch()
            return reply.states.contains { state in
                state.configuration.enabled &&
                    (state.credentialState == .available ||
                     state.credentialState == .noCredentialRequired)
            }
        } catch {
            return false
        }
    }
}
