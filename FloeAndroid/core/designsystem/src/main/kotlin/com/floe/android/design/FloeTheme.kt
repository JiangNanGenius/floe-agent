// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.LocalMinimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.robinpcrd.cupertino.theme.CupertinoTheme
import io.github.robinpcrd.cupertino.theme.darkColorScheme
import io.github.robinpcrd.cupertino.theme.lightColorScheme

/** User-selectable appearance (Settings → General → Day & Night theme). */
@Immutable
enum class FloeThemeMode { AUTO, LIGHT, DARK }

/**
 * Effective dark appearance for the saved mode: AUTO mirrors the system
 * night mode (re-read on configuration changes), LIGHT/DARK are app-forced.
 * Single source of truth shared by [FloeTheme] and the window-level system
 * bar bridge in the app module, so Compose surfaces and platform
 * status/navigation icon contrast can never diverge. Changing the user's
 * global system theme is never implied here — the system value is only read.
 */
@Composable
@ReadOnlyComposable
fun floeIsDarkAppearance(themeMode: FloeThemeMode): Boolean = when (themeMode) {
    FloeThemeMode.AUTO -> isSystemInDarkTheme()
    FloeThemeMode.LIGHT -> false
    FloeThemeMode.DARK -> true
}

internal val LocalFloeColors: ProvidableCompositionLocal<FloeColors> = staticCompositionLocalOf { FloeLightColors }
internal val LocalFloeType: ProvidableCompositionLocal<FloeTypography> = staticCompositionLocalOf { FloeTypography() }
internal val LocalFloeCompactSettings = staticCompositionLocalOf { false }

/**
 * Shared compact chrome provider for form/navigation surfaces that opt into
 * density (Settings on compact windows, the phone sidebar drawer): one step
 * down on title/section/body/metadata/group-header sizes, plus the
 * [LocalFloeCompactSettings] flag the row/section/switch wrappers read to
 * tighten paddings and visible chrome. Sizes stay in sp, so the system
 * font-scale keeps working; nothing here touches document/chat reading
 * surfaces and there is no fixed fontScale override.
 */
@Composable
fun FloeSettingsContentDensity(compact: Boolean, content: @Composable () -> Unit) {
    if (!compact) {
        content()
        return
    }
    val base = Floe.typography
    val type = remember(base) {
        base.copy(
            title = base.title.copy(fontSize = 17.sp, lineHeight = 22.sp),
            section = base.section.copy(fontSize = 15.sp, lineHeight = 21.sp),
            body = base.body.copy(fontSize = 14.sp, lineHeight = 20.sp),
            bodyEmphasized = base.bodyEmphasized.copy(fontSize = 14.sp, lineHeight = 20.sp),
            metadata = base.metadata.copy(fontSize = 12.sp, lineHeight = 17.sp),
            groupHeader = base.groupHeader.copy(fontSize = 12.sp, lineHeight = 16.sp),
        )
    }
    CompositionLocalProvider(
        LocalFloeType provides type,
        LocalFloeCompactSettings provides true,
        content = content,
    )
}

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
    /** Future Settings/accessibility switch; false keeps the opaque fallback. */
    materialEnabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    val dark = floeIsDarkAppearance(themeMode)
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
    // One real Haze source/effect owner for this App theme subtree. The host
    // only publishes the controller; a page still marks its actual moving
    // content with FloeMaterialScene/floeMaterialSource. Without that scene
    // every material surface keeps its opaque, readable fallback.
    FloeMaterialHost(userEnabled = materialEnabled) {
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
}
