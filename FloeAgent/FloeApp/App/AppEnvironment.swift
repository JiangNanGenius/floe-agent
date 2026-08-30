// FloeApp — Production application environment.
// See docs/ALPHA_DAILY_PLAN.md §"Navigation and app environment": replaces
// the M0 diagnostics root with a production `AppEnvironment` that owns
// persistence, provider registry, conversations, runs, approvals, files and
// remote sessions. Every dependency is explicit and replaceable with a test
// double. Secrets never live here — only Keychain references.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeSync
import FloeWorkspace
import FloeExecution
import FloeSSH
import FloeVNC
import FloeSkills
import FloeDocuments
import FloeImages
import FloeProviders
import FloeAgentRuntime
import FloeLocalModels
import FloeGit
import FloeTools
import CloudKit

/// Owns the app's long-lived services and stores. Created once at launch and
/// injected through the SwiftUI environment. All stores are protocol-typed so
/// tests and previews can substitute in-memory doubles.
@MainActor
final class AppEnvironment: ObservableObject {

    // MARK: Persistence

    let database: DatabaseManager
    let conversationStore: any ConversationStore
    let runStore: any RunStore
    /// Atomic preparation of conversation + run + first message before any
    /// provider work begins.
    let runLaunchStore: any RunLaunchStore
    let runningInputStore: any RunningInputStore
    let checkpointStore: any CheckpointStore
    let intelligenceStore: SQLiteIntelligenceStore
    let personalizationStore: SQLitePersonalizationStore
    let personalizationService: PersonalizationService
    let memoryCandidatePipeline: MemoryCandidatePipeline
    let skillStore: SQLiteSkillStore
    let configurationStore: ModelConfigurationStore
    let configurationSync: ConfigSyncEngine
    let credentialStore: CredentialStore
    let credentialVault: CredentialVaultService
    let remoteSessionRegistry: any RemoteSessionRegistry
    let localModelStore: LocalModelStore
    let localModelRuntime: LocalModelRuntime
    let localModelsCenter: LocalModelsCenter
    /// One validated font library shared by document workflows in every
    /// Floe workspace. Fonts are process-registered again on each launch.
    let fontStore: DeviceFontStore
    let networkStatusMonitor: NetworkStatusMonitor

    // MARK: Security

    let keychain: KeychainStore
    let catastrophicGate: CatastrophicActionGate
    let subagentRunnerRegistry: SubagentRunnerRegistry

    // MARK: Execution (T13/T14)

    /// Host store backing SSH + remote Python (shares the database).
    let remoteHostStore: RemoteHostStore
    /// Shared verified-SSH command service used by model tools and explicit
    /// host-management actions such as remote-agent updates.
    let sshCommandService: SSHCommandService
    let cloudWorkspaceService: CloudWorkspaceService
    let cloudWorkspaceCleanupQueue: CloudWorkspaceCleanupQueue
    let bluetoothSerialService: CoreBluetoothSerialService
    /// Bundled CPython capability. Unavailable only when the reproducible
    /// runtime bootstrap was intentionally omitted from the build.
    let localPythonProbe: FloeExecution.LocalPythonCapabilityProbe
    /// Real remote-Python capability probe (FloeExecution), surfaced to
    /// SettingsCenter so the UI reads live state instead of a placeholder.
    let remotePythonProbe: FloeExecution.RemotePythonProbe
    /// Long-lived visible WebKit session shared by UI and browser tools.
    let browserCenter: BrowserSessionCenter
    let previewCenter: LocalPreviewCoordinator
    /// The single microphone/SpeechAnalyzer session for the whole app. A
    /// composer never constructs its own AVAudioEngine.
    let voiceInput: VoiceInputController

    // MARK: Coordinators

