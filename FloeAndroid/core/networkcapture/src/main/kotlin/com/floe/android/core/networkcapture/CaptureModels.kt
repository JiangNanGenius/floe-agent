// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

import java.util.UUID

/**
 * The real owner of a capture session. Values come from the App host's
 * existing root/task/workspace authority; none of them is supplied by model
 * output. A UI-started capture may legitimately have no task/run (the same
 * honest absence the existing artifact import records), but its owner id,
 * native epoch and workspace binding are still real.
 */
data class CaptureOwner(
    val ownerId: String,
    val nativeEpoch: Long,
    val taskId: String? = null,
    val runId: String? = null,
    val workspaceId: String? = null,
    val projectId: String? = null,
    val environmentId: String? = null,
    val jobId: String? = null,
) {
    init {
        require(ownerId.isBoundedIdentity()) { "ownerId must be a bounded identity" }
        require(nativeEpoch > 0) { "nativeEpoch must be positive" }
        for ((name, value) in listOf(
            "taskId" to taskId,
            "runId" to runId,
            "workspaceId" to workspaceId,
            "projectId" to projectId,
            "environmentId" to environmentId,
            "jobId" to jobId,
        )) {
            require(value == null || value.isBoundedIdentity()) { "$name must be bounded" }
        }
    }

    val wire: Map<String, Any> get() = buildMap {
        put("ownerId", ownerId)
        put("nativeEpoch", nativeEpoch)
        taskId?.let { put("taskId", it) }
        runId?.let { put("runId", it) }
        workspaceId?.let { put("workspaceId", it) }
        projectId?.let { put("projectId", it) }
        environmentId?.let { put("environmentId", it) }
        jobId?.let { put("jobId", it) }
    }
}

private fun String.isBoundedIdentity(): Boolean =
    isNotBlank() && length <= CaptureLimits.MAX_OWNER_CHARS &&
        none { it.code < 0x20 || it.code == 0x7f }

enum class CaptureMode(val wire: String) {
    /** No-root VpnService path. Normal traffic keeps flowing through NetBare. */
    VPN("vpn"),

    /** Full-only genuine native phone capture through the root broker. */
    ROOT("root"),
}

enum class CapturePhase(val wire: String) {
    IDLE("idle"),
    CONSENT_REQUIRED("consentRequired"),
    STARTING("starting"),
    RUNNING("running"),
    STOPPING("stopping"),
    FINALIZING("finalizing"),
    COMPLETED("completed"),
    FAILED("failed"),
    UNSUPPORTED("unsupported"),
    CANCELLED("cancelled");

    val isTerminal: Boolean
        get() = this == COMPLETED || this == FAILED || this == UNSUPPORTED || this == CANCELLED
}

enum class CaptureEndReason(val wire: String) {
    USER_STOP("userStop"),
    USER_CANCELLED("userCancelled"),
    DURATION_LIMIT("durationLimit"),
    SIZE_LIMIT("sizeLimit"),
    PACKET_LIMIT("packetLimit"),
    VPN_REVOKED("vpnRevoked"),
    VPN_REPLACED("vpnReplaced"),
    PERMISSION_REVOKED("permissionRevoked"),
    SERVICE_DESTROYED("serviceDestroyed"),
    ROOT_STOP("rootStop"),
    DATA_PLANE_ERROR("dataPlaneError"),
    STOP_TIMEOUT("stopTimeout"),
    ANALYSIS_FAILED("analysisFailed"),
    HELPER_UNAVAILABLE("helperUnavailable"),
}

data class CaptureFailure(
    val code: String,
    val message: String? = null,
) {
    init {
        require(code.matches(Regex("^[A-Za-z][A-Za-z0-9_-]{0,63}$"))) { "invalid failure code" }
        require(message == null || message.length <= CaptureLimits.MAX_FAILURE_MESSAGE_CHARS) {
            "failure message too long"
        }
    }
}

data class CaptureStats(
    val capturedPackets: Long = 0,
    val capturedBytes: Long = 0,
    val writtenPackets: Long = 0,
    val writtenBytes: Long = 0,
    val droppedPackets: Long = 0,
    val droppedBytes: Long = 0,
    val truncatedPackets: Long = 0,
    val unsupportedPackets: Long = 0,
    val ipv6BypassedPackets: Long = 0,
    val forwardedPackets: Long = 0,
    val forwardedBytes: Long = 0,
) {
    init {
        require(capturedPackets >= 0 && capturedBytes >= 0) { "captured counters" }
        require(writtenPackets >= 0 && writtenBytes >= 0) { "written counters" }
        require(droppedPackets >= 0 && droppedBytes >= 0) { "dropped counters" }
        require(truncatedPackets >= 0) { "truncated counter" }
        require(unsupportedPackets >= 0) { "unsupported counter" }
        require(ipv6BypassedPackets >= 0) { "ipv6 counter" }
        require(forwardedPackets >= 0 && forwardedBytes >= 0) { "forwarded counters" }
    }
}

