// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import android.content.Context
import android.content.Intent
import com.floe.android.runlifecycle.ForegroundLease
import com.floe.android.runlifecycle.OperationKind
import com.floe.android.runlifecycle.RunForegroundController
import com.floe.android.runlifecycle.RunForegroundFailure
import com.floe.android.runlifecycle.RunStopHandler
import com.floe.android.runtimeipc.RuntimeConnection
import com.floe.android.runtimeipc.RuntimePackages
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean

internal sealed interface ComponentInstallEvent {
    val sessionID: Int
    data class Confirm(override val sessionID: Int, val intent: Intent) : ComponentInstallEvent
    data class Finished(override val sessionID: Int, val success: Boolean,
        val status: Int = Int.MIN_VALUE) : ComponentInstallEvent
}
internal data class ComponentPreparation(val intent: Intent?, val awaitingSystem: Boolean = false,
    val sessionID: Int? = null)

/** Installation only: never invents a task/project or grants model tool admission. */
class LocalRuntimeSetupHost(context: Context, private val scope: CoroutineScope) {
    private val context = context.applicationContext
    private val pair = RuntimePackages.forCore(context.packageName)
    enum class Phase { UNKNOWN, COMPONENT_REQUIRED, COMPONENT_INSTALLING, SETUP_REQUIRED, INSTALL_REQUIRED, INSTALLING, INSTALLED, STOPPING, FAILED }
    data class State(val phase: Phase = Phase.UNKNOWN, val bytes: Long = 0, val total: Long = -1,
                     val pendingIntent: Intent? = null, val localNetworkPermissionNeeded: Boolean = false,
                     val failure: LinuxSetupDiagnostic? = null,
                     internal val progress: LinuxSetupProgress? = null,
                     internal val componentSessionID: Int? = null)
    private val diagnostics = context.getSharedPreferences("linux_setup_diagnostic", Context.MODE_PRIVATE)
    private val mutable = MutableStateFlow(loadFailure()?.let { State(Phase.FAILED, diagnostics.getLong("bytes", 0), diagnostics.getLong("total", -1), failure = it) } ?: State())
    val state = mutable.asStateFlow()
    private val actions = Mutex()
    private val componentHandoff = ComponentInstallHandoff(actions)
    private val installRequest = AtomicReference<String?>()
    private val stopInstall = AtomicBoolean()
    private val foreground = RunForegroundController.forApplication(context)
    @Volatile private var engaged = false

    init {
        scope.launch {
            LocalRuntimeDistribution.results.collect { event ->
                if (!engaged) return@collect
                componentHandoff.route(event.sessionID) {
                    when (event) {
                        is ComponentInstallEvent.Confirm -> mutable.value = mutable.value.copy(
                            phase = Phase.COMPONENT_REQUIRED, pendingIntent = event.intent,
                            componentSessionID = event.sessionID, progress = null)
                        is ComponentInstallEvent.Finished -> {
                            componentHandoff.completed()
                            mutable.value = mutable.value.copy(pendingIntent = null, componentSessionID = null)
                            if (event.success) refresh() else {
                                val code = when (event.status) {
                                    android.content.pm.PackageInstaller.STATUS_FAILURE_ABORTED -> "COMPONENT_CANCELLED"
                                    android.content.pm.PackageInstaller.STATUS_FAILURE_BLOCKED -> "COMPONENT_BLOCKED"
                                    android.content.pm.PackageInstaller.STATUS_FAILURE_STORAGE -> "INSTALL_FAILED_INSUFFICIENT_STORAGE"
                                    android.content.pm.PackageInstaller.STATUS_FAILURE_INCOMPATIBLE,
                                    android.content.pm.PackageInstaller.STATUS_FAILURE_CONFLICT -> "COMPONENT_INCOMPATIBLE"
                                    else -> "COMPONENT_INSTALL_FAILED"
                                }
                                fail(LinuxSetupDiagnostic.fromFields(code, "component"))
                            }
                        }
                    }
                }
            }
        }
    }

