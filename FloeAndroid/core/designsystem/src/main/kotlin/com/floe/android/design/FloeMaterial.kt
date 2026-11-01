// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.remember
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState

/**
 * Shared, real backdrop material for the Floe Android chrome.
 *
 * This is deliberately NOT a translucent-alpha rectangle called "blur". A
 * [FloeMaterialController] owns one Haze 1.7.3 [HazeState]; a scene marks the
 * actual moving content with [floeMaterialSource]/[FloeMaterialScene], and
 * chrome surfaces opt into a [FloeMaterialLevel] through [floeMaterialSurface].
 * Haze captures that source in a graphics layer and draws the effect behind
 * the surface, including across Dialog/Popup windows (Haze 1.7.x handles the
 * cross-window pre-draw invalidation itself, so the sheet surfaces below do
 * not invent a second invalidation path).
 *
 * Readability and older-device behaviour:
 *  - the source scene and the effect are always siblings, never nested, so an
 *    effect can never sample itself recursively;
 *  - blur is enabled only where the platform implementation is reliable. SDK
 *    31 is deliberately excluded (the known RenderNode invalidation defect
 *    documented by Haze); SDK 28-31, an explicit disabled preference, or a
 *    scene with no live source use an OPAQUE fallback surface, not a fake
 *    blur. The fallback colours are the same semantic surfaces as before, so
 *    text contrast does not depend on the wallpaper or underlying content;
 *  - native editable content (the text/office/canvas render surfaces) is never
 *    wrapped as a material surface. Only chrome, sheets and popovers opt in.
 *
 * Lifecycle: [rememberFloeMaterialController] ties the Haze state to the
 * composition that owns it. [FloeMaterialHost] installs it for an App subtree;
 * the state and its graphics layers are released when that subtree leaves
 * composition. There is no process-global mutable material state.
 */
@Immutable
enum class FloeMaterialLevel(
    val blurRadius: Dp,
    /** Fraction of the semantic chrome colour drawn over the captured scene. */
    val lightSurfaceAlpha: Float,
    val darkSurfaceAlpha: Float,
    /** Subtle iOS-like tint over the blurred scene. */
    val lightTintAlpha: Float,
    val darkTintAlpha: Float,
    val noise: Float,
) {
    /** Circular toolbar controls and other small chrome that floats over content. */
    CHROME(
        blurRadius = 18.dp,
        lightSurfaceAlpha = 0.66f,
        darkSurfaceAlpha = 0.62f,
        lightTintAlpha = 0.08f,
        darkTintAlpha = 0.10f,
        noise = 0.04f,
    ),

    /** The composer chrome (r22 surface). */
    COMPOSER(
        blurRadius = 24.dp,
        lightSurfaceAlpha = 0.74f,
        darkSurfaceAlpha = 0.70f,
        lightTintAlpha = 0.10f,
        darkTintAlpha = 0.12f,
        noise = 0.05f,
    ),

    /** Toolbar/status chrome that sits against the page. */
    BAR(
        blurRadius = 20.dp,
        lightSurfaceAlpha = 0.82f,
        darkSurfaceAlpha = 0.78f,
        lightTintAlpha = 0.08f,
        darkTintAlpha = 0.10f,
        noise = 0.04f,
    ),

    /** Page sheets and form sheets. Kept nearly opaque for long-form reading. */
    SHEET(
        blurRadius = 28.dp,
        lightSurfaceAlpha = 0.95f,
        darkSurfaceAlpha = 0.92f,
        lightTintAlpha = 0.06f,
        darkTintAlpha = 0.08f,
        noise = 0.03f,
    ),

    /** Anchored popovers and menus; content-fit and readable over the page. */
    POPOVER(
        blurRadius = 30.dp,
        lightSurfaceAlpha = 0.92f,
        darkSurfaceAlpha = 0.90f,
        lightTintAlpha = 0.08f,
        darkTintAlpha = 0.10f,
        noise = 0.04f,
    ),
    ;

    fun surfaceAlpha(dark: Boolean): Float = if (dark) darkSurfaceAlpha else lightSurfaceAlpha

    fun tintAlpha(dark: Boolean): Float = if (dark) darkTintAlpha else lightTintAlpha
}

/**
 * Platform/feature gate for the real blur. Kept pure so JVM tests pin the
 * old-device boundary without booting a device.
 *
 * Haze's own default has varied between 31 and 32 across releases, and the
 * task's fixed upstream contract explicitly retains the SDK-31 exclusion.
 * Floe therefore does not rely on a library default that can drift: 31 and
 * older always receive the readable opaque fallback.
 */
object FloeMaterialSupport {
    /** First API level on which Haze's RenderNode path is used. */
    const val FIRST_RELIABLE_BLUR_SDK: Int = 32

    fun supportsBlur(sdkInt: Int): Boolean = sdkInt >= FIRST_RELIABLE_BLUR_SDK

    fun effectiveBlurEnabled(sdkInt: Int, userEnabled: Boolean): Boolean =
        userEnabled && supportsBlur(sdkInt)

    /**
     * True when a surface must paint its opaque semantic colour instead of a
     * Haze effect: unsupported platform, material explicitly disabled, or no
     * live source in the current scene.
     */
    fun usesOpaqueFallback(sdkInt: Int, userEnabled: Boolean, hasSource: Boolean): Boolean =
        !effectiveBlurEnabled(sdkInt, userEnabled) || !hasSource
}

