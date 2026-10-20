// SPDX-License-Identifier: MPL-2.0
//
// Host geometry for Settings-owned popovers.
//
// COORDINATE CONVENTION (single source of truth for this file):
//  - Every Rect and inset is in *window pixels*, origin at the top-left of the
//    Compose window, x to the right, y down. This is exactly the coordinate
//    space returned by Modifier.onGloballyPositioned { it.boundsInWindow() }
//    and consumed by a Popup in the same window.
//  - Dp is a measurement input only: the Settings host converts its actual
//    Dp bounds with LocalDensity once, then publishes pixels here. Popover
//    code never re-derives a device width, a fixed "320dp column" origin or a
//    screen coordinate from a model value.
//  - `safeInsetsPx` and `imeBottomInsetPx` are window insets. IME is kept
//    separate from the navigation-bar portion of safeDrawing so the resolver
//    does not subtract the same pixels twice.
//
// These types carry no layout side effects and no business state. They are a
// measured presentation snapshot supplied by the actual Settings host (and,
// for the standalone provider component fixture, by that host's own measured
// two-pane harness).

package com.floe.android.design

import androidx.compose.runtime.Immutable
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Window-pixel insets; all edges are non-negative. */
@Immutable
data class FloeWindowInsetsPx(
    val leftPx: Int = 0,
    val topPx: Int = 0,
    val rightPx: Int = 0,
    val bottomPx: Int = 0,
) {
    init {
        require(leftPx >= 0 && topPx >= 0 && rightPx >= 0 && bottomPx >= 0) {
            "window insets must be non-negative: $this"
        }
    }

    companion object {
        val Zero = FloeWindowInsetsPx()
    }
}

/**
 * Measured Settings host snapshot for a category-boundary popover.
 *
 * [categoryPaneBoundsPx] is the real left Settings column (its right edge is
 * the category boundary in the native iPad capture). [detailPaneBoundsPx] is
 * the real provider detail column behind it. [selectedCategoryRowBoundsPx] is
 * the measured selected Settings category row (the native reference row);
 * [selectedProviderRowBoundsPx] is an optional real provider-row anchor when a
 * host has one. Purpose-add has no selected provider row, so the actual host
 * supplies the selected category row and this resolver uses it as the native
 * vertical reference. A provider row, when genuinely measured, wins.
 *
 * [triggerBoundsPx] is the measured visible trigger (the provider + control).
 * It is merged by ProviderListPage, which owns the trigger, not by Settings.
 */
@Immutable
data class FloeSettingsHostGeometry(
    val windowBoundsPx: Rect,
    val categoryPaneBoundsPx: Rect? = null,
    val detailPaneBoundsPx: Rect? = null,
    val selectedCategoryRowBoundsPx: Rect? = null,
    val selectedProviderRowBoundsPx: Rect? = null,
    val triggerBoundsPx: Rect? = null,
    val safeInsetsPx: FloeWindowInsetsPx = FloeWindowInsetsPx.Zero,
    val imeBottomInsetPx: Int = 0,
    val wideLayout: Boolean,
    val categoryPaneVisible: Boolean,
    val density: Float = 1f,
    val fontScale: Float = 1f,
) {
    init {
        require(imeBottomInsetPx >= 0) { "imeBottomInsetPx must be non-negative" }
        require(density > 0f) { "density must be positive" }
        require(fontScale > 0f) { "fontScale must be positive" }
    }

    /**
     * The window minus system bars and IME. If a transient measurement makes
     * this rectangle empty, the raw window is retained so callers still have a
     * bounded placement instead of a zero-size popup.
     */
    val safeWindowBoundsPx: Rect
        get() {
            val left = windowBoundsPx.left + safeInsetsPx.leftPx
            val top = windowBoundsPx.top + safeInsetsPx.topPx
            val right = windowBoundsPx.right - safeInsetsPx.rightPx
            val bottom = windowBoundsPx.bottom - safeInsetsPx.bottomPx - imeBottomInsetPx
            return if (right > left && bottom > top) {
                Rect(left, top, right, bottom)
            } else {
                windowBoundsPx
            }
        }

    /** Real vertical reference: an actual provider row wins over the category row. */
    internal val verticalAnchorBoundsPx: Rect?
        get() = selectedProviderRowBoundsPx ?: selectedCategoryRowBoundsPx
}

