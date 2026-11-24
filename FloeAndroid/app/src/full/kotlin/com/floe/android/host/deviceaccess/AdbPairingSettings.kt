// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.provider.Settings

internal object AdbPairingSettings {
    enum class Page { DEVELOPER_OPTIONS, ABOUT_PHONE }
    enum class Opened { REQUESTED_PAGE, SETTINGS_HOME, UNAVAILABLE }

    fun open(context: Context, page: Page): Opened = open(page) { action, highlight ->
        val intent = Intent(action)
        // AOSP Settings accepts a preference highlight on its public developer
        // settings entry. OEMs can ignore it, so the guide also names the row.
        if (highlight != null) intent.putExtra(":settings:fragment_args_key", highlight)
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    fun open(page: Page, start: (action: String, highlight: String?) -> Boolean): Opened {
        val primary = when (page) {
            Page.DEVELOPER_OPTIONS -> start(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS, "toggle_adb_wireless")
            Page.ABOUT_PHONE -> start(Settings.ACTION_DEVICE_INFO_SETTINGS, null)
        }
        return when {
            primary -> Opened.REQUESTED_PAGE
            start(Settings.ACTION_SETTINGS, null) -> Opened.SETTINGS_HOME
            else -> Opened.UNAVAILABLE
        }
    }
}
