// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.util.UUID

internal data class PhoneControlCapture(
    val observation: PhoneControlObservation,
    val records: Map<String, PhoneControlNodeRecord>,
    val fingerprint: Long,
    val protectedWindow: Boolean,
    val hasSensitiveField: Boolean,
    /**
     * Package-only identities of the other visible windows at capture time,
     * used solely to attribute later package-less framework window events.
     * Never carries node text, titles or tree content.
     */
    val windowIdentities: List<PhoneControlWindowIdentity> = emptyList(),
)

/**
 * Builds the only observation that may exist for a Floe foreground: the actual
 * package/window identity plus the live fence/page ticket, with zero nodes.
 * Node children, text, descriptions, hints, view ids, window title, root class
 * name and screenshot pixels are never read for this case, so Floe's own
 * settings/approval content cannot enter the record even transiently.
 *
 * The returned record can authorize only the existing Back/Home navigation or
 * a Launch whose target passes the ordinary non-Floe [PhoneControlPolicy.launchDenial].
 */
internal fun navigationOnlyCapture(
    owner: PhoneControlOwner,
    ticket: PhoneControlFence.Ticket,
    packageName: String?,
    windowId: Int,
    windowType: Int?,
    displayId: Int,
    capturedAtElapsedRealtimeMillis: Long,
    screenshotSupport: PhoneControlScreenshotSupport,
    observationId: String = UUID.randomUUID().toString(),
): PhoneControlCapture {
    val observation = PhoneControlObservation(
        observationId = observationId,
        owner = owner,
        fenceGeneration = ticket.fenceGeneration,
        pageGeneration = ticket.pageGeneration,
        capturedAtElapsedRealtimeMillis = capturedAtElapsedRealtimeMillis,
        expiresAtElapsedRealtimeMillis =
            capturedAtElapsedRealtimeMillis + PhoneControlLimits.OBSERVATION_TTL_MS,
        packageName = PhoneControlText.bound(
            PhoneControlText.clean(packageName),
            PhoneControlLimits.MAX_PACKAGE_CHARS,
        ).text,
        windowId = windowId,
        windowType = windowType,
        windowTitle = null,
        displayId = displayId,
        rootClassName = null,
        sensitiveWindow = true,
        screenshotSupport = screenshotSupport,
        nodes = emptyList(),
        truncated = false,
        maxDepthReached = false,
        navigationOnly = true,
    )
    return PhoneControlCapture(
        observation = observation,
        records = emptyMap(),
        fingerprint = navigationFingerprint(observation.packageName, windowId),
        protectedWindow = true,
        hasSensitiveField = false,
    )
}

/** Metadata-only fingerprint; node content is deliberately never read. */
private fun navigationFingerprint(packageName: String?, windowId: Int): Long {
    var hash = -0x340d631b7bdddcdbL
    for (ch in packageName.orEmpty()) {
        hash = (hash xor ch.code.toLong()) * 0x100000001b3L
    }
    hash = (hash xor 0xfeL) * 0x100000001b3L
    return (hash xor windowId.toLong()) * 0x100000001b3L
}

/**
 * Reads one bounded window snapshot on the service main thread. Node handles
 * are read into primitives and recycled immediately; no live AccessibilityNodeInfo
 * or raw credentials survive this call. Password/sensitive view-id fields are
 * never read.
 */
internal class PhoneControlSnapshotter(private val service: AccessibilityService) {
    private data class ReadStats(
        var textLimited: Boolean = false,
        var hasSensitiveField: Boolean = false,
        var obsoleteNode: Boolean = false,
    )

