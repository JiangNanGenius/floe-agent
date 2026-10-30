// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkmonitor

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.floe.android.core.network.PhoneNetworkService
import com.floe.android.core.networkmonitor.NetworkMonitorDeviceMetadata
import com.floe.android.core.networkmonitor.NetworkMonitorEndReason
import com.floe.android.core.networkmonitor.NetworkMonitorExecutor
import com.floe.android.core.networkmonitor.NetworkMonitorOwner
import com.floe.android.core.networkmonitor.NetworkMonitorPhase
import com.floe.android.core.networkmonitor.NetworkMonitorReportFiles
import com.floe.android.core.networkmonitor.NetworkMonitorReportRenderer
import com.floe.android.core.networkmonitor.NetworkMonitorReportStore
import com.floe.android.core.networkmonitor.NetworkMonitorSessionSnapshot
import com.floe.android.core.networkmonitor.NetworkMonitorSessionState
import com.floe.android.core.networkmonitor.NetworkMonitorConfig
import com.floe.android.core.networkmonitor.NetworkMonitorStartResult
import com.floe.android.core.networkmonitor.NetworkMonitoringEngine
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext

/** The only production executor adapter: it forwards the existing frozen phone service verbatim. */
class PhoneNetworkMonitorExecutor(
    private val service: PhoneNetworkService,
) : NetworkMonitorExecutor {
    override suspend fun execute(requestJson: String): String = service.execute(requestJson)
    override fun cancel(operationID: String) = service.cancel(operationID)
}

enum class NetworkMonitorHostStartFailure {
    APP_NOT_FOREGROUND,
    NOTIFICATIONS_DISABLED,
    START_RESTRICTED,
    START_FAILED,
}

sealed interface NetworkMonitorHostStartResult {
    data class Accepted(val launchId: String, val sessionId: String) : NetworkMonitorHostStartResult
    data class AlreadyActive(val sessionId: String) : NetworkMonitorHostStartResult
    data class Rejected(val reason: NetworkMonitorHostStartFailure) : NetworkMonitorHostStartResult
}

enum class NetworkMonitorReportWriteFailure {
    SESSION_NOT_FOUND,
    REPORT_TOO_LARGE,
    WRITE_FAILED,
}

sealed interface NetworkMonitorReportWriteResult {
    data class Written(val files: NetworkMonitorReportFiles) : NetworkMonitorReportWriteResult
    data class Rejected(val reason: NetworkMonitorReportWriteFailure) : NetworkMonitorReportWriteResult
}

internal data class NetworkMonitorServiceAttachment(
    val engine: NetworkMonitoringEngine,
    val onNotificationPermissionRevoked: () -> Unit,
)

/** Root-stop retirement result: the exact active session still to join. */
internal data class NetworkMonitorLaunchRetirement(
    val activeSessionId: String?,
    val cancelledSessionIds: List<String>,
)

/**
 * Result of the atomic CLAIMED -> engine.start transition. [Refused] means the
 * launch was already cancelled/retired (the cancelling path published the
 * truthful terminal); [Failed] means this call itself published a start
 * failure and the Service only has to clean up its notification.
 */
internal sealed interface NetworkMonitorClaimedStartOutcome {
    data class Started(val sessionId: String) : NetworkMonitorClaimedStartOutcome
    data class AlreadyActive(val sessionId: String) : NetworkMonitorClaimedStartOutcome
    data object Refused : NetworkMonitorClaimedStartOutcome
    data object Failed : NetworkMonitorClaimedStartOutcome
}

/**
 * Application-scoped composition adapter. No constructor/subscription path
 * starts a probe.
 *
 * The single [NetworkMonitorLaunchLedger] is the authority for the pending ->
 * claimed -> active transition. [lock] is held across the ledger check and the
 * synchronous `engine.start` call, so exact Stop and root retirement can never
 * succeed while a stale launch is still able to attach. `launchAdmission` is
 * the RuntimeHost-owned native-root generation gate; it is consulted under
 * the same lock so a new root generation is required after retirement.
 */
