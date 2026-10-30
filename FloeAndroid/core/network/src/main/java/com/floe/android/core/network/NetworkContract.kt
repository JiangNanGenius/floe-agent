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
    const val DEFAULT_LAN_TIMEOUT_MS = 20_000
    const val DEFAULT_SPEED_TIMEOUT_MS = 30_000

    // G07.2 LAN discovery bounds.
    const val MAX_LAN_SERVICE_TYPES = 8
    const val MAX_LAN_SERVICES = 64
    const val MAX_LAN_ATTRIBUTES = 16
    const val MAX_LAN_ATTRIBUTE_KEY_CHARS = 32
    const val MAX_LAN_ATTRIBUTE_VALUE_BYTES = 128
    const val MIN_LAN_DISCOVERY_MS = 500
    const val MAX_LAN_DISCOVERY_MS = 15_000
    const val DEFAULT_LAN_DISCOVERY_MS = 4_000

    // G07.2 bounded private-subnet TCP discovery.
    const val MAX_TCP_PORTS = 8
    const val MAX_TCP_HOSTS = 254
    const val MAX_TCP_ATTEMPTS = 1_024
    const val MIN_TCP_CONNECT_TIMEOUT_MS = 100
    const val MAX_TCP_CONNECT_TIMEOUT_MS = 2_000
    const val DEFAULT_TCP_CONNECT_TIMEOUT_MS = 500
    const val MAX_TCP_CONCURRENCY = 32
    const val DEFAULT_TCP_CONCURRENCY = 16
    const val MAX_TCP_OPEN_PORTS = 256

    // G07.2 explicitly budgeted throughput diagnostics.
    const val MIN_SPEED_BYTES = 65_536
    const val MAX_SPEED_BYTES = 33_554_432
    const val DEFAULT_SPEED_BYTES = 8_388_608
    const val MIN_SPEED_DURATION_MS = 1_000
    const val MAX_SPEED_DURATION_MS = 15_000
    const val DEFAULT_SPEED_DURATION_MS = 10_000
    const val MAX_SPEED_WARMUP_BYTES = 262_144
    const val MIN_SPEED_SAMPLE_BYTES = 65_536
    const val MIN_SPEED_SAMPLE_MS = 250
    const val SPEED_CONNECTION_MARGIN_MS = 1_500

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
    HTTP("network.http", NetworkLimits.DEFAULT_HTTP_TIMEOUT_MS),
    LAN_DISCOVER("network.lanDiscover", NetworkLimits.DEFAULT_LAN_TIMEOUT_MS),
    SPEED_TEST("network.speedTest", NetworkLimits.DEFAULT_SPEED_TIMEOUT_MS);

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
