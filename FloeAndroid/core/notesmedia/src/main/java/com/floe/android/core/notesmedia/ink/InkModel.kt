// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import com.floe.android.core.notesmedia.media.InkFormat
import java.io.ByteArrayOutputStream
import java.util.ArrayDeque

/**
 * Paper-space geometry for one Notes page.
 *
 * Ink is stored in DISPLAYED page points (origin top-left, x right, y down),
 * identical to [com.floe.android.core.notesmedia.pdf.PdfPageBox] displayed
 * space. That is what makes a stroke drawn over a PDF page land in the same
 * place at every zoom/rotation: the editor only changes the view transform,
 * never the stored coordinates.
 *
 * [pageKey] is the Notes page identity owned by the caller (it is opaque here;
 * this module never derives a path from it).
 */
data class InkPageGeometry(
    val pageKey: String,
    val widthPt: Float,
    val heightPt: Float,
) {
    init {
        require(pageKey.isNotEmpty() && pageKey.length <= InkFormat.MAX_STRING_CHARS) { "Invalid ink page key" }
        require(widthPt.isFinite() && heightPt.isFinite()) { "Page geometry must be finite" }
        require(widthPt in 1f..InkFormat.MAX_PAGE_POINTS && heightPt in 1f..InkFormat.MAX_PAGE_POINTS) {
            "Page geometry outside the module bounds"
        }
    }

    val area: Float get() = widthPt * heightPt

    fun contains(x: Float, y: Float): Boolean = x in 0f..widthPt && y in 0f..heightPt
}

/** Axis-aligned box in paper points. */
data class InkBox(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float,
) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top
    val isValid: Boolean
        get() = left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite() &&
            right >= left && bottom >= top

    fun union(other: InkBox): InkBox = InkBox(
        minOf(left, other.left),
        minOf(top, other.top),
        maxOf(right, other.right),
        maxOf(bottom, other.bottom),
    )

    fun expand(by: Float): InkBox = InkBox(left - by, top - by, right + by, bottom + by)

    fun intersects(other: InkBox): Boolean =
        right >= other.left && left <= other.right && bottom >= other.top && top <= other.bottom

    fun contains(x: Float, y: Float): Boolean = x in left..right && y in top..bottom

    companion object {
        fun ofPoints(x0: Float, y0: Float, x1: Float, y1: Float): InkBox =
            InkBox(minOf(x0, x1), minOf(y0, y1), maxOf(x0, x1), maxOf(y0, y1))

        fun around(x: Float, y: Float, radius: Float): InkBox =
            InkBox(x - radius, y - radius, x + radius, y + radius)

        val EMPTY = InkBox(0f, 0f, 0f, 0f)
    }
}

/** 2x3 affine transform in paper space (x' = a*x + c*y + e, y' = b*x + d*y + f). */
data class InkAffine(
    val a: Float = 1f,
    val b: Float = 0f,
    val c: Float = 0f,
    val d: Float = 1f,
    val e: Float = 0f,
    val f: Float = 0f,
) {
    val isIdentity: Boolean
        get() = a == 1f && b == 0f && c == 0f && d == 1f && e == 0f && f == 0f

    val isFinite: Boolean get() = a.isFinite() && b.isFinite() && c.isFinite() && d.isFinite() && e.isFinite() && f.isFinite()

    fun mapX(x: Float, y: Float): Float = a * x + c * y + e
    fun mapY(x: Float, y: Float): Float = b * x + d * y + f

    /** `this` followed by [next]. */
    fun then(next: InkAffine): InkAffine = InkAffine(
        a = next.a * a + next.c * b,
        b = next.b * a + next.d * b,
        c = next.a * c + next.c * d,
        d = next.b * c + next.d * d,
        e = next.a * e + next.c * f + next.e,
        f = next.b * e + next.d * f + next.f,
    )

    fun invertOrNull(): InkAffine? {
        val det = a * d - b * c
        if (!det.isFinite() || kotlin.math.abs(det) < 1e-6f) return null
        val inv = 1f / det
        return InkAffine(
            a = d * inv,
            b = -b * inv,
            c = -c * inv,
            d = a * inv,
            e = (c * f - d * e) * inv,
            f = (b * e - a * f) * inv,
        )
    }

    /** Approximate uniform scale factor of this transform (for tolerance mapping). */
    fun approximateScale(): Float {
        val sx = kotlin.math.hypot(a.toDouble(), b.toDouble()).toFloat()
        val sy = kotlin.math.hypot(c.toDouble(), d.toDouble()).toFloat()
        return (sx + sy) / 2f
    }

    fun mapBox(box: InkBox): InkBox {
        val xs = floatArrayOf(
            mapX(box.left, box.top), mapX(box.right, box.top),
            mapX(box.left, box.bottom), mapX(box.right, box.bottom),
        )
        val ys = floatArrayOf(
            mapY(box.left, box.top), mapY(box.right, box.top),
            mapY(box.left, box.bottom), mapY(box.right, box.bottom),
        )
        return InkBox(xs.min(), ys.min(), xs.max(), ys.max())
    }

    companion object {
        val IDENTITY = InkAffine()

        fun translation(dx: Float, dy: Float): InkAffine = InkAffine(e = dx, f = dy)

        fun scale(sx: Float, sy: Float): InkAffine = InkAffine(a = sx, d = sy)
    }
}

