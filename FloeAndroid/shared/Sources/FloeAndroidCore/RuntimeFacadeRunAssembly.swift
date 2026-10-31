// SPDX-License-Identifier: MPL-2.0
//
// RB-4 RunDomain REPAIR (job-047bee7a3eff4941) — the REAL native run-service
// assembly factory, owned tool/child exact-token accounting, and the
// non-blocking owned P8 maintenance-feed dispatch (private source candidate;
// NOT compiled, NOT executed, NOT registered).
//
// What this file REPAIRS against the frozen parent (runtime-runs-approvals-
// source, pure archive 6c36124e…): Main review RUN-S1/RUN-S3 found the
// parent CALLED `makeService` (parent RuntimeFacadeRuns.swift:868/:1173) with
// NO declaration anywhere, never inserted into `liveServices`, never called
// `runAdapter(for:)` or `tools.registerDelegate(_:for:)`, and Awaited the P8
// message feed inline before the service handoff (blocking the launch on the
// feed) plus the terminal feed inline on the producer path. This file
// supplies the real bounded implementations:
//
// * `makeService` constructs the ORIGINAL `ConversationRunService` against
//   the CURRENT live constructor (ConversationRunService.swift:260-282) with
//   the ORIGINAL `FloeAgentRuntime.Configuration` (AgentRuntime.swift:349+),
//   the ORIGINAL adapter from `ProviderAdapterFactory` (or the host/test
//   factory override), the ORIGINAL `CatalogToolExecutor`
//   (AgentRuntime.swift:223), the ORIGINAL `HybridContextEngine` default, the
//   reviewed gate corpus loader result, the per-run immutable
//   `RunPersistenceBundle` stores, the persisted task policy read through
//   the ORIGINAL `SQLiteWorkspaceStore.taskPolicy(conversationID:)`, and the
//   real `RunCredentialArgumentNormalizing.normalized(call:runOwner:)`
//   bound through the service's `toolCallNormalizer` closure BEFORE tool
//   arguments can reach approval, audit, persistence or the executor.
//   The iOS ConversationCenter construction (ConversationCenter.swift
//   :2864/:3156-3177/:3220-3282) is the ORDERING reference only; no UIKit/
//   MainActor/CloudKit/Keychain coupling is copied and there is no iOS
//   execution fallback.
// * The per-run `SubagentRunner` (SubagentRunner.swift:186-198) is
//   registered through `RunToolAssembly.registerDelegate(runner:for:)`
//   (which performs the ORIGINAL `registerDelegateTool(registry:runners:)`
//   + runner binding) and retired ONLY at the real terminal through the
//   existing `tools.retireDelegate(runID:)`.
// * Tool/child exact tokens attach at the REAL lifecycle boundaries
//   (.tool at toolLifecycle .requested/.started, detach at .finished;
//   .childRun at non-terminal child frames, detach at terminal) and detach
//   ONLY at real completion — mid-run registry saturation degrades
//   conservatively so a later delete can never under-count quiescence.
// * The P8 maintenance feeds are dispatched as REAL owned Tasks: the
//   root+per-conversation lease is ACQUIRED (registry attach under the
//   CURRENT epoch, map insert, drain evidence) BEFORE the dispatching await
//   returns — never a check-then-await-only boolean fence — the delete drain
//   and root retirement see the exact token from that moment, and the lease
//   is released only after the handler really returns. Bookkeeping is
//   bounded and pruned after the trusted terminal (no unbounded
//   per-completed-run/every-message retained sets).
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity

// MARK: - Production credential-argument normalizer adapter (S1)

