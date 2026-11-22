// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — parked-run continuation + explicit Stop over the ORIGINAL run
// closure.
//
// The durable park truth is the run's OWN terminal status event
// (`state=checkpointed`, reason `awaiting.finite.job[:ids]`) plus the
// `run_dependencies` rows — NOT the recovery checkpoint's state: the runtime
// downgrades `streamingModel` to `preparing` when it writes the checkpoint,
// so a dependency park always leaves a replayable `preparing` checkpoint.
//
// Resume reuses the ORIGINAL ``ConversationRunService.resumePrepared(from:
// resumption:)`` seam (its documented purpose is exactly "a dependency
// completion (background job result)"): the parked turn is restored without
// replaying a provider/tool side effect and exactly ONE trusted lifecycle
// message is appended at the resumed boundary. That message is persisted as a
// `system` row (never a fabricated human user turn) with a deterministic id,
// so a retried continuation cannot duplicate it.
//
// Explicit Stop is a CAS on the ORIGINAL run row (re-proven `checkpointed`)
// followed by a truthful "stopped by you" checkpoint, a durable `cancelled`
// resolution of every still-pending dependency edge and a cooperative
// cancellation request for exactly this run's jobs. Android's terminal run
// vocabulary has no `cancelled` state: the stopped row stays `checkpointed`
// with the canonical stop reason, which is the durable fence that refuses
// every later automatic callback. The jobs stay nonterminal until their
// processors settle.

import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity

extension FacadeRunDomain {
    // MARK: - Durable park truth

    /// Latest durable `checkpointed` status reason for this run. This is the
    /// only persisted place the park cause lives (`writeCheckpoint` downgrades
    /// the recovery boundary to `preparing`), so every continuation decision
    /// that is not based on a live service snapshot reads it from here.
    func durableCheckpointReason(runID: UUID) async -> String? {
        await durableParkMarker(runID: runID)?.reason
    }

    /// The EXACT park identity: latest durable `checkpointed` status row plus
    /// its event sequence. A resume admission captures this BEFORE any
    /// preparation and re-proves the same marker after its committed CAS, so
    /// a Stop that rewrote the row (a worker's in-flight resume) cannot be
    /// overwritten by an older resume decision.
    func durableParkMarker(runID: UUID) async -> RunDependencyParkMarker? {
        var after = 0
        var latest: RunDependencyParkMarker?
        while true {
            let page: [RunEventRecord]
            do {
                page = try await durable.runs.events(
                    runID: runID, afterSequence: after, limit: 200)
            } catch {
                return nil
            }
            if page.isEmpty { break }
            for event in page where event.kind == .status {
                guard let data = event.payloadJSON.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { continue }
                guard (object["state"] as? String) == "checkpointed",
                      let reason = object["reason"] as? String,
                      !reason.isEmpty else { continue }
                latest = RunDependencyParkMarker(reason: reason,
                                                 sequence: event.sequence)
            }
            after = page.last?.sequence ?? after
            if page.count < 200 { break }
        }
        return latest
    }

    /// Bounded durable status rows strictly AFTER the park marker, in the
    /// exact shape the resume fence consumes. nil means the store could not
    /// answer (never an empty success).
    func resumeFenceEvents(runID: UUID, afterSequence: Int) async
        -> [(sequence: Int, kind: RunEventRecord.Kind, payload: String)]? {
        do {
            let page = try await durable.runs.events(
                runID: runID, afterSequence: afterSequence, limit: 32)
            return page.map {
                (sequence: $0.sequence, kind: $0.kind,
                 payload: $0.payloadJSON)
            }
        } catch {
            return nil
        }
    }

    /// True when THIS conversation already owns another live launch/run.
    /// An old parked run must never be resumed over a newer active run: that
    /// would invalidate the user's current turn and read the newer run's
    /// messages as this run's history. `.terminating` still owns a live
    /// service, so it counts as occupied until it really retires.
    func hasOtherLiveConversationRun(conversationID: UUID,
                                     excluding runID: UUID) -> Bool {
        owners.values.contains { ownership in
            ownership.conversationID == conversationID
                && ownership.runID != runID
                && (ownership.phase == .admitting
                    || ownership.phase == .prepared
                    || ownership.phase == .handedOff
                    || ownership.phase == .terminating)
        }
    }

    /// True only for a durable checkpointed row whose latest park reason is
    /// the stable dependency marker. Live owners and completed/failed rows
    /// are never "awaiting".
    func isAwaitingDependency(runID: UUID) async -> Bool {
        guard let record = try? await durable.runs.run(id: runID),
              record.state == "checkpointed" else { return false }
        guard let marker = await durableParkMarker(runID: runID) else {
            return false
        }
        return marker.isAwaitingDependency
    }

    /// Read this run's durable edges with the exact identities named by its
    /// own park reason. Returns nil when the shape is malformed or the store
    /// cannot answer.
    func dependencyObservations(runID: UUID, reason: String) async
        -> (shape: RunDependencyResumeGate.ReasonShape,
            observations: [RunDependencyObservation]?) {
        let shape = RunDependencyResumeGate.shape(of: reason)
        guard let reader = components.runDependencyEdges else {
            return (shape, nil)
        }
        let namedIDs: [UUID]
        if case .named(let ids) = shape { namedIDs = ids } else { namedIDs = [] }
        let observations = await reader.edges(runID: runID, jobIDs: namedIDs)
        return (shape, observations)
    }

    // MARK: - Execution-target eligibility (Linux preparation/upgrade recheck)

    /// Eligibility of a parked run's PINNED execution target for an
    /// automatic continuation, decided against the task's CURRENT target.
    enum ResumeExecutionTargetVerdict: Sendable, Equatable {
        /// No pin exists (a park that predates pinning) or the pin matches
        /// the live target identity AND the live root generation.
        case eligible
        /// The pinned environment identity, target revision or root
        /// generation no longer matches the live target. The automatic
        /// continuation surfaces the change and NEVER adopts a different
        /// environment by itself: unlike the iOS live-binding path there is
        /// no committed retained-rebuild receipt for a parked run, so the run
        /// stays parked as the visible recoverable wait until an explicit
        /// user Continue decides the new environment.
        case changed
        /// The store could not prove the target state. Never treated as
        /// eligible by an automatic callback.
        case unverifiable
    }

