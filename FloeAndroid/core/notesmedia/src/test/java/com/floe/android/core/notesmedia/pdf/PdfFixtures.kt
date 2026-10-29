// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.Deflater

/**
 * Deterministic PDF byte fixtures for the page-geometry reader.
 *
 * They are deliberately minimal: the reader consumes object dictionaries and
 * `trailer`/XRef dictionaries, not content streams, so the fixtures do not need
 * a valid xref table or page content. Everything here is generated in-test (no
 * binary asset is committed).
 */
object PdfFixtures {

    fun build(objects: List<String>, trailer: String? = null, eof: Boolean = true): ByteArray {
        val out = ByteArrayOutputStream()
        out.write("%PDF-1.7\n".toByteArray(Charsets.US_ASCII))
        // A harmless binary comment line exercises the scanner over non-ASCII.
        out.write("%\u00E2\u00E3\u00CF\u00D3\n".toByteArray(Charsets.ISO_8859_1))
        for (obj in objects) {
            out.write(obj.toByteArray(Charsets.US_ASCII))
            out.write('\n'.code)
        }
        trailer?.let {
            out.write(it.toByteArray(Charsets.US_ASCII))
            out.write('\n'.code)
        }
        if (eof) out.write("%%EOF\n".toByteArray(Charsets.US_ASCII))
        return out.toByteArray()
    }

    fun twoPages(): ByteArray = build(
        listOf(
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>\nendobj",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj",
            "4 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Rotate 90 >>\nendobj",
        ),
        "trailer\n<< /Root 1 0 R /Size 5 >>",
    )

    fun inheritedBoxes(): ByteArray = build(
        listOf(
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 600 800] /Rotate -90 >>\nendobj",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /CropBox [10 20 590 780] >>\nendobj",
        ),
        "trailer\n<< /Root 1 0 R /Size 4 >>",
    )

    fun objectStream(): ByteArray {
        val contained = "3 0 << /Type /Page /Parent 2 0 R >>"
        val compressed = deflate(contained.toByteArray(Charsets.US_ASCII))
        val out = ByteArrayOutputStream()
        out.write("%PDF-1.7\n".toByteArray(Charsets.US_ASCII))
        out.write(
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".toByteArray(Charsets.US_ASCII),
        )
        out.write(
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 300 400] >>\nendobj\n"
                .toByteArray(Charsets.US_ASCII),
        )
        out.write(
            ("6 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Length ${compressed.size} /Filter /FlateDecode >>\nstream\n")
                .toByteArray(Charsets.US_ASCII),
        )
        out.write(compressed)
        out.write("\nendstream\nendobj\n".toByteArray(Charsets.US_ASCII))
        out.write(
            ("7 0 obj\n<< /Type /XRef /Root 1 0 R /Size 8 /W [1 2 1] /Length 0 >>\nstream\n\nendstream\nendobj\n")
                .toByteArray(Charsets.US_ASCII),
        )
        out.write("%%EOF\n".toByteArray(Charsets.US_ASCII))
        return out.toByteArray()
    }

    fun encryptedClassicTrailer(): ByteArray = build(
        listOf(
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 200 300] >>\nendobj",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj",
            "4 0 obj\n<< /Filter /Standard /V 2 /R 3 >>\nendobj",
        ),
        "trailer\n<< /Root 1 0 R /Encrypt 4 0 R /Size 5 >>",
    )

    fun noCatalog(): ByteArray = build(
        listOf("1 0 obj\n<< /Type /Pages /Kids [2 0 R] /Count 1 /MediaBox [0 0 100 100] >>\nendobj"),
        "trailer\n<< /Size 2 >>",
    )

    fun zeroSizePage(): ByteArray = build(
        listOf(
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 0 0] >>\nendobj",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj",
        ),
        "trailer\n<< /Root 1 0 R /Size 4 >>",
    )

    fun write(file: File, bytes: ByteArray): File {
        file.writeBytes(bytes)
        return file
    }

    fun deflate(bytes: ByteArray): ByteArray {
        val deflater = Deflater(Deflater.BEST_SPEED)
        deflater.setInput(bytes)
        deflater.finish()
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(1024)
        while (!deflater.finished()) {
            val n = deflater.deflate(buffer)
            out.write(buffer, 0, n)
        }
        deflater.end()
        return out.toByteArray()
    }
}
