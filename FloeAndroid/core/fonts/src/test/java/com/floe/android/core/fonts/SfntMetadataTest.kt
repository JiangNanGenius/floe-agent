// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.fonts

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class SfntMetadataTest {
    private fun withFont(bytes: ByteArray, check: (File) -> Unit) {
        val file = File.createTempFile("floe-font-", ".ttf")
        try { file.writeBytes(bytes); check(file) } finally { file.delete() }
    }
    private fun fixture(): ByteArray {
        val name = "Floe Test".toByteArray(Charsets.UTF_16BE)
        return ByteBuffer.allocate(46 + name.size).order(ByteOrder.BIG_ENDIAN).apply {
            putInt(0x00010000); putShort(1); putShort(0); putShort(0); putShort(0)
            putInt(0x6e616d65); putInt(0); putInt(28); putInt(18 + name.size)
            putShort(0); putShort(1); putShort(18)
            putShort(3); putShort(1); putShort(0x409); putShort(4); putShort(name.size.toShort()); putShort(0)
            put(name)
        }.array()
    }
    @Test fun readsBoundedUnicodeName() = withFont(fixture()) { assertEquals(listOf("Floe Test"), SfntMetadata.faceNames(it)) }
    @Test fun preservesNamesForIosProjectResolution() = withFont(fixture()) {
        assertEquals(listOf("Floe Test"), SfntMetadata.metadata(it).single().aliases)
    }
    @Test fun rejectsTableOutsideFile() {
        val bytes = fixture(); ByteBuffer.wrap(bytes).putInt(20, Int.MAX_VALUE)
        withFont(bytes) { f -> assertThrows(IllegalArgumentException::class.java) { SfntMetadata.faceNames(f) } }
    }
    @Test fun rejectsNameOutsideTable() {
        val bytes = fixture(); ByteBuffer.wrap(bytes).putShort(44, 30000)
        withFont(bytes) { f -> assertThrows(IllegalArgumentException::class.java) { SfntMetadata.faceNames(f) } }
    }
    @Test fun rejectsExcessiveCollectionFaces() {
        val bytes = ByteBuffer.allocate(12).putInt(0x74746366).putInt(0x00010000).putInt(33).array()
        withFont(bytes) { f -> assertThrows(IllegalArgumentException::class.java) { SfntMetadata.faceNames(f) } }
    }
    @Test fun rejectsTruncatedCollectionOffsets() {
        val bytes = ByteBuffer.allocate(12).putInt(0x74746366).putInt(0x00010000).putInt(2).array()
        withFont(bytes) { f -> assertThrows(IllegalArgumentException::class.java) { SfntMetadata.faceNames(f) } }
    }
    @Test fun rejectsUnrecognizedFont() = withFont(ByteArray(64)) { f ->
        assertThrows(IllegalArgumentException::class.java) { SfntMetadata.faceNames(f) }
    }
    @Test fun doesNotClaimMetadataParsingIsTypefaceAdmission() {
        // This deliberately lacks glyph tables. Parser output alone is never
        // a registered font; the store separately requires Typeface.Builder.
        withFont(fixture()) { assertTrue(SfntMetadata.faceNames(it).isNotEmpty()) }
    }
}