/** Which surface the host geometry resolves to. */
enum class FloeHostPopoverMode {
    /** Wide Settings category pane is actually visible: sit inside it. */
    CATEGORY_BOUNDARY,

    /** Wide but category collapsed/absent: use the measured visible trigger. */
    TRIGGER_FALLBACK,

    /** Compact windows keep the bottom action sheet; no popup is rendered. */
    SUPPRESSED_COMPACT,
}

/** Arrow orientation. RIGHT is only used by the category-boundary mode. */
enum class FloeHostPopoverArrow { NONE, RIGHT, UP, DOWN }

/** Density-resolved popover metrics in window pixels. */
@Immutable
data class FloeHostPopoverMetrics(
    val edgeInsetPx: Int = 16,
    val arrowWidthPx: Int = 10,
    val arrowBasePx: Int = 18,
    val arrowDepthPx: Int = 10,
    val minWidthPx: Int = 220,
    val preferredWidthPx: Int = 320,
    val verticalMarginPx: Int = 12,
    val triggerGapPx: Int = 8,
    val cornerRadiusPx: Int = 24,
    val maxHeightFraction: Float = 0.9f,
) {
    init {
        require(edgeInsetPx >= 0) { "edgeInsetPx must be non-negative" }
        require(arrowWidthPx > 0 && arrowBasePx > 0 && arrowDepthPx > 0) {
            "arrow metrics must be positive"
        }
        require(minWidthPx > 0 && preferredWidthPx >= minWidthPx) {
            "width metrics must be positive and preferred >= min"
        }
        require(verticalMarginPx >= 0 && triggerGapPx >= 0 && cornerRadiusPx >= 0) {
            "spacing metrics must be non-negative"
        }
        require(maxHeightFraction in 0.1f..1f) { "maxHeightFraction must be in 0.1..1" }
    }

    companion object {
        /** Convert the single set of Dp design values at the measurement boundary. */
        fun fromDensity(density: Density): FloeHostPopoverMetrics = with(density) {
            FloeHostPopoverMetrics(
                edgeInsetPx = 16.dp.roundToPx(),
                arrowWidthPx = 10.dp.roundToPx(),
                arrowBasePx = 18.dp.roundToPx(),
                arrowDepthPx = 10.dp.roundToPx(),
                minWidthPx = 220.dp.roundToPx(),
                preferredWidthPx = 320.dp.roundToPx(),
                verticalMarginPx = 12.dp.roundToPx(),
                triggerGapPx = 8.dp.roundToPx(),
                cornerRadiusPx = 24.dp.roundToPx(),
            )
        }
    }
}

/**
 * Resolved popup geometry. All positions are window pixels except the
 * `*OffsetPx` fields, which are popup-local placement offsets, and the arrow
 * fields, which are popup-local.
 */
@Immutable
data class FloeHostPopoverLayout(
    val mode: FloeHostPopoverMode,
    val popupLeftPx: Int,
    val popupTopPx: Int,
    val popupWidthPx: Int,
    val popupHeightPx: Int,
    val bodyLeftPx: Int,
    val bodyTopPx: Int,
    val bodyWidthPx: Int,
    val bodyHeightPx: Int,
    val bodyOffsetXPx: Int,
    val bodyOffsetYPx: Int,
    val arrow: FloeHostPopoverArrow,
    val arrowLeftPx: Int,
    val arrowTopPx: Int,
    val arrowWidthPx: Int,
    val arrowHeightPx: Int,
    val arrowCenterXPx: Int,
    val arrowCenterYPx: Int,
    val maxBodyHeightPx: Int,
    val contentScrolls: Boolean,
)

