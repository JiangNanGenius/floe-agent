// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officereview

import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewNaming
import com.floe.android.core.officeengine.revisionreview.OfficeConflictPreviewRole
import com.floe.android.core.officeengine.revisionreview.OfficeConflictResolutionResult
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAction
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewAnswer
import com.floe.android.core.officeengine.revisionreview.OfficeConflictReviewState
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM tests for the C08 original-version review transaction. The fake
 * host returns only files/SHAs; no Android, provider or engine is used.
 */
class OfficeConflictReviewPolicyTest {

    private class FakeHost(
        var identity: OfficeConflictReviewIdentity?,
        var mine: OfficeConflictVersion?,
        var current: OfficeConflictVersion?,
    ) : OfficeConflictReviewHost {
        var deleted = false
        var previewCalls = 0
        var previewGate: CountDownLatch? = null
        val previewStarted = AtomicBoolean(false)

        override fun liveIdentity(sessionToken: String, generation: Long): OfficeConflictReviewIdentity? {
            val value = identity ?: return null
            return value.takeIf { it.sessionToken == sessionToken && it.generation == generation }
        }

        override fun captureMine(
            identity: OfficeConflictReviewIdentity,
            directory: File,
        ): OfficeConflictVersion? = mine

        override fun captureCurrent(
            identity: OfficeConflictReviewIdentity,
            directory: File,
        ): OfficeConflictVersion? = current

        override fun buildPreview(
            version: OfficeConflictVersion,
            directory: File,
            role: OfficeConflictPreviewRole,
            fileName: String,
            format: String,
            maxChars: Int,
        ): OfficeConflictPreviewBuild {
            previewCalls += 1
            previewGate?.let { gate ->
                previewStarted.set(true)
                gate.await(5, TimeUnit.SECONDS)
            }
            val text = "preview fixture"
            File(directory, fileName).writeText(text)
            return OfficeConflictPreviewBuild.Ready("e".repeat(64), text.toByteArray().size.toLong(), false)
        }

        override fun deleteReviewDirectory(directory: File) {
            deleted = true
            directory.deleteRecursively()
        }
    }

    private fun tempRoot(name: String): File =
        File(System.getProperty("java.io.tmpdir") ?: ".", name + "-" + UUID.randomUUID()).apply { mkdirs() }

    private fun tempFile(root: File, name: String): File =
        File(root, name).apply {
            parentFile?.mkdirs()
            writeText("fixture")
        }

    private fun version(root: File, name: String, sha: String, revision: String? = null): OfficeConflictVersion {
        val file = tempFile(root, name)
        return OfficeConflictVersion(sha, file.length(), revision, file)
    }

    private fun identity(
        root: File,
        baseSha: String = "a".repeat(64),
        baseRevision: String? = "rev-a",
        route: OfficeConflictRoute = OfficeConflictRoute.WORKSPACE,
    ): OfficeConflictReviewIdentity = OfficeConflictReviewIdentity(
        sessionToken = "session-1",
        generation = 7L,
        route = route,
        baseSha256 = baseSha,
        baseRevision = baseRevision,
        originalUri = "content://example/doc",
        ownerTaskId = "task",
        workspaceId = "workspace",
        nativeEpoch = 11L,
        hostGeneration = 3L,
        sourceLogicalPath = "notes/doc.docx",
        workingCopy = tempFile(root, "working.docx"),
        extension = "docx",
    )

    private fun coordinator(
        root: File,
        host: FakeHost,
    ): OfficeConflictReviewCoordinator = OfficeConflictReviewCoordinator(run {
        root.mkdirs()
        root
    }, host)

