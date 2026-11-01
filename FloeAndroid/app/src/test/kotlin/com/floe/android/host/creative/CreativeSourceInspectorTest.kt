// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The host measures the actual staged bytes; these vectors prove the parser
 * reads width/height/duration/rotation from real container headers instead of
 * trusting a UI string or a recorded project field.
 */
class CreativeSourceInspectorTest {
    private fun bytes(vararg parts: ByteArray): ByteArray {
        val total = parts.sumOf { it.size }
        val result = ByteArray(total)
        var offset = 0
        for (part in parts) {
            part.copyInto(result, offset)
            offset += part.size
        }
        return result
    }

    private fun tail(size: Int): ByteArray = ByteArray(size)

    private fun png(width: Int, height: Int): ByteArray {
        val header = byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
        val chunk = ByteArray(25)
        chunk[3] = 13
        "IHDR".toByteArray(Charsets.US_ASCII).copyInto(chunk, 4)
        writeU32(chunk, 8, width)
        writeU32(chunk, 12, height)
        chunk[16] = 8
        chunk[17] = 6
        return bytes(header, chunk)
    }

    private fun jpeg(width: Int, height: Int): ByteArray {
        val app0 = byteArrayOf(0xFF.toByte(), 0xE0.toByte(), 0x00, 0x10) + tail(14)
        val sof = byteArrayOf(
            0xFF.toByte(), 0xC0.toByte(), 0x00, 0x10, 0x08,
            (height shr 8).toByte(), height.toByte(),
            (width shr 8).toByte(), width.toByte(),
            0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01)
        return bytes(byteArrayOf(0xFF.toByte(), 0xD8.toByte()), app0, sof)
    }

    private fun gif(width: Int, height: Int): ByteArray =
        bytes(
            "GIF89a".toByteArray(Charsets.US_ASCII),
            byteArrayOf((width and 0xFF).toByte(), (width shr 8).toByte()),
            byteArrayOf((height and 0xFF).toByte(), (height shr 8).toByte()),
            tail(6))

    private fun bmp(width: Int, height: Int): ByteArray {
        val value = ByteArray(30)
        value[0] = 'B'.code.toByte()
        value[1] = 'M'.code.toByte()
        writeU32(value, 14, 40)
        writeU32(value, 18, width)
        writeU32(value, 22, height)
        return value
    }

    private fun webpVp8x(width: Int, height: Int): ByteArray {
        val value = ByteArray(40)
        "RIFF".toByteArray(Charsets.US_ASCII).copyInto(value, 0)
        "WEBP".toByteArray(Charsets.US_ASCII).copyInto(value, 8)
        "VP8X".toByteArray(Charsets.US_ASCII).copyInto(value, 12)
        writeU32(value, 16, 10)
        val w = width - 1
        val h = height - 1
        value[24] = (w and 0xFF).toByte()
        value[25] = ((w shr 8) and 0xFF).toByte()
        value[26] = ((w shr 16) and 0xFF).toByte()
        value[27] = (h and 0xFF).toByte()
        value[28] = ((h shr 8) and 0xFF).toByte()
        value[29] = ((h shr 16) and 0xFF).toByte()
        return value
    }

    private fun isoBmff(width: Int, height: Int, durationMs: Long,
                        rotation: Double = 0.0): ByteArray {
        val mvhdPayload = ByteArray(108)
        mvhdPayload[0] = 0
        writeU32(mvhdPayload, 12, 1000)
        writeU32(mvhdPayload, 16, durationMs.toInt())
        val mvhd = box("mvhd", mvhdPayload)

        val tkhdPayload = ByteArray(84)
        tkhdPayload[0] = 0
        val (a, b) = when (rotation.toInt()) {
            90 -> 0 to 0x00010000
            180 -> -0x00010000 to 0
            270 -> 0 to -0x00010000
            else -> 0x00010000 to 0
        }
        writeU32(tkhdPayload, 40, a)
        writeU32(tkhdPayload, 44, b)
        tkhdPayload[48] = 0
        tkhdPayload[52] = 0
        writeU32(tkhdPayload, 76, width shl 16)
        writeU32(tkhdPayload, 80, height shl 16)
        val tkhd = box("tkhd", tkhdPayload)
        val trak = box("trak", tkhd)
        val moov = box("moov", bytes(mvhd, trak))
        val ftyp = box("ftyp", "isom".toByteArray(Charsets.US_ASCII) + tail(4))
        return bytes(ftyp, moov)
    }

