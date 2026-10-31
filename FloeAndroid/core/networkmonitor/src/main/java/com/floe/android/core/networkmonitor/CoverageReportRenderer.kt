// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/**
 * Coverage exports are redacted by default (SSID/BSSID/host/address fields);
 * a detailed export is an explicit user choice. The Agent tool projection is
 * ALWAYS redacted and page-shaped to fit the shared 64 KiB bridge frame.
 */
object CoverageReportRenderer {
    const val MAX_TOOL_REPLY_BYTES = 32 * 1024

    fun renderJson(session: CoverageSession, detailed: Boolean, nowEpochMillis: Long): String {
        val aggregate = CoverageMetrics.aggregate(session, nowEpochMillis)
        val root = JSONObject()
            .put("schema", "floe.network-coverage-report.v1")
            .put("privacy", JSONObject()
                .put("mode", if (detailed) "detailed" else "redacted")
                .put("disclosure", if (detailed) {
                    "Explicitly requested on-device identifiers; credentials are never included."
                } else {
                    "SSIDs, BSSIDs, probe hosts and addresses are redacted."
                }))
            .put("session", JSONObject()
                .put("sessionID", session.sessionID)
                .put("name", session.name)
                .put("createdAt", Instant.ofEpochMilli(session.createdAtEpochMillis).toString())
                .put("updatedAt", Instant.ofEpochMilli(session.updatedAtEpochMillis).toString())
                .put("pointCount", session.points.size)
                .put("namedLocations", JSONArray().apply {
                    session.namedLocations.forEach { put(NetworkMonitorRedactor.value("location", it, detailed)) }
                })
                .put("hasFloorplan", session.floorplan != null)
                .put("floorplan", session.floorplan?.let {
                    JSONObject()
                        .put("width", it.width)
                        .put("height", it.height)
                        .put("mimeType", it.mimeType)
                        .put("byteCount", it.byteCount)
                        .put("sha256", if (detailed) it.sha256 else JSONObject.NULL)
                        .put("importedAt", Instant.ofEpochMilli(it.importedAtEpochMillis).toString())
                } ?: JSONObject.NULL))
            .put("aggregate", aggregate(aggregate))
            .put("points", JSONArray().apply {
                session.points.forEach { put(point(it, detailed, nowEpochMillis)) }
            })
            .put("limitations", limitations(session, aggregate))
        val text = root.toString(2)
        require(text.toByteArray(Charsets.UTF_8).size <= CoverageLimits.MAX_REPORT_JSON_BYTES) {
            "coverage report exceeds its bounded size"
        }
        return text
    }

    fun renderMarkdown(session: CoverageSession, detailed: Boolean, nowEpochMillis: Long): String {
        val aggregate = CoverageMetrics.aggregate(session, nowEpochMillis)
        val text = buildString {
            appendLine("# Floe Wi-Fi coverage report")
            appendLine()
            appendLine(if (detailed) {
                "**Privacy:** Detailed export requested on this device. SSIDs, BSSIDs and probe hosts may appear; credentials are never included."
            } else {
                "**Privacy:** Redacted export. SSIDs, BSSIDs, probe hosts and addresses are removed."
            })
            appendLine()
            appendLine("- Session: `${session.sessionID}`")
            appendLine("- Name: ${session.name}")
            appendLine("- Points: ${session.points.size}; locations: ${session.namedLocations.size}")
            appendLine("- Floorplan: " + (session.floorplan?.let {
                "${it.width}×${it.height} ${it.mimeType}"
            } ?: "none (grid view)"))
            appendLine("- RSSI: min ${aggregate.rssiMin ?: "—"} dBm / avg " +
                (aggregate.rssiAverage?.let { String.format(java.util.Locale.ROOT, "%.1f", it) } ?: "—") +
                " / max ${aggregate.rssiMax ?: "—"} dBm")
            appendLine("- Estimated sampled grid cells: " +
                (aggregate.estimatedCoveragePercent?.let {
                    String.format(java.util.Locale.ROOT, "%.0f%%", it)
                } ?: "—") + "; unsampled cells: ${aggregate.unsampledCells}")
            appendLine("- Stale points (>10 min): ${aggregate.staleCount}; cached scans: ${aggregate.cachedScanCount}; " +
                "permission-required: ${aggregate.permissionRequiredCount}")
            appendLine()
            appendLine(legendMarkdown(aggregate))
            appendLine()
            appendLine("| # | Location | x | y | RSSI dBm | Level | Channel | Age | Scan status |")
            appendLine("|---:|---|---:|---:|---:|---|---:|---|---|")
            session.points.forEachIndexed { index, point ->
                appendLine("| ${index + 1} | ${(point.label ?: "").markdownCell()} | " +
                    "${format(point.x)} | ${format(point.y)} | ${point.rssiDbm ?: "—"} | " +
                    "${point.signalLevel} | ${strongestChannel(point) ?: "—"} | " +
                    "${point.ageMillis(nowEpochMillis)} ms | ${point.scan.status.wire} |")
            }
            appendLine()
            appendLine("## Limitations")
            appendLine()
            limitations(session, aggregate).forEach { appendLine("- ${it.markdownCell()}") }
        }
        require(text.toByteArray(Charsets.UTF_8).size <= CoverageLimits.MAX_REPORT_MARKDOWN_BYTES) {
            "coverage markdown exceeds its bounded size"
        }
        return text
    }