    @Test
    fun reviewCapturesBothVersionsAndRecordsARealConflict() {
        val root = tempRoot("conflict-review")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-1")
            assertEquals(OfficeConflictReviewState.CHANGED, answer.state)
            assertNotNull(answer.recordId)
            assertEquals("b".repeat(64), answer.mineSha256)
            assertEquals("c".repeat(64), answer.currentSha256)
            assertEquals("rev-b", answer.currentRevision)
            assertTrue(answer.canKeepCurrent)
            assertTrue(answer.canPreserveMineAsCopy)
            // The manual viewer owns no original CAS authority; this must not
            // be flipped by a UI state.
            assertFalse(answer.canRetryOriginalCas)
            assertEquals(1, coordinator.activeRecordCount())

            val resolved = coordinator.resolve(
                "session-1", 7L, answer.recordId!!, OfficeConflictReviewAction.KEEP_CURRENT,
            )
            assertTrue(resolved.accepted)
            assertEquals("keptCurrent", resolved.code)
            assertEquals(0, coordinator.activeRecordCount())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun unchangedOriginalDoesNotCreateAConflictRecord() {
        val root = tempRoot("conflict-unchanged")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "a".repeat(64), "rev-a"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-2")
            assertEquals(OfficeConflictReviewState.UNCHANGED, answer.state)
            assertNull(answer.recordId)
            assertFalse(answer.canKeepCurrent)
            assertEquals(0, coordinator.activeRecordCount())
            assertTrue(host.deleted)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun wrongGenerationIsFencedBeforeAnyRead() {
        val root = tempRoot("conflict-fenced")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "a".repeat(64), "rev-a"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 8L, "request-3")
            assertEquals(OfficeConflictReviewState.UNAVAILABLE, answer.state)
            assertEquals("sessionFenced", answer.reason)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun missingWorkingCopyIsAnHonestUnavailable() {
        val root = tempRoot("conflict-no-mine")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = null,
                current = version(root, "current", "a".repeat(64), "rev-a"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-4")
            assertEquals(OfficeConflictReviewState.UNAVAILABLE, answer.state)
            assertEquals("mineUnavailable", answer.reason)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun retryIsRefusedWithoutARealCasAuthority() {
        val root = tempRoot("conflict-retry")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-5")
            val result = coordinator.resolve(
                "session-1", 7L, answer.recordId!!, OfficeConflictReviewAction.RETRY_ORIGINAL_CAS,
            )
            assertFalse(result.accepted)
            assertEquals("originalCasUnavailable", result.code)
            // Nothing was written or silently resolved.
            assertEquals(1, coordinator.activeRecordCount())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun changedAgainReviewIsStaleAndNeverAdmitsRetry() {
        val root = tempRoot("conflict-stale")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-6")
            // Simulate the original changing again before the deliberate
            // decision; the coordinator re-reads it before mutating.
            host.current = version(root, "current-2", "d".repeat(64), "rev-c")
            val result = coordinator.resolve(
                "session-1", 7L, answer.recordId!!, OfficeConflictReviewAction.RETRY_ORIGINAL_CAS,
            )
            assertFalse(result.accepted)
            assertEquals("reviewStale", result.code)
            assertEquals(0, coordinator.activeRecordCount())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun unreadableRecheckRetainsTheReviewAndWritesNothing() {
        val root = tempRoot("conflict-recheck-unavailable")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-8")
            host.current = null
            val result = coordinator.resolve(
                "session-1", 7L, answer.recordId!!, OfficeConflictReviewAction.KEEP_CURRENT,
            )
            assertFalse(result.accepted)
            assertEquals("originalUnavailable", result.code)
            assertEquals(1, coordinator.activeRecordCount())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun foreignSessionCannotResolveTheRecord() {
        val root = tempRoot("conflict-foreign")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-7")
            val result = coordinator.resolve(
                "session-2", 7L, answer.recordId!!, OfficeConflictReviewAction.KEEP_CURRENT,
            )
            assertFalse(result.accepted)
            assertEquals("sessionMismatch", result.code)
            assertEquals(1, coordinator.activeRecordCount())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun previewServesTheExactRetainedRoleAndHoldsACleanupLease() {
        val root = tempRoot("conflict-preview")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val reviewRoot = File(root, "reviews")
            val coordinator = coordinator(reviewRoot, host)
            val answer = coordinator.review("session-1", 7L, "request-preview")
            val recordId = answer.recordId!!
            val preview = coordinator.preview(
                "session-1", 7L, recordId,
                OfficeConflictPreviewRole.MINE, "b".repeat(64),
            )
            assertTrue(preview.ready)
            assertEquals(answer.recordId, preview.recordId)
            assertEquals(OfficeConflictPreviewRole.MINE, preview.role)
            assertEquals("b".repeat(64), preview.snapshotSha256)
            assertEquals("e".repeat(64), preview.previewSha256)
            assertNotNull(preview.leaseId)
            assertNotNull(preview.relativePath)
            assertTrue(
                OfficeConflictPreviewNaming.isValidRelativePath(
                    preview.relativePath!!,
                    OfficeConflictPreviewRole.MINE,
                ),
            )
            assertEquals(
                OfficeConflictPreviewNaming.MINE_FILE,
                preview.relativePath!!.substringAfter('/'),
            )
            val directory = File(reviewRoot, preview.relativePath!!.substringBefore('/'))
            assertTrue(File(directory, OfficeConflictPreviewNaming.MINE_FILE).isFile)
            assertEquals(1, host.previewCalls)

            val resolved = coordinator.resolve(
                "session-1", 7L, recordId, OfficeConflictReviewAction.KEEP_CURRENT,
            )
            assertTrue(resolved.accepted)
            assertEquals(0, coordinator.activeRecordCount())
            // A live preview reader blocks cleanup even though the record is
            // retired and no new decision/preview may use it.
            assertTrue(directory.isDirectory)
            assertFalse(
                coordinator.preview(
                    "session-1", 7L, recordId,
                    OfficeConflictPreviewRole.CURRENT, "c".repeat(64),
                ).ready,
            )
            coordinator.releasePreview("session-1", 7L, preview.leaseId!!)
            assertFalse(directory.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun closingPreviewKeepsTheActiveRecordForAnotherLook() {
        val root = tempRoot("conflict-preview-back")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val reviewRoot = File(root, "reviews")
            val coordinator = coordinator(reviewRoot, host)
            val recordId = coordinator.review("session-1", 7L, "request-preview-back").recordId!!
            val minePreview = coordinator.preview(
                "session-1", 7L, recordId,
                OfficeConflictPreviewRole.MINE, "b".repeat(64),
            )
            assertTrue(minePreview.ready)
            val directory = File(reviewRoot, minePreview.relativePath!!.substringBefore('/'))
            // Back to review releases the lease but the record is still the
            // user's active comparison; its snapshots must stay retained.
            coordinator.releasePreview("session-1", 7L, minePreview.leaseId!!)
            assertTrue(directory.isDirectory)
            assertEquals(1, coordinator.activeRecordCount())

            val currentPreview = coordinator.preview(
                "session-1", 7L, recordId,
                OfficeConflictPreviewRole.CURRENT, "c".repeat(64),
            )
            assertTrue(currentPreview.ready)
            assertEquals(OfficeConflictPreviewRole.CURRENT, currentPreview.role)
            assertTrue(File(directory, OfficeConflictPreviewNaming.CURRENT_FILE).isFile)
            coordinator.releasePreview("session-1", 7L, currentPreview.leaseId!!)
            assertTrue(directory.isDirectory)

            val resolved = coordinator.resolve(
                "session-1", 7L, recordId, OfficeConflictReviewAction.KEEP_CURRENT,
            )
            assertTrue(resolved.accepted)
            assertFalse(directory.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun previewRefusesWrongDigestForeignRoleAndWrongOwner() {
        val root = tempRoot("conflict-preview-fence")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val coordinator = coordinator(File(root, "reviews"), host)
            val answer = coordinator.review("session-1", 7L, "request-preview-fence")
            val recordId = answer.recordId!!

            val wrongDigest = coordinator.preview(
                "session-1", 7L, recordId,
                OfficeConflictPreviewRole.MINE, "d".repeat(64),
            )
            assertFalse(wrongDigest.ready)
            assertEquals("snapshotMismatch", wrongDigest.reason)

            val wrongRoleDigest = coordinator.preview(
                "session-1", 7L, recordId,
                OfficeConflictPreviewRole.CURRENT, "b".repeat(64),
            )
            assertFalse(wrongRoleDigest.ready)
            assertEquals("snapshotMismatch", wrongRoleDigest.reason)

            val wrongOwner = coordinator.preview(
                "session-2", 7L, recordId,
                OfficeConflictPreviewRole.MINE, "b".repeat(64),
            )
            assertFalse(wrongOwner.ready)
            assertEquals("sessionMismatch", wrongOwner.reason)

            val wrongGeneration = coordinator.preview(
                "session-1", 8L, recordId,
                OfficeConflictPreviewRole.MINE, "b".repeat(64),
            )
            assertFalse(wrongGeneration.ready)
            assertEquals("sessionMismatch", wrongGeneration.reason)

            val wrongRecord = coordinator.preview(
                "session-1", 7L, "missing-record",
                OfficeConflictPreviewRole.MINE, "b".repeat(64),
            )
            assertFalse(wrongRecord.ready)
            assertEquals("reviewExpired", wrongRecord.reason)
            assertEquals(0, host.previewCalls)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun retiredSessionDoesNotServeAPreviewAndCleanupDrainsOnRefusal() {
        val root = tempRoot("conflict-preview-settle")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val reviewRoot = File(root, "reviews")
            val coordinator = coordinator(reviewRoot, host)
            val answer = coordinator.review("session-1", 7L, "request-preview-settle")
            val recordId = answer.recordId!!
            val preview = coordinator.preview(
                "session-1", 7L, recordId,
                OfficeConflictPreviewRole.MINE, "b".repeat(64),
            )
            assertTrue(preview.ready)
            val directory = File(reviewRoot, preview.relativePath!!.substringBefore('/'))
            coordinator.releaseSession("session-1")
            assertTrue(directory.isDirectory)
            val refused = coordinator.preview(
                "session-1", 7L, recordId,
                OfficeConflictPreviewRole.CURRENT, "c".repeat(64),
            )
            assertFalse(refused.ready)
            assertEquals("sessionFenced", refused.reason)
            coordinator.releasePreview("session-1", 7L, preview.leaseId!!)
            assertFalse(directory.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun previewRaceWithDecisionDrainsWithoutServingTheRetiredRecord() {
        val root = tempRoot("conflict-preview-race")
        try {
            val host = FakeHost(
                identity = identity(root),
                mine = version(root, "mine", "b".repeat(64)),
                current = version(root, "current", "c".repeat(64), "rev-b"),
            )
            val reviewRoot = File(root, "reviews")
            val coordinator = coordinator(reviewRoot, host)
            val answer = coordinator.review("session-1", 7L, "request-preview-race")
            val recordId = answer.recordId!!
            val gate = CountDownLatch(1)
            host.previewGate = gate
            val result = java.util.concurrent.atomic.AtomicReference<OfficeConflictPreviewAnswer?>()
            val reader = Thread {
                result.set(
                    coordinator.preview(
                        "session-1", 7L, recordId,
                        OfficeConflictPreviewRole.MINE, "b".repeat(64),
                    ),
                )
            }
            reader.start()
            assertTrue(waitFor { host.previewStarted.get() })
            val directory = reviewRoot.listFiles()!!.first { it.name.startsWith("review-") }
            val resolved = coordinator.resolve(
                "session-1", 7L, recordId, OfficeConflictReviewAction.KEEP_CURRENT,
            )
            assertTrue(resolved.accepted)
            assertTrue(directory.isDirectory)
            gate.countDown()
            reader.join(5_000L)
            assertFalse(reader.isAlive)
            val preview = result.get()
            assertNotNull(preview)
            // The decision won the race: no receipt is handed to the viewer
            // and the directory drains as soon as the reader exits.
            assertFalse(preview!!.ready)
            assertFalse(directory.exists())
        } finally {
            root.deleteRecursively()
        }
    }

    private fun waitFor(condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + 2_000L
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(10L)
        }
        return condition()
    }

    @Test
    fun previewNamingRejectsEscapesAndWrongLeaf() {
        assertTrue(
            OfficeConflictPreviewNaming.isValidRelativePath(
                "review-12345678-1234-1234-1234-123456789012/mine.preview",
                OfficeConflictPreviewRole.MINE,
            ),
        )
        assertFalse(
            OfficeConflictPreviewNaming.isValidRelativePath(
                "review-12345678-1234-1234-1234-123456789012/current.preview",
                OfficeConflictPreviewRole.MINE,
            ),
        )
        assertFalse(
            OfficeConflictPreviewNaming.isValidRelativePath(
                "../review-12345678-1234-1234-1234-123456789012/mine.preview",
                OfficeConflictPreviewRole.MINE,
            ),
        )
        assertFalse(
            OfficeConflictPreviewNaming.isValidRelativePath(
                "review-12345678-1234-1234-1234-123456789012/sub/mine.preview",
                OfficeConflictPreviewRole.MINE,
            ),
        )
    }

    @Test
    fun policyComparesDigestAndRevisionIndependently() {
        assertEquals(
            OfficeConflictReviewState.UNCHANGED,
            OfficeConflictReviewPolicy.reviewState("a".repeat(64), "rev-a", "a".repeat(64), "rev-a", true),
        )
        assertEquals(
            OfficeConflictReviewState.CHANGED,
            OfficeConflictReviewPolicy.reviewState("a".repeat(64), "rev-a", "b".repeat(64), "rev-a", true),
        )
        assertEquals(
            OfficeConflictReviewState.CHANGED,
            OfficeConflictReviewPolicy.reviewState("a".repeat(64), "rev-a", "a".repeat(64), "rev-b", true),
        )
        assertEquals(
            OfficeConflictReviewState.UNAVAILABLE,
            OfficeConflictReviewPolicy.reviewState("a".repeat(64), "rev-a", null, null, false),
        )
        // A provider route has no CAS revision: equal bytes are unchanged.
        assertEquals(
            OfficeConflictReviewState.UNCHANGED,
            OfficeConflictReviewPolicy.reviewState("a".repeat(64), null, "a".repeat(64), null, true),
        )
    }

    @Test
    fun staleReviewDoesNotAdmitAnyActionBeforeMutation() {
        val keep = OfficeConflictReviewPolicy.resolve(
            state = OfficeConflictReviewState.CHANGED,
            action = OfficeConflictReviewAction.KEEP_CURRENT,
            currentStillMatches = false,
            originalCasAuthority = true,
        )
        assertFalse(keep.accepted)
        assertEquals("reviewStale", keep.code)
        val preserve = OfficeConflictReviewPolicy.resolve(
            state = OfficeConflictReviewState.CHANGED,
            action = OfficeConflictReviewAction.PRESERVE_MINE_AS_COPY,
            currentStillMatches = false,
            originalCasAuthority = true,
        )
        assertFalse(preserve.accepted)
        assertEquals("reviewStale", preserve.code)
    }

    @Test
    fun conflictAnswerDescriptorRoundTripsWithoutPaths() {
        val answer = OfficeConflictReviewAnswer(
            state = OfficeConflictReviewState.CHANGED,
            recordId = "record-1",
            baseSha256 = "a".repeat(64),
            baseRevision = "rev-a",
            mineSha256 = "b".repeat(64),
            mineBytes = 123L,
            currentSha256 = "c".repeat(64),
            currentBytes = 456L,
            currentRevision = "rev-b",
            canKeepCurrent = true,
            canPreserveMineAsCopy = true,
            canRetryOriginalCas = false,
            reason = null,
        )
        val parsed = OfficeConflictReviewAnswer.fromDescriptorLine(answer.descriptorLine())
        assertEquals(answer, parsed)
        assertNull(OfficeConflictReviewAnswer.fromDescriptorLine("broken|line"))

        val result = OfficeConflictResolutionResult(false, "originalCasUnavailable", "no write")
        assertEquals(result, OfficeConflictResolutionResult.fromDescriptorLine(result.descriptorLine()))
    }
}
