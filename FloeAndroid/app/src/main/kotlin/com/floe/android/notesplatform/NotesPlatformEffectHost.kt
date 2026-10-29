// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.floe.android.feature.notes.ui.api.NotesPortFailure

/**
 * Mounted ONCE by the App shell next to the existing Office effect host.
 *
 * It registers the two real platform launchers the Notes host needs — SAF
 * open-document and the existing Office viewer Activity — and routes their
 * callbacks by an opaque token held across configuration changes. The host
 * itself is App-owned and must outlive composition; this composable only binds
 * the current Activity and launchers to it. A late callback from a destroyed
 * process generation has no matching pending token and is dropped.
 *
 * Main integration: place this inside the same top-level composition that
 * mounts `OfficePreviewEffect`, before/around the Notes route. It renders no
 * UI (a zero-size Box) and performs no I/O at composition time.
 */
@Composable
fun NotesPlatformEffectHost(
    host: NotesPlatformHost,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val activity = LocalActivity.current ?: context.findActivity()
    DisposableEffect(host, activity) {
        if (activity != null) host.activityBroker.attach(activity)
        onDispose {
            if (activity != null) host.activityBroker.detach(activity)
        }
    }
    val pending by host.activityBroker.pendingLaunches.collectAsState()
    NotesLauncherSlot(
        host = host,
        lane = NotesLaunchLane.OPEN_DOCUMENT,
        stateKey = "notesplatform.launch.open",
        pending = pending[NotesLaunchLane.OPEN_DOCUMENT],
    )
    NotesLauncherSlot(
        host = host,
        lane = NotesLaunchLane.OFFICE_VIEWER,
        stateKey = "notesplatform.launch.office",
        pending = pending[NotesLaunchLane.OFFICE_VIEWER],
    )
    Box(modifier)
}

@Composable
private fun NotesLauncherSlot(
    host: NotesPlatformHost,
    lane: NotesLaunchLane,
    stateKey: String,
    pending: NotesPendingLaunch?,
) {
    var issued by rememberSaveable(stateKey) { mutableStateOf<String?>(null) }
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        val token = issued
        issued = null
        // The broker re-checks the lane+token; a callback for a retired or
        // replaced request is dropped without touching the new one.
        if (token != null) {
            host.activityBroker.deliver(lane, token, result.resultCode, result.data)
        }
    }
    LaunchedEffect(pending?.token, issued) {
        val request = pending
        if (request == null) {
            // Caller cancellation/teardown: clear the held token so a late
            // platform result can never be attributed to a future request.
            issued = null
            return@LaunchedEffect
        }
        if (issued == request.token) return@LaunchedEffect
        if (host.activityBroker.currentActivity() == null) {
            issued = null
            host.activityBroker.fail(
                lane,
                request.token,
                NotesPortFailure(NotesPortFailure.UNAVAILABLE, "noForegroundActivity"),
            )
            return@LaunchedEffect
        }
        issued = request.token
        try {
            launcher.launch(request.intent)
        } catch (_: Throwable) {
            issued = null
            host.activityBroker.fail(
                lane,
                request.token,
                NotesPortFailure(NotesPortFailure.UNAVAILABLE, "launcherRefused"),
            )
        }
    }
}

private fun Context.findActivity(): Activity? {
    var current: Context? = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return current as? Activity
}