/** Editable stroke tools. ERASER is a gesture, never a persisted stroke. */
enum class InkTool { PEN, HIGHLIGHTER }

/**
 * Stable brush identity. `familyId` maps to an androidx.ink stock BrushFamily in
 * [InkBrushCatalog]; colour/width are the user's parameters. Storing the family
 * id (not a native pointer or index) is what keeps documents readable across
 * process restarts and library updates.
 */
data class InkBrushSpec(
    val familyId: String,
    val colorArgb: Int,
    val widthPt: Float,
) {
    init {
        require(familyId in FAMILY_IDS) { "Unknown ink brush family" }
        require(widthPt.isFinite() && widthPt in MIN_WIDTH_PT..MAX_WIDTH_PT) { "Brush width out of range" }
    }

    val tool: InkTool
        get() = if (familyId == FAMILY_HIGHLIGHTER) InkTool.HIGHLIGHTER else InkTool.PEN

    companion object {
        const val FAMILY_PEN: String = "pen"
        const val FAMILY_HIGHLIGHTER: String = "highlighter"
        val FAMILY_IDS: Set<String> = setOf(FAMILY_PEN, FAMILY_HIGHLIGHTER)

        const val MIN_WIDTH_PT: Float = 0.25f
        const val MAX_WIDTH_PT: Float = 96f
        const val DEFAULT_PEN_WIDTH_PT: Float = 2f
        const val DEFAULT_HIGHLIGHTER_WIDTH_PT: Float = 14f

        fun pen(colorArgb: Int, widthPt: Float = DEFAULT_PEN_WIDTH_PT): InkBrushSpec {
            val width = widthPt.coerceIn(MIN_WIDTH_PT, MAX_WIDTH_PT)
            return InkBrushSpec(FAMILY_PEN, colorArgb, width)
        }

        fun highlighter(colorArgb: Int, widthPt: Float = DEFAULT_HIGHLIGHTER_WIDTH_PT): InkBrushSpec {
            val width = widthPt.coerceIn(MIN_WIDTH_PT, MAX_WIDTH_PT)
            // Highlighter ink is translucent by convention; keep a floor on alpha
            // so a fully opaque highlighter cannot hide document text.
            val amber = colorArgb and 0x00FFFFFF or (0x66000000)
            return InkBrushSpec(FAMILY_HIGHLIGHTER, amber, width)
        }
    }
}

/**
 * One committed stroke. [inputs] are the encoded androidx.ink StrokeInputBatch
 * bytes (format tagged by [inputFormat]); the model never interprets them, so
 * JVM tests can carry arbitrary opaque bytes and only the native bridge needs
 * the real Ink runtime.
 */
