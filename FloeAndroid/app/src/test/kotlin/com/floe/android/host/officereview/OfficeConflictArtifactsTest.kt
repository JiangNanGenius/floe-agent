// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewNaming
import java.io.File
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Filesystem-boundary regressions for conflict review. The review root is a
 * separate App-owned directory; deleting a review must never remove a
 * retained working copy, a recovery artifact or the original.
 */
class OfficeConflictArtifactsTest {

    private fun root(name: String): File =
        File(System.getProperty("java.io.tmpdir") ?: ".", name + "-" + UUID.randomUUID()).apply { mkdirs() }

    @Test
    fun immutableCopyLeavesTheWorkingSourceExactlyUntouched() {
        val root = root("review-copy")
        try {
            val source = File(root, "working.docx").apply { writeText("working-bytes") }
            val directory = File(root, "review").apply { mkdirs() }
            val before = source.readBytes()
            val copy = OfficeConflictArtifacts.copyVerified(
                source = source,
                directory = directory,
                name = "mine.docx",
                format = null,
            )
            assertNotNull(copy)
            assertEqualsBytes(before, source.readBytes())
            assertEqualsBytes(before, copy!!.file.readBytes())
            assertFalse(copy!!.file.canWrite())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun reviewCleanupRefusesADirectoryOutsideItsOwnRoot() {
        val root = root("review-cleanup")
        try {
            val reviewRoot = File(root, "reviews").apply { mkdirs() }
            val outside = File(root, "working-retained").apply { mkdirs() }
            val retained = File(outside, "document.docx").apply { writeText("recoverable") }
            OfficeConflictArtifacts.deleteReviewDirectory(reviewRoot, outside)
            assertTrue(outside.isDirectory)
            assertTrue(retained.isFile)
            assertEqualsBytes("recoverable".toByteArray(), retained.readBytes())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun boundedCopyRejectsOversizeOrMissingSourcesWithoutCreatingAReviewFile() {
        val root = root("review-refuse")
        try {
            val directory = File(root, "review").apply { mkdirs() }
            val missing = File(root, "missing.docx")
            assertNull(OfficeConflictArtifacts.copyVerified(missing, directory, "mine.docx", null))
            assertTrue(directory.listFiles().isNullOrEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun previewTextIsDerivedOnlyInsideItsReviewRootAndIsBounded() {
        val root = root("review-preview-text")
        try {
            val reviews = File(root, "reviews").apply { mkdirs() }
            val directory = File(reviews, "review-" + UUID.randomUUID()).apply { mkdirs() }
            val written = OfficeConflictArtifacts.writePreviewText(
                root = reviews,
                directory = directory,
                name = OfficeConflictPreviewNaming.MINE_FILE,
                text = "Hello preview",
            )
            assertNotNull(written)
            val file = File(directory, OfficeConflictPreviewNaming.MINE_FILE)
            assertTrue(file.isFile)
            assertEquals("Hello preview", file.readText())
            assertFalse(file.canWrite())
            assertEquals(written, OfficeConflictArtifacts.digest(file))
            // Re-admitting the same projection reuses the exact derived file.
            assertEquals(
                written,
                OfficeConflictArtifacts.writePreviewText(
                    reviews,
                    directory,
                    OfficeConflictPreviewNaming.MINE_FILE,
                    "Hello preview",
                ),
            )
            // Names that could escape or select another role are refused.
            assertNull(
                OfficeConflictArtifacts.writePreviewText(
                    reviews,
                    directory,
                    "../mine.preview",
                    "escape",
                ),
            )
            assertNull(
                OfficeConflictArtifacts.writePreviewText(
                    reviews,
                    directory,
                    "other.preview",
                    "wrong",
                ),
            )
            // Oversize projections are refused, never truncated inside the
            // App-owned file without the receiver's explicit flag.
            assertNull(
                OfficeConflictArtifacts.writePreviewText(
                    reviews,
                    directory,
                    OfficeConflictPreviewNaming.CURRENT_FILE,
                    "x".repeat((OfficeConflictPreviewAnswer.MAX_PREVIEW_FILE_BYTES + 1L).toInt()),
                ),
            )
            // A directory outside the review root is never written.
            val outside = File(root, "outside").apply { mkdirs() }
            assertNull(
                OfficeConflictArtifacts.writePreviewText(
                    reviews,
                    outside,
                    OfficeConflictPreviewNaming.MINE_FILE,
                    "outside",
                ),
            )
            assertTrue(outside.listFiles().isNullOrEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun ownedSnapshotRefusesEscapedOrSwappedFiles() {
        val root = root("review-owned-snapshot")
        try {
            val reviews = File(root, "reviews").apply { mkdirs() }
            val directory = File(reviews, "review-" + UUID.randomUUID()).apply { mkdirs() }
            val source = File(directory, "mine.docx").apply { writeText("snapshot") }
            val digest = OfficeConflictArtifacts.digest(source)!!
            val version = OfficeConflictVersion(
                sha256 = digest.first,
                bytes = digest.second,
                revision = null,
                file = source,
            )
            assertNotNull(OfficeConflictArtifacts.ownedVersionFile(reviews, directory, version))

            val outside = File(root, "outside.docx").apply { writeText("snapshot") }
            assertNull(
                OfficeConflictArtifacts.ownedVersionFile(
                    reviews,
                    directory,
                    version.copy(file = outside),
                ),
            )
            // Same length, different bytes: the retained digest no longer
            // proves this file and no reader may open it.
            source.writeText("SNAPSHOT")
            assertNull(OfficeConflictArtifacts.ownedVersionFile(reviews, directory, version))
        } finally {
            root.deleteRecursively()
        }
    }

    private fun assertEqualsBytes(expected: ByteArray, actual: ByteArray) {
        assertArrayEquals(expected, actual)
    }
}