    /// Compare the run's durable pin with the task's current target through
    /// the SAME generation-owned C02 authority the dispatch path uses. A nil
    /// `executionTargets` component (older composition) honestly reports
    /// `.eligible`: not observed is not proof of a change.
    func resumeExecutionTargetVerdict(runID: UUID, taskID: UUID) async
        -> ResumeExecutionTargetVerdict {
        guard let domain = components.executionTargets?.domain else { return .eligible }
        do {
            guard let pin = try await domain.runTargetPin(runID: runID) else {
                return .eligible
            }
            guard let target = try await domain.executionTarget(taskID: taskID) else {
                // The environment the park pinned no longer resolves at all.
                return .changed
            }
            // `C02RunTargetPin.matches` deliberately ignores the root
            // generation, so the live generation is re-proved HERE through
            // the existing authorities: the pinned value must belong to the
            // generation this domain actually serves and the target must
            // carry the same root epoch. A generation move with an otherwise
            // identical target is still a changed authority.
            guard pin.rootEpoch == target.rootEpoch,
                  pin.rootEpoch == epoch else {
                return .changed
            }
            return pin.matches(target) ? .eligible : .changed
        } catch {
            return .unverifiable
        }
    }

    /// Durable, fence-neutral visibility for a refused automatic resume: a
    /// `.notice` row (never a `status` row, so the park marker identity and
    /// the resume fence are untouched) records WHY the run did not continue.
    /// Best-effort: the typed refusal remains the authoritative answer.
    func noteResumeRefusedExecutionTargetChanged(runID: UUID) async {
        do {
            _ = try await durable.runs.appendEvent(
                runID: runID, kind: .notice,
                payloadJSON: Self.jsonString([
                    "notice": "resumeRefusedExecutionTargetChanged",
                    "reason": "resumeRefusedExecutionTargetChanged",
                    "recoverable": "true",
                    // The event projection surfaces payload.message.
                    "message": "The task's execution environment changed. Review the current environment before continuing. Completed work is preserved.",
                ]))
        } catch {
            // Best-effort visibility; the typed refusal still reaches the caller.
        }
    }

    // MARK: - Automatic continuation

    /// Trusted dependency callback entry. Re-proves every boundary against
    /// durable truth and resumes ONLY the same parked run. Uncertain
    /// (`interrupted`) or missing edges never auto-resume.
    func resumeAwaitingDependencyInternal(runID: UUID,
                                          conversationID: UUID) async
        -> JobDependencyResumeResult {
        guard !retirementFenced, globalFence == nil else { return .fenced }
        guard !resumingDependencyRuns.contains(runID),
              !stoppingDependencyRuns.contains(runID),
              owners[runID] == nil else { return .busy }
        do { try requireNoGuard(conversationID: conversationID) }
        catch { return .fenced }
        // Reserve this exact run across every suspension. A concurrent Stop
        // observes the reservation and answers busy without touching the
        // durable row; a duplicate callback is de-duplicated here too.
        resumingDependencyRuns.insert(runID)
        defer { resumingDependencyRuns.remove(runID) }

        if let decision = await C02TaskContinuityRuntimeHost.admissionDecision(
            taskID: conversationID, runID: runID, operation: .resume) {
            switch decision {
            case .paused: return .storagePaused
            case .resumeAuthorized: break
            }
        }
        let record: RunRecord
        do {
            record = try await durableRecord(runID, conversationID: conversationID)
        } catch let error as RunDomainError where error.code == .notFound {
            return .notAwaiting
        } catch {
            return .unverified
        }
        guard record.state == "checkpointed" else { return .notAwaiting }
        // A newer live run in THIS conversation wins over an older parked
        // one: never resume over the user's current turn or read its history.
        guard !hasOtherLiveConversationRun(conversationID: conversationID,
                                           excluding: runID) else { return .busy }
        // The EXACT durable park identity (reason + event sequence) is
        // captured HERE, before any preparation suspension. It is the identity
        // the committed resume must still continue; a Stop that lands during
        // preparation appends its own canonical row and makes this marker
        // stale, which the admission re-proves atomically.
        guard let park = await durableParkMarker(runID: runID),
              park.isAwaitingDependency else {
            return .notAwaiting
        }
        let (shape, observations) = await dependencyObservations(
            runID: runID, reason: park.reason)
        switch RunDependencyResumeGate.decide(
            shape: shape, observations: observations,
            allowMissing: false, allowUncertain: false) {
        case .notAwaiting:
            return .notAwaiting
        case .unverified:
            return .unverified
        case .waiting(let pending):
            return .waiting(pending)
        case .resume(let resolved):
            return await admitDependencyResume(record: record, park: park,
                                               resolvedEdges: resolved)
        }
    }

