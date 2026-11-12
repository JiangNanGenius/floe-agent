// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlStructuredRouting
import com.floe.android.phonecontrol.PhoneControlStructuredSource

/**
 * The one routing decision used by DeviceAccessHost for a NEW observation.
 * Keeping this pure lets the host/backend seam be regression-tested without an
 * Android context or a privileged service, while the actual source calls stay
 * in the host.
 */
internal object DeviceStructuredUiRouting {

    fun activeSource(
        accessibilityUsable: Boolean,
        accessibilityArmed: Boolean,
        adbReady: Boolean,
        adbArmed: Boolean,
    ): PhoneControlStructuredSource = when {
        // An already-armed observation base keeps its backend until a fresh
        // observation/stop; a newly usable Accessibility service must not
        // silently reinterpret ADB refs.
        adbArmed -> PhoneControlStructuredSource.ADB_UI_AUTOMATION
        accessibilityArmed && accessibilityUsable ->
            PhoneControlStructuredSource.ACCESSIBILITY
        else -> PhoneControlStructuredRouting.observationSource(
            accessibilityUsable = accessibilityUsable,
            adbUiReady = adbReady,
        )
    }
}
