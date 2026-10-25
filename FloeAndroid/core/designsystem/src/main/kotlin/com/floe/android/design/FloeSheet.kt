// SPDX-License-Identifier: MPL-2.0
package com.floe.android.design

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import kotlin.math.roundToInt

/**
 * Explicit placement of a [FloePageSheet].
 *
 * The legacy G01 full-window sheet is bottom-anchored. Fractional sheets need
 * an explicit policy: the wide provider editor / model manager are CENTERED
 * rounded panes, while compact partial-height choosers are BOTTOM-anchored
 * sheets (the iPad compact adaptation). Callers must choose instead of relying
 * on an inferred "fraction means centered" rule, which produced a floating
 * centered purpose/offer card on compact windows.
 */
enum class FloeSheetPlacement { CENTER, BOTTOM }

/**
 * iOS-style page sheet: dim scrim + rounded surface, system-back dismissal and
 * iOS-motion easing. Content owns its own toolbar (title + actions), matching
 * SettingsRootView's sheet behavior.
 *
 * Backward-compatible extension (G02 provider flow): [widthFraction] and
 * [heightFraction] let a sheet float as a centered rounded page (measured
 * iPad references: provider editor ≈82% of the usable window, nested model
 * manager ≈51%; see PROVIDER_UI_CONTRACT.md). [placement] is explicit:
 * CENTER for those measured wide panes, BOTTOM for compact sheets. When it is
 * omitted the historical behavior is preserved (fractional → centered, full
 * window → bottom), so the G01 settings sheet is unchanged.
 *
 * The surface is a fraction of the ACTUAL dialog window, so window insets and
 * font scale govern real size — never hard-coded pixels. Nested sheets stack
 * as separate dialogs; the narrower surface keeps the parent sheet visible
 * (dimmed) behind, so the retained context stays legible.
 */
@Composable
fun FloePageSheet(
    visible: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    topInset: Dp = 0.dp,
    widthFraction: Float = 1f,
    heightFraction: Float = 1f,
    placement: FloeSheetPlacement? = null,
    content: @Composable BoxScope.() -> Unit,
) {
    val floating = widthFraction < 1f || heightFraction < 1f
    // Legacy default stays exact: 1f/1f is the bottom settings sheet, a
    // fractional legacy call is centered. New G02 callers pass it explicitly.
    val resolvedPlacement = placement
        ?: if (floating) FloeSheetPlacement.CENTER else FloeSheetPlacement.BOTTOM
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(220, easing = LinearOutSlowInEasing)) +
            slideInVertically(tween(320, easing = LinearOutSlowInEasing)) { it / 6 },
        exit = fadeOut(tween(160)) +
            slideOutVertically(tween(280, easing = LinearOutSlowInEasing)) { it / 6 },
        modifier = modifier,
    ) {
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false,
            ),
        ) {
            BackHandler(onBack = onDismiss)
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.28f))
                    // safeDrawing includes the IME. Size the sheet inside
                    // that space so editable dialogs keep actions reachable.
                    .safeDrawingPadding(),
                contentAlignment = when (resolvedPlacement) {
                    FloeSheetPlacement.CENTER -> Alignment.Center
                    FloeSheetPlacement.BOTTOM -> Alignment.BottomCenter
                },
            ) {
                when (resolvedPlacement) {
                    FloeSheetPlacement.CENTER -> {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(widthFraction.coerceIn(0.3f, 1f))
                                .fillMaxHeight(heightFraction.coerceIn(0.3f, 1f))
                                .clip(RoundedCornerShape(FloeLayout.SettingsSheetCorner))
                                .background(Floe.colors.readingSurface),
                            content = content,
                        )
                    }
                    FloeSheetPlacement.BOTTOM -> {
                        // A compact partial-height sheet stays bottom-anchored
                        // and full-width; only its top corners are rounded so
                        // it reads as a sheet, not a floating card. The
                        // historical 1f/1f case is byte-for-byte the old
                        // full-window surface (topInset + top corners).
                        val fullHeight = heightFraction >= 1f
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .then(
                                    if (fullHeight) {
                                        Modifier.fillMaxSize()
                                    } else {
                                        Modifier.fillMaxHeight(heightFraction.coerceIn(0.15f, 1f))
                                    }
                                )
                                .padding(top = topInset)
                                .clip(
                                    RoundedCornerShape(
                                        topStart = FloeLayout.SettingsSheetCorner,
                                        topEnd = FloeLayout.SettingsSheetCorner,
                                    )
                                )
                                .background(Floe.colors.readingSurface),
                            content = content,
                        )
                    }
                }
            }
        }
    }
}

