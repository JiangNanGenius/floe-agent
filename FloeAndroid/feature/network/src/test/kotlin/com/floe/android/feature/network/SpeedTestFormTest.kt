// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure speed form policy: explicit HTTPS endpoints, per-direction integer
 * budgets and the 30-second overall deadline margin. Endpoint validation is
 * source-only here; the service owns the real TLS/socket checks.
 *
 * AUTHORED SOURCE ONLY: not compiled or executed by this lane.
 */
class SpeedTestFormTest {

    @Test
    fun defaultDirectionHasNoEndpointUntilTheUserEntersOne() {
        val result = SpeedTestPolicy.parse(SpeedTestFormValues())
        assertNull(result.input)
        assertEquals(listOf(SpeedTestValidationError.DOWNLOAD_URL_REQUIRED), result.errors)
        assertNull(SpeedTestPolicy.parseHttpsEndpoint(""))
    }

    @Test
    fun explicitHttpsDownloadBuildsTheFrozenBudget() {
        val result = SpeedTestPolicy.parse(
            SpeedTestFormValues(downloadUrl = "https://speed.example.net/payload"),
        )
        assertTrue(result.errors.isEmpty())
        val input = requireNotNull(result.input)
        assertEquals(SpeedTestDirection.DOWNLOAD, input.direction)
        assertEquals("https://speed.example.net/payload", input.downloadUrl)
        assertNull(input.uploadUrl)
        assertEquals(8 * 1024 * 1024, input.maxBytesPerDirection)
        assertEquals(10_000, input.durationBudgetMs)
        assertFalse(input.allowMetered)
        assertEquals(11_500, input.timeoutMs)
    }

    @Test
    fun onlyFullHttpsUrlsWithoutUserInfoAreAccepted() {
        assertNull(SpeedTestPolicy.parseHttpsEndpoint("http://example.com/payload"))
        assertNull(SpeedTestPolicy.parseHttpsEndpoint("https://user:secret@example.com/payload"))
        assertNull(SpeedTestPolicy.parseHttpsEndpoint("https:///missing-host"))
        assertEquals(
            "https://example.com/payload?x=1",
            SpeedTestPolicy.parseHttpsEndpoint("  https://example.com/payload?x=1  "),
        )
    }

    @Test
    fun uploadAndBothDirectionsRequireTheirOwnEndpoints() {
        val uploadMissing = SpeedTestPolicy.parse(
            SpeedTestFormValues(
                direction = SpeedTestDirection.UPLOAD,
                downloadUrl = "https://example.com/download",
            ),
        )
        assertEquals(listOf(SpeedTestValidationError.UPLOAD_URL_REQUIRED), uploadMissing.errors)

        val bothMissing = SpeedTestPolicy.parse(
            SpeedTestFormValues(
                direction = SpeedTestDirection.BOTH,
                downloadUrl = "https://example.com/download",
            ),
        )
        assertEquals(listOf(SpeedTestValidationError.UPLOAD_URL_REQUIRED), bothMissing.errors)

        val both = SpeedTestPolicy.parse(
            SpeedTestFormValues(
                direction = SpeedTestDirection.BOTH,
                downloadUrl = "https://example.com/download",
                uploadUrl = "https://example.com/upload",
                durationSeconds = "14",
            ),
        )
        assertTrue(both.errors.isEmpty())
        assertEquals(29_500, requireNotNull(both.input).timeoutMs)
    }

    @Test
    fun bothDirectionsRejectFifteenSecondsToRespectTheOverallDeadline() {
        val result = SpeedTestPolicy.parse(
            SpeedTestFormValues(
                direction = SpeedTestDirection.BOTH,
                downloadUrl = "https://example.com/download",
                uploadUrl = "https://example.com/upload",
                durationSeconds = "15",
            ),
        )
        assertEquals(listOf(SpeedTestValidationError.DURATION_BOTH), result.errors)
    }

    @Test
    fun singleDirectionAcceptsFifteenSecondsAndComputesItsOwnTimeout() {
        val result = SpeedTestPolicy.parse(
            SpeedTestFormValues(
                direction = SpeedTestDirection.UPLOAD,
                uploadUrl = "https://example.com/upload",
                durationSeconds = "15",
            ),
        )
        assertTrue(result.errors.isEmpty())
        assertEquals(16_500, requireNotNull(result.input).timeoutMs)
    }

    @Test
    fun dataCapAndDurationAreIntegerBoundedValues() {
        assertEquals(
            listOf(SpeedTestValidationError.BYTE_CAP),
            SpeedTestPolicy.parse(
                SpeedTestFormValues(downloadUrl = "https://example.com/p", maxMiB = "0"),
            ).errors,
        )
        assertEquals(
            listOf(SpeedTestValidationError.BYTE_CAP),
            SpeedTestPolicy.parse(
                SpeedTestFormValues(downloadUrl = "https://example.com/p", maxMiB = "33"),
            ).errors,
        )
        assertEquals(
            listOf(SpeedTestValidationError.DURATION),
            SpeedTestPolicy.parse(
                SpeedTestFormValues(downloadUrl = "https://example.com/p", durationSeconds = "16"),
            ).errors,
        )
        val maximum = SpeedTestPolicy.parse(
            SpeedTestFormValues(
                downloadUrl = "https://example.com/p",
                maxMiB = "32",
                durationSeconds = "5",
            ),
        )
        assertTrue(maximum.errors.isEmpty())
        assertEquals(33_554_432, requireNotNull(maximum.input).maxBytesPerDirection)
    }
}
