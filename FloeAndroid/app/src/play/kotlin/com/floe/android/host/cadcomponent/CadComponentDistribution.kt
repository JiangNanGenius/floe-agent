// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.cadcomponent

import android.content.Context
import com.floe.android.host.optionalsplit.OptionalComponentSpec
import com.floe.android.host.optionalsplit.PlayOptionalSplitBackend
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import kotlinx.coroutines.CoroutineScope

/** Play requests only the declared `cadpreview` feature; no APK download or
 * package-install permission, sharing the one optional-split backend with
 * the Office preview. */
internal object CadComponentDistribution {
    internal val SPEC = OptionalComponentSpec(
        module = CadComponentController.MODULE,
        prefsName = "cad_play_delivery",
        stagingDir = "CadComponent",
        assetName = { CadComponentController.assetName() },
        resultAction = "com.floe.cad.PLAY_DELIVERY_UNUSED",
        resultReceiver = null,
        downloadService = null,
        installed = { CadComponentController.installed(it) },
    )

    fun installed(context: Context): Boolean =
        CadComponentController.MODULE in
            SplitInstallManagerFactory.create(context).installedModules

    fun create(context: Context, scope: CoroutineScope,
        publish: (CadComponentState) -> Unit, refresh: () -> Unit,
        canRemove: () -> Boolean): CadComponentBackend =
        PlayOptionalSplitBackend(context, SPEC, publish, refresh, canRemove)
}