    /**
     * Exported ranges come from the same legend buckets as the classifier and
     * JSON legend; the literal version previously drifted by one decibel.
     */
    private fun legendMarkdown(aggregate: CoverageAggregate): String {
        val byLevel = aggregate.legend.associateBy { it.level }
        val strong = byLevel["strong"]?.minimumDbm ?: CoverageLimits.STRONG_RSSI
        val goodMinimum = byLevel["good"]?.minimumDbm ?: CoverageLimits.GOOD_RSSI
        val goodMaximum = byLevel["good"]?.maximumDbm ?: (CoverageLimits.STRONG_RSSI - 1)
        val fairMinimum = byLevel["fair"]?.minimumDbm ?: CoverageLimits.FAIR_RSSI
        val fairMaximum = byLevel["fair"]?.maximumDbm ?: (CoverageLimits.GOOD_RSSI - 1)
        val weakMaximum = byLevel["weak"]?.maximumDbm ?: (CoverageLimits.FAIR_RSSI - 1)
        return "**Estimated legend (not a calibrated RF model):** strong ≥ $strong dBm, " +
            "good $goodMinimum..$goodMaximum, fair $fairMinimum..$fairMaximum, " +
            "weak ≤ $weakMaximum dBm."
    }

    /** Shared UI/tool limitation text; no network identifiers. */
    fun limitations(session: CoverageSession, nowEpochMillis: Long): List<String> =
        limitations(session, CoverageMetrics.aggregate(session, nowEpochMillis))