    @Suppress("DEPRECATION")
    fun capture(
        owner: PhoneControlOwner,
        ticket: PhoneControlFence.Ticket,
        request: PhoneControlObserveRequest,
        keyguardLocked: Boolean,
        isCancelled: () -> Boolean = { false },
    ): PhoneControlCapture? {
        if (isCancelled()) return null
        val guardState = PhoneControlSensitiveGuard.state(service) ?: return null
        val guardTickets = guardState.tickets
        val req = request.normalized()
        // A quiet event stream does not prove the framework cache is fresh.
        // Samsung's calculator returned the preceding formula after accepted
        // input. Invalidate the service cache before an explicit observation;
        // older systems refresh the bounded visited nodes from their source.
        val cacheCleared = Build.VERSION.SDK_INT >= 33 &&
            runCatching { service.clearCache() }.getOrDefault(false)
        val root = service.rootInActiveWindow ?: return null
        try {
            if (!cacheCleared && !runCatching { root.refresh() }.getOrDefault(false)) return null
            val windowId = root.windowId
            val packageName = root.packageName?.toString()
            val navigationOnly = PhoneControlPolicy.isFloePackage(packageName)
            val windows = runCatching { service.windows }.getOrDefault(emptyList())
            val window = windows.firstOrNull { it.id == windowId }
            val windowType = window?.type
            val displayId = if (Build.VERSION.SDK_INT >= 30) {
                window?.displayId ?: Display.DEFAULT_DISPLAY
            } else {
                Display.DEFAULT_DISPLAY
            }
            if (navigationOnly) {
                // Floe's own UI is never traversed: return metadata only,
                // without reading the title, root class or any child node.
                windows.forEach { info -> runCatching { info.recycle() } }
                return navigationOnlyCapture(
                    owner = owner,
                    ticket = ticket,
                    packageName = packageName,
                    windowId = windowId,
                    windowType = windowType,
                    displayId = displayId,
                    capturedAtElapsedRealtimeMillis = SystemClock.elapsedRealtime(),
                    screenshotSupport = PhoneControlPolicy.screenshotSupport(
                        Build.VERSION.SDK_INT,
                    ),
                )
            }
            val className = root.className?.toString()
            // Any protected credential may be echoed into another app. Do
            // not bootstrap trusted labels from a different foreground app.
            val guarded = guardTickets.isNotEmpty()
            val rawWindowTitle = if (guarded) null else runCatching { window?.title?.toString() }.getOrNull()
            // Package-only metadata for the other visible windows, read inside
            // this explicit authorized observation (never in an accessibility
            // callback). A later package-less window event can be attributed
            // to a known transient/own overlay instead of failing closed;
            // node text and tree content are never read here.
            val windowIdentities = readWindowIdentities(windows, windowId)
            windows.forEach { info -> runCatching { info.recycle() } }

            // Protected windows never need node text at all. Establish that
            // before reading so password/credential/system surfaces are not
            // copied into a local raw list even transiently.
            val preProtected = PhoneControlPolicy.isProtectedWindow(
                packageName = packageName,
                className = className,
                windowType = windowType,
                hasPassword = false,
                keyguardLocked = keyguardLocked,
            )

            val raw = ArrayList<PhoneControlRawNode>(
                minOf(req.maxNodes * 2, PhoneControlLimits.MAX_SCAN_NODES),
            )
            // A guard from another window requires output masking, but it is
            // not evidence that this window contains a password field.
            val stats = ReadStats()
            val safeGuardAncestors = HashMap<List<Int>, Boolean>()
            val safeGuardParents = HashMap<List<Int>, com.floe.android.contracts.SensitiveUiLabelIdentity>()
            // Level order spends one global node budget across the real tree:
            // a deep form is read completely when it fits, while a genuinely
            // wide screen still yields its shallow toolbar/FAB controls first.
            // The walker retains at most one handle per level, not a queue of
            // live AccessibilityNodeInfo objects.
            val walk = PhoneControlCaptureWalk.walk(
                root = root,
                adapter = AccessibilityCaptureTreeAdapter,
                maxNodes = PhoneControlLimits.MAX_SCAN_NODES,
                maxDepth = req.maxDepth,
                deadlineElapsedRealtimeMillis = SystemClock.elapsedRealtime() +
                    PhoneControlLimits.SCAN_TIME_BUDGET_MS,
                nowElapsedRealtimeMillis = { SystemClock.elapsedRealtime() },
                isCancelled = isCancelled,
            ) { path, depth, node, insideScrollable ->
                readNode(
                    node = node,
                    path = path,
                    depth = depth,
                    redactAllText = preProtected,
                    guarded = guarded,
                    guardPackage = packageName,
                    guardWindow = windowId,
                    guardDisplay = displayId,
                    safeGuardAncestors = safeGuardAncestors,
                    safeGuardParents = safeGuardParents,
                    labelKey = guardState.labelKey,
                    refreshFromSource = !cacheCleared,
                    insideScrollable = insideScrollable,
                    stats = stats,
                    out = raw,
                )
            }
            // An obsolete or cancelled source is an unavailable capture, never
            // a partial tree presented as the verified effect of the previous
            // action. A time/node bound remains an honest bounded observation.
            if (walk.obsolete || walk.cancelled || stats.obsoleteNode ||
                PhoneControlSensitiveGuard.state(service) != guardState) return null

            val protectedWindow = PhoneControlPolicy.isProtectedWindow(
                packageName = packageName,
                className = className,
                windowType = windowType,
                hasPassword = stats.hasSensitiveField,
                keyguardLocked = keyguardLocked,
            )
            val redactAllText = protectedWindow
            val shaped = PhoneControlTreeShaper.shape(
                raw = raw,
                request = req,
                redactAllText = redactAllText,
                depthLimited = walk.depthLimited,
                nodeLimited = walk.nodeLimited,
                timeLimited = walk.timedOut,
                fieldLimited = stats.textLimited,
            )
            val capturedActionables = shaped.nodes.count { node ->
                node.visible && node.enabled && (
                    node.clickable || node.editable || node.scrollable ||
                        node.advertises(PhoneControlNodeAction.CLICK) ||
                        node.actions.any { it.isScrollAction }
                    )
            }
            val eligibleActionables = raw.count { node ->
                node.visible && node.enabled &&
                    (node.clickable || node.editable || node.scrollable ||
                        PhoneControlNodeAction.CLICK in node.actions ||
                        node.actions.any { it.isScrollAction }) &&
                    node.depth <= req.maxDepth &&
                    (req.includeInvisible || node.visible)
            }
            val capturedAt = SystemClock.elapsedRealtime()
            val observation = PhoneControlObservation(
                observationId = UUID.randomUUID().toString(),
                owner = owner,
                fenceGeneration = ticket.fenceGeneration,
                pageGeneration = ticket.pageGeneration,
                capturedAtElapsedRealtimeMillis = capturedAt,
                expiresAtElapsedRealtimeMillis = capturedAt + PhoneControlLimits.OBSERVATION_TTL_MS,
                packageName = PhoneControlText.bound(
                    PhoneControlText.clean(packageName),
                    PhoneControlLimits.MAX_PACKAGE_CHARS,
                ).text,
                windowId = windowId,
                windowType = windowType,
                windowTitle = if (redactAllText) null else PhoneControlText.bound(
                    PhoneControlText.clean(rawWindowTitle),
                    200,
                ).text,
                displayId = displayId,
                rootClassName = PhoneControlText.bound(PhoneControlText.clean(className), 200).text,
                sensitiveWindow = redactAllText || guarded || stats.hasSensitiveField,
                screenshotSupport = PhoneControlPolicy.screenshotSupport(Build.VERSION.SDK_INT),
                nodes = shaped.nodes,
                truncated = shaped.truncated,
                maxDepthReached = shaped.maxDepthReached,
                scannedNodeCount = raw.size,
                omittedActionableCount =
                    (eligibleActionables - capturedActionables).coerceAtLeast(0),
                scanLimited = shaped.scanLimited,
                timeLimited = shaped.timeLimited,
                selectionLimited = shaped.selectionLimited,
                textLimited = shaped.textLimited,
            )
            return PhoneControlCapture(
                observation = observation,
                records = shaped.records,
                fingerprint = shaped.fingerprint,
                protectedWindow = protectedWindow,
                hasSensitiveField = stats.hasSensitiveField,
                windowIdentities = windowIdentities,
            )
        } finally {
            @Suppress("DEPRECATION")
            runCatching { root.recycle() }
        }
    }