class InkStroke(
    val id: Long,
    val brush: InkBrushSpec,
    val inputs: ByteArray,
    val bounds: InkBox,
    val inputFormat: Int = INPUT_FORMAT_ANDROID_INK_V1,
    val transform: InkAffine = InkAffine.IDENTITY,
) {
    init {
        require(id > 0L) { "Stroke id must be positive" }
        require(inputs.isNotEmpty() && inputs.size <= InkFormat.MAX_INPUT_BYTES_PER_STROKE) {
            "Stroke input outside bounds"
        }
        require(bounds.isValid) { "Stroke bounds must be finite" }
        require(transform.isFinite) { "Stroke transform must be finite" }
        require(inputFormat == INPUT_FORMAT_ANDROID_INK_V1) { "Unsupported stroke input encoding" }
    }

    val tool: InkTool get() = brush.tool

    /** Paper-space bounds after the per-stroke transform. */
    fun transformedBounds(): InkBox = transform.mapBox(bounds)

    fun withTransform(newTransform: InkAffine): InkStroke = InkStroke(
        id = id,
        brush = brush,
        inputs = inputs,
        bounds = bounds,
        inputFormat = inputFormat,
        transform = newTransform,
    )

    fun withBrush(newBrush: InkBrushSpec): InkStroke = InkStroke(
        id = id,
        brush = newBrush,
        inputs = inputs,
        bounds = bounds,
        inputFormat = inputFormat,
        transform = transform,
    )

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is InkStroke) return false
        return id == other.id && brush == other.brush && inputFormat == other.inputFormat &&
            transform == other.transform && bounds == other.bounds && inputs.contentEquals(other.inputs)
    }

    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + brush.hashCode()
        result = 31 * result + inputs.contentHashCode()
        result = 31 * result + bounds.hashCode()
        result = 31 * result + transform.hashCode()
        result = 31 * result + inputFormat
        return result
    }

    companion object {
        const val INPUT_FORMAT_ANDROID_INK_V1: Int = 1
    }
}

/** Immutable document snapshot used by the codec and by export. */
data class InkSnapshot(
    val documentId: String,
    val geometry: InkPageGeometry,
    val revision: Long,
    val strokes: List<InkStroke>,
) {
    init {
        require(documentId.matches(Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))) { "Invalid ink document id" }
        require(revision >= 0L) { "Revision must be non-negative" }
        require(strokes.size <= InkFormat.MAX_STROKES) { "Too many strokes" }
        require(strokes.map { it.id }.toSet().size == strokes.size) { "Duplicate stroke ids" }
    }
}

/** Selection hit-test result for one stroke. */
data class InkSelectionHit(val strokeId: Long, val bounds: InkBox)

/**
 * Transactional ink document for one Notes page.
 *
 * Design:
 *  - strokes are IMMUTABLE and the document replaces the list wholesale, so a
 *    snapshot/rollback is a reference, not a deep copy;
 *  - undo/redo entries hold (beforeList, afterList); [beginGroup]/[endGroup]
 *    coalesce every operation into ONE undo step (the stroke-group undo the
 *    UI needs for multi-pointer strokes and eraser drags);
 *  - an unfinished stroke is a PENDING buffer OUTSIDE the committed list; it
 *    never enters undo, persistence or export until [finishStroke]. That is
 *    the structural "cancel/partial stroke fence": [cancelStroke] simply drops
 *    the buffer and the document is byte-identical to before.
 *
 * Thread-confined: the owner drives it from one editor thread (the UI will use
 * the main thread); it is intentionally not thread-safe.
 */
