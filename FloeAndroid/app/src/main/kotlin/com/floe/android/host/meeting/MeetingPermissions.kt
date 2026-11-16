// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.meeting

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Runtime permission helpers for the coordinator's ActivityResult launcher.
 *
 * The package never requests a permission itself: Android requires a visible
 * Activity for the microphone prompt. The UI calls [requiredPermissions] with
 * `ActivityResultContracts.RequestMultiplePermissions`, then
 * [MeetingManager.refreshPermissionState] when the callback returns.
 */
internal object MeetingPermissions {
    fun state(context: Context): MeetingPermissionState {
        val microphone = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        val notificationsRequired = Build.VERSION.SDK_INT >= 33
        val globallyEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
        val notifications = if (notificationsRequired) {
            globallyEnabled && ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            globallyEnabled
        }
        return MeetingPermissionState(
            microphoneGranted = microphone,
            notificationsGranted = notifications,
            notificationsRuntimeRequired = notificationsRequired,
        )
    }

    fun required(): List<String> = buildList {
        add(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
    }
}