    /**
     * Package-only identity inventory of the other visible windows. This runs
     * only inside an explicit observation: no node text, view id, title or
     * child tree is read, and each root handle is recycled immediately.
     */
    @Suppress("DEPRECATION")
    private fun readWindowIdentities(
        windows: List<AccessibilityWindowInfo>,
        observedWindowId: Int,
    ): List<PhoneControlWindowIdentity> {
        val identities = ArrayList<PhoneControlWindowIdentity>(minOf(windows.size, MAX_WINDOW_IDENTITIES))
        for (info in windows.asSequence().take(MAX_WINDOW_IDENTITIES)) {
            val windowId = info.id
            if (windowId < 0 || windowId == observedWindowId) continue
            val windowRoot = runCatching { info.root }.getOrNull() ?: continue
            val packageName = try {
                runCatching { windowRoot.packageName?.toString() }.getOrNull()
            } finally {
                runCatching { windowRoot.recycle() }
            }
            val bounded = PhoneControlText.bound(
                PhoneControlText.clean(packageName),
                PhoneControlLimits.MAX_PACKAGE_CHARS,
            ).text ?: continue
            identities += PhoneControlWindowIdentity(windowId, bounded)
        }
        return identities
    }

    /**
     * Reads one live node into primitives. The walker owns traversal,
     * budgeting, cancellation and recycling; this function owns the
     * privacy/refresh checks and the raw field caps. It returns the node's
     * child count from the same handle so the walker never needs to re-read a
     * node merely to schedule it.
     */
    private fun readNode(
        node: AccessibilityNodeInfo,
        path: List<Int>,
        depth: Int,
        redactAllText: Boolean,
        guarded: Boolean,
        guardPackage: String?,
        guardWindow: Int,
        guardDisplay: Int,
        safeGuardAncestors: MutableMap<List<Int>, Boolean>,
        safeGuardParents: MutableMap<List<Int>, com.floe.android.contracts.SensitiveUiLabelIdentity>,
        labelKey: com.floe.android.contracts.SensitiveUiLabelKey?,
        refreshFromSource: Boolean,
        insideScrollable: Boolean,
        stats: ReadStats,
        out: MutableList<PhoneControlRawNode>,
    ): PhoneControlCaptureWalk.Visit {
        // The root was already refreshed before its identity/privacy checks.
        if (refreshFromSource && path.isNotEmpty() &&
            !runCatching { node.refresh() }.getOrDefault(false)
        ) {
            stats.obsoleteNode = true
            return PhoneControlCaptureWalk.Visit(
                state = PhoneControlCaptureWalk.VisitState.OBSOLETE,
            )
        }
        val viewId = runCatching { node.viewIdResourceName }.getOrNull()
        // Unknown field flags are never evidence that reading it for an
        // identity check is safe. Redact an unknown password flag and leave
        // semantic matching disabled unless both flags were read as false.
        val passwordFlag = runCatching { node.isPassword }.getOrNull()
        val editableFlag = runCatching { node.isEditable }.getOrNull()
        val password = passwordFlag != false
        val sensitive = password || PhoneControlText.isSensitiveViewId(viewId)
        if (sensitive) stats.hasSensitiveField = true
        val redact = redactAllText || sensitive

        /**
         * One raw text field is capped before it enters the local scan. The
         * final projection applies the ordinary text budget as well; this cap
         * only stops an extreme field from making the bounded scan itself
         * unbounded in memory.
         */
        fun rawText(value: String?): String? {
            if (value == null) return null
            // One past the shaper's input cap, so a selected over-long field
            // is also marked truncated on the node itself.
            val limit = PhoneControlLimits.MAX_FIELD_CHARS * 4 + 1
            if (value.length <= limit) return value
            stats.textLimited = true
            return value.substring(0, limit)
        }

        val bounds = Rect()
        runCatching { node.getBoundsInScreen(bounds) }
        val scrollable = runCatching { node.isScrollable }.getOrDefault(false)
        val observedChildCount = runCatching { node.childCount }.getOrNull()
        val childCount = observedChildCount ?: 0
        // Platform-declared actions/range are read from the SAME live handle.
        // They are real metadata (never class-name inference) and are used both
        // for honest presentation and for dispatch-time capability checks.
        val range = runCatching {
            node.rangeInfo?.let { info ->
                PhoneControlRangeInfo(
                    min = info.min,
                    max = info.max,
                    current = info.current,
                ).takeIf { it.valid }
            }
        }.getOrNull()
        val advertisedActions = runCatching { node.actionList }.getOrNull()
        val actions = readActions(advertisedActions)
        val className = node.className?.toString().orEmpty()
        val clickable = runCatching { node.isClickable }.getOrDefault(false) ||
            PhoneControlNodeAction.CLICK in actions
        val ancestrySafe = !guarded || path.indices.all { safeGuardAncestors[path.take(it)] == true }
        val safeFlags = !redact && editableFlag == false && passwordFlag == false &&
            advertisedActions != null && PhoneControlNodeAction.SET_TEXT !in actions
        val safeCandidate = guarded && ancestrySafe && safeFlags
        if (guarded) safeGuardAncestors[path] = safeCandidate
        val expected = if (safeCandidate) PhoneControlSensitiveGuard.baseline(
            PhoneControlSensitiveGuard.Key(guardPackage, guardWindow, guardDisplay, path, className, viewId),
        ) else null
        val parentMatches = if (expected?.safeParent != null) {
            safeGuardParents[path.dropLast(1)] == expected.safeParent
        } else clickable
        if (safeFlags && ancestrySafe && clickable && guardPackage != null) {
            val identity = com.floe.android.contracts.SensitiveUiLabelIdentity(
                guardPackage, guardWindow, guardDisplay, path, className, viewId,
            )
            if (identity.isWellFormed()) safeGuardParents[path] = identity
        }
        // Fingerprint only real, complete, pre-guard fields; never compute a
        // new trusted baseline after a sensitive write has been armed.
        val ordinaryText = if (!guarded && !redact) node.text?.toString() else null
        val ordinaryDescription = if (!guarded && !redact) node.contentDescription?.toString() else null
        val directSafeParent = path.isNotEmpty() && safeGuardParents.containsKey(path.dropLast(1))
        val safeLabelHmac = if (!guarded && safeFlags && (clickable || directSafeParent) && labelKey != null &&
            (ordinaryText != null || ordinaryDescription != null)
        ) com.floe.android.contracts.SensitiveUiLabelFingerprint.hmac(labelKey, ordinaryText, ordinaryDescription) else null
        // A guarded input or unknown field never has any text getter called.
        // Read a previously known button or button-child label once, then expose it only if
        // its bounded identity is unchanged. Do not read hints in this mode.
        val safeLabel = PhoneControlGuardedLabel.read(
            guarded = guarded, platformSensitive = redact, editable = editableFlag, password = passwordFlag,
            actionsKnown = advertisedActions != null, setText = PhoneControlNodeAction.SET_TEXT in actions,
            clickable = parentMatches, safeAncestry = ancestrySafe,
            key = labelKey, expectedDigest = expected?.digest,
            text = { runCatching { node.text?.toString() }.getOrNull() },
            description = { runCatching { node.contentDescription?.toString() }.getOrNull() },
        )
        val guardRedacted = guarded && safeLabel == null
        out += PhoneControlRawNode(
            path = path,
            parentPath = if (path.isEmpty()) null else path.dropLast(1),
            depth = depth,
            className = className,
            packageName = node.packageName?.toString(),
            viewId = viewId,
            text = if (redact || guardRedacted) null else if (guarded) rawText(safeLabel?.text) else rawText(ordinaryText),
            contentDescription = if (redact || guardRedacted) null else if (guarded) rawText(safeLabel?.description) else
                rawText(ordinaryDescription),
            hintText = if (redact || guarded) null else
                runCatching { rawText(node.hintText?.toString()) }.getOrNull(),
            bounds = PhoneControlBounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
            visible = runCatching { node.isVisibleToUser }.getOrDefault(false),
            clickable = runCatching { node.isClickable }.getOrDefault(false),
            editable = editableFlag ?: false,
            scrollable = scrollable,
            enabled = runCatching { node.isEnabled }.getOrDefault(false),
            selected = runCatching { node.isSelected }.getOrDefault(false),
            checkable = runCatching { node.isCheckable }.getOrDefault(false),
            checked = runCatching { node.isChecked }.getOrDefault(false),
            password = password,
            insideScrollable = insideScrollable,
            actions = actions,
            focusable = runCatching { node.isFocusable }.getOrDefault(false),
            focused = runCatching { node.isFocused }.getOrDefault(false),
            range = range,
            semanticEligible = editableFlag == false && passwordFlag == false && !redact && !guardRedacted &&
                advertisedActions != null && PhoneControlNodeAction.SET_TEXT !in actions,
            semanticFlagsUnavailable = editableFlag == null || passwordFlag == null ||
                advertisedActions == null,
            observedChildCount = observedChildCount ?: -1,
            privacyRedacted = guardRedacted,
            safeLabelHmac = safeLabelHmac,
        )
        return PhoneControlCaptureWalk.Visit(
            childCount = childCount,
            scrollable = scrollable,
        )
    }

