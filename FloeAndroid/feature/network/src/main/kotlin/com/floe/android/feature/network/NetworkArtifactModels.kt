// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.network

import java.time.Instant
import java.time.format.DateTimeFormatter

/** A picked SAF capture; the App host copies and analyses it, never this UI. */
data class PcapImportUi(
    val uri: String,
    val displayName: String?,
    val mimeType: String?,
    val declaredBytes: Long?,
    val detailed: Boolean,
)

data class FloorplanImportUi(
    val uri: String,
    val displayName: String?,
    val mimeType: String?,
)

enum class PcapExportFormatUi(val extension: String, val mimeType: String) {
    JSON("json", "application/json"),
    MARKDOWN("md", "text/markdown"),
    CSV("csv", "text/csv"),
}

enum class CoverageExportFormatUi(val extension: String, val mimeType: String) {
    JSON("json", "application/json"),
    MARKDOWN("md", "text/markdown"),
}

data class PcapFilterValues(
    val protocols: Set<String> = emptySet(),
    val services: Set<String> = emptySet(),
    val address: String = "",
    val port: String = "",
    val startSeconds: String = "",
    val endSeconds: String = "",
)

data class PcapFilterQuery(
    val protocols: Set<String>,
    val services: Set<String>,
    val address: String?,
    val port: Int?,
    val startEpochMillis: Long?,
    val endEpochMillis: Long?,
)

data class PcapFilterResult(
    val query: PcapFilterQuery?,
    val errors: Set<String> = emptySet(),
)

object PcapFilterForm {
    val PROTOCOLS = listOf("tcp", "udp", "icmp", "icmpv6")
    val SERVICES = listOf("dns", "http")

    fun parse(values: PcapFilterValues): PcapFilterResult {
        val errors = mutableSetOf<String>()
        val address = values.address.trim()
        if (address.isNotEmpty() &&
            (address.length > 64 || address.any { it.isWhitespace() || it in "/@?#" })
        ) {
            errors += "address"
        }
        val port = values.port.trim().let { text ->
            if (text.isEmpty()) null else text.toIntOrNull()?.takeIf { it in 1..65_535 }
                ?: run { errors += "port"; null }
        }
        val start = values.startSeconds.trim().let { text ->
            if (text.isEmpty()) null else text.toLongOrNull()?.takeIf { it >= 0L }
                ?: run { errors += "time"; null }
        }
        val end = values.endSeconds.trim().let { text ->
            if (text.isEmpty()) null else text.toLongOrNull()?.takeIf { it >= 0L }
                ?: run { errors += "time"; null }
        }
        if (start != null && end != null && start > end) errors += "time"
        if (errors.isNotEmpty()) return PcapFilterResult(null, errors)
        return PcapFilterResult(
            PcapFilterQuery(
                protocols = values.protocols.filter { it in PROTOCOLS }.toSet(),
                services = values.services.filter { it in SERVICES }.toSet(),
                address = address.ifEmpty { null },
                port = port,
                startEpochMillis = start?.let { it * 1_000L },
                endEpochMillis = end?.let { it * 1_000L },
            ),
        )
    }

    /** Form values for an existing query, used when reopening a filtered view. */
    fun values(query: PcapFilterQuery): PcapFilterValues = PcapFilterValues(
        protocols = query.protocols,
        services = query.services,
        address = query.address.orEmpty(),
        port = query.port?.toString().orEmpty(),
        startSeconds = query.startEpochMillis?.let { (it / 1_000L).toString() }.orEmpty(),
        endSeconds = query.endEpochMillis?.let { (it / 1_000L).toString() }.orEmpty(),
    )
}

data class CoverageProbeRequestUi(
    val kind: String = "none",
    val host: String = "",
    val port: String = "",
    val endpointUrl: String = "",
    val allowMetered: Boolean = false,
)

data class CoverageSampleRequest(
    val label: String?,
    val x: Double,
    val y: Double,
    val probe: CoverageProbeRequestUi?,
)

data class CoverageSampleValidation(
    val request: CoverageSampleRequest?,
    val errors: Set<String> = emptySet(),
)

