// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import org.junit.Assert.assertEquals
import org.junit.Test

/** Source-only regression for the sheet's stepper math (closed ranges). */
class DeviceAccessSystemSettingsSheetTest {

    private fun entry(
        kind: DeviceAccessSystemSettingKindUi,
        min: Long,
        max: Long,
    ) = DeviceAccessSystemSettingUi(
        namespace = "system",
        key = "k",
        deviceWide = false,
        currentValue = null,
        baselineValue = null,
        kind = kind,
        minInclusive = min,
        maxInclusive = max,
    )

    @Test
    fun intSteppersClampToTheClosedRange() {
        val brightness = entry(DeviceAccessSystemSettingKindUi.INT, 0, 255)
        assertEquals("16", stepValue(brightness, "", down = false))
        assertEquals("0", stepValue(brightness, "8", down = true))
        assertEquals("255", stepValue(brightness, "250", down = false))
        assertEquals("255", stepValue(brightness, "999", down = false))
        assertEquals("0", stepValue(brightness, "3", down = true))
    }

    @Test
    fun rotationStepsByOneAndTimeoutByFiveSeconds() {
        val rotation = entry(DeviceAccessSystemSettingKindUi.INT, 0, 3)
        assertEquals("1", stepValue(rotation, "0", down = false))
        assertEquals("3", stepValue(rotation, "3", down = false))
        val timeout = entry(DeviceAccessSystemSettingKindUi.INT, 15_000, 1_800_000)
        assertEquals("20000", stepValue(timeout, "15000", down = false))
        assertEquals("15000", stepValue(timeout, "", down = false))
    }

    @Test
    fun scaleSteppersMoveInHalvesAndNormalize() {
        val scale = entry(DeviceAccessSystemSettingKindUi.SCALE, 0, 10)
        assertEquals("0.5", stepValue(scale, "0", down = false))
        assertEquals("1", stepValue(scale, "0.5", down = false))
        assertEquals("0", stepValue(scale, "0.25", down = true))
        assertEquals("10", stepValue(scale, "9.75", down = false))
    }
}
