// SPDX-License-Identifier: MPL-2.0
package com.floe.android.mediaintegration

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
 * System CREATE_DOCUMENT launcher for the verified G09-R2 export receipt.
 *
 * The save operation itself is Application/process owned: this effect only
 * presents the exact pending pick and forwards the REAL result URI/flags.
 * Rotation recreates the effect but does not cancel the operation (the same
 * `rememberSaveable` launch identity is restored and the pending incarnation
 * is held until its callback). Unmounting for an actual navigation cancels
 * only the still-awaiting pick; an in-flight provider write is owned by the
 * Application delivery controller, which reports its real terminal outcome.
 */
@Composable
internal fun MediaWorkbenchExportPickerEffect(
    delivery: MediaWorkbenchExportDelivery?,
) {
    if (delivery == null) return
    val pending by delivery.pendingPick.collectAsState()
    val context = LocalContext.current
    val activity = context as? Activity
    var issuedKey by rememberSaveable(delivery) { mutableStateOf<String?>(null) }
    val ledger = remember(delivery) {
        PlatformLaunchOwnership.LaneLedger(delivery.launchNamespace).also { lane ->
            // A callback can be delivered immediately after Activity
            // recreation, before the LaunchedEffect below runs. Adopt the
            // persisted identity synchronously so that result is dispatched
            // to its exact pending incarnation (or dropped by full identity).
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
            // Rotation tears down the composition but must preserve the
            // process-owned save/pick. Only an actual leaving surface cancels.
            if (activity?.isChangingConfigurations != true) {
                delivery.cancelPendingForUnmountedSurface("exportSurfaceClosed")
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
                            // The platform refused to show the picker: settle
                            // THIS exact request as a user cancel; nothing was
                            // written and no byte claim is made.
                            delivery.completePick(decision.savedKey.incarnation, null, 0)
                            issuedKey = null
                        }
                }
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }
}
