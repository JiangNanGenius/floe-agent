// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — real service constructors for the ORDINARY
// base service graph, all retained by the ONE accepted generation and ALL
// receiving the SAME original DatabaseManager through `G02OwnedStoreCluster`.
//
// Ordinary-base construction order (MAIN_PRODUCT_FIRST_EXECUTION_DECISION_
// 20261020): the temporary and privacy domain packages are NOT yet
// integrated; they bind later through the explicit `G02DomainExtension`
// seam and never gate this ordinary graph:
//   1. RB2  model/provider configuration facade (+ shared save coordinator)
//   2. RB2b credential vault joins runtime ownership (single durable view)
//   3. RB3b memory/personalization services (own the P8 handlers; the REAL
//      Run-qualified `RunPersonalizationFeedBinder` closes the cyclic
//      feed/lease graph — the rejected detached G02IntelligenceFeedBridge
//      is gone)
//   4. RB6  skills/MCP/capability domains with the REAL accepted cloud
//      skill-rewrite adapter and public-hub transport factories when
//      configured (never the unavailable-rewriter stand-in)
//   5. attachment staging service (run lease producer + wire commands)
//   6. RB4  run domain (self-installs; consumes 2/3/4/5 ports)
//   7. RB3  conversation history domain (consumes the RB4 deletion lifecycle)
//   8. settings defaults / usage adapters
//
// Handler registration installs the async mailbox processors and the
// synchronous binder submit handlers for every non-self-installing ORDINARY
// command in the frozen 87/19 matrix (goal-core batch appended three); self-installing domains (RB4 runs,
// attachment staging) register their own keys. Temporary/privacy keys stay
// unregistered until their real extension binds — the frozen fail-closed
// `runtimeUnavailable` refusal answers them (no matrix widening).
import Foundation
import GRDB
import FloePersistence
import FloeAgentRuntime
import FloeModels
import FloeProviders
import FloeAndroidWebTools

/// One generation's installed G02 ordinary service graph. Immutable after
/// build (except the truthful transport-admission propagation); retired as a
/// unit by `G02RuntimeComposition.beginRetirement`.
public final class G02InstalledComposition: @unchecked Sendable {

    public let epoch: UInt64
    public let cluster: G02OwnedStoreCluster

    // RB2 model/provider configuration.
    public let modelConfigurationFacade: ModelConfigurationFacade
    public let modelConfigurationRouter: ModelConfigurationCommandRouter
    public let credentialResolver: RunCredentialResolver

    // RB2b credential vault (joined; owns the durable V11 deletion queue).
    public let vault: AndroidCredentialVault
    /// The vault's accepted runtime epoch captured at build time (plain
    /// value: the vault actor is not reachable from synchronous readiness).
    public let vaultEpoch: UInt64

    // RB3b memory / personalization.
    public let intelligenceStore: SQLiteIntelligenceStore
    public let personalizationService: PersonalizationService
    public let memoryAdapter: FacadeMemoryAdapter
    public let memoryOrganizer: FacadeMemoryOrganizer
    public let personalizationAdapter: FacadePersonalizationAdapter
    public let personalizationGenerate: FacadePersonalizationGenerate
    public let memoryContentReader: RuntimeFacadeContentReader
    public let personalizationEvents: FacadePersonalizationEvents

    // RB6 skills / MCP / capabilities.
    public let toolWorkCoordinator: FacadeToolWorkCoordinator
    public let skillsDomain: SkillsDomain
    public let mcpDomain: MCPDomain
    public let capabilitiesDomain: CapabilitiesDomain
    public let skillsRouter: SkillsCommandRouter
    public let mcpRouter: MCPCommandRouter
    public let capabilitiesRouter: CapabilitiesCommandRouter

    // RB4 run domain components (the facade self-installs; the components
    // stay retained here for readiness, the truthful transport-admission
    // propagation and later extension ports).
    public internal(set) var runComponents: RunDomainComponents

    // Attachment staging (producer for the RB4 lease consumer).
    public let stagingService: AttachmentStagingService

    // RB3 conversation history.
    public let conversationDomain: FacadeConversationDomain

    // Settings defaults / usage.
    public let defaultsAdapter: FacadeSettingsDefaultsAdapter
    public let usageAdapter: FacadeUsageAdapter

