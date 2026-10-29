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
import Combine
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

/// Late-binding relay for the one-time long-run duration advisory sink.
/// Mirrors the existing `LocalServiceReadyRelay` idiom: the monitor is
/// constructed during `AppEnvironment.init` — before the job service, the
/// coordinator and `self` are fully initialized — so its sink captures ONLY
/// this relay (Swift 6 refuses a `self` capture, weak or not, before every
/// stored property exists). The real handler is installed exactly once
/// after the services are wired; a milestone that arrives before
/// installation is dropped silently (it cannot in practice: the threshold is
/// 600 s and installation happens at startup).
final class DurationAdvisoryRelay: @unchecked Sendable {
    typealias Handler = @Sendable (
        LongRunAdvisoryMilestone, @escaping LongRunDurationReminder.DeliveryFence
    ) async -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    func deliver(
        _ milestone: LongRunAdvisoryMilestone,
        fence: @escaping LongRunDurationReminder.DeliveryFence
    ) async {
        let handler = lock.withLock { self.handler }
        await handler?(milestone, fence)
    }
}

/// Owns the app's long-lived services and stores. Created once at launch and
/// injected through the SwiftUI environment. All stores are protocol-typed so
/// tests and previews can substitute in-memory doubles.
@MainActor
final class AppEnvironment: ObservableObject {

    #if DEBUG
    // Hosted qualification joins the actual launch instance instead of
    // opening a second database pool and replacing app-owned service routing.
    static weak var qualificationLaunchEnvironment: AppEnvironment?
    #endif

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
    let childResumeService: ChildResumeService

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
    /// Local Python capability (Linux guest backend since Phase 2).
    /// Unavailable with the honest reason when the Linux component is not
    /// installed in this build/on this device.
    let localPythonProbe: FloeExecution.LocalPythonCapabilityProbe
    /// Local Node.js capability (same Linux guest backend and component).
    let localNodeProbe: FloeExecution.LocalNodeCapabilityProbe
    /// Real remote-Python capability probe (FloeExecution), surfaced to
    /// SettingsCenter so the UI reads live state instead of a placeholder.
    let remotePythonProbe: FloeExecution.RemotePythonProbe
    /// Local shell substrate (ios_system-backed) shared by exec.shell and the
    /// interactive shell.* tools. It routes through `RoutingLocalShellBackend`
    /// so shell runs in a `runtime == .linux` environment execute inside that
    /// environment's guest instead of the native substrate.
    let localShellService: LocalShellService
    /// One-time long-run duration advisory monitor (new time policy
    /// 2026-10-26: default execution is unlimited; ONE reminder at 600
    /// seconds of host monotonic elapsed execution, work continues). Shared
    /// by the foreground shell service and the background job service so one
    /// unit of work never advises twice. Observe-only: it never changes any
    /// run/job/command state.
    private let durationReminder: LongRunDurationReminder
    /// Late-binding sink relay (see `DurationAdvisoryRelay`): keeps the
    /// monitor's sink free of any `self` capture during init.
    private let durationAdvisoryRelay: DurationAdvisoryRelay
    let shellSessionCenter: ShellSessionCenter
    /// One TinyEMU guest service for the whole app: the registry owns exactly
    /// one guest per `runtime == .linux` environment and is the single place
    /// exec.shell and the apt/dpkg entry reach it today; guest localService
    /// daemons use the same session/forward API when their consumer lands.
    /// Explicit tool calls retain their resolved environment. nil
    /// only where the engine is not built in.
    let linuxGuestService: TinyEMULinuxCommandService?
    /// Trusted lazy runtime-component deployment (Impeccable engine): records
    /// immutable task/run/environment-bound plans from verified exact skill
    /// reads and prepares download/staging/probe only at the approved
    /// exec.shell boundary through the routing backend's injected closure.
    let skillRuntimeComponents: SkillRuntimeComponentCenter
    /// Single lifecycle manager shared by the execution tools and the
    /// runtime's unknown-outcome reconciliation bridge. One instance per app
    /// so the authority probes (quiet-stop facts, launch generation, epoch)
    /// observe exactly the state the tools mutate.
    let linuxGuestLifecycle: LinuxGuestLifecycleManager
    /// App-facing half of the Build 222 heavy-runtime arbitration: the local
    /// model start reports active Linux guests/services here and the alert in
    /// `FloeAgentApp` gets the explicit confirmation before anything is
    /// stopped (or the local request is refused).
    let heavyRuntimeConflictCenter: HeavyRuntimeConflictCenter
    /// Layered-environment registry. Exposed so task-scoped wiring (for
    /// example the Notes document assistant) can ensure its own session
    /// environment with an explicit backend instead of inheriting a shared
    /// or default one.
    let environmentRegistry: EnvironmentRegistry
    private let environmentExecutions: EnvironmentExecutionCoordinator
    private let skillDependencyPrepareLinux: LinuxPreparationHandler
    lazy var localTerminals = LocalTerminalStore(sessions: shellSessionCenter)
    /// Managed Linux Python installer shared by internal services and exec.shell.
    let managedPythonInstaller: ManagedPythonInstallService?
    /// Reviewed capability catalog and install routing for internal provisioning.
    // SkillsCenter needs the fully initialized environment. Resolve this
    // dependency only when tool registration first asks for the installer.
    lazy var capabilityInstaller = CapabilityInstaller(
        catalog: CapabilityCatalog.bundled(),
        pythonInstaller: managedPythonInstaller,
        http: HTTPRequestService(),
        packagesRoot: capabilityRoot,
        skillInstaller: SkillCenterCapabilityAdapter(center: skillsCenter),
        fontInstaller: FontStoreCapabilityAdapter(store: fontStore),
        modelInstaller: nil,
        wasmStore: wasmCapabilities,
        toolCatalog: ToolCapabilityCatalog.bundled()
    )
    private let capabilityRoot: URL
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
    /// Owns the bounded App Group widget snapshot. It observes live
    /// conversation/run projections; it never owns a second task store.
    private lazy var _widgetSnapshotCenter = WidgetSnapshotCenter(
        runStore: runStore,
        conversationStore: conversationStore,
        store: WidgetTaskSnapshotStore.appGroup()
    )
    private lazy var _remoteSessionCenter = RemoteSessionCenter(environment: self)
    private lazy var _filesCenter = FilesCenter(environment: self)
    /// App-owned inbound-share queue/consumer (S5 P1). It lives for the
    /// process, not a Home view, and never sends or starts a task by itself.
    private lazy var _shareIntakeCenter = ShareIntakeCenter(
        inbox: try? ShareInbox.applicationGroup(),
        staging: FilesCenterShareAttachmentStaging(filesCenter: filesCenter)
    )
    private lazy var _documentIntakeCenter = DocumentIntakeCenter(
        root: DocumentIntakeCenter.applicationSupportRoot()
    )
    /// Durable 导入手记 / 导入任务 / 导入画布 chooser for ambiguous inbound
    /// entries. It owns only the explicit-decision ledger and the choice
    /// execution; the share card's Task pipeline, the queue's Notes
    /// pipeline and the existing material/Canvas services stay the single
    /// importers. Never navigates by itself and never mutates editor state.
    private lazy var _importDestinationCenter = ImportDestinationCenter(
        inbox: try? ShareInbox.applicationGroup(),
        // Real Canvas-owned committer (nodes + new canvas under the
        // ledger's planned identities; CAS + sync outbox + notification).
        canvas: CanvasExternalImportCommitter(
            ingestion: CreativeAssetIngestionService(assetStore: creativeAssetStore),
            assets: creativeAssetStore,
            sync: canvasSyncOperationStore
        ),
        // Read-only persisted-target list over the existing conversation
        // store (all ordinary, non-archived tasks; the picker pages them).
        taskProvider: ConversationStoreTaskDestinationProvider(store: conversationStore)
        // Existing-task landings go through the unified
        // ComposerDraftStore.acceptImportedDraft entrypoint owned by the
        // draft-sync job — closed slots commit durably and open composers
        // fold in the same turn; no parallel live-owner plumbing here.
    )
    private lazy var _workspaceCenter = WorkspaceCenter(environment: self)
    private lazy var _sourceControlCenter = SourceControlCenter(environment: self)
    private lazy var _settingsCenter = SettingsCenter(environment: self)
    private lazy var skillDependencies: SkillDependencyPreparationCenter = {
        let guests = linuxGuestService
        let wheelRoot: URL?
        if let root = try? RuntimeV2Layout.production().cacheDirectory(kind: "pip") {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                wheelRoot = root
            } catch { wheelRoot = nil }
        } else { wheelRoot = nil }
        let wheelGuestPath = wheelRoot.map { _ in "/floe/cache/pip/official-wheels" }
        let operations: (any SkillDependencyPackageOperating)?
        if let guests, let installer = managedPythonInstaller {
            operations = LinuxGuestSkillDependencyPackageOperations(
                managedPython: installer, languagePackages: LinuxGuestLanguagePackages(runner: guests),
                wheelStoreGuestPath: wheelGuestPath)
        } else { operations = nil }
        let components = skillRuntimeComponents
        return SkillDependencyPreparationCenter(
            authorityProvider: { [weak self] id in
                await self?.skillsCenter.dependencyAuthorization(skillID: id)
            },
            environmentResolver: { [weak self] id in
                await self?.resolveSkillDependencyEnvironment(id)
            },
            launchGeneration: { id in
                await guests?.runtimeStates().first { $0.environmentID == id && $0.running }?.identity.launchGeneration
            },
            operations: operations,
            prepareEnvironment: { [weak self] id, cancellation in
                guard let self else { throw FloeError.invalidConfiguration("App services are unavailable") }
                _ = try await self.skillDependencyPrepareLinux(LinuxPreparationRequest(
                    environmentID: id, cancellation: cancellation ?? CancellationToken()))
            },
            runtimeComponentProbe: { id, runID, cancellation in
                if await components.prepareBindings(environmentID: id, runID: runID, cancellation: cancellation) != nil {
                    return nil
                }
                return await components.state(environmentID: id, componentID: SkillRuntimeDependency.knownComponentID)
                    .deferredReason ?? "Runtime component is not ready"
            },
            pipWheels: { specs in
                try await ManagedPythonPackageInspector.fetchVerifiedWheels(specs: specs).map {
                    SkillDependencyWheelBundle(spec: $0.spec, filename: $0.filename,
                        sha256: $0.sha256, size: $0.size, bytes: $0.bytes)
                }
            },
            wheelStoreURL: wheelRoot, wheelStoreGuestPath: wheelGuestPath,
            appVersion: { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" },
            persistenceRoot: (try? FloeArtifactStore.root())?.appendingPathComponent("SkillDependencies", isDirectory: true))
    }()
    /// Skill bundle delivery uses the SAME descriptor-time share table the
    /// guest boots with, so an exact read that happens BEFORE the task's first
    /// exec.shell still stages into the workspace the later first boot mounts.
    /// No guest needs to be running and no new share or permission is added; a
    /// host without the local Linux service simply reports resources as
    /// unavailable.
    private lazy var _skillsCenter: SkillsCenter = {
        let guestService = linuxGuestService
        return SkillsCenter(
            environment: self,
            resourceStager: SkillWorkspaceResourceStager { environmentID in
                await guestService?.linuxGuestPathMap(environmentID: environmentID)
            },
            runtimeComponents: skillRuntimeComponents,
            dependencyPreparation: skillDependencies
        )
    }()
    private lazy var _mcpServiceCreationBackend = MCPServiceCreationAppBackend(
        environment: self, connections: .shared
    )
    private lazy var _mcpServiceCreationCoordinator: MCPServiceCreationCoordinator = {
        let backend = _mcpServiceCreationBackend
        let coordinator = MCPServiceCreationCoordinator(
            backend: backend, settings: SQLiteSettingsStore(database: database)
        )
        backend.onServiceEvent = { [weak coordinator] event in
            Task { await coordinator?.receive(event) }
        }
        return coordinator
    }()
    lazy var skillAuthoring: SkillAuthoringCoordinator = {
        let coordinator = SkillAuthoringCoordinator(environment: self)
        coordinator.onPromotion = { [weak self] id in
            await self?.conversationCenter.authoringConversationBecameVisible(id)
        }
        return coordinator
    }()
    private lazy var _contentUpdateCenter = ContentUpdateCenter(environment: self)
    private lazy var _memoryCenter = MemoryCenter(environment: self)
    private lazy var _memoryDreamService = MemoryDreamService(environment: self)
    private lazy var _skillDreamService = SkillDreamService(environment: self)
    private lazy var _ttsSettingsService = TTSSettingsService()
    private var speechMemoryWarningCancellable: AnyCancellable?
    private lazy var _localSpeechRuntime = LocalSpeechRuntime()
    private lazy var _ttsSpeechService = TTSSpeechService(localProvider: localSpeechRuntime)
    private lazy var _assistantAudioService = AssistantAudioService(
        settings: ttsSettingsService, speech: ttsSpeechService)
    var assistantAudioService: AssistantAudioService { _assistantAudioService }
    private lazy var _speechService: SpeechService = {
        let service = SpeechService()
        service.configure(settings: ttsSettingsService, speech: ttsSpeechService, localRuntime: localSpeechRuntime)
        return service
    }()
    let continuousVoicePresentation = ContinuousVoicePresentation()
    private lazy var _backgroundRunCoordinator = BackgroundRunCoordinator(environment: self)
    private lazy var _mediaGenerationService = MediaGenerationService(environment: self)
    private lazy var _creativeAssetStore: CreativeAssetStore = {
        CreativeAssetStore(
            database: database,
            reachabilityGuard: { assetID in
                // Fail-closed reachability backstop for the (deferred)
                // prune/delete paths: refuse to delete bytes any persisted
                // canvas project still reaches, and retain on incomplete
                // knowledge. Physical reclamation itself is DEFERRED in
                // this release (deferPhysicalReclamation) because there is
                // no shared lease with canvas publishers.
                WorkspaceCanvasRegistry.reachability(of: assetID)
            },
            // No shared lease between canvas publishers and the prune
            // decision exists in this release, so physical byte reclamation
            // conservatively defers everywhere; deferred bytes surface via
            // orphanedAssets() for a later cleanup.
            deferPhysicalReclamation: true)
    }()
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
    private lazy var _pipAudioService = PiPAudioService()
    /// Dictation-yields subscription for the task PiP sound service.
    private var pipAudioRecordingCancellable: AnyCancellable?
    private lazy var _webSearchSettingsCenter = WebSearchSettingsCenter()
    private lazy var _mcpSettingsCenter = MCPSettingsCenter.shared
    private lazy var _workbenchCenter = WorkbenchCenter(
        rootProvider: WorkspaceCenter.toolRootProvider,
        bridge: WorkbenchAIBridge.live(environment: self)
    )
    /// Single mutation/commit authority for CAD documents (visible editor and
    /// agent tools share it). The decision deliverer routes native CAD
    /// proposal outcomes to the originating conversation through the same
    /// durable runtime-input ingress the 2D path uses; reconciliation of
    /// interrupted applies and undelivered decisions runs at bootstrap.
    private lazy var _cadDocumentCenter: CadDocumentCenter = {
        // The FINAL argument is the trusted origin marker of the decision: an
        // automatic runtime-authority apply records `tool-automatic` (so the
        // chat surface projects the receipt onto the tool step), a human
        // CAD-UI confirmation records `user`. Without the origin-aware wiring
        // both paths would fall back to the historical `user` default.
        let center = CadDocumentCenter { [weak self] conversationID, proposalID, decision, revision, sha256, origin in
            guard let self else { return }
            switch origin {
            case .toolAutomatic:
                try await self.conversationCenter.recordAutomaticProposalDecision(
                    conversationID: conversationID, proposalID: proposalID, decision: decision,
                    revision: revision, sha256: sha256)
            case .user:
                try await self.conversationCenter.recordProposalDecision(
                    conversationID: conversationID, proposalID: proposalID, decision: decision,
                    revision: revision, sha256: sha256)
            }
        }
        return center
    }()
    /// Single authority for engine-level Office edits (document.office.edit);
    /// routes through the live editor session registered per document.
    private lazy var _officeCommandCenter = OfficeCommandCenter()

