// SPDX-License-Identifier: MPL-2.0
//
// Content-fit host popover used by the Settings provider purpose chooser.
//
// This is an explicit opt-in API. The historical FloeAnchoredPopoverCard
// (supplier chooser and other G01 callers) keeps its fixed preferred/minimum
// height contract and is intentionally untouched. FloeHostPopoverCard measures
// its actual content, so translations, font scale and the three real role
// actions determine the card height; there is no 420x396 body or empty area
// below the last action.
//
// Two placements share one resolver:
//  - CATEGORY_BOUNDARY: body inside the measured left Settings category pane,
//    trailing edge against the measured category boundary, right-pointing
//    arrow at the selected row's vertical reference;
//  - TRIGGER_FALLBACK: wide layout with the category collapsed/absent; the
//    card is attached to the measured visible trigger with content-fit size
//    and an up/down arrow, never to a guessed category rectangle.
// Compact windows are suppressed; the provider destination keeps its bottom
// action sheet.

package com.floe.android.design

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties

/** Stable semantics tags for the source-qualification fixture. */
object FloeHostPopoverTags {
    const val Scroll = "floe.hostPopover.scroll"
    const val ArrowRight = "floe.hostPopover.arrow.right"
    const val ArrowUp = "floe.hostPopover.arrow.up"
    const val ArrowDown = "floe.hostPopover.arrow.down"
}

private const val BodySlot = "floe.hostPopover.body"
private const val ArrowSlot = "floe.hostPopover.arrow"

/**
 * Explicit content-fit popover for a measured host placement.
 *
 * [geometry] must be the actual measured Settings host snapshot (window
 * pixels, see FloeSettingsHostGeometry). [content] is measured unconstrained
 * up to the resolved maximum height; the resulting card height is the content
 * height, and the content scrolls inside that bound when it cannot fit. The
 * caller's [modifier] is applied to the card body (use it for the stable
 * `provider.purposeMenu` test tag); the scroll container has
 * [FloeHostPopoverTags.Scroll] for real scroll assertions.
 */
@Composable
fun FloeHostPopoverCard(
    visible: Boolean,
    onDismiss: () -> Unit,
    geometry: FloeSettingsHostGeometry,
    modifier: Modifier = Modifier,
    metrics: FloeHostPopoverMetrics? = null,
    content: @Composable () -> Unit,
) {
    if (!visible) return
    val density = LocalDensity.current
    val resolvedMetrics = metrics ?: remember(density) {
        FloeHostPopoverMetrics.fromDensity(density)
    }
    val mode = resolveFloeHostPopoverMode(geometry, resolvedMetrics)
    if (mode == FloeHostPopoverMode.SUPPRESSED_COMPACT) return

    val widthPx = resolveFloeHostPopoverWidthPx(geometry, resolvedMetrics).coerceAtLeast(1)
    val maxContentHeightPx = resolveFloeHostPopoverMaxContentHeightPx(geometry, resolvedMetrics)
        .coerceAtLeast(1)
    val widthDp = with(density) { widthPx.toDp() }
    val maxContentHeightDp = with(density) { maxContentHeightPx.toDp() }
    val scrollState = rememberScrollState()
    val shape = RoundedCornerShape(FloeLayout.SettingsSheetCorner)
    val surfaceColor: Color = Floe.colors.groupedSurface
    val positionProvider = remember(geometry, resolvedMetrics) {
        FloeHostPopoverPositionProvider(geometry, resolvedMetrics)
    }

    Popup(
        popupPositionProvider = positionProvider,
        onDismissRequest = onDismiss,
        properties = PopupProperties(
            focusable = true,
            dismissOnClickOutside = true,
            dismissOnBackPress = true,
            clippingEnabled = false,
        ),
    ) {
        SubcomposeLayout { _ ->
            val body = subcompose(BodySlot) {
                Box(
                    modifier = modifier
                        .width(widthDp)
                        .shadow(elevation = 20.dp, shape = shape, clip = false)
                        .clip(shape)
                        .background(surfaceColor),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = maxContentHeightDp)
                            .verticalScroll(scrollState)
                            .testTag(FloeHostPopoverTags.Scroll),
                    ) {
                        content()
                    }
                }
            }.first().measure(
                Constraints(
                    minWidth = widthPx,
                    maxWidth = widthPx,
                    maxHeight = maxContentHeightPx,
                ),
            )

            val resolvedLayout = resolveFloeHostPopoverLayout(
                geometry = geometry,
                metrics = resolvedMetrics,
                measuredContentHeightPx = body.height,
            )
            val arrow = if (resolvedLayout.arrow == FloeHostPopoverArrow.NONE) {
                null
            } else {
                subcompose(ArrowSlot) {
                    FloeHostPopoverArrowCanvas(
                        arrow = resolvedLayout.arrow,
                        widthPx = resolvedLayout.arrowWidthPx,
                        heightPx = resolvedLayout.arrowHeightPx,
                        color = surfaceColor,
                    )
                }.first().measure(Constraints())
            }

            layout(
                width = resolvedLayout.popupWidthPx.coerceAtLeast(1),
                height = resolvedLayout.popupHeightPx.coerceAtLeast(1),
            ) {
                body.place(resolvedLayout.bodyOffsetXPx, resolvedLayout.bodyOffsetYPx)
                arrow?.place(resolvedLayout.arrowLeftPx, resolvedLayout.arrowTopPx)
            }
        }
    }
}