/// The REAL `RunCredentialArgumentNormalizing` implementation (Main decision
/// 2026-10-20): it is a thin, stateless adapter over the already-qualified
/// `CredentialArgumentNormalizer.normalize(argumentsJSON:toolName:targetScope:
/// vault:owner:authority:)` implementation compiled into this module, taking
/// the SAME-ROOT `CredentialCapturing` actor (the qualified
/// `AndroidCredentialVault`, never `vault.records`, which is the metadata
/// `CredentialStore`).
///
/// * Identity: the ORIGINAL `ToolCall` is returned with ONLY
///   `argumentsJSON` replaced by the normalized JSON — id, tool name,
///   scope and idempotency key stay untouched.
/// * Ownership: `RunCredentialOwner.Scope.conversation(id)` maps to
///   `CredentialOwner.conversation(id)` and `.workspace(id)` to
///   `.workspace(id)` (the exact original mapping; no `.vault` substitution).
/// * Authority: an optional original `RunCredentialAuthority` is forwarded
///   unchanged; nil keeps the reviewed capture behavior (the original port's
///   default) rather than inventing a grant.
/// * Temporary runs never receive this adapter (the assembly binds nil for
///   `.temporary`), so temporary raw arguments stay in RAM and are never
///   captured.
public struct RunCredentialArgumentNormalizerAdapter:
    RunCredentialArgumentNormalizing, Sendable {
    public let vault: any CredentialCapturing
    public let authority: RunCredentialAuthority?

    public init(vault: any CredentialCapturing,
                authority: RunCredentialAuthority? = nil) {
        self.vault = vault
        self.authority = authority
    }

    /// Composition factory used by the facade assembly input
    /// (`RunDomainComponents.credentialNormalizer`) and by the final App,
    /// which supplies its SAME-ROOT `AndroidCredentialVault` instance.
    public static func make(
        vault: any CredentialCapturing,
        authority: RunCredentialAuthority? = nil
    ) -> RunCredentialArgumentNormalizerAdapter {
        RunCredentialArgumentNormalizerAdapter(vault: vault, authority: authority)
    }

    public func normalized(call: ToolCall,
                           runOwner: RunCredentialOwner) async throws -> ToolCall {
        let owner: CredentialOwner
        switch runOwner.scope {
        case .conversation(let id): owner = .conversation(id)
        case .workspace(let id): owner = .workspace(id)
        }
        let normalizedJSON = try await CredentialArgumentNormalizer.normalize(
            call.argumentsJSON,
            toolName: call.toolName,
            targetScope: call.scope,
            vault: vault,
            owner: owner,
            authority: authority)
        guard normalizedJSON != call.argumentsJSON else { return call }
        var normalized = call
        normalized.argumentsJSON = normalizedJSON
        return normalized
    }
}

// MARK: - REAL P8 personalization feed binding (RUN-S3)

/// Trusted `PersonalizationEventOwnedLeaseProviding` over the SAME Run-owned
/// lease map/registry/epoch: the memory/P8 handler asks THIS seam immediately
/// before its first mutation, and it re-checks the live domain state (epoch,
/// delete guard, global admission fence, generation retirement) plus the
/// exact registry-attached conversation lease token. A missing/stale/fenced
/// lease fails CLOSED; an unbound provider also fails closed.
public struct RunPersonalizationLeaseValidator:
    PersonalizationEventOwnedLeaseProviding, Sendable {
    private let domainProvider: @Sendable () -> FacadeRunDomain?

    public init(domain: FacadeRunDomain) {
        self.domainProvider = { domain }
    }

    public init(domainProvider: @escaping @Sendable () -> FacadeRunDomain?) {
        self.domainProvider = domainProvider
    }

    public func isEventOperationLeaseValid(
        _ lease: PersonalizationEventOperationLease) async -> Bool {
        guard let domain = domainProvider() else { return false }
        return await domain.validatePersonalizationEventLease(lease)
    }
}

/// The REAL `RunIntelligencePostCommitFeeding` adapter to the qualified
/// memory/P8 processor (Main S3 decision 2026-10-20): each method AWAITS the
/// actual `FacadePersonalizationEvents` handler DIRECTLY inside the Run
/// domain's already-owned maintenance Task — no second detached Task, no
/// cancel-and-forget bridge, no timer — and passes the EXACT
/// `PersonalizationEventOperationLease` so the handler validates the same Run
/// lease before writing. The Run domain releases the lease only after this
/// method (and therefore the handler/write terminal) returns. Before binding
/// the events instance the adapter drops (no mutation) instead of inventing a
/// handler.
public struct RunPersonalizationFeedAdapter:
    RunIntelligencePostCommitFeeding, Sendable {
    private let eventsProvider: @Sendable () -> FacadePersonalizationEvents?

    public init(events: FacadePersonalizationEvents) {
        self.eventsProvider = { events }
    }

    public init(eventsProvider: @escaping @Sendable () -> FacadePersonalizationEvents?) {
        self.eventsProvider = eventsProvider
    }

    public func ordinaryUserMessageCommitted(_ event: RunIntelligenceEvent,
                                             feedToken: String) async {
        guard let events = eventsProvider() else { return }
        _ = await events.handleOrdinaryUserMessage(
            PersonalizationOrdinaryUserMessageEvent(
                messageID: event.messageID,
                conversationID: event.conversationID,
                rootEpoch: event.rootEpoch,
                temporaryAtStart: event.temporaryAtStart,
                temporaryAtCommit: event.temporaryAtCommit,
                operationLease: PersonalizationEventOperationLease(
                    token: feedToken,
                    conversationID: event.conversationID,
                    rootEpoch: event.rootEpoch)))
    }

    public func ordinaryRunCompleted(_ event: RunIntelligenceCompletionEvent,
                                      feedToken: String) async {
        guard let events = eventsProvider() else { return }
        _ = await events.handleOrdinaryRunCompleted(
            PersonalizationOrdinaryRunCompletedEvent(
                runID: event.runID,
                conversationID: event.conversationID,
                rootEpoch: event.rootEpoch,
                temporaryAtStart: event.temporaryAtStart,
                frozenTemporaryRun: event.frozenTemporaryRun,
                ordinarySurface: event.ordinarySurface,
                succeeded: event.succeeded,
                operationLease: PersonalizationEventOperationLease(
                    token: feedToken,
                    conversationID: event.conversationID,
                    rootEpoch: event.rootEpoch)))
    }
}

