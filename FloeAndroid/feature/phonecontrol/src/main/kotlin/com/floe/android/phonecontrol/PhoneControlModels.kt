// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import java.util.UUID

/**
 * Hard bounds for one phone-control exchange. These are presentation/runtime
 * limits, not authorization: every operation still asks the host's live grant
 * authority and every node reference is invalidated by a new page/fence
 * generation or by the observation TTL.
 */
object PhoneControlLimits {
    const val MAX_NODES = 400
    const val DEFAULT_NODES = 250
    const val MAX_DEPTH = 32
    const val DEFAULT_DEPTH = 20
    const val MAX_FIELD_CHARS = 2_000
    const val DEFAULT_TEXT_BUDGET_CHARS = 24_000
    const val MAX_TEXT_BUDGET_CHARS = 64_000
    const val MAX_SET_TEXT_CHARS = 2_000
    const val MAX_PACKAGE_CHARS = 255
    const val MAX_TARGET_PACKAGES = 64
    const val OBSERVATION_TTL_MS = 30_000L
    const val SETTLE_MIN_MS = 250L
    const val SETTLE_QUIET_MS = 120L
    const val SETTLE_TIMEOUT_MS = 1_500L
    const val GESTURE_TIMEOUT_MS = 3_000L
    const val ACTION_TIMEOUT_MS = 8_000L
    const val SCREENSHOT_TIMEOUT_MS = 6_000L
    const val DEFAULT_SCREENSHOT_MAX_BYTES = 1_500_000
    const val MAX_SCREENSHOT_BYTES = 6_000_000
    const val DEFAULT_SCREENSHOT_DIMENSION = 1_600
    const val MAX_SCREENSHOT_DIMENSION = 2_048
    const val MIN_SCREENSHOT_DIMENSION = 320
    const val DEFAULT_SCREENSHOT_QUALITY = 75
    const val MIN_SCREENSHOT_QUALITY = 25
    const val MIN_SWIPE_PX = 48
}

/**
 * The exact task (conversation) and run identities supplied by the actual host
 * ToolContext. Android phone control has no canonical environment/job role, so
 * this deliberately does not require the wider shared ExecutionOwner/
 * OperationContext or a fabricated environment/job UUID.
 */
data class PhoneControlOwner(
    val taskID: UUID,
    val runID: UUID,
)

/**
 * Host-supplied operation identity. [epoch], [generation], [grantID] and
 * [callID] come from the live ToolContext/approval state, never from model
 * output. [allowedPackages] is the caller's requested scope. None of these
 * values authorize an action by itself: the [PhoneControlGrant] returned from
 * the live authority callback is authoritative.
 */
data class PhoneControlPrincipal(
    val owner: PhoneControlOwner,
    val epoch: Long,
    val allowedPackages: Set<String>,
    /** Defaults to [epoch]; the host may supply a distinct live-grant counter. */
    val generation: Long = epoch,
    val grantID: UUID? = null,
    val callID: String? = null,
)

/**
 * The authority's current answer for one operation. The owner/epoch/generation
 * must exactly match the principal; [allowedPackages] can only narrow the
 * caller's requested scope. Returning `null` from the authority revokes.
 */
data class PhoneControlGrant(
    val owner: PhoneControlOwner,
    val epoch: Long,
    val allowedPackages: Set<String>,
    val allowGlobalNavigation: Boolean,
    /**
     * Host policy after an explicit whole-screen/window disclosure. There is
     * no default screen-capture permission; false refuses every screenshot.
     */
    val allowScreenshot: Boolean,
    /** Defaults to [epoch]; must equal the principal's generation. */
    val generation: Long = epoch,
    val grantID: UUID? = null,
)

data class PhoneControlObserveRequest(
    val maxNodes: Int = PhoneControlLimits.DEFAULT_NODES,
    val maxDepth: Int = PhoneControlLimits.DEFAULT_DEPTH,
    val includeInvisible: Boolean = false,
    val textBudgetChars: Int = PhoneControlLimits.DEFAULT_TEXT_BUDGET_CHARS,
) {
    fun normalized(): PhoneControlObserveRequest = copy(
        maxNodes = maxNodes.coerceIn(1, PhoneControlLimits.MAX_NODES),
        maxDepth = maxDepth.coerceIn(0, PhoneControlLimits.MAX_DEPTH),
        textBudgetChars = textBudgetChars.coerceIn(0, PhoneControlLimits.MAX_TEXT_BUDGET_CHARS),
    )
}

