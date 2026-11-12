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
    /**
     * Ordinary dialogs can nest their actionable controls deeper than 20; a
     * real inline date picker put its month header and prev/next controls at
     * depth 21. The default therefore reaches the existing hard bound. This
     * is a bounded presentation default, not a relaxation of [MAX_DEPTH],
     * the observation TTL, grants or node validation.
     */
    const val DEFAULT_DEPTH = MAX_DEPTH
    /**
     * One capture reads at most this many nodes from the live window. The
     * level-order traversal spends this one global budget across the tree, so
     * a bounded form is read completely while a genuinely wide screen still
     * inspects its shallow toolbar/FAB controls before deep content. This is a
     * runtime bound, never authorization; [MAX_NODES] still sizes the
     * returned observation after actionable-first selection.
     */
    const val MAX_SCAN_NODES = 1_200
    /** Wall-clock ceiling for one bounded capture traversal. */
    const val SCAN_TIME_BUDGET_MS = 1_500L
    const val MAX_FIELD_CHARS = 2_000
    const val DEFAULT_TEXT_BUDGET_CHARS = 24_000
    const val MAX_TEXT_BUDGET_CHARS = 64_000
    const val MAX_SET_TEXT_CHARS = 2_000
    const val MAX_PACKAGE_CHARS = 255
    const val MAX_TARGET_PACKAGES = 64
    // Includes both cloud planning and approval: the Samsung trace needed
    // 32s before its first click. Live owner/grant/page/node checks still
    // run at dispatch; this bounded lifetime never authorizes a stale page.
    const val OBSERVATION_TTL_MS = 120_000L
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

/**
 * One typed, App-owned read-only document VIEW request.
 *
 * This is NOT a general Intent API: it carries no action, category, flags,
 * extras, URI authority choice or mutable data. The Full host constructs every
 * field from an already verified handoff record; [uri] must be the App's own
 * `externaledits` FileProvider URI for its private working copy. The launch
 * path attaches only FLAG_GRANT_READ_URI_PERMISSION plus ClipData, proves the
 * exact installed ACTION_VIEW component again, and never claims that a viewer
 * displayed the file or an importer saved it.
 */
data class PhoneControlDocumentViewRequest(
    val uri: String,
    val mimeType: String,
    val packageName: String,
    val className: String,
    val displayName: String,
)

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

/**
 * Closed subset of actions the PLATFORM declares for one node
 * (`AccessibilityNodeInfo.actionList`). This is real metadata read from the
 * live node, not an inference from its class name. It lets dispatch use an
 * advertised ACTION_CLICK/ACTION_SCROLL when the corresponding `isClickable`/
 * `isScrollable` flag is false, while the model-facing projection says what is
 * actually advertised instead of pretending a capability.
 */
enum class PhoneControlNodeAction {
    CLICK,
    LONG_CLICK,
    FOCUS,
    CLEAR_FOCUS,
    IME_ENTER,
    SET_TEXT,
    SCROLL_FORWARD,
    SCROLL_BACKWARD,
    SCROLL_UP,
    SCROLL_DOWN,
    SCROLL_LEFT,
    SCROLL_RIGHT,
    ;

    /** True for the directional/legacy scroll actions the platform declares. */
    val isScrollAction: Boolean
        get() = this == SCROLL_FORWARD || this == SCROLL_BACKWARD ||
            this == SCROLL_UP || this == SCROLL_DOWN ||
            this == SCROLL_LEFT || this == SCROLL_RIGHT

    /** Stable compact token used by the bounded detail projection. */
    val wireName: String
        get() = when (this) {
            CLICK -> "click"
            LONG_CLICK -> "longClick"
            FOCUS -> "focus"
            CLEAR_FOCUS -> "clearFocus"
            IME_ENTER -> "ime"
            SET_TEXT -> "setText"
            SCROLL_FORWARD -> "scrollForward"
            SCROLL_BACKWARD -> "scrollBackward"
            SCROLL_UP -> "scrollUp"
            SCROLL_DOWN -> "scrollDown"
            SCROLL_LEFT -> "scrollLeft"
            SCROLL_RIGHT -> "scrollRight"
        }
}

/**
 * Platform-declared numeric range (`AccessibilityNodeInfo.rangeInfo`), for
 * example a slider or a number wheel. It is the real current value the platform
 * exposes, never a value guessed from the label.
 */
