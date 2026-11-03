// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.capture

import android.content.Context
import com.floe.android.core.networkcapture.RootCaptureBackend

/**
 * Loads the Full-only root capture implementation by name. The Play source
 * set has no such class, so this returns null and the UI shows the honest
 * `playBuild` reason. No root class, permission, receiver or native helper is
 * linked into the Play application.
 */
internal object RootCaptureBackendLoader {
    private const val FULL_CLASS = "com.floe.android.host.capture.root.FullRootCaptureBackend"
    internal const val FULL_SERVICE_CLASS = "com.floe.android.host.capture.root.RootPacketCaptureService"

    fun load(context: Context): RootCaptureBackend? = try {
        val type = Class.forName(FULL_CLASS, false, context.classLoader)
        val constructor = type.getConstructor(Context::class.java)
        constructor.newInstance(context.applicationContext) as? RootCaptureBackend
    } catch (_: Throwable) {
        null
    }
}
