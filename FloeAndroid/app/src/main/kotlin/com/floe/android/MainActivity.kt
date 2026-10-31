// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge

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
        enableEdgeToEdge()
        setContent { FloeApp() }
    }
}