    /// App-level coordinators, created lazily on first access. Views bind
    /// only to these centers, never to stores or runtimes directly.
    /// T01 vends minimal shells; T02/T04/T05 fill them in.
    private lazy var _conversationCenter = ConversationCenter(environment: self)
    private lazy var _remoteSessionCenter = RemoteSessionCenter(environment: self)
    private lazy var _filesCenter = FilesCenter(environment: self)
    private lazy var _workspaceCenter = WorkspaceCenter(environment: self)
    private lazy var _sourceControlCenter = SourceControlCenter(environment: self)
    private lazy var _settingsCenter = SettingsCenter(environment: self)
    private lazy var _skillsCenter = SkillsCenter(environment: self)
    private lazy var _memoryCenter = MemoryCenter(environment: self)
    private lazy var _memoryDreamService = MemoryDreamService(environment: self)
    private lazy var _skillDreamService = SkillDreamService(environment: self)
    private lazy var _speechService = SpeechService()
    private lazy var _backgroundRunCoordinator = BackgroundRunCoordinator(environment: self)
    private lazy var _mediaGenerationService = MediaGenerationService(environment: self)
    private lazy var _creativeAssetStore = CreativeAssetStore(database: database)
    private lazy var _canvasSyncOperationStore = CanvasSyncOperationStore(database: database)
    private lazy var _canvasCloudAssetService = CanvasCloudAssetService(
        store: _creativeAssetStore,
        operationStore: _canvasSyncOperationStore
    )
    private lazy var _screenShareCenter = ScreenShareCenter(conversationCenter: _conversationCenter)
    private lazy var _backgroundVideoService = BackgroundVideoService()
    private lazy var _webSearchSettingsCenter = WebSearchSettingsCenter()
    private lazy var _mcpSettingsCenter = MCPSettingsCenter.shared

    var conversationCenter: ConversationCenter { _conversationCenter }
    var remoteSessionCenter: RemoteSessionCenter { _remoteSessionCenter }
    var filesCenter: FilesCenter { _filesCenter }
    var workspaceCenter: WorkspaceCenter { _workspaceCenter }
    var sourceControlCenter: SourceControlCenter { _sourceControlCenter }
    /// Lazily created on first access; ConversationCenter reads
    /// `defaultAgentMode` through it without a construction cycle.
    var settingsCenter: SettingsCenter { _settingsCenter }
    var skillsCenter: SkillsCenter { _skillsCenter }
    var memoryCenter: MemoryCenter { _memoryCenter }
    var memoryDreamService: MemoryDreamService { _memoryDreamService }
    var skillDreamService: SkillDreamService { _skillDreamService }
    var speechService: SpeechService { _speechService }
    var backgroundRunCoordinator: BackgroundRunCoordinator { _backgroundRunCoordinator }
    var mediaGenerationService: MediaGenerationService { _mediaGenerationService }
    var creativeAssetStore: CreativeAssetStore { _creativeAssetStore }
    var canvasSyncOperationStore: CanvasSyncOperationStore { _canvasSyncOperationStore }
    var canvasCloudAssetService: CanvasCloudAssetService { _canvasCloudAssetService }
    var screenShareCenter: ScreenShareCenter {
        let center = _screenShareCenter
        if center.onGuidanceChanged == nil {
            center.onGuidanceChanged = { [weak self] image, hints in
                self?.backgroundVideoService.updateGuidance(
                    image: image,
                    hints: hints.map {
                        BackgroundVideoService.GuidanceHint(
                            label: $0.elementText,
                            instruction: $0.instruction,
                            point: $0.tapPoint
                        )
                    }
                )
            }
        }
        return center
    }
    var backgroundVideoService: BackgroundVideoService {
        let service = _backgroundVideoService
        if service.onUserStopped == nil {
            service.onUserStopped = { [weak self] in
                self?.backgroundRunCoordinator.didClosePictureInPicture()
            }
        }
        return service
    }
    var webSearchSettingsCenter: WebSearchSettingsCenter { _webSearchSettingsCenter }
    var mcpSettingsCenter: MCPSettingsCenter { _mcpSettingsCenter }

    // MARK: State

    /// Whether the local database finished migrating. The UI gates the
    /// workbench on this and shows an honest recovery state on failure.
    @Published private(set) var persistenceReady = false
    @Published private(set) var bootstrapError: String?
    /// True only for the emergency in-memory environment. Production
    /// actions remain unavailable because this state is not durable.
    let isEphemeral: Bool

