// SPDX-License-Identifier: MPL-2.0
//
// Focused JVM test for the capture artifact's structural PNG walk.
package com.floe.android.host.cad

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class C04CadPngTest {
    private fun chunk(type: String, data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        val length = data.size
        out.write(byteArrayOf(
            (length ushr 24).toByte(), (length ushr 16).toByte(),
            (length ushr 8).toByte(), length.toByte(),
        ))
        out.write(type.toByteArray(Charsets.US_ASCII))
        out.write(data)
        out.write(byteArrayOf(0, 0, 0, 0)) // CRC is not needed for the walk
        return out.toByteArray()
    }

    private fun png(width: Int, height: Int, idat: Boolean = true): ByteArray {
        val header = ByteArrayOutputStream().apply {
            write(byteArrayOf(
                (width ushr 24).toByte(), (width ushr 16).toByte(),
                (width ushr 8).toByte(), width.toByte(),
                (height ushr 24).toByte(), (height ushr 16).toByte(),
                (height ushr 8).toByte(), height.toByte(),
                8, 6, 0, 0, 0,
            ))
        }.toByteArray()
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        ))
        out.write(chunk("IHDR", header))
        if (idat) out.write(chunk("IDAT", byteArrayOf(1, 2, 3)))
        out.write(chunk("IEND", ByteArray(0)))
        return out.toByteArray()
    }

    @Test
    fun acceptsACompletePngAndReadsItsActualDimensions() {
        val info = C04CadPng.inspect(png(640, 480))
        assertNotNull(info)
        assertEquals(640, info!!.width)
        assertEquals(480, info.height)
        assertEquals(33, info.header.size)
        assertEquals(3, info.chunkCount)
    }

    @Test
    fun refusesTruncatedOrMissingImageData() {
        val complete = png(640, 480)
        assertNull(C04CadPng.inspect(complete.copyOf(complete.size - 1)))
        assertNull(C04CadPng.inspect(png(640, 480, idat = false)))
    }

    @Test
    fun textureWalkAcceptsSmallButStructurallyCompletePng() {
        val info = C04CadPng.inspectTexture(png(1, 1))
        assertNotNull(info)
        assertEquals(1, info!!.width)
        assertEquals(1, info.height)
        assertNull(C04CadPng.inspect(png(1, 1)))
    }
}
