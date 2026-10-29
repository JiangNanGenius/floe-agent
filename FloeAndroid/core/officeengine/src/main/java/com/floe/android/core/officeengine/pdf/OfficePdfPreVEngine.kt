// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.pdf

import android.graphics.Bitmap
import android.graphics.RectF
import android.graphics.pdf.LoadParams
import android.graphics.pdf.PdfRendererPreV
import android.graphics.pdf.RenderParams
import android.os.ParcelFileDescriptor
import java.io.IOException

/**
 * API 31–34 Mainline `framework-pdf` engine. `PdfRendererPreV` is a module
 * class (`module="framework-pdf"`, `sdks="31:13,33:13,34:13,..."` in the
 * installed API-37 metadata) that exposes the API-35 render/password/text
 * surface on devices with module version 13+. This file references that
 * class directly, so it is loaded ONLY after
 * [OfficePdfPlatformCapabilities.pdfModulePresent] proved both
 * `PdfRendererPreV` and `LoadParams.Builder` are linkable; API 28–30 never
 * load this class.
 *
 * Same ownership rules as the API-35 engine: the constructor owns the FD on
 * success; every failure closes it; a supplied password that the platform
 * refuses is [OfficePdfEngineOpenResult.PasswordRejected], never a generic
 * parse error. The transient `String` required by `LoadParams` exists only
 * inside the isolated process (no logs, no persistence, no Bundle).
 *
 * Lint: loaded only after [OfficePdfPlatformCapabilities.pdfModulePresent]
 * proved the module class + constructor + text method exist; never on API
 * 28–30.
 */
@android.annotation.SuppressLint("NewApi")
internal object OfficePdfPreVEngine {

    fun open(fd: ParcelFileDescriptor, password: CharArray?): OfficePdfEngineOpenResult {
        val renderer = try {
            if (password == null) {
                PdfRendererPreV(fd)
            } else {
                val params = try {
                    LoadParams.Builder().setPassword(String(password)).build()
                } finally {
                    password.fill('\u0000')
                }
                PdfRendererPreV(fd, params)
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

    private class Engine(private val renderer: PdfRendererPreV) : OfficePdfEngine {
        override val pageCount: Int
            get() = renderer.pageCount

        override fun openPage(index: Int): OfficePdfEnginePage = PagePreV(renderer.openPage(index))

        override fun close() {
            runCatching { renderer.close() }
        }
    }

    private class PagePreV(private val page: PdfRendererPreV.Page) : OfficePdfEnginePage {
        override val widthPt: Int get() = page.width
        override val heightPt: Int get() = page.height

        override fun render(bitmap: Bitmap, mode: Int) {
            val params = RenderParams.Builder(mode).build()
            page.render(bitmap, null, null, params)
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