/// Composition binder for the REAL lifetime binding. Construction order is
/// genuinely cyclic — the events actor takes the Run-owned lease validator
/// while the Run domain takes the feed adapter — so the final graph:
///   1. creates this binder,
///   2. builds `FacadePersonalizationEvents(ownedLeases: binder.leaseValidator)`,
///   3. builds `RunDomainComponents(intelligenceFeed: binder.feed)`,
///   4. calls `binder.bind(domain:events:)`.
/// Until step 4 both sides fail CLOSED (validator false, feed drops) — never
/// a boolean-ready flag or a substitute bridge. This replaces (never reuses)
/// the rejected detached G02 feed bridge.
public final class RunPersonalizationFeedBinder: @unchecked Sendable {
    private let lock = NSLock()
    private var domain: FacadeRunDomain?
    private var events: FacadePersonalizationEvents?

    public init() {}

    private func withState<T>(_ body: (inout FacadeRunDomain?,
                                      inout FacadePersonalizationEvents?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&domain, &events)
    }

    public var leaseValidator: any PersonalizationEventOwnedLeaseProviding {
        RunPersonalizationLeaseValidator(domainProvider: { [weak self] in
            self?.withState { domain, _ in domain }
        })
    }

    public var feed: any RunIntelligencePostCommitFeeding {
        RunPersonalizationFeedAdapter(eventsProvider: { [weak self] in
            self?.withState { _, events in events }
        })
    }

    public func bind(domain: FacadeRunDomain, events: FacadePersonalizationEvents) {
        withState { currentDomain, currentEvents in
            currentDomain = domain
            currentEvents = events
        }
    }
}

// MARK: - Exact runtime configuration for one prepared service

extension FacadeRunDomain {
    /// Builds the ORIGINAL `FloeAgentRuntime.Configuration` for one run. The
    /// admitted `environmentID` is carried EXACTLY (nil only when the host
    /// requested none). `localLinuxGuestEnvironment` remains the actual
    /// resolved truth for this platform: G02 has no Linux-guest resolution,
    /// so it is false and never forced true. Temporary runs keep the frozen
    /// RAM-only/public-web-only narrowing.
    static func runtimeConfiguration(conversationID: UUID,
                                     provider: ProviderProfile,
                                     model: ModelProfile,
                                     mode: ConversationMode,
                                     ceiling: Set<String>?,
                                     toolsEnabled: Bool,
                                     temporary: Bool,
                                     environmentID: String?) -> FloeAgentRuntime.Configuration {
        FloeAgentRuntime.Configuration(
            conversationID: conversationID,
            provider: provider,
            model: model,
            conversationMode: mode,
            allowedToolNames: ceiling,
            toolsEnabled: toolsEnabled,
            ephemeralTransport: temporary,
            publicWebOnly: temporary,
            temporaryReadOnly: temporary,
            environmentID: environmentID,
            localLinuxGuestEnvironment: false)
    }
}

// MARK: - The real native service assembly (RUN-S1 repair)

extension FacadeRunDomain {

