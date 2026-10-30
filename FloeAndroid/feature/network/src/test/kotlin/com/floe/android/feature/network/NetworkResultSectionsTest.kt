// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Result-section classification for the phone-network methods, including the
 * G07.2 LAN discovery and speed-test additions.
 * Stable JSON paths decide what leads; display labels are never inspected and
 * no fact is invented. Every input fact must appear exactly once across the
 * primary/Details groups.
 *
 * AUTHORED SOURCE ONLY: Main owns compilation/execution in the unified batch.
 */
class NetworkResultSectionsTest {

    private fun fact(key: String, value: String = key) =
        NetworkFactUi(label = key.substringAfterLast('.'), value = value, key = key)

    private fun keys(facts: List<NetworkFactUi>) = facts.map { it.key }

    @Test
    fun overviewLeadsWithActualConnectionAndWifiLinkWhileAddressesStayInDetails() {
        val connection = listOf(
            fact("network.typeName", "WIFI"),
            fact("network.state", "CONNECTED"),
            fact("network.validated", "Yes"),
            fact("network.linkAddresses", "192.168.1.5/24"),
            fact("network.dnsServers", "192.168.1.1"),
            fact("network.wifi.ssid", "lab"),
            fact("network.wifi.rssiDbm", "-41"),
            fact("network.wifi.channel", "36"),
        )
        val sections = NetworkResultSections.partition(NetworkPage.OVERVIEW.method, connection, emptyList())
        assertEquals(
            listOf(
                "network.typeName", "network.state", "network.validated",
                "network.wifi.ssid", "network.wifi.rssiDbm", "network.wifi.channel",
            ),
            keys(sections.primary),
        )
        assertEquals(listOf("network.linkAddresses", "network.dnsServers"), keys(sections.connection))
        assertTrue(sections.detail.isEmpty())
        assertEquals("-41", sections.primary.first { it.key == "network.wifi.rssiDbm" }.value)
    }

    @Test
    fun wifiScanLeadsWithActualLinkAndScanSummaryNotTheCommonNetworkBlock() {
        val connection = listOf(
            fact("network.typeName", "WIFI"),
            fact("network.linkAddresses", "192.168.1.5/24"),
            fact("network.dnsServers", "192.168.1.1"),
            fact("network.wifi.ssid", "lab"),
            fact("network.wifi.rssiDbm", "-51"),
            fact("network.wifi.channel", "11"),
            fact("network.wifi.frequencyMhz", "2462"),
            fact("network.wifi.band", "2.4GHz"),
        )
        val observations = listOf(
            fact("observations.totalAccessPoints", "26"),
            fact("observations.freshness", "fresh"),
            fact("observations.scanAccepted", "Yes"),
            fact("observations.wifiEnabled", "Yes"),
        )
        val sections = NetworkResultSections.partition(NetworkPage.WIFI.method, connection, observations)
        assertEquals(
            listOf(
                "network.wifi.ssid", "network.wifi.rssiDbm", "network.wifi.channel",
                "network.wifi.frequencyMhz", "network.wifi.band",
                "observations.totalAccessPoints", "observations.freshness",
            ),
            keys(sections.primary),
        )
        assertTrue(sections.connection.none { it.key?.startsWith("network.wifi.") == true })
        assertTrue(sections.connection.any { it.key == "network.linkAddresses" })
        assertEquals(
            listOf("observations.scanAccepted", "observations.wifiEnabled"),
            keys(sections.detail),
        )
        assertEquals("26", sections.primary.first { it.key == "observations.totalAccessPoints" }.value)
    }

    @Test
    fun dnsAnswersAndStatusLeadBeforeAnyNetworkMetadata() {
        val connection = listOf(
            fact("network.dnsServers", "192.168.1.1"),
            fact("network.linkAddresses", "192.168.1.5/24"),
        )
        val observations = listOf(
            fact("observations.answers", "example.com A 172.66.147.243"),
            fact("observations.addresses", "172.66.147.243"),
            fact("observations.rcodeName", "NOERROR"),
            fact("observations.elapsedMs", "44"),
            fact("observations.recordType", "A_AND_AAAA"),
            fact("observations.ttlSupported", "Yes"),
        )
        val sections = NetworkResultSections.partition(NetworkPage.DNS.method, connection, observations)
        assertEquals(
            listOf(
                "observations.answers", "observations.addresses", "observations.rcodeName",
                "observations.elapsedMs", "observations.recordType",
            ),
            keys(sections.primary),
        )
        assertEquals(keys(connection), keys(sections.connection))
        assertEquals(listOf("observations.ttlSupported"), keys(sections.detail))
        assertTrue(sections.primary.none { it.key?.startsWith("network.") == true })
    }

