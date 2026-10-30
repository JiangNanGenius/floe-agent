// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

/** Presentation receives measured facts from the same service as Agent tools. */
enum class NetworkPage(val method: String) {
    OVERVIEW("network.status"), WIFI("network.wifiScan"),
    LAN("network.lanDiscover"), SPEED("network.speedTest"),
    DNS("network.dnsLookup"), PING("network.ping"), TCP("network.tcpProbe"),
    HTTPS("network.http");

    /** Simple pages ask for one host/URL field; LAN and Speed have typed forms. */
    val needsTarget: Boolean get() = this in listOf(DNS, PING, TCP, HTTPS)
}
/**
 * One decoded observation fact. [key] is the stable JSON path of the source
 * field (for example `observations.phaseTimings.totalMs`), populated by the
 * projection that reads NetworkObservationV1. Presentation may use it to
 * order the actual measured answers; it is never a display label and it is
 * always optional so older projections keep compiling unchanged.
 */
data class NetworkFactUi(val label: String, val value: String, val key: String? = null)
data class WifiAccessPointUi(
    val identity: String, val name: String, val bssid: String?, val signalDbm: Int?,
    val frequencyMHz: Int?, val channel: Int?, val security: String?, val ageMs: Long?,
    val timestampMicros: Long? = null, val signalHistoryDbm: List<Int> = emptyList(),
)
data class NetworkObservationUi(
    val method: String, val status: String, val measuredAt: String,
    val facts: List<NetworkFactUi> = emptyList(),
    val accessPoints: List<WifiAccessPointUi> = emptyList(),
    val limitations: List<String> = emptyList(), val cacheAgeMs: Long? = null,
    val missingPermissions: List<String> = emptyList(), val details: String = "",
    /** Method-specific actual answers, in display order. */
    val primaryFacts: List<NetworkFactUi> = emptyList(),
    /** Captured-network metadata (addresses, routes, DNS servers, …). */
    val connectionFacts: List<NetworkFactUi> = emptyList(),
    /** Remaining observation detail (scan flags, probe rows, redirects, …). */
    val detailFacts: List<NetworkFactUi> = emptyList(),
    /** Structured LAN inventory from `network.lanDiscover`; null for other methods. */
    val lan: LanDiscoveryUi? = null,
    /** Structured transfer results from `network.speedTest`; null for other methods. */
    val speed: SpeedTestUi? = null,
    /** Metadata from a peer whose platform TLS handshake succeeded. */
    val certificates: List<TlsCertificateUi> = emptyList(),
)
data class NetworkWorkbenchState(
    val results: Map<NetworkPage, NetworkObservationUi> = emptyMap(),
    val running: NetworkPage? = null,
    /** The user asked to stop and the typed service response is still pending. */
    val stopping: Boolean = false,
)

/** Values are measurements at the captured time, not a revocation or pin check. */
data class TlsCertificateUi(
    val index: Int,
    val sha256: String,
    val notBefore: String,
    val notAfter: String,
    val validAtObservation: Boolean,
    val signatureAlgorithm: String,
    val publicKeyAlgorithm: String,
)
