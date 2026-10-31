// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

/**
 * Strict projection of the frozen `network.wifiScan` observation into the
 * coverage point shape. It never invents an access point, a signal value or a
 * fresh scan: missing rows stay missing, cached age is carried through, and a
 * permission/unavailable/error answer is preserved as the point's status.
 */
object CoverageScanParser {
    private val statuses = CoverageScanStatus.entries.map { it.wire }.toSet()

    fun parse(raw: String, capturedAtEpochMillis: Long): CoverageScanSnapshot {
        require(raw.toByteArray(Charsets.UTF_8).size <= NetworkMonitorLimits.MAX_RAW_RESULT_BYTES) {
            "wi-fi observation exceeds the 256 KiB bound"
        }
        val root = JSONObject(raw)
        require(root.optInt("version", -1) == 1 && root.optString("source") == "phone") {
            "not a phone observation v1"
        }
        require(runCatching { UUID.fromString(root.getString("operationID")) }.isSuccess) {
            "operationID must be a UUID"
        }
        require(root.optString("method") == "network.wifiScan") { "not a wi-fi scan observation" }
        val statusWire = root.optString("status", "error")
        require(statusWire in statuses) { "unknown observation status" }
        val observations = root.optJSONObject("observations") ?: JSONObject()
        val limitations = buildList {
            root.optJSONArray("limitations")?.let { array ->
                for (index in 0 until minOf(array.length(), 24)) {
                    array.opt(index)?.toString()?.takeIf { it.isNotBlank() }?.let {
                        add(NetworkMonitorRedactor.redactCredentials(it).take(300))
                    }
                }
            }
            observations.optString("errorCode").takeIf { it.isNotBlank() }?.let {
                add("The Wi-Fi scan returned $it.")
            }
        }.distinct()
        val missing = root.optJSONArray("missingPermissions")?.let { array ->
            (0 until minOf(array.length(), 16)).mapNotNull { index ->
                array.optString(index).takeIf { it.isNotBlank() }?.take(128)
            }
        }.orEmpty()
        val refreshRequested = observations.optBoolean("refreshRequested", false)
        val refreshStatus = refreshStatus(observations, refreshRequested)
        val rows = observations.optJSONArray("accessPoints") ?: JSONArray()
        val accessPoints = (0 until minOf(rows.length(), CoverageLimits.MAX_ACCESS_POINTS_PER_SCAN))
            .mapNotNull { index -> rows.optJSONObject(index)?.let(::accessPoint) }
        return CoverageScanSnapshot(
            capturedAtEpochMillis = capturedAtEpochMillis,
            status = CoverageScanStatus.fromWire(statusWire),
            wifiEnabled = observations.booleanOrNull("wifiEnabled"),
            locationServicesEnabled = observations.booleanOrNull("locationServicesEnabled"),
            cachedAgeMs = observations.longOrNull("cacheAgeMs")?.takeIf { it >= 0 }
                ?: root.longOrNull("cacheAgeMs")?.takeIf { it >= 0 },
            freshness = observations.optString("freshness").takeIf { it.isNotBlank() },
            refreshRequested = refreshRequested,
            refreshStatus = refreshStatus,
            scanAccepted = observations.booleanOrNull("scanAccepted"),
            resultsUpdated = observations.booleanOrNull("resultsUpdated"),
            truncated = observations.optBoolean("truncated", false),
            accessPoints = accessPoints,
            limitations = limitations,
            missingPermissions = missing,
        )
    }

    private fun accessPoint(row: JSONObject): CoverageAccessPoint? {
        val rssi = row.intOrNull("rssiDbm")
            ?: row.intOrNull("rssi")
            ?: row.intOrNull("level")
            ?: row.optJSONObject("signal")?.intOrNull("rssiDbm")
            ?: return null
        if (rssi !in -127..0) return null
        val frequency = row.intOrNull("frequencyMhz") ?: row.intOrNull("frequencyMHz")
        val channel = row.intOrNull("channel")
            ?: frequency?.let(::channelForFrequency)
        val security = buildList {
            row.optJSONArray("securityTypes")?.let { array ->
                for (index in 0 until minOf(array.length(), 8)) {
                    array.optString(index).takeIf { it.isNotBlank() }?.take(64)?.let(::add)
                }
            }
            row.optString("capabilities").takeIf { it.isNotBlank() }?.take(128)?.let(::add)
        }.distinct()
        return CoverageAccessPoint(
            ssid = row.optString("ssid").takeIf { it.isNotBlank() },
            bssid = row.optString("bssid").takeIf { it.isNotBlank() },
            rssiDbm = rssi,
            frequencyMhz = frequency?.takeIf { it in 1..100_000 },
            channel = channel?.takeIf { it in 1..233 },
            band = row.optString("band").takeIf { it.isNotBlank() }?.take(16),
            widthMhz = row.intOrNull("widthMhz")?.takeIf { it in 1..320 },
            security = security,
            ageMs = row.longOrNull("ageMs")?.takeIf { it >= 0 },
            timestampMicros = row.longOrNull("timestampMicros")?.takeIf { it > 0 },
        )
    }

