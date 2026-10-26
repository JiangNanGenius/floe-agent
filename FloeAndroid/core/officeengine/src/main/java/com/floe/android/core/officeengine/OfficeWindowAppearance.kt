// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import androidx.activity.ComponentActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.core.view.WindowCompat
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.floeIsDarkAppearance

/** Same window-local appearance convention as the Main shell. */
@Composable
internal fun OfficeWindowAppearance(activity: ComponentActivity, mode: FloeThemeMode) {
    val dark = floeIsDarkAppearance(mode)
    LaunchedEffect(activity, dark) {
        val controller = WindowCompat.getInsetsController(activity.window, activity.window.decorView)
        controller.isAppearanceLightStatusBars = !dark
        controller.isAppearanceLightNavigationBars = !dark
    }
}
