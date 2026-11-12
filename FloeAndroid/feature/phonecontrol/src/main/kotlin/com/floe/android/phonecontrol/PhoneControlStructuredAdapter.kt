// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/**
 * Bounded ADB structured page as delivered by the typed privileged service.
 * [path] is the service's opaque child-index locator and is never model-facing;
 * [ref] is the only identifier returned to the model.
 */
data class PhoneControlStructuredNode(
    val ref: String,
    val parentRef: String?,
    val path: List<Int>,
    val depth: Int,
    val className: String,
    val packageName: String?,
    val viewId: String?,
    val text: String?,
    val contentDescription: String?,
    val hintText: String?,
    val bounds: PhoneControlBounds,
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
    val range: PhoneControlRangeInfo?,
)

data class PhoneControlStructuredPage(
    val observationId: String,
    val packageName: String?,
    val windowId: Int,
    val windowType: Int?,
    val windowTitle: String?,
    val displayId: Int,
    val rootClassName: String?,
    val rotation: Int,
    val capturedAtElapsedRealtimeMillis: Long,
    val expiresAtElapsedRealtimeMillis: Long,
    val generation: Long,
    val userInteractionRevision: Long,
    val nodes: List<PhoneControlStructuredNode>,
    val scannedNodeCount: Int,
    val truncated: Boolean,
    val maxDepthReached: Boolean,
    val scanLimited: Boolean,
    val timeLimited: Boolean,
    val textLimited: Boolean,
    val sensitiveWindow: Boolean,
    val navigationOnly: Boolean,
    /** At least one password/credential field is present; capture is refused. */
    val hasSensitiveField: Boolean = false,
) {
    val appObservationId: String
        get() = if (observationId.startsWith(PhoneControlBackend.ADB_OBSERVATION_PREFIX)) {
            observationId
        } else {
            PhoneControlBackend.ADB_OBSERVATION_PREFIX + observationId
        }
}

/**
 * Converts the privileged service's primitives into the SAME observation model
 * used by the accessibility path. The existing PhoneControlTreeShaper remains
 * the single local structure processor: it applies visibility/depth/node/text
 * bounds, redacts password/sensitive fields, preserves real parent/row
 * relationships and computes the same honest truncation reasons. No label,
 * action or global completeness is invented from a short summary.
 */
data class PhoneControlStructuredMapped(
    val observation: PhoneControlObservation,
    /** App-ref -> the service's opaque node ref used for dispatch. */
    val refAliases: Map<String, String>,
)

object PhoneControlStructuredAdapter {

    fun toObservation(
        page: PhoneControlStructuredPage,
        owner: PhoneControlOwner,
        fenceGeneration: Long,
        request: PhoneControlObserveRequest = PhoneControlObserveRequest(),
    ): PhoneControlObservation = toMapped(page, owner, fenceGeneration, request).observation