/**
 * Explicit opt-in presentation for SECONDARY workspace forms (G04 repair
 * batch 2026-10-25): action / source / network / recovery / sibling sheets.
 *
 * [FloePageSheet]'s legacy default (1f/1f BOTTOM) is the main full-window
 * settings split view and must stay byte-for-byte unchanged. Measured device
 * evidence showed secondary workspace forms reusing that default stretched to
 * the whole tablet (full-width fields and giant Apply/Cancel). This helper is
 * the bounded iOS form-sheet idiom instead: on a wide window it is a
 * content-hugging rounded card centered and clamped to [maxCardWidth] (never
 * a fixed pixel size — the usable window after insets governs); on a compact
 * window it keeps the bottom-sheet idiom (full width, top corners only).
 * Height always hugs its content up to [maxCardHeightFraction] of the usable
 * window, and fixed-height panes (a `fillMaxSize` scrollable list) are
 * capped rather than stretched.
 *
 * Window/IME ownership is identical to [FloePageSheet]: the same Dialog
 * properties, scrim, corner radius, surface color and `safeDrawingPadding`
 * (which includes the IME), so keyboard-driven forms keep Apply/Cancel
 * reachable and system Back still dismisses.
 */
@Composable
fun FloeActionSheet(
    visible: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    maxCardWidth: Dp = 560.dp,
    maxCardHeightFraction: Float = 0.86f,
    content: @Composable BoxScope.() -> Unit,
) {
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(220, easing = LinearOutSlowInEasing)) +
            slideInVertically(tween(320, easing = LinearOutSlowInEasing)) { it / 6 },
        exit = fadeOut(tween(160)) +
            slideOutVertically(tween(280, easing = LinearOutSlowInEasing)) { it / 6 },
        modifier = modifier,
    ) {
        Dialog(
            onDismissRequest = onDismiss,
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false,
            ),
        ) {
            BackHandler(onBack = onDismiss)
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.28f))
                    // safeDrawing includes the IME; the card is sized inside
                    // that space exactly like FloePageSheet.
                    .safeDrawingPadding(),
            ) {
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val wide = maxWidth >= FloeLayout.PersistentTwoColumnMinWidth
                    val cardMaxWidth = if (wide) {
                        minOf(maxCardWidth, maxWidth - 32.dp)
                    } else {
                        maxWidth
                    }
                    val cardMaxHeight = maxHeight * maxCardHeightFraction.coerceIn(0.3f, 0.95f)
                    val shape = if (wide) {
                        RoundedCornerShape(FloeLayout.SettingsSheetCorner)
                    } else {
                        RoundedCornerShape(
                            topStart = FloeLayout.SettingsSheetCorner,
                            topEnd = FloeLayout.SettingsSheetCorner,
                        )
                    }
                    Box(
                        modifier = Modifier
                            .align(if (wide) Alignment.Center else Alignment.BottomCenter)
                            .widthIn(max = cardMaxWidth)
                            .heightIn(max = cardMaxHeight)
                            .clip(shape)
                            .background(Floe.colors.readingSurface),
                        content = content,
                    )
                }
            }
        }
    }
}

/**
 * Centered floating card (the old generic popover). Kept for surfaces that
 * are intentionally modal alerts (purpose chooser / one-time offer prompt on
 * wide windows). It is explicitly NOT an anchored popover: the supplier
 * chooser uses [FloeAnchoredPopoverCard] so it points at the measured
 * supplier field instead of the window center.
 */