    private init(
        database: DatabaseManager,
        conversationStore: any ConversationStore,
        runStore: any RunStore,
        configurationStore: ModelConfigurationStore,
        configurationSync: ConfigSyncEngine,
        remoteSessionRegistry: any RemoteSessionRegistry,
        keychain: KeychainStore,
        catastrophicGate: CatastrophicActionGate,
        isEphemeral: Bool = false
    ) {
        self.database = database
        self.conversationStore = conversationStore
        self.runStore = runStore
        self.runLaunchStore = SQLiteRunLaunchStore(database: database)
        self.runningInputStore = SQLiteRunningInputStore(database: database)
        let checkpointRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("FloeAgent/Checkpoints", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeAgent-Checkpoints")
        self.checkpointStore = FileCheckpointStore(directory: checkpointRoot)
        let intelligenceStore = SQLiteIntelligenceStore(database: database)
        self.intelligenceStore = intelligenceStore
        let personalizationStore = SQLitePersonalizationStore(database: database)
        self.personalizationStore = personalizationStore
        self.personalizationService = PersonalizationService(
            documents: personalizationStore,
            memories: intelligenceStore
        )
        self.memoryCandidatePipeline = MemoryCandidatePipeline(
            documents: personalizationStore,
            memories: intelligenceStore
        )
        self.skillStore = SQLiteSkillStore(database: database)
        self.configurationStore = configurationStore
        self.configurationSync = configurationSync
        self.credentialStore = CredentialStore(database: database)
        self.credentialVault = CredentialVaultService(records: self.credentialStore)
        self.remoteSessionRegistry = remoteSessionRegistry
        let localModelStore = LocalModelStore()
        self.localModelStore = localModelStore
        self.localModelRuntime = LocalModelRuntime(store: localModelStore)
        self.localModelsCenter = LocalModelsCenter(
            store: localModelStore,
            runtime: self.localModelRuntime,
            configurationStore: configurationStore
        )
        self.fontStore = DeviceFontStore()
        self.networkStatusMonitor = NetworkStatusMonitor()
        self.keychain = keychain
        self.catastrophicGate = catastrophicGate
        self.subagentRunnerRegistry = SubagentRunnerRegistry()
        self.isEphemeral = isEphemeral
        self.browserCenter = BrowserSessionCenter()
        self.previewCenter = LocalPreviewCoordinator(browser: self.browserCenter)
        self.voiceInput = VoiceInputController.live()

        // Register both execution locations. Local CPython is a stripped,
        // fixed app resource and always asks before executing; remote Python
        // continues to resolve credentials at the call site only.
        let hostStore = RemoteHostStore(database: database)
        self.remoteHostStore = hostStore
        let remoteServices = Self.makeRemoteServices(hostStore: hostStore)
        let pythonService = remoteServices.python
        let sshCommandService = remoteServices.ssh
        self.sshCommandService = sshCommandService
        let remoteAgentReadiness = RemoteAgentReadinessCoordinator(
            manager: RemoteAgentInstaller(service: sshCommandService),
            eligibility: { hostID in
                let hosts = try await hostStore.hosts()
                let selected = hostID.flatMap { requested in hosts.first { $0.id == requested } }
                    ?? hosts.first {
                        guard $0.isRemoteExecutionEnvironment ?? true,
                              let auth = try? JSONDecoder().decode(
                                SSHAuthMethod.self,
                                from: Data($0.authJSON.utf8)
                              ) else { return false }
                        return auth != .none
                    }
                guard let selected else { return false }
                guard let auth = try? JSONDecoder().decode(
                    SSHAuthMethod.self,
                    from: Data(selected.authJSON.utf8)
                ) else { return false }
                return (selected.isRemoteExecutionEnvironment ?? true) && auth != .none
            }
        )
        let cloudWorkspaceService = CloudWorkspaceService(
            ssh: sshCommandService,
            readiness: remoteAgentReadiness
        )
        self.cloudWorkspaceService = cloudWorkspaceService
        self.cloudWorkspaceCleanupQueue = CloudWorkspaceCleanupQueue(service: cloudWorkspaceService)
        self.bluetoothSerialService = CoreBluetoothSerialService()
        let localPythonService = CPythonServiceFactory.make()
        self.remotePythonProbe = FloeExecution.RemotePythonProbe(service: pythonService)
        self.localPythonProbe = FloeExecution.LocalPythonCapabilityProbe(
            service: localPythonService
        )

        self.localModelsCenter.onCatalogChanged = { [weak self] in
            await self?.localModelRuntime.unload(modelID: nil)
            await self?.conversationCenter.reload()
        }
        self.localModelsCenter.onConfigurationChanged = { [weak self] in
            await self?.conversationCenter.reload()
        }

        // All stored properties are initialized above. Registrations below
        // may now safely resolve lazy centers that retain this environment.
        // Unified tool registration: every tool the model can see is
        // registered here in one place, in a deterministic order.
        registerAllAgentTools(
            localPythonService: localPythonService,
            sshCommandService: sshCommandService,
            cloudWorkspaceService: cloudWorkspaceService
        )
        FloeShortcutsRuntime.shared.install(environment: self)
    }

    /// Registers every tool the agent can see, in one place and in a
    /// deterministic order. This is the single source of truth for the
    /// model's tool catalog.
    private func registerAllAgentTools(
        localPythonService: LocalPythonService?,
        sshCommandService: SSHCommandService?,
        cloudWorkspaceService: CloudWorkspaceService?
    ) {
        let credentialVault = self.credentialVault
        // Workspace file tools (T04/T05).
        registerWorkspaceTools(rootProvider: WorkspaceCenter.toolRootProvider)
        // Native local Git and GitHub repository tools. Credentials are read
        // from the dedicated device-local Keychain store at execution time.
        registerGitTools(rootProvider: WorkspaceCenter.toolRootProvider)
        // Document tools (OOXML spreadsheet reading).
        registerDocumentTools(rootProvider: WorkspaceCenter.toolRootProvider)
        // Device-global, digest-addressed font resources for document/PDF
        // work. Removal remains approval-gated; bounded installation does not.
        registerFontTools(store: fontStore)
        // Image tools (Core Image processing).
        registerImageTools(rootProvider: WorkspaceCenter.toolRootProvider)
        // Native canvas inspection and mutation tools. Canvas runs are scoped
        // back to their durable hidden assistant conversation at execution.
        registerCanvasAgentTools(environment: self)
        // Provider-backed semantic visual inspection plus generation through
        // the independently configured auxiliary models. These must be in
        // the agent catalog, not UI-only.
        registerRemoteImageTools(center: filesCenter)
        // Public Apple-framework integrations. Device-local settings filter
        // these descriptors before each provider request.
        registerAppleSystemTools(database: database)
        // Execution tools (JS, local Python, SSH, HTTP, LAN scan, OCR, barcode).
        registerExecutionTools(
            localPythonService: localPythonService,
            sshCommandService: sshCommandService,
            cloudWorkspaceService: cloudWorkspaceService,
            remoteHostStore: remoteHostStore,
            vncPasswordWriter: { hostID, connectionID, credentialInput in
                guard !credentialInput.isEmpty else {
                    throw FloeError.validationFailed("VNC password must not be empty")
                }
                let resolvedPassword: Data
                if let value = String(data: credentialInput, encoding: .utf8),
                   let credentialID = SecretIngressScanner.credentialID(from: value) {
                    resolvedPassword = try await credentialVault.resolveForApprovedUse(
                        CredentialHandle(id: credentialID)
                    )
                } else {
                    // Plaintext is permitted only at this executor boundary;
                    // the saved host profile receives a Keychain reference.
                    resolvedPassword = credentialInput
                }
                let secrets = KeychainSecretStore()
                try await secrets.storeSecret(
                    resolvedPassword,
                    scope: .hostVNCConnection(hostID: hostID, connectionID: connectionID)
                )
                return SecretReference(
                    keychainAccount: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)",
                    synchronizable: SyncControlPreferences.load().savedCredentialsEnabled
                )
            },
            vncPasswordDeleter: { hostID, connectionID in
                try await KeychainSecretStore().deleteSecret(
                    scope: .hostVNCConnection(hostID: hostID, connectionID: connectionID)
                )
            },
            bluetoothSerialService: bluetoothSerialService,
            webSearchService: WebSearchService(configurations: WebSearchSettingsCenter.resolvedConfigurations),
            includeOnDeviceJavaScript: true
        )
        // Browser automation.
        registerBrowserTools(center: browserCenter)
        // Local preview server.
        registerPreviewTools(environment: previewCenter)
        // Skill authoring.
        registerSkillTools(creator: LocalSkillCreator(center: skillsCenter))
        // Durable memory.
        registerMemoryTools(store: intelligenceStore) { [runStore] runID in
            try await runStore.run(id: runID)?.conversationID
        }
        // Cross-task history is quoted as untrusted data. Spawning is a
        // separate visible task, never an internal subagent, and is gated by
        // an explicit request in the latest user message.
        registerConversationTools(
            reader: intelligenceStore,
            currentConversationID: { [runStore] runID in
                try await runStore.run(id: runID)?.conversationID
            },
            hasExplicitUserAuthority: { [runStore, conversationStore] runID in
                guard let conversationID = try await runStore.run(id: runID)?.conversationID else {
                    return false
                }
                let latestUserText = try await conversationStore.messages(conversationID: conversationID)
                    .last(where: { $0.role == "user" })?.content ?? ""
                return ConversationSpawnAuthority.isExplicitRequest(latestUserText)
            },
            spawner: { [conversationStore, database] request in
                let now = Date()
                let conversationID = ConversationSpawnIdentity.uuid(
                    operationID: request.operationID,
                    suffix: "conversation"
                )
                let initialMessageID = ConversationSpawnIdentity.uuid(
                    operationID: request.operationID,
                    suffix: "initial-message"
                )
                let existing = try await conversationStore.conversation(id: conversationID)
                let record = ConversationRecord(
                    id: conversationID, title: request.title,
                    createdAt: existing?.createdAt ?? now, updatedAt: now,
                    titleOrigin: .manual
                )
                try await conversationStore.saveConversation(record)
                do {
                    if let workspaceID = request.workspaceID {
                        try await SQLiteWorkspaceStore(database: database).assignConversation(
                            workspaceID: workspaceID,
                            conversationID: record.id
                        )
                    }
                    try await conversationStore.appendMessage(PersistedMessage(
                        id: initialMessageID, conversationID: record.id, role: "user",
                        content: request.objective, createdAt: now
                    ))
                } catch {
                    try? await conversationStore.deleteConversation(id: record.id)
                    throw error
                }
                await MainActor.run { [weak self] in
                    Task { await self?.conversationCenter.reload() }
                }
                return ConversationSpawnResult(
                    conversationID: record.id,
                    title: record.title,
                    workspaceID: request.workspaceID,
                    wasCreated: existing == nil
                )
            }
        )
        // Supervisor-Worker delegation.
        registerDelegateTool(runners: subagentRunnerRegistry)
        // VNC remote-desktop driving.
        registerVNCTools(
            credentialResolver: { credentialID in
                try await credentialVault.resolveForApprovedUse(CredentialHandle(id: credentialID))
            },
            statusProvider: { [weak remoteSessionCenter] in
                await remoteSessionCenter?.toolVNCStatus()
                    ?? VNCToolConnectionStatus(state: .unconfigured, configuredEndpointCount: 0)
            },
            reconnect: { [weak remoteSessionCenter] in
                try await remoteSessionCenter?.reconnectToolVNCSession()
            },
            disconnect: { [weak remoteSessionCenter] in
                await remoteSessionCenter?.disconnectToolVNCSessions()
                    ?? VNCToolConnectionStatus(state: .unconfigured, configuredEndpointCount: 0)
            }
        ) { [weak remoteSessionCenter] in
            try await remoteSessionCenter?.activeOrConnectVNCSession()
        }
        // Standard remote MCP servers are configuration-driven tool sources.
        // Activation only discovers JSON schemas and registers namespaced
        // runners; no server code is downloaded or executed by the app.
        mcpSettingsCenter.activate()
    }

