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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
    LaunchedEffect(notice) { host.backgroundNoticeBoundToUi() }
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    // A REAL background start restriction is only user-actionable where the
    // Android-12+ restriction (and its exemption surface) exists; API 28-30
    // keeps the ordinary copy and never claims an Android-12 exemption.
    val restrictedActionable =
        notice == RuntimeHost.BackgroundAvailability.BACKGROUND_START_RESTRICTED &&
            BackgroundExecutionSettings.startRestrictionApplies(Build.VERSION.SDK_INT)
    FloePageSheet(visible = true,
        onDismiss = { host.backgroundAvailabilityNotice.value = null },
        widthFraction = if (wide) 0.52f else 1f,
        heightFraction = if (wide) 0.58f else 0.64f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
    ) {
        Column(
            Modifier.fillMaxSize().padding(24.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            FloeText(
                stringResource(
                    if (restrictedActionable) R.string.background_task_start_restricted_title
                    else R.string.background_task_notice_title),
                style = Floe.typography.title, color = Floe.colors.label)
            FloeText(
                stringResource(when {
                    notice == RuntimeHost.BackgroundAvailability.NOTIFICATIONS_BLOCKED ->
                        R.string.background_task_notifications_notice
                    restrictedActionable -> R.string.background_task_start_restricted_body
                    else -> R.string.background_task_system_notice
                }),
                style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            if (restrictedActionable) {
                // Opening settings proves nothing. The lifecycle-bound read
                // refreshes even when no other UI state changes on return.
                val power = rememberBackgroundPowerStatus()
                FloeText(
                    stringResource(when (power.ignoresBatteryOptimizations) {
                        true -> R.string.background_task_power_exempt
                        false -> R.string.background_task_power_not_exempt
                        null -> R.string.background_task_power_unknown
                    }),
                    style = Floe.typography.metadata, color = Floe.colors.secondaryLabel)
                // Three DISTINCT explicit routes. The direct request opens the
                // own-package consent dialog where available and falls back to
                // the ordinary settings; none of them claims a grant — the
                // status line above re-reads the real state on return.
                FloeCapsuleAction(
                    label = stringResource(R.string.background_task_request_exemption),
                    onClick = {
                        BackgroundExecutionSettings.requestExemptionOrSettings(context)
                    })
                FloeCapsuleAction(
                    label = stringResource(R.string.background_task_open_app_battery),
                    onClick = { BackgroundExecutionSettings.openAppBatterySettings(context) })
                FloeCapsuleAction(
                    label = stringResource(R.string.background_task_open_optimization_list),
                    onClick = { BackgroundExecutionSettings.openOptimizationList(context) })
            }
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
