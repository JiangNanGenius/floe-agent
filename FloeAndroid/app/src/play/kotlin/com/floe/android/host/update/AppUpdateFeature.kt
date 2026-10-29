package com.floe.android.host.update

import android.app.Application
import androidx.compose.runtime.Composable
import kotlinx.coroutines.CoroutineScope

/**
 * Play-channel Noop for the App self-update capability.
 *
 * Google Play policy forbids updating the app outside the Play mechanism, so
 * the Play product physically excludes the updater: this object has no
 * download code, no repository coordinates, no install intent, no settings
 * entry and no dialog. It only keeps the shared call sites compiling.
 */
internal object AppUpdateFeature {
    val available: Boolean = false

    fun attach(application: Application, scope: CoroutineScope) = Unit

    fun onApplicationForeground() = Unit

    @Composable
    fun SettingsEntry() = Unit

    @Composable
    fun DialogHost() = Unit
}
