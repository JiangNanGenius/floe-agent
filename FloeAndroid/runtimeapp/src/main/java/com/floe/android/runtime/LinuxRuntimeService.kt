// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.floe.android.runtimeipc.RuntimeControlBinder
import com.floe.android.runtimeipc.RuntimeForegroundPermit
import com.floe.android.runtimeipc.RuntimePackages
import com.floe.android.runtimeipc.RuntimePeerVerifier
import java.util.IdentityHashMap

/** Bound to Core's real foreground work. Intents never admit or restore commands. */
class LinuxRuntimeService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val kernel get() = (application as RuntimeApplication).kernel
    private lateinit var control: RuntimeControlBinder
    private val permits = IdentityHashMap<IBinder, IBinder.DeathRecipient>()
    private val inspectOwnership = object : Runnable {
        override fun run() {
            val retained = synchronized(permits) { permits.keys.toList() }
            if (kernel.hasOwnedWork()) {
                if (retained.any { !RuntimeForegroundPermit.isActive(this@LinuxRuntimeService, it) }) kernel.requestStop()
                handler.postDelayed(this, 1_000)
            } else clearPermits()
        }
    }

    override fun onCreate() {
        super.onCreate()
        RuntimePeerVerifier(this).verifyPeer(RuntimePackages.forRuntime(packageName).core)
        control = RuntimeControlBinder(this) { request, permit, workspaceGrant ->
            val admitsWork = request.operation == "install.start" || request.operation == "shell.start"
            if (admitsWork) {
                check(RuntimeForegroundPermit.isActive(this, permit)) { "Foreground operation is not active" }
            }
            val response = kernel.exchange(request, workspaceGrant) { RuntimeForegroundPermit.isActive(this, permit) }
            if (admitsWork) try { retainPermit(checkNotNull(permit)) }
            catch (_: Exception) {
                // Admission already happened: preserve its receipt even if
                // foreground ownership vanished. Failure here is a real stop
                // request, never a fabricated no-admission response.
                kernel.requestStop()
            }
            response
        }
        kernel.onChanged = { _ -> handler.post {
            handler.removeCallbacks(inspectOwnership)
            // A service/binding/token callback is a stop request, never exit proof.
            if (kernel.hasOwnedWork()) handler.post(inspectOwnership) else clearPermits()
        } }
    }

    private fun retainPermit(permit: IBinder) {
        synchronized(permits) {
            if (permits.containsKey(permit)) return
            val recipient = IBinder.DeathRecipient {
                if (synchronized(permits) { permits.containsKey(permit) } && kernel.hasOwnedWork()) kernel.requestStop()
            }
            permit.linkToDeath(recipient, 0)
            permits[permit] = recipient
        }
    }

    private fun clearPermits() {
        synchronized(permits) {
            permits.forEach { (permit, recipient) -> permit.unlinkToDeath(recipient, 0) }
            permits.clear()
        }
    }

    override fun onBind(intent: Intent?): IBinder = control
    override fun onUnbind(intent: Intent?): Boolean {
        if (kernel.hasOwnedWork()) kernel.requestStop()
        return false
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        stopSelf(startId)
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        handler.removeCallbacks(inspectOwnership)
        kernel.onChanged = null
        kernel.requestStop()
        clearPermits()
        super.onDestroy()
    }
}