/**
 * Whether the host geometry can use the real category boundary. Boundary mode
 * requires all of: wide layout, a visible category pane, a measured category
 * pane wide enough for the minimum card plus its insets/arrow, and a measured
 * vertical reference row that still intersects the pane. A scrolled or
 * partially clipped row remains valid (the card and arrow clamp); a row that
 * has left the pane falls back to the actual trigger instead of pinning the
 * popover to a phantom category location.
 */
fun resolveFloeHostPopoverMode(
    geometry: FloeSettingsHostGeometry,
    metrics: FloeHostPopoverMetrics,
): FloeHostPopoverMode {
    if (!geometry.wideLayout) return FloeHostPopoverMode.SUPPRESSED_COMPACT
    val category = geometry.categoryPaneBoundsPx ?: return FloeHostPopoverMode.TRIGGER_FALLBACK
    if (!geometry.categoryPaneVisible) return FloeHostPopoverMode.TRIGGER_FALLBACK
    val safeCategory = category.intersectWith(geometry.safeWindowBoundsPx)
        ?: return FloeHostPopoverMode.TRIGGER_FALLBACK
    val minimumCategoryWidth = metrics.edgeInsetPx * 2 + metrics.arrowWidthPx + metrics.minWidthPx
    if (safeCategory.width.roundToInt() < minimumCategoryWidth) {
        return FloeHostPopoverMode.TRIGGER_FALLBACK
    }
    val anchor = geometry.verticalAnchorBoundsPx
        ?: return FloeHostPopoverMode.TRIGGER_FALLBACK
    if (!anchor.intersectsVertically(safeCategory)) {
        return FloeHostPopoverMode.TRIGGER_FALLBACK
    }
    return FloeHostPopoverMode.CATEGORY_BOUNDARY
}

/** Width of the content body (excluding a right arrow) in window pixels. */
fun resolveFloeHostPopoverWidthPx(
    geometry: FloeSettingsHostGeometry,
    metrics: FloeHostPopoverMetrics,
): Int {
    val safe = geometry.safeWindowBoundsPx
    val safeWidth = safe.width.roundToInt().coerceAtLeast(1)
    val available = (safeWidth - metrics.edgeInsetPx * 2).coerceAtLeast(1)
    val mode = resolveFloeHostPopoverMode(geometry, metrics)
    if (mode == FloeHostPopoverMode.SUPPRESSED_COMPACT) return 0
    if (mode == FloeHostPopoverMode.CATEGORY_BOUNDARY) {
        val category = geometry.categoryPaneBoundsPx
            ?.intersectWith(safe)
            ?: return minOf(metrics.preferredWidthPx, available)
        val byCategory = (category.width.roundToInt() -
            metrics.edgeInsetPx * 2 - metrics.arrowWidthPx).coerceAtLeast(1)
        val desired = minOf(metrics.preferredWidthPx, byCategory)
        return desired.coerceIn(1, available)
    }
    return minOf(metrics.preferredWidthPx, available).coerceAtLeast(1)
}

/** Maximum content height before the popover body starts scrolling. */
fun resolveFloeHostPopoverMaxContentHeightPx(
    geometry: FloeSettingsHostGeometry,
    metrics: FloeHostPopoverMetrics,
): Int {
    val safe = geometry.safeWindowBoundsPx
    val windowCap = (safe.height * metrics.maxHeightFraction).roundToInt().coerceAtLeast(1)
    val mode = resolveFloeHostPopoverMode(geometry, metrics)
    if (mode == FloeHostPopoverMode.CATEGORY_BOUNDARY) {
        val category = geometry.categoryPaneBoundsPx?.intersectWith(safe)
            ?: return windowCap
        val inPane = (category.height.roundToInt() - metrics.verticalMarginPx * 2)
            .coerceAtLeast(1)
        return minOf(windowCap, inPane)
    }
    val available = (safe.height.roundToInt() - metrics.verticalMarginPx * 2 -
        metrics.arrowDepthPx).coerceAtLeast(1)
    return minOf(windowCap, available)
}