    private func admitDependencyResume(record: RunRecord,
                                       park: RunDependencyParkMarker,
                                       resolvedEdges: [RunDependencyObservation]) async
        -> JobDependencyResumeResult {
        let runID = record.id
        let conversationID = record.conversationID
        guard let identity = await runStopIdentity(
            runID: runID, conversationID: conversationID),
              identity.state == "checkpointed" else {
            return .unverified
        }
        // Legacy parks can predate activation markers. The store must prove
        // the entire legacy history and bootstrap inside the same park CAS;
        // a missing identity is never itself evidence of a completed stop.
        let sourceIncarnation = identity.incarnation
        // Re-prove the owner/fences after the edge read suspend.
        guard !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil,
              owners[runID] == nil else { return .fenced }
        switch await resumeExecutionTargetVerdict(runID: runID, taskID: conversationID) {
        case .eligible: break
        case .unverifiable: return .unverified
        case .changed:
            await noteResumeRefusedExecutionTargetChanged(runID: runID)
            return .refused(code: RunDomainError.Code.unsupportedRole.rawValue,
                            reason: RunDomainError.Reason.environmentRoleUnresolvable.rawValue)
        }
        if dependencyRunsWaitingForLinux.contains(runID) { return .waiting([]) }
        let savedTarget = try? await components.executionTargets?.domain.executionTarget(taskID: conversationID)
        let localTarget = savedTarget?.kind == .localLinux ? savedTarget : nil
        if let target = localTarget,
           !Self.linuxPreflightPrerequisitesAreLive(LinuxReadinessIngress.shared.derivedFields()) {
            let rootEpoch = epoch
            let host = C01LinuxEnvironmentMailboxHost(epoch: { rootEpoch })
            let phase = await host.preparationPhase()
            if phase == .pending || phase == .installing {
                dependencyRunsWaitingForLinux.insert(runID)
                // Release the usual resume reservation while the installer
                // owns work, so Stop and explicit Continue remain responsive.
                // The wake re-enters the original admission from the beginning.
                Task { [weak self] in
                    await self?.wakeDependencyAfterLinuxPreparation(runID: runID, target: target, park: park)
                }
                return .waiting([])
            }
            // Installation can finish between the first check and the host
            // reply. Honor newly verified readiness for this generation.
            guard Self.linuxPreflightPrerequisitesAreLive(LinuxReadinessIngress.shared.derivedFields()) else {
                await noteLinuxPreparationInterrupted(runID: runID)
                return Self.resumeRefusal(RunDomainError(.capabilityNotUsable, .environmentRoleUnresolvable))
            }
        }
        let checkpoint: AgentCheckpoint
        do {
            guard let loaded = try await components.checkpoints.load(runID: runID),
                  loaded.runID == runID,
                  loaded.conversationID == conversationID else {
                return .unverified
            }
            checkpoint = loaded
        } catch {
            return .unverified
        }
        let checkpointReason: String?
        if let persisted = checkpoint.state.isCheckpointedReason {
            checkpointReason = persisted
        } else {
            checkpointReason = park.reason
        }
        guard RunDependencyResumeGate.shape(of: checkpointReason) != .notAwaiting else {
            return .notAwaiting
        }
        let launch: RunModelAssembly.ResolvedPair
        do {
            guard let modelID = record.modelID, let providerID = record.providerID else {
                throw RunDomainError(.needsConfiguration, .modelDisabled)
            }
            launch = try await assembly.resolveSelected(
                providerID: providerID, modelID: modelID)
        } catch let error as RunDomainError {
            return Self.resumeRefusal(error)
        } catch {
            return .refused(code: RunDomainError.Code.needsConfiguration.rawValue,
                            reason: RunDomainError.Reason.providerDisabled.rawValue)
        }
        let gate: CatastrophicActionGate
        do {
            if components.credentialNormalizer == nil {
                throw RunDomainError(.needsConfiguration, .normalizerUnbound)
            }
            switch RunGateAdmission.admit(context: components.context) {
            case .usable(let admittedGate):
                gate = admittedGate
            case .needsCorpus:
                throw RunDomainError(.needsConfiguration, .corpusAbsent)
            }
            if !components.context.isTransportQualified {
                throw RunDomainError(.transportUnavailable, .transportNotQualified)
            }
        } catch let error as RunDomainError {
            return Self.resumeRefusal(error)
        } catch {
            return .refused(code: RunDomainError.Code.persistenceUnavailable.rawValue,
                            reason: RunDomainError.Reason.storeWriteFailed.rawValue)
        }
        let history: [ConversationMessage]
        do {
            history = try await loadRunHistory(
                conversationID: conversationID, excludingRun: runID, bundle: durable)
        } catch let error as RunDomainError {
            return Self.resumeRefusal(error)
        } catch {
            return .refused(code: RunDomainError.Code.persistenceUnavailable.rawValue,
                            reason: RunDomainError.Reason.storeReadFailed.rawValue)
        }
        guard let mode = ConversationMode(
            rawValue: record.conversationMode ?? "chat") else {
            return .refused(code: RunDomainError.Code.invalidState.rawValue,
                            reason: RunDomainError.Reason.payloadInvalid.rawValue)
        }
        let service: ConversationRunService
        do {
            service = try await makeService(
                runID: runID, conversationID: conversationID,
                goal: record.goal, mode: mode, launch: launch,
                history: history, images: [], bundle: durable,
                draftPolicy: nil, gate: gate, workspaceName: nil,
                hostToolCeiling: nil, environmentID: nil,
                // Same restart contract as an explicit retry: the immutable
                // run row first, then the exact checkpoint it just loaded.
                explicitExecutionMode: FacadeRunDomain.resumedExplicitExecutionMode(
                    record: record, checkpoint: checkpoint))
        } catch let error as RunDomainError {
            return Self.resumeRefusal(error)
        } catch {
            return .refused(code: RunDomainError.Code.persistenceUnavailable.rawValue,
                            reason: RunDomainError.Reason.storeWriteFailed.rawValue)
        }
        if localTarget != nil, !RuntimeFacadeLinuxBindings.shared.isCapabilityQualified {
            await noteLinuxPreparationInterrupted(runID: runID)
            return Self.resumeRefusal(RunDomainError(.capabilityNotUsable, .environmentRoleUnresolvable))
        }
        // Durable re-proof before the ONE committed resume admission: the row
        // must still be checkpointed, the EXACT park marker must still be the
        // latest park (a Stop appends its own row and invalidates this
        // identity), no Stop may be parked, and no owner may have appeared
        // while the service was assembled.
        guard !stoppingDependencyRuns.contains(runID) else { return .fenced }
        do {
            let current = try await durableRecord(runID, conversationID: conversationID)
            guard current.state == "checkpointed" else { return .notAwaiting }
        } catch {
            return .unverified
        }
        guard await durableParkMarker(runID: runID) == park else {
            // The park changed (a completed Stop, a foreign rewrite). Never
            // continue an older decision over newer durable truth.
            return .notAwaiting
        }
        guard !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil,
              owners[runID] == nil else { return .fenced }

        // Linux preparation/upgrade recheck (Android counterpart of the iOS
        // live-execution-binding guard, commit 6a4582131): the parked run's
        // pinned environment must still be the task's live target — same
        // identity AND same live root generation — before the ONE committed
        // admission. A change NEVER auto-continues: unlike iOS there is no
        // committed retained-rebuild receipt for a parked run, so any change
        // is surfaced as a typed, durably noticed refusal; the run stays
        // parked and recoverable, and an explicit user Continue decides the
        // new environment.
        switch await resumeExecutionTargetVerdict(runID: runID,
                                                  taskID: conversationID) {
        case .eligible:
            break
        case .unverifiable:
            return .unverified
        case .changed:
            await noteResumeRefusedExecutionTargetChanged(runID: runID)
            return .refused(
                code: RunDomainError.Code.unsupportedRole.rawValue,
                reason: RunDomainError.Reason.environmentRoleUnresolvable.rawValue)
        }

        // The ONE trusted lifecycle cause (system role, deterministic id).
        // It is persisted AFTER the resume CAS commits and BEFORE the runtime
        // handoff, so a refused/fenced resume never leaves a false "the task
        // continued" notice behind.
        let messageID = Self.dependencyResumptionMessageID(
            runID: runID, edges: resolvedEdges)
        let content = Self.dependencyResumeNote(edges: resolvedEdges)

        // C0 admission owner (start parity): attach the exact scoped tokens
        // before the atomic resume commit so a Stop during this window is
        // classified and the commit re-proves the same identity.
        let launchToken = issueFence(conversationID)
        switch RuntimeOwnedWorkRegistry.shared.attach(
            epoch: epoch, kind: .run, ownerID: runID.uuidString) {
        case .attached(let token):
            var ownership = RunOwnership(
                conversationID: conversationID, runID: runID, epoch: epoch,
                identity: .ordinary, launchToken: launchToken, bundle: durable)
            ownership.phase = .admitting
            ownership.incarnation = sourceIncarnation
            ownership.ownedTokens[RuntimeOwnedWorkKind.run.rawValue] = token
            register(ownership)
            recordDrainEvidence(conversationID: conversationID, token: token)
        case .rejected:
            return .fenced
        case .invalidIdentity:
            return .refused(code: RunDomainError.Code.internalError.rawValue,
                            reason: RunDomainError.Reason.internal.rawValue)
        }

        // REAL App-host foreground protection MUST exist before the commit
        // and before any provider/tool side effect. The acquisition is the
        // ORIGINAL RunForegroundController lease (same authority a
        // user-launched run uses); the trusted host answers over the existing
        // LinuxShellMailbox lane. A refusal/unbound host never dispatches
        // anything: the run stays parked with its data and stays retryable.
        guard let foreground = components.runForegroundAdmission else {
            releaseResumeAdmission(runID: runID)
            return .foregroundUnavailable
        }
        switch await foreground.admit(epoch: epoch, runID: runID,
                                      conversationID: conversationID) {
        case .admitted:
            break
        case .refused:
            releaseResumeAdmission(runID: runID)
            return .foregroundUnavailable
        case .unbound:
            // The host may have started a reservation before its reply was
            // lost. Ask it to reconcile; never assume timeout means no lease.
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            releaseResumeAdmission(runID: runID)
            return .foregroundUnavailable
        }
        // The admission awaited a real OS foreground start: EVERY durable and
        // in-process fact is re-proven before the CAS. A Stop during the
        // acquisition has already committed its own park row.
        guard await durableParkMarker(runID: runID) == park,
              !stoppingDependencyRuns.contains(runID),
              !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil,
              !hasOtherLiveConversationRun(conversationID: conversationID,
                                           excluding: runID),
              owners[runID]?.launchToken == launchToken,
              owners[runID]?.phase == .admitting,
              owners[runID]?.cancelRequested == false else {
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            releaseResumeAdmission(runID: runID)
            return hasOtherLiveConversationRun(conversationID: conversationID,
                                               excluding: runID) ? .busy : .fenced
        }
        // The foreground start awaited REAL OS work: a target migration may
        // have landed inside that window. Re-prove the same eligibility and
        // release the lease truthfully on any change — the resume CAS must
        // never commit onto an environment the park did not pin.
        switch await resumeExecutionTargetVerdict(runID: runID,
                                                  taskID: conversationID) {
        case .eligible:
            break
        case .unverifiable:
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            releaseResumeAdmission(runID: runID)
            return .unverified
        case .changed:
            await noteResumeRefusedExecutionTargetChanged(runID: runID)
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            releaseResumeAdmission(runID: runID)
            return .refused(
                code: RunDomainError.Code.unsupportedRole.rawValue,
                reason: RunDomainError.Reason.environmentRoleUnresolvable.rawValue)
        }

        var committedIncarnation: RunIncarnation?
        do {
            guard let resumable = durable.runs as? any ResumeActivationRunStore else {
                throw RunDomainError(.capabilityNotUsable, .intelligenceStoreUnbound)
            }
            committedIncarnation = try await resumable.beginDependencyResume(
                runID: runID, conversationID: conversationID,
                expectedIncarnation: sourceIncarnation?.proof,
                observedSettlementSequence: identity.latestSettlementSequence,
                expectedParkSequence: park.sequence)
        } catch let error as RunDomainError {
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            releaseResumeAdmission(runID: runID)
            return Self.resumeRefusal(error)
        } catch {
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            releaseResumeAdmission(runID: runID)
            return .refused(code: RunDomainError.Code.persistenceUnavailable.rawValue,
                            reason: RunDomainError.Reason.storeWriteFailed.rawValue)
        }
        guard let committedIncarnation else {
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            let current = (try? await durable.runs.run(id: runID))?.state
            releaseResumeAdmission(runID: runID)
            return current == "checkpointed" ? .unverified : .notAwaiting
        }
        if var current = owners[runID], current.launchToken == launchToken {
            current.incarnation = committedIncarnation
            register(current)
        }
        // ATOMIC STOP FENCE: `beginUserResume` re-proves only the row state,
        // and a parked Stop keeps `checkpointed`; the canonical userStop row
        // it appends is what proves who won. The committed `userResume`
        // marker must be the ONLY status row after the exact park event.
        let fenceVerdict = RunDependencyResumeFence.verdict(
            park: park,
            eventsAfterPark: await resumeFenceEvents(
                runID: runID, afterSequence: park.sequence),
            allowsLegacyBootstrap: sourceIncarnation == nil)
        switch fenceVerdict {
        case .clean:
            break
        case .userStopped:
            // The user's Stop committed first: restore the truthful stopped
            // checkpoint (the canonical row already exists) and never hand a
            // service off.
            await markCommittedResumeStopped(runID: runID, bundle: durable)
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            await retire(runID: runID, terminalSucceeded: false,
                         feedTerminal: false)
            return .fenced
        case .foreign, .unreadable:
            await markCommittedLaunchAbandoned(runID: runID,
                                               reason: "resumeFenceInterleaved",
                                               bundle: durable)
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            await retire(runID: runID, terminalSucceeded: false,
                         feedTerminal: false)
            return fenceVerdict == .unreadable ? .unverified : .fenced
        }
        // The commit landed. Re-prove the exact admission before publishing the
        // service: a Stop/fence that interleaved fails the resume truthfully
        // and never hands a service off.
        if hasOtherLiveConversationRun(conversationID: conversationID,
                                       excluding: runID) {
            // A newer run appeared between our admission and the commit. The
            // parked run keeps recoverable data (failed → retryable), but it
            // must not run concurrently with the user's current turn.
            await markCommittedLaunchAbandoned(runID: runID,
                                               reason: "conversationOccupied",
                                               bundle: durable)
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            await retire(runID: runID, terminalSucceeded: false,
                         feedTerminal: false)
            return .busy
        }
        guard let ownership = owners[runID],
              ownership.launchToken == launchToken,
              ownership.epoch == epoch else {
            await markCommittedLaunchAbandoned(runID: runID,
                                               reason: "resumeAdmissionReplaced",
                                               bundle: durable)
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            return .fenced
        }
        if ownership.cancelRequested || !fenceIsValid(launchToken)
            || retirementFenced || globalFence != nil
            || deleteGuards[conversationID] != nil
            || stoppingDependencyRuns.contains(runID) {
            let userStopped = ownership.cancelRequested
                || stoppingDependencyRuns.contains(runID)
            if userStopped {
                // The user's Stop won the race after the resume CAS: publish
                // the truthful stopped checkpoint instead of a generic failure.
                await markCommittedResumeStopped(runID: runID, bundle: durable)
            } else {
                await markCommittedLaunchAbandoned(runID: runID,
                                                   reason: "cancelledDuringResume",
                                                   bundle: durable)
            }
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            await retire(runID: runID, terminalSucceeded: false,
                         feedTerminal: false)
            return .fenced
        }
        // The resume is durably committed. Persist the visible system notice
        // BEFORE the runtime starts; a failed write abandons this exact
        // committed admission truthfully instead of resuming silently.
        let message = PersistedMessage(
            id: messageID, conversationID: conversationID,
            role: "system", content: content, createdAt: Date(),
            parts: [MessagePart(messageID: messageID, partIndex: 0,
                                kind: .text, text: content)],
            runID: runID)
        do {
            try await durable.conversations.appendMessage(message)
        } catch {
            await markCommittedLaunchAbandoned(
                runID: runID, reason: "resumeLifecycleMessageFailed",
                bundle: durable)
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            await retire(runID: runID, terminalSucceeded: false,
                         feedTerminal: false)
            return .refused(code: RunDomainError.Code.persistenceUnavailable.rawValue,
                            reason: RunDomainError.Reason.storeWriteFailed.rawValue)
        }
        // Final re-proof AFTER the message write: a Stop/fence that landed
        // while the durable append suspended must not be overwritten by the
        // handoff. The exact same admission must still own this run.
        guard let current = owners[runID],
              current.launchToken == launchToken,
              current.epoch == epoch,
              !current.cancelRequested,
              !stoppingDependencyRuns.contains(runID),
              fenceIsValid(launchToken),
              !retirementFenced,
              globalFence == nil,
              deleteGuards[conversationID] == nil else {
            let userStopped = owners[runID]?.cancelRequested == true
                || stoppingDependencyRuns.contains(runID)
            if userStopped {
                await markCommittedResumeStopped(runID: runID, bundle: durable)
            } else {
                await markCommittedLaunchAbandoned(
                    runID: runID, reason: "cancelledDuringResume",
                    bundle: durable)
            }
            await releaseForegroundAdmission(runID: runID, epoch: epoch)
            await retire(runID: runID, terminalSucceeded: false,
                         feedTerminal: false)
            return .fenced
        }
        var handing = current
        handing.phase = .prepared
        register(handing)
        if mode == .goal {
            goalModeRuns.insert(runID)
            frozenRoutes[runID] = launch
        }
        liveServices[runID] = service
        handing.phase = .handedOff
        register(handing)
        // The service's RuntimeSteerInput represents a human user turn. A
        // dependency receipt is native lifecycle context, so restore it as
        // the same system message we persisted above instead of fabricating
        // user input in the provider request.
        var resumedCheckpoint = checkpoint
        if !resumedCheckpoint.messages.contains(where: { $0.id == messageID }) {
            resumedCheckpoint.messages.append(ConversationMessage(
                id: messageID, role: "system", content: content,
                createdAt: message.createdAt))
        }
        ownedLaunchTasks(
            preparedRunID: runID, service: service, goal: record.goal,
            resumeFrom: resumedCheckpoint)
        return .resumed
    }

