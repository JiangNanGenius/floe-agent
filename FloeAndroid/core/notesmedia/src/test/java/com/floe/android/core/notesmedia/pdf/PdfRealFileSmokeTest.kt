// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * OPT-IN real-world PDF smoke check.
 *
 * The hermetic suite uses synthetic fixtures; this test additionally parses a
 * real document supplied by the caller:
 *
 * ```
 * ./gradlew :core:notesmedia:testDebugUnitTest -Pnotesmedia.realPdfFile=/abs/path.pdf
 * ```
 *
 * Without the property the test is SKIPPED (JUnit assumption), so no external
 * file can make the normal suite flaky. It asserts only what the module must
 * guarantee for any acceptable source: a typed result, >=1 page and a valid
 * box for every page when the geometry is readable.
 */
class PdfRealFileSmokeTest {

    @Test
    fun realFileGeometryIsReadableOrTyped() {
        val path = System.getProperty("notesmedia.realPdfFile").orEmpty()
        assumeTrue("no -Pnotesmedia.realPdfFile supplied", path.isNotBlank())
        val file = File(path)
        assumeTrue("real PDF file does not exist: $path", file.isFile)
        val sha = MessageDigest.getInstance("SHA-256").digest(file.readBytes())
            .joinToString("") { "%02x".format(it) }
        val result = PdfPageBoxReader().read(file, sha)
        println("notesmedia.realPdf=$path sha256=$sha")
        when (result) {
            is PdfGeometryResult.Refused -> {
                println("notesmedia.realPdf.refused=${result.reason} encrypted=${result.encrypted}")
                // A typed refusal is acceptable only for reasons that mean the
                // page tree genuinely cannot be proven; it must never be a
                // crash or a bogus success.
                assertTrue(
                    result.reason in setOf(
                        PdfGeometryRefusal.MALFORMED,
                        PdfGeometryRefusal.PAGE_TREE_UNREADABLE,
                        PdfGeometryRefusal.UNSUPPORTED_FILTER,
                        PdfGeometryRefusal.NO_CATALOG,
                    ),
                )
            }
            is PdfGeometryResult.Ok -> {
                val geometry = result.geometry
                println(
                    "notesmedia.realPdf.pages=${geometry.pageCount} encrypted=${geometry.encrypted} " +
                        "first=${geometry.pages.first().displayedWidthPt}x${geometry.pages.first().displayedHeightPt}pt",
                )
                assertTrue(geometry.pageCount >= 1)
                assertTrue(geometry.pages.all {
                    it.displayedWidthPt >= 1f && it.displayedHeightPt >= 1f &&
                        it.displayedWidthPt.isFinite() && it.displayedHeightPt.isFinite()
                })
            }
        }
    }
}
