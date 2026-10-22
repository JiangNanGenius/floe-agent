package com.floe.android.host.linux

import android.content.Context
import android.content.Intent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.mapNotNull

internal object LocalRuntimeDistribution {
    val results: Flow<ComponentInstallEvent> = RuntimeInstallState.state.mapNotNull {
        when (it) {
            RuntimeInstallState.Result.Idle -> null
            is RuntimeInstallState.Result.Confirmation -> ComponentInstallEvent.Confirm(it.intent)
            is RuntimeInstallState.Result.Finished -> ComponentInstallEvent.Finished(it.success)
        }
    }
    fun prepareComponent(context: Context): ComponentPreparation = when (val result = BundledRuntimeInstaller(context).install()) {
        is BundledRuntimeInstaller.Action.GrantInstallPermission -> ComponentPreparation(result.intent)
        is BundledRuntimeInstaller.Action.AwaitingSystem -> ComponentPreparation(null, awaitingSystem = true)
    }
}