    fun renderToolSummary(session: CoverageSession, nowEpochMillis: Long): String {
        val aggregate = CoverageMetrics.aggregate(session, nowEpochMillis)
        var pointRows = minOf(session.points.size, 60)
        var gridRows = minOf(aggregate.grid.size, 48)
        while (true) {
            val root = JSONObject()
                .put("version", 1)
                .put("source", "phone")
                .put("schema", "floe.coverage-tool-summary.v1")
                .put("sessionID", session.sessionID)
                .put("status", "ok")
                .put("name", session.name)
                .put("privacy", "redacted")
                .put("pointCount", session.points.size)
                .put("namedLocations", JSONArray().apply {
                    session.namedLocations.forEach {
                        put(NetworkMonitorRedactor.value("location", it, false).take(96))
                    }
                })
                .put("hasFloorplan", session.floorplan != null)
                .put("aggregate", aggregate(aggregate))
                .put("points", JSONArray().apply {
                    session.points.take(pointRows).forEach { point ->
                        put(JSONObject()
                            .put("label", point.label?.let {
                                NetworkMonitorRedactor.value("location", it, false)
                            } ?: JSONObject.NULL)
                            .put("x", round(point.x))
                            .put("y", round(point.y))
                            .put("rssiDbm", point.rssiDbm ?: JSONObject.NULL)
                            .put("level", point.signalLevel)
                            .put("channel", strongestChannel(point) ?: JSONObject.NULL)
                            .put("ageMs", point.ageMillis(nowEpochMillis))
                            .put("stale", point.isStale(nowEpochMillis))
                            .put("scanStatus", point.scan.status.wire)
                            .put("cachedAgeMs", point.scan.cachedAgeMs ?: JSONObject.NULL)
                            .put("refreshStatus", point.scan.refreshStatus.wire)
                            .put("permissionRequired",
                                point.scan.status == CoverageScanStatus.PERMISSION_REQUIRED)
                            .put("probe", point.probe?.let {
                                JSONObject().put("kind", it.kind).put("status", it.status)
                                    .put("latencyMs", it.latencyMs ?: JSONObject.NULL)
                                    .put("bitsPerSecond", it.bitsPerSecond ?: JSONObject.NULL)
                            } ?: JSONObject.NULL))
                    }
                })
                .put("grid", JSONArray().apply {
                    aggregate.grid.take(gridRows).forEach {
                        put(JSONObject()
                            .put("column", it.column)
                            .put("row", it.row)
                            .put("samples", it.sampleCount)
                            .put("averageRssiDbm", it.averageRssiDbm ?: JSONObject.NULL)
                            .put("bestRssiDbm", it.bestRssiDbm ?: JSONObject.NULL))
                    }
                })
                .put("limitations", JSONArray().apply {
                    limitations(session, aggregate).forEach(::put)
                })
            val text = root.toString()
            if (text.toByteArray(Charsets.UTF_8).size <= MAX_TOOL_REPLY_BYTES) return text
            when {
                pointRows > 10 -> pointRows -= 10
                gridRows > 0 -> gridRows = 0
                pointRows > 0 -> pointRows = 0
                else -> throw IllegalStateException("coverage tool summary cannot fit its bounded reply")
            }
        }
    }

    fun unavailableReply(sessionID: String?, code: String): String = JSONObject()
        .put("version", 1)
        .put("source", "phone")
        .put("schema", "floe.coverage-tool-summary.v1")
        .put("sessionID", sessionID ?: JSONObject.NULL)
        .put("status", "unavailable")
        .put("errorCode", code)
        .put("privacy", "redacted")
        .put("limitations", JSONArray().put("The requested coverage session is not available."))
        .toString()

    private fun point(point: CoveragePoint, detailed: Boolean, now: Long): JSONObject = JSONObject()
        .put("pointID", point.pointID)
        .put("label", point.label?.let { NetworkMonitorRedactor.value("location", it, detailed) }
            ?: JSONObject.NULL)
        .put("x", point.x)
        .put("y", point.y)
        .put("rssiDbm", point.rssiDbm ?: JSONObject.NULL)
        .put("level", point.signalLevel)
        .put("ageMs", point.ageMillis(now))
        .put("stale", point.isStale(now))
        .put("scan", JSONObject()
            .put("status", point.scan.status.wire)
            .put("capturedAt", Instant.ofEpochMilli(point.scan.capturedAtEpochMillis).toString())
            .put("cachedAgeMs", point.scan.cachedAgeMs ?: JSONObject.NULL)
            .put("freshness", point.scan.freshness ?: JSONObject.NULL)
            .put("refreshRequested", point.scan.refreshRequested)
            .put("refreshStatus", point.scan.refreshStatus.wire)
            .put("scanAccepted", point.scan.scanAccepted ?: JSONObject.NULL)
            .put("truncated", point.scan.truncated)
            .put("wifiEnabled", point.scan.wifiEnabled ?: JSONObject.NULL)
            .put("locationServicesEnabled", point.scan.locationServicesEnabled ?: JSONObject.NULL)
            .put("accessPoints", JSONArray().apply {
                point.scan.accessPoints.forEach { accessPoint ->
                    put(JSONObject()
                        .put("ssid", accessPoint.ssid?.let {
                            NetworkMonitorRedactor.value("ssid", it, detailed)
                        } ?: JSONObject.NULL)
                        .put("bssid", accessPoint.bssid?.let {
                            NetworkMonitorRedactor.value("bssid", it, detailed)
                        } ?: JSONObject.NULL)
                        .put("rssiDbm", accessPoint.rssiDbm)
                        .put("channel", accessPoint.channel ?: JSONObject.NULL)
                        .put("band", accessPoint.band ?: JSONObject.NULL)
                        .put("ageMs", accessPoint.ageMs ?: JSONObject.NULL))
                }
            })
            .put("limitations", JSONArray().apply { point.scan.limitations.forEach(::put) })
            .put("missingPermissions", JSONArray().apply { point.scan.missingPermissions.forEach(::put) }))
        .put("probe", point.probe?.let { probe ->
            JSONObject()
                .put("kind", probe.kind)
                .put("status", probe.status)
                .put("targetHost", probe.targetHost?.let {
                    NetworkMonitorRedactor.value("target", it, detailed)
                } ?: JSONObject.NULL)
                .put("latencyMs", probe.latencyMs ?: JSONObject.NULL)
                .put("bitsPerSecond", probe.bitsPerSecond ?: JSONObject.NULL)
                .put("payloadBytes", probe.payloadBytes ?: JSONObject.NULL)
                .put("errorCode", probe.errorCode ?: JSONObject.NULL)
        } ?: JSONObject.NULL)

