// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.pcap

import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/**
 * Hard product bounds for offline capture analysis. They are deliberately
 * enforced by the parser, store and renderer, not by caller convention:
 * a 128 MiB source is the same limit as the existing SAF attachment cap,
 * parsing is stopped at a 30 second monotonic budget, no more than two
 * million packets or 65k flow keys are aggregated, and every persisted or
 * exported document stays below 4 MiB.
 */
object PcapLimits {
    const val MAX_SOURCE_BYTES = 128L * 1024L * 1024L
    const val MAX_PACKETS = 2_000_000L
    const val MAX_FLOW_KEYS = 65_536
    const val MAX_RETAINED_FLOWS = 500
    const val MAX_RESULT_BYTES = 4 * 1024 * 1024
    const val MAX_MARKDOWN_BYTES = 512 * 1024
    const val MAX_CSV_BYTES = 1024 * 1024
    const val MAX_PARSE_BUDGET_MILLIS = 30_000L
    const val MAX_PACKET_CAPTURE_BYTES = 65_535
    const val MAX_BLOCK_BYTES = 4 * 1024 * 1024
    const val MAX_TIMELINE_BUCKETS = 120
    const val MAX_DNS_RECORDS = 200
    const val MAX_HTTP_RECORDS = 200
    const val MAX_INTERFACES = 64
    const val MAX_STORED_ANALYSES = 20
    const val MAX_ADDRESS_CHARS = 64
    const val MAX_SOURCE_LABEL_CHARS = 128
    const val MAX_LIMITATIONS = 24
}

enum class PcapCaptureFormat(val wire: String) {
    PCAP("pcap"),
    PCAPNG("pcapng"),
    UNKNOWN("unknown"),
}

enum class PcapAnalysisStatus(val wire: String) {
    OK("ok"),
    PARTIAL("partial"),
    FAILED("failed"),
}

enum class PcapProtocol(val wire: String) {
    TCP("tcp"),
    UDP("udp"),
    ICMP("icmp"),
    ICMPV6("icmpv6"),
    OTHER("other"),
    NON_IP("nonIp"),
    ;

    companion object {
        fun fromWire(value: String): PcapProtocol? = entries.firstOrNull { it.wire == value }
    }
}

enum class PcapIpVersion(val number: Int) {
    IPV4(4),
    IPV6(6),
    ;

    val wire: String get() = "ipv$number"
}

/** DNS/HTTP extraction can be narrowed without pretending they are L4 protocols. */
enum class PcapServiceFilter { DNS, HTTP }

/**
 * View filters. They always run against the already bounded 500 retained
 * flows and 200 DNS/HTTP records; totals remain the honest global totals.
 */
data class PcapFilters(
    val protocols: Set<PcapProtocol> = emptySet(),
    val services: Set<PcapServiceFilter> = emptySet(),
    val address: String? = null,
    val port: Int? = null,
    val startEpochMillis: Long? = null,
    val endEpochMillis: Long? = null,
) {
    init {
        require(protocols.none { it == PcapProtocol.NON_IP }) {
            "protocol filters are tcp, udp, icmp, icmpv6 or other"
        }
        require(address == null || (address.isNotBlank() &&
            address.length <= PcapLimits.MAX_ADDRESS_CHARS &&
            address.none { it.isWhitespace() || it in "/@?#" })) {
            "address filter must be a bounded bare address"
        }
        require(port == null || port in 1..65_535) { "port filter must be 1..65535" }
        require(startEpochMillis == null || startEpochMillis >= 0L) { "start time must be non-negative" }
        require(endEpochMillis == null || endEpochMillis >= 0L) { "end time must be non-negative" }
        require(startEpochMillis == null || endEpochMillis == null ||
            startEpochMillis <= endEpochMillis) { "start time must not be after end time" }
    }

    val isEmpty: Boolean
        get() = protocols.isEmpty() && services.isEmpty() && address == null &&
            port == null && startEpochMillis == null && endEpochMillis == null

    val addressToken: String? get() = address?.let(PcapIdentifiers::token)

    fun matchesProtocol(protocol: PcapProtocol): Boolean =
        protocols.isEmpty() || protocol in protocols

    fun matchesAddressPort(source: PcapEndpoint, destination: PcapEndpoint): Boolean {
        if (port != null && source.port != port && destination.port != port) return false
        val token = addressToken ?: return true
        return source.addressToken == token || destination.addressToken == token
    }

    /** A flow is retained when its lifetime overlaps the requested window. */
    fun matchesFlow(flow: PcapFlow): Boolean {
        if (!matchesProtocol(flow.protocol)) return false
        if (!matchesAddressPort(flow.source, flow.destination)) return false
        val start = startEpochMillis
        val end = endEpochMillis
        if (start != null && flow.lastEpochMillis < start) return false
        if (end != null && flow.firstEpochMillis > end) return false
        return true
    }

    fun matchesTime(epochMillis: Long): Boolean =
        (startEpochMillis == null || epochMillis >= startEpochMillis) &&
            (endEpochMillis == null || epochMillis <= endEpochMillis)

    fun matchesExtraction(protocol: PcapProtocol, source: PcapEndpoint,
                          destination: PcapEndpoint, epochMillis: Long): Boolean =
        matchesProtocol(protocol) && matchesAddressPort(source, destination) &&
            matchesTime(epochMillis)
}

