// SPDX-License-Identifier: MPL-2.0
package com.floe.android.designintegration

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source-authored receipt identity tests (NOT RUN).
 *
 * These cover the pure captured-owner identity and display-name bounds used by
 * the verified design artifact opener; they do not touch a real provider,
 * Root, bitmap decoder or device.
 */
class DesignArtifactReceiptTest {
    private fun capture(
        rootPath: String = "/accepted/root/DesignArtifacts/Previews",
        relativePath: String = "target/revision.png",
        sha256: String = "a".repeat(64),
        byteCount: Long = 12,
        ownerRevision: Long = 3,
        candidateID: String? = "candidate-1",
        revisionID: String? = "revision-1",
        kind: DesignArtifactAccess.DesignArtifactKind =
            DesignArtifactAccess.DesignArtifactKind.PREVIEW,
    ) = DesignArtifactAccess.DesignArtifactCapture(
        epoch = 7,
        targetKey = "canvasNode|canvas|document|node|session",
        rootPath = rootPath,
        relativePath = relativePath,
        file = File(rootPath, relativePath),
        byteCount = byteCount,
        sha256 = sha256,
        format = "png",
        ownerRevision = ownerRevision,
        candidateID = candidateID,
        revisionID = revisionID,
        kind = kind,
    )

    @Test
    fun receiptIdentityIncludesTargetRootPathDigestRevisionAndKind() {
        val base = capture()
        assertEquals(base.key, capture().key)
        assertNotEquals(base.key, capture(rootPath = "/accepted/root/Other").key)
        assertNotEquals(base.key, capture(relativePath = "target/other.png").key)
        assertNotEquals(base.key, capture(sha256 = "b".repeat(64)).key)
        assertNotEquals(base.key, capture(ownerRevision = 4).key)
        assertNotEquals(base.key, capture(candidateID = "candidate-2").key)
        assertNotEquals(base.key, capture(revisionID = "revision-2").key)
        assertNotEquals(
            base.key,
            capture(kind = DesignArtifactAccess.DesignArtifactKind.EXPORT).key,
        )
    }

    @Test
    fun receiptMimeAndNameAreTypedAndBounded() {
        val pdf = capture(relativePath = "target/revision.pdf").copy(format = "pdf")
        assertEquals("application/pdf", pdf.mimeType)
        assertEquals("revision.pdf", pdf.suggestedName)
        val unsafe = capture(relativePath = "target/../../.hidden name.md")
            .copy(format = "md")
        assertEquals("text/markdown", unsafe.mimeType)
        assertTrue(unsafe.suggestedName.length <= 120)
        assertTrue(!unsafe.suggestedName.startsWith("."))
        val unnamed = capture(relativePath = "target/").copy(format = "json")
        assertTrue(unnamed.suggestedName.endsWith(".json"))
    }
}
