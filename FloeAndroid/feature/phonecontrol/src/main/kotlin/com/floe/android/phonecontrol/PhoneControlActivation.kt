// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.accessibility.AccessibilityManager

/**
 * The only activation hook: the user opens the system Accessibility settings
 * and enables this service themselves. There is deliberately no ADB/settings
 * write, no `WRITE_SECURE_SETTINGS`, and no programmatic enablement.
 *
 * `isEnabled` reads the actual AccessibilityManager list. It is separate from
 * "connected" and from "an operation actually succeeded".
 */
class PhoneControlActivation internal constructor(private val context: Context) {
    fun component(): ComponentName = ComponentName(
        context.packageName,
        PhoneControlAccessibilityService::class.java.name,
    )

    fun isEnabled(): Boolean {
        val manager = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        val enabled = manager != null && manager.getEnabledAccessibilityServiceList(
            AccessibilityServiceInfo.FEEDBACK_ALL_MASK,
        ).any { info ->
            val serviceInfo = info.resolveInfo?.serviceInfo ?: return@any false
            val expected = component()
            serviceInfo.packageName == expected.packageName &&
                normalize(serviceInfo.packageName, serviceInfo.name) == expected.className
        }
        PhoneControlRuntime.noteEnabled(enabled)
        return enabled
    }

    fun isConnected(): Boolean = PhoneControlRuntime.snapshot().connected

    fun settingsIntent(): Intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun normalize(packageName: String, name: String?): String {
        val raw = name.orEmpty()
        return when {
            raw.startsWith(".") -> packageName + raw
            !raw.contains('.') -> "$packageName.$raw"
            else -> raw
        }
    }
}
