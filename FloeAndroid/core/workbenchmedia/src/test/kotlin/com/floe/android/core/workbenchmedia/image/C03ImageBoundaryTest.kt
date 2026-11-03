// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.workbenchmedia.image

import java.io.File
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM checks for the C03 HEIC/HDR boundary and ISO-BMFF brand detection.
 * These do not load Android codecs and do not claim a device encode.
 */
class C03ImageBoundaryTest {
    @Test
    fun heifHeaderAcceptsHeicMajorAndCompatibleBrands() {
        val major = tempFile(heif(major = "heic", compatible = emptyList()))
        assertEquals("heic", HeifHeaderInspector.detect(major))
        val compatible = tempFile(heif(major = "mif1", compatible = listOf("heic", "mif1")))
        assertEquals("heic", HeifHeaderInspector.detect(compatible))
    }

    @Test
    fun heifHeaderRejectsMp4AndAvif() {
        val mp4 = tempFile(heif(major = "isom", compatible = listOf("isom", "mp41")))
        assertEquals(null, HeifHeaderInspector.detect(mp4))
        val avif = tempFile(heif(major = "avif", compatible = listOf("avif", "mif1")))
        assertEquals("avif", HeifHeaderInspector.detect(avif))
    }

    @Test
    fun hdrProbeDetectsPqTransferAndIsoHighBitDepth() {
        val pq = tempFile(
            heif(
                major = "heic",
                compatible = listOf("heic"),
                extra = nclx(transfer = 16),
            ),
        )
        assertTrue(HdrSourceProbe.inspect(pq).isHdr)
        val pixi = tempFile(
            heif(
                major = "heic",
                compatible = listOf("heic"),
                extra = box("pixi", byteArrayOf(0, 0, 0, 0, 3, 10, 10, 10)),
            ),
        )
        assertTrue(HdrSourceProbe.inspect(pixi).isHdr)
        val gainMap = tempFile(
            heif(
                major = "heic",
                compatible = listOf("heic"),
                extra = "urn:com:apple:photo:2020:aux:hdrgainmap"
                    .toByteArray(Charsets.ISO_8859_1),
            ),
        )
        assertTrue(HdrSourceProbe.inspect(gainMap).isHdr)
    }

    @Test
    fun hdrProbeKeepsSdrHeifAndPngAsSdr() {
        val sdr = tempFile(heif(major = "heic", compatible = listOf("heic")))
        assertFalse(HdrSourceProbe.inspect(sdr).isHdr)
        val png = tempFile(pngHeader(width = 2, height = 2))
        assertFalse(HdrSourceProbe.inspect(png).isHdr)
    }

    @Test
    fun hdrProbeDetectsPngCicpPqAndHlg() {
        val pq = tempFile(pngHeader(width = 2, height = 2, cicpTransfer = 16))
        assertTrue(HdrSourceProbe.inspect(pq).isHdr)
        val hlg = tempFile(pngHeader(width = 2, height = 2, cicpTransfer = 18))
        assertTrue(HdrSourceProbe.inspect(hlg).isHdr)
    }

    private fun tempFile(bytes: ByteArray): File {
        val dir = createTempDirectory("c03-image-boundary")
        val file = File(dir.toFile(), "sample")
        file.writeBytes(bytes)
        return file
    }

    private fun heif(
        major: String,
        compatible: List<String>,
        extra: ByteArray = ByteArray(0),
    ): ByteArray {
        val body = java.io.ByteArrayOutputStream()
        body.write(0) // size placeholder
        body.write(0)
        body.write(0)
        body.write(0)
        body.write("ftyp".toByteArray(Charsets.ISO_8859_1))
        body.write(major.toByteArray(Charsets.ISO_8859_1))
        body.write(0)
        body.write(0)
        body.write(0)
        body.write(0)
        for (brand in compatible) body.write(brand.toByteArray(Charsets.ISO_8859_1))
        body.write(extra)
        val bytes = body.toByteArray()
        val size = bytes.size
        bytes[0] = ((size ushr 24) and 0xff).toByte()
        bytes[1] = ((size ushr 16) and 0xff).toByte()
        bytes[2] = ((size ushr 8) and 0xff).toByte()
        bytes[3] = (size and 0xff).toByte()
        return bytes
    }

    private fun nclx(transfer: Int): ByteArray {
        val payload = java.io.ByteArrayOutputStream()
        payload.write("nclx".toByteArray(Charsets.ISO_8859_1))
        payload.write(0); payload.write(1) // primaries = BT.709
        payload.write((transfer ushr 8) and 0xff)
        payload.write(transfer and 0xff)
        payload.write(0); payload.write(1) // matrix = BT.709
        payload.write(1) // full range
        return box("colr", payload.toByteArray())
    }

    private fun box(type: String, payload: ByteArray): ByteArray {
        val size = 8 + payload.size
        return byteArrayOf(
            ((size ushr 24) and 0xff).toByte(),
            ((size ushr 16) and 0xff).toByte(),
            ((size ushr 8) and 0xff).toByte(),
            (size and 0xff).toByte(),
        ) + type.toByteArray(Charsets.ISO_8859_1) + payload
    }

    private fun pngHeader(width: Int, height: Int, cicpTransfer: Int? = null): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        out.write(byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ))
        out.write(byteArrayOf(0, 0, 0, 13))
        out.write("IHDR".toByteArray(Charsets.ISO_8859_1))
        out.write(
            byteArrayOf(
                ((width ushr 24) and 0xff).toByte(),
                ((width ushr 16) and 0xff).toByte(),
                ((width ushr 8) and 0xff).toByte(),
                (width and 0xff).toByte(),
                ((height ushr 24) and 0xff).toByte(),
                ((height ushr 16) and 0xff).toByte(),
                ((height ushr 8) and 0xff).toByte(),
                (height and 0xff).toByte(),
                8, 6, 0, 0, 0,
            ),
        )
        out.write(byteArrayOf(0, 0, 0, 0)) // CRC (not validated by the probe)
        if (cicpTransfer != null) {
            out.write(box("cICP", byteArrayOf(1, 13, cicpTransfer.toByte(), 1)))
        }
        return out.toByteArray()
    }
}
