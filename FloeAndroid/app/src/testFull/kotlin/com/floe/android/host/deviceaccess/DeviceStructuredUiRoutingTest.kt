// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlStructuredSource
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Exercises the exact source-selection seam used by DeviceAccessHost: an
 * armed ADB page keeps its backend, an armed Accessibility page stays AS, and
 * a genuinely ready ADB tier is selected when Accessibility is off. This is
 * routing, not authorization; the host still checks arm/grant/epoch/target.
 */
class DeviceStructuredUiRoutingTest {

    @Test fun accessibilityIsPreferredWhenUsableAndNotArmed() {
        assertEquals(
            PhoneControlStructuredSource.ACCESSIBILITY,
            DeviceStructuredUiRouting.activeSource(
                accessibilityUsable = true,
                accessibilityArmed = false,
                adbReady = true,
                adbArmed = false,
            ),
        )
    }

    @Test fun adbIsSelectedWhenAccessibilityIsActuallyOff() {
        assertEquals(
            PhoneControlStructuredSource.ADB_UI_AUTOMATION,
            DeviceStructuredUiRouting.activeSource(
                accessibilityUsable = false,
                accessibilityArmed = false,
                adbReady = true,
                adbArmed = false,
            ),
        )
    }

    @Test fun anArmedAdbPageIsNeverReinterpretedByNewAccessibility() {
        assertEquals(
            PhoneControlStructuredSource.ADB_UI_AUTOMATION,
            DeviceStructuredUiRouting.activeSource(
                accessibilityUsable = true,
                accessibilityArmed = true,
                adbReady = true,
                adbArmed = true,
            ),
        )
    }

    @Test fun anArmedAccessibilityPageStaysAsUntilAFreshObservation() {
        assertEquals(
            PhoneControlStructuredSource.ACCESSIBILITY,
            DeviceStructuredUiRouting.activeSource(
                accessibilityUsable = true,
                accessibilityArmed = true,
                adbReady = true,
                adbArmed = false,
            ),
        )
    }

    @Test fun noBackendMeansNoFakeStructuredSource() {
        assertEquals(
            PhoneControlStructuredSource.NONE,
            DeviceStructuredUiRouting.activeSource(
                accessibilityUsable = false,
                accessibilityArmed = false,
                adbReady = false,
                adbArmed = false,
            ),
        )
    }
}