    /// G03-R3 FIRST-USE await (Main amendment FIRST_USE_HOST_OPERATION_CONTRACT
    /// v1). Trusted INTERNAL host work over the ORIGINAL `LinuxShellMailbox`
    /// (no new Core ABI, no model route, no parallel mailbox): operation
    /// `host.workspacePreflight` carries the REAL active run/conversation
    /// identity, the accepted root epoch and the admitted environment id
    /// (OMITTED when nil, never null). The host performs the NON-EXECUTING
    /// import/faithful-mirror export preflight on the ORIGINAL grant/lease
    /// authorities, ingests the real mapping + lease facts, calls
    /// `floe_linux_readiness_activate_registration`, and answers
    /// `{status: ready|unavailable|cancelled, rootEpoch, runID,
    ///  conversationID, workspaceIndexDigest?, leaseProofDigest?,
    ///  shellRegistered?, reason?}`.
    /// Core accepts `ready` ONLY after re-reading its OWN live state (mapping
    /// + lease derived true, `isCapabilityQualified` true, the exec.shell
    /// descriptor actually registered) — never from reply strings alone.
    /// Preconditions are the FIVE transport/rootfs/workload facts (mapping +
    /// lease are what preflight PRODUCES, so they must not gate it); with no
    /// configured/verified peer this returns instantly so ordinary non-Linux
    /// chat is never delayed, and temporary contexts never reach here.
    /// A claimed-but-unsettled request keeps its mailbox ticket owned (the
    /// existing expireWaiter discipline: timeout/cancellation never detaches
    /// claimed IO and never fabricates drain); every refusal, malformed or
    /// unverified outcome is INERT and RETAINED — the next ordinary run
    /// re-issues its own bounded request. No blind replay, no global cancel,
    /// no fake run, no first-project/temp-root guessing.
    func linuxWorkspaceFirstUsePreflight(runID: UUID, conversationID: UUID,
                                         environmentID: String?) async {
        let bindings = RuntimeFacadeLinuxBindings.shared
        guard bindings.components != nil,
              let epoch = LinuxReadinessIngress.liveAcceptedEpoch(),
              bindings.boundNativeEpoch == epoch else { return }
        let before = LinuxReadinessIngress.shared.derivedFields()
        guard before.runtimeUidBoundaryVerified, before.engineConnected,
              before.mailboxEpochBound, before.rootfsQualified,
              before.singleWorkloadContractAcknowledged else { return }
        if before.workspaceMappingSynced && before.leaseAuthorityQualified { return }
        var request: [String: Any] = [
            "runID": runID.uuidString,
            "conversationID": conversationID.uuidString,
            "rootEpoch": epoch,
        ]
        if let environmentID, !environmentID.isEmpty {
            request["environmentID"] = environmentID
        }
        guard JSONSerialization.isValidJSONObject(request),
              let payload = try? JSONSerialization.data(withJSONObject: request,
                                                        options: [.sortedKeys]) else { return }
        let reply: Data
        do {
            reply = try await LinuxShellMailbox.shared.submit(
                operation: "host.workspacePreflight", payload: payload,
                timeoutMillis: LinuxShellMailboxLimits.startBudgetMillis)
        } catch {
            return // notBound/hostFenced/budget/cancelled: ticket retained, unqualified
        }
        guard reply.count <= LinuxShellMailboxLimits.maximumFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              (object["status"] as? String) == "ready",
              (object["rootEpoch"] as? NSNumber)?.uint64Value == epoch,
              (object["runID"] as? String) == runID.uuidString,
              (object["conversationID"] as? String) == conversationID.uuidString,
              let indexDigest = object["workspaceIndexDigest"] as? String,
              indexDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let leaseDigest = object["leaseProofDigest"] as? String,
              leaseDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (object["shellRegistered"] as? Bool) == true else {
            return // unavailable / cancelled / malformed: inert, retained
        }
        // NO echo success: verify Core's OWN live qualification + registration.
        let after = LinuxReadinessIngress.shared.derivedFields()
        guard after.workspaceMappingSynced, after.leaseAuthorityQualified,
              bindings.isCapabilityQualified,
              ToolRunnerRegistry.shared.descriptor(named: "exec.shell") != nil else {
            return
        }
    }

