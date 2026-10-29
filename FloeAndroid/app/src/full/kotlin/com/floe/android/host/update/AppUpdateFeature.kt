// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import android.app.Application
import androidx.compose.runtime.Composable
import kotlinx.coroutines.CoroutineScope

/**
 * Full-channel (GitHub) self-update capability.
 *
 * This object is the flavour seam referenced from shared App code: the full
 * source set provides the real GitHub check/download/install implementation,
 * the Play source set provides an empty Noop object of the same shape. The
 * Play APK therefore physically contains no updater implementation, no
 * repository coordinates, no download code and no install UI — the Play
 * channel updates through Google Play and keeps no REQUEST_INSTALL_PACKAGES
 * permission.
 */
internal object AppUpdateFeature {
    val available: Boolean = true

    @Volatile
    private var controllerInstance: AppUpdateController? = null

    /** Application-owned creation; data-only until a real user/foreground event. */
    fun attach(application: Application, scope: CoroutineScope) {
        if (controllerInstance != null) return
        val created = AppUpdateController.create(application, scope)
        controllerInstance = created
        AppUpdateRuntime.controller = created
        created.attach()
    }

    fun controller(): AppUpdateController? = controllerInstance

    /** Called from the real Activity resume; cooldown/enabled rules apply. */
    fun onApplicationForeground() {
        controllerInstance?.onApplicationForeground()
    }

    @Composable
    fun SettingsEntry() {
        AppUpdateSettingsEntry()
    }

    @Composable
    fun DialogHost() {
        AppUpdateDialogHost()
    }
}
