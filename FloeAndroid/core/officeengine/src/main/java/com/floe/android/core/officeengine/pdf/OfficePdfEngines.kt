// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.IOException

/**
 * Internal platform renderer seam for the isolated service. It exists so the
 * service's trust logic (owner fence, descriptor handling, bounds, one-page
 * lifecycle) is identical for every real platform class:
 *  - [OfficePdfLegacyEngine] (API 28–30): legacy `PdfRenderer`, pixels only;
 *  - [OfficePdfApi35Engine] (API 35+): `PdfRenderer` + `LoadParams` password
 *    + page text content;
 *  - [OfficePdfPreVEngine] (API 31–34 with the Mainline `framework-pdf`
 *    module): `PdfRendererPreV`, same password/text surface.
 *
 * The adapter classes never decide policy, never touch paths and never keep a
 * document open between jobs. The service owns ONE open engine at a time.
 */
internal interface OfficePdfEngine : AutoCloseable {
    val pageCount: Int
    fun openPage(index: Int): OfficePdfEnginePage
}

internal interface OfficePdfEnginePage : AutoCloseable {
    val widthPt: Int
    val heightPt: Int

    /** Renders into an ARGB_8888 bitmap that the caller already bounded. */
    fun render(bitmap: Bitmap, mode: Int)

    /** Real platform text lines; empty means "no platform text API" for legacy only. */
    fun textLines(): List<OfficePdfTextLine>
}

/** Result of one real platform open. Failures already closed the received FD. */
internal sealed class OfficePdfEngineOpenResult {
    class Ok(val engine: OfficePdfEngine) : OfficePdfEngineOpenResult()

    /** Encrypted and no password supplied: the caller may prompt the user. */
    object PasswordRequired : OfficePdfEngineOpenResult()

    /** A password was supplied and the platform refused it (or the scheme). */
    object PasswordRejected : OfficePdfEngineOpenResult()

    /** This device has no public password-capable renderer. */
    object PasswordUnsupported : OfficePdfEngineOpenResult()

    object Invalid : OfficePdfEngineOpenResult()
}

internal object OfficePdfEngines {

    /**
     * Opens [fd] with the engine selected by [OfficePdfPlatformCapabilities].
     * Takes ownership of [fd] on success; closes it on every failure. The
     * password char array is never retained here and is zeroed by the caller
     * as soon as this returns.
     */
    @android.annotation.SuppressLint("NewApi")
    fun open(
        kind: OfficePdfEngineKind,
        fd: ParcelFileDescriptor,
        password: CharArray?,
    ): OfficePdfEngineOpenResult = when (kind) {
        OfficePdfEngineKind.LEGACY -> openLegacy(fd, password)
        OfficePdfEngineKind.API_35 -> OfficePdfApi35Engine.open(fd, password)
        OfficePdfEngineKind.PRE_V -> OfficePdfPreVEngine.open(fd, password)
    }

    /**
     * API 28–30: the legacy `PdfRenderer` constructor is the only public
     * surface. Encrypted files are refused by the platform; no password
     * channel exists, so an unlock attempt is a typed platform limitation.
     */
    private fun openLegacy(
        fd: ParcelFileDescriptor,
        password: CharArray?,
    ): OfficePdfEngineOpenResult {
        if (password != null) {
            runCatching { fd.close() }
            return OfficePdfEngineOpenResult.PasswordUnsupported
        }
        val renderer = try {
            PdfRenderer(fd)
        } catch (_: SecurityException) {
            runCatching { fd.close() }
            return OfficePdfEngineOpenResult.PasswordRequired
        } catch (_: IOException) {
            runCatching { fd.close() }
            return OfficePdfEngineOpenResult.Invalid
        } catch (_: RuntimeException) {
            runCatching { fd.close() }
            return OfficePdfEngineOpenResult.Invalid
        }
        return OfficePdfEngineOpenResult.Ok(LegacyEngine(renderer))
    }

    private class LegacyEngine(private val renderer: PdfRenderer) : OfficePdfEngine {
        override val pageCount: Int
            get() = renderer.pageCount

        override fun openPage(index: Int): OfficePdfEnginePage = LegacyPage(renderer.openPage(index))

        override fun close() {
            runCatching { renderer.close() }
        }
    }

    private class LegacyPage(private val page: PdfRenderer.Page) : OfficePdfEnginePage {
        override val widthPt: Int get() = page.width
        override val heightPt: Int get() = page.height

        override fun render(bitmap: Bitmap, mode: Int) {
            page.render(bitmap, null, null, mode)
        }

        override fun textLines(): List<OfficePdfTextLine> = emptyList()

        override fun close() {
            runCatching { page.close() }
        }
    }
}