    private func wakeDependencyAfterLinuxPreparation(runID: UUID, target: C02ExecutionTarget,
                                                     park: RunDependencyParkMarker) async {
        let prepared = (try? await awaitLocalLinuxPreparation(runID: runID, target: target, park: park)) == true
        dependencyRunsWaitingForLinux.remove(runID)
        guard prepared, await durableParkMarker(runID: runID) == park else { return }
        _ = await resumeAwaitingDependencyInternal(runID: runID, conversationID: target.taskID)
    }

    /// A committed resume abandoned by the user's explicit Stop. The row was
    /// just moved `checkpointed→preparing` by the resume CAS; only that exact
    /// state is rewritten back to the canonical stopped checkpoint, so a real
    /// runtime terminal is never overwritten.
    ///
    /// The canonical stopped status row is appended AFTER the losing resume
    /// marker, so the event stream and the row agree on the final cause (the
    /// user's Stop) even when the earlier Stop row is what fenced the resume.
    private func markCommittedResumeStopped(runID: UUID,
                                            bundle: RunPersistenceBundle) async {
        do {
            guard let record = try await bundle.runs.run(id: runID),
                  record.state == "preparing" else { return }
            try await bundle.runs.updateRunState(id: runID, state: "checkpointed",
                                                 endedAt: Date())
            _ = try await bundle.runs.appendEvent(
                runID: runID, kind: .status,
                payloadJSON: Self.jsonString([
                    "state": "checkpointed",
                    "reason": Self.parkedUserStopReason,
                    "userStopped": "true",
                ]))
            lastObservedState[runID] = "checkpointed"
        } catch {
            // Best-effort: the runtime/launch failure path remains truthful.
        }
    }

