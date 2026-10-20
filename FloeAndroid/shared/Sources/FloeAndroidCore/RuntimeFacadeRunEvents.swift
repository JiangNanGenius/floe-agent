// SPDX-License-Identifier: MPL-2.0
//
// RB-4 RunDomain — live/durable event projection (the run-track producer of
// the reviewed RB1 `FacadeEventPump`) and the bounded snapshot wire builder
// (private source candidate; NOT compiled, NOT executed, NOT registered).
//
// Projection correctness (contract eventPump + frameBudget; Main typed
// carrier decision):
// * The run consumes the ACTUAL `ConversationRunService.events()`
//   HarnessEvent stream — the embedded runtime/harness channel — and feeds
//   it into the reviewed `FacadeEventPump` (live ring, bufferingNewest-512
//   semantics, priority classification, epoch-fenced consumers). Harness
//   events carry NO sequence: live drops are possible and undetectable, so
//   correctness NEVER depends on the live channel; the durable per-run
//   monotonic pages (`SQLiteRunStore.events(runID:afterSequence:limit<=200)`)
//   plus the bounded snapshot are the correctness path.
// * Durable LAG is native truth: the service flushes assistant text only at
//   segment boundaries and yields some live events BEFORE the corresponding
//   completion-critical store write (toolResult :1128 before :1166,
//   approvalRequested :976 before :982). A refresh taken one beat early
//   simply shows the previous watermark; the next boundary or the terminal
//   final refresh lands the page — never fabricated as durable-present.
// * `event.poll` stays bound by RB1 (`BridgeV3.runEventPumpHandlerKey`).
//   This package owns the PRODUCERS only: window refresh + one live
//   consumer per run. The cursor numeric value always equals the real
//   native per-run event sequence. No global sequence, no pre-run receipts
//   on this channel (they ride `effect.poll`/floe.effect-cursor/3), no new
//   wire labels.
// * Priority approval/terminal saturation DETACHES the projection consumer
//   with explicit resyncRequired (pump semantics); this lane re-attaches at
//   the next epoch and NEVER cancels the underlying business run. A slow
//   or absent consumer cannot slow the run: ingest is the pump's bounded
//   synchronous ring — no synchronous JNI/SQLite/network waits on the run
//   path (durable refresh is async on the cooperative track Task).
// * Old-root/stale-epoch callbacks cannot mutate a newer generation: every
//   handler re-checks the accepted epoch and live ownership; a retired run's
//   late frames are classified and dropped, never re-registered.
//
// Snapshot honesty:
// * Real durable state + live answer/reasoning/approval/liveness/
//   providerAttempt + plan/goal/children/pendingInputs/usage/errors from
//   the ORIGINAL stores, with explicit CAS-able opaque revisions so the
//   host can drive every stateful command without guessing.
// * Oversized unsequenced live text is NOT labelled complete: the full
//   text stages through the reviewed `FacadeContentReader` (per-generation
//   handles, epoch-owned) and the frame carries a bounded scalar-safe
//   inline prefix PLUS a continuation handle with an explicit
//   `answerPartial` flag. Prefix-complete is never claimed.
// * 48 KiB normal / 64 KiB hard including JSON escaping, measured on the
//   ACTUAL encoded object (`FacadeFrameBudget.serializedBytes`); arrays
//   stop-at-budget with honest `truncated` flags and cursors; authoritative
//   facts (identity, terminal, pending approval, revisions) are dropped
//   LAST — if even the minimal authoritative frame cannot fit, the reply
//   fails typed (`frameBudgetExceeded`), never silently truncates truth.
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeSecurity

// MARK: - Track producer

/// The per-run owned projection Task. One per facade-owned run, started by
/// `FacadeRunDomain` right after the ORIGINAL service exists and the launch
/// Task is dispatched. Its lifecycle IS the run's ownership retirement:
/// real terminal + final durable refresh → domain retirement (exact-token
/// detach last). View reconstruction is not navigation; consumer teardown
/// here never touches the business run.
enum RunTrack {
    /// `bundle` is the run's IMMUTABLE operational bundle (RUN-S2 repair):
    /// the track's durable-window refresh, stream-ended reconciliation and
    /// child cross-check read ONLY the run's own stores — the ordinary
    /// singleton is never a fallback for a temporary bundle, and a
    /// temporary run's RAM store is its own projection authority.
    static func start(domain: FacadeRunDomain,
                      service: ConversationRunService,
                      runID: UUID,
                      conversationID: UUID,
                      epoch: UInt64,
                      bundle: RunPersistenceBundle,
                      components: RunDomainComponents) -> Task<Void, Never> {
        Task { [weak domain] in
            guard let domain else { return }
            await domain.beginTrack(runID: runID)
            for await event in service.events() {
                // Cancellation of the PROJECTION consumer (explicit detach,
                // epoch fence, domain retirement) must not cancel the run:
                // the loop keeps consuming until the channel finishes.
                let terminalSettled = await domain.handleTracked(event: event,
                                                                 runID: runID)
                if terminalSettled { return }
                if Task.isCancelled {
                    // The domain asked the track to stop (retire/delete
                    // path). The run itself is owned by its service; this
                    // Task closing does NOT claim the run ended.
                    await domain.trackStoppedWithoutTerminal(runID: runID)
                    return
                }
            }
            await domain.trackStreamEnded(runID: runID, bundle: bundle)
        }
    }
}