/**
 * Pure layout resolver. [measuredContentHeightPx] is the actual measured
 * content height at the width returned by [resolveFloeHostPopoverWidthPx].
 * The card height is that content height (bounded by the max above); there is
 * no fixed 396dp body and no phantom blank area below the three role actions.
 */
fun resolveFloeHostPopoverLayout(
    geometry: FloeSettingsHostGeometry,
    metrics: FloeHostPopoverMetrics,
    measuredContentHeightPx: Int,
): FloeHostPopoverLayout {
    val mode = resolveFloeHostPopoverMode(geometry, metrics)
    if (mode == FloeHostPopoverMode.SUPPRESSED_COMPACT) {
        return FloeHostPopoverLayout(
            mode = mode,
            popupLeftPx = 0,
            popupTopPx = 0,
            popupWidthPx = 0,
            popupHeightPx = 0,
            bodyLeftPx = 0,
            bodyTopPx = 0,
            bodyWidthPx = 0,
            bodyHeightPx = 0,
            bodyOffsetXPx = 0,
            bodyOffsetYPx = 0,
            arrow = FloeHostPopoverArrow.NONE,
            arrowLeftPx = 0,
            arrowTopPx = 0,
            arrowWidthPx = 0,
            arrowHeightPx = 0,
            arrowCenterXPx = 0,
            arrowCenterYPx = 0,
            maxBodyHeightPx = 0,
            contentScrolls = false,
        )
    }
    val bodyWidth = resolveFloeHostPopoverWidthPx(geometry, metrics).coerceAtLeast(1)
    val maxHeight = resolveFloeHostPopoverMaxContentHeightPx(geometry, metrics).coerceAtLeast(1)
    val measured = measuredContentHeightPx.coerceAtLeast(1)
    val bodyHeight = measured.coerceAtMost(maxHeight)
    val contentScrolls = measured > maxHeight
    return if (mode == FloeHostPopoverMode.CATEGORY_BOUNDARY) {
        resolveCategoryBoundary(
            geometry = geometry,
            metrics = metrics,
            bodyWidth = bodyWidth,
            bodyHeight = bodyHeight,
            maxHeight = maxHeight,
            contentScrolls = contentScrolls,
        )
    } else {
        resolveTriggerFallback(
            geometry = geometry,
            metrics = metrics,
            bodyWidth = bodyWidth,
            bodyHeight = bodyHeight,
            maxHeight = maxHeight,
            contentScrolls = contentScrolls,
        )
    }
}