    /// Release the EXACT foreground lease of an abandoned automatic resume.
    /// It is called only before a handoff, so no live run can own the lease;
    /// a handed-off run keeps it until real owned-work settlement.
    private func releaseForegroundAdmission(runID: UUID, epoch: UInt64) async {
        guard let foreground = components.runForegroundAdmission else { return }
        await foreground.release(epoch: epoch, runID: runID)
    }

    private func releaseResumeAdmission(runID: UUID) {
        guard var ownership = owners[runID] else { return }
        if let token = ownership.ownedTokens.removeValue(
            forKey: RuntimeOwnedWorkKind.run.rawValue) {
            RuntimeOwnedWorkRegistry.shared.detach(token)
        }
        ownership.phase = .retired
        unregister(ownership)
    }

    // MARK: - Explicit Stop

    /// The user's explicit Stop of a parked waiting run. It never fakes a job
    /// terminal; it fences the run so no late callback can revive it.
    ///
    /// `expectedIncarnation` is the durable activation the caller's command
    /// addressed. When supplied, the writer re-proves that EXACT incarnation
    /// inside the same transaction as the row CAS; a retry that committed a
    /// newer activation makes this Stop stale and writes nothing.
    public func stopAwaitingDependency(runID: UUID,
                                       conversationID: UUID,
                                       expectedIncarnation: RunIncarnation? = nil,
                                       expectedStatusSequence: Int? = nil) async
        -> JobDependencyStopResult {
        let expectedOwner = captureStopOwner(runID: runID)
        return await stopAwaitingDependencyBound(
            runID: runID, conversationID: conversationID,
            expectedIncarnation: expectedIncarnation,
            expectedStatusSequence: expectedStatusSequence,
            expectedOwner: expectedOwner)
    }