// MARK: - Domain-side track handlers (actor state only)

extension FacadeRunDomain {
    /// Attach the one live consumer + the first bounded durable window.
    func beginTrack(runID: UUID) async {
        guard var ownership = owners[runID] else { return }
        if ownership.consumerToken == nil {
            ownership.consumerToken = components.events.attachConsumer(runID: runID)
            register(ownership)
        }
        await refreshWindow(runID: runID, bundle: ownership.bundle)
    }

    /// Feed ONE real HarnessEvent into the projection and update owned
    /// accounting. Returns true only after a REAL terminal settled the run
    /// ownership (the track loop then exits). The run's OWN bundle drives
    /// every store touch (RUN-S2 repair).
    func handleTracked(event: HarnessEvent, runID: UUID) async -> Bool {
        guard let ownership = owners[runID], ownership.epoch == epoch else {
            return true // foreign/retired producer: drop, mutate nothing
        }
        let bundle = ownership.bundle
        if let token = ownership.consumerToken {
            let outcome = components.events.ingestLive(event, token: token)
            switch outcome {
            case .detached, .fencedByEpoch:
                // Priority saturation or an epoch fence detaches THIS
                // projection only. Re-attach at the next epoch so newer
                // frames flow; the business run is never cancelled here.
                if ownership.phase != .retired,
                   let current = owners[runID], current.consumerToken == token {
                    var replacement = current
                    replacement.consumerToken = components.events.attachConsumer(runID: runID)
                    register(replacement)
                }
            default:
                break
            }
        }
        switch event {
        case .toolLifecycle(let lifecycle):
            switch lifecycle {
            case .requested(let call), .started(let call):
                attachToolInternal(runID: runID, callID: call.id)
            case .finished(let result):
                detachToolInternal(runID: runID, callID: result.callID)
            }
            await refreshWindow(runID: runID, bundle: bundle)
        case .approvalRequested(let request):
            // Boundary: the durable approval event lands right after the
            // yield inside the service; take the window anyway and let the
            // next beat complete it (durable lag is native truth).
            _ = request
            await refreshWindow(runID: runID, bundle: bundle)
        case .approvalResolved:
            await refreshWindow(runID: runID, bundle: bundle)
        case .approvalReviewChanged:
            // Live review-status frame (current main): the durable approval
            // row moves at the same boundary, so take the window here too.
            await refreshWindow(runID: runID, bundle: bundle)
        case .childRunChanged(let snapshot):
            await observeChild(runID: runID, snapshot: snapshot, bundle: bundle)
            await refreshWindow(runID: runID, bundle: bundle)
        case .userInputConsumed(let receipt):
            _ = receipt
            await refreshWindow(runID: runID, bundle: bundle)
        case .planChanged, .goalChanged, .contextCompacted:
            await refreshWindow(runID: runID, bundle: bundle)
        case .stateChanged(let state):
            markStateObserved(runID: runID, harnessState: state)
        case .answerDelta, .reasoningDelta, .livenessChanged,
             .providerAttemptChanged, .usageChanged:
            break   // droppable frames: the pump already classified
        case .terminal(let terminal):
            await refreshWindow(runID: runID, bundle: bundle)
            let succeeded: Bool
            if case .completed = terminal { succeeded = true } else { succeeded = false }
            await retire(runID: runID, terminalSucceeded: succeeded, feedTerminal: true)
            RunTaskBox.clear(runID: runID)
            return true
        }
        return false
    }

    /// Track Task cancelled WITHOUT observing the engine terminal (the run
    /// may still be live under its service). Ownership RETAINS its exact
    /// tokens (never detach here), so a later delete/shutdown still waits
    /// for the real producer. Honesty over convenience.
    func trackStoppedWithoutTerminal(runID: UUID) async {
        guard let ownership = owners[runID] else { return }
        // Keep every owned token; mark the projection detached only.
        if let token = ownership.consumerToken {
            components.events.detachConsumer(token)
            var updated = ownership
            updated.consumerToken = nil
            register(updated)
        }
    }