@Composable
fun FloePopoverCard(
    visible: Boolean,
    onDismiss: () -> Unit,
    widthDp: Dp = 520.dp,
    heightDp: Dp = 680.dp,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    if (!visible) return
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        BackHandler(onBack = onDismiss)
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.24f)),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = modifier
                    .width(widthDp)
                    .height(heightDp)
                    .clip(RoundedCornerShape(FloeLayout.SettingsSheetCorner))
                    .background(Floe.colors.groupedSurface),
                content = content,
            )
        }
    }
}

/**
 * Geometry policy for [FloeAnchoredPopoverCard]. Kept as a small immutable
 * value object so the anchor math is explicit and testable in source review.
 */
@Immutable
data class FloePopoverGeometry(
    val horizontalMarginPx: Int,
    val verticalMarginPx: Int,
    val anchorGapPx: Int,
    val arrowHeightPx: Int,
)

/** Pixel inputs for the anchored-popover layout policy (density-resolved). */
@Immutable
internal data class FloePopoverMetrics(
    val preferredWidthPx: Int,
    val minWidthPx: Int,
    val preferredHeightPx: Int,
    val minHeightPx: Int,
    val horizontalMarginPx: Int,
    val verticalMarginPx: Int,
    val anchorGapPx: Int,
    val arrowHeightPx: Int,
) {
    fun geometry(): FloePopoverGeometry = FloePopoverGeometry(
        horizontalMarginPx = horizontalMarginPx,
        verticalMarginPx = verticalMarginPx,
        anchorGapPx = anchorGapPx,
        arrowHeightPx = arrowHeightPx,
    )
}

/** Resolved card box (excluding the arrow) and its actual side. */
@Immutable
internal data class FloePopoverLayout(
    val widthPx: Int,
    val cardHeightPx: Int,
    val placeAbove: Boolean,
    val cardLeftPx: Int,
    val arrowCenterInCardPx: Int,
)

/**
 * Pure anchored-popover sizing/placement policy: anchor-centred horizontally,
 * above the anchor when the field sits in the upper-middle of the window
 * (matching source capture 04), otherwise on the larger free side; all edges
 * clamped into the window and the height shrunk to the actual free side.
 * Unit-tested without a device so clamp regressions are visible in JVM tests.
 */
internal fun resolveFloePopoverLayout(
    anchor: Rect,
    windowWidthPx: Int,
    windowHeightPx: Int,
    metrics: FloePopoverMetrics,
): FloePopoverLayout {
    val safeWindowWidth = windowWidthPx.coerceAtLeast(1)
    val safeWindowHeight = windowHeightPx.coerceAtLeast(1)
    val availableWidth =
        (safeWindowWidth - metrics.horizontalMarginPx * 2).coerceAtLeast(1)
    val minWidthPx = metrics.minWidthPx.coerceIn(1, availableWidth)
    val widthPx = metrics.preferredWidthPx.coerceIn(minWidthPx, availableWidth)

    val anchorTop = anchor.top.roundToInt()
    val anchorBottom = anchor.bottom.roundToInt()
    val spaceAbove = (anchorTop - metrics.anchorGapPx - metrics.arrowHeightPx -
        metrics.verticalMarginPx).coerceAtLeast(0)
    val spaceBelow = (safeWindowHeight - anchorBottom - metrics.anchorGapPx -
        metrics.arrowHeightPx - metrics.verticalMarginPx).coerceAtLeast(0)
    val anchorCenterY = anchor.center.y.roundToInt()
    val preferAbove = anchorCenterY >= (safeWindowHeight * 0.38f).roundToInt()
    val minUsefulAbove = (safeWindowHeight * 0.22f).roundToInt()
    // Above is the source-capture side for an upper-middle field, but never
    // squeeze the card into a sliver: near the top (or when above is smaller)
    // flip below where the form has room.
    val placeAbove = spaceAbove >= minUsefulAbove && (preferAbove || spaceAbove > spaceBelow)
    val freeOnChosenSide = if (placeAbove) spaceAbove else spaceBelow
    val maxCardHeight = (safeWindowHeight - metrics.verticalMarginPx * 2 -
        metrics.arrowHeightPx).coerceAtLeast(1)
    val minHeightPx = metrics.minHeightPx.coerceIn(1, maxCardHeight)
    val cardHeightPx = metrics.preferredHeightPx
        .coerceIn(1, maxCardHeight)
        .coerceAtMost(freeOnChosenSide.coerceAtLeast(1))
        .coerceAtLeast(
            minOf(minHeightPx, freeOnChosenSide.coerceAtLeast(1))
        )

    val anchorCenterX = anchor.center.x.roundToInt()
    val maxLeft = (safeWindowWidth - metrics.horizontalMarginPx - widthPx)
        .coerceAtLeast(metrics.horizontalMarginPx)
    val cardLeftPx = (anchorCenterX - widthPx / 2)
        .coerceIn(metrics.horizontalMarginPx, maxLeft)
    val arrowCenterInCardPx = (anchorCenterX - cardLeftPx)
        .coerceIn(
            metrics.arrowHeightPx,
            (widthPx - metrics.arrowHeightPx).coerceAtLeast(metrics.arrowHeightPx),
        )
    return FloePopoverLayout(
        widthPx = widthPx,
        cardHeightPx = cardHeightPx,
        placeAbove = placeAbove,
        cardLeftPx = cardLeftPx,
        arrowCenterInCardPx = arrowCenterInCardPx,
    )
}