/**
 * Composition-scoped owner of the single Haze state used by Floe chrome.
 * [hasSource] is observed from Haze's snapshot area list, so a material
 * surface automatically moves between the opaque fallback and the effect
 * when the owning scene appears/disappears (for example after a route change
 * or a Dialog teardown).
 */
@Stable
class FloeMaterialController internal constructor(
    val state: HazeState,
    val blurEnabled: Boolean,
) {
    val hasSource: Boolean
        get() = state.areas.isNotEmpty()
}

/** Installed by [FloeMaterialHost]/[FloeMaterialScene] and by [FloeTheme]. */
val LocalFloeMaterial: ProvidableCompositionLocal<FloeMaterialController?> =
    staticCompositionLocalOf { null }

/** Separate owner for Dialog/Popup windows sampling the App scene. In-window
 * chrome keeps its own scene controller, so the modal source never samples
 * its own effect through a descendant control. */
val LocalFloeOverlayMaterial: ProvidableCompositionLocal<FloeMaterialController?> =
    staticCompositionLocalOf { null }

/**
 * Create the material controller for one composition. [userEnabled] is the
 * future Settings/accessibility switch; disabling it keeps the exact same
 * semantic surfaces with the opaque fallback.
 */
@Composable
fun rememberFloeMaterialController(
    userEnabled: Boolean = true,
    sdkInt: Int = Build.VERSION.SDK_INT,
): FloeMaterialController {
    val blurEnabled = remember(userEnabled, sdkInt) {
        FloeMaterialSupport.effectiveBlurEnabled(sdkInt, userEnabled)
    }
    val state = rememberHazeState(blurEnabled = blurEnabled)
    return remember(state, blurEnabled) {
        FloeMaterialController(state = state, blurEnabled = blurEnabled)
    }
}

/**
 * Install one shared material controller for a subtree without declaring a
 * scene. Pages that own real content call [FloeMaterialScene] or mark their
 * own source with [floeMaterialSource]; without a source every material
 * surface uses its opaque fallback.
 */
@Composable
fun FloeMaterialHost(
    userEnabled: Boolean = true,
    content: @Composable () -> Unit,
) {
    val controller = rememberFloeMaterialController(userEnabled = userEnabled)
    // No Box here: installing a theme must not change the caller's layout
    // constraints. Only FloeMaterialScene owns a full-size sibling layout.
    CompositionLocalProvider(LocalFloeMaterial provides controller, content = content)
}

/**
 * Sibling scene/effect layout. [background] is the real moving content and is
 * captured by [hazeSource]; [chrome] is drawn above it and contains the
 * material surfaces. Keeping them as siblings is what prevents self-sampling
 * (a surface inside the source would capture itself every frame).
 */
@Composable
fun FloeMaterialScene(
    modifier: Modifier = Modifier,
    controller: FloeMaterialController? = null,
    userEnabled: Boolean = true,
    background: @Composable BoxScope.() -> Unit,
    chrome: @Composable BoxScope.() -> Unit,
) {
    val fallback = rememberFloeMaterialController(userEnabled = userEnabled)
    val resolved = controller ?: LocalFloeMaterial.current ?: fallback
    CompositionLocalProvider(LocalFloeMaterial provides resolved) {
        Box(modifier = modifier.fillMaxSize()) {
            Box(
                modifier = if (resolved.blurEnabled) {
                    Modifier
                        .matchParentSize()
                        .hazeSource(resolved.state)
                } else {
                    // No layer capture at all on unsupported/disabled
                    // platforms; the opaque fallback is the complete surface.
                    Modifier.matchParentSize()
                },
                content = background,
            )
            Box(
                modifier = Modifier.matchParentSize(),
                content = chrome,
            )
        }
    }
}

/**
 * Mark this subtree as the actual scene for the nearest material controller.
 * Callers must place the marked subtree as a sibling of the chrome that uses
 * [floeMaterialSurface]; nesting an effect inside its own source is the
 * recursive case this API intentionally makes hard to write.
 */
@Composable
fun Modifier.floeMaterialSource(
    controller: FloeMaterialController? = LocalFloeMaterial.current,
    zIndex: Float = 0f,
): Modifier {
    val resolved = controller ?: return this
    if (!resolved.blurEnabled) return this
    return this.then(Modifier.hazeSource(resolved.state, zIndex = zIndex))
}

/**
 * Draw [level] behind this surface using the real captured scene.
 *
 * When no controller/source is available, or blur is disabled/unsupported,
 * this paints [fallbackColor] opaquely. The shape is always clipped before
 * painting, so the fallback and the effect share identical geometry.
 */
@Composable
fun Modifier.floeMaterialSurface(
    level: FloeMaterialLevel,
    shape: Shape = RectangleShape,
    controller: FloeMaterialController? = LocalFloeMaterial.current,
    fallbackColor: Color? = null,
): Modifier {
    val colors = Floe.colors
    val base = fallbackColor ?: colors.chromeSurface
    val usable = controller != null &&
        controller.blurEnabled &&
        controller.hasSource
    if (!usable) {
        // Opaque semantic surface. This is the old, readable surface — not a
        // translucent layer pretending to be a backdrop effect.
        return this
            .clip(shape)
            .background(base)
    }
    val dark = colors.isDark
    val tint = if (dark) Color.Black else Color.White
    return this
        .clip(shape)
        .hazeEffect(state = controller.state) {
            blurEnabled = true
            backgroundColor = base.copy(alpha = level.surfaceAlpha(dark))
            tints = listOf(HazeTint(tint.copy(alpha = level.tintAlpha(dark))))
            fallbackTint = HazeTint(base)
            blurRadius = level.blurRadius
            noiseFactor = level.noise
        }
}
