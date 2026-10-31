// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.settings

import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import com.floe.android.FloeSettingsExternalSection
import com.floe.android.R
import com.floe.android.design.FloeIcons

/**
 * FULL-channel settings seam for the G08 phone (device access) category.
 *
 * Mirrors the proven per-flavor `AppUpdateFeature` pattern: shared App code
 * references only this object's common shape, the FULL flavor supplies the
 * real page/resource/key, and the PLAY flavor supplies an empty Noop. No
 * phone/ADB/Root string, class, icon or Compose content therefore enters the
 * Play APK.
 *
 * The category is absent until the App integrator attaches the real
 * presentation (state + callbacks backed by the phonecontrol / embedded ADB /
 * root status APIs). An unattached build shows NO category at all — it never
 * renders a fabricated "available" state.
 */
internal object DistributionSettingsFeature {
    val available: Boolean = true

    /**
     * App-scoped presentation; attached once by the Application-owned host.
     * A Compose state makes the attach observable: the category appears when
     * real state callbacks exist (after the host starts) and disappears again
     * on a terminal detach, rather than depending on a later recomposition.
     */
    private val presentation = mutableStateOf<(@Composable () -> Unit)?>(null)

    fun attach(content: (@Composable () -> Unit)?) {
        presentation.value = content
    }

    /** True only when a real presentation was attached for this process. */
    val wired: Boolean get() = presentation.value != null

    @Composable
    fun sections(): List<FloeSettingsExternalSection> {
        val content = presentation.value ?: return emptyList()
        return listOf(
            FloeSettingsExternalSection(
                // Distinct from every FloeSettingsSection enum name; the host
                // treats it as an external key, not an enum value.
                key = "x:phone_access",
                titleRes = R.string.settings_phone,
                icon = FloeIcons.DeviceLocal,
                content = content,
            ),
        )
    }
}
