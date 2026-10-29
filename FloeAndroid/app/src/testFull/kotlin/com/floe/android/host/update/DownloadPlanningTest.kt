// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Resume correctness and staged-metadata integrity. These rules are what keep
 * an interrupted download from mixing bytes of two different artifacts.
 */
class DownloadPlanningTest {

    private val etag = "\"abc123\""
    private val sha = "a".repeat(64)

    private fun meta(
        fileName: String = "Floe-Android-0.1.0-alpha.14-full-arm64-v8a.apk",
        completed: Boolean = false,
    ) = DownloadMeta(
        tag = "android/v0.1.0-alpha.14",
        versionName = "0.1.0-alpha.14",
        fileName = fileName,
        apkUrl = "https://example.test/apk",
        checksumsUrl = "https://example.test/SHA256SUMS",
        expectedSha256 = sha,
        totalBytes = 432_697_008L,
        receivedBytes = 100L,
        etag = etag,
        completed = completed,
    )

    @Test
    fun appendsOnlyForMatchingPartialResponse() {
        val plan = DownloadPlanning.plan(
            stagedBytes = 100L,
            stagedEtag = etag,
            httpStatus = 206,
            contentRangeStart = 100L,
            contentRangeTotal = 432_697_008L,
            responseEtag = etag,
            expectedTotal = 432_697_008L,
        )
        assertEquals(ResumePlan.AppendFrom(100L), plan)
    }

    @Test
    fun restartsWhenArtifactEtagChanged() {
        val plan = DownloadPlanning.plan(
            stagedBytes = 100L,
            stagedEtag = etag,
            httpStatus = 206,
            contentRangeStart = 100L,
            contentRangeTotal = 432_697_008L,
            responseEtag = "\"different\"",
            expectedTotal = 432_697_008L,
        )
        assertEquals(ResumePlan.Restart, plan)
    }

    @Test
    fun restartsWhenServerIgnoresRange() {
        val plan = DownloadPlanning.plan(
            stagedBytes = 100L,
            stagedEtag = etag,
            httpStatus = 200,
            contentRangeStart = null,
            contentRangeTotal = null,
            responseEtag = etag,
            expectedTotal = 432_697_008L,
        )
        assertEquals(ResumePlan.Restart, plan)
    }

    @Test
    fun restartsWhenOffsetDoesNotMatch() {
        val plan = DownloadPlanning.plan(
            stagedBytes = 100L,
            stagedEtag = etag,
            httpStatus = 206,
            contentRangeStart = 200L,
            contentRangeTotal = 432_697_008L,
            responseEtag = etag,
            expectedTotal = 432_697_008L,
        )
        assertEquals(ResumePlan.Restart, plan)
    }

    @Test
    fun restartsWhenTotalDiffersFromReleaseAsset() {
        val plan = DownloadPlanning.plan(
            stagedBytes = 100L,
            stagedEtag = etag,
            httpStatus = 206,
            contentRangeStart = 100L,
            contentRangeTotal = 1_000L,
            responseEtag = etag,
            expectedTotal = 432_697_008L,
        )
        assertEquals(ResumePlan.Restart, plan)
    }

    @Test
    fun restartsWhenNoStagedValidator() {
        assertEquals(
            ResumePlan.Restart,
            DownloadPlanning.plan(
                stagedBytes = 100L,
                stagedEtag = null,
                httpStatus = 206,
                contentRangeStart = 100L,
                contentRangeTotal = 432_697_008L,
                responseEtag = etag,
                expectedTotal = 432_697_008L,
            ),
        )
        assertEquals(
            ResumePlan.Restart,
            DownloadPlanning.plan(
                stagedBytes = 100L,
                stagedEtag = etag,
                httpStatus = 206,
                contentRangeStart = 100L,
                contentRangeTotal = 432_697_008L,
                responseEtag = null,
                expectedTotal = 432_697_008L,
            ),
        )
    }

    @Test
    fun freshDownloadAlwaysStartsAtZero() {
        assertEquals(
            ResumePlan.Restart,
            DownloadPlanning.plan(
                stagedBytes = 0L,
                stagedEtag = null,
                httpStatus = 200,
                contentRangeStart = null,
                contentRangeTotal = null,
                responseEtag = etag,
                expectedTotal = 432_697_008L,
            ),
        )
    }

    @Test
    fun metadataRoundTripsThroughJson() {
        val original = meta()
        assertEquals(original, DownloadMeta.fromJson(original.toJson()))
    }

    @Test
    fun metadataRejectsTraversalAndInsecureUrls() {
        assertNull(DownloadMeta.fromJson(meta(fileName = "../escape.apk").toJson()))
        assertNull(
            DownloadMeta.fromJson(
                meta().copy(apkUrl = "http://example.test/apk").toJson(),
            ),
        )
        assertNull(DownloadMeta.fromJson("{}"))
    }

    @Test
    fun metadataKeepsCompletionFlag() {
        val completed = meta(completed = true)
        val parsed = DownloadMeta.fromJson(completed.toJson())!!
        assertTrue(parsed.completed)
        assertEquals(completed.totalBytes, parsed.totalBytes)
    }
}
