// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.Manifest
import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.floe.android.host.capture.PacketCaptureNavigation
import com.floe.android.host.creative.GenerationReturnNavigation
import com.floe.android.host.entryflow.C07EntryFlowHost
import com.floe.android.host.gallery.GalleryPermissionRequester
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    /**
     * C03 uses the system recognizer only after an explicit user tap. The
     * host emits one request per attempt; this launcher is the only Android
     * permission UI and the result is returned to the same host generation.
     */
    private val voicePermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        (application as FloeApplication).runtimeHost?.onVoicePermissionResult(granted)
    }

    /**
     * API 28 gallery save only. The request originates from the explicit
     * "Save to Gallery" user action; API 29+ own-media inserts never request a
     * broad storage/read permission.
     */
    private val galleryPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        GalleryPermissionRequester.complete(granted)
    }
    override fun onResume() {
        super.onResume()
        (application as FloeApplication).linuxSetup.onResume()
        (application as FloeApplication).reconcileForegroundOnResume()
        // Cooldown-gated automatic update check + install/permission resume.
        com.floe.android.host.update.AppUpdateFeature.onApplicationForeground()
        (application as FloeApplication).setActivityForeground(true)
        // FULL: reconcile real Accessibility/ADB/Root status after the user
        // returns from a system settings/pairing screen; PLAY is inert.
        (application as FloeApplication).onPlatformActivityResumed(this)
        (application as FloeApplication).runtimeHost?.externalEdits?.onForeground()
        (application as FloeApplication).officeComponent.onForeground(this)
    }
    override fun onPause() {
        (application as FloeApplication).onPlatformActivityPaused()
        (application as FloeApplication).setActivityForeground(false)
        super.onPause()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // C07 external entry: SEND/SEND_MULTIPLE, content VIEW, floe:// links
        // and question/schedule notification taps. Admission is data-only and
        // idempotent across rotation/recreation; the App-owned host applies the
        // real policy and asks for a destination before any copy.
        C07EntryFlowHost.admit(this, intent)
        // Cold-Activity launch: the explicit generation notification PendingIntent
        // delivers its opaque return token here. The shell resolves it later
        // against the LIVE registered foreground claim + captured project
        // context + current native bound epoch. A rotation re-delivery of the
        // SAME request id is ignored by the one-shot owner.
        admitGenerationReturn(intent)
        admitOwnedNotification(intent)
        PacketCaptureNavigation.submitFromIntent(intent, packageName)
        admitCalendarRoute(intent)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                (application as FloeApplication).runtimeHost
                    ?.voicePermissionRequests()
                    ?.collect {
                        voicePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    }
            }
        }
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                GalleryPermissionRequester.requests.collect {
                    if (Build.VERSION.SDK_INT <= 28) {
                        galleryPermissionLauncher.launch(
                            Manifest.permission.WRITE_EXTERNAL_STORAGE,
                        )
                    } else {
                        GalleryPermissionRequester.complete(false)
                    }
                }
            }
        }
        enableEdgeToEdge()
        setContent { FloeApp() }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm launch: keep the newest Intent so an Activity recreation does
        // not replay an older route; the one-shot owner still dedupes by id.
        setIntent(intent)
        C07EntryFlowHost.admit(this, intent)
        admitGenerationReturn(intent)
        admitOwnedNotification(intent)
        PacketCaptureNavigation.submitFromIntent(intent, packageName)
        admitCalendarRoute(intent)
    }

    /**
     * The Intent is never authorization: the action and explicit same-app
     * component are checked, and only opaque UUID extras are forwarded. No
     * project id, path or root is read from it.
     */
    private fun admitOwnedNotification(intent: Intent?) {
        val incoming = intent ?: return
        com.floe.android.host.notification.OwnedNotificationNavigation.admit(
            incoming.action, incoming.component?.packageName, packageName,
            incoming.getStringExtra(com.floe.android.runlifecycle.RunNotificationReturn.EXTRA_REQUEST_ID),
        )
    }

    private fun admitGenerationReturn(intent: Intent?) {
        val incoming = intent ?: return
        GenerationReturnNavigation.submitFromIntent(
            action = incoming.action,
            componentPackage = incoming.component?.packageName,
            ownPackage = packageName,
            requestID = incoming.getStringExtra(
                GenerationReturnNavigation.EXTRA_RETURN_REQUEST_ID),
            token = incoming.getStringExtra(
                GenerationReturnNavigation.EXTRA_RETURN_TOKEN),
        )
        GenerationReturnNavigation.submitExportFromIntent(
            incoming.action, incoming.component?.packageName, packageName,
            incoming.getStringExtra(com.floe.android.core.workbenchmedia.export.MediaExportReturns.EXTRA_REQUEST_ID),
            incoming.getStringExtra(com.floe.android.core.workbenchmedia.export.MediaExportReturns.EXTRA_TOKEN),
        )
    }

    /**
     * C06 local reminder route. Only the explicit same-app action and opaque
     * todo id/revision are forwarded; the destination re-reads the live todo.
     */
    private fun admitCalendarRoute(intent: Intent?) {
        val incoming = intent ?: return
        com.floe.android.host.calendar.C06CalendarNavigation.submitFromIntent(
            action = incoming.action,
            componentPackage = incoming.component?.packageName,
            ownPackage = packageName,
            todoID = incoming.getStringExtra(
                com.floe.android.host.calendar.C06CalendarNavigation.EXTRA_TODO_ID),
            revision = incoming.getIntExtra(
                com.floe.android.host.calendar.C06CalendarNavigation.EXTRA_TODO_REVISION,
                0,
            ),
        )
    }
}
