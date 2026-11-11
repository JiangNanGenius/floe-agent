// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.Activity
import android.app.KeyguardManager
import com.floe.android.phonecontrol.PhoneUnlockResult
import com.floe.android.phonecontrol.PhoneRelockResult
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import androidx.compose.runtime.snapshotFlow
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.core.app.NotificationManagerCompat
import com.floe.android.DeviceAccessAccessibilityUi
import com.floe.android.DeviceAccessActiveTaskUi
import com.floe.android.DeviceAccessAdbUi
import com.floe.android.DeviceAccessBusyUi
import com.floe.android.DeviceAccessCallbacks
import com.floe.android.DeviceAccessErrorSectionUi
import com.floe.android.DeviceAccessFileRootUi
import com.floe.android.DeviceAccessFileRootKindUi
import com.floe.android.DeviceAccessLookupUiState
import com.floe.android.DeviceAccessPackageUi
import com.floe.android.DeviceAccessPermissionOpsInspector
import com.floe.android.DeviceAccessPermissionOpsResult
import com.floe.android.DeviceAccessPairingDiscoveryUi
import com.floe.android.DeviceAccessPresentationState
import com.floe.android.DeviceAccessPresentation
import com.floe.android.DeviceAccessRootUi
import com.floe.android.DeviceAccessScreenScopeUi
import com.floe.android.DeviceAccessTargetsUi
import com.floe.android.DeviceAccessTaskControlUi
import com.floe.android.DeviceAccessTaskPhaseUi
import com.floe.android.DeviceAccessUiError
import com.floe.android.R
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.host.RuntimeHost
import com.floe.android.host.HostCommandRequest
import com.floe.android.host.HostOperationOutcome
import com.floe.android.host.HostScope
import com.floe.android.host.questions.UserQuestionWire
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import com.floe.android.host.settings.DistributionSettingsFeature
import com.floe.android.phonecontrol.PhoneControlAction
import com.floe.android.phonecontrol.PhoneControlAuthority
import com.floe.android.phonecontrol.PhoneControlBlocker
import com.floe.android.phonecontrol.PhoneControlClient
import com.floe.android.phonecontrol.PhoneControlDenial
import com.floe.android.phonecontrol.PhoneControlGrant
import com.floe.android.phonecontrol.PhoneControlModule
import com.floe.android.phonecontrol.PhoneControlObservation
import com.floe.android.phonecontrol.PhoneControlObserveRequest
import com.floe.android.phonecontrol.PhoneControlOwner
import com.floe.android.phonecontrol.PhoneControlPrincipal
import com.floe.android.phonecontrol.PhoneControlResult
import com.floe.android.phonecontrol.PhoneControlScreenshotRequest
import com.floe.android.phonecontrol.PhoneControlStatus
import com.floe.android.phonecontrol.PhoneControlUnavailable
import com.floe.android.rootsystem.AccessActionResult
import com.floe.android.rootsystem.AdbStatus
import com.floe.android.rootsystem.AuthorityDecision
import com.floe.android.rootsystem.FileEntry
import com.floe.android.rootsystem.FileRead
import com.floe.android.rootsystem.GrantRequest
import com.floe.android.rootsystem.NetworkDiagnostics
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.PackageQuery
import com.floe.android.rootsystem.PairingResult
import com.floe.android.rootsystem.RootOperationRequest
import com.floe.android.rootsystem.RootResult
import com.floe.android.rootsystem.RootStatus
import com.floe.android.rootsystem.RootSystemAuthority
import com.floe.android.rootsystem.RootSystemConfig
import com.floe.android.rootsystem.RootSystemController
import com.floe.android.rootsystem.RootSystemModule
import com.floe.android.rootsystem.ScopeRoot
import com.floe.android.rootsystem.SettingItemReceipt
import com.floe.android.rootsystem.SettingsChange
import com.floe.android.rootsystem.SettingsChangeAction
import com.floe.android.rootsystem.StagedApk
import com.floe.android.rootsystem.SystemOperation
import com.floe.android.rootsystem.ipc.BinderProtocol
import com.floe.android.rootsystem.policy.FloePackageFamily
import com.floe.android.rootsystem.policy.SettingsKeyPolicy
import java.nio.charset.CodingErrorAction
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull

/**
 * FULL-channel, Application-owned device-access controller.
 *
 * It is the ONLY App owner of the phone-control client, the embedded ADB/root
 * controller and the trusted platform-tool pump. Views and the settings sheet
 * merely collect [presentation] and invoke user callbacks; navigation,
 * rotation, background or a closed sheet never stop the backends.
 *
 * Authority model:
 *  - the REAL canonical ToolContext ticket (task/run/epoch/call/approval) is
 *    the only source of operation identity;
 *  - user Settings are capability CEILINGS (selected target apps, shared file
 *    roots, screen scope, capture consent, package management);
 *  - phone control is armed by a visible user gesture or explicit saved automation
 *    consent, always tied to the actual canonical task/run claim;
 *  - a user Stop/Takeover/disable fences queued platform work, cancels the real
 *    in-flight backend operation and sends run cancel through the existing
 *    conversation authority. Saved automation consent never clears a user stop.
 */