/** Proof that every owned resource has settled. No boolean is inferred. */
data class CaptureStopProof(
    val stopRequested: Boolean,
    val forwardersStopped: Boolean = false,
    val dataPlaneThreadStopped: Boolean = false,
    val sinkDrained: Boolean = false,
    val vpnFdClosed: Boolean = false,
    val foregroundServiceStopped: Boolean = false,
    val sinkWriterJoined: Boolean = true,
    val mode: CaptureMode = CaptureMode.VPN,
    val rootProcessExited: Boolean = false,
    val rootFileOwnerClosed: Boolean = false,
    val rootDrainProven: Boolean = false,
) {
    val isComplete: Boolean
        get() = when (mode) {
            CaptureMode.VPN -> stopRequested && forwardersStopped &&
                dataPlaneThreadStopped && sinkDrained && vpnFdClosed &&
                foregroundServiceStopped && sinkWriterJoined
            CaptureMode.ROOT -> stopRequested && rootProcessExited &&
                rootFileOwnerClosed && rootDrainProven
        }

    fun missing(): List<String> = buildList {
        if (!stopRequested) add("stopRequested")
        when (mode) {
            CaptureMode.VPN -> {
                if (!forwardersStopped) add("forwardersStopped")
                if (!dataPlaneThreadStopped) add("dataPlaneThreadStopped")
                if (!sinkDrained) add("sinkDrained")
                if (!vpnFdClosed) add("vpnFdClosed")
                if (!foregroundServiceStopped) add("foregroundServiceStopped")
                if (!sinkWriterJoined) add("sinkWriterJoined")
            }
            CaptureMode.ROOT -> {
                if (!rootProcessExited) add("rootProcessExited")
                if (!rootFileOwnerClosed) add("rootFileOwnerClosed")
                if (!rootDrainProven) add("rootDrainProven")
            }
        }
    }
}

data class CaptureState(
    val sessionId: String? = null,
    val launchId: String? = null,
    val owner: CaptureOwner? = null,
    val mode: CaptureMode? = null,
    val phase: CapturePhase = CapturePhase.IDLE,
    val stats: CaptureStats = CaptureStats(),
    val analysisId: String? = null,
    val rawCaptureId: String? = null,
    val startedAtMillis: Long? = null,
    val endedAtMillis: Long? = null,
    val stopRequested: Boolean = false,
    val endReason: CaptureEndReason? = null,
    val failure: CaptureFailure? = null,
    val limitations: List<String> = emptyList(),
    val ipv6Bypass: Boolean = mode == CaptureMode.VPN,
    // Capture preserves plaintext protocols too; TLS is never decrypted.
    val encryptedTrafficOnly: Boolean = false,
) {
    init {
        require(limitations.size <= CaptureLimits.MAX_LIMITATIONS) { "too many limitations" }
        require(limitations.all { it.length <= CaptureLimits.MAX_LIMITATION_CHARS }) {
            "limitation too long"
        }
        require(sessionId == null || runCatching { UUID.fromString(sessionId) }.isSuccess) {
            "sessionId must be a UUID"
        }
    }

    val canStart: Boolean get() = phase == CapturePhase.IDLE
    val isActive: Boolean get() = phase == CapturePhase.STARTING || phase == CapturePhase.RUNNING ||
        phase == CapturePhase.STOPPING || phase == CapturePhase.FINALIZING

    companion object {
        fun unsupported(reason: CaptureFailure, mode: CaptureMode? = null): CaptureState =
            CaptureState(mode = mode, phase = CapturePhase.UNSUPPORTED, failure = reason)
    }
}

/** One start request after host validation; limits are already clamped. */
data class CaptureConfig(
    val owner: CaptureOwner,
    val mode: CaptureMode,
    val detailed: Boolean,
    val maxDurationMillis: Long,
    val maxBytes: Long,
    val maxPackets: Long,
    val mtu: Int = CaptureLimits.DEFAULT_MTU,
    val vpnAddress: String = CaptureLimits.DEFAULT_VPN_ADDRESS,
    val vpnAddressPrefix: Int = CaptureLimits.VPN_ADDRESS_PREFIX,
    val sessionName: String = "Floe capture",
    val agentReadable: Boolean = false,
) {
    init {
        val hardDuration = if (mode == CaptureMode.ROOT) {
            CaptureLimits.MAX_ROOT_DURATION_MILLIS
        } else {
            CaptureLimits.MAX_DURATION_MILLIS
        }
        val hardBytes = if (mode == CaptureMode.ROOT) {
            CaptureLimits.MAX_ROOT_BYTES
        } else {
            CaptureLimits.MAX_BYTES
        }
        require(maxDurationMillis in 1..hardDuration) { "duration out of bounds" }
        require(maxBytes in 1..hardBytes) { "bytes out of bounds" }
        require(maxPackets in 1..CaptureLimits.MAX_PACKETS) { "packets out of bounds" }
        require(mtu in CaptureLimits.MIN_MTU..CaptureLimits.MAX_MTU) { "mtu out of bounds" }
        require(vpnAddressPrefix == 32 && isIpv4VpnAddressLiteral(vpnAddress)) { "vpn address" }
        require(sessionName.isNotBlank() && sessionName.length <= 64) { "session name" }
        require(!agentReadable) { "live capture is never granted to the Agent implicitly" }
    }
}

private fun isIpv4VpnAddressLiteral(value: String): Boolean {
    val parts = value.split('.')
    if (parts.size != 4) return false
    return parts.all { part ->
        part.isNotEmpty() && part.all(Char::isDigit) &&
            part.toIntOrNull()?.let { it in 0..255 } == true
    }
}
