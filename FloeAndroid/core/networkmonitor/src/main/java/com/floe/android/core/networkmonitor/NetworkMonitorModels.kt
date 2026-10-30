// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.util.UUID
import org.json.JSONObject

/** Hard product bounds; no caller can create an unbounded monitoring session. */
object NetworkMonitorLimits {
    const val DEFAULT_DURATION_MILLIS = 10 * 60 * 1_000L
    const val MIN_DURATION_MILLIS = 60 * 1_000L
    const val MAX_DURATION_MILLIS = 60 * 60 * 1_000L
    const val DEFAULT_INTERVAL_MILLIS = 30 * 1_000L
    const val MIN_INTERVAL_MILLIS = 5 * 1_000L
    const val MAX_INTERVAL_MILLIS = 5 * 60 * 1_000L
    const val MAX_OBSERVATIONS = 720
    const val MAX_RAW_RESULT_BYTES = 256 * 1024
    const val MAX_SESSION_RAW_BYTES = 1024 * 1024
    const val MAX_REPORT_JSON_BYTES = 4 * 1024 * 1024
    const val MAX_REPORT_MARKDOWN_BYTES = 512 * 1024
}

enum class NetworkMonitorProbeKind(internal val wireMethod: String) {
    STATUS("network.status"),
    PING("network.ping"),
    TCP("network.tcpProbe"),
}

/** Only status and explicitly configured ping/TCP targets are admitted. */
data class NetworkMonitorProbe(
    val kind: NetworkMonitorProbeKind,
    val host: String? = null,
    val port: Int? = null,
    val timeoutMillis: Int = 5_000,
) {
    init {
        require(timeoutMillis in 500..30_000) { "timeoutMillis must be within 500..30000" }
        when (kind) {
            NetworkMonitorProbeKind.STATUS -> {
                require(host == null && port == null) { "status takes no target" }
            }
            NetworkMonitorProbeKind.PING -> {
                requireValidMonitorHost(host)
                require(port == null) { "ping takes no port" }
            }
            NetworkMonitorProbeKind.TCP -> {
                requireValidMonitorHost(host)
                require(port in 1..65_535) { "tcp requires a valid port" }
            }
        }
    }

    internal fun requestJson(operationID: String): String {
        val arguments = JSONObject()
        if (host != null) arguments.put("host", host)
        when (kind) {
            NetworkMonitorProbeKind.STATUS -> Unit
            NetworkMonitorProbeKind.PING -> {
                arguments.put("count", 1)
                arguments.put("timeoutMs", timeoutMillis)
            }
            NetworkMonitorProbeKind.TCP -> {
                arguments.put("port", port)
                arguments.put("timeoutMs", timeoutMillis)
            }
        }
        return JSONObject()
            .put("version", 1)
            .put("operationID", operationID)
            .put("method", kind.wireMethod)
            .put("arguments", arguments)
            .toString()
    }

    companion object {
        fun status(): NetworkMonitorProbe = NetworkMonitorProbe(NetworkMonitorProbeKind.STATUS)

        fun ping(host: String, timeoutMillis: Int = 5_000): NetworkMonitorProbe =
            NetworkMonitorProbe(NetworkMonitorProbeKind.PING, host = host, timeoutMillis = timeoutMillis)

        fun tcp(host: String, port: Int, timeoutMillis: Int = 5_000): NetworkMonitorProbe =
            NetworkMonitorProbe(
                NetworkMonitorProbeKind.TCP,
                host = host,
                port = port,
                timeoutMillis = timeoutMillis,
            )
    }
}

private fun requireValidMonitorHost(host: String?) {
    require(!host.isNullOrBlank() && host.length <= 253) { "a bounded host is required" }
    require(host == host.trim()) { "host must not have surrounding whitespace" }
    require(host.none { it.isWhitespace() || it == '/' || it == '@' || it == '?' || it == '#' }) {
        "host must not contain a URL, user info or whitespace"
    }
}

data class NetworkMonitorConfig(
    val durationMillis: Long = NetworkMonitorLimits.DEFAULT_DURATION_MILLIS,
    val intervalMillis: Long = NetworkMonitorLimits.DEFAULT_INTERVAL_MILLIS,
    val probes: List<NetworkMonitorProbe> = listOf(NetworkMonitorProbe.status()),
) {
    init {
        require(durationMillis in NetworkMonitorLimits.MIN_DURATION_MILLIS..NetworkMonitorLimits.MAX_DURATION_MILLIS) {
            "durationMillis must be within one minute and one hour"
        }
        require(intervalMillis in NetworkMonitorLimits.MIN_INTERVAL_MILLIS..NetworkMonitorLimits.MAX_INTERVAL_MILLIS) {
            "intervalMillis must be within five seconds and five minutes"
        }
        require(probes.isNotEmpty() && probes.size <= NetworkMonitorProbeKind.entries.size) {
            "one to three probes are required"
        }
        require(probes.distinctBy { it.kind }.size == probes.size) { "probe methods must be unique" }
    }
}

/** Ownership is used for control/fencing, never persisted as a device identifier. */
data class NetworkMonitorOwner(
    val rootOwnerId: String,
    val taskId: String? = null,
) {
    init {
        require(rootOwnerId.isNotBlank() && rootOwnerId.length <= 128) { "rootOwnerId is required and bounded" }
        require(taskId == null || (taskId.isNotBlank() && taskId.length <= 128)) { "taskId must be bounded" }
    }
}

