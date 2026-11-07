// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officecomponent

import android.app.Activity
import android.content.Context
import android.content.Intent
import com.floe.android.BuildConfig
import com.floe.android.FloeApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

// One state shape serves every optional preview component; the Office
// name is kept so the verified Office UI/controller contract is unchanged.
internal typealias OfficeComponentState =
    com.floe.android.host.optionalsplit.OptionalComponentState

// One backend contract serves every optional preview component; channel
// distributions bind it to the Full/Play installers.
internal typealias OfficeComponentBackend =
    com.floe.android.host.optionalsplit.OptionalComponentBackend

/** App-owned install state. PackageManager read-back, not a download callback,
 * is the only source of the installed flag. Both channels use one module identity. */
internal class OfficeComponentController(private val context: Context, scope: CoroutineScope) {
    private val mutable = MutableStateFlow(OfficeComponentState())
    val state = mutable.asStateFlow()
    private val backend = OfficeComponentDistribution.create(context, scope,
        ::update, ::refresh, ::canRemove)
    fun requestInstall() {
        if (state.value.working) return
        if (installed(context)) { refresh(); return }
        backend.install()
    }
    fun requestClearCache() {
        if (canRemove()) backend.clearCache()
    }

    fun cancel() { backend.cancel() }
    fun onInstallResult(intent: Intent) { backend.onInstallResult(intent) }
    fun confirm(activity: Activity) { backend.confirm(activity) }
    fun requestUninstall() {
        if (!canRemove()) { update(state.value.copy(failure = "component_in_use")); return }
        backend.uninstall()
    }
    fun onForeground(activity: Activity) { refresh(); backend.onForeground(activity) }
    private fun canRemove(): Boolean {
        val app = context.applicationContext as? FloeApplication ?: return false
        val preview = app.officePreviews.state.value
        return !preview.staging && preview.viewer == null && preview.ownedReturn == null
    }
    fun refresh() {
        if (installed(context)) {
            if (state.value.working) return
            val info = context.packageManager.getApplicationInfo(context.packageName, 0)
            val splitBytes = info.splitSourceDirs.orEmpty().filter { it.substringAfterLast('/').contains(MODULE) }
                .sumOf { java.io.File(it).length() }
            update(OfficeComponentState("installed", removable = canRemove(), installedBytes = splitBytes, cachedBytes = backend.cacheBytes()))
        } else if (state.value.phase == "installed") update(OfficeComponentState())
    }
    private fun update(value: OfficeComponentState) { mutable.value = value }
    companion object {
        const val MODULE = "officepreview"
        fun installed(context: Context): Boolean = OfficeComponentDistribution.installed(context)
        fun assetName(): String = "Floe-Office-Preview-${BuildConfig.VERSION_NAME}-full-arm64-v8a.component"
    }
}
