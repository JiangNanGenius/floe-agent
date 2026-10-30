// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.util.Locale
import org.json.JSONObject

internal enum class SpeedDirection(
    val wire: String,
    val includesDownload: Boolean,
    val includesUpload: Boolean,
) {
    DOWNLOAD("download", true, false),
    UPLOAD("upload", false, true),
    DOWNLOAD_AND_UPLOAD("downloadAndUpload", true, true);

    val count: Int get() = (if (includesDownload) 1 else 0) + (if (includesUpload) 1 else 0)

    companion object {
        fun fromWire(value: String): SpeedDirection? =
            entries.firstOrNull { it.wire.lowercase(Locale.ROOT) == value.trim().lowercase(Locale.ROOT) }
    }
}

/**
 * Frozen network.speedTest arguments. Both endpoints are explicit; there is no
 * default hosted endpoint and no implicit upload. budgets are per requested
 * direction and are validated by the parser instead of silently widened.
 */
internal data class SpeedTestRequest(
    val direction: SpeedDirection,
    val downloadTarget: HttpTarget?,
    val uploadTarget: HttpTarget?,
    val maxBytesPerDirection: Int = NetworkLimits.DEFAULT_SPEED_BYTES,
    val durationBudgetMs: Int = NetworkLimits.DEFAULT_SPEED_DURATION_MS,
    val warmupBytes: Int = 0,
    val allowMetered: Boolean = false,
    val timeoutMs: Int = NetworkLimits.DEFAULT_SPEED_TIMEOUT_MS,
)

internal class SpeedTestFailure(
    val status: ObservationStatus,
    val code: String,
    message: String? = null,
    val missingPermissions: List<String> = emptyList(),
) : Exception(message ?: code)

/**
 * Monotonic transfer accounting. The measurement interval starts immediately
 * before the first measured read/write after warmup and ends at the monotonic
 * end of the last measured read/write, so a blocking first read is included.
 * A rate is not fabricated from a zero/near-zero interval.
 */
internal class SpeedMeter(private val warmupBytes: Long) {
    var payloadBytes: Long = 0L
        private set
    var warmupCompletedBytes: Long = 0L
        private set
    var measuredBytes: Long = 0L
        private set

    private var measurementStartNanos: Long? = null
    private var measurementEndNanos: Long? = null

    val warmupComplete: Boolean get() = warmupCompletedBytes >= warmupBytes

    fun beginMeasuredIo(nowNanos: Long) {
        if (warmupComplete && measuredBytes == 0L && measurementStartNanos == null) {
            measurementStartNanos = nowNanos
        }
    }

    fun recordWarmup(bytes: Int) {
        if (bytes <= 0) return
        payloadBytes += bytes
        warmupCompletedBytes = minOf(warmupBytes, payloadBytes)
    }

    fun recordMeasured(bytes: Int, nowNanos: Long) {
        if (bytes <= 0) return
        payloadBytes += bytes
        measuredBytes += bytes
        if (measurementStartNanos == null) measurementStartNanos = nowNanos
        measurementEndNanos = nowNanos
    }

    fun finish(nowNanos: Long) {
        if (measurementStartNanos != null && measurementEndNanos == null) {
            measurementEndNanos = nowNanos
        }
    }

    fun measurementElapsedMs(): Long? {
        val start = measurementStartNanos ?: return null
        val end = measurementEndNanos ?: return null
        return ((end - start) / 1_000_000L).coerceAtLeast(0L)
    }
}

internal data class SpeedRate(
    val bytesPerSecond: Double?,
    val bitsPerSecond: Double?,
    val available: Boolean,
    val omittedReason: String? = null,
)

/**
 * Pure rate policy. A rate is available only when there are measured bytes and
 * a monotonic interval of at least 10 ms; shorter intervals are retained as an
 * actual measurement but omitted as a meaningful rate and marked inadequate.
 */
internal object SpeedMath {
    const val MIN_RATE_INTERVAL_MS = 10L

    fun rate(measuredBytes: Long, elapsedMs: Long?): SpeedRate {
        if (measuredBytes <= 0L) {
            return SpeedRate(null, null, false, "noMeasuredBytes")
        }
        if (elapsedMs == null) {
            return SpeedRate(null, null, false, "noMeasurementInterval")
        }
        if (elapsedMs < MIN_RATE_INTERVAL_MS) {
            return SpeedRate(null, null, false, "measurementIntervalTooShort")
        }
        val bytesPerSecond = measuredBytes.toDouble() * 1000.0 / elapsedMs.toDouble()
        if (!bytesPerSecond.isFinite() || bytesPerSecond <= 0.0) {
            return SpeedRate(null, null, false, "rateNotFinite")
        }
        return SpeedRate(
            bytesPerSecond = bytesPerSecond,
            bitsPerSecond = bytesPerSecond * 8.0,
            available = true,
        )
    }