/**
 * Real anchored popover (iOS popover / pointing popup): the card is placed
 * beside the measured [anchorBounds] in window coordinates — above the anchor
 * when there is useful space there, otherwise below it — horizontally centred
 * on the anchor and clamped into the visible window on every side. The arrow
 * points back at the anchor.
 *
 * This is a [Popup] window (focusable, outside-tap dismiss, no clipping), not
 * a centered [Dialog]: opening the supplier chooser must stay attached to the
 * supplier row the user tapped. The actual width/height are the measured iPad
 * source sizes (min420/ideal520 wide, min540/ideal680 high) constrained to the
 * live window and the space on the chosen side; insets/density/font scale
 * govern the result. [FloePopoverGeometry] is computed from the real window
 * and density, never hard-coded device pixels.
 */
@Composable
fun FloeAnchoredPopoverCard(
    visible: Boolean,
    onDismiss: () -> Unit,
    anchorBounds: Rect,
    modifier: Modifier = Modifier,
    preferredWidth: Dp = 520.dp,
    minWidth: Dp = 420.dp,
    preferredHeight: Dp = 680.dp,
    minHeight: Dp = 540.dp,
    content: @Composable BoxScope.() -> Unit,
) {
    if (!visible) return
    val density = LocalDensity.current
    val windowInfo = LocalWindowInfo.current
    val windowSize = windowInfo.containerSize
    // Fallback keeps the popover usable during the first measurement pass on
    // unusual hosts where the window container size is not published yet.
    val windowWidthPx = windowSize.width.takeIf { it > 0 } ?: with(density) { 1280.dp.roundToPx() }
    val windowHeightPx = windowSize.height.takeIf { it > 0 } ?: with(density) { 800.dp.roundToPx() }
    val metrics = remember(density, preferredWidth, minWidth, preferredHeight, minHeight) {
        FloePopoverMetrics(
            preferredWidthPx = with(density) { preferredWidth.roundToPx() },
            minWidthPx = with(density) { minWidth.roundToPx() },
            preferredHeightPx = with(density) { preferredHeight.roundToPx() },
            minHeightPx = with(density) { minHeight.roundToPx() },
            horizontalMarginPx = with(density) { 16.dp.roundToPx() },
            verticalMarginPx = with(density) { 12.dp.roundToPx() },
            anchorGapPx = with(density) { 8.dp.roundToPx() },
            arrowHeightPx = with(density) { 10.dp.roundToPx() },
        )
    }
    val shape = RoundedCornerShape(FloeLayout.SettingsSheetCorner)
    val layout = resolveFloePopoverLayout(
        anchor = anchorBounds,
        windowWidthPx = windowWidthPx,
        windowHeightPx = windowHeightPx,
        metrics = metrics,
    )
    val geometry = metrics.geometry()
    val positionProvider = remember(
        anchorBounds,
        layout.widthPx,
        layout.cardHeightPx,
        layout.placeAbove,
        geometry,
        windowWidthPx,
        windowHeightPx,
    ) {
        FloeAnchoredPopoverPositionProvider(
            anchor = anchorBounds,
            geometry = geometry,
            placeAbove = layout.placeAbove,
        )
    }
    val cardWidth = with(density) { layout.widthPx.toDp() }
    val cardHeight = with(density) { layout.cardHeightPx.toDp() }
    val arrowHeight = with(density) { metrics.arrowHeightPx.toDp() }

    Popup(
        popupPositionProvider = positionProvider,
        onDismissRequest = onDismiss,
        properties = PopupProperties(
            focusable = true,
            dismissOnClickOutside = true,
            clippingEnabled = false,
        ),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            if (layout.placeAbove) {
                PopoverSurfaceCard(
                    width = cardWidth,
                    height = cardHeight,
                    shape = shape,
                    modifier = modifier,
                    content = content,
                )
                PopoverArrow(
                    width = cardWidth,
                    height = arrowHeight,
                    centerInCard = layout.arrowCenterInCardPx,
                    pointsDown = true,
                )
            } else {
                PopoverArrow(
                    width = cardWidth,
                    height = arrowHeight,
                    centerInCard = layout.arrowCenterInCardPx,
                    pointsDown = false,
                )
                PopoverSurfaceCard(
                    width = cardWidth,
                    height = cardHeight,
                    shape = shape,
                    modifier = modifier,
                    content = content,
                )
            }
        }
    }
}

