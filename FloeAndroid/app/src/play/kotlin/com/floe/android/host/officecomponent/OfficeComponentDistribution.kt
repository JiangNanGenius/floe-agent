// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officecomponent

import android.content.Context
import com.floe.android.host.optionalsplit.OptionalComponentSpec
import com.floe.android.host.optionalsplit.PlayOptionalSplitBackend
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import kotlinx.coroutines.CoroutineScope

internal object OfficeComponentDistribution {
    internal val SPEC = OptionalComponentSpec(
        module = OfficeComponentController.MODULE,
        prefsName = "office_play_delivery",
        stagingDir = "OfficeComponent",
        assetName = { OfficeComponentController.assetName() },
        resultAction = "com.floe.office.PLAY_DELIVERY_UNUSED",
        resultReceiver = null,
        downloadService = null,
        installed = { OfficeComponentController.installed(it) },
    )

    fun installed(context: Context): Boolean = OfficeComponentController.MODULE in
        SplitInstallManagerFactory.create(context).installedModules

    fun create(context: Context, scope: CoroutineScope, publish: (OfficeComponentState) -> Unit,
        refresh: () -> Unit, canRemove: () -> Boolean): OfficeComponentBackend =
        PlayOptionalSplitBackend(context, SPEC, publish, refresh, canRemove)
}