    /// The REAL Run-qualified P8 feed/lease binder (replaces the rejected
    /// frozen G02IntelligenceFeedBridge). Retained for lifetime; privacy
    /// event-drop reuses its lease surface through a later extension.
    public let feedBinder: RunPersonalizationFeedBinder

    /// G07.3B: the ONE epoch-owned scheduled-task service over the durable
    /// `task_schedules`/`task_schedule_occurrences` ledger. Main's command
    /// table binds `G073TaskScheduleBindings` against this same instance.
    public let taskSchedules: G073TaskScheduleService

    /// Optional-domain extensions that attached successfully for this
    /// epoch (temporary, privacy successors). Empty in the ordinary product.
    internal var attachedExtensions: [G02DomainExtensionID: any G02DomainExtension] = [:]

    /// Every handler key this composition registered (for retirement).
    public internal(set) var registeredHandlerKeys: [String] = []

    /// The generation's domain registry (real processors; diagnostics).
    public let registry: RuntimeDomainRegistry

    /// Same-original-database identity evidence captured at build time:
    /// every domain's database object identifier must equal the cluster's.
    public private(set) var databaseIdentifiers: [String: ObjectIdentifier] = [:]

    init(epoch: UInt64, cluster: G02OwnedStoreCluster,
         registry: RuntimeDomainRegistry,
         modelConfigurationFacade: ModelConfigurationFacade,
         modelConfigurationRouter: ModelConfigurationCommandRouter,
         credentialResolver: RunCredentialResolver,
         vault: AndroidCredentialVault,
         vaultEpoch: UInt64,
         intelligenceStore: SQLiteIntelligenceStore,
         personalizationService: PersonalizationService,
         memoryAdapter: FacadeMemoryAdapter,
         memoryOrganizer: FacadeMemoryOrganizer,
         personalizationAdapter: FacadePersonalizationAdapter,
         personalizationGenerate: FacadePersonalizationGenerate,
         memoryContentReader: RuntimeFacadeContentReader,
         personalizationEvents: FacadePersonalizationEvents,
         toolWorkCoordinator: FacadeToolWorkCoordinator,
         skillsDomain: SkillsDomain,
         mcpDomain: MCPDomain,
         capabilitiesDomain: CapabilitiesDomain,
         skillsRouter: SkillsCommandRouter,
         mcpRouter: MCPCommandRouter,
         capabilitiesRouter: CapabilitiesCommandRouter,
         runComponents: RunDomainComponents,
         stagingService: AttachmentStagingService,
         conversationDomain: FacadeConversationDomain,
         defaultsAdapter: FacadeSettingsDefaultsAdapter,
         usageAdapter: FacadeUsageAdapter,
         feedBinder: RunPersonalizationFeedBinder,
         taskSchedules: G073TaskScheduleService) {
        self.epoch = epoch
        self.cluster = cluster
        self.registry = registry
        self.modelConfigurationFacade = modelConfigurationFacade
        self.modelConfigurationRouter = modelConfigurationRouter
        self.credentialResolver = credentialResolver
        self.vault = vault
        self.vaultEpoch = vaultEpoch
        self.intelligenceStore = intelligenceStore
        self.personalizationService = personalizationService
        self.memoryAdapter = memoryAdapter
        self.memoryOrganizer = memoryOrganizer
        self.personalizationAdapter = personalizationAdapter
        self.personalizationGenerate = personalizationGenerate
        self.memoryContentReader = memoryContentReader
        self.personalizationEvents = personalizationEvents
        self.toolWorkCoordinator = toolWorkCoordinator
        self.skillsDomain = skillsDomain
        self.mcpDomain = mcpDomain
        self.capabilitiesDomain = capabilitiesDomain
        self.skillsRouter = skillsRouter
        self.mcpRouter = mcpRouter
        self.capabilitiesRouter = capabilitiesRouter
        self.runComponents = runComponents
        self.stagingService = stagingService
        self.conversationDomain = conversationDomain
        self.defaultsAdapter = defaultsAdapter
        self.usageAdapter = usageAdapter
        self.feedBinder = feedBinder
        self.taskSchedules = taskSchedules
    }

    // MARK: - Build

