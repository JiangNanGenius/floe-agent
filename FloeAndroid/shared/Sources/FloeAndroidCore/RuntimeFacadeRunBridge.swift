// SPDX-License-Identifier: MPL-2.0
//
// RB-4 RunDomain — v3 binder + processor composition for the 15
/// command.submit keys of the frozen run/child/event matrix PLUS the three
/// additive goal-core controls (plan.accept / goal.confirm /
/// conversation.compact, 2026-10-21 batch — 18 keys total; private source
// candidate; NOT compiled, NOT executed, NOT registered).
//
// This is the RUN-DOMAIN-owned installation surface only. It never edits
// the reviewed RB1 bootstrap/mailbox/pump files and never touches
// `event.poll` / `effect.poll` (their binder keys stay owned by RB1; this
// lane supplies their PRODUCERS through `RunTrack` and the effect
// prepared/started appends inside the domain). `MissingBinding.runDomain`
// stays until Main installs this package after compilation/qualification;
// source alone registers nothing and advertises nothing.
//
// Synchronous binder handlers (any JNI thread) do ONLY: stable-field
/// re-read of the ALREADY-validated envelope, correlation dedupe lookup,
// bounded receipt mint, mailbox enqueue, immediate receipt JSON return.
// They never await actors, SQLite or network (reviewed RB1 discipline).
import Foundation

public enum RunDomainFacade {

