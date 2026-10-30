// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
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

/** One shared permission explanation for a real tool refusal. Never auto-replays a probe. */
@Composable
internal fun NetworkDiagnosticPermissionEffect(host: RuntimeHost) {
    val notice by host.networkPermissionNotice.collectAsState()
    val context = LocalContext.current
    val asked = remember { mutableSetOf<String>() }
    var issued by remember { mutableStateOf<RuntimeHost.NetworkPermissionNotice?>(null) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        val captured = issued
        issued = null
        if (captured != null && host.currentNetworkPermissionNotice(captured)) host.networkPermissionNotice.value = null
    }
    val captured = notice ?: return
    if (!host.currentNetworkPermissionNotice(captured)) return
    val wide = LocalConfiguration.current.screenWidthDp >= 700
    FloePageSheet(
        visible = true, onDismiss = { if (host.currentNetworkPermissionNotice(captured)) host.networkPermissionNotice.value = null },
        widthFraction = if (wide) 0.55f else 1f, heightFraction = if (wide) 0.48f else 0.5f,
        placement = if (wide) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM,
    ) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            FloeText(stringResource(R.string.network_permission_notice_title), style = Floe.typography.title)
            FloeText(stringResource(R.string.network_permission_notice_body), style = Floe.typography.body, color = Floe.colors.secondaryLabel)
            FloeCapsuleButton(stringResource(R.string.network_permission_allow), onClick = {
                if (host.currentNetworkPermissionNotice(captured)) {
                    val missing = captured.request.missingPermissions
                    val lan = "android.permission.ACCESS_LOCAL_NETWORK"
                    if (Build.VERSION.SDK_INT >= 37 && lan in missing) {
                        host.integrations.localNetwork.runExplicitAction(
                            ownerID = "network-permission:${captured.request.operationID}", endpoint = "https://localhost",
                            isCurrent = { host.currentNetworkPermissionNotice(captured) },
                            onDenied = { _ -> if (host.currentNetworkPermissionNotice(captured)) host.networkPermissionNotice.value = null },
                            dispatch = { if (host.currentNetworkPermissionNotice(captured)) host.networkPermissionNotice.value = null },
                        )
                    } else {
                        val permissions = missing.filter { permission ->
                            permission in setOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION,
                                "android.permission.NEARBY_WIFI_DEVICES") &&
                                (permission != "android.permission.NEARBY_WIFI_DEVICES" || Build.VERSION.SDK_INT >= 33) &&
                                context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED
                        }.toMutableSet()
                        if (Manifest.permission.ACCESS_FINE_LOCATION in permissions) permissions += Manifest.permission.ACCESS_COARSE_LOCATION
                        val activity = context as? Activity
                        if (permissions.any { it in asked && activity?.shouldShowRequestPermissionRationale(it) == false }) {
                            host.networkPermissionNotice.value = null
                            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                        } else if (permissions.isNotEmpty()) {
                            issued = captured; asked += permissions; launcher.launch(permissions.toTypedArray())
                        } else {
                            host.networkPermissionNotice.value = null
                            context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        }
                    }
                }
            }, prominent = true)
            FloeCapsuleButton(stringResource(R.string.network_permission_later), onClick = {
                if (host.currentNetworkPermissionNotice(captured)) host.networkPermissionNotice.value = null
            })
        }
    }
}