    /// Builds the remote-Python service against the shared host store.
    /// Sessions open on demand through SSHConnectionService; credentials
    /// resolve through the Keychain and are never held beyond the connect.
    private static func makeRemoteServices(
        hostStore: RemoteHostStore
    ) -> (python: RemotePythonService, ssh: SSHCommandService) {
        let sshService = SSHConnectionService(hostStore: hostStore)

        let sessionFactory: RemotePythonService.SessionFactory = { hostID in
            guard let stored = try await hostStore.host(id: hostID) else {
                throw RemotePythonError.hostNotFound(hostID)
            }
            let profile = try RemoteHostProfile(stored: stored)
            do {
                return try await sshService.connect(
                    profile: profile,
                    credentialResolver: { reference in
                        let store = KeychainStore(
                            service: "org.floeagent.ios.secrets",
                            synchronizable: reference.synchronizable
                        )
                        return try store.read(account: reference.keychainAccount)
                    },
                    // Non-interactive context: an unknown host key is rejected
                    // rather than prompting. The user trusts hosts via the
                    // Hosts UI (TOFU) before running remote Python.
                    hostKeyDecision: { _ in false }
                )
            } catch let error as SSHConnectionError {
                throw RemotePythonError.sshConnection(error)
            }
        }

        let hostResolver: RemotePythonService.HostResolver = { hostID in
            guard let stored = try await hostStore.host(id: hostID) else { return nil }
            return RemotePythonService.RemotePythonHost(
                id: stored.id,
                displayName: stored.displayName
            )
        }

        let defaultHostProvider: RemotePythonService.DefaultHostProvider = {
            try await hostStore.hosts().first { stored in
                guard stored.isRemoteExecutionEnvironment ?? true,
                      let auth = try? JSONDecoder().decode(
                        SSHAuthMethod.self,
                        from: Data(stored.authJSON.utf8)
                      ) else { return false }
                return auth != .none
            }?.id
        }

        let python = RemotePythonService(
            sessionFactory: sessionFactory,
            hostResolver: hostResolver,
            defaultHostProvider: defaultHostProvider
        )
        let ssh = SSHCommandService(
            sessionFactory: sessionFactory,
            hostResolver: hostResolver,
            defaultHostProvider: defaultHostProvider
        )
        return (python, ssh)
    }