internal class DeviceAccessHost(
    private val context: Context,
    private val host: RuntimeHost,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
) {
    private data class AccessSettings(
        val allowedPackages: Set<String> = emptySet(),
        val fileRootIds: Set<String> = emptySet(),
        /** Explicit other-app data folders; used only while Root is live. */
        val appDataPaths: Set<String> = emptySet(),
        val fileWritesAllowed: Boolean = false,
        val wholeScreenConsent: Boolean = false,
        val packageManagementAllowed: Boolean = false,
        /**
         * The ONE shared advanced-system master. This packet implements the
         * three app-state tools under it; later permission/AppOps/settings
         * packets reuse the same master, allowed-tools set and targets.
         */
        val advancedSystemManagementAllowed: Boolean = false,
        /** Exact ABI tool names the user allowed (only shipped ones stored). */
        val advancedSystemAllowedTools: Set<String> = emptySet(),
        /** User-selected installed-app targets for the advanced group. */
        val advancedSystemTargets: Set<String> = emptySet(),
        val adbEnabled: Boolean = false,
        val automaticPhoneControl: Boolean = false,
        val autoUnlock: Boolean = false,
        val floatingControls: Boolean = false,
    )

    private data class TaskCandidate(
        val owner: PhoneControlOwner,
        val title: String,
        val phase: DeviceAccessTaskPhaseUi,
    )

    private class PhoneCallBinding(
        val call: PlatformToolCall,
        val owner: PhoneControlOwner,
    )

    private class ActiveRootGrant(
        val platformClaim: Long,
        val taskId: String,
        val runId: String,
        val epoch: Long,
        val operations: Set<SystemOperation>,
        val packageManagementAllowed: Boolean,
        val expectedTarget: String?,
        val expiresAtMillis: Long,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
        @Volatile var operationClaim: OperationClaim? = null,
    ) {
        fun matches(claim: OperationClaim): Boolean =
            claim.taskId == taskId && claim.runId == runId && claim.epoch == epoch

        fun ticketLive(): Boolean =
            !cancelled.get() &&
                System.currentTimeMillis() < expiresAtMillis &&
                PlatformToolsNativeLive.isLive(platformClaim)

        fun ticketCancelled(): Boolean =
            cancelled.get() ||
                System.currentTimeMillis() >= expiresAtMillis ||
                PlatformToolsNativeLive.shouldStop(platformClaim)
    }

    /** Tiny indirection so JVM-only code never touches the native library. */
    private object PlatformToolsNativeLive {
        fun isLive(claim: Long): Boolean = try {
            com.floe.android.swiftbridge.PlatformToolsNative.isLive(claim) == 1
        } catch (_: Throwable) {
            false
        }

        fun shouldStop(claim: Long): Boolean = try {
            com.floe.android.swiftbridge.PlatformToolsNative.shouldStop(claim) == 1
        } catch (_: Throwable) {
            true
        }
    }

    private val preferences = context.getSharedPreferences(
        "floe_device_access_v1", Context.MODE_PRIVATE)
    private val mutablePresentation = MutableStateFlow(DeviceAccessPresentationState())
    val presentation: StateFlow<DeviceAccessPresentationState> = mutablePresentation.asStateFlow()

    /** Live stored values for the closed system-settings sheet (user action). */
    private val mutableSystemSettingsUi =
        MutableStateFlow(com.floe.android.DeviceAccessSystemSettingsUiState())
    val systemSettingsUi: StateFlow<com.floe.android.DeviceAccessSystemSettingsUiState> =
        mutableSystemSettingsUi.asStateFlow()

    @Volatile
    private var systemSettingsSnapshot: Map<String, String?> = emptyMap()
    private val systemSettingsWriteInFlight = AtomicBoolean(false)

    private val activation = PhoneControlModule.activation(context)
    private var phoneClient: PhoneControlClient? = null
    private var rootController: RootSystemController? = null
    private var rootCredentials: com.floe.android.contracts.CredentialStore? = null

    @Volatile
    private var settings = AccessSettings()
    private val automationMutex = Mutex()
    private val unlockCredentials = AndroidKeystoreCredentialStore(context, "phone-unlock")
    private val pauseSaved = preferences.getString(KEY_PHONE_PAUSE, null)
    private val phonePause = PhoneAutomationPause(PhoneAutomationPause.Snapshot.decode(pauseSaved))
    private val phoneControlRevision = java.util.concurrent.atomic.AtomicLong()
    @Volatile private var explicitResumeOwner: PhoneControlOwner? = null
    @Volatile private var pauseStateInvalid = pauseSaved != null && phonePause.snapshot == null
    private val automationControls = PhoneAutomationControls(context, ::onAutomationControl)
    private val automatedOwner = java.util.concurrent.atomic.AtomicReference<PhoneControlOwner?>(null)
    private var unlockConfigured = false
    @Volatile
    private var phoneStatus: PhoneControlStatus = PhoneControlModule.statusSnapshot()
    @Volatile
    private var adbStatus: AdbStatus? = null
    @Volatile
    private var rootStatus: RootStatus? = null

    /** Root service (not an ADB shell binder) is the live system owner. */
    private var rootTierWasUsable = false

    @Volatile
    private var rootRebuilding = false

    @Volatile
    private var rootConfigDirty = false

    /** The exact list handed to the live controller's RootSystemConfig. */
    @Volatile
    private var currentScopeBases: List<String> = emptyList()

    private var busy: DeviceAccessBusyUi = DeviceAccessBusyUi.NONE
    private var error: DeviceAccessUiError? = null
    private var installedPackages: List<DeviceAccessPackageUi> = emptyList()

    /** Pre-window launcher rows the ordinary chooser could not show; when
     *  larger than [installedPackages].size the sheet must say so. */
    @Volatile
    private var installedCatalogTotal = 0

    /**
     * Eligible targets for the advanced app-state chooser: the privileged
     * current-user query (including disabled and uninstalled-for-user
     * system-image packages) when the service is alive, otherwise the
     * ordinary installed-app list. Persisted selections are always merged so
     * disabling or removing an app never silently drops its identity.
     */
    @Volatile
    private var advancedSystemPackages: List<DeviceAccessPackageUi> = emptyList()

    /** Last privileged page before windowing/extras merge; the base the
     *  exact-lookup path re-merges so it never loses hidden rows. */
    @Volatile
    private var advancedDiscovered: List<DeviceAccessPackageUi> = emptyList()

    /** Merged advanced rows before the [MAX_LISTED_PACKAGES] window. */
    @Volatile
    private var advancedCatalogListed = 0

    /** True when the merged catalog exceeds the window; the sheet then shows
     *  the honest "not all listed" note instead of a silent drop. */
    @Volatile
    private var advancedCatalogWindowed = false

    /** The service page itself hit its 500-row bound; even more packages
     *  exist than [advancedCatalogListed]. */
    @Volatile
    private var advancedCatalogServiceTruncated = false

    /** USER-requested exact-name rows, verified by the service; RAM-only. */
    private val advancedLookupExtras = ConcurrentHashMap<String, DeviceAccessPackageUi>()

    @Volatile
    private var advancedLookupState = DeviceAccessLookupUiState.IDLE

    @Volatile
    private var advancedLookupQuery = ""

    @Volatile
    private var advancedLookupBusy = false

    @Volatile private var catalogLoading = false
    @Volatile private var advancedCatalogReadFailed = false
    private var advancedLookupJob: Job? = null

    /** App-local staged-APK store; listing it needs no privilege. */
    private val apkStaging = ApkStagingStore(context)

    @Volatile
    private var stagedApks: List<StagedApk> = emptyList()

    @Volatile
    private var cachedRoots: List<FileRootCatalog.Root> = emptyList()

    @Volatile
    private var armedOwner: PhoneControlOwner? = null

    @Volatile
    private var armingOwner: PhoneControlOwner? = null

    @Volatile
    private var userStopped = false

    @Volatile
    private var lastStoppedOwner: PhoneControlOwner? = null

    /**
     * True once a post-stop observation proved the exact stopped run is no
     * longer live (its cancellation settled). A later live run with the same
     * owner is then an explicit Continue/retry incarnation, not the original
     * stop still settling, and may receive a fresh user grant.
     */
    @Volatile
    private var stoppedOwnerSettled = false

    @Volatile
    private var recentOwner: PhoneControlOwner? = null

    @Volatile
    private var recentTitle: String? = null

    /**
     * RAM-only screen-share consent. "This task" is bound to the exact live
     * task/run owner and native epoch the user selected; it is never stored in
     * [preferences] and never follows another task or a restarted process.
     * "Until stopped" is the distinct broader session mode. See
     * [ScreenScopeConsent].
     */
    private val screenShare = ScreenScopeConsent()

    /**
     * RAM revision of the separate whole-screen consent. It does not replace
     * that persistent user ceiling; it lets a pending display capture prove
     * the exact consent it started under was not revoked and re-granted.
     */
    @Volatile
    private var wholeScreenConsentRevision = 0L

    @Volatile
    private var pairingSessionOpen = false
    private var pairingPortInput = ""
    @Volatile
    private var discoveredPairingPort: Int? = null
    @Volatile
    private var pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
    private var pairingJob: Job? = null

    /**
     * RAM-only notification session: unpredictable nonce/epoch, monotonic
     * generation and a consumed-on-submit token. It is never persisted and is
     * closed on cancel/close/success/forget/root-stop.
     */
    private val pairingNotification = PairingNotificationSession()

    /**
     * The active notification-reply broadcast handoff. The manifest receiver
     * holds goAsync until this callback runs; every completion/failure/cancel
     * path below invokes it exactly once.
     */
    private var pairingReplyCompletion: (() -> Unit)? = null

    /** RAM-only code while the API 37 local-network permission flow is pending. */
    @Volatile
    private var pendingPairingCode: CharArray? = null

    @Volatile
    private var usbBootstrapExported = false

    private val phoneBindings = ConcurrentHashMap<String, PhoneCallBinding>()
    private val rootGrants = ConcurrentHashMap<String, ActiveRootGrant>()

    private var pump: PlatformToolHostPump? = null
    private val statusJobs = ArrayList<Job>()
    private var started = false
    @Volatile
    private var closed = false

    /** Coalesced, generation-fenced catalog refresh: install/remove bursts and
     *  sheet-entry refreshes cancel the previous in-flight refresh so a late
     *  reply can never overwrite a newer catalog. */
    private val catalogRefreshLock = Any()
    private var catalogRefreshJob: Job? = null

    @Volatile
    private var catalogRefreshGeneration = 0L

    /** Event-driven catalog refresh: real install/remove/replace broadcasts
     *  only, never a liveness poller. RAM-only receiver, no manifest entry. */
    private val packageChangeMonitor = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (closed) return
            if (intent.action == Intent.ACTION_PACKAGE_REMOVED) {
                intent.data?.schemeSpecificPart?.let(advancedLookupExtras::remove)
            }
            scheduleCatalogRefresh()
        }
    }

    val callbacks: DeviceAccessCallbacks = DeviceAccessCallbacks(
        onOpenAccessibilitySettings = ::openAccessibilitySettings,
        onRefresh = ::refreshFromUser,
        onTargetsRefresh = ::scheduleCatalogRefresh,
        onAdvancedTargetLookup = ::lookupAdvancedSystemTarget,
        onArmPhoneControl = ::armVisibleTask,
        onAutomaticControlChange = { enabled ->
            settings = settings.copy(automaticPhoneControl = enabled)
            persist()
            if (!enabled) stopActiveTask(takeOver = true)
            publish()
        },
        onAutoUnlockChange = { enabled ->
            settings = settings.copy(autoUnlock = enabled && unlockConfigured)
            persist(); publish()
        },
        onSaveUnlockCredential = ::saveUnlockCredential,
        onForgetUnlockCredential = ::forgetUnlockCredential,
        onFloatingControlsChange = ::setFloatingControls,
        onStopActiveTask = { stopActiveTask(takeOver = false) },
        onTakeOverActiveTask = { stopActiveTask(takeOver = true) },
        onAllowedPackagesChange = ::setAllowedPackages,
        onFileRootsChange = ::setFileRoots,
        onAddAppDataRoot = ::addAppDataRoot,
        onFileWritesChange = ::setFileWrites,
        onWholeScreenConsentChange = ::setWholeScreenConsent,
        onPackageManagementChange = ::setPackageManagement,
        onAdvancedSystemChange = ::setAdvancedSystem,
        onAdvancedSystemToolsChange = ::setAdvancedSystemTools,
        onAdvancedSystemTargetsChange = ::setAdvancedSystemTargets,
        onScreenScopeChange = ::setScreenScope,
        onEnableAdb = ::enableAdb,
        onPairAdb = ::openPairing,
        onSubmitPairingCode = ::submitPairingCode,
        onPairingPortChange = ::setPairingPortInput,
        onDiscoverPairingPort = ::discoverPairingPort,
        onExportUsbBootstrap = ::exportUsbBootstrap,
        onCancelPairing = ::cancelPairing,
        onStartAdbService = ::startAdbService,
        onStopAdbService = ::stopAdbService,
        onForgetAdbPairing = ::forgetPairing,
        onOpenDeveloperOptions = ::openDeveloperOptions,
        onCheckRootGrant = ::checkRootGrant,
        onEnableRoot = ::setRootEnabled,
        onStageApks = ::stageApks,
        onRemoveStagedApk = ::removeStagedApk,
        onRevokeSystemGrants = ::revokeSystemGrants,
        onSystemSettingsRefresh = {
            mutableSystemSettingsUi.value = com.floe.android.DeviceAccessSystemSettingsUiState(
                enabled = systemSettingsCeilingEnabled(), busy = true,
            )
            publish()
            scope.launch(io) { refreshSystemSettings() }
        },
        onSystemSettingsApply = ::applySystemSettingChanges,
        onSystemSettingsRestore = ::restoreSystemSetting,
    )

    // ------------------------------------------------------------- lifecycle

    fun start() {
        if (started || closed) return
        started = true
        PairingNotificationRelay.attach(this)
        // A notification from a previous process is stale: pairing state is
        // RAM-only and never restored across process death.
        pairingNotification.close()
        cancelPairingNotification()
        settings = loadSettings()
        scope.launch(io) {
            unlockConfigured = runCatching { unlockCredentials.read("device-lock")?.let {
                it.fill(0); true
            } ?: false }.getOrDefault(false)
            publish()
        }
        refreshRootCatalog()
        // Root is default-off after every process start. Previously selected
        // other-app data folders are NOT silently active again; they require
        // an explicit re-add while the Root tier is actually live.
        if (!appDataUsable()) pruneAppDataRoots(rebuild = false)
        refreshStagedApks()
        phoneStatus = runCatching { PhoneControlModule.statusSnapshot() }
            .getOrDefault(phoneStatus)
        phoneClient = runCatching {
            PhoneControlModule.client(context, PhoneControlAuthority(::authorizePhone))
        }.getOrNull()
        ensureRootController()
        registerPackageChangeMonitor()
        statusJobs += scope.launch {
            PhoneControlModule.status.collect { status ->
                val tornDownBefore = phoneServiceTornDown(phoneStatus)
                val previousRelock = phoneStatus.relockReceipt
                phoneStatus = status
                if (status.relockReceipt != previousRelock &&
                    status.relockReceipt?.result == PhoneRelockResult.USER_REQUIRED) {
                    error = DeviceAccessUiError(context.getString(R.string.phone_automation_relock_failed),
                        "phone_relock_unconfirmed")
                }
                // Actual Accessibility/driver teardown revokes the RAM-only
                // screen consent. A user Stop/Takeover is cleared by its own
                // action; the transient blockers emitted while explicitly
                // arming the next task must not discard its fresh choice.
                if (!tornDownBefore && phoneServiceTornDown(status)) {
                    screenShare.clear()
                }
                publish()
            }
        }
        // The module-level flows survive a controller rebuild; a per-controller
        // collector would be cancelled by the next config rebuild.
        statusJobs += scope.launch {
            combine(RootSystemModule.adbStatus, RootSystemModule.rootStatus) { adb, root ->
                adb to root
            }.collectLatest { (adb, root) ->
                adbStatus = adb
                rootStatus = root
                onRootStateChanged()
                // These are ordinary volatile fields, not Compose state.
                // Observe the actual service flows, including peer changes
                // while overall availability remains true.
                withContext(io) {
                    refreshAppOpsUidScopeSupport()
                    refreshAdvancedSystemPackages()
                }
                if (!closed) publish()
            }
        }
        // The settings page collects a StateFlow; no host event fires merely
        // because a run started or ended while the sheet was closed. Observe
        // the EXISTING history projection (live-run ids only) so the Active
        // phone task card tracks real run liveness without polling and
        // without a second owner registry. publish() only reads state.
        statusJobs += scope.launch(Dispatchers.Main.immediate) {
            snapshotFlow {
                host.conversations.historyHolder.state.value?.runningConversationIds.orEmpty()
            }
                .distinctUntilChanged()
                .collect { if (!closed) publish() }
        }
        statusJobs += scope.launch(io) {
            refreshPackages()
            refreshControllerStatus()
            publish()
        }
        attachSettingsPresentation()
        publish()
    }

    fun onOwnedStoreReady(epoch: Long) {
        if (closed || epoch <= 0) return
        // A later accepted generation re-creates the App-owned backends that a
        // previous root retirement closed; pairing trust and user ceilings are
        // process-independent, the live binder/grant/call state is not.
        if (phoneClient == null) {
            phoneClient = runCatching {
                PhoneControlModule.client(context, PhoneControlAuthority(::authorizePhone))
            }.getOrNull()
        }
        ensureRootController()
        val current = pump ?: PlatformToolHostPump(
            scope = scope,
            ioDispatcher = io,
            currentEpoch = { host.nativeRootEpoch() },
            handler = ::executeTool,
            availability = ::availableToolNames,
            onCancelBackend = ::cancelBackend,
            autoAdmission = ::autoAdmissionJson,
        ).also { pump = it }
        scope.launch(io) {
            if (!current.start(epoch)) {
                // A refused bind is honest: no platform tool is advertised.
                // The next accepted root generation retries through the same
                // start contract; there is no fake available state.
                publish()
            } else {
                publish()
            }
        }
    }

    suspend fun prepareForRootStop(): Boolean {
        closePairingSession()
        val drained = pump?.stopAndJoin() ?: true
        if (!drained) return false
        closeBackends()
        return true
    }

    fun onRootStopped() {
        closePairingSession()
        pump?.forceClose()
        closeBackends()
        pruneAppDataRoots(rebuild = false)
        rootTierWasUsable = false
        armedOwner = null
        recentOwner = null
        recentTitle = null
        userStopped = false
        lastStoppedOwner = null
        stoppedOwnerSettled = false
        screenShare.clear()
        publish()
    }

    fun onActivityResumed(activity: Activity) {
        if (closed) return
        // The permission broker belongs to the main/platform lane. Read its
        // CURRENT state on the main thread; never touch it from the IO worker.
        val discoveryBlocked = pairingSessionOpen && localNetworkBlocked()
        scope.launch(io) {
            refreshRootCatalog()
            refreshControllerStatus()
            if (pairingSessionOpen && discoveredPairingPort == null && !discoveryBlocked) {
                discoverPairingPortInternal()
            }
            // Newly installed editors must appear when returning to Floe.
            refreshPackages()
            publish()
        }
    }

    fun onActivityPaused() = Unit

    fun onRunActivityChanged() {
        if (!closed) publish()
    }

    /**
     * Explicit presentation entry: the stateless settings page was composed.
     * The presentation is a one-shot StateFlow projection, and a run can have
     * started after the last publish, so recompute it now. This only reads
     * live task/arm state; it never arms or resumes anything.
     */
    fun onPresentationVisible() {
        if (closed) return
        publish()
    }

    fun close() {
        if (closed) return
        closed = true
        automatedOwner.getAndSet(null)?.let { phoneClient?.finishAutomation(it) }
        automationControls.clear()
        closePairingSession()
        PairingNotificationRelay.detach(this)
        catalogRefreshJob?.cancel()
        advancedLookupJob?.cancel()
        runCatching { context.unregisterReceiver(packageChangeMonitor) }
        statusJobs.forEach { it.cancel() }
        statusJobs.clear()
        pump?.forceClose()
        pump = null
        closeBackends()
        DistributionSettingsFeature.attach(null)
    }

    private fun closeBackends() {
        runCatching { rootController?.close() }
        rootController = null
        rootCredentials = null
        currentScopeBases = emptyList()
        runCatching { phoneClient?.close() }
        phoneClient = null
        rootGrants.clear()
        phoneBindings.clear()
        // The phone/root session owning the screen ceiling is gone; RAM-only
        // screen consent must not outlive the service it was granted to.
        screenShare.clear()
    }

    private fun attachSettingsPresentation() {
        Handler(Looper.getMainLooper()).post {
            if (!closed) DistributionSettingsFeature.attach { DeviceAccessSettingsRoute(this) }
        }
    }

    // ------------------------------------------------------------- settings IO

    /**
     * The stable App/runtime family the phone backend independently refuses.
     * The picker, new selections and previously persisted selections must all
     * agree with that boundary; an old stored self target is pruned here while
     * every unrelated user-authorized target is preserved.
     */
    private val floeProtectedPackages: Set<String> by lazy {
        FloePackageFamily.protectedPackages(setOf(context.packageName))
    }

    private fun isFloeSelfPackage(packageName: String?): Boolean =
        packageName != null && FloePackageFamily.isWithinRoots(packageName, floeProtectedPackages)

    private fun loadSettings(): AccessSettings {
        // Screen sharing is an ephemeral task consent (RAM-only). A value
        // stored by an older build is discarded, never restored: process
        // reconstruction must not re-grant another task's screen access.
        if (preferences.contains(KEY_SCREEN_SCOPE)) {
            preferences.edit().remove(KEY_SCREEN_SCOPE).apply()
        }
        val storedPackages = preferences.getStringSet(KEY_PACKAGES, emptySet()).orEmpty().toSet()
        val packages = storedPackages.filterNot { isFloeSelfPackage(it) }.toSet()
        if (packages != storedPackages) {
            // Prune only the forbidden self targets from the persisted ceiling.
            preferences.edit().putStringSet(KEY_PACKAGES, HashSet(packages)).apply()
        }
        val roots = preferences.getStringSet(KEY_ROOTS, emptySet()).orEmpty().toSet()
        val appData = preferences.getStringSet(KEY_APP_DATA_ROOTS, emptySet()).orEmpty()
            .mapNotNull {
                FileRootCatalog.normalizeAppDataBase(it, context.packageName, currentUserId())
            }
            .distinct()
            .take(FileRootCatalog.MAX_APP_DATA_ROOTS)
            .toSet()
        // Only the three shipped app-state tool names may be stored; the
        // reserved ABI names get no placeholder persistence either.
        val allowedTools = preferences.getStringSet(KEY_ADVANCED_TOOLS, emptySet()).orEmpty()
            .toSet().intersect(DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS)
        if (allowedTools != preferences.getStringSet(KEY_ADVANCED_TOOLS, emptySet()).orEmpty().toSet()) {
            preferences.edit().putStringSet(KEY_ADVANCED_TOOLS, HashSet(allowedTools)).apply()
        }
        val advancedTargets = preferences.getStringSet(KEY_ADVANCED_TARGETS, emptySet()).orEmpty()
            .toSet().filterNot { isFloeSelfPackage(it) }.take(MAX_TARGET_PACKAGES).toSet()
        return AccessSettings(
            allowedPackages = packages,
            fileRootIds = roots,
            appDataPaths = appData,
            fileWritesAllowed = preferences.getBoolean(KEY_FILE_WRITES, false),
            wholeScreenConsent = preferences.getBoolean(KEY_WHOLE_SCREEN, false),
            packageManagementAllowed = preferences.getBoolean(KEY_MANAGEMENT, false),
            advancedSystemManagementAllowed = preferences.getBoolean(KEY_ADVANCED_SYSTEM, false),
            advancedSystemAllowedTools = allowedTools,
            advancedSystemTargets = advancedTargets,
            adbEnabled = preferences.getBoolean(KEY_ADB_ENABLED, false),
            automaticPhoneControl = preferences.getBoolean("automatic_phone_control", false),
            autoUnlock = preferences.getBoolean("automatic_unlock", false),
            floatingControls = preferences.getBoolean("floating_controls", false),
        )
    }

    private fun persist() {
        preferences.edit()
            .putStringSet(KEY_PACKAGES, HashSet(settings.allowedPackages))
            .putStringSet(KEY_ROOTS, HashSet(settings.fileRootIds))
            .putStringSet(KEY_APP_DATA_ROOTS, HashSet(settings.appDataPaths))
            .putBoolean(KEY_FILE_WRITES, settings.fileWritesAllowed)
            .putBoolean(KEY_WHOLE_SCREEN, settings.wholeScreenConsent)
            .putBoolean(KEY_MANAGEMENT, settings.packageManagementAllowed)
            .putBoolean(KEY_ADVANCED_SYSTEM, settings.advancedSystemManagementAllowed)
            .putStringSet(KEY_ADVANCED_TOOLS, HashSet(settings.advancedSystemAllowedTools))
            .putStringSet(KEY_ADVANCED_TARGETS, HashSet(settings.advancedSystemTargets))
            .putBoolean(KEY_ADB_ENABLED, settings.adbEnabled)
            .putBoolean("automatic_phone_control", settings.automaticPhoneControl)
            .putBoolean("automatic_unlock", settings.autoUnlock)
            .putBoolean("floating_controls", settings.floatingControls)
            .apply()
    }

    private fun saveUnlockCredential(value: String) {
        if (value.isEmpty() || value.length > 64) return
        val bytes = value.toByteArray(Charsets.UTF_8)
        scope.launch(io) {
            try {
                unlockCredentials.write("device-lock", bytes)
                unlockConfigured = true
                settings = settings.copy(autoUnlock = true)
                persist()
                error = null
            } catch (_: Exception) {
                error = DeviceAccessUiError(context.getString(R.string.phone_automation_credential_failed), "unlock_storage")
            } finally { bytes.fill(0); publish() }
        }
    }

    private fun forgetUnlockCredential() {
        settings = settings.copy(autoUnlock = false)
        persist()
        scope.launch(io) {
            try { unlockCredentials.delete("device-lock"); unlockConfigured = false }
            catch (_: Exception) {
                error = DeviceAccessUiError(context.getString(R.string.phone_automation_credential_failed), "unlock_delete")
            }
            publish()
        }
    }

    private fun setFloatingControls(enabled: Boolean) {
        if (enabled && !Settings.canDrawOverlays(context)) {
            runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                android.net.Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
        settings = settings.copy(floatingControls = enabled)
        persist()
        publish()
    }

    private fun setAllowedPackages(packages: Set<String>) {
        if (busy != DeviceAccessBusyUi.NONE) return
        settings = settings.copy(
            allowedPackages = packages
                .filterNot { isFloeSelfPackage(it) }
                .take(MAX_TARGET_PACKAGES)
                .toSet(),
        )
        persist()
        publish()
    }

    private fun setFileRoots(roots: Set<String>) {
        if (busy != DeviceAccessBusyUi.NONE) return
        val available = cachedRoots.map { it.id }.toSet()
        val next = roots.intersect(available)
        // Switching an app-data folder off REVOKES that stored folder, not
        // merely its checkbox: the old path must leave the configured ceiling
        // and any live grant. Shared/system choices keep the fixed baseline.
        val nextAppData = settings.appDataPaths.filter { path ->
            val id = FileRootCatalog.appDataRoot(path, context.packageName, currentUserId())?.id
            id != null && id in next
        }.toSet()
        val ceilingChanged = nextAppData != settings.appDataPaths
        val writableSelected = FileScopePolicy.hasWritableSelection(
            roots = cachedRoots,
            selectedIds = next,
            appDataUsable = appDataUsable(),
        )
        if (next != settings.fileRootIds) fenceActiveRootGrants()
        settings = settings.copy(
            fileRootIds = next,
            appDataPaths = nextAppData,
            fileWritesAllowed = settings.fileWritesAllowed && writableSelected,
        )
        persist()
        refreshRootCatalog()
        if (ceilingChanged) requestRootConfigRebuild()
        publish()
    }

    private fun addAppDataRoot(rawPath: String) {
        if (busy != DeviceAccessBusyUi.NONE) return
        if (!appDataUsable()) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_app_data_requires_root),
                "app_data_requires_root",
            )
            publish()
            return
        }
        val root = FileRootCatalog.appDataRoot(
            rawPath, context.packageName, currentUserId())
        if (root == null) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_app_data_path),
                "app_data_path",
            )
            publish()
            return
        }
        if (root.path !in settings.appDataPaths &&
            settings.appDataPaths.size >= FileRootCatalog.MAX_APP_DATA_ROOTS
        ) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_app_data_limit),
                "app_data_limit",
            )
            publish()
            return
        }
        settings = settings.copy(
            fileRootIds = settings.fileRootIds + root.id,
            appDataPaths = settings.appDataPaths + root.path,
        )
        error = null
        persist()
        refreshRootCatalog()
        requestRootConfigRebuild()
        publish()
    }

    private fun setFileWrites(enabled: Boolean) {
        if (busy != DeviceAccessBusyUi.NONE) return
        if (!enabled) fenceActiveRootGrants()
        settings = settings.copy(
            fileWritesAllowed = enabled && hasWritableSelection(),
        )
        persist()
        publish()
    }

    /**
     * A user revocation (root selection or write ceiling) must not leave an
     * already-registered per-call grant usable. Fence the in-memory entries
     * first, then cancel the real backend operation where one is in flight.
     */
    private fun fenceActiveRootGrants() {
        userActionGrants.values.forEach { it.cancelled.set(true) }
        userActionGrants.clear()
        val active = rootGrants.values.toList()
        if (active.isEmpty()) return
        rootGrants.clear()
        active.forEach { it.cancelled.set(true) }
        val controller = rootController ?: return
        scope.launch(io) {
            active.mapNotNull { it.operationClaim }.forEach { claim ->
                runCatching { controller.cancelOperation(claim) }
            }
        }
    }

    private fun setWholeScreenConsent(enabled: Boolean) {
        if (busy != DeviceAccessBusyUi.NONE) return
        if (settings.wholeScreenConsent == enabled) return
        settings = settings.copy(wholeScreenConsent = enabled)
        wholeScreenConsentRevision += 1
        persist()
        publish()
    }

    private fun setPackageManagement(enabled: Boolean) {
        if (busy != DeviceAccessBusyUi.NONE) return
        if (!enabled) fenceActiveRootGrants()
        settings = settings.copy(packageManagementAllowed = enabled)
        persist()
        publish()
    }

    /**
     * The shared advanced-system master. Disabling it is a real revocation:
     * live per-call grants are fenced and cancelled, availability and the
     * published admission JSON drop the advanced names for the same epoch.
     */
    private fun setAdvancedSystem(enabled: Boolean) {
        if (busy != DeviceAccessBusyUi.NONE) return
        if (!enabled) fenceActiveRootGrants()
        settings = settings.copy(advancedSystemManagementAllowed = enabled)
        persist()
        publish()
    }

    private fun setAdvancedSystemTools(tools: Set<String>) {
        if (busy != DeviceAccessBusyUi.NONE) return
        val allowed = tools.intersect(DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS)
        if (allowed != settings.advancedSystemAllowedTools) fenceActiveRootGrants()
        settings = settings.copy(advancedSystemAllowedTools = allowed)
        persist()
        publish()
    }

    private fun setAdvancedSystemTargets(targets: Set<String>) {
        if (busy != DeviceAccessBusyUi.NONE) return
        val clean = targets
            .filterNot { isFloeSelfPackage(it) }
            .take(MAX_TARGET_PACKAGES)
            .toSet()
        if (clean != settings.advancedSystemTargets) fenceActiveRootGrants()
        settings = settings.copy(advancedSystemTargets = clean)
        persist()
        publish()
    }

    /** UID operations inherit the existing app-management, category and target gates. */
    private fun appOpsUidScopeAllowed(): Boolean =
        settings.packageManagementAllowed && settings.advancedSystemManagementAllowed &&
            DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE in settings.advancedSystemAllowedTools

    /**
     * True only when the LIVE privileged peer advertises the AppOps UID
     * write scope. Refreshed whenever service liveness flips; the UID scope
     * control and every scope=uid dispatch re-check this so an older peer
     * never receives a UID request it would silently downgrade.
     */
    @Volatile
    private var appOpsUidScopeSupported: Boolean = false

    private suspend fun refreshAppOpsUidScopeSupport() {
        val supported = try {
            com.floe.android.rootsystem.policy.PermissionOpsPolicy.CAPABILITY_APPOPS_UID in
                (rootController?.serviceCapabilities() ?: emptySet())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            false
        }
        currentCoroutineContext().ensureActive()
        if (closed) return
        if (supported != appOpsUidScopeSupported) {
            appOpsUidScopeSupported = supported
            publish()
        }
    }

    /**
     * Stage user-picked SAF documents into the App-local staging dir. Copying
     * never installs anything; the picked bytes are only made readable to the
     * privileged installer that the install tool later invokes by staged id.
     */
    private fun stageApks(uris: List<android.net.Uri>) {
        if (busy != DeviceAccessBusyUi.NONE || uris.isEmpty()) return
        scope.launch(io) {
            val result = apkStaging.stage(uris)
            when (result) {
                is ApkStagingStore.StageResult.Ok -> {
                    error = if (result.skipped.isNotEmpty()) {
                        DeviceAccessUiError(
                            context.getString(R.string.device_access_staged_partial),
                            "staged_partial",
                        )
                    } else {
                        null
                    }
                }
                is ApkStagingStore.StageResult.Failed -> {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_staged_failed),
                        result.code,
                    )
                }
            }
            stagedApks = apkStaging.list()
            publish()
        }
    }

    private fun removeStagedApk(stagedId: String) {
        if (busy != DeviceAccessBusyUi.NONE) return
        scope.launch(io) {
            val removed = apkStaging.remove(stagedId)
            // Service-owned (file-root origin) bytes are released through
            // the typed authenticated maintenance path; a busy or failed
            // release restores the manifest row and is surfaced honestly.
            if (removed != null && removed.origin == ApkStagingManifest.Origin.FILE_ROOT) {
                val released = runCatching {
                    rootController?.releaseStagedApk(removed.sha256)
                }.getOrNull() == com.floe.android.rootsystem.AccessActionResult.Ok
                if (!released) {
                    apkStaging.restore(removed)
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_staged_release_failed),
                        "staged_release",
                    )
                }
            }
            stagedApks = apkStaging.list()
            publish()
        }
    }

    /**
     * Visible user revocation: fences every live per-call grant, cancels the
     * in-flight backend operation and revokes the registered grants on the
     * service. Durable ceilings stay as the user set them; this only stops
     * what is active right now.
     */
    private fun revokeSystemGrants() {
        if (busy != DeviceAccessBusyUi.NONE) return
        fenceActiveRootGrants()
        scope.launch(io) {
            runCatching { rootController?.revokeAllGrants() }
            publish()
        }
    }

    private fun refreshStagedApks() {
        stagedApks = apkStaging.list()
    }

    /**
     * USER-ONLY screen-share selection. "This task" requires a CURRENT live
     * run candidate and is bound to that exact owner plus the current native
     * epoch; a retained arm or a stopped task can never mint it. "Until
     * stopped" is the broader session mode (still epoch-bound and RAM-only).
     */
    private fun setScreenScope(scope: DeviceAccessScreenScopeUi) {
        if (busy != DeviceAccessBusyUi.NONE) return
        val candidate = currentCandidate()
        val selection = screenShare.select(
            requested = scope,
            candidateOwner = candidate?.owner,
            sessionOwner = candidate?.owner ?: exactArmedOwner(),
            epoch = host.nativeRootEpoch()?.takeIf { it > 0 },
        )
        when (selection) {
            is ScreenScopeSelection.Active -> error = null
            is ScreenScopeSelection.Cleared -> error = null
            is ScreenScopeSelection.Refused -> {
                error = DeviceAccessUiError(
                    context.getString(
                        if (selection.code == ScreenScopeConsent.CODE_RUNTIME_NOT_READY) {
                            R.string.device_access_error_runtime_not_ready
                        } else {
                            R.string.device_access_error_no_task
                        },
                    ),
                    selection.code,
                )
            }
        }
        publish()
    }

    private fun setPairingPortInput(raw: String) {
        pairingPortInput = raw.filter { it.isDigit() }.take(5)
        publish()
    }

    // ------------------------------------------------------------- status/home

    private fun ensureRootController() {
        if (rootController != null || rootRebuilding) return
        val bases = desiredScopeBases()
        val credentials = rootCredentials ?: try {
            AndroidKeystoreCredentialStore.create(context, CREDENTIAL_NAMESPACE)
        } catch (_: Throwable) {
            return
        }
        val config = try {
            RootSystemConfig.fromContext(
                context = context,
                allowedScopeBases = bases,
                connectPort = null,
                allowPackageManagement = true,
            )
        } catch (_: Throwable) {
            return
        }
        val controller = try {
            RootSystemModule.createController(
                config = config,
                credentials = credentials,
                authority = RootAuthority(),
                context = context,
            )
        } catch (_: Throwable) {
            return
        }
        rootCredentials = credentials
        rootController = controller
        currentScopeBases = bases
        adbStatus = runCatching { controller.adbStatus.value }.getOrNull() ?: adbStatus
        rootStatus = runCatching { controller.rootStatus.value }.getOrNull() ?: rootStatus
        rootTierWasUsable = appDataUsable()
    }

    private fun currentUserId(): Int = android.os.Process.myUid() / 100_000

    private fun refreshRootCatalog() {
        val previousBaseline = cachedRoots
            .filter { it.kind != FileRootCatalog.Kind.APP_DATA }
            .map { it.path }
            .toSet()
        val roots = ArrayList<FileRootCatalog.Root>(FileRootCatalog.standardRoots())
        for (path in settings.appDataPaths.sorted()) {
            FileRootCatalog.appDataRoot(path, context.packageName, currentUserId())?.let { roots += it }
        }
        cachedRoots = roots
        val baselineChanged = previousBaseline != roots
            .filter { it.kind != FileRootCatalog.Kind.APP_DATA }
            .map { it.path }
            .toSet()
        if (baselineChanged && rootController != null) requestRootConfigRebuild()
    }

    /**
     * The controller's user-grantable ceiling. The fixed shared/system
     * baseline is always listed (System is also the diagnostics anchor), and
     * an other-app folder is added ONLY while it is a stored explicit choice
     * on this Root tier. The live selected-id check below remains the actual
     * grant gate; the App never widens this from model text and never makes an
     * empty ceiling mean "all paths".
     */
    private fun desiredScopeBases(): List<String> {
        val paths = LinkedHashSet<String>()
        for (root in FileRootCatalog.standardRoots()) paths += root.path
        for (path in settings.appDataPaths.sorted()) {
            FileRootCatalog.normalizeAppDataBase(path, context.packageName, currentUserId())
                ?.let { paths += it }
        }
        if (paths.isEmpty()) paths += FileRootCatalog.DIAGNOSTICS_BASE
        return paths.toList()
    }

    private fun appDataUsable(): Boolean = FileScopePolicy.appDataUsable(
        rootEnabled = rootStatus is RootStatus.Enabled,
        adbServiceAlive = adbStatus is AdbStatus.ServiceAlive,
    )

    private fun effectiveSelectedRoots(): List<FileRootCatalog.Root> = FileScopePolicy.effectiveSelected(
        roots = cachedRoots,
        selectedIds = settings.fileRootIds,
        appDataUsable = appDataUsable(),
    )

    private fun hasWritableSelection(): Boolean = FileScopePolicy.hasWritableSelection(
        roots = cachedRoots,
        selectedIds = settings.fileRootIds,
        appDataUsable = appDataUsable(),
    )

    /** Status changes may prune RAM/file preferences, so they run on the main
     *  thread next to the other user-action mutations. */
    private fun onRootStateChanged() {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            handleRootStateChanged()
        } else {
            Handler(Looper.getMainLooper()).post { if (!closed) handleRootStateChanged() }
        }
    }

    private fun handleRootStateChanged() {
        if (closed) return
        val usable = appDataUsable()
        if (!rootRebuilding) {
            // Once the Root tier is no longer the live owner, its explicitly
            // added other-app folders stop being a stored ceiling too. ADB
            // never inherits them by selecting a root.
            if (rootTierWasUsable && !usable) pruneAppDataRoots(rebuild = true)
            rootTierWasUsable = usable
        }
        publish()
    }

    private fun pruneAppDataRoots(rebuild: Boolean) {
        val derived = settings.appDataPaths.mapNotNull {
            FileRootCatalog.appDataRoot(it, context.packageName, currentUserId())?.id
        }.toSet()
        val stale = derived + settings.fileRootIds.filter { FileRootCatalog.isAppDataId(it) }
        if (stale.isEmpty() && settings.appDataPaths.isEmpty()) return
        settings = settings.copy(
            fileRootIds = settings.fileRootIds - stale,
            appDataPaths = emptySet(),
            fileWritesAllowed = settings.fileWritesAllowed && hasWritableSelectionAfter(stale),
        )
        persist()
        refreshRootCatalog()
        if (rebuild && rootController != null) requestRootConfigRebuild()
    }

    private fun hasWritableSelectionAfter(removing: Set<String>): Boolean = FileScopePolicy.hasWritableSelection(
        roots = cachedRoots,
        selectedIds = settings.fileRootIds - removing,
        appDataUsable = appDataUsable(),
    )

    private fun requestRootConfigRebuild() {
        if (closed || rootController == null) return
        if (currentScopeBases == desiredScopeBases()) {
            rootConfigDirty = false
            return
        }
        rootConfigDirty = true
        tryRebuildRootController()
    }

    /**
     * App-data folders are the only scopes whose presence depends on a user
     * edit after the controller exists. Rebuilding uses the SAME credential
     * store, fences/revokes every old grant first, lets the module attach the
     * new controller (which closes the old one) and then re-adopts an already
     * user-enabled Root service. The service itself is never stopped or
     * started implicitly by the rebuild.
     */
    private fun tryRebuildRootController() {
        if (!rootConfigDirty || closed || rootRebuilding) return
        if (busy != DeviceAccessBusyUi.NONE) return
        if (adbStatus is AdbStatus.Pairing) return
        rootConfigDirty = false
        rootRebuilding = true
        // Never turn a live ADB session into a Root re-adoption. The new
        // controller's own refresh adopts the existing ADB binder; Root is
        // re-adopted only when it was the actual live owner.
        val resumeRoot = rootStatus is RootStatus.Enabled &&
            adbStatus !is AdbStatus.ServiceAlive
        scope.launch(io) {
            try {
                val bases = desiredScopeBases()
                if (currentScopeBases == bases) return@launch
                // No old grant may survive under an old ceiling.
                val active = rootGrants.values.toList()
                rootGrants.clear()
                active.forEach { it.cancelled.set(true) }
                active.mapNotNull { it.operationClaim }.forEach { claim ->
                    runCatching { rootController?.cancelOperation(claim) }
                }
                val credentials = rootCredentials ?: AndroidKeystoreCredentialStore.create(
                    context, CREDENTIAL_NAMESPACE)
                val config = RootSystemConfig.fromContext(
                    context = context,
                    allowedScopeBases = bases,
                    connectPort = null,
                    allowPackageManagement = true,
                )
                // createController attaches to the single module runtime and
                // closes the previous controller (revoking its grants).
                val controller = RootSystemModule.createController(
                    config = config,
                    credentials = credentials,
                    authority = RootAuthority(),
                    context = context,
                )
                rootController = controller
                rootCredentials = credentials
                currentScopeBases = bases
                adbStatus = runCatching { controller.adbStatus.value }.getOrNull() ?: adbStatus
                rootStatus = runCatching { controller.rootStatus.value }.getOrNull() ?: rootStatus
                if (resumeRoot) {
                    val result = controller.setRootEnabled(true)
                    if (result !is AccessActionResult.Ok) {
                        error = DeviceAccessUiError(
                            context.getString(R.string.device_access_error_root_failed),
                            (result as? AccessActionResult.Denied)?.code ?: "root_config",
                        )
                    }
                }
            } catch (_: Throwable) {
                error = DeviceAccessUiError(
                    context.getString(R.string.device_access_error_unavailable), "root_config")
            } finally {
                rootRebuilding = false
                if (!closed) {
                    // Read the new controller's ACTUAL state before deciding
                    // whether the app-data ceiling became unusable.
                    refreshControllerStatus()
                    val usableNow = appDataUsable()
                    val dropAppData = !usableNow && settings.appDataPaths.isNotEmpty()
                    if (dropAppData) {
                        // Do not start a nested rebuild before this one has
                        // refreshed and published its final controller state.
                        pruneAppDataRoots(rebuild = false)
                    } else {
                        rootTierWasUsable = usableNow
                    }
                    publish()
                    if (dropAppData) {
                        requestRootConfigRebuild()
                    } else if (rootConfigDirty) {
                        tryRebuildRootController()
                    }
                }
            }
        }
    }

    private suspend fun refreshControllerStatus() {
        runCatching { rootController?.refresh() }
        adbStatus = runCatching { rootController?.adbStatus?.value }.getOrNull() ?: adbStatus
        rootStatus = runCatching { rootController?.rootStatus?.value }.getOrNull() ?: rootStatus
        refreshAppOpsUidScopeSupport()
    }

    private fun refreshFromUser() {
        if (busy != DeviceAccessBusyUi.NONE) return
        error = null
        scope.launch(io) {
            refreshRootCatalog()
            refreshControllerStatus()
            refreshPackages()
            refreshAdvancedSystemPackages()
            publish()
        }
    }

    /**
     * Refresh the advanced catalog through the privileged current-user query
     * (including disabled and removed-for-user preinstalled apps for
     * restore/disable) and merge it with the user's exact lookups and the
     * persisted selection identities; falls back to the ordinary installed
     * list while no service is alive.
     */
    private suspend fun refreshAdvancedSystemPackages() {
        scheduleCatalogRefresh()
    }

    private class AdvancedCatalogResult(
        val packages: List<DeviceAccessPackageUi>,
        val serviceTruncated: Boolean,
        val failed: Boolean = false,
    )

    /**
     * The privileged inventory travels the SAME real UI grant lifecycle as
     * the user's own settings actions ([withUserActionGrant]: register one
     * host-issued read-only grant, dispatch, revoke in finally). The old
     * fabricated "readlease:appstate-refresh" id was never enrolled in the
     * userActionGrants/rootGrants registries, so RootAuthority denied every
     * dispatch with grant_unknown and the chooser silently mirrored the
     * (visibility-empty) launcher list.
     */
    private suspend fun collectAdvancedCatalog(
        fallback: List<DeviceAccessPackageUi> = installedPackages,
    ): AdvancedCatalogResult {
        if (!systemServiceAlive()) return AdvancedCatalogResult(fallback, false)
        val result = withUserActionGrant(
            operation = SystemOperation.PACKAGE_QUERY,
            target = null,
            destructive = false,
        ) { claim ->
            rootController?.packageQuery(
                claim = claim,
                packageName = null,
                includeSystem = true,
                maxEntries = BinderProtocol.MAX_LIST,
                includeUninstalled = true,
            ) ?: RootResult.Unavailable("service_not_alive")
        }
        val query = (result as? RootResult.Ok)?.value
            ?: return AdvancedCatalogResult(fallback, false, failed = true)
        return AdvancedCatalogResult(
            packages = query.packages
                .filterNot { isFloeSelfPackage(it.packageName) }
                .map { record ->
                    DeviceAccessPackageUi(
                        packageName = record.packageName,
                        label = runCatching {
                            context.packageManager.getApplicationInfo(record.packageName, 0)
                        }.getOrNull()?.let {
                            runCatching { it.loadLabel(context.packageManager).toString() }
                                .getOrNull()
                        } ?: record.packageName,
                        selected = record.packageName in settings.advancedSystemTargets,
                    )
                },
            serviceTruncated = query.truncated,
        )
    }

    /**
     * Merge the discovered page, the verified exact-lookup extras and the
     * persisted selection identities. A stored selection is never silently
     * dropped: rows currently invisible still show by package name, and the
     * pre-window size is published so the sheet can state the window
     * honestly instead of truncating before search.
     */
    private fun mergeAdvancedCatalog(discovered: List<DeviceAccessPackageUi>): List<DeviceAccessPackageUi> {
        val rows = com.floe.android.mergeDeviceAccessAppCatalog(
            discovered, advancedLookupExtras.values.toList(), settings.advancedSystemTargets)
        advancedCatalogListed = rows.size
        // Keep the whole bounded service page for filtering. LazyColumn only
        // composes visible rows; cutting here hid exact lookup hits as well.
        advancedCatalogWindowed = false
        return rows
    }

    /**
     * The user's exact-name lookup from the advanced chooser: one real
     * PACKAGE_QUERY grant through [withUserActionGrant] resolves the typed
     * name against the live service (including removed-for-user preinstalled
     * packages). A found row is merged into the catalog so it is selectable
     * immediately; a miss is reported truthfully. No guessed rows are ever
     * shown — only the service's own record.
     */
    fun lookupAdvancedSystemTarget(rawName: String) {
        if (closed || busy != DeviceAccessBusyUi.NONE || advancedLookupBusy) return
        val name = rawName.trim()
        advancedLookupQuery = name
        if (!ADVANCED_LOOKUP_NAME.matches(name) || !systemServiceAlive()) {
            advancedLookupState = DeviceAccessLookupUiState.ERROR
            publish()
            return
        }
        val acceptedEpoch = host.nativeRootEpoch()
        val acceptedController = rootController
        advancedLookupBusy = true
        advancedLookupState = DeviceAccessLookupUiState.RUNNING
        publish()
        advancedLookupJob = scope.launch(io) {
            try {
                val result = withUserActionGrant(
                    operation = SystemOperation.PACKAGE_QUERY,
                    target = name,
                    destructive = false,
                ) { claim ->
                    rootController?.packageQuery(
                        claim = claim, packageName = name, includeSystem = true,
                        maxEntries = 1, includeUninstalled = true,
                    ) ?: RootResult.Unavailable("service_not_alive")
                }
                if (closed) return@launch
                if (host.nativeRootEpoch() != acceptedEpoch ||
                    rootController !== acceptedController) {
                    advancedLookupState = DeviceAccessLookupUiState.ERROR
                    return@launch
                }
                val query = (result as? RootResult.Ok)?.value
                val record = query?.packages?.firstOrNull()
                advancedLookupState = when {
                    query == null -> DeviceAccessLookupUiState.ERROR
                    record == null || isFloeSelfPackage(record.packageName) -> DeviceAccessLookupUiState.MISSING
                    else -> {
                        advancedLookupExtras[record.packageName] = DeviceAccessPackageUi(
                            packageName = record.packageName,
                            label = runCatching {
                                context.packageManager.getApplicationInfo(record.packageName, 0)
                                    .loadLabel(context.packageManager).toString()
                            }.getOrDefault(record.packageName),
                            selected = record.packageName in settings.advancedSystemTargets,
                        )
                        DeviceAccessLookupUiState.FOUND
                    }
                }
                advancedSystemPackages = mergeAdvancedCatalog(advancedDiscovered)
            } finally {
                advancedLookupBusy = false
                if (!closed) publish()
            }
        }
    }

    private suspend fun refreshPackages() {
        scheduleCatalogRefresh()
    }

    private suspend fun collectInstalledPackages(): List<DeviceAccessPackageUi> {
        val packages = try {
            val manager = context.packageManager
            val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            val resolved = if (Build.VERSION.SDK_INT >= 33) {
                manager.queryIntentActivities(
                    intent,
                    android.content.pm.PackageManager.ResolveInfoFlags.of(0L),
                )
            } else {
                @Suppress("DEPRECATION")
                manager.queryIntentActivities(intent, 0)
            }
            resolved.asSequence()
                .mapNotNull { it.activityInfo?.applicationInfo }
                .distinctBy { it.packageName }
                .filterNot { isFloeSelfPackage(it.packageName) }
                .map {
                    DeviceAccessPackageUi(
                        packageName = it.packageName,
                        label = runCatching { it.loadLabel(manager).toString() }
                            .getOrDefault(it.packageName),
                        selected = it.packageName in settings.allowedPackages,
                    )
                }
                .sortedBy { it.label.lowercase() }
                .toList()
        } catch (_: Throwable) {
            emptyList()
        }
        return packages
    }

    private fun registerPackageChangeMonitor() {
        runCatching {
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_PACKAGE_ADDED)
                addAction(Intent.ACTION_PACKAGE_REMOVED)
                addAction(Intent.ACTION_PACKAGE_REPLACED)
                addDataScheme("package")
            }
            if (Build.VERSION.SDK_INT >= 33) {
                context.registerReceiver(
                    packageChangeMonitor, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(packageChangeMonitor, filter)
            }
        }
    }

    /**
     * Coalescing catalog refresh used by sheet-entry refreshes and the
     * install/remove monitor. Cancelling the previous job and checking the
     * generation before every assignment fences late replies: a refresh
     * superseded while in flight never publishes or clobbers the newer
     * catalog.
     */
    private fun scheduleCatalogRefresh() {
        if (closed) return
        synchronized(catalogRefreshLock) {
            if (closed) return
            val generation = ++catalogRefreshGeneration
            catalogRefreshJob?.cancel()
            catalogLoading = true
            catalogRefreshJob = scope.launch(io) {
                try {
                    val installed = collectInstalledPackages()
                    if (closed || generation != catalogRefreshGeneration) return@launch
                    val advanced = collectAdvancedCatalog(installed)
                    if (closed || generation != catalogRefreshGeneration) return@launch
                    installedPackages = installed
                    installedCatalogTotal = installed.size
                    advancedDiscovered = advanced.packages
                    advancedCatalogServiceTruncated = advanced.serviceTruncated
                    advancedCatalogReadFailed = advanced.failed
                    advancedSystemPackages = mergeAdvancedCatalog(advanced.packages)
                } catch (failure: Exception) {
                    if (closed || generation != catalogRefreshGeneration) return@launch
                    advancedCatalogReadFailed = true
                } finally {
                    if (!closed && generation == catalogRefreshGeneration) {
                        catalogLoading = false
                        publish()
                    }
                }
            }
        }
        publish()
    }

    /**
     * The visible running task, or — when the chat surface is not the
     * currently bound one (for example while the Settings dialog owns the
     * window) — exactly one uniquely resolved live task from the existing
     * history projection. Never inferred from a previous phone tool call,
     * never from a finished owner, and never guessed among several live
     * tasks.
     */
    private fun currentCandidate(): TaskCandidate? {
        val visible = try {
            host.conversations.currentVisibleConversationId()
        } catch (_: Throwable) {
            null
        }
        if (visible != null) return candidateFor(visible)
        return liveCandidateFallback()
    }

    private fun candidateFor(conversationId: String): TaskCandidate? {
        val entry = try {
            host.conversations.entryFor(conversationId)
        } catch (_: Throwable) {
            null
        } ?: return null
        val state = try {
            entry.holder.snapshot.value
        } catch (_: Throwable) {
            null
        } ?: return null
        if (!state.isRunning) return null
        val runId = state.selectedRunId ?: return null
        val taskUuid = runCatching { UUID.fromString(conversationId) }.getOrNull() ?: return null
        val runUuid = runCatching { UUID.fromString(runId) }.getOrNull() ?: return null
        val phase = if (state.pendingApprovals.isNotEmpty()) {
            DeviceAccessTaskPhaseUi.WAITING_FOR_USER
        } else {
            DeviceAccessTaskPhaseUi.RUNNING
        }
        return TaskCandidate(
            owner = PhoneControlOwner(taskUuid, runUuid),
            title = state.taskTitle.ifBlank { context.getString(R.string.device_access_current_task) },
            phase = phase,
        )
    }

    /**
     * Bounded fallback over the history projection's REAL live-run ids. The
     * projection is refreshed by the conversation host on launch/terminal, so
     * this is not a poller; each id is still resolved through the same holder
     * snapshot and must report a running selected run.
     *
     * Only a UNIQUELY resolved live candidate is returned. Several
     * concurrently running tasks are ambiguous, and choosing the first or the
     * "newest" would grant phone control to a task the user is not looking
     * at. Ambiguity means no candidate; the user selects/opens the task.
     */
    private fun liveCandidateFallback(): TaskCandidate? {
        val state = runCatching {
            host.conversations.historyHolder.state.value
        }.getOrNull() ?: return null
        val running = state.runningConversationIds
        if (running.isEmpty()) return null
        // A set larger than the scan cannot be proven unique within bounds.
        if (running.size > MAX_LIVE_TASK_SCAN) return null
        val resolved = running.mapNotNull { candidateFor(it) }
        val unique = PhoneTaskPresentation.uniqueLiveCandidate(
            resolved.map { PhoneTaskLiveCandidate(it.owner, it.title, it.phase) },
        ) ?: return null
        return resolved.first { it.owner == unique.owner }
    }

    private fun titleFor(owner: PhoneControlOwner): String =
        if (recentOwner == owner) {
            recentTitle?.takeIf { it.isNotBlank() }
                ?: context.getString(R.string.device_access_current_task)
        } else {
            context.getString(R.string.device_access_current_task)
        }

    /**
     * The exact run that is live in the REAL holder: the task/run pair the
     * conversation host itself reports as running and selected. A released
     * holder or a terminal/other selected run is not live.
     *
     * Native holders are keyed by canonical UPPERCASE UUID text
     * (`UUID.uuidString`); JVM-created holders use lowercase
     * `UUID.toString()`. Try exactly those two spellings of THIS owner's
     * conversation id — never a scan or another owner's key.
     */
    private fun isOwnerRunLive(owner: PhoneControlOwner): Boolean {
        val entry = PhoneTaskPresentation.holderLookupKeys(owner.taskID)
            .firstNotNullOfOrNull { key ->
                runCatching { host.conversations.entryFor(key) }.getOrNull()
            } ?: return false
        val state = runCatching { entry.holder.snapshot.value }.getOrNull()
            ?: return false
        return PhoneTaskPresentation.liveOwnerRun(
            isRunning = state.isRunning,
            selectedRunID = state.selectedRunId,
            runID = owner.runID,
        )
    }

    /**
     * The host arm ONLY while it is also the phone service's actual fence
     * owner. A stale host arm is not a live session to extend.
     */
    private fun exactArmedOwner(): PhoneControlOwner? =
        armedOwner?.takeIf { !userStopped && it == phoneStatus.activeOwner }

    /**
     * Drop RAM-only screen consent that can no longer authorize the exact
     * live session: the bound "This task" run terminal, a new native epoch,
     * or a torn-down phone service. "Until stopped" deliberately survives a
     * task terminal; only the user's Stop/Takeover, epoch or teardown ends it.
     */
    private fun reconcileScreenShare() {
        if (screenShare.binding == null) return
        screenShare.reconcile(
            epoch = host.nativeRootEpoch()?.takeIf { it > 0 },
            ownerRunLive = ::isOwnerRunLive,
        )
    }

    /**
     * Latch the exact stop as settled only after the ACTUAL holder no longer
     * reports that run live. This is what separates the short cancellation
     * window from a real Continue/retry incarnation of the same run id.
     * A missing/released holder is not live and therefore settled.
     */
    private fun markStoppedOwnerSettled() {
        if (!userStopped) return
        val owner = lastStoppedOwner ?: return
        if (stoppedOwnerSettled) return
        if (!isOwnerRunLive(owner)) stoppedOwnerSettled = true
    }

    // ------------------------------------------------------------ presentation

    private fun publish() {
        if (closed) return
        markStoppedOwnerSettled()
        val ended = automatedOwner.get()?.takeUnless { isOwnerRunLive(it) }
        if (ended != null && automatedOwner.compareAndSet(ended, null)) {
            runCatching { android.util.Log.i("FloePhoneUnlock", "AUTOMATION_RUN_NO_LONGER_LIVE") }
            if (explicitResumeOwner == ended) explicitResumeOwner = null
            if (armedOwner == ended) armedOwner = null
            phoneClient?.finishAutomation(ended)
            automationControls.clear(expectedOwner = ended)
        }
        automatedOwner.get()?.takeIf { !userStopped && isOwnerRunLive(it) }?.let {
            automationControls.show(it, titleFor(it), settings.floatingControls, phonePause.isPaused(it))
        }
        reconcileScreenShare()
        val candidate = currentCandidate()
        // Only the phone service's ACTUAL fence owner may be shown as armed.
        // After a user touch, stop, takeover, lock or service loss the host's
        // armedOwner is stale: it is not live authorization and must not hide
        // the current run's explicit Allow entry.
        val ownership = PhoneTaskPresentation.ownership(
            candidate = candidate?.let {
                PhoneTaskLiveCandidate(it.owner, it.title, it.phase)
            },
            armedOwner = armedOwner,
            actualOwner = phoneStatus.activeOwner,
            stoppedOwner = lastStoppedOwner,
            userStopped = userStopped,
        )
        val active = ownership?.let {
            DeviceAccessActiveTaskUi(
                title = if (it.titleSource == PhoneTaskTitleSource.CANDIDATE) {
                    candidate?.title ?: titleFor(it.owner)
                } else {
                    titleFor(it.owner)
                },
                phase = if (phonePause.isPaused(it.owner)) DeviceAccessTaskPhaseUi.WAITING_FOR_USER else it.phase,
            )
        }
        val control = if (ownership != null && phonePause.isPaused(ownership.owner)) DeviceAccessTaskControlUi.OFF
            else ownership?.control ?: DeviceAccessTaskControlUi.OFF
        val roots = cachedRoots
        val writableSelected = hasWritableSelection()
        val targets = DeviceAccessTargetsUi(
            packages = installedPackages.map {
                it.copy(selected = it.packageName in settings.allowedPackages)
            },
            selectedPackages = settings.allowedPackages,
            fileRoots = roots.map {
                DeviceAccessFileRootUi(
                    id = it.id,
                    labelRes = it.labelRes,
                    label = it.label,
                    selected = it.id in settings.fileRootIds,
                    writable = it.writable,
                    kind = when (it.kind) {
                        FileRootCatalog.Kind.SHARED -> DeviceAccessFileRootKindUi.SHARED
                        FileRootCatalog.Kind.SYSTEM -> DeviceAccessFileRootKindUi.SYSTEM
                        FileRootCatalog.Kind.APP_DATA -> DeviceAccessFileRootKindUi.APP_DATA
                    },
                )
            },
            selectedRootIds = settings.fileRootIds,
            fileWritesAllowed = settings.fileWritesAllowed && writableSelected,
            appDataRootsAvailable = appDataUsable(),
            packageManagementAllowed = settings.packageManagementAllowed,
            advancedSystemManagementAllowed = settings.advancedSystemManagementAllowed,
            advancedSystemAllowedTools = settings.advancedSystemAllowedTools,
            selectedAdvancedSystemTargets = settings.advancedSystemTargets,
            appOpsUidScopeAllowed = appOpsUidScopeAllowed(),
            appOpsUidScopeSupported = appOpsUidScopeSupported,
            advancedSystemTargets = advancedSystemPackages.map {
                it.copy(selected = it.packageName in settings.advancedSystemTargets)
            },
            installedCatalogTotal = installedCatalogTotal,
            catalogLoading = catalogLoading,
            advancedCatalogReadFailed = advancedCatalogReadFailed,
            advancedCatalogListed = advancedCatalogListed,
            advancedCatalogWindowed = advancedCatalogWindowed,
            advancedCatalogServiceTruncated = advancedCatalogServiceTruncated,
            advancedLookupState = advancedLookupState,
            advancedLookupQuery = advancedLookupQuery,
            advancedLookupAvailable = systemServiceAlive(),
            stagedApks = stagedApks.map {
                com.floe.android.DeviceAccessStagedApkUi(
                    stagedId = it.stagedId,
                    fileName = it.fileName,
                    sizeBytes = it.sizeBytes,
                    packageName = it.packageName,
                    sha256 = it.sha256,
                )
            },
            wholeScreenConsent = settings.wholeScreenConsent,
            windowScreenshotCapable = Build.VERSION.SDK_INT >= 34,
        )
        mutableSystemSettingsUi.value = mutableSystemSettingsUi.value.copy(
            enabled = systemSettingsCeilingEnabled(),
        )
        mutablePresentation.value = DeviceAccessPresentationState(
            accessibility = accessibilityUi(),
            adb = adbUi(),
            root = rootUi(),
            // Never project a global/stale choice: the effective RAM consent
            // is shown only for the candidate it actually covers.
            screenScope = screenShare.presented(
                activeOwner = ownership?.owner,
                liveCandidateOwner = candidate?.owner,
                epoch = host.nativeRootEpoch()?.takeIf { it > 0 },
            ),
            activeTask = active,
            taskControl = control,
            targets = targets,
            busy = busy,
            error = error,
            pairingSupported = pairingSupported(),
            pairingPort = if (pairingSessionOpen) {
                discoveredPairingPort?.toString() ?: pairingPortInput
            } else {
                ""
            },
            pairingDiscovery = pairingDiscovery,
            usbBootstrapExported = usbBootstrapExported,
            automaticPhoneControl = settings.automaticPhoneControl,
            autoUnlock = settings.autoUnlock && unlockConfigured,
            unlockConfigured = unlockConfigured,
            floatingControls = settings.floatingControls,
            systemSettings = mutableSystemSettingsUi.value,
        )
        pump?.publishAvailability()
    }

    private fun pairingSupported(): Boolean =
        rootController?.pairingSupported ?: (Build.VERSION.SDK_INT >= 30)

    private fun accessibilityUi(): DeviceAccessAccessibilityUi {
        if (closed) return DeviceAccessAccessibilityUi.Revoked
        val enabled = runCatching { activation.isEnabled() }.getOrDefault(false)
        if (!enabled) return DeviceAccessAccessibilityUi.NotGranted
        return when (phoneStatus.blocker) {
            PhoneControlBlocker.SERVICE_REVOKED -> DeviceAccessAccessibilityUi.Revoked
            PhoneControlBlocker.SERVICE_DISCONNECTED -> DeviceAccessAccessibilityUi.Restricted
            else -> if (phoneStatus.connected) {
                DeviceAccessAccessibilityUi.Granted
            } else {
                DeviceAccessAccessibilityUi.Restricted
            }
        }
    }

    private fun adbUi(): DeviceAccessAdbUi {
        if (!settings.adbEnabled) return DeviceAccessAdbUi.Off
        val status = adbStatus ?: return DeviceAccessAdbUi.Error(
            context.getString(R.string.device_access_error_unavailable), "controller_unbound")
        return when (status) {
            AdbStatus.Disabled -> DeviceAccessAdbUi.Off
            AdbStatus.PairRequired -> DeviceAccessAdbUi.PairRequired(pairingSessionOpen)
            AdbStatus.Pairing -> DeviceAccessAdbUi.Pairing
            is AdbStatus.Paired -> DeviceAccessAdbUi.Paired()
            is AdbStatus.ServiceAlive ->
                DeviceAccessAdbUi.ServiceAlive(status.effectiveUid)
            is AdbStatus.ServiceDied -> DeviceAccessAdbUi.ServiceDied(status.code)
            AdbStatus.RestartRequired -> DeviceAccessAdbUi.RestartRequired
            AdbStatus.Revoked -> DeviceAccessAdbUi.Revoked
            is AdbStatus.Error -> DeviceAccessAdbUi.Error(
                context.getString(R.string.device_access_error_unavailable), status.code)
        }
    }

    private fun rootUi(): DeviceAccessRootUi = when (val status = rootStatus) {
        null, RootStatus.Off -> DeviceAccessRootUi.Off
        RootStatus.GrantNotFound -> DeviceAccessRootUi.GrantNotFound
        RootStatus.GrantFound -> DeviceAccessRootUi.GrantFound
        // A live ADB service owns the one controller binder. The Root status
        // field can still say Enabled from an earlier adoption; it is a stored
        // grant, not the live owner, so do not present it as active Root.
        is RootStatus.Enabled -> if (adbStatus is AdbStatus.ServiceAlive) {
            DeviceAccessRootUi.GrantFound
        } else {
            DeviceAccessRootUi.Enabled(status.effectiveUid)
        }
        is RootStatus.Refused -> DeviceAccessRootUi.Refused(status.code)
        is RootStatus.Error -> DeviceAccessRootUi.Error(
            context.getString(R.string.device_access_error_unavailable), status.code)
    }

    // ------------------------------------------------------------- user actions

    private fun openAccessibilitySettings() {
        val intent = try {
            activation.settingsIntent()
        } catch (_: Throwable) {
            null
        } ?: return
        startActivity(intent)
    }

    private fun openDeveloperOptions() {
        startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
    }

    private fun startActivity(intent: Intent) {
        try {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Throwable) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_open_settings), "open_settings")
            publish()
        }
    }

    private fun armVisibleTask() {
        if (busy != DeviceAccessBusyUi.NONE) return
        markStoppedOwnerSettled()
        val candidate = currentCandidate()
        val decision = PhoneTaskPresentation.armTarget(
            candidate = candidate?.let {
                PhoneTaskLiveCandidate(it.owner, it.title, it.phase)
            },
            userStopped = userStopped,
            stoppedOwner = lastStoppedOwner,
            stoppedOwnerSettled = stoppedOwnerSettled,
        )
        val target = when (decision) {
            is PhoneTaskArmDecision.Refuse -> {
                error = if (decision.code == PhoneTaskPresentation.CODE_STOP_SETTLING) {
                    DeviceAccessUiError(
                        context.getString(R.string.device_access_active_stopping), decision.code)
                } else {
                    DeviceAccessUiError(
                        context.getString(R.string.device_access_error_no_task), decision.code)
                }
                publish()
                return
            }
            is PhoneTaskArmDecision.Arm -> decision.candidate
        }
        val owner = target.owner
        val title = target.title
        val epoch = host.nativeRootEpoch()?.takeIf { it > 0 }
        if (epoch == null) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_runtime_not_ready), "runtime_not_ready")
            publish()
            return
        }
        val packages = settings.allowedPackages
        if (packages.isEmpty()) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_select_apps), "no_target_apps")
            publish()
            return
        }
        val client = phoneClient ?: return
        // Settings Allow is an explicit fresh user gesture too. It can
        // resume this exact task, never a foreign retained pause.
        val paused = phonePause.snapshot?.takeIf { it.owner == owner }
        if (pauseStateInvalid || paused != null) {
            val cleared = if (paused != null) phonePause.resume(owner, paused.id, ::clearPersistedPause)
                else clearPersistedPause()
            if (!cleared) { resumeFailed(); return }
            pauseStateInvalid = false
        }
        busy = DeviceAccessBusyUi.PHONE_ARM
        val armRevision = phoneControlRevision.get()
        error = null
        publish()
        scope.launch(io) {
            armingOwner = owner
            try {
                val principal = PhoneControlPrincipal(
                    owner = owner,
                    epoch = epoch,
                    allowedPackages = packages,
                )
                // If the service still has a DIFFERENT actual owner, this
                // explicit user gesture transfers the one phone-control
                // grant. Fence the old owner first (its in-flight operation
                // is aborted); the old grant is never inherited or reused.
                val liveOwner = phoneStatus.activeOwner
                if (liveOwner != null && liveOwner != owner) {
                    armedOwner = null
                    // Moving the one phone-control grant away from the OLD
                    // actual owner ends that owner's exact "This task"
                    // consent. A choice already made for the new task and the
                    // explicit broader Until-stopped mode both survive.
                    screenShare.clearExactTask(liveOwner)
                    client.takeover()
                }
                when (val result = client.arm(principal)) {
                    is PhoneControlResult.Ok -> {
                        if (phoneControlRevision.get() != armRevision || phonePause.isPaused(owner)) {
                            client.takeover()
                            return@launch
                        }
                        armedOwner = owner
                        automatedOwner.set(owner)
                        phoneStatus = result.value
                        userStopped = false
                        lastStoppedOwner = null
                        recentOwner = owner
                        recentTitle = title
                        error = null
                    }
                    is PhoneControlResult.Denied -> {
                        error = DeviceAccessUiError(
                            denialMessage(result.reason), denialCode(result.reason))
                    }
                    is PhoneControlResult.Unavailable -> {
                        error = DeviceAccessUiError(
                            unavailableMessage(result.reason), unavailableCode(result.reason))
                    }
                    is PhoneControlResult.Failed -> {
                        error = DeviceAccessUiError(
                            context.getString(R.string.device_access_error_phone_failed),
                            "phone_${result.reason.name.lowercase()}")
                    }
                }
            } catch (_: Throwable) {
                error = DeviceAccessUiError(
                    context.getString(R.string.device_access_error_phone_failed), "phone_arm")
            } finally {
                armingOwner = null
                busy = DeviceAccessBusyUi.NONE
                publish()
            }
        }
    }

    private fun controlOwner(): PhoneControlOwner? = armingOwner ?: phoneStatus.activeOwner ?: armedOwner ?: automatedOwner.get()

    private fun clearPersistedPause(): Boolean = preferences.edit().remove(KEY_PHONE_PAUSE).commit()

    private fun resumeFailed() {
        error = DeviceAccessUiError(context.getString(R.string.phone_automation_resume_failed), "phone_resume_failed")
        publish()
    }

    /** Notification/overlay callbacks carry their exact owner. A different
     * task becoming visible cannot turn an old action into a fresh grant. */
    private fun onAutomationControl(owner: PhoneControlOwner, action: PhoneAutomationControls.Action) {
        if (closed || userStopped || !isOwnerRunLive(owner) || controlOwner() != owner) return
        when (action) {
            PhoneAutomationControls.Action.PAUSE -> {
                phoneControlRevision.incrementAndGet()
                explicitResumeOwner = null
                val pause = phonePause.pause(owner, System.currentTimeMillis())
                if (!preferences.edit().putString(KEY_PHONE_PAUSE, pause.encode()).commit()) resumeFailed()
                armedOwner = null
                // Fences live gestures/observations but DOES NOT cancel the
                // Agent run or its independent background operations.
                phoneClient?.takeover()
                publish()
            }
            PhoneAutomationControls.Action.RESUME -> {
                val pause = phonePause.snapshot?.takeIf { it.owner == owner } ?: return
                if (!phonePause.resume(owner, pause.id, ::clearPersistedPause)) { resumeFailed(); return }
                explicitResumeOwner = owner
                publish()
                resumePausedQuestion(pause)
            }
            PhoneAutomationControls.Action.TAKE_OVER -> stopActiveTask(takeOver = true, expectedOwner = owner)
        }
    }

    /** A real user Continue settles only the matching durable pause question
     * through its existing digest/nonce/revision CAS. No synthetic run start. */
    private fun resumePausedQuestion(pause: PhoneAutomationPause.Snapshot) {
        if (!host.readiness.value.conversationDomainAdmitted) return
        val owner = pause.owner
        val revision = phoneControlRevision.get()
        val conversation = owner.taskID.toString()
        host.trackOperation(HostCommandRequest(command = "question.pending",
            scope = HostScope.ConversationLifecycle(conversation), stateful = false,
            correlationID = "phone-pause-pending-${UUID.randomUUID()}")) { outcome ->
            if (closed || userStopped || !isOwnerRunLive(owner) || controlOwner() != owner ||
                phoneControlRevision.get() != revision || phonePause.isPaused(owner)) return@trackOperation
            val completed = outcome as? HostOperationOutcome.Completed ?: run { resumeFailed(); return@trackOperation }
            val questions = completed.value?.let { PhonePauseQuestionSelector.select(it, pause) } ?: emptyList()
            // Zero is valid when paused between tools; no unrelated question
            // is answered. Each selected request is bound to a real phone call.
            for (question in questions) {
                val payload = JsonObject(mapOf(
                    "requestID" to JsonPrimitive(question.requestId), "requestDigest" to JsonPrimitive(question.requestDigest),
                    "questionID" to JsonPrimitive(question.questionId), "runID" to JsonPrimitive(question.runId),
                    "expectedRevision" to JsonPrimitive(question.revision), "answerNonce" to JsonPrimitive(question.answerNonce),
                    "source" to JsonPrimitive("human"), "selectedOptionIDs" to JsonArray(listOf(JsonPrimitive("allow"))),
                    "freeText" to JsonNull))
                host.trackOperation(HostCommandRequest(command = "question.answer",
                    scope = HostScope.ConversationLifecycle(conversation), stateful = false,
                    correlationID = "phone-pause-answer-${UUID.randomUUID()}", payload = payload)) { answer ->
                    if (closed || phoneControlRevision.get() != revision || controlOwner() != owner || !isOwnerRunLive(owner)) return@trackOperation
                    val receipt = (answer as? HostOperationOutcome.Completed)?.value?.let(UserQuestionWire::decodeReceipt)
                    if (receipt?.accepted != true && receipt?.alreadySettled != true) resumeFailed()
                }
            }
        }
    }

    private fun stopActiveTask(takeOver: Boolean, expectedOwner: PhoneControlOwner? = null) {
        if (busy != DeviceAccessBusyUi.NONE && expectedOwner == null) return
        val owner = expectedOwner ?: armedOwner ?: armingOwner ?: currentCandidate()?.owner ?: return
        if (expectedOwner != null && (!isOwnerRunLive(owner) || controlOwner() != owner)) return
        phoneControlRevision.incrementAndGet()
        explicitResumeOwner = null
        busy = if (takeOver) {
            DeviceAccessBusyUi.TASK_TAKE_OVER
        } else {
            DeviceAccessBusyUi.TASK_STOP
        }
        publish()
        scope.launch(io) {
            // 1) Fence queued/new platform work for the same epoch (the host
            // publishes the reduced availability mask; phone tools disappear
            // from discovery until a fresh USER arm).
            userStopped = true
            phonePause.snapshot?.takeIf { it.owner == owner }?.let { phonePause.resume(owner, it.id, ::clearPersistedPause) }
            automationControls.clear()
            lastStoppedOwner = owner
            stoppedOwnerSettled = false
            armedOwner = null
            recentOwner = owner
            // An actual Stop/Takeover ends BOTH screen-share modes, including
            // the broader "Until stopped"; a later task must ask again.
            screenShare.clear()
            // Publish the reduced availability mask first (fences queued
            // dispatch), then cancel the real in-flight backend operation.
            publish()
            pump?.cancelInFlight()
            // 2) Stop/take over the REAL phone session and cancel the run.
            runCatching { if (takeOver) phoneClient?.takeover() else phoneClient?.stop() }
            runCatching {
                host.conversations.cancelRunFromNotification(
                    owner.taskID.toString(), owner.runID.toString())
            }
            busy = DeviceAccessBusyUi.NONE
            publish()
        }
    }

    // ---------------------------------------------------------------- ADB flow

    /**
     * The existing Application-owned API 37 ACCESS_LOCAL_NETWORK lane
     * (`RuntimeHost.integrations.localNetwork`, mounted once by
     * `LocalNetworkPermissionEffect`). Pairing discovery and the local
     * loopback connection are explicit user actions, so they use that broker
     * instead of a second permission system. A numeric port never bypasses a
     * required grant: if the permission is denied, the action reports it.
     */
    private fun withLocalPairingPermission(
        owner: String,
        onDenied: (String) -> Unit,
        isCurrent: () -> Boolean = { !closed },
        dispatch: () -> Unit,
    ): Boolean {
        if (Build.VERSION.SDK_INT < LOCAL_NETWORK_API) {
            dispatch()
            return true
        }
        return try {
            host.integrations.localNetwork.runExplicitAction(
                ownerID = owner,
                endpoint = LOCAL_PAIRING_ENDPOINT,
                isCurrent = isCurrent,
                onDenied = onDenied,
                dispatch = dispatch,
            )
        } catch (_: Throwable) {
            // Never silently open a local socket when the existing lane cannot
            // be consulted; pairing stays unavailable and actionable.
            onDenied("local_network_unavailable")
            false
        }
    }

    private fun localNetworkBlocked(): Boolean = try {
        host.integrations.localNetwork.blocksConnectHop(LOCAL_PAIRING_ENDPOINT)
    } catch (_: Throwable) {
        false
    }

    private fun onLocalNetworkDenied(code: String) {
        busy = DeviceAccessBusyUi.NONE
        error = DeviceAccessUiError(
            context.getString(R.string.device_access_error_local_network), code)
        publish()
    }

    private fun onPairingLocalNetworkDenied(code: String) {
        val submitting = pendingPairingCode != null
        wipePendingPairingCode()
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.UNAVAILABLE
        onLocalNetworkDenied(code)
        // A notification reply that could not dispatch keeps one actionable
        // retry token; opening/discovering the dialog does not post a useless
        // notification.
        if (submitting && pairingSessionOpen && !closed) {
            PairingForegroundService.stop(context)
            reissuePairingNotification(
                R.string.device_access_pairing_notification_retry)
        }
        if (submitting) finishPairingReplyHandoff()
    }

    private fun wipePendingPairingCode() {
        pendingPairingCode?.fill('\u0000')
        pendingPairingCode = null
    }

    /**
     * Closes the ONE live pairing flow and invalidates its notification token.
     * Cancel, success, forget, host close, root stop and process start all use
     * this exact boundary; no stale notification can revive an old session.
     */
    private fun closePairingSession() {
        pairingSessionOpen = false
        pairingJob?.cancel()
        pairingJob = null
        discoveredPairingPort = null
        pairingPortInput = ""
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
        wipePendingPairingCode()
        pairingNotification.close()
        cancelPairingNotification()
        PairingForegroundService.stop(context)
        finishPairingReplyHandoff()
    }

    private fun finishPairingReplyHandoff() {
        val done = pairingReplyCompletion
        pairingReplyCompletion = null
        runCatching { done?.invoke() }
    }

    private fun enableAdb() {
        if (busy != DeviceAccessBusyUi.NONE) return
        settings = settings.copy(adbEnabled = true)
        persist()
        error = null
        scope.launch(io) {
            refreshControllerStatus()
            publish()
        }
    }

    private fun openPairing() {
        if (busy != DeviceAccessBusyUi.NONE) return
        // Wireless debugging pairing exists only on API 30+. API 28/29 keeps
        // the existing USB bootstrap path and never advertises this flow.
        if (!pairingSupported() || Build.VERSION.SDK_INT < 30) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_pairing_unsupported),
                "pairing_requires_api30",
            )
            publish()
            return
        }
        // A new explicit user action replaces any previous session/token.
        closePairingSession()
        pairingSessionOpen = true
        error = null
        pairingNotification.open()
        postPairingNotification()
        publish()
        val started = withLocalPairingPermission(
            owner = "adb-pairing-open",
            onDenied = ::onPairingLocalNetworkDenied,
        ) {
            // Only open the Android screen after any required local-network
            // grant is settled; the pairing flow never starts half-authorized.
            // A late permission result after Cancel must not revive it.
            if (pairingSessionOpen && !closed) {
                openDeveloperOptions()
                launchPairingDiscovery()
            }
        }
        if (!started && !closed) {
            pairingDiscovery = DeviceAccessPairingDiscoveryUi.UNAVAILABLE
            publish()
        }
    }

    private fun discoverPairingPort() {
        if (busy == DeviceAccessBusyUi.PAIRING) return
        error = null
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.DISCOVERING
        publish()
        val started = withLocalPairingPermission(
            owner = "adb-pairing-port",
            onDenied = ::onPairingLocalNetworkDenied,
        ) {
            if (pairingSessionOpen && !closed) launchPairingDiscovery()
        }
        if (!started && !closed) {
            pairingDiscovery = DeviceAccessPairingDiscoveryUi.UNAVAILABLE
            publish()
        }
    }

    private fun launchPairingDiscovery() {
        pairingJob?.cancel()
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.DISCOVERING
        publish()
        pairingJob = scope.launch(io) {
            val port = AdbPairingPortDiscovery.findPairingPort(context)
            if (closed || !pairingSessionOpen) return@launch
            // Discovery never reissues the notification token: the user may
            // be typing in the current RemoteInput, and a live port refresh
            // must not replace the action under their draft.
            discoveredPairingPort = port
            pairingDiscovery = if (port != null) {
                DeviceAccessPairingDiscoveryUi.FOUND
            } else {
                DeviceAccessPairingDiscoveryUi.UNAVAILABLE
            }
            publish()
        }
    }

    private suspend fun discoverPairingPortInternal() {
        val port = AdbPairingPortDiscovery.findPairingPort(context)
        if (closed || !pairingSessionOpen) return
        // Same rule as launchPairingDiscovery: never invalidate a RemoteInput
        // draft just because the bounded NSD lookup finished.
        discoveredPairingPort = port
        pairingDiscovery = if (port != null) {
            DeviceAccessPairingDiscoveryUi.FOUND
        } else {
            DeviceAccessPairingDiscoveryUi.UNAVAILABLE
        }
    }

    private fun exportUsbBootstrap() {
        if (busy != DeviceAccessBusyUi.NONE) return
        val controller = rootController ?: run {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_unavailable), "controller_unbound")
            publish()
            return
        }
        busy = DeviceAccessBusyUi.STARTING
        error = null
        usbBootstrapExported = false
        publish()
        scope.launch(io) {
            try {
                when (val result = controller.usbBootstrap()) {
                    is RootResult.Ok -> {
                        val command = result.value.adbShellCommand
                        if (host.copyToClipboard(command)) {
                            usbBootstrapExported = true
                            error = null
                        } else {
                            error = DeviceAccessUiError(
                                context.getString(R.string.device_access_error_unavailable),
                                "clipboard",
                            )
                        }
                    }
                    is RootResult.Denied -> error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_backend_failed), result.code)
                    is RootResult.Unavailable -> error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_unavailable), result.code)
                    is RootResult.Failed -> error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_backend_failed), result.code)
                }
            } catch (_: Throwable) {
                error = DeviceAccessUiError(
                    context.getString(R.string.device_access_error_unavailable), "usb_bootstrap")
            } finally {
                busy = DeviceAccessBusyUi.NONE
                publish()
            }
        }
    }

    private fun submitPairingCode(code: String) {
        if (busy != DeviceAccessBusyUi.NONE || pendingPairingCode != null) return
        val controller = rootController
        if (controller == null) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_unavailable), "controller_unbound")
            publish()
            return
        }
        // The freshly discovered pairing port always wins over a stale manual
        // fallback. A notification Intent never carries a port.
        val port = PairingNotificationPolicy.selectPairingPort(
            discoveredPairingPort, pairingPortInput)
        if (port == null) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_pairing_port), "pairing_port")
            publish()
            return
        }
        wipePendingPairingCode()
        val chars = code.toCharArray()
        pendingPairingCode = chars
        cancelPairingNotification()
        busy = DeviceAccessBusyUi.PAIRING
        error = null
        publish()
        val sessionEpoch = pairingNotification.currentEpoch()
        val started = withLocalPairingPermission(
            owner = "adb-pairing-submit",
            onDenied = ::onPairingLocalNetworkDenied,
            isCurrent = {
                !closed && pairingSessionOpen &&
                    (sessionEpoch == null ||
                        pairingNotification.currentEpoch() == sessionEpoch)
            },
        ) {
            startPairing(controller, port)
        }
        if (!started && !closed) {
            wipePendingPairingCode()
            busy = DeviceAccessBusyUi.NONE
            publish()
        }
    }

    private fun startPairing(controller: RootSystemController, port: Int) {
        scope.launch(io) { performPairing(controller, port) }
    }

    /**
     * Notification replies may arrive after the initial bounded discovery ran
     * while the user was still opening Android's pairing dialog. Refresh the
     * own-device PAIRING port exactly once at submission time, then pair. If
     * it is still unavailable the user gets an actionable retry notification
     * instead of an endless scan or a guessed port.
     */
    private fun startPairingWithPortRefresh(controller: RootSystemController) {
        scope.launch(io) {
            val chars = pendingPairingCode
            if (chars == null) {
                PairingForegroundService.stop(context)
                busy = DeviceAccessBusyUi.NONE
                publish()
                finishPairingReplyHandoff()
                return@launch
            }
            var port = PairingNotificationPolicy.selectPairingPort(
                discoveredPairingPort, pairingPortInput)
            if (port == null) {
                val found = AdbPairingPortDiscovery.findPairingPort(context)
                if (closed || !pairingSessionOpen) {
                    wipePendingPairingCode()
                    PairingForegroundService.stop(context)
                    busy = DeviceAccessBusyUi.NONE
                    publish()
                    finishPairingReplyHandoff()
                    return@launch
                }
                discoveredPairingPort = found
                pairingDiscovery = if (found != null) {
                    DeviceAccessPairingDiscoveryUi.FOUND
                } else {
                    DeviceAccessPairingDiscoveryUi.UNAVAILABLE
                }
                publish()
                port = found
            }
            if (port == null) {
                wipePendingPairingCode()
                error = DeviceAccessUiError(
                    context.getString(R.string.device_access_error_pairing_port), "pairing_port")
                busy = DeviceAccessBusyUi.NONE
                PairingForegroundService.stop(context)
                publish()
                if (pairingSessionOpen && !closed) {
                    reissuePairingNotification(
                        R.string.device_access_pairing_notification_retry)
                }
                finishPairingReplyHandoff()
                return@launch
            }
            performPairing(controller, port)
        }
    }

    private suspend fun performPairing(controller: RootSystemController, port: Int) {
        val chars = pendingPairingCode
        if (chars == null) {
            PairingForegroundService.stop(context)
            busy = DeviceAccessBusyUi.NONE
            publish()
            finishPairingReplyHandoff()
            return
        }
        var retryNotification = false
        // A timeout/transport failure may mean this dialog advertised a NEW
        // ephemeral pairing port. Clear the cached one so the retry performs
        // one fresh bounded discovery instead of repeating a stale port.
        var refreshPortOnRetry = false
        try {
            val result = controller.pair(port, chars)
            // Cancel/close/root-stop during the handshake owns the final UI;
            // a late failure never resurrects an error or a notification.
            val keepSession = !closed && pairingSessionOpen
            when (result) {
                PairingResult.Success -> {
                    closePairingSession()
                    error = null
                }
                PairingResult.InvalidCode -> if (keepSession) {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_code), "invalid_code")
                    retryNotification = true
                }
                PairingResult.Timeout -> if (keepSession) {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_timeout), "timeout")
                    retryNotification = true
                    refreshPortOnRetry = true
                }
                is PairingResult.Unsupported -> if (keepSession) {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_unsupported), result.code)
                }
                is PairingResult.Failed -> if (keepSession) {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_failed), result.code)
                    retryNotification = true
                    refreshPortOnRetry = true
                }
            }
        } catch (_: Throwable) {
            if (!closed && pairingSessionOpen) {
                error = DeviceAccessUiError(
                    context.getString(R.string.device_access_error_pairing_failed), "pair")
                retryNotification = true
                refreshPortOnRetry = true
            }
        } finally {
            wipePendingPairingCode()
            if (refreshPortOnRetry && !closed && pairingSessionOpen) {
                discoveredPairingPort = null
                pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
            }
            refreshControllerStatus()
            busy = DeviceAccessBusyUi.NONE
            publish()
            tryRebuildRootController()
            PairingForegroundService.stop(context)
            if (retryNotification && pairingSessionOpen && !closed) {
                reissuePairingNotification(
                    R.string.device_access_pairing_notification_retry)
            }
            finishPairingReplyHandoff()
        }
    }

    /**
     * Manifest receiver entry. The token is checked and consumed before any
     * controller/network work; only the CURRENT open session can proceed.
     */
    internal fun onPairingNotificationReply(
        nonce: String?,
        epoch: Long,
        generation: Long,
        code: CharArray?,
        onFinished: (() -> Unit)? = null,
    ): Boolean {
        if (closed) {
            code?.fill('\u0000')
            cancelPairingNotification()
            onFinished?.invoke()
            return false
        }
        val sessionEpoch = pairingNotification.currentEpoch()
        when (pairingNotification.authorize(nonce, epoch, generation, code)) {
            PairingNotificationPolicy.Decision.STALE -> {
                code?.fill('\u0000')
                // An older PendingIntent must not dismiss a newer session's
                // live notification. Only remove an orphan after close.
                if (!pairingSessionOpen || !pairingNotification.isOpen()) {
                    cancelPairingNotification()
                }
                onFinished?.invoke()
                // Handled rejection: do not let the receiver cancel the
                // current notification as though no live host existed.
                return true
            }
            PairingNotificationPolicy.Decision.EXPIRED -> {
                code?.fill('\u0000')
                reissuePairingNotification(
                    R.string.device_access_pairing_notification_retry)
                onFinished?.invoke()
                return true
            }
            PairingNotificationPolicy.Decision.INVALID_CODE -> {
                code?.fill('\u0000')
                reissuePairingNotification(
                    R.string.device_access_pairing_notification_invalid)
                onFinished?.invoke()
                return true
            }
            PairingNotificationPolicy.Decision.ACCEPTED -> Unit
        }
        val chars = code
        if (chars == null) {
            cancelPairingNotification()
            onFinished?.invoke()
            return false
        }
        if (!pairingSessionOpen) {
            chars.fill('\u0000')
            cancelPairingNotification()
            onFinished?.invoke()
            return false
        }
        if (busy != DeviceAccessBusyUi.NONE) {
            chars.fill('\u0000')
            // A concurrent real pairing owns the controller; the reply is
            // stale. Any other busy state may be retried by the user.
            if (busy == DeviceAccessBusyUi.PAIRING) {
                cancelPairingNotification()
            } else {
                reissuePairingNotification(
                    R.string.device_access_pairing_notification_retry)
            }
            onFinished?.invoke()
            return false
        }
        val controller = rootController
        if (controller == null) {
            chars.fill('\u0000')
            closePairingSession()
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_unavailable), "controller_unbound")
            publish()
            onFinished?.invoke()
            return false
        }
        // The token is consumed and the host takes its OWN copy. The receiver
        // can wipe its array and finish goAsync immediately; the FGS below is
        // the bounded process-lifetime owner for the real handshake.
        val owned = chars.copyOf()
        chars.fill('\u0000')
        pairingReplyCompletion = onFinished
        cancelPairingNotification()
        wipePendingPairingCode()
        pendingPairingCode = owned
        PairingForegroundService.start(context)
        busy = DeviceAccessBusyUi.PAIRING
        error = null
        publish()
        val started = withLocalPairingPermission(
            owner = "adb-pairing-notification",
            onDenied = ::onPairingLocalNetworkDenied,
            isCurrent = {
                !closed && pairingSessionOpen &&
                    sessionEpoch != null &&
                    pairingNotification.currentEpoch() == sessionEpoch
            },
        ) {
            startPairingWithPortRefresh(controller)
        }
        if (!started) {
            // A denied-forever broker already stopped/reissued above; avoid a
            // second post for the same failed submission. Even a close/root
            // stop racing this reply must finish the receiver handoff.
            val hadPendingReply = pendingPairingCode != null
            wipePendingPairingCode()
            PairingForegroundService.stop(context)
            busy = DeviceAccessBusyUi.NONE
            publish()
            if (!closed && hadPendingReply && pairingSessionOpen) {
                reissuePairingNotification(
                    R.string.device_access_pairing_notification_retry)
            }
            finishPairingReplyHandoff()
        }
        return true
    }

    private fun cancelPairing() {
        closePairingSession()
        if (busy == DeviceAccessBusyUi.PAIRING) busy = DeviceAccessBusyUi.NONE
        publish()
        scope.launch(io) {
            runCatching { rootController?.cancelPairing() }
            refreshControllerStatus()
            publish()
        }
    }

    private fun startAdbService() {
        if (busy != DeviceAccessBusyUi.NONE) return
        busy = DeviceAccessBusyUi.STARTING
        error = null
        publish()
        // Starting the embedded ADB service opens a real local ADB socket.
        // It uses the same API 37 local-network lane as MCP/provider connects.
        val started = withLocalPairingPermission(
            owner = "adb-service-start",
            onDenied = { code ->
                busy = DeviceAccessBusyUi.NONE
                error = DeviceAccessUiError(context.getString(R.string.device_access_error_local_network),
                    code, DeviceAccessErrorSectionUi.ADB)
                publish()
            },
        ) {
            scope.launch(io) {
                try {
                    val result = rootController?.startAdbService()
                        ?: AccessActionResult.Unavailable("controller_unbound")
                    applyAccessResult(result, DeviceAccessErrorSectionUi.ADB)
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    applyAccessResult(AccessActionResult.Failed("adb_start"), DeviceAccessErrorSectionUi.ADB)
                } finally {
                    refreshControllerStatus()
                    busy = DeviceAccessBusyUi.NONE
                    publish()
                    tryRebuildRootController()
                }
            }
        }
        if (!started && !closed) {
            busy = DeviceAccessBusyUi.NONE
            publish()
        }
    }

    private fun stopAdbService() {
        runBackendAction(DeviceAccessBusyUi.STOPPING) {
            val result = rootController?.stopAdbService()
            if (result != null) applyAccessResult(result)
        }
    }

    private fun forgetPairing() {
        closePairingSession()
        runBackendAction(DeviceAccessBusyUi.FORGETTING) {
            val controller = rootController
            if (controller != null) {
                runCatching { controller.stopAdbService() }
                runCatching { controller.forgetPairing() }
                    .onFailure {
                        error = DeviceAccessUiError(
                            context.getString(R.string.device_access_error_forget), "forget")
                    }
            }
        }
    }

    private fun checkRootGrant() {
        // No read-only root probe exists in the current public contract; the
        // page asks the user to confirm that this explicit action may enable
        // an EXISTING root grant. Floe never roots the device itself.
        runBackendAction(DeviceAccessBusyUi.ROOT_CHECK) {
            val controller = rootController ?: return@runBackendAction
            val result = controller.setRootEnabled(true)
            if (result is AccessActionResult.Ok) return@runBackendAction
            when (result) {
                is AccessActionResult.Denied -> {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_root_not_granted), result.code)
                }
                is AccessActionResult.Unavailable -> {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_unavailable), result.code)
                }
                is AccessActionResult.Failed -> {
                    error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_root_failed), result.code)
                }
                AccessActionResult.Ok -> Unit
            }
        }
    }

    private fun setRootEnabled(enabled: Boolean) {
        runBackendAction(
            if (enabled) DeviceAccessBusyUi.ROOT_ENABLE else DeviceAccessBusyUi.ROOT_CHECK,
        ) {
            val controller = rootController ?: return@runBackendAction
            val result = controller.setRootEnabled(enabled)
            if (result !is AccessActionResult.Ok) applyAccessResult(result)
        }
    }

    private fun runBackendAction(tag: DeviceAccessBusyUi, block: suspend () -> Unit) {
        if (busy != DeviceAccessBusyUi.NONE) return
        busy = tag
        error = null
        publish()
        scope.launch(io) {
            try {
                block()
            } catch (_: Throwable) {
                error = DeviceAccessUiError(
                    context.getString(R.string.device_access_error_unavailable), "backend")
            } finally {
                refreshControllerStatus()
                busy = DeviceAccessBusyUi.NONE
                publish()
                tryRebuildRootController()
            }
        }
    }

    private fun applyAccessResult(
        result: AccessActionResult,
        section: DeviceAccessErrorSectionUi = DeviceAccessErrorSectionUi.GENERAL,
    ) {
        if (section == DeviceAccessErrorSectionUi.ADB && result !is AccessActionResult.Ok) {
            val code = when (result) {
                is AccessActionResult.Denied -> result.code
                is AccessActionResult.Unavailable -> result.code
                is AccessActionResult.Failed -> result.code
                AccessActionResult.Ok -> return
            }
            error = DeviceAccessUiError(
                context.getString(DeviceAccessPresentation.adbStartFailureRes(code)), code, section)
            return
        }
        when (result) {
            AccessActionResult.Ok -> error = null
            is AccessActionResult.Denied -> error = DeviceAccessUiError(
                denialMessageForCode(result.code), result.code)
            is AccessActionResult.Unavailable -> error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_unavailable), result.code)
            is AccessActionResult.Failed -> error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_backend_failed), result.code)
        }
    }

    // ------------------------------------------------------------ pairing notice

    /**
     * Posts the ONE active inline-code notification. Availability is checked
     * explicitly first (API 33+ POST_NOTIFICATIONS and the pairing channel),
     * so a disabled notification surface is reported by the settings page
     * instead of being swallowed by a catch around notify().
     */
    private fun postPairingNotification(
        textRes: Int = R.string.device_access_pairing_notification_text,
    ): Boolean {
        if (closed || !pairingSessionOpen) return false
        val token = pairingNotification.currentToken() ?: return false
        PairingNotificationAccess.ensureChannel(context) ?: return false
        if (PairingNotificationAccess.availability(context) !=
            PairingNotificationPolicy.Availability.AVAILABLE
        ) {
            return false
        }
        return try {
            val contentIntent = Intent(context, com.floe.android.MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val contentPending = PendingIntent.getActivity(
                context,
                PairingNotificationPolicy.NOTIFICATION_ID,
                contentIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            // Explicit component + a fresh requestCode per token. The mutable
            // flag is required ONLY so the platform can attach RemoteInput
            // results; there is no implicit intent another app could target.
            val replyIntent = Intent(context, PairingCodeReceiver::class.java)
                .setAction(PairingNotificationPolicy.ACTION_REPLY)
                .putExtra(PairingNotificationPolicy.EXTRA_NONCE, token.nonce)
                .putExtra(PairingNotificationPolicy.EXTRA_EPOCH, token.epoch)
                .putExtra(PairingNotificationPolicy.EXTRA_GENERATION, token.generation)
            val mutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
            val replyPending = PendingIntent.getBroadcast(
                context,
                token.requestCode,
                replyIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag,
            )
            val remoteInput = RemoteInput.Builder(PairingNotificationPolicy.KEY_CODE)
                .setLabel(context.getString(R.string.device_access_adb_code_label))
                .build()
            val builder = NotificationCompat.Builder(
                context, PairingNotificationPolicy.CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(
                    context.getString(R.string.device_access_pairing_notification_title))
                .setContentText(context.getString(textRes))
                .setContentIntent(contentPending)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .setTimeoutAfter(PairingNotificationSession.TOKEN_LIFETIME_MILLIS)
                .addAction(
                    NotificationCompat.Action.Builder(
                        0,
                        context.getString(
                            R.string.device_access_pairing_notification_action),
                        replyPending,
                    )
                        .addRemoteInput(remoteInput)
                        .setAllowGeneratedReplies(false)
                        .setSemanticAction(
                            NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
                        .build(),
                )
            NotificationManagerCompat.from(context)
                .notify(PairingNotificationPolicy.NOTIFICATION_ID, builder.build())
            true
        } catch (_: Throwable) {
            // Unexpected platform failure: the page's explicit availability
            // row remains the actionable surface; pairing itself is unchanged.
            false
        }
    }

    /** Replaces the consumed/failed token and updates the notification in place. */
    private fun reissuePairingNotification(textRes: Int) {
        if (closed || !pairingSessionOpen) return
        pairingNotification.reissue() ?: return
        postPairingNotification(textRes)
    }

    private fun cancelPairingNotification() {
        runCatching {
            NotificationManagerCompat.from(context)
                .cancel(PairingNotificationPolicy.NOTIFICATION_ID)
        }
    }

    // -------------------------------------------------------------- availability

    private fun systemServiceAlive(): Boolean =
        (settings.adbEnabled && adbStatus is AdbStatus.ServiceAlive) ||
            rootStatus is RootStatus.Enabled

    private fun phoneServiceUsable(status: PhoneControlStatus = phoneStatus): Boolean {
        if (!status.connected || !status.enabled) return false
        return when (status.blocker) {
            PhoneControlBlocker.STOPPED,
            PhoneControlBlocker.TAKEN_OVER,
            PhoneControlBlocker.SERVICE_REVOKED,
            PhoneControlBlocker.SERVICE_DISCONNECTED,
            -> false
            else -> true
        }
    }

    private fun availableToolNames(): Set<String> {
        val state = mutablePresentation.value
        return DeviceAccessToolCatalog.availableNames(
            DeviceAccessToolCatalog.Availability(
                accessibilityConnected = phoneServiceUsable(),
                targetPackagesSelected = state.targets.selectedPackages.isNotEmpty(),
                // Potential capability only: mirrors
                // PhoneControlPolicy.screenshotSupport (display capture on
                // API 30+, the preferred window capture on API 34+). The
                // task's live screen scope, arm and whole-screen consent are
                // checked by phoneScreenshot at invocation, so granting them
                // while a run is live never changes this run's offer.
                screenCaptureSupported = Build.VERSION.SDK_INT >= 30,
                systemServiceAlive = systemServiceAlive(),
                fileRootsSelected = effectiveSelectedRoots().isNotEmpty(),
                fileWritesAllowed = state.targets.fileWritesAllowed,
                packageManagementAllowed = state.targets.packageManagementAllowed,
                advancedSystemManagementAllowed = settings.advancedSystemManagementAllowed,
                advancedSystemAllowedTools = settings.advancedSystemAllowedTools,
                advancedSystemTargetsSelected = settings.advancedSystemTargets.isNotEmpty(),
            ),
        )
    }

    /**
     * Durable ordinary-automatic ceiling snapshot for the CURRENT settings,
     * published alongside availability for the same epoch. The Swift
     * approval pipeline consumes it BEFORE dispatch: it is the trusted-host
     * proof of which mutating platform tools may receive a real bound
     * approval grant without the interactive hard gate. Closed key set and
     * bounded values; root ids are catalog tokens, never user text.
     */
    private fun autoAdmissionJson(): String {
        val state = mutablePresentation.value
        // Catalog root ids are host-issued tokens: alnum/_/- plus the stable
        // "appdata:<16lowhex>" form (see FileRootCatalog.appDataId). Dropping
        // the colon silently removed real user-selected writable Root folders.
        val rootIds = effectiveSelectedRoots()
            .filter { it.writable }
            .map { it.id }
            .filter {
                it.length in 1..64 && it.all { ch ->
                    ch.isLetterOrDigit() || ch == '_' || ch == '-' || ch == ':'
                }
            }
            .take(32)
        val advancedTools = advancedToolsForAdmission()
        return buildString {
            append("{\"version\":1")
            append(",\"packageManagement\":").append(state.targets.packageManagementAllowed)
            append(",\"fileWrites\":").append(state.targets.fileWritesAllowed)
            append(",\"fileRootIds\":[")
            append(rootIds.joinToString(",") { "\"" + it + "\"" })
            append("]")
            // Emitted only when non-empty: the canonical side treats absent
            // as the default empty list. Only names that are BOTH user-allowed
            // and actually available in the bound catalog are published.
            if (advancedTools.isNotEmpty()) {
                append(",\"advancedTools\":[")
                append(advancedTools.joinToString(",") { "\"" + it + "\"" })
                append("]")
            }
            append("}")
        }
    }

    /**
     * Advanced tool names eligible for the trusted same-epoch admission
     * snapshot: the shared master and the base management ceiling on, the
     * name user-allowed, and the name actually published in the frozen
     * availability set for this epoch. The three reserved ABI names can
     * never appear here (they are never stored or advertised).
     */
    private fun advancedToolsForAdmission(): List<String> {
        if (!settings.advancedSystemManagementAllowed) return emptyList()
        if (!settings.packageManagementAllowed) return emptyList()
        val available = availableToolNames()
        return settings.advancedSystemAllowedTools
            .filter { it in available }
            .filter { it in DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS }
    }

    // ------------------------------------------------------------ phone authority

    private fun authorizePhone(principal: PhoneControlPrincipal): PhoneControlGrant? {
        if (closed) return null
        if (pauseStateInvalid || phonePause.isPaused(principal.owner)) return null
        val epoch = host.nativeRootEpoch() ?: return null
        if (principal.epoch != epoch) return null
        val packages = settings.allowedPackages
        if (packages.isEmpty() || principal.allowedPackages != packages) return null
        val liveOwner = armedOwner
        val armRequest = armingOwner
        if (principal.owner != liveOwner && principal.owner != armRequest) return null
        if (userStopped && principal.owner != armRequest) return null
        val binding = principal.callID?.let { phoneBindings[it] }
        if (binding != null) {
            if (binding.owner != principal.owner || binding.call.epoch != principal.epoch) return null
            if (!PlatformToolsNativeLive.isLive(binding.call.claim)) return null
            if (PlatformToolsNativeLive.shouldStop(binding.call.claim)) return null
        } else if (principal.callID != null) {
            return null
        }
        return PhoneControlGrant(
            owner = principal.owner,
            epoch = principal.epoch,
            allowedPackages = packages,
            allowGlobalNavigation = true,
            allowScreenshot = screenshotCeiling(principal.owner, principal.epoch),
            generation = principal.generation,
            grantID = principal.grantID,
        )
    }

    /**
     * Screen content ceiling for the EXACT call owner and epoch. There is no
     * global/persistent fallback: a missing binding, a different owner, a
     * terminal run for "This task", a new epoch or a revoked session denies.
     * Display capture additionally requires the separate whole-screen consent
     * in the tool handler; window capture does not.
     */
    private fun screenshotCeiling(owner: PhoneControlOwner, epoch: Long): Boolean =
        screenShare.allows(owner, epoch, ownerRunLive = isOwnerRunLive(owner))

    // -------------------------------------------------------------- tool entry

    private suspend fun executeTool(call: PlatformToolCall): PlatformToolOutcome {
        val revision = phoneControlRevision.get()
        val outcome = when (call.tool) {
            DeviceAccessToolCatalog.DEVICE_OBSERVE -> deviceObserve(call)
            DeviceAccessToolCatalog.DEVICE_ACT -> deviceAct(call)
            DeviceAccessToolCatalog.DEVICE_SCREENSHOT -> deviceScreenshot(call)
            DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS -> systemStatus()
            DeviceAccessToolCatalog.SYSTEM_FILES_LIST -> systemFilesList(call)
            DeviceAccessToolCatalog.SYSTEM_FILES_READ -> systemFilesRead(call)
            DeviceAccessToolCatalog.SYSTEM_FILES_WRITE -> systemFilesWrite(call)
            DeviceAccessToolCatalog.SYSTEM_FILES_MOVE -> systemFilesMove(call)
            DeviceAccessToolCatalog.SYSTEM_FILES_DELETE -> systemFilesDelete(call)
            DeviceAccessToolCatalog.SYSTEM_PROCESSES_QUERY -> systemProcessQuery(call)
            DeviceAccessToolCatalog.SYSTEM_SERVICES_QUERY -> systemServiceQuery(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_QUERY -> systemPackageQuery(call)
            DeviceAccessToolCatalog.SYSTEM_NETWORK_DIAGNOSTICS -> systemNetworkDiagnostics(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_FORCE_STOP -> systemForceStop(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_STAGED -> systemPackagesStaged()
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_STAGE -> systemPackagesStage(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_INSTALL -> systemPackagesInstall(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_UNINSTALL -> systemPackagesUninstall(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED -> systemPackagesSetEnabled(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_REMOVE_FOR_USER -> systemPackagesRemoveForUser(call)
            DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE -> systemPackagesRestore(call)
            DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_QUERY -> systemPermissionsQuery(call)
            DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE -> systemPermissionsManage(call)
            DeviceAccessToolCatalog.SYSTEM_APPOPS_QUERY -> systemAppOpsQuery(call)
            DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE -> systemAppOpsManage(call)
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_READ -> systemSettingsRead(call)
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE -> systemSettingsWrite(call)
            else -> PlatformToolOutcome.Failure("unknown_tool")
        }
        // The pause/interruption fence covers the device-interaction tools by
        // their canonical wire names (the shared Swift mailbox resolves the
        // bounded legacy phone.* spellings BEFORE a ticket reaches this host,
        // so old names never arrive here; the check below is exact-name, not
        // a prefix rule, and never widens to unknown phone.* tools).
        if (call.tool in DeviceAccessToolCatalog.DEVICE_INTERACTION_NAMES)
            pausedPhoneOutcome(call)?.let { return it }
        if (call.tool in DeviceAccessToolCatalog.DEVICE_INTERACTION_NAMES &&
            revision != phoneControlRevision.get())
            return PlatformToolOutcome.Failure("phone_interrupted", "Observe the current screen before continuing device actions.")
        return outcome
    }

    // ----------------------------------------------------------- device tools

    private fun ownerOf(call: PlatformToolCall) =
        PhoneControlOwner(call.taskID, call.runID)

    private fun pausedPhoneOutcome(call: PlatformToolCall): PlatformToolOutcome? {
        val pause = phonePause.snapshot?.takeIf { it.owner == ownerOf(call) } ?: return null
        if (!phonePause.bindQuestion(pause.owner, pause.id, call.toolCallID) {
                preferences.edit().putString(KEY_PHONE_PAUSE, it.encode()).commit()
            }) return PlatformToolOutcome.Failure("phone_interrupted", "Open the task to continue phone control.")
        return PlatformToolOutcome.Failure("phone_paused_by_user", pause.id.toString())
    }

    private fun phonePrincipal(call: PlatformToolCall): PhoneControlPrincipal? {
        if (userStopped) return null
        val owner = ownerOf(call)
        if (pauseStateInvalid || phonePause.isPaused(owner)) return null
        if (armedOwner != owner) return null
        val packages = settings.allowedPackages
        if (packages.isEmpty()) return null
        return PhoneControlPrincipal(
            owner = owner,
            epoch = call.epoch,
            allowedPackages = packages,
            generation = call.epoch,
            grantID = call.approvalGrantID,
            callID = phoneBindingKey(call),
        )
    }

    private fun phoneBindingKey(call: PlatformToolCall): String =
        call.toolCallID.ifEmpty { call.idempotencyKey }.ifEmpty { "claim-${call.claim}" }

    private fun bindPhoneCall(call: PlatformToolCall) {
        phoneBindings[phoneBindingKey(call)] = PhoneCallBinding(call, ownerOf(call))
    }

    private fun unbindPhoneCall(call: PlatformToolCall) {
        phoneBindings.remove(phoneBindingKey(call))
    }

    private fun rememberToolTask(call: PlatformToolCall) {
        val owner = ownerOf(call)
        recentOwner = owner
        val candidate = currentCandidate()
        if (candidate?.owner == owner) recentTitle = candidate.title
    }

    /** Admission remains tied to the real platform claim; persisted user consent only
     * replaces the repetitive per-run settings gesture, never canonical tool approval. */
    private suspend fun preparePhoneAutomation(call: PlatformToolCall): PlatformToolOutcome? = automationMutex.withLock {
        val owner = ownerOf(call)
        if (pauseStateInvalid) return@withLock PlatformToolOutcome.Failure("phone_pause_state_unavailable")
        if (phonePause.isPaused(owner)) {
            if (!PlatformToolsNativeLive.isLive(call.claim) || PlatformToolsNativeLive.shouldStop(call.claim))
                return@withLock PlatformToolOutcome.Failure("cancelled")
            if (!userStopped && phonePause.resumeAfterHumanAnswer(owner, call.pauseApprovalID, call.presenceApprovedAtMillis, ::clearPersistedPause)) {
                explicitResumeOwner = owner
            } else {
                automatedOwner.set(owner)
                automationControls.show(owner, titleFor(owner), settings.floatingControls, paused = true)
                return@withLock pausedPhoneOutcome(call) ?: PlatformToolOutcome.Failure("phone_interrupted")
            }
        }
        val client = phoneClient ?: return@withLock null
        if (userStopped) return@withLock null
        if (!PlatformToolsNativeLive.isLive(call.claim) || PlatformToolsNativeLive.shouldStop(call.claim))
            return@withLock PlatformToolOutcome.Failure("cancelled")
        if (settings.allowedPackages.isEmpty() || !phoneServiceUsable()) return@withLock null
        if (phoneStatus.automationFinishing) {
            val settled = withTimeoutOrNull(2_500) {
                PhoneControlModule.status.first { !it.automationFinishing }
            } ?: return@withLock PlatformToolOutcome.Failure("phone_finishing")
            phoneStatus = settled
            if (!PlatformToolsNativeLive.isLive(call.claim) || PlatformToolsNativeLive.shouldStop(call.claim))
                return@withLock PlatformToolOutcome.Failure("cancelled")
        }
        if (armedOwner == owner && phoneStatus.activeOwner == owner) return@withLock null
        if (!settings.automaticPhoneControl && explicitResumeOwner != owner) return@withLock null
        if (phoneStatus.activeOwner != null && phoneStatus.activeOwner != owner)
            return@withLock PlatformToolOutcome.Failure("phone_busy")
        val keyguard = context.getSystemService(KeyguardManager::class.java)
        automationControls.show(owner, titleFor(owner), settings.floatingControls)
        automatedOwner.set(owner)
        if (!keyguard.isKeyguardLocked && client.userIsActive() &&
            call.presenceApprovedAtMillis < client.lastUserInteractionWallMillis()) {
            val token = if (armedOwner == owner) "PRESENCE_RECHECK_SAME_TASK" else "INITIAL_PHONE_PRESENCE_REQUIRED"
            runCatching { android.util.Log.i("FloePhoneUnlock", token) }
            return@withLock PlatformToolOutcome.Failure("phone_presence_required")
        }
        armingOwner = owner
        val armRevision = phoneControlRevision.get()
        bindPhoneCall(call)
        try {
            val principal = PhoneControlPrincipal(owner, call.epoch, settings.allowedPackages,
                generation = call.epoch, grantID = call.approvalGrantID, callID = phoneBindingKey(call))
            if (keyguard.isKeyguardLocked) {
                if (!settings.autoUnlock || !unlockConfigured)
                    return@withLock PlatformToolOutcome.Failure("phone_unlock_required")
                val attemptID = "${owner.taskID}:${owner.runID}"
                val attempts = preferences.getStringSet("unlock_attempted_runs", emptySet()).orEmpty()
                if (attemptID in attempts) return@withLock PlatformToolOutcome.Failure("phone_unlock_needs_user")
                // Commit before any input: process death cannot silently retry a credential.
                if (!preferences.edit().putStringSet("unlock_attempted_runs",
                        (attempts.toList().takeLast(63) + attemptID).toSet()).commit())
                    return@withLock PlatformToolOutcome.Failure("phone_unlock_state_unavailable")
                val stored = unlockCredentials.read("device-lock")
                    ?: return@withLock PlatformToolOutcome.Failure("phone_unlock_required")
                val secret = try { stored.toString(Charsets.UTF_8).toCharArray() } finally { stored.fill(0) }
                runCatching { android.util.Log.i("FloePhoneUnlock", "HOST_UNLOCK_REQUESTED") }
                val result = try {
                    client.unlockForTask(principal, secret) {
                        !closed && !userStopped && automatedOwner.get() == owner && isOwnerRunLive(owner)
                    }
                } finally { secret.fill('\u0000') }
                runCatching { android.util.Log.i("FloePhoneUnlock", "HOST_UNLOCK_RESULT_${result.name}") }
                if (result != PhoneUnlockResult.UNLOCKED && result != PhoneUnlockResult.ALREADY_UNLOCKED)
                    return@withLock PlatformToolOutcome.Failure("phone_unlock_needs_user")
            }
            when (val result = client.arm(principal)) {
                is PhoneControlResult.Ok -> {
                    if (userStopped || phonePause.isPaused(owner) || armRevision != phoneControlRevision.get()) {
                        client.takeover()
                        PlatformToolOutcome.Failure(if (phonePause.isPaused(owner)) "phone_paused_by_user" else "phone_interrupted")
                    } else {
                        armedOwner = owner; explicitResumeOwner = null; phoneStatus = result.value; publish(); null
                    }
                }
                is PhoneControlResult.Denied -> deniedOutcome(result.reason)
                is PhoneControlResult.Unavailable -> unavailableOutcome(result.reason)
                is PhoneControlResult.Failed -> failedOutcome(result)
            }
        } finally { armingOwner = null; unbindPhoneCall(call) }
    }

    private fun phonePrecondition(call: PlatformToolCall, requireApproval: Boolean): PlatformToolOutcome? {
        rememberToolTask(call)
        if (phonePause.isPaused(ownerOf(call))) return PlatformToolOutcome.Failure("phone_paused_by_user")
        val client = phoneClient
        if (client == null || client.isClosed) {
            return PlatformToolOutcome.Failure("phone_unavailable")
        }
        if (!phoneServiceUsable()) {
            return PlatformToolOutcome.Failure("phone_service_not_ready")
        }
        if (userStopped) {
            return PlatformToolOutcome.Failure(
                "phone_stopped_by_user",
                "Phone control was stopped by the user; allow it again in Settings",
            )
        }
        if (armedOwner != ownerOf(call)) {
            publish()
            return PlatformToolOutcome.Failure(
                "phone_arm_required",
                "The user must allow phone control for this task in Settings > Phone",
            )
        }
        if (settings.allowedPackages.isEmpty()) {
            return PlatformToolOutcome.Failure(
                "phone_target_required",
                "No target apps are authorized in Settings > Phone",
            )
        }
        if (requireApproval && call.approvalGrantID == null) {
            return PlatformToolOutcome.Failure("approval_required")
        }
        return null
    }

    private suspend fun deviceObserve(call: PlatformToolCall): PlatformToolOutcome {
        preparePhoneAutomation(call)?.let { return it }
        phonePrecondition(call, requireApproval = false)?.let { return it }
        val client = phoneClient ?: return PlatformToolOutcome.Failure("phone_unavailable")
        val principal = phonePrincipal(call)
            ?: return PlatformToolOutcome.Failure("phone_arm_required")
        bindPhoneCall(call)
        try {
            val request = PhoneControlObserveRequest(
                maxNodes = 100,
                maxDepth = 20,
                includeInvisible = call.arguments.optBoolean("includeInvisible", false),
                textBudgetChars = 8_000,
            )
            return when (val result = withTimeout(20_000) {
                client.observe(principal, request)
            }) {
                is PhoneControlResult.Ok -> {
                    if (userStopped || phonePause.isPaused(ownerOf(call)) || armedOwner != ownerOf(call)) {
                        PlatformToolOutcome.Failure("phone_stopped_by_user")
                    } else {
                        observationOutcome(result.value)
                    }
                }
                is PhoneControlResult.Denied -> deniedOutcome(result.reason)
                is PhoneControlResult.Unavailable -> unavailableOutcome(result.reason)
                is PhoneControlResult.Failed -> failedOutcome(result)
            }
        } catch (_: Throwable) {
            return PlatformToolOutcome.Failure("phone_timeout")
        } finally {
            unbindPhoneCall(call)
        }
    }

    private suspend fun deviceAct(call: PlatformToolCall): PlatformToolOutcome {
        preparePhoneAutomation(call)?.let { return it }
        phonePrecondition(call, requireApproval = true)?.let { return it }
        val client = phoneClient ?: return PlatformToolOutcome.Failure("phone_unavailable")
        val principal = phonePrincipal(call)
            ?: return PlatformToolOutcome.Failure("phone_arm_required")
        val dispatch = when (val request = PhoneActionArguments.request(call.arguments)) {
            is PhoneActionArguments.Request.InvalidArguments ->
                return PlatformToolOutcome.Failure("invalid_arguments")
            is PhoneActionArguments.Request.MissingObservation ->
                // Precise, static and bounded recovery code instead of the
                // undifferentiated invalid_arguments the Alpha72 trace showed:
                // the closed advertised schema cannot express the conditional
                // `required`, so the supported contract enforces it here. The
                // code keeps its historical phone_observation_required
                // spelling (legacy receipts stay readable); the model
                // recovers by calling device.observe again and passing
                // the new observation= id; NO dispatch or device-side effect
                // happens on this path and no argument value is ever echoed.
                return PlatformToolOutcome.Failure(
                    PhoneActionArguments.OBSERVATION_REQUIRED_CODE,
                    "Call device.observe first, then pass its observation id as observationId",
                )
            is PhoneActionArguments.Request.Dispatch -> request
        }
        val action = dispatch.action
        val observationId = dispatch.observationId
        // The credential bytes live only in this dispatch path: the outcome
        // header marks the input as redacted and never includes the payload.
        val sensitiveInput = action is PhoneControlAction.SetText && action.sensitive
        bindPhoneCall(call)
        try {
            return when (val result = withTimeout(20_000) {
                if (action is PhoneControlAction.Launch && observationId.isEmpty())
                    client.launchApplication(principal, action.packageName)
                else client.perform(principal, observationId, action)
            }) {
                is PhoneControlResult.Ok -> {
                    if (userStopped || phonePause.isPaused(ownerOf(call)) || armedOwner != ownerOf(call)) {
                        PlatformToolOutcome.Failure("phone_stopped_by_user")
                    } else {
                        actionOutcome(result.value, sensitiveInput)
                    }
                }
                is PhoneControlResult.Denied -> deniedOutcome(result.reason)
                is PhoneControlResult.Unavailable -> unavailableOutcome(result.reason)
                is PhoneControlResult.Failed -> failedOutcome(result)
            }
        } catch (_: Throwable) {
            return PlatformToolOutcome.Failure("phone_timeout")
        } finally {
            unbindPhoneCall(call)
        }
    }

    private suspend fun deviceScreenshot(call: PlatformToolCall): PlatformToolOutcome {
        preparePhoneAutomation(call)?.let { return it }
        phonePrecondition(call, requireApproval = false)?.let { return it }
        val client = phoneClient ?: return PlatformToolOutcome.Failure("phone_unavailable")
        val principal = phonePrincipal(call)
            ?: return PlatformToolOutcome.Failure("phone_arm_required")
        val owner = ownerOf(call)
        val captureRevision = phoneControlRevision.get()
        val dispatchEpoch = host.nativeRootEpoch()?.takeIf { it > 0 }
            ?: return PlatformToolOutcome.Failure("runtime_not_ready")
        if (dispatchEpoch != call.epoch) {
            return PlatformToolOutcome.Failure("epoch_fenced")
        }
        // Immutable per-dispatch consent ticket. It is checked again BEFORE
        // writing the returned bytes, so a revoke/regrant, whole-screen change
        // or live-epoch change while the async capture is pending cannot
        // publish an image.
        val ticket = screenShare.ticket(
            owner, dispatchEpoch, ownerRunLive = isOwnerRunLive(owner),
        ) ?: return PlatformToolOutcome.Failure(
            "screen_scope_off", "Screen content sharing is off for this task in Settings > Phone")
        val wholeScreenRevision = wholeScreenConsentRevision
        val observationId = call.arguments.optString("observationId").ifEmpty { null }
        if (observationId != null && Build.VERSION.SDK_INT < 34) {
            return PlatformToolOutcome.Failure(
                "window_screenshot_unsupported",
                "Window screenshots need Android 14; no silent display fallback is used",
            )
        }
        val displayCapture = observationId == null
        if (displayCapture && !settings.wholeScreenConsent) {
            return PlatformToolOutcome.Failure(
                "whole_screen_consent_required",
                "The user must allow whole-screen capture in Settings > Phone",
            )
        }
        if (!screenShare.ticketStillValid(
                ticket = ticket,
                owner = owner,
                epoch = dispatchEpoch,
                ownerRunLive = isOwnerRunLive(owner),
                displayCapture = displayCapture,
                wholeScreenConsent = settings.wholeScreenConsent,
                wholeScreenUnchanged = wholeScreenConsentRevision == wholeScreenRevision,
            )
        ) {
            return PlatformToolOutcome.Failure(
                "screen_scope_off", "Screen sharing changed before capture started")
        }
        bindPhoneCall(call)
        try {
            val result = withTimeout(20_000) {
                client.screenshot(
                    principal,
                    observationId,
                    PhoneControlScreenshotRequest(),
                )
            }
            return when (result) {
                is PhoneControlResult.Ok -> {
                    if (userStopped || phonePause.isPaused(owner) || captureRevision != phoneControlRevision.get() || armedOwner != owner) {
                        result.value.bytes.fill(0)
                        return PlatformToolOutcome.Failure("phone_stopped_by_user")
                    }
                    // The native ticket/epoch is the real authority; an
                    // asynchronous binding clear may lag it. Re-read both
                    // before any image can be published.
                    val liveEpoch = host.nativeRootEpoch()?.takeIf { it > 0 }
                    if (liveEpoch == null || liveEpoch != ticket.epoch) {
                        result.value.bytes.fill(0)
                        return PlatformToolOutcome.Failure(
                            "epoch_fenced",
                            "The native epoch changed before the image was stored",
                        )
                    }
                    if (!PlatformToolsNativeLive.isLive(call.claim) ||
                        PlatformToolsNativeLive.shouldStop(call.claim)
                    ) {
                        result.value.bytes.fill(0)
                        return PlatformToolOutcome.Failure(
                            "cancelled",
                            "The screenshot call was fenced before the image was stored",
                        )
                    }
                    val ownerLive = isOwnerRunLive(owner)
                    if (!screenShare.ticketStillValid(
                            ticket = ticket,
                            owner = owner,
                            epoch = liveEpoch,
                            ownerRunLive = ownerLive,
                            displayCapture = displayCapture,
                            wholeScreenConsent = settings.wholeScreenConsent,
                            wholeScreenUnchanged =
                                wholeScreenConsentRevision == wholeScreenRevision,
                        )
                    ) {
                        result.value.bytes.fill(0)
                        val scopeStill = screenShare.allows(owner, liveEpoch, ownerLive)
                        return PlatformToolOutcome.Failure(
                            if (displayCapture && scopeStill && !settings.wholeScreenConsent) {
                                "whole_screen_consent_required"
                            } else {
                                "screen_scope_off"
                            },
                            "Screen sharing consent changed while the screenshot was " +
                                "being captured; the image was discarded",
                        )
                    }
                    val screenshot = result.value
                    try {
                        val root = com.floe.android.swiftbridge.PlatformToolsNative.artifactRootPath()
                        val written = PlatformArtifactWriter.write(
                            root, screenshot.bytes, screenshot.mimeType)
                        when (written) {
                            is PlatformArtifactWriter.Result.Ok -> PlatformToolOutcome.Success(
                                summary = "Captured ${screenshot.width}x${screenshot.height} " +
                                    "${screenshot.mimeType}.",
                                evidence = listOf(
                                    "window=${screenshot.windowId ?: "display"}",
                                    "mode=${if (observationId == null) "display" else "window"}",
                                ),
                                artifact = written.artifact,
                            )
                            is PlatformArtifactWriter.Result.Failed ->
                                PlatformToolOutcome.Failure("artifact_store_failed", written.code)
                        }
                    } finally {
                        screenshot.bytes.fill(0)
                    }
                }
                is PhoneControlResult.Denied -> deniedOutcome(result.reason)
                is PhoneControlResult.Unavailable -> unavailableOutcome(result.reason)
                is PhoneControlResult.Failed -> failedOutcome(result)
            }
        } catch (_: Throwable) {
            return PlatformToolOutcome.Failure("phone_timeout")
        } finally {
            unbindPhoneCall(call)
        }
    }

    // ------------------------------------------------------------ phone results

    private fun observationOutcome(observation: PhoneControlObservation): PlatformToolOutcome =
        PlatformToolOutcome.Success(
            summary = observationDigest(observation),
            evidence = observationEvidence(observation),
        )

    private fun actionOutcome(
        result: com.floe.android.phonecontrol.PhoneControlActionResult,
        sensitiveInput: Boolean = false,
    ): PlatformToolOutcome {
        val header = buildString {
            append("action=").append(result.action)
            if (sensitiveInput) append(" input=redacted")
            append(" dispatch=").append(result.dispatch.name)
            result.screenChanged?.let { append(" screenChanged=").append(it) }
            result.gestureCompleted?.let { append(" gestureCompleted=").append(it) }
            result.note?.take(120)?.let { append(" note=").append(it) }
        }
        val fresh = result.observation?.let { observationDigest(it) }
        val summary = if (fresh != null) header + "\n" + fresh else header
        return PlatformToolOutcome.Success(
            summary = summary,
            evidence = result.observation?.let { observationEvidence(it) } ?: emptyList(),
        )
    }

    private fun observationDigest(observation: PhoneControlObservation): String {
        return com.floe.android.phonecontrol.PhoneControlObservationText.summary(observation, MAX_DIGEST_NODES)
    }

    private fun observationEvidence(observation: PhoneControlObservation): List<String> {
        val remaining = (observation.expiresAtElapsedRealtimeMillis - SystemClock.elapsedRealtime())
            .coerceAtLeast(0)
        return listOf(
            "fence=${observation.fenceGeneration}",
            "pageGen=${observation.pageGeneration}",
            "expiresInMs=$remaining",
            "screenshot=${observation.screenshotSupport.name}",
            "window=${observation.windowId}",
            "sensitive=${observation.sensitiveWindow}",
            "navigationOnly=${observation.navigationOnly}",
        )
    }

    private fun deniedOutcome(reason: PhoneControlDenial): PlatformToolOutcome =
        PlatformToolOutcome.Failure(
            "phone_" + reason.name.lowercase(),
            denialMessage(reason),
        )

    private fun unavailableOutcome(reason: PhoneControlUnavailable): PlatformToolOutcome =
        PlatformToolOutcome.Failure("phone_" + reason.name.lowercase(), unavailableMessage(reason))

    private fun failedOutcome(failure: PhoneControlResult.Failed): PlatformToolOutcome =
        // The session's closed detail (e.g. the bounded readiness-window
        // explanation for OBSERVATION_FAILED) travels through the transport's
        // bounded detail channel; it is sanitized at encode time and never
        // carries secrets, node text or raw exception data.
        PlatformToolOutcome.Failure("phone_" + failure.reason.name.lowercase(), failure.detail)

    private fun denialCode(reason: PhoneControlDenial): String =
        "phone_" + reason.name.lowercase()

    private fun unavailableCode(reason: PhoneControlUnavailable): String =
        "phone_" + reason.name.lowercase()

    private fun denialMessage(reason: PhoneControlDenial): String = when (reason) {
        PhoneControlDenial.STOPPED -> context.getString(R.string.device_access_error_phone_stopped)
        PhoneControlDenial.TAKEN_OVER -> context.getString(R.string.device_access_error_phone_taken)
        PhoneControlDenial.SERVICE_DISCONNECTED,
        PhoneControlDenial.SERVICE_REVOKED,
        -> context.getString(R.string.device_access_error_phone_service)
        PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED ->
            context.getString(R.string.device_access_error_phone_target)
        PhoneControlDenial.SENSITIVE_FIELD,
        PhoneControlDenial.PROTECTED_WINDOW,
        PhoneControlDenial.DEVICE_LOCKED,
        -> context.getString(R.string.device_access_error_phone_protected)
        PhoneControlDenial.STALE_OBSERVATION,
        PhoneControlDenial.OBSERVATION_EXPIRED,
        PhoneControlDenial.WINDOW_CHANGED,
        PhoneControlDenial.FOREGROUND_CHANGED,
        -> context.getString(R.string.device_access_error_phone_stale)
        PhoneControlDenial.AUTHORIZATION_DENIED,
        PhoneControlDenial.AUTHORIZATION_STALE,
        -> context.getString(R.string.device_access_error_phone_not_allowed)
        else -> context.getString(R.string.device_access_error_phone_failed)
    }

    private fun unavailableMessage(reason: PhoneControlUnavailable): String = when (reason) {
        PhoneControlUnavailable.SERVICE_NOT_ENABLED ->
            context.getString(R.string.device_access_error_phone_not_enabled)
        PhoneControlUnavailable.SERVICE_NOT_CONNECTED ->
            context.getString(R.string.device_access_error_phone_service)
        PhoneControlUnavailable.SCREENSHOT_UNSUPPORTED,
        PhoneControlUnavailable.WINDOW_SCREENSHOT_UNSUPPORTED,
        -> context.getString(R.string.device_access_error_screenshot_unsupported)
        else -> context.getString(R.string.device_access_error_phone_failed)
    }

    private fun denialMessageForCode(code: String): String =
        if (code.contains("root")) {
            context.getString(R.string.device_access_error_root_failed)
        } else {
            context.getString(R.string.device_access_error_backend_failed)
        }

    // ------------------------------------------------------------- system tools

    private fun systemStatus(): PlatformToolOutcome {
        val adb = adbStatus
        val root = rootStatus
        val phone = phoneStatus
        val targets = settings.allowedPackages
        val roots = effectiveSelectedRoots()
        val summary = buildString {
            append("phoneEnabled=").append(phone.enabled)
            append(" connected=").append(phone.connected)
            append(" blocker=").append(phone.blocker?.name?.lowercase() ?: "none")
            append(" selectedApps=").append(targets.size)
            append(" phoneToolsAvailable=").append(phoneServiceUsable(phone) && targets.isNotEmpty())
            append(" userStopped=").append(userStopped)
            append(" automaticControl=").append(settings.automaticPhoneControl)
            val phoneNext = when {
                !phone.enabled -> "enable_accessibility"
                !phone.connected -> "connect_accessibility"
                targets.isEmpty() -> "select_target_apps"
                userStopped || !phoneServiceUsable(phone) -> "allow_task_again"
                else -> "task_authorization_checked_on_call"
            }
            append("\nphoneNext=").append(phoneNext)
            append(" (Settings > Phone; VNC is not phone UI)\n")
            append("adb=").append(
                when (adb) {
                    is AdbStatus.ServiceAlive -> "alive(uid=${adb.effectiveUid})"
                    is AdbStatus.Paired -> "paired"
                    AdbStatus.PairRequired -> "pair_required"
                    AdbStatus.Pairing -> "pairing"
                    is AdbStatus.ServiceDied -> "died"
                    AdbStatus.RestartRequired -> "restart_required"
                    AdbStatus.Revoked -> "revoked"
                    is AdbStatus.Error -> "error"
                    null, AdbStatus.Disabled -> "off"
                },
            )
            append("\nroot=").append(
                when (root) {
                    is RootStatus.Enabled -> if (adbStatus is AdbStatus.ServiceAlive) {
                        "grant_found(adb_live)"
                    } else {
                        "enabled(uid=${root.effectiveUid})"
                    }
                    RootStatus.GrantFound -> "grant_found"
                    RootStatus.GrantNotFound -> "grant_not_found"
                    is RootStatus.Refused -> "refused"
                    is RootStatus.Error -> "error"
                    null, RootStatus.Off -> "off"
                },
            )
            append("\nfileRoots=")
            append(
                if (roots.isEmpty()) {
                    "none"
                } else {
                    roots.joinToString(",") { root ->
                        if (root.writable && settings.fileWritesAllowed) "${root.id}:rw"
                        else "${root.id}:ro"
                    }
                },
            )
            append(" writes=").append(settings.fileWritesAllowed && hasWritableSelection())
            append("\npackageManagement=").append(settings.packageManagementAllowed)
            append(" advancedSystem=").append(settings.advancedSystemManagementAllowed)
            append(" advancedTools=").append(
                settings.advancedSystemAllowedTools.intersect(
                    DeviceAccessToolCatalog.SHIPPED_ADVANCED_TOOLS).size)
            append(" advancedTargets=").append(settings.advancedSystemTargets.size)
            append(" stagedApks=").append(stagedApks.size)
            append("\nadbEnabled=").append(settings.adbEnabled)
            append("\nservice=").append(
                if (adbStatus is AdbStatus.ServiceAlive || rootStatus is RootStatus.Enabled) {
                    "alive"
                } else {
                    "not_running"
                },
            )
        }
        return PlatformToolOutcome.Success(summary = summary)
    }

    private val readOnlyOperations = setOf(
        SystemOperation.FILE_LIST,
        SystemOperation.FILE_READ,
        SystemOperation.PROCESS_QUERY,
        SystemOperation.SERVICE_QUERY,
        SystemOperation.PACKAGE_QUERY,
        SystemOperation.NETWORK_DIAGNOSTICS,
        SystemOperation.PERMISSIONS_QUERY,
        SystemOperation.APP_OPS_QUERY,
        // Closed settings read keeps the ordinary read-only ceiling
        // (temporary-chat rules unchanged).
        SystemOperation.SETTINGS_READ,
    )

    private suspend fun <T> withRootGrant(
        call: PlatformToolCall,
        operation: SystemOperation,
        scopeId: String?,
        destructive: Boolean,
        target: String? = null,
        packageTargets: Set<String> = emptySet(),
        appOpsScope: String = com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_PACKAGE,
        block: suspend (OperationClaim) -> RootResult<T>,
    ): RootResult<T> {
        if (rootRebuilding || rootConfigDirty) return RootResult.Unavailable("policy_updating")
        val controller = rootController ?: return RootResult.Unavailable("service_not_alive")
        if (!systemServiceAlive()) return RootResult.Unavailable("service_not_alive")
        val roots = cachedRoots.ifEmpty { FileRootCatalog.standardRoots() }
        val readOnly = operation in readOnlyOperations
        val fileOperation = operation in FILE_OPERATIONS
        val decision = FileScopePolicy.decide(
            roots = roots,
            selectedIds = settings.fileRootIds,
            requestedId = scopeId,
            fileOperation = fileOperation,
            writeOperation = !readOnly,
            appDataUsable = appDataUsable(),
            globalWrites = settings.fileWritesAllowed,
        )
        val routing = when (decision) {
            is FileScopePolicy.Decision.Denied -> return RootResult.Denied(decision.code)
            is FileScopePolicy.Decision.Ok -> decision.routing
        }
        val root = routing.root
        val scopes = listOf(
            ScopeRoot(
                scopeId = root.id,
                path = root.path,
                writable = routing.writable && !readOnly,
            ),
        )
        // Mutations: the CANONICAL approval grant issued by the Swift runtime
        // (task/run/epoch/call-bound, minted before dispatch only inside the
        // user-published durable ceilings) is the ONLY accepted authority.
        // This host never fabricates grant ids; without one the upstream
        // interactive hard gate already denied the call and it never arrives.
        // Ceiling revocation still refuses at this layer: the management
        // flag below is computed from the CURRENT durable settings and the
        // service re-checks it on the registered grant.
        val grantId = if (readOnly) {
            readLeaseId(call)
        } else {
            call.approvalGrantID?.toString()
                ?: return RootResult.Denied("approval_required")
        }
        val now = System.currentTimeMillis()
        val grantLifetime = maxOf(ROOT_GRANT_LIFETIME_MILLIS,
            rootOperationTimeoutMillis(operation) + 5_000L)
        val management = SystemOperation.isPackageManagement(operation) &&
            settings.packageManagementAllowed
        val request = GrantRequest(
            grantId = grantId,
            taskId = call.taskID.toString(),
            runId = call.runID.toString(),
            epoch = call.epoch,
            expiresAtMillis = now + grantLifetime,
            scopes = scopes,
            operations = setOf(operation),
            packageManagementAllowed = management,
            // Canonical scope binding (N02): the UID write scope allowance is
            // minted only for an AppOps manage call that the caller declared
            // as scope=uid, so a package-scoped approval can never be
            // replayed against this grant as a UID-wide operation.
            appOpsUidScopeAllowed = operation == SystemOperation.APP_OPS_MANAGE &&
                appOpsScope == com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_UID,
            packageTargets = packageTargets
                .filterNot { isFloeSelfPackage(it) }
                .take(GrantRequest.MAX_PACKAGE_TARGETS)
                .toSet(),
        )
        when (val registered = controller.registerGrant(request)) {
            is RootResult.Ok -> Unit
            is RootResult.Denied -> return RootResult.Denied(registered.code, registered.message)
            is RootResult.Unavailable -> return RootResult.Unavailable(registered.code)
            is RootResult.Failed -> return RootResult.Failed(registered.code, registered.message)
        }
        val requestId = call.toolCallID.ifEmpty { call.idempotencyKey }
            .ifEmpty { UUID.randomUUID().toString() }
        val claim = OperationClaim(
            taskId = call.taskID.toString(),
            runId = call.runID.toString(),
            epoch = call.epoch,
            grantId = grantId,
            requestId = requestId,
            callId = call.toolCallID.ifEmpty { null },
        )
        val entry = ActiveRootGrant(
            platformClaim = call.claim,
            taskId = claim.taskId,
            runId = claim.runId,
            epoch = claim.epoch,
            operations = setOf(operation),
            packageManagementAllowed = management,
            expectedTarget = target,
            expiresAtMillis = now + grantLifetime,
            operationClaim = claim,
        )
        rootGrants[grantId] = entry
        try {
            return withTimeout(rootOperationTimeoutMillis(operation)) { block(claim) }
        } catch (_: Throwable) {
            return RootResult.Failed("timeout")
        } finally {
            entry.cancelled.set(true)
            rootGrants.remove(grantId)
            runCatching { controller.revokeGrant(grantId) }
        }
    }

    private fun readLeaseId(call: PlatformToolCall): String {
        val tail = call.toolCallID.ifEmpty { call.idempotencyKey }
            .ifEmpty { call.claim.toString() }
            .take(64)
        return ("readlease:" + call.runID + ":" + tail).take(128)
    }

    /**
     * Per-operation host ceiling over the privileged dispatch. Package
     * operations run a real bounded `pm` child per item; the ceiling must let
     * the service-side timeout (plus read-back) report the true outcome
     * instead of racing it.
     */
    private fun rootOperationTimeoutMillis(operation: SystemOperation): Long = when (operation) {
        SystemOperation.PACKAGE_STAGE,
        SystemOperation.PACKAGE_INSTALL -> 120_000
        SystemOperation.PACKAGE_UNINSTALL -> 60_000
        SystemOperation.PACKAGE_FORCE_STOP -> 30_000
        // Advanced app-state batches: the settled Host outer ceiling for the
        // nine bounded batch mutation tools is 17 minutes; per-item OS
        // timeouts (30-60s inside the service) plus the read-back keep the
        // real outcome far under it.
        SystemOperation.PACKAGE_SET_ENABLED,
        SystemOperation.PACKAGE_REMOVE_FOR_USER,
        SystemOperation.PACKAGE_RESTORE -> HOST_BATCH_OUTER_TIMEOUT_MILLIS
        // Permission/AppOps batches settle under the same 17-minute Host
        // outer ceiling as the other bounded batch mutation tools; the
        // per-item OS timeouts inside the service keep the real outcome far
        // under it. The two queries stay on the ordinary 25s read-only
        // budget (each does at most 13 bounded single-op reads).
        SystemOperation.PERMISSIONS_MANAGE,
        SystemOperation.APP_OPS_MANAGE -> HOST_BATCH_OUTER_TIMEOUT_MILLIS
        // Per-item settings grant: one bounded child plus read-back. The
        // 17-minute host batch ceiling for the closed nine mutation tools is
        // unchanged; no blanket timeout expansion.
        SystemOperation.SETTINGS_WRITE -> 30_000
        else -> 25_000
    }

    private fun rootOutcome(
        result: RootResult<*>,
        success: (Any?) -> PlatformToolOutcome.Success,
    ): PlatformToolOutcome = when (result) {
        is RootResult.Ok -> success(result.value)
        is RootResult.Denied -> PlatformToolOutcome.Failure(
            "root_" + result.code, result.message ?: result.code)
        is RootResult.Unavailable -> PlatformToolOutcome.Failure(
            "root_unavailable_" + result.code)
        is RootResult.Failed -> PlatformToolOutcome.Failure(
            "root_failed_" + result.code, result.message)
    }

    private suspend fun systemFilesList(call: PlatformToolCall): PlatformToolOutcome {
        val rootId = call.arguments.optString("root")
        if (rootId.isEmpty()) return PlatformToolOutcome.Failure("invalid_arguments")
        val path = call.arguments.optString("path")
        val maxEntries = call.arguments.optInt("maxEntries", 40)
            .coerceIn(1, 60)
        val result = withRootGrant(
            call, SystemOperation.FILE_LIST, rootId, destructive = false, target = path,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.fileList(claim, rootId, path, maxEntries)
        }
        return when (result) {
            is RootResult.Ok -> {
                val entries = result.value
                val summary = buildString {
                    append("root=").append(rootId)
                    append(" path=").append(path.ifEmpty { "/" })
                    append(" entries=").append(entries.size)
                    entries.sortedWith(
                        compareByDescending<FileEntry> { it.directory }.thenBy { it.name.lowercase() },
                    ).take(MAX_LIST_ROWS).forEach { entry ->
                        val suffix = if (entry.directory) "/" else ""
                        append('\n')
                            .append(if (entry.directory) "D" else "F").append('|')
                            .append(entry.sizeBytes).append('|')
                            .append(entry.relativePath.take(120)).append(suffix)
                    }
                    if (entries.size > MAX_LIST_ROWS) {
                        append("\n… ").append(entries.size - MAX_LIST_ROWS).append(" more")
                    }
                }
                PlatformToolOutcome.Success(summary)
            }
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Listed.") }
        }
    }

    private suspend fun systemFilesRead(call: PlatformToolCall): PlatformToolOutcome {
        val rootId = call.arguments.optString("root")
        val path = call.arguments.optString("path")
        if (rootId.isEmpty() || path.isEmpty()) {
            return PlatformToolOutcome.Failure("invalid_arguments")
        }
        val offset = call.arguments.optLong("offset", 0L).coerceAtLeast(0L)
        val maxBytes = call.arguments.optInt("maxBytes", 4_096).coerceIn(1, 16_384)
        val result = withRootGrant(
            call, SystemOperation.FILE_READ, rootId, destructive = false, target = path,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.fileRead(claim, rootId, path, offset, maxBytes)
        }
        return when (result) {
            is RootResult.Ok -> readOutcome(path, offset, result.value)
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Read.") }
        }
    }

    private fun readOutcome(path: String, offset: Long, read: FileRead): PlatformToolOutcome {
        val next = offset + read.bytes.size
        val text = decodeUtf8(read.bytes)
        if (text == null) {
            return PlatformToolOutcome.Success(
                summary = "file=$path bytes=${read.bytes.size} offset=$offset binary=true " +
                    "nextOffset=$next truncated=${read.truncated}\nBinary content is not displayed.",
                evidence = listOf("nextOffset=$next", "truncated=${read.truncated}"),
            )
        }
        val budget = 1_700
        val clipped = if (text.length <= budget) text else BoundedResultText.clip(text, budget - 80)
        val summary = buildString {
            append("file=").append(path.take(120))
            append(" offset=").append(offset)
            append(" bytes=").append(read.bytes.size)
            if (read.truncated) append(" truncated")
            append('\n').append(clipped)
            if (text.length > budget) {
                append("\n… more text follows; call again with offset=").append(next)
            }
        }
        return PlatformToolOutcome.Success(
            summary = summary,
            evidence = listOf("nextOffset=$next", "truncated=${read.truncated}"),
        )
    }

    private fun decodeUtf8(bytes: ByteArray): String? = try {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    } catch (_: Throwable) {
        null
    }

    private suspend fun systemFilesWrite(call: PlatformToolCall): PlatformToolOutcome {
        val rootId = call.arguments.optString("root")
        val path = call.arguments.optString("path")
        val text = call.arguments.optString("text")
        if (rootId.isEmpty() || path.isEmpty()) {
            return PlatformToolOutcome.Failure("invalid_arguments")
        }
        if (text.toByteArray(Charsets.UTF_8).size > MAX_WRITE_BYTES) {
            return PlatformToolOutcome.Failure("argument_too_large")
        }
        val overwrite = call.arguments.optBoolean("overwrite", false)
        val result = withRootGrant(
            call, SystemOperation.FILE_WRITE, rootId, destructive = overwrite, target = path,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.fileWrite(claim, rootId, path, text.toByteArray(Charsets.UTF_8), overwrite)
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(
                "file=${path.take(120)} bytes=${result.value.bytesWritten} " +
                    "atomic=${result.value.atomic}",
            )
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Written.") }
        }
    }

    private suspend fun systemFilesMove(call: PlatformToolCall): PlatformToolOutcome {
        val rootId = call.arguments.optString("root")
        val from = call.arguments.optString("from")
        val to = call.arguments.optString("to")
        if (rootId.isEmpty() || from.isEmpty() || to.isEmpty()) {
            return PlatformToolOutcome.Failure("invalid_arguments")
        }
        val overwrite = call.arguments.optBoolean("overwrite", false)
        val result = withRootGrant(
            call, SystemOperation.FILE_MOVE, rootId, destructive = overwrite,
            target = "$from -> $to",
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.fileMove(claim, rootId, from, to, overwrite)
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(
                "from=${result.value.from.take(120)} to=${result.value.to.take(120)}",
            )
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Moved.") }
        }
    }

    private suspend fun systemFilesDelete(call: PlatformToolCall): PlatformToolOutcome {
        val rootId = call.arguments.optString("root")
        val path = call.arguments.optString("path")
        if (rootId.isEmpty() || path.isEmpty()) {
            return PlatformToolOutcome.Failure("invalid_arguments")
        }
        val recursive = call.arguments.optBoolean("recursive", false)
        val result = withRootGrant(
            call, SystemOperation.FILE_DELETE, rootId, destructive = true, target = path,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.fileDelete(claim, rootId, path, recursive)
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(
                "deleted=${result.value.deleted} path=${path.take(120)}",
            )
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Deleted.") }
        }
    }

    private suspend fun systemProcessQuery(call: PlatformToolCall): PlatformToolOutcome {
        val filter = call.arguments.optString("filter").ifEmpty { null }
        val maxEntries = call.arguments.optInt("maxEntries", 60).coerceIn(1, 200)
        val result = withRootGrant(
            call, SystemOperation.PROCESS_QUERY, null, destructive = false, target = filter,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.processQuery(claim, filter, maxEntries)
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(
                buildRows("processes", result.value.map {
                    "${it.pid}|${it.uid}|${it.name.take(100)}"
                }),
            )
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Queried.") }
        }
    }

    private suspend fun systemServiceQuery(call: PlatformToolCall): PlatformToolOutcome {
        val maxEntries = call.arguments.optInt("maxEntries", 60).coerceIn(1, 200)
        val result = withRootGrant(
            call, SystemOperation.SERVICE_QUERY, null, destructive = false,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.serviceQuery(claim, maxEntries)
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(
                buildRows("services", result.value.map {
                    "${it.pid}|${if (it.foreground) "fg" else "bg"}|" +
                        "${it.processName.take(80)}|${it.className.take(80)}"
                }),
            )
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Queried.") }
        }
    }

    private suspend fun systemPackageQuery(call: PlatformToolCall): PlatformToolOutcome {
        val packageName = call.arguments.optString("packageName").ifEmpty { null }
        val includeSystem = call.arguments.optBoolean("includeSystem", true)
        val includeUninstalled = call.arguments.optBoolean("includeUninstalled", false)
        val maxEntries = call.arguments.optInt("maxEntries", 60).coerceIn(1, 200)
        val result = withRootGrant(
            call, SystemOperation.PACKAGE_QUERY, null, destructive = false, target = packageName,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.packageQuery(
                claim, packageName, includeSystem, maxEntries,
                includeUninstalled = includeUninstalled,
            )
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(
                buildRows("packages", result.value.packages.map {
                    "${it.packageName.take(100)}|${it.uid}|${it.versionCode}|" +
                        if (it.enabled) "enabled" else "disabled"
                }, truncated = result.value.truncated),
            )
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Queried.") }
        }
    }

    private suspend fun systemNetworkDiagnostics(call: PlatformToolCall): PlatformToolOutcome {
        val result = withRootGrant(
            call, SystemOperation.NETWORK_DIAGNOSTICS, null, destructive = false,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.networkDiagnostics(claim)
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(networkSummary(result.value))
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Read.") }
        }
    }

    private suspend fun systemForceStop(call: PlatformToolCall): PlatformToolOutcome {
        if (!settings.packageManagementAllowed) {
            return PlatformToolOutcome.Failure(
                "management_not_allowed",
                "The user must allow app management in Settings > Phone",
            )
        }
        val packageName = call.arguments.optString("packageName")
        if (packageName.isBlank()) return PlatformToolOutcome.Failure("invalid_arguments")
        val userId = call.arguments.optInt("userId", 0).coerceIn(0, 999)
        val result = withRootGrant(
            call, SystemOperation.PACKAGE_FORCE_STOP, null, destructive = true,
            target = packageName,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.forceStopPackage(claim, packageName, userId)
        }
        return when (result) {
            is RootResult.Ok -> PlatformToolOutcome.Success(
                "package=${result.value.packageName.take(120)} operation=${result.value.operation} " +
                    "stillRunning=${result.value.stillRunning}",
            )
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Stopped.") }
        }
    }

    private fun systemPackagesStaged(): PlatformToolOutcome {
        refreshStagedApks()
        val staged = stagedApks
        val summary = buildString {
            append("staged=").append(staged.size)
            staged.take(MAX_LIST_ROWS).forEach { apk ->
                append('\n')
                    .append(apk.stagedId).append('|')
                    .append(apk.fileName.take(60)).append('|')
                    .append(apk.sizeBytes).append('|')
                    .append(apk.packageName?.take(80) ?: "unknown").append('|')
                    .append(apk.sha256.take(12))
            }
            if (staged.size > MAX_LIST_ROWS) {
                append("\n… ").append(staged.size - MAX_LIST_ROWS).append(" more")
            }
            if (staged.isEmpty()) {
                append("\nNo staged APKs. Use system.packages.stage for task workspace or granted-root files, or ask the user to stage APKs in Settings > Phone > App management.")
            }
        }
        return PlatformToolOutcome.Success(summary)
    }

    /**
     * Batch install over staged ids. Every item gets its own real privileged
     * grant and dispatch; a fenced ticket between items skips the rest. Each
     * item carries its staging-time digest binding into the service, which
     * re-verifies the streamed bytes before reporting: ok means the receipt
     * itself says succeeded, never a bare transport success.
     */
    private suspend fun systemPackagesInstall(call: PlatformToolCall): PlatformToolOutcome {
        if (!settings.packageManagementAllowed) {
            return PlatformToolOutcome.Failure(
                "management_not_allowed",
                "The user must allow app management in Settings > Phone",
            )
        }
        val request = PackageBatchArguments.install(call.arguments)
        if (request is PackageBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PackageBatchArguments.Request.Install
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(request.stagedIds.size)
        for ((index, stagedId) in request.stagedIds.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += request.stagedIds.size - index
                break
            }
            val staged = apkStaging.stagedEntry(stagedId)
            if (staged == null) {
                failed += 1
                lines += "fail id=$stagedId code=staged_missing"
                continue
            }
            val (path, entry) = staged
            val result = withRootGrant(
                call, SystemOperation.PACKAGE_INSTALL, null, destructive = true, target = path,
            ) { claim ->
                val controller = rootController
                    ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
                controller.installPackage(
                    claim, path, request.userId,
                    com.floe.android.rootsystem.StagedApkBinding(
                        expectedSha256 = entry.sha256,
                        expectedSizeBytes = entry.sizeBytes,
                        expectedPackageName = entry.packageName,
                    ),
                )
            }
            when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        ok += 1
                        lines += "ok id=$stagedId pkg=${receipt.packageName.take(80)} " +
                            "version=${receipt.versionCode} present=${receipt.presentAfter}"
                    } else {
                        failed += 1
                        lines += "fail id=$stagedId pkg=${receipt.packageName.take(80)} " +
                            "code=${receipt.detailCode} present=${receipt.presentAfter}" +
                            (receipt.failureDetail?.let { " reason=${it.take(60)}" } ?: "")
                    }
                }
                is RootResult.Denied -> {
                    if (result.code == "cancelled") {
                        cancelled = true
                        skipped += request.stagedIds.size - index
                        break
                    }
                    failed += 1
                    lines += "fail id=$stagedId code=root_${result.code}"
                }
                is RootResult.Unavailable -> {
                    failed += 1
                    lines += "fail id=$stagedId code=unavailable_${result.code}"
                }
                is RootResult.Failed -> {
                    failed += 1
                    lines += "fail id=$stagedId code=${result.code}"
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure("cancelled", "The install batch was cancelled.")
        }
        val summary = buildString {
            append("install requested=").append(request.stagedIds.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        // Truthful transport status: a partially or fully failed install
        // batch is not a zero-exit success.
        val exitStatus = if (failed == 0 && !cancelled) 0 else 1
        return PlatformToolOutcome.Success(summary, exitStatus = exitStatus)
    }

    /**
     * Trusted automatic staging for task-owned or user-granted APKs.
     *
     * workspace sources: the Swift runtime resolves the CURRENT ticket's run
     * workspace (never the model's view of the filesystem), guards the
     * relative path, streams the bytes into a verified inbox file and returns
     * a digest binding; the store re-verifies size + SHA-256 before the entry
     * becomes installable.
     *
     * fileRoot sources: the host resolves the granted root, canonicalizes the
     * relative path inside it and asks the privileged service to copy the
     * bytes into its own digest-named staging area; the returned receipt is
     * adopted into the manifest.
     *
     * A fenced ticket between items skips the rest; per-item failures are
     * reported with the exact typed code and never abort the batch.
     */
    private suspend fun systemPackagesStage(call: PlatformToolCall): PlatformToolOutcome {
        if (!settings.packageManagementAllowed) {
            return PlatformToolOutcome.Failure("management_not_allowed",
                "The user must allow app management in Settings > Phone")
        }
        val request = PackageStageArguments.parse(call.arguments)
        if (request is PackageStageArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PackageStageArguments.Request.Stage
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(request.sources.size)
        for ((index, source) in request.sources.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += request.sources.size - index
                break
            }
            when (source) {
                is PackageStageArguments.Source.Workspace -> {
                    val staged = stageWorkspaceSource(call, source)
                    if (staged != null) {
                        ok += 1
                        lines += "ok staged=${staged.stagedId} size=${staged.sizeBytes} " +
                            "pkg=${staged.packageName?.take(80) ?: "unknown"} origin=workspace"
                    } else {
                        failed += 1
                        lines += "fail path=${source.relativePath.take(100)} code=stage_failed"
                    }
                }
                is PackageStageArguments.Source.FileRoot -> {
                    val staged = stageFileRootSource(call, source)
                    if (staged != null) {
                        ok += 1
                        lines += "ok staged=${staged.stagedId} size=${staged.sizeBytes} " +
                            "pkg=${staged.packageName?.take(80) ?: "unknown"} origin=fileRoot"
                    } else {
                        failed += 1
                        lines += "fail root=${source.rootId.take(40)} " +
                            "path=${source.relativePath.take(80)} code=stage_failed"
                    }
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure("cancelled", "The stage batch was cancelled.")
        }
        val summary = buildString {
            append("stage requested=").append(request.sources.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        val exitStatus = if (failed == 0 && !cancelled) 0 else 1
        return PlatformToolOutcome.Success(summary, exitStatus = exitStatus)
    }

    /**
     * Transfer one workspace-relative APK through the trusted runtime seam.
     * The native call blocks on owned IO; it is fenced by the live platform
     * claim (the Swift side checks shouldStop per chunk) and re-checked here
     * before and after.
     */
    private suspend fun stageWorkspaceSource(
        call: PlatformToolCall,
        source: PackageStageArguments.Source.Workspace,
    ): com.floe.android.rootsystem.StagedApk? = withContext(io) {
        if (platformCallFenced(call)) return@withContext null
        val reply = try {
            com.floe.android.swiftbridge.PlatformToolsNative.stageWorkspaceApk(
                call.claim,
                source.relativePath.toByteArray(Charsets.UTF_8),
            )
        } catch (_: Throwable) {
            null
        } ?: return@withContext null
        if (platformCallFenced(call)) return@withContext null
        val text = com.floe.android.swiftbridge.PlatformToolsNative.strictText(reply)
            ?: return@withContext null
        val root = runCatching { org.json.JSONObject(text) }.getOrNull() ?: return@withContext null
        val absolute = root.optString("absolutePath")
        val sha = root.optString("sha256")
        val size = root.optLong("sizeBytes", -1)
        if (!absolute.startsWith("/") || sha.length != 64 || size < 0) return@withContext null
        apkStaging.adoptWorkspaceFile(File(absolute), sha, size)
    }

    /**
     * Copy one granted-root APK through the privileged service. The path is
     * canonicalized inside the granted root and re-checked against the
     * shared-storage ceiling before dispatch; the service returns the
     * digest-named owned copy it actually committed.
     */
    private suspend fun stageFileRootSource(
        call: PlatformToolCall,
        source: PackageStageArguments.Source.FileRoot,
    ): com.floe.android.rootsystem.StagedApk? {
        if (source.rootId !in settings.fileRootIds) return null
        val roots = cachedRoots.ifEmpty { FileRootCatalog.standardRoots() }
        val root = roots.firstOrNull { it.id == source.rootId } ?: return null
        val absolute = try {
            File(root.path, source.relativePath).canonicalFile
        } catch (_: Throwable) {
            return null
        }
        val rootCanonical = try {
            File(root.path).canonicalFile
        } catch (_: Throwable) {
            return null
        }
        if (!absolute.path.startsWith(rootCanonical.path.trimEnd('/') + "/")) return null
        if (com.floe.android.rootsystem.policy.StagedApkPolicy.normalizeStagedPath(absolute.path) == null) {
            return null
        }
        val result = withRootGrant(
            call, SystemOperation.PACKAGE_STAGE, null, destructive = false, target = absolute.path,
        ) { claim ->
            val controller = rootController
                ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.stageApk(claim, absolute.path)
        }
        val receipt = (result as? RootResult.Ok)?.value ?: return null
        return apkStaging.adoptServiceCopy(receipt.stagedPath, receipt)
    }

    /**
     * Batch uninstall over package names with the same per-item grant,
     * dispatch, cancellation and read-back semantics as batch install.
     */
    private suspend fun systemPackagesUninstall(call: PlatformToolCall): PlatformToolOutcome {
        if (!settings.packageManagementAllowed) {
            return PlatformToolOutcome.Failure(
                "management_not_allowed",
                "The user must allow app management in Settings > Phone",
            )
        }
        val request = PackageBatchArguments.uninstall(call.arguments)
        if (request is PackageBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PackageBatchArguments.Request.Uninstall
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(request.packageNames.size)
        for ((index, packageName) in request.packageNames.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += request.packageNames.size - index
                break
            }
            val result = withRootGrant(
                call, SystemOperation.PACKAGE_UNINSTALL, null, destructive = true,
                target = packageName,
            ) { claim ->
                val controller = rootController
                    ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
                controller.uninstallPackage(claim, packageName, request.userId)
            }
            when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        ok += 1
                        lines += "ok pkg=${receipt.packageName.take(100)} " +
                            "present=${receipt.presentAfter}"
                    } else {
                        failed += 1
                        lines += "fail pkg=${packageName.take(100)} " +
                            "code=${receipt.detailCode} present=${receipt.presentAfter}" +
                            (receipt.failureDetail?.let { " reason=${it.take(60)}" } ?: "")
                    }
                }
                is RootResult.Denied -> {
                    if (result.code == "cancelled") {
                        cancelled = true
                        skipped += request.packageNames.size - index
                        break
                    }
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=root_${result.code}"
                }
                is RootResult.Unavailable -> {
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=unavailable_${result.code}"
                }
                is RootResult.Failed -> {
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=${result.code}"
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure("cancelled", "The uninstall batch was cancelled.")
        }
        val summary = buildString {
            append("uninstall requested=").append(request.packageNames.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        val exitStatus = if (failed == 0 && !cancelled) 0 else 1
        return PlatformToolOutcome.Success(summary, exitStatus = exitStatus)
    }

    // --------------------------------------------- permission/appops tools

    /**
     * The Settings-sheet inspector: user-initiated reads and changes of the
     * selected targets' permission/AppOps state. Every action re-checks the
     * CURRENT durable ceilings (management + advanced master + selected
     * targets) and the service re-checks the registered grant and target
     * ceiling, so a ceiling revoked while the sheet is open refuses on the
     * very next tap.
     */
    val permissionOpsInspector = object : DeviceAccessPermissionOpsInspector {
        override suspend fun permissions(packageName: String): DeviceAccessPermissionOpsResult {
            val result = withUserAdvancedGrant(
                SystemOperation.PERMISSIONS_QUERY, packageName,
            ) { claim ->
                val controller = rootController
                    ?: return@withUserAdvancedGrant RootResult.Unavailable("service_not_alive")
                controller.queryPermissions(claim, packageName, currentUserId())
            }
            return when (result) {
                is RootResult.Ok -> {
                    val query = result.value
                    DeviceAccessPermissionOpsResult.Ok(
                        buildString {
                            append("permissions=").append(query.permissions.size)
                            query.permissions.take(MAX_LIST_ROWS).forEach { row ->
                                append('\n')
                                    .append(if (row.granted) "granted" else "denied").append('|')
                                    .append(row.protectionLevel).append('|')
                                    .append(row.name.take(140))
                            }
                            if (query.permissions.size > MAX_LIST_ROWS) {
                                append("\n… more")
                            }
                        },
                    )
                }
                else -> permissionOpsFailure(result)
            }
        }

        override suspend fun appOps(packageName: String): DeviceAccessPermissionOpsResult {
            val result = withUserAdvancedGrant(
                SystemOperation.APP_OPS_QUERY, packageName,
            ) { claim ->
                val controller = rootController
                    ?: return@withUserAdvancedGrant RootResult.Unavailable("service_not_alive")
                controller.queryAppOps(claim, packageName, currentUserId())
            }
            return when (result) {
                is RootResult.Ok -> {
                    val query = result.value
                    DeviceAccessPermissionOpsResult.Ok(
                        buildString {
                            query.operations.forEach { row ->
                                append('\n').append(row.operation).append('|')
                                    .append(row.effective)
                                row.overrideMode?.let { append("|override=").append(it) }
                                row.uidMode?.let { append("|uid=").append(it) }
                                row.defaultMode?.let { append("|default=").append(it) }
                            }
                        },
                    )
                }
                else -> permissionOpsFailure(result)
            }
        }

        override suspend fun setPermission(
            packageName: String,
            permission: String,
            grant: Boolean,
        ): DeviceAccessPermissionOpsResult {
            val result = withUserAdvancedGrant(
                SystemOperation.PERMISSIONS_MANAGE, packageName,
            ) { claim ->
                val controller = rootController
                    ?: return@withUserAdvancedGrant RootResult.Unavailable("service_not_alive")
                controller.managePermission(
                    claim, packageName, currentUserId(), permission,
                    if (grant) {
                        com.floe.android.rootsystem.policy.PermissionOpsPolicy.ACTION_GRANT
                    } else {
                        com.floe.android.rootsystem.policy.PermissionOpsPolicy.ACTION_REVOKE
                    },
                )
            }
            return when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        DeviceAccessPermissionOpsResult.Ok(
                            "ok ${receipt.permission} granted=${receipt.grantedAfter}",
                        )
                    } else {
                        DeviceAccessPermissionOpsResult.Failed(
                            receipt.detailCode +
                                (receipt.failureDetail?.let { ": ${it.take(80)}" } ?: ""),
                        )
                    }
                }
                else -> permissionOpsFailure(result)
            }
        }

        override suspend fun setAppOp(
            packageName: String,
            operation: String,
            mode: String,
            scope: String,
        ): DeviceAccessPermissionOpsResult {
            // Use the same app-management/category gates and LIVE peer capability as the model path.
            if (scope == com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_UID) {
                if (!appOpsUidScopeAllowed()) {
                    return DeviceAccessPermissionOpsResult.Failed("uid_scope_not_allowed")
                }
                if (!appOpsUidScopeSupported) refreshAppOpsUidScopeSupport()
                if (!appOpsUidScopeSupported) {
                    return DeviceAccessPermissionOpsResult.Failed("uid_scope_unsupported")
                }
            }
            val result = withUserAdvancedGrant(
                SystemOperation.APP_OPS_MANAGE, packageName, appOpsScope = scope,
            ) { claim ->
                val controller = rootController
                    ?: return@withUserAdvancedGrant RootResult.Unavailable("service_not_alive")
                controller.manageAppOps(claim, packageName, currentUserId(), operation, mode, scope)
            }
            return when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        DeviceAccessPermissionOpsResult.Ok(
                            "ok ${receipt.operation} requested=${receipt.requestedMode} " +
                                "effective=${receipt.effectiveAfter}" +
                                appOpsScopeSuffix(receipt),
                        )
                    } else {
                        DeviceAccessPermissionOpsResult.Failed(
                            receipt.detailCode + appOpsScopeSuffix(receipt) +
                                (receipt.failureDetail?.let { ": ${it.take(80)}" } ?: ""),
                        )
                    }
                }
                else -> permissionOpsFailure(result)
            }
        }
    }

    /**
     * Compact read-back suffix for the AppOps UID scope: the requested
     * scope and the service-resolved UID stay visible in the model-facing
     * summary, so a package-scope result can never masquerade as a UID one.
     * Preserve the captured layers for restoration on success and failure;
     * an absent entry differs from an unobserved platform default.
     */
    private fun appOpsScopeSuffix(receipt: com.floe.android.rootsystem.AppOpsSetReceipt): String =
        (if (receipt.scope == com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_UID) {
            " scope=uid uid=${receipt.resolvedUid}"
        } else {
            " scope=package"
        }) +
            " overrideBefore=${receipt.overrideBefore ?: "absent"}" +
            " uidBefore=${receipt.uidBefore ?: "absent"}" +
            " defaultBefore=${receipt.defaultBefore ?: "unknown"}" +
            " effectiveBefore=${receipt.effectiveBefore}" +
            " overrideAfter=${receipt.overrideAfter ?: "absent"}" +
            " uidAfter=${receipt.uidAfter ?: "absent"}"

    private fun permissionOpsFailure(result: RootResult<*>): DeviceAccessPermissionOpsResult =
        when (result) {
            is RootResult.Denied -> DeviceAccessPermissionOpsResult.Failed(result.code)
            is RootResult.Unavailable ->
                DeviceAccessPermissionOpsResult.Failed("unavailable_" + result.code)
            is RootResult.Failed -> DeviceAccessPermissionOpsResult.Failed(result.code)
            is RootResult.Ok -> DeviceAccessPermissionOpsResult.Failed("unknown")
        }

    /**
     * UI-initiated advanced grant: the tap in Settings IS the user approval,
     * so unlike the model path no canonical approvalGrantID exists. A RAM
     * nonce grant id is registered with the privileged service for exactly
     * one action and revoked immediately after; the durable ceilings are
     * re-checked from the CURRENT settings at dispatch and the service
     * re-checks the grant and the selected-target ceiling. Never a model
     * path: tool calls still require the canonical approval grant.
     */
    private suspend fun <T> withUserAdvancedGrant(
        operation: SystemOperation,
        target: String,
        appOpsScope: String = com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_PACKAGE,
        block: suspend (OperationClaim) -> RootResult<T>,
    ): RootResult<T> {
        if (rootRebuilding || rootConfigDirty) return RootResult.Unavailable("policy_updating")
        val controller = rootController ?: return RootResult.Unavailable("service_not_alive")
        if (!systemServiceAlive()) return RootResult.Unavailable("service_not_alive")
        if (!settings.packageManagementAllowed) return RootResult.Denied("management_not_allowed")
        if (!settings.advancedSystemManagementAllowed) {
            return RootResult.Denied("advanced_system_not_allowed")
        }
        if (settings.advancedSystemTargets.isEmpty()) return RootResult.Denied("advanced_targets_required")
        if (target !in settings.advancedSystemTargets) return RootResult.Denied("target_not_authorized")
        return withUserActionGrant(
            operation = operation,
            target = target,
            destructive = operation !in readOnlyOperations,
            packageTargets = settings.advancedSystemTargets,
            appOpsScope = appOpsScope,
            block = block,
        )
    }



    /**
     * Read-only advanced gate: the base management ceiling, the shared
     * advanced master and a non-empty selected target set. Query
     * descriptors deliberately do NOT require the tool name in the durable
     * allowed-tools set (they disclose state only); the two manager tools
     * use [advancedSystemGate], which additionally pins the exact name.
     */
    private fun advancedSystemQueryGate(): PlatformToolOutcome.Failure? = when {
        !settings.packageManagementAllowed -> PlatformToolOutcome.Failure(
            "management_not_allowed",
            "The user must allow app management in Settings > Phone",
        )
        !settings.advancedSystemManagementAllowed -> PlatformToolOutcome.Failure(
            "advanced_system_not_allowed",
            "The user must turn on advanced app state in Settings > Phone",
        )
        settings.advancedSystemTargets.isEmpty() -> PlatformToolOutcome.Failure(
            "advanced_targets_required",
            "The user must select target apps in Settings > Phone",
        )
        else -> null
    }

    private fun permissionOpsTargetRefused(packageName: String): PlatformToolOutcome.Failure? =
        if (packageName !in settings.advancedSystemTargets) {
            PlatformToolOutcome.Failure(
                "target_not_authorized",
                "Only apps the user selected in Settings can be inspected or changed.",
            )
        } else {
            null
        }

    private suspend fun systemPermissionsQuery(call: PlatformToolCall): PlatformToolOutcome {
        advancedSystemQueryGate()?.let { return it }
        val request = PermissionOpsBatchArguments.permissionsQuery(call.arguments)
        if (request is PermissionOpsBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PermissionOpsBatchArguments.Request.PermissionsQuery
        crossUserRefused(request.userId)?.let { return it }
        permissionOpsTargetRefused(request.packageName)?.let { return it }
        val result = withRootGrant(
            call, SystemOperation.PERMISSIONS_QUERY, null, destructive = false,
            target = request.packageName,
            packageTargets = settings.advancedSystemTargets,
        ) { claim ->
            val controller = rootController
                ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.queryPermissions(claim, request.packageName, request.userId)
        }
        return when (result) {
            is RootResult.Ok -> {
                val query = result.value
                val summary = buildString {
                    append("pkg=").append(query.packageName.take(100))
                    append(" user=").append(query.userId)
                    append(" permissions=").append(query.permissions.size)
                    query.permissions.take(MAX_LIST_ROWS).forEach { row ->
                        append('\n')
                            .append(if (row.granted) "granted" else "denied").append('|')
                            .append(row.protectionLevel).append('|')
                            .append(row.name.take(160))
                    }
                    if (query.permissions.size > MAX_LIST_ROWS) {
                        append("\n… ").append(query.permissions.size - MAX_LIST_ROWS)
                            .append(" more")
                    }
                }
                PlatformToolOutcome.Success(summary)
            }
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Queried.") }
        }
    }

    /**
     * Bounded permission grant/revoke batch (at most 8 items): one real
     * privileged grant per item under the management ceiling, the advanced
     * master, the exact allowed name and the selected-target ceiling; the
     * service re-validates declaration and protection level and reports OS
     * refusals (signature/fixed/admin/platform, undeclared permission,
     * shared UID) as real per-item failures. Truthful nonzero exitStatus
     * when anything failed or the batch was partially cancelled.
     */
    private suspend fun systemPermissionsManage(call: PlatformToolCall): PlatformToolOutcome {
        advancedSystemGate(DeviceAccessToolCatalog.SYSTEM_PERMISSIONS_MANAGE)?.let { return it }
        val request = PermissionOpsBatchArguments.permissionsManage(call.arguments)
        if (request is PermissionOpsBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PermissionOpsBatchArguments.Request.PermissionsManage
        crossUserRefused(request.userId)?.let { return it }
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(request.items.size)
        for ((index, item) in request.items.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += request.items.size - index
                break
            }
            permissionOpsTargetRefused(item.packageName)?.let {
                failed += 1
                lines += "fail pkg=${item.packageName.take(100)} " +
                    "perm=${item.permission.take(120)} code=${it.code}"
                continue
            }
            val result = withRootGrant(
                call, SystemOperation.PERMISSIONS_MANAGE, null, destructive = true,
                target = item.packageName,
                packageTargets = settings.advancedSystemTargets,
            ) { claim ->
                val controller = rootController
                    ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
                controller.managePermission(
                    claim, item.packageName, request.userId,
                    item.permission, item.action,
                )
            }
            when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        ok += 1
                        lines += "ok pkg=${receipt.packageName.take(100)} " +
                            "perm=${receipt.permission.take(120)} " +
                            "action=${receipt.action} granted=${receipt.grantedAfter}"
                    } else {
                        failed += 1
                        lines += "fail pkg=${receipt.packageName.take(100)} " +
                            "perm=${receipt.permission.take(120)} " +
                            "code=${receipt.detailCode} " +
                            "granted=${receipt.grantedBefore}->${receipt.grantedAfter}" +
                            (receipt.failureDetail?.let { " reason=${it.take(60)}" } ?: "")
                    }
                }
                is RootResult.Denied -> {
                    if (result.code == "cancelled") {
                        cancelled = true
                        skipped += request.items.size - index
                        break
                    }
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "perm=${item.permission.take(120)} code=root_${result.code}"
                }
                is RootResult.Unavailable -> {
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "perm=${item.permission.take(120)} code=unavailable_${result.code}"
                }
                is RootResult.Failed -> {
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "perm=${item.permission.take(120)} code=${result.code}"
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure(
                "cancelled", "The permission batch was cancelled.",
            )
        }
        val summary = buildString {
            append("permissions requested=").append(request.items.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        val exitStatus = if (failed == 0 && !cancelled) 0 else 1
        return PlatformToolOutcome.Success(summary, exitStatus = exitStatus)
    }

    private suspend fun systemAppOpsQuery(call: PlatformToolCall): PlatformToolOutcome {
        advancedSystemQueryGate()?.let { return it }
        val request = PermissionOpsBatchArguments.appOpsQuery(call.arguments)
        if (request is PermissionOpsBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PermissionOpsBatchArguments.Request.AppOpsQuery
        crossUserRefused(request.userId)?.let { return it }
        permissionOpsTargetRefused(request.packageName)?.let { return it }
        val result = withRootGrant(
            call, SystemOperation.APP_OPS_QUERY, null, destructive = false,
            target = request.packageName,
            packageTargets = settings.advancedSystemTargets,
        ) { claim ->
            val controller = rootController
                ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.queryAppOps(claim, request.packageName, request.userId)
        }
        return when (result) {
            is RootResult.Ok -> {
                val query = result.value
                val summary = buildString {
                    append("pkg=").append(query.packageName.take(100))
                    append(" user=").append(query.userId)
                    append(" ops=").append(query.operations.size)
                    query.operations.forEach { row ->
                        append('\n').append(row.operation).append('|')
                            .append(row.effective)
                        row.overrideMode?.let { append("|override=").append(it) }
                        row.uidMode?.let { append("|uid=").append(it) }
                        row.defaultMode?.let { append("|default=").append(it) }
                    }
                }
                PlatformToolOutcome.Success(summary)
            }
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Queried.") }
        }
    }

    /**
     * Bounded AppOps mode batch (at most 8 items) over the closed catalog.
     * Each item captures the restorable BEFORE layers (override/UID/default)
     * and the observed read-back; "default" success means the package
     * override is gone or recorded default — restoring an inherited UID
     * mode as a new package override is never reported as a restore.
     * Truthful nonzero exitStatus when anything failed or was cancelled.
     */
    private suspend fun systemAppOpsManage(call: PlatformToolCall): PlatformToolOutcome {
        advancedSystemGate(DeviceAccessToolCatalog.SYSTEM_APPOPS_MANAGE)?.let { return it }
        val request = PermissionOpsBatchArguments.appOpsManage(call.arguments)
        if (request is PermissionOpsBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PermissionOpsBatchArguments.Request.AppOpsManage
        crossUserRefused(request.userId)?.let { return it }
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(request.items.size)
        for ((index, item) in request.items.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += request.items.size - index
                break
            }
            permissionOpsTargetRefused(item.packageName)?.let {
                failed += 1
                lines += "fail pkg=${item.packageName.take(100)} " +
                    "op=${item.operation} code=${it.code}"
                continue
            }
            // UID scope uses the existing authorization and LIVE peer capability.
            // An older service must never silently downgrade it to a package write.
            if (item.scope == com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_UID) {
                if (!appOpsUidScopeAllowed()) {
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "op=${item.operation} code=uid_scope_not_allowed"
                    continue
                }
                if (!appOpsUidScopeSupported) refreshAppOpsUidScopeSupport()
                if (!appOpsUidScopeSupported) {
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "op=${item.operation} code=uid_scope_unsupported"
                    continue
                }
            }
            val result = withRootGrant(
                call, SystemOperation.APP_OPS_MANAGE, null, destructive = true,
                target = item.packageName,
                packageTargets = settings.advancedSystemTargets,
                appOpsScope = item.scope,
            ) { claim ->
                val controller = rootController
                    ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
                controller.manageAppOps(
                    claim, item.packageName, request.userId,
                    item.operation, item.mode, item.scope,
                )
            }
            when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        ok += 1
                        lines += "ok pkg=${receipt.packageName.take(100)} " +
                            "op=${receipt.operation} requested=${receipt.requestedMode} " +
                            "effective=${receipt.effectiveAfter}" +
                            appOpsScopeSuffix(receipt)
                    } else {
                        failed += 1
                        lines += "fail pkg=${receipt.packageName.take(100)} " +
                            "op=${receipt.operation} code=${receipt.detailCode} " +
                            "effective=${receipt.effectiveBefore}->${receipt.effectiveAfter}" +
                            appOpsScopeSuffix(receipt) +
                            (receipt.failureDetail?.let { " reason=${it.take(60)}" } ?: "")
                    }
                }
                is RootResult.Denied -> {
                    if (result.code == "cancelled") {
                        cancelled = true
                        skipped += request.items.size - index
                        break
                    }
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "op=${item.operation} code=root_${result.code}"
                }
                is RootResult.Unavailable -> {
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "op=${item.operation} code=unavailable_${result.code}"
                }
                is RootResult.Failed -> {
                    failed += 1
                    lines += "fail pkg=${item.packageName.take(100)} " +
                        "op=${item.operation} code=${result.code}"
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure("cancelled", "The AppOps batch was cancelled.")
        }
        val summary = buildString {
            append("appOps requested=").append(request.items.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        val exitStatus = if (failed == 0 && !cancelled) 0 else 1
        return PlatformToolOutcome.Success(summary, exitStatus = exitStatus)
    }

    // ------------------------------------------------------- app-state tools

    /**
     * Fail-closed gate for the advanced app-state group, checked from the
     * CURRENT durable ceilings for every call: base management ceiling, the
     * shared advanced master, the exact allowed tool name and a non-empty
     * selected target set. A disabled master or name refuses AND has already
     * fenced live grants through the setters.
     */
    private fun advancedSystemGate(requiredTool: String): PlatformToolOutcome.Failure? = when {
        !settings.packageManagementAllowed -> PlatformToolOutcome.Failure(
            "management_not_allowed",
            "The user must allow app management in Settings > Phone",
        )
        !settings.advancedSystemManagementAllowed -> PlatformToolOutcome.Failure(
            "advanced_system_not_allowed",
            "The user must turn on advanced app state in Settings > Phone",
        )
        requiredTool !in settings.advancedSystemAllowedTools -> PlatformToolOutcome.Failure(
            "advanced_tool_not_allowed",
            "The user has not allowed this advanced action in Settings > Phone",
        )
        settings.advancedSystemTargets.isEmpty() -> PlatformToolOutcome.Failure(
            "advanced_targets_required",
            "The user must select target apps in Settings > Phone",
        )
        else -> null
    }

    private fun crossUserRefused(userId: Int): PlatformToolOutcome.Failure? =
        if (userId != currentUserId()) {
            PlatformToolOutcome.Failure(
                "cross_user_unsupported",
                "Only the current Android profile is supported for app-state changes.",
            )
        } else {
            null
        }

    private suspend fun systemPackagesSetEnabled(call: PlatformToolCall): PlatformToolOutcome {
        advancedSystemGate(DeviceAccessToolCatalog.SYSTEM_PACKAGES_SET_ENABLED)?.let { return it }
        val request = PackageBatchArguments.setEnabled(call.arguments)
        if (request is PackageBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PackageBatchArguments.Request.SetEnabled
        crossUserRefused(request.userId)?.let { return it }
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(request.packageNames.size)
        for ((index, packageName) in request.packageNames.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += request.packageNames.size - index
                break
            }
            if (packageName !in settings.advancedSystemTargets) {
                failed += 1
                lines += "fail pkg=${packageName.take(100)} code=target_not_authorized"
                continue
            }
            val result = withRootGrant(
                call, SystemOperation.PACKAGE_SET_ENABLED, null, destructive = true,
                target = packageName,
                packageTargets = settings.advancedSystemTargets,
            ) { claim ->
                val controller = rootController
                    ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
                controller.setPackageEnabled(claim, packageName, request.userId, request.state)
            }
            when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        ok += 1
                        lines += "ok pkg=${receipt.packageName.take(100)} " +
                            "state=${receipt.stateAfter}"
                    } else {
                        failed += 1
                        lines += "fail pkg=${receipt.packageName.take(100)} " +
                            "code=${receipt.detailCode} state=${receipt.stateAfter}" +
                            (receipt.failureDetail?.let { " reason=${it.take(60)}" } ?: "")
                    }
                }
                is RootResult.Denied -> {
                    if (result.code == "cancelled") {
                        cancelled = true
                        skipped += request.packageNames.size - index
                        break
                    }
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=root_${result.code}"
                }
                is RootResult.Unavailable -> {
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=unavailable_${result.code}"
                }
                is RootResult.Failed -> {
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=${result.code}"
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure("cancelled", "The set-enabled batch was cancelled.")
        }
        val summary = buildString {
            append("setEnabled state=").append(request.state)
            append(" requested=").append(request.packageNames.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        // Truthful transport status: a partially or fully failed batch is not
        // a zero-exit success; the per-item lines carry the exact receipts.
        val exitStatus = if (failed == 0 && !cancelled) 0 else 1
        return PlatformToolOutcome.Success(summary, exitStatus = exitStatus)
    }

    private suspend fun systemPackagesRemoveForUser(call: PlatformToolCall): PlatformToolOutcome {
        advancedSystemGate(DeviceAccessToolCatalog.SYSTEM_PACKAGES_REMOVE_FOR_USER)?.let { return it }
        val request = PackageBatchArguments.removeForUser(call.arguments)
        if (request is PackageBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PackageBatchArguments.Request.RemoveForUser
        crossUserRefused(request.userId)?.let { return it }
        return runAppStateLifecycleBatch(
            call, request.packageNames,
            SystemOperation.PACKAGE_REMOVE_FOR_USER,
            "removeForUser",
        ) { claim, packageName, controller ->
            controller.removePackageForUser(claim, packageName, request.userId)
        }
    }

    private suspend fun systemPackagesRestore(call: PlatformToolCall): PlatformToolOutcome {
        advancedSystemGate(DeviceAccessToolCatalog.SYSTEM_PACKAGES_RESTORE)?.let { return it }
        val request = PackageBatchArguments.restore(call.arguments)
        if (request is PackageBatchArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as PackageBatchArguments.Request.Restore
        crossUserRefused(request.userId)?.let { return it }
        return runAppStateLifecycleBatch(
            call, request.packageNames,
            SystemOperation.PACKAGE_RESTORE,
            "restore",
        ) { claim, packageName, controller ->
            controller.restorePackage(claim, packageName, request.userId)
        }
    }

    /**
     * Shared per-user lifecycle batch (remove/restore): one real privileged
     * grant per item, cooperative fencing between items, per-item typed
     * receipts with the concise pm failure reason, and a truthful nonzero
     * exit status when anything failed or the batch was partially cancelled.
     */
    private suspend fun runAppStateLifecycleBatch(
        call: PlatformToolCall,
        packageNames: List<String>,
        operation: SystemOperation,
        label: String,
        dispatch: suspend (OperationClaim, String, RootSystemController) -> RootResult<com.floe.android.rootsystem.PackageLifecycleReceipt>,
    ): PlatformToolOutcome {
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(packageNames.size)
        for ((index, packageName) in packageNames.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += packageNames.size - index
                break
            }
            if (packageName !in settings.advancedSystemTargets) {
                failed += 1
                lines += "fail pkg=${packageName.take(100)} code=target_not_authorized"
                continue
            }
            val result = withRootGrant(
                call, operation, null, destructive = true,
                target = packageName,
                packageTargets = settings.advancedSystemTargets,
            ) { claim ->
                val controller = rootController
                    ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
                dispatch(claim, packageName, controller)
            }
            when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    if (receipt.succeeded) {
                        ok += 1
                        lines += "ok pkg=${receipt.packageName.take(100)} " +
                            "present=${receipt.presentAfter}"
                    } else {
                        failed += 1
                        lines += "fail pkg=${receipt.packageName.take(100)} " +
                            "code=${receipt.detailCode} present=${receipt.presentAfter}" +
                            (receipt.failureDetail?.let { " reason=${it.take(60)}" } ?: "")
                    }
                }
                is RootResult.Denied -> {
                    if (result.code == "cancelled") {
                        cancelled = true
                        skipped += packageNames.size - index
                        break
                    }
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=root_${result.code}"
                }
                is RootResult.Unavailable -> {
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=unavailable_${result.code}"
                }
                is RootResult.Failed -> {
                    failed += 1
                    lines += "fail pkg=${packageName.take(100)} code=${result.code}"
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure("cancelled", "The $label batch was cancelled.")
        }
        val summary = buildString {
            append(label).append(" requested=").append(packageNames.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        val exitStatus = if (failed == 0 && !cancelled) 0 else 1
        return PlatformToolOutcome.Success(summary, exitStatus = exitStatus)
    }

    // ---------------------------------------------------------- settings tools

    private suspend fun systemSettingsRead(call: PlatformToolCall): PlatformToolOutcome {
        val request = SettingsToolArguments.read(call.arguments)
        if (request is SettingsToolArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as SettingsToolArguments.Request.Read
        val result = withRootGrant(
            call, SystemOperation.SETTINGS_READ, null, destructive = false,
            target = "${request.namespace}/${request.key}",
        ) { claim ->
            val controller = rootController
                ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.readSetting(claim, request.namespace, request.key)
        }
        return when (result) {
            is RootResult.Ok -> {
                val value = result.value
                PlatformToolOutcome.Success(
                    buildString {
                        append("setting=").append(value.namespace).append('/').append(value.key)
                        append(" present=").append(value.value != null)
                        value.value?.let { append(" value=").append(it) }
                        if (value.deviceWide) append(" scope=device-wide")
                        else append(" user=").append(value.userId)
                    },
                    evidence = listOf(
                        "present=${value.value != null}",
                        if (value.deviceWide) "scope=device-wide" else "user=${value.userId}",
                    ),
                )
            }
            else -> rootOutcome(result) { PlatformToolOutcome.Success("Read.") }
        }
    }

    /**
     * Bounded typed settings batch over the closed table. Every item gets its
     * own real privileged grant and dispatch; a fenced ticket between items
     * skips the rest and the completed receipts are preserved. The summary
     * result= token and the batch exitStatus stay truthful for
     * failed/partial/cancelled batches.
     */
    private suspend fun systemSettingsWrite(call: PlatformToolCall): PlatformToolOutcome {
        if (!settings.packageManagementAllowed) {
            return PlatformToolOutcome.Failure(
                "management_not_allowed",
                "The user must allow app management in Settings > Phone",
            )
        }
        if (!settings.advancedSystemManagementAllowed ||
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE !in settings.advancedSystemAllowedTools
        ) {
            return PlatformToolOutcome.Failure(
                "advanced_settings_not_allowed",
                "The user must enable the advanced system switch and select system.settings.write",
            )
        }
        val request = SettingsToolArguments.write(call.arguments)
        if (request is SettingsToolArguments.Request.Invalid) {
            return PlatformToolOutcome.Failure(request.code)
        }
        request as SettingsToolArguments.Request.Write
        var ok = 0
        var failed = 0
        var skipped = 0
        var cancelled = false
        val lines = ArrayList<String>(request.changes.size)
        for ((index, change) in request.changes.withIndex()) {
            if (platformCallFenced(call)) {
                cancelled = true
                skipped += request.changes.size - index
                break
            }
            val name = "${change.namespace}/${change.key}"
            val result = withRootGrant(
                call, SystemOperation.SETTINGS_WRITE, null, destructive = true, target = "1 settings change(s)",
            ) { claim ->
                val controller = rootController
                    ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
                controller.writeSettings(claim, listOf(change))
            }
            when (result) {
                is RootResult.Ok -> {
                    val item = result.value.items.firstOrNull()
                    if (item != null && item.succeeded) {
                        ok += 1
                        lines += settingsItemLine("ok", item)
                    } else {
                        failed += 1
                        lines += settingsItemLine("fail", item)
                    }
                }
                is RootResult.Denied -> {
                    if (result.code == "cancelled") {
                        cancelled = true
                        skipped += request.changes.size - index
                        break
                    }
                    failed += 1
                    lines += "fail setting=$name code=root_${result.code}"
                }
                is RootResult.Unavailable -> {
                    failed += 1
                    lines += "fail setting=$name code=unavailable_${result.code}"
                }
                is RootResult.Failed -> {
                    failed += 1
                    lines += "fail setting=$name code=${result.code}"
                }
            }
        }
        if (cancelled && ok == 0 && failed == 0) {
            return PlatformToolOutcome.Failure("cancelled", "The settings batch was cancelled.")
        }
        val summary = buildString {
            append("settings requested=").append(request.changes.size)
            append(" ok=").append(ok)
            append(" failed=").append(failed)
            append(" skipped=").append(skipped)
            if (cancelled) append(" result=cancelled")
            lines.forEach { append('\n').append(it.take(180)) }
        }
        return PlatformToolOutcome.Success(
            summary = summary,
            exitStatus = when {
                cancelled && failed > 0 -> 131
                cancelled -> 130
                failed > 0 || ok == 0 -> 1
                else -> 0
            },
        )
    }

    private fun settingsItemLine(kind: String, item: SettingItemReceipt?): String {
        if (item == null) return "$kind setting=? code=receipt_missing"
        return buildString {
            append(kind).append(" setting=").append(item.namespace).append('/').append(item.key)
            append(" action=").append(item.action.name.lowercase())
            append(" old=").append(item.oldValue ?: "absent")
            item.requestedValue?.let { append(" requested=").append(it) }
            append(" effective=").append(item.effectiveValue ?: "absent")
            if (item.deviceWide) append(" scope=device-wide") else append(" user=").append(item.userId)
            if (!item.succeeded) {
                append(" code=").append(item.detailCode)
                item.failureDetail?.let { append(" detail=").append(it.take(60)) }
            }
        }
    }

    // ---------------------------------------------------- system settings UI

    /** The durable gate for the settings sheet and its user actions. */
    private fun systemSettingsCeilingEnabled(): Boolean =
        systemServiceAlive() && settings.packageManagementAllowed &&
            settings.advancedSystemManagementAllowed &&
            DeviceAccessToolCatalog.SYSTEM_SETTINGS_WRITE in settings.advancedSystemAllowedTools

    private fun systemSettingsEntries(): List<com.floe.android.DeviceAccessSystemSettingUi> =
        SettingsKeyPolicy.ALL_SPECS.filter { spec ->
            systemSettingsSnapshot.containsKey(spec.namespace + "/" + spec.key)
        }.map { spec ->
            val id = spec.namespace + "/" + spec.key
            com.floe.android.DeviceAccessSystemSettingUi(
                namespace = spec.namespace,
                key = spec.key,
                deviceWide = spec.deviceWide,
                currentValue = systemSettingsSnapshot[id],
                baselineValue = systemSettingsSnapshot[id],
                kind = when (spec.kind) {
                    SettingsKeyPolicy.ValueKind.INT ->
                        com.floe.android.DeviceAccessSystemSettingKindUi.INT
                    SettingsKeyPolicy.ValueKind.SCALE ->
                        com.floe.android.DeviceAccessSystemSettingKindUi.SCALE
                },
                minInclusive = spec.minInclusive,
                maxInclusive = spec.maxInclusive,
            )
        }

    /** Live stored values for every closed key, one read lease per key. */
    private suspend fun refreshSystemSettings() {
        val controller = rootController
        if (controller == null || !systemServiceAlive()) {
            systemSettingsSnapshot = emptyMap()
            mutableSystemSettingsUi.value = com.floe.android.DeviceAccessSystemSettingsUiState(
                enabled = false,
            )
            return
        }
        val values = HashMap<String, String?>()
        for (spec in SettingsKeyPolicy.ALL_SPECS) {
            val result = withUserActionGrant(
                SystemOperation.SETTINGS_READ,
                "${spec.namespace}/${spec.key}",
                destructive = false,
            ) { claim -> controller.readSetting(claim, spec.namespace, spec.key) }
            (result as? RootResult.Ok)?.let {
                values[spec.namespace + "/" + spec.key] = it.value.value
            }
        }
        systemSettingsSnapshot = values
        mutableSystemSettingsUi.value = com.floe.android.DeviceAccessSystemSettingsUiState(
            entries = systemSettingsEntries(),
            enabled = systemSettingsCeilingEnabled(),
            lastResult = if (values.size < SettingsKeyPolicy.ALL_SPECS.size) {
                context.getString(R.string.device_access_system_settings_read_failed,
                    SettingsKeyPolicy.ALL_SPECS.size - values.size)
            } else null,
        )
        publish()
    }

    private fun applySystemSettingChanges(
        changes: List<com.floe.android.DeviceAccessSystemSettingChangeUi>,
    ) {
        if (mutableSystemSettingsUi.value.busy) return
        if (!systemSettingsCeilingEnabled()) {
            mutableSystemSettingsUi.value = mutableSystemSettingsUi.value.copy(enabled = false)
            return
        }
        val typed = changes.take(SettingsKeyPolicy.MAX_BATCH_CHANGES).map {
            SettingsChange(
                it.namespace,
                it.key,
                if (it.delete) SettingsChangeAction.DELETE else SettingsChangeAction.PUT,
                if (it.delete) null else it.value,
            )
        }
        if (typed.isEmpty() || !systemSettingsWriteInFlight.compareAndSet(false, true)) return
        mutableSystemSettingsUi.value = mutableSystemSettingsUi.value.copy(busy = true)
        publish()
        scope.launch(io) {
            try {
            val result = withUserActionGrant(
                SystemOperation.SETTINGS_WRITE,
                "${typed.size} settings change(s)",
                destructive = true,
                timeoutMillis = rootOperationTimeoutMillis(SystemOperation.SETTINGS_WRITE) * typed.size,
            ) { claim ->
                rootController?.writeSettings(claim, typed)
                    ?: RootResult.Unavailable("service_not_alive")
            }
            val last = when (result) {
                is RootResult.Ok -> {
                    val receipt = result.value
                    context.getString(R.string.device_access_system_settings_result,
                        receipt.ok, receipt.failed)
                }
                is RootResult.Denied -> context.getString(R.string.device_access_system_settings_failed)
                is RootResult.Unavailable -> context.getString(R.string.device_access_system_settings_failed)
                is RootResult.Failed -> context.getString(R.string.device_access_system_settings_failed)
            }
            refreshSystemSettings()
            mutableSystemSettingsUi.value = mutableSystemSettingsUi.value.copy(
                busy = false,
                lastResult = last.take(240),
            )
            publish()
            } finally {
                systemSettingsWriteInFlight.set(false)
                mutableSystemSettingsUi.value = mutableSystemSettingsUi.value.copy(busy = false)
                publish()
            }
        }
    }

    private fun restoreSystemSetting(
        entry: com.floe.android.DeviceAccessSystemSettingUi,
        baseline: String?,
    ) {
        if (!systemSettingsCeilingEnabled()) return
        applySystemSettingChanges(
            listOf(
                com.floe.android.DeviceAccessSystemSettingChangeUi(
                    namespace = entry.namespace,
                    key = entry.key,
                    value = baseline ?: "",
                    delete = baseline == null,
                ),
            ),
        )
    }

    /**
     * The USER's own settings action (sheet Apply/Restore): consent is the
     * durable ceiling checked before dispatch; no model ticket and no
     * fabricated approval id exists. The grant still travels the real
     * canonical path — one host-issued, task/run/epoch-bound grant registered
     * with the service and revoked in a finally — and the authority check
     * consults the same live registry shape as model tickets.
     */
    private class UserActionGrant(
        val taskId: String,
        val runId: String,
        val epoch: Long,
        val operations: Set<SystemOperation>,
        val packageManagementAllowed: Boolean,
        val expectedTarget: String?,
        val expiresAtMillis: Long,
        val cancelled: AtomicBoolean = AtomicBoolean(false),
    ) {
        fun matches(claim: OperationClaim): Boolean =
            claim.taskId == taskId && claim.runId == runId && claim.epoch == epoch

        fun live(): Boolean = !cancelled.get() && System.currentTimeMillis() < expiresAtMillis
    }

    private val userActionGrants = ConcurrentHashMap<String, UserActionGrant>()

    private suspend fun <T> withUserActionGrant(
        operation: SystemOperation,
        target: String?,
        destructive: Boolean,
        packageTargets: Set<String> = emptySet(),
        appOpsScope: String = com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_PACKAGE,
        timeoutMillis: Long = rootOperationTimeoutMillis(operation),
        block: suspend (OperationClaim) -> RootResult<T>,
    ): RootResult<T> {
        if (rootRebuilding || rootConfigDirty) return RootResult.Unavailable("policy_updating")
        val controller = rootController ?: return RootResult.Unavailable("service_not_alive")
        if (!systemServiceAlive()) return RootResult.Unavailable("service_not_alive")
        val epoch = host.nativeRootEpoch()?.takeIf { it > 0 }
            ?: return RootResult.Unavailable("no_epoch")
        val readOnly = operation in readOnlyOperations
        val roots = cachedRoots.ifEmpty { FileRootCatalog.standardRoots() }
        val decision = FileScopePolicy.decide(
            roots = roots,
            selectedIds = settings.fileRootIds,
            requestedId = null,
            fileOperation = false,
            writeOperation = !readOnly,
            appDataUsable = appDataUsable(),
            globalWrites = settings.fileWritesAllowed,
        )
        val routing = when (decision) {
            is FileScopePolicy.Decision.Denied -> return RootResult.Denied(decision.code)
            is FileScopePolicy.Decision.Ok -> decision.routing
        }
        val management = SystemOperation.isPackageManagement(operation) &&
            settings.packageManagementAllowed
        val now = System.currentTimeMillis()
        val grantId = "usersettings:" + UUID.randomUUID().toString()
        val request = GrantRequest(
            grantId = grantId,
            taskId = "user-settings-action",
            runId = UUID.randomUUID().toString(),
            epoch = epoch,
            expiresAtMillis = now + timeoutMillis + 5_000L,
            scopes = listOf(
                ScopeRoot(
                    scopeId = routing.root.id,
                    path = routing.root.path,
                    writable = routing.writable && !readOnly,
                ),
            ),
            operations = setOf(operation),
            packageManagementAllowed = management,
            appOpsUidScopeAllowed = operation == SystemOperation.APP_OPS_MANAGE &&
                appOpsScope == com.floe.android.rootsystem.policy.PermissionOpsPolicy.SCOPE_UID,
            packageTargets = packageTargets,
        )
        when (val registered = controller.registerGrant(request)) {
            is RootResult.Ok -> Unit
            is RootResult.Denied -> return RootResult.Denied(registered.code, registered.message)
            is RootResult.Unavailable -> return RootResult.Unavailable(registered.code)
            is RootResult.Failed -> return RootResult.Failed(registered.code, registered.message)
        }
        val claim = OperationClaim(
            taskId = request.taskId,
            runId = request.runId,
            epoch = epoch,
            grantId = grantId,
            requestId = UUID.randomUUID().toString(),
            callId = null,
        )
        val entry = UserActionGrant(
            taskId = claim.taskId,
            runId = claim.runId,
            epoch = epoch,
            operations = setOf(operation),
            packageManagementAllowed = management,
            expectedTarget = target,
            expiresAtMillis = request.expiresAtMillis,
        )
        userActionGrants[grantId] = entry
        try {
            return withTimeout(timeoutMillis) { block(claim) }
        } catch (_: Throwable) {
            return RootResult.Failed("timeout")
        } finally {
            entry.cancelled.set(true)
            userActionGrants.remove(grantId)
            runCatching { controller.revokeGrant(grantId) }
        }
    }

    /** True when the native ticket or user stop fences this call. */
    private fun platformCallFenced(call: PlatformToolCall): Boolean =
        userStopped ||
            !PlatformToolsNativeLive.isLive(call.claim) ||
            PlatformToolsNativeLive.shouldStop(call.claim)

    private fun buildRows(title: String, rows: List<String>, truncated: Boolean = false): String =
        buildString {
            append(title).append("=").append(rows.size)
            rows.take(MAX_LIST_ROWS).forEach { append('\n').append(it.take(180)) }
            if (rows.size > MAX_LIST_ROWS) {
                append("\n… ").append(rows.size - MAX_LIST_ROWS).append(" more")
            }
            if (truncated) append("\ntruncated=true")
        }

    private fun networkSummary(diagnostics: NetworkDiagnostics): String = buildString {
        append("interfaces=").append(diagnostics.interfaces.size)
        diagnostics.interfaces.take(8).forEach { iface ->
            append('\n').append(iface.name.take(40))
                .append('|').append(if (iface.up) "up" else "down")
                .append('|').append(iface.addresses.take(4).joinToString(",").take(120))
        }
        append("\nroutes=").append(diagnostics.routes.size)
        diagnostics.routes.take(8).forEach { route ->
            append('\n').append(route.interfaceName.take(24))
                .append('|').append(route.destination.take(60))
                .append('|').append(route.gateway?.take(48) ?: "-")
                .append('|').append(if (route.defaultRoute) "default" else "")
        }
        append("\ntransports=").append(diagnostics.activeTransports.take(8).joinToString(","))
    }

    // ------------------------------------------------------------- root authority

    private inner class RootAuthority : RootSystemAuthority {
        override fun authorize(request: RootOperationRequest): AuthorityDecision {
            val entry = rootGrants[request.claim.grantId]
                ?: return authorizeUserAction(request)
            if (!entry.matches(request.claim)) {
                return AuthorityDecision.Denied("grant_mismatch")
            }
            if (request.operation !in entry.operations) {
                return AuthorityDecision.Denied("operation")
            }
            if (SystemOperation.isPackageManagement(request.operation) &&
                !entry.packageManagementAllowed
            ) {
                return AuthorityDecision.Denied("management")
            }
            if (entry.expectedTarget != null && request.target != entry.expectedTarget) {
                return AuthorityDecision.Denied("target_mismatch")
            }
            if (!entry.ticketLive()) return AuthorityDecision.Denied("ticket_fenced")
            if (System.currentTimeMillis() >= entry.expiresAtMillis) {
                return AuthorityDecision.Denied("expired")
            }
            return AuthorityDecision.Allowed
        }

        override fun isCancelled(request: RootOperationRequest): Boolean {
            rootGrants[request.claim.grantId]?.let { return it.ticketCancelled() }
            val grant = userActionGrants[request.claim.grantId] ?: return true
            return !grant.live()
        }

        /** The USER's own sheet action: same checks, host-owned grant entry. */
        private fun authorizeUserAction(request: RootOperationRequest): AuthorityDecision {
            val grant = userActionGrants[request.claim.grantId]
                ?: return AuthorityDecision.Denied("grant_unknown")
            if (!grant.matches(request.claim)) return AuthorityDecision.Denied("grant_mismatch")
            if (request.operation !in grant.operations) return AuthorityDecision.Denied("operation")
            if (SystemOperation.isPackageManagement(request.operation) &&
                !grant.packageManagementAllowed
            ) {
                return AuthorityDecision.Denied("management")
            }
            if (grant.expectedTarget != null && request.target != grant.expectedTarget) {
                return AuthorityDecision.Denied("target_mismatch")
            }
            return if (grant.live()) {
                AuthorityDecision.Allowed
            } else {
                AuthorityDecision.Denied("expired")
            }
        }
    }

    /** Called by the pump when a claimed ticket must stop. */
    private fun cancelBackend(call: PlatformToolCall) {
        // Device interaction: fence the whole phone-control service session;
        // the module rejects the in-flight call and the pump settles it as
        // cancelled, never success. Exact canonical names (the legacy
        // phone.* spellings are the same values through the retained
        // constants) — never a prefix rule, so unknown phone.* tools never
        // stop the service session.
        if (call.tool in DeviceAccessToolCatalog.DEVICE_INTERACTION_NAMES) {
            // The actual phone session is being stopped: its RAM-only screen
            // consent cannot outlive that service state.
            screenShare.clear()
            runCatching { phoneClient?.stop() }
            return
        }
        val entry = rootGrants.values.firstOrNull { it.platformClaim == call.claim } ?: return
        entry.cancelled.set(true)
        val claim = entry.operationClaim ?: return
        scope.launch(io) {
            runCatching { rootController?.cancelOperation(claim) }
        }
    }

    private companion object {
        const val CREDENTIAL_NAMESPACE = "floe-system-access-v1"
        const val KEY_PHONE_PAUSE = "phone_paused_run_v1"
        const val KEY_PACKAGES = "allowed_packages"
        const val KEY_ROOTS = "file_roots"
        const val KEY_APP_DATA_ROOTS = "app_data_roots"
        const val LOCAL_NETWORK_API = 37
        const val LOCAL_PAIRING_ENDPOINT = "adb-tls-pairing._tcp.local"
        /** Legacy persisted choice; removed at startup, never restored. */
        const val KEY_SCREEN_SCOPE = "screen_scope"
        const val KEY_FILE_WRITES = "file_writes"
        const val KEY_WHOLE_SCREEN = "whole_screen"
        const val KEY_MANAGEMENT = "management"
        const val KEY_ADVANCED_SYSTEM = "advanced_system"
        const val KEY_ADVANCED_TOOLS = "advanced_system_tools"
        const val KEY_ADVANCED_TARGETS = "advanced_system_targets"
        const val KEY_ADB_ENABLED = "adb_enabled"
        const val MAX_TARGET_PACKAGES = 64

        /** Settled Host outer ceiling for the nine bounded batch mutations. */
        const val HOST_BATCH_OUTER_TIMEOUT_MILLIS = 1_020_000L
        const val MAX_LISTED_PACKAGES = 200
        /** Exact-name advanced lookup: same shape the service already checks. */
        val ADVANCED_LOOKUP_NAME = Regex("[A-Za-z0-9._-]{1,255}")
        const val MAX_LIVE_TASK_SCAN = 8
        const val MAX_DIGEST_NODES = 28
        const val MAX_LIST_ROWS = 24
        const val MAX_WRITE_BYTES = 48_000
        const val ROOT_GRANT_LIFETIME_MILLIS = 30_000L
        /** One UI-initiated permission/AppOps action: register and revoke. */
        const val USER_ACTION_GRANT_MILLIS = 120_000L
        val FILE_OPERATIONS = setOf(
            SystemOperation.FILE_LIST,
            SystemOperation.FILE_READ,
            SystemOperation.FILE_WRITE,
            SystemOperation.FILE_MOVE,
            SystemOperation.FILE_DELETE,
        )
    }
}
