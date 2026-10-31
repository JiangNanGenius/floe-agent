// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.util.UUID

/**
 * G07.3B Wi-Fi coverage. Every point is a user-triggered measurement: the
 * App calls the existing `network.wifiScan` service (and optional ping/TCP/
 * speed tools only when the user explicitly enables them) and stores the
 * typed result. There is no background scanning, no GPS, no RTT ranging and
 * no synthetic RF value.
 */
object CoverageLimits {
    const val MAX_SESSIONS = 20
    const val MAX_POINTS_PER_SESSION = 250
    const val MAX_LOCATIONS = 64
    const val MAX_ACCESS_POINTS_PER_SCAN = 256
    const val MAX_REPORT_JSON_BYTES = 4 * 1024 * 1024
    const val MAX_REPORT_MARKDOWN_BYTES = 512 * 1024
    const val MAX_SESSION_JSON_BYTES = 4 * 1024 * 1024
    const val MAX_TOOL_REPLY_BYTES = 32 * 1024
    const val MAX_FLOORPLAN_BYTES = 8 * 1024 * 1024
    const val MAX_FLOORPLAN_DIMENSION = 8192
    const val MAX_NAME_CHARS = 128
    const val MAX_LABEL_CHARS = 96
    const val MIN_POINT_COORDINATE = 0.0
    const val MAX_POINT_COORDINATE = 1.0
    const val STALE_AFTER_MILLIS = 10 * 60 * 1_000L
    const val GRID_COLUMNS = 8
    const val GRID_ROWS = 6
    const val STRONG_RSSI = -60
    const val GOOD_RSSI = -70
    const val FAIR_RSSI = -80
}

enum class CoverageScanStatus(val wire: String) {
    OK("ok"),
    PARTIAL("partial"),
    PERMISSION_REQUIRED("permissionRequired"),
    UNAVAILABLE("unavailable"),
    UNSUPPORTED("unsupported"),
    ERROR("error"),
    ;

    companion object {
        fun fromWire(value: String): CoverageScanStatus =
            entries.firstOrNull { it.wire == value } ?: ERROR
    }
}

enum class CoverageRefreshStatus(val wire: String) {
    UPDATED("updated"),
    NOT_UPDATED("notUpdated"),
    REFUSED("refused"),
    TIMEOUT("completionTimeout"),
    UNAVAILABLE("completionUnavailable"),
    UNKNOWN("unknown"),
}

data class CoverageAccessPoint(
    val ssid: String?,
    val bssid: String?,
    val rssiDbm: Int,
    val frequencyMhz: Int?,
    val channel: Int?,
    val band: String?,
    val widthMhz: Int?,
    val security: List<String>,
    val ageMs: Long?,
    val timestampMicros: Long?,
) {
    init {
        require(rssiDbm in -127..0) { "rssi must be a real dBm value" }
        require(ssid == null || ssid.length <= 128) { "ssid bounded" }
        require(bssid == null || bssid.length <= 64) { "bssid bounded" }
    }
}

data class CoverageScanSnapshot(
    val capturedAtEpochMillis: Long,
    val status: CoverageScanStatus,
    val wifiEnabled: Boolean?,
    val locationServicesEnabled: Boolean?,
    val cachedAgeMs: Long?,
    val freshness: String?,
    val refreshRequested: Boolean,
    val refreshStatus: CoverageRefreshStatus,
    val scanAccepted: Boolean?,
    val resultsUpdated: Boolean?,
    val truncated: Boolean,
    val accessPoints: List<CoverageAccessPoint>,
    val limitations: List<String>,
    val missingPermissions: List<String>,
) {
    init {
        require(capturedAtEpochMillis >= 0) { "capture time" }
        require(accessPoints.size <= CoverageLimits.MAX_ACCESS_POINTS_PER_SCAN) { "access point bound" }
    }

    val bestSignalDbm: Int? get() = accessPoints.maxOfOrNull { it.rssiDbm }
    val isUsable: Boolean get() = accessPoints.isNotEmpty()
}

data class CoverageProbeResult(
    val kind: String,
    val status: String,
    val targetHost: String? = null,
    val latencyMs: Double? = null,
    val bitsPerSecond: Double? = null,
    val payloadBytes: Long? = null,
    val errorCode: String? = null,
    val measuredAtEpochMillis: Long = 0L,
    val limitations: List<String> = emptyList(),
) {
    init {
        require(kind in setOf("ping", "tcpProbe", "speedDownload", "speedUpload")) { "probe kind" }
        require(status in setOf("ok", "partial", "permissionRequired", "unavailable",
            "unsupported", "cancelled", "timeout", "error")) { "probe status" }
        require(targetHost == null || targetHost.length <= 253) { "probe target bounded" }
    }
}

