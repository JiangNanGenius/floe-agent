// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/** Bounded session JSON. The App-private file may contain real scan rows; exports redact. */
object CoverageSessionCodec {
    const val SCHEMA = "floe.network-coverage-session.v1"

    fun encode(session: CoverageSession): String {
        val root = JSONObject()
            .put("schema", SCHEMA)
            .put("sessionID", session.sessionID)
            .put("name", session.name)
            .put("createdAt", Instant.ofEpochMilli(session.createdAtEpochMillis).toString())
            .put("updatedAt", Instant.ofEpochMilli(session.updatedAtEpochMillis).toString())
            .put("ownerTaskId", session.ownerTaskId ?: JSONObject.NULL)
            .put("ownerWorkspaceId", session.ownerWorkspaceId ?: JSONObject.NULL)
            .put("agentReadable", session.agentReadable)
            .put("floorplan", session.floorplan?.let {
                JSONObject()
                    .put("width", it.width)
                    .put("height", it.height)
                    .put("mimeType", it.mimeType)
                    .put("byteCount", it.byteCount)
                    .put("sha256", it.sha256)
                    .put("importedAt", Instant.ofEpochMilli(it.importedAtEpochMillis).toString())
            } ?: JSONObject.NULL)
            .put("points", JSONArray().apply { session.points.forEach { put(point(it)) } })
        val text = root.toString(2)
        require(text.toByteArray(Charsets.UTF_8).size <= CoverageLimits.MAX_SESSION_JSON_BYTES) {
            "coverage session exceeds its bounded size"
        }
        return text
    }

    fun decode(json: String): CoverageSession {
        require(json.toByteArray(Charsets.UTF_8).size <= CoverageLimits.MAX_SESSION_JSON_BYTES) {
            "coverage session exceeds its bounded size"
        }
        val root = JSONObject(json)
        require(root.optString("schema") == SCHEMA) { "unexpected coverage schema" }
        val points = root.optJSONArray("points") ?: JSONArray()
        return CoverageSession(
            sessionID = root.getString("sessionID"),
            name = root.getString("name"),
            createdAtEpochMillis = instant(root.getString("createdAt")),
            updatedAtEpochMillis = instant(root.getString("updatedAt")),
            ownerTaskId = root.opt("ownerTaskId")?.toString()?.takeIf { it != "null" },
            ownerWorkspaceId = root.opt("ownerWorkspaceId")?.toString()?.takeIf { it != "null" },
            agentReadable = root.optBoolean("agentReadable"),
            floorplan = root.optJSONObject("floorplan")?.let { floorplan(it) },
            points = (0 until minOf(points.length(), CoverageLimits.MAX_POINTS_PER_SESSION))
                .mapNotNull { index -> points.optJSONObject(index)?.let(::point) },
        )
    }

    private fun point(point: CoveragePoint): JSONObject = JSONObject()
        .put("pointID", point.pointID)
        .put("label", point.label ?: JSONObject.NULL)
        .put("x", point.x)
        .put("y", point.y)
        .put("createdAt", Instant.ofEpochMilli(point.createdAtEpochMillis).toString())
        .put("scan", scan(point.scan))
        .put("probe", point.probe?.let(::probe) ?: JSONObject.NULL)

    private fun scan(scan: CoverageScanSnapshot): JSONObject = JSONObject()
        .put("capturedAt", Instant.ofEpochMilli(scan.capturedAtEpochMillis).toString())
        .put("status", scan.status.wire)
        .put("wifiEnabled", scan.wifiEnabled ?: JSONObject.NULL)
        .put("locationServicesEnabled", scan.locationServicesEnabled ?: JSONObject.NULL)
        .put("cachedAgeMs", scan.cachedAgeMs ?: JSONObject.NULL)
        .put("freshness", scan.freshness ?: JSONObject.NULL)
        .put("refreshRequested", scan.refreshRequested)
        .put("refreshStatus", scan.refreshStatus.wire)
        .put("scanAccepted", scan.scanAccepted ?: JSONObject.NULL)
        .put("resultsUpdated", scan.resultsUpdated ?: JSONObject.NULL)
        .put("truncated", scan.truncated)
        .put("accessPoints", JSONArray().apply {
            scan.accessPoints.forEach {
                put(JSONObject()
                    .put("ssid", it.ssid ?: JSONObject.NULL)
                    .put("bssid", it.bssid ?: JSONObject.NULL)
                    .put("rssiDbm", it.rssiDbm)
                    .put("frequencyMhz", it.frequencyMhz ?: JSONObject.NULL)
                    .put("channel", it.channel ?: JSONObject.NULL)
                    .put("band", it.band ?: JSONObject.NULL)
                    .put("widthMhz", it.widthMhz ?: JSONObject.NULL)
                    .put("security", JSONArray().apply { it.security.forEach(::put) })
                    .put("ageMs", it.ageMs ?: JSONObject.NULL)
                    .put("timestampMicros", it.timestampMicros ?: JSONObject.NULL))
            }
        })
        .put("limitations", JSONArray().apply { scan.limitations.forEach(::put) })
        .put("missingPermissions", JSONArray().apply { scan.missingPermissions.forEach(::put) })

