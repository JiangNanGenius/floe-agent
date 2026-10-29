// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ImageHeaderReaderTest {

    @Test
    fun readsPngIhdrDimensions() {
        val png = byteArrayOf(
            0x89.toByte(), 0x50.toByte(), 0x4E.toByte(), 0x47.toByte(),
            0x0D.toByte(), 0x0A.toByte(), 0x1A.toByte(), 0x0A.toByte(),
            0, 0, 0, 13,
            'I'.code.toByte(), 'H'.code.toByte(), 'D'.code.toByte(), 'R'.code.toByte(),
            0, 0, 0x04.toByte(), 0xB0.toByte(), // 1200
            0, 0, 0x06.toByte(), 0x40.toByte(), // 1600
        )
        assertEquals(1200 to 1600, ImageHeaderReader.read(png))
    }

    @Test
    fun readsJpegSofDimensions() {
        val jpeg = byteArrayOf(
            0xFF.toByte(), 0xD8.toByte(),
            0xFF.toByte(), 0xC0.toByte(), 0x00, 0x11, 0x08,
            0x00, 0x10, // height 16
            0x00, 0x20, // width 32
            0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
        )
        assertEquals(32 to 16, ImageHeaderReader.read(jpeg))
    }

    @Test
    fun garbageIsRejectedInsteadOfGuessed() {
        assertNull(ImageHeaderReader.read(byteArrayOf(1, 2, 3, 4)))
        assertNull(ImageHeaderReader.read(ByteArray(0)))
        assertNull(ImageHeaderReader.read("not an image".toByteArray()))
        // A PNG signature without a valid IHDR size.
        val truncated = byteArrayOf(
            0x89.toByte(), 0x50.toByte(), 0x4E.toByte(), 0x47.toByte(),
            0x0D.toByte(), 0x0A.toByte(), 0x1A.toByte(), 0x0A.toByte(), 0, 0, 0, 13,
        )
        assertNull(ImageHeaderReader.read(truncated))
    }
}
