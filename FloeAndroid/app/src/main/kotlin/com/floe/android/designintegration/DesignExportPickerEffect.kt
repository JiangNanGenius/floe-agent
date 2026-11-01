// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.safgateway.SafPickerIntents

/**
 * System CREATE_DOCUMENT launcher for a verified design export receipt.
 *
 * The save itself is process-owned by [DesignExportDelivery]; this effect only
 * presents the exact pending pick and forwards the REAL returned URI/flags.
 * Rotation restores the same launch identity and does not cancel the
 * operation; an actual surface close cancels only the still-pending pick.
 */
@Composable
internal fun DesignExportPickerEffect(delivery: DesignExportDelivery?) {
    if (delivery == null) return
    val pending by delivery.pendingPick.collectAsState()
    val context = LocalContext.current
    val activity = context as? Activity
    var issuedKey by rememberSaveable(delivery) { mutableStateOf<String?>(null) }
    val ledger = remember(delivery) {
        PlatformLaunchOwnership.LaneLedger(delivery.launchNamespace).also { lane ->
            lane.restore(PlatformLaunchOwnership.LaunchKey.decode(issuedKey))
        }
    }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val decision = ledger.onCallback(delivery.pendingPick.value?.incarnation)
        issuedKey = null
        when (decision) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch -> {
                val ok = result.resultCode == Activity.RESULT_OK
                delivery.completePick(
                    incarnation = decision.incarnation,
                    uriString = if (ok) SafPickerIntents.resultUriString(result.data) else null,
                    flags = if (ok) SafPickerIntents.resultFlags(result.data) else 0,
                )
            }
            PlatformLaunchOwnership.CallbackDecision.Drop -> Unit
        }
    }
    DisposableEffect(delivery, activity) {
        onDispose {
            if (activity?.isChangingConfigurations != true) {
                delivery.cancelPendingForUnmountedSurface("designExportSurfaceClosed")
                ledger.release()
            }
        }
    }
    LaunchedEffect(pending?.incarnation, issuedKey, delivery) {
        ledger.restore(PlatformLaunchOwnership.LaunchKey.decode(issuedKey))
        when (val decision = ledger.onPending(pending?.incarnation)) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedKey = decision.savedKey.encode()
                val spec = pending?.spec
                if (spec == null) {
                    delivery.completePick(decision.savedKey.incarnation, null, 0)
                    issuedKey = null
                } else {
                    runCatching { launcher.launch(SafPickerIntents.from(spec)) }
                        .onFailure {
                            delivery.completePick(decision.savedKey.incarnation, null, 0)
                            issuedKey = null
                        }
                }
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }
}