    var conversationCenter: ConversationCenter { _conversationCenter }
    /// Home-screen widget snapshot owner. Refreshes on actual run/title/
    /// deletion/temporary-session changes; it grants no task authority.
    var widgetSnapshotCenter: WidgetSnapshotCenter { _widgetSnapshotCenter }

    /// Shared, published design-entry state (durable-derived; see
    /// DesignEntryStateCenter). The root re-vends it as an environment
    /// object so toolbars update live.
    let designEntryState = DesignEntryStateCenter()
    /// Set during tool registration; used at launch to reconcile interrupted
    /// in-process jobs and by UI surfaces that list active background work.
    private(set) var backgroundJobService: BackgroundJobService?
    #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
    private var alarmService: SystemAlarmService?
    #endif
    var remoteSessionCenter: RemoteSessionCenter { _remoteSessionCenter }
    var filesCenter: FilesCenter { _filesCenter }
    var shareIntakeCenter: ShareIntakeCenter { _shareIntakeCenter }
    var documentIntakeCenter: DocumentIntakeCenter { _documentIntakeCenter }
    var importDestinationCenter: ImportDestinationCenter { _importDestinationCenter }
    var sharedDocumentsCenter: SharedDocumentsCenter { .shared }
    var workspaceCenter: WorkspaceCenter { _workspaceCenter }
    var sourceControlCenter: SourceControlCenter { _sourceControlCenter }
    /// Lazily created on first access; ConversationCenter reads
    /// `defaultAgentMode` through it without a construction cycle.
    var settingsCenter: SettingsCenter { _settingsCenter }
    var skillsCenter: SkillsCenter { _skillsCenter }

