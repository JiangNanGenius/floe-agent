package com.floe.android.host.linux

import android.content.Context
import android.content.Intent
import android.net.Uri
import com.floe.android.runtimeipc.RuntimePackages
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

internal object LocalRuntimeDistribution {
    val results: Flow<ComponentInstallEvent> = emptyFlow()
    fun prepareComponent(context: Context): ComponentPreparation = ComponentPreparation(Intent(Intent.ACTION_VIEW,
        Uri.parse("https://play.google.com/store/apps/details?id=" + RuntimePackages.forCore(context.packageName).runtime)))
}
