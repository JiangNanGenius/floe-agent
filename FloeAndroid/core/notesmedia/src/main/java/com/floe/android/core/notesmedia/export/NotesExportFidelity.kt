// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import android.os.Build
import com.floe.android.core.officeengine.pdf.OfficePdfGeometry
import com.floe.android.core.officeengine.pdf.OfficePdfPlatformCapabilities

/**
 * What an exported PDF actually is. There is exactly ONE implemented route
 * today: [RASTERIZED_COPY] — the source page content is re-rendered at the
 * bounded render size, the caller's text/image/shape/ink overlays are drawn
 * on top, and a NEW `PdfDocument` is written. The original PDF file is never
 * modified, but its text/vector structure is NOT preserved in the output.
 *
 * This type exists so no UI, guide or release note can silently call that
 * "lossless" or "annotation-preserving": the readback below carries the same
 * explicit flags.
 */
enum class NotesPdfExportFidelity {
    /** New PDF whose page background is a bounded raster image; overlays are drawn into it. */
    RASTERIZED_COPY,
}

/**
 * Explicit export capability/fidelity facts. `platform*` fields describe the
 * PUBLIC Android SDK surface (verified against the installed API-37 SDK):
 * `PdfRenderer.write` since API 35 (PreV Mainline module 13 on 31–34) and
 * `Page.addPageAnnotation` since API 36.1 (module 18). They do NOT mean this
 * module implements a preserving route — [preservingRouteEnabled] is the
 * module fact, and [preservingRouteBlocker] states why.
 *
 * A native preserving route is deliberately NOT shipped in this batch:
 *  - the supported native annotation types are FREETEXT/HIGHLIGHT/STAMP only;
 *    Floe ink strokes/shapes/text/images would have to be flattened into a
 *    STAMP image object, i.e. a new bitmap binder surface plus unproven print
 *    fidelity, not a verified text/vector-preserving notes export;
 *  - annotation APIs require API 36.1/module 18, while the accepted device
 *    matrix includes API 33 (Samsung) without them;
 *  - no device/print qualification is allowed in this source lane.
 * The rasterized route keeps the original and reports the truth instead of
 * claiming losslessness.
 */
data class NotesPdfExportCapability(
    val fidelity: NotesPdfExportFidelity,
    val originalSourcePreserved: Boolean,
    val sourceTextPreserved: Boolean,
    val sourceVectorContentPreserved: Boolean,
    val overlayContentFlattenedToPixels: Boolean,
    val boundedRenderEdgePx: Int,
    val targetDpi: Int,
    val platformNativeWriteApiPresent: Boolean,
    val platformAnnotationApiPresent: Boolean,
    val supportedNativeAnnotationTypes: List<String>,
    val preservingRouteEnabled: Boolean,
    val preservingRouteBlocker: String,
)

object NotesExportCapabilities {

    const val RASTER_TARGET_DPI: Int = 144

    fun pdf(
        apiLevel: Int = Build.VERSION.SDK_INT,
        pdfModulePresent: Boolean = OfficePdfPlatformCapabilities.pdfModulePresent(),
    ): NotesPdfExportCapability {
        val native = OfficePdfPlatformCapabilities.nativeAnnotationWrite(apiLevel, pdfModulePresent)
        return NotesPdfExportCapability(
            fidelity = NotesPdfExportFidelity.RASTERIZED_COPY,
            originalSourcePreserved = true,
            sourceTextPreserved = false,
            sourceVectorContentPreserved = false,
            overlayContentFlattenedToPixels = true,
            boundedRenderEdgePx = OfficePdfGeometry.MAX_RENDER_DIMENSION_PX,
            targetDpi = RASTER_TARGET_DPI,
            platformNativeWriteApiPresent = native.writeApiPresent,
            platformAnnotationApiPresent = native.annotationApiPresent,
            supportedNativeAnnotationTypes = native.supportedAnnotationTypes,
            preservingRouteEnabled = false,
            preservingRouteBlocker =
                "Supported native annotations are FREETEXT/HIGHLIGHT/STAMP only (API 36.1+); " +
                    "Floe ink/shape/text overlays would become a flattened stamp image and " +
                    "print fidelity is unverified on the accepted devices.",
        )
    }

    /** Short, path-free line for settings/diagnostics. */
    fun diagnosticsLine(
        apiLevel: Int = Build.VERSION.SDK_INT,
        pdfModulePresent: Boolean = OfficePdfPlatformCapabilities.pdfModulePresent(),
    ): String {
        val cap = pdf(apiLevel, pdfModulePresent)
        return "pdfExport=${cap.fidelity.name.lowercase()} " +
            "textPreserved=${cap.sourceTextPreserved} vectorPreserved=${cap.sourceVectorContentPreserved} " +
            "nativeWrite=${cap.platformNativeWriteApiPresent} annotations=${cap.platformAnnotationApiPresent} " +
            "preservingRoute=${cap.preservingRouteEnabled}"
    }
}
