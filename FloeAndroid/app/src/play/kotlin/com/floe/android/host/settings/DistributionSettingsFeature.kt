// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.settings

import androidx.compose.runtime.Composable
import com.floe.android.FloeSettingsExternalSection

/**
 * PLAY-channel Noop for the G08 phone (device access) settings category.
 *
 * Google Play physically excludes phone control, embedded ADB and Root
 * access. This object keeps the shared App call site compiling while
 * contributing NO section, NO page, NO strings and NO dependencies. It must
 * never import a phone/ADB/root type or resource.
 */
internal object DistributionSettingsFeature {
    val available: Boolean = false

    fun attach(content: (@Composable () -> Unit)?) = Unit

    val wired: Boolean get() = false

    @Composable
    fun sections(): List<FloeSettingsExternalSection> = emptyList()
}
