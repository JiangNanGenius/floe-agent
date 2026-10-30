// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

/** Frozen NetworkObservationV1 request/result constants. */
internal object NetworkLimits {
    const val VERSION = 1

    /** Whole request JSON, UTF-8 bytes. */
    const val MAX_REQUEST_BYTES = 16 * 1024
    /** Whole result JSON, UTF-8 bytes; oversized observations are truncated honestly. */
    const val MAX_OUTPUT_BYTES = 256 * 1024

    const val MAX_ACCESS_POINTS = 256
    const val MAX_PING_COUNT = 10
    const val MAX_REDIRECTS = 10
    const val MAX_TIMEOUT_MS = 30_000
    const val MIN_TIMEOUT_MS = 500

    const val DEFAULT_STATUS_TIMEOUT_MS = 5_000
    const val DEFAULT_WIFI_TIMEOUT_MS = 10_000
    const val DEFAULT_DNS_TIMEOUT_MS = 5_000
    const val DEFAULT_PING_TIMEOUT_MS = 5_000
    const val DEFAULT_TCP_TIMEOUT_MS = 5_000
    const val DEFAULT_HTTP_TIMEOUT_MS = 10_000

    const val MAX_HOST_CHARS = 253
    const val MAX_URL_CHARS = 4096
    const val MAX_IDENTIFIER_CHARS = 64
    const val MAX_DNS_RESPONSE_BYTES = 4096
    const val MAX_DNS_RECORDS = 64
    const val MAX_LIMITATIONS = 32
    const val MAX_LIMITATION_CHARS = 300
}

/** Exact method names accepted by PhoneNetworkService. */
internal enum class NetworkMethod(val wire: String, val defaultTimeoutMs: Int) {
    STATUS("network.status", NetworkLimits.DEFAULT_STATUS_TIMEOUT_MS),
    WIFI_SCAN("network.wifiScan", NetworkLimits.DEFAULT_WIFI_TIMEOUT_MS),
    DNS_LOOKUP("network.dnsLookup", NetworkLimits.DEFAULT_DNS_TIMEOUT_MS),
    PING("network.ping", NetworkLimits.DEFAULT_PING_TIMEOUT_MS),
    TCP_PROBE("network.tcpProbe", NetworkLimits.DEFAULT_TCP_TIMEOUT_MS),
    HTTP("network.http", NetworkLimits.DEFAULT_HTTP_TIMEOUT_MS);

    companion object {
        fun fromWire(value: String): NetworkMethod? = entries.firstOrNull { it.wire == value }
    }
}

/** DNS record selector as frozen in the G07.1 contract. */
internal enum class DnsRecordType(val wire: String, val dnsType: Int?) {
    A("A", 1),
    AAAA("AAAA", 28),
    A_AND_AAAA("A_AND_AAAA", null);

    companion object {
        fun fromWire(value: String): DnsRecordType? = entries.firstOrNull { it.wire == value }
    }
}

/** The only status values allowed by NetworkObservationV1. */
internal enum class ObservationStatus(val wire: String) {
    OK("ok"),
    PARTIAL("partial"),
    PERMISSION_REQUIRED("permissionRequired"),
    UNAVAILABLE("unavailable"),
    UNSUPPORTED("unsupported"),
    CANCELLED("cancelled"),
    TIMEOUT("timeout"),
    ERROR("error"),
}
