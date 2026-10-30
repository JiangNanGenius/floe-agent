// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.time.Instant
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** Converts the frozen envelope into bounded scalar fields; arbitrary JSON is never retained. */
object NetworkMonitorObservationParser {
    private const val MAX_FIELDS = 96
    private const val MAX_DEPTH = 6
    private const val MAX_ARRAY_ITEMS = 32
    private const val MAX_KEY_CHARS = 96
    private const val MAX_VALUE_CHARS = 300
    private val statuses = setOf("ok", "error", "timeout", "cancelled", "permissionRequired", "unsupported")

    internal fun parse(
        raw: String,
        sequence: Long,
        expectedOperationID: String,
        expectedMethod: String,
        fallbackMeasuredAtEpochMillis: Long,
        startedAtElapsedNanos: Long,
        finishedAtElapsedNanos: Long,
    ): NetworkMonitorObservation {
        val rawBytes = raw.toByteArray(Charsets.UTF_8).size
        val fallbackMeasuredAt = Instant.ofEpochMilli(fallbackMeasuredAtEpochMillis).toString()
        if (rawBytes > NetworkMonitorLimits.MAX_RAW_RESULT_BYTES) {
            return failure(
                sequence, expectedOperationID, expectedMethod, fallbackMeasuredAt,
                "resultTooLarge", startedAtElapsedNanos, finishedAtElapsedNanos, rawBytes,
            )
        }
        val root = try {
            JSONObject(raw)
        } catch (_: Exception) {
            return failure(
                sequence, expectedOperationID, expectedMethod, fallbackMeasuredAt,
                "invalidResponse", startedAtElapsedNanos, finishedAtElapsedNanos, rawBytes,
            )
        }
        val operationID = root.optString("operationID", "")
        val method = root.optString("method", "")
        val status = root.optString("status", "")
        if (root.optInt("version", -1) != 1 ||
            root.optString("source", "") != "phone" ||
            operationID != expectedOperationID ||
            method != expectedMethod ||
            status !in statuses
        ) {
            return failure(
                sequence, expectedOperationID, expectedMethod, fallbackMeasuredAt,
                "invalidResponse", startedAtElapsedNanos, finishedAtElapsedNanos, rawBytes,
            )
        }
        val measuredAt = root.optString("measuredAt", "").takeIf {
            runCatching { Instant.parse(it) }.isSuccess
        } ?: fallbackMeasuredAt
        val network = readFields(root.optJSONObject("network"))
        val allObservations = readFields(root.optJSONObject("observations"))
        val transfers = allObservations.onlyTransferFields()
        val details = allObservations.withoutTransferFields()
        val handle = network.text["handle"]?.takeIf { it.isNotBlank() && it != "[redacted]" }
        val available = network.booleans["available"] == true
        val capturedNetworkKey = when {
            !available -> "unavailable"
            handle != null -> "handle:$handle"
            else -> "unknown"
        }
        return NetworkMonitorObservation(
            sequence = sequence,
            operationID = operationID,
            method = method,
            measuredAt = measuredAt,
            status = status,
            target = (root.opt("target") as? String)?.let {
                NetworkMonitorRedactor.redactCredentials(it.take(MAX_VALUE_CHARS))
            },
            actualNetwork = network,
            transfers = transfers,
            details = details,
            limitations = stringList(root.optJSONArray("limitations")),
            missingPermissions = stringList(root.optJSONArray("missingPermissions")),
            startedAtElapsedNanos = startedAtElapsedNanos,
            finishedAtElapsedNanos = finishedAtElapsedNanos,
            rawBytes = rawBytes,
            capturedNetworkKey = capturedNetworkKey,
        )
    }

    internal fun failure(
        sequence: Long,
        operationID: String,
        method: String,
        measuredAt: String,
        code: String,
        startedAtElapsedNanos: Long,
        finishedAtElapsedNanos: Long,
        rawBytes: Int = 0,
    ): NetworkMonitorObservation = NetworkMonitorObservation(
        sequence = sequence,
        operationID = operationID,
        method = method,
        measuredAt = measuredAt,
        status = "error",
        target = null,
        actualNetwork = NetworkMonitorFields(),
        transfers = NetworkMonitorFields(),
        details = NetworkMonitorFields(text = mapOf("errorCode" to code)),
        limitations = listOf("The probe did not return a valid measurement."),
        missingPermissions = emptyList(),
        startedAtElapsedNanos = startedAtElapsedNanos,
        finishedAtElapsedNanos = finishedAtElapsedNanos,
        rawBytes = rawBytes,
        capturedNetworkKey = "unknown",
    )

