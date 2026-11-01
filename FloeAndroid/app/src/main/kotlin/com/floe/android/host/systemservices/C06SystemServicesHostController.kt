// SPDX-License-Identifier: MPL-2.0
//
// Application-owned C06 system-services controller.
//
// Owns the trusted bridge token, the real platform service, the reverse
// mailbox lane, ActivityResult routing, foreground/NFC lifecycle and the
// capability projection. It survives Activity reconstruction because
// RuntimeHost is app-scoped: a permission result or NFC scan never belongs to
// a view lifetime. It never opens a permission dialog by itself and never
// performs a background location/health read.

package com.floe.android.host.systemservices

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.Uri
import android.nfc.NfcAdapter
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.health.connect.client.HealthConnectClient
import com.floe.android.core.systemservices.ContactsPlatformClient
import com.floe.android.core.systemservices.HealthConnectPlatformClient
import com.floe.android.core.systemservices.HealthPermissionCatalog
import com.floe.android.core.systemservices.LocationPlatformClient
import com.floe.android.core.systemservices.NfcPlatformClient
import com.floe.android.core.systemservices.PermissionEvidence
import com.floe.android.core.systemservices.SystemAvailability
import com.floe.android.core.systemservices.SystemPermission
import com.floe.android.core.systemservices.SystemServicesEngine
import com.floe.android.feature.systemservices.CapabilityKind
import com.floe.android.feature.systemservices.CapabilityState
import com.floe.android.feature.systemservices.CapabilityUi
import com.floe.android.feature.systemservices.DiagnosticRowUi
import com.floe.android.feature.systemservices.HealthMetricUi
import com.floe.android.feature.systemservices.SystemServicesNotice
import com.floe.android.feature.systemservices.SystemServicesUiState
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal enum class SystemPermissionKind {
    LOCATION,
    CONTACTS,
    HEALTH,
}

internal data class SystemPermissionRequest(
    val kind: SystemPermissionKind,
    val requestID: String = UUID.randomUUID().toString(),
)