    @Test
    fun pingAndTcpExposeOnlyTheMeasuredResultAndTimingTheyActuallyReturned() {
        val ping = NetworkResultSections.partition(
            NetworkPage.PING.method,
            listOf(fact("network.typeName", "WIFI")),
            listOf(
                fact("observations.resolvedAddress", "203.0.113.4"),
                fact("observations.family", "IPv4"),
                fact("observations.sent", "4"),
                fact("observations.received", "0"),
                fact("observations.lost", "4"),
                fact("observations.packetLossPercent", "100"),
                fact("observations.probes", "…"),
            ),
        )
        assertEquals(
            listOf(
                "observations.resolvedAddress", "observations.family", "observations.sent",
                "observations.received", "observations.lost", "observations.packetLossPercent",
            ),
            keys(ping.primary),
        )
        assertEquals(listOf("observations.probes"), keys(ping.detail))

        val tcp = NetworkResultSections.partition(
            NetworkPage.TCP.method,
            listOf(fact("network.typeName", "WIFI")),
            listOf(
                fact("observations.connected", "Yes"),
                fact("observations.connectTimeMs", "36"),
                fact("observations.remoteAddress", "203.0.113.4"),
                fact("observations.port", "443"),
                fact("observations.timeoutBudgetMs", "5000"),
            ),
        )
        assertEquals(
            listOf(
                "observations.connected", "observations.connectTimeMs",
                "observations.remoteAddress", "observations.port",
            ),
            keys(tcp.primary),
        )
        assertEquals(listOf("observations.timeoutBudgetMs"), keys(tcp.detail))
        assertEquals("36", tcp.primary.first { it.key == "observations.connectTimeMs" }.value)
    }

    @Test
    fun httpsLeadsWithStatusFinalUrlPhaseTimingsAndTls() {
        val connection = listOf(
            fact("network.typeName", "WIFI"),
            fact("network.linkAddresses", "192.168.1.5/24"),
        )
        val observations = listOf(
            fact("observations.statusCode", "200"),
            fact("observations.finalUrl", "https://example.com/"),
            fact("observations.phaseTimings.dnsMs", "4"),
            fact("observations.phaseTimings.tcpConnectMs", "34"),
            fact("observations.phaseTimings.tlsHandshakeMs", "504"),
            fact("observations.phaseTimings.responseHeadersMs", "8"),
            fact("observations.phaseTimings.totalMs", "552"),
            fact("observations.tls.protocol", "TLSv1.3"),
            fact("observations.tls.cipherSuite", "TLS_AES_128_GCM_SHA256"),
            fact("observations.redirects", "…"),
            fact("observations.responseHeaders", "…"),
        )
        val sections = NetworkResultSections.partition(NetworkPage.HTTPS.method, connection, observations)
        assertEquals(
            listOf(
                "observations.statusCode", "observations.finalUrl",
                "observations.phaseTimings.dnsMs", "observations.phaseTimings.tcpConnectMs",
                "observations.phaseTimings.tlsHandshakeMs", "observations.phaseTimings.responseHeadersMs",
                "observations.phaseTimings.totalMs",
                "observations.tls.protocol", "observations.tls.cipherSuite",
            ),
            keys(sections.primary),
        )
        assertEquals(keys(connection), keys(sections.connection))
        assertEquals(listOf("observations.redirects", "observations.responseHeaders"), keys(sections.detail))
        assertEquals("TLSv1.3", sections.primary.first { it.key == "observations.tls.protocol" }.value)
    }

    @Test
    fun unknownFutureMethodKeepsEveryObservationFactPrimary() {
        val observations = listOf(
            fact("observations.services", "printer._ipp._tcp.local"),
            fact("observations.matched", "3"),
        )
        val connection = listOf(fact("network.typeName", "WIFI"))
        val sections = NetworkResultSections.partition("network.futureProbe", connection, observations)
        assertEquals(keys(observations), keys(sections.primary))
        assertEquals(keys(connection), keys(sections.connection))
        assertTrue(sections.detail.isEmpty())
    }

