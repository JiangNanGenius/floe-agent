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
    data class Confirm(val intent: Intent) : ComponentInstallEvent
    data class Finished(val success: Boolean) : ComponentInstallEvent
}
internal data class ComponentPreparation(val intent: Intent?, val awaitingSystem: Boolean = false)

/** Installation only: never invents a task/project or grants model tool admission. */
class LocalRuntimeSetupHost(context: Context, private val scope: CoroutineScope) {
    private val context = context.applicationContext
    private val pair = RuntimePackages.forCore(context.packageName)
    enum class Phase { UNKNOWN, COMPONENT_REQUIRED, COMPONENT_INSTALLING, SETUP_REQUIRED, INSTALL_REQUIRED, INSTALLING, INSTALLED, STOPPING, FAILED }
    data class State(val phase: Phase = Phase.UNKNOWN, val bytes: Long = 0, val total: Long = -1,
                     val pendingIntent: Intent? = null, val localNetworkPermissionNeeded: Boolean = false)
    private val mutable = MutableStateFlow(State())
    val state = mutable.asStateFlow()
    private val actions = Mutex()
    private val installRequest = AtomicReference<String?>()
    private val stopInstall = AtomicBoolean()
    private val foreground = RunForegroundController.forApplication(context)
    @Volatile private var engaged = false

    init {
        scope.launch {
            LocalRuntimeDistribution.results.collect { event ->
                if (!engaged) return@collect
                when (event) {
                    is ComponentInstallEvent.Confirm -> mutable.value = State(Phase.COMPONENT_REQUIRED, pendingIntent = event.intent)
                    is ComponentInstallEvent.Finished -> if (event.success) refresh() else mutable.value = State(Phase.FAILED)
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
                if (!componentMatches()) { mutable.value = State(Phase.COMPONENT_REQUIRED); return@withLock }
                connection { client ->
                    val status = result(client.exchange("status"))
                    val installed = completeRequest(client, client.exchange("install.status"))
                    mutable.value = State(when {
                        installed.optString("phase") == "installed" -> Phase.INSTALLED
                        !notificationsEnabled() -> Phase.SETUP_REQUIRED
                        else -> Phase.INSTALL_REQUIRED
                    }, localNetworkPermissionNeeded = android.os.Build.VERSION.SDK_INT >= 37 &&
                        !status.getBoolean("localNetworkGranted"))
                }
            } catch (_: Exception) { mutable.value = State(Phase.FAILED) }
        }
    }

    fun prepare() = scope.launch(Dispatchers.IO) {
        engaged = true
        actions.withLock {
            var lease: ForegroundLease? = null
            var admitted = false
            var operationID: String? = null
            try {
                if (!componentMatches()) {
                    // Package updates kill the runtime: unresolved work is not idle.
                    ensureComponentIdle()
                    val prepared = LocalRuntimeDistribution.prepareComponent(context)
                    mutable.value = State(if (prepared.awaitingSystem) Phase.COMPONENT_INSTALLING else Phase.COMPONENT_REQUIRED,
                        pendingIntent = prepared.intent)
                    return@withLock
                }
                if (!notificationsEnabled()) { openNotificationSettings(); return@withLock }
                val id = java.util.UUID.randomUUID().toString()
                check(installRequest.compareAndSet(null, id))
                operationID = id
                stopInstall.set(false)
                val activeLease = foreground.acquireOperation(id, OperationKind.ENVIRONMENT_INSTALL,
                    RunStopHandler { cancelInstall() })
                lease = activeLease
                if (stopInstall.get()) return@withLock
                mutable.value = State(Phase.INSTALLING)
                connection(activeLease.runtimePermit) { client ->
                    // Retain ownership for an uncertain Binder response as well.
                    admitted = true
                    val envelope = client.exchange("install.start", requestID = id)
                    if (!envelope.getBoolean("ok")) {
                        admitted = false // authenticated, explicit admission refusal
                        error("Installation was not admitted")
                    }
                    val receipt = result(envelope)
                    check(receipt.getString("requestID") == id)
                    val installed = completeReceipt(client, id) {
                        val progress = result(client.exchange("install.status"))
                        mutable.value = State(if (stopInstall.get()) Phase.STOPPING else Phase.INSTALLING,
                            progress.optLong("archiveBytes", 0), progress.optLong("archiveTotal", -1))
                    }
                    check(installed.optString("phase") == "installed")
                }
            } catch (_: RunForegroundFailure.NotificationsBlocked) {
                openNotificationSettings()
            } catch (failure: kotlinx.coroutines.CancellationException) {
                stopInstall.set(true)
                throw failure
            } catch (_: Exception) {
                mutable.value = State(if (admitted) Phase.STOPPING else Phase.FAILED)
            } finally {
                val settlingID = operationID
                if (admitted && settlingID != null) {
                    // View dismissal, coroutine cancellation or Binder loss is
                    // never completion. Rebind metadata and await actual stop;
                    // constructor recovery proves quiescence after process loss.
                    withContext(NonCancellable + Dispatchers.IO) {
                        val progress = awaitInstallQuiescence(settlingID)
                        mutable.value = State(when {
                            progress.optString("phase") == "installed" -> Phase.INSTALLED
                            stopInstall.get() -> Phase.INSTALL_REQUIRED
                            else -> Phase.FAILED
                        })
                    }
                }
                lease?.close()
                operationID?.let { installRequest.compareAndSet(it, null) }
                if (admitted) refresh()
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
        mutable.value = value.copy(pendingIntent = null)
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
            } catch (_: Exception) { mutable.value = State(Phase.FAILED) }
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
        connection { check(!result(it.exchange("status")).getBoolean("active")) }
    }

    private suspend fun <T> connection(permit: android.os.IBinder? = null, body: suspend (RuntimeConnection) -> T): T {
        val client = RuntimeConnection(context, permit)
        try { client.connect().get(15, TimeUnit.SECONDS); return body(client) }
        finally { client.close() }
    }

    private fun result(response: JSONObject): JSONObject {
        check(response.getBoolean("ok"))
        return response.getJSONObject("result")
    }

    private suspend fun completeRequest(client: RuntimeConnection, response: JSONObject): JSONObject {
        val value = result(response)
        return when (value.optString("state")) {
            "queued", "running" -> completeReceipt(client, value.getString("requestID")) {}
            "completed" -> value.getJSONObject("result")
            "failed", "unknown" -> error("Runtime operation failed")
            else -> value // progress requestID is not a queued receipt
        }
    }

    private suspend fun completeReceipt(client: RuntimeConnection, id: String, onProgress: suspend () -> Unit): JSONObject {
        while (true) {
            val value = result(client.exchange("request.status", JSONObject().put("requestID", id)))
            when (value.getString("state")) {
                "completed" -> return value.getJSONObject("result")
                "failed", "unknown" -> error("Runtime operation did not complete")
            }
            onProgress()
            delay(250)
        }
    }
}