internal class C06SystemServicesHostController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val currentNativeEpoch: () -> Long?,
    private val engine: SystemServicesEngine = SystemServicesEngine(
        locationService = LocationPlatformClient(context),
        contactsService = ContactsPlatformClient(context),
        nfcService = NfcPlatformClient(context),
        healthService = HealthConnectPlatformClient(context),
    ),
    private val client: C06SystemServicesClient = C06SystemServicesClient(),
) {
    private val appContext = context.applicationContext
    private val ownerToken = UUID.randomUUID().toString()
    private val preferences = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val lane = SystemServicesLane(
        scope = scope,
        engine = engine,
        currentActivity = { activity },
        ioDispatcher = ioDispatcher,
    )
    private val revision = AtomicLong(System.currentTimeMillis())
    private val foreground = AtomicBoolean(false)
    private val receiversRegistered = AtomicBoolean(false)
    private val application = appContext as? Application
    private val startedActivities = java.util.concurrent.atomic.AtomicInteger(0)
    private val activityCallbacksRegistered = AtomicBoolean(false)

    private val activityCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            startedActivities.incrementAndGet()
            foreground.set(true)
            refresh()
        }

        override fun onActivityResumed(activity: Activity) {
            this@C06SystemServicesHostController.activity = activity
        }

        override fun onActivityPaused(activity: Activity) {
            if (this@C06SystemServicesHostController.activity === activity) {
                this@C06SystemServicesHostController.activity = null
            }
        }

        override fun onActivityStopped(activity: Activity) {
            if (startedActivities.decrementAndGet() <= 0) {
                startedActivities.set(0)
                foreground.set(false)
                refresh()
            }
        }

        override fun onActivityDestroyed(activity: Activity) {
            if (this@C06SystemServicesHostController.activity === activity) {
                this@C06SystemServicesHostController.activity = null
            }
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) {}
    }

    @Volatile
    private var activity: Activity? = null

    @Volatile
    private var lastEpoch: Long = 0

    private val _state = MutableStateFlow(SystemServicesUiState())
    val state: StateFlow<SystemServicesUiState> = _state.asStateFlow()

    private val _permissionRequests =
        MutableStateFlow<SystemPermissionRequest?>(null)
    val permissionRequests: StateFlow<SystemPermissionRequest?> = _permissionRequests.asStateFlow()

    private val refreshReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            refresh()
        }
    }

    private val packageReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val packageName = intent?.data?.schemeSpecificPart
            if (packageName == HEALTH_PROVIDER_PACKAGE) refresh()
        }
    }

    private var refreshJob: Job? = null

    // MARK: Lifecycle

    fun onOwnedStoreReady() {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 } ?: return
        lastEpoch = epoch
        val started = lane.isRunning || lane.start(epoch)
        registerReceivers()
        registerActivityCallbacks()
        if (!started) {
            _state.update {
                it.copy(loading = false, coreReady = false, notice = SystemServicesNotice.REFRESH_FAILED)
            }
            return
        }
        refresh()
    }

    fun enter() {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch != null && epoch != lastEpoch) {
            lastEpoch = epoch
            lane.start(epoch)
        }
        refresh()
    }

    fun onAppForeground() {
        foreground.set(true)
        if (currentNativeEpoch()?.takeIf { it > 0 } != null && !lane.isRunning) {
            onOwnedStoreReady()
        } else {
            refresh()
        }
    }

    fun onAppBackground() {
        foreground.set(false)
        refresh()
    }

    fun setCurrentActivity(value: Activity?) {
        activity = value
    }

    suspend fun prepareForRootStop(timeoutMillis: Int): Boolean {
        refreshJob?.cancel()
        refreshJob = null
        unregisterActivityCallbacks()
        unregisterReceivers()
        activity = null
        foreground.set(false)
        lastEpoch = 0
        val drained = withContext(ioDispatcher) { lane.stop(timeoutMillis) }
        _state.value = SystemServicesUiState()
        return drained
    }

    fun onRootStopped() {
        refreshJob?.cancel()
        refreshJob = null
        unregisterActivityCallbacks()
        unregisterReceivers()
        activity = null
        foreground.set(false)
        lastEpoch = 0
        engine.reset()
        _state.value = SystemServicesUiState()
    }

    // MARK: Refresh / availability

    fun refresh() {
        refreshJob?.cancel()
        refreshJob = scope.launch { refreshInternal() }
    }

    private suspend fun refreshInternal() {
        val epoch = currentNativeEpoch()?.takeIf { it > 0 }
        if (epoch == null) {
            _state.value = SystemServicesUiState()
            return
        }
        if (!lane.isRunning && !lane.start(epoch)) {
            _state.update {
                it.copy(loading = false, coreReady = false, notice = SystemServicesNotice.REFRESH_FAILED)
            }
            return
        }
        lastEpoch = epoch
        _state.update { it.copy(loading = true) }
        val availability = try {
            withContext(ioDispatcher) {
                engine.capabilities(
                    foreground = foreground.get(),
                    revision = nextRevision(),
                    evidence = evidence(),
                )
            }
        } catch (failure: Throwable) {
            _state.update {
                it.copy(loading = false, coreReady = lane.isRunning,
                    notice = SystemServicesNotice.REFRESH_FAILED)
            }
            return
        }
        val push = try {
            withContext(ioDispatcher) {
                client.pushAvailability(owner(epoch), availability)
            }
        } catch (_: SystemServicesClientFailure) {
            null
        }
        _state.update { current ->
            current.copy(
                loading = false,
                coreReady = lane.isRunning,
                revision = availability.revision,
                foreground = availability.foreground,
                location = locationUi(availability),
                contacts = contactsUi(availability),
                nfc = nfcUi(availability),
                health = healthUi(availability),
                healthMetrics = healthMetrics(availability),
                notice = if (push == null) SystemServicesNotice.REFRESH_FAILED else current.notice,
                diagnostics = diagnostics(availability, push, epoch),
            )
        }
    }

    private fun owner(epoch: Long): SystemServicesOwnerRef =
        SystemServicesOwnerRef(token = ownerToken, nativeEpoch = epoch)

    private fun nextRevision(): Long = revision.updateAndGet { previous ->
        maxOf(previous + 1, System.currentTimeMillis())
    }

    private fun evidence(): PermissionEvidence = PermissionEvidence(
        locationRequested = preferences.getBoolean(KEY_LOCATION_REQUESTED, false),
        contactsRequested = preferences.getBoolean(KEY_CONTACTS_REQUESTED, false),
    )

    // MARK: Permissions

    fun requestPermission(kind: SystemPermissionKind) {
        when (kind) {
            SystemPermissionKind.LOCATION ->
                preferences.edit().putBoolean(KEY_LOCATION_REQUESTED, true).apply()
            SystemPermissionKind.CONTACTS ->
                preferences.edit().putBoolean(KEY_CONTACTS_REQUESTED, true).apply()
            SystemPermissionKind.HEALTH -> Unit
        }
        _permissionRequests.value = SystemPermissionRequest(kind)
    }

    fun grantHealth() {
        requestPermission(SystemPermissionKind.HEALTH)
    }

    fun cancelPermissionRequest() {
        _permissionRequests.value = null
    }

    /** The destination has actually handed the request to a system
     *  ActivityResult contract. Clear the pending projection so a rotation or
     *  recomposition cannot relaunch the same system dialog. */
    fun markPermissionLaunched(requestID: String) {
        _permissionRequests.update { current ->
            current?.takeIf { it.requestID != requestID }
        }
    }

    fun onPermissionResult(kind: SystemPermissionKind, granted: Boolean) {
        _permissionRequests.value = null
        if (!granted) {
            _state.update {
                it.copy(
                    notice = if (kind == SystemPermissionKind.LOCATION ||
                        kind == SystemPermissionKind.CONTACTS
                    ) {
                        SystemServicesNotice.GRANT_FAILED
                    } else {
                        SystemServicesNotice.PERMISSION_DENIED
                    },
                )
            }
        }
        refresh()
    }

    fun onHealthPermissionResult(granted: Set<String>) {
        _permissionRequests.value = null
        preferences.edit().putBoolean(KEY_HEALTH_REQUESTED, true).apply()
        if (granted.isEmpty()) {
            _state.update { it.copy(notice = SystemServicesNotice.GRANT_FAILED) }
        }
        refresh()
    }

    val healthReadPermissions: Set<String>
        get() = HealthPermissionCatalog.readPermissions()

    // MARK: Settings / install

    fun openSettings(kind: CapabilityKind) {
        val intent = when (kind) {
            CapabilityKind.LOCATION -> {
                val state = _state.value.location.state
                if (state == CapabilityState.DENIED || state == CapabilityState.RESTRICTED) {
                    appDetailsIntent()
                } else {
                    Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                }
            }
            CapabilityKind.CONTACTS -> appDetailsIntent()
            CapabilityKind.NFC -> Intent(Settings.ACTION_NFC_SETTINGS)
            CapabilityKind.HEALTH -> {
                val state = _state.value.health.state
                if (state == CapabilityState.NOT_INSTALLED || state == CapabilityState.UPDATE_REQUIRED) {
                    marketIntent()
                } else {
                    healthSettingsIntent() ?: appDetailsIntent()
                }
            }
        }
        launchSettings(intent)
    }

    fun installHealth() {
        launchSettings(marketIntent())
    }

    fun updateHealth() {
        launchSettings(marketIntent())
    }

    fun dismissNotice() {
        _state.update { it.copy(notice = null) }
    }

    private fun launchSettings(intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(appContext.packageManager) == null) {
            _state.update { it.copy(notice = SystemServicesNotice.SETTINGS_UNAVAILABLE) }
            return
        }
        try {
            appContext.startActivity(intent)
        } catch (_: Exception) {
            _state.update { it.copy(notice = SystemServicesNotice.SETTINGS_UNAVAILABLE) }
        }
    }

    private fun appDetailsIntent(): Intent = Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.fromParts("package", appContext.packageName, null),
    )

    private fun marketIntent(): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$HEALTH_PROVIDER_PACKAGE"))

    private fun healthSettingsIntent(): Intent? = try {
        HealthConnectClient.getHealthConnectManageDataIntent(appContext)
    } catch (_: Throwable) {
        null
    }

    // MARK: Receivers

    private fun registerReceivers() {
        if (!receiversRegistered.compareAndSet(false, true)) return
        val systemFilter = IntentFilter().apply {
            addAction(NfcAdapter.ACTION_ADAPTER_STATE_CHANGED)
            addAction(LocationManager.PROVIDERS_CHANGED_ACTION)
        }
        val packageFilter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        try {
            ContextCompat.registerReceiver(
                appContext,
                refreshReceiver,
                systemFilter,
                ContextCompat.RECEIVER_EXPORTED,
            )
        } catch (_: Exception) {
            receiversRegistered.set(false)
            return
        }
        try {
            ContextCompat.registerReceiver(
                appContext,
                packageReceiver,
                packageFilter,
                ContextCompat.RECEIVER_EXPORTED,
            )
        } catch (_: Exception) {
            try {
                appContext.unregisterReceiver(refreshReceiver)
            } catch (_: IllegalArgumentException) {
            }
            receiversRegistered.set(false)
        }
    }

    private fun registerActivityCallbacks() {
        val application = application ?: return
        if (!activityCallbacksRegistered.compareAndSet(false, true)) return
        try {
            application.registerActivityLifecycleCallbacks(activityCallbacks)
        } catch (_: Exception) {
            activityCallbacksRegistered.set(false)
        }
    }

    private fun unregisterActivityCallbacks() {
        val application = application ?: return
        if (!activityCallbacksRegistered.compareAndSet(true, false)) return
        try {
            application.unregisterActivityLifecycleCallbacks(activityCallbacks)
        } catch (_: Exception) {
        }
    }

    private fun unregisterReceivers() {
        if (!receiversRegistered.compareAndSet(true, false)) return
        try {
            appContext.unregisterReceiver(refreshReceiver)
        } catch (_: IllegalArgumentException) {
        }
        try {
            appContext.unregisterReceiver(packageReceiver)
        } catch (_: IllegalArgumentException) {
        }
    }

    fun close() {
        unregisterActivityCallbacks()
        unregisterReceivers()
    }

    // MARK: UI projection

    private fun locationUi(availability: SystemAvailability): CapabilityUi {
        val location = availability.location
        val state = when {
            !location.hardwareAvailable -> CapabilityState.UNSUPPORTED
            location.permission == SystemPermission.NOT_DETERMINED -> CapabilityState.NEEDS_PERMISSION
            location.permission == SystemPermission.DENIED -> CapabilityState.DENIED
            location.permission == SystemPermission.RESTRICTED -> CapabilityState.RESTRICTED
            location.permission == SystemPermission.UNAVAILABLE -> CapabilityState.UNSUPPORTED
            !location.servicesEnabled -> CapabilityState.DISABLED
            else -> CapabilityState.READY
        }
        return CapabilityUi(
            kind = CapabilityKind.LOCATION,
            state = state,
            available = state == CapabilityState.READY,
            precise = if (location.permission == SystemPermission.GRANTED) {
                location.precise
            } else {
                null
            },
            canRequest = state == CapabilityState.NEEDS_PERMISSION && availability.foreground,
            canOpenSettings = state != CapabilityState.UNSUPPORTED,
        )
    }

    private fun contactsUi(availability: SystemAvailability): CapabilityUi {
        val contacts = availability.contacts
        val state = when {
            !contacts.providerAvailable -> CapabilityState.UNSUPPORTED
            contacts.permission == SystemPermission.NOT_DETERMINED -> CapabilityState.NEEDS_PERMISSION
            contacts.permission == SystemPermission.DENIED -> CapabilityState.DENIED
            contacts.permission == SystemPermission.RESTRICTED -> CapabilityState.RESTRICTED
            contacts.permission == SystemPermission.UNAVAILABLE -> CapabilityState.UNSUPPORTED
            else -> CapabilityState.READY
        }
        return CapabilityUi(
            kind = CapabilityKind.CONTACTS,
            state = state,
            available = state == CapabilityState.READY,
            canRequest = state == CapabilityState.NEEDS_PERMISSION && availability.foreground,
            canOpenSettings = state != CapabilityState.UNSUPPORTED,
        )
    }

    private fun nfcUi(availability: SystemAvailability): CapabilityUi {
        val nfc = availability.nfc
        val state = when {
            !nfc.hardwareAvailable -> CapabilityState.UNSUPPORTED
            !nfc.enabled -> CapabilityState.DISABLED
            else -> CapabilityState.READY
        }
        return CapabilityUi(
            kind = CapabilityKind.NFC,
            state = state,
            available = state == CapabilityState.READY,
            canOpenSettings = state != CapabilityState.UNSUPPORTED,
        )
    }

    private fun healthUi(availability: SystemAvailability): CapabilityUi {
        val health = availability.health
        val state = when (health.providerStatus.wire) {
            "available" -> if (health.grantedMetrics.isEmpty()) {
                CapabilityState.NEEDS_PERMISSION
            } else {
                CapabilityState.READY
            }
            "updateRequired" -> CapabilityState.UPDATE_REQUIRED
            else -> CapabilityState.NOT_INSTALLED
        }
        return CapabilityUi(
            kind = CapabilityKind.HEALTH,
            state = state,
            available = state == CapabilityState.READY,
            grantedMetricCount = health.grantedMetrics.size,
            canOpenSettings = true,
        )
    }

    private fun healthMetrics(availability: SystemAvailability): List<HealthMetricUi> =
        HealthPermissionCatalog.metrics.map { metric ->
            HealthMetricUi(metric.wire, availability.health.grantedMetrics.contains(metric.wire))
        }

    private fun diagnostics(
        availability: SystemAvailability,
        push: SystemAvailabilityPush?,
        epoch: Long,
    ): List<DiagnosticRowUi> = buildList {
        add(DiagnosticRowUi("androidApi", Build.VERSION.SDK_INT.toString()))
        add(DiagnosticRowUi("nativeEpoch", epoch.toString()))
        add(DiagnosticRowUi("revision", availability.revision.toString()))
        add(DiagnosticRowUi("foreground", availability.foreground.toString()))
        add(DiagnosticRowUi("locationPermission", availability.location.permission.wire))
        add(
            DiagnosticRowUi(
                "locationPrecision",
                if (availability.location.permission == SystemPermission.GRANTED) {
                    if (availability.location.precise) "precise" else "approximate"
                } else {
                    "unknown"
                },
            ),
        )
        add(DiagnosticRowUi("locationProviderAvailable", availability.location.hardwareAvailable.toString()))
        add(DiagnosticRowUi("locationServicesEnabled", availability.location.servicesEnabled.toString()))
        add(DiagnosticRowUi("contactsPermission", availability.contacts.permission.wire))
        add(DiagnosticRowUi("contactsProviderAvailable", availability.contacts.providerAvailable.toString()))
        add(DiagnosticRowUi("nfcHardware", availability.nfc.hardwareAvailable.toString()))
        add(DiagnosticRowUi("nfcEnabled", availability.nfc.enabled.toString()))
        add(DiagnosticRowUi("healthProvider", availability.health.providerStatus.wire))
        add(DiagnosticRowUi("healthMetricCount", availability.health.grantedMetrics.size.toString()))
        add(DiagnosticRowUi("healthMetrics", availability.health.grantedMetrics.sorted().joinToString(",")))
        if (push != null) {
            add(DiagnosticRowUi("swiftLocationAvailable", push.locationAvailable.toString()))
            add(DiagnosticRowUi("swiftContactsAvailable", push.contactsAvailable.toString()))
            add(DiagnosticRowUi("swiftNfcAvailable", push.nfcAvailable.toString()))
            add(DiagnosticRowUi("swiftHealthAvailable", push.healthAvailable.toString()))
        }
        lane.statsJson()?.let { stats ->
            add(DiagnosticRowUi("mailboxPending", stats.optInt("pending", 0).toString()))
            add(DiagnosticRowUi("mailboxCompleted", stats.optInt("completed", 0).toString()))
            add(DiagnosticRowUi("mailboxFailed", stats.optInt("failed", 0).toString()))
        }
    }

    companion object {
        const val PREFS = "floe.system.host"
        const val KEY_LOCATION_REQUESTED = "permission.location.requested"
        const val KEY_CONTACTS_REQUESTED = "permission.contacts.requested"
        const val KEY_HEALTH_REQUESTED = "permission.health.requested"
        const val HEALTH_PROVIDER_PACKAGE = "com.google.android.apps.healthdata"
    }
}
