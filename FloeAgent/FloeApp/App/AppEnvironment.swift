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
import FloeEnvironments
import FloePackages
import FloeMedia
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
import UserNotifications
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

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
    let interactiveShellService: InteractiveShellSessionService
    let cloudWorkspaceService: CloudWorkspaceService
    let cloudWorkspaceCleanupQueue: CloudWorkspaceCleanupQueue
    let bluetoothSerialService: CoreBluetoothSerialService
    /// Bundled CPython capability. Unavailable only when the reproducible
    /// runtime bootstrap was intentionally omitted from the build.
    let localPythonProbe: FloeExecution.LocalPythonCapabilityProbe
    /// Real remote-Python capability probe (FloeExecution), surfaced to
    /// SettingsCenter so the UI reads live state instead of a placeholder.
    let remotePythonProbe: FloeExecution.RemotePythonProbe
    /// Local shell substrate (ios_system-backed) shared by exec.shell and the
    /// interactive shell.* tools.
    let localShellService: LocalShellService
    let shellSessionCenter: ShellSessionCenter
    lazy var localTerminals = LocalTerminalStore(sessions: shellSessionCenter)
    /// Managed pure-Python installer shared by exec.localPython, exec.shell
    /// and the apt capability layer.
    let managedPythonInstaller: ManagedPythonInstallService?
    /// apt/pkg capability catalog and reviewed install routing.
    let capabilityInstaller: CapabilityInstaller
    private let wasmCapabilities: SignedWasmCapabilityStore?
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
    private lazy var _canvasCloudAssetService: CanvasCloudAssetService = {
        #if targetEnvironment(simulator)
        return CanvasCloudAssetService(localOnlyStore: _creativeAssetStore, operationStore: _canvasSyncOperationStore)
        #else
        return CanvasCloudAssetService(store: _creativeAssetStore, operationStore: _canvasSyncOperationStore)
        #endif
    }()
    private lazy var _screenShareCenter = ScreenShareCenter(conversationCenter: _conversationCenter)
    private lazy var _backgroundVideoService = BackgroundVideoService()
    private lazy var _webSearchSettingsCenter = WebSearchSettingsCenter()
    private lazy var _mcpSettingsCenter = MCPSettingsCenter.shared

    var conversationCenter: ConversationCenter { _conversationCenter }
    /// Set during tool registration; used at launch to reconcile interrupted
    /// in-process jobs and by UI surfaces that list active background work.
    private(set) var backgroundJobService: BackgroundJobService?
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
    private let shouldSeedBundledSkills: Bool

    private init(
        database: DatabaseManager,
        conversationStore: any ConversationStore,
        runStore: any RunStore,
        configurationStore: ModelConfigurationStore,
        configurationSync: ConfigSyncEngine,
        remoteSessionRegistry: any RemoteSessionRegistry,
        keychain: KeychainStore,
        catastrophicGate: CatastrophicActionGate,
        isEphemeral: Bool = false,
        seedBundledSkills: Bool = true
    ) {
        self.shouldSeedBundledSkills = seedBundledSkills
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
        self.interactiveShellService = remoteServices.interactiveShell
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

        // Local shell substrate. The backend is the ios_system command bus;
        // Floe replacement commands (python3, ping, traceroute, dig, nc,
        // sha256sum, apt/pkg/dpkg) shadow the external ones with Floe-backed
        // implementations at registration time below.
        let shellPolicy = ShellCommandPolicy(
            gate: try? CatastrophicActionGate.withBundledPatterns()
        )
        let shellBackend = IOSSystemShellBackend()
        self.localShellService = LocalShellService(
            backend: shellBackend,
            policy: shellPolicy,
            environmentDefaults: Self.localShellEnvironment(),
            rootProvider: WorkspaceCenter.toolRootProvider
        )
        self.shellSessionCenter = ShellSessionCenter(backend: shellBackend, policy: shellPolicy)
        let managedPython = localPythonService.map { ManagedPythonInstallService(python: $0, packagesChanged: { await FloeShellCommands.refreshPythonCommands() }) }
        self.managedPythonInstaller = managedPython
        let capabilityRoot = ((try? FloeArtifactStore.root()) ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Packages", isDirectory: true)
        let wasmCapabilities = BundledWasmCapabilities.load(root: capabilityRoot)
        self.wasmCapabilities = wasmCapabilities
        self.capabilityInstaller = CapabilityInstaller(
            catalog: CapabilityCatalog.bundled(),
            pythonInstaller: managedPython,
            http: HTTPRequestService(),
            packagesRoot: capabilityRoot,
            skillInstaller: SkillCenterCapabilityAdapter(center: skillsCenter),
            fontInstaller: FontStoreCapabilityAdapter(store: fontStore),
            modelInstaller: nil,
            wasmStore: wasmCapabilities
        )

        // Container substrate: layered environments, apt/dpkg and media
        // services. Configured before tool registration so the shell command
        // registry can resolve the active container.
        let environmentRoots = EnvironmentRoots()
        let environmentRegistry = EnvironmentRegistry(
            baseRevision: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev"
        )
        let containerCAS = ContainerCAS(roots: environmentRoots)
        let environmentExecutions = EnvironmentExecutionCoordinator(roots: environmentRoots, registry: environmentRegistry)
        ToolEnvironmentRouting.shared.configure { context in try await environmentExecutions.acquire(context) }
        let containerLifecycle = ContainerLifecycle(
            roots: environmentRoots,
            registry: environmentRegistry,
            cas: containerCAS,
            hooks: ContainerLifecycle.Hooks(
                stopSessions: { [weak self] id in
                    guard let self else { throw FloeError.invalidConfiguration("Shell session service is unavailable") }
                    await self.shellSessionCenter.closeAll(environmentID: id)
                },
                cancelJobs: { id in try await environmentExecutions.stopAndWait(environmentID: id) },
                terminateWorkers: { id in
                    try await environmentExecutions.stopAndWait(environmentID: id)
                    try await FloeShellCommandRegistry.shared.waitForWorkers(environmentID: id)
                    guard !FloeNodeHasActiveTask(id) else {
                        throw FloeError.validationFailed("Node worker has not stopped; environment data was retained")
                    }
                }
            )
        )
        let containerPromote = ContainerPromote(
            roots: environmentRoots,
            registry: environmentRegistry,
            cas: containerCAS
        )
        let packageHTTP = HTTPRequestService()
        let aptEngine = AptEngine(
            downloader: AptEngine.Downloader { url, maxBytes in
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("floe-apt-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temp) }
                _ = try await packageHTTP.download(
                    url: url,
                    timeout: 120,
                    maxBytes: min(maxBytes, 64 * 1024 * 1024),
                    to: temp
                )
                return try Data(floeContentsOf: temp)
            }
        )
        FloePlatformServices.shared.configure(
            registry: environmentRegistry,
            lifecycle: containerLifecycle,
            cas: containerCAS,
            promote: containerPromote,
            aptEngine: aptEngine,
            contextProvider: {
                guard let environment = FloeShellCommandRegistry.shared.context?.environment,
                      let record = await environmentRegistry.record(id: environment.id),
                      record.state == .active, !record.requiresRebuild else { return nil }
                let stack = await environmentRegistry.layerStack(for: record.id, bundledBaseURL: nil)
                let layerURL = environment.writableLayerURL
                let layerKind: LayerKind = record.kind == .session ? .session : .project
                return PackagesCLI.Context(
                    container: AptEngine.Container(id: record.id, rootURL: environmentRoots.rootURL,
                        layerURL: layerURL, layerKind: layerKind, baseRevision: record.baseRevision),
                    sources: AptSources.read(inContainerAt: layerURL), layerURL: layerURL,
                    installed: DpkgDatabase.merged(layers: stack.layers.map { ($0.kind, $0.url) })
                )
            },
            baseSliceURL: nil
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

    /// Environment exported into every local shell run. Paths point at
    /// Floe-owned directories (package bins, a writable HOME, a shell tmp),
    /// never at host paths the sandbox does not own.
    private static func localShellEnvironment() -> [String: String] {
        let root = (try? FloeArtifactStore.root())
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let packagesBin = root.appendingPathComponent("Packages/bin").path
        let pythonBin = root.appendingPathComponent("Packages/pybin").path
        let home = root.appendingPathComponent("ShellHome").path
        let temp = root.appendingPathComponent("ShellTmp").path
        return [
            "PATH": "\(packagesBin):\(pythonBin):/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
            "TMPDIR": temp,
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PS1": "[\\w]\\$ "
        ]
    }

    /// Terminal-state hook for jobs.* background work. A live run is steered
    /// with the outcome; a finished run leaves a durable queued input the user
    /// can see and act on. A local notification always mirrors the outcome.
    private func handleBackgroundJobTerminal(_ job: BackgroundJob) async {        let evidence = job.resultSummary ?? job.lastError ?? job.state.rawValue
        let content = "[Floe background job \(job.id.uuidString)] \(job.targetTool) finished with state=\(job.state.rawValue). "
            + "Evidence excerpt: \(String(evidence.prefix(1_000))). "
            + "Use jobs.result with this jobID for the full output; do not resubmit an unchanged payload."
        do {
            try await conversationCenter.submitRunningInput(
                content: content,
                in: job.conversationID,
                expectedRunID: job.runID,
                mode: .steer,
                selectedModelID: nil,
                workspaceID: nil,
                executionMode: .agent,
                attachments: []
            )
        } catch {
            FloeLogger(category: .app).info(
                "backgroundJob terminal steer failed jobID=\(job.id.uuidString) error=\(error.localizedDescription)"
            )
        }
        let notification = UNMutableNotificationContent()
        notification.title = job.state == .completed ? "后台任务完成" : "后台任务结束：\(job.state.rawValue)"
        notification.body = "\(job.targetTool) · \(String(evidence.prefix(160)))"
        notification.userInfo = ["conversationID": job.conversationID.uuidString, "jobID": job.id.uuidString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "jobs.\(job.id.uuidString)", content: notification, trigger: nil
        ))
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
        registerWorkspaceTools(
            rootProvider: WorkspaceCenter.toolRootProvider,
            compressedArchiveHandler: localPythonService.map(ArchiveCompressedBridge.makeHandler)
        )
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
        // Independent credential-card management over the shared vault.
        registerCredentialManageTool(vault: credentialVault, store: credentialStore)
        // Execution tools (JS, local Python, SSH, HTTP, LAN scan, OCR, barcode).
        // Interactive shell sessions get their guardian backend now that the
        // cloud-workspace channel exists.
        let interactiveShell = self.interactiveShellService
        if let cloudWorkspaceService {
            let remoteAgentTasks = RemoteAgentTaskService(client: cloudWorkspaceService)
            Task {
                await interactiveShell.attachGuardian(GuardianShellClient(
            open: { hostID, term, columns, rows in
                let opened = try await remoteAgentTasks.shellOpen(
                    hostID: hostID, term: term, columns: columns, rows: rows,
                    cancellation: CancellationToken()
                )
                return (shellID: opened.shellID, output: opened.output, alive: opened.alive)
            },
            io: { hostID, shellID, input, waitMs, maxBytes, cancellation in
                let result = try await remoteAgentTasks.shellIO(
                    hostID: hostID, shellID: shellID, input: input,
                    waitMs: waitMs, maxBytes: maxBytes,
                    cancellation: cancellation ?? CancellationToken()
                )
                return (output: result.output, alive: result.alive)
            },
            close: { hostID, shellID in
                try await remoteAgentTasks.shellClose(
                    hostID: hostID, shellID: shellID,
                    cancellation: CancellationToken()
                )
            }
            ))
            }
        }
        registerExecutionTools(
            localPythonService: localPythonService,
            sshCommandService: sshCommandService,
            interactiveShellService: interactiveShell,
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
            remoteHostUpdateObserver: { [weak remoteSessionCenter] hostID, endpointIDs in
                await remoteSessionCenter?.agentDidUpdateHost(
                    hostID: hostID,
                    vncEndpointIDs: endpointIDs
                )
            },
            bluetoothSerialService: bluetoothSerialService,
            webSearchService: WebSearchService(configurations: WebSearchSettingsCenter.resolvedConfigurations),
            includeOnDeviceJavaScript: true
        )
        // Local shell surface: exec.shell, interactive shell.* and apt.
        registerShellTools(
            shell: localShellService,
            sessions: shellSessionCenter,
            pythonInstaller: managedPythonInstaller,
            capabilityInstaller: capabilityInstaller
        )
        FloeShellCommandRegistry.shared.configure(
            python: localPythonService,
            installer: capabilityInstaller,
            wasm: wasmCapabilities
        )
        FloeShellCommands.install()
        Task { await FloeShellCommands.refreshPythonCommands() }
        // Media surface: capabilities, inspection, editing, export,
        // interpolation/super resolution and signed-catalog model management.
        let mediaModelRoot = ((try? FloeArtifactStore.root()) ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MediaModels", isDirectory: true)
        let mediaModelStore = ModelArtifactStore(rootURL: mediaModelRoot) { url, maxBytes in
            let service = HTTPRequestService()
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-model-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            _ = try await service.download(
                url: url,
                timeout: 600,
                maxBytes: Int(min(maxBytes, 512 * 1024 * 1024)),
                to: temporary
            )
            return try Data(floeContentsOf: temporary)
        }
        MediaToolRegistration.register(
            appBuild: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev",
            modelProvider: { await MediaModelCatalogService.shared.report() },
            modelStore: mediaModelStore,
            modelCatalogProvider: { await MediaModelCatalogService.shared.catalog() }
        )
        Task {
            await MediaModelCatalogService.shared.bind(store: mediaModelStore)
            _ = await MediaModelCatalogService.shared.catalog()
        }
        // Background jobs (jobs.*): long downloads and Python data work run
        // off the run's critical path. Registered after the execution tools so
        // submit-time availability checks see every supported target runner.
        let jobDownloads = JobDownloadCoordinator(
            database: database,
            reattacher: WorkspaceRootReattacher(store: SQLiteWorkspaceStore(database: database))
        ) { [weak self] job in
            await self?.handleBackgroundJobTerminal(job)
        }
        backgroundJobService = registerBackgroundJobTools(
            database: database,
            onTerminal: { [weak self] job in
                await self?.handleBackgroundJobTerminal(job)
            },
            downloadHandler: { job, context in
                try await jobDownloads.take(job: job, context: context)
            },
            downloadCancelHandler: { jobID in
                await jobDownloads.cancel(jobID: jobID)
            },
            downloadTaskLiveness: { jobID in
                await jobDownloads.hasLiveTask(jobID: jobID)
            }
        )
        // Browser automation.
        registerBrowserTools(center: browserCenter)
        registerMailTools()
        // Local preview server.
        registerPreviewTools(environment: previewCenter)
        // Skill authoring.
        registerSkillTools(creator: LocalSkillCreator(center: skillsCenter), manager: LocalSkillCreator(center: skillsCenter))
        // Bundled domain skills: seed/upgrade in the background; failures are
        // logged inside the seeder and never block startup.
        if shouldSeedBundledSkills { Task { await skillsCenter.seedBuiltinDomainSkills() } }
        // Durable memory.
        registerTaskChecklistTools(store: TaskChecklistStore(database: database))
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
            connect: { [weak remoteSessionCenter] in
                try await remoteSessionCenter?.activeOrConnectVNCSession()
            },
            reconnect: { [weak remoteSessionCenter] in
                try await remoteSessionCenter?.reconnectToolVNCSession()
            },
            disconnect: { [weak remoteSessionCenter] in
                await remoteSessionCenter?.disconnectToolVNCSessions()
                    ?? VNCToolConnectionStatus(state: .unconfigured, configuredEndpointCount: 0)
            }
        ) { [weak remoteSessionCenter] in
            // Observation and input tools are honest consumers of an
            // existing session. Only vnc.connect/reconnect may open a socket.
            await remoteSessionCenter?.activeVNCSession()
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
    ) -> (python: RemotePythonService, ssh: SSHCommandService, interactiveShell: InteractiveShellSessionService) {
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
        // Interactive shell sessions (ssh.shell.*) ride the same host store
        // and credential path; the guardian backend is attached by the caller
        // once CloudWorkspaceService exists.
        let ptyFactory: InteractiveShellSessionService.DirectPTYFactory = { hostID, term, columns, rows in
            guard let stored = try await hostStore.host(id: hostID) else {
                throw RemotePythonError.hostNotFound(hostID)
            }
            let profile = try RemoteHostProfile(stored: stored)
            do {
                let connection = try await sshService.connect(
                    profile: profile,
                    credentialResolver: { reference in
                        let store = KeychainStore(
                            service: "org.floeagent.ios.secrets",
                            synchronizable: reference.synchronizable
                        )
                        return try store.read(account: reference.keychainAccount)
                    },
                    hostKeyDecision: { _ in false }
                )
                return try await connection.openPTY(term: term, columns: columns, rows: rows)
            } catch let error as SSHConnectionError {
                throw RemotePythonError.sshConnection(error)
            }
        }
        let interactiveShell = InteractiveShellSessionService(
            directFactory: ptyFactory,
            defaultHostProvider: defaultHostProvider
        )
        return (python, ssh, interactiveShell)
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
            // In-process jobs from the previous process can never resume;
            // mark them interrupted so the model can resubmit honestly.
            if let backgroundJobService {
                _ = try? await backgroundJobService.reconcileInterruptedOnLaunch()
            }
            let fontActivationFailures = await fontStore.activateManagedFonts()
            if !fontActivationFailures.isEmpty {
                FloeLogger(category: .tools).warning(
                    "fontActivationFailed count=\(fontActivationFailures.count)"
                )
            }
            let bundledFontFailures = BundledFontRegistrar.activateBundledFonts()
            if !bundledFontFailures.isEmpty {
                FloeLogger(category: .tools).warning(
                    "bundledFontActivationFailed count=\(bundledFontFailures.count)"
                )
            }
            // Approval/background choices affect the very first task created
            // after launch. Restore them before `persistenceReady` exposes the
            // composer; settings-screen visitation must never be required.
            await settingsCenter.loadLaunchPreferences()
            await configurationSync.setCredentialStore(credentialStore)
            await credentialVault.drainDeletionQueue()
            _ = await workspaceCenter.retryPendingLocalCleanup()
            // Replays offline cloud deletion tombstones. The endpoint is
            // idempotent, so launch-time retry is safe after crashes too.
            Task { [cloudWorkspaceCleanupQueue] in
                _ = await cloudWorkspaceCleanupQueue.drain()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-batch-fixture") {
                let fixtureID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
                if try await conversationStore.conversation(id: fixtureID) == nil {
                    let fixture = ConversationRecord(id: fixtureID, title: "批量选择测试", createdAt: Date(), updatedAt: Date())
                    try await conversationStore.saveConversation(fixture)
                    _ = try await SQLiteWorkspaceStore(database: database).ensureWorkspace(conversationID: fixtureID, title: fixture.title)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-checklist-fixture") {
                let taskID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
                let runID = UUID(uuidString: "8C09095D-7CB9-4BB0-AC5D-3C58CB71A2B4")!
                let store = TaskChecklistStore(database: database)
                if try await store.latest(conversationID: taskID) == nil {
                    try await runStore.saveRun(.init(id: runID, conversationID: taskID, state: "completed", goal: "合成待办验收", startedAt: Date(), endedAt: Date()))
                    _ = try await store.update(.init(expectedRevision: 0, title: "文档更新", steps: [
                        .init(id: "read", title: "检查原始文档", status: .completed, evidence: ["检查记录.txt"]),
                        .init(id: "edit", title: "更新图表与正文", status: .inProgress),
                        .init(id: "verify", title: "保存并重新打开验证"),
                        .init(id: "removed", title: "已取消的额外导出", status: .cancelled)
                    ]), runID: runID, operationID: "ui-fixture")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-pdf-fixture") {
                let fixtureID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
                let record = try await SQLiteWorkspaceStore(database: database).ensureWorkspace(
                    conversationID: fixtureID, title: "批量选择测试"
                )
                let lease = try await workspaceCenter.acquireTaskRoot(record, conversationID: fixtureID)
                defer { lease.release() }
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
                let bytes = renderer.pdfData { context in
                    for page in 1...2 {
                        context.beginPage()
                        ("Floe PDF Preview · Page \(page)" as NSString).draw(
                            at: CGPoint(x: 48, y: 64),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 26, weight: .semibold)]
                        )
                        ("Inline reading, fullscreen, and return to the same document." as NSString).draw(
                            in: CGRect(x: 48, y: 118, width: 490, height: 80),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 16)]
                        )
                        UIColor.systemBlue.setFill()
                        context.cgContext.fill(CGRect(x: 48, y: 220, width: 100 * page, height: 90))
                    }
                }
                try bytes.write(to: lease.url.appendingPathComponent("预览验收.pdf"), options: .atomic)
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-material-fixture") {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("素材缩略图验收.png")
                defer { try? FileManager.default.removeItem(at: url) }
                let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
                    UIColor.systemYellow.setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: 240, y: 40, width: 160, height: 160))
                    ("FLOE MATERIAL" as NSString).draw(at: CGPoint(x: 150, y: 260),
                        withAttributes: [.font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.white])
                }
                if let data = image.pngData() {
                    try data.write(to: url, options: .atomic)
                    _ = try await CreativeAssetIngestionService(assetStore: creativeAssetStore).importLocalFile(url)
                }
                UserDefaults.standard.set(false, forKey: "canvas.materials.posterLayout")
            }
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
            // Office engine prewarm. cok_init_2 blocks its calling thread for
            // seconds, so run it at a quiet moment after launch instead of on
            // the first document open. Device-only framework; skipped in Low
            // Power Mode and via the office.prewarm.disabled default.
            #if canImport(FloeOfficeNative)
            if !ProcessInfo.processInfo.isLowPowerModeEnabled,
               !UserDefaults.standard.bool(forKey: "office.prewarm.disabled") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    FloeOfficeNativeRuntime.shared.prepare { _ in }
                }
            }
            #endif
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
                ?? .failClosed(reason: "Catastrophic-action rules are unavailable"),
            seedBundledSkills: false
        )
    }
}
#endif