data class PhoneControlRangeInfo(
    val min: Float,
    val max: Float,
    val current: Float,
) {
    val valid: Boolean
        get() = min.isFinite() && max.isFinite() && current.isFinite() && max >= min
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
    /**
     * True when an enclosing captured node is scrollable. This bounded
     * structural fact lets the compact projection rank fixed-screen chrome
     * (toolbar/FAB) above content that can be reached by scrolling. It is
     * presentation metadata and grants no action.
     */
    val insideScrollable: Boolean = false,
    /** Actions the platform actually advertises for this node. */
    val actions: Set<PhoneControlNodeAction> = emptySet(),
    /** Platform focus attribute; the action list remains the dispatch truth. */
    val focusable: Boolean = false,
    val focused: Boolean = false,
    /** Real platform range/value metadata when the control exposes it. */
    val range: PhoneControlRangeInfo? = null,
) {
    /** True only when the live platform node advertised this action. */
    fun advertises(action: PhoneControlNodeAction): Boolean = action in actions

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
    /**
     * Nodes actually read from the live window before bounded selection.
     * Always >= `nodes.size`; equal on an untruncated tree.
     */
    val scannedNodeCount: Int = nodes.size,
    /**
     * Visible actionable nodes that were read but omitted by the bounded
     * actionable-first selection. Zero when every such control is included;
     * the omission is also reflected in [truncated].
     */
    val omittedActionableCount: Int = 0,
    /** The live scan stopped at [PhoneControlLimits.MAX_SCAN_NODES]. */
    val scanLimited: Boolean = false,
    /** The live scan stopped at [PhoneControlLimits.SCAN_TIME_BUDGET_MS]. */
    val timeLimited: Boolean = false,
    /** Eligible nodes were dropped by the bounded actionable-first selection. */
    val selectionLimited: Boolean = false,
    /** A text budget/per-field cap shortened or withheld a captured field. */
    val textLimited: Boolean = false,
) {
    /**
     * Honest, deduplicated truncation reasons for model-facing copy. Empty only
     * when the capture and the retained node set are both complete. Never
     * implies that omitted rows are absent platform controls.
     */
    val truncationReasons: List<String>
        get() {
            val reasons = ArrayList<String>(5)
            if (scanLimited) reasons += "scan"
            if (timeLimited) reasons += "time"
            if (maxDepthReached) reasons += "depth"
            if (selectionLimited) reasons += "selection"
            if (textLimited) reasons += "text"
            return reasons
        }

    /** Summary only; use PhoneControlJson for an explicit structured payload. */
    override fun toString(): String =
        "PhoneControlObservation(id=$observationId, package=$packageName, window=$windowId, " +
            "nodeCount=${nodes.size}, sensitive=$sensitiveWindow, " +
            "navigationOnly=$navigationOnly)"
}

/**
 * One bounded page of the captured observation's node list, read from the
 * retained observation (never a new screen read). [nextOffset] is the exact
 * `offset` for the next page, or null on the last page.
 */
data class PhoneControlDetailPage(
    val observationId: String,
    val offset: Int,
    val rows: Int,
    val total: Int,
    val nextOffset: Int?,
    val text: String,
    /** The retained observation's existing TTL; pages never extend it. */
    val expiresAtElapsedRealtimeMillis: Long = 0L,
) {
    override fun toString(): String =
        "PhoneControlDetailPage(observation=$observationId, offset=$offset, rows=$rows, total=$total)"
}

sealed interface PhoneControlAction {
    val wireName: String

    data class Click(val nodeRef: String) : PhoneControlAction {
        override val wireName: String get() = "click"
    }

    /**
     * Never logged or echoed; [toString] intentionally hides the payload.
     *
     * [sensitive] is true when the payload arrived through the explicit
     * `device.act` `sensitiveText` parameter (published as `phone.act`
     * before the device-namespace rename): a credential the user already
     * supplied inside this authorized task (no vault prerequisite). The exact
     * bytes are dispatched once to a live-owned, fresh, editable node, both
     * wire keys are redacted before persistence, and an interrupted fill is
     * never silently replayed. [sensitive] = false keeps the ordinary-text
     * behaviour, which still refuses protected fields at the policy gate.
     */
    class SetText(
        val nodeRef: String,
        val text: String,
        val sensitive: Boolean = false,
    ) : PhoneControlAction {
        override val wireName: String get() = "setText"
        override fun toString(): String =
            "SetText(nodeRef=$nodeRef, text=<redacted>, chars=${text.length}, sensitive=$sensitive)"
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

    /**
     * Moves input focus to a node whose live platform metadata declares focus
     * support. It changes no text and performs no business action.
     */
    data class Focus(val nodeRef: String) : PhoneControlAction {
        override val wireName: String get() = "focus"
    }

    /**
     * Sends the platform IME action (search/go/done/send/next) to a live,
     * editable, currently focused or platform-advertised field. Android 11+
     * only: older platforms expose no such action and report unavailable.
     * Framework acceptance is never proof that a search ran or a date value
     * was committed; the caller verifies the result by re-observing.
     */
    data class Commit(val nodeRef: String) : PhoneControlAction {
        override val wireName: String get() = "commit"
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
    NODE_DISABLED,
    NODE_NOT_FOCUSABLE,
    NODE_NOT_FOCUSED,
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
    /** Android 10 and older expose no IME-action node operation. */
    IME_ACTION_UNSUPPORTED,
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
    val automationFinishing: Boolean = false,
    val relockReceipt: PhoneRelockReceipt? = null,
)