data class PhoneControlScreenshotRequest(
    val maxBytes: Int = PhoneControlLimits.DEFAULT_SCREENSHOT_MAX_BYTES,
    val maxDimension: Int = PhoneControlLimits.DEFAULT_SCREENSHOT_DIMENSION,
    val quality: Int = PhoneControlLimits.DEFAULT_SCREENSHOT_QUALITY,
) {
    fun normalized(): PhoneControlScreenshotRequest = copy(
        maxBytes = maxBytes.coerceIn(32_768, PhoneControlLimits.MAX_SCREENSHOT_BYTES),
        maxDimension = maxDimension.coerceIn(
            PhoneControlLimits.MIN_SCREENSHOT_DIMENSION,
            PhoneControlLimits.MAX_SCREENSHOT_DIMENSION,
        ),
        quality = quality.coerceIn(PhoneControlLimits.MIN_SCREENSHOT_QUALITY, 90),
    )
}

/** Screen coordinates in pixels, captured from the observed layout. */
data class PhoneControlBounds(
    val left: Int,
    val top: Int,
    val right: Int,
    val bottom: Int,
) {
    val width: Int get() = (right - left).coerceAtLeast(0)
    val height: Int get() = (bottom - top).coerceAtLeast(0)
    val isEmpty: Boolean get() = width <= 0 || height <= 0
    fun contains(x: Int, y: Int): Boolean = x in left until right && y in top until bottom
}

data class PhoneControlNode(
    val ref: String,
    val parentRef: String?,
    val depth: Int,
    val className: String,
    val packageName: String?,
    val viewId: String?,
    val text: String?,
    val contentDescription: String?,
    val hintText: String?,
    val bounds: PhoneControlBounds,
    val visible: Boolean,
    val clickable: Boolean,
    val editable: Boolean,
    val scrollable: Boolean,
    val enabled: Boolean,
    val selected: Boolean,
    val checkable: Boolean,
    val checked: Boolean,
    /** Framework `isPassword` flag. Always paired with redacted text. */
    val password: Boolean,
    /** True when any text field was withheld/truncated for privacy or bounds. */
    val redacted: Boolean,
    /** True when one of this node's text fields was cut by the character cap. */
    val truncated: Boolean,
) {
    /** Never dump observed text into a diagnostic/log line. */
    override fun toString(): String =
        "PhoneControlNode(ref=$ref, class=$className, viewId=$viewId, bounds=$bounds, " +
            "password=$password, redacted=$redacted)"
}

enum class PhoneControlScreenshotSupport { NONE, DISPLAY, WINDOW }

/**
 * One bounded, ephemeral observation. [observationId], [fenceGeneration] and
 * [pageGeneration] must still match when an action is dispatched; the node
 * references are not durable authorization and expire after [expiresAtElapsedRealtimeMillis].
 */
data class PhoneControlObservation(
    val observationId: String,
    val owner: PhoneControlOwner,
    val fenceGeneration: Long,
    val pageGeneration: Long,
    val capturedAtElapsedRealtimeMillis: Long,
    val expiresAtElapsedRealtimeMillis: Long,
    val packageName: String?,
    val windowId: Int,
    val windowType: Int?,
    val windowTitle: String?,
    val displayId: Int,
    val rootClassName: String?,
    val sensitiveWindow: Boolean,
    val screenshotSupport: PhoneControlScreenshotSupport,
    val nodes: List<PhoneControlNode>,
    val truncated: Boolean,
    val maxDepthReached: Boolean,
    /**
     * True only for the zero-node Floe metadata observation. Such a record may
     * authorize only Back/Home or a Launch to an already-authorized non-Floe
     * package; it never carries node refs, text or screenshot permission.
     */
    val navigationOnly: Boolean = false,
) {
    /** Summary only; use PhoneControlJson for an explicit structured payload. */
    override fun toString(): String =
        "PhoneControlObservation(id=$observationId, package=$packageName, window=$windowId, " +
            "nodeCount=${nodes.size}, sensitive=$sensitiveWindow, " +
            "navigationOnly=$navigationOnly)"
}

sealed interface PhoneControlAction {
    val wireName: String

    data class Click(val nodeRef: String) : PhoneControlAction {
        override val wireName: String get() = "click"
    }

    /** Never logged or echoed; [toString] intentionally hides the payload. */
    class SetText(val nodeRef: String, val text: String) : PhoneControlAction {
        override val wireName: String get() = "setText"
        override fun toString(): String =
            "SetText(nodeRef=$nodeRef, text=<redacted>, chars=${text.length})"
    }

    data class Scroll(
        val nodeRef: String,
        val direction: PhoneControlScrollDirection,
    ) : PhoneControlAction {
        override val wireName: String get() = "scroll"
    }

    /**
     * A coordinate swipe whose path is derived only from the explicit bounds
     * of an observed node. Direction names the finger movement, not content.
     */
    data class Swipe(
        val nodeRef: String,
        val direction: PhoneControlSwipeDirection,
    ) : PhoneControlAction {
        override val wireName: String get() = "swipe"
    }