    /// Constructs the ordinary graph over the owned cluster. Every domain
    /// constructor receives stores from `cluster` — one DatabaseManager.
    /// Returns nil on a real constructor refusal (vault join / skills init):
    /// the caller rolls back any self-installed lane and installs nothing.
    static func build(gen: AndroidRuntimeBootstrap.Generation,
                      cluster: G02OwnedStoreCluster,
                      transportGate: G02QualifiedTransportGate,
                      routeContext: G02HostRouteContextProvider,
                      catalogBytes: Data?) async -> G02InstalledComposition? {
        let epoch = gen.epoch
        let database = cluster.database
        let rootURL = URL(fileURLWithPath: cluster.identity.root.path)
        guard BackgroundJobOutputSpoolRoot.bind(
            root: rootURL.appendingPathComponent("Floe/JobOutputs", isDirectory: true), epoch: epoch
        ) else { return nil }

        // 1. RB2 model/provider configuration facade. Every port receives
        //    the REAL shared coordinator/registry/epoch/sink — never nil to
        //    compile. First-provider save readiness is this domain's own
        //    typed state, distinct from an ordinary usable configured model.
        let credentialResolver = RunCredentialResolver()
        let configFacade = ModelConfigurationFacade(
            database: database,
            gateway: SecretGatewayRegistry.shared,
            catalogBytes: catalogBytes,
            transportAdmission: transportGate,
            routeContext: routeContext,
            adapters: OriginalProviderAdapterFactory(),
            ownership: ProviderOperationCoordinatorRegistry.shared
                .coordinator(for: database),
            epochProvider: G02CompositionEpochProvider(),
            ownedWorkRegistry: RuntimeOwnedWorkRegistry.shared,
            effectSink: G02ConfigEffectSink(effects: gen.effects))
        let configRouter = ModelConfigurationCommandRouter(facade: configFacade)

        // 2. RB2b vault joins runtime ownership: the SAME database + the
        //    exact accepted identity. `vault.records` is the graph's single
        //    durable credential-store view for later reuse.
        guard let vault = try? AndroidCredentialVault.joinRuntimeOwnership(
            database: database,
            identity: cluster.identity,
            ownedWork: RuntimeOwnedWorkRegistryAttachment.shared,
            gateway: SecretGatewayRegistryForwarder())
        else {
            // Vault join failed (identity/DB drift): honest fail-closed, the
            // composition installs nothing and readiness stays blocked.
            return nil
        }

        // 3. RB3b memory / personalization over the SAME database. The REAL
        //    Run-qualified feed binder closes the cyclic graph:
        //    events take binder.leaseValidator; run components take
        //    binder.feed; both sides fail closed until `bind` below.
        let intelligence = SQLiteIntelligenceStore(database: database)
        let personalizationStore = SQLitePersonalizationStore(database: database)
        let personalizationService = PersonalizationService(
            documents: personalizationStore, memories: intelligence)
        let workspace = cluster.workspaceStore
        let conversations = cluster.conversationStore
        let memoryAdapter = FacadeMemoryAdapter(
            database: database, intelligenceStore: intelligence,
            workspaceStore: workspace, conversationStore: conversations)
        let routeProvider = G02PersonalizationRouteProvider(
            configurationStore: cluster.modelConfigurationStore,
            credentials: credentialResolver)
        let semanticProvider = FacadeSemanticMemoryOrganizer(route: routeProvider)
        let memoryOrganizer = FacadeMemoryOrganizer(
            database: database, intelligenceStore: intelligence,
            semanticProvider: semanticProvider)
        let personalizationContentStore = FacadePersonalizationContentStore(
            port: G02PersonalizationContentPort(content: gen.content))
        let personalizationAdapter = FacadePersonalizationAdapter(
            database: database, workspaceStore: workspace,
            contentStore: personalizationContentStore)
        let personalizationGenerate = FacadePersonalizationGenerate(
            database: database, workspaceStore: workspace, route: routeProvider)
        let feedBinder = RunPersonalizationFeedBinder()
        let personalizationEvents = FacadePersonalizationEvents(
            database: database,
            personalizationService: personalizationService,
            generate: personalizationGenerate,
            memoryAdapter: memoryAdapter,
            fences: G02PersonalizationFenceProvider(),
            ownedLeases: feedBinder.leaseValidator)

        // 4. RB6 skills / MCP / capabilities. Transport stays fail-closed
        //    until the qualified gate flips; stdio/SSH remain PendingEnv
        //    (G03). The rewriter binds the REAL accepted cloud skill-rewrite
        //    adapter factory (configured providers rewrite; unconfigured
        //    stays typed-unavailable inside the adapter — never the
        //    unavailable-rewriter stand-in) and the public-hub transport
        //    factory owns ONE shared HTTP service (single-session doctrine).
        let toolWork = FacadeToolWorkCoordinator()
        // Linux transport is composed over the same owned-work coordinator.
        // A missing ToolContext workspace never falls back to the App root.
        // Actual UID/rootfs/workspace qualification controls advertisement;
        // installation or source presence does not enable exec.shell.
        let workspaceAuthorityInstalled = LinuxWorkspaceAuthority.install(storageRoot: cluster.identity.root)
        // G03-R3: the frozen-false compiled seam is REPLACED by the trusted
        // live readiness authority. Still fails closed: nothing is qualified
        // until the host ingests every real fact for THIS generation (and
        // workspaceAuthorityInstalled gates the transfer half). The same
        // authority answers dispatch AND route discovery.
        _ = workspaceAuthorityInstalled
        RuntimeFacadeLinuxBindings.shared.compose(
            coordinator: toolWork,
            rootProvider: { nil },
            readiness: LinuxShellLiveReadiness.makeInjected())
        if let shell = RuntimeFacadeLinuxBindings.shared.components,
           let spool = BackgroundJobOutputSpoolRoot.url() {
            let owner = G03JobLifecycle(epoch: epoch)
            guard RuntimeFacadeJobBindings.shared.compose(database: database, shell: shell,
                transport: MailboxLinuxShellTransport(), settlementGate: LinuxShellJobSettlement.gate,
                outputRootURL: spool, onTerminal: { await owner.terminal($0) }, processorOwnership: owner),
                let jobs = RuntimeFacadeJobBindings.shared.register() else { return nil }
            owner.bind(jobs)
            G03JobLifecycle.install(owner)
            do { _ = try await RuntimeFacadeJobBindings.shared.reconcileInterruptedOnLaunch() }
            catch { return nil }
        }
        let ownedWorkLifecycle = ConfigOwnedWorkLifecycle(
            registry: RuntimeOwnedWorkRegistry.shared,
            epochProvider: G02CompositionEpochProvider())
        let hostContext = G02SkillsHostContextProvider(
            rootFingerprint: cluster.identity.root.fingerprint)
        // A real skills-init refusal fails the whole build closed (the
        // caller rolls back the self-installed lanes).
        guard let skillsDomain = try? SkillsDomain(services: SkillsDomain.Services(
            database: database,
            installationRoot: rootURL.appendingPathComponent("FloeAgent/Skills",
                                                             isDirectory: true),
            stagingRoot: rootURL.appendingPathComponent("FloeAgent/SkillsStaging",
                                                        isDirectory: true),
            hostContext: hostContext,
            transport: SkillsRemoteTransportComposition.makePublicHubTransport(),
            rewriter: SkillsModelRewriteComposition.makeAdapter(
                database: database,
                gateway: SecretGatewayRegistry.shared,
                transportAdmission: transportGate,
                ownedWork: ownedWorkLifecycle),
            ownedWork: ownedWorkLifecycle,
            toolWork: toolWork,
            registry: .shared,
            trustedKeys: nil)) else {
            return nil
        }
        let mcpDomain = MCPDomain(services: MCPDomain.Services(
            database: database,
            gateway: SecretGatewayRegistry.shared,
            routeContext: routeContext,
            transportAdmission: transportGate,
            clientFactory: OriginalMCPClientFactory(),
            ownedWork: ownedWorkLifecycle,
            toolWork: toolWork,
            registry: .shared,
            hostContext: hostContext))
        let capabilitiesDomain = CapabilitiesDomain(services: CapabilitiesDomain.Services(
            database: database,
            webSearch: G02CapabilitiesWebSearchProvider(facade: configFacade),
            mcp: mcpDomain,
            hostContext: hostContext,
            registry: .shared))
        let skillsRouter = SkillsCommandRouter(domain: skillsDomain)
        let mcpRouter = MCPCommandRouter(domain: mcpDomain, routeContext: routeContext)
        let capabilitiesRouter = CapabilitiesCommandRouter(domain: capabilitiesDomain)

        // 5. Attachment staging service over the EXACT accepted root
        //    identity + original store + reviewed owned-work registry. Real
        //    crash-recovery reconcile runs BEFORE the facade installs, so no
        //    command can address an unreconciled staging state.
        let staging = AttachmentStagingService(
            components: AttachmentStagingService.Components(
                identity: cluster.identity,
                store: conversations,
                ownedWork: RuntimeOwnedWorkRegistryStagingAttach.shared,
                files: .floeStaging))
        _ = await staging.reconcile()
        let stagingLaunchAuthority = AttachmentStagingLaunchAuthority(service: staging)
        guard AttachmentStagingFacade.install(components: AttachmentStagingDomainComponents(
            epoch: epoch, mailbox: gen.mailbox, effects: gen.effects,
            registry: gen.registry, service: staging,
            launchAuthority: stagingLaunchAuthority,
            readGrants: AttachmentReadGrantTable())) else {
            // Staging self-install refused (epoch/identity drift): roll back
            // the reconcile side effects and fail the whole build closed.
            return nil
        }

        // 6. RB4 run domain: real durable bundle over the SAME database; the
        //    REAL qualified normalizer adapter (owner-exact; ordinary runs
        //    only — temporary runs stay with the later temp extension); the
        //    staging authority binds the REAL service; the feed binder's
        //    REAL adapter replaces the rejected detached bridge.
        let taskChecklist = TaskChecklistStore(database: database)
        let runBundle = RunPersistenceBundle(
            identity: .ordinary,
            conversations: conversations,
            runs: cluster.runStore,
            runningInputs: cluster.runningInputStore,
            launches: cluster.runLaunchStore,
            childRuns: cluster.childRunStore,
            intelligence: intelligence,
            discovery: SQLiteConversationDiscoveryStore(database: database),
            taskChecklist: taskChecklist)
        // G07.3B: real scheduled Agent tasks over the EXISTING durable
        // schedule/occurrence model. The service is created BEFORE the run
        // components (its terminal hook rides them) and its launch port
        // resolves the run domain lazily after `RunDomainFacade.install`.
        let scheduleStore = SQLiteTaskScheduleStore(database: database)
        let environmentOwnership = G073ScheduleEnvironmentOwnership {
            conversationID in
            try? await workspace.workspaceID(conversationID: conversationID)
        }
        let scheduleService = G073TaskScheduleService(
            epoch: epoch,
            store: scheduleStore,
            dependencies: G073TaskScheduleDependencies(
                launch: G073RunDomainLaunchPort(epoch: epoch),
                workspaceForConversation: { conversationID in
                    try? await workspace.workspaceID(conversationID: conversationID)
                },
                workspace: { id in
                    guard let record = try? await workspace.workspace(id: id) else {
                        return nil
                    }
                    return G073WorkspaceSummary(id: record.id, name: record.name,
                                                kind: record.kind)
                },
                workspaces: {
                    let records = (try? await workspace.workspaces()) ?? []
                    return records.map {
                        G073WorkspaceSummary(id: $0.id, name: $0.name, kind: $0.kind)
                    }
                },
                model: { id in
                    guard let model = try? await cluster.modelConfigurationStore.model(id: id),
                          let provider = try? await cluster.modelConfigurationStore.provider(
                            id: model.providerID),
                          model.isEnabled, provider.isEnabled else { return nil }
                    return G073ModelSummary(
                        id: model.id, providerID: provider.id,
                        displayName: model.displayName,
                        providerName: provider.displayName ?? provider.kind.rawValue,
                        supportsChat: model.supportsChatAgentSurface)
                },
                models: {
                    let providers = (try? await cluster.modelConfigurationStore.providers()) ?? []
                    let models = (try? await cluster.modelConfigurationStore.models()) ?? []
                    let enabled = Dictionary(uniqueKeysWithValues:
                        providers.filter(\.isEnabled).map { ($0.id, $0) })
                    return models.compactMap { model in
                        guard model.isEnabled, let provider = enabled[model.providerID] else {
                            return nil
                        }
                        return G073ModelSummary(
                            id: model.id, providerID: provider.id,
                            displayName: model.displayName,
                            providerName: provider.displayName ?? provider.kind.rawValue,
                            supportsChat: model.supportsChatAgentSurface)
                    }
                },
                defaultModelID: {
                    (try? await cluster.modelConfigurationStore.preferences())?
                        .defaultAgentModelID
                },
                runState: { id in
                    (try? await cluster.runStore.run(id: id))?.state
                },
                terminalStopReason: { id in
                    guard let events = try? await cluster.runStore.recentEvents(
                        runID: id, limit: 8) else { return nil }
                    for event in events.reversed() where event.kind == .terminal {
                        guard let data = event.payloadJSON.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any] else { return nil }
                        return object["stopReason"] as? String
                    }
                    return nil
                },
                claimedOccurrences: {
                    // Row is not Sendable: project it into the Sendable DTO
                    // INSIDE the reader closure instead of crossing the
                    // DatabaseManager.reader boundary with [Row].
                    let claimed: [G073ClaimedOccurrence]
                    do {
                        claimed = try await database.reader { db in
                            let rows = try Row.fetchAll(db, sql: """
                                SELECT id, schedule_id, scheduled_for, run_id
                                FROM task_schedule_occurrences
                                WHERE state IN ('claimed', 'running')
                                ORDER BY scheduled_for DESC
                                LIMIT 200
                                """)
                            let fractional = ISO8601DateFormatter()
                            fractional.formatOptions = [.withInternetDateTime,
                                                        .withFractionalSeconds]
                            let plain = ISO8601DateFormatter()
                            plain.formatOptions = [.withInternetDateTime]
                            func date(_ raw: String?) -> Date? {
                                guard let raw else { return nil }
                                return fractional.date(from: raw) ?? plain.date(from: raw)
                            }
                            return rows.compactMap { row in
                                guard let id = UUID(uuidString: row["id"]),
                                      let scheduleID = UUID(uuidString: row["schedule_id"]),
                                      let scheduledFor = date(row["scheduled_for"]) else {
                                    return nil
                                }
                                return G073ClaimedOccurrence(
                                    id: id, scheduleID: scheduleID,
                                    scheduledFor: scheduledFor,
                                    runID: (row["run_id"] as String?)
                                        .flatMap(UUID.init(uuidString:)))
                            }
                        }
                    } catch {
                        claimed = []
                    }
                    return claimed
                },
                environmentSource: nil,
                environmentOwnership: environmentOwnership,
                // G07.3B after-success run choices: the EXISTING durable
                // top-level run projection over the SAME database. This is a
                // read-only seam; the schedule service re-validates the chosen
                // run (existence, liveness, bound project) before freezing it.
                recentRunChoices: { limit in
                    let runs = (try? await cluster.runStore.recentRunSummaries(
                        limit: limit)) ?? []
                    return runs.map {
                        G073ScheduleRecentRun(
                            id: $0.id,
                            conversationID: $0.conversationID,
                            conversationTitle: $0.conversationTitle,
                            state: $0.state,
                            startedAt: $0.startedAt)
                    }
                },
                runConversation: { id in
                    (try? await cluster.runStore.run(id: id))?.conversationID
                }),
            )