    @Test
    fun lanDiscoveryLeadsWithObservedCountsScopeAndTcpCompletion() {
        val observations = listOf(
            fact("observations.mdns.scope", "capturedNetwork"),
            fact("observations.mdns.networkScoped", "Yes"),
            fact("observations.mdns.serviceCount", "2"),
            fact("observations.mdns.unresolvedCount", "1"),
            fact("observations.mdns.lostCount", "0"),
            fact("observations.mdns.noReplies", "No"),
            fact("observations.mdns.filteredForeignNetwork", "1"),
            fact("observations.tcp.subnetCidr", "192.168.1.0/24"),
            fact("observations.tcp.hostCount", "254"),
            fact("observations.tcp.completedAttempts", "250"),
            fact("observations.tcp.plannedAttempts", "253"),
            fact("observations.tcp.openPortCount", "1"),
            fact("observations.tcp.stoppedReason", "timeBudget"),
            fact("observations.tcp.refusedAttempts", "200"),
            fact("observations.networkChanged", "No"),
        )
        val sections = NetworkResultSections.partition(
            NetworkPage.LAN.method,
            listOf(fact("network.typeName", "WIFI")),
            observations,
        )
        assertEquals(
            listOf(
                "observations.mdns.scope", "observations.mdns.networkScoped",
                "observations.mdns.serviceCount", "observations.mdns.unresolvedCount",
                "observations.mdns.lostCount", "observations.mdns.noReplies",
                "observations.mdns.filteredForeignNetwork",
                "observations.tcp.subnetCidr", "observations.tcp.hostCount",
                "observations.tcp.plannedAttempts", "observations.tcp.completedAttempts",
                "observations.tcp.openPortCount", "observations.tcp.stoppedReason",
                "observations.networkChanged",
            ),
            keys(sections.primary),
        )
        assertEquals(listOf("observations.tcp.refusedAttempts"), keys(sections.detail))
        assertEquals("1", sections.primary.first { it.key == "observations.tcp.openPortCount" }.value)
    }

    @Test
    fun speedTestLeadsWithBudgetAndHonestyFlagsOnly() {
        val observations = listOf(
            fact("observations.budget.maxBytesPerDirection", "8388608"),
            fact("observations.budget.durationBudgetMs", "10000"),
            fact("observations.budget.warmupBytes", "0"),
            fact("observations.budget.timeoutMs", "30000"),
            fact("observations.direction", "download"),
            fact("observations.metered", "No"),
            fact("observations.allowMetered", "No"),
            fact("observations.singleTransfer", "Yes"),
            fact("observations.sampleAdequate", "Yes"),
            fact("observations.networkChanged", "No"),
            fact("observations.download.measuredBytes", "8388608"),
        )
        val sections = NetworkResultSections.partition(
            NetworkPage.SPEED.method,
            listOf(fact("network.typeName", "WIFI")),
            observations,
        )
        assertEquals(
            listOf(
                "observations.budget.maxBytesPerDirection",
                "observations.budget.durationBudgetMs",
                "observations.budget.warmupBytes",
                "observations.budget.timeoutMs",
                "observations.direction",
                "observations.metered",
                "observations.allowMetered",
                "observations.singleTransfer",
                "observations.sampleAdequate",
                "observations.networkChanged",
            ),
            keys(sections.primary),
        )
        assertEquals(listOf("observations.download.measuredBytes"), keys(sections.detail))
        assertTrue(sections.primary.none { it.key?.startsWith("observations.download.") == true })
    }

    @Test
    fun noAnswerOrErrorNeverFabricatesAPrimaryMetric() {
        val sections = NetworkResultSections.partition(
            NetworkPage.DNS.method,
            listOf(fact("network.typeName", "WIFI"), fact("network.state", "CONNECTED")),
            listOf(fact("observations.errorCode", "noActiveNetwork")),
        )
        assertTrue("a failed check has no measured answer to lead with", sections.primary.isEmpty())
        assertEquals(2, sections.connection.size)
        assertEquals(listOf("observations.errorCode"), keys(sections.detail))
    }

    @Test
    fun keylessLegacyFactsAreNeverGuessedFromLabels() {
        val connection = listOf(NetworkFactUi("Connection", "WIFI"))
        val observations = listOf(NetworkFactUi("Answers", "203.0.113.4"))
        val sections = NetworkResultSections.partition(NetworkPage.DNS.method, connection, observations)
        assertTrue(sections.primary.isEmpty())
        assertEquals(connection, sections.connection)
        assertEquals(observations, sections.detail)
    }

    @Test
    fun everyInputFactAppearsExactlyOnceAcrossSections() {
        val connection = listOf(
            fact("network.typeName", "WIFI"),
            fact("network.linkAddresses", "192.168.1.5/24"),
            fact("network.wifi.ssid", "lab"),
            fact("network.wifi.rssiDbm", "-51"),
        )
        val observations = listOf(
            fact("observations.statusCode", "200"),
            fact("observations.phaseTimings.totalMs", "552"),
            fact("observations.redirects", "…"),
        )
        val sections = NetworkResultSections.partition(NetworkPage.HTTPS.method, connection, observations)
        val output = sections.primary + sections.connection + sections.detail
        assertEquals((connection + observations).toSet(), output.toSet())
        assertEquals((connection + observations).size, output.size)
        assertEquals(output.size, output.distinctBy { it.key }.size)
        assertFalse(output.any { it.value.isBlank() })
    }
}