    /// Constructs the ORIGINAL `ConversationRunService` for one prepared
    /// run. Every store argument comes from the run's IMMUTABLE operational
    /// bundle (ordinary = the owner durable bundle; temporary = RB5's
    /// ephemeral bundle) — the ordinary store singleton is NEVER a fallback
    /// for a supplied temporary bundle, and no second DB/schema/execution
    /// mode exists. Throws typed `RunDomainError` only; every failure lands
    /// before the durable C1 window closes so an abandoned launch is marked
    /// through the ORIGINAL run-store state CAS by the caller.
    func makeService(
        runID: UUID,
        conversationID: UUID,
        goal: String,
        mode: ConversationMode,
        launch: RunModelAssembly.ResolvedPair,
        history: [ConversationMessage],
        images: [ConversationImagePart],
        bundle: RunPersistenceBundle,
        draftPolicy: DraftTaskPolicy?,
        gate: CatastrophicActionGate?,
        workspaceName: String?,
        hostToolCeiling: [String]?,
        environmentID: String?,
        notes: NotesRunBinding? = nil
    ) async throws -> ConversationRunService {
        let temporary = bundle.identity == .temporary
        let isNotes = bundle.identity == .notes
        if isNotes, notes == nil {
            // A Notes bundle without its exact document binding can never be
            // assembled: there would be no scoped tools and no document
            // authority.
            throw RunDomainError(.needsConfiguration, .notesRuntimeUnbound)
        }
        // G06 Notes: the ONLY tool surface for this run. The registry is
        // isolated (never `.shared`), so ordinary discovery/execution can
        // neither see nor run these tools.
        // The port supplies the closed tool registry + document policy. An
        // unbound port at this point means the composition is inconsistent
        // (startNotes already proved it), so the run refuses rather than
        // running behind the ordinary ceiling.
        var notesRegistry: ToolRunnerRegistry?
        if let notes {
            guard let provider = components.notesRuntime else {
                throw RunDomainError(.needsConfiguration, .notesRuntimeUnbound)
            }
            guard provider.closedToolNames == NotesAssistantToolNames.closed else {
                throw RunDomainError(.capabilityNotUsable, .notesRuntimeUnbound)
            }
            notesRegistry = provider.makeToolRegistry(
                epoch: epoch, binding: notes, runID: runID,
                environmentID: environmentID)
        }
        let toolAssembly = notesRegistry.map { RunToolAssembly(registry: $0) } ?? tools
        // G03-R3 FIRST-USE boundary: the ORDINARY run awaits the trusted host
        // workspace preflight BEFORE the configuration, tool-ceiling and
        // service snapshots below, so ordinary route discovery reads the REAL
        // post-preflight qualification state instead of racing the App
        // `prepared` effect (Main amendment FIRST_USE_HOST_OPERATION_CONTRACT
        // v1). Temporary sessions skip entirely (frozen RAM-only public-web
        // ceiling); an unconfigured peer or an already qualified mapping+lease
        // pair returns instantly, so non-Linux chat is never delayed and a
        // refused/unsettled preflight simply keeps this run's Linux discovery
        // honestly unqualified — never a failed run, never assumed success.
        if !temporary, !isNotes {
            await linuxWorkspaceFirstUsePreflight(runID: runID,
                                                  conversationID: conversationID,
                                                  environmentID: environmentID)
        }
        // The persisted task policy row was committed by the ORIGINAL
        // prepare (or an earlier turn); the service policy is rebuilt from
        // THAT truth, never from envelope/model text. A TEMPORARY session
        // owns NO durable rows (RB5 RAM-only contract): its policy value is
        // synthesized in-RAM from the launch draft — the durable workspace
        // store is never read for a temporary identity (that would be a
        // durable fallback read the frozen session cannot satisfy).
        let taskPolicy: TaskPolicy
        if temporary {
            let draft = draftPolicy ?? DraftTaskPolicy()
            taskPolicy = TaskPolicy(
                conversationID: conversationID,
                approvalMode: draft.approvalMode.rawValue,
                recoveryPolicy: draft.recoveryPolicy,
                notificationPolicy: draft.notificationPolicy)
        } else {
            do {
                taskPolicy = try await components.workspaceStore.taskPolicy(
                    conversationID: conversationID)
            } catch {
                throw RunDomainError(.persistenceUnavailable, .storeReadFailed)
            }
        }
        // The exact per-run tool ceiling: persisted policy ∩ host ceiling
        // ∩ compiled/availability projection, plan-narrowed by the ORIGINAL
        // PlanToolPolicy, temporary-narrowed by the frozen public-web
        // allowlist (RunToolAssembly owns the intersection; the runtime
        // STILL re-validates every main/child call for temporary runs).
        let modeRaw = RunLaunchMode(rawValue: mode.rawValue) ?? .chat
        let ceiling = toolAssembly.allowedToolNames(
            taskPolicy: taskPolicy,
            hostCeiling: hostToolCeiling,
            mode: modeRaw,
            temporary: temporary)
        let toolsEnabled = ceiling.map { !$0.isEmpty } ?? true
        // The ORIGINAL provider adapter: the host/test factory override when
        // injected, otherwise the ORIGINAL ProviderAdapterFactory coverage
        // of every cloud wire protocol (no parallel adapter path).
        let adapter = runAdapter(for: launch.provider)
        // Required-auth secrets resolve through the registered gateway; the
        // bytes stay inside this path and never cross JNI/JSON/logs.
        let credentials: ProviderCredentials
        do {
            credentials = try await ingress.credentials(for: launch.provider)
        } catch let error as RunDomainError {
            throw error
        } catch {
            throw RunDomainError(.credentialUnavailable, .secretInvalidated)
        }
        // The ORIGINAL policy family for the persisted task policy. The
        // service wraps it in the ORIGINAL DynamicApprovalPolicy, so
        // `run.policy.update` mutates the SAME live service policy.
        let policy: any ApprovalPolicy
        if let notes, let provider = components.notesRuntime {
            // Document-assistant policy: the exact live Notes read/edit grant
            // decides the three closed tools deterministically; everything
            // else (which cannot appear under the closed ceiling) keeps the
            // ordinary human policy. Never a model-authored approval.
            policy = DynamicApprovalPolicy(provider.approvalPolicy(
                epoch: epoch, binding: notes, runID: runID,
                environmentID: environmentID))
        } else {
            policy = try await assembly.approvalPolicy(for: taskPolicy,
                                                       primaryModel: launch.model)
        }
        // The vault-backed credential-argument normalizer bound BEFORE any
        // tool argument reaches approval/audit/persistence/execution. nil
        // ONLY for a temporary run (the ORIGINAL RAM-only contract — raw
        // arguments stay in RAM through the public-web ceiling); an
        // ordinary run can never reach this point with an unbound
        // normalizer (admission refuses pre-effect).
        let normalizer: (@Sendable (ToolCall) async throws -> ToolCall)?
        if temporary {
            normalizer = nil
        } else {
            guard let credentialNormalizer = components.credentialNormalizer else {
                throw RunDomainError(.needsConfiguration, .normalizerUnbound)
            }
            let owner = RunCredentialOwner(scope: .conversation(conversationID))
            normalizer = { call in
                try await credentialNormalizer.normalized(call: call, runOwner: owner)
            }
        }
        // Frozen execution identity of this run and its delegated children.
        // The ADMITTED environment identity (proven before any effect) is an
        // immutable part of this service — never dropped. `localLinuxGuest`
        // stays the ACTUAL resolved truth: G02 resolves NO Linux guest, so it
        // is false; the ORIGINAL runtime child-binding guard still runs from
        // the bound id (AgentRuntime.swift:3336-3351).
        var configuration = Self.runtimeConfiguration(
            conversationID: conversationID,
            provider: launch.provider,
            model: launch.model,
            mode: mode,
            ceiling: ceiling,
            toolsEnabled: toolsEnabled,
            temporary: temporary,
            environmentID: environmentID)
        if !temporary, !isNotes {
            // Original persisted conversation/workspace ownership selects this
            // root. No App-root, first-project or temporary-directory fallback.
            // A Notes run is chat-only: it gets no Linux workspace root and no
            // job dependency probe (no Linux/environment/job role).
            configuration.workspaceRootURL = await LinuxWorkspaceAuthority.trustedWorkspaceRoot(
                runID: runID, conversationID: conversationID)
            // PRoot is not a VM; retain the conservative approval class.
            configuration.outstandingDependencies = {
                await RuntimeFacadeJobBindings.shared.outstandingRunDependencies(runID: runID)
            }
        }
        if !temporary, !isNotes, let checklist = bundle.taskChecklist {
            // Same original provider used by iOS. Temporary runs never
            // receive a durable checklist or inherit one from the owner.
            configuration.planChecklistProvider = {
                try? await checklist.latest(conversationID: conversationID)
            }
        }
        // The ORIGINAL executor over the run-scoped registry; availability
        // and descriptor authority stay the registry's truth.
        let executor = CatalogToolExecutor(runners: notesRegistry ?? components.registry)
        // Temporary runs never write recovery checkpoints or intelligence /
        // discovery rows (RAM-only retention; goal mode already refused at
        // admission without an intelligence store). Ordinary runs use the
        // generation's reviewed checkpoint store and the bundle's own
        // intelligence/discovery stores.
        let checkpointStore: (any CheckpointStore)? =
            (temporary || isNotes) ? nil : components.checkpoints
        let intelligenceStore = (temporary || isNotes) ? nil : bundle.intelligence
        let discoveryStore = (temporary || isNotes) ? nil : bundle.discovery
        let personalizationProvider =
            (temporary || isNotes) ? nil : components.personalizationProvider
        let service = ConversationRunService(
            configuration: configuration,
            adapter: adapter,
            policy: policy,
            executor: executor,
            credentials: credentials,
            gate: temporary ? nil : gate,
            checkpointStore: checkpointStore,
            contextEngine: HybridContextEngine(),
            toolCallNormalizer: normalizer,
            intelligenceStore: intelligenceStore,
            discoveryStore: discoveryStore,
            conversationStore: bundle.conversations,
            runStore: bundle.runs,
            runningInputStore: bundle.runningInputs,
            runID: runID,
            conversationHistory: history,
            currentUserImages: images,
            runContext: ConversationRunService.RunContext(
                // A Notes run receives the app-generated navigation context as
                // skill instructions (data + workflow guidance; it grants
                // nothing) and nothing else: no workspace, plan, goal, memory,
                // profile, listing or project instructions.
                workspaceName: (temporary || isNotes) ? nil : workspaceName,
                availableToolNames: ceiling,
                skillInstructions: isNotes ? notes?.contextText : nil),
            personalizationProvider: personalizationProvider,
            resourceAccessCleanup: nil,
            artifactRootURL: components.artifactRootURL)
        // The REAL per-run delegate/subagent wiring: the ORIGINAL
        // registerDelegateTool + SubagentRunner bound to this exact runID
        // (DelegateTool.swift:209-217 + SubagentRunner.swift:186-198). The
        // durable child store rides the SAME bundle; the state-change hook
        // feeds the facade's existing child accounting path (exact-token
        // attach/detach + durable cross-check) — observation only, never a
        // permission channel. Retired ONLY at the real terminal via
        // `tools.retireDelegate(runID:)` in `retire`.
        let childStore: (any ChildRunStoring)? = (temporary || isNotes) ? nil : bundle.childRuns
        let runner = SubagentRunner(
            provider: launch.provider,
            model: launch.model,
            adapter: adapter,
            credentials: credentials,
            executor: executor,
            childRunStore: childStore,
            onChildStateChange: { [weak self] snapshot in
                guard let self else { return }
                await self.handleTracked(event: .childRunChanged(snapshot),
                                         runID: runID)
            })
        if !isNotes {
            // A Notes run never delegates: its ceiling has no delegate tool and
            // its bundle has no child store. Registering the delegate runner
            // would also add its descriptor to the isolated registry.
            await tools.registerDelegate(runner: runner, for: runID)
        }
        return service
    }
}