    private func resolveSkillDependencyEnvironment(_ id: String) async -> ToolEnvironment? {
        guard let record = await environmentRegistry.record(id: id),
              record.effectiveExecutionBackend == .linuxVM else { return nil }
        do {
            // Reuse the canonical layer/variable resolution. The caller's
            // tool lease remains held throughout dependency preparation.
            let lease = try await environmentExecutions.acquireManagement(
                environmentID: id, cancellation: CancellationToken())
            let resolved = lease.context.environment
            await lease.finish()
            return resolved
        } catch { return nil }
    }
    var mcpServiceCreationBackend: MCPServiceCreationAppBackend { _mcpServiceCreationBackend }
    var mcpServiceCreationCoordinator: MCPServiceCreationCoordinator { _mcpServiceCreationCoordinator }
    /// Signed declarative-content updates (prompts/help/templates/providers).
    var contentUpdateCenter: ContentUpdateCenter { _contentUpdateCenter }
    var memoryCenter: MemoryCenter { _memoryCenter }
    var memoryDreamService: MemoryDreamService { _memoryDreamService }
    var skillDreamService: SkillDreamService { _skillDreamService }
    var speechService: SpeechService { _speechService }
    var ttsSettingsService: TTSSettingsService { _ttsSettingsService }
    var ttsSpeechService: TTSSpeechService { _ttsSpeechService }
    var localSpeechRuntime: LocalSpeechRuntime { _localSpeechRuntime }
    var backgroundRunCoordinator: BackgroundRunCoordinator { _backgroundRunCoordinator }
    var mediaGenerationService: MediaGenerationService { _mediaGenerationService }
    /// Design workflow adapters bound to the real editor/asset services.
    lazy var designAdapterCenter: DesignAdapterCenter = {
        let center = DesignAdapterCenter(adapters: Self.makeDesignAdapters(environment: self))
        center.bind(environment: self)
        return center
    }()
    /// Live capability matrix over the real services (Office session, Linux
    /// guest, configured media routes, CAD kernel, Notes/PDF). A capability
    /// is offered only when static wiring AND the live probe agree; a gap
    /// carries the honest reason + recovery, never a static "ready".
    lazy var designCapabilityMatrix: DesignCapabilityMatrix = {
        DesignCapabilityProbeFactory.makeMatrix(environment: self)
    }()
    /// Central design composition (constructed ONCE).
    ///
    /// Canvas keeps its ONE authority: this service is the trusted-UI
    /// `DesignCanvasService` the panel and `DesignWorkflowActions` use; a run
    /// binding is still enforced when a caller passes a runID. The generic
    /// owner workflow below FAILS CLOSED for every `.canvasNode` operation
    /// (T3 C14), so there is never a second mutable authority for a node.
    lazy var designCanvasService: DesignCanvasService = {
        let database = self.database
        return DesignCanvasService(
            repository: FileCanvasDocumentRepository(),
            authorize: { runID, canvasID in
                // Trusted in-app UI carries no run; an agent run must be
                // bound to the exact canvas through the durable context.
                guard let runID else { return true }
                let store = CanvasRunContextStore(database: database)
                guard let context = try? await store.context(runID: runID) else { return false }
                return context.canvasID == canvasID
            })
    }()
    /// Production idempotent result publication (existing FilesCenter
    /// staging/ConversationStore attachments and CreativeAssetStore).
    lazy var designResultPublicationPort: AppDesignResultPublicationPort = {
        AppDesignResultPublicationPort(environment: self)
    }()
    /// The typed target service + generic owner workflow shared by the UI
    /// entrances and (once T5 wires them) the agent tools. The factory uses
    /// the SAME envelope/payload stores for both the workflow and the
    /// creative port; no parallel state.
    lazy var designComposition: (targets: DesignTargetService, workflow: DesignOwnerWorkflow) = {
        let made = DesignOwnerWorkflowFactory.make(
            environment: self,
            canvasService: designCanvasService,
            adapters: designAdapterCenter,
            decisionSink: { [weak self] conversationID, proposalID, decision, revision, sha256 in
                guard let self else {
                    throw FloeError.internalError("App environment unavailable for design decision delivery")
                }
                try await self.conversationCenter.recordProposalDecision(
                    conversationID: conversationID,
                    proposalID: proposalID,
                    decision: "design-candidate-\(decision)",
                    revision: revision,
                    sha256: sha256)
            },
            publicationPort: designResultPublicationPort)
        return (targets: made.service, workflow: made.workflow)
    }()
    var designTargetService: DesignTargetService { designComposition.targets }
    var designOwnerWorkflow: DesignOwnerWorkflow { designComposition.workflow }
    /// The ONE concrete adoption-confirmation service shared by the trusted
    /// UI (mints the assistant grant for an exact target/candidate/base/
    /// proposed-revision/mode) and the registered `design.adopt` tool
    /// (validates + atomically consumes it). Same instance → same
    /// `ApprovalGrantStore`; no second confirmation store.
    var designOwnerAdoptionGrants: DesignOwnerAuthorization { .shared }
    var creativeAssetStore: CreativeAssetStore { _creativeAssetStore }
    var workbenchCenter: WorkbenchCenter { _workbenchCenter }
    var cadDocumentCenter: CadDocumentCenter { _cadDocumentCenter }
    var officeCommandCenter: OfficeCommandCenter { _officeCommandCenter }
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
    /// Task PiP sound service (ambient loops, generic stage narration,
    /// attention cues). All cross-service wiring installs once here: the PiP
    /// video surface owns start/stop and transport pause, answer speech and
    /// dictation duck/yield the loop, and the two same-category session
    /// owners consult each other's real state before either releases the
    /// shared AVAudioSession.
    var pipAudioService: PiPAudioService {
        let service = _pipAudioService
        if service.preferencesProvider == nil {
            service.preferencesProvider = { [weak self] in
                self?.settingsCenter.pipAudioPreferences ?? PiPAudioPreferences()
            }
            let video = backgroundVideoService
            video.onAudioOwnerChange = { [weak service] active in
                service?.handleTaskPiPActiveChanged(active)
            }
            video.onPiPTransportControl = { [weak service] playing in
                service?.handlePiPTransportControlled(playing)
            }
            video.onPiPWindowDismissed = { [weak service] in
                service?.handlePiPWindowDismissed()
            }
            video.externalAudioSessionOwner = { [weak service] in
                service?.holdsSharedAudioSession ?? false
            }
            video.onAudioSessionReleaseDeferred = { [weak service] in
                service?.adoptDeferredSessionLease()
            }
            // Synchronous dictation gates for BOTH session owners: the real
            // voice-input state decides, never a lagging publisher event and
            // never category equality (a retained `.record` category after
            // recording must not block playback forever).
            video.externalRecordingActive = { [weak self] in
                guard let self else { return false }
                return self.voiceInput.state.hasSession || self.voiceInput.state == .requestingPermission || self.continuousVoicePresentation.isPresented
            }
            service.isRecordingActiveNow = { [weak self] in
                guard let self else { return false }
                return self.voiceInput.state.hasSession || self.voiceInput.state == .requestingPermission || self.continuousVoicePresentation.isPresented
            }
            service.setSessionReleaseCheck { [weak video] in
                video?.audioSessionMayBeReleased ?? true
            }
            let answerSpeech = speechService
            if answerSpeech.onSpeakingChanged == nil {
                answerSpeech.onSpeakingChanged = { [weak service] speaking in
                    service?.handleAnswerSpeechActive(speaking)
                }
            }
            // Dictation owns the record session: the ambient loop yields for
            // the whole voice-input session and resumes only while its own
            // task-PiP owner is still active.
            pipAudioRecordingCancellable = voiceInput.$state
                .combineLatest(continuousVoicePresentation.$request)
                .map { state, request in state.hasSession || state == .requestingPermission || request != nil }
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak service] recording in
                    Task { @MainActor [weak service] in
                        service?.handleRecordingActive(recording)
                    }
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

    // S3 external-automation readiness. ONE in-flight bootstrap/launch-recovery
    // attempt per process: view rebuilds and concurrent App Intents join it
    // instead of re-running interrupted recovery over runs that were just
    // started. A finished attempt retires before its completion is visible, so
    // a later call retries a failed launch instead of rejoining finished work.
    // Successful repeats are no-ops. The App keeps the single environment.
    private let bootstrapGate = FloeSingleFlightGate()
    private let externalAutomationGate = FloeSingleFlightGate()
    private var bootstrapDidCompleteSuccessfully = false
    private var externalAutomationReady = false
    private var backgroundDownloadInitialization: Task<Void, Never>?
    #if DEBUG
    /// Hosted-qualification observability only: how many times the launch
    /// body and the shared external-automation body actually executed. Product
    /// code never reads these; they let tests prove join/skip/retry instead of
    /// inferring it from timing.
    private(set) var bootstrapExecutionCount = 0
    var isBackgroundDownloadInitializationRunning: Bool { backgroundDownloadInitialization != nil }
    private(set) var externalAutomationExecutionCount = 0
    #endif

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
        StorageSuspensionCoordinator.shared.start()
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
        self.childResumeService = ChildResumeService(store: SQLiteChildRunStore(database: database))
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
        self.remotePythonProbe = FloeExecution.RemotePythonProbe(service: pythonService)

        // Local shell substrate. The backend is the ios_system command bus;
        // Floe replacement commands (python3, ping, traceroute, dig, nc,
        // sha256sum, apt/pkg/dpkg) shadow the external ones with Floe-backed
        // implementations at registration time below.
        let shellPolicy = ShellCommandPolicy(
            gate: try? CatastrophicActionGate.withBundledPatterns()
        )
        let nativeShellBackend = IOSSystemShellBackend()
        let capabilityRoot = ((try? FloeArtifactStore.root()) ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Packages", isDirectory: true)
        self.capabilityRoot = capabilityRoot
        let wasmCapabilities = BundledWasmCapabilities.load(root: capabilityRoot)
        self.wasmCapabilities = wasmCapabilities


        // Container substrate: layered environments, apt/dpkg and media
        // services. Configured before tool registration so the shell command
        // registry can resolve the active container.
        let environmentRoots = EnvironmentRoots()
        let environmentRegistry = EnvironmentRegistry(
            baseRevision: FloePlatformServices.environmentBaseRevision,
            compatibleBaseRevisions: ["156"]
        )
        self.environmentRegistry = environmentRegistry
        let containerCAS = ContainerCAS(roots: environmentRoots)
        let environmentExecutions = EnvironmentExecutionCoordinator(roots: environmentRoots, registry: environmentRegistry)
        self.environmentExecutions = environmentExecutions
        ToolEnvironmentRouting.shared.configure { context in try await environmentExecutions.acquire(context) }

        // Linux guest backend: one TinyEMU-backed service for the whole app,
        // injected into the platform services seam so apt/dpkg, exec.shell and
        // Python scripts share the same guest interpreter per Linux
        // environment. Native environments never touch it
        // (`ownsLinuxEnvironment` is false without `executionBackend .linuxVM`).
        let linuxGuests = LinuxGuestBackendAssembly.makeService(
            registry: environmentRegistry,
            artifactRoot: try? FloeArtifactStore.root(),
            // Injected here, not read from the lazy workspace center: a
            // cold-start guest start must resolve an external workspace's
            // security scope before any UI object exists.
            workspaceStore: SQLiteWorkspaceStore(database: database)
        )
        self.linuxGuestService = linuxGuests
        // Optional guest → host archive bridge: a `floe-host archive …`
        // command inside an environment's guest delegates to the host's
        // native archive engine over bounded console control frames. The
        // capability is advertised in the HELLO handshake only while this
        // factory is installed, and every request is scoped to the
        // environment's own 9p share table (`linuxGuestPathMap`); a guest
        // path outside those shares is refused before any host filesystem
        // access. Installing it here — before any guest can start — keeps the
        // handshake truthful; an environment with no shares simply never
        // advertises it.
        linuxGuests.installHostRequestHandlerFactory { environmentID, pathMap in
            ArchiveHostBridgeFactory.makeHandler(environmentID: environmentID, pathMap: pathMap)
        }

        // Build 222 heavy-runtime arbitration wiring. One process-wide arbiter
        // owns the boundary between on-device MLX inference and TinyEMU Linux:
        //   * a guest start waits cancellably while any local inference
        //     session is active (`TinyEMULinuxGuestRegistry.start`),
        //   * beginning local-model use probes this app for active guests and
        //     local services and presents the conflict here,
        //   * guests are stopped only after the user confirms; a declined or
        //     cancelled confirmation fails the local request before any model
        //     work instead of overlapping the guest,
        //   * the ONE exception is a logical run's own verified transient tool
        //     guest (the Linux environment its exec.shell just used, owned by
        //     that run, with no command/terminal/service/forward/quarantine):
        //     the built-in releaser stops exactly that guest so the run can
        //     continue its own tool result — still only after the release
        //     settles, never while model pages are mapped, and never for
        //     user-started, other-run or persistent work.
        // The probe/releaser are the shared FloeExecution bridge, so the app
        // and the integration tests consume identical registry facts.
        let conflictCenter = HeavyRuntimeConflictCenter()
        self.heavyRuntimeConflictCenter = conflictCenter
        let arbiterLocalRuntime = self.localModelRuntime
        HeavyRuntimeArbiter.shared.configure(
            activityProbe: LinuxGuestRuntimeArbiterBridge.activityProbe(service: linuxGuests),
            guestStopper: LinuxGuestRuntimeArbiterBridge.guestStopper(
                service: linuxGuests,
                // A user-confirmed stop ends real runtimes: report each guest
                // the engine actually stopped through the same background-
                // location seam as the direct stop entries. The bridge filters
                // quarantined survivors itself.
                onStopped: { environmentID in
                    await FloePlatformServices.shared.reportLinuxRuntimeEnded(
                        environmentID: environmentID
                    )
                }
            ),
            decisionHandler: { activity in
                await conflictCenter.requestDecision(activity)
            },
            transientGuestReleaser: LinuxGuestRuntimeArbiterBridge.transientGuestReleaser(
                service: linuxGuests,
                onReleased: { environmentID in
                    // The engine dropped this guest's forwards with it; clear
                    // the applied view but keep the durable rules.
                    await LinuxPortForwardCenter.shared.guestStopped(environmentID: environmentID)
                    // Only `.released` reaches here (the bridge gates on the
                    // registry's revalidated outcome), so this is a confirmed
                    // runtime end and may invalidate background location.
                    await FloePlatformServices.shared.reportLinuxRuntimeEnded(
                        environmentID: environmentID
                    )
                }
            ),
            idleDrainHandler: {
                // A retained task may be waiting for its own Linux tool.
                // Preserve its logical context while yielding only an idle
                // physical mapping; active inference remains protected.
                if let released = await arbiterLocalRuntime.yieldIdleResidentEngineForLinux(
                    reason: "linuxStartWaiting"
                ) {
                    return .released(modelID: released)
                }
                // During loading the model ID can still be nil while its
                // weights are being mapped. That is retained, not empty.
                if await arbiterLocalRuntime.hasActiveInferenceOperation() {
                    return .retained
                }
                if await arbiterLocalRuntime.residentModelID() == nil {
                    return .nothingResident
                }
                return .retained
            }
        )
        FloePlatformServices.shared.setLinuxCommandService(linuxGuests)
        // Verified image storage backs `floe-env image …`: digests are checked
        // against the qualification record and archives are only promoted
        // after extraction into an app-owned directory.
        let linuxImageService = LinuxGuestBackendAssembly.makeImageService(
            artifactRoot: try? FloeArtifactStore.root()
        )
        FloePlatformServices.shared.setLinuxImageService(linuxImageService)
        // Always registered: the closure lazily recovers the image service
        // (bounded retries + backend reconnect) at first Linux use, so a
        // transient assembly-time root failure no longer freezes preparation
        // to nil for the whole process. The handler accepts no image URL or
        // install script.
        let linuxPreparation: LinuxPreparationHandler = { request in
            guard await FloePlatformServices.shared.ensureLinuxImageService() else {
                throw FloeError.invalidConfiguration(
                    String(localized: "environment.backend.image_store_unavailable")
                )
            }
            return try await FloePlatformServices.shared.prepareLinuxEnvironment(
                environmentID: request.environmentID,
                cancellation: request.cancellation,
                runID: request.runID
            )
        }
        self.skillDependencyPrepareLinux = linuxPreparation

        // Phase 2 (TinyEMU migration): local Python runs only inside the task
        // environment's Linux guest (shared venv, real pip). The bundled
        // in-process CPython and its managed installer left the app; a
        // non-Linux environment gets the honest "Linux backend required"
        // answer instead of a native fallback.
        let linuxBackendStatus: @Sendable () async -> FloeExecution.LocalPythonCapabilityProbe.BackendStatus = {
            if let status = await FloePlatformServices.shared.linuxImageStatus(id: LinuxGuestBackendAssembly.defaultImageID) {
                return .init(
                    backendPresent: true,
                    componentInstalled: status.installed && status.verificationFailure == nil,
                    detail: status.verificationFailure
                )
            }
            return .init(backendPresent: true, componentInstalled: false)
        }
        let localPythonService = LocalPythonServiceFactory.make(
            linuxGuests: linuxGuests,
            prepareLinux: linuxPreparation
        )
        self.localPythonProbe = FloeExecution.LocalPythonCapabilityProbe(
            service: localPythonService,
            backendStatus: linuxBackendStatus,
            liveProbeEnvironment: {
                for record in await environmentRegistry.all() where record.effectiveExecutionBackend == .linuxVM {
                    if await linuxGuests.guestIsRunning(environmentID: record.id) { return record.id }
                }
                return nil
            }
        )
        self.localNodeProbe = FloeExecution.LocalNodeCapabilityProbe(backendStatus: linuxBackendStatus)
        let managedPython = ManagedPythonInstallService(
            linux: LinuxGuestLanguagePackages(runner: linuxGuests)
        )
        self.managedPythonInstaller = managedPython

        // The app-wide guest lifecycle manager is a stored property (probes
        // and tools observe the same instance); it must be assigned BEFORE
        // any closure below captures self, so it is created here — after
        // `linuxPreparation` exists, before ContainerLifecycle hooks.
        let softRestartOrchestrator = LinuxGuestSoftRestartOrchestrator(
            transport: LinuxGuestServiceSoftRestartTransport(controller: linuxGuests),
            store: LinuxGuestFileSoftRestartStore(
                directory: URL.applicationSupportDirectory
                    .appendingPathComponent("FloeAgent/LinuxGuestSoftRestart", isDirectory: true)
            )
        )
        let linuxGuestLifecycle = LinuxGuestLifecycleManager(
            controller: linuxGuests,
            softRestartPerformer: { request in
                try await softRestartOrchestrator.perform(request)
            },
            softRestartReplay: { request in
                try await softRestartOrchestrator.committedReceipt(for: request)
            },
            prepareImage: { environmentID, cancellation in
                _ = try await linuxPreparation(LinuxPreparationRequest(
                    environmentID: environmentID,
                    cancellation: cancellation ?? CancellationToken()
                ))
            }
        )
        self.linuxGuestLifecycle = linuxGuestLifecycle

        // Trusted lazy runtime components (Impeccable engine). Built from
        // init-locals only: the routing backend closure below must not capture
        // a partially initialized `self`, so the two `self`-dependent seams
        // (GitHub-only transport, skills-center authorization) late-bind right
        // after phase-1 completes (same publication pattern as the pinned
        // image source). No environment is chosen at install time — staging
        // resolves the explicit task/run/environment write layer at use.
        let runtimeComponentCacheRoot = (try? FloeArtifactStore.root())?
            .appendingPathComponent("RuntimeComponents", isDirectory: true)
        let skillRuntimeComponents = SkillRuntimeComponentCenter(
            environmentResolver: { environmentID in
                guard let record = await environmentRegistry.record(id: environmentID) else { return nil }
                return SkillRuntimeComponentEnvironment(
                    layerURL: await environmentRegistry.layerURL(for: environmentID),
                    isLinuxVM: record.effectiveExecutionBackend == .linuxVM,
                    isActive: record.state != .deleting
                )
            },
            runner: linuxGuests,
            cacheRoot: runtimeComponentCacheRoot,
            pathMapping: { environmentID in
                await linuxGuests.linuxGuestPathMap(environmentID: environmentID)
            },
            launchGeneration: { environmentID in
                let states = await linuxGuests.runtimeStates()
                return states.first { $0.environmentID == environmentID && $0.running }?.identity.launchGeneration
            },
            appVersion: {
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            }
        )
        self.skillRuntimeComponents = skillRuntimeComponents

        // exec.shell requires the request's owned Linux environment;
        // an unavailable guest never falls back to the host substrate.
        let linuxShellBackend = RoutingLocalShellBackend(
            native: nativeShellBackend,
            guests: linuxGuests,
            prepareLinux: linuxPreparation,
            // Fixed native runtime-component preparation: after the real guest
            // activation, before the already-authorized command; verified
            // guest-path bindings are exported for this run only (native
            // values win over caller-supplied ones). Never a recursive
            // shell-tool dispatch; a deferral never blocks the command.
            prepareNativeComponents: { environmentID, runID, cancellation in
                await skillRuntimeComponents.prepareBindings(
                    environmentID: environmentID, runID: runID, cancellation: cancellation
                )
            }
        )
        // Only a trusted macBridge lease routes to the same-Mac shell; every
        // other environment keeps the Linux guest backend.
        let shellBackend = MacBridgeExecutionRouter(defaultBackend: linuxShellBackend)
        let advisoryRelay = DurationAdvisoryRelay()
        self.durationAdvisoryRelay = advisoryRelay
        self.durationReminder = LongRunDurationReminder { [relay = advisoryRelay] milestone, fence in
            await relay.deliver(milestone, fence: fence)
        }
        self.localShellService = LocalShellService(
            backend: shellBackend,
            policy: shellPolicy,
            durationReminder: durationReminder,
            environmentDefaults: Self.localShellEnvironment(),
            rootProvider: WorkspaceCenter.toolRootProvider
        )
        self.shellSessionCenter = ShellSessionCenter(backend: shellBackend, policy: shellPolicy)
        // Phase-1 is complete: publish the two self-dependent component seams.
        skillRuntimeComponents.setLateBindings(
            transport: { [weak self] owner, repository, ref, path in
                guard let self else {
                    throw FloeError.invalidConfiguration("App services are unavailable")
                }
                // GitHub-only trusted transport at the SAME publication commit
                // Y recorded in the curated receipt; no website fallback.
                return try await self.sourceControlCenter.skillRepositoryData(
                    owner: owner, repository: repository, ref: ref, path: path,
                    usesConnectorCredential: false
                )
            },
            authorization: { [weak self] skillID in
                guard let self else { return nil }
                return await self.skillsCenter.runtimeComponentAuthorization(skillID: skillID)
            }
        )
        let skillDependencies = self.skillDependencies
        if let runtimeComponentCacheRoot {
            skillDependencies.setLateBindings(
                transport: { [weak self] owner, repository, ref, path in
                    guard let self else { throw FloeError.invalidConfiguration("App services are unavailable") }
                    return try await self.sourceControlCenter.skillRepositoryData(
                        owner: owner, repository: repository, ref: ref, path: path,
                        usesConnectorCredential: false)
                },
                componentStoreRoot: runtimeComponentCacheRoot)
        }

        let containerLifecycle = ContainerLifecycle(
            roots: environmentRoots,
            registry: environmentRegistry,
            cas: containerCAS,
            hooks: ContainerLifecycle.Hooks(
                stopSessions: { [weak self, linuxGuests, skillRuntimeComponents, skillDependencies] id in
                    // The lifecycle invokes this hook before cancelJobs. Join
                    // dependency workers while their guest is still available.
                    await skillRuntimeComponents.releaseEnvironment(id)
                    await skillDependencies.releaseEnvironment(id)
                    // A stopped environment must not keep a guest running:
                    // its console would keep executing with the layer frozen.
                    await linuxGuests.stopGuest(environmentID: id)
                    if !(await linuxGuests.guestIsRunning(environmentID: id)) {
                        await FloePlatformServices.shared.reportLinuxRuntimeEnded(environmentID: id)
                    }
                    guard let self else { throw FloeError.invalidConfiguration("Shell session service is unavailable") }
                    await self.shellSessionCenter.closeAll(environmentID: id)
                },
                cancelJobs: { [linuxGuests, skillRuntimeComponents, skillDependencies] id in
                    // Join owned runtime-component work (cancel + await) while
                    // the guest and its write layer still exist, so an
                    // in-flight preparation never outlives its environment.
                    await skillRuntimeComponents.releaseEnvironment(id)
                    await skillDependencies.releaseEnvironment(id)
                    // stopGuest also stops every guest localService and drops
                    // the shared interpreter caches; the retired native
                    // CPython/Node workers no longer exist to stop.
                    await linuxGuests.stopGuest(environmentID: id)
                    if !(await linuxGuests.guestIsRunning(environmentID: id)) {
                        await FloePlatformServices.shared.reportLinuxRuntimeEnded(environmentID: id)
                    }
                    await EnvironmentPackageJobs.shared.cancelAndWait(id: id)
                    try await environmentExecutions.stopAndWait(environmentID: id)
                },
                terminateWorkers: { [linuxGuests, skillRuntimeComponents, skillDependencies] id in
                    await skillRuntimeComponents.releaseEnvironment(id)
                    await skillDependencies.releaseEnvironment(id)
                    await linuxGuests.stopGuest(environmentID: id)
                    if !(await linuxGuests.guestIsRunning(environmentID: id)) {
                        await FloePlatformServices.shared.reportLinuxRuntimeEnded(environmentID: id)
                    }
                    try await environmentExecutions.stopAndWait(environmentID: id)
                    try await FloeShellCommandRegistry.shared.waitForWorkers(environmentID: id)
                    guard !(await linuxGuests.guestIsRunning(environmentID: id)) else {
                        throw FloeError.validationFailed("Linux guest has not stopped; environment data was retained")
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
            downloader: AptEngine.Downloader(cancellableFetch: { url, maxBytes, cancellation in
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("floe-apt-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: temp) }
                do {
                    _ = try await packageHTTP.download(
                        url: url,
                        timeout: 120,
                        maxBytes: min(maxBytes, 64 * 1024 * 1024),
                        to: temp,
                        cancellation: cancellation
                    )
                } catch HTTPRequestError.httpStatus(404) {
                    throw AptEngine.Downloader.Failure.notFound
                }
                return try Data(floeContentsOf: temp)
            })
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
            baseSliceURL: nil,
            languageManagement: EnvironmentLanguagePackageService(
                coordinator: environmentExecutions,
                python: managedPython,
                linux: LinuxGuestLanguagePackages(runner: linuxGuests)
            )
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
        browserCenter.ownerReleaseHook = { [previewCenter] owner in
            previewCenter.releasePreview(for: owner)
        }
        // Unified tool registration: every tool the model can see is
        // registered here in one place, in a deterministic order.
        registerAllAgentTools(
            localPythonService: localPythonService,
            sshCommandService: sshCommandService,
            cloudWorkspaceService: cloudWorkspaceService,
            linuxPreparation: linuxPreparation,
            linuxLifecycle: linuxGuestLifecycle
        )
        // App Intents join the single live environment from FloeAgentApp.init
        // (AppDependencyManager registration + FloeShortcutsRuntime install).
        // Installing the runtime from every environment constructor let a
        // preview/test environment replace the live shortcut runtime globally.
        // Build 233 R2: every Office surface (workspace preview, IDE tab,
        // Notes, fullscreen editor) can reach the idle-model shed even when its
        // own view does not resolve this environment. The safety contract stays
        // in the runtime (idle-only, claim-checked, non-blocking).
        OfficeMemoryCoordination.shared.install { [weak self] reason in
            guard let self else { return nil }
            return await self.shedIdleLocalModelForOffice(reason: reason)
        }
        speechMemoryWarningCancellable = NotificationCenter.default
            .publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.localSpeechRuntime.handleMemoryWarning()
                }
                #if canImport(UIKit) && canImport(WhisperKit)
                // Warm enhanced recognition model: same pressure contract as
                // the output engine (cancel/join the owning worker, release).
                Task { await SpeechRecognitionRuntime.live.handleMemoryWarning() }
                #endif
            }
        voiceInput.prepareForCapture = { [weak self] in
            guard let self else { return }
            self.pipAudioService.handleRecordingActive(true)
            await self.speechService.stopAndWait()
        }
    }

    /// Build 233 R2: Office memory-coordination seam. Office memory-heavy
    /// preparation (editable mount, Impress import) and system memory warnings
    /// ask for an immediate release of an *idle* resident local model.
    ///
    /// The runtime enforces the safety contract: an active load/benchmark/
    /// generation or a durable run that still holds its logical claim answers
    /// nil immediately, without waiting on the inference FIFO. It never
    /// unloads a mapping an active operation, a retained task or a benchmark is
    /// using, and never cancels a task, a guest or a tool continuation. Only
    /// the physical MLX mapping is released; the next local turn reloads the
    /// same pinned snapshot.
    func shedIdleLocalModelForOffice(reason: String) async -> String? {
        await localModelRuntime.shedIdleResidentEngineForOffice(reason: reason)
    }

    /// Build 233 R1: device font-library facts recorded beside the engine's own
    /// discovery numbers in the Office stage trace. Counts only. Fonts imported
    /// before the engine starts are registered for the process and visible to
    /// its font scan; an import that lands after the engine cached its font
    /// list is the open refresh question this fact makes inspectable — no claim
    /// is made that every imported font is engine-visible.
    func officeDeviceFontFacts() async -> [String: String] {
        let records = await fontStore.list()
        return ["deviceFonts": String(records.count)]
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
    private func handleBackgroundJobTerminal(_ job: BackgroundJob) async {
        // Terminal close of this job/operation: withdraw a still-QUEUED
        // duration advisory so no late "still running" reminder outlives the
        // actual end. The liveness answer is the same trusted lease/member
        // read the delivery gate uses, so a grouped operation mid-handoff
        // keeps its queued advisory until the owner closes the lease.
        // Already-posted OS alerts are the accepted non-atomic window; this
        // only forbids known-terminal late delivery.
        if let service = backgroundJobService,
           await service.advisoryTargetIsLive(
               jobID: job.id, advisoryGroupID: job.advisoryGroupID) == false {
            await backgroundRunCoordinator.discardPendingDurationAdvisory(
                ownershipKey: "job.\((job.advisoryGroupID ?? job.id).uuidString)")
        }
        let evidence = job.resultSummary ?? job.lastError ?? job.state.rawValue
        let events = (try? await runStore.events(runID: job.runID, afterSequence: 0, limit: 32)) ?? []
        let isStandaloneService = events.contains {
            NativeServiceRunMetadata.matches($0, runID: job.runID,
                conversationID: job.conversationID, targetTool: job.targetTool)
        }
        let content = "[Floe background job \(job.id.uuidString)] \(job.targetTool) finished with state=\(job.state.rawValue). "
            + "Evidence excerpt: \(String(evidence.prefix(1_000))). "
            + "Use jobs.result with this jobID for the full output; do not resubmit an unchanged payload."
        // A native IDE service is independently requested work, not an
        // unanswered model turn. Keep its job/notification, without injecting
        // an unsolicited model input on stop/failure/completion.
        if !isStandaloneService {
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
        }
        let notification = UNMutableNotificationContent()
        notification.title = job.state == .completed ? FloeL10n.l("app.app_environment.background_task_complete") : FloeL10n.l("app.app_environment.background_task_ended", job.state.rawValue)
        notification.body = isStandaloneService && job.state == .cancelled
            ? (Locale.current.language.languageCode?.identifier == "zh" ? "服务已停止" : "Service stopped")
            : "\(job.targetTool) · \(String(evidence.prefix(160)))"
        if isStandaloneService && job.state == .cancelled {
            notification.title = notification.body
        }
        notification.userInfo = ["conversationID": job.conversationID.uuidString, "jobID": job.id.uuidString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "jobs.\(job.id.uuidString)", content: notification, trigger: nil
        ))
    }

    /// First verified readiness of a long-lived local service (its own HTTP
    /// probe answered): resolve the durable dependency edge (the service keeps
    /// running) and, when the submitting run is actually parked on it, resume
    /// that SAME run with the readiness fact. A run that is still working only
    /// gets its edge settled, so it will not park at its terminal boundary.
    private func handleBackgroundServiceReady(jobID: UUID) async {
        guard let service = backgroundJobService,
              let job = try? await service.job(id: jobID) else { return }
        await service.resolveServiceReady(
            id: jobID,
            note: "Service is verifiably ready and keeps running in the background.")
        guard await conversationCenter.isAwaitingDependency(
            runID: job.runID, conversationID: job.conversationID) else { return }
        let content = "[Floe background service \(jobID.uuidString)] \(job.targetTool) is ready and keeps running. "
            + "Use jobs.status to inspect it; the previewURL appears once HTTP responds. "
            + "Do not resubmit the same payload."
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
                "backgroundService ready steer failed jobID=\(jobID.uuidString) error=\(error.localizedDescription)"
            )
        }
    }

    /// Delivery sink for the one-time long-run duration advisory, in strict
    /// order: (1) store-backed liveness for job/group milestones (a trusted
    /// lease covers phase-handoff gaps; anything unreadable drops silently —
    /// nothing alerts after actual completion/cancel); (2) the monitor's
    /// DELIVERY FENCE immediately before the enqueue, which cancels the
    /// delivery when the unit of work ended while this sink task was in
    /// flight (the foreground shell case — proven by fence tests, not by
    /// comment); (3) the durable outbox enqueue; (4) only AFTER the enqueue
    /// succeeded, the best-effort durable marker, so a skipped or failed
    /// delivery never leaves a marker claiming it happened. Permission or
    /// storage failures stay diagnostics and can never fail the running
    /// job or command.
    private func deliverDurationAdvisory(
        _ milestone: LongRunAdvisoryMilestone,
        fence: @escaping LongRunDurationReminder.DeliveryFence
    ) async {
        if let jobID = milestone.jobID {
            guard let service = backgroundJobService,
                  await service.advisoryTargetIsLive(
                      jobID: jobID, advisoryGroupID: milestone.advisoryGroupID) else { return }
            guard await fence() else { return }
            let accepted = await backgroundRunCoordinator.enqueueDurationAdvisory(
                ownershipKey: milestone.ownershipKey,
                conversationID: milestone.conversationID,
                runID: milestone.runID,
                jobID: jobID,
                advisoryGroupID: milestone.advisoryGroupID,
                deliveryFence: fence
            )
            if accepted {
                await service.markDurationAdvisoryEnqueued(jobID: jobID, at: milestone.firedAt)
            }
        } else {
            guard await fence() else { return }
            await backgroundRunCoordinator.enqueueDurationAdvisory(
                ownershipKey: milestone.ownershipKey,
                conversationID: milestone.conversationID,
                runID: milestone.runID,
                jobID: nil,
                advisoryGroupID: nil,
                deliveryFence: fence
            )
        }
    }

    func durationAdvisoryWorkIsActive(ownershipKey: String) async -> Bool {
        await durationReminder.workIsActive(key: ownershipKey)
    }

    /// Registers every tool the agent can see, in one place and in a
    /// deterministic order. This is the single source of truth for the
    /// model's tool catalog.
    private func registerAllAgentTools(
        localPythonService: LocalPythonService?,
        sshCommandService: SSHCommandService?,
        cloudWorkspaceService: CloudWorkspaceService?,
        linuxPreparation: LinuxPreparationHandler?,
        linuxLifecycle: any LinuxGuestLifecycleControlling
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
        _ = registerImageTools(rootProvider: WorkspaceCenter.toolRootProvider)
        // Native canvas inspection and mutation tools. Canvas runs are scoped
        // back to their durable hidden assistant conversation at execution.
        registerCanvasAgentTools(environment: self)
        // Design workflow tools (brief/spec/revisions/anchored feedback/
        // candidate/adopt/reject/restore) on the shared design project model.
        // Capability flags reflect this build's actually connected operations.
        // Authorization fails closed: a run may only touch the canvas its run
        // context is bound to.
        let designDatabase = database
        registerDesignAgentTools(
            capabilities: { [weak self] in
                self?.designAdapterCenter.capabilityRegistry() ?? .designCoreDefaults()
            },
            adapters: designAdapterCenter,
            environment: self,
            authorize: { runID, canvasID in
                guard let runID else { return false }
                let store = CanvasRunContextStore(database: designDatabase)
                guard let context = try? await store.context(runID: runID) else { return false }
                return context.canvasID == canvasID
            },
            decisionSink: { [weak self] conversationID, proposalID, decision, revision, sha256 in
                // The shared durable proposal-decision ingress: queued runtime
                // input on the originating conversation + idempotent
                // transcript upsert. Errors PROPAGATE: the caller keeps the
                // outbox intent pending for launch-time reconcile rather than
                // falsely acknowledging a delivery that did not persist.
                guard let environment = self else {
                    throw FloeError.internalError("App environment unavailable for decision delivery")
                }
                try await environment.conversationCenter.recordProposalDecision(
                    conversationID: conversationID,
                    proposalID: proposalID,
                    decision: "design-candidate-\(decision)",
                    revision: revision,
                    sha256: sha256
                )
            },
            decisionOutbox: DesignDecisionOutbox.shared,
            // EXACTLY the same composition instances the trusted-UI panel
            // drives: typed targets, the one owner workflow, the one typed
            // canvas service, and the one user-confirmation service. No
            // duplicate store or permissive fallback authorizer is created
            // inside registration.
            targets: designTargetService,
            ownerWorkflow: designOwnerWorkflow,
            ownerAdoptionGrants: designOwnerAdoptionGrants,
            canvasService: designCanvasService,
            runTask: { [runStore = self.runStore] runID in
                // Trusted run→task(conversation) provenance comes from the
                // durable run store, never from model JSON.
                (try? await runStore.run(id: runID))?.conversationID
            }
        )
        // Launch recovery for design decisions whose delivery crashed between
        // the Canvas CAS commit and the durable notice (the intent was
        // persisted before the CAS, so the decision is never lost).
        Task { [self] in
            await DesignDecisionOutbox.shared.reconcile(
                terminalDecision: { intent in
                    guard let canvasID = UUID(uuidString: intent.canvasID),
                          let nodeID = UUID(uuidString: intent.nodeID) else { return .unavailable }
                    let service = DesignCanvasService(repository: FileCanvasDocumentRepository())
                    // The intent names the EXACT node owning the candidate.
                    // Lookup failure is NEVER mistaken for "not committed".
                    guard let design = try? await service.designState(canvasID: canvasID, nodeID: nodeID) else {
                        return .unavailable
                    }
                    // Exact fingerprint: the recorded operation must be
                    // applied AND the candidate must be in the terminal state
                    // the intent recorded (adopt/reject + matching base). A
                    // candidate terminal state alone can belong to a later
                    // unrelated operation.
                    guard design.hasApplied(operationID: intent.operationID),
                          let candidate = design.candidate(intent.candidateID) else {
                        return .notCommitted
                    }
                    if let base = intent.baseRevisionID, candidate.baseRevisionID != base {
                        return .notCommitted
                    }
                    if intent.decision == "adopted", intent.mode == DesignAdoptMode.variant.rawValue,
                       candidate.variantArtifactID == nil {
                        return .notCommitted
                    }
                    switch (candidate.status, intent.decision) {
                    case (.adopted, "adopted"): return .committed("adopted")
                    case (.rejected, "rejected"): return .committed("rejected")
                    case (.superseded, "rejected"): return .committed("rejected")
                    case (.pending, _): return .notCommitted
                    default: return .notCommitted
                    }
                },
                deliver: { [self] intent, decision in
                    guard let conversationID = UUID(uuidString: intent.conversationID),
                          let candidateUUID = UUID(uuidString: intent.candidateID) else {
                        throw FloeError.validationFailed("Durable decision has an invalid target")
                    }
                    // THROWS: reconcile catches and keeps the intent pending
                    // until the durable ingress actually persists.
                    try await conversationCenter.recordProposalDecision(
                        conversationID: conversationID,
                        proposalID: candidateUUID,
                        decision: "design-candidate-\(decision)",
                        revision: nil,
                        sha256: nil
                    )
                }
            )
        }
        // Non-canvas design decisions settle through the generic owner
        // workflow's idempotent reconcile (retained candidate + verified
        // result publication included). Canvas intents are handled by the
        // closure above; the owner path fails closed for them (T3 C14) and
        // is skipped. A missing publication route keeps the durable record
        // pending instead of claiming a completed return.
        Task { [self] in
            let outbox = DesignDecisionOutbox.shared
            let pending = await outbox.pendingIntents()
            for intent in pending
            where intent.target != nil && intent.phase == .committing {
                do {
                    _ = try await designOwnerWorkflow.reconcilePendingAdoption(
                        intent,
                        verifyReopen: DesignOwnerWorkflowFactory.verifier(adapters: designAdapterCenter))
                } catch let error as DesignOwnerWorkflowError {
                    if case .canvasRequiresCanvasAuthority = error { continue }
                    // Token-only: never log user content or paths.
                    FloeLogger(category: .app).warning(
                        "design target reconcile retained intent \(intent.id)")
                } catch {
                    FloeLogger(category: .app).warning(
                        "design target reconcile retained intent \(intent.id)")
                }
            }
        }
        // Provider-backed semantic visual inspection plus generation through
        // the independently configured auxiliary models. These must be in
        // the agent catalog, not UI-only.
        registerRemoteImageTools(center: filesCenter)
        // Provider-backed durable video generation (Google Veo/Omni, Ark
        // Seedance, DashScope Wan) for ordinary chat. Submissions become
        // conversation-owned media jobs that survive relaunches.
        registerRemoteVideoTools(center: filesCenter)
        // Unified image/video workbench: `media.project` read/propose/apply/
        // export. Proposals only apply through a UI-minted grant.
        registerWorkbenchTools(center: workbenchCenter)
        // CAD drawings: cad.document read/propose/apply/save/export through the
        // native Rust WASM engine, with a UI-minted confirmation grant.
        registerCadDocumentTools(center: cadDocumentCenter)
        // Office engine edits: document.office.edit propose/apply/export
        // through the live pinned Office editor session, with a UI-minted
        // confirmation grant and saved-package verification.
        registerOfficeEditTools(center: officeCommandCenter)
        // Public Apple-framework integrations. Device-local settings filter
        // these descriptors before each provider request. The automation
        // editor freezes the SAME trusted bindings as `task.schedule` and can
        // trigger one real due pass, so both creation paths behave identically.
        registerAppleSystemTools(
            database: database,
            scheduleBindingResolver: { [weak self] context in
                await self?.taskScheduleBinding(for: context)
            },
            onScheduleDue: { [weak self] in
                guard let self else { return }
                await self.backgroundRunCoordinator.runDueSchedulesNow()
            }
        )
        // Read-only HealthKit metrics and the foreground NFC NDEF scan. Both
        // use process-wide app-lifetime services owned by the registration
        // helper; the settings capability gate and device availability hide
        // them from discovery when unsupported.
        #if canImport(UIKit) && canImport(HealthKit) && canImport(CoreNFC)
        registerAppleHealthNFCTools()
        #endif
        #if canImport(AlarmKit) && !targetEnvironment(macCatalyst)
        alarmService = registerAppleAlarmTools(database: database, existingService: alarmService)
        #endif
        registerAppleContactsMediaTools(
            audioBusyReason: { [weak self] in
                guard let self else { return "unavailable" }
                return await MainActor.run { () -> String? in
                    if self.voiceInput.state.hasSession { return "recording" }
                    if self.speechService.isSpeaking { return "speech" }
                    if self.pipAudioService.holdsSharedAudioSession
                        || self.pipAudioService.state != .stopped { return "taskAudio" }
                    if self.backgroundVideoService.audioSessionActivationOwned
                        || self.backgroundVideoService.isPiPActive { return "video" }
                    return nil
                }
            }
        )
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
            webSearchAvailability: WebSearchSettingsCenter.toolIsAvailable,
            linuxPreparation: linuxPreparation,
            linuxLifecycle: linuxLifecycle
        )
        // One Linux command surface, shared with interactive terminals.
        registerShellTools(
            shell: localShellService,
            sessions: shellSessionCenter,
            pythonInstaller: managedPythonInstaller,
            capabilityInstaller: capabilityInstaller,
            wasmStore: wasmCapabilities,
            dependencyGate: skillsCenter
        )
        FloeShellCommandRegistry.shared.configure(
            python: localPythonService,
            wasm: wasmCapabilities
        )
        FloeShellCommands.install()
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
        NotesToolRegistration.register()
        ToolCatalog.register(AudioTranscribeTool.self)
        ToolRunnerRegistry.shared.register(AudioTranscribeTool(assistant: assistantAudioService))
        ToolCatalog.register(AudioSynthesizeTool.self)
        ToolRunnerRegistry.shared.register(AudioSynthesizeTool(assistant: assistantAudioService))
        ToolCatalog.register(AudioServicesTool.self)
        ToolRunnerRegistry.shared.register(AudioServicesTool(assistant: assistantAudioService))
        // Real shared enhancement processor (VideoToolbox frame-rate
        // conversion/low-latency/super resolution, installed Core ML RIFE
        // and Real-ESRGAN bundles, MetalFX spatial scaler). There is
        // deliberately no global workspace provider: each tool request
        // freezes the caller's immutable `context.workspaceRootURL`
        // snapshot into `FrameProcessingRequest.workspaceRoot`, so a
        // concurrent project/task switch can never redirect a queued job.
        let mediaProcessor = MediaEnhancementIntegration.makeFrameProcessing(
            modelResolver: MediaModelResolution.store(mediaModelStore)
        )
        MediaToolRegistration.register(
            appBuild: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "dev",
            // Real readiness: the store's installed records are the installed
            // list, and every entry is hash-verified and qualified by one
            // bounded fixture inference (or a revalidated persisted
            // qualification). Installation alone never reports runnable; the
            // verified catalog still supplies the presentation metadata.
            modelProvider: {
                let (catalogInstalled, available) = await MediaModelCatalogService.shared.report()
                let records = await mediaModelStore.installed()
                let readiness = await MediaModelReadiness.report(
                    installed: records.map { (id: $0.id, rootPath: $0.rootPath) }
                )
                var catalogByID: [String: MediaCapabilities.Model] = [:]
                for model in catalogInstalled { catalogByID[model.id] = model }
                let installed = readiness.map { qualified -> MediaCapabilities.Model in
                    guard var model = catalogByID[qualified.id] else { return qualified }
                    model.runnable = qualified.runnable
                    model.unavailableReason = qualified.unavailableReason
                    return model
                }
                return (installed, available)
            },
            modelStore: mediaModelStore,
            modelCatalogProvider: { await MediaModelCatalogService.shared.catalog() },
            frameProcessing: mediaProcessor
        )
        Task {
            await MediaModelCatalogService.shared.configure(
                catalogURL: URL(string: "https://raw.githubusercontent.com/\(OfficialSkillHub.owner)/\(OfficialSkillHub.repository)/main/\(OfficialSkillHub.catalogPath)")
            )
            await MediaModelCatalogService.shared.bind(store: mediaModelStore)
            _ = await MediaModelCatalogService.shared.catalog()
        }
        ToolCatalog.register(LocalServiceTool.self)
        // Late-binding readiness relay: the tool must exist before the job
        // service (the service resolves the durable dependency edge later).
        let localServiceReadyRelay = LocalServiceReadyRelay()
        var localServiceRunner = AnyAgentTool(LocalServiceTool(
            store: BackgroundJobStore(database: database),
            onServiceReady: { [relay = localServiceReadyRelay] jobID in
                await relay.announce(jobID)
            }
        ))
        // jobs.submit rejects a missing entry script or working directory
        // synchronously, before the durable job record exists.
        localServiceRunner.preflightSubmission = { payload, workspaceRoot in
            try LocalServiceJobPreflight.validate(payloadJSON: payload, workspaceRootURL: workspaceRoot)
        }
        ToolRunnerRegistry.shared.register(localServiceRunner)
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
            // Service-owned prepared operations for the authorized Office and
            // media apply paths: they consume the runtime authority for the
            // exact submitting `jobs.submit` call, freeze root/revision/digests
            // at submission and run the real services with progress and
            // cooperative cancellation. Ordinary targets keep the generic
            // runner path (adapters are per-target).
            adapters: NativeJobAppAdapters.make(
                officeCenter: officeCommandCenter,
                workbenchCenter: workbenchCenter,
                frameProcessing: mediaProcessor
            ),
            onTerminal: { [weak self] job in
                await self?.handleBackgroundJobTerminal(job)
            },
            durationReminder: durationReminder,
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
        // Install the real advisory sink now that every service it touches
        // exists (same late-binding point as the local-service ready relay).
        durationAdvisoryRelay.install { [weak self] milestone, fence in
            await self?.deliverDurationAdvisory(milestone, fence: fence)
        }
        if let backgroundJobService {
            registerLocalServiceCommand(service: backgroundJobService, store: BackgroundJobStore(database: database))
            // First verified readiness of a long-lived service settles its
            // durable dependency edge and resumes a parked submitting run in
            // the SAME run; the service itself is never terminated here.
            localServiceReadyRelay.install { [weak self] jobID in
                await self?.handleBackgroundServiceReady(jobID: jobID)
            }
        }
        // Scheduled tasks (task.schedule). The tool operates the SAME durable
        // `SQLiteTaskScheduleStore` the Home sheet and the background
        // coordinator use (no second manager). Bindings are frozen at creation
        // from the ACTUAL submitting run (see `taskScheduleBinding(for:)`),
        // never from model arguments; without the resolver the tool refuses
        // `create` rather than freezing empty bindings. `onScheduleDue` runs
        // one real due pass after runNow/enable when the app can.
        registerTaskScheduleTools(
            database: database,
            onScheduleDue: { [weak self] in
                guard let self else { return }
                await self.backgroundRunCoordinator.runDueSchedulesNow()
            },
            bindingResolver: { [weak self] context in
                await self?.taskScheduleBinding(for: context)
            }
        )
        // Browser automation.
        registerBrowserTools(center: browserCenter)
        ToolCatalog.register(LinuxPortTool.self)
        ToolRunnerRegistry.shared.register(LinuxPortTool())
        registerMailTools()
        // Local preview server.
        registerPreviewTools(environment: previewCenter)
        // Skill authoring.
        registerSkillTools(creator: LocalSkillCreator(center: skillsCenter), manager: LocalSkillCreator(center: skillsCenter),
            catalog: SkillHubAppBridge(center: skillsCenter))
        // Complete-package install from the current task workspace.
        ToolCatalog.register(SkillWorkspaceInstallTool.self)
        ToolRunnerRegistry.shared.register(
            SkillWorkspaceInstallTool(installer: SkillWorkspaceInstaller(center: skillsCenter), hub: SkillHubAppBridge(center: skillsCenter))
        )
        // Bundled domain skills: seed/upgrade in the background; failures are
        // logged inside the seeder and never block startup.
        if shouldSeedBundledSkills { Task { await skillsCenter.seedBuiltinDomainSkills() } }
        // Signed declarative content: foreground check at most once per day.
        // Failures are logged inside the center and never block startup.
        Task { await contentUpdateCenter.checkAutomaticallyIfDue() }
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

    /// Trusted frozen bindings for a model-created scheduled task.
    ///
    /// The model can never choose the model/project/environment/permission of
    /// a scheduled task: everything is derived from the ACTUAL submitting run
    /// (its durable run record, its conversation's workspace link and its
    /// saved task policy) plus the run's explicit environment binding. A
    /// missing binding is `nil` (the record's creation-time resolution), never
    /// an invented value; a resolver failure refuses `create` in the tool.
    /// The permission ceiling is revalidated again at execution.
    private func taskScheduleBinding(for context: ToolContext) async -> TaskScheduleBinding? {
        guard let run = try? await runStore.run(id: context.runID) else { return nil }
        let conversationID = context.conversationID ?? run.conversationID
        let workspaceStore = SQLiteWorkspaceStore(database: database)
        let workspaceID = (try? await workspaceStore.workspaceID(conversationID: conversationID)) ?? nil
        let permissionJSON: String?
        if let policy = try? await workspaceStore.taskPolicy(conversationID: conversationID) {
            // Freeze exactly the policy the task really runs under (approval
            // mode / recovery / notifications); the execution boundary
            // re-checks it and never widens it.
            let draft = DraftTaskPolicy(
                approvalMode: policy.resolvedApprovalMode,
                recoveryPolicy: policy.recoveryPolicy,
                notificationPolicy: policy.notificationPolicy)
            permissionJSON = (try? JSONEncoder().encode(draft))
                .map { String(decoding: $0, as: UTF8.self) }
        } else {
            permissionJSON = nil
        }
        return TaskScheduleBinding(
            workspaceID: workspaceID,
            environmentID: context.environmentID,
            modelID: run.modelID,
            permissionJSON: permissionJSON,
            anchorTimezone: TimeZone.current.identifier)
    }

    /// Creation-time bindings for an APP-initiated schedule with no run
    /// context (Shortcuts). Freezes the CURRENT default agent model and the
    /// current default approval policy, so a schedule created now cannot
    /// silently follow a later settings change; no environment is bound here
    /// (it is resolved from the task workspace at execution and revalidated).
    /// Returns nil when no default model resolves — the caller refuses
    /// creation instead of freezing an empty binding.
    func appDefaultTaskScheduleBinding() -> TaskScheduleBinding? {
        guard let defaultModelID = conversationCenter.modelPreferences.defaultAgentModelID,
              conversationCenter.providerAndModel(modelID: defaultModelID) != nil else {
            return nil
        }
        let approvalMode = TaskApprovalMode(
            rawValue: settingsCenter.defaultAgentMode.taskApprovalModeName) ?? .ask
        let permissionJSON = (try? JSONEncoder().encode(DraftTaskPolicy(approvalMode: approvalMode)))
            .map { String(decoding: $0, as: UTF8.self) }
        return TaskScheduleBinding(
            workspaceID: nil,
            environmentID: nil,
            modelID: defaultModelID,
            permissionJSON: permissionJSON,
            anchorTimezone: TimeZone.current.identifier)
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
    ///
    /// Shared single-flight: concurrent callers (root view task, scene
    /// reconstruction, App Intents) join the SAME in-flight attempt. A
    /// completed successful bootstrap is skipped so interrupted recovery and
    /// launch fixtures never re-run over work created after launch. The
    /// attempt retires itself before completion, so a call made after a failed
    /// attempt starts a real retry instead of rejoining the finished failure.
    func bootstrap() async {
        StorageSuspensionCoordinator.shared.start()
        if bootstrapDidCompleteSuccessfully { return }
        await bootstrapGate.run { [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
    }

    /// The original launch migration/recovery sequence.
    private func performBootstrap() async {
        #if DEBUG
        bootstrapExecutionCount += 1
        // Hosted actual-entry acceptance: inject ONE cold-start failure at the
        // very start, before migrations or any shared launch maintenance. The
        // fault is armed only by the explicit test launch environment, so a
        // normal Debug/Release launch and any ordinary test are unaffected.
        if FloeEntryQualification.consumeBootstrapFailureOnce() {
            persistenceReady = false
            bootstrapError = FloeEntryQualification.injectedBootstrapFailure
            bootstrapDidCompleteSuccessfully = false
            return
        }
        #endif
        do {
            try await database.migrate()
            try await NotesRepository.shared.reconcileAssistantOwnership(database: database)
            try await runningInputStore.recoverTransientInputs()
            // In-process jobs from the previous process can never resume;
            // mark them interrupted so the model can resubmit honestly.
            if let backgroundJobService {
                _ = try? await backgroundJobService.reconcileInterruptedOnLaunch()
            }
            // Delegated children left registered/running by a dead process are
            // marked interrupted too; otherwise the child panel would show a
            // live "working" child forever and keep its 2 s poll alive. The
            // count/error is observable in diagnostics instead of discarded,
            // because a reconcile failure leaves honest "running" records that
            // the user should be able to explain.
            do {
                let reconciled = try await SQLiteChildRunStore(database: database)
                    .reconcileInterruptedOnLaunch()
                if reconciled > 0 {
                    FloeLogger(category: .persistence).warning(
                        "childRunReconcileInterrupted count=\(reconciled)")
                }
            } catch {
                FloeLogger(category: .persistence).error(
                    "childRunReconcileFailed errorType=\(String(describing: type(of: error)))")
            }
            // S3-D run-output tombstones left by a conversation deletion whose
            // snapshot cleanup failed (or whose process died mid-deletion) are
            // retried exactly here — once per readiness pass, no timer, no
            // global scan. Each persisted request is reattempted only after
            // its original conversation is verified truly absent, so a
            // pre-DB-failure tombstone can never delete a live run's output.
            // Failures keep their requests on disk and stay observable.
            let cleanupOutcome = await RunOutputCleanupQueue.retryPersistedTombstones { [database] conversationID in
                // A read failure is unknown, not proof of deletion. Let the
                // queue retain the request and the user's output snapshots.
                try await SQLiteConversationStore(database: database)
                    .conversation(id: conversationID) != nil
            }
            if cleanupOutcome.completedRequests > 0
                || cleanupOutcome.retainedLiveConversationRequests > 0 {
                FloeLogger(category: .persistence).info(
                    "runOutputCleanupRetry completed=\(cleanupOutcome.completedRequests) "
                    + "liveRetained=\(cleanupOutcome.retainedLiveConversationRequests)")
            }
            if cleanupOutcome.failedRequestCount > 0 {
                FloeLogger(category: .persistence).error(
                    "runOutputCleanupRetryFailed count=\(cleanupOutcome.failedRequestCount) "
                    + "details=\(cleanupOutcome.failureDescriptions.joined(separator: " | "))")
            }
            // Native CAD proposals interrupted mid-apply and decision
            // deliveries that never reached the originating task reconcile
            // from durable records (never from ordering alone).
            Task { await self.cadDocumentCenter.reconcileNativeProposals() }
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
               ProcessInfo.processInfo.arguments.contains("--ui-test-reset-creative-draft") {
                // The creative conversational entry uses ONE fixed draft
                // slot; the UI acceptance that proves draft retention across
                // a relaunch asks for a clean slot (keyboard-based clearing
                // is unreliable on the simulator). Only this test-owned slot
                // is cleared, only under -ui-testing.
                ComposerDraftStore.shared.clear(
                    conversationID: CreativeDesignStartView.draftID)
            }
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
               ProcessInfo.processInfo.arguments.contains(OfficeWorkspaceStageFixture.pinchCenterLaunchArgument) {
                // Seed the owned document before the first Notes library load.
                await OfficeWorkspaceStageFixture.seedCenteredPinchDocumentIfRequested()
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains(OfficeWorkspaceStageFixture.pinchCenterCalcLaunchArgument) {
                // Calc companion fixture for the same strict real-UIKit pinch
                // acceptance; seeded before the first library load so the real
                // card is listed by the ordinary session open path.
                await OfficeWorkspaceStageFixture.seedCenteredPinchCalcDocumentIfRequested()
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains(OfficeWorkspaceStageFixture.pinchCenterPresentationLaunchArgument) {
                // Impress companion fixture, same owned seeding route.
                await OfficeWorkspaceStageFixture.seedCenteredPinchPresentationDocumentIfRequested()
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains(OfficeInkCardLoopFixture.wordLaunchArgument)
                || ProcessInfo.processInfo.arguments.contains(OfficeInkCardLoopFixture.calcLaunchArgument)
                || ProcessInfo.processInfo.arguments.contains(OfficeInkCardLoopFixture.presentationLaunchArgument) {
                // OWNED synthetic Office documents for the actual Main-App
                // saved-ink library-card UI loop acceptance (one unique
                // tokenized document per run, per format). Seeded through the
                // same Notes importer path as a user file import before the
                // first library load, only under -ui-testing plus the
                // explicit fixture family; nothing else in the library is
                // touched. See OfficeInkCardLoopFixture.
                await OfficeInkCardLoopFixture.seedIfRequested()
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-task-management-fixture") {
                // OWNED synthetic tasks for the bulk task-management UI
                // acceptance. Fixed identities, idempotent: a missing task is
                // created, an archived one is made active again (each run
                // starts from the same active slice). No real user
                // conversation is ever read, changed or deleted.
                let fixtures: [(id: UUID, title: String)] = [
                    (UUID(uuidString: "A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A001")!, "任务管理测试-A"),
                    (UUID(uuidString: "A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A002")!, "任务管理测试-B"),
                    (UUID(uuidString: "A1D4A0F2-6F2E-4E7A-9C31-0B7C51E6A003")!, "任务管理测试-C")
                ]
                for fixture in fixtures {
                    if let existing = try await conversationStore.conversation(id: fixture.id) {
                        if existing.archivedAt != nil {
                            try await conversationStore.setArchived(id: fixture.id, archived: false)
                        }
                    } else {
                        let record = ConversationRecord(
                            id: fixture.id, title: fixture.title,
                            createdAt: Date(), updatedAt: Date()
                        )
                        try await conversationStore.saveConversation(record)
                        _ = try await SQLiteWorkspaceStore(database: database)
                            .ensureWorkspace(conversationID: fixture.id, title: fixture.title)
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains(DesignWorkflowFixture.launchArgument) {
                // Synthetic design-workflow fixtures through the REAL
                // stores/typed services (bound modify with frozen original +
                // pending candidate; creative first-result-bound + candidate;
                // restructure-bound frozen webroot). Named, idempotent; only
                // under -ui-testing. See DesignWorkflowFixture.
                await DesignWorkflowFixture.seedIfRequested(environment: self)
                // The center loaded its list before seeding: publish the
                // fixture conversations so the sidebar shows them immediately.
                await conversationCenter.reload()
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-checklist-fixture") {                let taskID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
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
               ProcessInfo.processInfo.arguments.contains("--ui-test-ide-fixture") {
                let fixtureID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
                let record = try await SQLiteWorkspaceStore(database: database).ensureWorkspace(
                    conversationID: fixtureID, title: "批量选择测试"
                )
                let lease = try await workspaceCenter.acquireTaskRoot(record, conversationID: fixtureID)
                defer { lease.release() }
                // Seed only once: a second App launch must read the real saved
                // file, never replace it with a fixture that hides a lost save.
                let file = lease.url.appendingPathComponent("IDE验收.txt")
                if !FileManager.default.fileExists(atPath: file.path) {
                    try Data("Floe IDE durable workspace\n".utf8).write(to: file, options: .atomic)
                }
            }
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-engineering-fixture") {
                let fixtureID = UUID(uuidString: "57C0A79F-CF1B-45D2-B640-EF54E5C55391")!
                let record = try await SQLiteWorkspaceStore(database: database).ensureWorkspace(
                    conversationID: fixtureID, title: "批量选择测试"
                )
                let lease = try await workspaceCenter.acquireTaskRoot(record, conversationID: fixtureID)
                defer { lease.release() }
                guard let sample = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil)?.appendingPathComponent("sample-plate.dxf") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                for (source, name) in [(sample, "工程图验收.dxf"), (sample.deletingLastPathComponent().appendingPathComponent("sample-editable.dwg"), "可编辑图纸验收.dwg")] {
                    let destination = lease.url.appendingPathComponent(name)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try Data(contentsOf: source).write(to: destination, options: .atomic)
                    }
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
            // Onboarding-only test reset: flips the persisted onboarding
            // marker so the setup guide shows again. NON-DESTRUCTIVE: it
            // never touches existing providers, models or Keychain secrets,
            // because the shared review simulator and user devices may hold
            // real configuration. Deleting user configuration requires the
            // separate, explicitly destructive flag below, which no regular
            // test passes.
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-reset-onboarding") {
                ConversationCenter.persistOnboardingSkippedMarker(false)
                // The setup guide keeps its own resumable position record. A
                // test that resets onboarding must start from the first
                // section, so the record goes with the marker. It carries no
                // configuration and no secret: section identity, the chosen
                // preset and per-section status only.
                SetupGuideProgressStore.clear()
            }
            // DESTRUCTIVE test-only reset for a THROWAWAY simulator/CI runner
            // only: wipes all provider/model configuration so a test can
            // exercise first-run setup. Never used by the shared review
            // device; not implied by any other flag.
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--ui-test-delete-all-providers") {
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
            // System-notification tap qualification: prepares one synthetic
            // task and posts ONE real terminal notification through the
            // production path. It never simulates the tap or the route.
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains(NotificationQualificationFixture.launchArgument) {
                await NotificationQualificationFixture.seedIfRequested(environment: self)
            }
            // Temporary-chat GUI acceptance: ONE synthetic saved conversation
            // (fixed identity, two synthetic messages) for the real toggle /
            // End / Keep paths without any model request.
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains(TemporaryChatUITestFixture.launchArgument) {
                await TemporaryChatUITestFixture.seedIfRequested(environment: self)
            }
            // Task-lifecycle GUI acceptance: ONE synthetic saved conversation
            // with a durable child, a real tool pair and a spooled job output
            // for the delegate card / inspector / retained-output viewer.
            if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
               ProcessInfo.processInfo.arguments.contains(TaskLifecycleUITestFixture.launchArgument) {
                await TaskLifecycleUITestFixture.seedIfRequested(environment: self)
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
            // Inbound shares are app-owned (never View-owned). Start the
            // foreground refresh once launch reached a usable state; the
            // center itself performs the App Group maintenance pass.
            // The destination chooser must install its durable decision
            // gate BEFORE stores start the automatic drain, so a cold
            // ambiguous arrival waits for an explicit 手记/任务 choice
            // instead of silently importing.
            if !isEphemeral {
                shareIntakeCenter.start()
                importDestinationCenter.start(
                    shareCenter: shareIntakeCenter,
                    documentCenter: documentIntakeCenter
                )
                documentIntakeCenter.markStoresReady()
                sharedDocumentsCenter.start()
                StorageSuspensionCoordinator.shared.configure(
                    sharedDocuments: sharedDocumentsCenter,
                    intake: documentIntakeCenter,
                    shareIntake: shareIntakeCenter,
                    destinations: importDestinationCenter
                )
            }
            // Design freeze reconciliation: drop protections whose owning
            // conversation no longer exists (deleted task / crashed launch)
            // so an original can never stay frozen forever.
            if !isEphemeral {
                let database = self.database
                await DesignFreezeProtectionCoordinator.reconcile { conversationID in
                    guard let uuid = UUID(uuidString: conversationID) else { return false }
                    return (try? await SQLiteConversationStore(database: database)
                        .conversation(id: uuid)) != nil
                }
            }
            // PiP/service truth: observe the existing Linux guest supervisor's
            // bounded lifecycle stream now that the environment is fully
            // initialized, so an observed managed-service end reaches the
            // durable terminal pipeline exactly once with the real identity.
            // Explicit stops are filtered by the coordinator; no view owns a
            // monitor of its own.
            backgroundRunCoordinator.startLinuxGuestServiceLifecycleObservation()
            // Runtime-ended → background location: one bounded callback on the
            // existing platform-services seam, installed after the environment
            // is fully initialized (never from the giant init). Only the
            // production assembly binds it: a recovery (ephemeral) instance
            // and a SwiftUI preview (`seedBundledSkills: false`) must not
            // replace the production binding on the process-wide service. The
            // services report only runtime-owned confirmed stops (direct
            // stop/delete/backend switch, the arbiter's confirmed stop and a
            // confirmed transient release), so a quarantined VM never marks a
            // live guest dead. The coordinator drops that environment's
            // location authority, PiP hold and surface cache on the spot; no
            // polling or keepalive is involved.
            if !isEphemeral, shouldSeedBundledSkills {
                let coordinator = backgroundRunCoordinator
                FloePlatformServices.shared.setLinuxRuntimeEndedHandler { [weak coordinator] environmentID in
                    await coordinator?.linuxEnvironmentRuntimeEnded(environmentID: environmentID)
                }
            }
            // Office engine prewarm — intentionally removed from launch.
            // `cok_init_2` installs LibreOffice's process-wide signal handler
            // as a side effect, and that handler converts any later async
            // fault on any thread (including an MLX inference fault) into a
            // process abort, masking the original exception in crash reports
            // (Build 227 MLX prefill abort symbolicated through it). The
            // engine now initializes on the first document open instead —
            // `OfficeDocumentEditorView.prepareNativeRuntime`, bounded by a
            // 30s deadline with a visible spinner — so chat-only usage never
            // installs the handler. Office on-demand prepare is unchanged.
            #if canImport(FloeOfficeNative)
            // Trace guard for the cloud simulator qualification: one durable,
            // content-free breadcrumb proving the genuine FloeOfficeNative
            // framework was linked into this process before any document
            // opened. A build without the framework never records it, so the
            // gate can never mistake a stub run for the real engine.
            Task { @MainActor in
                OfficeStageRecorder.shared.record(
                    session: "app-launch",
                    generation: 0,
                    stage: "engine.linked",
                    detail: [
                        "simulator": {
                            #if targetEnvironment(simulator)
                            return "true"
                            #else
                            return "false"
                            #endif
                        }(),
                    ])
            }
            if !ProcessInfo.processInfo.isLowPowerModeEnabled,
               UserDefaults.standard.bool(forKey: "office.prewarm.enabled") {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    FloeLogger(category: .app).info(
                        "officeEnginePrewarmStarted source=launchOptIn"
                    )
                    FloeOfficeNativeRuntime.shared.prepare { _ in }
                }
            }
            #endif
        } catch {
            persistenceReady = false
            bootstrapError = error.localizedDescription
        }
        // Success means the WHOLE launch sequence above finished with durable
        // storage. An ephemeral recovery environment stays retryable so a
        // transient database failure is not remembered as permanent.
        bootstrapDidCompleteSuccessfully = !isEphemeral && persistenceReady
        if bootstrapDidCompleteSuccessfully {
            bootstrapError = nil
        }
    }

    /// A download wake joins the existing launch/configuration pipeline,
    /// even when no SwiftUI scene is constructed. Ownership belongs to the
    /// app service so the wake's bounded waiter cannot cancel initialization
    /// another scene or Intent is joining. This does not launch an Agent or
    /// request continued-processing qualification.
    func startBackgroundDownloadInitialization() {
        guard !backgroundDownloadAutomationReady, backgroundDownloadInitialization == nil else { return }
        backgroundDownloadInitialization = Task { [weak self] in
            guard let self else { return }
            defer { self.backgroundDownloadInitialization = nil }
            do { try await self.ensureReadyForExternalAutomation() }
            catch {
                FloeLogger(category: .app).warning(
                    "downloadWakeInitializationDeferred errorType=\(String(describing: type(of: error)))")
            }
        }
    }

    var backgroundDownloadAutomationReady: Bool {
        externalAutomationReady && bootstrapDidCompleteSuccessfully
            && !isEphemeral && persistenceReady && bootstrapError == nil
            && settingsCenter.launchPreferencesLoaded
    }

    /// Shared readiness for App Intents/Shortcuts automation. Joins the
    /// single-flight bootstrap and then the FIRST shared run recovery + model
    /// configuration publication for this process, so external starts and
    /// queries never observe a half-recovered graph:
    ///
    /// - `persistenceReady` can flip true inside bootstrap while later steps
    ///   still run; the whole task is joined instead of the boolean alone.
    /// - `reconcileInterruptedRunsOnLaunch()` is process-latched and protected
    ///   by its current-process owner rules; this seam never re-runs it per
    ///   call and never starts a second environment, pool or runtime.
    /// - Launch settings (approval/background choices) were loaded by
    ///   bootstrap; provider/model preferences are loaded by `reload()` here,
    ///   then read back from the durable store before automation may start.
    ///
    /// Failed durable initialization blocks external writes/queries. A
    /// configuration read failure is retryable on the next call. Caller
    /// cancellation is checked before and after the shared waits: a cancelled
    /// caller never proceeds to start work, and it never cancels the shared
    /// attempt other callers are joining.
    func ensureReadyForExternalAutomation() async throws {
        if externalAutomationReady { return }
        try Task.checkCancellation()
        await bootstrap()
        try Task.checkCancellation()
        try verifyDurableLaunchReady()
        // Another caller may have published readiness while this one awaited
        // the shared launch: join that result instead of a duplicate pass.
        if externalAutomationReady { return }

        await externalAutomationGate.run { [weak self] in
            guard let self else { return }
            #if DEBUG
            self.externalAutomationExecutionCount += 1
            #endif
            await self.conversationCenter.reconcileInterruptedRunsOnLaunch()
            await self.conversationCenter.reload()
            do {
                _ = try await self.configurationStore.preferences()
                _ = try await self.configurationStore.providers()
                _ = try await self.configurationStore.models()
                self.externalAutomationReady = true
            } catch {
                self.externalAutomationReady = false
            }
        }
        try Task.checkCancellation()
        try verifyDurableLaunchReady()
        guard externalAutomationReady else {
            throw FloeShortcutRunError.modelConfigurationUnavailable
        }
    }

    /// Read-only exact-run readiness. An already persisted run can be
    /// inspected, waited on or cancelled without a currently usable provider
    /// or model configuration, so this joins only the durable launch:
    /// single-flight bootstrap + launch recovery for runs left by a previous
    /// process. It never reloads model configuration, never starts a task and
    /// never invents a replacement environment.
    ///
    /// The capability (Shortcuts enabled) guard stays in the service, so a
    /// disabled capability still refuses before any read.
    func ensureDurableAutomationReady() async throws {
        try Task.checkCancellation()
        await bootstrap()
        try Task.checkCancellation()
        try verifyDurableLaunchReady()
        // Process-latched: marks stale non-terminal runs from a dead process
        // as interrupted so a query cannot report `running` forever. It reads
        // runs only and does not require provider/model configuration.
        await conversationCenter.reconcileInterruptedRunsOnLaunch()
        try Task.checkCancellation()
        try verifyDurableLaunchReady()
    }

    /// Exact-run service used by App Intents and Shortcuts. It projects the
    /// SAME live environment, stores and conversation center: no second
    /// `.live()`, database pool, runtime, or permission grant. The service
    /// holds sendable store reads, the durable exact-run reply reader, the
    /// system clock and weak app/center actions; a released environment never
    /// fabricates a replacement.
    func floeShortcutRunService() -> FloeShortcutRunService {
        let store = runStore
        let conversations = conversationStore
        let replyReader = SQLiteRunReplyReader(database: database)
        let outputReader = SQLiteRunOutputReader(database: database)
        return FloeShortcutRunService(deps: FloeShortcutRunDeps(
            ensureReady: { [weak self] access in
                guard let self else { throw FloeShortcutRunError.applicationStillStarting }
                switch access {
                case .read:
                    try await self.ensureDurableAutomationReady()
                case .start:
                    try await self.ensureReadyForExternalAutomation()
                }
            },
            capabilityEnabled: {
                AppleCapabilityPreferences.isEnabled(.shortcuts)
            },
            defaultModel: { [weak self] in
                guard let self else { return nil }
                let center = self.conversationCenter
                return center.providerAndModel(modelID: center.modelPreferences.defaultAgentModelID)
            },
            startTask: { [weak self] request in
                guard let self else { throw FloeShortcutRunError.applicationStillStarting }
                let center = self.conversationCenter
                let started = try await center.startTask(
                    goal: request.goal,
                    title: request.title,
                    provider: request.provider,
                    model: request.model,
                    startOrigin: .externalAutomation
                )
                return FloeRunStartReceipt(
                    runID: started.run.runID,
                    conversationID: started.conversationID
                )
            },
            cancelRun: { [weak self] runID in
                guard let self else { return }
                await self.conversationCenter.cancel(runID: runID)
            },
            hasLiveOwner: { [weak self] runID in
                guard let self else { return false }
                return self.conversationCenter.hasLiveOwner(runID: runID)
            },
            loadRun: { runID in
                try await store.run(id: runID)
            },
            loadConversation: { conversationID in
                try await conversations.conversation(id: conversationID)
            },
            recentRunEvents: { runID, limit in
                try await store.recentEvents(runID: runID, limit: limit)
            },
            earlierRunEvents: { runID, sequence, limit in
                try await store.earlierEvents(
                    runID: runID, beforeSequence: sequence, limit: limit
                )
            },
            provenFinalReplyText: { runID, conversationID, messageID in
                try await replyReader.provenFinalReplyText(
                    runID: runID, conversationID: conversationID, messageID: messageID
                )
            },
            // S3-D exact-run file projection. Both IDs are bound inside the
            // SQL predicate itself, and snapshot verification re-checks the
            // canonical RunOutputs bytes at retrieval. No new service graph,
            // no environment/provider dependency: reads need durable
            // storage only, same as the reply/text paths above.
            runOutputManifest: { runID, conversationID in
                try await outputReader.manifestRows(
                    runID: runID, expectedConversationID: conversationID
                )
            },
            verifyRunOutputSnapshot: { receipt in
                RunOutputSnapshotStore.verify(receipt)
            }
        ))
    }

    private func verifyDurableLaunchReady() throws {
        guard !isEphemeral, persistenceReady, bootstrapError == nil else {
            throw FloeShortcutRunError.durableStorageUnavailable
        }
    }

    /// Design adapters bound to the real services of this environment.
    @MainActor
    private static func makeDesignAdapters(environment: AppEnvironment) -> [DesignContentType: any DesignTypeAdapter] {
        let importPort = CreativeAssetDesignImportPort(environment: environment)
        let generationPort = MediaGenerationDesignPort(environment: environment)
        let cadPort = CanvasCADDesignExportPort(environment: environment)
        let capturePort = BrowserPageCapturePort(environment: environment)
        return [
            .image: ImageDesignAdapter(importPort: importPort, generationPort: generationPort),
            .video: VideoDesignAdapter(importPort: importPort),
            .pdf: PDFDesignAdapter(importPort: importPort),
            .notes: NotesDesignAdapter(importPort: importPort),
            .webpage: WebpageDesignAdapter(kind: .webpage, importPort: importPort, capturePort: capturePort),
            .prototype: WebpageDesignAdapter(kind: .prototype, importPort: importPort, capturePort: capturePort),
            .cad: CADDesignAdapter(exportPort: cadPort),
            // Office/presentation connect through an explicit Canvas-owned
            // workspace binding (canvas.designBindDocument); verified export
            // runs through OfficeCommandCenter. Engine-command edits stay in
            // the existing office proposal flow.
            .officeDocument: OfficeDesignAdapter(
                kind: .document,
                exportPort: OfficeDesignExportPort(environment: environment),
                bindingProvider: DesignBindingResolution.provider
            ),
            .presentation: OfficeDesignAdapter(
                kind: .presentation,
                exportPort: OfficeDesignExportPort(environment: environment),
                bindingProvider: DesignBindingResolution.provider
            )
        ]
    }

    #if DEBUG
    /// Hosted-test seam: publishes an ISOLATED in-memory environment as
    /// durably launched so the production Shortcuts factory and readiness
    /// layers can be exercised without running launch maintenance (Notes
    /// reconciliation, credential queues, CloudKit, fonts) against shared
    /// service roots. It writes no defaults, model configuration or
    /// notification state. Release builds do not contain this method.
    func markIsolatedLaunchReadyForTesting() {
        bootstrapDidCompleteSuccessfully = true
        persistenceReady = true
        bootstrapError = nil
    }
    #endif

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
