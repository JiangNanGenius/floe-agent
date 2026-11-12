// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.KeyguardManager
import android.app.UiAutomation
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import android.view.InputEvent
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import com.floe.android.rootsystem.UiAction
import com.floe.android.rootsystem.UiBounds
import com.floe.android.rootsystem.UiDispatchOutcome
import com.floe.android.rootsystem.UiObserveRequest
import com.floe.android.rootsystem.UiRangeInfo
import com.floe.android.rootsystem.UiScreenshotRequest
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Real service-owned Android UI bridge.
 *
 * The process is the verified shell-UID app_process service, so it can create
 * a UiAutomation connection with FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES:
 * Floe's accessibility service (when enabled) and future user accessibility
 * services remain connected. No generic shell command, raw binder forwarding
 * or arbitrary input action is exposed.
 *
 * All traversal is bounded; live AccessibilityNodeInfo handles are read into
 * primitives and recycled immediately. The only retained state is the opaque
 * observation/page record in UiOperations.
 */
internal class AndroidUiAutomationBridge(
    private val context: Context,
) : Closeable {

    class UiBridgeException(val code: String) : Exception(code)

    data class Node(
        val ref: String,
        val parentRef: String?,
        val depth: Int,
        val className: String,
        val packageName: String?,
        val viewId: String?,
        val text: String?,
        val contentDescription: String?,
        val hintText: String?,
        val bounds: UiBounds,
        val visible: Boolean,
        val enabled: Boolean,
        val clickable: Boolean,
        val editable: Boolean,
        val scrollable: Boolean,
        val focusable: Boolean,
        val focused: Boolean,
        val selected: Boolean,
        val checkable: Boolean,
        val checked: Boolean,
        val password: Boolean,
        val redacted: Boolean,
        val insideScrollable: Boolean,
        val actions: Set<String>,
        val range: UiRangeInfo?,
        val path: List<Int>,
    )

    data class Page(
        val observationId: String,
        val packageName: String?,
        val windowId: Int,
        val windowType: Int?,
        val windowTitle: String?,
        val displayId: Int,
        val rootClassName: String?,
        val rotation: Int,
        val capturedAtElapsed: Long,
        val expiresAtElapsed: Long,
        val generation: Long,
        val userInteractionRevision: Long,
        val nodes: List<Node>,
        val scannedNodeCount: Int,
        val truncated: Boolean,
        val maxDepthReached: Boolean,
        val scanLimited: Boolean,
        val timeLimited: Boolean,
        val textLimited: Boolean,
        val sensitiveWindow: Boolean,
        val hasSensitiveField: Boolean,
        val navigationOnly: Boolean,
        val overlayUnsafe: Boolean,
    )

    data class ActExecution(
        val dispatch: UiDispatchOutcome,
        val method: String?,
        val detailCode: String? = null,
        val detail: String? = null,
    )

    data class Screenshot(
        val bytes: ByteArray,
        val width: Int,
        val height: Int,
        val originalWidth: Int,
        val originalHeight: Int,
        val rotation: Int,
        val displayId: Int,
    )

    @Volatile
    private var automation: UiAutomation? = null

    @Volatile
    private var connected = false

    @Volatile
    private var lastUserInteractionElapsed = -1L

    @Volatile
    private var userInteractionRevision = 0L

    @Volatile
    private var dispatching = false

    @Volatile
    private var lastDispatchElapsed = 0L

    /**
     * The one owned input currently held (if any). Its token is the exact
     * operation claim requestId, so an older cancellation can never inject a
     * release into a successor task's gesture. [cancelRequested] is set by
     * uiCancel and observed by the active injection loop, which performs the
     * real UP/release on its own dispatch gate.
     */
    @Volatile
    private var inputLease: InputLease? = null

    /** Serializes one whole input gesture with close/detach release. */
    private val dispatchGate = Any()

    private val closed = AtomicBoolean(false)
    private val gate = Any()

    /** True only when this process can construct a UiAutomation type at all. */
    fun supported(): Boolean = runCatching {
        Class.forName(UI_AUTOMATION_CLASS)
        true
    }.getOrDefault(false)

    /**
     * Connect (or return the existing connection). The connection is lazy so
     * a service that never uses structured UI does not disturb accessibility.
     * Failure is a typed, truthful unavailability reason; there is no silent
     * fallback to a shell dump or a different privileged backend.
     */
    fun ensureConnected(): UiAutomation {
        synchronized(gate) {
            if (closed.get()) throw UiBridgeException("ui_closed")
            automation?.let { if (connected) return it }
            val instance = connectAutomation()
            automation = instance
            connected = true
            applyServiceInfo(instance)
            return instance
        }
    }

    private fun connectAutomation(): UiAutomation {
        // Primary: the framework's public UiAutomation type with the hidden
        // connection constructor used by uiautomator. The service already
        // bootstraps ActivityThread and carries a bounded hidden-API
        // exemption for that entry point.
        runCatching {
            val automationClass = Class.forName(UI_AUTOMATION_CLASS)
            val connectionClass = Class.forName(UI_AUTOMATION_CONNECTION_CLASS)
            val connection = connectionClass.getDeclaredConstructor()
                .apply { isAccessible = true }
                .newInstance()
            val connectionInterface = Class.forName(UI_AUTOMATION_CONNECTION_INTERFACE)
            val constructor = automationClass.getDeclaredConstructor(
                Looper::class.java,
                connectionInterface,
                Int::class.javaPrimitiveType,
            ).apply { isAccessible = true }
            val instance = constructor.newInstance(
                Looper.getMainLooper(),
                connection,
                UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES,
            ) as UiAutomation
            automationClass.getMethod("connect").invoke(instance)
            return instance
        }

        // Fallback: the public Instrumentation.getUiAutomation(int) entry
        // point. A bare Instrumentation needs the system context and main
        // looper; both are supplied reflectively without registering the
        // process as an instrumentation test.
        runCatching {
            val instrumentation = android.app.Instrumentation()
            setInstrumentationContext(instrumentation, "mInstrContext")
            setInstrumentationContext(instrumentation, "mAppContext")
            setInstrumentationThread(instrumentation)
            return instrumentation.getUiAutomation(
                UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES,
            )
        }

        throw UiBridgeException("ui_automation_unavailable")
    }

    private fun setInstrumentationContext(instrumentation: android.app.Instrumentation, field: String) {
        runCatching {
            val target = android.app.Instrumentation::class.java.getDeclaredField(field)
            target.isAccessible = true
            target.set(instrumentation, context)
        }
    }

    private fun setInstrumentationThread(instrumentation: android.app.Instrumentation) {
        runCatching {
            val target = android.app.Instrumentation::class.java.getDeclaredField("mThread")
            target.isAccessible = true
            target.set(instrumentation, Thread.currentThread())
        }
    }

    private fun applyServiceInfo(instance: UiAutomation) {
        runCatching {
            val info = instance.serviceInfo ?: AccessibilityServiceInfo()
            info.eventTypes = AccessibilityEvent.TYPE_VIEW_CLICKED or
                AccessibilityEvent.TYPE_VIEW_LONG_CLICKED or
                AccessibilityEvent.TYPE_VIEW_SCROLLED or
                AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_WINDOWS_CHANGED
            info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
            info.flags = info.flags or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                // Stable node identity and sensitive-view-id redaction rely
                // on the real resource id being reported. A missing platform
                // id stays missing; it is never fabricated into an identity.
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            instance.setServiceInfo(info)
            instance.setOnAccessibilityEventListener(
                UiAutomation.OnAccessibilityEventListener { event ->
                    onAccessibilityEvent(event)
                },
            )
        }
    }

    private fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val type = event?.eventType ?: return
        try {
            val now = SystemClock.elapsedRealtime()
            if (!dispatching && type in USER_EVENT_TYPES &&
                (lastDispatchElapsed == 0L || now - lastDispatchElapsed > 500L)
            ) {
                lastUserInteractionElapsed = now
                userInteractionRevision += 1L
            }
        } finally {
            // UiAutomation owns/recycles the event after the listener returns.
        }
    }

    fun keyguardLocked(): Boolean = runCatching {
        (context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)
            ?.isKeyguardLocked == true
    }.getOrDefault(true)

    fun lastUserInteractionElapsedRealtime(): Long = lastUserInteractionElapsed

    fun userInteractionRevision(): Long = userInteractionRevision

    /**
     * Read one bounded page. The target package must be the actual active
     * window package, except for the launcher which yields a navigation-only
     * metadata record with no node content. Floe/system-credential surfaces
     * are refused before any node text is read.
     */
    fun observe(
        targets: Set<String>,
        request: UiObserveRequest,
        cancelled: () -> Boolean,
        generation: Long,
    ): Page {
        if (cancelled()) throw UiBridgeException("cancelled")
        if (keyguardLocked()) throw UiBridgeException("locked")
        val instance = ensureConnected()
        val cacheCleared = Build.VERSION.SDK_INT >= 33 &&
            runCatching { instance.clearCache() }.getOrDefault(false)
        val root = awaitRoot(instance) ?: throw UiBridgeException("ui_not_ready")
        if (!cacheCleared && !runCatching { root.refresh() }.getOrDefault(false)) {
            runCatching { root.recycle() }
            throw UiBridgeException("ui_not_ready")
        }
        val windows = runCatching { instance.windows }.getOrDefault(emptyList())
        try {
            val windowId = root.windowId
            val packageName = root.packageName?.toString()
            val window = windows.firstOrNull { it.id == windowId }
            val windowType = window?.type
            val displayId = displayIdOf(window)
            val rotation = displayRotation()
            val navigationOnly = packageName != null &&
                (isFloePackage(packageName) || isHomePackage(packageName))
            val overlayUnsafe = overlayUnsafe(windows, packageName, targets)
            if (navigationOnly) {
                val className = if (isFloePackage(packageName ?: "")) null else root.className?.toString()
                return Page(
                    observationId = java.util.UUID.randomUUID().toString(),
                    packageName = packageName,
                    windowId = windowId,
                    windowType = windowType,
                    windowTitle = null,
                    displayId = displayId,
                    rootClassName = className,
                    rotation = rotation,
                    capturedAtElapsed = SystemClock.elapsedRealtime(),
                    expiresAtElapsed = SystemClock.elapsedRealtime() + OBSERVATION_TTL_MS,
                    generation = generation,
                    userInteractionRevision = userInteractionRevision,
                    nodes = emptyList(),
                    scannedNodeCount = 0,
                    truncated = false,
                    maxDepthReached = false,
                    scanLimited = false,
                    timeLimited = false,
                    textLimited = false,
                    sensitiveWindow = isFloePackage(packageName ?: ""),
                    hasSensitiveField = false,
                    navigationOnly = true,
                    overlayUnsafe = overlayUnsafe,
                )
            }
            if (packageName == null || packageName !in targets) {
                throw UiBridgeException(
                    if (packageName != null && isProtectedPackage(packageName)) {
                        "protected_target"
                    } else {
                        "target_not_authorized"
                    },
                )
            }
            val className = root.className?.toString()
            val rawWindowTitle = runCatching { window?.title?.toString() }.getOrNull()

            val nodes = ArrayList<Node>(minOf(request.maxNodes, MAX_NODES))
            var scanned = 0
            var textSpent = 0
            var textLimited = false
            var scanLimited = false
            var timeLimited = false
            var depthLimited = false
            var sensitive = false
            val deadline = SystemClock.elapsedRealtime() + SCAN_TIME_BUDGET_MS
            val queue = ArrayDeque<Frame>()
            queue += Frame(root, null, 0, emptyList(), false)
            try {
                while (queue.isNotEmpty()) {
                    if (cancelled()) throw UiBridgeException("cancelled")
                    if (SystemClock.elapsedRealtime() > deadline) {
                        timeLimited = true
                        break
                    }
                    if (scanned >= MAX_SCAN_NODES) {
                        scanLimited = true
                        break
                    }
                    val frame = queue.removeFirst()
                    scanned += 1
                    val node = frame.node
                    try {
                        val nodePackage = node.packageName?.toString()
                        if (nodePackage != null && nodePackage !in targets &&
                            nodePackage != packageName
                        ) {
                            // Never read children of a foreign overlay/app.
                            continue
                        }
                        val bounds = Rect()
                        runCatching { node.getBoundsInScreen(bounds) }
                        val visible = runCatching { node.isVisibleToUser }.getOrDefault(false)
                        val password = runCatching { node.isPassword }.getOrDefault(false)
                        val viewId = runCatching { node.viewIdResourceName }.getOrNull()
                        val sensitiveField = password || isSensitiveViewId(viewId)
                        if (sensitiveField) sensitive = true
                        val redact = sensitiveField
                        val remaining = (request.textBudgetChars - textSpent).coerceAtLeast(0)
                        // A protected field's contents are not even
                        // materialized here: redaction happens before the
                        // read, not only before the response.
                        val rawText = if (redact) null else node.text?.toString()
                        val rawDescription = if (redact) {
                            null
                        } else {
                            node.contentDescription?.toString()
                        }
                        val rawHint = if (redact || Build.VERSION.SDK_INT < 26) {
                            null
                        } else {
                            node.hintText?.toString()
                        }
                        val text = if (redact) null else boundField(rawText, remaining)
                        val description = if (redact) null else
                            boundField(rawDescription, remaining - (text?.length ?: 0))
                        val hint = if (redact) null else
                            boundField(
                                rawHint,
                                remaining - (text?.length ?: 0) - (description?.length ?: 0),
                            )
                        if (!redact) {
                            val used = (text?.length ?: 0) + (description?.length ?: 0) +
                                (hint?.length ?: 0)
                            textSpent += used
                            if ((rawText?.length ?: 0) > (text?.length ?: 0) ||
                                (rawDescription?.length ?: 0) > (description?.length ?: 0) ||
                                (rawHint?.length ?: 0) > (hint?.length ?: 0)
                            ) {
                                textLimited = true
                            }
                        }
                        if (node.childCount > 0 && frame.depth >= request.maxDepth) {
                            depthLimited = true
                        }
                        if ((request.includeInvisible || visible) &&
                            nodes.size < minOf(request.maxNodes, MAX_NODES)
                        ) {
                            val ref = "n${nodes.size}"
                            nodes += Node(
                                ref = ref,
                                parentRef = frame.parentRef,
                                depth = frame.depth,
                                className = node.className?.toString()?.take(200).orEmpty(),
                                packageName = nodePackage ?: packageName,
                                viewId = viewId?.take(255),
                                text = text,
                                contentDescription = description,
                                hintText = hint,
                                bounds = UiBounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
                                visible = visible,
                                enabled = runCatching { node.isEnabled }.getOrDefault(false),
                                clickable = runCatching { node.isClickable }.getOrDefault(false),
                                editable = runCatching { node.isEditable }.getOrDefault(false),
                                scrollable = runCatching { node.isScrollable }.getOrDefault(false),
                                focusable = runCatching { node.isFocusable }.getOrDefault(false),
                                focused = runCatching { node.isFocused }.getOrDefault(false),
                                selected = runCatching { node.isSelected }.getOrDefault(false),
                                checkable = runCatching { node.isCheckable }.getOrDefault(false),
                                checked = runCatching { node.isChecked }.getOrDefault(false),
                                password = password,
                                redacted = redact,
                                insideScrollable = frame.insideScrollable,
                                actions = actionNames(node),
                                range = runCatching {
                                    node.rangeInfo?.let {
                                        UiRangeInfo(it.min, it.max, it.current)
                                    }
                                }.getOrNull(),
                                path = frame.path,
                            )
                            frame.ref = ref
                        }
                        if (frame.depth < request.maxDepth && node.childCount > 0) {
                            for (index in 0 until node.childCount) {
                                val child = runCatching { node.getChild(index) }.getOrNull()
                                if (child == null) continue
                                queue += Frame(
                                    child,
                                    frame.ref,
                                    frame.depth + 1,
                                    frame.path + index,
                                    frame.insideScrollable ||
                                        runCatching { node.isScrollable }.getOrDefault(false),
                                )
                            }
                        }
                    } finally {
                        if (node !== root) runCatching { node.recycle() }
                    }
                }
            } finally {
                // Child handles already recycled; root is recycled here.
                runCatching { root.recycle() }
            }
            val now = SystemClock.elapsedRealtime()
            return Page(
                observationId = java.util.UUID.randomUUID().toString(),
                packageName = packageName,
                windowId = windowId,
                windowType = windowType,
                windowTitle = rawWindowTitle?.take(200),
                displayId = displayId,
                rootClassName = className?.take(200),
                rotation = rotation,
                capturedAtElapsed = now,
                expiresAtElapsed = now + OBSERVATION_TTL_MS,
                generation = generation,
                userInteractionRevision = userInteractionRevision,
                nodes = nodes,
                scannedNodeCount = scanned,
                truncated = scanLimited || timeLimited || depthLimited ||
                    nodes.size >= minOf(request.maxNodes, MAX_NODES) && scanned > nodes.size,
                maxDepthReached = depthLimited,
                scanLimited = scanLimited,
                timeLimited = timeLimited,
                textLimited = textLimited,
                sensitiveWindow = false,
                hasSensitiveField = sensitive,
                navigationOnly = false,
                overlayUnsafe = overlayUnsafe,
            )
        } finally {
            runCatching { root.recycle() }
            windows.forEach { runCatching { it.recycle() } }
        }
    }

    /**
     * Dispatch exactly one closed action to the node resolved from the
     * retained observation. The caller has already validated the observation
     * owner/generation/TTL. A changed/ambiguous live node is NOT_DISPATCHED
     * before any input; a framework refusal that is proven not to have
     * mutated may use one bounded coordinate fallback; a thrown or partial
     * dispatch is UNKNOWN and is never replayed.
     */
    fun act(
        page: Page?,
        nodeRef: String?,
        action: UiAction,
        direction: String?,
        text: String?,
        sensitiveIntent: Boolean,
        ownerToken: String,
        requestId: String,
        targetPackage: String?,
        targets: Set<String>,
        cancelled: () -> Boolean,
    ): ActExecution {
        if (cancelled()) throw UiBridgeException("cancelled")
        if (keyguardLocked()) throw UiBridgeException("locked")
        if (action == UiAction.LAUNCH) {
            val target = targetPackage
                ?: throw UiBridgeException("launch_target_required")
            if (target !in targets || isFloePackage(target) || isProtectedPackage(target)) {
                throw UiBridgeException("target_not_authorized")
            }
            return launchApplication(target)
        }
        val retained = page ?: throw UiBridgeException("ui_observation_invalid")
        val instance = ensureConnected()
        if (retained.rotation != displayRotation()) {
            return ActExecution(UiDispatchOutcome.NOT_DISPATCHED, null, "rotation_changed")
        }
        val root = awaitRoot(instance) ?: throw UiBridgeException("ui_not_ready")
        var resolved: AccessibilityNodeInfo? = null
        var parent: AccessibilityNodeInfo? = null
        try {
            if (root.packageName?.toString() != retained.packageName ||
                root.windowId != retained.windowId
            ) {
                return ActExecution(UiDispatchOutcome.NOT_DISPATCHED, null, "stale_observation")
            }
            if (action == UiAction.BACK || action == UiAction.HOME) {
                if (cancelled()) throw UiBridgeException("cancelled")
                val global = if (action == UiAction.BACK) {
                    android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK
                } else {
                    android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME
                }
                val decision = decideAction {
                    instance.performGlobalAction(global)
                }
                return when (decision.dispatch) {
                    UiDispatchOutcome.ACCEPTED ->
                        ActExecution(UiDispatchOutcome.ACCEPTED, "globalAction")
                    UiDispatchOutcome.NOT_DISPATCHED -> ActExecution(
                        UiDispatchOutcome.NOT_DISPATCHED, null, "global_action_rejected",
                    )
                    UiDispatchOutcome.UNKNOWN -> ActExecution(
                        UiDispatchOutcome.UNKNOWN, "globalAction", "global_action_unknown",
                    )
                }
            }
            val ref = nodeRef ?: return ActExecution(
                UiDispatchOutcome.NOT_DISPATCHED, null, "node_required",
            )
            val stored = retained.nodes.firstOrNull { it.ref == ref }
                ?: return ActExecution(
                    UiDispatchOutcome.NOT_DISPATCHED, null, "observation_invalid",
                )
            val targetNode = resolveNode(root, stored.path)
                ?: return ActExecution(
                    UiDispatchOutcome.NOT_DISPATCHED, null, "node_changed",
                )
            resolved = targetNode
            parent = if (stored.path.isEmpty()) {
                null
            } else {
                resolveNode(root, stored.path.dropLast(1))
            }
            val pageIdentity = storedIdentity(retained, stored)
            val liveIdentity = readLiveIdentity(targetNode, parent, pageIdentity)
                ?: return ActExecution(
                    UiDispatchOutcome.NOT_DISPATCHED, null, "node_changed",
                )
            UiNodeIdentityPolicy.mismatch(pageIdentity, liveIdentity)?.let { code ->
                return ActExecution(UiDispatchOutcome.NOT_DISPATCHED, null, code)
            }
            if (cancelled()) throw UiBridgeException("cancelled")
            return when (action) {
                UiAction.CLICK -> {
                    if (hasAction(
                            targetNode,
                            AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK,
                        )
                    ) {
                        val decision = decideAction {
                            targetNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        }
                        when (decision.dispatch) {
                            UiDispatchOutcome.ACCEPTED -> ActExecution(
                                UiDispatchOutcome.ACCEPTED, "accessibilityAction",
                            )
                            UiDispatchOutcome.NOT_DISPATCHED -> if (decision.fallbackAllowed) {
                                tapFallback(
                                    targetNode, cancelled, ownerToken, requestId,
                                )
                            } else {
                                ActExecution(
                                    UiDispatchOutcome.NOT_DISPATCHED, null,
                                    "not_clickable",
                                )
                            }
                            UiDispatchOutcome.UNKNOWN -> ActExecution(
                                UiDispatchOutcome.UNKNOWN, "accessibilityAction",
                                "action_unknown",
                            )
                        }
                    } else if (stored.clickable) {
                        tapFallback(targetNode, cancelled, ownerToken, requestId)
                    } else {
                        ActExecution(
                            UiDispatchOutcome.NOT_DISPATCHED, null, "not_clickable",
                        )
                    }
                }
                UiAction.LONG_CLICK -> {
                    if (hasAction(
                            targetNode,
                            AccessibilityNodeInfo.AccessibilityAction.ACTION_LONG_CLICK,
                        )
                    ) {
                        val decision = decideAction {
                            targetNode.performAction(
                                AccessibilityNodeInfo.ACTION_LONG_CLICK,
                            )
                        }
                        when (decision.dispatch) {
                            UiDispatchOutcome.ACCEPTED -> ActExecution(
                                UiDispatchOutcome.ACCEPTED, "accessibilityAction",
                            )
                            UiDispatchOutcome.NOT_DISPATCHED -> ActExecution(
                                UiDispatchOutcome.NOT_DISPATCHED, null,
                                "action_unsupported",
                            )
                            UiDispatchOutcome.UNKNOWN -> ActExecution(
                                UiDispatchOutcome.UNKNOWN, "accessibilityAction",
                                "action_unknown",
                            )
                        }
                    } else {
                        ActExecution(
                            UiDispatchOutcome.NOT_DISPATCHED, null, "action_unsupported",
                        )
                    }
                }
                UiAction.SET_TEXT -> {
                    val advertisesSetText = hasAction(
                        targetNode,
                        AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT,
                    )
                    val denial = UiSensitiveInputPolicy.denial(
                        hasText = text != null,
                        sensitiveIntent = sensitiveIntent,
                        storedPassword = pageIdentity.password,
                        storedRedacted = pageIdentity.redacted,
                        livePassword = liveIdentity.password,
                        liveRedacted = liveIdentity.redacted,
                        liveEditable = liveIdentity.editable,
                        advertisesSetText = advertisesSetText,
                    )
                    if (denial != null) {
                        ActExecution(UiDispatchOutcome.NOT_DISPATCHED, null, denial)
                    } else {
                        // The exact bytes are written once below; nothing
                        // here logs, echoes or persists them. An unmarked
                        // request never reaches this branch on a protected
                        // field, and a protection change is stale first.
                        val arguments = android.os.Bundle().apply {
                            putCharSequence(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                                text.orEmpty(),
                            )
                        }
                        val decision = decideAction {
                            targetNode.performAction(
                                AccessibilityNodeInfo.ACTION_SET_TEXT,
                                arguments,
                            )
                        }
                        when (decision.dispatch) {
                            UiDispatchOutcome.ACCEPTED -> ActExecution(
                                UiDispatchOutcome.ACCEPTED, "accessibilityAction",
                            )
                            UiDispatchOutcome.NOT_DISPATCHED -> ActExecution(
                                UiDispatchOutcome.NOT_DISPATCHED, null,
                                "set_text_rejected",
                            )
                            UiDispatchOutcome.UNKNOWN -> ActExecution(
                                UiDispatchOutcome.UNKNOWN, "accessibilityAction",
                                "set_text_unknown",
                            )
                        }
                    }
                }
                UiAction.SCROLL -> {
                    val forward = direction != "backward"
                    val scrollAction = if (forward) {
                        AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD
                    } else {
                        AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD
                    }
                    if (hasAction(targetNode, scrollAction)) {
                        val decision = decideAction {
                            targetNode.performAction(scrollAction.id)
                        }
                        when (decision.dispatch) {
                            UiDispatchOutcome.ACCEPTED -> ActExecution(
                                UiDispatchOutcome.ACCEPTED, "accessibilityAction",
                            )
                            UiDispatchOutcome.NOT_DISPATCHED ->
                                if (decision.fallbackAllowed &&
                                    (stored.scrollable || stored.insideScrollable)
                                ) {
                                    swipeFallback(
                                        targetNode,
                                        if (forward) "up" else "down",
                                        cancelled,
                                        ownerToken,
                                        requestId,
                                    )
                                } else {
                                    ActExecution(
                                        UiDispatchOutcome.NOT_DISPATCHED, null,
                                        "not_scrollable",
                                    )
                                }
                            UiDispatchOutcome.UNKNOWN -> ActExecution(
                                UiDispatchOutcome.UNKNOWN, "accessibilityAction",
                                "action_unknown",
                            )
                        }
                    } else if (stored.scrollable || stored.insideScrollable) {
                        swipeFallback(
                            targetNode,
                            if (forward) "up" else "down",
                            cancelled,
                            ownerToken,
                            requestId,
                        )
                    } else {
                        ActExecution(
                            UiDispatchOutcome.NOT_DISPATCHED, null, "not_scrollable",
                        )
                    }
                }
                UiAction.SWIPE -> if (stored.scrollable || stored.insideScrollable) {
                    swipeFallback(
                        targetNode,
                        direction ?: "up",
                        cancelled,
                        ownerToken,
                        requestId,
                    )
                } else {
                    ActExecution(
                        UiDispatchOutcome.NOT_DISPATCHED, null, "not_scrollable",
                    )
                }
                UiAction.FOCUS -> {
                    val decision = decideAction {
                        targetNode.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                    }
                    when (decision.dispatch) {
                        UiDispatchOutcome.ACCEPTED -> ActExecution(
                            UiDispatchOutcome.ACCEPTED, "accessibilityAction",
                        )
                        UiDispatchOutcome.NOT_DISPATCHED -> ActExecution(
                            UiDispatchOutcome.NOT_DISPATCHED, null, "focus_rejected",
                        )
                        UiDispatchOutcome.UNKNOWN -> ActExecution(
                            UiDispatchOutcome.UNKNOWN, "accessibilityAction",
                            "action_unknown",
                        )
                    }
                }
                UiAction.COMMIT -> {
                    val imeAction = if (Build.VERSION.SDK_INT >= 30) {
                        runCatching {
                            targetNode.actionList.firstOrNull {
                                it.id == AccessibilityNodeInfo.AccessibilityAction
                                    .ACTION_IME_ENTER.id
                            }
                        }.getOrNull()
                    } else {
                        null
                    }
                    val editorCapable = liveIdentity.editable ||
                        runCatching { targetNode.isFocused }.getOrDefault(false)
                    if (imeAction != null) {
                        val decision = decideAction {
                            targetNode.performAction(imeAction.id)
                        }
                        when (decision.dispatch) {
                            UiDispatchOutcome.ACCEPTED -> ActExecution(
                                UiDispatchOutcome.ACCEPTED, "accessibilityAction",
                            )
                            UiDispatchOutcome.NOT_DISPATCHED ->
                                if (decision.fallbackAllowed && editorCapable) {
                                    injectEnter(cancelled, ownerToken, requestId)
                                } else {
                                    ActExecution(
                                        UiDispatchOutcome.NOT_DISPATCHED, null,
                                        "not_focused",
                                    )
                                }
                            UiDispatchOutcome.UNKNOWN -> ActExecution(
                                UiDispatchOutcome.UNKNOWN, "accessibilityAction",
                                "action_unknown",
                            )
                        }
                    } else if (editorCapable) {
                        injectEnter(cancelled, ownerToken, requestId)
                    } else {
                        ActExecution(
                            UiDispatchOutcome.NOT_DISPATCHED, null, "not_focused",
                        )
                    }
                }
                UiAction.BACK, UiAction.HOME, UiAction.LAUNCH ->
                    ActExecution(
                        UiDispatchOutcome.NOT_DISPATCHED, null, "action_unsupported",
                    )
            }
        } finally {
            if (parent != null && parent !== root && parent !== resolved) {
                runCatching { parent.recycle() }
            }
            if (resolved != null && resolved !== root) runCatching { resolved.recycle() }
            runCatching { root.recycle() }
        }
    }

    /**
     * Display screenshot only. The App proves the whole-screen consent before
     * dispatch; the service refuses a locked/password/foreign/overlay page so
     * a capture cannot become a credential-window reader. No window capture is
     * silently widened to the display.
     */
    fun screenshot(
        targets: Set<String>,
        request: UiScreenshotRequest,
        cancelled: () -> Boolean,
        generation: Long,
    ): Screenshot {
        if (cancelled()) throw UiBridgeException("cancelled")
        if (keyguardLocked()) throw UiBridgeException("locked")
        val page = observe(
            targets = targets,
            request = UiObserveRequest(
                maxNodes = 400,
                maxDepth = 32,
                includeInvisible = false,
                textBudgetChars = 0,
            ),
            cancelled = cancelled,
            generation = generation,
        )
        if (page.navigationOnly) throw UiBridgeException("target_not_authorized")
        if (page.sensitiveWindow || page.hasSensitiveField) {
            throw UiBridgeException("protected_target")
        }
        if (page.overlayUnsafe) throw UiBridgeException("overlay_present")
        val instance = ensureConnected()
        var bitmap = runCatching { instance.takeScreenshot() }.getOrNull()
            ?: throw UiBridgeException("screenshot_unavailable")
        try {
            val afterRoot = awaitRoot(instance)
                ?: throw UiBridgeException("ui_not_ready")
            try {
                if (afterRoot.packageName?.toString() != page.packageName ||
                    afterRoot.windowId != page.windowId ||
                    displayRotation() != page.rotation
                ) {
                    throw UiBridgeException("window_changed")
                }
            } finally {
                runCatching { afterRoot.recycle() }
            }
            if (bitmap.width <= 0 || bitmap.height <= 0) {
                throw UiBridgeException("screenshot_unavailable")
            }
            // takeScreenshot() may return a hardware bitmap on newer Android
            // releases. Compress/scale only a software copy and release both.
            val software = runCatching {
                bitmap.copy(Bitmap.Config.ARGB_8888, false)
            }.getOrNull() ?: throw UiBridgeException("screenshot_unavailable")
            if (software !== bitmap) {
                bitmap.recycle()
                bitmap = software
            }
            val originalWidth = bitmap.width
            val originalHeight = bitmap.height
            var scaled = bitmap
            try {
                val maxDimension = max(originalWidth, originalHeight)
                if (maxDimension > request.maxDimension) {
                    val ratio = request.maxDimension.toFloat() / maxDimension.toFloat()
                    val width = max(1, (originalWidth * ratio).roundToInt())
                    val height = max(1, (originalHeight * ratio).roundToInt())
                    val resized = Bitmap.createScaledBitmap(scaled, width, height, true)
                    if (resized !== scaled) {
                        scaled.recycle()
                        scaled = resized
                    }
                }
                var quality = request.quality
                var attempt = 0
                while (true) {
                    if (cancelled()) throw UiBridgeException("cancelled")
                    val output = ByteArrayOutputStream()
                    if (!scaled.compress(Bitmap.CompressFormat.JPEG, quality, output)) {
                        throw UiBridgeException("screenshot_failed")
                    }
                    val bytes = output.toByteArray()
                    if (bytes.isNotEmpty() && bytes.size <= request.maxBytes) {
                        return Screenshot(
                            bytes = bytes,
                            width = scaled.width,
                            height = scaled.height,
                            originalWidth = originalWidth,
                            originalHeight = originalHeight,
                            rotation = displayRotation(),
                            displayId = Display.DEFAULT_DISPLAY,
                        )
                    }
                    if (quality > 25) {
                        quality = (quality - 10).coerceAtLeast(25)
                        continue
                    }
                    if (attempt >= 3) break
                    val nextWidth = max(1, (scaled.width * 3) / 4)
                    val nextHeight = max(1, (scaled.height * 3) / 4)
                    if (nextWidth >= scaled.width && nextHeight >= scaled.height) break
                    val next = Bitmap.createScaledBitmap(scaled, nextWidth, nextHeight, true)
                    if (next !== scaled) scaled.recycle()
                    scaled = next
                    quality = request.quality
                    attempt += 1
                }
                throw UiBridgeException("image_too_large")
            } finally {
                if (scaled !== bitmap) runCatching { scaled.recycle() }
            }
        } finally {
            runCatching { bitmap.recycle() }
        }
    }

    override fun close() {
        if (closed.get()) return
        // Actual owned input release BEFORE the automation connection
        // disappears. Event recycling alone is not input release.
        releaseBeforeDisconnect()
        if (!closed.compareAndSet(false, true)) return
        synchronized(gate) {
            val instance = automation
            automation = null
            connected = false
            if (instance != null) {
                runCatching {
                    instance.setOnAccessibilityEventListener(
                        null as UiAutomation.OnAccessibilityEventListener?,
                    )
                }
                runCatching {
                    UiAutomation::class.java.getMethod("disconnect").invoke(instance)
                }
            }
        }
    }

    // ------------------------------------------------------- input ownership

    private class InputLease(
        val token: String,
        val requestId: String,
        val release: () -> InputEvent,
    ) {
        @Volatile
        var cancelRequested: Boolean = false
    }

    /**
     * Marks the current owned input for release only when the caller's exact
     * operation claim still owns it. A successor's gesture has a different
     * token and is never touched by an older cancellation.
     */
    fun cancelOwnedInput(requestId: String, ownerToken: String? = null) {
        val lease = inputLease ?: return
        if (!UiInputLeasePolicy.matches(
                activeToken = lease.token,
                activeRequestId = lease.requestId,
                requestId = requestId,
                ownerToken = ownerToken,
            )
        ) {
            return
        }
        lease.cancelRequested = true
        synchronized(dispatchGate) {
            if (inputLease === lease) releaseLeaseLocked()
        }
    }

    /**
     * Releases held input on close/detach before the automation connection is
     * disconnected. Event recycling is never treated as release.
     */
    private fun releaseBeforeDisconnect() {
        synchronized(dispatchGate) {
            if (inputLease != null) releaseLeaseLocked()
        }
    }

    private fun releaseLeaseLocked(): String {
        val lease = inputLease ?: return "release=superseded"
        dispatching = true
        return try {
            UiInputLeasePolicy.release(
                stillOwned = { inputLease === lease },
                attempt = {
                    val event = lease.release()
                    try {
                        val confirmed = runCatching {
                            ensureConnected().injectInputEvent(event, true)
                        }.getOrDefault(false)
                        if (confirmed) {
                            "release=confirmed"
                        } else {
                            // Queued input is not confirmation of delivery.
                            val queued = runCatching {
                                ensureConnected().injectInputEvent(event, false)
                            }.getOrDefault(false)
                            if (queued) "release=queued" else "release=unconfirmed"
                        }
                    } finally {
                        recycleReleaseEvent(event)
                    }
                },
                clearOwnership = { inputLease = null },
            )
        } finally {
            dispatching = false
            lastDispatchElapsed = SystemClock.elapsedRealtime()
        }
    }

    /**
     * Only pooled MotionEvents are recycled. KeyEvent exposes no recycle();
     * dropping a reference is not input release, which is why the actual UP
     * injection above is the release attempt.
     */
    private fun recycleReleaseEvent(event: InputEvent) {
        if (event is MotionEvent) runCatching { event.recycle() }
    }

    /**
     * Sends one collected gesture/key sequence and derives the truthful
     * outcome from what actually happened. The lease is held for the whole
     * sequence and is released with a real owned UP after any partial,
     * thrown, cancelled-before-completion attempt.
     */
    private fun dispatchInput(
        ownerToken: String,
        requestId: String,
        events: List<InputEvent>,
        cancelled: () -> Boolean,
        method: String,
        release: () -> InputEvent,
    ): ActExecution {
        synchronized(dispatchGate) {
            val existing = inputLease
            if (existing != null) {
                // Never overwrite a previous unconfirmed input lease. Its
                // exact request may attempt cleanup, but cannot replay it.
                val state = if (UiInputLeasePolicy.matches(
                        activeToken = existing.token,
                        activeRequestId = existing.requestId,
                        requestId = requestId,
                        ownerToken = ownerToken,
                    )
                ) {
                    releaseLeaseLocked()
                } else {
                    "release=unconfirmed"
                }
                return ActExecution(
                    UiDispatchOutcome.UNKNOWN, method, "input_owned", state,
                )
            }
            val lease = InputLease(ownerToken, requestId, release)
            inputLease = lease
            val sends = ArrayList<UiInputSend>(events.size)
            var cancelledBeforeCompletion = false
            dispatching = true
            try {
                for (event in events) {
                    if (cancelled() || lease.cancelRequested) {
                        cancelledBeforeCompletion = true
                        break
                    }
                    val send = try {
                        if (ensureConnected().injectInputEvent(event, true)) {
                            UiInputSend.ACCEPTED
                        } else {
                            UiInputSend.REJECTED
                        }
                    } catch (_: Throwable) {
                        UiInputSend.THREW
                    }
                    sends += send
                    if (send != UiInputSend.ACCEPTED) break
                }
            } finally {
                dispatching = false
                lastDispatchElapsed = SystemClock.elapsedRealtime()
            }
            val decision = UiDispatchPolicy.input(sends, cancelledBeforeCompletion)
            if (sends.isEmpty()) {
                inputLease = null
                if (cancelled() || lease.cancelRequested) {
                    throw UiBridgeException("cancelled")
                }
                return ActExecution(
                    UiDispatchOutcome.NOT_DISPATCHED, null, "input_rejected",
                )
            }
            if (decision.releaseRequired) {
                // The real owned UP/release attempt. The dispatch outcome
                // stays UNKNOWN regardless of the release result.
                val releaseState = releaseLeaseLocked()
                return ActExecution(
                    decision.dispatch,
                    method,
                    "input_partial",
                    releaseState,
                )
            }
            inputLease = null
            return when (decision.dispatch) {
                UiDispatchOutcome.ACCEPTED ->
                    ActExecution(UiDispatchOutcome.ACCEPTED, method)
                UiDispatchOutcome.NOT_DISPATCHED -> ActExecution(
                    UiDispatchOutcome.NOT_DISPATCHED, null, "input_rejected",
                )
                UiDispatchOutcome.UNKNOWN -> {
                    val releaseState = releaseLeaseLocked()
                    ActExecution(
                        UiDispatchOutcome.UNKNOWN, method, "input_partial", releaseState,
                    )
                }
            }
        }
    }

    // ------------------------------------------------------------- internals

    private data class Frame(
        val node: AccessibilityNodeInfo,
        val parentRef: String?,
        val depth: Int,
        val path: List<Int>,
        val insideScrollable: Boolean,
        var ref: String? = null,
    )

    private fun awaitRoot(instance: UiAutomation): AccessibilityNodeInfo? {
        repeat(3) { attempt ->
            val root = runCatching { instance.rootInActiveWindow }.getOrNull()
            if (root != null) return root
            if (attempt < 2) SystemClock.sleep(60)
        }
        return null
    }

    private fun resolveNode(root: AccessibilityNodeInfo, path: List<Int>): AccessibilityNodeInfo? {
        if (path.isEmpty()) return root
        var current: AccessibilityNodeInfo = root
        var owned = false
        try {
            for (index in path) {
                val child = runCatching { current.getChild(index) }.getOrNull() ?: return null
                if (owned) runCatching { current.recycle() }
                current = child
                owned = true
            }
            return current
        } catch (_: Throwable) {
            if (owned) runCatching { current.recycle() }
            return null
        }
    }

    /**
     * Target-local identity from the retained page. Direct children are
     * captured only when the node has no own text/description/hint, because a
     * clickable row container often carries its content in children; a
     * recycled row must not hand its old ref to different content. A
     * protected target never reads descendant text anchors at all.
     */
    private fun storedIdentity(page: Page, node: Node): UiNodeIdentity {
        val parent = node.parentRef?.let { ref ->
            page.nodes.firstOrNull { it.ref == ref }
        }
        val childAnchors = if (!node.redacted && node.text == null &&
            node.contentDescription == null && node.hintText == null
        ) {
            page.nodes.asSequence()
                .filter { it.parentRef == node.ref }
                .mapNotNull { child ->
                    val index = child.path.lastOrNull() ?: return@mapNotNull null
                    index to child
                }
                .sortedBy { it.first }
                .take(UiNodeIdentityPolicy.MAX_CHILD_ANCHORS)
                .map { (index, child) -> storedAnchor(index, child) }
                .toList()
        } else {
            emptyList()
        }
        return UiNodeIdentity(
            packageName = node.packageName,
            className = node.className,
            viewId = node.viewId,
            bounds = node.bounds,
            visible = node.visible,
            enabled = node.enabled,
            clickable = node.clickable,
            editable = node.editable,
            password = node.password,
            redacted = node.redacted,
            actions = node.actions,
            text = node.text,
            contentDescription = node.contentDescription,
            hintText = node.hintText,
            childAnchors = childAnchors,
            parentAnchor = parent?.let { storedAnchor(-1, it) },
        )
    }

    private fun storedAnchor(index: Int, node: Node): UiIdentityAnchor =
        UiIdentityAnchor(
            index = index,
            className = node.className,
            viewId = node.viewId,
            bounds = node.bounds,
            password = node.password,
            redacted = node.redacted,
            text = node.text,
            contentDescription = node.contentDescription,
            hintText = node.hintText,
        )

    /**
     * One bounded live re-read of the resolved node and the exact anchors
     * used for identity. Protected fields never have their text read here;
     * only class/view id/bounds/protection are compared for them.
     */
    private fun readLiveIdentity(
        node: AccessibilityNodeInfo,
        parent: AccessibilityNodeInfo?,
        stored: UiNodeIdentity,
    ): UiNodeIdentity? {
        return try {
            val livePassword = runCatching { node.isPassword }.getOrDefault(false)
            val viewId = runCatching { node.viewIdResourceName }.getOrNull()
                ?.take(255)
            val liveRedacted = livePassword || isSensitiveViewId(viewId)
            val bounds = Rect()
            runCatching { node.getBoundsInScreen(bounds) }
            val mayReadText = !stored.redacted && !liveRedacted
            val childAnchors = ArrayList<UiIdentityAnchor>(
                stored.childAnchors.size,
            )
            for (anchor in stored.childAnchors) {
                val child = runCatching { node.getChild(anchor.index) }.getOrNull()
                    ?: return null
                try {
                    childAnchors += liveAnchor(anchor.index, child, anchor.redacted)
                } finally {
                    runCatching { child.recycle() }
                }
            }
            val storedParent = stored.parentAnchor
            val liveParent = if (storedParent != null) {
                val parentNode = parent ?: return null
                liveAnchor(-1, parentNode, storedParent.redacted)
            } else {
                null
            }
            UiNodeIdentity(
                packageName = runCatching { node.packageName?.toString() }.getOrNull(),
                className = runCatching { node.className?.toString() }.getOrNull()
                    ?.take(200).orEmpty(),
                viewId = viewId,
                bounds = UiBounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
                visible = runCatching { node.isVisibleToUser }.getOrDefault(false),
                enabled = runCatching { node.isEnabled }.getOrDefault(false),
                clickable = runCatching { node.isClickable }.getOrDefault(false),
                editable = runCatching { node.isEditable }.getOrDefault(false),
                password = livePassword,
                redacted = liveRedacted,
                actions = actionNames(node),
                text = if (mayReadText) {
                    runCatching { node.text?.toString() }.getOrNull()
                        ?.take(MAX_FIELD_CHARS)
                } else {
                    null
                },
                contentDescription = if (mayReadText) {
                    runCatching { node.contentDescription?.toString() }.getOrNull()
                        ?.take(MAX_FIELD_CHARS)
                } else {
                    null
                },
                hintText = if (mayReadText && Build.VERSION.SDK_INT >= 26) {
                    runCatching { node.hintText?.toString() }.getOrNull()
                        ?.take(MAX_FIELD_CHARS)
                } else {
                    null
                },
                childAnchors = childAnchors,
                parentAnchor = liveParent,
            )
        } catch (_: Throwable) {
            null
        }
    }

    private fun liveAnchor(
        index: Int,
        node: AccessibilityNodeInfo,
        storedRedacted: Boolean,
    ): UiIdentityAnchor {
        val password = runCatching { node.isPassword }.getOrDefault(false)
        val viewId = runCatching { node.viewIdResourceName }.getOrNull()?.take(255)
        val redacted = password || isSensitiveViewId(viewId)
        val bounds = Rect()
        runCatching { node.getBoundsInScreen(bounds) }
        val mayReadText = !storedRedacted && !redacted
        return UiIdentityAnchor(
            index = index,
            className = runCatching { node.className?.toString() }.getOrNull()
                ?.take(200).orEmpty(),
            viewId = viewId,
            bounds = UiBounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
            password = password,
            redacted = redacted,
            text = if (mayReadText) {
                runCatching { node.text?.toString() }.getOrNull()
                    ?.take(MAX_FIELD_CHARS)
            } else {
                null
            },
            contentDescription = if (mayReadText) {
                runCatching { node.contentDescription?.toString() }.getOrNull()
                    ?.take(MAX_FIELD_CHARS)
            } else {
                null
            },
            hintText = if (mayReadText && Build.VERSION.SDK_INT >= 26) {
                runCatching { node.hintText?.toString() }.getOrNull()
                    ?.take(MAX_FIELD_CHARS)
            } else {
                null
            },
        )
    }

    private inline fun attemptAction(block: () -> Boolean): UiActionAttempt = try {
        if (block()) UiActionAttempt.ACCEPTED else UiActionAttempt.REJECTED
    } catch (_: Throwable) {
        UiActionAttempt.THREW
    }

    private inline fun decideAction(block: () -> Boolean): UiActionDecision =
        UiDispatchPolicy.action(attemptAction(block))

    private fun tapFallback(
        node: AccessibilityNodeInfo,
        cancelled: () -> Boolean,
        ownerToken: String,
        requestId: String,
    ): ActExecution {
        if (cancelled()) throw UiBridgeException("cancelled")
        val bounds = Rect()
        runCatching { node.getBoundsInScreen(bounds) }
        if (bounds.width() <= 0 || bounds.height() <= 0) {
            return ActExecution(UiDispatchOutcome.NOT_DISPATCHED, null, "no_bounds")
        }
        val x = bounds.centerX().toFloat()
        val y = bounds.centerY().toFloat()
        val downTime = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, x, y, 0)
        val up = MotionEvent.obtain(downTime, downTime + 40L, MotionEvent.ACTION_UP, x, y, 0)
        return try {
            dispatchInput(
                ownerToken, requestId, listOf(down, up), cancelled, "inputTap",
            ) {
                val releaseTime = SystemClock.uptimeMillis()
                MotionEvent.obtain(
                    downTime, releaseTime, MotionEvent.ACTION_UP, x, y, 0,
                )
            }
        } finally {
            down.recycle()
            up.recycle()
        }
    }

    private fun swipeFallback(
        node: AccessibilityNodeInfo,
        direction: String,
        cancelled: () -> Boolean,
        ownerToken: String,
        requestId: String,
    ): ActExecution {
        if (cancelled()) throw UiBridgeException("cancelled")
        val bounds = Rect()
        runCatching { node.getBoundsInScreen(bounds) }
        if (bounds.width() < 24 || bounds.height() < 24) {
            return ActExecution(UiDispatchOutcome.NOT_DISPATCHED, null, "no_bounds")
        }
        val cx = bounds.centerX().toFloat()
        val cy = bounds.centerY().toFloat()
        val marginX = max(8, bounds.width() / 6).toFloat()
        val marginY = max(8, bounds.height() / 6).toFloat()
        val (sx, sy, ex, ey) = when (direction.lowercase()) {
            "down" -> listOf(cx, bounds.top + marginY, cx, bounds.bottom - marginY)
            "left" -> listOf(bounds.right - marginX, cy, bounds.left + marginX, cy)
            "right" -> listOf(bounds.left + marginX, cy, bounds.right - marginX, cy)
            else -> listOf(cx, bounds.bottom - marginY, cx, bounds.top + marginY)
        }
        val downTime = SystemClock.uptimeMillis()
        val duration = 240L
        val steps = 8
        val events = ArrayList<MotionEvent>(steps + 2)
        events += MotionEvent.obtain(
            downTime, downTime, MotionEvent.ACTION_DOWN, sx, sy, 0,
        )
        for (step in 1..steps) {
            val fraction = step.toFloat() / steps
            events += MotionEvent.obtain(
                downTime,
                downTime + (duration * fraction).toLong(),
                MotionEvent.ACTION_MOVE,
                sx + (ex - sx) * fraction,
                sy + (ey - sy) * fraction,
                0,
            )
        }
        events += MotionEvent.obtain(
            downTime, downTime + duration, MotionEvent.ACTION_UP, ex, ey, 0,
        )
        return try {
            dispatchInput(
                ownerToken, requestId, events, cancelled, "inputSwipe",
            ) {
                val releaseTime = SystemClock.uptimeMillis()
                MotionEvent.obtain(
                    downTime, releaseTime, MotionEvent.ACTION_UP, ex, ey, 0,
                )
            }
        } finally {
            events.forEach { runCatching { it.recycle() } }
        }
    }

    private fun injectEnter(
        cancelled: () -> Boolean,
        ownerToken: String,
        requestId: String,
    ): ActExecution {
        if (cancelled()) throw UiBridgeException("cancelled")
        val now = SystemClock.uptimeMillis()
        val down = KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, 0)
        val up = KeyEvent(now, now + 30L, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, 0)
        return dispatchInput(
            ownerToken, requestId, listOf(down, up), cancelled, "inputKey",
        ) {
            val releaseTime = SystemClock.uptimeMillis()
            KeyEvent(
                releaseTime,
                releaseTime,
                KeyEvent.ACTION_UP,
                KeyEvent.KEYCODE_ENTER,
                0,
            )
        }
    }

    private fun launchApplication(packageName: String): ActExecution {
        val intent = runCatching { context.packageManager.getLaunchIntentForPackage(packageName) }
            .getOrNull() ?: return ActExecution(
            UiDispatchOutcome.NOT_DISPATCHED, null, "launch_target_unavailable",
        )
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            ActExecution(UiDispatchOutcome.ACCEPTED, "launchIntent")
        } catch (_: SecurityException) {
            ActExecution(UiDispatchOutcome.NOT_DISPATCHED, null, "launch_denied")
        } catch (_: Throwable) {
            ActExecution(UiDispatchOutcome.UNKNOWN, "launchIntent", "launch_unknown")
        }
    }

    private fun hasAction(
        node: AccessibilityNodeInfo,
        action: AccessibilityNodeInfo.AccessibilityAction,
    ): Boolean = runCatching {
        node.actionList.any { it.id == action.id }
    }.getOrDefault(false)

    private fun actionNames(node: AccessibilityNodeInfo): Set<String> {
        val names = LinkedHashSet<String>(8)
        runCatching {
            for (action in node.actionList) {
                val name = when (action.id) {
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK.id -> "click"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_LONG_CLICK.id -> "longClick"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_FOCUS.id -> "focus"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_CLEAR_FOCUS.id -> "clearFocus"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_TEXT.id -> "setText"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_FORWARD.id ->
                        "scrollForward"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_BACKWARD.id ->
                        "scrollBackward"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.id -> "scrollUp"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.id -> "scrollDown"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id -> "scrollLeft"
                    AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id -> "scrollRight"
                    else -> null
                }
                if (name != null) names += name
            }
            if (Build.VERSION.SDK_INT >= 30 &&
                node.actionList.any {
                    it.id == AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
                }
            ) {
                names += "ime"
            }
        }
        return names
    }

    private fun boundField(value: String?, remaining: Int): String? {
        if (value == null) return null
        val limit = minOf(MAX_FIELD_CHARS, remaining.coerceAtLeast(0))
        if (limit <= 0) return null
        return if (value.length <= limit) value else value.substring(0, limit)
    }

    private fun isSensitiveViewId(viewId: String?): Boolean {
        val lower = viewId?.lowercase() ?: return false
        return SENSITIVE_VIEW_MARKERS.any { lower.contains(it) }
    }

    private fun isFloePackage(packageName: String): Boolean =
        packageName == context.packageName ||
            packageName == "com.floe.agent" ||
            packageName == "com.floe.agent.full" ||
            packageName == "com.floe.agent.dev" ||
            packageName == "com.floe.agent.full.dev" ||
            packageName.startsWith("com.floe.agent.")

    private fun isProtectedPackage(packageName: String): Boolean {
        val lower = packageName.lowercase()
        return isFloePackage(packageName) ||
            lower.contains("credential") ||
            lower.contains("keystore") ||
            lower.contains("security") ||
            lower.contains("permissioncontroller") ||
            lower == "com.android.systemui" ||
            lower == "com.google.android.permissioncontroller"
    }

    private fun isHomePackage(packageName: String): Boolean = runCatching {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val resolved = context.packageManager.resolveActivity(intent, 0)
        resolved?.activityInfo?.packageName == packageName
    }.getOrDefault(false)

    private fun displayIdOf(window: AccessibilityWindowInfo?): Int {
        if (window == null) return Display.DEFAULT_DISPLAY
        return runCatching {
            if (Build.VERSION.SDK_INT >= 30) window.displayId else Display.DEFAULT_DISPLAY
        }.getOrDefault(Display.DEFAULT_DISPLAY)
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int = runCatching {
        if (Build.VERSION.SDK_INT >= 30) {
            context.display?.rotation ?: 0
        } else {
            (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .defaultDisplay.rotation
        }
    }.getOrDefault(0)

    private fun overlayUnsafe(
        windows: List<AccessibilityWindowInfo>,
        activePackage: String?,
        targets: Set<String>,
    ): Boolean {
        for (window in windows) {
            val active = runCatching { window.isActive }.getOrDefault(false)
            val focused = runCatching { window.isFocused }.getOrDefault(false)
            if (!active && !focused) continue
            val type = runCatching { window.type }.getOrDefault(0)
            val root = runCatching { window.root }.getOrNull()
            val packageName = root?.packageName?.toString()
            root?.let { runCatching { it.recycle() } }
            if (type == AccessibilityWindowInfo.TYPE_INPUT_METHOD ||
                type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY
            ) {
                return true
            }
            if (packageName != null && packageName != activePackage &&
                packageName !in targets && !isSystemBar(packageName)
            ) {
                return true
            }
        }
        return false
    }

    private fun isSystemBar(packageName: String): Boolean =
        packageName == "com.android.systemui" ||
            packageName == "com.android.launcher" ||
            packageName.endsWith(".launcher")

    internal companion object {
        const val OBSERVATION_TTL_MS = 120_000L
        const val MAX_NODES = 400
        const val MAX_SCAN_NODES = 1_200
        const val SCAN_TIME_BUDGET_MS = 1_500L
        const val MAX_FIELD_CHARS = 2_000
        private const val UI_AUTOMATION_CLASS = "android.app.UiAutomation"
        private const val UI_AUTOMATION_CONNECTION_CLASS = "android.app.UiAutomationConnection"
        private const val UI_AUTOMATION_CONNECTION_INTERFACE = "android.app.IUiAutomationConnection"
        private val SENSITIVE_VIEW_MARKERS = listOf(
            "password", "passwd", "passcode", "pwd", "secret", "credential",
        )
        private val USER_EVENT_TYPES = setOf(
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_LONG_CLICKED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
        )
    }
}
