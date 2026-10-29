// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.api

import android.content.Context
import android.os.Build
import com.floe.android.core.notesmedia.export.NotesExportCapabilities
import com.floe.android.core.notesmedia.export.NotesExportEngine
import com.floe.android.core.notesmedia.export.NotesPdfExportFidelity
import com.floe.android.core.notesmedia.ink.InkCanvasView
import com.floe.android.core.notesmedia.ink.InkDocument
import com.floe.android.core.notesmedia.ink.InkPageGeometry
import com.floe.android.core.notesmedia.ink.InkResourceStore
import com.floe.android.core.notesmedia.media.InkFormat
import com.floe.android.core.notesmedia.media.MediaBindings
import com.floe.android.core.notesmedia.media.MediaEditability
import com.floe.android.core.notesmedia.media.NotesMediaType
import com.floe.android.core.notesmedia.pdf.OfficePdfRenderGateway
import com.floe.android.core.notesmedia.pdf.PdfDocumentSession
import com.floe.android.core.notesmedia.pdf.PdfDocumentSessions
import com.floe.android.core.notesmedia.pdf.PdfOpenResult
import com.floe.android.core.notesmedia.pdf.PdfPasswordSupport
import com.floe.android.core.notesmedia.pdf.PlatformPdfTextBackend
import com.floe.android.core.notesmedia.pdf.PdfSessionOptions
import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import com.floe.android.core.officeengine.pdf.OfficePdfPlatformCapabilities
import java.io.File

/**
 * Single entry point for the G06 Notes media layer.
 *
 * The Notes UI/authority should depend on this object (plus the value types it
 * returns) rather than on individual implementation classes. Everything here is
 * a thin factory; no hidden state, no singleton renderer, no database.
 */
object NotesMedia {

    /** Semver of this source package (not the App version). 1.1.0 adds isolated text/password/fidelity. */
    const val MODULE_VERSION: String = "1.1.0"

    /** Binary ink format this build writes. */
    const val INK_FORMAT_VERSION: Int = InkFormat.CURRENT

    /** Media types the module accepts for a verified source snapshot. */
    val SUPPORTED_SOURCE_MEDIA_TYPES: Set<String> = setOf(
        NotesMediaType.PDF,
        NotesMediaType.FLOE_INK,
        NotesMediaType.APPLE_PENCILKIT,
    )

    /**
     * Capability inventory for UI/feature gating. Values are FACTS about this
     * build, not a promise that a given device supports them: the UI must still
     * handle typed failures (e.g. renderer transport, OCR backend absent).
     */
    data class Capabilities(
        val pdfRendering: Boolean,
        val pdfPageGeometry: Boolean,
        val pdfThumbnails: Boolean,
        val pdfTiles: Boolean,
        val pdfNativeTextSearch: Boolean,
        val pdfNativeTextSearchMinApi: Int,
        val pdfNativeTextSearchOptIn: Boolean,
        val pdfPasswordUnlock: Boolean,
        val inkAuthoringView: Boolean,
        val inkComposeAuthoring: Boolean,
        val inkEditablePersistence: Boolean,
        val foreignInkPreservedOnly: Boolean,
        /** Overlays can be exported into a PDF; the implemented route flattens them into the rasterized copy. */
        val pdfAnnotationExport: Boolean,
        val imageExport: Boolean,
        val systemPrint: Boolean,
        val inkFormatVersion: Int,
        /**
         * Isolated text also works on API 31–34 when the Mainline
         * `framework-pdf` module (v13+) is present; class presence is the
         * runtime gate, so [pdfNativeTextSearch] already reflects THIS device.
         * New fields carry defaults so pre-existing positional construction of
         * this capability record remains source-compatible.
         */
        val pdfNativeTextSearchBackportMinApi: Int = 31,
        val pdfPasswordMinApi: Int = 35,
        val pdfPasswordBackportMinApi: Int = 31,
        val pdfExportFidelity: NotesPdfExportFidelity = NotesPdfExportFidelity.RASTERIZED_COPY,
        val pdfPreservingExport: Boolean = false,
    )