@Composable
private fun FloeHostPopoverArrowCanvas(
    arrow: FloeHostPopoverArrow,
    widthPx: Int,
    heightPx: Int,
    color: Color,
) {
    val density = LocalDensity.current
    val tag = when (arrow) {
        FloeHostPopoverArrow.RIGHT -> FloeHostPopoverTags.ArrowRight
        FloeHostPopoverArrow.UP -> FloeHostPopoverTags.ArrowUp
        FloeHostPopoverArrow.DOWN -> FloeHostPopoverTags.ArrowDown
        FloeHostPopoverArrow.NONE -> return
    }
    val widthDp = with(density) { widthPx.coerceAtLeast(1).toDp() }
    val heightDp = with(density) { heightPx.coerceAtLeast(1).toDp() }
    Canvas(
        modifier = Modifier
            .width(widthDp)
            .height(heightDp)
            .testTag(tag),
    ) {
        val path = Path().apply {
            when (arrow) {
                FloeHostPopoverArrow.RIGHT -> {
                    moveTo(0f, 0f)
                    lineTo(0f, size.height)
                    lineTo(size.width, size.height / 2f)
                }
                FloeHostPopoverArrow.UP -> {
                    moveTo(0f, size.height)
                    lineTo(size.width, size.height)
                    lineTo(size.width / 2f, 0f)
                }
                FloeHostPopoverArrow.DOWN -> {
                    moveTo(0f, 0f)
                    lineTo(size.width, 0f)
                    lineTo(size.width / 2f, size.height)
                }
                FloeHostPopoverArrow.NONE -> Unit
            }
            close()
        }
        drawPath(path, color)
    }
}

/**
 * Positions the popup from the pure resolver. The popup content size includes
 * a vertical arrow depth for trigger fallback; subtract it before replaying
 * the same content-height calculation so provider and content agree exactly.
 */
private class FloeHostPopoverPositionProvider(
    private val geometry: FloeSettingsHostGeometry,
    private val metrics: FloeHostPopoverMetrics,
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val mode = resolveFloeHostPopoverMode(geometry, metrics)
        if (mode == FloeHostPopoverMode.SUPPRESSED_COMPACT) return IntOffset.Zero
        val verticalArrowDepth = if (
            mode == FloeHostPopoverMode.TRIGGER_FALLBACK &&
            geometry.triggerBoundsPx != null
        ) {
            metrics.arrowDepthPx
        } else {
            0
        }
        val contentHeight = (popupContentSize.height - verticalArrowDepth).coerceAtLeast(1)
        val layout = resolveFloeHostPopoverLayout(geometry, metrics, contentHeight)
        return IntOffset(layout.popupLeftPx, layout.popupTopPx)
    }
}
