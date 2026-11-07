// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.host.voice.C03VoiceHost
import com.floe.android.SecretGatewayCapability
import com.floe.android.host.officeai.AppOfficeAiDocumentPorts
import com.floe.android.host.officeai.NativeOfficeAiTransport
import com.floe.android.host.officeai.OfficeAiHostPump
import com.floe.android.host.officeai.OfficeAiOoxmlVerifier
import com.floe.android.host.cad.C04CadViewerController
import com.floe.android.host.mail.C06BrokerMailLanGate
import com.floe.android.host.mail.C06MailHostController
import com.floe.android.host.calendar.C06CalendarHostController
import com.floe.android.host.systemservices.C06SystemServicesHostController
import com.floe.android.host.dataexchange.C07DataExchangeHostController
import com.floe.android.host.executiontarget.ExecutionTargetHostController
import com.floe.android.host.toolresults.ToolResultHostController
import com.floe.android.host.taskcontinuity.TaskContinuityHostController
import com.floe.android.host.remote.C05BrokerLocalNetworkGate
import com.floe.android.host.devicecommunication.C05BrokerDeviceLanGate
import com.floe.android.host.devicecommunication.C05DevicesHostController
import com.floe.android.host.remote.C05VNCClient
import com.floe.android.host.remote.C05RemoteFailure
import com.floe.android.host.remote.C05RemoteHostController
import com.floe.android.host.sftp.C05SFTPHostController
import com.floe.android.host.rdp.C05RDPClient
import com.floe.android.host.rdp.C05RDPException
import com.floe.android.host.rdp.C05RDPHostController
import com.floe.android.host.desktopassist.C05DesktopAssistSettingsController
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement

/**
 * The Application-owned G02 host binding.
 *
 * Exactly one [RuntimeHost] exists per process. It is created by
 * [com.floe.android.FloeApplication] after the RB-1 owned store bootstrap
 * reaches [RuntimeBootstrapCapability.OwnedStoreReady], it reuses the SAME
 * gateway + owner generation the Application already owns (no second
 * runtime/DB/token copy), and it outlives every Activity/Composition.
 * Navigation, rotation, background/lock and recomposition never restart or
 * dispose it; only the Application owner stops it (real drain before the
 * database closes).
 *
 * The host owns the typed domain controllers that map every existing G02
 * feature callback onto canonical native operations and project the async
 * effect/event channels back into the immutable UI states the feature
 * components consume:
 *
 *  * [ProviderHostController] — providers/models/catalogue/preferences;
 *  * [ConversationHostController] — conversation/history/run/temporary;
 *  * [IntegrationsHostController] — Skills/MCP/backend tool discovery;
 *  * [SettingsHostController] — defaults/memory/personalization/usage/privacy;
 *  * [WebSearchHostController] — web-search provider metadata + secure editor;
 *  * [AttachmentImportController] — picker/SAF/staging handoff ownership;
 *  * [ProjectHostController] — the real user project library CRUD +
 *    pre-first-run assignment projections.
 *
 * Nothing in this package executes business logic natively in Kotlin: the
 * Swift runtime remains the single structural authority; the host only
 * correlates, decodes, budgets, fences and projects.
 */