    fun capabilities(apiLevel: Int = Build.VERSION.SDK_INT): Capabilities = Capabilities(
        pdfRendering = true,
        pdfPageGeometry = true,
        pdfThumbnails = true,
        pdfTiles = true,
        // Default = the shared Office ISOLATED renderer text transaction
        // (API 35+, or the Mainline PDF module v13+ on 31–34). The in-process
        // platform backend remains opt-in but is no longer the only path.
        pdfNativeTextSearch = OfficePdfPlatformCapabilities.textExtractionSupported(apiLevel),
        pdfNativeTextSearchMinApi = PlatformPdfTextBackend.MIN_API,
        pdfNativeTextSearchOptIn = false,
        pdfNativeTextSearchBackportMinApi = OfficePdfPlatformCapabilities.PRE_V_MIN_API,
        pdfPasswordUnlock = OfficePdfPlatformCapabilities.passwordSupported(apiLevel),
        pdfPasswordMinApi = PdfPasswordSupport.NATIVE_PASSWORD_MIN_API,
        pdfPasswordBackportMinApi = PdfPasswordSupport.MODULE_PASSWORD_MIN_API,
        inkAuthoringView = true,
        inkComposeAuthoring = false,
        inkEditablePersistence = true,
        foreignInkPreservedOnly = true,
        pdfAnnotationExport = true,
        pdfExportFidelity = NotesExportCapabilities.pdf(apiLevel).fidelity,
        pdfPreservingExport = NotesExportCapabilities.pdf(apiLevel).preservingRouteEnabled,
        imageExport = true,
        systemPrint = true,
        inkFormatVersion = InkFormat.CURRENT,
    )

    /** Opens a verified PDF source (see [PdfDocumentSessions.open] for semantics). */
    suspend fun openPdf(
        context: Context,
        source: VerifiedMediaSnapshot,
        options: PdfSessionOptions = PdfSessionOptions(),
    ): PdfOpenResult = PdfDocumentSessions.open(context, source, options)

    /**
     * Creates a new empty editable ink document for one page. [pageKey] is the
     * Notes page identity; geometry is the displayed page size in points.
     */
    fun createInkDocument(documentId: String, pageKey: String, widthPt: Float, heightPt: Float): InkDocument =
        InkDocument(documentId, InkPageGeometry(pageKey, widthPt, heightPt))

    /** Root for the Notes authority's resource directory (NOT created here). */
    fun inkStore(resourceRoot: File): InkResourceStore = InkResourceStore(resourceRoot)

    fun exportEngine(session: PdfDocumentSession): NotesExportEngine = NotesExportEngine(session)

    /** One renderer gateway (share it across sessions to avoid re-binding). */
    fun renderGateway(context: Context): OfficePdfRenderGateway =
        OfficePdfRenderGateway(context.applicationContext)

    fun instrumentedInkCanvas(context: Context): InkCanvasView = InkCanvasView(context)

    /**
     * Editability of a declared resource, using the explicit media/format
     * binding. The UI must refuse to open a null result rather than guess.
     */
    fun editabilityOf(mediaType: String?, formatVersion: Int): MediaEditability? =
        MediaBindings.resolve(mediaType, formatVersion)

    /**
     * True when THIS device has a public password-capable renderer (API 35+,
     * or API 31–34 with the Mainline PDF module v13+). Actual success still
     * requires opening the document; a wrong password is a typed refusal.
     */
    fun passwordUnlockAvailable(): Boolean =
        OfficePdfPlatformCapabilities.passwordSupported()

    /** Short, path-free diagnostics line for the settings/diagnostics view. */
    fun diagnosticsLine(apiLevel: Int = Build.VERSION.SDK_INT): String {
        val caps = capabilities(apiLevel)
        val password = PdfPasswordSupport.capability(apiLevel)
        return buildString {
            append("notesmedia=").append(MODULE_VERSION)
            append(" ink=v").append(caps.inkFormatVersion)
            append(" pdfRender=").append(caps.pdfRendering)
            append(" geometry=").append(caps.pdfPageGeometry)
            append(" nativeText=").append(if (caps.pdfNativeTextSearch) "isolated" else "off")
            append(" textMinApi=").append(caps.pdfNativeTextSearchMinApi)
            append(" password=").append(password::class.simpleName)
            append(" export=").append(caps.pdfAnnotationExport)
                .append(" fidelity=").append(caps.pdfExportFidelity.name.lowercase())
            append(" image=").append(caps.imageExport)
        }
    }
}
