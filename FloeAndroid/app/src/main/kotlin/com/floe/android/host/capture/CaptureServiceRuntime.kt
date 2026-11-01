// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * One process-local accessor installed by the App host. A service started by
 * a stale persisted Intent has no host and stops itself; process death leaves
 * no restoration token or auto-start path.
 *
 * The [drainOwner] is created here, once per App process, and is deliberately
 * NOT a child of any Service or Activity scope. A foreground Service destroyed
 * during an unproven drain hands its exact resource set to this owner, which
 * keeps retrying the same joins and finalizes the original staging file
 * exactly once. [CaptureDrainOwner] itself documents the process-death limit.
 */
object CaptureServiceRuntime {
    @Volatile
    private var host: CaptureHostController? = null

    private val owner = CaptureDrainOwner(
        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    )

    @Synchronized
    fun install(host: CaptureHostController) {
        val existing = this.host
        check(existing == null || existing === host) { "a different CaptureHostController is installed" }
        this.host = host
    }

    @Synchronized
    fun uninstall(host: CaptureHostController) {
        if (this.host === host) this.host = null
    }

    fun current(): CaptureHostController? = host

    /** Process-lifetime late-drain owner, shared by both capture services. */
    fun drainOwner(): CaptureDrainOwner = owner
}

object PacketCaptureIntents {
    /** MainActivity consumes this extra once; it never contains a file path. */
    const val EXTRA_DESTINATION = "floe.destination"
    const val DESTINATION_NETWORK_CAPTURE = "network-capture"
}
