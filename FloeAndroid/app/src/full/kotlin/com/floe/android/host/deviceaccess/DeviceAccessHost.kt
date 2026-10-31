// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import com.floe.android.DeviceAccessAccessibilityUi
import com.floe.android.DeviceAccessActiveTaskUi
import com.floe.android.DeviceAccessAdbUi
import com.floe.android.DeviceAccessBusyUi
import com.floe.android.DeviceAccessCallbacks
import com.floe.android.DeviceAccessFileRootUi
import com.floe.android.DeviceAccessFileRootKindUi
import com.floe.android.DeviceAccessPackageUi
import com.floe.android.DeviceAccessPairingDiscoveryUi
import com.floe.android.DeviceAccessPresentationState
import com.floe.android.DeviceAccessRootUi
import com.floe.android.DeviceAccessScreenScopeUi
import com.floe.android.DeviceAccessTargetsUi
import com.floe.android.DeviceAccessTaskControlUi
import com.floe.android.DeviceAccessTaskPhaseUi
import com.floe.android.DeviceAccessUiError
import com.floe.android.R
import com.floe.android.credentials.AndroidKeystoreCredentialStore
import com.floe.android.host.RuntimeHost
import com.floe.android.host.settings.DistributionSettingsFeature
import com.floe.android.phonecontrol.PhoneControlAction
import com.floe.android.phonecontrol.PhoneControlAuthority
import com.floe.android.phonecontrol.PhoneControlBlocker
import com.floe.android.phonecontrol.PhoneControlClient
import com.floe.android.phonecontrol.PhoneControlDenial
import com.floe.android.phonecontrol.PhoneControlFailure
import com.floe.android.phonecontrol.PhoneControlGrant
import com.floe.android.phonecontrol.PhoneControlModule
import com.floe.android.phonecontrol.PhoneControlObservation
import com.floe.android.phonecontrol.PhoneControlObserveRequest
import com.floe.android.phonecontrol.PhoneControlOwner
import com.floe.android.phonecontrol.PhoneControlPrincipal
import com.floe.android.phonecontrol.PhoneControlResult
import com.floe.android.phonecontrol.PhoneControlScreenshotRequest
import com.floe.android.phonecontrol.PhoneControlScrollDirection
import com.floe.android.phonecontrol.PhoneControlStatus
import com.floe.android.phonecontrol.PhoneControlSwipeDirection
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
import com.floe.android.rootsystem.SystemOperation
import com.floe.android.rootsystem.policy.FloePackageFamily
import java.nio.charset.CodingErrorAction
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

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
 *  - phone control is armed ONLY by an explicit user gesture on the visible
 *    task, never by a model/tool call;
 *  - a user Stop/Takeover/disable fences queued platform work, cancels the real
 *    in-flight backend operation and sends run cancel through the existing
 *    conversation authority. No automatic re-arm exists.
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
        val screenScope: DeviceAccessScreenScopeUi = DeviceAccessScreenScopeUi.OFF,
        val wholeScreenConsent: Boolean = false,
        val packageManagementAllowed: Boolean = false,
        val adbEnabled: Boolean = false,
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

    private val activation = PhoneControlModule.activation(context)
    private var phoneClient: PhoneControlClient? = null
    private var rootController: RootSystemController? = null
    private var rootCredentials: com.floe.android.contracts.CredentialStore? = null

    @Volatile
    private var settings = AccessSettings()
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
    private var packagesLoaded = false

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

    @Volatile
    private var recentOwner: PhoneControlOwner? = null

    @Volatile
    private var recentTitle: String? = null

    private var pairingSessionOpen = false
    private var pairingPortInput = ""
    private var discoveredPairingPort: Int? = null
    private var pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
    private var pairingJob: Job? = null

    /** RAM-only code while the API 37 local-network permission flow is pending. */
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

    val callbacks: DeviceAccessCallbacks = DeviceAccessCallbacks(
        onOpenAccessibilitySettings = ::openAccessibilitySettings,
        onRefresh = ::refreshFromUser,
        onArmPhoneControl = ::armVisibleTask,
        onStopActiveTask = { stopActiveTask(takeOver = false) },
        onTakeOverActiveTask = { stopActiveTask(takeOver = true) },
        onAllowedPackagesChange = ::setAllowedPackages,
        onFileRootsChange = ::setFileRoots,
        onAddAppDataRoot = ::addAppDataRoot,
        onFileWritesChange = ::setFileWrites,
        onWholeScreenConsentChange = ::setWholeScreenConsent,
        onPackageManagementChange = ::setPackageManagement,
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
    )

    // ------------------------------------------------------------- lifecycle

    fun start() {
        if (started || closed) return
        started = true
        // A notification from a previous process is stale: pairing state is
        // RAM-only and never restored across process death.
        cancelPairingNotification()
        settings = loadSettings()
        refreshRootCatalog()
        // Root is default-off after every process start. Previously selected
        // other-app data folders are NOT silently active again; they require
        // an explicit re-add while the Root tier is actually live.
        if (!appDataUsable()) pruneAppDataRoots(rebuild = false)
        phoneStatus = runCatching { PhoneControlModule.statusSnapshot() }
            .getOrDefault(phoneStatus)
        phoneClient = runCatching {
            PhoneControlModule.client(context, PhoneControlAuthority(::authorizePhone))
        }.getOrNull()
        ensureRootController()
        statusJobs += scope.launch {
            PhoneControlModule.status.collect { status ->
                phoneStatus = status
                publish()
            }
        }
        // The module-level flows survive a controller rebuild; a per-controller
        // collector would be cancelled by the next config rebuild.
        statusJobs += scope.launch {
            RootSystemModule.adbStatus.collect { status ->
                adbStatus = status
                onRootStateChanged()
            }
        }
        statusJobs += scope.launch {
            RootSystemModule.rootStatus.collect { status ->
                rootStatus = status
                onRootStateChanged()
            }
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
        pairingJob?.cancel()
        pairingJob = null
        wipePendingPairingCode()
        val drained = pump?.stopAndJoin() ?: true
        if (!drained) return false
        closeBackends()
        return true
    }

    fun onRootStopped() {
        pairingJob?.cancel()
        pairingJob = null
        wipePendingPairingCode()
        pump?.forceClose()
        closeBackends()
        pruneAppDataRoots(rebuild = false)
        rootTierWasUsable = false
        armedOwner = null
        recentOwner = null
        recentTitle = null
        userStopped = false
        publish()
    }

    fun onActivityResumed() {
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
            if (!packagesLoaded) refreshPackages()
            publish()
        }
    }

    fun onActivityPaused() = Unit

    fun close() {
        if (closed) return
        closed = true
        pairingJob?.cancel()
        wipePendingPairingCode()
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
        val scope = runCatching {
            DeviceAccessScreenScopeUi.valueOf(
                preferences.getString(KEY_SCREEN_SCOPE, null)
                    ?: DeviceAccessScreenScopeUi.OFF.name)
        }.getOrDefault(DeviceAccessScreenScopeUi.OFF)
        return AccessSettings(
            allowedPackages = packages,
            fileRootIds = roots,
            appDataPaths = appData,
            fileWritesAllowed = preferences.getBoolean(KEY_FILE_WRITES, false),
            screenScope = scope,
            wholeScreenConsent = preferences.getBoolean(KEY_WHOLE_SCREEN, false),
            packageManagementAllowed = preferences.getBoolean(KEY_MANAGEMENT, false),
            adbEnabled = preferences.getBoolean(KEY_ADB_ENABLED, false),
        )
    }

    private fun persist() {
        preferences.edit()
            .putStringSet(KEY_PACKAGES, HashSet(settings.allowedPackages))
            .putStringSet(KEY_ROOTS, HashSet(settings.fileRootIds))
            .putStringSet(KEY_APP_DATA_ROOTS, HashSet(settings.appDataPaths))
            .putString(KEY_SCREEN_SCOPE, settings.screenScope.name)
            .putBoolean(KEY_FILE_WRITES, settings.fileWritesAllowed)
            .putBoolean(KEY_WHOLE_SCREEN, settings.wholeScreenConsent)
            .putBoolean(KEY_MANAGEMENT, settings.packageManagementAllowed)
            .putBoolean(KEY_ADB_ENABLED, settings.adbEnabled)
            .apply()
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
        settings = settings.copy(wholeScreenConsent = enabled)
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

    private fun setScreenScope(scope: DeviceAccessScreenScopeUi) {
        if (busy != DeviceAccessBusyUi.NONE) return
        settings = settings.copy(screenScope = scope)
        persist()
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
    }

    private fun refreshFromUser() {
        if (busy != DeviceAccessBusyUi.NONE) return
        error = null
        scope.launch(io) {
            refreshRootCatalog()
            refreshControllerStatus()
            refreshPackages()
            publish()
        }
    }

    private suspend fun refreshPackages() {
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
                .take(MAX_LISTED_PACKAGES)
                .toList()
        } catch (_: Throwable) {
            emptyList()
        }
        installedPackages = packages
        packagesLoaded = true
    }

    private fun currentCandidate(): TaskCandidate? {
        val conversationId = try {
            host.conversations.currentVisibleConversationId()
        } catch (_: Throwable) {
            null
        } ?: return null
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

    private fun titleFor(owner: PhoneControlOwner): String =
        if (recentOwner == owner) {
            recentTitle?.takeIf { it.isNotBlank() }
                ?: context.getString(R.string.device_access_current_task)
        } else {
            context.getString(R.string.device_access_current_task)
        }

    // ------------------------------------------------------------ presentation

    private fun publish() {
        if (closed) return
        val candidate = currentCandidate()
        val activeOwner = armedOwner ?: candidate?.owner?.takeIf { !userStopped }
            ?: recentOwner?.takeIf { !userStopped }
        val active = if (activeOwner == null) null else {
            val phase = when {
                armedOwner == activeOwner -> DeviceAccessTaskPhaseUi.RUNNING
                candidate?.owner == activeOwner -> candidate.phase
                userStopped && lastStoppedOwner == activeOwner -> DeviceAccessTaskPhaseUi.TAKEN_OVER
                else -> DeviceAccessTaskPhaseUi.RUNNING
            }
            DeviceAccessActiveTaskUi(titleFor(activeOwner), phase)
        }
        val control = when {
            armedOwner != null -> DeviceAccessTaskControlUi.ARMED
            activeOwner != null && userStopped && lastStoppedOwner == activeOwner ->
                DeviceAccessTaskControlUi.STOPPED
            else -> DeviceAccessTaskControlUi.OFF
        }
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
            wholeScreenConsent = settings.wholeScreenConsent,
            windowScreenshotCapable = Build.VERSION.SDK_INT >= 34,
        )
        mutablePresentation.value = DeviceAccessPresentationState(
            accessibility = accessibilityUi(),
            adb = adbUi(),
            root = rootUi(),
            screenScope = if (active == null) DeviceAccessScreenScopeUi.OFF else settings.screenScope,
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
        val candidate = currentCandidate()
        val owner = candidate?.owner ?: recentOwner
        if (owner == null) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_no_task), "no_task")
            publish()
            return
        }
        val title = if (candidate != null && candidate.owner == owner) {
            candidate.title
        } else {
            titleFor(owner)
        }
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
        busy = DeviceAccessBusyUi.PHONE_ARM
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
                when (val result = client.arm(principal)) {
                    is PhoneControlResult.Ok -> {
                        armedOwner = owner
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

    private fun stopActiveTask(takeOver: Boolean) {
        if (busy != DeviceAccessBusyUi.NONE) return
        val owner = armedOwner ?: recentOwner ?: currentCandidate()?.owner ?: return
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
            lastStoppedOwner = owner
            armedOwner = null
            recentOwner = owner
            // Both scope choices end with the user's stop/takeover; a later
            // task must ask again instead of silently inheriting screen access.
            if (settings.screenScope != DeviceAccessScreenScopeUi.OFF) {
                settings = settings.copy(screenScope = DeviceAccessScreenScopeUi.OFF)
                persist()
            }
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
                isCurrent = { !closed },
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
        wipePendingPairingCode()
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.UNAVAILABLE
        onLocalNetworkDenied(code)
    }

    private fun wipePendingPairingCode() {
        pendingPairingCode?.fill('\u0000')
        pendingPairingCode = null
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
        pairingSessionOpen = true
        discoveredPairingPort = null
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
        error = null
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
        val port = discoveredPairingPort
            ?: AdbPairingPortDiscovery.parsePort(pairingPortInput)
        if (port == null) {
            error = DeviceAccessUiError(
                context.getString(R.string.device_access_error_pairing_port), "pairing_port")
            publish()
            return
        }
        wipePendingPairingCode()
        val chars = code.toCharArray()
        pendingPairingCode = chars
        busy = DeviceAccessBusyUi.PAIRING
        error = null
        publish()
        val started = withLocalPairingPermission(
            owner = "adb-pairing-submit",
            onDenied = ::onPairingLocalNetworkDenied,
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
        scope.launch(io) {
            val chars = pendingPairingCode
            if (chars == null) {
                busy = DeviceAccessBusyUi.NONE
                publish()
                return@launch
            }
            try {
                val result = controller.pair(port, chars)
                when (result) {
                    PairingResult.Success -> {
                        pairingSessionOpen = false
                        discoveredPairingPort = null
                        pairingPortInput = ""
                        pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
                        cancelPairingNotification()
                        error = null
                    }
                    PairingResult.InvalidCode -> error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_code), "invalid_code")
                    PairingResult.Timeout -> error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_timeout), "timeout")
                    is PairingResult.Unsupported -> error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_unsupported), result.code)
                    is PairingResult.Failed -> error = DeviceAccessUiError(
                        context.getString(R.string.device_access_error_pairing_failed), result.code)
                }
            } catch (_: Throwable) {
                error = DeviceAccessUiError(
                    context.getString(R.string.device_access_error_pairing_failed), "pair")
            } finally {
                wipePendingPairingCode()
                refreshControllerStatus()
                busy = DeviceAccessBusyUi.NONE
                publish()
                tryRebuildRootController()
            }
        }
    }

    private fun cancelPairing() {
        pairingSessionOpen = false
        discoveredPairingPort = null
        pairingPortInput = ""
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
        wipePendingPairingCode()
        if (busy == DeviceAccessBusyUi.PAIRING) busy = DeviceAccessBusyUi.NONE
        cancelPairingNotification()
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
            onDenied = ::onLocalNetworkDenied,
        ) {
            scope.launch(io) {
                try {
                    val result = rootController?.startAdbService()
                    if (result != null) applyAccessResult(result)
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
        pairingSessionOpen = false
        discoveredPairingPort = null
        pairingPortInput = ""
        pairingDiscovery = DeviceAccessPairingDiscoveryUi.IDLE
        cancelPairingNotification()
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

    private fun applyAccessResult(result: AccessActionResult) {
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

    private fun postPairingNotification() {
        try {
            val manager = context.getSystemService(android.app.NotificationManager::class.java)
                ?: return
            if (Build.VERSION.SDK_INT >= 26) {
                val channel = android.app.NotificationChannel(
                    PAIRING_CHANNEL,
                    context.getString(R.string.device_access_pairing_notification_channel),
                    android.app.NotificationManager.IMPORTANCE_DEFAULT,
                )
                manager.createNotificationChannel(channel)
            }
            val intent = Intent(context, com.floe.android.MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val pending = android.app.PendingIntent.getActivity(
                context,
                PAIRING_NOTIFICATION_ID,
                intent,
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or
                    android.app.PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                android.app.Notification.Builder(context, PAIRING_CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                android.app.Notification.Builder(context)
            }
            val notification = builder
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(context.getString(R.string.device_access_pairing_notification_title))
                .setContentText(context.getString(R.string.device_access_pairing_notification_text))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()
            manager.notify(PAIRING_NOTIFICATION_ID, notification)
        } catch (_: Throwable) {
            // Notification is a convenience only; pairing remains available in
            // the page and never depends on it.
        }
    }

    private fun cancelPairingNotification() {
        runCatching {
            context.getSystemService(android.app.NotificationManager::class.java)
                ?.cancel(PAIRING_NOTIFICATION_ID)
        }
    }

    // -------------------------------------------------------------- availability

    private fun systemServiceAlive(): Boolean =
        (settings.adbEnabled && adbStatus is AdbStatus.ServiceAlive) ||
            rootStatus is RootStatus.Enabled

    private fun phoneServiceUsable(): Boolean {
        if (!phoneStatus.connected || !phoneStatus.enabled) return false
        return when (phoneStatus.blocker) {
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
                screenScopeEnabled = state.screenScope != DeviceAccessScreenScopeUi.OFF,
                wholeScreenCaptureConsent = state.targets.wholeScreenConsent,
                windowScreenshotCapable = Build.VERSION.SDK_INT >= 34,
                systemServiceAlive = systemServiceAlive(),
                fileRootsSelected = effectiveSelectedRoots().isNotEmpty(),
                fileWritesAllowed = state.targets.fileWritesAllowed,
                packageManagementAllowed = state.targets.packageManagementAllowed,
            ),
        )
    }

    // ------------------------------------------------------------ phone authority

    private fun authorizePhone(principal: PhoneControlPrincipal): PhoneControlGrant? {
        if (closed) return null
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
            allowScreenshot = screenshotCeiling(),
            generation = principal.generation,
            grantID = principal.grantID,
        )
    }

    /** Screen content ceiling. Display capture additionally requires explicit
     * whole-screen consent in the tool handler; window capture does not. */
    private fun screenshotCeiling(): Boolean =
        settings.screenScope != DeviceAccessScreenScopeUi.OFF

    // -------------------------------------------------------------- tool entry

    private suspend fun executeTool(call: PlatformToolCall): PlatformToolOutcome =
        when (call.tool) {
            DeviceAccessToolCatalog.PHONE_OBSERVE -> phoneObserve(call)
            DeviceAccessToolCatalog.PHONE_ACT -> phoneAct(call)
            DeviceAccessToolCatalog.PHONE_SCREENSHOT -> phoneScreenshot(call)
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
            else -> PlatformToolOutcome.Failure("unknown_tool")
        }

    // ---------------------------------------------------------------- phone tools

    private fun ownerOf(call: PlatformToolCall) =
        PhoneControlOwner(call.taskID, call.runID)

    private fun phonePrincipal(call: PlatformToolCall): PhoneControlPrincipal? {
        if (userStopped) return null
        val owner = ownerOf(call)
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

    private fun phonePrecondition(call: PlatformToolCall, requireApproval: Boolean): PlatformToolOutcome? {
        rememberToolTask(call)
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

    private suspend fun phoneObserve(call: PlatformToolCall): PlatformToolOutcome {
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
                    if (userStopped || armedOwner != ownerOf(call)) {
                        PlatformToolOutcome.Failure("phone_stopped_by_user")
                    } else {
                        observationOutcome(result.value)
                    }
                }
                is PhoneControlResult.Denied -> deniedOutcome(result.reason)
                is PhoneControlResult.Unavailable -> unavailableOutcome(result.reason)
                is PhoneControlResult.Failed -> failedOutcome(result.reason)
            }
        } catch (_: Throwable) {
            return PlatformToolOutcome.Failure("phone_timeout")
        } finally {
            unbindPhoneCall(call)
        }
    }

    private suspend fun phoneAct(call: PlatformToolCall): PlatformToolOutcome {
        phonePrecondition(call, requireApproval = true)?.let { return it }
        val client = phoneClient ?: return PlatformToolOutcome.Failure("phone_unavailable")
        val principal = phonePrincipal(call)
            ?: return PlatformToolOutcome.Failure("phone_arm_required")
        val observationId = call.arguments.optString("observationId")
        if (observationId.isEmpty()) {
            return PlatformToolOutcome.Failure("invalid_arguments")
        }
        val action = parsePhoneAction(call.arguments)
            ?: return PlatformToolOutcome.Failure("invalid_arguments")
        bindPhoneCall(call)
        try {
            return when (val result = withTimeout(20_000) {
                client.perform(principal, observationId, action)
            }) {
                is PhoneControlResult.Ok -> {
                    if (userStopped || armedOwner != ownerOf(call)) {
                        PlatformToolOutcome.Failure("phone_stopped_by_user")
                    } else {
                        actionOutcome(result.value)
                    }
                }
                is PhoneControlResult.Denied -> deniedOutcome(result.reason)
                is PhoneControlResult.Unavailable -> unavailableOutcome(result.reason)
                is PhoneControlResult.Failed -> failedOutcome(result.reason)
            }
        } catch (_: Throwable) {
            return PlatformToolOutcome.Failure("phone_timeout")
        } finally {
            unbindPhoneCall(call)
        }
    }

    private suspend fun phoneScreenshot(call: PlatformToolCall): PlatformToolOutcome {
        phonePrecondition(call, requireApproval = false)?.let { return it }
        val client = phoneClient ?: return PlatformToolOutcome.Failure("phone_unavailable")
        val principal = phonePrincipal(call)
            ?: return PlatformToolOutcome.Failure("phone_arm_required")
        if (!screenshotCeiling()) {
            return PlatformToolOutcome.Failure(
                "screen_scope_off", "Screen content sharing is off in Settings > Phone")
        }
        val observationId = call.arguments.optString("observationId").ifEmpty { null }
        if (observationId != null && Build.VERSION.SDK_INT < 34) {
            return PlatformToolOutcome.Failure(
                "window_screenshot_unsupported",
                "Window screenshots need Android 14; no silent display fallback is used",
            )
        }
        if (observationId == null && !settings.wholeScreenConsent) {
            return PlatformToolOutcome.Failure(
                "whole_screen_consent_required",
                "The user must allow whole-screen capture in Settings > Phone",
            )
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
                    if (userStopped || armedOwner != ownerOf(call)) {
                        result.value.bytes.fill(0)
                        return PlatformToolOutcome.Failure("phone_stopped_by_user")
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
                is PhoneControlResult.Failed -> failedOutcome(result.reason)
            }
        } catch (_: Throwable) {
            return PlatformToolOutcome.Failure("phone_timeout")
        } finally {
            unbindPhoneCall(call)
        }
    }

    private fun parsePhoneAction(arguments: JSONObject): PhoneControlAction? {
        val action = arguments.optString("action")
        val nodeRef = arguments.optString("nodeRef")
        fun validRef(): Boolean =
            nodeRef.isNotEmpty() && nodeRef.length <= 16 &&
                nodeRef.all { it.isLetterOrDigit() }
        return when (action) {
            "click" -> if (validRef()) PhoneControlAction.Click(nodeRef) else null
            "setText" -> {
                val text = arguments.optString("text")
                if (!validRef() || text.length > 2_000) null
                else PhoneControlAction.SetText(nodeRef, text)
            }
            "scroll" -> {
                val direction = when (arguments.optString("direction")) {
                    "forward" -> PhoneControlScrollDirection.FORWARD
                    "backward" -> PhoneControlScrollDirection.BACKWARD
                    else -> null
                }
                if (!validRef() || direction == null) null
                else PhoneControlAction.Scroll(nodeRef, direction)
            }
            "swipe" -> {
                val direction = when (arguments.optString("direction")) {
                    "up" -> PhoneControlSwipeDirection.UP
                    "down" -> PhoneControlSwipeDirection.DOWN
                    "left" -> PhoneControlSwipeDirection.LEFT
                    "right" -> PhoneControlSwipeDirection.RIGHT
                    else -> null
                }
                if (!validRef() || direction == null) null
                else PhoneControlAction.Swipe(nodeRef, direction)
            }
            "back" -> PhoneControlAction.Back
            "home" -> PhoneControlAction.Home
            "launch" -> {
                val pkg = arguments.optString("packageName")
                if (pkg.isBlank() || pkg.length > 255) null
                else PhoneControlAction.Launch(pkg)
            }
            else -> null
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
    ): PlatformToolOutcome {
        val header = buildString {
            append("action=").append(result.action)
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
        val builder = StringBuilder(2_000)
        builder.append("observation=").append(observation.observationId)
        builder.append(" page=").append(observation.packageName ?: "unknown")
        observation.windowTitle?.take(48)?.let { builder.append(" title=").append(it) }
        builder.append(" nodes=").append(observation.nodes.size)
        if (observation.navigationOnly) builder.append(" navigationOnly")
        if (observation.truncated) builder.append(" truncated")
        val ranked = observation.nodes.sortedWith(
            compareByDescending<com.floe.android.phonecontrol.PhoneControlNode> {
                it.clickable || it.editable || it.scrollable
            }.thenBy {
                it.ref.removePrefix("n").toIntOrNull() ?: Int.MAX_VALUE
            },
        )
        var count = 0
        for (node in ranked) {
            if (builder.length > 1_850) break
            val label = sequenceOf(node.text, node.contentDescription, node.hintText, node.viewId)
                .filterNotNull().firstOrNull { it.isNotBlank() } ?: continue
            val role = node.className.substringAfterLast('.').take(24)
            val flags = buildString {
                if (node.clickable) append('c')
                if (node.editable) append('e')
                if (node.scrollable) append('s')
                if (node.password) append('*')
            }
            builder.append('\n')
                .append(node.ref).append('|')
                .append(role).append('|')
                .append(flags).append('|')
                .append(label.replace('\n', ' ').take(56))
            count += 1
            if (count >= MAX_DIGEST_NODES) break
        }
        if (count == 0) {
            builder.append(
                if (observation.navigationOnly) {
                    "\nProtected Floe page; navigation-only (back, home, or launch an allowed app)."
                } else {
                    "\nNo labeled nodes on this page."
                },
            )
        }
        return builder.toString()
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

    private fun failedOutcome(reason: PhoneControlFailure): PlatformToolOutcome =
        PlatformToolOutcome.Failure("phone_" + reason.name.lowercase())

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
        val roots = effectiveSelectedRoots()
        val summary = buildString {
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
    )

    private suspend fun <T> withRootGrant(
        call: PlatformToolCall,
        operation: SystemOperation,
        scopeId: String?,
        destructive: Boolean,
        target: String? = null,
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
        val grantId = if (readOnly) {
            readLeaseId(call)
        } else {
            call.approvalGrantID?.toString() ?: return RootResult.Denied("approval_required")
        }
        val now = System.currentTimeMillis()
        val management = operation == SystemOperation.PACKAGE_FORCE_STOP &&
            settings.packageManagementAllowed
        val request = GrantRequest(
            grantId = grantId,
            taskId = call.taskID.toString(),
            runId = call.runID.toString(),
            epoch = call.epoch,
            expiresAtMillis = now + ROOT_GRANT_LIFETIME_MILLIS,
            scopes = scopes,
            operations = setOf(operation),
            packageManagementAllowed = management,
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
            expiresAtMillis = now + ROOT_GRANT_LIFETIME_MILLIS,
            operationClaim = claim,
        )
        rootGrants[grantId] = entry
        try {
            return withTimeout(25_000) { block(claim) }
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
        val maxEntries = call.arguments.optInt("maxEntries", 60).coerceIn(1, 200)
        val result = withRootGrant(
            call, SystemOperation.PACKAGE_QUERY, null, destructive = false, target = packageName,
        ) { claim ->
            val controller = rootController ?: return@withRootGrant RootResult.Unavailable("service_not_alive")
            controller.packageQuery(claim, packageName, includeSystem, maxEntries)
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
                ?: return AuthorityDecision.Denied("grant_unknown")
            if (!entry.matches(request.claim)) {
                return AuthorityDecision.Denied("grant_mismatch")
            }
            if (request.operation !in entry.operations) {
                return AuthorityDecision.Denied("operation")
            }
            if (request.operation == SystemOperation.PACKAGE_FORCE_STOP &&
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
            val entry = rootGrants[request.claim.grantId] ?: return true
            return entry.ticketCancelled()
        }
    }

    /** Called by the pump when a claimed ticket must stop. */
    private fun cancelBackend(call: PlatformToolCall) {
        // Phone: fencethe whole service session; the module rejects the
        // in-flight call and the pump settles it as cancelled, never success.
        if (call.tool.startsWith("phone.")) {
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
        const val KEY_PACKAGES = "allowed_packages"
        const val KEY_ROOTS = "file_roots"
        const val KEY_APP_DATA_ROOTS = "app_data_roots"
        const val LOCAL_NETWORK_API = 37
        const val LOCAL_PAIRING_ENDPOINT = "adb-tls-pairing._tcp.local"
        const val KEY_SCREEN_SCOPE = "screen_scope"
        const val KEY_FILE_WRITES = "file_writes"
        const val KEY_WHOLE_SCREEN = "whole_screen"
        const val KEY_MANAGEMENT = "management"
        const val KEY_ADB_ENABLED = "adb_enabled"
        const val MAX_TARGET_PACKAGES = 64
        const val MAX_LISTED_PACKAGES = 200
        const val MAX_DIGEST_NODES = 28
        const val MAX_LIST_ROWS = 24
        const val MAX_WRITE_BYTES = 48_000
        const val ROOT_GRANT_LIFETIME_MILLIS = 30_000L
        const val PAIRING_CHANNEL = "floe_device_pairing"
        const val PAIRING_NOTIFICATION_ID = 0x0F10
        val FILE_OPERATIONS = setOf(
            SystemOperation.FILE_LIST,
            SystemOperation.FILE_READ,
            SystemOperation.FILE_WRITE,
            SystemOperation.FILE_MOVE,
            SystemOperation.FILE_DELETE,
        )
    }
}
