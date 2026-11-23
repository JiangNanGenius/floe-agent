// SPDX-License-Identifier: MPL-2.0
//
// Android boundary of the lightweight PDF document export. It draws the pure
// [MeetingPdfLayout] lines onto platform pages with android.graphics.pdf.
// PdfDocument, so CJK transcript text renders with the system fonts and no
// third-party dependency is introduced. All layout decisions stay in the pure
// layout object, which the unit tests verify line by line.
package com.floe.android.host.meetingexchange

import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import java.io.ByteArrayOutputStream

internal object MeetingPdfExport {
    /**
     * Renders [layout] to PDF bytes. The first line baseline starts below the
     * top margin; each following line advances by its own line height so mixed
     * title/body pages keep readable spacing.
     */
    fun render(layout: MeetingPdfLayout): ByteArray {
        val document = PdfDocument()
        try {
            layout.pages.forEachIndexed { index, page ->
                val info = PdfDocument.PageInfo
                    .Builder(layout.pageWidth, layout.pageHeight, index + 1)
                    .create()
                val started = document.startPage(info)
                val canvas = started.canvas
                val paint = Paint(Paint.ANTI_ALIAS_FLAG)
                paint.typeface = Typeface.DEFAULT
                var baseline = MeetingPdfLayoutBuilder.MARGIN_TOP + MeetingPdfLayoutBuilder.TITLE_SIZE
                page.lines.forEach { line ->
                    paint.textSize = line.textSize
                    paint.isFakeBoldText = line.bold
                    canvas.drawText(line.text, MeetingPdfLayoutBuilder.MARGIN_X, baseline, paint)
                    baseline += line.textSize * MeetingPdfLayoutBuilder.LINE_HEIGHT_FACTOR
                }
                document.finishPage(started)
            }
            val out = ByteArrayOutputStream()
            document.writeTo(out)
            return out.toByteArray()
        } finally {
            document.close()
        }
    }
}
