// SPDX-License-Identifier: MPL-2.0
package com.floe.android.workspacebridge

import org.json.JSONObject

/**
 * G03-R3 (job-7e9db10b801940c2): the strict runtime-side decoder for the
 * trusted-host `runtimeWorkspaceCopies.clear` control, plus the typed result
 * builders the runtime handler returns to the host pump. Reuses ONLY the
 * frozen Core cleanup lane's payload grammar (RUNTIME_CLEANUP_HOST_CONTRACT
 * v1 — the same shape `LinuxRuntimeCleanup.swift` mints): exact key sets,
 * canonical case-SENSITIVE owner UUID echoes, positive stable targetEpoch,
 * `PrivateTasks/<conversationID>` owned shape, <=16 bounded diagnostic
 * session keys with an honest truncation flag.
 *
 * Fail-closed by construction: any malformed/extra/missing key returns null
 * (the host then delivers a typed REFUSED receipt — the obligation RETAINS;
 * a refusal is never a success). The evidence keys are diagnostics only:
 * they NEVER limit the deletion set, which is the COMPLETE proven
 * target-project scope resolved by the deterministic project mapping.
 */
data class RuntimeCleanupScope(
    /** Core-minted 32-hex request id (distinct namespace from the RuntimeWire UUID control id). */
    val requestID: String,
    val conversationID: String,
    val projectID: String,
    val targetEpoch: Long,
    val workspaceRelativePath: String,
    val provenTotal: Int,
    val evidenceSessionKeys: List<String>,
    val evidenceTruncated: Boolean,
) {
    companion object {
        const val OPERATION = "runtimeWorkspaceCopies.clear"
        const val DELETION_SET = "targetProjectScope"
        const val MAX_EVIDENCE_KEYS = 16
        private val REQUEST_ID = Regex("^[0-9a-f]{32}$")
        private val SESSION_KEY = Regex("^[0-9a-f]{32}$")
        // Canonical 8-4-4-4-12 UUID, case-insensitive SHAPE; the case itself
        // is preserved exactly (owner IDs are compared as received).
        private val UUID_TOKEN = Regex(
            "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")

        /** Exact wire control key set: the frozen Core payload grammar PLUS
         *  the host-forwarded Core-minted `requestID` (32-hex namespace,
         *  always distinct from the RuntimeWire UUID control id). */
        val CONTROL_KEYS = setOf(
            "requestID", "operation", "deletionSet", "conversationID", "projectID", "targetEpoch",
            "workspaceRelativePath", "provenTotal", "evidenceSessionKeys", "evidenceTruncated",
        )

        fun requestIDMatches(value: String): Boolean = REQUEST_ID.matches(value)
        fun uuidMatches(value: String): Boolean = UUID_TOKEN.matches(value)
        fun sessionKeyMatches(value: String): Boolean = SESSION_KEY.matches(value)

        /**
         * Strict integral parse: booleans, fractional/truncated numbers and
         * out-of-range values are refused (never coerced), mirroring
         * `WorkspaceBudgetsView.sanitize`.
         */
        private fun integer(json: JSONObject, key: String, min: Long, max: Long): Long? {
            val raw = try { json.get(key) } catch (_: Exception) { return null }
            if (raw is Boolean || raw !is Number) return null
            val value = raw.toDouble()
            if (!value.isFinite()) return null
            val converted = value.toLong()
            if (converted.toDouble() != value) return null
            return if (converted in min..max) converted else null
        }

        fun parse(json: JSONObject): RuntimeCleanupScope? {
            if (json.keys().asSequence().toSet() != CONTROL_KEYS) return null
            if (json.optString("operation") != OPERATION) return null
            if (json.optString("deletionSet") != DELETION_SET) return null
            val conversationID = json.optString("conversationID")
            val projectID = json.optString("projectID")
            if (!UUID_TOKEN.matches(conversationID) || !UUID_TOKEN.matches(projectID)) return null
            // The ORIGINAL owned shape only; no caller-chosen path spelling.
            if (json.optString("workspaceRelativePath") != "PrivateTasks/$conversationID") return null
            val requestID = json.optString("requestID")
            if (!REQUEST_ID.matches(requestID)) return null
            val targetEpoch = integer(json, "targetEpoch", 1, Long.MAX_VALUE) ?: return null
            val provenTotal = integer(json, "provenTotal", 0, 1_000_000) ?: return null
            val truncated = when (val raw = try { json.get("evidenceTruncated") } catch (_: Exception) { return null }) {
                is Boolean -> raw
                else -> return null
            }
            val keys = try { json.getJSONArray("evidenceSessionKeys") } catch (_: Exception) { return null }
            if (keys.length() > MAX_EVIDENCE_KEYS) return null
            val evidence = ArrayList<String>(keys.length())
            for (index in 0 until keys.length()) {
                val key = keys.optString(index)
                if (!SESSION_KEY.matches(key)) return null
                evidence.add(key)
            }
            if (evidence.size != keys.length()) return null
            return RuntimeCleanupScope(
                requestID = requestID, conversationID = conversationID, projectID = projectID,
                targetEpoch = targetEpoch, workspaceRelativePath = json.getString("workspaceRelativePath"),
                provenTotal = provenTotal.toInt(), evidenceSessionKeys = evidence,
                evidenceTruncated = truncated,
            )
        }
    }
}

/**
 * Typed result objects the runtime handler returns over RuntimeWire. These
 * carry the ACTUAL measured effect (counts from the real removal pass) and
 * this runtime process's executor facts — never a body echo of the request.
 * The host pump stamps the identity fields (peer UID/cert/version/binder
 * generation) from its OWN verified observation before Core `complete`.
 */
object RuntimeCleanupResults {
    fun cleared(scope: RuntimeCleanupScope, executorUid: Int, pathsRemoved: Long, bytesFreed: Long,
                proofDigest: String): JSONObject = JSONObject()
        .put("operation", RuntimeCleanupScope.OPERATION)
        .put("requestID", scope.requestID)
        .put("conversationID", scope.conversationID)
        .put("projectID", scope.projectID)
        .put("targetEpoch", scope.targetEpoch)
        .put("outcome", "cleared")
        .put("executorUid", executorUid)
        .put("pathsRemoved", pathsRemoved)
        .put("bytesFreed", bytesFreed)
        .put("executorProofDigest", proofDigest)

    fun refused(scope: RuntimeCleanupScope?, reason: String): JSONObject = JSONObject()
        .put("operation", RuntimeCleanupScope.OPERATION)
        .put("requestID", scope?.requestID ?: "")
        .put("conversationID", scope?.conversationID ?: "")
        .put("projectID", scope?.projectID ?: "")
        .put("targetEpoch", scope?.targetEpoch ?: 0)
        .put("outcome", "refused")
        .put("reason", reason.take(64))

    /** Scope echo used by the host to validate the result BEFORE any receipt. */
    fun matchesScope(result: JSONObject, scope: RuntimeCleanupScope): Boolean =
        result.optString("requestID") == scope.requestID &&
            result.optString("conversationID") == scope.conversationID &&
            result.optString("projectID") == scope.projectID &&
            result.optLong("targetEpoch", -1) == scope.targetEpoch
}
