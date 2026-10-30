// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import java.util.Locale

/** One DNS-SD service exactly as the service observed it. */
data class LanServiceUi(
    val serviceName: String,
    val serviceType: String,
    val hostname: String?,
    val addresses: List<String>,
    val port: Int?,
    val state: String,
    val resolution: String,
    val resolveError: String? = null,
) {
    val resolved: Boolean get() = resolution == "resolved" && addresses.isNotEmpty() && port != null
    val lost: Boolean get() = state == "lost"
}

/** Actual mDNS discovery summary, including honest empty/unsupported states. */
data class LanMdnsUi(
    val requestedServiceTypes: List<String>,
    val scope: String,
    val networkScoped: Boolean,
    val discoveryDurationMs: Int,
    val elapsedMs: Long,
    val services: List<LanServiceUi>,
    val serviceCount: Int,
    val activeServiceCount: Int,
    val unresolvedCount: Int,
    val lostCount: Int,
    val filteredForeignNetwork: Int,
    val truncated: Boolean,
    val noReplies: Boolean,
    val stoppedReason: String,
)

data class LanOpenPortUi(
    val address: String,
    val port: Int,
    val connectTimeMs: Long,
)

/** Boundary TCP scan summary; only successful connects become open ports. */
data class LanTcpUi(
    val subnetCidr: String,
    val ports: List<Int>,
    val hostCount: Int,
    val excludedSelfAddresses: List<String>,
    val attemptedHosts: Int,
    val plannedAttempts: Int,
    val completedAttempts: Int,
    val openPorts: List<LanOpenPortUi>,
    val refusedAttempts: Int,
    val timedOutAttempts: Int,
    val errorAttempts: Int,
    val unreachableAttempts: Int,
    val hostsWithResponse: Int,
    val hostsWithOpenPort: Int,
    val truncated: Boolean,
    val stoppedReason: String,
    val cancelled: Boolean,
    val elapsedMs: Long,
)

data class LanDiscoveryUi(
    val mdns: LanMdnsUi? = null,
    val tcp: LanTcpUi? = null,
    val noReplies: Boolean = false,
    val networkChanged: Boolean = false,
    val cancelled: Boolean = false,
    val errorCode: String? = null,
)

/** One measured direction from `network.speedTest`. */
data class SpeedTransferUi(
    val direction: String,
    val endpoint: String,
    val status: String,
    val payloadBytes: Long?,
    val measuredBytes: Long?,
    val warmupBytes: Long?,
    val measurementElapsedMs: Long?,
    val totalElapsedMs: Long?,
    val bitsPerSecond: Double?,
    val rateAvailable: Boolean,
    val rateOmittedReason: String?,
    val completionReason: String?,
    val contentComplete: Boolean,
    val clientStopped: Boolean,
    val httpStatus: Int?,
    val contentLength: Long?,
    val contentEncoding: String?,
    val tlsProtocol: String?,
    val cipherSuite: String?,
    val payloadBytesMeaning: String?,
    val networkChanged: Boolean,
)

data class SpeedTestUi(
    val direction: String,
    val maxBytesPerDirection: Long?,
    val durationBudgetMs: Long?,
    val warmupBytes: Long?,
    val timeoutMs: Long?,
    val metered: Boolean?,
    val allowMetered: Boolean,
    val singleTransfer: Boolean,
    val sampleAdequate: Boolean?,
    val transfers: List<SpeedTransferUi>,
    val networkChanged: Boolean,
    val proxyConfigured: Boolean,
    val proxyHost: String?,
    val proxyPort: Int?,
    val cancelled: Boolean,
    val errorCode: String?,
)

/** Exact byte counts are always shown next to a scaled value. */
object NetworkMeasureFormat {
    fun bytes(bytes: Long): String {
        if (bytes < 1_024L) return "$bytes B"
        val units = listOf("KiB", "MiB", "GiB", "TiB")
        var value = bytes.toDouble()
        var unit = -1
        while (value >= 1_024.0 && unit < units.lastIndex) {
            value /= 1_024.0
            unit++
        }
        return String.format(Locale.ROOT, "%.1f %s (%d B)", value, units[unit], bytes)
    }

    fun duration(ms: Long): String {
        if (ms < 1_000L) return "$ms ms"
        return String.format(Locale.ROOT, "%.1f s (%d ms)", ms / 1_000.0, ms)
    }

    fun bitsPerSecond(bits: Double): String {
        if (!bits.isFinite() || bits < 0.0) return ""
        return when {
            bits >= 1_000_000_000.0 -> String.format(Locale.ROOT, "%.1f Gbps", bits / 1_000_000_000.0)
            bits >= 1_000_000.0 -> String.format(Locale.ROOT, "%.1f Mbps", bits / 1_000_000.0)
            bits >= 1_000.0 -> String.format(Locale.ROOT, "%.1f kbps", bits / 1_000.0)
            else -> String.format(Locale.ROOT, "%.0f bps", bits)
        }
    }
}
