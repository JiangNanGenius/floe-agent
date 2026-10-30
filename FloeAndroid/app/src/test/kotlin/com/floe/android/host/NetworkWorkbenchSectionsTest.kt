// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import com.floe.android.feature.network.NetworkObservationUi
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * App-side projection for the six existing phone-network methods.
 *
 * MAIN INTEGRATION FILE (outside the ui02 write scope): apply
 * `PATCH_app_NetworkWorkbenchSectionsTest.diff` with the controller patch.
 * The pre-existing `NetworkWorkbenchProjectionTest.kt` assertions stay
 * untouched. This file proves the controller now collects the captured-
 * network snapshot separately from the method's observations and fills
 * `primaryFacts` / `connectionFacts` / `detailFacts` by stable JSON path,
 * not by localized labels. No metric is synthesized.
 *
 * AUTHORED SOURCE ONLY: not compiled or executed by the ui02 lane.
 */
class NetworkWorkbenchSectionsTest {

    private fun decode(
        method: String,
        observations: String,
        network: String = """{"typeName":"WIFI","state":"CONNECTED","linkAddresses":["192.168.100.187/24"],"dnsServers":["192.168.100.1"]}""",
        operationID: String = "op-1",
    ): NetworkObservationUi {
        val json = """{"version":1,"operationID":"$operationID","method":"$method",""" +
            """"source":"phone","status":"ok","measuredAt":"2026-10-30T00:00:00Z",""" +
            """"network":$network,"observations":$observations}"""
        return NetworkWorkbenchProjection.decode(method, operationID, json, zh = false)
    }

    private fun keys(facts: List<com.floe.android.feature.network.NetworkFactUi>) = facts.map { it.key }

    @Test
    fun wifiProjectsActualLinkAndScanSummaryAheadOfAddresses() {
        val ui = decode(
            "network.wifiScan",
            observations = """{"totalAccessPoints":2,"freshness":"fresh","scanAccepted":true,
                "accessPoints":[{"ssid":"lab","bssid":"aa:bb:cc:dd:ee:ff","rssiDbm":-51,
                "frequencyMhz":2462,"channel":11,"ageMs":150}]}""",
            network = """{"typeName":"WIFI","state":"CONNECTED",""" +
                """"linkAddresses":["192.168.100.187/24"],"dnsServers":["192.168.100.1"],""" +
                """"wifi":{"ssid":"lab","rssiDbm":-51,"channel":11,"frequencyMhz":2462}}""",
        )
        assertEquals(
            listOf(
                "network.wifi.ssid", "network.wifi.rssiDbm", "network.wifi.channel",
                "network.wifi.frequencyMhz",
                "observations.totalAccessPoints", "observations.freshness",
            ),
            keys(ui.primaryFacts),
        )
        assertTrue(ui.primaryFacts.none { it.key == "network.linkAddresses" || it.key == "network.dnsServers" })
        assertTrue(ui.connectionFacts.any { it.key == "network.linkAddresses" })
        assertTrue(ui.connectionFacts.any { it.key == "network.dnsServers" })
        assertTrue(ui.detailFacts.any { it.key == "observations.scanAccepted" })
        assertEquals("-51", ui.primaryFacts.first { it.key == "network.wifi.rssiDbm" }.value)
        assertEquals(1, ui.accessPoints.size)
        assertEquals("lab", ui.accessPoints.single().name)
        assertEquals(11, ui.accessPoints.single().channel)
    }

    @Test
    fun dnsLeadsWithActualAnswersAndStatus() {
        val ui = decode(
            "network.dnsLookup",
            observations = """{"recordType":"A_AND_AAAA","rcodeName":"NOERROR","elapsedMs":44,
                "ttlSupported":true,"answers":[{"name":"example.com","type":"A","ttlSeconds":195,
                "address":"172.66.147.243"}],"addresses":["172.66.147.243"]}""",
        )
        assertEquals(
            listOf(
                "observations.answers", "observations.addresses", "observations.rcodeName",
                "observations.elapsedMs", "observations.recordType",
            ),
            keys(ui.primaryFacts),
        )
        assertTrue(ui.primaryFacts.none { it.key == "network.linkAddresses" || it.key == "network.dnsServers" })
        assertTrue(ui.detailFacts.any { it.key == "observations.ttlSupported" })
        assertTrue(ui.connectionFacts.any { it.key == "network.dnsServers" })
        assertTrue(ui.primaryFacts.first { it.key == "observations.answers" }.value.contains("172.66.147.243"))
    }

