// SPDX-License-Identifier: MPL-2.0
//
// App-level binding between the C06 system-services controller and the
// presentation module. Permission launchers, the ActivityResult routing and
// the foreground lifecycle stay here; the controller owns every platform
// effect and the Swift mailbox.

package com.floe.android.host.systemservices

import android.Manifest
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.health.connect.client.PermissionController
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeUnavailableView
import com.floe.android.feature.systemservices.CapabilityKind
import com.floe.android.feature.systemservices.R
import com.floe.android.feature.systemservices.SystemServicesDestinationUi
import com.floe.android.host.RuntimeHost

@Composable
internal fun C06SystemServicesDestination(
    host: RuntimeHost?,
    compact: Boolean,
    showSidebarToggle: Boolean,
    onExpandSidebar: () -> Unit,
    onOpenDrawer: () -> Unit,
    sheetNavigation: (@Composable () -> Unit)? = null,
) {
    val controller = host?.c06SystemServices
    if (controller == null) {
        FloeUnavailableView(
            icon = FloeIcons.Gearshape,
            title = stringResource(R.string.system_services_title),
            description = stringResource(R.string.system_services_unavailable),
            modifier = Modifier.fillMaxSize(),
        )
        return
    }
    val state by controller.state.collectAsState()
    val permissionRequest by controller.permissionRequests.collectAsState()
    val context = LocalContext.current
    val activity = context as? ComponentActivity

    val locationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { result ->
        val granted = result[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            result[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        controller.onPermissionResult(SystemPermissionKind.LOCATION, granted)
    }
    val contactsLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        controller.onPermissionResult(SystemPermissionKind.CONTACTS, granted)
    }
    val healthLauncher = rememberLauncherForActivityResult(
        PermissionController.createRequestPermissionResultContract(),
    ) { granted ->
        controller.onHealthPermissionResult(granted)
    }

    LaunchedEffect(controller) { controller.enter() }
    DisposableEffect(activity, controller) {
        controller.setCurrentActivity(activity)
        if (activity == null) return@DisposableEffect onDispose { }
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> controller.onAppForeground()
                Lifecycle.Event.ON_STOP -> controller.onAppBackground()
                else -> Unit
            }
        }
        activity.lifecycle.addObserver(observer)
        onDispose {
            activity.lifecycle.removeObserver(observer)
            controller.setCurrentActivity(null)
        }
    }
    LaunchedEffect(permissionRequest?.requestID) {
        val request = permissionRequest ?: return@LaunchedEffect
        runCatching {
            when (request.kind) {
                SystemPermissionKind.LOCATION -> locationLauncher.launch(
                    arrayOf(
                        Manifest.permission.ACCESS_FINE_LOCATION,
                        Manifest.permission.ACCESS_COARSE_LOCATION,
                    ),
                )
                SystemPermissionKind.CONTACTS -> contactsLauncher.launch(
                    Manifest.permission.READ_CONTACTS,
                )
                SystemPermissionKind.HEALTH -> healthLauncher.launch(
                    controller.healthReadPermissions,
                )
            }
            controller.markPermissionLaunched(request.requestID)
        }.onFailure {
            controller.cancelPermissionRequest()
        }
    }

    SystemServicesDestinationUi(
        sheetNavigation = sheetNavigation,
        state = state,
        compact = compact,
        showSidebarToggle = showSidebarToggle,
        onExpandSidebar = onExpandSidebar,
        onOpenDrawer = onOpenDrawer,
        onRefresh = { controller.refresh() },
        onRequestPermission = { kind ->
            when (kind) {
                CapabilityKind.LOCATION -> controller.requestPermission(SystemPermissionKind.LOCATION)
                CapabilityKind.CONTACTS -> controller.requestPermission(SystemPermissionKind.CONTACTS)
                CapabilityKind.HEALTH -> controller.grantHealth()
                CapabilityKind.NFC -> Unit
            }
        },
        onGrantHealth = { controller.grantHealth() },
        onOpenSettings = { controller.openSettings(it) },
        onInstallHealth = { controller.installHealth() },
        onUpdateHealth = { controller.updateHealth() },
        onDismissNotice = { controller.dismissNotice() },
    )
}