    private fun aggregate(aggregate: CoverageAggregate): JSONObject = JSONObject()
        .put("pointCount", aggregate.pointCount)
        .put("staleCount", aggregate.staleCount)
        .put("permissionRequiredCount", aggregate.permissionRequiredCount)
        .put("cachedScanCount", aggregate.cachedScanCount)
        .put("noSignalCount", aggregate.noSignalCount)
        .put("rssiMin", aggregate.rssiMin ?: JSONObject.NULL)
        .put("rssiMax", aggregate.rssiMax ?: JSONObject.NULL)
        .put("rssiAverage", aggregate.rssiAverage?.let { round(it) } ?: JSONObject.NULL)
        .put("estimatedCoveragePercent", aggregate.estimatedCoveragePercent?.let { round(it) }
            ?: JSONObject.NULL)
        .put("unsampledCells", aggregate.unsampledCells)
        .put("bandCounts", JSONObject().apply {
            aggregate.bandCounts.forEach { (band, count) -> put(band, count) }
        })
        .put("channelCounts", JSONObject().apply {
            aggregate.channelCounts.forEach { (channel, count) -> put(channel.toString(), count) }
        })
        .put("legend", JSONArray().apply {
            aggregate.legend.forEach {
                put(JSONObject().put("level", it.level)
                    .put("minimumDbm", it.minimumDbm).put("maximumDbm", it.maximumDbm)
                    .put("points", it.pointCount))
            }
        })

    private fun limitations(session: CoverageSession, aggregate: CoverageAggregate): List<String> = buildList {
        add("Coverage is user-sampled at explicit points; it is not a continuous RF survey.")
        add("Signal level is the strongest access point seen by a real scan; it is not a calibrated heatmap.")
        add("No GPS, RTT ranging, background scanning or synthetic access points are used.")
        if (session.floorplan == null) add("No floorplan is attached; the grid view is shown.")
        if (aggregate.staleCount > 0) add("${aggregate.staleCount} points are older than 10 minutes.")
        if (aggregate.cachedScanCount > 0) add("${aggregate.cachedScanCount} points use a cached scan; its age is shown.")
        if (aggregate.permissionRequiredCount > 0) {
            add("${aggregate.permissionRequiredCount} samples lack Wi-Fi scan permission/location services.")
        }
        if (aggregate.noSignalCount > 0) add("${aggregate.noSignalCount} samples returned no access point.")
        if (aggregate.unsampledCells > 0) add("${aggregate.unsampledCells} grid cells have no sample.")
    }.distinct()

    private fun strongestChannel(point: CoveragePoint): Int? =
        point.scan.accessPoints.maxByOrNull { it.rssiDbm }?.channel

    private fun format(value: Double): String =
        String.format(java.util.Locale.ROOT, "%.3f", value)

    private fun round(value: Double): Double = Math.round(value * 1000.0) / 1000.0

    private fun String.markdownCell(): String =
        replace("|", "\\|").replace('\n', ' ').replace('\r', ' ')
}
