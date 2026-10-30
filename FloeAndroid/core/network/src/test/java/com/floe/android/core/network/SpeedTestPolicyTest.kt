// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeedTestPolicyTest {
    @Test
    fun directionsAreExplicitAndCounted() {
        assertEquals(SpeedDirection.DOWNLOAD, SpeedDirection.fromWire("download"))
        assertEquals(SpeedDirection.UPLOAD, SpeedDirection.fromWire("UPLOAD"))
        assertEquals(SpeedDirection.DOWNLOAD_AND_UPLOAD, SpeedDirection.fromWire("downloadAndUpload"))
        assertNull(SpeedDirection.fromWire("both"))
        assertEquals(1, SpeedDirection.DOWNLOAD.count)
        assertEquals(2, SpeedDirection.DOWNLOAD_AND_UPLOAD.count)
    }

    @Test
    fun measurementIntervalIncludesBlockingFirstReadAndLastWrite() {
        val meter = SpeedMeter(warmupBytes = 0)
        val start = 1_000_000_000L
        meter.beginMeasuredIo(start)
        meter.recordMeasured(4_096, start + 25_000_000L)
        assertEquals(25L, meter.measurementElapsedMs())
        assertEquals(4_096L, meter.measuredBytes)
        assertEquals(4_096L, meter.payloadBytes)
    }

    @Test
    fun warmupBytesAreTransferredButExcludedFromMeasuredRate() {
        val meter = SpeedMeter(warmupBytes = 1_000)
        meter.recordWarmup(1_000)
        val start = 2_000_000_000L
        meter.beginMeasuredIo(start)
        meter.recordMeasured(500, start + 100_000_000L)
        assertEquals(1_500L, meter.payloadBytes)
        assertEquals(1_000L, meter.warmupCompletedBytes)
        assertEquals(500L, meter.measuredBytes)
        assertEquals(100L, meter.measurementElapsedMs())
        assertEquals(5_000.0, SpeedMath.rate(500, 100)!!.bytesPerSecond!!, 0.001)
    }

    @Test
    fun tinyAndZeroIntervalsDoNotFabricateARate() {
        val zero = SpeedMath.rate(100, 0)
        assertFalse(zero.available)
        assertEquals("measurementIntervalTooShort", zero.omittedReason)
        assertNull(zero.bytesPerSecond)

        val nearZero = SpeedMath.rate(100, 1)
        assertFalse(nearZero.available)
        assertEquals("measurementIntervalTooShort", nearZero.omittedReason)

        val normal = SpeedMath.rate(1_000_000, 1_000)
        assertTrue(normal.available)
        assertEquals(8_000_000.0, normal.bitsPerSecond!!, 0.001)
    }

    @Test
    fun sampleAdequacyRequiresBytesAndDuration() {
        assertTrue(SpeedMath.sampleAdequate(65_536, 250))
        assertFalse(SpeedMath.sampleAdequate(65_535, 250))
        assertFalse(SpeedMath.sampleAdequate(65_536, 249))
        assertFalse(SpeedMath.sampleAdequate(65_536, null))
    }

    @Test
    fun syntheticPayloadIsDeterministicAndBounded() {
        val first = SpeedPayload.chunk(4_096)
        val second = SpeedPayload.chunk(4_096)
        assertTrue(first.contentEquals(second))
        assertEquals(4_096, first.size)
        assertTrue(first.any { it != 0.toByte() })
        assertEquals(1, SpeedPayload.chunk(0).size)
        assertEquals(256 * 1024, SpeedPayload.chunk(Int.MAX_VALUE).size)
    }

    @Test
    fun downloadAndUploadRequestsCarryNoAuthCookiesOrUserPayloadName() {
        val target = NetworkTargetPolicy.parseHttpTarget("https://example.com/p?q=1")
        val download = String(
            SpeedHttpWire.downloadRequest(target, 443),
            Charsets.ISO_8859_1,
        )
        assertTrue(download.startsWith("GET /p?q=1 HTTP/1.1\r\n"))
        assertTrue(download.contains("Host: example.com\r\n"))
        assertTrue(download.contains("Accept-Encoding: identity\r\n"))
        assertTrue(download.contains("Connection: close\r\n\r\n"))
        assertFalse(download.contains("Authorization", ignoreCase = true))
        assertFalse(download.contains("Cookie", ignoreCase = true))

        val upload = String(
            SpeedHttpWire.uploadRequest(target, 8443, 1234),
            Charsets.ISO_8859_1,
        )
        assertTrue(upload.startsWith("POST /p?q=1 HTTP/1.1\r\n"))
        assertTrue(upload.contains("Host: example.com:8443\r\n"))
        assertTrue(upload.contains("Content-Length: 1234\r\n"))
        assertTrue(upload.contains("Content-Type: application/octet-stream\r\n"))
        assertFalse(upload.contains("Expect:", ignoreCase = true))
    }

    @Test
    fun contentLengthNeverInflatesTransferredBytes() {
        val result = transfer(
            payloadBytes = 1_234L,
            measuredBytes = 1_234L,
            elapsedMs = 100L,
            contentLength = 10_000_000L,
        )
        val json = result.toJson()
        assertEquals(1_234L, json.getLong("payloadBytes"))
        assertEquals(10_000_000L, json.getLong("contentLength"))
        assertEquals(12_340.0, json.getDouble("bytesPerSecond"), 0.001)
    }

    @Test
    fun uploadCountsAreClientStreamAcceptedBytes() {
        val result = transfer(
            payloadBytes = 65_536L,
            measuredBytes = 65_536L,
            elapsedMs = 500L,
            payloadMeaning = "clientStreamAcceptedBytes",
        )
        val json = result.toJson()
        assertEquals("clientStreamAcceptedBytes", json.getString("payloadBytesMeaning"))
        assertTrue(json.getBoolean("rateAvailable"))
    }

    @Test
    fun networkChangeIsDistinctButRetainsPartialBytes() {
        val request = SpeedTestRequest(
            direction = SpeedDirection.DOWNLOAD,
            downloadTarget = NetworkTargetPolicy.parseHttpTarget("https://example.com/p"),
            uploadTarget = null,
        )
        val download = transfer(
            status = ObservationStatus.PARTIAL,
            payloadBytes = 8_192L,
            measuredBytes = 8_192L,
            elapsedMs = 100L,
            networkChanged = true,
        )
        val result = SpeedTestResult.build(
            request,
            download,
            null,
            networkChanged = true,
            metered = true,
            proxyHost = "proxy.example",
            proxyPort = 8080,
        )
        assertEquals(ObservationStatus.ERROR, result.status)
        assertEquals("networkChanged", result.observations.getString("errorCode"))
        assertEquals(8_192L, result.observations.getJSONObject("download").getLong("payloadBytes"))
        assertEquals(true, result.observations.getJSONObject("download").getBoolean("networkChanged"))
        assertTrue(result.limitations.any { it.contains("proxy", ignoreCase = true) })
        assertTrue(result.limitations.any { it.contains("not a broadband ceiling", ignoreCase = true) })
    }

    @Test
    fun meteredRefusalIsUnsupportedWithNoDirectionResult() {
        val request = SpeedTestRequest(
            direction = SpeedDirection.DOWNLOAD,
            downloadTarget = NetworkTargetPolicy.parseHttpTarget("https://example.com/p"),
            uploadTarget = null,
            allowMetered = false,
        )
        val result = SpeedTestResult.build(
            request,
            null,
            null,
            networkChanged = false,
            failure = SpeedTestFailure(
                ObservationStatus.UNSUPPORTED,
                "meteredNetworkDisallowed",
                "metered",
            ),
            metered = true,
            proxyHost = null,
            proxyPort = null,
        )
        assertEquals(ObservationStatus.UNSUPPORTED, result.status)
        assertEquals("meteredNetworkDisallowed", result.observations.getString("errorCode"))
        assertTrue(result.observations.getBoolean("metered"))
        assertFalse(result.observations.has("download"))
    }

    private fun transfer(
        status: ObservationStatus = ObservationStatus.OK,
        payloadBytes: Long = 1_234L,
        measuredBytes: Long = 1_234L,
        elapsedMs: Long = 100L,
        contentLength: Long? = null,
        payloadMeaning: String = "responseBodyBytesRead",
        networkChanged: Boolean = false,
    ): SpeedTransferResult = SpeedTransferResult(
        endpoint = "https://example.com/p",
        status = status,
        payloadBytes = payloadBytes,
        measuredBytes = measuredBytes,
        warmupBytes = 0L,
        measurementElapsedMs = elapsedMs,
        totalElapsedMs = elapsedMs + 50L,
        completionReason = if (status == ObservationStatus.OK) "contentComplete" else "timeBudget",
        contentComplete = status == ObservationStatus.OK,
        clientStopped = status != ObservationStatus.OK,
        contentLength = contentLength,
        payloadBytesMeaning = payloadMeaning,
        networkChanged = networkChanged,
        rate = SpeedMath.rate(measuredBytes, elapsedMs),
    )
    @Test
    fun httpHeadReaderSkipsInterimResponsesAndBoundsLength() {
        val input = ByteArrayInputStream(
            (
                "HTTP/1.1 100 Continue\r\n\r\n" +
                    "HTTP/1.1 206 Partial Content\r\n" +
                    "Content-Length: 4096\r\n" +
                    "Content-Encoding: identity\r\n\r\n"
                ).toByteArray(Charsets.ISO_8859_1),
        )
        val head = SpeedHttpWire.readHead(input)
        assertEquals(206, head.statusCode)
        assertEquals(4_096L, head.contentLength()!!)
        assertEquals("identity", head.contentEncoding())
    }

    @Test
    fun redirectIsUnsupportedAndHasNoMeasuredPayload() {
        val request = SpeedTestRequest(
            direction = SpeedDirection.DOWNLOAD,
            downloadTarget = NetworkTargetPolicy.parseHttpTarget("https://example.com/redirect"),
            uploadTarget = null,
        )
        val redirect = SpeedTransferResult(
            endpoint = "https://example.com/redirect",
            status = ObservationStatus.UNSUPPORTED,
            payloadBytes = 0L,
            measuredBytes = 0L,
            warmupBytes = 0L,
            measurementElapsedMs = null,
            totalElapsedMs = 25L,
            completionReason = "redirectNotFollowed",
            contentComplete = false,
            clientStopped = false,
            httpStatus = 302,
            payloadBytesMeaning = "responseBodyBytesRead",
            rate = SpeedMath.rate(0, null),
        )
        val result = SpeedTestResult.build(
            request, redirect, null, networkChanged = false,
            metered = false, proxyHost = null, proxyPort = null,
        )
        assertEquals(ObservationStatus.UNSUPPORTED, result.status)
        assertEquals(0L, result.observations.getJSONObject("download").getLong("payloadBytes"))
        assertEquals("redirectNotFollowed", result.observations.getJSONObject("download").getString("completionReason"))
    }

}
