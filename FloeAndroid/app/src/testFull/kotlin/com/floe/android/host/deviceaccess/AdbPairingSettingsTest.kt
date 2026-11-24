// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.provider.Settings
import org.junit.Assert.assertEquals
import org.junit.Test

class AdbPairingSettingsTest {
    @Test
    fun developerOptionsAreOpenedWithWirelessDebuggingHighlighted() {
        val launched = mutableListOf<Pair<String, String?>>()
        val result = AdbPairingSettings.open(AdbPairingSettings.Page.DEVELOPER_OPTIONS) { action, key ->
            launched += action to key
            true
        }

        assertEquals(AdbPairingSettings.Opened.REQUESTED_PAGE, result)
        assertEquals(
            listOf(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS to "toggle_adb_wireless"),
            launched,
        )
    }

    @Test
    fun unavailableDeveloperOptionsFallBackToSettingsHome() {
        val launched = mutableListOf<Pair<String, String?>>()
        val result = AdbPairingSettings.open(AdbPairingSettings.Page.DEVELOPER_OPTIONS) { action, key ->
            launched += action to key
            action == Settings.ACTION_SETTINGS
        }

        assertEquals(AdbPairingSettings.Opened.SETTINGS_HOME, result)
        assertEquals(
            listOf(
                Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS to "toggle_adb_wireless",
                Settings.ACTION_SETTINGS to null,
            ),
            launched,
        )
    }

    @Test
    fun unavailableAboutPhoneAndSettingsReturnAnActionableFailure() {
        val launched = mutableListOf<String>()
        val result = AdbPairingSettings.open(AdbPairingSettings.Page.ABOUT_PHONE) { action, key ->
            assertEquals(null, key)
            launched += action
            false
        }

        assertEquals(AdbPairingSettings.Opened.UNAVAILABLE, result)
        assertEquals(listOf(Settings.ACTION_DEVICE_INFO_SETTINGS, Settings.ACTION_SETTINGS), launched)
    }
}
