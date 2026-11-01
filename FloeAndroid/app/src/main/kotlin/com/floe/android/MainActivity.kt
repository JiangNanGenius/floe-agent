// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import com.floe.android.host.creative.GenerationReturnNavigation
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
    }
    override fun onPause() {
        (application as FloeApplication).onPlatformActivityPaused()
        (application as FloeApplication).setActivityForeground(false)
        super.onPause()
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cold-Activity launch: the explicit generation notification PendingIntent
        // delivers its opaque return token here. The shell resolves it later
        // against the LIVE registered foreground claim + captured project
        // context + current native bound epoch. A rotation re-delivery of the
        // SAME request id is ignored by the one-shot owner.
        admitGenerationReturn(intent)
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                (application as FloeApplication).runtimeHost
                    ?.voicePermissionRequests()
                    ?.collect {
                        voicePermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
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
        admitGenerationReturn(intent)
    }

    /**
     * The Intent is never authorization: the action and explicit same-app
     * component are checked, and only opaque UUID extras are forwarded. No
     * project id, path or root is read from it.
     */
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
    }
}