    func stopAwaitingDependencyBound(runID: UUID,
                                     conversationID: UUID,
                                     expectedIncarnation: RunIncarnation?,
                                     expectedStatusSequence: Int?,
                                     expectedOwner: StopOwnerCapture) async
        -> JobDependencyStopResult {
        guard !stoppingDependencyRuns.contains(runID) else { return .busy }
        guard !retirementFenced, globalFence == nil else {
            return .refused(code: RunDomainError.Code.sessionFenced.rawValue,
                            reason: RunDomainError.Reason.generationRetired.rawValue)
        }
        do { try requireNoGuard(conversationID: conversationID) }
        catch {
            return .refused(code: RunDomainError.Code.sessionFenced.rawValue,
                            reason: RunDomainError.Reason.deletingGuarded.rawValue)
        }
        guard stopOwnerMatches(expectedOwner, runID: runID) else {
            return .staleIncarnation
        }
        // A Stop that lands while an AUTOMATIC resume is still admitting MUST
        // win. The in-flight admission is marked synchronously here (it
        // re-proves this exact flag after every await and before any provider
        // or tool side effect); a genuinely live/handed-off run keeps the
        // ordinary live-cancel path instead. Once that admission COMMITTED
        // its new incarnation proof, an older Stop must not touch it.
        if var owner = owners[runID] {
            guard owner.phase == .admitting else { return .busy }
            if let ownerIncarnation = owner.incarnation,
               ownerIncarnation.proof != expectedIncarnation?.proof {
                return .staleIncarnation
            }
            owner.cancelRequested = true
            register(owner)
        }
        stoppingDependencyRuns.insert(runID)
        defer { stoppingDependencyRuns.remove(runID) }

        let record: RunRecord
        do {
            record = try await durableRecord(runID, conversationID: conversationID)
        } catch let error as RunDomainError {
            return .refused(code: error.code.rawValue, reason: error.reason.rawValue)
        } catch {
            return .refused(code: RunDomainError.Code.persistenceUnavailable.rawValue,
                            reason: RunDomainError.Reason.storeReadFailed.rawValue)
        }
        guard record.state == "checkpointed",
              let marker = await durableParkMarker(runID: runID),
              marker.isAwaitingDependency else {
            return .alreadyStarted(state: record.state)
        }
        // Only an admission still in flight (or no owner yet) may run the
        // parked-stop CAS; a handed-off owner is a live cancel.
        if let owner = owners[runID], owner.phase != .admitting { return .busy }
        // Read state + incarnation from ONE reader transaction before the
        // commit. When the caller supplied an incarnation, a moved row is a
        // stale command; when it did not, the same read can still BIND the
        // proof (direct trusted callers) instead of silently writing a
        // less-provable stop.
        let identity = await runStopIdentity(runID: runID,
                                             conversationID: conversationID)
        if let identity {
            guard identity.state == "checkpointed" else {
                return .alreadyStarted(state: identity.state)
            }
            if let expectedStatusSequence,
               identity.latestStatusSequence != expectedStatusSequence {
                return .staleIncarnation
            }
            if let expectedIncarnation,
               identity.incarnation?.proof != expectedIncarnation.proof {
                return .staleIncarnation
            }
        }
        // A caller that captured a nil incarnation may not silently rebind
        // to a new activation observed after its Stop request.
        let boundIncarnation = expectedStatusSequence == nil
            ? (expectedIncarnation ?? identity?.incarnation) : expectedIncarnation
        let boundStatusSequence = expectedStatusSequence ?? identity?.latestStatusSequence
        // The CAS is the fence: if a resume committed first, the row is no
        // longer checkpointed and NOTHING is rewritten. The typed commit
        // additionally re-proves the exact incarnation in the SAME writer
        // transaction and appends the settlement row there.
        var typedSettlement: RunStopSettlement?
        var alreadySettled = false
        if let typedCommit = components.commitParkedRunStopSettlement {
            let outcome = await typedCommit(runID, conversationID,
                                            "checkpointed", boundIncarnation,
                                            boundStatusSequence)
            switch outcome {
            case .settled(let settlement):
                typedSettlement = settlement
            case .alreadySettled(let settlement):
                typedSettlement = settlement
                alreadySettled = true
            case .unboundStopped:
                break
            case .staleIncarnation:
                return .staleIncarnation
            case .notStopped(let state):
                return .alreadyStarted(state: state)
            case .unreadable:
                return .refused(
                    code: RunDomainError.Code.persistenceUnavailable.rawValue,
                    reason: RunDomainError.Reason.storeWriteFailed.rawValue)
            }
        } else {
            guard let commit = components.commitParkedRunStop else {
                return .refused(
                    code: RunDomainError.Code.persistenceUnavailable.rawValue,
                    reason: RunDomainError.Reason.storeWriteFailed.rawValue)
            }
            let committed = await commit(runID, conversationID, "checkpointed")
            guard committed else {
                let current = (try? await durable.runs.run(id: runID))?.state
                return .alreadyStarted(state: current ?? record.state)
            }
        }
        // The run is durably stopped from this point on. Rewrite the recovery
        // checkpoint's reason (identity preserved) so the durable cause is the
        // user's Stop, never the stale dependency marker.
        if let checkpoint = try? await components.checkpoints.load(runID: runID),
           checkpoint.runID == runID,
           checkpoint.conversationID == conversationID {
            var copy = checkpoint
            copy.state = .checkpointed(AgentState.CheckpointRef(
                reason: Self.parkedUserStopReason))
            try? await components.checkpoints.save(copy)
        }
        // Resolve every still-pending edge as cancelled. This is the durable
        // fence for late job callbacks: resolution is exactly-once, so a later
        // terminal cannot overwrite it and the continuation gate sees a
        // cancelled (terminal) edge on a run that is no longer parked.
        var namedIDs: [UUID] = []
        if case .named(let ids) = RunDependencyResumeGate.shape(of: marker.reason) {
            namedIDs = ids
        }
        var pendingJobIDs: [UUID] = []
        if let reader = components.runDependencyEdges,
           let observations = await reader.edges(runID: runID,
                                                 jobIDs: namedIDs) {
            for case .pending(let jobID, _) in observations {
                await reader.resolve(
                    jobID: jobID, state: .cancelled,
                    note: "The run was stopped by the user; this dependency will not resume it.")
                pendingJobIDs.append(jobID)
            }
        }
        // Cooperative cancellation of the EXACT pending dependency jobs. A
        // legacy checkpoint without identifiers cancels nothing it cannot
        // prove; the run itself is already durably stopped.
        let requested: [UUID]
        if let cancelJobs = components.cancelParkedRunJobs, !pendingJobIDs.isEmpty {
            requested = await cancelJobs(runID, conversationID, pendingJobIDs)
        } else {
            requested = []
        }
        // The CAS transaction already appended the ONE canonical userStop
        // status row; no second, contradictory cause is written here.
        lastObservedState[runID] = "checkpointed"
        if let typedSettlement {
            return alreadySettled
                ? .alreadySettled(settlement: typedSettlement)
                : .settled(cancelledJobIDs: requested,
                           settlement: typedSettlement)
        }
        return .stopped(cancelledJobIDs: requested)
    }

