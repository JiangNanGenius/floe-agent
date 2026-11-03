// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.revisionreview

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM tests for the retained-snapshot preview receipt. No Parcel,
 * Android framework, file, provider or engine is involved.
 */
class OfficeConflictPreviewContractTest {

    private fun receipt(
        recordId: String = "record-1",
        role: OfficeConflictPreviewRole = OfficeConflictPreviewRole.MINE,
        snapshotSha256: String = "b".repeat(64),
        relativePath: String = "review-12345678-1234-1234-1234-123456789012/mine.preview",
    ): OfficeConflictPreviewAnswer = OfficeConflictPreviewAnswer(
        ready = true,
        recordId = recordId,
        role = role,
        snapshotSha256 = snapshotSha256,
        snapshotBytes = 1_024L,
        relativePath = relativePath,
        previewSha256 = "e".repeat(64),
        previewBytes = 256L,
        truncated = false,
        leaseId = "lease-1",
        reason = null,
    )

    @Test
    fun receiptBindsToTheExactRecordRoleAndSourceDigest() {
        val answer = receipt()
        assertTrue(answer.matches("record-1", OfficeConflictPreviewRole.MINE, "b".repeat(64)))
        assertFalse(answer.matches("record-2", OfficeConflictPreviewRole.MINE, "b".repeat(64)))
        assertFalse(answer.matches("record-1", OfficeConflictPreviewRole.CURRENT, "b".repeat(64)))
        assertFalse(answer.matches("record-1", OfficeConflictPreviewRole.MINE, "c".repeat(64)))
    }

    @Test
    fun relativePathRejectsEscapesAndTheOtherRoleLeaf() {
        val mine = "review-12345678-1234-1234-1234-123456789012/mine.preview"
        assertTrue(OfficeConflictPreviewNaming.isValidRelativePath(mine, OfficeConflictPreviewRole.MINE))
        assertFalse(OfficeConflictPreviewNaming.isValidRelativePath(mine, OfficeConflictPreviewRole.CURRENT))
        assertFalse(
            OfficeConflictPreviewNaming.isValidRelativePath(
                "/data/user/0/com.floe.android/files/review-12345678-1234-1234-1234-123456789012/mine.preview",
                OfficeConflictPreviewRole.MINE,
            ),
        )
        assertFalse(
            OfficeConflictPreviewNaming.isValidRelativePath(
                "review-..%2F/mine.preview",
                OfficeConflictPreviewRole.MINE,
            ),
        )
        assertFalse(
            OfficeConflictPreviewNaming.isValidRelativePath(
                "review-12345678-1234-1234-1234-123456789012/../mine.preview",
                OfficeConflictPreviewRole.MINE,
            ),
        )
        assertNull(
            OfficeConflictPreviewNaming.relativePath(
                "not-a-review-dir",
                OfficeConflictPreviewRole.MINE,
            ),
        )
    }

    @Test
    fun refusedAnswerNeverCarriesAReadableReceipt() {
        val refused = OfficeConflictPreviewAnswer.refused(
            reason = "snapshotMismatch",
            recordId = "record-1",
            role = OfficeConflictPreviewRole.CURRENT,
            snapshotSha256 = "c".repeat(64),
            snapshotBytes = 2_048L,
        )
        assertFalse(refused.ready)
        assertEquals("snapshotMismatch", refused.reason)
        assertNull(refused.relativePath)
        assertNull(refused.previewSha256)
        assertNull(refused.leaseId)
        assertEquals(0L, refused.previewBytes)
        assertFalse(refused.matches("record-1", OfficeConflictPreviewRole.CURRENT, "c".repeat(64)))
    }

    @Test
    fun genericReviewDescriptorStillCarriesNoContentOrPath() {
        val answer = OfficeConflictReviewAnswer(
            state = OfficeConflictReviewState.CHANGED,
            recordId = "record-1",
            baseSha256 = "a".repeat(64),
            baseRevision = "rev-a",
            mineSha256 = "b".repeat(64),
            mineBytes = 1_024L,
            currentSha256 = "c".repeat(64),
            currentBytes = 2_048L,
            currentRevision = "rev-b",
            canKeepCurrent = true,
            canPreserveMineAsCopy = true,
            canRetryOriginalCas = false,
            reason = null,
        )
        val line = answer.descriptorLine()
        assertFalse(line.contains("preview"))
        assertFalse(line.contains("Hello"))
        assertFalse(line.contains("/"))
        assertEquals(13, line.split('|').size)
    }
}
