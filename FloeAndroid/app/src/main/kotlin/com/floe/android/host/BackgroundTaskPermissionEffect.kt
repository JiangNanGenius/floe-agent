// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.R
import com.floe.android.design.*

/** One honest notice per process; OS consent follows an explicit button. */
@Composable
fun BackgroundTaskPermissionEffect(host: RuntimeHost) {
    val notice by host.backgroundAvailabilityNotice.collectAsState()
    val context = LocalContext.current
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        // Permission result never replays a task or pretends an old task
        // acquired protection. The next explicit launch checks real state.
        host.backgroundAvailabilityNotice.value = null
    }
    if (notice == null) return
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    FloePageSheet(visible = true,
        onDismiss = { host.backgroundAvailabilityNotice.value = null },
        widthFraction = if (wide) 0.52f else 1f,
        heightFraction = if (wide) 0.42f else 0.46f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
    ) {
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            FloeText(stringResource(R.string.background_task_notice_title),
                style = Floe.typography.title, color = Floe.colors.label)
            FloeText(stringResource(if (notice == RuntimeHost.BackgroundAvailability.NOTIFICATIONS_BLOCKED)
                R.string.background_task_notifications_notice else R.string.background_task_system_notice),
                style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            if (notice == RuntimeHost.BackgroundAvailability.NOTIFICATIONS_BLOCKED) {
                FloeCapsuleAction(label = stringResource(R.string.background_task_notifications_enable), onClick = {
                    val preferences = context.getSharedPreferences("floe-background-permission", 0)
                    val asked = preferences.getBoolean("notificationAsked", false)
                    if (Build.VERSION.SDK_INT >= 33 && !asked &&
                        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                        preferences.edit().putBoolean("notificationAsked", true).apply()
                        permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                    } else {
                        host.backgroundAvailabilityNotice.value = null
                        try { context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)) }
                        catch (_: android.content.ActivityNotFoundException) { }
                        catch (_: SecurityException) { }
                    }
                })
            }
            FloeCapsuleAction(label = stringResource(R.string.background_task_keep_open),
                onClick = { host.backgroundAvailabilityNotice.value = null })
        }
    }
}