    fun sampleAdequate(measuredBytes: Long, elapsedMs: Long?): Boolean =
        measuredBytes >= NetworkLimits.MIN_SPEED_SAMPLE_BYTES &&
            elapsedMs != null &&
            elapsedMs >= NetworkLimits.MIN_SPEED_SAMPLE_MS
}

internal object SpeedPayload {
    /** Deterministic, non-secret 64 KiB-style pattern; never a user file. */
    fun chunk(size: Int): ByteArray {
        val safeSize = size.coerceIn(1, 256 * 1024)
        val bytes = ByteArray(safeSize)
        var state = 0x5DEE_CE66_5DEE_CE66L
        for (index in bytes.indices) {
            state = state * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
            bytes[index] = (state ushr 33).toByte()
        }
        return bytes
    }
}

internal data class SpeedTransferResult(
    val endpoint: String,
    val status: ObservationStatus,
    val payloadBytes: Long,
    val measuredBytes: Long,
    val warmupBytes: Long,
    val measurementElapsedMs: Long?,
    val totalElapsedMs: Long,
    val completionReason: String,
    val contentComplete: Boolean,
    val clientStopped: Boolean,
    val httpStatus: Int? = null,
    val contentLength: Long? = null,
    val contentEncoding: String? = null,
    val requestContentLength: Long? = null,
    val responseBytesRead: Long? = null,
    val networkChanged: Boolean = false,
    val tlsProtocol: String? = null,
    val cipherSuite: String? = null,
    val phases: Map<String, Long> = emptyMap(),
    val payloadBytesMeaning: String,
    val rate: SpeedRate = SpeedRate(null, null, false, "notMeasured"),
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("endpoint", endpoint)
        put("status", status.wire)
        put("payloadBytes", payloadBytes)
        put("measuredBytes", measuredBytes)
        put("warmupBytes", warmupBytes)
        put("payloadBytesMeaning", payloadBytesMeaning)
        measurementElapsedMs?.let { put("measurementElapsedMs", it) }
        put("totalElapsedMs", totalElapsedMs)
        put("completionReason", completionReason)
        put("contentComplete", contentComplete)
        put("clientStopped", clientStopped)
        put("networkChanged", networkChanged)
        put("rateAvailable", rate.available)
        rate.bytesPerSecond?.let { put("bytesPerSecond", it) }
        rate.bitsPerSecond?.let { put("bitsPerSecond", it) }
        rate.omittedReason?.let { put("rateOmittedReason", it) }
        put("rateBasis", "measuredPayloadBytes / monotonicMeasurementElapsedMs")
        httpStatus?.let { put("httpStatus", it) }
        contentLength?.let { put("contentLength", it) }
        contentEncoding?.let { put("contentEncoding", it.take(64)) }
        requestContentLength?.let { put("requestContentLength", it) }
        responseBytesRead?.let { put("responseBytesRead", it) }
        tlsProtocol?.let { put("tlsProtocol", it.take(32)) }
        cipherSuite?.let { put("cipherSuite", it.take(128)) }
        put(
            "phases",
            JSONObject().apply {
                phases.forEach { (key, value) -> put(key, value) }
            },
        )
    }
}

internal object SpeedHttpWire {
    const val MAX_HEADER_BYTES = 32 * 1024
    const val MAX_HEADER_LINES = 64
    const val MAX_HEADER_VALUE_CHARS = 1024

    data class Head(
        val statusCode: Int,
        val headers: Map<String, String>,
        /**
         * Untruncated values in wire order, keyed by lowercase field name.
         * Framing decisions use this instead of the display map so duplicate
         * or conflicting Content-Length/Transfer-Encoding fields are visible.
         */
        val headerValues: Map<String, List<String>> = emptyMap(),
    ) {
        fun header(name: String): String? = headers[name.lowercase(Locale.ROOT)]

        fun values(name: String): List<String> {
            val key = name.lowercase(Locale.ROOT)
            return headerValues[key] ?: headers[key]?.let { listOf(it) } ?: emptyList()
        }

        fun contentLength(): Long? = header("content-length")?.trim()?.toLongOrNull()?.takeIf { it >= 0 }
        fun contentEncoding(): String? = header("content-encoding")
    }

    fun downloadRequest(target: HttpTarget, port: Int): ByteArray {
        val authority = authority(target, port)
        val pathAndQuery = pathAndQuery(target)
        val request = buildString {
            append("GET ").append(pathAndQuery).append(" HTTP/1.1\r\n")
            append("Host: ").append(authority).append("\r\n")
            append("Accept: */*\r\n")
            append("Accept-Encoding: identity\r\n")
            append("Connection: close\r\n\r\n")
        }
        return request.toByteArray(Charsets.ISO_8859_1)
    }

