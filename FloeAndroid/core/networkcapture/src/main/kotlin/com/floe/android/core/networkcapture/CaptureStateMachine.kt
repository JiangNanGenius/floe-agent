// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

/**
 * Pure transition authority for one live capture.
 *
 * A stop request is deliberately not a terminal state: [complete] is valid
 * only after the host supplies [CaptureStopProof] proving the data plane,
 * forwarders, sink, VPN fd and foreground service all settled. Cancelling
 * before start is terminal without pretending a capture happened.
 */
class CaptureStateMachine {

    fun begin(
        current: CaptureState,
        owner: CaptureOwner,
        mode: CaptureMode,
        sessionId: String,
        launchId: String,
        requiresConsent: Boolean,
    ): CaptureState {
        require(current.phase == CapturePhase.IDLE || current.phase.isTerminal) {
            "capture already active"
        }
        require(mode in CaptureMode.entries) { "mode" }
        return CaptureState(
            sessionId = sessionId,
            launchId = launchId,
            owner = owner,
            mode = mode,
            phase = if (requiresConsent) CapturePhase.CONSENT_REQUIRED else CapturePhase.STARTING,
            ipv6Bypass = true,
            encryptedTrafficOnly = true,
        )
    }

    fun markStarting(current: CaptureState): CaptureState {
        require(current.phase == CapturePhase.CONSENT_REQUIRED) { "consent not required" }
        return current.copy(phase = CapturePhase.STARTING)
    }

    fun markRunning(current: CaptureState, startedAtMillis: Long): CaptureState {
        require(current.phase == CapturePhase.STARTING) { "not starting" }
        require(startedAtMillis > 0) { "startedAtMillis" }
        return current.copy(phase = CapturePhase.RUNNING, startedAtMillis = startedAtMillis)
    }

    fun updateStats(current: CaptureState, stats: CaptureStats): CaptureState {
        require(current.phase == CapturePhase.RUNNING || current.phase == CapturePhase.STOPPING) {
            "capture is not collecting"
        }
        require(stats.capturedPackets >= current.stats.capturedPackets) { "packet counter regressed" }
        require(stats.capturedBytes >= current.stats.capturedBytes) { "byte counter regressed" }
        require(stats.writtenPackets >= current.stats.writtenPackets) { "written counter regressed" }
        return current.copy(stats = stats)
    }

    /**
     * Idempotent stop request. The first real reason is retained; a later
     * service-destroyed callback cannot overwrite a user stop or revoke.
     */
    fun requestStop(
        current: CaptureState,
        reason: CaptureEndReason,
        atMillis: Long,
    ): CaptureState {
        if (current.phase.isTerminal) return current
        if (current.phase == CapturePhase.CONSENT_REQUIRED ||
            current.phase == CapturePhase.STARTING
        ) {
            if (reason == CaptureEndReason.USER_CANCELLED ||
                reason == CaptureEndReason.USER_STOP ||
                reason == CaptureEndReason.ROOT_STOP
            ) {
                return current.copy(
                    phase = CapturePhase.CANCELLED,
                    stopRequested = true,
                    endReason = reason,
                    endedAtMillis = atMillis,
                )
            }
        }
        if (current.phase == CapturePhase.IDLE) {
            return current.copy(
                phase = CapturePhase.CANCELLED,
                stopRequested = true,
                endReason = reason,
                endedAtMillis = atMillis,
            )
        }
        require(current.phase == CapturePhase.RUNNING || current.phase == CapturePhase.STOPPING) {
            "capture cannot be stopped from ${current.phase.wire}"
        }
        return current.copy(
            phase = CapturePhase.STOPPING,
            stopRequested = true,
            endReason = current.endReason ?: reason,
        )
    }

    fun markFinalizing(current: CaptureState): CaptureState {
        require(current.phase == CapturePhase.STOPPING) { "stop not requested" }
        require(current.stopRequested) { "stop not requested" }
        return current.copy(phase = CapturePhase.FINALIZING)
    }

    fun complete(
        current: CaptureState,
        analysisId: String?,
        rawCaptureId: String,
        stats: CaptureStats,
        limitations: List<String>,
        proof: CaptureStopProof,
        atMillis: Long,
    ): CaptureState {
        require(current.phase == CapturePhase.FINALIZING) { "not finalizing" }
        require(current.stopRequested) { "stop not requested" }
        require(proof.isComplete) { "capture resources did not settle: ${proof.missing()}" }
        require(rawCaptureId.isNotBlank()) { "raw capture id" }
        require(analysisId == null || runCatching {
            java.util.UUID.fromString(analysisId)
        }.isSuccess) { "analysis id" }
        require(limitations.size <= CaptureLimits.MAX_LIMITATIONS) { "limitations" }
        return current.copy(
            phase = CapturePhase.COMPLETED,
            stats = stats,
            analysisId = analysisId,
            rawCaptureId = rawCaptureId,
            limitations = limitations,
            endedAtMillis = atMillis,
        )
    }

    fun fail(
        current: CaptureState,
        failure: CaptureFailure,
        reason: CaptureEndReason?,
        stats: CaptureStats? = null,
        limitations: List<String>? = null,
        atMillis: Long,
    ): CaptureState {
        if (current.phase.isTerminal) return current
        return current.copy(
            phase = CapturePhase.FAILED,
            failure = failure,
            endReason = current.endReason ?: reason,
            stats = stats ?: current.stats,
            limitations = limitations ?: current.limitations,
            endedAtMillis = atMillis,
        )
    }

    /**
     * The host must call this before publishing a completed capture. Keeping
     * it explicit makes a testable proof a precondition, not a log line.
     */
    fun requireSettled(proof: CaptureStopProof) {
        require(proof.isComplete) { "capture resources did not settle: ${proof.missing()}" }
    }
}