    private fun probe(probe: CoverageProbeResult): JSONObject = JSONObject()
        .put("kind", probe.kind)
        .put("status", probe.status)
        .put("targetHost", probe.targetHost ?: JSONObject.NULL)
        .put("latencyMs", probe.latencyMs ?: JSONObject.NULL)
        .put("bitsPerSecond", probe.bitsPerSecond ?: JSONObject.NULL)
        .put("payloadBytes", probe.payloadBytes ?: JSONObject.NULL)
        .put("errorCode", probe.errorCode ?: JSONObject.NULL)
        .put("measuredAt", Instant.ofEpochMilli(probe.measuredAtEpochMillis).toString())
        .put("limitations", JSONArray().apply { probe.limitations.forEach(::put) })

    private fun point(value: JSONObject): CoveragePoint? = runCatching {
        CoveragePoint(
            pointID = value.getString("pointID"),
            label = value.opt("label")?.toString()?.takeIf { it != "null" },
            x = value.getDouble("x"),
            y = value.getDouble("y"),
            createdAtEpochMillis = instant(value.getString("createdAt")),
            scan = scan(value.getJSONObject("scan")),
            probe = value.optJSONObject("probe")?.let(::probe),
        )
    }.getOrNull()

    private fun scan(value: JSONObject): CoverageScanSnapshot {
        val rows = value.optJSONArray("accessPoints") ?: JSONArray()
        return CoverageScanSnapshot(
            capturedAtEpochMillis = instant(value.getString("capturedAt")),
            status = CoverageScanStatus.fromWire(value.optString("status")),
            wifiEnabled = value.booleanOrNull("wifiEnabled"),
            locationServicesEnabled = value.booleanOrNull("locationServicesEnabled"),
            cachedAgeMs = value.longOrNull("cachedAgeMs"),
            freshness = value.opt("freshness")?.toString()?.takeIf { it != "null" },
            refreshRequested = value.optBoolean("refreshRequested"),
            refreshStatus = CoverageRefreshStatus.entries.firstOrNull {
                it.wire == value.optString("refreshStatus")
            } ?: CoverageRefreshStatus.UNKNOWN,
            scanAccepted = value.booleanOrNull("scanAccepted"),
            resultsUpdated = value.booleanOrNull("resultsUpdated"),
            truncated = value.optBoolean("truncated"),
            accessPoints = (0 until minOf(rows.length(), CoverageLimits.MAX_ACCESS_POINTS_PER_SCAN))
                .mapNotNull { index -> rows.optJSONObject(index)?.let(::accessPoint) },
            limitations = stringList(value.optJSONArray("limitations"), 24),
            missingPermissions = stringList(value.optJSONArray("missingPermissions"), 16),
        )
    }

    private fun accessPoint(value: JSONObject): CoverageAccessPoint? = runCatching {
        CoverageAccessPoint(
            ssid = value.opt("ssid")?.toString()?.takeIf { it != "null" },
            bssid = value.opt("bssid")?.toString()?.takeIf { it != "null" },
            rssiDbm = value.getInt("rssiDbm"),
            frequencyMhz = value.intOrNull("frequencyMhz"),
            channel = value.intOrNull("channel"),
            band = value.opt("band")?.toString()?.takeIf { it != "null" },
            widthMhz = value.intOrNull("widthMhz"),
            security = stringList(value.optJSONArray("security"), 8),
            ageMs = value.longOrNull("ageMs"),
            timestampMicros = value.longOrNull("timestampMicros"),
        )
    }.getOrNull()

    private fun probe(value: JSONObject): CoverageProbeResult? = runCatching {
        CoverageProbeResult(
            kind = value.getString("kind"),
            status = value.getString("status"),
            targetHost = value.opt("targetHost")?.toString()?.takeIf { it != "null" },
            latencyMs = value.doubleOrNull("latencyMs"),
            bitsPerSecond = value.doubleOrNull("bitsPerSecond"),
            payloadBytes = value.longOrNull("payloadBytes"),
            errorCode = value.opt("errorCode")?.toString()?.takeIf { it != "null" },
            measuredAtEpochMillis = instant(value.getString("measuredAt")),
            limitations = stringList(value.optJSONArray("limitations"), 8),
        )
    }.getOrNull()

    private fun floorplan(value: JSONObject): CoverageFloorplan = CoverageFloorplan(
        width = value.getInt("width"),
        height = value.getInt("height"),
        mimeType = value.getString("mimeType"),
        byteCount = value.getLong("byteCount"),
        sha256 = value.getString("sha256"),
        importedAtEpochMillis = instant(value.getString("importedAt")),
    )

    private fun instant(value: String): Long =
        Instant.parse(value).toEpochMilli()

    private fun stringList(array: JSONArray?, limit: Int): List<String> =
        if (array == null) emptyList()
        else (0 until minOf(array.length(), limit)).mapNotNull { index ->
            array.optString(index).takeIf { it.isNotBlank() }?.take(300)
        }
}

private fun JSONObject.booleanOrNull(key: String): Boolean? =
    if (has(key) && !isNull(key)) optBoolean(key) else null

private fun JSONObject.intOrNull(key: String): Int? =
    if (has(key) && !isNull(key)) optInt(key) else null

private fun JSONObject.longOrNull(key: String): Long? =
    if (has(key) && !isNull(key)) optLong(key) else null

private fun JSONObject.doubleOrNull(key: String): Double? =
    if (has(key) && !isNull(key)) optDouble(key).takeIf { it.isFinite() } else null
