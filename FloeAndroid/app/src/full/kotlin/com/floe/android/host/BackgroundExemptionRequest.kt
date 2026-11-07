// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings

/** Full-only, explicit user action. true means the system dialog opened,
 * never that the user granted background access. Read real state on return. */
internal object BackgroundExemptionRequest {
    fun launch(context: Context): Boolean {
        if (context.checkSelfPermission(Manifest.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            != PackageManager.PERMISSION_GRANTED) return false
        val power = context.getSystemService(PowerManager::class.java) ?: return false
        if (power.isIgnoringBatteryOptimizations(context.packageName)) return false
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.fromParts("package", context.packageName, null))
        if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }
}