/** One display-safe endpoint. The token is always derived from the real address bytes. */
data class PcapEndpoint(
    val address: String,
    val addressToken: String,
    val port: Int? = null,
) {
    init {
        require(address.isNotBlank() && address.length <= PcapLimits.MAX_ADDRESS_CHARS) {
            "endpoint address must be bounded"
        }
        require(addressToken.matches(Regex("[0-9a-f]{16,64}"))) { "endpoint token must be hex" }
        require(port == null || port in 1..65_535) { "endpoint port must be 1..65535" }
    }
}

data class PcapProtocolStats(
    val protocol: PcapProtocol,
    val packetCount: Long,
    val byteCount: Long,
)

data class PcapFlow(
    val protocol: PcapProtocol,
    val ipVersion: PcapIpVersion,
    val source: PcapEndpoint,
    val destination: PcapEndpoint,
    val packetCount: Long,
    val byteCount: Long,
    val firstEpochMillis: Long,
    val lastEpochMillis: Long,
    val tcpFlags: String? = null,
) {
    init {
        require(packetCount > 0) { "a flow has at least one packet" }
        require(byteCount >= 0) { "flow bytes are non-negative" }
        require(firstEpochMillis <= lastEpochMillis) { "flow time order" }
    }
}

data class PcapTimelineBucket(
    val startEpochMillis: Long,
    val bucketMillis: Long,
    val packetCount: Long,
    val byteCount: Long,
)

data class PcapInterface(
    val index: Int,
    val linkType: Int,
    val snaplen: Long,
    val timestampResolution: String,
    val name: String? = null,
) {
    init {
        require(index >= 0) { "interface index" }
        require(linkType >= 0) { "link type" }
        require(snaplen >= 0) { "snaplen" }
        require(timestampResolution.length <= 32) { "timestamp resolution" }
    }
}

data class PcapDnsRecord(
    val timestampEpochMillis: Long,
    val direction: String,
    val name: String,
    val nameToken: String,
    val recordType: String,
    val responseCode: Int?,
    val source: PcapEndpoint,
    val destination: PcapEndpoint,
    val overTcp: Boolean,
    val truncated: Boolean = false,
) {
    init {
        require(direction == "query" || direction == "response") { "dns direction" }
        require(name.isNotBlank() && name.length <= 320) { "dns name bounded" }
        require(nameToken.matches(Regex("[0-9a-f]{16,64}"))) { "dns token" }
        require(recordType.length <= 16) { "dns type" }
    }
}

data class PcapHttpRecord(
    val timestampEpochMillis: Long,
    val direction: String,
    val methodOrStatus: String,
    val host: String?,
    val path: String?,
    val source: PcapEndpoint,
    val destination: PcapEndpoint,
    val payloadBytes: Int,
    val truncated: Boolean = false,
) {
    init {
        require(direction == "request" || direction == "response") { "http direction" }
        require(methodOrStatus.isNotBlank() && methodOrStatus.length <= 64) { "http method/status" }
        require(host == null || host.length <= 320) { "http host bounded" }
        require(path == null || path.length <= 512) { "http path bounded" }
        require(payloadBytes in 0..PcapLimits.MAX_PACKET_CAPTURE_BYTES) { "http payload bytes" }
    }
}

