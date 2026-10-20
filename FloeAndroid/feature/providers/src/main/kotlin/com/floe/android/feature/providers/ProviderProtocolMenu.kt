// SPDX-License-Identifier: MPL-2.0
//
// Compact floating protocol menu (⇄ ProviderEditorView.swift Picker menu).
//
// The native picker menu is a small right-aligned floating menu (~240-280dp)
// that overlaps/sits above the row; it is NOT an inline expanded form and NOT
// a 420dp supplier picker card. This is a provider-private popup primitive:
// it measures the actual row bounds, right-aligns the menu to the row's
// trailing edge, prefers the space above (with a small overlap), and clamps
// every edge to the real window. No global screen pixels are used.

package com.floe.android.feature.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties
import com.floe.android.design.Floe
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeLayout
import com.floe.android.design.FloeText
import com.floe.android.design.IconGlyph
import kotlin.math.roundToInt

/** One protocol option in the compact floating menu. */
internal data class ProviderProtocolOption(val key: String, val label: String)

/** Resolved popup position from the actual row/window geometry. */
internal data class ProviderProtocolMenuPosition(
    val x: Int,
    val y: Int,
    val widthPx: Int,
    val placeAbove: Boolean,
)

/**
 * Right-aligned popup placement policy. The menu's trailing edge follows the
 * actual row/value trailing edge, preferring the space above with a small
 * overlap; when above cannot hold the menu it flips below (also overlapped).
 * All edges are clamped into the live window with the supplied margins.
 */
internal fun resolveProviderProtocolMenuPosition(
    anchor: Rect,
    windowWidthPx: Int,
    windowHeightPx: Int,
    popupWidthPx: Int,
    popupHeightPx: Int,
    horizontalMarginPx: Int,
    verticalMarginPx: Int,
    overlapPx: Int,
): ProviderProtocolMenuPosition {
    val safeWindowWidth = windowWidthPx.coerceAtLeast(1)
    val safeWindowHeight = windowHeightPx.coerceAtLeast(1)
    val availableWidth =
        (safeWindowWidth - horizontalMarginPx * 2).coerceAtLeast(1)
    val widthPx = popupWidthPx.coerceIn(1, availableWidth)
    val popupHeight = popupHeightPx.coerceAtLeast(1)
    val maxX = (safeWindowWidth - horizontalMarginPx - widthPx)
        .coerceAtLeast(horizontalMarginPx)
    val x = (anchor.right.roundToInt() - widthPx)
        .coerceIn(horizontalMarginPx, maxX)

    val spaceAbove =
        (anchor.top - verticalMarginPx - overlapPx).coerceAtLeast(0f)
    val spaceBelow =
        (safeWindowHeight - anchor.bottom - verticalMarginPx + overlapPx)
            .coerceAtLeast(0f)
    val placeAbove = when {
        spaceAbove >= popupHeight -> true
        spaceBelow >= popupHeight -> false
        else -> spaceAbove >= spaceBelow
    }
    val rawY = if (placeAbove) {
        anchor.top.roundToInt() - popupHeight + overlapPx
    } else {
        anchor.bottom.roundToInt() - overlapPx
    }
    val maxY = (safeWindowHeight - verticalMarginPx - popupHeight)
        .coerceAtLeast(verticalMarginPx)
    val y = rawY.coerceIn(verticalMarginPx, maxY)
    return ProviderProtocolMenuPosition(
        x = x,
        y = y,
        widthPx = widthPx,
        placeAbove = placeAbove,
    )
}

private class ProviderProtocolMenuPositionProvider(
    private val anchor: Rect,
    private val horizontalMarginPx: Int,
    private val verticalMarginPx: Int,
    private val overlapPx: Int,
) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val position = resolveProviderProtocolMenuPosition(
            anchor = anchor,
            windowWidthPx = windowSize.width,
            windowHeightPx = windowSize.height,
            popupWidthPx = popupContentSize.width,
            popupHeightPx = popupContentSize.height,
            horizontalMarginPx = horizontalMarginPx,
            verticalMarginPx = verticalMarginPx,
            overlapPx = overlapPx,
        )
        return IntOffset(position.x, position.y)
    }
}

/**
 * Compact floating protocol menu: ~272dp wide (clamped to the live window),
 * selected checkmark leading, 48dp rows, outside-tap/back dismissal. The
 * parent editor layout is untouched: this is a separate popup window.
 */
@Composable
internal fun ProviderProtocolMenuPopup(
    anchorBounds: Rect,
    options: List<ProviderProtocolOption>,
    selectedKey: String,
    onSelect: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val density = LocalDensity.current
    val windowInfo = LocalWindowInfo.current
    val windowWidthDp = with(density) { windowInfo.containerSize.width.toDp() }
    val maxMenuWidth = (windowWidthDp - 32.dp).coerceAtLeast(1.dp)
    // Native source measurement: a compact menu, not the 420dp supplier card.
    val menuWidth = 272.dp.coerceAtMost(maxMenuWidth)
    val metrics = remember(density) {
        ProviderProtocolMenuMetrics(
            horizontalMarginPx = with(density) { 16.dp.roundToPx() },
            verticalMarginPx = with(density) { 12.dp.roundToPx() },
            overlapPx = with(density) { 6.dp.roundToPx() },
        )
    }
    val positionProvider = remember(anchorBounds, metrics) {
        ProviderProtocolMenuPositionProvider(
            anchor = anchorBounds,
            horizontalMarginPx = metrics.horizontalMarginPx,
            verticalMarginPx = metrics.verticalMarginPx,
            overlapPx = metrics.overlapPx,
        )
    }
    val shape = RoundedCornerShape(FloeLayout.BubbleCorner)
    Popup(
        popupPositionProvider = positionProvider,
        onDismissRequest = onDismiss,
        properties = PopupProperties(
            focusable = true,
            dismissOnBackPress = true,
            dismissOnClickOutside = true,
            clippingEnabled = false,
        ),
    ) {
        Column(
            modifier = Modifier
                .width(menuWidth)
                .testTag("provider.protocolMenu")
                .background(Floe.colors.sectionCardSurface, shape)
                .border(0.5.dp, Floe.colors.chromeHairline, shape)
                .padding(vertical = 4.dp),
        ) {
            options.forEach { option ->
                val isSelected = option.key == selectedKey
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = FloeLayout.MinimumTarget)
                        .clickable(role = Role.Button) { onSelect(option.key) }
                        .semantics { selected = isSelected }
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                        .testTag("provider.protocolOption.${option.key}"),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    // Selected checkmark leads the label; an equally sized
                    // empty slot keeps every label aligned.
                    Box(
                        modifier = Modifier.size(18.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        if (isSelected) {
                            IconGlyph(FloeIcons.Checkmark, Floe.colors.accent, 18.dp)
                        }
                    }
                    FloeText(
                        option.label,
                        style = Floe.typography.body,
                        color = Floe.colors.label,
                        modifier = Modifier.weight(1f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

private data class ProviderProtocolMenuMetrics(
    val horizontalMarginPx: Int,
    val verticalMarginPx: Int,
    val overlapPx: Int,
)