    /// Builds the production environment against the on-disk database,
    /// migrating to the current schema. Returns a value whose
    /// `persistenceReady` reflects whether migration succeeded.
    static func live() -> AppEnvironment {
        let environment: AppEnvironment
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = support.appendingPathComponent("FloeAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try DatabaseManager(path: directory.appendingPathComponent("floe.sqlite"))
            let configurationStore = ModelConfigurationStore(database: database)
            let remoteHostStore = RemoteHostStore(database: database)
            let configurationSync = ConfigSyncEngine(
                configurationStore: configurationStore,
                metadataStore: ConfigSyncMetadataStore(database: database),
                remoteHostStore: remoteHostStore
            )

            environment = AppEnvironment(
                database: database,
                conversationStore: SQLiteConversationStore(database: database),
                runStore: SQLiteRunStore(database: database),
                configurationStore: configurationStore,
                configurationSync: configurationSync,
                remoteSessionRegistry: SQLiteRemoteSessionRegistry(database: database),
                keychain: KeychainStore(service: "org.floeagent.ios.providers"),
                catastrophicGate: (try? CatastrophicActionGate.withBundledPatterns())
                    ?? .failClosed(reason: "Catastrophic-action rules are unavailable")
            )
        } catch {
            // Fall back to an in-memory database so the app still launches and
            // can surface an honest recovery state instead of crashing.
            let database = try! DatabaseManager.inMemory() // in-memory open cannot fail here
            let configurationStore = ModelConfigurationStore(database: database)
            let remoteHostStore = RemoteHostStore(database: database)
            environment = AppEnvironment(
                database: database,
                conversationStore: SQLiteConversationStore(database: database),
                runStore: SQLiteRunStore(database: database),
                configurationStore: configurationStore,
                configurationSync: ConfigSyncEngine(
                    configurationStore: configurationStore,
                    metadataStore: ConfigSyncMetadataStore(database: database),
                    remoteHostStore: remoteHostStore
                ),
                remoteSessionRegistry: SQLiteRemoteSessionRegistry(database: database),
                keychain: KeychainStore(service: "org.floeagent.ios.providers"),
                catastrophicGate: (try? CatastrophicActionGate.withBundledPatterns())
                    ?? .failClosed(reason: "Catastrophic-action rules are unavailable"),
                isEphemeral: true
            )
            environment.bootstrapError = error.localizedDescription
        }
        return environment
    }

