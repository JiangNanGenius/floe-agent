// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officecomponent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.floe.android.FloeApplication
import com.floe.android.host.optionalsplit.FullOptionalSplitBackend
import com.floe.android.host.optionalsplit.OptionalComponentSpec
import com.floe.android.host.optionalsplit.OptionalSplitInstallResults
import kotlinx.coroutines.CoroutineScope

internal object OfficeComponentDistribution {
    internal val SPEC = OptionalComponentSpec(
        module = OfficeComponentController.MODULE,
        prefsName = "office_component_install",
        stagingDir = "OfficeComponent",
        assetName = { OfficeComponentController.assetName() },
        resultAction = "com.floe.office.COMPONENT_INSTALL_RESULT",
        resultReceiver = OfficeComponentInstallReceiver::class.java,
        downloadService = OfficeComponentDownloadService::class.java,
        installed = { OfficeComponentController.installed(it) },
    )

    fun installed(context: Context): Boolean = runCatching {
        OfficeComponentController.MODULE in context.packageManager
            .getPackageInfo(context.packageName, 0).splitNames.orEmpty()
    }.getOrDefault(false)

    fun create(context: Context, scope: CoroutineScope, publish: (OfficeComponentState) -> Unit,
        refresh: () -> Unit, canRemove: () -> Boolean): OfficeComponentBackend =
        FullOptionalSplitBackend(context, SPEC, scope, publish, refresh, canRemove)
}

class OfficeComponentInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext as? FloeApplication ?: return
        OptionalSplitInstallResults.dispatch(
            OfficeComponentDistribution.SPEC, app.officeComponent::onInstallResult, intent)
    }
}
