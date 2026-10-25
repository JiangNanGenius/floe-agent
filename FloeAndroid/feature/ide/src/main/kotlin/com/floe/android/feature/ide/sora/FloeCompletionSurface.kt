// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 *    sora-editor - the awesome code editor for Android
 *    https://github.com/Rosemoe/sora-editor
 *    Copyright (C) 2020-2024  Rosemoe
 *
 *     This library is free software; you can redistribute it and/or
 *     modify it under the terms of the GNU Lesser General Public
 *     License as published by the Free Software Foundation; either
 *     version 2.1 of the License, or (at your option) any later version.
 *
 *     This library is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *     Lesser General Public License for more details.
 *
 *     You should have received a copy of the GNU Lesser General Public
 *     License along with this library; if not, write to the Free Software
 *     Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301
 *     USA
 *
 *     Please contact Rosemoe by email 2073412493@qq.com if you need
 *     additional information or have any questions
 */
// Floe adapts the default completion layout and popup placement for bounded
// scrolling and compressed editor viewports. Upstream editor AAR is unchanged.
package com.floe.android.feature.ide.sora

import android.content.Context
import android.graphics.Outline
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.View
import android.view.ViewOutlineProvider
import android.widget.AdapterView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ProgressBar
import io.github.rosemoe.sora.widget.CodeEditor
import io.github.rosemoe.sora.widget.component.CompletionLayout
import io.github.rosemoe.sora.widget.component.EditorAutoCompletion
import io.github.rosemoe.sora.widget.schemes.EditorColorScheme

/**
 * Bounded completion surface for the pinned Sora editor 0.24.4 (device
 * evidence 2026-10-25, PID 16724 ANR):
 *
 * 1. `DefaultCompletionLayout.ensureListPositionVisible` scrolls its ListView
 *    with an UNBOUNDED `while` loop of synthetic MotionEvent drags. When the
 *    popup viewport collapses to a sub-row strip — the actual tablet case:
 *    the IDE editor is a 145px strip (compressed panel above the IME) with a
 *    3-line document, so Sora's `restY` fell to ~25px and its scroll
 *    compensation hit `scrollMaxY == 0` — the drags never advance
 *    first/lastVisiblePosition while `canScrollList(1)` stays true, pinning
 *    the main thread until the 5s input-dispatch ANR
 *    (performScrollList:166 <- ensureListPositionVisible:201).
 *
 * 2. Sora always places the popup BELOW the caret, clamped inside the editor
 *    view; in that strip the visible band was less than one row.
 *
 * The replacements here keep completion fully enabled and native-authoritative
 * edit/undo/CAS untouched: [FloeCompletionLayout] makes list placement a
 * SINGLE bounded selection step (no synthetic touches, no loop), and
 * [FloeAutoCompletion] flips the popup ABOVE the caret — bounded, caret row
 * unobstructed — only when Sora's own below-caret placement would leave a
 * sub-usable strip. All decisions live in the pure [FloeCompletionPlacement]
 * / [FloeCompletionScroll] helpers so the exact evidence geometry is a JVM
 * regression, not a device hope.
 */

/** Pure single-step list placement decision (mirrors the convergence target
 * of the Default loop — position strictly inside (first, last) — without any
 * iteration). Total: every input maps to exactly one placement. */
internal object FloeCompletionScroll {
    enum class Placement { NONE, TOP, BOTTOM }

    fun resolve(firstVisible: Int, lastVisible: Int, position: Int): Placement = when {
        position < 0 || lastVisible < firstVisible -> Placement.NONE
        position <= firstVisible -> Placement.TOP
        position >= lastVisible -> Placement.BOTTOM
        else -> Placement.NONE
    }
}

/** Pure popup placement decision for the compressed-viewport case.
 * Returns null when Sora's own below-caret geometry must stay untouched
 * (usable strip below, or nowhere to put even one full row — the honest
 * bounded result is kept; completion is never hidden by this helper). */
internal object FloeCompletionPlacement {
    data class Window(val x: Int, val y: Int, val width: Int, val height: Int)