        let runComponents = RunDomainComponents(
            context: RunIngressContext(
                epoch: epoch,
                // Trusted bundled corpus frozen by the App bootstrap before
                // the Root start (validated through the ORIGINAL loader:
                // pinned SHA, <=1 MiB, same schema, non-empty patterns).
                // Absent => the run gate keeps its honest corpusAbsent
                // refusal BEFORE any effect; never an empty gate.
                catastrophicCorpusBytes: G02SecurityCorpus.frozenBytes(),
                isTransportQualified: transportGate.admitsCloudNetwork),
            durable: runBundle,
            checkpoints: cluster.checkpointStore,
            modelStore: cluster.modelConfigurationStore,
            workspaceStore: workspace,
            effects: gen.effects,
            events: gen.events,
            content: gen.content,
            conversationRevisions: G02ConversationRevisionReader(database: database),
            credentialNormalizer: RunCredentialArgumentNormalizerAdapter.make(
                vault: vault, authority: nil),
            stagedAttachments: stagingLaunchAuthority,
            stagedImages: G02StagedImageLoader(staging: staging),
            toolCancellation: toolWork,
            // G07.3B: the real project/session ownership gate over the host's
            // FRESH runtime authority metadata (unbound -> fail closed exactly
            // like the previous no-environment build).
            environmentProof: environmentOwnership,
            intelligenceFeed: feedBinder.feed,
            personalizationProvider: {
                try await personalizationStore.liveSnapshot(workspaceID: nil)
            },
            adapterFactoryOverride: nil,
            registry: .shared,
            // goal-core batch: the SAME original DatabaseManager's shared
            // settings store (semantic-compaction key read only; the cluster
            // already owns this exact store instance).
            settings: cluster.settingsStore,
            // G06 Notes: the ONE process-wide assistant coordinator (closed
            // tools, document policy, durable purpose.notes threads). It is
            // the same accepted-epoch domain's port, never a second runtime.
            notesRuntime: NotesAssistantDomain.shared,
            // G07.3B: terminal occurrence settlement + after-success enqueue.
            scheduleCompletion: scheduleService)
        RunDomainFacade.install(components: runComponents, registry: gen.registry)
        G073TaskScheduleFacade.install(epoch: epoch, service: scheduleService)
        // Cold-start ordering is enforced by the service: settle occurrences
        // whose durable run reached a terminal, THEN interrupt leftovers.
        // Unknown in-flight outcomes stay interrupted and are never replayed.
        _ = await scheduleService.reconcileColdStart()
        // The agent-facing tool shares the SAME service; it cannot grant any
        // permission (the binding resolver only freezes the run's actual
        // three-field DraftTaskPolicy, workspace and model).
        registerG073TaskScheduleTools(
            service: scheduleService,
            registry: runComponents.registry,
            bindingResolver: { context in
                var frozenWorkspace: UUID?
                var policy = DraftTaskPolicy()
                if let conversationID = context.conversationID {
                    if let workspaceID = try? await workspace.workspaceID(
                        conversationID: conversationID),
                       let record = try? await workspace.workspace(id: workspaceID) {
                        // A previous private task workspace is deliberately
                        // not frozen; nil means a new independent workspace
                        // per occurrence.
                        if record.kind == .project { frozenWorkspace = record.id }
                    }
                    if let taskPolicy = try? await workspace.taskPolicy(
                        conversationID: conversationID) {
                        policy = DraftTaskPolicy(
                            approvalMode: taskPolicy.resolvedApprovalMode,
                            recoveryPolicy: taskPolicy.recoveryPolicy,
                            notificationPolicy: taskPolicy.notificationPolicy)
                    }
                }
                var modelID: UUID?
                if let run = try? await cluster.runStore.run(id: context.runID) {
                    modelID = run.modelID
                }
                if modelID == nil {
                    modelID = (try? await cluster.modelConfigurationStore.preferences())?
                        .defaultAgentModelID
                }
                guard let modelID else { return nil }
                var environmentID: String?
                if let environment = context.environmentID {
                    guard let project = frozenWorkspace,
                          await environmentOwnership.proveScheduledEnvironment(
                            environment, workspaceID: project,
                            metadata: environmentOwnership.metadata(id: environment),
                            epoch: epoch) else { return nil }
                    environmentID = environment
                }
                return G073TaskScheduleToolBinding(
                    workspaceID: frozenWorkspace, modelID: modelID,
                    environmentID: environmentID, policy: policy)
            })

