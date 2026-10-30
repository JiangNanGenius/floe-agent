// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONArray
import org.json.JSONObject

/**
 * One actual Wi-Fi link as reported by WifiManager.getConnectionInfo() on the
 * currently captured Network. Fields are absent when the OS redacts or does
 * not expose them; they are never guessed.
 */
internal data class WifiLinkSnapshot(
    val ssid: String? = null,
    val ssidRedacted: Boolean = false,
    val bssid: String? = null,
    val bssidRedacted: Boolean = false,
    val rssiDbm: Int? = null,
    val frequencyMhz: Int? = null,
    val channel: Int? = null,
    val band: String? = null,
    val linkSpeedMbps: Int? = null,
    val rxLinkSpeedMbps: Int? = null,
    val txLinkSpeedMbps: Int? = null,
    val wifiStandard: String? = null,
    val hiddenSsid: Boolean? = null,
) {
    fun toJson(): JSONObject = JSONObject().apply {
        ssid?.let { put("ssid", it) }
        if (ssidRedacted) put("ssidRedacted", true)
        bssid?.let { put("bssid", it) }
        if (bssidRedacted) put("bssidRedacted", true)
        rssiDbm?.let { put("rssiDbm", it) }
        frequencyMhz?.let { put("frequencyMhz", it) }
        channel?.let { put("channel", it) }
        band?.let { put("band", it) }
        linkSpeedMbps?.let { put("linkSpeedMbps", it) }
        rxLinkSpeedMbps?.let { put("rxLinkSpeedMbps", it) }
        txLinkSpeedMbps?.let { put("txLinkSpeedMbps", it) }
        wifiStandard?.let { put("wifiStandard", it) }
        hiddenSsid?.let { put("hiddenSsid", it) }
    }
}

/**
 * Actual Android Network state captured once at the start of an execute()
 * call. The same Network handle is used by every method of that call; this
 * snapshot is descriptive only and never becomes a routing decision elsewhere.
 */
internal data class NetworkSnapshot(
    val available: Boolean,
    val handle: String? = null,
    val networkCount: Int? = null,
    val transports: List<String> = emptyList(),
    val capabilities: List<String> = emptyList(),
    val typeName: String? = null,
    val subtypeName: String? = null,
    val state: String? = null,
    val detailedState: String? = null,
    val connected: Boolean? = null,
    val roaming: Boolean? = null,
    val metered: Boolean? = null,
    val validated: Boolean? = null,
    val internet: Boolean? = null,
    val localNetwork: Boolean? = null,
    val captivePortal: Boolean? = null,
    val vpn: Boolean = false,
    val interfaceName: String? = null,
    val mtu: Int? = null,
    val dnsServers: List<String> = emptyList(),
    val domains: String? = null,
    val privateDnsActive: Boolean? = null,
    val privateDnsServerName: String? = null,
    val httpProxyHost: String? = null,
    val httpProxyPort: Int? = null,
    val linkAddresses: List<String> = emptyList(),
    val routes: Int? = null,
    val nat64Prefix: String? = null,
    val dhcpServer: String? = null,
    val wakeOnLanSupported: Boolean? = null,
    val signalStrength: Int? = null,
    val downstreamKbps: Int? = null,
    val upstreamKbps: Int? = null,
    val wifi: WifiLinkSnapshot? = null,
    val limitations: List<String> = emptyList(),
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("available", available)
        handle?.let { put("handle", it) }
        networkCount?.let { put("networkCount", it) }
        if (available) {
            put("transports", jsonArray(transports))
            put("capabilities", jsonArray(capabilities))
            typeName?.let { put("typeName", it) }
            subtypeName?.let { put("subtypeName", it) }
            state?.let { put("state", it) }
            detailedState?.let { put("detailedState", it) }
            connected?.let { put("connected", it) }
            roaming?.let { put("roaming", it) }
            metered?.let { put("metered", it) }
            validated?.let { put("validated", it) }
            internet?.let { put("internet", it) }
            localNetwork?.let { put("localNetwork", it) }
            captivePortal?.let { put("captivePortal", it) }
            put("vpn", vpn)
            interfaceName?.let { put("interfaceName", it) }
            mtu?.let { put("mtu", it) }
            put("dnsServers", jsonArray(dnsServers))
            domains?.let { put("domains", it) }
            privateDnsActive?.let { put("privateDnsActive", it) }
            privateDnsServerName?.let { put("privateDnsServerName", it) }
            httpProxyHost?.let {
                put("httpProxy", JSONObject().put("host", it).put("port", httpProxyPort ?: -1))
            }
            put("linkAddresses", jsonArray(linkAddresses))
            routes?.let { put("routes", it) }
            nat64Prefix?.let { put("nat64Prefix", it) }
            dhcpServer?.let { put("dhcpServer", it) }
            wakeOnLanSupported?.let { put("wakeOnLanSupported", it) }
            signalStrength?.let { put("signalStrengthDbm", it) }
            downstreamKbps?.let { put("downstreamKbps", it) }
            upstreamKbps?.let { put("upstreamKbps", it) }
            wifi?.let { put("wifi", it.toJson()) }
        }
    }
}

/** One platform measurement plus its real limitations. */
internal data class ProbeResult(
    val status: ObservationStatus = ObservationStatus.OK,
    val observations: JSONObject = JSONObject(),
    val limitations: List<String> = emptyList(),
    val target: String? = null,
    val cacheAgeMs: Long? = null,
    val missingPermissions: List<String> = emptyList(),
)

internal fun jsonArray(values: Collection<String>): JSONArray = JSONArray().apply {
    values.forEach { put(it) }
}