class NetworkMonitorHost(
    context: Context,
    internal val executor: NetworkMonitorExecutor,
    private val isAppForeground: () -> Boolean,
    private val deviceMetadata: () -> NetworkMonitorDeviceMetadata,
    private val launchAdmission: () -> Boolean = { true },
) {
    private val appContext = context.applicationContext
    private val lock = Any()
    private val ledger = NetworkMonitorLaunchLedger()
    private val mutableState = MutableStateFlow(NetworkMonitorSessionState())
    val state: StateFlow<NetworkMonitorSessionState> = mutableState

    private var attachment: NetworkMonitorServiceAttachment? = null
    private var lastSnapshot: NetworkMonitorSessionSnapshot? = null
    private val reportStore by lazy { NetworkMonitorReportStore(File(appContext.filesDir, "network-monitor-reports")) }

    fun startFromVisibleUserAction(
        config: NetworkMonitorConfig,
        owner: NetworkMonitorOwner,
    ): NetworkMonitorHostStartResult {
        synchronized(lock) {
            reconcileActiveLaunchLocked()
            activeEngineSessionLocked()?.let {
                return NetworkMonitorHostStartResult.AlreadyActive(it)
            }
            if (!launchAdmission()) {
                return NetworkMonitorHostStartResult.Rejected(NetworkMonitorHostStartFailure.START_RESTRICTED)
            }
            when (val current = ledger.current()) {
                null -> Unit
                else -> when (current.phase) {
                    NetworkMonitorLaunchLedger.Phase.ACTIVE ->
                        return NetworkMonitorHostStartResult.AlreadyActive(current.launch.sessionId)
                    NetworkMonitorLaunchLedger.Phase.PENDING,
                    NetworkMonitorLaunchLedger.Phase.CLAIMED ->
                        return NetworkMonitorHostStartResult.Accepted(
                            current.launch.launchId,
                            current.launch.sessionId,
                        )
                }
            }
        }
        if (!isAppForeground()) return NetworkMonitorHostStartResult.Rejected(
            NetworkMonitorHostStartFailure.APP_NOT_FOREGROUND,
        )
        if (!NetworkMonitorNotificationAccess.isAllowed(appContext)) {
            return NetworkMonitorHostStartResult.Rejected(NetworkMonitorHostStartFailure.NOTIFICATIONS_DISABLED)
        }
        val launchId = UUID.randomUUID().toString()
        val sessionId = UUID.randomUUID().toString()
        val launch = synchronized(lock) {
            reconcileActiveLaunchLocked()
            activeEngineSessionLocked()?.let {
                return NetworkMonitorHostStartResult.AlreadyActive(it)
            }
            if (!launchAdmission()) {
                return NetworkMonitorHostStartResult.Rejected(NetworkMonitorHostStartFailure.START_RESTRICTED)
            }
            when (val reserved = ledger.reserve(launchId, sessionId, config, owner)) {
                is NetworkMonitorLaunchLedger.ReserveResult.Reserved -> reserved.launch
                is NetworkMonitorLaunchLedger.ReserveResult.Existing -> return NetworkMonitorHostStartResult.Accepted(
                    reserved.launch.launchId,
                    reserved.launch.sessionId,
                )
                is NetworkMonitorLaunchLedger.ReserveResult.Active -> return NetworkMonitorHostStartResult.AlreadyActive(
                    reserved.sessionId,
                )
            }
        }
        val intent = Intent(appContext, NetworkMonitorService::class.java)
            .setAction(NetworkMonitorService.ACTION_START)
            .putExtra(NetworkMonitorService.EXTRA_LAUNCH_ID, launch.launchId)
        try {
            ContextCompat.startForegroundService(appContext, intent)
        } catch (failure: Exception) {
            synchronized(lock) { ledger.abandon(launch) }
            val reason = when {
                Build.VERSION.SDK_INT >= 31 && failure is android.app.ForegroundServiceStartNotAllowedException ->
                    NetworkMonitorHostStartFailure.START_RESTRICTED
                failure is SecurityException -> NetworkMonitorHostStartFailure.NOTIFICATIONS_DISABLED
                failure is IllegalStateException -> NetworkMonitorHostStartFailure.START_RESTRICTED
                else -> NetworkMonitorHostStartFailure.START_FAILED
            }
            return NetworkMonitorHostStartResult.Rejected(reason)
        }
        return NetworkMonitorHostStartResult.Accepted(launch.launchId, launch.sessionId)
    }

    /**
     * Exact-session stop. A pending/claimed launch is invalidated synchronously
     * and published as a truthful terminal before it could reach the engine; a
     * foreign session ID never cancels the current launch/session.
     */
    fun requestStop(sessionId: String): Boolean = synchronized(lock) {
        when (val cancelled = ledger.cancelExact(sessionId)) {
            is NetworkMonitorLaunchLedger.CancelResult.Cancelled -> {
                publishTerminalLocked(cancelled.launch, NetworkMonitorEndReason.USER_STOP)
                true
            }
            is NetworkMonitorLaunchLedger.CancelResult.Active ->
                attachment?.engine?.requestStop(sessionId, NetworkMonitorEndReason.USER_STOP) ?: false
            NetworkMonitorLaunchLedger.CancelResult.None ->
                attachment?.engine?.requestStop(sessionId, NetworkMonitorEndReason.USER_STOP) ?: false
        }
    }

    suspend fun stopAndJoin(
        sessionId: String,
        timeoutMillis: Long = 5_000,
        reason: NetworkMonitorEndReason = NetworkMonitorEndReason.USER_STOP,
    ): Boolean {
        var cancelledBeforeStart = false
        var engine: NetworkMonitoringEngine? = null
        synchronized(lock) {
            when (val cancelled = ledger.cancelExact(sessionId)) {
                is NetworkMonitorLaunchLedger.CancelResult.Cancelled -> {
                    publishTerminalLocked(cancelled.launch, reason)
                    cancelledBeforeStart = true
                }
                is NetworkMonitorLaunchLedger.CancelResult.Active -> {
                    engine = attachment?.engine
                }
                NetworkMonitorLaunchLedger.CancelResult.None -> {
                    val attached = attachment?.engine
                    if (attached?.state?.value?.sessionId == sessionId) engine = attached
                }
            }
        }
        if (cancelledBeforeStart) return true
        val target = engine ?: return synchronized(lock) { lastSnapshot?.sessionId == sessionId }
        val joined = target.stopAndJoin(sessionId, timeoutMillis, reason)
        if (joined) synchronized(lock) { ledger.completeActive(sessionId) }
        return joined
    }

    /** Explicit user request only. detailed=true must follow the product's clear disclosure. */
    suspend fun writeReport(sessionId: String, detailed: Boolean = false): NetworkMonitorReportWriteResult =
        withContext(Dispatchers.IO) {
            val snapshot = synchronized(lock) {
                attachment?.engine?.snapshot(sessionId)
                    ?: lastSnapshot?.takeIf { it.sessionId == sessionId }
            } ?: return@withContext NetworkMonitorReportWriteResult.Rejected(
                NetworkMonitorReportWriteFailure.SESSION_NOT_FOUND,
            )
            try {
                val document = NetworkMonitorReportRenderer.render(snapshot, detailed, deviceMetadata())
                val files = reportStore.write(UUID.randomUUID().toString(), document)
                NetworkMonitorReportWriteResult.Written(files)
            } catch (failure: IllegalArgumentException) {
                NetworkMonitorReportWriteResult.Rejected(NetworkMonitorReportWriteFailure.REPORT_TOO_LARGE)
            } catch (_: IOException) {
                NetworkMonitorReportWriteResult.Rejected(NetworkMonitorReportWriteFailure.WRITE_FAILED)
            } catch (_: SecurityException) {
                NetworkMonitorReportWriteResult.Rejected(NetworkMonitorReportWriteFailure.WRITE_FAILED)
            }
        }

    /** Main calls after its explicit notification-permission result or settings return. */
    fun onNotificationPermissionChanged() {
        if (NetworkMonitorNotificationAccess.isAllowed(appContext)) return
        synchronized(lock) {
            ledger.cancelUnstarted()?.let { launch ->
                publishTerminalLocked(launch, NetworkMonitorEndReason.NOTIFICATION_PERMISSION_REVOKED, failed = true)
            }
        }
        val callback = synchronized(lock) { attachment?.onNotificationPermissionRevoked }
        callback?.invoke()
    }

    /**
     * Service-side claim of the one-time opaque launch token. The launch stays
     * in the ledger as CLAIMED, so it remains cancellable until `engine.start`
     * linearizes.
     */
    internal fun claimLaunch(launchId: String): NetworkMonitorLaunchLedger.Launch? = synchronized(lock) {
        if (!launchAdmission()) return null
        ledger.claim(launchId)
    }

    /**
     * True while a newer explicit Start still waits for its Service intent
     * and that launch is still admissible. A launch already fenced by root
     * retirement must not keep a foreground-start Service alive waiting for a
     * command that can never start work.
     */
    internal fun hasUnstartedLaunch(): Boolean = synchronized(lock) {
        ledger.isPendingOrClaimed() && launchAdmission()
    }

    /**
     * Atomic CLAIMED -> engine.start transition. This whole block, including
     * `engine.start`, runs under [lock]; root retirement/exact Stop take the
     * same lock. Therefore either the start linearizes first (retirement sees
     * the ACTIVE entry and joins it) or retirement cancels the claim first and
     * this call refuses without starting any measurement.
     */
    internal fun startClaimedLaunch(
        launch: NetworkMonitorLaunchLedger.Launch,
        engine: NetworkMonitoringEngine,
    ): NetworkMonitorClaimedStartOutcome = synchronized(lock) {
        if (attachment?.engine !== engine) return NetworkMonitorClaimedStartOutcome.Refused
        if (!launchAdmission() || !ledger.authorizeEngineStart(launch)) {
            return NetworkMonitorClaimedStartOutcome.Refused
        }
        val result = try {
            engine.start(launch.config, launch.owner, launch.sessionId)
        } catch (_: Exception) {
            ledger.abandon(launch)
            publishTerminalLocked(launch, NetworkMonitorEndReason.FOREGROUND_START_FAILED, failed = true)
            return NetworkMonitorClaimedStartOutcome.Failed
        }
        when (result) {
            is NetworkMonitorStartResult.Started -> {
                // A notification revocation handled reentrantly by the Service
                // collector can publish the terminal while engine.start is
                // emitting RUNNING. Never activate a session that already has
                // a truthful terminal.
                if (startWasFencedLocked(result.sessionId, engine)) {
                    ledger.abandon(launch)
                    return NetworkMonitorClaimedStartOutcome.Failed
                }
                if (!ledger.activate(launch, result.sessionId)) {
                    engine.requestStop(result.sessionId, NetworkMonitorEndReason.SERVICE_DESTROYED)
                    return NetworkMonitorClaimedStartOutcome.Failed
                }
                NetworkMonitorClaimedStartOutcome.Started(result.sessionId)
            }
            is NetworkMonitorStartResult.AlreadyActive -> {
                if (startWasFencedLocked(result.sessionId, engine)) {
                    ledger.abandon(launch)
                    return NetworkMonitorClaimedStartOutcome.Failed
                }
                if (!ledger.activate(launch, result.sessionId)) {
                    return NetworkMonitorClaimedStartOutcome.Failed
                }
                NetworkMonitorClaimedStartOutcome.AlreadyActive(result.sessionId)
            }
            NetworkMonitorStartResult.Closed -> {
                ledger.abandon(launch)
                publishTerminalLocked(launch, NetworkMonitorEndReason.FOREGROUND_START_FAILED, failed = true)
                NetworkMonitorClaimedStartOutcome.Failed
            }
        }
    }

    /** Service start failure before `engine.start`; never overwrites a stop/retire terminal. */
    internal fun failClaimedLaunch(launch: NetworkMonitorLaunchLedger.Launch, reason: NetworkMonitorEndReason) {
        synchronized(lock) {
            if (ledger.abandon(launch)) publishTerminalLocked(launch, reason, failed = true)
        }
    }

    /** Service destruction/notification Stop before `engine.start`. */
    internal fun abandonClaimedLaunch(launch: NetworkMonitorLaunchLedger.Launch, reason: NetworkMonitorEndReason) {
        synchronized(lock) {
            if (ledger.abandon(launch)) publishTerminalLocked(launch, reason)
        }
    }

    /**
     * Root retirement: invalidate every PENDING/CLAIMED launch and report the
     * exact ACTIVE session the caller must join. It deliberately does not
     * inspect the asynchronously published StateFlow; the ledger records
     * ACTIVE synchronously with `engine.start`.
     */
    internal fun retireForRootStop(): NetworkMonitorLaunchRetirement = synchronized(lock) {
        // The collector may not have delivered a terminal yet; do not report
        // an already-ended engine session as an ACTIVE join target.
        reconcileActiveLaunchLocked()
        val retirement = ledger.retire()
        retirement.cancelled.forEach { launch ->
            publishTerminalLocked(launch, NetworkMonitorEndReason.SERVICE_DESTROYED)
        }
        NetworkMonitorLaunchRetirement(
            activeSessionId = retirement.activeSessionId ?: activeEngineSessionLocked(),
            cancelledSessionIds = retirement.cancelled.map { it.sessionId },
        )
    }

    internal fun attach(attachment: NetworkMonitorServiceAttachment): Boolean = synchronized(lock) {
        if (this.attachment != null) return false
        this.attachment = attachment
        true
    }

    internal fun publish(engine: NetworkMonitoringEngine, value: NetworkMonitorSessionState) {
        synchronized(lock) {
            if (attachment?.engine !== engine) return
            mutableState.value = value
            if (value.isTerminal) {
                value.sessionId?.let { id ->
                    engine.snapshot(id)?.let { lastSnapshot = it }
                    ledger.completeActive(id)
                }
            }
        }
    }

    internal fun publishServiceTerminal(
        engine: NetworkMonitoringEngine,
        sessionId: String,
        reason: NetworkMonitorEndReason,
    ) {
        synchronized(lock) {
            if (attachment?.engine !== engine) return
            val observed = engine.snapshot(sessionId)
            val snapshot = observed?.copy(
                endedAtEpochMillis = System.currentTimeMillis(),
                endedAtElapsedNanos = System.nanoTime(),
                endReason = reason,
                failed = observed.failed || reason == NetworkMonitorEndReason.FOREGROUND_START_FAILED,
            )
            if (snapshot != null) lastSnapshot = snapshot
            val current = mutableState.value
            val launch = ledger.current()?.takeIf { it.launch.sessionId == sessionId }?.launch
            val base = when {
                current.sessionId == sessionId -> current
                snapshot != null -> NetworkMonitorSessionState(
                    sessionId = sessionId,
                    owner = snapshot.owner,
                    startedAtEpochMillis = snapshot.startedAtEpochMillis,
                    startedAtElapsedNanos = snapshot.startedAtElapsedNanos,
                    deadlineAtElapsedNanos = snapshot.deadlineAtElapsedNanos,
                    observationCount = snapshot.totalObservationCount,
                    droppedObservationCount = snapshot.droppedObservationCount,
                    consumedRawBytes = snapshot.consumedRawBytes,
                    retainedRawBytes = snapshot.retainedRawBytes,
                    lastObservation = snapshot.observations.lastOrNull(),
                )
                launch != null -> NetworkMonitorSessionState(sessionId = launch.sessionId, owner = launch.owner)
                else -> return
            }
            mutableState.value = base.copy(
                phase = if (reason == NetworkMonitorEndReason.FOREGROUND_START_FAILED) {
                    NetworkMonitorPhase.FAILED
                } else {
                    NetworkMonitorPhase.COMPLETED
                },
                endReason = reason,
            )
            ledger.completeActive(sessionId)
        }
    }

    internal fun detach(engine: NetworkMonitoringEngine) {
        synchronized(lock) {
            if (attachment?.engine !== engine) return
            val id = mutableState.value.sessionId ?: engine.state.value.sessionId
            val terminalSnapshotAlreadyRetained = mutableState.value.isTerminal &&
                id != null && lastSnapshot?.sessionId == id
            if (id != null && !terminalSnapshotAlreadyRetained) {
                engine.snapshot(id)?.let { lastSnapshot = it }
            }
            attachment = null
            if (id != null) ledger.completeActive(id)
        }
    }

    private fun activeEngineSessionLocked(): String? =
        attachment?.engine?.state?.value?.takeIf { it.isActive }?.sessionId

    /**
     * A session that already reached a terminal/IDLE engine state may have its
     * collector terminal publication still queued. Reconcile the ledger before
     * deciding that an explicit Start is a duplicate: the previous code read
     * the engine state directly and allowed a new session immediately after
     * the old one ended.
     */
    private fun reconcileActiveLaunchLocked() {
        val current = ledger.current() ?: return
        if (current.phase != NetworkMonitorLaunchLedger.Phase.ACTIVE) return
        val engine = attachment?.engine
        val engineState = engine?.state?.value
        val ended = engine == null || (
            engineState != null &&
                !engineState.isActive &&
                (engineState.sessionId == current.launch.sessionId || engineState.sessionId == null)
            )
        if (ended) ledger.completeActive(current.launch.sessionId)
    }

    /**
     * True when this exact session already has a truthful terminal (for
     * example a notification-revocation stop handled reentrantly while
     * `engine.start` was publishing RUNNING). The start is then stopped
     * immediately and never recorded as an owned measurement.
     */
    private fun startWasFencedLocked(sessionId: String, engine: NetworkMonitoringEngine): Boolean {
        val current = mutableState.value
        if (!current.isTerminal || current.sessionId != sessionId) return false
        engine.requestStop(sessionId, NetworkMonitorEndReason.SERVICE_DESTROYED)
        return true
    }

    private fun publishTerminalLocked(
        launch: NetworkMonitorLaunchLedger.Launch,
        reason: NetworkMonitorEndReason,
        failed: Boolean = false,
    ) {
        mutableState.value = NetworkMonitorSessionState(
            phase = if (failed) NetworkMonitorPhase.FAILED else NetworkMonitorPhase.COMPLETED,
            sessionId = launch.sessionId,
            owner = launch.owner,
            startedAtEpochMillis = 0L,
            startedAtElapsedNanos = 0L,
            deadlineAtElapsedNanos = 0L,
            endReason = reason,
        )
    }
}

internal object NetworkMonitorNotificationAccess {
    fun isAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                context, Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        return NotificationManagerCompat.from(context).areNotificationsEnabled()
    }
}

/** One process-local accessor installed by Main; process death leaves no restoration token. */
object NetworkMonitorServiceRuntime {
    @Volatile
    private var host: NetworkMonitorHost? = null

    @Synchronized
    fun install(host: NetworkMonitorHost) {
        val existing = this.host
        check(existing == null || existing === host) { "a different NetworkMonitorHost is already installed" }
        this.host = host
    }

    @Synchronized
    fun uninstall(host: NetworkMonitorHost) {
        if (this.host === host) this.host = null
    }

    internal fun current(): NetworkMonitorHost? = host
}