        // Close the REAL feed/lease cycle with the exact accepted domain
        // instance; until this line both sides answered fail-closed.
        if let (runDomain, _) = RunDomainFacade.current(epoch: epoch) {
            feedBinder.bind(domain: runDomain, events: personalizationEvents)
        }
        // G06 Notes: bind the assistant coordinator to THIS accepted epoch.
        // Its durable threads/transcripts live in the same stores; the Notes
        // library root stays owned by the existing NotesDomainService binding
        // and is only opened by an explicit Notes action.
        await NotesAssistantDomain.shared.bind(epoch: epoch)

        // 7. RB3 conversation history (after RB4: real deletion lifecycle).
        let runHandles = RunDomainFacade.current(epoch: epoch)
        let contentAuthority = FacadeConversationContentAuthority(
            publisher: G02ConversationContentPublisher(content: gen.content),
            database: database,
            conversationStore: conversations,
            context: ConversationFacadeContext(hostEpoch: epoch))
        let memoryContentReader = RuntimeFacadeContentReader(
            contentStore: personalizationContentStore,
            conversations: G02ConversationContentReadDelegate {
                await G02RuntimeComposition.shared
                    .installedConversationDomain(epoch: epoch)
            })
        let conversationDomain = FacadeConversationDomain(
            database: database,
            conversationStore: conversations,
            runStore: cluster.runStore,
            runningInputStore: cluster.runningInputStore,
            workspaceStore: workspace,
            intelligenceStore: intelligence,
            content: contentAuthority,
            context: ConversationFacadeContext(hostEpoch: epoch),
            lifecycle: runHandles?.1,
            credentialDrain: G02VaultCredentialDrain(vault: vault),
            workspaceCleaning: G02WorkspaceCleaning(root: cluster.identity.root))

