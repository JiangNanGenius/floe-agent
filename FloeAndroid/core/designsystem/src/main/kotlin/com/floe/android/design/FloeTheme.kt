// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.unit.dp
import io.github.robinpcrd.cupertino.theme.CupertinoTheme
import io.github.robinpcrd.cupertino.theme.darkColorScheme
import io.github.robinpcrd.cupertino.theme.lightColorScheme

/** User-selectable appearance (Settings → General → Day & Night theme). */
@Immutable
enum class FloeThemeMode { AUTO, LIGHT, DARK }

internal val LocalFloeColors: ProvidableCompositionLocal<FloeColors> = staticCompositionLocalOf { FloeLightColors }
internal val LocalFloeType: ProvidableCompositionLocal<FloeTypography> = staticCompositionLocalOf { FloeTypography() }

/** Semantic accessors — business pages never hard-code colors or text styles. */
object Floe {
    val colors: FloeColors
        @Composable @ReadOnlyComposable get() = LocalFloeColors.current
    val typography: FloeTypography
        @Composable @ReadOnlyComposable get() = LocalFloeType.current
}

/**
 * The Floe theme shell: explicit Cupertino theming (never the adaptive
 * Material fallback) bridged to the Floe semantic palette sampled from the
 * current iPad build, plus the Android 48dp interactive floor overriding
 * Cupertino's 44dp default.
 */
@Composable
fun FloeTheme(
    themeMode: FloeThemeMode = FloeThemeMode.AUTO,
    content: @Composable () -> Unit,
) {
    val dark = when (themeMode) {
        FloeThemeMode.AUTO -> isSystemInDarkTheme()
        FloeThemeMode.LIGHT -> false
        FloeThemeMode.DARK -> true
    }
    val colors = if (dark) FloeDarkColors else FloeLightColors
    val scheme = if (dark) {
        darkColorScheme(
            accent = colors.accent,
            label = colors.label,
            secondaryLabel = colors.secondaryLabel,
            tertiaryLabel = colors.tertiaryLabel,
            quaternaryLabel = colors.tertiaryLabel,
            placeholderText = colors.placeholderText,
            separator = colors.separator,
            systemGroupedBackground = colors.groupedSurface,
            secondarySystemGroupedBackground = colors.sectionCardSurface,
            tertiarySystemGroupedBackground = colors.sidebarSurface,
            systemBackground = colors.readingSurface,
            secondarySystemBackground = colors.sidebarSurface,
            tertiarySystemBackground = colors.groupedSurface,
        )
    } else {
        lightColorScheme(
            accent = colors.accent,
            label = colors.label,
            secondaryLabel = colors.secondaryLabel,
            tertiaryLabel = colors.tertiaryLabel,
            quaternaryLabel = colors.tertiaryLabel,
            placeholderText = colors.placeholderText,
            separator = colors.separator,
            systemGroupedBackground = colors.groupedSurface,
            secondarySystemGroupedBackground = colors.sectionCardSurface,
            tertiarySystemGroupedBackground = colors.groupedSurface,
            systemBackground = colors.readingSurface,
            secondarySystemBackground = colors.sidebarSurface,
            tertiarySystemBackground = colors.groupedSurface,
        )
    }
    CupertinoTheme(colorScheme = scheme) {
        // Android hit-target floor: upstream Cupertino provides 44dp.
        androidx.compose.runtime.CompositionLocalProvider(
            LocalMinimumInteractiveComponentSize provides FloeLayout.MinimumTarget,
            LocalFloeColors provides colors,
            LocalFloeType provides FloeTypography(),
            content = content,
        )
    }
}
