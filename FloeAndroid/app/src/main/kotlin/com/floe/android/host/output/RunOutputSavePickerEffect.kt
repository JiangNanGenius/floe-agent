// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.output

import android.app.Activity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.floe.android.host.PlatformLaunchOwnership
import com.floe.android.safgateway.SafPickerIntents

/**
 * System CREATE_DOCUMENT launcher for the owned run-output Save Copy lane.
 * The service requests a pick; this launcher presents the platform picker
 * and hands the ACTUAL result (URI + real returned intent flags, verbatim)
 * back to the host-owned verified write pipeline.
 *
 * Ownership follows the reviewed attachment/skills picker discipline
 * (PlatformLaunchOwnership): the launcher callback persists the exact
 * `namespace:incarnation` launch identity it issued and dispatches ONLY to
 * the still-current pending request with that full identity. A late
 * callback for a superseded request, or a result restored after process
 * death, is DROPPED — never re-read blindly, never broad-cancelled onto the
 * current request. A null data result settles only the exact issued
 * request's own cancel through [RunOutputHostService.deliverPickResult].
 *
 * Mount this where the Save Copy lane lives (shell root, next to the
 * attachment/skills pickers). Unmounting while a pick is still outstanding
 * cancels THAT exact request (the egress lease is released and the card
 * returns to its verified availability; nothing is deleted and no progress
 * is claimed).
 */
@Composable
internal fun RunOutputSavePickerEffect(service: RunOutputHostService?) {
    val picker by (service?.pickerRequest
        ?: kotlinx.coroutines.flow.MutableStateFlow<RunOutputPendingPick?>(null))
        .collectAsState()
    val namespace = service?.launchNamespace ?: return
    val context = LocalContext.current
    var issuedKey by rememberSaveable(service) { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val saved = PlatformLaunchOwnership.LaunchKey.decode(issuedKey)
        issuedKey = null
        when (val decision = PlatformLaunchOwnership.evaluateCallback(
            saved,
            service?.pickerRequest?.value?.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.CallbackDecision.Dispatch ->
                service?.pickerRequest?.value
                    ?.takeIf { it.incarnation == decision.incarnation }
                    ?.let { issued ->
                        val data = result.data
                        val ok = result.resultCode == Activity.RESULT_OK
                        service.deliverPickResult(
                            issued.incarnation,
                            if (ok) SafPickerIntents.resultUriString(data) else null,
                            if (ok) SafPickerIntents.resultFlags(data) else 0,
                        )
                    }
            PlatformLaunchOwnership.CallbackDecision.Drop -> Unit
        }
    }
    DisposableEffect(service, namespace) {
        onDispose {
            // Composition unmount is an explicit cancel only for the exact
            // request THIS surface still owns (never a blanket cancel of a
            // newer operation on another screen).
            val pending = service?.pickerRequest?.value
            if (pending != null) {
                service.cancelActiveSave("save-surface-closed", pending.identity.runID,
                    pending.identity.outputID)
            }
        }
    }
    LaunchedEffect(picker, issuedKey, service) {
        val request = picker ?: return@LaunchedEffect
        val owner = service ?: return@LaunchedEffect
        when (val decision = PlatformLaunchOwnership.evaluatePending(
            PlatformLaunchOwnership.LaunchKey.decode(issuedKey),
            request.incarnation,
            namespace,
        )) {
            is PlatformLaunchOwnership.PendingDecision.Launch -> {
                issuedKey = decision.savedKey.encode()
                val intent = SafPickerIntents.from(request.spec)
                runCatching { launcher.launch(intent) }
                    .onFailure {
                        // The platform refused to present the picker: settle
                        // THIS exact request as cancelled — the card shows
                        // the honest failed/cancelled state, never progress.
                        owner.deliverPickResult(request.incarnation, null, 0)
                    }
            }
            PlatformLaunchOwnership.PendingDecision.Hold -> Unit
        }
    }
}