    /// Channel ended without an observed terminal frame (service finish()
    /// is only reached through handleTransition's terminal path; anything
    /// else means the durable state already moved past the live frames).
    /// The run's OWN bundle answers the reconciliation read.
    func trackStreamEnded(runID: UUID, bundle: RunPersistenceBundle) async {
        guard let ownership = owners[runID] else { return }
        let record = try? await bundle.runs.run(id: runID)
        if let record, !Self.activeRunStates.contains(record.state) {
            await retire(runID: runID, terminalSucceeded: record.state == "completed",
                         feedTerminal: record.state == "completed")
            RunTaskBox.clear(runID: runID)
            return
        }
        // Durable still says the run is live: ownership stays conservative
        // (tokens attached). A later explicit cancel or an in-process
        // terminal event settles it; shutdown drain blocks honestly until
        // then. Never fabricate a terminal.
        if let token = ownership.consumerToken {
            components.events.detachConsumer(token)
            var updated = ownership
            updated.consumerToken = nil
            register(updated)
        }
    }

    /// Reads one real bounded append-only page through the RUN'S OWN store
    /// and materializes it into the pump window. Ordinary → SQLite; a
    /// temporary run (RB5) → the SAME `EphemeralRunStore` the service
    /// appends to, whose per-run sequences are monotonic exactly like the
    /// SQLite counter. The durable singleton is never a fallback, and the
    /// temporary App contract (`event.poll` frames + terminal) stops being
    /// permanently `notAttached`.
    private func refreshWindow(runID: UUID, bundle: RunPersistenceBundle) async {
        await components.events.refreshDurableWindow(runID: runID,
                                                     store: bundle.runs)
    }

    private func markStateObserved(runID: UUID, harnessState: HarnessState) {
        lastObservedState[runID] = harnessState.rawValue
    }

    private func attachToolInternal(runID: UUID, callID: String) {
        attachTool(runID: runID, callID: callID)
    }

    private func detachToolInternal(runID: UUID, callID: String) {
        detachTool(runID: runID, callID: callID)
    }

    /// Child graph transitions observed from the ACTUAL runtime
    /// (`ChildRunSnapshot` frames written by the original delegate path plus
    /// the durable store): non-terminal attaches `.childRun` exact tokens,
    /// terminal detaches them. No UI-emulated children exist here. The
    /// cross-check reads the run's OWN bundle (temporary sessions keep
    /// children in-memory by the original DelegateTool semantics).
    private func observeChild(runID: UUID, snapshot: ChildRunSnapshot,
                              bundle: RunPersistenceBundle) async {
        switch snapshot.state {
        case .completed, .paused, .interrupted, .cancelled, .failed:
            detachChild(runID: runID, childRunID: snapshot.id)
        default:
            attachChild(runID: runID, childRunID: snapshot.id)
        }
        // Cross-check the durable graph for already-settled children whose
        // live frame arrived out of order (bounded, cheap for ≤4 children).
        if let store = bundle.childRuns,
           let current = owners[runID] {
            for childID in current.pendingChildRunIDs {
                let child = try? await store.child(id: childID)
                if let child, child.state.isTerminal {
                    detachChild(runID: runID, childRunID: childID)
                }
            }
        }
    }
}

// MARK: - Snapshot wire builder (bounded, truthful)

