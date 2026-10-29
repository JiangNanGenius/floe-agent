// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import android.graphics.Canvas
import android.graphics.Matrix
import androidx.ink.brush.Brush
import androidx.ink.brush.BrushFamily
import androidx.ink.brush.StockBrushes
import androidx.ink.geometry.ImmutableAffineTransform
import androidx.ink.geometry.MutableBox
import androidx.ink.rendering.android.canvas.CanvasStrokeRenderer
import androidx.ink.storage.decode
import androidx.ink.storage.encode
import androidx.ink.strokes.ImmutableStrokeInputBatch
import androidx.ink.strokes.Stroke
import androidx.ink.strokes.StrokeInputBatch
import com.floe.android.core.notesmedia.media.InkFormat
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

/**
 * The ONE adapter between the module's pure ink model and androidx.ink 1.0.0.
 *
 * Everything native lives here:
 *  - stock brush families ([StockBrushes.pressurePen]/[StockBrushes.highlighter])
 *    and the `Brush` (family + colour + width + epsilon) construction;
 *  - `StrokeInputBatch` encode/decode (gzip-protobuf per the library's own
 *    `StrokeInputBatch.encode/decode`, bounded to the module's per-stroke cap);
 *  - `Stroke` construction and mesh bounds/hit-testing;
 *  - canvas rendering (`ViewStrokeRenderer` in views, `CanvasStrokeRenderer`
 *    for export).
 *
 * The model layer never needs the native runtime, which is why JVM tests can
 * exercise the document, codec, store, pointer routing and export planning
 * without loading libink.so. Anything that loads native is a device gate and
 * is reported as such.
 */
internal object InkNativeBridge {

    /**
     * Curve-fitting epsilon in stroke units (= paper points here). 0.1 pt is the
     * library's typical screen-scale value; it keeps small handwriting faithful
     * without exploding the mesh for long strokes.
     */
    const val BRUSH_EPSILON_PT: Float = 0.1f

    private val families: Map<String, () -> BrushFamily> = mapOf(
        InkBrushSpec.FAMILY_PEN to { StockBrushes.pressurePen() },
        InkBrushSpec.FAMILY_HIGHLIGHTER to { StockBrushes.highlighter() },
    )

    fun familyFor(familyId: String): BrushFamily? = families[familyId]?.invoke()

    /** Brush in PAPER units; the same brush renders identically at any zoom. */
    fun brushFor(spec: InkBrushSpec): Brush? {
        val family = familyFor(spec.familyId) ?: return null
        return try {
            Brush.createWithColorIntArgb(family, spec.colorArgb, spec.widthPt, BRUSH_EPSILON_PT)
        } catch (_: Exception) {
            null
        }
    }

    /** Encodes a finished native stroke's inputs for persistence. */
    fun encodeStrokeInputs(batch: StrokeInputBatch): ByteArray? {
        val out = ByteArrayOutputStream(4096)
        return try {
            batch.encode(out)
            val bytes = out.toByteArray()
            if (bytes.isEmpty() || bytes.size > InkFormat.MAX_INPUT_BYTES_PER_STROKE) null else bytes
        } catch (_: Exception) {
            null
        }
    }

    fun decodeStrokeInputs(bytes: ByteArray): ImmutableStrokeInputBatch? {
        if (bytes.isEmpty() || bytes.size > InkFormat.MAX_INPUT_BYTES_PER_STROKE) return null
        return try {
            StrokeInputBatch.decode(ByteArrayInputStream(bytes))
        } catch (_: Exception) {
            null
        }
    }

    /** Reconstructs a native stroke from a persisted record (null when bytes are invalid). */
    fun toStroke(record: InkStroke): Stroke? {
        val brush = brushFor(record.brush) ?: return null
        val inputs = decodeStrokeInputs(record.inputs) ?: return null
        return try {
            Stroke(brush, inputs)
        } catch (_: Exception) {
            null
        }
    }

    /** Stroke-local mesh bounds in paper units. */
    fun localBounds(stroke: Stroke): InkBox? = try {
        val box = stroke.shape.computeBoundingBox() ?: return null
        InkBox(box.xMin, box.yMin, box.xMax, box.yMax).takeIf { it.isValid }
    } catch (_: Exception) {
        null
    }

    /**
     * Eraser hit test: the paper-space point expanded by [tolerancePt] is mapped
     * into stroke-local space (per-stroke move transforms included) and tested
     * against the stroke mesh coverage. Returns false on any native failure —
     * an eraser must never delete a stroke it could not test.
     */
    fun isHit(record: InkStroke, xPt: Float, yPt: Float, tolerancePt: Float): Boolean {
        if (!xPt.isFinite() || !yPt.isFinite() || tolerancePt <= 0f) return false
        val stroke = toStroke(record) ?: return false
        val tolerance = tolerancePt.coerceIn(0.25f, 64f)
        val paperBox = InkBox.around(xPt, yPt, tolerance)
        val localBox: InkBox = if (record.transform.isIdentity) {
            paperBox
        } else {
            val inverse = record.transform.invertOrNull() ?: return false
            val scale = record.transform.approximateScale().coerceAtLeast(0.01f)
            inverse.mapBox(paperBox.expand(tolerance / scale * 0.5f))
        }
        return try {
            val probe = MutableBox()
                .setXBounds(localBox.left, localBox.right)
                .setYBounds(localBox.top, localBox.bottom)
            stroke.shape.computeCoverageIsGreaterThan(probe, 0f)
        } catch (_: Exception) {
            false
        }
    }

    fun toAndroidMatrix(affine: InkAffine): Matrix = Matrix().apply {
        setValues(
            floatArrayOf(
                affine.a, affine.c, affine.e,
                affine.b, affine.d, affine.f,
                0f, 0f, 1f,
            ),
        )
    }

    fun toInkTransform(affine: InkAffine): ImmutableAffineTransform = ImmutableAffineTransform(
        affine.a, affine.b, affine.e, affine.c, affine.d, affine.f,
    )

    /**
     * Draws one finished stroke for EXPORT onto a canvas whose units are paper
     * points. The canvas transform and the renderer's stroke→canvas transform
     * are the same matrix, matching the library's documented usage.
     */
    fun drawOnPaperCanvas(
        canvas: Canvas,
        renderer: CanvasStrokeRenderer,
        record: InkStroke,
    ): Boolean {
        val stroke = toStroke(record) ?: return false
        val matrix = toAndroidMatrix(record.transform)
        return try {
            val checkpoint = canvas.save()
            canvas.concat(matrix)
            renderer.draw(canvas, stroke, matrix)
            canvas.restoreToCount(checkpoint)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Selects the topmost stroke whose MESH point set covers ([xPt],[yPt]) —
     * used by tap-to-select (a hit test in paper coordinates).
     * Returns null when nothing is hit or the native layer refuses.
     */
    fun topmostHit(strokes: List<InkStroke>, xPt: Float, yPt: Float, tolerancePt: Float): InkStroke? {
        for (i in strokes.indices.reversed()) {
            if (isHit(strokes[i], xPt, yPt, tolerancePt)) return strokes[i]
        }
        return null
    }
}
