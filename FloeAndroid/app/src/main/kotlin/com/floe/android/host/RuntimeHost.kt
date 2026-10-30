// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.SecretGatewayCapability
import com.floe.android.host.officeai.AppOfficeAiDocumentPorts
import com.floe.android.host.officeai.NativeOfficeAiTransport
import com.floe.android.host.officeai.OfficeAiHostPump
import com.floe.android.host.officeai.OfficeAiOoxmlVerifier
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
 *  * [AttachmentImportController] — picker/SAF/staging handoff ownership.
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
    /** Ordinary-task editor projections outlive Activity/inspector views. */
    internal val workspaceEditors = G04WorkspaceEditorController(this)
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
    internal var workspaceGitTrust: G04GitTrustController? = null
    internal var workspaceTerminal: G04TerminalHostController? = null

    private var observationJob: Job? = null
    private val started = java.util.concurrent.atomic.AtomicBoolean(false)
    private val configProjectionRefreshed = java.util.concurrent.atomic.AtomicBoolean(false)
    /** Application-owned foreground adapter; absent in pure controller fixtures. */
    internal var runForeground: RunForegroundBinding? = null
    /** Application-owned provider transport; null in fixtures/unbound hosts. */
    internal var workspaceSources: WorkspaceSourcePump? = null
    /** Same Application owner and native epoch as the provider transport. */
    internal var networkWorkspaceHost: NetworkWorkspaceHostController? = null
    /** One phone-native measurement service shared by workbench and Agent pump. */
    internal val networkService by lazy { com.floe.android.core.network.PhoneNetworkService(appContext) }
    internal val networkWorkbench by lazy { NetworkWorkbenchController(this) }
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
        return monitorReady && diagnosticsReady
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
    internal fun reportBackgroundUnavailable(failure: com.floe.android.runlifecycle.RunForegroundFailure) {
        if (backgroundNoticeReported.compareAndSet(false, true)) {
            backgroundAvailabilityNotice.value = if (failure is com.floe.android.runlifecycle.RunForegroundFailure.NotificationsBlocked)
                BackgroundAvailability.NOTIFICATIONS_BLOCKED else BackgroundAvailability.SYSTEM_UNAVAILABLE
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

    /** Called once by the Application owner, off-main. */
    fun start() {
        if (!started.compareAndSet(false, true)) return
        observationJob = scope.launch(ioDispatcher) { observeCapabilities() }
        providers.start()
        conversations.start()
        integrations.start()
        gitCredentials.start()
        attachments.start()
        settings.start()
        webSearch.start()
        home.start()
    }

    /**
     * Real shutdown: controllers drain their pumps first (generation bump
     * disposes matching collectors only), then the caller proceeds with the
     * RB-1 owner stop. The host never cancels another owner's work.
     */
    suspend fun stop() {
        // A real preview reader still holding a native-root snapshot must
        // close before the root retires; a refused drain keeps the old
        // generation rather than pretending the document work is gone.
        if (!prepareWorkspaceDocumentPreviewForRootStop()) return
        prepareNetworkForRootStop()
        commandClient.bumpGeneration()
        providers.stop()
        conversations.stop()
        integrations.stop()
        gitCredentials.stop()
        attachments.stop()
        settings.stop()
        webSearch.stop()
        home.stop()
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
    }

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
                // Office AI host lane follows the ACTUAL accepted root epoch
                // with bounded attempts (same doctrine as the browser lane).
                startOfficeAiLane()
                startNetworkDiagnosticsLane()
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
                stopOfficeAiLane()
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
        ).also { it.appContext = context.applicationContext ?: context }
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