enum RunSnapshotWireBuilder {
    /// Compose one run snapshot page from the ORIGINAL stores plus the
    /// live service when facade-owned. The returned page is measured on
    /// the COMPLETE encoded object (identity/wrapper included).
    static func build(domain: FacadeRunDomain,
                      components: RunDomainComponents,
                      query: SnapshotQuery,
                      ownership: RunOwnership?,
                      liveService: ConversationRunService?,
                      readBundle: RunPersistenceBundle? = nil) async -> RunDomainReply {
        // The RUN'S OWN stores answer every run-scoped read. An ordinary
        // run's bundle IS the durable cluster; a temporary run's bundle is
        // the session's ORIGINAL Ephemeral* set. The durable singleton is
        // never a fallback for a supplied temporary bundle.
        let stores = readBundle ?? ownership?.bundle ?? components.durable
        let record: RunRecord?
        do {
            record = try await stores.runs.run(id: query.runID)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard let record, record.conversationID == query.conversationID else {
            return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
        }
        var snapshot: ConversationRunService.Snapshot?
        if let liveService { snapshot = await liveService.snapshot() }

        var fields: [String: SettingsDomainV1.JSONValue] = [:]
        fields["schema"] = .string(BridgeV3.commandSchema)
        fields["conversationID"] = .string(record.conversationID.uuidString)
        fields["runID"] = .string(record.id.uuidString)
        fields["durableState"] = .string(record.state)
        fields["revision"] = .object([
            "resourceID": .string(RunWireRevision.runResourceID(record.id)),
            "version": .string(RunWireRevision.runVersion(state: record.state)),
        ])
        let isTerminal = !FacadeRunDomain.activeRunStates.contains(record.state)
        fields["isTerminal"] = .boolean(isTerminal)
        fields["conversationMode"] = record.conversationMode.map { .string($0) } ?? .null
        fields["goal"] = .string(bounded(record.goal, maxBytes: 2_048))
        fields["liveOwner"] = .boolean(liveService != nil)
        if let snapshot {
            fields["stateName"] = .string(snapshot.stateName)
            fields["hasProviderActivity"] = .boolean(snapshot.hasProviderActivity)
            fields["liveness"] = .object([
                "phase": .string(snapshot.liveness.phase.rawValue),
                "message": .string(bounded(snapshot.liveness.message, maxBytes: 512)),
                "attempt": .integer(Int64(snapshot.liveness.attempt)),
                "retryCount": .integer(Int64(snapshot.liveness.retryCount)),
                "isRecoverable": .boolean(snapshot.liveness.isRecoverable),
            ])
            fields["providerAttempt"] = snapshot.providerAttempt.map { attemptJSON($0) } ?? .null
            if let waiting = snapshot.pendingApproval {
                fields["pendingApproval"] = .object([
                    "callID": .string(waiting.toolCall.id),
                    "tool": .string(waiting.toolCall.toolName),
                    "reason": .string(bounded(waiting.reason, maxBytes: 1_024)),
                    "requestedAt": .string(RunWireDate.encode(waiting.requestedAt)),
                ])
                fields["approvalRevision"] = .object([
                    "resourceID": .string(RunWireRevision.approvalResourceID(
                        callID: waiting.toolCall.id)),
                    "version": .string(RunWireRevision.approvalVersion(
                        requestedAt: waiting.requestedAt)),
                ])
            }
            if let reason = snapshot.checkpointReason {
                fields["checkpointReason"] = .string(bounded(reason, maxBytes: 512))
            }
        } else {
            // Honest absence: without a live owner the transient approval
            // state is NOT knowable; the durable thread and child graph are
            // still authoritative below.
            fields["pendingApproval"] = .null
            fields["approvalRevision"] = .null
        }

        // Watermark from the run's OWN append-only sequence (durable SQLite
        // or the temporary session's RAM store). The wire label is frozen;
        // the value is the real per-run sequence either way.
        let recentWatermark = try? await stores.runs.recentEvents(
            runID: record.id, limit: 1)
        let watermark = recentWatermark?.last?.sequence ?? 0
        fields["durableWatermark"] = .integer(Int64(watermark))

        // Usage (original records, bounded to last 16 + run totals).
        var usageFields: [SettingsDomainV1.JSONValue] = []
        var totals = (input: 0, output: 0)
        let usageRecords = (try? await stores.runs.usage(runID: record.id)) ?? []
        if !usageRecords.isEmpty {
            for usage in usageRecords.suffix(16) {
                totals.input += usage.inputTokens
                totals.output += usage.outputTokens
                usageFields.append(.object([
                    "inputTokens": .integer(Int64(usage.inputTokens)),
                    "outputTokens": .integer(Int64(usage.outputTokens)),
                    "estimated": .boolean(usage.isEstimated),
                    "cacheReadTokens": usage.cacheReadTokens.map { .integer(Int64($0)) } ?? .null,
                    "reasoningTokens": usage.reasoningTokens.map { .integer(Int64($0)) } ?? .null,
                    "totalDurationMs": usage.totalDurationMs.map { .integer(Int64($0)) } ?? .null,
                ]))
            }
        }
        fields["usage"] = .object([
            "recent": .array(usageFields),
            "totalInput": .integer(Int64(totals.input)),
            "totalOutput": .integer(Int64(totals.output)),
            "truncated": .boolean(usageRecords.count > usageFields.count),
        ])

        // Errors from the run's OWN store (redacted by the original
        // service path exactly as before).
        let errors = (try? await stores.runs.errors(runID: record.id)) ?? []
        fields["errors"] = .array(errors.suffix(8).map { error in
            .object([
                "kind": .string(error.kind),
                "recoverable": .boolean(error.recoverable),
                "httpStatus": error.httpStatus.map { .integer(Int64($0)) } ?? .null,
                "messageDigest": .string(String(error.message.prefix(16))),
            ])
        })
        fields["errorsTruncated"] = .boolean(errors.count > 8)

        // Plan/goal from the bundle's own intelligence store (nil for a
        // temporary session: goal mode was refused at admission).
        if let intelligence = stores.intelligence {
            let plan = try? await intelligence.latestPlan(conversationID: record.conversationID)
            fields["plan"] = plan.map { planJSON($0) } ?? .null
            let goals = (try? await intelligence.goals(conversationID: record.conversationID)) ?? []
            fields["goals"] = .array(goals.suffix(4).map { goal in
                .object([
                    "goalID": .string(goal.id.uuidString),
                    "status": .string(goal.status.rawValue),
                    "revision": .integer(Int64(goal.revision ?? 1)),
                ])
            })
            fields["goalsTruncated"] = .boolean(goals.count > 4)
        } else {
            fields["plan"] = .null
            fields["goals"] = .null
        }

        // Children from the bundle's own child graph (nil for temporary:
        // the original DelegateTool keeps children in-memory; the snapshot
        // honestly reports the empty durable graph).
        if let store = stores.childRuns,
           let children = try? await store.children(parentRunID: record.id) {
            fields["children"] = .array(children.prefix(RunDomainLimits.maximumChildItems).map {
                .object(FacadeRunDomain.childJSON($0))
            })
            fields["childrenTruncated"] = .boolean(children.count > RunDomainLimits.maximumChildItems)
        } else {
            fields["children"] = .array([])
            fields["childrenTruncated"] = .boolean(false)
        }

        // Pending inputs from the bundle's own queue (RAM for temporary).
        var inputItems: [SettingsDomainV1.JSONValue] = []
        var queuedIDs: [UUID] = []
        if let pending = try? await stores.runningInputs.pending(
            conversationID: record.conversationID) {
            for item in pending.prefix(RunDomainLimits.maximumPendingInputItems) {
                if item.status == .queued { queuedIDs.append(item.id) }
                inputItems.append(.object([
                    "inputID": .string(item.id.uuidString),
                    "position": .integer(Int64(item.position)),
                    "status": .string(item.status.rawValue),
                    "mode": .string(item.mode.rawValue),
                    "targetRunID": item.targetRunID.map { .string($0.uuidString) } ?? .null,
                    "consumedRunID": item.consumedRunID.map { .string($0.uuidString) } ?? .null,
                    "updatedAt": .string(RunWireDate.encode(item.updatedAt)),
                    "inputVersion": .string(RunWireRevision.inputVersion(updatedAt: item.updatedAt)),
                    "preview": .string(bounded(item.content, maxBytes: 512)),
                ]))
            }
            fields["pendingInputs"] = .array(inputItems)
            fields["pendingInputsTruncated"] = .boolean(pending.count > inputItems.count)
        } else {
            fields["pendingInputs"] = .array([])
            fields["pendingInputsTruncated"] = .boolean(false)
        }
        fields["queueRevision"] = .object([
            "resourceID": .string(RunWireRevision.pendingQueueResourceID(record.conversationID)),
            "version": .string(RunWireRevision.queueVersion(orderedIDs: queuedIDs)),
        ])

        // Task-policy revision for run.policy.update CAS. A temporary run
        // has NO durable task_policies row (the run lane synthesizes the
        // ORIGINAL default in RAM); report the honest null instead of
        // reading the durable workspace store through a RAM-only id.
        if stores.identity == .temporary {
            fields["policyRevision"] = .null
        } else if let policy = try? await components.workspaceStore.taskPolicy(
            conversationID: record.conversationID) {
            fields["policyRevision"] = .object([
                "resourceID": .string(RunWireRevision.taskPolicyResourceID(record.conversationID)),
                "version": .string(RunWireRevision.taskPolicyVersion(updatedAt: policy.updatedAt)),
            ])
        } else {
            fields["policyRevision"] = .null
        }

        // Live answer/reasoning: inline the bounded prefix, stage the FULL
        // text under an owned continuation handle when it exceeds budget.
        // NEVER label a prefix complete.
        var answerInline: String?
        var reasoningInline: String?
        var answerHandle: String?
        var reasoningHandle: String?
        if let snapshot {
            let answer = snapshot.streamedText
            let reasoning = snapshot.reasoningText
            if answer.utf8.count > RunDomainLimits.snapshotInlineBudgetBytes {
                guard let handle = await domain.stageSnapshotText(
                    Data(answer.utf8), runID: record.id,
                    conversationID: record.conversationID) else {
                    // Oversized live answer cannot be staged (reader
                    // saturated/refused) and cannot fit the frame inline:
                    // explicit typed refusal — NEVER a null-text page that
                    // still claims completion.
                    return RunDomainReply(.rejected(
                        RunDomainError(.payloadTooLarge, .payloadTooLarge)))
                }
                answerHandle = handle
                // Scalar-safe bounded prefix via the reviewed reader.
                switch components.content.read(handle: handle, offset: 0,
                                               maxBytes: RunDomainLimits
                                                   .snapshotInlineBudgetBytes / 2) {
                case .slice(let bytes, _, _):
                    answerInline = String(decoding: bytes, as: UTF8.self)
                default:
                    answerInline = nil
                }
            } else {
                answerInline = answer
            }
            if reasoning.utf8.count > RunDomainLimits.snapshotInlineBudgetBytes / 2 {
                guard let handle = await domain.stageSnapshotText(
                    Data(reasoning.utf8), runID: record.id,
                    conversationID: record.conversationID) else {
                    // Same truth rule as the answer: no silent loss.
                    return RunDomainReply(.rejected(
                        RunDomainError(.payloadTooLarge, .payloadTooLarge)))
                }
                reasoningHandle = handle
                switch components.content.read(handle: handle, offset: 0,
                                               maxBytes: RunDomainLimits
                                                   .snapshotInlineBudgetBytes / 4) {
                case .slice(let bytes, _, _):
                    reasoningInline = String(decoding: bytes, as: UTF8.self)
                default:
                    reasoningInline = nil
                }
            } else {
                reasoningInline = reasoning
            }
            fields["answerText"] = answerInline.map { .string($0) } ?? .null
            // An inline non-empty answer is COMPLETE only at the real
            // terminal; mid-stream content is partial truth (the durable
            // events remain the correctness path) and must never report
            // completion merely because no continuation handle exists.
            fields["answerComplete"] = .boolean(answerHandle == nil
                                                && !answer.isEmpty && isTerminal)
            fields["answerContinuationHandle"] = answerHandle.map { .string($0) } ?? .null
            fields["reasoningText"] = reasoningInline.map { .string($0) } ?? .null
            fields["reasoningComplete"] = .boolean(reasoningHandle == nil
                                                   && !reasoning.isEmpty && isTerminal)
            fields["reasoningContinuationHandle"] = reasoningHandle.map { .string($0) } ?? .null
        } else {
            fields["answerText"] = .null
            // Without the live owner the full text is UNKNOWN (isTerminal
            // already conveys termination): Complete must never claim
            // content completeness for absent/unretrievable text. The
            // bounded durable cursor walk remains the correctness path.
            fields["answerComplete"] = .boolean(false)
            fields["answerContinuationHandle"] = .null
            fields["reasoningText"] = .null
            fields["reasoningComplete"] = .boolean(false)
            fields["reasoningContinuationHandle"] = .null
        }

        // Fit the frame: drop droppable arrays first, then inline text,
        // always re-measuring the COMPLETE encoded object.
        var page: [String: SettingsDomainV1.JSONValue] = fields
        let fit = await domain.fitSnapshotPage(&page, runID: record.id,
                                               conversationID: record.conversationID)
        guard fit else {
            // Authoritative minimum frame cannot fit: typed failure beats
            // silent truncation. (The durable pages + cursor walk remain.)
            return RunDomainReply(.rejected(RunDomainError(.payloadTooLarge, .payloadTooLarge)))
        }
        let bytes = measured(page)
        return RunDomainReply(.completedPage(
            page: RunTypedPage(object: .object(page), pageBytes: bytes),
            nextCursor: nil))
    }

    /// Bounded child list page.
    static func childList(domain: FacadeRunDomain,
                          components: RunDomainComponents,
                          query: ChildListQuery) async -> RunDomainReply {
        guard let store = components.durable.childRuns else {
            return RunDomainReply(.rejected(RunDomainError(.capabilityNotUsable, .internal)))
        }
        let children: [ChildRunRecord]
        do {
            children = try await store.children(parentRunID: query.parentRunID)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        for child in children where child.conversationID != query.conversationID {
            // Foreign graph rows are invisible here, exactly like a missing
            // parent: never a cross-conversation leak.
            return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
        }
        var items: [SettingsDomainV1.JSONValue] = []
        for child in children.prefix(RunDomainLimits.maximumChildItems) {
            items.append(.object(FacadeRunDomain.childJSON(child)))
        }
        var page: [String: SettingsDomainV1.JSONValue] = [
            "schema": .string(BridgeV3.commandSchema),
            "parentRunID": .string(query.parentRunID.uuidString),
            "children": .array(items),
            // Same canonical truncation flag as the snapshot page.
            "childrenTruncated": .boolean(children.count > items.count),
        ]
        var guardCount = 0
        while measured(page) > RunDomainLimits.pageBudgetBytes, items.count > 1,
              guardCount < RunDomainLimits.maximumChildItems {
            guardCount += 1
            items.removeLast()
            page["children"] = .array(items)
            page["childrenTruncated"] = .boolean(true)
        }
        let bytes = measured(page)
        guard bytes <= RunDomainLimits.pageBudgetBytes else {
            return RunDomainReply(.rejected(RunDomainError(.payloadTooLarge, .payloadTooLarge)))
        }
        return RunDomainReply(.completedPage(
            page: RunTypedPage(object: .object(page), pageBytes: bytes),
            nextCursor: nil))
    }

    /// Bounded child transcript page (durable ChildRunEntryPage cursor).
    static func childEntries(domain: FacadeRunDomain,
                             components: RunDomainComponents,
                             query: ChildEntriesQuery) async -> RunDomainReply {
        guard let store = components.durable.childRuns else {
            return RunDomainReply(.rejected(RunDomainError(.capabilityNotUsable, .internal)))
        }
        let child: ChildRunRecord?
        do { child = try await store.child(id: query.childRunID) }
        catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        guard let child, child.conversationID == query.conversationID else {
            return RunDomainReply(.rejected(RunDomainError(.notFound, .childMissing)))
        }
        let fetched: ChildRunEntryPage
        do {
            fetched = try await store.entries(childRunID: query.childRunID,
                                               afterSequence: query.afterSequence,
                                               limit: query.limit)
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable,
                                                           .storeReadFailed)))
        }
        var items: [SettingsDomainV1.JSONValue] = []
        var lastSequence: Int?
        for entry in fetched.entries {
            let candidate: SettingsDomainV1.JSONValue = .object([
                "sequence": .integer(Int64(entry.sequence)),
                "kind": .string(entry.kind.rawValue),
                "payload": .string(entry.payloadJSON),
                "createdAt": .string(RunWireDate.encode(entry.createdAt)),
            ])
            items.append(candidate)
            lastSequence = entry.sequence
            if measured(["e": .array(items)]) > RunDomainLimits.pageBudgetBytes - 4_096 {
                items.removeLast()
                break
            }
        }
        let hasMore = items.count < fetched.entries.count || fetched.nextSequence != nil
        var page: [String: SettingsDomainV1.JSONValue] = [
            "schema": .string(BridgeV3.commandSchema),
            "childRunID": .string(query.childRunID.uuidString),
            "entries": .array(items),
            "hasMore": .boolean(hasMore),
            "nextSequence": lastSequence.map { .integer(Int64($0)) } ?? .null,
        ]
        if items.isEmpty, hasMore,
           measured(page) > RunDomainLimits.pageBudgetBytes {
            // Zero-progress guard (typed carrier decision 2): a single
            // entry larger than the page budget is typed recoverable, never
            // an endless hasMore cursor.
            return RunDomainReply(.rejected(RunDomainError(.payloadTooLarge, .payloadTooLarge)))
        }
        let bytes = measured(page)
        guard bytes <= RunDomainLimits.pageBudgetBytes else {
            return RunDomainReply(.rejected(RunDomainError(.payloadTooLarge, .payloadTooLarge)))
        }
        return RunDomainReply(.completedPage(
            page: RunTypedPage(object: .object(page), pageBytes: bytes),
            nextCursor: lastSequence.map { String($0) }))
    }

    // MARK: Measurement / shrink helpers

    private static func measured(_ page: [String: SettingsDomainV1.JSONValue]) -> Int {
        FacadeFrameBudget.serializedBytes(FacadeRunDomain.unwrap(.object(page)))
    }

    /// Drop the cheapest NON-authoritative arrays first (tool/usage/error
    /// tails, goal/plan summaries are kept while possible, text inline last).
    static func shrinkDroppable(
        _ page: inout [String: SettingsDomainV1.JSONValue]) -> Bool {
        if case .object(let usage)? = page["usage"],
           case .array(let records)? = usage["recent"], !records.isEmpty {
            var trimmed = usage
            var items = records
            items.removeFirst(max(1, items.count / 2))
            trimmed["recent"] = .array(items)
            trimmed["truncated"] = .boolean(true)
            page["usage"] = .object(trimmed)
            return true
        }
        if case .array(let errors)? = page["errors"], !errors.isEmpty {
            page["errors"] = .array([])
            page["errorsTruncated"] = .boolean(true)
            return true
        }
        if case .array(let inputs)? = page["pendingInputs"], !inputs.isEmpty {
            var items = inputs
            items.removeLast(max(1, items.count / 2))
            page["pendingInputs"] = .array(items)
            page["pendingInputsTruncated"] = .boolean(true)
            return true
        }
        if case .array(let children)? = page["children"], !children.isEmpty {
            var items = children
            items.removeLast(max(1, items.count / 2))
            page["children"] = .array(items)
            page["childrenTruncated"] = .boolean(true)
            return true
        }
        if case .array(let goals)? = page["goals"], !goals.isEmpty {
            page["goals"] = .array([])
            page["goalsTruncated"] = .boolean(true)
            return true
        }
        return false
    }

    private static func bounded(_ text: String, maxBytes: Int) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        var length = maxBytes
        while length > 0, (bytes[length - 1] & 0xC0) == 0x80 { length -= 1 }
        return String(decoding: bytes.prefix(length), as: UTF8.self) + "…"
    }

    private static func attemptJSON(_ attempt: ProviderAttemptSnapshot)
        -> SettingsDomainV1.JSONValue {
        .object([
            "attempt": .integer(Int64(attempt.attempt)),
            "maxAttempts": .integer(Int64(attempt.maxAttempts)),
            "status": .string(attempt.status.rawValue),
            "reason": attempt.reason.map { .string(bounded($0, maxBytes: 512)) } ?? .null,
            "errorKind": attempt.errorKind.map { .string($0) } ?? .null,
            "httpStatus": attempt.httpStatus.map { .integer(Int64($0)) } ?? .null,
        ])
    }

    private static func planJSON(_ plan: PlanDraft) -> SettingsDomainV1.JSONValue {
        .object([
            "planID": .string(plan.id.uuidString),
            "revision": .integer(Int64(plan.revision)),
            "status": .string(plan.status.rawValue),
        ])
    }
}

