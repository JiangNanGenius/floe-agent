package com.floe.android.host.linux

import android.content.Context
import android.content.Intent
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.mapNotNull

internal object LocalRuntimeDistribution {
    val results: Flow<ComponentInstallEvent> = RuntimeInstallState.state.mapNotNull {
        when (it) {
            RuntimeInstallState.Result.Idle -> null
            is RuntimeInstallState.Result.Confirmation -> ComponentInstallEvent.Confirm(it.sessionID, it.intent)
            is RuntimeInstallState.Result.Finished -> ComponentInstallEvent.Finished(it.sessionID, it.success, it.status)
        }
    }
    fun prepareComponent(context: Context, progress: (Long, Long) -> Unit = { _, _ -> }): ComponentPreparation = when (val result = BundledRuntimeInstaller(context).install(progress)) {
        is BundledRuntimeInstaller.Action.GrantInstallPermission -> ComponentPreparation(result.intent)
        is BundledRuntimeInstaller.Action.AwaitingSystem -> ComponentPreparation(null, awaitingSystem = true,
            sessionID = result.sessionID)
    }
    fun cancelComponent(context: Context, sessionID: Int) {
        val expected = com.floe.android.runtimeipc.RuntimePackages.forCore(context.packageName).runtime
        val installer = context.packageManager.packageInstaller
        val own = installer.mySessions.firstOrNull { it.sessionId == sessionID && it.appPackageName == expected }
        if (own != null) installer.abandonSession(own.sessionId)
    }
}