    // MARK: Registry (one live domain per accepted epoch)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: (epoch: UInt64,
                                                  domain: FacadeRunDomain,
                                                  lifecycle: RunDomainDeletionLifecycle)?

    static func install(_ entry: (epoch: UInt64, domain: FacadeRunDomain,
                                  lifecycle: RunDomainDeletionLifecycle)) {
        lock.lock(); live = entry; lock.unlock()
    }

    public static func current(epoch: UInt64) -> (FacadeRunDomain,
                                                  RunDomainDeletionLifecycle)? {
        lock.lock(); defer { lock.unlock() }
        guard let live, live.epoch == epoch else { return nil }
        return (live.domain, live.lifecycle)
    }

    /// Test/integration reset. Never called by a wire path.
    internal static func clearForTesting() {
        lock.lock(); live = nil; lock.unlock()
    }

    // MARK: - Install (trusted host bootstrap glue)

    /// Registers EXACTLY the run-domain binder keys + processors (15
    /// original + the 3 additive goal-core controls, 2026-10-21) over the
    /// reviewed generation components. The host glue (Main integration)
    /// calls this after `RuntimeFacadeBridge.install(for:)` and only when
    /// every non-optional component dependency is real; unregistered
    /// optional ports stay typed-unavailable inside the domain, never a
    /// noop substitution.
    public static func install(components: RunDomainComponents,
                               registry: RuntimeDomainRegistry) {
        let domain = FacadeRunDomain(components: components)
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        install((epoch: components.context.epoch, domain: domain,
                 lifecycle: lifecycle))
        let binder = RuntimeCommandBinder.shared
        for binding in RunDomainHandlerPlan.bindings {
            binder.register(binding.handlerKey,
                            makeSubmitHandler(binding: binding,
                                              epoch: components.context.epoch))
            registry.register(handlerKey: binding.handlerKey,
                              processor: makeProcessor(binding: binding,
                                                       epoch: components.context.epoch))
        }
    }

    /// Removes only this package's keys. RB1's bootstrap keys and the two
    /// pump keys are untouched (owned elsewhere).
    public static func uninstall() {
        let binder = RuntimeCommandBinder.shared
        for binding in RunDomainHandlerPlan.bindings {
            binder.unregister(binding.handlerKey)
        }
        clearForTesting()
    }

    /// Graceful-generation retirement hook Main may bind into the shutdown
    /// path BEFORE the drain loop: it fences NEW admissions and closes the
    /// ACTUAL owned producers (real runtime cancel cascade per run, final
    /// durable writes awaited by the drain via exact-token zero). It never
    /// detaches on a timeout and never fakes quiescence: an un-settled run
    /// keeps the reviewed `failedDrainPending` ownership semantics honest.
    public static func beginGenerationRetirement(epoch: UInt64) async {
        guard let (domain, _) = current(epoch: epoch) else { return }
        await domain.beginGenerationRetirement()
    }

    // MARK: - Synchronous submit handlers

    private static func makeSubmitHandler(binding: RunDomainHandlerPlan.Binding,
                                          epoch: UInt64)
        -> RuntimeCommandBinder.Handler {
        let handlerKey = binding.handlerKey
        let command = binding.command
        return { data in
            // BridgeV3 already structurally validated this envelope; only
            // re-read stable identity fields (reviewed RB1 pattern).
            guard let envelope = parseObject(data),
                  let correlation = envelope["correlationID"] as? String,
                  !correlation.isEmpty else {
                return errorJSON(error: "invalidEnvelope",
                                 reason: "malformedAfterValidation")
            }
            guard let pumps = AndroidRuntimeBootstrap.currentPumps(),
                  pumps.epoch == epoch, pumps.storeReady else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: "runDomainNotInstalled")
            }
            if pumps.mailbox.isAdmissionFenced {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.alreadyDraining.rawValue)
            }
            // Correlation dedupe FIRST (never a second receipt mint).
            if let existing = pumps.mailbox.liveReceipt(correlationID: correlation) {
                return receiptJSON(correlation: correlation, receipt: existing)
            }
            guard let receipt = pumps.effects.register(correlationID: correlation)
            else {
                return errorJSON(error: "runtimeUnavailable",
                                 reason: RuntimeFacadeCode.receiptSaturated.rawValue)
            }
            let job = RuntimeCommandEnvelopeJob(
                correlationID: correlation,
                handlerKey: handlerKey,
                command: command,
                scope: binding.scope,
                configurationScope: binding.configurationScope,
                receipt: receipt,
                envelope: data)
            switch pumps.mailbox.submit(job) {
            case .queued:
                return receiptJSON(correlation: correlation, receipt: receipt)
            case .duplicate(let existing):
                return receiptJSON(correlation: correlation, receipt: existing)
            case .rejected(let code):
                return errorJSON(error: "runtimeUnavailable", reason: code.rawValue)
            }
        }
    }

    private static func receiptJSON(correlation: String, receipt: String) -> Data {
        // Queue receipt ONLY: correlationID + operationReceiptID. No
        // conversation/run identity, no outcome (settled rule).
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

    private static func makeProcessor(binding: RunDomainHandlerPlan.Binding,
                                      epoch: UInt64) -> RuntimeAsyncProcessor {
        let command = binding.command
        return RuntimeAsyncProcessor { job in
            // The processor reaches the pumps THROUGH the generation-owned
            // components (captured at install); the synchronous submit
            // handler already enforced the live bootstrap mailbox/pump
            // admission. No second process-global lookup here: a retired
            // epoch simply loses `current(epoch:)` and refuses.
            guard let (domain, _) = current(epoch: epoch) else {
                return RuntimeCommandResult(kind: .rejected, code: .notInstalled)
            }
            guard let envelopeObject = parseObject(job.envelope) else {
                return RuntimeCommandResult(kind: .rejected, code: .domainNotBound,
                                            detail: ["error": "invalidEnvelope",
                                                     "reason": "malformedAfterValidation"])
            }
            let envelope = RunCommandEnvelope(object: envelopeObject)
            let reply: RunDomainReply
            switch command {
            case "run.start":
                reply = await domain.start(envelope: envelope, receipt: job.receipt,
                                           correlation: job.correlationID)
            case "run.startTask":
                reply = await domain.startTask(envelope: envelope, receipt: job.receipt,
                                               correlation: job.correlationID)
            case "run.cancel":
                reply = await domain.cancel(envelope: envelope)
            case "run.retry":
                reply = await domain.retry(envelope: envelope, receipt: job.receipt)
            case "run.steer":
                reply = await domain.steer(envelope: envelope)
            case "run.queue":
                reply = await domain.queue(envelope: envelope)
            case "run.input.edit":
                reply = await domain.inputEdit(envelope: envelope)
            case "run.input.remove":
                reply = await domain.inputRemove(envelope: envelope)
            case "run.input.reorder":
                reply = await domain.inputReorder(envelope: envelope)
            case "run.approval.resolve":
                reply = await domain.resolveApproval(envelope: envelope)
            case "run.policy.update":
                reply = await domain.policyUpdate(envelope: envelope)
            case "run.skillcancel":
                reply = await domain.skillCancel(envelope: envelope)
            case "run.snapshot":
                reply = await domain.snapshot(envelope: envelope)
            case "child.list":
                reply = await domain.childList(envelope: envelope)
            case "child.entries":
                reply = await domain.childEntries(envelope: envelope)
            // goal-core code batch (2026-10-21): the three additive controls
            // routed through the SAME mailbox/typed-result discipline.
            case "plan.accept":
                reply = await domain.planAccept(envelope: envelope, receipt: job.receipt,
                                                correlation: job.correlationID)
            case "goal.confirm":
                reply = await domain.goalConfirm(envelope: envelope)
            case "conversation.compact":
                reply = await domain.conversationCompact(envelope: envelope)
            default:
                // Defense in depth: nothing else routes here.
                reply = RunDomainReply(.rejected(RunDomainError(.internalError, .internal)))
            }
            // Settlement rides the reviewed mailbox settle path; the typed
            // page stays on `reply.typedPage` for Main's binding adapter
            // (RB1 typed-carrier decision), never smuggled through strings.
            return reply.commandResult()
        }
    }
}

// MARK: - Domain retirement support

extension FacadeRunDomain {
    /// Fences new admissions and closes every facade-owned producer through
    /// the ACTUAL `ConversationRunService.cancel()` cascade. The drain loop
    /// (reviewed RB1 `waitForLifecycleDrain`) then observes the exact-token
    /// zero ONLY at real settlement; nothing here waits on a timer and
    /// nothing detaches early.
    func beginGenerationRetirement() async {
        retirementFenced = true
        cancelG04WorkspaceOperations()
        retiredRunSet.removeAll()
        retiredRuns.removeAll()
        for ownership in owners.values where ownership.phase == .handedOff
                || ownership.phase == .terminating {
            var updated = ownership
            updated.phase = .terminating
            updated.cancelRequested = true
            register(updated)
            if let service = liveService(ownership.runID) {
                await service.cancel()
            }
        }
        // goal-core batch: the in-process goal review/continuation lane is
        // real owned work — retirement FENCES new dispatch, CANCELS the
        // actual Tasks (their network calls unwind cooperatively) and the
        // reviewed drain still waits the exact lease to real handler return
        // (never a detach-on-cancel false drain). Late settle callbacks for
        // retired generations mutate nothing (reservation + epoch + durable
        // re-reads are the guards).
        cancelGoalReviewTasks()
    }
}