    @Test
    fun pingProjectsOnlyReportedLossAndRttFacts() {
        val ui = decode(
            "network.ping",
            observations = """{"resolvedAddress":"203.0.113.4","family":"IPv4","countRequested":4,
                "sent":4,"received":0,"lost":4,"packetLossPercent":100,"timeoutBudgetMs":5000,
                "probes":[{"sequence":0,"replied":false}]}""",
        )
        assertEquals(
            listOf(
                "observations.resolvedAddress", "observations.family", "observations.sent",
                "observations.received", "observations.lost", "observations.packetLossPercent",
                "observations.countRequested",
            ),
            keys(ui.primaryFacts),
        )
        assertEquals("100", ui.primaryFacts.first { it.key == "observations.packetLossPercent" }.value)
        assertTrue(ui.primaryFacts.none { it.key == "observations.rttAvgMs" })
        assertTrue(ui.detailFacts.any { it.key == "observations.probes" })
    }

    @Test
    fun tcpProjectsConnectionResultAndMeasuredTime() {
        val ui = decode(
            "network.tcpProbe",
            observations = """{"port":443,"resolvedAddresses":["203.0.113.4"],"connected":true,
                "connectTimeMs":36,"refused":false,"timeoutBudgetMs":5000,
                "attempts":[{"address":"203.0.113.4","result":"connected","elapsedMs":36}],
                "remoteAddress":"203.0.113.4","localAddress":"10.0.2.16","localPort":57696}""",
        )
        assertEquals(
            listOf(
                "observations.connected", "observations.connectTimeMs", "observations.remoteAddress",
                "observations.port", "observations.resolvedAddresses", "observations.refused",
                "observations.attempts",
            ),
            keys(ui.primaryFacts),
        )
        assertEquals("36", ui.primaryFacts.first { it.key == "observations.connectTimeMs" }.value)
        assertTrue(ui.primaryFacts.none { it.key == "observations.timeoutBudgetMs" })
    }

    @Test
    fun httpsProjectsStatusTlsAndPhaseTimings() {
        val ui = decode(
            "network.http",
            observations = """{"requestedUrl":"https://example.com/","finalUrl":"https://example.com/",
                "statusCode":200,"redirectCount":0,"probeTotalMs":552,
                "phaseTimings":{"dnsMs":4,"tcpConnectMs":34,"tlsHandshakeMs":504,
                "responseHeadersMs":8,"totalMs":552},
                "tls":{"protocol":"TLSv1.3","cipherSuite":"TLS_AES_128_GCM_SHA256"},
                "responseHeaders":{"server":"cloudflare"},"redirects":[{"url":"https://example.com/","statusCode":200}]}""",
        )
        assertEquals(
            listOf(
                "observations.statusCode", "observations.finalUrl",
                "observations.phaseTimings.dnsMs", "observations.phaseTimings.tcpConnectMs",
                "observations.phaseTimings.tlsHandshakeMs", "observations.phaseTimings.responseHeadersMs",
                "observations.phaseTimings.totalMs", "observations.probeTotalMs",
                "observations.tls.protocol", "observations.tls.cipherSuite",
                "observations.redirectCount", "observations.requestedUrl",
            ),
            keys(ui.primaryFacts),
        )
        assertEquals("TLSv1.3", ui.primaryFacts.first { it.key == "observations.tls.protocol" }.value)
        assertEquals("552", ui.primaryFacts.first { it.key == "observations.phaseTimings.totalMs" }.value)
        assertTrue(ui.detailFacts.any { it.key == "observations.redirects" })
        assertFalse(ui.primaryFacts.any { it.key == "observations.responseHeaders" })
    }

    @Test
    fun futureMethodKeepsItsObservedFactsVisible() {
        val ui = decode(
            "network.futureProbe",
            observations = """{"statusCode":200,"finalUrl":"http://printer.local/"}""",
        )
        assertEquals(listOf("observations.statusCode", "observations.finalUrl"), keys(ui.primaryFacts))
        assertTrue(ui.detailFacts.isEmpty())
        assertTrue(ui.connectionFacts.any { it.key == "network.typeName" })
    }

