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

    // MARK: Security

    let keychain: KeychainStore
    let catastrophicGate: CatastrophicActionGate
    let subagentRunnerRegistry: SubagentRunnerRegistry

    // MARK: Execution (T13/T14)

    /// Host store backing SSH + remote Python (shares the database).
    let remoteHostStore: RemoteHostStore
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
    private lazy var _settingsCenter = SettingsCenter(environment: self)
    private lazy var _skillsCenter = SkillsCenter(environment: self)
    private lazy var _memoryCenter = MemoryCenter(environment: self)
    private lazy var _memoryDreamService = MemoryDreamService(environment: self)
    private lazy var _skillDreamService = SkillDreamService(environment: self)
    private lazy var _speechService = SpeechService()
    private lazy var _backgroundRunCoordinator = BackgroundRunCoordinator(environment: self)
    private lazy var _screenShareCenter = ScreenShareCenter(conversationCenter: _conversationCenter)
    private lazy var _backgroundVideoService = BackgroundVideoService()
    private lazy var _webSearchSettingsCenter = WebSearchSettingsCenter()

    var conversationCenter: ConversationCenter { _conversationCenter }
    var remoteSessionCenter: RemoteSessionCenter { _remoteSessionCenter }
    var filesCenter: FilesCenter { _filesCenter }
    var workspaceCenter: WorkspaceCenter { _workspaceCenter }
    /// Lazily created on first access; ConversationCenter reads
    /// `defaultAgentMode` through it without a construction cycle.
    var settingsCenter: SettingsCenter { _settingsCenter }
    var skillsCenter: SkillsCenter { _skillsCenter }
    var memoryCenter: MemoryCenter { _memoryCenter }
    var memoryDreamService: MemoryDreamService { _memoryDreamService }
    var skillDreamService: SkillDreamService { _skillDreamService }
    var speechService: SpeechService { _speechService }
    var backgroundRunCoordinator: BackgroundRunCoordinator { _backgroundRunCoordinator }
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
        self.localModelsCenter = LocalModelsCenter(store: localModelStore)
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
        let localPythonService = CPythonServiceFactory.make()
        self.remotePythonProbe = FloeExecution.RemotePythonProbe(service: pythonService)
        self.localPythonProbe = FloeExecution.LocalPythonCapabilityProbe(
            service: localPythonService
        )

        self.localModelsCenter.onCatalogChanged = { [weak self] in
            await self?.localModelRuntime.unload(modelID: nil)
            await self?.conversationCenter.reload()
        }

        // All stored properties are initialized above. Registrations below
        // may now safely resolve lazy centers that retain this environment.
        // Unified tool registration: every tool the model can see is
        // registered here in one place, in a deterministic order.
        registerAllAgentTools(
            localPythonService: localPythonService,
            sshCommandService: sshCommandService
        )
        FloeShortcutsRuntime.shared.install(environment: self)
    }

    /// Registers every tool the agent can see, in one place and in a
    /// deterministic order. This is the single source of truth for the
    /// model's tool catalog.
    private func registerAllAgentTools(
        localPythonService: LocalPythonService?,
        sshCommandService: SSHCommandService?
    ) {
        // Workspace file tools (T04/T05).
        registerWorkspaceTools(rootProvider: WorkspaceCenter.toolRootProvider)
        // Document tools (OOXML spreadsheet reading).
        registerDocumentTools(rootProvider: WorkspaceCenter.toolRootProvider)
        // Image tools (Core Image processing).
        registerImageTools(rootProvider: WorkspaceCenter.toolRootProvider)
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
            remoteHostStore: remoteHostStore,
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
        registerMemoryTools(store: intelligenceStore)
        // Supervisor-Worker delegation.
        registerDelegateTool(runners: subagentRunnerRegistry)
        // VNC remote-desktop driving.
        registerVNCTools { [weak remoteSessionCenter] in
            await remoteSessionCenter?.activeVNCSession()
        }
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
        }

        let hostResolver: RemotePythonService.HostResolver = { hostID in
            guard let stored = try await hostStore.host(id: hostID) else { return nil }
            return RemotePythonService.RemotePythonHost(
                id: stored.id,
                displayName: stored.displayName
            )
        }

        let defaultHostProvider: RemotePythonService.DefaultHostProvider = {
            try await hostStore.hosts().first?.id
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
            // Approval/background choices affect the very first task created
            // after launch. Restore them before `persistenceReady` exposes the
            // composer; settings-screen visitation must never be required.
            await settingsCenter.loadLaunchPreferences()
            await configurationSync.setCredentialStore(credentialStore)
            await credentialVault.drainDeletionQueue()
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