data class CoveragePoint(
    val pointID: String,
    val label: String?,
    val x: Double,
    val y: Double,
    val createdAtEpochMillis: Long,
    val scan: CoverageScanSnapshot,
    val probe: CoverageProbeResult? = null,
) {
    init {
        require(runCatching { UUID.fromString(pointID) }.isSuccess) { "pointID must be a UUID" }
        require(label == null || (label.isNotBlank() && label.length <= CoverageLimits.MAX_LABEL_CHARS)) {
            "point label bounded"
        }
        require(x in CoverageLimits.MIN_POINT_COORDINATE..CoverageLimits.MAX_POINT_COORDINATE) {
            "x must be normalized to 0..1"
        }
        require(y in CoverageLimits.MIN_POINT_COORDINATE..CoverageLimits.MAX_POINT_COORDINATE) {
            "y must be normalized to 0..1"
        }
        require(createdAtEpochMillis >= 0) { "created time" }
    }

    val rssiDbm: Int? get() = scan.bestSignalDbm
    val signalLevel: String get() = CoverageMetrics.levelFor(rssiDbm)

    fun ageMillis(nowEpochMillis: Long): Long =
        (nowEpochMillis - scan.capturedAtEpochMillis).coerceAtLeast(0L)

    fun isStale(nowEpochMillis: Long): Boolean =
        ageMillis(nowEpochMillis) > CoverageLimits.STALE_AFTER_MILLIS
}

data class CoverageFloorplan(
    val width: Int,
    val height: Int,
    val mimeType: String,
    val byteCount: Long,
    val sha256: String,
    val importedAtEpochMillis: Long,
) {
    init {
        require(width in 1..CoverageLimits.MAX_FLOORPLAN_DIMENSION) { "floorplan width" }
        require(height in 1..CoverageLimits.MAX_FLOORPLAN_DIMENSION) { "floorplan height" }
        require(mimeType in setOf("image/png", "image/jpeg", "image/webp")) { "floorplan MIME" }
        require(byteCount in 1..CoverageLimits.MAX_FLOORPLAN_BYTES.toLong()) { "floorplan bytes" }
        require(sha256.matches(Regex("[0-9a-f]{64}"))) { "floorplan digest" }
        require(importedAtEpochMillis >= 0) { "floorplan import time" }
    }

    /** Width / height, for an aspect-ratio-preserving Compose canvas. */
    val aspectRatio: Float get() = width.toFloat() / height.toFloat()
}

data class CoverageSession(
    val sessionID: String,
    val name: String,
    val createdAtEpochMillis: Long,
    val updatedAtEpochMillis: Long,
    val ownerTaskId: String?,
    val floorplan: CoverageFloorplan?,
    val points: List<CoveragePoint>,
    val ownerWorkspaceId: String? = null,
    /** Explicit user grant: Agent tools may read this session (never a file grant). */
    val agentReadable: Boolean = false,
) {
    init {
        require(runCatching { UUID.fromString(sessionID) }.isSuccess) { "sessionID must be a UUID" }
        require(name.isNotBlank() && name.length <= CoverageLimits.MAX_NAME_CHARS) { "session name" }
        require(createdAtEpochMillis >= 0 && updatedAtEpochMillis >= createdAtEpochMillis) {
            "session time order"
        }
        require(ownerTaskId == null || (ownerTaskId.isNotBlank() && ownerTaskId.length <= 64)) {
            "owner task bounded"
        }
        require(ownerWorkspaceId == null ||
            (ownerWorkspaceId.isNotBlank() && ownerWorkspaceId.length <= 128)) {
            "owner workspace bounded"
        }
        require(points.size <= CoverageLimits.MAX_POINTS_PER_SESSION) { "point bound" }
        require(points.map { it.pointID }.distinct().size == points.size) { "point ids unique" }
        require(points.mapNotNull { it.label }.distinct().size <= CoverageLimits.MAX_LOCATIONS) {
            "location bound"
        }
    }

    val namedLocations: List<String> get() = points.mapNotNull { it.label }.distinct()
}

/** Estimated legend; never presented as a calibrated RF propagation model. */
data class CoverageLegendBucket(
    val level: String,
    val minimumDbm: Int,
    val maximumDbm: Int,
    val pointCount: Int,
)

data class CoverageGridCell(
    val column: Int,
    val row: Int,
    val sampleCount: Int,
    val averageRssiDbm: Double?,
    val bestRssiDbm: Int?,
)

