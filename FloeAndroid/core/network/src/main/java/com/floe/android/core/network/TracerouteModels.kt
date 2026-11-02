// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONObject

/**
 * Frozen `network.traceroute` request v1. Mirrors the original NET-PING-TRACE
 * tool shape (increasing IP TTL, bounded probes per hop) inside the existing
 * NetworkObservationV1 envelope; every value is normalized/clamped by the
 * parser before a session ever sees it.
 */
internal data class TracerouteRequest(
    val host: String,
    val maxHops: Int = NetworkLimits.DEFAULT_TRACEROUTE_HOPS,
    val probesPerHop: Int = NetworkLimits.DEFAULT_TRACEROUTE_PROBES_PER_HOP,
    val probeTimeoutMs: Int = NetworkLimits.DEFAULT_TRACEROUTE_PROBE_TIMEOUT_MS,
) {
    init {
        require(maxHops in NetworkLimits.MIN_TRACEROUTE_HOPS..NetworkLimits.MAX_TRACEROUTE_HOPS) {
            "maxHops out of bounds"
        }
        require(probesPerHop in NetworkLimits.MIN_TRACEROUTE_PROBES_PER_HOP..NetworkLimits.MAX_TRACEROUTE_PROBES_PER_HOP) {
            "probesPerHop out of bounds"
        }
        require(probeTimeoutMs in NetworkLimits.MIN_TRACEROUTE_PROBE_TIMEOUT_MS..NetworkLimits.MAX_TRACEROUTE_PROBE_TIMEOUT_MS) {
            "probeTimeoutMs out of bounds"
        }
    }
}

/** What one hop's probes actually observed; timeout hops carry no address. */
internal enum class TracerouteHopStatus(val wire: String) {
    REACHED("reached"),
    TIME_EXCEEDED("timeExceeded"),
    TIMEOUT("timeout"),
    UNREACHABLE("unreachable"),
}

/**
 * One observed hop. The probe only constructs valid rows; the strict
 * [fromJson] factory lets regressions and projections reject malformed
 * observed hop data (out-of-range TTL, address on a timeout hop, non-finite
 * RTTs, RTTs beyond the probe budget, mixed identities) instead of rendering
 * invented measurements.
 */
internal data class TracerouteHop(
    val ttl: Int,
    val status: TracerouteHopStatus,
    val address: String? = null,
    val rttsMs: List<Double> = emptyList(),
    val unreachableCode: Int? = null,
) {
    init {
        require(ttl in NetworkLimits.MIN_TRACEROUTE_HOPS..NetworkLimits.MAX_TRACEROUTE_HOPS) {
            "hop TTL out of bounds"
        }
        require(address == null || address.isNotBlank()) { "hop address must not be blank" }
        when (status) {
            TracerouteHopStatus.TIMEOUT ->
                require(address == null && unreachableCode == null) {
                    "a timed-out hop cannot carry an address or unreachable code"
                }

            TracerouteHopStatus.TIME_EXCEEDED, TracerouteHopStatus.REACHED -> {
                require(address != null) { "a responding hop needs its observed address" }
                require(unreachableCode == null) {
                    "only an unreachable hop carries an ICMP unreachable code"
                }
            }

            TracerouteHopStatus.UNREACHABLE ->
                require(address != null && unreachableCode != null) {
                    "an unreachable hop needs its observed address and ICMP code"
                }
        }
        require(rttsMs.size <= NetworkLimits.MAX_TRACEROUTE_PROBES_PER_HOP) {
            "a hop cannot report more RTTs than the probe budget"
        }
        require(rttsMs.all { it.isFinite() && it >= 0.0 }) { "RTTs must be finite and non-negative" }
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("ttl", ttl)
        put("status", status.wire)
        address?.let { put("address", it) }
        unreachableCode?.let { put("unreachableCode", it) }
        if (rttsMs.isNotEmpty()) {
            put(
                "rttsMs",
                org.json.JSONArray().apply { rttsMs.forEach { put(it) } },
            )
        }
    }

    companion object {
        /** Strict decoder for untrusted/persisted hop rows; null = malformed. */
        fun fromJson(json: JSONObject): TracerouteHop? = runCatching {
            val ttl = json.optInt("ttl", -1)
            val statusWire = json.optString("status")
            val status = TracerouteHopStatus.entries.firstOrNull { it.wire == statusWire }
                ?: return null
            val address = json.optString("address").takeIf { it.isNotBlank() }
            val unreachableCode = if (json.has("unreachableCode") && !json.isNull("unreachableCode")) {
                json.optInt("unreachableCode")
            } else {
                null
            }
            val rtts = json.optJSONArray("rttsMs")?.let { array ->
                (0 until array.length()).map { index ->
                    array.optDouble(index, Double.NaN)
                }
            }.orEmpty()
            TracerouteHop(
                ttl = ttl,
                status = status,
                address = address,
                rttsMs = rtts,
                unreachableCode = unreachableCode,
            )
        }.getOrNull()
    }
}