    data object Back : PhoneControlAction {
        override val wireName: String get() = "back"
    }

    data object Home : PhoneControlAction {
        override val wireName: String get() = "home"
    }

    data class Launch(val packageName: String) : PhoneControlAction {
        override val wireName: String get() = "launch"
    }
}

enum class PhoneControlScrollDirection { FORWARD, BACKWARD }
enum class PhoneControlSwipeDirection { UP, DOWN, LEFT, RIGHT }

enum class PhoneControlDispatch { NOT_DISPATCHED, ACCEPTED, REJECTED, PARTIAL, UNKNOWN }

/**
 * Honest action receipt: framework acceptance and a fresh observation, never
 * a claim that the app performed the user's intended semantic operation.
 */
data class PhoneControlActionResult(
    val action: String,
    val dispatch: PhoneControlDispatch,
    val gestureCompleted: Boolean?,
    val observation: PhoneControlObservation?,
    val screenChanged: Boolean?,
    val note: String?,
)

/**
 * In-memory JPEG bytes. The App host must commit them to its authorized
 * `VNCArtifacts/` artifact root (or equivalent bounded artifact egress),
 * compute SHA-256 and return metadata. They are never serialized inline as
 * JSON, written to a log, or retained by this module.
 */
class PhoneControlScreenshot(
    val bytes: ByteArray,
    val mimeType: String,
    val width: Int,
    val height: Int,
    val capturedAtElapsedRealtimeMillis: Long,
    val windowId: Int?,
) {
    val byteCount: Int get() = bytes.size
}

enum class PhoneControlDenial {
    STOPPED,
    TAKEN_OVER,
    USER_TOUCH,
    DEVICE_LOCKED,
    SERVICE_REVOKED,
    SERVICE_DISCONNECTED,
    CLIENT_CLOSED,
    FOREIGN_RUN,
    AUTHORIZATION_DENIED,
    AUTHORIZATION_STALE,
    TARGET_PACKAGE_NOT_ALLOWED,
    FOREGROUND_CHANGED,
    WINDOW_CHANGED,
    STALE_OBSERVATION,
    OBSERVATION_EXPIRED,
    NODE_UNAVAILABLE,
    NODE_NOT_CLICKABLE,
    NODE_NOT_EDITABLE,
    NODE_NOT_SCROLLABLE,
    SENSITIVE_FIELD,
    PROTECTED_WINDOW,
    INVALID_ARGUMENT,
    OPERATION_IN_FLIGHT,
}

enum class PhoneControlUnavailable {
    SERVICE_NOT_CONNECTED,
    SERVICE_NOT_ENABLED,
    SCREENSHOT_UNSUPPORTED,
    WINDOW_SCREENSHOT_UNSUPPORTED,
    GESTURE_UNSUPPORTED,
    LAUNCH_TARGET_UNAVAILABLE,
}

enum class PhoneControlFailure {
    OBSERVATION_FAILED,
    ACTION_REJECTED,
    GESTURE_NOT_STARTED,
    GESTURE_CANCELLED,
    GESTURE_TIMEOUT,
    SCREENSHOT_FAILED,
    SCREENSHOT_THROTTLED,
    IMAGE_TOO_LARGE,
    CAPTURE_SECURE_WINDOW,
    CANCELLED,
    TIMEOUT,
    INTERNAL_ERROR,
}

sealed interface PhoneControlResult<out T> {
    data class Ok<T>(val value: T) : PhoneControlResult<T>

    data class Denied(
        val reason: PhoneControlDenial,
        val detail: String? = null,
        val observation: PhoneControlObservation? = null,
    ) : PhoneControlResult<Nothing>

    data class Unavailable(
        val reason: PhoneControlUnavailable,
        val detail: String? = null,
    ) : PhoneControlResult<Nothing>

    data class Failed(
        val reason: PhoneControlFailure,
        val detail: String? = null,
        val observation: PhoneControlObservation? = null,
    ) : PhoneControlResult<Nothing>
}

/**
 * Live service state for capability reporting/UI. `connected` is the actual
 * bound service; `enabled` is the last process-observed bound state. Use
 * [PhoneControlActivation.isEnabled] for the system Accessibility setting.
 * A connected service can still be fenced (stopped/taken over/locked).
 */
data class PhoneControlStatus(
    val connected: Boolean,
    val enabled: Boolean,
    val blocker: PhoneControlBlocker?,
    val activeOwner: PhoneControlOwner?,
    val fenceGeneration: Long,
    val pageGeneration: Long,
    val screenshotSupport: PhoneControlScreenshotSupport,
)