    /** Rows of visible strip below the caret that count as usable. */
    const val MIN_VISIBLE_ROWS = 2.5f

    fun flipAboveCaret(
        editorWidth: Int,
        editorHeight: Int,
        panelX: Float,
        panelY: Float,
        rowHeight: Float,
        dpUnit: Float,
        fullWidth: Boolean,
        contentHeight: Int,
    ): Window? {
        if (rowHeight <= 0f || dpUnit <= 0f || editorWidth <= 0 || editorHeight <= 0) return null
        val minStrip = rowHeight * MIN_VISIBLE_ROWS
        val below = editorHeight - panelY
        if (below >= minStrip) return null
        // Keep the caret row itself unobstructed: the popup bottom must sit
        // at or above the caret row's top edge.
        val above = panelY - rowHeight / 2f
        if (above < rowHeight) return null
        // Sora's own width rules, recomputed from public inputs so the popup
        // never jumps horizontally between its internal reposition passes.
        val width = if (fullWidth) {
            editorWidth * 7 / 8
        } else {
            minOf(300f * dpUnit, editorWidth / 2f).toInt()
        }
        val x = if (fullWidth) (editorWidth / 8f / 2f).toInt() else panelX.toInt()
        val bounded = minOf(200f * dpUnit, above)
        val height = (if (contentHeight > 0) minOf(bounded, contentHeight.toFloat()) else bounded)
            .toInt().coerceAtLeast(1)
        val y = (above - height).toInt().coerceAtLeast(0)
        return Window(x, y, width, height)
    }
}

/**
 * The bounded replacement for `DefaultCompletionLayout`: identical chrome
 * (vertical LinearLayout, thin indeterminate progress bar with the same
 * negative margins, divider-less ListView, 8dp rounded scheme background and
 * clipped outline, item click -> [EditorAutoCompletion.select]) with a
 * single-step [ensureListPositionVisible] — one `setSelectionFromTop`, never
 * synthetic MotionEvents, never a loop, so a sub-row viewport can no longer
 * pin the main thread.
 */
internal class FloeCompletionLayout : CompletionLayout {

    private var listView: ListView? = null
    private var progressBar: ProgressBar? = null
    private var rootView: LinearLayout? = null
    private var editorAutoCompletion: EditorAutoCompletion? = null

    override fun setEditorCompletion(completion: EditorAutoCompletion) {
        editorAutoCompletion = completion
    }

    override fun inflate(context: Context): View {
        val dm = context.resources.displayMetrics
        val root = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val list = ListView(context)
        val progress = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal)
        progress.isIndeterminate = true
        rootView = root
        listView = list
        progressBar = progress
        val dip: (Float) -> Int = { TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, it, dm).toInt() }
        root.addView(progress, LinearLayout.LayoutParams(-1, dip(20f)).apply {
            topMargin = dip(-8f); bottomMargin = dip(-8f)
            leftMargin = dip(4f); rightMargin = dip(4f)
        })
        root.addView(list, LinearLayout.LayoutParams(-1, -1))
        list.dividerHeight = 0
        list.onItemClickListener = AdapterView.OnItemClickListener { _, _, position, _ ->
            // Best-effort like the Default layout (whose catch shows a raw
            // toast): a failed click-select must never crash the IDE; the
            // document truth stays with the presenter/native CAS either way.
            try {
                editorAutoCompletion?.select(position)
            } catch (_: Exception) {
            }
        }
        setLoading(true)
        return root
    }

    override fun getCompletionList(): AdapterView<*> =
        listView ?: error("FloeCompletionLayout used before inflate()")

    override fun setLoading(state: Boolean) {
        progressBar?.visibility = if (state) View.VISIBLE else View.GONE
    }

    override fun onApplyColorScheme(colorScheme: EditorColorScheme) {
        val root = rootView ?: return
        val dm = root.context.resources.displayMetrics
        val gd = GradientDrawable()
        gd.cornerRadius = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 8f, dm)
        gd.setStroke(
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 1f, dm).toInt(),
            colorScheme.getColor(EditorColorScheme.COMPLETION_WND_CORNER),
        )
        gd.setColor(colorScheme.getColor(EditorColorScheme.COMPLETION_WND_BACKGROUND))
        root.background = gd
        val corner = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 8f, dm)
        root.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setRoundRect(0, 0, view.width, view.height, corner)
            }
        }
        root.clipToOutline = true
    }

    override fun ensureListPositionVisible(position: Int, incrementPixels: Int) {
        val list = listView ?: return
        list.post {
            val view = listView ?: return@post
            if (position == 0 && incrementPixels == 0) {
                // The reset idiom, identical to the Default layout's.
                view.setSelectionFromTop(0, 0)
                return@post
            }
            when (FloeCompletionScroll.resolve(view.firstVisiblePosition, view.lastVisiblePosition, position)) {
                FloeCompletionScroll.Placement.TOP -> view.setSelectionFromTop(position, 0)
                FloeCompletionScroll.Placement.BOTTOM -> {
                    // Anchor the item's bottom edge into the (possibly
                    // sub-row) viewport; incrementPixels IS the adapter's
                    // item height per the CompletionLayout contract.
                    val item = if (incrementPixels > 0) incrementPixels else view.height
                    view.setSelectionFromTop(position, (view.height - item).coerceAtLeast(0))
                }
                FloeCompletionScroll.Placement.NONE -> Unit
            }
        }
    }
}