// MARK: - Domain handle bookkeeping

extension FacadeRunDomain {
    /// Stage one oversized snapshot text blob through the reviewed
    /// per-generation reader and index the handle to its REAL owners. The
    /// per-generation reader makes handle expiry honest (a new generation
    /// answers typed notFound; handles never resurrect).
    func stageSnapshotText(_ data: Data, runID: UUID, conversationID: UUID) -> String? {
        guard !data.isEmpty else { return nil }
        guard case .staged(let handle) = components.content.stage(data) else {
            return nil   // saturation: honest inline-only fallback below
        }
        contentHandles[handle] = (runID: runID, conversationID: conversationID, epoch: epoch)
        contentHandleOrder.append(handle)
        while contentHandleOrder.count > 64,
              let evictable = contentHandleOrder.first(where: { $0 != handle }) {
            components.content.release(handle: evictable)
            contentHandles.removeValue(forKey: evictable)
            contentHandleOrder.removeAll { $0 == evictable }
        }
        return handle
    }

    /// Actor-side frame fitting: shrink droppable arrays, then move inline
    /// text into owned continuation handles, re-measuring the COMPLETE
    /// encoded object each step. Returns false only when even the minimal
    /// authoritative frame cannot fit (typed failure, never silent truth
    /// loss).
    func fitSnapshotPage(_ page: inout [String: SettingsDomainV1.JSONValue],
                         runID: UUID,
                         conversationID: UUID) async -> Bool {
        var guardCount = 0
        while measured(page) > RunDomainLimits.pageBudgetBytes, guardCount < 24 {
            guardCount += 1
            if RunSnapshotWireBuilder.shrinkDroppable(&page) { continue }
            if case .string(let text)? = page["answerText"], !text.isEmpty {
                guard page["answerContinuationHandle"] == nil
                        || page["answerContinuationHandle"] == .null,
                      let handle = stageSnapshotText(Data(text.utf8), runID: runID,
                                                     conversationID: conversationID) else {
                    // Staging saturated/refused with text too big for the
                    // frame: NEVER null the only carrier and report success —
                    // the page fails typed instead.
                    return false
                }
                page["answerContinuationHandle"] = .string(handle)
                page["answerText"] = .null
                page["answerComplete"] = .boolean(false)
                continue
            }
            if case .string(let text)? = page["reasoningText"], !text.isEmpty {
                guard page["reasoningContinuationHandle"] == nil
                        || page["reasoningContinuationHandle"] == .null,
                      let handle = stageSnapshotText(Data(text.utf8), runID: runID,
                                                     conversationID: conversationID) else {
                    return false
                }
                page["reasoningContinuationHandle"] = .string(handle)
                page["reasoningText"] = .null
                page["reasoningComplete"] = .boolean(false)
                continue
            }
            break
        }
        return measured(page) <= RunDomainLimits.pageBudgetBytes
    }
}

private func measured(_ page: [String: SettingsDomainV1.JSONValue]) -> Int {
    FacadeFrameBudget.serializedBytes(FacadeRunDomain.unwrap(.object(page)))
}
