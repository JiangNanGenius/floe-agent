// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

/** Presentation receives measured facts from the same service as Agent tools. */
enum class NetworkPage(val method: String) {
    OVERVIEW("network.status"), WIFI("network.wifiScan"), DNS("network.dnsLookup"),
    PING("network.ping"), TCP("network.tcpProbe"), HTTPS("network.http");
    val needsTarget: Boolean get() = this !in listOf(OVERVIEW, WIFI)
}
data class NetworkFactUi(val label: String, val value: String)
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
)
data class NetworkWorkbenchState(
    val results: Map<NetworkPage, NetworkObservationUi> = emptyMap(),
    val running: NetworkPage? = null,
)
