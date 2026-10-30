// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

/**
 * Pure sectioning for the phone-network methods (six G07.1 methods plus the
 * G07.2 LAN discovery and speed-test pages).
 *
 * The measurement service already returns the actual answer and a large
 * captured-network snapshot in one response. The projection gives each fact
 * its stable JSON path; this object moves those actual facts into:
 *  - [Sections.primary]: the method's real answer (AP link, DNS answers,
 *    ping loss/RTT, TCP result/timing, HTTPS status/TLS/timing);
 *  - [Sections.connection]: the common captured-network metadata shown only
 *    in explicit Details;
 *  - [Sections.detail]: remaining observation rows shown in Details.
 *
 * It never creates, derives or guesses a measurement: every returned fact is
 * one of the input facts, unchanged. Unknown/future methods keep their whole
 * observation list primary so a new method cannot silently lose its result.
 */
object NetworkResultSections {
    data class Sections(
        val primary: List<NetworkFactUi>,
        val connection: List<NetworkFactUi>,
        val detail: List<NetworkFactUi>,
    )

    private val WIFI_LINK_KEYS = listOf(
        "network.wifi.ssid",
        "network.wifi.rssiDbm",
        "network.wifi.channel",
        "network.wifi.frequencyMhz",
        "network.wifi.band",
        "network.wifi.linkSpeedMbps",
        "network.wifi.rxLinkSpeedMbps",
        "network.wifi.txLinkSpeedMbps",
        "network.wifi.wifiStandard",
    )

    private val OVERVIEW_KEYS = listOf(
        "network.typeName",
        "network.state",
        "network.internet",
        "network.validated",
        "network.localNetwork",
        "network.metered",
        "network.roaming",
        "network.privateDnsActive",
        "network.interfaceName",
    ) + WIFI_LINK_KEYS

    private val WIFI_SCAN_KEYS = listOf(
        "observations.totalAccessPoints",
        "observations.freshness",
    )

    private val DNS_KEYS = listOf(
        "observations.answers",
        "observations.addresses",
        "observations.rcodeName",
        "observations.elapsedMs",
        "observations.recordType",
        "observations.queryFailures",
        "observations.truncated",
    )

    private val PING_KEYS = listOf(
        "observations.resolvedAddress",
        "observations.family",
        "observations.sent",
        "observations.received",
        "observations.lost",
        "observations.packetLossPercent",
        "observations.rttMinMs",
        "observations.rttMaxMs",
        "observations.rttAvgMs",
        "observations.countRequested",
    )

    private val TCP_KEYS = listOf(
        "observations.connected",
        "observations.connectTimeMs",
        "observations.remoteAddress",
        "observations.port",
        "observations.resolvedAddresses",
        "observations.refused",
        "observations.attempts",
    )

    private val HTTPS_KEYS = listOf(
        "observations.statusCode",
        "observations.finalUrl",
        "observations.phaseTimings.dnsMs",
        "observations.phaseTimings.tcpConnectMs",
        "observations.phaseTimings.tlsHandshakeMs",
        "observations.phaseTimings.responseHeadersMs",
        "observations.phaseTimings.totalMs",
        "observations.probeTotalMs",
        "observations.tls.protocol",
        "observations.tls.cipherSuite",
        "observations.redirectCount",
        "observations.requestedUrl",
        "observations.contentType",
        "observations.stoppedReason",
    )

    /**
     * LAN discovery leads with the actual inventory counts/scope and the TCP
     * completion facts. Service rows and open ports keep their own structured
     * presentation, and all raw fields stay in explicit Details.
     */
    private val LAN_KEYS = listOf(
        "observations.mdns.scope",
        "observations.mdns.networkScoped",
        "observations.mdns.serviceCount",
        "observations.mdns.activeServiceCount",
        "observations.mdns.unresolvedCount",
        "observations.mdns.lostCount",
        "observations.mdns.noReplies",
        "observations.mdns.filteredForeignNetwork",
        "observations.mdns.elapsedMs",
        "observations.tcp.subnetCidr",
        "observations.tcp.hostCount",
        "observations.tcp.plannedAttempts",
        "observations.tcp.completedAttempts",
        "observations.tcp.openPortCount",
        "observations.tcp.hostsWithResponse",
        "observations.tcp.hostsWithOpenPort",
        "observations.tcp.stoppedReason",
        "observations.tcp.elapsedMs",
        "observations.networkChanged",
        "observations.noReplies",
    )

    /**
     * The speed page leads with the frozen budget and the overall honesty
     * flags. Per-direction transfer rows are structured (download/upload), and
     * a rate only appears when the service marked it available.
     */
    private val SPEED_KEYS = listOf(
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
    )

    private val OBSERVATION_KEYS: Map<String, List<String>> = mapOf(
        NetworkPage.OVERVIEW.method to emptyList(),
        NetworkPage.WIFI.method to WIFI_SCAN_KEYS,
        NetworkPage.LAN.method to LAN_KEYS,
        NetworkPage.SPEED.method to SPEED_KEYS,
        NetworkPage.DNS.method to DNS_KEYS,
        NetworkPage.PING.method to PING_KEYS,
        NetworkPage.TCP.method to TCP_KEYS,
        NetworkPage.HTTPS.method to HTTPS_KEYS,
    )

    fun partition(
        method: String,
        connectionFacts: List<NetworkFactUi>,
        observationFacts: List<NetworkFactUi>,
    ): Sections {
        val connectionKeys = when (method) {
            NetworkPage.OVERVIEW.method -> OVERVIEW_KEYS
            NetworkPage.WIFI.method -> WIFI_LINK_KEYS
            else -> emptyList()
        }
        val observationKeys = OBSERVATION_KEYS[method]
        if (observationKeys == null) {
            // A method this presentation does not know yet: show ALL of its
            // actual observation rows, never an empty/fabricated summary.
            return Sections(
                primary = observationFacts,
                connection = connectionFacts,
                detail = emptyList(),
            )
        }
        val connection = select(connectionFacts, connectionKeys)
        val observation = select(observationFacts, observationKeys)
        return Sections(
            primary = connection.selected + observation.selected,
            connection = connection.remaining,
            detail = observation.remaining,
        )
    }

    private class Selection(
        val selected: List<NetworkFactUi>,
        val remaining: List<NetworkFactUi>,
    )

    /** Stable-key selection: key order wins; input order breaks ties. */
    private fun select(facts: List<NetworkFactUi>, keys: List<String>): Selection {
        if (keys.isEmpty()) return Selection(emptyList(), facts)
        val used = BooleanArray(facts.size)
        val selected = ArrayList<NetworkFactUi>()
        keys.forEach { key ->
            facts.forEachIndexed { index, fact ->
                if (!used[index] && fact.key == key) {
                    used[index] = true
                    selected += fact
                }
            }
        }
        val remaining = facts.filterIndexed { index, _ -> !used[index] }
        return Selection(selected, remaining)
    }
}
