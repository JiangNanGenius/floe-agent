// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.util.LinkedHashSet
import org.json.JSONObject

/** Renders the frozen NetworkObservationV1 envelope and enforces its bounds. */
internal object NetworkObservationJson {
    fun envelope(
        operationID: String,
        methodWire: String,
        status: ObservationStatus,
        measuredAt: String,
        snapshot: NetworkSnapshot?,
        target: String?,
        observations: JSONObject?,
        limitations: List<String>,
        cacheAgeMs: Long?,
        missingPermissions: List<String>,
    ): String {
        val root = JSONObject()
        root.put("version", NetworkLimits.VERSION)
        root.put("operationID", operationID)
        root.put("method", methodWire)
        root.put("source", "phone")
        root.put("status", status.wire)
        root.put("measuredAt", measuredAt)
        if (cacheAgeMs != null && cacheAgeMs >= 0) root.put("cacheAgeMs", cacheAgeMs)
        root.put("network", snapshot?.toJson() ?: JSONObject().put("available", false))
        if (!target.isNullOrEmpty()) root.put("target", target)
        root.put("observations", observations ?: JSONObject())
        // The frozen result carries both the captured-network limitations
        // (e.g. redacted Wi-Fi identifiers) and the operation's own limits.
        // The service normally pre-merges them; merging here as well keeps
        // direct envelope callers consistent and sanitizeLimitations()
        // removes the duplicate text.
        val boundedLimitations = sanitizeLimitations(
            snapshot?.limitations.orEmpty() + limitations,
        )
        if (boundedLimitations.isNotEmpty()) {
            root.put("limitations", jsonArray(boundedLimitations))
        }
        val boundedMissing = missingPermissions
            .asSequence()
            .filter { it.isNotBlank() }
            .distinct()
            .take(16)
            .toList()
        if (boundedMissing.isNotEmpty()) {
            root.put("missingPermissions", jsonArray(boundedMissing))
        }
        val rendered = root.toString()
        if (rendered.toByteArray(Charsets.UTF_8).size <= NetworkLimits.MAX_OUTPUT_BYTES) return rendered

        val truncated = JSONObject()
        truncated.put("version", NetworkLimits.VERSION)
        truncated.put("operationID", operationID)
        truncated.put("method", methodWire)
        truncated.put("source", "phone")
        truncated.put("status", status.wire)
        truncated.put("measuredAt", measuredAt)
        truncated.put("network", snapshot?.toJson() ?: JSONObject().put("available", false))
        truncated.put(
            "observations",
            JSONObject()
                .put("truncated", true)
                .put("reason", "outputLimit")
                .put("limitBytes", NetworkLimits.MAX_OUTPUT_BYTES),
        )
        if (!target.isNullOrEmpty()) truncated.put("target", target)
        val finalLimitations = (boundedLimitations + "Result truncated to the 256 KiB output limit.")
            .distinct()
            .take(NetworkLimits.MAX_LIMITATIONS)
        truncated.put("limitations", jsonArray(finalLimitations))
        if (boundedMissing.isNotEmpty()) truncated.put("missingPermissions", jsonArray(boundedMissing))
        return truncated.toString()
    }

    fun errorEnvelope(
        operationID: String?,
        methodWire: String?,
        status: ObservationStatus,
        measuredAt: String,
        code: String,
        message: String?,
        snapshot: NetworkSnapshot? = null,
    ): String = envelope(
        operationID = operationID.orEmpty(),
        methodWire = methodWire.orEmpty(),
        status = status,
        measuredAt = measuredAt,
        snapshot = snapshot,
        target = null,
        observations = JSONObject().apply {
            put("errorCode", code)
            message?.takeIf { it.isNotBlank() }?.let { put("message", it.take(300)) }
        },
        limitations = listOf("The request could not be completed."),
        cacheAgeMs = null,
        missingPermissions = emptyList(),
    )

    fun permissionEnvelope(
        request: ParsedRequest,
        measuredAt: String,
        snapshot: NetworkSnapshot?,
        missingPermissions: List<String>,
    ): String = envelope(
        operationID = request.operationID,
        methodWire = request.method.wire,
        status = ObservationStatus.PERMISSION_REQUIRED,
        measuredAt = measuredAt,
        snapshot = snapshot,
        target = request.target,
        observations = JSONObject().put("requiredFor", request.method.wire),
        limitations = snapshot?.limitations.orEmpty(),
        cacheAgeMs = null,
        missingPermissions = missingPermissions,
    )

    private fun sanitizeLimitations(values: List<String>): List<String> {
        val set = LinkedHashSet<String>()
        values.forEach { value ->
            val text = value.replace('\n', ' ').replace('\r', ' ').trim()
            if (text.isNotEmpty()) set += text.take(NetworkLimits.MAX_LIMITATION_CHARS)
        }
        return set.take(NetworkLimits.MAX_LIMITATIONS)
    }
}
