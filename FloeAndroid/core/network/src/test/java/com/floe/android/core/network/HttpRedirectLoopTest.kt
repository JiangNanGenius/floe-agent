// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.net.SocketTimeoutException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class HttpRedirectLoopTest {
    @Test
    fun followsRelativeHttpsRedirectAndReportsFinalHop() = runBlocking {
        val initial = target("https://example.com/start")
        val chain = HttpRedirectLoop.follow(
            initial = initial,
            maxRedirects = 5,
            timeoutMs = 2_000,
            fetcher = FakeFetcher(
                listOf(
                    hop(initial, 302, "/next"),
                    hop(target("https://example.com/next"), 200, null),
                ),
            ),
            elapsedMillis = { 0L },
        )
        assertEquals(ObservationStatus.OK, chain.status)
        assertEquals(2, chain.hops.size)
        assertEquals("https://example.com/next", chain.finalTarget?.redacted)
        assertEquals(200, chain.hops.last().statusCode)
    }

    @Test
    fun stopsAtRedirectLimit() = runBlocking {
        val initial = target("https://example.com/start")
        val chain = HttpRedirectLoop.follow(
            initial = initial,
            maxRedirects = 0,
            timeoutMs = 2_000,
            fetcher = FakeFetcher(listOf(hop(initial, 302, "/next"))),
            elapsedMillis = { 0L },
        )
        assertEquals(ObservationStatus.PARTIAL, chain.status)
        assertEquals("redirectLimitReached", chain.stoppedReason)
    }

    @Test
    fun refusesCleartextMetadataAndUserinfoRedirects() = runBlocking {
        val initial = target("https://example.com/start")

        val cleartext = HttpRedirectLoop.follow(
            initial,
            5,
            2_000,
            FakeFetcher(listOf(hop(initial, 301, "http://example.com/next")))
        ) { 0L }
        assertEquals(ObservationStatus.PARTIAL, cleartext.status)
        assertEquals("cleartextRedirectBlocked", cleartext.stoppedReason)

        val metadata = HttpRedirectLoop.follow(
            initial,
            5,
            2_000,
            FakeFetcher(listOf(hop(initial, 302, "https://169.254.169.254/latest/meta-data")))
        ) { 0L }
        assertEquals(ObservationStatus.PARTIAL, metadata.status)
        assertEquals("policyDenied", metadata.stoppedReason)

        val userinfo = HttpRedirectLoop.follow(
            initial,
            5,
            2_000,
            FakeFetcher(listOf(hop(initial, 302, "https://user:pass@example.com/next")))
        ) { 0L }
        assertEquals(ObservationStatus.PARTIAL, userinfo.status)
        assertEquals("invalidRedirect", userinfo.stoppedReason)
    }

    @Test
    fun mapsFirstHopPolicyAndPermissionFailures() = runBlocking {
        val initial = target("https://example.com/start")
        val first = HttpRedirectLoop.follow(
            initial,
            5,
            2_000,
            object : HttpFetcher {
                override suspend fun fetch(target: HttpTarget, timeoutMs: Int): HttpHop {
                    throw HttpFetchException(ObservationStatus.UNSUPPORTED, "policyDenied")
                }
            }
        ) { 0L }
        assertEquals(ObservationStatus.UNSUPPORTED, first.status)
        assertEquals("policyDenied", first.stoppedReason)

        val permission = HttpRedirectLoop.follow(
            initial,
            5,
            2_000,
            object : HttpFetcher {
                override suspend fun fetch(target: HttpTarget, timeoutMs: Int): HttpHop {
                    throw HttpFetchException(
                        ObservationStatus.PERMISSION_REQUIRED,
                        "localNetworkPermissionRequired",
                        missingPermissions = listOf("android.permission.ACCESS_LOCAL_NETWORK"),
                    )
                }
            }
        ) { 0L }
        assertEquals(ObservationStatus.PERMISSION_REQUIRED, permission.status)
        assertEquals(listOf("android.permission.ACCESS_LOCAL_NETWORK"), permission.missingPermissions)
    }

    @Test
    fun mapsFetchTimeoutAndIoFailure() = runBlocking {
        val initial = target("https://example.com/start")
        val timeout = HttpRedirectLoop.follow(
            initial,
            5,
            2_000,
            object : HttpFetcher {
                override suspend fun fetch(target: HttpTarget, timeoutMs: Int): HttpHop {
                    throw SocketTimeoutException("timed out")
                }
            }
        ) { 0L }
        assertEquals(ObservationStatus.TIMEOUT, timeout.status)

        val error = HttpRedirectLoop.follow(
            initial,
            5,
            2_000,
            object : HttpFetcher {
                override suspend fun fetch(target: HttpTarget, timeoutMs: Int): HttpHop {
                    throw IllegalStateException("boom")
                }
            }
        ) { 0L }
        assertEquals(ObservationStatus.ERROR, error.status)
    }

    @Test
    fun timeoutBudgetProducesTypedTimeout() = runBlocking {
        val initial = target("https://example.com/start")
        var now = 0L
        val chain = HttpRedirectLoop.follow(
            initial = initial,
            maxRedirects = 5,
            timeoutMs = 10,
            fetcher = FakeFetcher(listOf(hop(initial, 200, null))),
            elapsedMillis = {
                now += 20
                now
            },
        )
        assertEquals(ObservationStatus.TIMEOUT, chain.status)
        assertTrue(chain.hops.isEmpty())
    }

    private fun target(value: String): HttpTarget = NetworkTargetPolicy.parseHttpTarget(value)

    private fun hop(target: HttpTarget, status: Int, location: String?): HttpHop = HttpHop(
        target = target,
        statusCode = status,
        location = location,
        cipherSuite = "TLS_AES_128_GCM_SHA256",
        contentType = "text/plain",
        contentLength = 0,
        headers = mapOf("content-type" to "text/plain"),
        tlsProtocol = "TLSv1.3",
        dnsMs = 1,
        tcpConnectMs = 2,
        tlsHandshakeMs = 3,
        responseHeadersMs = 4,
        totalMs = 10,
    )

    private class FakeFetcher(private val hops: List<HttpHop>) : HttpFetcher {
        private var index = 0
        override suspend fun fetch(target: HttpTarget, timeoutMs: Int): HttpHop = hops[index++]
    }
}
