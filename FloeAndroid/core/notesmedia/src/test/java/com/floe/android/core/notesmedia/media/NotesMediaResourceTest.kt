// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

class NotesMediaResourceTest {

    @Test
    fun mediaBindingsDecideEditabilityNotTheCaller() {
        assertEquals(MediaEditability.EDITABLE, MediaBindings.resolve(NotesMediaType.FLOE_INK, 1))
        assertEquals(MediaEditability.PRESERVE_ONLY, MediaBindings.resolve(NotesMediaType.APPLE_PENCILKIT, 1))
        assertEquals(MediaEditability.READ_ONLY, MediaBindings.resolve(NotesMediaType.PDF, 0))
        assertNull(MediaBindings.resolve(NotesMediaType.FLOE_INK, 99))
        assertNull(MediaBindings.resolve("application/unknown", 1))
        assertNull(MediaBindings.resolve(null, 1))
    }

    @Test
    fun resourceIdsCannotCarryPathSegments() {
        assertTrue(ResourceIdPolicy.isValid("res_1.a-b"))
        assertFalse(ResourceIdPolicy.isValid(null))
        assertFalse(ResourceIdPolicy.isValid(""))
        assertFalse(ResourceIdPolicy.isValid("../escape"))
        assertFalse(ResourceIdPolicy.isValid("a/b"))
        assertFalse(ResourceIdPolicy.isValid("a..b"))
        assertFalse(ResourceIdPolicy.isValid("x".repeat(ResourceIdPolicy.MAX_CHARS + 1)))
    }

    @Test
    fun sha256HexMatchesTheKnownVector() {
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            Sha256.hex("abc".toByteArray()),
        )
        assertTrue(Sha256.isValid("a".repeat(64)))
        assertFalse(Sha256.isValid("A".repeat(64)))
    }

    @Test
    fun descriptorValidatesIdentityFields() {
        val descriptor = MediaResourceDescriptor(
            resourceId = "res-1",
            mediaType = NotesMediaType.FLOE_INK,
            formatVersion = InkFormat.CURRENT,
            byteCount = 12,
            sha256 = "b".repeat(64),
            editable = MediaEditability.EDITABLE,
        )
        assertEquals("res-1", descriptor.resourceId)
        var threw = false
        try {
            descriptor.copy(byteCount = 0)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw)
    }

    @Test
    fun foreignInkIsCopiedVerbatimAndOnlyRefusesEditing() {
        val bytes = byteArrayOf(9, 8, 7, 6)
        val descriptor = MediaResourceDescriptor(
            resourceId = "pencil-1",
            mediaType = NotesMediaType.APPLE_PENCILKIT,
            formatVersion = 0,
            byteCount = bytes.size.toLong(),
            sha256 = Sha256.hex(bytes),
            editable = MediaEditability.PRESERVE_ONLY,
        )
        val foreign = ForeignInkResource(descriptor, bytes)
        assertTrue(foreign.identityHolds())
        assertEquals(InkEditRefusal.FOREIGN_INK_FORMAT, foreign.requestEdit())
        val out = ByteArrayOutputStream()
        foreign.copyTo { out }
        assertTrue(out.toByteArray().contentEquals(bytes))
    }

    @Test
    fun foreignInkCannotBeConstructedForEditableMedia() {
        val bytes = byteArrayOf(1)
        val descriptor = MediaResourceDescriptor(
            resourceId = "ink-1",
            mediaType = NotesMediaType.FLOE_INK,
            formatVersion = 1,
            byteCount = 1,
            sha256 = Sha256.hex(bytes),
            editable = MediaEditability.EDITABLE,
        )
        var threw = false
        try {
            ForeignInkResource(descriptor, bytes)
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw)
    }

    @Test
    fun inkFormatReadabilityIsBounded() {
        assertTrue(InkFormat.readable(InkFormat.CURRENT))
        assertFalse(InkFormat.readable(0))
        assertFalse(InkFormat.readable(InkFormat.CURRENT + 1))
        assertEquals(1, InkFormat.MIN_READABLE)
    }
}
