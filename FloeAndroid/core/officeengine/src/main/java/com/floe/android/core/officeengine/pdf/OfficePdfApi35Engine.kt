// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.graphics.Bitmap
import android.graphics.RectF
import android.graphics.pdf.LoadParams
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import java.io.IOException

/**
 * API 35+ platform engine: `PdfRenderer(fd, LoadParams)` (public since 35)
 * for password-protected documents, plus `Page.getTextContents()` for real
 * text. Loaded only when [OfficePdfPlatformCapabilities.engineKind] answers
 * [OfficePdfEngineKind.API_35].
 *
 * Password handling (verified Javadoc): a wrong password/unsupported scheme
 * throws `SecurityException`; the constructor takes ownership of the FD on
 * success and the caller keeps ownership on failure. The platform requires a
 * `String` for `LoadParams.Builder.setPassword`: that immutable copy exists
 * only transiently inside the disposable isolated process, is never logged,
 * persisted or placed in a Bundle, and the originating `CharArray` is
 * zero-filled immediately after the builder copies it.
 *
 * Lint: this class is loaded only for [OfficePdfEngineKind.API_35]; the
 * runtime selection is in [OfficePdfEngines.open], never on older devices.
 */
@android.annotation.SuppressLint("NewApi")
internal object OfficePdfApi35Engine {

    fun open(fd: ParcelFileDescriptor, password: CharArray?): OfficePdfEngineOpenResult {
        val renderer = try {
            if (password == null) {
                PdfRenderer(fd)
            } else {
                val params = try {
                    LoadParams.Builder().setPassword(String(password)).build()
                } finally {
                    password.fill('\u0000')
                }
                PdfRenderer(fd, params)
            }
        } catch (_: SecurityException) {
            runCatching { fd.close() }
            return if (password == null) {
                OfficePdfEngineOpenResult.PasswordRequired
            } else {
                OfficePdfEngineOpenResult.PasswordRejected
            }
        } catch (_: IOException) {
            runCatching { fd.close() }
            return OfficePdfEngineOpenResult.Invalid
        } catch (_: IllegalArgumentException) {
            runCatching { fd.close() }
            return OfficePdfEngineOpenResult.Invalid
        } catch (_: RuntimeException) {
            runCatching { fd.close() }
            return OfficePdfEngineOpenResult.Invalid
        }
        return OfficePdfEngineOpenResult.Ok(Engine(renderer))
    }

    private class Engine(private val renderer: PdfRenderer) : OfficePdfEngine {
        override val pageCount: Int
            get() = renderer.pageCount

        override fun openPage(index: Int): OfficePdfEnginePage = Page35(renderer.openPage(index))

        override fun close() {
            runCatching { renderer.close() }
        }
    }

    private class Page35(private val page: PdfRenderer.Page) : OfficePdfEnginePage {
        override val widthPt: Int get() = page.width
        override val heightPt: Int get() = page.height

        override fun render(bitmap: Bitmap, mode: Int) {
            page.render(bitmap, null, null, mode)
        }

        override fun textLines(): List<OfficePdfTextLine> {
            // A platform exception is a FAILURE, not "this page has no
            // text": the service maps it to S_INTERNAL and the consumer shows
            // a typed backend failure instead of triggering a false OCR scan.
            val contents = page.textContents
            val lines = ArrayList<OfficePdfTextLine>(minOf(contents.size, OfficePdfTextContract.MAX_TEXT_REGIONS))
            for (content in contents) {
                if (lines.size >= OfficePdfTextContract.MAX_TEXT_REGIONS) break
                val text = runCatching { content.text }.getOrNull() ?: continue
                if (text.isEmpty()) continue
                val bounds = runCatching { content.bounds }.getOrNull().orEmpty()
                val rects = ArrayList<OfficePdfTextLineRect>(minOf(bounds.size, OfficePdfTextContract.MAX_REGION_RECTS))
                for (rect in bounds) {
                    if (rects.size >= OfficePdfTextContract.MAX_REGION_RECTS) break
                    rects.add(rect.toLineRect())
                }
                lines.add(OfficePdfTextLine(text, rects))
            }
            return lines
        }

        override fun close() {
            runCatching { page.close() }
        }
    }

    private fun RectF.toLineRect(): OfficePdfTextLineRect =
        OfficePdfTextLineRect(left = left, top = top, right = right, bottom = bottom)
}
