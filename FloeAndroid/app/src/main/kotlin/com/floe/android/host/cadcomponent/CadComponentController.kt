// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.cadcomponent

import android.app.Activity
import android.content.Context
import android.content.Intent
import com.floe.android.BuildConfig
import com.floe.android.host.optionalsplit.OptionalComponentState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal typealias CadComponentState = OptionalComponentState

// One backend contract serves every optional preview component; the channel
// distributions bind it to the Full/Play installers.
internal typealias CadComponentBackend =
    com.floe.android.host.optionalsplit.OptionalComponentBackend

/** App-owned CAD preview component state. PackageManager read-back, not a
 * download callback, is the only source of the installed flag. Both channels
 * use one module identity; the heavy pinned viewer bytes live exclusively in
 * the signed `cadpreview` split and are served only after the system has
 * validated signer and base version at install. */
internal class CadComponentController(
    private val context: Context,
    scope: CoroutineScope,
    private val viewerInUse: () -> Boolean = { false },
    private val onComponentChanged: () -> Unit = {},
) {
    private val mutable = MutableStateFlow(CadComponentState())
    val state = mutable.asStateFlow()
    private val backend = CadComponentDistribution.create(
        context, scope, ::update, ::refresh, ::canRemove)

    fun requestInstall() {
        if (state.value.working) return
        if (installed(context)) {
            refresh()
            return
        }
        backend.install()
    }

    fun requestClearCache() {
        if (canRemove()) backend.clearCache()
    }

    fun cancel() = backend.cancel()
    fun onInstallResult(intent: Intent) = backend.onInstallResult(intent)
    fun confirm(activity: Activity) = backend.confirm(activity)

    fun requestUninstall() {
        if (!canRemove()) {
            update(state.value.copy(failure = "component_in_use"))
            return
        }
        backend.uninstall()
    }

    fun onForeground(activity: Activity) {
        refresh()
        backend.onForeground(activity)
    }

    private fun canRemove(): Boolean = !viewerInUse()

    fun refresh() {
        if (installed(context)) {
            if (state.value.working) return
            val info = context.packageManager.getApplicationInfo(context.packageName, 0)
            val splitBytes = info.splitSourceDirs.orEmpty()
                .filter { it.substringAfterLast('/').contains(MODULE) }
                .sumOf { java.io.File(it).length() }
            update(CadComponentState("installed", removable = canRemove(), installedBytes = splitBytes, cachedBytes = backend.cacheBytes()))
        } else if (state.value.phase == "installed") {
            update(CadComponentState())
        }
    }

    private fun update(value: CadComponentState) {
        if (value.phase == "installed" && mutable.value.phase != "installed") onComponentChanged()
        mutable.value = value
    }

    companion object {
        const val MODULE = "cadpreview"

        fun installed(context: Context): Boolean = CadComponentDistribution.installed(context)

        fun assetName(): String =
            "Floe-CAD-Preview-${BuildConfig.VERSION_NAME}-full-arm64-v8a.component"
    }
}