// MARK: - Owned tool/child exact-token accounting (RUN-S1 repair)

extension FacadeRunDomain {
    /// Attaches the `.tool` exact token for one live provider call. Called
    /// at the REAL toolLifecycle .requested/.started boundary; the token
    /// detaches ONLY at the matching .finished (or run retirement after the
    /// final writes). Registry saturation degrades conservatively
    /// (`degradedToolAccounting`) so a later delete drain never
    /// under-counts quiescence.
    func attachTool(runID: UUID, callID: String) {
        guard var ownership = owners[runID], ownership.epoch == epoch else { return }
        let key = RuntimeOwnedWorkKind.tool.rawValue + ":" + callID
        guard ownership.ownedTokens[key] == nil else { return }
        switch RuntimeOwnedWorkRegistry.shared.attach(
            epoch: epoch, kind: .tool,
            ownerID: runID.uuidString + ":tool:" + callID) {
        case .attached(let token):
            ownership.ownedTokens[key] = token
            register(ownership)
            recordDrainEvidence(conversationID: ownership.conversationID, token: token)
        case .rejected, .invalidIdentity:
            ownership.degradedToolAccounting = true
            register(ownership)
        }
    }

    /// Detaches the `.tool` exact token at the REAL .finished boundary.
    /// A late/duplicate finish for an unknown call is a no-op, never a
    /// resurrection.
    func detachTool(runID: UUID, callID: String) {
        guard var ownership = owners[runID] else { return }
        let key = RuntimeOwnedWorkKind.tool.rawValue + ":" + callID
        guard let token = ownership.ownedTokens.removeValue(forKey: key) else { return }
        RuntimeOwnedWorkRegistry.shared.detach(token)
        register(ownership)
    }

