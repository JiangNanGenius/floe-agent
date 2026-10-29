// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.notes.ui.presentation

import com.floe.android.feature.notes.NoteElement
import com.floe.android.feature.notes.NotePage
import com.floe.android.feature.notes.NoteRect
import kotlin.math.abs

public enum class NotesResizeCorner { TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT }

public object NotesElementGeometry {
    public const val MIN_ELEMENT_SIZE: Double = 20.0

    /** Topmost element under a page-space point; later elements paint above. */
    public fun hitTest(page: NotePage, x: Double, y: Double): NoteElement? =
        page.elements.asReversed().firstOrNull { element ->
            x >= element.frame.x && x <= element.frame.x + element.frame.width &&
                y >= element.frame.y && y <= element.frame.y + element.frame.height
        }

    public fun clampToPage(frame: NoteRect, page: NotePage): NoteRect {
        val width = frame.width.coerceIn(MIN_ELEMENT_SIZE, page.width)
        val height = frame.height.coerceIn(MIN_ELEMENT_SIZE, page.height)
        val maxX = (page.width - width).coerceAtLeast(0.0)
        val maxY = (page.height - height).coerceAtLeast(0.0)
        return NoteRect(
            x = frame.x.coerceIn(0.0, maxX),
            y = frame.y.coerceIn(0.0, maxY),
            width = width,
            height = height,
        )
    }

    /**
     * Moves every selected element by the same page-space delta. Elements keep
     * their relative arrangement; each frame is clamped individually at the
     * page edge (no element escapes the saved page geometry).
     */
    public fun moveSelected(
        page: NotePage,
        selectedIDs: Set<String>,
        deltaX: Double,
        deltaY: Double,
    ): Map<String, NoteRect> {
        if (selectedIDs.isEmpty()) return emptyMap()
        return page.elements
            .filter { it.id in selectedIDs }
            .associate { element ->
                element.id to clampToPage(
                    element.frame.copy(
                        x = element.frame.x + deltaX,
                        y = element.frame.y + deltaY,
                    ),
                    page,
                )
            }
    }

    /**
     * Resizes one element from a corner. The opposite corner stays anchored;
     * the frame never crosses its minimum size or the page bounds.
     */
    public fun resize(
        page: NotePage,
        frame: NoteRect,
        corner: NotesResizeCorner,
        deltaX: Double,
        deltaY: Double,
        minSize: Double = MIN_ELEMENT_SIZE,
    ): NoteRect {
        val left = frame.x
        val top = frame.y
        val right = frame.x + frame.width
        val bottom = frame.y + frame.height
        var newLeft = left
        var newTop = top
        var newRight = right
        var newBottom = bottom
        when (corner) {
            NotesResizeCorner.TOP_LEFT -> {
                newLeft = (left + deltaX).coerceIn(0.0, right - minSize)
                newTop = (top + deltaY).coerceIn(0.0, bottom - minSize)
            }
            NotesResizeCorner.TOP_RIGHT -> {
                newRight = (right + deltaX).coerceIn(left + minSize, page.width)
                newTop = (top + deltaY).coerceIn(0.0, bottom - minSize)
            }
            NotesResizeCorner.BOTTOM_LEFT -> {
                newLeft = (left + deltaX).coerceIn(0.0, right - minSize)
                newBottom = (bottom + deltaY).coerceIn(top + minSize, page.height)
            }
            NotesResizeCorner.BOTTOM_RIGHT -> {
                newRight = (right + deltaX).coerceIn(left + minSize, page.width)
                newBottom = (bottom + deltaY).coerceIn(top + minSize, page.height)
            }
        }
        return NoteRect(newLeft, newTop, (newRight - newLeft).coerceAtLeast(minSize), (newBottom - newTop).coerceAtLeast(minSize))
    }

    /** Reorders selected elements in paint order; returns a new page. */
    public fun reorder(page: NotePage, selectedIDs: Set<String>, toFront: Boolean): NotePage {
        if (selectedIDs.isEmpty()) return page
        val selected = page.elements.filter { it.id in selectedIDs }
        if (selected.isEmpty() || selected.size == page.elements.size) return page
        val rest = page.elements.filterNot { it.id in selectedIDs }
        return page.copy(elements = if (toFront) rest + selected else selected + rest)
    }

    /** Suggests a non-overlapping starter frame for new content. */
    public fun nextInsertionFrame(page: NotePage, width: Double = 240.0, height: Double = 120.0): NoteRect {
        val bottom = page.elements.maxOfOrNull { it.frame.y + it.frame.height } ?: 40.0
        val x = ((page.width - width) / 2).coerceAtLeast(16.0)
        val y = (bottom + 20.0).coerceAtMost((page.height - height - 16.0).coerceAtLeast(16.0))
        return NoteRect(x, y, width.coerceAtMost(page.width - 32.0), height)
    }

    /** Snap a dragged frame to whole page points; keeps saved geometry stable. */
    public fun snap(frame: NoteRect): NoteRect = NoteRect(
        x = frame.x.roundHalf(),
        y = frame.y.roundHalf(),
        width = frame.width.roundHalf().coerceAtLeast(MIN_ELEMENT_SIZE),
        height = frame.height.roundHalf().coerceAtLeast(MIN_ELEMENT_SIZE),
    )

    public fun sameFrame(first: NoteRect, second: NoteRect): Boolean =
        abs(first.x - second.x) < 0.5 && abs(first.y - second.y) < 0.5 &&
            abs(first.width - second.width) < 0.5 && abs(first.height - second.height) < 0.5

    private fun Double.roundHalf(): Double = kotlin.math.round(this * 2.0) / 2.0
}
