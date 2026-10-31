// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.platform

import android.app.Activity
import android.content.Context
import com.floe.android.host.RuntimeHost
import com.floe.android.host.RuntimePlatformExtension
import com.floe.android.host.deviceaccess.DeviceAccessHost

/**
 * FULL-channel factory. The real controller is Application-owned through the
 * RuntimeHost and outlives every view/sheet. Construction is data-only; status
 * reads and the platform-tool pump start only at the real lifecycle hooks.
 */
internal object DistributionPlatformFeature {
    fun create(context: Context): RuntimePlatformExtension =
        FullRuntimePlatformExtension(context.applicationContext ?: context)
}

private class FullRuntimePlatformExtension(
    private val context: Context,
) : RuntimePlatformExtension {
    private var device: DeviceAccessHost? = null

    override fun onHostStarted(host: RuntimeHost) {
        if (device != null) return
        // A backend construction failure must never take down App start: the
        // category simply stays unattached and every entry point is honest
        // about unavailability. Main still sees a real compile/runtime error in
        // qualification; this is not a success fallback.
        val created = runCatching {
            DeviceAccessHost(
                context = context,
                host = host,
                scope = host.scope,
                io = host.ioDispatcher,
            )
        }.getOrNull() ?: return
        device = created
        runCatching { created.start() }.onFailure {
            created.close()
            device = null
        }
    }

    override fun onOwnedStoreReady(epoch: Long) {
        device?.onOwnedStoreReady(epoch)
    }

    override suspend fun prepareForRootStop(): Boolean =
        device?.prepareForRootStop() ?: true

    override fun onRootStopped() {
        device?.onRootStopped()
    }

    override fun onActivityResumed(activity: Activity) {
        device?.onActivityResumed()
    }

    override fun onActivityPaused() {
        device?.onActivityPaused()
    }

    override fun close() {
        device?.close()
        device = null
    }
}