    /// Attaches the `.childRun` exact token when the durable/live graph
    /// first shows a child non-terminal; also tracks it in
    /// `pendingChildRunIDs` for the drain report.
    func attachChild(runID: UUID, childRunID: UUID) {
        guard var ownership = owners[runID], ownership.epoch == epoch else { return }
        let key = RuntimeOwnedWorkKind.childRun.rawValue + ":" + childRunID.uuidString
        guard ownership.ownedTokens[key] == nil else { return }
        switch RuntimeOwnedWorkRegistry.shared.attach(
            epoch: epoch, kind: .childRun, ownerID: childRunID.uuidString) {
        case .attached(let token):
            ownership.ownedTokens[key] = token
            ownership.pendingChildRunIDs.insert(childRunID)
            register(ownership)
            recordDrainEvidence(conversationID: ownership.conversationID, token: token)
        case .rejected, .invalidIdentity:
            ownership.degradedToolAccounting = true
            register(ownership)
        }
    }

    /// Detaches the `.childRun` exact token at the child's durable/live
    /// terminal; the child leaves the pending set exactly once.
    func detachChild(runID: UUID, childRunID: UUID) {
        guard var ownership = owners[runID] else { return }
        let key = RuntimeOwnedWorkKind.childRun.rawValue + ":" + childRunID.uuidString
        ownership.pendingChildRunIDs.remove(childRunID)
        guard let token = ownership.ownedTokens.removeValue(forKey: key) else {
            register(ownership)
            return
        }
        RuntimeOwnedWorkRegistry.shared.detach(token)
        register(ownership)
    }
}

// MARK: - Owned P8 maintenance feed dispatch (RUN-S3 repair)

extension FacadeRunDomain {
    /// The exact source identity of one feed delivery: the stable durable
    /// identity (message id for the user-message commit, run id for the
    /// terminal truth) — never a per-message retained set, never a replay
    /// counter.
    enum FeedDelivery: Sendable {
        case userMessage(RunIntelligenceEvent)
        case terminal(RunIntelligenceCompletionEvent)

        var tag: String {
            switch self {
            case .userMessage(let event):
                return "msg-" + event.messageID.uuidString
            case .terminal(let event):
                return "term-" + event.runID.uuidString
            }
        }

        var conversationID: UUID {
            switch self {
            case .userMessage(let event): return event.conversationID
            case .terminal(let event): return event.conversationID
            }
        }

        var isTerminal: Bool {
            if case .terminal = self { return true }
            return false
        }
    }

