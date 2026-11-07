// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure policy of the shared background-execution settings helper: the
 * Android-12+ start-restriction gate must NOT demand Android-12 exemptions
 * on API 28-30, and the real power-status carrier keeps honest null
 * semantics for unreadable framework answers. Intent construction itself
 * needs the framework and stays thin by design.
 */
class BackgroundExecutionSettingsTest {

    @Test
    fun android12StartRestrictionGateStartsAtApi31() {
        assertFalse(BackgroundExecutionSettings.startRestrictionApplies(28))
        assertFalse(BackgroundExecutionSettings.startRestrictionApplies(29))
        assertFalse(BackgroundExecutionSettings.startRestrictionApplies(30))
        assertTrue(BackgroundExecutionSettings.startRestrictionApplies(31))
        assertTrue(BackgroundExecutionSettings.startRestrictionApplies(33))
        assertTrue(BackgroundExecutionSettings.startRestrictionApplies(34))
        assertTrue(BackgroundExecutionSettings.startRestrictionApplies(37))
    }

    @Test
    fun powerStatusCarriesTheAuthoritativeExemptionRead() {
        val exempt = BackgroundExecutionSettings.PowerStatus(
            ignoresBatteryOptimizations = true,
            standbyBucket = 10,
        )
        assertEquals(true, exempt.ignoresBatteryOptimizations)
        val restricted = BackgroundExecutionSettings.PowerStatus(
            ignoresBatteryOptimizations = false,
            standbyBucket = 45,
        )
        assertEquals(false, restricted.ignoresBatteryOptimizations)
    }

    @Test
    fun unreadableFrameworkAnswersStayNullAndAreNeverGuessed() {
        val unknown = BackgroundExecutionSettings.PowerStatus(
            ignoresBatteryOptimizations = null,
            standbyBucket = null,
        )
        assertNull(unknown.ignoresBatteryOptimizations)
        assertNull(unknown.standbyBucket)
    }
}