    fun toMapped(
        page: PhoneControlStructuredPage,
        owner: PhoneControlOwner,
        fenceGeneration: Long,
        request: PhoneControlObserveRequest = PhoneControlObserveRequest(),
    ): PhoneControlStructuredMapped {
        val req = request.normalized()
        if (page.navigationOnly) {
            return PhoneControlStructuredMapped(
                observation = PhoneControlObservation(
                observationId = page.appObservationId,
                owner = owner,
                fenceGeneration = fenceGeneration,
                pageGeneration = page.generation,
                capturedAtElapsedRealtimeMillis = page.capturedAtElapsedRealtimeMillis,
                expiresAtElapsedRealtimeMillis = page.expiresAtElapsedRealtimeMillis,
                packageName = page.packageName?.take(PhoneControlLimits.MAX_PACKAGE_CHARS),
                windowId = page.windowId,
                windowType = page.windowType,
                windowTitle = null,
                displayId = page.displayId,
                rootClassName = null,
                sensitiveWindow = true,
                screenshotSupport = PhoneControlScreenshotSupport.DISPLAY,
                nodes = emptyList(),
                truncated = false,
                maxDepthReached = false,
                navigationOnly = true,
                hasSensitiveField = false,
                backend = PhoneControlBackend.ADB_UI_AUTOMATION,
                provenance = "adbUiAutomation",
                ),
                refAliases = emptyMap(),
            )
        }
        val raw = page.nodes.map { node ->
            PhoneControlRawNode(
                path = node.path,
                parentPath = if (node.path.isEmpty()) null else node.path.dropLast(1),
                depth = node.depth,
                className = node.className,
                packageName = node.packageName,
                viewId = node.viewId,
                text = node.text,
                contentDescription = node.contentDescription,
                hintText = node.hintText,
                bounds = node.bounds,
                visible = node.visible,
                clickable = node.clickable,
                editable = node.editable,
                scrollable = node.scrollable,
                enabled = node.enabled,
                selected = node.selected,
                checkable = node.checkable,
                checked = node.checked,
                password = node.password,
                insideScrollable = node.insideScrollable,
                actions = node.actions.mapNotNull(::actionOf).toSet(),
                focusable = node.focusable,
                focused = node.focused,
                range = node.range,
            )
        }
        val shaped = PhoneControlTreeShaper.shape(
            raw = raw,
            request = req,
            redactAllText = page.sensitiveWindow,
            depthLimited = page.maxDepthReached,
            nodeLimited = page.truncated,
            timeLimited = page.timeLimited,
            fieldLimited = page.textLimited,
        )
        val capturedActionables = shaped.nodes.count { actionable(it) }
        val eligibleActionables = raw.count { node ->
            (req.includeInvisible || node.visible) && node.enabled &&
                node.depth <= req.maxDepth &&
                (node.clickable || node.editable || node.scrollable ||
                    PhoneControlNodeAction.CLICK in node.actions ||
                    node.actions.any { it.isScrollAction })
        }
        val pathToServerRef = page.nodes.associate { it.path to it.ref }
        val refAliases = shaped.records.mapNotNull { (ref, record) ->
            pathToServerRef[record.path]?.let { serverRef -> ref to serverRef }
        }.toMap()
        val observation = PhoneControlObservation(
            observationId = page.appObservationId,
            owner = owner,
            fenceGeneration = fenceGeneration,
            pageGeneration = page.generation,
            capturedAtElapsedRealtimeMillis = page.capturedAtElapsedRealtimeMillis,
            expiresAtElapsedRealtimeMillis = page.expiresAtElapsedRealtimeMillis,
            packageName = page.packageName?.take(PhoneControlLimits.MAX_PACKAGE_CHARS),
            windowId = page.windowId,
            windowType = page.windowType,
            windowTitle = page.windowTitle,
            displayId = page.displayId,
            rootClassName = page.rootClassName,
            sensitiveWindow = shaped.sensitiveWindow || page.sensitiveWindow || page.hasSensitiveField,
            screenshotSupport = PhoneControlScreenshotSupport.DISPLAY,
            nodes = shaped.nodes,
            truncated = shaped.truncated || page.truncated,
            maxDepthReached = shaped.maxDepthReached || page.maxDepthReached,
            scannedNodeCount = page.scannedNodeCount.coerceAtLeast(
                page.nodes.size.coerceAtLeast(shaped.nodes.size),
            ),
            omittedActionableCount = (eligibleActionables - capturedActionables).coerceAtLeast(0),
            scanLimited = shaped.scanLimited || page.scanLimited,
            timeLimited = shaped.timeLimited || page.timeLimited,
            selectionLimited = shaped.selectionLimited,
            textLimited = shaped.textLimited,
            backend = PhoneControlBackend.ADB_UI_AUTOMATION,
            provenance = "adbUiAutomation",
        )
        return PhoneControlStructuredMapped(observation, refAliases)
    }

    private fun actionOf(token: String): PhoneControlNodeAction? = when (token) {
        "click" -> PhoneControlNodeAction.CLICK
        "longClick" -> PhoneControlNodeAction.LONG_CLICK
        "focus" -> PhoneControlNodeAction.FOCUS
        "clearFocus" -> PhoneControlNodeAction.CLEAR_FOCUS
        "ime" -> PhoneControlNodeAction.IME_ENTER
        "setText" -> PhoneControlNodeAction.SET_TEXT
        "scrollForward" -> PhoneControlNodeAction.SCROLL_FORWARD
        "scrollBackward" -> PhoneControlNodeAction.SCROLL_BACKWARD
        "scrollUp" -> PhoneControlNodeAction.SCROLL_UP
        "scrollDown" -> PhoneControlNodeAction.SCROLL_DOWN
        "scrollLeft" -> PhoneControlNodeAction.SCROLL_LEFT
        "scrollRight" -> PhoneControlNodeAction.SCROLL_RIGHT
        else -> null
    }

    private fun actionable(node: PhoneControlNode): Boolean =
        node.visible && node.enabled &&
            (node.clickable || node.editable || node.scrollable ||
                node.advertises(PhoneControlNodeAction.CLICK) ||
                node.actions.any { it.isScrollAction })
}