@Composable
private fun PopoverSurfaceCard(
    width: Dp,
    height: Dp,
    shape: androidx.compose.ui.graphics.Shape,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(
        modifier = modifier
            .width(width)
            .height(height)
            .shadow(elevation = 20.dp, shape = shape, clip = false)
            .clip(shape)
            .background(Floe.colors.groupedSurface),
        content = content,
    )
}

@Composable
private fun PopoverArrow(
    width: Dp,
    height: Dp,
    centerInCard: Int,
    pointsDown: Boolean,
) {
    val color = Floe.colors.groupedSurface
    val density = LocalDensity.current
    val centerDp = with(density) { centerInCard.toDp() }
    Canvas(modifier = Modifier.width(width).height(height)) {
        val half = size.height / 2f
        val centerX = centerDp.toPx()
        val path = Path().apply {
            if (pointsDown) {
                moveTo(centerX - half, 0f)
                lineTo(centerX + half, 0f)
                lineTo(centerX, size.height)
            } else {
                moveTo(centerX, 0f)
                lineTo(centerX - half, size.height)
                lineTo(centerX + half, size.height)
            }
            close()
        }
        drawPath(path, color)
    }
}

/**
 * Places the popup window from the real anchor rectangle and window size.
 * The horizontal position centres on the anchor and clamps to the window;
 * the vertical position sits above/below the anchor with the arrow gap and
 * clamps as well. Exposed internally for source-level geometry checks.
 */
internal class FloeAnchoredPopoverPositionProvider(
    private val anchor: Rect,
    private val geometry: FloePopoverGeometry,
    private val placeAbove: Boolean,
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val contentWidth = popupContentSize.width.coerceAtLeast(1)
        val contentHeight = popupContentSize.height.coerceAtLeast(1)
        val anchorCenterX = anchor.center.x.roundToInt()
        val maxX = (windowSize.width - geometry.horizontalMarginPx - contentWidth)
            .coerceAtLeast(geometry.horizontalMarginPx)
        val x = (anchorCenterX - contentWidth / 2)
            .coerceIn(geometry.horizontalMarginPx, maxX)
        val rawY = if (placeAbove) {
            anchor.top.roundToInt() - contentHeight - geometry.anchorGapPx
        } else {
            anchor.bottom.roundToInt() + geometry.anchorGapPx
        }
        val maxY = (windowSize.height - geometry.verticalMarginPx - contentHeight)
            .coerceAtLeast(geometry.verticalMarginPx)
        val y = rawY.coerceIn(geometry.verticalMarginPx, maxY)
        return IntOffset(x, y)
    }
}