class RuntimeHost internal constructor(
    val commandClient: RuntimeHostCommandClient,
    internal val gatewayCapability: StateFlow<SecretGatewayCapability>,
    internal val bootstrapCapability: StateFlow<RuntimeBootstrapCapability>,
    internal val scope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default),
    internal val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val readinessState = MutableStateFlow(RuntimeHostReadiness())
    val readiness: StateFlow<RuntimeHostReadiness> = readinessState

    /** Controllers are created eagerly; they bind as readiness admits. */
    val providers = ProviderHostController(this)
    val conversations = ConversationHostController(this)
    val integrations = IntegrationsHostController(this)
    val gitCredentials = GitHubCredentialHostController(this)
    val settings = SettingsHostController(this)
    val webSearch = WebSearchHostController(this)
    val attachments = AttachmentImportController(this)
    val home = HomeLaunchpadHost(this)
    /** Real managed user-project library. Source-only until Main wires the
     * native C01 library/bridge; commands stay fail-closed until then. */
    val projects = ProjectHostController(this)
    /**
     * C02 App-owned per-task execution target. Swift owns pinning, migration,
     * CAS and the drain gate; this controller only correlates trusted-host
     * replies. It never starts an SSH session or a target on construction.
     */
    val executionTargets = ExecutionTargetHostController(this)
    /**
     * C02 retained tool-result reader for the existing tool card. It pages
     * only this task's already-redacted bytes through `floe.results/20`; it
     * never re-runs a tool and never opens a workspace file.
     */
    internal val toolResults = ToolResultHostController()
    /**
     * C02 App-owned durable task continuity. The Swift coordinator owns the
     * pause marker, storage probe and explicit resume validation; this
     * controller only correlates trusted-host replies and never resumes,
     * answers or retries automatically.
     */
    val taskContinuity = TaskContinuityHostController(this)
    /** Ordinary-task editor projections outlive Activity/inspector views. */
    internal val workspaceEditors = G04WorkspaceEditorController(this)
    internal val externalEdits by lazy {
        com.floe.android.host.externaledit.ExternalEditController(appContext, this)
    }
    internal val browser = BrowserHostController(this)
    internal val workspaceGit = G04GitHostController(this)
    internal val workspaceActions = G04ActionsHostController(this)
    /**
     * G07.1 Application-owned read-only full-window PDF/raster preview. It
     * owns the verified immutable snapshot, the isolated PDF renderer host
     * and the transient decoded bitmap, so rotation, background and the
     * dialog's own recomposition never duplicate a stage/render. Created
     * lazily on the first explicit document open; [prepareWorkspaceDocumentPreviewForRootStop]
     * is the real root-stop gate.
     */
    private val workspaceDocumentPreviewDelegate = lazy {
        WorkspaceDocumentPreviewController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            currentHostGeneration = { commandClient.generation() },
            isTemporaryTask = { id -> conversations.entryFor(id)?.isTemporary == true },
            admitsPasswordPrompt = {
                nativeRootEpoch() != null &&
                    (appContext as? com.floe.android.FloeApplication)?.isActivityInForeground() != false
            },
        )
    }
    internal val workspaceDocumentPreview: WorkspaceDocumentPreviewController
        get() = workspaceDocumentPreviewDelegate.value
    /**
     * C04A Application-owned read-only CAD/3D viewer. The native snapshots,
     * local-only WebView session and capture artifacts outlive Activity /
     * composition so rotation does not re-stage the source. Created lazily on
     * the first explicit CAD open; the root-stop drain below is the real gate.
     */
    private val cadViewerDelegate = lazy {
        C04CadViewerController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            currentHostGeneration = { commandClient.generation() },
            isTemporaryTask = { id -> conversations.entryFor(id)?.isTemporary == true },
        )
    }
    internal val cadViewer: C04CadViewerController
        get() = cadViewerDelegate.value
    /**
     * WSF-SAFE-EXTRACT Application-owned archive document controller. It
     * owns only the trusted `floe.archive/25` bridge calls, the
     * long-running extract job, its real cancellation/progress and the
     * typed state the full-window browser renders; every byte and effect
     * stays behind the bridge on the ORIGINAL G04 workspace lease. Created
     * lazily on the first explicit archive open; the root-stop gate below
     * drains it before the epoch retires.
     */
    private val workspaceArchiveDelegate = lazy {
        WorkspaceArchiveHostController(
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            currentHostGeneration = { commandClient.generation() },
            isTemporaryTask = { id -> conversations.entryFor(id)?.isTemporary == true },
        )
    }
    internal val workspaceArchive: WorkspaceArchiveHostController
        get() = workspaceArchiveDelegate.value
    /**
     * C05 Application-owned SSH remote-host controller. Created lazily on
     * the first Remote screen use; it owns only the trusted-host bridge
     * calls, PTY polling and bounded input lanes. The root-stop gate below
     * closes every live SSH channel and loopback listener.
     */
    private val c05RemoteDelegate = lazy {
        C05RemoteHostController(
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            localNetwork = C05BrokerLocalNetworkGate(integrations.localNetwork),
        )
    }
    internal val c05Remote: C05RemoteHostController
        get() = c05RemoteDelegate.value

    /**
     * C05 Application-owned SFTP controller. It is created lazily on the
     * first remote-file use; all host trust, credentials and destination
     * commits stay in the Swift `floe.sftp/18` domain. The root-stop gate
     * below drains every lane and staging file before the epoch retires.
     */
    private val c05SFTPDelegate = lazy {
        C05SFTPHostController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
        )
    }
    internal val c05Sftp: C05SFTPHostController
        get() = c05SFTPDelegate.value

    /**
     * C05 Application-owned RDP controller. The real FreeRDP session, frame
     * lease, explicit certificate decision and bounded input lane live in
     * FloeAndroidCore/FloeRDP; this controller only owns the trusted
     * `floe.rdp/17` client and the App-scoped pump. It is created lazily on
     * the first RDP screen use and drained before Root retirement.
     */
    private val c05RdpDelegate = lazy {
        C05RDPHostController(
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
        )
    }
    internal val c05Rdp: C05RDPHostController
        get() = c05RdpDelegate.value

    /**
     * C05 Desktop Assist settings controller (secure credential cards and
     * text-recognition readiness). App-scoped: a card save/delete is drained
     * before Root retirement and never belongs to a Settings view lifetime.
     */
    private val c05DesktopAssistDelegate = lazy {
        C05DesktopAssistSettingsController(
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
        )
    }
    internal val desktopAssist: C05DesktopAssistSettingsController
        get() = c05DesktopAssistDelegate.value

    /**
     * C05 Application-owned real-device controller: TCP/Telnet sockets, BLE
     * GATT sessions, USB serial sessions, USB permission receiver and the
     * trusted device model-tool pump. It follows the live native epoch and
     * is drained before Root retirement. Created on the accepted store
     * generation so configured model tools work without opening the screen.
     */
    private val c05DevicesDelegate = lazy {
        C05DevicesHostController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            lanGate = C05BrokerDeviceLanGate(integrations.localNetwork),
        )
    }
    internal val c05Devices: C05DevicesHostController
        get() = c05DevicesDelegate.value

    /**
     * C06 Application-owned mail controller. The controller owns the trusted
     * host bridge, the platform TLS lane, the compose draft and bounded SAF
     * attachment transfer. It is app-scoped so a send/download never belongs
     * to a view; the root-stop gate below closes the lane before retirement.
     */
    private val c06MailDelegate = lazy {
        C06MailHostController(
            scope = scope,
            contentResolver = appContext.contentResolver,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            lanGate = C06BrokerMailLanGate { integrations.localNetwork },
        )
    }
    internal val c06Mail: C06MailHostController
        get() = c06MailDelegate.value

    /**
     * C06 Application-owned calendar/todo controller. It owns the trusted
     * bridge token, the real CalendarContract backend, the reverse provider
     * lane and the local reminder transport. App-scoped so a provider write
     * or reminder rearm never belongs to a view; the root-stop gate closes
     * the lane before retirement.
     */
    private val c06CalendarDelegate = lazy {
        C06CalendarHostController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
        )
    }
    internal val c06Calendar: C06CalendarHostController
        get() = c06CalendarDelegate.value

    /**
     * C06 Application-owned system-services controller. It owns the trusted
     * bridge token, the real location/contacts/NFC/Health Connect platform
     * clients, permission/ActivityResult routing, the foreground/NFC lifecycle
     * and the reverse mailbox lane. App-scoped so a permission result or tag
     * scan never belongs to a view; the root-stop gate closes it before
     * retirement.
     */
    private val c06SystemServicesDelegate = lazy {
        C06SystemServicesHostController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
        )
    }
    internal val c06SystemServices: C06SystemServicesHostController
        get() = c06SystemServicesDelegate.value

    /**
     * C07 Application-owned manual data exchange. It owns no archive bytes:
     * SAF source/destination, bounded chunk streaming and the read-back
     * receipt live here; staging, manifest validation, hashing and the
     * restore journal live in the trusted Swift domain. App-scoped so a
     * download/restore does not belong to a dismissed view.
     */
    private val c07DataExchangeDelegate = lazy {
        C07DataExchangeHostController(
            context = appContext,
            scope = scope,
            currentNativeEpoch = ::nativeRootEpoch,
            ioDispatcher = ioDispatcher,
        )
    }
    internal val c07DataExchange: C07DataExchangeHostController
        get() = c07DataExchangeDelegate.value
    internal var workspaceGitTrust: G04GitTrustController? = null
    private val linuxDesktopOwner = lazy { com.floe.android.host.linux.LinuxDesktopHost(this) }
    internal val linuxDesktop get() = linuxDesktopOwner.value
    internal fun linuxDesktopMetadata(environmentID: String): org.json.JSONObject? =
        if (linuxDesktopOwner.isInitialized()) linuxDesktopOwner.value.environmentMetadata(environmentID) else null
    internal var workspaceTerminal: G04TerminalHostController? = null

    private var observationJob: Job? = null
    private val started = java.util.concurrent.atomic.AtomicBoolean(false)
    private val configProjectionRefreshed = java.util.concurrent.atomic.AtomicBoolean(false)
    /** Application-owned foreground adapter; absent in pure controller fixtures. */
    internal var runForeground: RunForegroundBinding? = null
    /**
     * Channel flavour extension (FULL: real phone/ADB/Root settings + trusted
     * platform-tool pump; PLAY: inert). Application-owned through this host; a
     * null value means a pure controller fixture and every hook is skipped.
     */
    internal var platformExtension: RuntimePlatformExtension? = null

    /** G09-R1 creative Canvas/media lane; bound by the Application owner. */
    internal var creativeHost: com.floe.android.host.creative.CreativeHostController? = null
    /**
     * C03 App-owned voice coordinator. Created by [create] after the context is
     * attached; pure controller fixtures never touch it.
     */
    internal lateinit var voice: C03VoiceHost
    /** Typed accessor for the later Canvas/media UI routes (same instance). */
    internal fun creativeServices(): com.floe.android.feature.workbench.CreativeHostApi? =
        creativeHost?.services
    /** Application-owned provider transport; null in fixtures/unbound hosts. */
    internal var workspaceSources: WorkspaceSourcePump? = null
    /** Same Application owner and native epoch as the provider transport. */
    internal var networkWorkspaceHost: NetworkWorkspaceHostController? = null
    /** One phone-native measurement service shared by workbench and Agent pump. */
    internal val networkService by lazy { com.floe.android.core.network.PhoneNetworkService(appContext) }
    internal val networkWorkbench by lazy { NetworkWorkbenchController(this) }
    /** Offline artifacts share this host's scope and native generation. The
     * owned lazy avoids a process-wide registry retaining retired hosts. */
    private val networkArtifactDelegate = lazy {
        com.floe.android.host.networkartifact.NetworkArtifactHostController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            networkService = networkService,
            access = networkArtifactAccessFor(::nativeRootEpoch),
        )
    }
    internal val networkArtifact: com.floe.android.host.networkartifact.NetworkArtifactHostController
        get() = networkArtifactDelegate.value
    internal val isNetworkArtifactInitialized: Boolean
        get() = networkArtifactDelegate.isInitialized()

    /** Root draining must not create an unused artifact controller. */
    internal fun networkArtifactIfCreated(): com.floe.android.host.networkartifact.NetworkArtifactHostController? =
        if (networkArtifactDelegate.isInitialized()) networkArtifactDelegate.value else null

    /**
     * C06 Application-owned live capture. Created only by an explicit capture
     * panel entry; the service owns the TUN fd/forwarders while this host owns
     * the launch ticket, state machine, raw artifact and analysis publication.
     * RootStop never constructs an unused controller.
     */
    private val captureDelegate = lazy {
        com.floe.android.host.capture.CaptureHostController(
            context = appContext,
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            onPcapPublished = {
                networkArtifactIfCreated()?.refreshForExternalCapture()
            },
        ).also { com.floe.android.host.capture.CaptureServiceRuntime.install(it) }
    }
    internal val capture: com.floe.android.host.capture.CaptureHostController
        get() = captureDelegate.value
    internal val isCaptureInitialized: Boolean
        get() = captureDelegate.isInitialized()

    internal fun captureIfCreated(): com.floe.android.host.capture.CaptureHostController? =
        if (captureDelegate.isInitialized()) captureDelegate.value else null
    internal data class NetworkPermissionNotice(
        val request: com.floe.android.host.network.NetworkPermissionRequest,
        val generation: Long,
        val epoch: Long?,
    )
    internal val networkPermissionNotice = MutableStateFlow<NetworkPermissionNotice?>(null)
    internal val networkDiagnostics by lazy {
        com.floe.android.host.network.NetworkDiagnosticsHostController(
            scope = scope, ioDispatcher = ioDispatcher, currentNativeEpoch = ::nativeRootEpoch,
            serviceProvider = { com.floe.android.host.network.PhoneNetworkServiceAdapter(networkService) },
            onPermissionRequired = { request ->
                networkPermissionNotice.value = NetworkPermissionNotice(request, commandClient.generation(), nativeRootEpoch())
            },
        )
    }
    private var networkDiagnosticsControl: Job? = null
    private var networkArtifactControl: Job? = null
    private val networkDiagnosticsLock = Any()

    /**
     * Native-root generation gate for the monitoring launch. It is armed
     * before the root drain (even when the lazy host below was never
     * constructed) and admits explicit Starts again only after a different
     * live [nativeRootEpoch] is observed. This is the root-retirement hook,
     * not a second lifecycle tracker: the launch lifecycle stays in the
     * host-side pure ledger.
     */
    private val networkMonitorLaunchAdmission =
        com.floe.android.host.networkmonitor.NetworkMonitorLaunchAdmission()

    internal fun isNetworkMonitorLaunchAdmitted(): Boolean =
        networkMonitorLaunchAdmission.isAdmitted(nativeRootEpoch())

    private fun armNetworkMonitorLaunchRetirementAt(epoch: Long?) {
        networkMonitorLaunchAdmission.arm(epoch)
    }

    /**
     * G07.2 application-scoped bounded-monitoring host. Construction performs
     * no probe, no disk read and no Service start; it is admitted only when
     * the dedicated monitoring panel is first opened. The existing single
     * PhoneNetworkService is the only transport port, and the real Activity
     * foreground callback is the start authority. The ServiceRuntime resolver
     * is installed before the panel can expose Start.
     */
    private val networkMonitorDelegate = lazy {
        val monitor = com.floe.android.host.networkmonitor.NetworkMonitorHost(
            context = appContext,
            executor = com.floe.android.host.networkmonitor.PhoneNetworkMonitorExecutor(networkService),
            isAppForeground = {
                (appContext as? com.floe.android.FloeApplication)?.isActivityInForeground() == true
            },
            deviceMetadata = {
                val appVersion = runCatching {
                    appContext.packageManager.getPackageInfo(appContext.packageName, 0).versionName
                }.getOrNull().orEmpty().take(128).ifBlank { "unknown" }
                com.floe.android.core.networkmonitor.NetworkMonitorDeviceMetadata(
                    osVersion = "Android ${android.os.Build.VERSION.RELEASE} " +
                        "(API ${android.os.Build.VERSION.SDK_INT})",
                    appVersion = appVersion,
                )
            },
            launchAdmission = ::isNetworkMonitorLaunchAdmitted,
        )
        com.floe.android.host.networkmonitor.NetworkMonitorServiceRuntime.install(monitor)
        monitor
    }
    internal val networkMonitorHost: com.floe.android.host.networkmonitor.NetworkMonitorHost
        get() = networkMonitorDelegate.value

    /** Test/verification seam: proves an untouched panel is not initialized by root stop. */
    internal val isNetworkMonitorHostInitialized: Boolean
        get() = networkMonitorDelegate.isInitialized()
    /** Stable in-process control owner for the workbench monitoring panel. */
    internal val networkMonitorOwnerId =
        "network-monitor-ui:" + java.util.UUID.randomUUID().toString()

    internal fun currentNetworkPermissionNotice(notice: NetworkPermissionNotice): Boolean =
        networkPermissionNotice.value === notice && commandClient.generation() == notice.generation && nativeRootEpoch() == notice.epoch

    private fun startNetworkDiagnosticsLane() {
        if (!::appContext.isInitialized) return
        synchronized(networkDiagnosticsLock) {
            if (networkDiagnosticsControl?.isActive == true) return
            networkDiagnosticsControl = scope.launch(ioDispatcher) {
                for (attempt in 0 until 5) {
                    val epoch = nativeRootEpoch()
                    if (epoch != null && epoch > 0) {
                        val previous = networkDiagnostics.boundEpoch()
                        if (previous > 0 && previous != epoch && !networkDiagnostics.stopAndJoin(previous, 5_000)) return@launch
                        if (networkDiagnostics.start(epoch)) return@launch
                    }
                    delay(250L * (attempt + 1))
                }
            }
        }
    }

    private fun startNetworkArtifactLane() {
        if (!::appContext.isInitialized) return
        synchronized(networkDiagnosticsLock) {
            if (networkArtifactControl?.isActive == true) return
            networkArtifactControl = scope.launch(ioDispatcher) {
                for (attempt in 0 until 5) {
                    val epoch = nativeRootEpoch()
                    if (epoch != null && epoch > 0) {
                        val artifacts = networkArtifact
                        val previous = artifacts.boundEpoch()
                        if (previous > 0 && previous != epoch &&
                            !artifacts.stopAndJoin(previous, 5_000)
                        ) return@launch
                        if (artifacts.start(epoch)) return@launch
                    }
                    delay(250L * (attempt + 1))
                }
            }
        }
    }

    internal suspend fun prepareNetworkForRootStop(): Boolean {
        // Arm the generation gate before any lane work: from here on a new
        // launch (including one arriving after an untouched lazy host is
        // eventually constructed) is refused until a different live native
        // root epoch exists. Repeated drains keep the last known epoch.
        armNetworkMonitorLaunchRetirementAt(nativeRootEpoch())
        return drainNetworkForRootStop()
    }

    private suspend fun drainNetworkForRootStop(): Boolean {
        networkWorkbench.leave()
        networkPermissionNotice.value = null
        networkDiagnosticsControl?.cancelAndJoin()
        networkDiagnosticsControl = null
        // Never initialize the monitoring host just to stop it: an untouched
        // panel has no owned launch. For an admitted host, retirement first
        // invalidates every PENDING/CLAIMED launch (not just the asynchronously
        // published StateFlow), then joins the exact ACTIVE session before the
        // native root is retired. A failed join is reported honestly and keeps
        // the old generation pending.
        val monitorReady = if (networkMonitorDelegate.isInitialized()) {
            val monitor = networkMonitorDelegate.value
            val retirement = monitor.retireForRootStop()
            val sessionId = retirement.activeSessionId
            sessionId == null || monitor.stopAndJoin(
                sessionId,
                NETWORK_MONITOR_STOP_WAIT_MS,
                com.floe.android.core.networkmonitor.NetworkMonitorEndReason.SERVICE_DESTROYED,
            )
        } else {
            true
        }
        val epoch = networkDiagnostics.boundEpoch()
        val diagnosticsReady = epoch <= 0 || networkDiagnostics.stopAndJoin(epoch, 5_000)
        networkArtifactControl?.cancelAndJoin()
        networkArtifactControl = null
        // Even a local-only artifact operation started before mailbox binding
        // must settle. Do not skip its IO drain merely because epoch is zero.
        val artifacts = networkArtifactIfCreated()
        val artifactsReady = artifacts == null ||
            artifacts.stopAndJoin(artifacts.boundEpoch(), 5_000)
        val capture = captureIfCreated()
        val captureReady = capture == null ||
            capture.prepareForRootStop(nativeRootEpoch() ?: 0L, 5_000L)
        return monitorReady && diagnosticsReady && artifactsReady && captureReady
    }

    /**
     * Root-stop gate for the owned workspace document preview: cancel a
     * still-staging read, release the isolated renderer, and wait for the
     * real snapshot-deletion quiescence BEFORE the native root is retired.
     * True when nothing was ever created. An unproven drain returns false so
     * the coordinator keeps the old generation honestly pending (the same
     * contract as the network lane, which remains the LAST drain clause).
     */
    internal suspend fun prepareWorkspaceDocumentPreviewForRootStop(): Boolean =
        if (workspaceDocumentPreviewDelegate.isInitialized()) {
            workspaceDocumentPreview.prepareForRootStop(WORKSPACE_PREVIEW_STOP_WAIT_MS)
        } else {
            true
        }

    /**
     * Root-stop gate for the C04A viewer: cancel a still-staging read, destroy
     * the local WebView surface, delete only this session's immutable
     * snapshots and release the Swift session before the native root retires.
     * An unproven drain keeps the old generation pending.
     */
    internal suspend fun prepareCadViewerForRootStop(): Boolean =
        if (cadViewerDelegate.isInitialized()) {
            cadViewer.prepareForRootStop(CAD_VIEWER_STOP_WAIT_MS)
        } else {
            true
        }

    /**
     * Root-stop gate for the archive document surface: cancel a still-
     * running extraction (the engine abandons its staging), discard hidden
     * preview staging and join the owned jobs before the native root
     * retires. An unproven drain keeps the old generation pending.
     */
    internal suspend fun prepareWorkspaceArchiveForRootStop(): Boolean =
        if (workspaceArchiveDelegate.isInitialized()) {
            workspaceArchive.prepareForRootStop(ARCHIVE_STOP_WAIT_MS)
        } else {
            true
        }

    /**
     * Root-stop gate for C05 SSH: close every live session, PTY, exec
     * channel and loopback listener and await their owned shutdown before
     * the native root retires. An unproven drain keeps the old generation
     * pending; no remote session survives into a new epoch.
     */
    internal suspend fun prepareC05RemoteForRootStop(): Boolean {
        if (c05RemoteDelegate.isInitialized()) {
            return c05Remote.prepareForRootStop(C05_REMOTE_STOP_WAIT_MS)
        }
        // Ordinary VNC model tools can open a Swift-owned VNC session without
        // ever showing the Remote screen. Drain the VNC domain directly so
        // such a session cannot outlive the native Root epoch merely because
        // the UI controller was never constructed.
        val epoch = nativeRootEpoch()?.takeIf { it > 0 } ?: return true
        return try {
            val result = withContext(ioDispatcher) { C05VNCClient().rootStop(epoch) }
            result.drained
        } catch (failure: C05RemoteFailure) {
            failure.code == "needsCoreUpdate" || failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Root-stop gate for C05 Desktop Assist: drain any in-flight card
     * save/delete before the native Root epoch retires. A controller that
     * was never constructed is already drained.
     */
    internal suspend fun prepareC05DesktopAssistForRootStop(): Boolean {
        if (!c05DesktopAssistDelegate.isInitialized()) return true
        desktopAssist.stop()
        return true
    }

    /**
     * Root-stop gate for C05 RDP: close every live FreeRDP session, release
     * pressed input and await the App/tool frame/input pump before the native
     * root retires. An unproven drain keeps the generation pending; no RDP
     * session survives into a new epoch.
     */
    internal suspend fun prepareC05RDPForRootStop(): Boolean {
        if (c05RdpDelegate.isInitialized()) {
            return c05Rdp.prepareForRootStop(C05_RDP_STOP_WAIT_MS)
        }
        // Model tools can open a Swift-owned RDP session without ever showing
        // the RDP screen. Drain that domain directly so a tool session cannot
        // outlive the native Root epoch just because the UI controller was
        // never constructed.
        val epoch = nativeRootEpoch()?.takeIf { it > 0 } ?: return true
        return try {
            withContext(ioDispatcher) { C05RDPClient().rootStop(epoch) }
            true
        } catch (failure: C05RDPException) {
            failure.code == "needsCoreUpdate" || failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (failure: com.floe.android.host.remote.C05RemoteFailure) {
            failure.code == "needsCoreUpdate" || failure.code == "coreUnavailable" ||
                failure.code == "runtimeNotInstalled"
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Root-stop gate for C05 SFTP: cancel every staged transfer, remove only
     * this lane's staging files, close the SFTP channel/SSH transport and
     * await the native typed drain before the root epoch retires.
     */
    internal suspend fun prepareC05SFTPForRootStop(): Boolean =
        if (c05SFTPDelegate.isInitialized()) {
            c05Sftp.prepareForRootStop(C05_SFTP_STOP_WAIT_MS)
        } else {
            true
        }

    /**
     * Root-stop gate for C02: cancel a pending target/migration reply and
     * drop the controller's projection before the native root retires. The
     * Swift domain owns any durable migration row; a cancelled bridge reply
     * cannot commit it.
     */
    internal suspend fun prepareC02ExecutionTargetsForRootStop(): Boolean {
        executionTargets.release()
        taskContinuity.release()
        return true
    }

    /**
     * Root-stop gate for C05 devices: stop the trusted tool mailbox, close
     * every App/tool TCP/Telnet/BLE/USB session and await the engine's real
     * close/join before the native root retires. An unproven drain keeps the
     * generation pending; no device handle survives into a new epoch.
     */
    internal suspend fun prepareC05DevicesForRootStop(): Boolean =
        if (c05DevicesDelegate.isInitialized()) {
            c05Devices.prepareForRootStop(C05_DEVICES_STOP_WAIT_MS)
        } else {
            true
        }

    /**
     * Root-stop gate for C06 mail: close every platform TLS socket, join the
     * lane and acknowledge `laneClosed` before the old native mailbox is
     * retired. An unproven drain keeps the old generation pending; an
     * in-flight send is never reported as a success by this gate.
     */
    internal suspend fun prepareC06MailForRootStop(): Boolean =
        if (c06MailDelegate.isInitialized()) {
            c06Mail.prepareForRootStop(C06_MAIL_STOP_WAIT_MS.toInt())
        } else {
            true
        }

    /**
     * Root-stop gate for C06 calendar/todo: stop admitting provider tickets,
     * join the App lane and acknowledge `laneClosed` before the old Swift
     * mailbox retires. An unproven drain keeps the generation pending; a
     * calendar write is never reported as a success by this gate.
     */
    internal suspend fun prepareC06CalendarForRootStop(): Boolean =
        if (c06CalendarDelegate.isInitialized()) {
            c06Calendar.prepareForRootStop(C06_CALENDAR_STOP_WAIT_MS.toInt())
        } else {
            true
        }

    /**
     * Root-stop gate for C06 system services: cancel permission/refresh work,
     * unregister capability receivers, disable NFC reader mode and drain the
     * platform mailbox before the old Swift generation retires. An unproven
     * drain keeps the old generation pending; an in-flight read is never
     * reported as a success by this gate.
     */
    internal suspend fun prepareC06SystemServicesForRootStop(): Boolean =
        if (c06SystemServicesDelegate.isInitialized()) {
            c06SystemServices.prepareForRootStop(C06_SYSTEM_SERVICES_STOP_WAIT_MS.toInt())
        } else {
            true
        }

    /**
     * Root-stop gate for C07: cancel an in-flight SAF read/write and the
     * native job. Staged files are app-private; the durable restore journal
     * remains for the next generation's explicit recovery action.
     */
    internal suspend fun prepareC07DataExchangeForRootStop(): Boolean =
        if (c07DataExchangeDelegate.isInitialized()) c07DataExchange.prepareForRootStop() else true

    internal suspend fun prepareFontsForRootStop(): Boolean =
        if (fontToolsDelegate.isInitialized()) fontTools.stopAndJoin() else true

    internal fun resumeFontsAfterRefusedStop() {
        if (fontToolsDelegate.isInitialized() && nativeRootEpoch()?.let { it > 0L } == true) {
            fontTools.resumeAfterRefusedStop()
        }
    }


    internal var workspaceSourceHost: WorkspaceSourceHostController? = null
    /** D04 owned run-output lane (list / verified Save Copy / Office egress
     * helper). Stateless per call: every query carries the CURRENT accepted
     * native root epoch and the Swift side re-validates it, so no explicit
     * bind/retire dance exists here; the Application retires only the
     * service's pending Save Copy pick at `Stopped`. */
    internal var runOutputs: com.floe.android.host.output.RunOutputHostService? = null

    /**
     * G05-R2 Office AI host lane (Main host20): ONE serialized epoch pump
     * over the delivered OfficeAiNative claims. It binds only to the ACTUAL
     * accepted root epoch at [onBootstrapCapability] `OwnedStoreReady`
     * (bounded attempts, no idle poller) — a successful bind is what makes
     * `document.office.edit` really available on the Swift side; a refused
     * bind leaves the tool honestly absent (never a constructor-stub true).
     * Stop/retire runs through the pump's own drain contract before Root
     * close: an unproven drain keeps the old generation honestly pending.
     */
    internal var officeAi: OfficeAiHostPump? = null
    private var officeAiControl: Job? = null
    private var officeAiRetire: Job? = null
    private val officeAiLock = Any()

    /**
     * Observation-only projection of the shell's modal surfaces (Settings
     * Dialog, preview Dialog, open navigation drawer) maintained by FloeShell
     * for the Office AI lane's TRANSIENT launch admission (Main review
     * 2026-10-27): the privacy visible-holder binding does NOT clear while
     * SettingsSheet layers over the still-composed chat, so
     * [com.floe.android.host.ConversationHostController.currentVisibleConversationId]
     * alone cannot prove no modal owns the surface. Nothing reads this for
     * privacy, navigation or rendering behavior — it is written by ONE
     * LaunchedEffect observer in the shell and consumed only by the AI
     * launch admission before the viewer claims (never after VIEWING).
     */
    @Volatile
    internal var uiModalSurfaceOwned = false

    internal enum class BackgroundAvailability { NOTIFICATIONS_BLOCKED, SYSTEM_UNAVAILABLE }
    internal val backgroundAvailabilityNotice = MutableStateFlow<BackgroundAvailability?>(null)
    private val backgroundNoticeReported = java.util.concurrent.atomic.AtomicBoolean()
    @Volatile private var backgroundNoticeDiagnostic: com.floe.android.runlifecycle.RunForegroundTrace.Attribution? = null
    internal fun reportBackgroundUnavailable(failure: com.floe.android.runlifecycle.RunForegroundFailure) {
        val posted = backgroundNoticeReported.compareAndSet(false, true)
        val diagnostic = com.floe.android.runlifecycle.RunForegroundTrace.notice(failure, posted)
        if (posted) {
            backgroundNoticeDiagnostic = diagnostic
            backgroundAvailabilityNotice.value = if (failure is com.floe.android.runlifecycle.RunForegroundFailure.NotificationsBlocked)
                BackgroundAvailability.NOTIFICATIONS_BLOCKED else BackgroundAvailability.SYSTEM_UNAVAILABLE
        }
    }

    internal fun backgroundNoticeBoundToUi() {
        if (backgroundAvailabilityNotice.value != null) {
            com.floe.android.runlifecycle.RunForegroundTrace.noticeBoundToUi(backgroundNoticeDiagnostic)
        }
    }

    /**
     * G02 minimal readiness adapter (additive delta): polls the narrow
     * trusted-host native readbacks and republishes the REAL per-domain
     * state through the existing [onDomainAvailability] seam. Null/invalid
     * native answers never manufacture readiness.
     */
    private val g02ReadinessAdapter = G02DomainReadinessAdapter(
        host = this,
        readReadiness = {
            runCatching { com.floe.android.bridge.RuntimeCoreNative.g02DomainReadiness() }
                .getOrNull()
        },
        readRootEpoch = {
            runCatching {
                com.floe.android.bridge.RuntimeCoreNative.g02NativeRootEpoch()?.toLongOrNull()
            }.getOrNull() ?: -1L
        },
    )

    /**
     * ACTUAL accepted native Root epoch, or null when no generation is live.
     * Shared trusted-host readback used by the secure-route admission; it
     * NEVER fabricates a 0 and never echoes the UI command generation.
     */
    internal var nativeRootEpochReader: () -> Long? = {
        runCatching {
            com.floe.android.bridge.RuntimeCoreNative.g02NativeRootEpoch()?.toLongOrNull()
        }.getOrNull()?.takeIf { it > 0 }
    }

    fun nativeRootEpoch(): Long? = nativeRootEpochReader()

    /**
     * Privileged privacy-clear confirmation issuer injected by the
     * Application owner. The implementation resolves the live coordinator's
     * ACCEPTED epoch + owner token and the native ingress; the owner token
     * never enters this class's state, a log or the wire. [expectedNativeEpoch]
     * is the exact accepted Root epoch the App bound to the immutable user
     * preview — a stale/foreign epoch is refused by the owner, never minted.
     * Must be invoked off the main thread.
     */
    internal var privacyConfirmationIssuer:
        ((expectedNativeEpoch: Long, operation: String, previewDigest: String,
          invocationID: String, action: String) -> String?)? = null

    fun issuePrivacyConfirmation(
        expectedNativeEpoch: Long,
        operation: String,
        previewDigest: String,
        invocationID: String,
        action: String,
    ): String? = privacyConfirmationIssuer?.invoke(
        expectedNativeEpoch, operation, previewDigest, invocationID, action)

    // create() injects appContext after construction; instantiate only once
    // the Application starts this host and its owned services.
    private val fontToolsDelegate = lazy {
        com.floe.android.host.fonts.FontToolHostPump(appContext, scope, ::nativeRootEpoch)
    }
    private val fontTools by fontToolsDelegate

    /** Called once by the Application owner, off-main. */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        platformExtension?.onHostStarted(this)
        if (appContextOrNull != null) fontTools.start()
        observationJob = scope.launch(ioDispatcher) { observeCapabilities() }
        providers.start()
        conversations.start()
        integrations.start()
        gitCredentials.start()
        attachments.start()
        settings.start()
        webSearch.start()
        home.start()
        projects.start()
        if (::voice.isInitialized) voice.start()
    }

    /**
     * Real shutdown: controllers drain their pumps first (generation bump
     * disposes matching collectors only), then the caller proceeds with the
     * RB-1 owner stop. The host never cancels another owner's work.
     */
    suspend fun stop() {
        if (linuxDesktopOwner.isInitialized() && !linuxDesktopOwner.value.stopAndJoin()) return
        if (!prepareC07DataExchangeForRootStop()) return
        if (!prepareFontsForRootStop()) return
        // C03 voice owns real microphone/TTS/cloud operations; fence and join
        // them before the native root retires.
        if (::voice.isInitialized && !voice.prepareForRootStop()) return
        // A real preview reader still holding a native-root snapshot must
        // close before the root retires; a refused drain keeps the old
        // generation rather than pretending the document work is gone.
        if (!prepareWorkspaceDocumentPreviewForRootStop()) return
        // An in-flight archive extract/preview staging is real workspace
        // work owned by this host; drain it with the same contract.
        if (!prepareWorkspaceArchiveForRootStop()) return
        if (!prepareNetworkForRootStop()) return
        commandClient.bumpGeneration()
        providers.stop()
        conversations.stop()
        integrations.stop()
        gitCredentials.stop()
        attachments.stop()
        settings.stop()
        webSearch.stop()
        if (c05DesktopAssistDelegate.isInitialized()) desktopAssist.stop()
        home.stop()
        projects.stop()
        observationJob?.cancel()
        // The Office AI pump drains through its OWN contract first: an
        // unproven drain keeps the old generation owned/pending honestly
        // (no force clean-cancel while native/provider IO is live).
        officeAiControl?.cancel()
        officeAiControl = null
        officeAi?.let { lane ->
            val epoch = lane.boundNativeEpoch
            if (epoch > 0 && lane.stopAndJoin(epoch, OFFICE_AI_STOP_WAIT_MS) && officeAi === lane) {
                officeAi = null
            }
        }
        if (::voice.isInitialized) voice.shutdown()
        platformExtension?.close()
    }

    /** Null in pure controller fixtures, never a fabricated adapter. */
    internal fun voiceOrNull(): C03VoiceHost? =
        if (::voice.isInitialized) voice else null

    internal fun onVoiceForeground(active: Boolean) {
        voiceOrNull()?.onAppForegroundChanged(active)
    }

    internal fun onVoicePermissionResult(granted: Boolean) {
        voiceOrNull()?.onMicrophonePermissionResult(granted)
    }

    internal fun voicePermissionRequests(): kotlinx.coroutines.flow.Flow<Unit>? =
        voiceOrNull()?.permissionRequests

    internal suspend fun prepareVoiceForRootStop(): Boolean =
        voiceOrNull()?.prepareForRootStop() ?: true

    /** Re-read canonical voice settings after a root-generation replacement. */
    internal fun onVoiceRootChanged() {
        voiceOrNull()?.onRootChanged()
    }

    /**
     * Root-retirement drain clause for the flavour platform extension. The
     * Application calls this inside the existing local-runtime drain BEFORE
     * the native root is retired; false keeps the old generation pending.
     */
    internal suspend fun preparePlatformForRootStop(): Boolean =
        platformExtension?.prepareForRootStop() ?: true

    // ------------------------------------------------- Office AI host lane

    /**
     * Bounded owned start (Main host20 doctrine, mirroring the browser
     * lane): re-validate the CURRENT accepted epoch before every attempt,
     * rebind a replaced generation only through the previous pump's real
     * drain (an unproven drain fails closed and retries), and never leave a
     * constructor-stub availability behind.
     */
    private fun startOfficeAiLane() {
        synchronized(officeAiLock) {
            if (officeAiControl?.isActive == true) return
            officeAiControl = scope.launch(ioDispatcher) {
                val lane = officeAi ?: createOfficeAiPump() ?: return@launch
                officeAi = lane
                for (attempt in 0 until OFFICE_AI_START_ATTEMPTS) {
                    val epoch = nativeRootEpoch()
                    if (epoch != null && epoch > 0) {
                        val previous = lane.boundNativeEpoch
                        if (previous > 0 && previous != epoch) {
                            if (!lane.stopAndJoin(previous, OFFICE_AI_STOP_WAIT_MS)) return@launch
                        }
                        if (lane.start(epoch)) return@launch
                    }
                    delay(OFFICE_AI_START_BACKOFF_MILLIS * (attempt + 1))
                }
            }
        }
    }

    private fun createOfficeAiPump(): OfficeAiHostPump? {
        if (!::appContext.isInitialized) return null
        val application = appContext as? com.floe.android.FloeApplication ?: return null
        // Main-process owner only: the isolated provider/office processes
        // never duplicate this lane (their early-return bootstrap owns no
        // RuntimeHost at all; this guard mirrors the Application doctrine).
        if (android.os.Process.isIsolated()) return null
        val controller = runCatching { application.officePreviews }.getOrNull() ?: return null
        return OfficeAiHostPump(
            scope = scope,
            ioDispatcher = ioDispatcher,
            currentNativeEpoch = ::nativeRootEpoch,
            ports = AppOfficeAiDocumentPorts(this, controller),
            transport = NativeOfficeAiTransport,
            verifier = OfficeAiOoxmlVerifier,
        )
    }

    /** Root stop / retirement: bounded owned drain attempts, then leave the
     * lane honestly pending if the drain is unproven. */
    private fun stopOfficeAiLane() {
        synchronized(officeAiLock) {
            officeAiControl?.cancel()
            officeAiControl = null
            if (officeAiRetire?.isActive == true) return
            officeAiRetire = scope.launch(ioDispatcher) {
                val lane = officeAi ?: return@launch
                val epoch = lane.boundNativeEpoch
                if (epoch <= 0) {
                    if (officeAi === lane) officeAi = null
                    return@launch
                }
                for (attempt in 0 until OFFICE_AI_RETIRE_ATTEMPTS) {
                    if (lane.stopAndJoin(epoch, OFFICE_AI_STOP_WAIT_MS)) {
                        if (officeAi === lane) officeAi = null
                        return@launch
                    }
                    delay(OFFICE_AI_RETIRE_BACKOFF_MILLIS)
                }
            }
        }
    }

    private suspend fun observeCapabilities() {
        // Gateway fact.
        gatewayCapability.collect { capability ->
            val gateway = when (capability) {
                is SecretGatewayCapability.Loading ->
                    RuntimeHostReadiness.GatewayReadiness.Loading
                is SecretGatewayCapability.Ready ->
                    RuntimeHostReadiness.GatewayReadiness.Ready
                is SecretGatewayCapability.Failed ->
                    RuntimeHostReadiness.GatewayReadiness.Failed(capability.reason)
            }
            update { it.copy(gateway = gateway) }
        }
    }

    /** The bootstrap capability drives store + domain readiness truth. */
    internal fun onBootstrapCapability(value: RuntimeBootstrapCapability) {
        when (value) {
            is RuntimeBootstrapCapability.Idle ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.Idle) }
            is RuntimeBootstrapCapability.WaitingGateway ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.WaitingGateway) }
            is RuntimeBootstrapCapability.Starting ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.Starting(value.receipt)) }
            is RuntimeBootstrapCapability.OwnedStoreReady -> {
                update {
                    it.copy(
                        store = RuntimeHostReadiness.StoreReadiness.OwnedStoreReady,
                        // Configuration surfaces become usable at store
                        // readiness; never gated on a synthetic "AI ready".
                        domains = it.domains + ("providerConfigurationDomain" to available()),
                    )
                }.also { refreshConfigurationProjections() }
                // G02: republish the REAL native domain readiness (handler
                // registry + composition constructors), not source optimism.
                g02ReadinessAdapter.pollAndPublish()
                // A REAL accepted store generation re-admits the owned
                // document preview after a completed stop/rebind cycle; an
                // unproven old-generation drain never reached here.
                if (workspaceDocumentPreviewDelegate.isInitialized()) {
                    workspaceDocumentPreview.onOwnedStoreReady()
                }
                if (cadViewerDelegate.isInitialized()) {
                    cadViewer.onOwnedStoreReady()
                }
                if (c05RemoteDelegate.isInitialized()) {
                    c05Remote.onOwnedStoreReady()
                }
                if (c05RdpDelegate.isInitialized()) {
                    c05Rdp.onOwnedStoreReady()
                }
                if (appContextOrNull != null) {
                    // C05 devices: the engine/tool-pump lane follows the ACTUAL
                    // accepted epoch and must be available to configured model
                    // tools even if the Devices screen was never opened.
                    c05Devices.onOwnedStoreReady()
                    // C06: the mail lane is App-owned, so it starts on the real
                    // accepted store generation even when the Mail screen has not
                    // been opened (configured model mail tools need it). It does
                    // not open a socket until an operation is requested.
                    c06Mail.onOwnedStoreReady()
                    // C06: the calendar/todo controller owns the real provider
                    // lane and the local reminder transport. It starts on the
                    // accepted store generation even when the Calendar screen has
                    // not been opened (configured model calendar tools need it);
                    // it performs no provider query until work is requested.
                    c06Calendar.onOwnedStoreReady()
                    // C06: system services follow the ACTUAL accepted epoch so
                    // configured model tools work even when the screen was never
                    // opened. No permission prompt or platform read happens until
                    // an explicit tool or UI action; the capability push is the
                    // only startup work.
                    c06SystemServices.onOwnedStoreReady()
                }
                // C07 only reacts if the settings surface already created
                // the controller; no backup/restore work starts implicitly.
                if (appContextOrNull != null) fontTools.start()
                if (c07DataExchangeDelegate.isInitialized()) {
                    c07DataExchange.onOwnedStoreReady()
                }
                // Office AI host lane follows the ACTUAL accepted root epoch
                // with bounded attempts (same doctrine as the browser lane).
                startOfficeAiLane()
                startNetworkDiagnosticsLane()
                startNetworkArtifactLane()
                // C01: the project list becomes readable with the accepted
                // store; refresh once on the real readiness transition.
                projects.refresh()
                // G08 Full-only platform extension follows the SAME accepted
                // generation. A null/foreign epoch is never fabricated.
                nativeRootEpoch()?.takeIf { it > 0 }?.let { epoch ->
                    platformExtension?.onOwnedStoreReady(epoch)
                }
            }
            is RuntimeBootstrapCapability.Failed ->
                update { it.copy(store = RuntimeHostReadiness.StoreReadiness.Failed(value.reason)) }
            is RuntimeBootstrapCapability.Stopped -> {
                update {
                    it.copy(
                        store = RuntimeHostReadiness.StoreReadiness.Stopped,
                        domains = it.domains.mapValues { blocked(listOf("storeStopped")) },
                    )
                }
                g02ReadinessAdapter.reset()
                if (cadViewerDelegate.isInitialized()) cadViewer.onRootStopped()
                executionTargets.release()
                taskContinuity.release()
                if (c05RemoteDelegate.isInitialized()) c05Remote.onRootStopped()
                if (c05SFTPDelegate.isInitialized()) c05Sftp.onRootStopped()
                if (c05RdpDelegate.isInitialized()) c05Rdp.onRootStopped()
                if (c05DevicesDelegate.isInitialized()) c05Devices.onRootStopped()
                if (c06MailDelegate.isInitialized()) c06Mail.onRootStopped()
                if (c06CalendarDelegate.isInitialized()) c06Calendar.onRootStopped()
                if (c06SystemServicesDelegate.isInitialized()) c06SystemServices.onRootStopped()
                if (c07DataExchangeDelegate.isInitialized()) c07DataExchange.onRootStopped()
                stopOfficeAiLane()
                // Fence the flavour extension on the real retirement. The
                // main pre-stop drain already ran prepareForRootStop(); this
                // closes the terminal state and never retires a newer epoch.
                if (nativeRootEpoch() == null) platformExtension?.onRootStopped()
                scope.launch(ioDispatcher) {
                    // Post-stop cleanup only for a genuinely retired root. A
                    // live non-null epoch means a NEW generation has already
                    // been accepted: the main pre-stop drain cleaned the old
                    // generation, and this late callback must neither retire
                    // the new root's monitor session nor arm/block its epoch.
                    if (nativeRootEpoch() != null) return@launch
                    // A cleared gate that was armed before means a newer
                    // generation was already admitted; never drain it from
                    // this stale callback. A never-armed gate (no main drain)
                    // is closed now so the retired window cannot admit work.
                    if (networkMonitorLaunchAdmission.wasEverArmed() &&
                        !networkMonitorLaunchAdmission.isArmed()
                    ) {
                        return@launch
                    }
                    armNetworkMonitorLaunchRetirementAt(null)
                    drainNetworkForRootStop()
                }
            }
        }
    }

    /**
     * Domain availability is reported by the REAL native handler registry
     * (status readback), never assumed. The bootstrap coordinator's typed
     * admission carries the authoritative missing-bindings list; as the
     * owning packages land, the Swift side flips domains to registered and
     * the App host records truthful availability for the CURRENT generation.
     */
    internal fun onDomainAvailability(domain: String, available: Boolean, missing: List<String>) {
        update {
            it.copy(
                domains = it.domains + (
                    domain to if (available) {
                        RuntimeHostReadiness.DomainReadiness.Available(commandClient.generation())
                    } else {
                        RuntimeHostReadiness.DomainReadiness.Blocked(missing)
                    }
                    ),
            )
        }
        // Settings summaries are owned by their OWN settings domain, not by
        // provider-configuration readiness. A domain that only becomes
        // available AFTER the one-shot settings.start() must still load its
        // surface; this transition is the late-admission owner. The adapter
        // publishes CHANGED states only, so this is not a poll loop.
        if (available) settings.onSettingsDomainAvailable(domain)
        refreshConfigurationProjections()
    }

    /**
     * One-shot re-read of the narrow native domain-readiness snapshot.
     *
     * Used by a user-visible Settings page open to recover when the initial
     * `OwnedStoreReady` snapshot could not be published (JNI/readback race):
     * the adapter's normal trigger is the bootstrap capability transition, so
     * a first poll that returned null/unknown would otherwise leave every
     * settings surface unadmitted for the rest of the process. This performs
     * exactly one bounded readback and publishes real transitions only; it is
     * never a timer/poll loop. Must run off the main thread.
     */
    internal suspend fun refreshDomainReadiness() {
        g02ReadinessAdapter.pollAndPublish()
    }

    /**
     * The controllers' start() ran before the store was ready and gated out;
     * when configuration admission first becomes true the REAL projections
     * must be read once or the composer/launchpad never sees a model (F1
     * cold-start gap). Exactly-once per admission epoch — the reads are
     * idempotent, and repeating them on every domain flip would only add
     * noise to unrelated surfaces.
     */
    private fun refreshConfigurationProjections() {
        if (!readiness.value.providerConfigurationAdmitted) return
        if (!configProjectionRefreshed.compareAndSet(false, true)) return
        providers.refreshProviders()
        settings.refreshPreferences()
        conversations.refreshModels()
    }

    private fun available() = RuntimeHostReadiness.DomainReadiness.Available(
        commandClient.generation())

    private fun blocked(missing: List<String>) =
        RuntimeHostReadiness.DomainReadiness.Blocked(missing)

    private inline fun update(transform: (RuntimeHostReadiness) -> RuntimeHostReadiness) {
        readinessState.value = transform(readinessState.value)
    }

    // ---------------------------------------------------- host affordances

    /** Application context, set once by the owner at creation. */
    lateinit var appContext: android.content.Context
        internal set

    /**
     * Null until the Application owner binds [appContext]. Pure controller
     * fixtures and component hosts have no platform surface, so every
     * optional platform affordance (share sheet, notification reminder) must
     * no-op instead of dereferencing an unbound context from a background
     * effect callback.
     */
    internal val appContextOrNull: android.content.Context?
        get() = if (::appContext.isInitialized) appContext else null

    /** Share text through the platform share sheet (off the UI thread). */
    internal fun shareText(text: String, mimeType: String): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                type = mimeType
                putExtra(android.content.Intent.EXTRA_TEXT, text)
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }

    /** Open a public-web URL in the browser (temporary-ceiling-safe). */
    internal fun openWebUrl(url: String): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val intent = android.content.Intent(
                android.content.Intent.ACTION_VIEW,
                android.net.Uri.parse(url),
            ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            true
        } catch (t: Throwable) {
            false
        }
    }

    /** Copy text to the clipboard. */
    internal fun copyToClipboard(text: String): Boolean {
        if (!::appContext.isInitialized) return false
        return try {
            val manager = appContext.getSystemService(
                android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            manager.setPrimaryClip(
                android.content.ClipData.newPlainText("floe", text))
            true
        } catch (t: Throwable) {
            false
        }
    }

    // ------------------------------------------------------------ operations

    /** One independently owned reader per logical page request. Provider,
     * role and conversation reads must never supersede one another. */
    internal fun readModelPage(
        providerID: String?,
        cursor: String?,
        correlationTag: String = "mlist",
        isCurrent: () -> Boolean = { true },
        onOutcome: (HostOperationOutcome) -> Unit,
    ) {
        ModelPageReadController(this).readPage(
            providerID, cursor, correlationTag, isCurrent, onOutcome)
    }


    /**
     * Submit + track one canonical operation to its terminal. [onTerminal]
     * is invoked exactly once with the typed outcome; the correlation is
     * closed on every path. Failures are typed — never secrets, raw paths
     * or exception text.
     *
     * [onAccepted] (optional, default null = no behavior change for existing
     * callers) fires exactly once with the REAL mailbox-issued
     * `operationReceiptID` the moment the queue admits the envelope — before
     * the effect stream opens. Long-running cancellable operations
     * (personalization generate, memory organize) retain this receipt so an
     * explicit user cancel can address the actual active operation by
     * reusing the original correlation; a UI dismissal or request id is
     * never presented as a domain receipt. Terminal-once delivery and
     * effect ownership are unchanged.
     */
    internal fun trackOperation(
        request: HostCommandRequest,
        onFrame: (HostEffectFrame) -> Unit = { },
        onAccepted: ((String) -> Unit)? = null,
        onTerminal: (HostOperationOutcome) -> Unit,
    ) {
        scope.launch(ioDispatcher) {
            when (val submitted = commandClient.submit(request)) {
                is HostSubmitResult.Accepted -> {
                    onAccepted?.invoke(submitted.operationReceiptID)
                    commandClient.openEffectStream(
                        operationReceiptID = submitted.operationReceiptID,
                        configurationScope = request.configurationScope ?: "system",
                        onFrame = onFrame,
                        onTerminal = { terminal ->
                            logRunFailureMetadata(request, terminal)
                            commandClient.closeCorrelation(request.correlationID)
                            onTerminal(terminal.toOperationOutcome())
                        },
                        onFailure = { failure ->
                            logRunPumpFailureMetadata(request, failure)
                            commandClient.closeCorrelation(request.correlationID)
                            onTerminal(failure.toOperationOutcome())
                        },
                    )
                }
                is HostSubmitResult.Rejected -> {
                    logRunSubmitRefusal(request, submitted.reason)
                    onTerminal(HostOperationOutcome.Rejected(submitted.reason, submitted.reason))
                }
                HostSubmitResult.Superseded -> onTerminal(HostOperationOutcome.Superseded)
            }
        }
    }

    // ---------------------------------------------------- run.start diagnostics

    /**
     * DEBUG-only redacted refusal metadata for `run.start`. The generic UI
     * only shows the outer typed code; the REAL root-cause lives in the
     * effect detail (wire/code/reason/binding/phase/expected/actual) which
     * [HostEffectTerminal.toOperationOutcome] intentionally does not carry
     * into ordinary UI. This fixed-tag line is the safe diagnostic channel:
     * whitelisted structural keys only, credential-pattern redaction, bounded
     * strings, never the request/payload/headers/key. No-op in release.
     */
    private fun logRunFailureMetadata(request: HostCommandRequest, terminal: HostEffectTerminal) {
        if (request.command != "run.start" && request.command != "run.startTask") return
        if (!com.floe.android.BuildConfig.DEBUG) return
        val code: String
        val reason: String
        val detail: Map<String, String>
        when (terminal) {
            is HostEffectTerminal.Rejected -> {
                code = terminal.code
                reason = terminal.reason
                detail = terminal.detail
            }
            is HostEffectTerminal.Failed -> {
                code = terminal.code
                reason = terminal.reason
                detail = terminal.detail
            }
            else -> return
        }
        emitRunFailureLine(code, reason, detail)
    }

    private fun logRunPumpFailureMetadata(request: HostCommandRequest, failure: HostPumpFailure) {
        if (request.command != "run.start" && request.command != "run.startTask") return
        if (!com.floe.android.BuildConfig.DEBUG) return
        when (failure) {
            is HostPumpFailure.Recoverable ->
                emitRunFailureLine(failure.code, failure.reason, emptyMap())
            HostPumpFailure.Superseded ->
                emitRunFailureLine("superseded", "superseded", emptyMap())
        }
    }

    private fun logRunSubmitRefusal(request: HostCommandRequest, reason: String) {
        if (request.command != "run.start" && request.command != "run.startTask") return
        if (!com.floe.android.BuildConfig.DEBUG) return
        emitRunFailureLine(reason, reason, emptyMap())
    }

    private fun emitRunFailureLine(
        code: String,
        reason: String,
        detail: Map<String, String>,
    ) {
        runCatching {
            android.util.Log.e("FloeRunFailure", buildString {
                append("op=run.start")
                append(" code=").append(boundedDiagnostic(code))
                append(" reason=").append(boundedDiagnostic(reason))
                for (key in RUN_FAILURE_DETAIL_KEYS) {
                    val raw = detail[key] ?: continue
                    append(' ').append(key).append('=')
                        .append(redactDiagnosticValue(raw))
                }
            })
        }
    }

    /** Bounded, credential-redacted diagnostic value (never user payload). */
    private fun redactDiagnosticValue(raw: String): String {
        val bounded = boundedDiagnostic(raw)
        return CREDENTIAL_PATTERN.replace(bounded, "[redacted]")
    }

    private fun boundedDiagnostic(raw: String): String =
        if (raw.length <= 128) raw else raw.take(128) + "…"

    companion object {
        /** Office AI lane start doctrine: bounded attempts, no idle poller
         * (same shape as the browser lane). */
        internal const val OFFICE_AI_START_ATTEMPTS = 4
        internal const val OFFICE_AI_START_BACKOFF_MILLIS = 150L
        internal const val OFFICE_AI_STOP_WAIT_MS = 8_000L
        internal const val OFFICE_AI_RETIRE_ATTEMPTS = 8
        internal const val OFFICE_AI_RETIRE_BACKOFF_MILLIS = 1_000L

        /** Bounded join for the owned document-preview renderer/snapshot
         * drain, matching the other lane stop waits. */
        internal const val WORKSPACE_PREVIEW_STOP_WAIT_MS = 8_000L

        /** Bounded join for the C04A viewer WebView/snapshot drain. */
        internal const val CAD_VIEWER_STOP_WAIT_MS = 8_000L

        /** Bounded join for the archive extract/preview-staging drain. */
        internal const val ARCHIVE_STOP_WAIT_MS = 8_000L

        /** Bounded join for the C05 SSH session/PTY/tunnel drain. */
        internal const val C05_REMOTE_STOP_WAIT_MS = 8_000L
        internal const val C05_SFTP_STOP_WAIT_MS = 8_000L

        /** Bounded join for the C05 RDP session/frame/input drain. */
        internal const val C05_RDP_STOP_WAIT_MS = 8_000L

        /** Bounded join for the C05 device sessions/tool mailbox drain. */
        internal const val C05_DEVICES_STOP_WAIT_MS = 6_000L

        /** Bounded join for the C06 platform TLS lane / mail transport drain. */
        internal const val C06_MAIL_STOP_WAIT_MS = 8_000L

        /** Bounded join for the C06 CalendarContract/reminder lane drain. */
        internal const val C06_CALENDAR_STOP_WAIT_MS = 8_000L

        /** Bounded join for the C06 system-services platform mailbox drain. */
        internal const val C06_SYSTEM_SERVICES_STOP_WAIT_MS = 6_000L

        /** Bounded join for the exact active monitoring session on root stop. */
        internal const val NETWORK_MONITOR_STOP_WAIT_MS = 5_000L

        /** Structural refusal metadata only — never echo the goal/payload. */
        private val RUN_FAILURE_DETAIL_KEYS = listOf(
            "wire", "code", "reason", "binding", "phase",
            "expected", "actual", "expectedState", "runState",
            "storePrimary", "storeExtended",
        )

        private val CREDENTIAL_PATTERN = Regex(
            "(?i)(api[_-]?key|secret|token|authorization|bearer|sk-[a-z0-9]{6,})",
        )

        /** Production factory; performs no native or disk work. */
        fun create(
            context: android.content.Context,
            gatewayCapability: StateFlow<SecretGatewayCapability>,
            bootstrapCapability: StateFlow<RuntimeBootstrapCapability>,
        ): RuntimeHost = RuntimeHost(
            commandClient = RuntimeHostCommandClient.system(),
            gatewayCapability = gatewayCapability,
            bootstrapCapability = bootstrapCapability,
        ).also {
            it.appContext = context.applicationContext ?: context
            it.voice = C03VoiceHost(
                context = it.appContext,
                scope = it.scope,
                ioDispatcher = it.ioDispatcher,
                currentEpoch = { it.nativeRootEpoch() },
            )
            // Flavour seam: FULL returns the real phone/ADB/Root extension,
            // PLAY an inert one. Construction is data-only; no backend,
            // native, disk or device work happens here.
            it.platformExtension =
                com.floe.android.host.platform.DistributionPlatformFeature.create(
                    context.applicationContext ?: context)
        }
    }
}