private fun resolveCategoryBoundary(
    geometry: FloeSettingsHostGeometry,
    metrics: FloeHostPopoverMetrics,
    bodyWidth: Int,
    bodyHeight: Int,
    maxHeight: Int,
    contentScrolls: Boolean,
): FloeHostPopoverLayout {
    val safe = geometry.safeWindowBoundsPx
    val category = geometry.categoryPaneBoundsPx
        ?.intersectWith(safe)
        ?: return resolveTriggerFallback(
            geometry, metrics, bodyWidth, bodyHeight, maxHeight, contentScrolls,
        )
    val anchor = geometry.verticalAnchorBoundsPx
        ?: return resolveTriggerFallback(
            geometry, metrics, bodyWidth, bodyHeight, maxHeight, contentScrolls,
        )

    val minTop = (category.top + metrics.verticalMarginPx).roundToInt()
    val maxTop = (category.bottom - metrics.verticalMarginPx - bodyHeight)
        .roundToInt().coerceAtLeast(minTop)
    val rawTop = (anchor.center.y - bodyHeight / 2f).roundToInt()
    val bodyTop = rawTop.coerceIn(minTop, maxTop)
    val arrowMinY = minOf(metrics.cornerRadiusPx, bodyHeight / 2)
    val arrowMaxY = maxOf(arrowMinY, bodyHeight - metrics.cornerRadiusPx)
    val arrowCenterY = (anchor.center.y - bodyTop).roundToInt().coerceIn(arrowMinY, arrowMaxY)
    val arrowVisible = bodyHeight >= metrics.arrowBasePx && bodyWidth >= metrics.arrowBasePx
    val arrow = if (arrowVisible) FloeHostPopoverArrow.RIGHT else FloeHostPopoverArrow.NONE
    val arrowWidth = if (arrowVisible) metrics.arrowWidthPx else 0
    val bodyLeft = (category.right - metrics.edgeInsetPx - arrowWidth - bodyWidth)
        .roundToInt()
    val popupWidth = bodyWidth + arrowWidth
    val popupHeight = bodyHeight
    val arrowLeft = bodyWidth
    val arrowTop = if (arrowVisible) {
        arrowCenterY - metrics.arrowBasePx / 2
    } else {
        0
    }
    return FloeHostPopoverLayout(
        mode = FloeHostPopoverMode.CATEGORY_BOUNDARY,
        popupLeftPx = bodyLeft,
        popupTopPx = bodyTop,
        popupWidthPx = popupWidth,
        popupHeightPx = popupHeight,
        bodyLeftPx = bodyLeft,
        bodyTopPx = bodyTop,
        bodyWidthPx = bodyWidth,
        bodyHeightPx = bodyHeight,
        bodyOffsetXPx = 0,
        bodyOffsetYPx = 0,
        arrow = arrow,
        arrowLeftPx = arrowLeft,
        arrowTopPx = arrowTop,
        arrowWidthPx = if (arrowVisible) metrics.arrowWidthPx else 0,
        arrowHeightPx = if (arrowVisible) metrics.arrowBasePx else 0,
        arrowCenterXPx = if (arrowVisible) bodyWidth + metrics.arrowWidthPx / 2 else 0,
        arrowCenterYPx = if (arrowVisible) arrowCenterY else 0,
        maxBodyHeightPx = maxHeight,
        contentScrolls = contentScrolls,
    )
}