    // MARK: - Bounded model-facing cause

    private static func resumeRefusal(_ error: RunDomainError)
        -> JobDependencyResumeResult {
        .refused(code: error.code.rawValue, reason: error.reason.rawValue)
    }

    /// Deterministic identity for the ONE lifecycle message of a dependency
    /// continuation. The same settled edge set always maps to the same id, so
    /// `appendMessage`'s upsert cannot duplicate it.
    static func dependencyResumptionMessageID(
        runID: UUID, edges: [RunDependencyObservation]
    ) -> UUID {
        let identity = edges.map { observation -> String in
            switch observation {
            case .pending(let jobID, _): return jobID.uuidString
            case .terminal(let jobID, _, let state):
                return jobID.uuidString + ":" + state.rawValue
            case .missing(let jobID): return jobID.uuidString + ":missing"
            }
        }.sorted().joined(separator: ",")
        let digest = FloeDigest.sha256Hex(Data(
            "floe.job.dependency.resume|\(runID.uuidString)|\(identity)".utf8))
        let hex = Array(digest.prefix(32))
        func part(_ range: Range<Int>) -> String {
            String(hex[range.lowerBound..<min(range.upperBound, hex.count)])
        }
        let value = "\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-"
            + "\(part(16..<20))-\(part(20..<32))"
        return UUID(uuidString: value) ?? UUID()
    }

