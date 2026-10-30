// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkmonitor

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkMonitorNotificationCopyTest {
    @Test
    fun notificationReflectsActualResultWithoutTargetOrInventedAvailability() {
        val starting = NetworkMonitorNotificationCopy.forResult(
            chinese = false, starting = true, status = null, available = null, count = 0,
        )
        assertTrue(starting.text.contains("Starting"))
        assertFalse(starting.text.contains("available"))

        val failure = NetworkMonitorNotificationCopy.forResult(
            chinese = false, starting = false, status = "error", available = null, count = 3,
        )
        assertEquals("Latest measurement failed · 3 samples", failure.text)
        assertFalse(failure.text.contains("available"))

        val available = NetworkMonitorNotificationCopy.forResult(
            chinese = false, starting = false, status = "ok", available = true, count = 1,
        )
        assertEquals("Latest measurement: network available · 1 sample", available.text)
        listOf("example.com", "192.168.1.2", "HomeSSID", "root-owner").forEach {
            assertFalse(available.text.contains(it))
        }
    }

    @Test
    fun englishAndChineseControlsStayAligned() {
        val english = NetworkMonitorNotificationCopy.forResult(false, false, "timeout", null, 2)
        val chinese = NetworkMonitorNotificationCopy.forResult(true, false, "timeout", null, 2)
        assertEquals("Stop", english.stop)
        assertEquals("停止", chinese.stop)
        assertTrue(english.text.contains("timed out"))
        assertTrue(chinese.text.contains("超时"))
        assertTrue(english.text.contains("2"))
        assertTrue(chinese.text.contains("2"))
    }
}
