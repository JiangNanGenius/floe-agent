// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.media

import com.floe.android.core.notesmedia.source.VerifiedMediaSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Regression for the corrected Notes identity rule (2026-10-30): a page's
 * drawing/background/office resource ID is the authority's opaque resource
 * UUID (`ImportedResource.resourceID`), NOT the CAS/SHA-256 digest. The digest
 * is a byte-verification fact and stays separate in the descriptor.
 */
class ResourceIdentityTest {

    private val sha = "b".repeat(64)
    private val uuid = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    @Test
    fun resourceIdIsOpaqueUuidWhileShaStaysAVerificationFact() {
        val file = File(System.getProperty("java.io.tmpdir"), "resource-identity-${System.nanoTime()}.pdf")
        file.writeBytes(byteArrayOf(1, 2, 3))
        file.deleteOnExit()
        val snapshot = VerifiedMediaSnapshot(
            file = file.absoluteFile,
            sha256 = sha,
            byteCount = 3,
            mediaType = NotesMediaType.PDF,
            displayName = "page.pdf",
        )
        val descriptor = snapshot.descriptor(uuid, MediaEditability.READ_ONLY)
        assertEquals("resource id must be the authority UUID", uuid, descriptor.resourceId)
        assertEquals("a PDF is not stamped with the ink container version", 0, descriptor.formatVersion)
        assertNotEquals("the digest is not the resource id", descriptor.sha256, descriptor.resourceId)
        assertTrue(Sha256.isValid(descriptor.sha256))
        assertTrue("UUIDs are valid opaque resource ids", ResourceIdPolicy.isValid(uuid))
        assertTrue(ResourceIdPolicy.isValid(descriptor.resourceId))
        assertEquals(3L, descriptor.byteCount)
    }

    @Test
    fun resourceIdPolicyRejectsPathSmugglingButNotUuidHyphens() {
        assertTrue(ResourceIdPolicy.isValid("3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
        assertTrue(ResourceIdPolicy.isValid("resource_01"))
        assertFalse(ResourceIdPolicy.isValid("../escape"))
        assertFalse(ResourceIdPolicy.isValid("a/b"))
        assertFalse(ResourceIdPolicy.isValid(""))
        assertFalse(ResourceIdPolicy.isValid(null))
        assertFalse(ResourceIdPolicy.isValid("x".repeat(ResourceIdPolicy.MAX_CHARS + 1)))
    }

    @Test
    fun descriptorRequiresBothIdentitiesIndependently() {
        val good = MediaResourceDescriptor(
            resourceId = uuid,
            mediaType = NotesMediaType.PDF,
            formatVersion = 1,
            byteCount = 3,
            sha256 = sha,
            editable = MediaEditability.READ_ONLY,
        )
        assertEquals(uuid, good.resourceId)
        var threw = false
        try {
            good.copy(sha256 = "not-a-digest")
        } catch (_: IllegalArgumentException) {
            threw = true
        }
        assertTrue("an invalid digest is refused by the descriptor itself", threw)
    }
}