    /**
     * Maps the platform's advertised action list into the closed action set.
     * Only ids the running platform actually exposes are read; version guards
     * keep API-30 IME and API-23 directional scroll constants off older
     * devices (API 28 is the supported floor, but the guard stays explicit).
     */
    private fun readActions(
        advertised: List<AccessibilityNodeInfo.AccessibilityAction>?,
    ): Set<PhoneControlNodeAction> {
        if (advertised == null) return emptySet()
        if (advertised.isEmpty()) return emptySet()
        val actions = LinkedHashSet<PhoneControlNodeAction>(minOf(advertised.size, 8))
        for (action in advertised) {
            when (action?.id) {
                AccessibilityNodeInfo.ACTION_CLICK ->
                    actions += PhoneControlNodeAction.CLICK
                AccessibilityNodeInfo.ACTION_LONG_CLICK ->
                    actions += PhoneControlNodeAction.LONG_CLICK
                AccessibilityNodeInfo.ACTION_FOCUS ->
                    actions += PhoneControlNodeAction.FOCUS
                AccessibilityNodeInfo.ACTION_CLEAR_FOCUS ->
                    actions += PhoneControlNodeAction.CLEAR_FOCUS
                AccessibilityNodeInfo.ACTION_SET_TEXT ->
                    actions += PhoneControlNodeAction.SET_TEXT
                AccessibilityNodeInfo.ACTION_SCROLL_FORWARD ->
                    actions += PhoneControlNodeAction.SCROLL_FORWARD
                AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD ->
                    actions += PhoneControlNodeAction.SCROLL_BACKWARD
            }
        }
        if (Build.VERSION.SDK_INT >= 30 &&
            advertised.any {
                it?.id == AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id
            }
        ) {
            actions += PhoneControlNodeAction.IME_ENTER
        }
        if (Build.VERSION.SDK_INT >= 23) {
            val directional = arrayOf(
                AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP to
                    PhoneControlNodeAction.SCROLL_UP,
                AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN to
                    PhoneControlNodeAction.SCROLL_DOWN,
                AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT to
                    PhoneControlNodeAction.SCROLL_LEFT,
                AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT to
                    PhoneControlNodeAction.SCROLL_RIGHT,
            )
            for ((declared, mapped) in directional) {
                if (advertised.any { it?.id == declared.id }) actions += mapped
            }
        }
        return actions
    }

    /** Adapter is stateless: every acquired child is recycled by the walker. */
    private object AccessibilityCaptureTreeAdapter :
        PhoneControlCaptureTreeAdapter<AccessibilityNodeInfo> {
        override fun child(node: AccessibilityNodeInfo, index: Int): AccessibilityNodeInfo? =
            runCatching { node.getChild(index) }.getOrNull()

        override fun recycle(node: AccessibilityNodeInfo) {
            @Suppress("DEPRECATION")
            runCatching { node.recycle() }
        }
    }

    private companion object {
        /** Bound the per-observation root-package reads to the book's capacity. */
        const val MAX_WINDOW_IDENTITIES = 32
    }
}
