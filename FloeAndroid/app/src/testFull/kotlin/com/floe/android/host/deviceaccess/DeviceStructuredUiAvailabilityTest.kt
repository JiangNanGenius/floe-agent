// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.phonecontrol.PhoneControlBackend
import com.floe.android.phonecontrol.PhoneControlStructuredRouting
import com.floe.android.phonecontrol.PhoneControlStructuredSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Discovery must reflect a live verified ADB structured-UI backend even when
 * Accessibility is off, while never advertising device interaction from
 * pairing alone (the host passes only an actual readiness round-trip here).
 */
class DeviceStructuredUiAvailabilityTest {

    private fun availability(
        accessibility: Boolean = false,
        adb: Boolean = false,
        targets: Boolean = true,
    ) = DeviceAccessToolCatalog.Availability(
        accessibilityConnected = accessibility,
        adbStructuredUiReady = adb,
        targetPackagesSelected = targets,
        screenCaptureSupported = true,
    )

    @Test fun adbOnlyOffersTheSameDeviceStarSurface() {
        val tools = DeviceAccessToolCatalog.availableNames(availability(adb = true))
        assertTrue(DeviceAccessToolCatalog.DEVICE_OBSERVE in tools)
        assertTrue(DeviceAccessToolCatalog.DEVICE_ACT in tools)
        assertTrue(DeviceAccessToolCatalog.DEVICE_SCREENSHOT in tools)
        // No competing adb.* or phone.* public surface is introduced.
        assertFalse(tools.any { it.startsWith("adb.") || it.startsWith("phone.") })
    }

    @Test fun noStructuredBackendMeansNoDeviceInteractionTools() {
        val tools = DeviceAccessToolCatalog.availableNames(availability())
        assertFalse(DeviceAccessToolCatalog.DEVICE_OBSERVE in tools)
        assertFalse(DeviceAccessToolCatalog.DEVICE_ACT in tools)
        assertFalse(DeviceAccessToolCatalog.DEVICE_SCREENSHOT in tools)
        // Status stays available so the user can be told what is missing.
        assertTrue(DeviceAccessToolCatalog.SYSTEM_ACCESS_STATUS in tools)
    }

    @Test fun targetsRemainMandatoryForAdbOnlyDiscovery() {
        val tools = DeviceAccessToolCatalog.availableNames(availability(adb = true, targets = false))
        assertFalse(DeviceAccessToolCatalog.DEVICE_OBSERVE in tools)
        assertFalse(DeviceAccessToolCatalog.DEVICE_ACT in tools)
    }

    @Test fun observationIdNeverMovesBetweenBackends() {
        assertEquals(
            PhoneControlStructuredSource.ADB_UI_AUTOMATION,
            PhoneControlStructuredRouting.sourceForObservation(
                "adbui-abc", accessibilityUsable = true, adbUiReady = true),
        )
        assertEquals(
            PhoneControlStructuredSource.NONE,
            PhoneControlStructuredRouting.sourceForObservation(
                "adbui-abc", accessibilityUsable = true, adbUiReady = false),
        )
        assertEquals(
            PhoneControlBackend.ADB_UI_AUTOMATION,
            PhoneControlBackend.fromObservationId("adbui-abc"),
        )
    }
}