    private fun stringList(array: JSONArray?): List<String> {
        if (array == null) return emptyList()
        return buildList {
            for (index in 0 until minOf(array.length(), 16)) {
                val value = array.opt(index) as? String ?: continue
                val clean = NetworkMonitorRedactor.redactCredentials(value)
                    .replace('\n', ' ')
                    .replace('\r', ' ')
                    .trim()
                    .take(MAX_VALUE_CHARS)
                if (clean.isNotEmpty()) add(clean)
            }
        }.distinct()
    }

    private fun readFields(root: JSONObject?): NetworkMonitorFields {
        if (root == null) return NetworkMonitorFields()
        val text = linkedMapOf<String, String>()
        val numbers = linkedMapOf<String, Double>()
        val booleans = linkedMapOf<String, Boolean>()
        val state = FlattenState(text, numbers, booleans)
        flattenObject(root, "", state, 0)
        if (state.truncated) text["_truncated"] = "true"
        return NetworkMonitorFields(text, numbers, booleans)
    }

    private data class FlattenState(
        val text: LinkedHashMap<String, String>,
        val numbers: LinkedHashMap<String, Double>,
        val booleans: LinkedHashMap<String, Boolean>,
        var count: Int = 0,
        var truncated: Boolean = false,
    )

    private fun flattenObject(value: JSONObject, prefix: String, state: FlattenState, depth: Int) {
        if (depth > MAX_DEPTH) {
            state.truncated = true
            return
        }
        val keys = value.keys()
        while (keys.hasNext()) {
            val rawKey = keys.next()
            val key = sanitizeKey(rawKey)
            val path = if (prefix.isEmpty()) key else "$prefix.$key"
            flattenValue(value.opt(rawKey), path, state, depth)
            if (state.count >= MAX_FIELDS) {
                state.truncated = true
                return
            }
        }
    }

    private fun flattenArray(value: JSONArray, prefix: String, state: FlattenState, depth: Int) {
        if (depth > MAX_DEPTH || value.length() > MAX_ARRAY_ITEMS) state.truncated = true
        for (index in 0 until minOf(value.length(), MAX_ARRAY_ITEMS)) {
            flattenValue(value.opt(index), "$prefix.$index", state, depth)
            if (state.count >= MAX_FIELDS) {
                state.truncated = true
                return
            }
        }
    }

    private fun flattenValue(value: Any?, path: String, state: FlattenState, depth: Int) {
        if (state.count >= MAX_FIELDS) {
            state.truncated = true
            return
        }
        when (value) {
            null, JSONObject.NULL -> Unit
            is JSONObject -> flattenObject(value, path, state, depth + 1)
            is JSONArray -> flattenArray(value, path, state, depth + 1)
            is Boolean -> {
                state.booleans[path] = value
                state.count++
            }
            is Number -> {
                val number = value.toDouble()
                if (number.isFinite() &&
                    !NetworkMonitorRedactor.isCredentialKey(path) &&
                    !NetworkMonitorRedactor.isDeviceUniqueKey(path)
                ) {
                    state.numbers[path] = number
                }
                state.count++
            }
            else -> {
                val raw = value.toString().take(MAX_VALUE_CHARS)
                state.text[path] = if (
                    NetworkMonitorRedactor.isCredentialKey(path) ||
                    NetworkMonitorRedactor.isDeviceUniqueKey(path)
                ) {
                    "[redacted]"
                } else {
                    NetworkMonitorRedactor.redactCredentials(raw)
                }
                state.count++
            }
        }
    }

    private fun sanitizeKey(raw: String): String {
        val cleaned = buildString(raw.length) {
            raw.take(MAX_KEY_CHARS).forEach { character ->
                append(if (character.isLetterOrDigit() || character in "_.-") character else '_')
            }
        }
        return cleaned.ifBlank { "field" }
    }
}

private fun NetworkMonitorFields.onlyTransferFields(): NetworkMonitorFields = NetworkMonitorFields(
    text = text.filterKeys(::isTransferKey),
    numbers = numbers.filterKeys(::isTransferKey),
    booleans = booleans.filterKeys(::isTransferKey),
)