data class PcapSummary(
    val analysisID: String,
    val createdAtEpochMillis: Long,
    val status: PcapAnalysisStatus,
    val format: PcapCaptureFormat,
    val sourceLabel: String?,
    val sourceBytes: Long,
    val parsedBytes: Long,
    val totalByteCount: Long,
    val sourceTruncated: Boolean,
    val detailed: Boolean,
    val startEpochMillis: Long?,
    val endEpochMillis: Long?,
    val parseMillis: Long,
    val budgetMillis: Long,
    val packetCount: Long,
    val capturedPacketCount: Long,
    val truncatedPacketCount: Long,
    val malformedPacketCount: Long,
    val unsupportedPacketCount: Long,
    val nonIpPacketCount: Long,
    val flowTableOverflow: Long,
    val totalFlowCount: Long,
    val protocols: List<PcapProtocolStats>,
    val ipVersions: Map<PcapIpVersion, Long>,
    val interfaces: List<PcapInterface>,
    val flows: List<PcapFlow>,
    val timeline: List<PcapTimelineBucket>,
    val dns: List<PcapDnsRecord>,
    val http: List<PcapHttpRecord>,
    val stoppedReason: String?,
    val cancelled: Boolean,
    val limitations: List<String>,
) {
    init {
        require(runCatching { UUID.fromString(analysisID) }.isSuccess) { "analysisID must be a UUID" }
        require(createdAtEpochMillis >= 0) { "createdAt" }
        require(sourceBytes >= 0 && parsedBytes >= 0 && totalByteCount >= 0) { "byte counts" }
        require(parseMillis >= 0 && budgetMillis >= 0) { "time counts" }
        require(flows.size <= PcapLimits.MAX_RETAINED_FLOWS) { "retained flows bound" }
        require(timeline.size <= PcapLimits.MAX_TIMELINE_BUCKETS) { "timeline bound" }
        require(dns.size <= PcapLimits.MAX_DNS_RECORDS) { "dns bound" }
        require(http.size <= PcapLimits.MAX_HTTP_RECORDS) { "http bound" }
        require(interfaces.size <= PcapLimits.MAX_INTERFACES) { "interfaces bound" }
        require(limitations.size <= PcapLimits.MAX_LIMITATIONS) { "limitations bound" }
        require(sourceLabel == null || sourceLabel.length <= PcapLimits.MAX_SOURCE_LABEL_CHARS)
    }
}

/** A filter projection over a stored, already aggregated analysis. */
data class PcapSummaryView(
    val summary: PcapSummary,
    val filters: PcapFilters,
    val matchedFlows: List<PcapFlow>,
    val matchedPackets: Long,
    val matchedBytes: Long,
    val matchedDns: List<PcapDnsRecord>,
    val matchedHttp: List<PcapHttpRecord>,
    val matchedTimeline: List<PcapTimelineBucket>,
) {
    init {
        require(matchedFlows.size <= PcapLimits.MAX_RETAINED_FLOWS)
        require(matchedDns.size <= PcapLimits.MAX_DNS_RECORDS)
        require(matchedHttp.size <= PcapLimits.MAX_HTTP_RECORDS)
        require(matchedTimeline.size <= PcapLimits.MAX_TIMELINE_BUCKETS)
    }

    companion object {
        fun of(summary: PcapSummary, filters: PcapFilters): PcapSummaryView {
            if (filters.isEmpty) {
                return PcapSummaryView(
                    summary = summary,
                    filters = filters,
                    matchedFlows = summary.flows,
                    matchedPackets = summary.packetCount,
                    matchedBytes = summary.totalByteCount,
                    matchedDns = summary.dns,
                    matchedHttp = summary.http,
                    matchedTimeline = summary.timeline,
                )
            }
            val flows = summary.flows.filter(filters::matchesFlow)
            val dns = if (filters.services.isEmpty() || PcapServiceFilter.DNS in filters.services) {
                summary.dns.filter { record ->
                    filters.matchesExtraction(
                        if (record.overTcp) PcapProtocol.TCP else PcapProtocol.UDP,
                        record.source, record.destination, record.timestampEpochMillis,
                    )
                }
            } else {
                emptyList()
            }
            val http = if (filters.services.isEmpty() || PcapServiceFilter.HTTP in filters.services) {
                summary.http.filter { record ->
                    filters.matchesExtraction(
                        PcapProtocol.TCP, record.source, record.destination,
                        record.timestampEpochMillis,
                    )
                }
            } else {
                emptyList()
            }
            val timeline = summary.timeline.filter { bucket ->
                val end = bucket.startEpochMillis + bucket.bucketMillis - 1
                (filters.startEpochMillis == null || end >= filters.startEpochMillis) &&
                    (filters.endEpochMillis == null || bucket.startEpochMillis <= filters.endEpochMillis)
            }
            return PcapSummaryView(
                summary = summary,
                filters = filters,
                matchedFlows = flows,
                matchedPackets = flows.sumOf { it.packetCount },
                matchedBytes = flows.sumOf { it.byteCount },
                matchedDns = dns,
                matchedHttp = http,
                matchedTimeline = timeline,
            )
        }
    }
}

/** Cancellation is polled by the streaming reader; no coroutine dependency. */
fun interface PcapCancellation {
    fun isCancelled(): Boolean

    companion object {
        val NONE = PcapCancellation { false }
    }
}

