// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import com.floe.android.DeviceAccessAccessibilityUi
import com.floe.android.phonecontrol.PhoneControlBlocker
import com.floe.android.phonecontrol.PhoneControlScreenshotSupport
import com.floe.android.phonecontrol.PhoneControlStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceAccessibilityRefreshTest {
    private fun status(connected: Boolean, enabled: Boolean = connected, blocker: PhoneControlBlocker? = null) =
        PhoneControlStatus(connected, enabled, blocker, null, 1, 1, PhoneControlScreenshotSupport.DISPLAY)

    @Test fun systemSettingAndActualAttachmentAreNotConfused() {
        assertEquals(DeviceAccessAccessibilityUi.NotGranted, deviceAccessibilityUi(false, status(false)))
        assertEquals(DeviceAccessAccessibilityUi.Inconsistent, deviceAccessibilityUi(true, status(false)))
        assertEquals(DeviceAccessAccessibilityUi.Inconsistent, deviceAccessibilityUi(false, status(true)))
        assertEquals(DeviceAccessAccessibilityUi.Granted, deviceAccessibilityUi(true, status(true)))
    }

    @Test fun discoveryRequiresTheSameRealServiceAndOpenClientAsTheSettingsBackend() {
        assertFalse(phoneAccessibilityBackendReady(true, status(true), clientOpen = false))
        assertFalse(phoneAccessibilityBackendReady(false, status(true), clientOpen = true))
        assertFalse(phoneAccessibilityBackendReady(true, status(false), clientOpen = true))
        assertFalse(phoneAccessibilityBackendReady(true, status(true, blocker = PhoneControlBlocker.LOCKED), clientOpen = true))
        assertFalse(phoneAccessibilityBackendReady(true, status(true, blocker = PhoneControlBlocker.SERVICE_DISCONNECTED), clientOpen = true))
        assertTrue(phoneAccessibilityBackendReady(true, status(true), clientOpen = true))
        // Explicit re-arm may clear the previous task's user stop, but does
        // not itself grant a new task or bypass the real execution checks.
        assertTrue(phoneAccessibilityBackendReady(true, status(true, blocker = PhoneControlBlocker.STOPPED), clientOpen = true))
    }
}