sealed interface HostOperationOutcome {
    /**
     * A settled completion. [value] is the typed value/page document; [detail]
     * stays the bounded identifier/reason map the native terminal carried
     * (e.g. a queue acceptance's real `inputID`/`position`). Identifier-only
     * commands legitimately have `value == null` and a populated detail.
     */
    data class Completed(
        val value: JsonElement?,
        val detail: Map<String, String> = emptyMap(),
    ) : HostOperationOutcome
    data class Rejected(val code: String, val reason: String) : HostOperationOutcome
    data class Failed(
        val code: String,
        val reason: String,
        /**
         * Bounded structural detail the native terminal carried (e.g. the
         * domain `wire` code). Diagnostic-only; ordinary UI keeps showing
         * the settlement class and uses this solely to map a typed,
         * user-actionable privacy-clear failure.
         */
        val detail: Map<String, String> = emptyMap(),
    ) : HostOperationOutcome
    data object Cancelled : HostOperationOutcome
    data object Superseded : HostOperationOutcome
}

private fun HostEffectTerminal.toOperationOutcome(): HostOperationOutcome = when (this) {
    is HostEffectTerminal.Completed -> HostOperationOutcome.Completed(value, detail)
    is HostEffectTerminal.Rejected -> HostOperationOutcome.Rejected(code, reason)
    is HostEffectTerminal.Failed -> HostOperationOutcome.Failed(code, reason, detail)
    is HostEffectTerminal.Cancelled -> HostOperationOutcome.Cancelled
    is HostEffectTerminal.Closed -> HostOperationOutcome.Completed(null, detail)
    is HostEffectTerminal.Replaced -> HostOperationOutcome.Superseded
}

private fun HostPumpFailure.toOperationOutcome(): HostOperationOutcome = when (this) {
    is HostPumpFailure.Recoverable -> HostOperationOutcome.Failed(code, reason)
    HostPumpFailure.Superseded -> HostOperationOutcome.Superseded
}
