// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Test

class PhoneControlModelsTest {
    @Test
    fun generationDefaultsToEpochWithoutRequiringEnvironmentOrJobIds() {
        val principal = PhoneControlPrincipal(
            owner = testOwner(),
            epoch = 7,
            allowedPackages = setOf("com.example.app"),
        )
        assertEquals(7L, principal.generation)
        val grant = PhoneControlGrant(
            owner = testOwner(),
            epoch = 7,
            allowedPackages = setOf("com.example.app"),
            allowGlobalNavigation = true,
            allowScreenshot = false,
        )
        assertEquals(7L, grant.generation)
        assertEquals(null, principal.grantID)
        assertEquals(null, principal.callID)
    }

    @Test
    fun observeRequestIsClampedToTheDeclaredBounds() {
        val high = PhoneControlObserveRequest(
            maxNodes = Int.MAX_VALUE,
            maxDepth = Int.MAX_VALUE,
            textBudgetChars = Int.MAX_VALUE,
        ).normalized()
        assertEquals(PhoneControlLimits.MAX_NODES, high.maxNodes)
        assertEquals(PhoneControlLimits.MAX_DEPTH, high.maxDepth)
        assertEquals(PhoneControlLimits.MAX_TEXT_BUDGET_CHARS, high.textBudgetChars)

        val low = PhoneControlObserveRequest(
            maxNodes = -1,
            maxDepth = -1,
            textBudgetChars = -1,
        ).normalized()
        assertEquals(1, low.maxNodes)
        assertEquals(0, low.maxDepth)
        assertEquals(0, low.textBudgetChars)
    }

    @Test
    fun screenshotRequestIsClampedToTheDeclaredBounds() {
        val high = PhoneControlScreenshotRequest(
            maxBytes = Int.MAX_VALUE,
            maxDimension = Int.MAX_VALUE,
            quality = Int.MAX_VALUE,
        ).normalized()
        assertEquals(PhoneControlLimits.MAX_SCREENSHOT_BYTES, high.maxBytes)
        assertEquals(PhoneControlLimits.MAX_SCREENSHOT_DIMENSION, high.maxDimension)
        assertEquals(90, high.quality)

        val low = PhoneControlScreenshotRequest(
            maxBytes = 1,
            maxDimension = 1,
            quality = 1,
        ).normalized()
        assertEquals(32_768, low.maxBytes)
        assertEquals(PhoneControlLimits.MIN_SCREENSHOT_DIMENSION, low.maxDimension)
        assertEquals(PhoneControlLimits.MIN_SCREENSHOT_QUALITY, low.quality)
    }

    @Test
    fun boundsReportEmptyAndContainment() {
        val bounds = PhoneControlBounds(10, 20, 30, 60)
        assertEquals(20, bounds.width)
        assertEquals(40, bounds.height)
        assertEquals(false, bounds.isEmpty)
        assertEquals(true, bounds.contains(20, 40))
        assertEquals(false, bounds.contains(30, 40))
        assertEquals(true, PhoneControlBounds(0, 0, 0, 0).isEmpty)
    }
}