object CoverageForm {
    val PROBE_KINDS = listOf("none", "ping", "tcp", "speedDownload")
    private val hostPattern = Regex("^[A-Za-z0-9._:-]{1,253}$")
    private val httpsPattern = Regex("^https://[^\\s/@?#]+(?:[/:?#][^\\s]*)?$", RegexOption.IGNORE_CASE)

    fun parse(
        label: String,
        x: Double,
        y: Double,
        probeEnabled: Boolean,
        probe: CoverageProbeRequestUi,
    ): CoverageSampleValidation {
        val errors = mutableSetOf<String>()
        val normalizedLabel = label.trim().takeIf { it.isNotEmpty() }
        if (normalizedLabel != null && normalizedLabel.length > 96) errors += "label"
        val selected = if (!probeEnabled || probe.kind == "none") null else probe
        if (selected != null) {
            when (selected.kind) {
                "ping" -> if (!hostPattern.matches(selected.host.trim())) errors += "probeHost"
                "tcp" -> {
                    if (!hostPattern.matches(selected.host.trim())) errors += "probeHost"
                    if (selected.port.trim().toIntOrNull() !in 1..65_535) errors += "probePort"
                }
                "speedDownload" -> if (!httpsPattern.matches(selected.endpointUrl.trim())) {
                    errors += "probeUrl"
                }
                else -> errors += "probeKind"
            }
        }
        if (errors.isNotEmpty()) return CoverageSampleValidation(null, errors)
        return CoverageSampleValidation(
            CoverageSampleRequest(
                label = normalizedLabel,
                x = x.coerceIn(0.0, 1.0),
                y = y.coerceIn(0.0, 1.0),
                probe = selected?.copy(
                    host = selected.host.trim(),
                    port = selected.port.trim(),
                    endpointUrl = selected.endpointUrl.trim(),
                ),
            ),
        )
    }
}

/* ------------------------------- UI state -------------------------------- */

enum class NetworkArtifactFailure {
    SOURCE_TOO_LARGE,
    SOURCE_UNAVAILABLE,
    UNSUPPORTED_FORMAT,
    READ_FAILED,
    STORE_FAILED,
    NOT_FOUND,
    EXPORT_FAILED,
    CANCELLED,
    PERMISSION_REQUIRED,
    SCAN_FAILED,
    FLOORPLAN_TOO_LARGE,
    FLOORPLAN_INVALID,
    SESSION_LIMIT,
    CAPTURE_LIMIT,
    POINT_LIMIT,
    INVALID_INPUT,
}

data class PcapAnalysisItemUi(
    val analysisID: String,
    val createdAtEpochMillis: Long,
    val status: String,
    val format: String,
    val sourceLabel: String?,
    val detailed: Boolean,
    val packetCount: Long,
    val flowCount: Long,
    val sourceBytes: Long,
    val parseMillis: Long,
    val agentReadable: Boolean = false,
)

data class PcapProtocolRowUi(val protocol: String, val packets: Long, val bytes: Long)

data class PcapFlowRowUi(
    val firstEpochMillis: Long,
    val lastEpochMillis: Long,
    val protocol: String,
    val ipVersion: Int,
    val source: String,
    val sourcePort: Int?,
    val destination: String,
    val destinationPort: Int?,
    val packets: Long,
    val bytes: Long,
    val tcpFlags: String?,
)

data class PcapDnsRowUi(
    val timestampEpochMillis: Long,
    val direction: String,
    val name: String,
    val recordType: String,
    val responseCode: Int?,
)

data class PcapHttpRowUi(
    val timestampEpochMillis: Long,
    val direction: String,
    val methodOrStatus: String,
    val host: String?,
    val path: String?,
    val payloadBytes: Int,
)

data class PcapTimelineRowUi(
    val startEpochMillis: Long,
    val bucketMillis: Long,
    val packets: Long,
    val bytes: Long,
)

data class PcapAnalysisUi(
    val item: PcapAnalysisItemUi,
    val startEpochMillis: Long?,
    val endEpochMillis: Long?,
    val totalBytes: Long,
    val matchedFlows: Long,
    val matchedPackets: Long,
    val matchedBytes: Long,
    val filters: PcapFilterQuery,
    val protocols: List<PcapProtocolRowUi>,
    val flows: List<PcapFlowRowUi>,
    val timeline: List<PcapTimelineRowUi>,
    val dns: List<PcapDnsRowUi>,
    val http: List<PcapHttpRowUi>,
    val limitations: List<String>,
    val stoppedReason: String?,
    val cancelled: Boolean,
)