    /// Applies pending migrations. Called once during app launch. On failure
    /// the environment records the error so the UI can offer recovery rather
    /// than presenting a broken workbench.
    func bootstrap() async {
        do {
            try await database.migrate()
            try await runningInputStore.recoverTransientInputs()
            let fontActivationFailures = await fontStore.activateManagedFonts()
            if !fontActivationFailures.isEmpty {
                FloeLogger(category: .tools).warning(
                    "fontActivationFailed count=\(fontActivationFailures.count)"
                )
            }
            // Approval/background choices affect the very first task created
            // after launch. Restore them before `persistenceReady` exposes the
            // composer; settings-screen visitation must never be required.
            await settingsCenter.loadLaunchPreferences()
            await configurationSync.setCredentialStore(credentialStore)
            await credentialVault.drainDeletionQueue()
            // Replays offline cloud deletion tombstones. The endpoint is
            // idempotent, so launch-time retry is safe after crashes too.
            Task { [cloudWorkspaceCleanupQueue] in
                _ = await cloudWorkspaceCleanupQueue.drain()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-onboarding") {
                ConversationCenter.persistOnboardingSkippedMarker(false)
                for provider in try await configurationStore.providers() {
                    try await configurationStore.deleteProvider(id: provider.id)
                }
                try await configurationStore.savePreferences(ModelSelectionPreferences())
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reset-sync") {
                UserDefaults.standard.removeObject(forKey: SyncControlPreferences.overallKey)
                UserDefaults.standard.removeObject(forKey: SyncControlPreferences.configurationKey)
                await configurationSync.setSynchronizationEnabled(true)
            }
            #endif
            #if !targetEnvironment(simulator)
            do {
                let syncPreferences = SyncControlPreferences.load()
                await configurationSync.setSynchronizationEnabled(
                    syncPreferences.overallEnabled && syncPreferences.configurationEnabled
                )
                try await configurationSync.configure(container: CKContainer.default())
                // Never hold the launch UI behind CloudKit. The root view
                // performs a short, bounded second check before presenting
                // first-run setup, while this pull continues independently.
                if syncPreferences.overallEnabled && syncPreferences.configurationEnabled {
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.configurationSync.synchronize()
                            await self.conversationCenter.reload()
                        } catch {
                            let nsError = error as NSError
                            FloeLogger(category: .sync).warning(
                                "configurationSyncLaunchFailed domain=\(nsError.domain) code=\(nsError.code)"
                            )
                        }
                    }
                }
            } catch {
                // Local setup remains fully usable when iCloud is unavailable.
            }
            #endif
            if isEphemeral {
                persistenceReady = false
                if bootstrapError == nil {
                    bootstrapError = "Durable storage is unavailable. Floe Agent is in recovery mode."
                }
            } else {
                persistenceReady = true
                bootstrapError = nil
            }
        } catch {
            persistenceReady = false
            bootstrapError = error.localizedDescription
        }
    }

    /// In-memory environment for tests and SwiftUI previews.
    static func preview() -> AppEnvironment {
        let database = try! DatabaseManager.inMemory()
        let configurationStore = ModelConfigurationStore(database: database)
        let remoteHostStore = RemoteHostStore(database: database)
        return AppEnvironment(
            database: database,
            conversationStore: SQLiteConversationStore(database: database),
            runStore: SQLiteRunStore(database: database),
            configurationStore: configurationStore,
            configurationSync: ConfigSyncEngine(
                configurationStore: configurationStore,
                metadataStore: ConfigSyncMetadataStore(database: database),
                remoteHostStore: remoteHostStore
            ),
            remoteSessionRegistry: SQLiteRemoteSessionRegistry(database: database),
            keychain: KeychainStore(service: "org.floeagent.ios.providers"),
            catastrophicGate: (try? CatastrophicActionGate.withBundledPatterns())
                ?? .failClosed(reason: "Catastrophic-action rules are unavailable")
        )
    }
}
#endif
