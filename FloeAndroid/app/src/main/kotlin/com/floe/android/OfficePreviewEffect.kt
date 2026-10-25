// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.floe.android.design.*
import com.floe.android.host.OfficePreviewController
import com.floe.android.host.PlatformLaunchOwnership

/** Mounted once by the shell, including before a model/runtime is ready.
 * Both platform lanes reuse existing namespace+incarnation launch ownership.
 * Saved state contains only opaque keys, never URIs or document content.
 */
@Composable
internal fun OfficePreviewEffect(controller: OfficePreviewController, themeMode: FloeThemeMode) {
    val currentTheme by rememberUpdatedState(themeMode)
    val state by controller.state.collectAsState()
    val pickerLedger = remember(controller) { PlatformLaunchOwnership.LaneLedger(controller.pickerNamespace) }
    val viewerLedger = remember(controller) { PlatformLaunchOwnership.LaneLedger(controller.viewerNamespace) }
    var issuedPicker by rememberSaveable { mutableStateOf<String?>(null) }
    var issuedViewer by rememberSaveable { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        when (val decision = pickerLedger.onCallback(controller.state.value.picker)) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch -> controller.onPickerResult(
                decision.incarnation,
                if (result.resultCode == Activity.RESULT_OK) result.data?.dataString else null,
                if (result.resultCode == Activity.RESULT_OK) result.data?.flags ?: 0 else 0,
            )
            PlatformLaunchOwnership.CallbackDecision.Drop -> Unit
        }
        issuedPicker = null
    }
    val viewer = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        when (val decision = viewerLedger.onCallback(controller.state.value.viewer?.incarnation)) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch -> controller.onViewerResult(decision.incarnation, result.data)
            PlatformLaunchOwnership.CallbackDecision.Drop -> Unit
        }
        issuedViewer = null
    }

    LaunchedEffect(controller, state.picker, issuedPicker) {
        pickerLedger.restore(PlatformLaunchOwnership.LaunchKey.decode(issuedPicker))
        when (val decision = pickerLedger.onPending(controller.state.value.picker)) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedPicker = decision.savedKey.encode()
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, OfficePreviewController.MIME_TYPES)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                runCatching { picker.launch(intent) }.onFailure {
                    pickerLedger.release(); issuedPicker = null
                    controller.cancelUnopened()
                }
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }
    LaunchedEffect(controller, state.viewer?.incarnation, issuedViewer) {
        viewerLedger.restore(PlatformLaunchOwnership.LaunchKey.decode(issuedViewer))
        when (val decision = viewerLedger.onPending(controller.state.value.viewer?.incarnation)) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                val intent = controller.claimViewer(decision.savedKey.incarnation)?.apply {
                    putExtra("com.floe.office.THEME_MODE", currentTheme.name)
                }
                if (intent == null) { viewerLedger.release(); issuedViewer = null }
                else {
                    issuedViewer = decision.savedKey.encode()
                    runCatching { viewer.launch(intent) }.onFailure {
                        viewerLedger.release(); issuedViewer = null
                        controller.launchFailed(decision.savedKey.incarnation)
                    }
                }
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }

    FloeActionSheet(visible = state.staging || state.error != null,
        onDismiss = { if (state.staging) controller.cancelUnopened() else controller.clearError() },
        maxCardWidth = 420.dp) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            FloeText(stringResource(R.string.office_open_document), style = Floe.typography.toolbarTitle)
            if (state.staging) {
                FloeActivityIndicator()
                FloeText(stringResource(if (state.cancelling) R.string.office_open_cancelling else R.string.office_open_preparing),
                    color = Floe.colors.secondaryLabel)
                FloeCapsuleButton(stringResource(R.string.office_open_cancel),
                    onClick = controller::cancelUnopened, enabled = !state.cancelling)
            } else {
                FloeText(stringResource(when (state.error) {
                    "busy" -> R.string.office_open_busy
                    "format" -> R.string.office_open_unsupported
                    "tooLarge" -> R.string.office_open_too_large
                    else -> R.string.office_open_failed
                }), color = Floe.colors.secondaryLabel)
                FloeCapsuleButton(stringResource(R.string.office_open_done), onClick = controller::clearError)
            }
        }
    }
}