    fun engage() { engaged = true; refresh() }
    fun openNotificationSettings() {
        mutable.value = State(Phase.SETUP_REQUIRED, pendingIntent = Intent(
            android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS
        ).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    fun onResume() {
        if (engaged && installRequest.get() == null && mutable.value.pendingIntent == null &&
            mutable.value.phase != Phase.COMPONENT_INSTALLING) refresh()
    }

    fun refresh() = scope.launch(Dispatchers.IO) {
        actions.withLock {
            if (installRequest.get() != null) return@withLock
            try {
                if (!componentMatches()) {
                    if (mutable.value.failure == null) mutable.value = State(Phase.COMPONENT_REQUIRED)
                    return@withLock
                }
                connection { client ->
                    val status = result(client.exchange("status"))
                    val installed = completeRequest(client, client.exchange("install.status"))
                    if (installed.optString("phase") == "failed") {
                        fail(wireFailure(installed)); return@connection
                    }
                    if (installed.optString("phase") != "installed" && mutable.value.failure != null)
                        return@connection // A lifecycle refresh must not erase the actual failure.
                    if (installed.optString("phase") == "installed") clearFailure()
                    mutable.value = State(when {
                        installed.optString("phase") == "installed" -> Phase.INSTALLED
                        !notificationsEnabled() -> Phase.SETUP_REQUIRED
                        else -> Phase.INSTALL_REQUIRED
                    }, localNetworkPermissionNeeded = android.os.Build.VERSION.SDK_INT >= 37 &&
                        !status.getBoolean("localNetworkGranted"))
                }
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (error: Exception) { fail(LinuxSetupDiagnostic.fromThrowable(error, "status")) }
        }
    }

    fun prepare() = scope.launch(Dispatchers.IO) {
        engaged = true
        actions.withLock {
            var lease: ForegroundLease? = null
            var admitted = false
            var operationID: String? = null
            var stage = "component"
            try {
                clearFailure()
                mutable.value = State(Phase.UNKNOWN)
                if (!componentMatches()) {
                    // Package updates kill the runtime: unresolved work is not idle.
                    ensureComponentIdle()
                    componentHandoff.begin()
                    val componentMeter = LinuxSetupProgressMeter()
                    val prepared = LocalRuntimeDistribution.prepareComponent(context) { bytes, total ->
                        mutable.value = State(Phase.COMPONENT_INSTALLING, bytes, total,
                            progress = componentMeter.sample(LinuxSetupStage.COMPONENT_FILE, bytes, total,
                                android.os.SystemClock.elapsedRealtime()))
                    }
                    componentHandoff.bind(prepared.sessionID)
                    mutable.value = mutable.value.copy(phase = if (prepared.awaitingSystem) Phase.COMPONENT_INSTALLING else Phase.COMPONENT_REQUIRED,
                        pendingIntent = prepared.intent, componentSessionID = prepared.sessionID, progress = null)
                    return@withLock
                }
                if (!notificationsEnabled()) { openNotificationSettings(); return@withLock }
                stage = "prepare"
                val id = java.util.UUID.randomUUID().toString()
                check(installRequest.compareAndSet(null, id))
                operationID = id
                stopInstall.set(false)
                val activeLease = foreground.acquireOperation(id, OperationKind.ENVIRONMENT_INSTALL,
                    RunStopHandler { cancelInstall() })
                lease = activeLease
                if (stopInstall.get()) return@withLock
                mutable.value = State(Phase.INSTALLING)
                stage = "connect"
                connection(activeLease.runtimePermit) { client ->
                    stage = "prepare"
                    // Retain ownership for an uncertain Binder response as well.
                    admitted = true
                    val envelope = client.exchange("install.start", requestID = id)
                    if (!envelope.getBoolean("ok")) {
                        admitted = false // authenticated, explicit admission refusal
                        throw LinuxSetupException(LinuxSetupDiagnostic.fromFields(
                            envelope.optString("code", "OPERATION_NOT_ADMITTED"), stage))
                    }
                    val receipt = result(envelope)
                    check(receipt.getString("requestID") == id)
                    val meter = LinuxSetupProgressMeter()
                    val installed = completeReceipt(client, id) {
                        val progress = result(client.exchange("install.status"))
                        if (progress.optString("requestID") == id) mutable.value = State(if (stopInstall.get()) Phase.STOPPING else Phase.INSTALLING,
                            progress.optLong("archiveBytes", 0), progress.optLong("archiveTotal", -1),
                            progress = meter.sample(LinuxSetupStage.fromWire(progress.optString("phase")),
                                progress.optLong("archiveBytes", 0), progress.optLong("archiveTotal", -1),
                                android.os.SystemClock.elapsedRealtime(), progress.optLong("entries", 0),
                                progress.optLong("extractedBytes", 0)))
                    }
                    check(installed.optString("phase") == "installed")
                }
            } catch (_: RunForegroundFailure.NotificationsBlocked) {
                openNotificationSettings()
            } catch (failure: kotlinx.coroutines.CancellationException) {
                stopInstall.set(true)
                throw failure
            } catch (error: Exception) {
                fail(LinuxSetupDiagnostic.fromThrowable(error, stage), if (admitted) Phase.STOPPING else Phase.FAILED)
            } finally {
                val settlingID = operationID
                if (admitted && settlingID != null) {
                    // View dismissal, coroutine cancellation or Binder loss is
                    // never completion. Rebind metadata and await actual stop;
                    // constructor recovery proves quiescence after process loss.
                    withContext(NonCancellable + Dispatchers.IO) {
                        val progress = awaitInstallQuiescence(settlingID)
                        when {
                            progress.optString("phase") == "installed" -> { clearFailure(); mutable.value = State(Phase.INSTALLED) }
                            stopInstall.get() -> { clearFailure(); mutable.value = State(Phase.INSTALL_REQUIRED) }
                            progress.optString("phase") == "failed" -> fail(wireFailure(progress))
                            else -> fail(mutable.value.failure ?: LinuxSetupDiagnostic.fromFields("OPERATION_FAILED", stage))
                        }
                    }
                }
                lease?.close()
                operationID?.let { installRequest.compareAndSet(it, null) }
                if (admitted && mutable.value.phase == Phase.INSTALLED) refresh()
            }
        }
    }

    private fun notificationsEnabled(): Boolean {
        if (android.os.Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(
                android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) return false
        return context.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()
    }

    private suspend fun awaitInstallQuiescence(id: String): JSONObject {
        while (true) {
            try {
                val settled = connection { client ->
                    if (stopInstall.get()) try {
                        result(client.exchange("install.cancel", JSONObject().put("requestID", id)))
                    } catch (_: Exception) { /* Already settled or still preparing. */ }
                    val progress = completeRequest(client, client.exchange("install.status"))
                    if (!result(client.exchange("status")).getBoolean("active")) progress else null
                }
                if (settled != null) return settled
            } catch (_: Exception) { /* Retain actual unresolved ownership. */ }
            delay(1_000)
        }
    }

    /** Caller presents this only after a visible user click; never a background launch. */
    fun consumeIntent(): Intent? {
        val value = mutable.value
        val intent = value.pendingIntent ?: return null
        // Keep the exact attested system confirmation reachable while its session is pending.
        // Returning from Android installer is not proof of success/cancellation.
        mutable.value = if (value.componentSessionID != null)
            value.copy(phase = Phase.COMPONENT_INSTALLING) else value.copy(pendingIntent = null)
        return intent
    }

    fun requestLocalNetworkAccess() = scope.launch(Dispatchers.IO) {
        if (android.os.Build.VERSION.SDK_INT < 37) return@launch
        actions.withLock {
            if (installRequest.get() != null || mutable.value.pendingIntent != null) return@withLock
            try {
                check(componentMatches())
                ensureComponentIdle()
                mutable.value = mutable.value.copy(pendingIntent = Intent().setComponent(
                    android.content.ComponentName(pair.runtime, RuntimePackages.ACCESS)))
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (error: Exception) { fail(LinuxSetupDiagnostic.fromThrowable(error, "local_network")) }
        }
    }

    fun cancelComponentInstall() = scope.launch(Dispatchers.IO) {
        actions.withLock {
            val id = mutable.value.componentSessionID ?: return@withLock
            try {
                LocalRuntimeDistribution.cancelComponent(context, id)
                componentHandoff.completed()
                mutable.value = State(Phase.COMPONENT_REQUIRED)
                refresh()
            } catch (failure: Exception) {
                fail(LinuxSetupDiagnostic.fromThrowable(failure, "component"))
            }
        }
    }

    fun cancelInstall() = scope.launch(Dispatchers.IO) {
        val id = installRequest.get() ?: return@launch
        stopInstall.set(true)
        mutable.value = mutable.value.copy(phase = Phase.STOPPING)
        try { connection { result(it.exchange("install.cancel", JSONObject().put("requestID", id))) } }
        catch (_: Exception) { /* Work remains owned until its actual terminal receipt. */ }
    }

    private fun componentMatches(): Boolean = RuntimeComponentMatch.matches(context)

    private suspend fun ensureComponentIdle() {
        try { context.packageManager.getPackageUid(pair.runtime, 0) }
        catch (_: android.content.pm.PackageManager.NameNotFoundException) { return }
        connection { if (result(it.exchange("status")).getBoolean("active"))
            throw LinuxSetupException(LinuxSetupDiagnostic.fromFields("RUNTIME_BUSY", "component")) }
    }

    private suspend fun <T> connection(permit: android.os.IBinder? = null, body: suspend (RuntimeConnection) -> T): T {
        val client = RuntimeConnection(context, permit)
        try {
            try { client.connect().get(15, TimeUnit.SECONDS) }
            catch (error: Exception) {
                val root = LinuxSetupDiagnostic.fromThrowable(error, "connect")
                throw LinuxSetupException(LinuxSetupDiagnostic.fromFields("RUNTIME_CONNECTION_FAILED", "connect", root.exceptionType))
            }
            return body(client)
        }
        finally { client.close() }
    }

    private fun result(response: JSONObject): JSONObject {
        if (!response.getBoolean("ok")) throw LinuxSetupException(LinuxSetupDiagnostic.fromFields(
            response.optString("code", "OPERATION_FAILED"), "status"))
        return response.getJSONObject("result")
    }

    private suspend fun completeRequest(client: RuntimeConnection, response: JSONObject): JSONObject {
        val value = result(response)
        return when (value.optString("state")) {
            "queued", "running" -> completeReceipt(client, value.getString("requestID")) {}
            "completed" -> value.getJSONObject("result")
            "failed", "unknown" -> throw LinuxSetupException(wireFailure(value))
            else -> value // progress requestID is not a queued receipt
        }
    }

    private suspend fun completeReceipt(client: RuntimeConnection, id: String, onProgress: suspend () -> Unit): JSONObject {
        while (true) {
            val value = result(client.exchange("request.status", JSONObject().put("requestID", id)))
            when (value.getString("state")) {
                "completed" -> return value.getJSONObject("result")
                "failed", "unknown" -> {
                    val progress = result(client.exchange("install.status"))
                    throw LinuxSetupException(if (progress.optString("phase") == "failed" && progress.optString("requestID") == id) wireFailure(progress)
                        else LinuxSetupDiagnostic.fromFields("OPERATION_FAILED", "prepare"))
                }
            }
            onProgress()
            delay(250)
        }
    }

    private fun wireFailure(value: JSONObject): LinuxSetupDiagnostic {
        mutable.value = mutable.value.copy(bytes = value.optLong("archiveBytes", mutable.value.bytes),
            total = value.optLong("archiveTotal", mutable.value.total))
        return LinuxSetupDiagnostic.fromFields(value.optString("failureCode", "OPERATION_FAILED"),
            value.optString("failureStage", "prepare"), value.optString("failureType"))
    }

    private fun fail(failure: LinuxSetupDiagnostic, phase: Phase = Phase.FAILED) {
        diagnostics.edit().putString("code", failure.code).putString("stage", failure.stage)
            .putString("type", failure.exceptionType).putLong("bytes", mutable.value.bytes)
            .putLong("total", mutable.value.total).apply()
        mutable.value = mutable.value.copy(phase = phase, pendingIntent = null, failure = failure,
            progress = mutable.value.progress?.copy(bytesPerSecond = null))
    }
    private fun loadFailure(): LinuxSetupDiagnostic? = diagnostics.getString("code", null)?.let {
        LinuxSetupDiagnostic.fromFields(it, diagnostics.getString("stage", "unknown").orEmpty(),
            diagnostics.getString("type", "").orEmpty())
    }
    private fun clearFailure() { diagnostics.edit().clear().apply() }

    fun diagnosticDetails(): String = buildString {
        appendLine("Floe Android ${com.floe.android.BuildConfig.VERSION_NAME} (${com.floe.android.BuildConfig.VERSION_CODE})")
        appendLine("Android ${android.os.Build.VERSION.RELEASE} / SDK ${android.os.Build.VERSION.SDK_INT}")
        appendLine("ABI: ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
        appendLine("Free MiB: ${context.filesDir.usableSpace / 1_048_576}")
        val version = try { context.packageManager.getPackageInfo(pair.runtime, 0).versionName } catch (_: Exception) { "missing" }
        appendLine("Runtime: $version")
        mutable.value.failure?.let {
            appendLine("Stage: ${it.stage}"); appendLine("Code: ${it.code}"); appendLine("Type: ${it.exceptionType}")
        }
        appendLine("Processed bytes: ${mutable.value.bytes}/${mutable.value.total}")
    }
}