    @Test
    fun lanDiscoveryProjectsStructuredInventoryAndSummaryFacts() {
        val ui = decode(
            "network.lanDiscover",
            observations = """{
                "mdns":{"requestedServiceTypes":["_http._tcp"],"scope":"capturedNetwork",
                  "networkScoped":true,"discoveryDurationMs":4000,"elapsedMs":4012,
                  "services":[{"serviceName":"Living Room","serviceType":"_http._tcp.","addresses":["192.168.1.20"],
                    "port":80,"hostname":"living-room","state":"active","resolution":"resolved"},
                    {"serviceName":"Printer","serviceType":"_ipp._tcp.","addresses":[],
                    "state":"active","resolution":"unresolved"}],
                  "serviceCount":2,"activeServiceCount":2,"unresolvedCount":1,"lostCount":0,
                  "filteredForeignNetwork":1,"truncated":false,"noReplies":false,"stoppedReason":"duration"},
                "tcp":{"subnetCidr":"192.168.1.0/24","ports":[80],"hostCount":254,
                  "excludedSelfAddresses":["192.168.1.5"],"attemptedHosts":253,"plannedAttempts":253,
                  "completedAttempts":250,"openPorts":[{"address":"192.168.1.20","port":80,"connectTimeMs":12}],
                  "openPortCount":1,"refusedAttempts":200,"timedOutAttempts":50,"errorAttempts":0,
                  "unreachableAttempts":0,"hostsWithResponse":120,"hostsWithOpenPort":1,"truncated":false,
                  "stoppedReason":"timeBudget","cancelled":false,"elapsedMs":5000},
                "networkChanged":false,"noReplies":false
            }""",
        )
        val lan = requireNotNull(ui.lan)
        assertEquals("capturedNetwork", lan.mdns?.scope)
        assertEquals(2, lan.mdns?.services?.size)
        assertEquals(80, requireNotNull(lan.mdns?.services?.first()).port)
        assertTrue(lan.mdns?.services?.first()?.resolved == true)
        assertFalse(lan.mdns?.services?.get(1)?.resolved == true)
        assertEquals(1, lan.mdns?.filteredForeignNetwork)
        assertEquals("192.168.1.0/24", lan.tcp?.subnetCidr)
        assertEquals(12L, requireNotNull(lan.tcp?.openPorts?.single()).connectTimeMs)
        assertTrue(ui.primaryFacts.any { it.key == "observations.tcp.openPortCount" && it.value == "1" })
        assertTrue(ui.detailFacts.any { it.key == "observations.tcp.refusedAttempts" })
    }

    @Test
    fun speedTestProjectsBudgetAndBothTransferDirections() {
        val ui = decode(
            "network.speedTest",
            observations = """{
                "budget":{"maxBytesPerDirection":8388608,"durationBudgetMs":10000,"warmupBytes":0,"timeoutMs":30000},
                "metered":false,"allowMetered":false,"direction":"downloadAndUpload","singleTransfer":true,
                "download":{"endpoint":"https://example.com/payload","status":"partial","payloadBytes":1048576,
                  "measuredBytes":1000000,"measurementElapsedMs":2000,"totalElapsedMs":2400,
                  "bytesPerSecond":500000.0,"bitsPerSecond":4000000.0,"completionReason":"cancelled",
                  "contentComplete":false,"clientStopped":true,"networkChanged":false,
                  "tlsProtocol":"TLSv1.3","cipherSuite":"TLS_AES_128_GCM_SHA256","rateAvailable":true,
                  "payloadBytesMeaning":"responseBodyBytesRead"},
                "upload":{"endpoint":"https://example.com/upload","status":"ok","payloadBytes":8388608,
                  "measuredBytes":8388608,"measurementElapsedMs":3000,"totalElapsedMs":3400,
                  "completionReason":"contentComplete","contentComplete":true,"clientStopped":false,
                  "networkChanged":false,"rateAvailable":false,"rateOmittedReason":"measurementIntervalTooShort",
                  "payloadBytesMeaning":"clientStreamAcceptedBytes"},
                "sampleAdequate":false,"networkChanged":false
            }""",
        )
        val speed = requireNotNull(ui.speed)
        assertEquals("downloadAndUpload", speed.direction)
        assertEquals(8_388_608L, requireNotNull(speed.maxBytesPerDirection))
        assertEquals(2, speed.transfers.size)
        assertEquals(4_000_000.0, speed.transfers.first().bitsPerSecond ?: 0.0, 0.001)
        assertTrue(speed.transfers.first().rateAvailable)
        assertFalse(speed.transfers[1].rateAvailable)
        assertEquals("clientStreamAcceptedBytes", speed.transfers[1].payloadBytesMeaning)
        assertEquals(1_048_576L, speed.transfers.first().payloadBytes)
        assertTrue(ui.primaryFacts.any { it.key == "observations.budget.maxBytesPerDirection" })
        assertFalse(ui.primaryFacts.any { it.key?.startsWith("observations.download.") == true })
    }

    @Test
    fun errorObservationDoesNotInventAPrimaryMeasurement() {
        val ui = decode(
            "network.dnsLookup",
            observations = """{"errorCode":"noActiveNetwork"}""",
        )
        assertTrue(ui.primaryFacts.isEmpty())
        assertTrue(ui.detailFacts.isEmpty())
        assertTrue(ui.connectionFacts.any { it.key == "network.typeName" })
        assertFalse(ui.facts.any { it.value == "0" })
    }

    @Test
    fun everyProjectedFactComesFromTheActualResponseOnce() {
        val ui = decode(
            "network.http",
            observations = """{"statusCode":204,"finalUrl":"https://example.com/","redirectCount":1,
                "phaseTimings":{"totalMs":90},"redirects":[{"url":"https://example.com/"}]}""",
        )
        val output = ui.primaryFacts + ui.connectionFacts + ui.detailFacts
        assertEquals(output.size, output.distinctBy { it.key }.size)
        assertEquals(output.toSet(), ui.facts.toSet())
        assertEquals("204", ui.primaryFacts.first { it.key == "observations.statusCode" }.value)
    }
}