    fun uploadRequest(target: HttpTarget, port: Int, contentLength: Long): ByteArray {
        val authority = authority(target, port)
        val pathAndQuery = pathAndQuery(target)
        val request = buildString {
            append("POST ").append(pathAndQuery).append(" HTTP/1.1\r\n")
            append("Host: ").append(authority).append("\r\n")
            append("Accept: */*\r\n")
            append("Content-Type: application/octet-stream\r\n")
            append("Content-Length: ").append(contentLength).append("\r\n")
            append("Connection: close\r\n\r\n")
        }
        return request.toByteArray(Charsets.ISO_8859_1)
    }

    fun readHead(input: java.io.InputStream): Head {
        var attempt = 0
        while (attempt < 3) {
            attempt++
            val raw = readHeadBytes(input)
            val text = String(raw, Charsets.ISO_8859_1)
            val lines = text.split("\r\n")
            val status = lines.firstOrNull()?.split(' ') ?: emptyList()
            val statusCode = status.getOrNull(1)?.toIntOrNull()
                ?: throw SpeedHttpProtocolException(
                    "invalidStatusLine",
                    "invalid HTTPS status line",
                )
            val headers = LinkedHashMap<String, String>()
            val headerValues = LinkedHashMap<String, MutableList<String>>()
            var headerLines = 0
            lines.drop(1).forEach { line ->
                if (line.isEmpty()) return@forEach
                headerLines++
                if (headerLines > MAX_HEADER_LINES) {
                    throw SpeedHttpProtocolException(
                        "oversizedHeaders",
                        "HTTPS response exceeded $MAX_HEADER_LINES header fields",
                    )
                }
                if (line[0] == ' ' || line[0] == '\t') {
                    // Obsolete line folding could hide a different
                    // Content-Length; refuse instead of mis-framing the body.
                    throw SpeedHttpProtocolException(
                        "malformedHeaders",
                        "obsolete HTTPS header line folding is not accepted",
                    )
                }
                val separator = line.indexOf(':')
                if (separator <= 0) {
                    // A malformed field line could hide a different framing
                    // header; refuse instead of silently falling back to EOF.
                    throw SpeedHttpProtocolException(
                        "malformedHeaders",
                        "HTTPS header field has no name",
                    )
                }
                val name = line.substring(0, separator).trim().lowercase(Locale.ROOT)
                if (name.isEmpty()) {
                    throw SpeedHttpProtocolException(
                        "malformedHeaders",
                        "HTTPS header field has an empty name",
                    )
                }
                val value = line.substring(separator + 1).trim()
                headerValues.getOrPut(name) { ArrayList() }.add(value)
                // The display map stays bounded; framing reads headerValues so
                // a long or duplicated field is never silently truncated.
                headers[name] = value.take(MAX_HEADER_VALUE_CHARS)
            }
            if (statusCode in 100..199) continue
            return Head(
                statusCode = statusCode,
                headers = headers,
                headerValues = headerValues.mapValues { it.value.toList() },
            )
        }
        throw SpeedHttpProtocolException(
            "tooManyInterimResponses",
            "too many interim HTTPS responses",
        )
    }

    private fun readHeadBytes(input: java.io.InputStream): ByteArray {
        val output = java.io.ByteArrayOutputStream(1024)
        val one = ByteArray(1)
        var read = 0
        var tail = 0
        while (read < MAX_HEADER_BYTES) {
            val count = input.read(one)
            if (count < 0) {
                if (read == 0) {
                    throw SpeedHttpProtocolException("emptyResponse", "empty HTTPS response")
                }
                throw SpeedHttpProtocolException(
                    "truncatedHeaders",
                    "HTTPS response headers ended before the blank line",
                )
            }
            output.write(one[0].toInt())
            read++
            tail = (tail shl 8) or (one[0].toInt() and 0xFF)
            if (tail == 0x0D0A0D0A) return output.toByteArray()
        }
        throw SpeedHttpProtocolException(
            "oversizedHeaders",
            "HTTPS response headers exceeded $MAX_HEADER_BYTES bytes",
        )
    }

    private fun authority(target: HttpTarget, port: Int): String {
        val host = if (target.host.contains(':')) "[${target.host}]" else target.host
        return if (port == 443) host else "$host:$port"
    }

    private fun pathAndQuery(target: HttpTarget): String =
        target.path + (target.query?.let { "?$it" } ?: "")
}

