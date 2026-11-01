// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.networkcapture

/**
 * Full-only root capture capability projection. It is deliberately a typed
 * closed set: no arbitrary executable path, interface expression or command
 * text can cross this boundary.
 */
enum class RootCaptureHelper(val id: String) {
    /** A pinned tcpdump built for arm64 and installed by Main/user. */
    TCPDUMP("tcpdump-v1"),
}

data class RootCaptureAvailability(
    val available: Boolean,
    val code: String? = null,
    val message: String? = null,
    val helperId: String? = null,
    val helperPath: String? = null,
    val helperSha256: String? = null,
    val effectiveUid: Int? = null,
) {
    init {
        require(available == (code == null)) { "available/code must agree" }
        require(message == null || message.length <= CaptureLimits.MAX_FAILURE_MESSAGE_CHARS)
        require(helperId == null || helperId.length <= 64)
        require(helperPath == null || (helperPath.startsWith("/") && helperPath.length <= 256))
        require(helperSha256 == null || helperSha256.matches(Regex("^[0-9a-f]{64}$")))
        require(effectiveUid == null || effectiveUid >= 0)
    }

    companion object {
        fun unavailable(code: String, message: String? = null): RootCaptureAvailability =
            RootCaptureAvailability(available = false, code = code, message = message)

        fun playBuild(): RootCaptureAvailability = unavailable(
            "playBuild",
            "Root capture is available only in the Full distribution.",
        )
    }
}

data class RootCaptureRequest(
    val owner: CaptureOwner,
    val config: CaptureConfig,
    val helper: RootCaptureHelper = RootCaptureHelper.TCPDUMP,
    val interfaceName: String = "any",
) {
    init {
        require(config.mode == CaptureMode.ROOT) { "root request requires root mode" }
        require(interfaceName == "any" || interfaceName.matches(Regex("^[A-Za-z0-9_.:-]{1,32}$"))) {
            "interface name"
        }
    }
}

data class RootCaptureProgress(
    val bytes: Long,
    val packets: Long,
    val malformed: Boolean,
    val endReason: CaptureEndReason? = null,
    /** True only when the helper process exited and every byte owner closed. */
    val drainProven: Boolean = false,
)

sealed interface RootCaptureStart {
    data object Started : RootCaptureStart

    /** The helper reached a real end and the client/process/file owners settled. */
    data class Completed(val progress: RootCaptureProgress) : RootCaptureStart
    data class Unavailable(val code: String) : RootCaptureStart
    data class Failed(val code: String) : RootCaptureStart
}

/**
 * App host contract implemented only by the Full source set. The main source
 * set loads it by class name and otherwise returns [RootCaptureAvailability.playBuild].
 */
interface RootCaptureBackend {
    fun availability(): RootCaptureAvailability
    suspend fun start(
        request: RootCaptureRequest,
        onChunk: (ByteArray, Int, Int) -> Unit,
        onProgress: (RootCaptureProgress) -> Unit,
    ): RootCaptureStart
    suspend fun stop(): RootCaptureProgress
    fun close()
}