interface PcapSource {
    val sizeBytes: Long
    val label: String?
    fun openStream(): java.io.InputStream
}

data class PcapAnalysisOptions(
    val analysisID: String,
    val sourceLabel: String? = null,
    val detailed: Boolean = false,
    val timeBudgetMillis: Long = PcapLimits.MAX_PARSE_BUDGET_MILLIS,
    val maxPackets: Long = PcapLimits.MAX_PACKETS,
    val maxFlowKeys: Int = PcapLimits.MAX_FLOW_KEYS,
    val maxRetainedFlows: Int = PcapLimits.MAX_RETAINED_FLOWS,
    val maxTimelineBuckets: Int = PcapLimits.MAX_TIMELINE_BUCKETS,
    val maxDnsRecords: Int = PcapLimits.MAX_DNS_RECORDS,
    val maxHttpRecords: Int = PcapLimits.MAX_HTTP_RECORDS,
    val createdAtEpochMillis: Long = System.currentTimeMillis(),
    val cancellation: PcapCancellation = PcapCancellation.NONE,
) {
    init {
        require(runCatching { UUID.fromString(analysisID) }.isSuccess) { "analysisID must be a UUID" }
        require(sourceLabel == null || sourceLabel.length <= PcapLimits.MAX_SOURCE_LABEL_CHARS)
        require(timeBudgetMillis in 0..PcapLimits.MAX_PARSE_BUDGET_MILLIS)
        require(maxPackets in 1..PcapLimits.MAX_PACKETS)
        require(maxFlowKeys in 1..PcapLimits.MAX_FLOW_KEYS)
        require(maxRetainedFlows in 1..PcapLimits.MAX_RETAINED_FLOWS)
        require(maxTimelineBuckets in 1..PcapLimits.MAX_TIMELINE_BUCKETS)
        require(maxDnsRecords in 0..PcapLimits.MAX_DNS_RECORDS)
        require(maxHttpRecords in 0..PcapLimits.MAX_HTTP_RECORDS)
        require(createdAtEpochMillis >= 0)
    }
}

/** Pure identifier helpers; IPv4/IPv6 tokens match across equivalent spellings. */
object PcapIdentifiers {
    private val ipv4 = Regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$")
    private val ipv6Chars = Regex("^[0-9A-Fa-f:.]+$")

    fun token(address: String): String {
        val bytes = canonicalAddressBytes(address) ?: address.trim().lowercase(Locale.ROOT)
            .toByteArray(Charsets.UTF_8)
        return MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }.take(32)
    }

    internal fun canonicalAddressBytes(address: String): ByteArray? {
        val trimmed = address.trim()
        if (trimmed.isEmpty() || trimmed.length > PcapLimits.MAX_ADDRESS_CHARS) return null
        val isV6 = trimmed.contains(':')
        if (isV6 && !ipv6Chars.matches(trimmed)) return null
        if (!isV6 && !ipv4.matches(trimmed)) return null
        if (!isV6 && trimmed.split('.').any { (it.toIntOrNull() ?: 256) !in 0..255 }) return null
        return runCatching { java.net.InetAddress.getByName(trimmed).address }.getOrNull()
            ?.takeIf { if (isV6) it.size == 16 else it.size == 4 }
    }

    internal fun displayName(label: String?): String? {
        val value = label?.substringAfterLast('/')?.substringAfterLast('\\') ?: return null
        val cleaned = value.filter { it.code >= 0x20 && it.code != 0x7f }
            .trim().take(PcapLimits.MAX_SOURCE_LABEL_CHARS)
        return cleaned.ifBlank { null }
    }
}

/** The one place a literal network identifier becomes a display value. */
internal object PcapRedactor {
    fun address(address: String, token: String, detailed: Boolean): String =
        if (detailed) address.take(PcapLimits.MAX_ADDRESS_CHARS - 1) else "ip:" + token.take(12)

    fun host(name: String, detailed: Boolean): String =
        if (detailed) name.trim().lowercase(Locale.ROOT).take(320)
        else "host:" + PcapIdentifiers.token(name).take(12)

    fun path(path: String, detailed: Boolean): String {
        val withoutQuery = path.substringBefore('?').substringBefore('#').take(512)
        return if (detailed) withoutQuery else "/" + PcapIdentifiers.token(withoutQuery).take(12)
    }

    fun label(label: String): String =
        label.filter { it.code >= 0x20 && it.code != 0x7f }.trim().take(300)

    fun limitation(message: String): String =
        label(message).replace(Regex("(?i)(https?://|www\\.)\\S+"), "[redacted]")
}