    private fun refreshStatus(observations: JSONObject, requested: Boolean): CoverageRefreshStatus {
        if (!requested) return CoverageRefreshStatus.UNKNOWN
        val outcome = observations.optString("refreshOutcome")
        return when (outcome) {
            "updated" -> CoverageRefreshStatus.UPDATED
            "notUpdated" -> CoverageRefreshStatus.NOT_UPDATED
            "refused" -> CoverageRefreshStatus.REFUSED
            "completionTimeout" -> CoverageRefreshStatus.TIMEOUT
            "completionUnavailable" -> CoverageRefreshStatus.UNAVAILABLE
            else -> {
                val accepted = observations.booleanOrNull("scanAccepted")
                val updated = observations.booleanOrNull("resultsUpdated")
                when {
                    accepted == false -> CoverageRefreshStatus.REFUSED
                    updated == false -> CoverageRefreshStatus.NOT_UPDATED
                    updated == true -> CoverageRefreshStatus.UPDATED
                    accepted == true -> CoverageRefreshStatus.TIMEOUT
                    else -> CoverageRefreshStatus.UNKNOWN
                }
            }
        }
    }

    private fun channelForFrequency(frequency: Int): Int? = when {
        frequency == 2_487 -> 14
        frequency in 2_412..2_472 -> (frequency - 2_407) / 5
        frequency in 5_000..5_925 -> (frequency - 5_000) / 5
        frequency in 5_955..7_125 -> (frequency - 5_955) / 5 + 1
        else -> null
    }
}

/**
 * Projects an explicitly enabled ping/TCP/speed observation into the
 * optional coverage probe row. The App only calls these after the user
 * enables the existing consent/allowance path; a failed or missing answer is
 * preserved as a typed row instead of being hidden.
 */
object CoverageProbeParser {
    fun parse(kind: String, raw: String, measuredAtEpochMillis: Long): CoverageProbeResult {
        val requiredMethod = when (kind) {
            "ping" -> "network.ping"
            "tcpProbe" -> "network.tcpProbe"
            "speedDownload", "speedUpload" -> "network.speedTest"
            else -> throw IllegalArgumentException("unsupported coverage probe")
        }
        val root = JSONObject(raw)
        require(root.optInt("version", -1) == 1 && root.optString("source") == "phone" &&
            root.optString("method") == requiredMethod) { "unexpected probe observation" }
        val observations = root.optJSONObject("observations") ?: JSONObject()
        val status = root.optString("status", "error")
        val errorCode = observations.optString("errorCode", observations.optString("stoppedReason"))
            .takeIf { it.isNotBlank() }?.take(64)
        val latency = when (kind) {
            "ping" -> observations.doubleOrNull("averageMs")
                ?: observations.doubleOrNull("rttAvgMs")
                ?: observations.doubleOrNull("rttMinMs")
            "tcpProbe" -> observations.doubleOrNull("connectTimeMs")
            else -> null
        }
        val bits = if (kind.startsWith("speed")) {
            val direction = if (kind == "speedUpload") "upload" else "download"
            observations.optJSONObject(direction)?.doubleOrNull("bitsPerSecond")
        } else {
            null
        }
        val bytes = if (kind.startsWith("speed")) {
            val direction = if (kind == "speedUpload") "upload" else "download"
            observations.optJSONObject(direction)?.longOrNull("measuredBytes")
        } else {
            null
        }
        val limitations = root.optJSONArray("limitations")?.let { array ->
            (0 until minOf(array.length(), 8)).mapNotNull { index ->
                array.optString(index).takeIf { it.isNotBlank() }
                    ?.let(NetworkMonitorRedactor::redactCredentials)?.take(300)
            }
        }.orEmpty()
        return CoverageProbeResult(
            kind = kind,
            status = status,
            targetHost = root.optString("target").takeIf { it.isNotBlank() }?.take(253),
            latencyMs = latency?.takeIf { it.isFinite() && it >= 0.0 },
            bitsPerSecond = bits?.takeIf { it.isFinite() && it >= 0.0 },
            payloadBytes = bytes?.takeIf { it >= 0 },
            errorCode = errorCode,
            measuredAtEpochMillis = measuredAtEpochMillis,
            limitations = limitations,
        )
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
