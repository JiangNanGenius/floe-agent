// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

/**
 * One process-local accessor installed by the App host. A service started by
 * a stale persisted Intent has no host and stops itself; process death leaves
 * no restoration token or auto-start path.
 */
object CaptureServiceRuntime {
    @Volatile
    private var host: CaptureHostController? = null

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
}

object PacketCaptureIntents {
    /** MainActivity consumes this extra once; it never contains a file path. */
    const val EXTRA_DESTINATION = "floe.destination"
    const val DESTINATION_NETWORK_CAPTURE = "network-capture"
}