class InkDocument(
    val documentId: String,
    val geometry: InkPageGeometry,
) {
    private var committed: List<InkStroke> = emptyList()
    private var revisionCounter: Long = 0L
    private var selection: Set<Long> = emptySet()
    private val undoStack = ArrayDeque<UndoEntry>()
    private val redoStack = ArrayDeque<UndoEntry>()
    private var groupDepth: Int = 0
    private var groupBefore: List<InkStroke>? = null
    private val pending = LinkedHashMap<Long, PendingStroke>()

    val revision: Long get() = revisionCounter
    val strokeCount: Int get() = committed.size
    val strokes: List<InkStroke> get() = committed
    val selectedStrokeIds: Set<Long> get() = selection
    val hasPendingStrokes: Boolean get() = pending.isNotEmpty()

    fun snapshot(): InkSnapshot =
        InkSnapshot(documentId, geometry, revisionCounter, committed)

    /** Restores an immutable snapshot (e.g. after a failed load or an editor reset). */
    fun restore(snapshot: InkSnapshot) {
        require(snapshot.documentId == documentId) { "Snapshot belongs to another document" }
        require(snapshot.geometry == geometry) { "Snapshot page geometry differs" }
        committed = snapshot.strokes
        revisionCounter = snapshot.revision
        selection = selection.intersect(committed.map { it.id }.toSet())
        pending.clear()
        undoStack.clear()
        redoStack.clear()
        groupDepth = 0
        groupBefore = null
    }

    // ------------------------------------------------------------------
    // Pending stroke lifecycle
    // ------------------------------------------------------------------

    fun beginStroke(id: Long, brush: InkBrushSpec, startedAtMs: Long): Boolean {
        if (id <= 0L || pending.containsKey(id) || committed.any { it.id == id }) return false
        if (pending.size >= MAX_PENDING_STROKES) return false
        pending[id] = PendingStroke(id, brush, startedAtMs)
        return true
    }

    /**
     * Appends encoded input bytes and updates the pending bounds. Refuses
     * oversized input; refuses an unknown/cancelled pending id.
     */
    fun appendStrokeInput(id: Long, inputBytes: ByteArray, bounds: InkBox): Boolean {
        val p = pending[id] ?: return false
        if (bounds.isValid) {
            // First input defines the box; unioning with a zero-origin EMPTY
            // placeholder would wrongly stretch every stroke to (0,0).
            val previous = p.bounds
            p.bounds = if (previous == null) bounds else previous.union(bounds)
        }
        if (inputBytes.isEmpty()) return true
        if (p.input.size() + inputBytes.size > InkFormat.MAX_INPUT_BYTES_PER_STROKE) {
            pending.remove(id)
            return false
        }
        p.input.write(inputBytes)
        return true
    }

    /**
     * Commits a pending stroke into the document as ONE undoable operation.
     * Returns the committed stroke or null when the id is unknown or the input
     * is empty (an empty stroke is a cancelled stroke, never persisted).
     */
    fun finishStroke(id: Long): InkStroke? {
        val p = pending.remove(id) ?: return null
        val bytes = p.input.toByteArray()
        val pendingBounds = p.bounds
        // A dot (one input point, zero-size bounds) is a valid stroke; only an
        // EMPTY input batch or non-finite bounds is refused.
        if (bytes.isEmpty() || pendingBounds == null || !pendingBounds.isValid) {
            return null
        }
        val stroke = InkStroke(
            id = p.id,
            brush = p.brush,
            inputs = bytes,
            bounds = pendingBounds.expand(p.brush.widthPt / 2f),
            transform = InkAffine.IDENTITY,
        )
        mutate { it + stroke }
        return stroke
    }

    /** Drops a pending stroke with no document/undo side effects. */
    fun cancelStroke(id: Long): Boolean {
        val removed = pending.remove(id) ?: return false
        removed.clear()
        return true
    }

    fun cancelAllPending() {
        pending.values.forEach { it.clear() }
        pending.clear()
    }

    /**
     * Commits a FULLY-ENCODED stroke (used when the native layer hands over a
     * finished Stroke and there is no pending buffer, e.g. paste/import).
     */
    fun addCommittedStroke(stroke: InkStroke): Boolean {
        if (committed.any { it.id == stroke.id }) return false
        mutate { it + stroke }
        return true
    }

    // ------------------------------------------------------------------
    // Editing
    // ------------------------------------------------------------------

    fun setSelection(ids: Set<Long>): Boolean {
        val valid = ids.filter { id -> committed.any { it.id == id } }.toSet()
        val changed = valid != selection
        selection = valid
        return changed
    }

    fun clearSelection(): Boolean {
        val changed = selection.isNotEmpty()
        selection = emptySet()
        return changed
    }

    /**
     * Selects every stroke whose transformed bounds intersect [box] (marquee).
     * [replace] false adds to the current selection.
     */
    fun selectInBox(box: InkBox, replace: Boolean = true): Set<Long> {
        val hits = committed.filter { it.transformedBounds().intersects(box) }.map { it.id }.toSet()
        selection = if (replace) hits else selection + hits
        return selection
    }

    /** First hit for a tap inside [box] (topmost stroke wins: last drawn is on top). */
    fun hitTest(box: InkBox): InkSelectionHit? {
        val hit = committed.lastOrNull { it.transformedBounds().intersects(box) } ?: return null
        return InkSelectionHit(hit.id, hit.transformedBounds())
    }

    fun deleteStrokes(ids: Set<Long>): Boolean {
        val present = committed.filter { it.id in ids }
        if (present.isEmpty()) return false
        mutate { list -> list.filter { it.id !in ids } }
        selection = selection - ids
        return true
    }

    fun deleteSelection(): Boolean = deleteStrokes(selection)

    /**
     * Moves the current selection by a paper-space delta. The per-stroke
     * transform is updated (never the encoded inputs), so undo/redo and
     * re-rendering stay exact.
     */
    fun moveSelection(dxPt: Float, dyPt: Float): Boolean {
        if (selection.isEmpty() || !dxPt.isFinite() || !dyPt.isFinite()) return false
        if (dxPt == 0f && dyPt == 0f) return false
        val delta = InkAffine.translation(dxPt, dyPt)
        mutate { list ->
            list.map { stroke ->
                if (stroke.id in selection) stroke.withTransform(delta.then(stroke.transform)) else stroke
            }
        }
        return true
    }

    /** Replaces the brush of every selected stroke (colour/width change). */
    fun restyleSelection(brush: InkBrushSpec): Boolean {
        if (selection.isEmpty()) return false
        var changed = false
        val updated = committed.map { stroke ->
            if (stroke.id in selection && stroke.brush != brush) {
                changed = true
                stroke.withBrush(brush)
            } else {
                stroke
            }
        }
        if (!changed) return false
        mutate { updated }
        return true
    }

    // ------------------------------------------------------------------
    // Undo / redo / grouping
    // ------------------------------------------------------------------

    val canUndo: Boolean get() = undoStack.isNotEmpty()
    val canRedo: Boolean get() = redoStack.isNotEmpty()

    /**
     * Starts a coalesced undo group (e.g. one eraser drag or a multi-pointer
     * batch). Nested calls are ref-counted; the outermost end commits ONE
     * undo entry. Returns the group depth for diagnostics.
     */
    fun beginGroup(): Int {
        if (groupDepth == 0) groupBefore = committed
        groupDepth++
        return groupDepth
    }

    /** Ends one group level; the outermost end pushes a single undo entry. */
    fun endGroup(): Boolean {
        if (groupDepth == 0) return false
        groupDepth--
        if (groupDepth == 0) {
            val before = groupBefore
            groupBefore = null
            if (before != null && before !== committed) {
                undoStack.push(UndoEntry(before, committed))
                trimUndo()
                redoStack.clear()
            }
        }
        return true
    }

    fun undo(): Boolean {
        if (groupDepth > 0 || undoStack.isEmpty()) return false
        val entry = undoStack.pop()
        committed = entry.before
        redoStack.push(entry)
        selection = selection.intersect(committed.map { it.id }.toSet())
        revisionCounter++
        return true
    }

    fun redo(): Boolean {
        if (groupDepth > 0 || redoStack.isEmpty()) return false
        val entry = redoStack.pop()
        committed = entry.after
        undoStack.push(entry)
        selection = selection.intersect(committed.map { it.id }.toSet())
        revisionCounter++
        return true
    }

    fun clearHistory() {
        undoStack.clear()
        redoStack.clear()
        groupDepth = 0
        groupBefore = null
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    private fun mutate(block: (List<InkStroke>) -> List<InkStroke>) {
        val before = committed
        val after = block(before)
        if (after === before) return
        committed = after
        revisionCounter++
        if (groupDepth == 0) {
            undoStack.push(UndoEntry(before, after))
            trimUndo()
            redoStack.clear()
        }
    }

    private fun trimUndo() {
        while (undoStack.size > MAX_UNDO_ENTRIES) undoStack.removeLast()
    }

    private class UndoEntry(val before: List<InkStroke>, val after: List<InkStroke>)

    private class PendingStroke(
        val id: Long,
        val brush: InkBrushSpec,
        val startedAtMs: Long,
    ) {
        val input = ByteArrayOutputStream(1024)
        var bounds: InkBox? = null

        fun clear() {
            // ByteArrayOutputStream has no wipe; reset releases the reference.
            input.reset()
        }
    }

    companion object {
        const val MAX_UNDO_ENTRIES: Int = 100
        const val MAX_PENDING_STROKES: Int = 4

        /** Builds a new document from a validated snapshot (decode path). */
        fun fromSnapshot(snapshot: InkSnapshot): InkDocument =
            InkDocument(snapshot.documentId, snapshot.geometry).also { it.restore(snapshot) }
    }
}