    /// Concise, bounded, secret-free lifecycle text. It names only durable job
    /// identities and states — never a command, payload, path or output.
    static func dependencyResumeNote(edges: [RunDependencyObservation]) -> String {
        let resolved = edges.filter {
            switch $0 {
            case .terminal, .missing: return true
            case .pending: return false
            }
        }
        var lines: [String] = [
            "[Floe background work] This task paused for required background work. "
                + "The durable outcome is now settled:"
        ]
        let listed = resolved.prefix(8)
        for observation in listed {
            switch observation {
            case .terminal(let jobID, let kind, let state):
                let outcome: String
                if kind == "service", state == .resolved {
                    outcome = "is ready and keeps running"
                } else {
                    switch state {
                    case .resolved: outcome = "completed"
                    case .failed: outcome = "failed"
                    case .cancelled: outcome = "was cancelled"
                    case .interrupted:
                        outcome = "was interrupted; its outcome is unknown"
                    case .pending:
                        outcome = "is still pending"
                    }
                }
                lines.append("- job \(jobID.uuidString) (\(kind) dependency): \(outcome)")
            case .missing(let jobID):
                lines.append("- job \(jobID.uuidString) (dependency): "
                    + "the durable edge is gone; its outcome is unknown")
            case .pending:
                break
            }
        }
        if resolved.count > listed.count {
            lines.append("- and \(resolved.count - listed.count) more settled job(s)")
        }
        lines.append("Use jobs.status or jobs.result with these job IDs for the "
            + "durable details. Do not resubmit an unchanged payload, and do not "
            + "claim work that did not complete.")
        let text = lines.joined(separator: "\n")
        return String(text.prefix(2_000))
    }
}

extension FacadeRunDomain: JobDependencyContinuationPort {
    public func resumeAwaitingDependency(runID: UUID, conversationID: UUID) async
        -> JobDependencyResumeResult {
        await resumeAwaitingDependencyInternal(
            runID: runID, conversationID: conversationID)
    }
}

// MARK: - Live-parent lifecycle receipt

extension FacadeRunDomain: JobDependencyLiveNoticePort {
    public func noteSettledDependency(runID: UUID, conversationID: UUID,
                                      jobID: UUID, kind: String,
                                      state: RunDependencyState) async -> Bool {
        await noteSettledDependencyInternal(
            runID: runID, conversationID: conversationID,
            jobID: jobID, kind: kind, state: state)
    }
}

extension FacadeRunDomain {
    /// A dependency settled while its parent may still be RUNNING (the job
    /// finished before the runtime's final pending-edge check, or the parent
    /// is between steps). The ORIGINAL runtime service receives ONE trusted
    /// `system` lifecycle receipt at its next complete step boundary, which
    /// keeps the turn alive and lets the model consume the durable result.
    ///
    /// This never creates a run, never fabricates a user turn, never touches
    /// queued history/permission/temporary ceilings and never rewrites an
    /// edge. A parked/terminal/foreign run answers false and the parked
    /// continuation path decides instead.
    func noteSettledDependencyInternal(runID: UUID, conversationID: UUID,
                                       jobID: UUID, kind: String,
                                       state: RunDependencyState) async -> Bool {
        guard !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil else { return false }
        guard let owner = owners[runID],
              owner.conversationID == conversationID,
              owner.phase == .prepared || owner.phase == .handedOff,
              let service = liveServices[runID] else { return false }
        let notice = RuntimeLifecycleNotice(
            id: Self.dependencyNoticeMessageID(runID: runID, jobID: jobID,
                                               state: state),
            content: Self.dependencyNoticeText(jobID: jobID, kind: kind,
                                              state: state))
        switch await service.deliverLifecycleNotice(notice,
                                                    expectedRunID: runID) {
        case .accepted, .alreadyAccepted:
            return true
        case .rejected:
            return false
        }
    }

    /// Deterministic identity: the same settled (run, job, state) always maps
    /// to the same notice row, so a duplicated terminal callback cannot add a
    /// second copy.
    static func dependencyNoticeMessageID(runID: UUID, jobID: UUID,
                                          state: RunDependencyState) -> UUID {
        let digest = FloeDigest.sha256Hex(Data(
            "floe.job.dependency.notice|\(runID.uuidString)|\(jobID.uuidString)|\(state.rawValue)".utf8))
        let hex = Array(digest.prefix(32))
        func part(_ range: Range<Int>) -> String {
            String(hex[range.lowerBound..<min(range.upperBound, hex.count)])
        }
        let value = "\(part(0..<8))-\(part(8..<12))-\(part(12..<16))-"
            + "\(part(16..<20))-\(part(20..<32))"
        return UUID(uuidString: value) ?? UUID()
    }

    /// Concise, closed, secret-free lifecycle metadata. It names only the
    /// durable job identity, its dependency kind and its terminal state —
    /// never a command, payload, path or output excerpt.
    static func dependencyNoticeText(jobID: UUID, kind: String,
                                     state: RunDependencyState) -> String {
        let outcome: String
        if kind == "service", state == .resolved {
            outcome = "is ready and keeps running"
        } else {
            switch state {
            case .resolved: outcome = "completed"
            case .failed: outcome = "failed"
            case .cancelled: outcome = "was cancelled"
            case .interrupted:
                outcome = "was interrupted; its outcome is unknown"
            case .pending: outcome = "is still pending"
            }
        }
        let text = """
        [Floe background work] A background job this task submitted reached its durable outcome while the task was still running:
        - job \(jobID.uuidString) (\(kind) dependency): \(outcome)
        Use jobs.status or jobs.result with this job ID before you finalize. Do not resubmit an unchanged payload, and do not claim work that did not complete.
        """
        return String(text.prefix(2_000))
    }
}

/// Convenience entry points for the trusted host (never a wire command).
public extension RunDomainFacade {
    static func resumeAwaitingDependency(epoch: UInt64, runID: UUID,
                                         conversationID: UUID) async
        -> JobDependencyResumeResult {
        guard let (domain, _) = current(epoch: epoch) else { return .fenced }
        return await domain.resumeAwaitingDependency(
            runID: runID, conversationID: conversationID)
    }

    static func stopAwaitingDependency(epoch: UInt64, runID: UUID,
                                       conversationID: UUID) async
        -> JobDependencyStopResult {
        guard let (domain, _) = current(epoch: epoch) else {
            return .refused(code: RunDomainError.Code.sessionFenced.rawValue,
                            reason: RunDomainError.Reason.generationRetired.rawValue)
        }
        return await domain.stopAwaitingDependency(
            runID: runID, conversationID: conversationID)
    }
}

// MARK: - Checkpoint state helper

extension AgentState {
    /// The durable park reason when the in-memory state is a checkpoint
    /// reference (the persisted checkpoint itself is usually `preparing`).
    var isCheckpointedReason: String? {
        if case .checkpointed(let reference) = self { return reference.reason }
        return nil
    }
}
