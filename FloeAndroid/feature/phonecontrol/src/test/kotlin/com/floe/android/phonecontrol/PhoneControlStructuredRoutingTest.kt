// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneControlStructuredRoutingTest {

    @Test fun accessibilityStaysPreferredWhenBothAreUsable() {
        assertEquals(
            PhoneControlStructuredSource.ACCESSIBILITY,
            PhoneControlStructuredRouting.observationSource(
                accessibilityUsable = true, adbUiReady = true),
        )
    }

    @Test fun readyAdbIsDiscoverableWhenAccessibilityIsOff() {
        assertEquals(
            PhoneControlStructuredSource.ADB_UI_AUTOMATION,
            PhoneControlStructuredRouting.observationSource(
                accessibilityUsable = false, adbUiReady = true),
        )
        assertTrue(
            PhoneControlStructuredRouting.available(
                targetPackagesSelected = true,
                accessibilityUsable = false,
                adbUiReady = true,
            ),
        )
    }

    @Test fun noBackendMeansNoStructuredTools() {
        assertEquals(
            PhoneControlStructuredSource.NONE,
            PhoneControlStructuredRouting.observationSource(
                accessibilityUsable = false, adbUiReady = false),
        )
        assertFalse(
            PhoneControlStructuredRouting.available(
                targetPackagesSelected = true,
                accessibilityUsable = false,
                adbUiReady = false,
            ),
        )
    }

    @Test fun observationIdSelectsExactlyOneBackend() {
        assertEquals(
            PhoneControlStructuredSource.ADB_UI_AUTOMATION,
            PhoneControlStructuredRouting.sourceForObservation(
                "adbui-123", accessibilityUsable = true, adbUiReady = true),
        )
        // An ADB observation is never silently re-read by Accessibility.
        assertEquals(
            PhoneControlStructuredSource.NONE,
            PhoneControlStructuredRouting.sourceForObservation(
                "adbui-123", accessibilityUsable = true, adbUiReady = false),
        )
        // An accessibility observation is never silently replayed on ADB.
        assertEquals(
            PhoneControlStructuredSource.NONE,
            PhoneControlStructuredRouting.sourceForObservation(
                "n1", accessibilityUsable = false, adbUiReady = true),
        )
    }

    @Test fun acceptedUnknownRequiresReadbackButNotDispatchedDoesNot() {
        assertTrue(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.ACCEPTED))
        assertTrue(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.UNKNOWN))
        assertTrue(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.PARTIAL))
        assertFalse(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.NOT_DISPATCHED))
        assertFalse(PhoneControlStructuredRouting.requiresReadback(PhoneControlDispatch.REJECTED))
    }

    @Test fun readFallbackOnlyForUnavailableNotForDeniedState() {
        assertTrue(
            PhoneControlStructuredRouting.canFallbackToAdbForRead(
                PhoneControlUnavailable.SERVICE_NOT_CONNECTED, adbUiReady = true),
        )
        assertFalse(
            PhoneControlStructuredRouting.canFallbackToAdbForRead(
                PhoneControlUnavailable.SERVICE_NOT_CONNECTED, adbUiReady = false),
        )
        assertFalse(
            PhoneControlStructuredRouting.canFallbackToAdbForRead(
                PhoneControlDenial.STALE_OBSERVATION, adbUiReady = true),
        )
    }
}
