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
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent { FloeApp() }
    }
}