        // 8. Settings defaults / usage.
        let defaultsAdapter = FacadeSettingsDefaultsAdapter(database: database)
        let usageAdapter = FacadeUsageAdapter(database: database)

        var installed = G02InstalledComposition(
            epoch: epoch, cluster: cluster,
            registry: gen.registry,
            modelConfigurationFacade: configFacade,
            modelConfigurationRouter: configRouter,
            credentialResolver: credentialResolver,
            vault: vault,
            vaultEpoch: await vault.runtimeEpoch,
            intelligenceStore: intelligence,
            personalizationService: personalizationService,
            memoryAdapter: memoryAdapter,
            memoryOrganizer: memoryOrganizer,
            personalizationAdapter: personalizationAdapter,
            personalizationGenerate: personalizationGenerate,
            memoryContentReader: memoryContentReader,
            personalizationEvents: personalizationEvents,
            toolWorkCoordinator: toolWork,
            skillsDomain: skillsDomain,
            mcpDomain: mcpDomain,
            capabilitiesDomain: capabilitiesDomain,
            skillsRouter: skillsRouter,
            mcpRouter: mcpRouter,
            capabilitiesRouter: capabilitiesRouter,
            runComponents: runComponents,
            stagingService: staging,
            conversationDomain: conversationDomain,
            defaultsAdapter: defaultsAdapter,
            usageAdapter: usageAdapter,
            feedBinder: feedBinder,
            taskSchedules: scheduleService)
        // Capture the SAME-database identity evidence at build time: each
        // entry is the identifier of the ACTUAL argument bound at the
        // domain's construction call site — a second DatabaseManager opened
        // anywhere in the graph changes its entry and fails the identity
        // test.
        installed.databaseIdentifiers = [
            "cluster": ObjectIdentifier(database),
            "modelConfiguration": ObjectIdentifier(database),
            "conversationHistory": ObjectIdentifier(database),
            "memory": ObjectIdentifier(database),
            "skillsMcpCapabilities": ObjectIdentifier(database),
            "runDomain": ObjectIdentifier(database),
            "attachmentStaging": ObjectIdentifier(database),
            "defaults": ObjectIdentifier(database),
            "usage": ObjectIdentifier(database),
            "vault": ObjectIdentifier(database),
        ]
        // The install reservation prevents a newer graph from publishing
        // while this build owns it. Register the ORIGINAL progress tools
        // only after every constructor succeeded and the owner is current.
        guard AndroidRuntimeBootstrap.bootstrapStillCurrent(epoch: epoch, owner: gen.owner) else {
            return nil
        }
        registerTaskChecklistTools(store: taskChecklist, registry: runComponents.registry)
        // G07.3A user questions: install the durable/RAM coordinator for this
        // exact epoch and register the main-run-only `user.ask` runner. The
        // runner's availability closure reads this installation, so a
        // retired graph never advertises a tool it cannot execute.
        _ = UserQuestionHostAPI.shared.install(database: database, epoch: epoch)
        return installed
    }
}