    /// ACQUIRE-then-deliver, made structural (Main P8 correction): the
    /// owned-root registry attach runs UNDER THE CURRENT EPOCH at the call
    /// site — BEFORE this function returns and therefore before any feed
    /// await — and the per-conversation lease map entry + drain evidence
    /// land in the SAME actor step, so the delete drain / root retirement
    /// see the exact token from the moment the launch pipeline dispatches.
    /// Fenced states refuse the FEED (typed counters), never fake a
    /// delivery; a feed NEVER fires from a temporary identity (callers gate
    /// on `bundle.identity` before dispatching).
    func acquireFeedLease(conversationID: UUID, tag: String)
        -> RuntimeOwnedWorkToken? {
        guard !retirementFenced, globalFence == nil,
              deleteGuards[conversationID] == nil else {
            feedStats.fenceSkipped += 1
            return nil
        }
        let ownerID = conversationID.uuidString + ":p8:" + tag
        switch RuntimeOwnedWorkRegistry.shared.attach(epoch: epoch, kind: .conversation,
                                                      ownerID: ownerID) {
        case .attached(let token):
            feedLeases[conversationID, default: [:]][token.receipt] = token
            recordFeedEvidence(conversationID: conversationID, token: token)
            return token
        case .rejected, .invalidIdentity:
            feedStats.saturatedSkipped += 1
            return nil
        }
    }

    /// Releases the lease after the handler REALLY returned (or was
    /// refused). Drains keep waiting on the map entry until this runs.
    func releaseFeedLease(conversationID: UUID, token: RuntimeOwnedWorkToken) {
        RuntimeOwnedWorkRegistry.shared.detach(token)
        feedLeases[conversationID]?.removeValue(forKey: token.receipt)
        if feedLeases[conversationID]?.isEmpty == true {
            feedLeases[conversationID] = nil
        }
        feedStats.delivered += 1
        feedDeliveredObserved[conversationID, default: 0] += 1
    }

    /// Dispatches ONE real owned maintenance Task for a committed-source
    /// feed. The launch/retire path is NEVER blocked on the handler: the
    /// ordinary chat/terminal proceeds while a stalled source-index /
    /// organize / generation feed holds only its exact lease — which the
    /// per-conversation delete drain and the root shutdown wait for. No
    /// timeout detach, no unowned Task, exactly-once per stable source
    /// identity (the caller's flag/set guards duplication).
    func dispatchIntelligenceFeed(runID: UUID, _ delivery: FeedDelivery) {
        guard let feed = components.intelligenceFeed else { return }
        let conversationID = delivery.conversationID
        guard let token = acquireFeedLease(conversationID: conversationID,
                                           tag: delivery.tag) else { return }
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            switch delivery {
            case .userMessage(let event):
                await feed.ordinaryUserMessageCommitted(event, feedToken: token.receipt)
            case .terminal(let event):
                await feed.ordinaryRunCompleted(event, feedToken: token.receipt)
            }
            await self.feedTaskFinished(runID: runID, taskID: taskID,
                                        conversationID: conversationID,
                                        token: token,
                                        terminal: delivery.isTerminal,
                                        tag: delivery.tag)
        }
        feedMaintenanceTasks[runID, default: [:]][taskID] = task
    }

    /// Completion bookkeeping for one feed Task: release the exact lease,
    /// drop the Task handle, prune terminal exactly-once state and bound
    /// the evidence windows once the trusted terminal settled and no delete
    /// guard needs the drain proof.
    private func feedTaskFinished(runID: UUID, taskID: UUID, conversationID: UUID,
                                  token: RuntimeOwnedWorkToken, terminal: Bool,
                                  tag: String) {
        releaseFeedLease(conversationID: conversationID, token: token)
        feedMaintenanceTasks[runID]?.removeValue(forKey: taskID)
        if feedMaintenanceTasks[runID]?.isEmpty == true {
            feedMaintenanceTasks[runID] = nil
        }
        if terminal {
            // The trusted terminal for this run is fed; its exactly-once
            // guard entry can go. Sibling runs of the same conversation
            // carry their own identities.
            feedTerminalsDone.remove(runID)
        }
        pruneFeedBookkeeping(conversationID: conversationID)
        _ = tag
    }

    /// Bounded live bookkeeping (Main RUN-S3 correction): evidence arrays
    /// keep only the most recent window per conversation and the delivered
    /// observation counter is reset at the trusted terminal — while a
    /// delete guard is open the proof is PRESERVED untouched (the drain
    /// cross-checks exact tokens live, so nothing here may erase its
    /// window). No unbounded per-completed-run or every-message retention.
    private func pruneFeedBookkeeping(conversationID: UUID) {
        guard deleteGuards[conversationID] == nil else { return }
        let bound = Self.feedEvidenceWindowBound
        if let evidence = feedEvidence[conversationID], evidence.count > bound {
            feedEvidence[conversationID] = Array(evidence.suffix(bound))
        }
        if let evidence = drainEvidence[conversationID], evidence.count > bound {
            drainEvidence[conversationID] = Array(evidence.suffix(bound))
        }
        feedDeliveredObserved[conversationID] = nil
    }

    /// Per-conversation retained evidence window (live/fence bookkeeping
    /// bound; the durable thread and registry remain the authorities).
    static let feedEvidenceWindowBound = 64
}
