// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.view.Window
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.core.view.WindowCompat
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.Floe
import com.floe.android.design.floeIsDarkAppearance

/**
 * Bridges the in-app Day/Night/Auto appearance (Settings → General,
 * persisted [FloeThemeStore]) to the platform status/navigation icon
 * contrast of the hosting activity window, using the existing Compose
 * lifecycle as the trigger — no parallel window manager or global listener.
 *
 * Only the window-local WindowInsetsControllerCompat appearance bits change:
 * the user's system-wide theme is read, never written. Edge-to-edge from
 * MainActivity.enableEdgeToEdge(), predictive back and IME insets are
 * untouched — the default transparent auto scrims keep their behaviour and
 * this effect only re-resolves icon contrast whenever the effective
 * appearance flips: forced Night → light icons, forced Day → dark icons,
 * Auto → follow the system (re-applied after the uiMode configuration
 * change). Writing the same value again is a platform no-op, and the effect
 * is bound to the composition so it cannot outlive the activity.
 */
@Composable
fun FloeSystemBarAppearance(themeMode: FloeThemeMode) {
    val view = LocalView.current
    FloeWindowBarAppearance(view.context.floeHostActivity()?.window,
        dark = floeIsDarkAppearance(themeMode))
}

/** A fullscreen Compose dialog has its own window; changing the activity's
 * icons does not reach it. Match the current Floe surface in that window. */
@Composable
internal fun FloeDialogSystemBarAppearance() {
    val view = LocalView.current
    val window = (view.parent as? DialogWindowProvider)?.window
    FloeWindowBarAppearance(window, dark = Floe.colors.isDark)
}

@Composable
private fun FloeWindowBarAppearance(window: Window?, dark: Boolean) {
    LaunchedEffect(window, dark) {
        window ?: return@LaunchedEffect
        val controller = WindowCompat.getInsetsController(window, window.decorView)
            ?: return@LaunchedEffect
        controller.isAppearanceLightStatusBars = !dark
        controller.isAppearanceLightNavigationBars = !dark
    }
}

/** setContent() wraps the activity context; unwrap to reach its window. */
private tailrec fun Context.floeHostActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext?.floeHostActivity()
    else -> null
}
