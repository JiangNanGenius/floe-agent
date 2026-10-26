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
 * The picker lane reuses the shared platform launch ledger unchanged.
 * The viewer lane registers ONE platform ActivityResult launcher per
 * immutable (namespace, incarnation) launch identity inside a keyed child
 * composition: a platform callback carries no request identity of its own,
 * so it may dispatch ONLY the identity its registration was issued for —
 * never the controller's CURRENT pending. The late-result rebinding that
 * would let a retired old launch settle the next document is thus
 * structurally impossible. The held identity releases the lane when its own
 * callback arrives, or when the controller has already retired that
 * operation without a callback (the fatal native close exit can bypass the
 * result entirely) — the next open then registers under a DISTINCT launcher
 * key. Saved state contains only opaque keys, never URIs or content.
 */
@Composable
internal fun OfficePreviewEffect(controller: OfficePreviewController, themeMode: FloeThemeMode) {
    val state by controller.state.collectAsState()
    val pickerLedger = remember(controller) { PlatformLaunchOwnership.LaneLedger(controller.pickerNamespace) }
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

    val viewerPending = state.viewer?.incarnation
    val viewerSlot = viewerSlotIdentity(controller.viewerNamespace, issuedViewer, viewerPending)
    if (viewerSlot != null) {
        key(controller.viewerNamespace, viewerSlot) {
            OfficeViewerLaunchSlot(
                controller = controller,
                themeMode = themeMode,
                incarnation = viewerSlot,
                pendingIncarnation = viewerPending,
                issuedKey = issuedViewer,
                onIssuedKey = { issuedViewer = it },
                onReleaseKey = { expected -> issuedViewer = viewerKeyAfterRelease(issuedViewer, expected) },
            )
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

/** Pure decisions for ONE viewer launch slot, expressed over the encoded
 * PlatformLaunchOwnership key so the JVM regression drives the SAME rules
 * the composition uses. [namespace] is the CURRENT controller viewer lane's
 * namespace; [issuedKey] the single held viewer identity (at most one);
 * [pendingIncarnation] the controller's current pending viewer;
 * [slotIncarnation] this slot's immutable launch identity. */
internal sealed interface ViewerSlotAction {
    /** Lane free and this slot IS the controller's current pending viewer:
     * claim and launch exactly once. */
    data object Launch : ViewerSlotAction

    /** This slot's own exact launch is in flight for the current pending
     * viewer: never relaunch the same pending. */
    data object Hold : ViewerSlotAction

    /** Release the held key only: the key is malformed, belongs to a dead
     * process generation (restored pre-death namespace), or names an
     * operation the controller has already retired (its callback can never
     * arrive — the fatal native close exit bypasses the result). Releasing
     * is the ONLY thing allowed for another identity; never dispatch and
     * never launch under a foreign/retired key. */
    data object Release : ViewerSlotAction

    /** Nothing to do (lane free, pending elsewhere; slot is leaving). */
    data object Idle : ViewerSlotAction
}

/** Which viewer identity gets a launch slot: a held same-namespace launch
 * must own the slot until it settles, otherwise the controller's current
 * pending viewer. A restored pre-death key is not mounted — the new
 * generation's pending launches fresh and the stale key releases there. */
internal fun viewerSlotIdentity(
    namespace: String,
    issuedKey: String?,
    pendingIncarnation: Long?,
): Long? {
    val issued = PlatformLaunchOwnership.LaunchKey.decode(issuedKey)
    if (issued != null && issued.namespace == namespace) return issued.incarnation
    return pendingIncarnation
}

internal fun viewerSlotAction(
    namespace: String,
    issuedKey: String?,
    pendingIncarnation: Long?,
    slotIncarnation: Long,
): ViewerSlotAction {
    val issued = PlatformLaunchOwnership.LaunchKey.decode(issuedKey)
    if (issuedKey != null) {
        if (issued == null || issued.namespace != namespace ||
            issued.incarnation != slotIncarnation || pendingIncarnation != slotIncarnation
        ) {
            return ViewerSlotAction.Release
        }
        return ViewerSlotAction.Hold
    }
    if (pendingIncarnation == slotIncarnation) return ViewerSlotAction.Launch
    return ViewerSlotAction.Idle
}

/** A platform delivery at THIS slot's registration may dispatch only when
 * the lane still holds this slot's own exact namespace+incarnation key.
 * String equality over the encoded key carries BOTH checks: namespace
 * (a restored pre-death result never dispatches into a new generation's
 * operation, defeating the counter-reset collision) and incarnation (a
 * retired old launch's late null result never settles the next document).
 * Anything else settles the lane with NO controller call. */
internal fun viewerCallbackOwnsLaunch(
    namespace: String,
    issuedKey: String?,
    slotIncarnation: Long,
): Boolean = issuedKey != null &&
    issuedKey == PlatformLaunchOwnership.LaunchKey(namespace, slotIncarnation).encode()

/** A retired registration may clear only its own held key. */
internal fun viewerKeyAfterRelease(heldKey: String?, expectedKey: String): String? =
    if (heldKey == expectedKey) null else heldKey

/** One immutable viewer launch (namespace + incarnation): its own
 * rememberLauncherForActivityResult registration, its own dispatch binding.
 * Unmounting (identity retired and lane released) unregisters this launcher;
 * the next operation mounts a DISTINCT slot, so a callback that physically
 * lands here can only ever name this slot's incarnation — and the
 * controller's exact-operation fence still re-checks everything. */
@Composable
private fun OfficeViewerLaunchSlot(
    controller: OfficePreviewController,
    themeMode: FloeThemeMode,
    incarnation: Long,
    pendingIncarnation: Long?,
    issuedKey: String?,
    onIssuedKey: (String?) -> Unit,
    onReleaseKey: (String) -> Unit,
) {
    val namespace = controller.viewerNamespace
    val currentTheme by rememberUpdatedState(themeMode)
    val currentIssued by rememberUpdatedState(issuedKey)
    val currentOnIssued by rememberUpdatedState(onIssuedKey)
    val currentOnRelease by rememberUpdatedState(onReleaseKey)
    val slotKey = PlatformLaunchOwnership.LaunchKey(namespace, incarnation).encode()
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        // The callback carries no request identity: bind ONLY to this slot's
        // captured incarnation when the lane still holds this slot's exact
        // key; otherwise settle the lane without dispatching (a retired
        // operation's late result must NEVER be handed to the current
        // pending viewer).
        val dispatch = viewerCallbackOwnsLaunch(namespace, currentIssued, incarnation)
        currentOnRelease(slotKey)
        if (dispatch) controller.onViewerResult(incarnation, result.data)
    }
    LaunchedEffect(controller, incarnation, issuedKey, pendingIncarnation) {
        when (viewerSlotAction(namespace, issuedKey, pendingIncarnation, incarnation)) {
            ViewerSlotAction.Launch -> {
                val intent = controller.claimViewer(incarnation)?.apply {
                    putExtra("com.floe.office.THEME_MODE", currentTheme.name)
                }
                if (intent != null) {
                    currentOnIssued(slotKey)
                    runCatching { launcher.launch(intent) }.onFailure {
                        currentOnRelease(slotKey)
                        controller.launchFailed(incarnation)
                    }
                }
            }
            ViewerSlotAction.Release -> issuedKey?.let { currentOnRelease(it) }
            ViewerSlotAction.Hold, ViewerSlotAction.Idle -> Unit
        }
    }
}