/** The only transport port. The App adapter delegates to PhoneNetworkService. */
interface NetworkMonitorExecutor {
    suspend fun execute(requestJson: String): String
    fun cancel(operationID: String)
}

/** Typed scalar fields replace arbitrary nested JSON before retention/reporting. */
data class NetworkMonitorFields(
    val text: Map<String, String> = emptyMap(),
    val numbers: Map<String, Double> = emptyMap(),
    val booleans: Map<String, Boolean> = emptyMap(),
) {
    val isEmpty: Boolean get() = text.isEmpty() && numbers.isEmpty() && booleans.isEmpty()

    internal fun redacted(detailed: Boolean): NetworkMonitorFields = NetworkMonitorFields(
        text = text.entries.associate { (key, value) ->
            key to NetworkMonitorRedactor.value(key, value, detailed)
        },
        numbers = numbers.filterKeys { key ->
            !NetworkMonitorRedactor.isCredentialKey(key) &&
                !NetworkMonitorRedactor.isDeviceUniqueKey(key) &&
                (detailed || !NetworkMonitorRedactor.isSensitiveKey(key))
        },
        booleans = booleans.filterKeys { key ->
            !NetworkMonitorRedactor.isCredentialKey(key) &&
                !NetworkMonitorRedactor.isDeviceUniqueKey(key) &&
                (detailed || !NetworkMonitorRedactor.isSensitiveKey(key))
        },
    )
}

data class NetworkMonitorObservation(
    val sequence: Long,
    val operationID: String,
    val method: String,
    val measuredAt: String,
    val status: String,
    val target: String?,
    val actualNetwork: NetworkMonitorFields,
    val transfers: NetworkMonitorFields,
    val details: NetworkMonitorFields,
    val limitations: List<String>,
    val missingPermissions: List<String>,
    val startedAtElapsedNanos: Long,
    val finishedAtElapsedNanos: Long,
    val rawBytes: Int,
    /** Process-local captured Android Network fence; omitted from persisted reports. */
    internal val capturedNetworkKey: String,
)

enum class NetworkMonitorPhase {
    IDLE,
    RUNNING,
    STOPPING,
    COMPLETED,
    FAILED,
}

enum class NetworkMonitorEndReason {
    USER_STOP,
    FOREGROUND_START_FAILED,
    DURATION_REACHED,
    DATA_CAP_REACHED,
    NETWORK_CHANGED,
    NETWORK_IDENTITY_UNAVAILABLE,
    TIME_BUDGET_EXHAUSTED,
    TASK_REMOVED,
    NOTIFICATION_PERMISSION_REVOKED,
    SERVICE_DESTROYED,
    EXECUTOR_FAILURE,
}

data class NetworkMonitorSessionState(
    val phase: NetworkMonitorPhase = NetworkMonitorPhase.IDLE,
    val sessionId: String? = null,
    val owner: NetworkMonitorOwner? = null,
    val startedAtEpochMillis: Long = 0L,
    val startedAtElapsedNanos: Long = 0L,
    val deadlineAtElapsedNanos: Long = 0L,
    val observationCount: Long = 0L,
    val droppedObservationCount: Long = 0L,
    val consumedRawBytes: Long = 0L,
    val retainedRawBytes: Long = 0L,
    val lastObservation: NetworkMonitorObservation? = null,
    val endReason: NetworkMonitorEndReason? = null,
) {
    val isActive: Boolean get() = phase == NetworkMonitorPhase.RUNNING || phase == NetworkMonitorPhase.STOPPING
    val isTerminal: Boolean get() = phase == NetworkMonitorPhase.COMPLETED || phase == NetworkMonitorPhase.FAILED
}

data class NetworkMonitorSessionSnapshot(
    val sessionId: String,
    val config: NetworkMonitorConfig,
    val owner: NetworkMonitorOwner,
    val startedAtEpochMillis: Long,
    val startedAtElapsedNanos: Long,
    val endedAtEpochMillis: Long?,
    val endedAtElapsedNanos: Long?,
    val deadlineAtElapsedNanos: Long,
    val observations: List<NetworkMonitorObservation>,
    val totalObservationCount: Long,
    val droppedObservationCount: Long,
    val consumedRawBytes: Long,
    val retainedRawBytes: Long,
    val endReason: NetworkMonitorEndReason?,
    val failed: Boolean,
)

data class NetworkMonitorDeviceMetadata(
    val osVersion: String,
    val appVersion: String,
) {
    init {
        require(osVersion.isNotBlank() && osVersion.length <= 128) { "osVersion is required and bounded" }
        require(appVersion.isNotBlank() && appVersion.length <= 128) { "appVersion is required and bounded" }
    }
}

data class NetworkMonitorReportDocument(
    val json: String,
    val markdown: String,
) {
    init {
        require(json.toByteArray(Charsets.UTF_8).size <= NetworkMonitorLimits.MAX_REPORT_JSON_BYTES) {
            "JSON report exceeds its bounded size"
        }
        require(markdown.toByteArray(Charsets.UTF_8).size <= NetworkMonitorLimits.MAX_REPORT_MARKDOWN_BYTES) {
            "Markdown report exceeds its bounded size"
        }
    }
}

internal fun newMonitorId(idFactory: () -> String): String {
    val value = idFactory()
    require(runCatching { UUID.fromString(value) }.isSuccess) { "monitor IDs must be UUIDs" }
    return value
}