internal object SpeedTestResult {
    fun build(
        request: SpeedTestRequest,
        download: SpeedTransferResult?,
        upload: SpeedTransferResult?,
        networkChanged: Boolean,
        failure: SpeedTestFailure? = null,
        metered: Boolean?,
        proxyHost: String?,
        proxyPort: Int?,
    ): ProbeResult {
        val proxyLabel = proxyHost?.take(253) ?: ""
        val observations = JSONObject().apply {
            put(
                "budget",
                JSONObject()
                    .put("maxBytesPerDirection", request.maxBytesPerDirection)
                    .put("durationBudgetMs", request.durationBudgetMs)
                    .put("warmupBytes", request.warmupBytes)
                    .put("timeoutMs", request.timeoutMs),
            )
            metered?.let { put("metered", it) }
            put("allowMetered", request.allowMetered)
            put("direction", request.direction.wire)
            put("singleTransfer", true)
            download?.let { put("download", it.toJson()) }
            upload?.let { put("upload", it.toJson()) }
            put("networkChanged", networkChanged)
            if (!proxyHost.isNullOrBlank()) {
                put(
                    "proxy",
                    JSONObject()
                        .put("configured", true)
                        .put("used", false)
                        .put("host", proxyLabel)
                        .put("port", proxyPort ?: -1),
                )
            }
            if (networkChanged) put("errorCode", "networkChanged")
        }
        val results = listOfNotNull(download, upload)
        val sampleAdequate = results.isNotEmpty() && results.all {
            SpeedMath.sampleAdequate(it.measuredBytes, it.measurementElapsedMs)
        }
        observations.put("sampleAdequate", sampleAdequate)

        val limitations = ArrayList<String>()
        limitations += "A single transfer is a point-in-time sample of one endpoint and path; it is not a broadband ceiling."
        limitations += "Payload byte counts are actual response-body bytes read (download) or client stream accepted bytes (upload); Content-Length is never used as a byte count."
        limitations += "Upload counts prove bytes accepted by the client TLS stream, not server receipt or persistence."
        limitations += "No cookies, Authorization headers, user files or default hosted endpoint are used."
        limitations += "Redirects are not followed; a 3xx response is reported without contacting the Location target."
        limitations += "The diagnostic uses a direct pinned TLS socket on the captured Network and does not route through an app HTTP proxy."
        if (!proxyHost.isNullOrBlank()) {
            limitations += "The captured network reports an HTTP proxy at $proxyLabel:${proxyPort ?: -1}; this direct diagnostic does not use that proxy, and proxy-only egress may fail."
        }
        if (metered == true) {
            limitations += if (request.allowMetered) {
                "The captured network is metered and the caller explicitly allowed metered transfer."
            } else {
                "The captured network is metered; this request did not allow metered transfer."
            }
        }
        if (!sampleAdequate && results.isNotEmpty()) {
            limitations += "The measured interval or byte count is too small for a stable rate; the sample is marked inadequate."
        }
        results.forEach { result ->
            if (result.status == ObservationStatus.PARTIAL) {
                limitations += "A ${result.payloadBytesMeaning} measurement stopped with ${result.completionReason}; actual transferred bytes are retained."
            }
        }
        if (failure != null) {
            observations.put("errorCode", failure.code)
            failure.message?.takeIf { it.isNotBlank() }?.let { observations.put("message", it.take(300)) }
        }

        val status: ObservationStatus
        val missing: List<String>
        if (failure != null) {
            status = failure.status
            missing = failure.missingPermissions
        } else if (networkChanged) {
            status = ObservationStatus.ERROR
            missing = emptyList()
        } else if (results.isEmpty()) {
            status = ObservationStatus.ERROR
            missing = emptyList()
            observations.put("errorCode", "noDirectionMeasured")
        } else {
            status = when {
                results.all { it.status == ObservationStatus.OK } -> ObservationStatus.OK
                results.any {
                    it.status == ObservationStatus.ERROR ||
                        it.status == ObservationStatus.TIMEOUT ||
                        it.status == ObservationStatus.UNSUPPORTED ||
                        it.status == ObservationStatus.UNAVAILABLE ||
                        it.status == ObservationStatus.PERMISSION_REQUIRED
                } -> if (results.any {
                    it.status == ObservationStatus.OK || it.status == ObservationStatus.PARTIAL
                }) {
                    ObservationStatus.PARTIAL
                } else {
                    results.first { it.status != ObservationStatus.OK }.status
                }
                else -> ObservationStatus.PARTIAL
            }
            missing = emptyList()
        }

        val target = (download ?: upload)?.endpoint
            ?: request.downloadTarget?.redacted
            ?: request.uploadTarget?.redacted
        return ProbeResult(
            status = status,
            observations = observations,
            limitations = limitations,
            target = target,
            missingPermissions = missing,
        )
    }
}