data class PcapArtifactState(
    val analyses: List<PcapAnalysisItemUi> = emptyList(),
    val selectedID: String? = null,
    val selected: PcapAnalysisUi? = null,
    val importing: Boolean = false,
    val importedBytes: Long = 0L,
    val busy: Boolean = false,
    val failure: NetworkArtifactFailure? = null,
    val exportedBytes: Long? = null,
)

data class CoverageAccessPointUi(
    val ssid: String?,
    val bssid: String?,
    val rssiDbm: Int,
    val channel: Int?,
    val band: String?,
    val ageMs: Long?,
)

data class CoverageProbeUi(
    val kind: String,
    val status: String,
    val latencyMs: Double?,
    val bitsPerSecond: Double?,
    val payloadBytes: Long?,
    val errorCode: String?,
)

data class CoveragePointUi(
    val pointID: String,
    val label: String?,
    val x: Double,
    val y: Double,
    val capturedAtEpochMillis: Long,
    val rssiDbm: Int?,
    val level: String,
    val ageMs: Long,
    val stale: Boolean,
    val scanStatus: String,
    val refreshStatus: String,
    val cachedAgeMs: Long?,
    val permissionRequired: Boolean,
    val channel: Int?,
    val band: String?,
    val accessPoints: List<CoverageAccessPointUi>,
    val probe: CoverageProbeUi?,
)

data class CoverageLegendUi(val level: String, val minimumDbm: Int, val maximumDbm: Int, val points: Int)

data class CoverageGridCellUi(
    val column: Int,
    val row: Int,
    val samples: Int,
    val averageRssiDbm: Double?,
    val bestRssiDbm: Int?,
)

data class CoverageAggregateUi(
    val pointCount: Int,
    val staleCount: Int,
    val permissionRequiredCount: Int,
    val cachedScanCount: Int,
    val noSignalCount: Int,
    val rssiMin: Int?,
    val rssiMax: Int?,
    val rssiAverage: Double?,
    val estimatedCoveragePercent: Double?,
    val unsampledCells: Int,
    val bandCounts: Map<String, Int>,
    val channelCounts: Map<Int, Int>,
    val legend: List<CoverageLegendUi>,
    val grid: List<CoverageGridCellUi>,
)

data class CoverageSessionItemUi(
    val sessionID: String,
    val name: String,
    val updatedAtEpochMillis: Long,
    val pointCount: Int,
    val namedLocations: List<String>,
    val hasFloorplan: Boolean,
    val agentReadable: Boolean = false,
)

data class CoverageFloorplanUi(
    val width: Int,
    val height: Int,
    val mimeType: String,
    val byteCount: Long,
    /** App-private bytes, only for the selected session; never exported. */
    val image: ByteArray?,
)

data class CoverageSessionUi(
    val item: CoverageSessionItemUi,
    val aggregate: CoverageAggregateUi,
    val points: List<CoveragePointUi>,
    val floorplan: CoverageFloorplanUi?,
    val limitations: List<String>,
    val sampledAtEpochMillis: Long,
)

data class CoverageArtifactState(
    val sessions: List<CoverageSessionItemUi> = emptyList(),
    val selectedID: String? = null,
    val selected: CoverageSessionUi? = null,
    val sampling: Boolean = false,
    val busy: Boolean = false,
    val failure: NetworkArtifactFailure? = null,
    val missingPermissions: List<String> = emptyList(),
    val exportedBytes: Long? = null,
)

data class NetworkArtifactState(
    val pcap: PcapArtifactState = PcapArtifactState(),
    val coverage: CoverageArtifactState = CoverageArtifactState(),
)

/** Compact presentation helpers shared by the two artifact pages. */
object NetworkArtifactFormat {
    private val time = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
    fun timestamp(epochMillis: Long): String =
        runCatching { Instant.ofEpochMilli(epochMillis).atZone(java.time.ZoneId.systemDefault()).format(time) }
            .getOrDefault("—")

    fun rate(bitsPerSecond: Double?): String =
        bitsPerSecond?.let(NetworkMeasureFormat::bitsPerSecond).orEmpty()
}