data class CoverageAggregate(
    val pointCount: Int,
    val staleCount: Int,
    val permissionRequiredCount: Int,
    val cachedScanCount: Int,
    val noSignalCount: Int,
    val bandCounts: Map<String, Int>,
    val channelCounts: Map<Int, Int>,
    val rssiMin: Int?,
    val rssiMax: Int?,
    val rssiAverage: Double?,
    val legend: List<CoverageLegendBucket>,
    val grid: List<CoverageGridCell>,
    val unsampledCells: Int,
    val estimatedCoveragePercent: Double?,
)

object CoverageMetrics {
    fun levelFor(rssiDbm: Int?): String = when {
        rssiDbm == null -> "unsampled"
        rssiDbm >= CoverageLimits.STRONG_RSSI -> "strong"
        rssiDbm >= CoverageLimits.GOOD_RSSI -> "good"
        rssiDbm >= CoverageLimits.FAIR_RSSI -> "fair"
        else -> "weak"
    }

    fun stale(scan: CoverageScanSnapshot, nowEpochMillis: Long): Boolean =
        nowEpochMillis - scan.capturedAtEpochMillis > CoverageLimits.STALE_AFTER_MILLIS

    fun aggregate(session: CoverageSession, nowEpochMillis: Long): CoverageAggregate {
        val rssi = session.points.mapNotNull { it.rssiDbm }
        val bandCounts = linkedMapOf<String, Int>()
        val channelCounts = linkedMapOf<Int, Int>()
        session.points.forEach { point ->
            point.scan.accessPoints.forEach { accessPoint ->
                accessPoint.band?.let { bandCounts[it] = (bandCounts[it] ?: 0) + 1 }
                accessPoint.channel?.let { channelCounts[it] = (channelCounts[it] ?: 0) + 1 }
            }
        }
        val legend = listOf(
            CoverageLegendBucket("strong", CoverageLimits.STRONG_RSSI, 0, 0),
            CoverageLegendBucket("good", CoverageLimits.GOOD_RSSI, CoverageLimits.STRONG_RSSI - 1, 0),
            CoverageLegendBucket("fair", CoverageLimits.FAIR_RSSI, CoverageLimits.GOOD_RSSI - 1, 0),
            CoverageLegendBucket("weak", -127, CoverageLimits.FAIR_RSSI - 1, 0),
        ).map { bucket ->
            bucket.copy(pointCount = rssi.count { it in bucket.minimumDbm..bucket.maximumDbm })
        }
        val grid = grid(session)
        val sampled = grid.count { it.sampleCount > 0 }
        return CoverageAggregate(
            pointCount = session.points.size,
            staleCount = session.points.count { stale(it.scan, nowEpochMillis) },
            permissionRequiredCount = session.points.count {
                it.scan.status == CoverageScanStatus.PERMISSION_REQUIRED
            },
            cachedScanCount = session.points.count { (it.scan.cachedAgeMs ?: 0L) > 0L },
            noSignalCount = session.points.count { it.rssiDbm == null },
            bandCounts = bandCounts,
            channelCounts = channelCounts,
            rssiMin = rssi.minOrNull(),
            rssiMax = rssi.maxOrNull(),
            rssiAverage = rssi.takeIf { it.isNotEmpty() }?.average(),
            legend = legend,
            grid = grid,
            unsampledCells = grid.size - sampled,
            estimatedCoveragePercent = if (grid.isEmpty()) null
            else sampled.toDouble() * 100.0 / grid.size,
        )
    }

    fun grid(
        session: CoverageSession,
        columns: Int = CoverageLimits.GRID_COLUMNS,
        rows: Int = CoverageLimits.GRID_ROWS,
    ): List<CoverageGridCell> {
        require(columns in 1..32 && rows in 1..32) { "grid bounds" }
        val values = Array(columns * rows) { mutableListOf<Int>() }
        session.points.forEach { point ->
            val column = (point.x * columns).toInt().coerceIn(0, columns - 1)
            val row = (point.y * rows).toInt().coerceIn(0, rows - 1)
            point.rssiDbm?.let { values[row * columns + column] += it }
        }
        return (0 until rows).flatMap { row ->
            (0 until columns).map { column ->
                val samples = values[row * columns + column]
                CoverageGridCell(
                    column = column,
                    row = row,
                    sampleCount = samples.size,
                    averageRssiDbm = samples.takeIf { it.isNotEmpty() }?.average(),
                    bestRssiDbm = samples.maxOrNull(),
                )
            }
        }
    }

    fun normalizeCoordinate(value: Double): Double =
        value.coerceIn(CoverageLimits.MIN_POINT_COORDINATE, CoverageLimits.MAX_POINT_COORDINATE)
}
