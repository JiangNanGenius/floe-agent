// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.floe.android.design.*
import com.floe.android.feature.network.*
import com.floe.android.host.RuntimeHost

/** Permission callbacks grant access only; they never replay a diagnostic. */
@Composable
internal fun NetworkWorkbenchDestination(
    host: RuntimeHost?, compact: Boolean, showSidebarToggle: Boolean, onNavigate: () -> Unit,
) {
    if (host == null) {
        FloeUnavailableView(FloeIcons.Antenna, stringResource(R.string.network_workbench), stringResource(R.string.projects_runtime_pending))
        return
    }
    val controller = host.networkWorkbench
    val state by controller.state.collectAsState()
    val context = LocalContext.current
    val asked = remember { mutableSetOf<String>() }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
        // No run is captured by a permission prompt. The user starts a fresh
        // measurement after returning, including after rotation/process death.
    }
    LaunchedEffect(controller) { controller.enter() }
    NetworkWorkbench(
        state = state, compact = compact,
        onExecute = controller::execute, onStop = controller::stop,
        onPermission = { missing ->
            val lan = "android.permission.ACCESS_LOCAL_NETWORK"
            if (Build.VERSION.SDK_INT >= 37 && lan in missing) {
                host.integrations.localNetwork.runExplicitAction(
                    ownerID = controller.ownerID, endpoint = "https://localhost",
                    isCurrent = controller::isActive, onDenied = { _ -> }, dispatch = {},
                )
            } else {
                val runtime = missing.filter { permission ->
                    permission in setOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION,
                        "android.permission.NEARBY_WIFI_DEVICES") &&
                        context.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED &&
                        (permission != "android.permission.NEARBY_WIFI_DEVICES" || Build.VERSION.SDK_INT >= 33)
                }.toSet().toMutableSet()
                // Modern Android requests precise and approximate together.
                if (Manifest.permission.ACCESS_FINE_LOCATION in runtime) runtime += Manifest.permission.ACCESS_COARSE_LOCATION
                val activity = context as? Activity
                val needsSettings = runtime.any { it in asked && activity?.shouldShowRequestPermissionRationale(it) == false }
                if (needsSettings) context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                else if (runtime.isNotEmpty()) { asked += runtime; launcher.launch(runtime.toTypedArray()) }
            }
        },
        onOpenLocationSettings = { context.startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)) },
        onNavigate = onNavigate, showSidebarToggle = showSidebarToggle,
        monitoringLabel = stringResource(R.string.network_monitor),
        monitoringContent = { panelModifier -> NetworkMonitoringDestination(host, panelModifier) },
        modifier = Modifier.fillMaxSize(),
    )
}
