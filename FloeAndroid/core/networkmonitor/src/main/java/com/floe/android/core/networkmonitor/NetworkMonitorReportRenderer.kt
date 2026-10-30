// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkmonitor

import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/** Serialization has no transport or resolver dependency; supplied observations are the only input. */
object NetworkMonitorReportRenderer {
    fun render(
        snapshot: NetworkMonitorSessionSnapshot,
        detailed: Boolean,
        deviceMetadata: NetworkMonitorDeviceMetadata,
    ): NetworkMonitorReportDocument {
        val root = JSONObject()
            .put("schema", "floe.network-monitor-report.v1")
            .put("privacy", JSONObject()
                .put("mode", if (detailed) "detailed" else "redacted")
                .put("disclosure", if (detailed) {
                    "Explicitly requested sensitive network identifiers are included; credentials, URL secrets and device-unique identifiers remain redacted."
                } else {
                    "Network identifiers, private addresses, URL secrets, localhost and service identifiers are redacted."
                }))
            .put("device", JSONObject()
                .put("osVersion", deviceMetadata.osVersion)
                .put("appVersion", deviceMetadata.appVersion))
            .put("session", JSONObject()
                .put("sessionId", snapshot.sessionId)
                .put("complete", snapshot.endedAtElapsedNanos != null)
                .put("failed", snapshot.failed)
                .put("endReason", snapshot.endReason?.name)
                .put("startedAt", Instant.ofEpochMilli(snapshot.startedAtEpochMillis).toString())
                .put("endedAt", snapshot.endedAtEpochMillis?.let(Instant::ofEpochMilli)?.toString())
                .put("configuredDurationMs", snapshot.config.durationMillis)
                .put("configuredIntervalMs", snapshot.config.intervalMillis)
                .put("probeMethods", JSONArray().apply {
                    snapshot.config.probes.forEach { put(it.kind.wireMethod) }
                })
                .put("totalObservationCount", snapshot.totalObservationCount)
                .put("retainedObservationCount", snapshot.observations.size)
                .put("droppedObservationCount", snapshot.droppedObservationCount)
                .put("consumedRawBytes", snapshot.consumedRawBytes)
                .put("retainedRawBytes", snapshot.retainedRawBytes)
                .put("limits", JSONObject()
                    .put("maxDurationMs", NetworkMonitorLimits.MAX_DURATION_MILLIS)
                    .put("maxRetainedObservations", NetworkMonitorLimits.MAX_OBSERVATIONS)
                    .put("maxSessionRawBytes", NetworkMonitorLimits.MAX_SESSION_RAW_BYTES)))
            .put("observations", JSONArray().apply {
                snapshot.observations.forEach { observation -> put(renderObservation(observation, detailed)) }
            })
        val json = root.toString(2)
        val markdown = renderMarkdown(snapshot, detailed, deviceMetadata)
        return NetworkMonitorReportDocument(json, markdown)
    }

    private fun renderObservation(observation: NetworkMonitorObservation, detailed: Boolean): JSONObject =
        JSONObject()
            .put("sequence", observation.sequence)
            .put("operationID", observation.operationID)
            .put("method", observation.method)
            .put("measuredAt", observation.measuredAt)
            .put("status", observation.status)
            .put("target", observation.target?.let { NetworkMonitorRedactor.value("target", it, detailed) })
            .put("time", JSONObject()
                .put("startedAtElapsedNanos", observation.startedAtElapsedNanos)
                .put("finishedAtElapsedNanos", observation.finishedAtElapsedNanos)
                .put("durationMs", (observation.finishedAtElapsedNanos - observation.startedAtElapsedNanos) / 1_000_000L))
            .put("actualNetwork", renderFields(observation.actualNetwork.redacted(detailed)))
            .put("transfers", renderFields(observation.transfers.redacted(detailed)))
            .put("details", renderFields(observation.details.redacted(detailed)))
            .put("limitations", JSONArray().apply {
                observation.limitations.forEach {
                    put(NetworkMonitorRedactor.value("message", it, detailed))
                }
            })
            .put("missingPermissions", JSONArray().apply {
                observation.missingPermissions.forEach {
                    put(NetworkMonitorRedactor.value("permission", it, detailed))
                }
            })
            .put("rawResultBytes", observation.rawBytes)

    private fun renderFields(fields: NetworkMonitorFields): JSONObject = JSONObject()
        .put("text", JSONObject().apply { fields.text.forEach { (key, value) -> put(key, value) } })
        .put("numbers", JSONObject().apply { fields.numbers.forEach { (key, value) -> put(key, value) } })
        .put("booleans", JSONObject().apply { fields.booleans.forEach { (key, value) -> put(key, value) } })

    private fun renderMarkdown(
        snapshot: NetworkMonitorSessionSnapshot,
        detailed: Boolean,
        metadata: NetworkMonitorDeviceMetadata,
    ): String = buildString {
        appendLine("# Floe network monitoring report")
        appendLine()
        appendLine(if (detailed) {
            "**Privacy:** Detailed report explicitly requested by the user. Sensitive network identifiers may appear; credentials, URL secrets and device-unique identifiers remain redacted."
        } else {
            "**Privacy:** Redacted report. Network identifiers, private addresses, URL secrets, localhost and service identifiers are removed."
        })
        appendLine()
        appendLine("- Session: `${snapshot.sessionId}`")
        appendLine("- Started: ${Instant.ofEpochMilli(snapshot.startedAtEpochMillis)}")
        appendLine("- Ended: ${snapshot.endedAtEpochMillis?.let { Instant.ofEpochMilli(it).toString() } ?: "still running"}")
        appendLine("- End reason: ${snapshot.endReason?.name ?: "not ended"}")
        appendLine("- OS / app: ${metadata.osVersion} / ${metadata.appVersion}")
        appendLine("- Observations: ${snapshot.totalObservationCount} total, ${snapshot.observations.size} retained, ${snapshot.droppedObservationCount} evicted by the bounded ring")
        appendLine("- Raw input accounting: ${snapshot.consumedRawBytes} bytes consumed, ${snapshot.retainedRawBytes} bytes represented by retained observations")
        appendLine()
        appendLine("| # | Measured at | Method | Status | Network available | Duration ms |" + if (detailed) " Target |" else "")
        appendLine("|---:|---|---|---|---|---:|" + if (detailed) "---|" else "")
        snapshot.observations.forEach { observation ->
            val available = observation.actualNetwork.booleans["available"]?.toString() ?: "unknown"
            val duration = (observation.finishedAtElapsedNanos - observation.startedAtElapsedNanos) / 1_000_000L
            append("| ${observation.sequence} | ${observation.measuredAt.markdownCell()} | ${observation.method.markdownCell()} | ${observation.status.markdownCell()} | $available | $duration |")
            if (detailed) {
                val target = observation.target?.let { NetworkMonitorRedactor.value("target", it, true) } ?: ""
                append(" ${target.markdownCell()} |")
            }
            appendLine()
        }
        val limits = snapshot.observations.flatMap { it.limitations }.distinct()
        if (limits.isNotEmpty()) {
            appendLine()
            appendLine("## Measured limitations")
            limits.forEach { limitation ->
                appendLine("- ${NetworkMonitorRedactor.value("message", limitation, detailed).markdownCell()}")
            }
        }
        appendLine()
        appendLine("Failed, timed-out, cancelled and permission-required observations are retained with their actual status; no missing measurement is represented as available.")
    }

    private fun String.markdownCell(): String = replace("|", "\\|").replace('\n', ' ').replace('\r', ' ')
}
