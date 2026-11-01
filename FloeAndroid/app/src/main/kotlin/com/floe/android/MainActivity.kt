// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.floe.android.host.creative.GenerationReturnNavigation

class MainActivity : ComponentActivity() {
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