private fun NetworkMonitorFields.withoutTransferFields(): NetworkMonitorFields = NetworkMonitorFields(
    text = text.filterKeys { !isTransferKey(it) },
    numbers = numbers.filterKeys { !isTransferKey(it) },
    booleans = booleans.filterKeys { !isTransferKey(it) },
)

private fun isTransferKey(key: String): Boolean {
    val normalized = key.lowercase(Locale.ROOT)
    return listOf("byte", "transfer", "download", "upload", "throughput", "bandwidth", "packet")
        .any(normalized::contains)
}

/** Pure string/URI redaction only: no DNS, sockets or network permission is used during export. */
internal object NetworkMonitorRedactor {
    private val credentialKey = Regex(
        "(?i)(?:api[-_]?key|secret|token|password|passwd|authorization|cookie|credential|bearer)",
    )
    private val deviceUniqueKey = Regex(
        "(?i)(?:android[-_]?id|device[-_]?unique[-_]?id|device[-_]?id|serial[-_]?number|imei|imsi|iccid|advertising[-_]?id)",
    )
    private val sensitiveKey = Regex(
        "(?i)(?:ssid|bssid|mac(?:address)?|ip(?:address)?|address|host|target|handle|interface|identifier|service|dns|dhcp|proxy|route|domain|url|uri)",
    )
    private val bearer = Regex("(?i)bearer\\s+[A-Za-z0-9._~+/=-]+")
    private val assignedSecret = Regex(
        "(?i)(api[-_]?key|secret|token|password|authorization|cookie)\\s*[:=]\\s*[^,;\\s]+",
    )
    private val url = Regex("(?i)https?://[^\\s<>\"']+")
    private val mac = Regex("(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])")
    private val ipv4 = Regex("(?<![0-9])(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(?![0-9])")
    private val ipv6 = Regex("(?i)(?<![0-9a-f])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:%[a-z0-9_.-]+)?(?![0-9a-f])")
    private val localhost = Regex("(?i)(?<![a-z0-9.-])localhost(?:\\.localdomain)?(?![a-z0-9.-])")
    private val serviceName = Regex("(?i)(?<![a-z0-9_-])_[a-z0-9-]+\\._(?:tcp|udp)(?:\\.[a-z0-9_-]+)*")
    private val localName = Regex("(?i)(?<![a-z0-9_-])[a-z0-9_-]+\\.local(?![a-z0-9_-])")

    fun isCredentialKey(key: String): Boolean = credentialKey.containsMatchIn(key)
    fun isDeviceUniqueKey(key: String): Boolean = deviceUniqueKey.containsMatchIn(key)
    fun isSensitiveKey(key: String): Boolean = sensitiveKey.containsMatchIn(key) || isDeviceUniqueKey(key)

    fun redactCredentials(value: String): String = assignedSecret.replace(bearer.replace(value, "[redacted-credential]")) {
        "${it.groupValues[1]}=[redacted]"
    }

    fun value(key: String, raw: String, detailed: Boolean): String {
        if (isCredentialKey(key) || isDeviceUniqueKey(key)) return "[redacted]"
        val withoutCredentials = redactCredentials(raw)
        if (detailed) return sanitizeUrlsWithoutSecrets(withoutCredentials)
        if (isSensitiveKey(key)) return "[redacted-network-identifier]"
        return redactSensitiveValues(withoutCredentials)
    }

    fun redactSensitiveValues(raw: String): String {
        var output = url.replace(raw, "[redacted-url]")
        output = mac.replace(output, "[redacted-mac]")
        output = ipv4.replace(output, "[redacted-ip]")
        output = ipv6.replace(output, "[redacted-ipv6]")
        output = localhost.replace(output, "[redacted-localhost]")
        output = serviceName.replace(output, "[redacted-service]")
        output = localName.replace(output, "[redacted-local-name]")
        return output
    }

    /** URI parsing is syntactic. Userinfo/query/fragment never enter a detailed report. */
    private fun sanitizeUrlsWithoutSecrets(raw: String): String = url.replace(raw) { match ->
        val original = match.value
        try {
            val parsed = java.net.URI(original)
            val host = parsed.host
            if (host == null) {
                "[redacted-url]"
            } else {
                val port = if (parsed.port >= 0) ":${parsed.port}" else ""
                val path = parsed.rawPath.orEmpty()
                "${parsed.scheme}://$host$port$path"
            }
        } catch (_: Exception) {
            "[redacted-url]"
        }
    }
}
