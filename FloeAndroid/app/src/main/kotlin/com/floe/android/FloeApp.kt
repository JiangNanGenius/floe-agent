// SPDX-License-Identifier: MPL-2.0
package com.floe.android

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeThemeMode

/**
 * Local appearance preference (Settings → General → Day & Night). This is
 * intentionally a real G01 feature: the value persists across restarts in
 * the app's private preferences and drives the theme immediately.
 */
class FloeThemeStore(context: Context) {
    private val prefs = context.getSharedPreferences("floe_appearance", Context.MODE_PRIVATE)

    var mode: FloeThemeMode
        get() = runCatching { FloeThemeMode.valueOf(prefs.getString(KEY, null) ?: FloeThemeMode.AUTO.name) }
            .getOrDefault(FloeThemeMode.AUTO)
        set(value) {
            prefs.edit().putString(KEY, value.name).apply()
        }

    companion object {
        private const val KEY = "theme_mode"
    }
}

@Composable
fun FloeApp() {
    val context = LocalContext.current
    val store = androidx.compose.runtime.remember(context) { FloeThemeStore(context) }
    var themeMode by rememberSaveable { mutableStateOf(store.mode) }
    FloeTheme(themeMode = themeMode) {
        FloeSystemBarAppearance(themeMode)
        FloeShell(
            themeMode = themeMode,
            onThemeModeChange = { next ->
                themeMode = next
                store.mode = next
            },
        )
    }
}