private fun resolveTriggerFallback(
    geometry: FloeSettingsHostGeometry,
    metrics: FloeHostPopoverMetrics,
    bodyWidth: Int,
    bodyHeight: Int,
    maxHeight: Int,
    contentScrolls: Boolean,
): FloeHostPopoverLayout {
    val safe = geometry.safeWindowBoundsPx
    val trigger = geometry.triggerBoundsPx
    val arrow = if (trigger == null) FloeHostPopoverArrow.NONE else FloeHostPopoverArrow.UP
    val arrowExtent = if (arrow == FloeHostPopoverArrow.NONE) 0 else metrics.arrowDepthPx
    val cardExtent = bodyHeight + arrowExtent
    val minTop = (safe.top + metrics.verticalMarginPx).roundToInt()
    val maxTop = (safe.bottom - metrics.verticalMarginPx - cardExtent)
        .roundToInt().coerceAtLeast(minTop)
    val anchorCenterX = trigger?.center?.x ?: safe.center.x
    val gap = if (trigger == null) 0 else metrics.triggerGapPx
    val belowTop = trigger?.bottom?.plus(gap) ?: (safe.center.y - cardExtent / 2f)
    val aboveTop = trigger?.top?.minus(gap + cardExtent) ?: belowTop
    val fitsBelow = belowTop + cardExtent <= safe.bottom - metrics.verticalMarginPx
    val fitsAbove = aboveTop >= safe.top + metrics.verticalMarginPx
    val placeBelow = when {
        trigger == null -> true
        fitsBelow && !fitsAbove -> true
        !fitsBelow && fitsAbove -> false
        fitsBelow && fitsAbove -> true
        else -> (safe.bottom - belowTop) >= (aboveTop - safe.top)
    }
    val rawTop = if (placeBelow) belowTop else aboveTop
    val popupTop = rawTop.roundToInt().coerceIn(minTop, maxTop)
    val finalArrow = when {
        arrow == FloeHostPopoverArrow.NONE -> FloeHostPopoverArrow.NONE
        placeBelow -> FloeHostPopoverArrow.UP
        else -> FloeHostPopoverArrow.DOWN
    }
    val bodyTop = if (finalArrow == FloeHostPopoverArrow.UP) popupTop + metrics.arrowDepthPx else popupTop
    val bodyLeft = (anchorCenterX - bodyWidth / 2f).roundToInt()
        .coerceIn(
            (safe.left + metrics.edgeInsetPx).roundToInt(),
            (safe.right - metrics.edgeInsetPx - bodyWidth).roundToInt()
                .coerceAtLeast((safe.left + metrics.edgeInsetPx).roundToInt()),
        )
    val arrowMinX = minOf(metrics.cornerRadiusPx, bodyWidth / 2)
    val arrowMaxX = maxOf(arrowMinX, bodyWidth - metrics.cornerRadiusPx)
    val arrowCenterX = (anchorCenterX - bodyLeft).roundToInt().coerceIn(arrowMinX, arrowMaxX)
    val arrowLeft = when (finalArrow) {
        FloeHostPopoverArrow.UP, FloeHostPopoverArrow.DOWN ->
            arrowCenterX - metrics.arrowBasePx / 2
        else -> 0
    }
    val arrowTop = when (finalArrow) {
        FloeHostPopoverArrow.UP -> 0
        FloeHostPopoverArrow.DOWN -> bodyHeight
        else -> 0
    }
    val arrowWidth = when (finalArrow) {
        FloeHostPopoverArrow.UP, FloeHostPopoverArrow.DOWN -> metrics.arrowBasePx
        else -> 0
    }
    val arrowHeight = when (finalArrow) {
        FloeHostPopoverArrow.UP, FloeHostPopoverArrow.DOWN -> metrics.arrowDepthPx
        else -> 0
    }
    val popupHeight = bodyHeight + (if (finalArrow == FloeHostPopoverArrow.NONE) 0 else metrics.arrowDepthPx)
    return FloeHostPopoverLayout(
        mode = FloeHostPopoverMode.TRIGGER_FALLBACK,
        popupLeftPx = bodyLeft,
        popupTopPx = popupTop,
        popupWidthPx = bodyWidth,
        popupHeightPx = popupHeight,
        bodyLeftPx = bodyLeft,
        bodyTopPx = bodyTop,
        bodyWidthPx = bodyWidth,
        bodyHeightPx = bodyHeight,
        bodyOffsetXPx = 0,
        bodyOffsetYPx = bodyTop - popupTop,
        arrow = finalArrow,
        arrowLeftPx = arrowLeft,
        arrowTopPx = arrowTop,
        arrowWidthPx = arrowWidth,
        arrowHeightPx = arrowHeight,
        arrowCenterXPx = if (finalArrow == FloeHostPopoverArrow.NONE) 0 else arrowCenterX,
        arrowCenterYPx = when (finalArrow) {
            FloeHostPopoverArrow.UP -> metrics.arrowDepthPx / 2
            FloeHostPopoverArrow.DOWN -> bodyHeight + metrics.arrowDepthPx / 2
            else -> 0
        },
        maxBodyHeightPx = maxHeight,
        contentScrolls = contentScrolls,
    )
}

private fun Rect.intersectsVertically(other: Rect): Boolean =
    bottom > other.top && top < other.bottom

private fun Rect.intersectWith(other: Rect): Rect? {
    val left = maxOf(this.left, other.left)
    val top = maxOf(this.top, other.top)
    val right = minOf(this.right, other.right)
    val bottom = minOf(this.bottom, other.bottom)
    return if (right > left && bottom > top) Rect(left, top, right, bottom) else null
}