/**
 * [EditorAutoCompletion] with bounded IME/compressed-viewport placement,
 * installed via the supported `CodeEditor.replaceComponent` route (the old
 * component is disabled by that call; its sub-event manager stops with it).
 * Everything else — the completion pipeline, adapter, key handling, Tab/Enter
 * accept, publish/hide semantics — is inherited unchanged, so native stays
 * the only edit/undo/CAS authority.
 */
internal class FloeAutoCompletion(editor: CodeEditor) : EditorAutoCompletion(editor) {

    init {
        // Public replacement route: re-inflates the content view and
        // re-attaches the existing adapter.
        setLayout(FloeCompletionLayout())
    }

    override fun updateCompletionWindowPosition(scrollEditor: Boolean) {
        super.updateCompletionWindowPosition(scrollEditor)
        // Re-derive Sora's own below-caret anchor from public state (the
        // window fields are private), then flip ONLY when super's placement
        // left a sub-usable strip.
        val ed = getEditor()
        val dp = ed.dpUnit
        val rowHeight = ed.rowHeight.toFloat()
        val cursor = ed.cursor ?: return
        val right = ed.layout.getCharLayoutOffset(cursor.rightLine, cursor.rightColumn)
        val panelY = right[0] - ed.offsetY + rowHeight / 2f
        val panelX = ed.updateCursorAnchor() + dp * 20f
        val mode = completionWndPositionMode
        // Java statics are not inherited into Kotlin subclass scope; qualify
        // against the declaring class exactly.
        val fullWidth = (ed.width < 500 * dp && mode == EditorAutoCompletion.WINDOW_POS_MODE_AUTO) ||
            mode == EditorAutoCompletion.WINDOW_POS_MODE_FULL_WIDTH_ALWAYS
        // The adapter is unbound until its first candidate publication.
        // getCount is safe before attachment; itemHeight needs its context.
        val contentHeight = adapter?.let { a ->
            val count = a.count
            if (count > 0) a.itemHeight * count else 0
        } ?: 0
        val flip = FloeCompletionPlacement.flipAboveCaret(
            editorWidth = ed.width,
            editorHeight = ed.height,
            panelX = panelX,
            panelY = panelY,
            rowHeight = rowHeight,
            dpUnit = dp,
            fullWidth = fullWidth,
            contentHeight = contentHeight,
        ) ?: return
        // maxHeight first: publish() re-clamps with min(content, maxHeight)
        // right after this call, so the flipped height survives the pipeline.
        maxHeight = flip.height
        setLocationAbsolutely(flip.x, flip.y)
        setSize(flip.width, flip.height)
    }
}