    private fun box(type: String, payload: ByteArray): ByteArray {
        val header = ByteArray(8)
        writeU32(header, 0, payload.size + 8)
        type.toByteArray(Charsets.US_ASCII).copyInto(header, 4)
        return bytes(header, payload)
    }

    private fun writeU32(target: ByteArray, offset: Int, value: Int) {
        target[offset] = ((value ushr 24) and 0xFF).toByte()
        target[offset + 1] = ((value ushr 16) and 0xFF).toByte()
        target[offset + 2] = ((value ushr 8) and 0xFF).toByte()
        target[offset + 3] = (value and 0xFF).toByte()
    }

    private fun tempFile(value: ByteArray): File {
        val directory = File(
            System.getProperty("java.io.tmpdir"),
            "floe-inspector-${java.util.UUID.randomUUID()}")
        directory.mkdirs()
        val file = File(directory, "source.bin")
        file.writeBytes(value)
        return file
    }

    @Test
    fun `png and jpeg headers are measured from bytes`() {
        val pngHeader = CreativeSourceInspector.inspect(png(640, 480))
        assertNotNull(pngHeader)
        assertEquals(CreativeSourceKind.IMAGE, pngHeader!!.kind)
        assertEquals("image/png", pngHeader.mimeType)
        assertEquals(640, pngHeader.width)
        assertEquals(480, pngHeader.height)

        val jpegHeader = CreativeSourceInspector.inspect(jpeg(1920, 1080))
        assertNotNull(jpegHeader)
        assertEquals("image/jpeg", jpegHeader!!.mimeType)
        assertEquals(1920, jpegHeader.width)
        assertEquals(1080, jpegHeader.height)
    }

    @Test
    fun `gif bmp and webp headers are measured from bytes`() {
        val gifHeader = CreativeSourceInspector.inspect(gif(320, 200))
        assertEquals(320, gifHeader?.width)
        assertEquals(200, gifHeader?.height)

        val bmpHeader = CreativeSourceInspector.inspect(bmp(800, 600))
        assertEquals(800, bmpHeader?.width)
        assertEquals(600, bmpHeader?.height)

        val webpHeader = CreativeSourceInspector.inspect(webpVp8x(1024, 768))
        assertEquals("image/webp", webpHeader?.mimeType)
        assertEquals(1024, webpHeader?.width)
        assertEquals(768, webpHeader?.height)
    }

    @Test
    fun `mp4 moov is parsed for dimensions duration and rotation`() {
        val header = CreativeSourceInspector.inspect(isoBmff(1280, 720, 12_500))
        assertNotNull(header)
        assertEquals(CreativeSourceKind.VIDEO, header!!.kind)
        assertEquals("video/mp4", header.mimeType)
        assertEquals(1280, header.width)
        assertEquals(720, header.height)
        assertEquals(12.5, header.durationSeconds!!, 0.0001)
        assertEquals(0.0, header.rotationDegrees!!, 0.0001)

        val rotated = CreativeSourceInspector.inspect(
            isoBmff(1920, 1080, 4_000, rotation = 90.0))
        assertEquals(CreativeSourceKind.VIDEO, rotated!!.kind)
        // A 90-degree track displays portrait: the canvas must follow the
        // displayed orientation, and the rotation survives as metadata.
        assertEquals(1080, rotated.width)
        assertEquals(1920, rotated.height)
        assertEquals(90.0, rotated.rotationDegrees!!, 0.0001)
    }

    @Test
    fun `audio magic and unknown bytes are classified honestly`() {
        val mp3 = CreativeSourceInspector.inspect(
            bytes("ID3".toByteArray(Charsets.US_ASCII), tail(32)))
        assertEquals(CreativeSourceKind.AUDIO, mp3?.kind)
        assertEquals("audio/mpeg", mp3?.mimeType)

        assertNull(CreativeSourceInspector.inspect(ByteArray(64) { 0x7F }))
    }

    @Test
    fun `file inspection reads a large staged copy with the real header`() {
        val value = png(900, 700) + ByteArray(2 shl 20)
        val file = tempFile(value)
        try {
            val header = CreativeSourceInspector.inspect(file)
            assertEquals(900, header?.width)
            assertEquals(700, header?.height)
        } finally {
            file.parentFile?.deleteRecursively()
        }
    }

    @Test
    fun `truncated image headers are not reported as measurements`() {
        assertNull(CreativeSourceInspector.inspect(ByteArray(8)))
        assertTrue(CreativeSourceInspector.inspect(png(640, 480))!!.width == 640)
    }
}
