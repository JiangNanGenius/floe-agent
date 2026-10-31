// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import android.app.KeyguardManager
import java.util.UUID
import kotlin.math.max

/**
 * One live phone-control session, owned by the bound AccessibilityService and
 * always called on the service main thread. It enforces the fence/observation
 * generations, resolves node paths against a fresh tree, dispatches actual
 * AccessibilityService/node actions, waits for a bounded settle interval and
 * re-observes. It never retries an action blindly and never reports framework
 * acceptance as semantic success.
 */
internal class PhoneControlSession(
    private val service: PhoneControlAccessibilityService,
) {
    val fence = PhoneControlFence()

    private val mainHandler = Handler(Looper.getMainLooper())
    private val snapshotter = PhoneControlSnapshotter(service)
    private val screenshotter = PhoneControlScreenshotter(service)
    private val powerManager = service.getSystemService(Context.POWER_SERVICE) as? PowerManager
    private val keyguardManager =
        service.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager

    private var closed = false
    private var latest: ObservationRecord? = null
    private var homePackage: String? = null
    private var inFlightId: String? = null
    private var pendingAction: ((PhoneControlResult<PhoneControlActionResult>) -> Unit)? = null
    private var pendingActionState: PendingActionState? = null
    private var pendingScreenshot: ((PhoneControlResult<PhoneControlScreenshot>) -> Unit)? = null
    private var pendingClientToken: String? = null
    private var pendingTimeout: Runnable? = null

    private var pendingEffectivePackages: Set<String> = emptySet()
    private var pendingAllowGlobalNavigation = false
    private var lastWindowChangeAt = 0L
    private var lastContentChangeAt = 0L
    private var suppressUserTouchUntil = 0L

    private data class ObservationRecord(
        val observation: PhoneControlObservation,
        val records: Map<String, PhoneControlNodeRecord>,
        val fingerprint: Long,
        val protectedWindow: Boolean,
        val hasSensitiveField: Boolean,
        val request: PhoneControlObserveRequest,
    )

    private class PendingActionState(val actionName: String) {
        var dispatch: PhoneControlDispatch = PhoneControlDispatch.NOT_DISPATCHED
        var gestureCompleted: Boolean? = null
        var note: String? = null
    }

    private enum class NodeRequirement { CLICK, SET_TEXT, SCROLL, SWIPE }

    // ---------------------------------------------------------------------
    // Observation
    // ---------------------------------------------------------------------

    fun observe(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
        request: PhoneControlObserveRequest,
    ): PhoneControlResult<PhoneControlObservation> {
        if (closed) return PhoneControlResult.Denied(PhoneControlDenial.SERVICE_DISCONNECTED)
        PhoneControlPolicy.grantDenial(principal, grant)?.let {
            return PhoneControlResult.Denied(it)
        }
        if (inFlightId != null) return PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT)
        lockedDenial()?.let { return it }
        claimDenial(principal.owner)?.let { return it }
        PhoneControlRuntime.publish()
        val ticket = fence.ticket(principal.owner)
            ?: return PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN)
        val capture = snapshotter.capture(
            owner = principal.owner,
            ticket = ticket,
            request = request.normalized(),
            keyguardLocked = keyguardLocked(),
        ) ?: return PhoneControlResult.Failed(
            PhoneControlFailure.OBSERVATION_FAILED,
            "active window content is unavailable",
        )
        val effective = PhoneControlPolicy.effectivePackages(principal, grant)
        // A Floe foreground is a zero-node navigation-only metadata capture.
        // It is accepted only when the live grant allows global navigation, so
        // an armed task can leave Floe without ever reading Floe's UI.
        val denial = PhoneControlPolicy.observationDenial(
            packageName = capture.observation.packageName,
            effectivePackages = effective,
            homePackage = homePackage(),
            allowGlobalNavigation = grant.allowGlobalNavigation,
            navigationMetadataOnly = capture.observation.navigationOnly,
        )
        if (denial != null) {
            PhoneControlRuntime.publish()
            return PhoneControlResult.Denied(denial)
        }
        latest = record(capture, request.normalized())
        PhoneControlRuntime.publish()
        return PhoneControlResult.Ok(capture.observation)
    }

    fun arm(principal: PhoneControlPrincipal): PhoneControlResult<PhoneControlStatus> {
        if (closed) return PhoneControlResult.Denied(PhoneControlDenial.SERVICE_DISCONNECTED)
        if (inFlightId != null) {
            return PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT)
        }
        lockedDenial()?.let { return it }
        when (val claim = fence.arm(principal.owner)) {
            is PhoneControlFence.Claim.Blocked ->
                return PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(claim.blocker))
            PhoneControlFence.Claim.ForeignRun ->
                return PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN)
            PhoneControlFence.Claim.Ok -> Unit
        }
        latest = null
        PhoneControlRuntime.publish()
        return PhoneControlResult.Ok(PhoneControlRuntime.snapshot())
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    fun perform(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
        observationId: String,
        action: PhoneControlAction,
        operationToken: String,
        complete: (PhoneControlResult<PhoneControlActionResult>) -> Unit,
    ) {
        if (closed) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.SERVICE_DISCONNECTED))
            return
        }
        PhoneControlPolicy.grantDenial(principal, grant)?.let {
            complete(PhoneControlResult.Denied(it))
            return
        }
        if (inFlightId != null) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT))
            return
        }
        lockedDenial()?.let {
            complete(it)
            return
        }
        val record = latest
        val early = validateBeforeDispatch(record, principal, observationId, action, grant)
        if (early != null) {
            complete(early)
            return
        }
        val activeRecord = record ?: run {
            complete(PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION))
            return
        }
        val effective = PhoneControlPolicy.effectivePackages(principal, grant)
        val opId = UUID.randomUUID().toString()
        beginAction(
            opId = opId,
            operationToken = operationToken,
            actionName = action.wireName,
            complete = complete,
            record = activeRecord,
            effective = effective,
            allowGlobalNavigation = grant.allowGlobalNavigation,
        )
        try {
            execute(effective, activeRecord, action, opId)
        } catch (error: Exception) {
            finishAction(PhoneControlResult.Failed(PhoneControlFailure.INTERNAL_ERROR))
        }
    }

    private fun validateBeforeDispatch(
        record: ObservationRecord?,
        principal: PhoneControlPrincipal,
        observationId: String,
        action: PhoneControlAction,
        grant: PhoneControlGrant,
    ): PhoneControlResult.Denied? {
        if (record == null || record.observation.observationId != observationId) {
            return PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        }
        if (record.observation.owner != principal.owner) {
            return PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN)
        }
        val now = SystemClock.elapsedRealtime()
        if (now > record.observation.expiresAtElapsedRealtimeMillis) {
            return PhoneControlResult.Denied(PhoneControlDenial.OBSERVATION_EXPIRED)
        }
        val verdict = fence.validate(
            PhoneControlFence.Ticket(
                owner = record.observation.owner,
                fenceGeneration = record.observation.fenceGeneration,
                pageGeneration = record.observation.pageGeneration,
            ),
        )
        verdictDenial(verdict)?.let { return it }
        // A Floe foreground observation is zero-node metadata. It may use only
        // the existing global Back/Home or Launch path below; a click, text,
        // scroll or swipe can never be authorized from it even with a forged ref.
        PhoneControlPolicy.navigationOnlyActionDenial(
            navigationOnly = record.observation.navigationOnly,
            allowGlobalNavigation = grant.allowGlobalNavigation,
            action = action,
        )?.let { return PhoneControlResult.Denied(it) }
        when (action) {
            is PhoneControlAction.Click ->
                record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
            is PhoneControlAction.SetText -> {
                if (action.text.length > PhoneControlLimits.MAX_SET_TEXT_CHARS) {
                    return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
                }
                val node = record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
                if (!node.editable) return PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_EDITABLE)
                PhoneControlPolicy.fieldActionDenial(node)?.let {
                    return PhoneControlResult.Denied(it)
                }
            }
            is PhoneControlAction.Scroll -> {
                val node = record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
                if (!node.scrollable) return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_NOT_SCROLLABLE,
                )
            }
            is PhoneControlAction.Swipe -> {
                val node = record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
                PhoneControlPolicy.fieldActionDenial(node)?.let {
                    return PhoneControlResult.Denied(it)
                }
                val horizontal = action.direction == PhoneControlSwipeDirection.LEFT ||
                    action.direction == PhoneControlSwipeDirection.RIGHT
                val span = if (horizontal) node.bounds.width else node.bounds.height
                if (span < PhoneControlLimits.MIN_SWIPE_PX) {
                    return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
                }
            }
            PhoneControlAction.Back, PhoneControlAction.Home -> {
                if (!grant.allowGlobalNavigation) {
                    return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
                }
            }
            is PhoneControlAction.Launch -> {
                val effective = PhoneControlPolicy.effectivePackages(principal, grant)
                PhoneControlPolicy.launchDenial(action.packageName, effective)?.let {
                    return PhoneControlResult.Denied(it)
                }
            }
        }
        val protected = PhoneControlPolicy.nodeActionDenial(
            packageName = record.observation.packageName,
            className = record.observation.rootClassName,
            windowType = record.observation.windowType,
            hasPassword = record.hasSensitiveField,
            keyguardLocked = keyguardLocked(),
        )
        if (protected != null && action !is PhoneControlAction.Back &&
            action !is PhoneControlAction.Home && action !is PhoneControlAction.Launch
        ) {
            return PhoneControlResult.Denied(protected)
        }
        return null
    }

    private fun execute(
        effective: Set<String>,
        record: ObservationRecord,
        action: PhoneControlAction,
        opId: String,
    ) {
        when (action) {
            is PhoneControlAction.Click -> nodeAction(
                effective, record, action.nodeRef, NodeRequirement.CLICK, opId,
                actionName = action.wireName, scrollDirection = null, setText = null,
            )
            is PhoneControlAction.SetText -> nodeAction(
                effective, record, action.nodeRef, NodeRequirement.SET_TEXT, opId,
                actionName = action.wireName, scrollDirection = null, setText = action.text,
            )
            is PhoneControlAction.Scroll -> nodeAction(
                effective, record, action.nodeRef, NodeRequirement.SCROLL, opId,
                actionName = action.wireName, scrollDirection = action.direction, setText = null,
            )
            is PhoneControlAction.Swipe -> swipeAction(
                effective, record, action.nodeRef, action.direction, opId,
            )
            PhoneControlAction.Back -> globalAction(record, ACCESSIBILITY_GLOBAL_BACK, "back", opId)
            PhoneControlAction.Home -> globalAction(record, ACCESSIBILITY_GLOBAL_HOME, "home", opId)
            is PhoneControlAction.Launch -> launchAction(record, action.packageName, opId)
        }
    }

    private fun nodeAction(
        effective: Set<String>,
        record: ObservationRecord,
        nodeRef: String,
        requirement: NodeRequirement,
        opId: String,
        actionName: String,
        scrollDirection: PhoneControlScrollDirection?,
        setText: String?,
    ) {
        val nodeRecord = record.records[nodeRef]
        if (nodeRecord == null) {
            finishAction(PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE))
            return
        }
        val root = service.rootInActiveWindow
        if (root == null) {
            finishAction(PhoneControlResult.Failed(PhoneControlFailure.OBSERVATION_FAILED))
            return
        }
        try {
            foregroundDenial(root, record)?.let {
                finishAction(it)
                return
            }
            val node = resolveNode(root, nodeRecord.path)
            if (node == null) {
                finishAction(PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE))
                return
            }
            try {
                validateResolved(node, nodeRecord, record, effective, requirement)?.let {
                    finishAction(PhoneControlResult.Denied(it))
                    return
                }
                suppressOwnInput()
                val accepted = when (requirement) {
                    NodeRequirement.CLICK -> node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    NodeRequirement.SET_TEXT -> node.performAction(
                        AccessibilityNodeInfo.ACTION_SET_TEXT,
                        Bundle().apply {
                            putCharSequence(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                                setText.orEmpty(),
                            )
                        },
                    )
                    NodeRequirement.SCROLL -> node.performAction(
                        if (scrollDirection == PhoneControlScrollDirection.FORWARD) {
                            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                        } else {
                            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD
                        },
                    )
                    NodeRequirement.SWIPE -> false
                }
                if (!accepted) {
                    completeAfterDispatch(
                        record, opId, actionName, PhoneControlDispatch.REJECTED, null,
                        PhoneControlFailure.ACTION_REJECTED,
                        "the framework refused the node action; no blind retry",
                    )
                } else {
                    completeAfterDispatch(
                        record, opId, actionName, PhoneControlDispatch.ACCEPTED, null,
                        null,
                        "framework accepted the action; re-observation is the effect check",
                    )
                }
            } finally {
                if (node !== root) {
                    @Suppress("DEPRECATION")
                    runCatching { node.recycle() }
                }
            }
        } finally {
            @Suppress("DEPRECATION")
            runCatching { root.recycle() }
        }
    }

    private fun swipeAction(
        effective: Set<String>,
        record: ObservationRecord,
        nodeRef: String,
        direction: PhoneControlSwipeDirection,
        opId: String,
    ) {
        val nodeRecord = record.records[nodeRef]
        if (nodeRecord == null) {
            finishAction(PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE))
            return
        }
        val root = service.rootInActiveWindow
        if (root == null) {
            finishAction(PhoneControlResult.Failed(PhoneControlFailure.OBSERVATION_FAILED))
            return
        }
        try {
            foregroundDenial(root, record)?.let {
                finishAction(it)
                return
            }
            val node = resolveNode(root, nodeRecord.path)
            if (node == null) {
                finishAction(PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE))
                return
            }
            try {
                validateResolved(node, nodeRecord, record, effective, NodeRequirement.SWIPE)?.let {
                    finishAction(PhoneControlResult.Denied(it))
                    return
                }
            } finally {
                if (node !== root) {
                    @Suppress("DEPRECATION")
                    runCatching { node.recycle() }
                }
            }
        } finally {
            @Suppress("DEPRECATION")
            runCatching { root.recycle() }
        }

        val bounds = nodeRecord.bounds
        if (bounds.isEmpty) {
            finishAction(PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT))
            return
        }
        val path = swipePath(bounds, direction) ?: run {
            finishAction(PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT))
            return
        }
        val duration = 260L
        suppressUserTouchUntil = SystemClock.elapsedRealtime() + duration + 500
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, duration))
            .build()
        val callback = object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                onGestureFinished(opId, completed = true)
            }

            override fun onCancelled(gestureDescription: GestureDescription?) {
                onGestureFinished(opId, completed = false)
            }
        }
        val dispatched = runCatching {
            service.dispatchGesture(gesture, callback, mainHandler)
        }.getOrDefault(false)
        if (!dispatched) {
            finishAction(PhoneControlResult.Failed(PhoneControlFailure.GESTURE_NOT_STARTED))
            return
        }
        pendingActionState?.dispatch = PhoneControlDispatch.ACCEPTED
        pendingActionState?.note =
            "gesture dispatched; completion is not semantic success and the platform exposes no mid-gesture cancel"
        rescheduleTimeout(opId, PhoneControlLimits.GESTURE_TIMEOUT_MS)
    }

    private fun onGestureFinished(opId: String, completed: Boolean) {
        if (inFlightId != opId) return
        val state = pendingActionState ?: return
        val record = pendingActionRecord
        if (record == null) {
            finishAction(PhoneControlResult.Failed(PhoneControlFailure.INTERNAL_ERROR))
            return
        }
        state.gestureCompleted = completed
        rescheduleTimeout(opId, PhoneControlLimits.ACTION_TIMEOUT_MS)
        if (!completed) {
            completeAfterDispatch(
                record,
                opId,
                state.actionName,
                PhoneControlDispatch.REJECTED,
                false,
                PhoneControlFailure.GESTURE_CANCELLED,
                "gesture was cancelled; partial input may already have been delivered",
            )
            return
        }
        completeAfterDispatch(
            record,
            opId,
            state.actionName,
            PhoneControlDispatch.ACCEPTED,
            true,
            null,
            "gesture completed; semantic effect is verified only by re-observation",
        )
    }

    private var pendingActionRecord: ObservationRecord? = null

    private fun globalAction(
        record: ObservationRecord,
        globalAction: Int,
        actionName: String,
        opId: String,
    ) {
        // Back/Home are system-wide and must remain usable when an IME or a
        // system overlay owns the active window. The observation ticket,
        // principal and grant are still validated by the caller.
        suppressOwnInput()
        val accepted = runCatching { service.performGlobalAction(globalAction) }.getOrDefault(false)
        if (!accepted) {
            completeAfterDispatch(
                record, opId, actionName, PhoneControlDispatch.REJECTED, null,
                PhoneControlFailure.ACTION_REJECTED,
                "the framework refused the global action",
            )
        } else {
            completeAfterDispatch(
                record, opId, actionName, PhoneControlDispatch.ACCEPTED, null, null,
                "global action accepted; re-observation is the effect check",
            )
        }
    }

    private fun launchAction(record: ObservationRecord, packageName: String, opId: String) {
        // The target package is authorized by the live grant; launching it is
        // not tied to a node in the currently active window (an IME or system
        // overlay may be showing). The post-action observation reads back what
        // actually became foreground.
        val intent = runCatching {
            service.packageManager.getLaunchIntentForPackage(packageName)
        }.getOrNull()
        if (intent == null) {
            finishAction(
                PhoneControlResult.Unavailable(
                    PhoneControlUnavailable.LAUNCH_TARGET_UNAVAILABLE,
                    "no launchable activity is visible for the authorized package",
                ),
            )
            return
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        suppressOwnInput()
        val started = runCatching { service.startActivity(intent) }
        if (started.isFailure) {
            completeAfterDispatch(
                record, opId, "launch", PhoneControlDispatch.REJECTED, null,
                PhoneControlFailure.ACTION_REJECTED,
                "the platform refused the activity launch",
            )
            return
        }
        completeAfterDispatch(
            record, opId, "launch", PhoneControlDispatch.ACCEPTED, null, null,
            "launch requested; the resulting foreground state is read back by re-observation",
        )
    }

    private fun foregroundDenial(
        root: AccessibilityNodeInfo,
        record: ObservationRecord,
    ): PhoneControlResult.Denied? {
        val currentPackage = root.packageName?.toString()
        return when {
            root.windowId != record.observation.windowId ->
                PhoneControlResult.Denied(PhoneControlDenial.WINDOW_CHANGED)
            currentPackage != record.observation.packageName ->
                PhoneControlResult.Denied(PhoneControlDenial.FOREGROUND_CHANGED)
            else -> null
        }
    }

    private fun validateResolved(
        node: AccessibilityNodeInfo,
        nodeRecord: PhoneControlNodeRecord,
        record: ObservationRecord,
        effective: Set<String>,
        requirement: NodeRequirement,
    ): PhoneControlDenial? {
        val className = node.className?.toString().orEmpty()
        if (className != nodeRecord.className) return PhoneControlDenial.NODE_UNAVAILABLE
        val viewId = runCatching { node.viewIdResourceName }.getOrNull()
        if (viewId != nodeRecord.viewId) return PhoneControlDenial.NODE_UNAVAILABLE
        if (!runCatching { node.isVisibleToUser }.getOrDefault(false)) {
            return PhoneControlDenial.NODE_UNAVAILABLE
        }
        if (!nodeRecord.bounds.isEmpty) {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            if (!nodeRecord.bounds.contains(rect.centerX(), rect.centerY())) {
                return PhoneControlDenial.NODE_UNAVAILABLE
            }
        }
        val nodePackage = node.packageName?.toString() ?: nodeRecord.packageName
        PhoneControlPolicy.nodeTargetDenial(
            nodePackage,
            record.observation.packageName,
            effective,
        )?.let { return it }
        return when (requirement) {
            NodeRequirement.CLICK ->
                if (runCatching { node.isClickable }.getOrDefault(false)) null
                else PhoneControlDenial.NODE_NOT_CLICKABLE
            NodeRequirement.SET_TEXT -> when {
                !runCatching { node.isEditable }.getOrDefault(false) ->
                    PhoneControlDenial.NODE_NOT_EDITABLE
                runCatching { node.isPassword }.getOrDefault(false) ->
                    PhoneControlDenial.SENSITIVE_FIELD
                else -> null
            }
            NodeRequirement.SCROLL ->
                if (runCatching { node.isScrollable }.getOrDefault(false)) null
                else PhoneControlDenial.NODE_NOT_SCROLLABLE
            NodeRequirement.SWIPE -> null
        }
    }

    private fun resolveNode(
        root: AccessibilityNodeInfo,
        path: List<Int>,
    ): AccessibilityNodeInfo? {
        var current: AccessibilityNodeInfo = root
        for (index in path) {
            val child = runCatching { current.getChild(index) }.getOrNull()
            if (child == null) {
                if (current !== root) {
                    @Suppress("DEPRECATION")
                    runCatching { current.recycle() }
                }
                return null
            }
            if (current !== root) {
                @Suppress("DEPRECATION")
                runCatching { current.recycle() }
            }
            current = child
        }
        return current
    }

    private fun swipePath(
        bounds: PhoneControlBounds,
        direction: PhoneControlSwipeDirection,
    ): Path? {
        val insetX = max(1, bounds.width / 5)
        val insetY = max(1, bounds.height / 5)
        val left = bounds.left + insetX
        val right = bounds.right - insetX
        val top = bounds.top + insetY
        val bottom = bounds.bottom - insetY
        if (right <= left || bottom <= top) return null
        val centerX = (left + right) / 2
        val centerY = (top + bottom) / 2
        val (startX, startY, endX, endY) = when (direction) {
            PhoneControlSwipeDirection.UP -> listOf(centerX, bottom, centerX, top)
            PhoneControlSwipeDirection.DOWN -> listOf(centerX, top, centerX, bottom)
            PhoneControlSwipeDirection.LEFT -> listOf(right, centerY, left, centerY)
            PhoneControlSwipeDirection.RIGHT -> listOf(left, centerY, right, centerY)
        }
        if (max(kotlin.math.abs(endX - startX), kotlin.math.abs(endY - startY)) <
            PhoneControlLimits.MIN_SWIPE_PX
        ) {
            return null
        }
        return Path().apply {
            moveTo(startX.toFloat(), startY.toFloat())
            lineTo(endX.toFloat(), endY.toFloat())
        }
    }

    // ---------------------------------------------------------------------
    // Screenshot
    // ---------------------------------------------------------------------

    fun screenshot(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
        observationId: String?,
        request: PhoneControlScreenshotRequest,
        operationToken: String,
        complete: (PhoneControlResult<PhoneControlScreenshot>) -> Unit,
    ) {
        if (closed) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.SERVICE_DISCONNECTED))
            return
        }
        PhoneControlPolicy.grantDenial(principal, grant)?.let {
            complete(PhoneControlResult.Denied(it))
            return
        }
        if (inFlightId != null) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT))
            return
        }
        lockedDenial()?.let {
            complete(it)
            return
        }
        if (!grant.allowScreenshot) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED))
            return
        }
        val support = PhoneControlPolicy.screenshotSupport(android.os.Build.VERSION.SDK_INT)
        if (support == PhoneControlScreenshotSupport.NONE) {
            complete(PhoneControlResult.Unavailable(PhoneControlUnavailable.SCREENSHOT_UNSUPPORTED))
            return
        }
        val windowScoped = observationId != null
        val record = if (windowScoped) {
            val current = latest
            if (current == null || current.observation.observationId != observationId) {
                complete(PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION))
                return
            }
            if (current.observation.owner != principal.owner) {
                complete(PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN))
                return
            }
            val verdict = fence.validate(
                PhoneControlFence.Ticket(
                    current.observation.owner,
                    current.observation.fenceGeneration,
                    current.observation.pageGeneration,
                ),
            )
            verdictDenial(verdict)?.let {
                complete(it)
                return
            }
            if (SystemClock.elapsedRealtime() > current.observation.expiresAtElapsedRealtimeMillis) {
                complete(PhoneControlResult.Denied(PhoneControlDenial.OBSERVATION_EXPIRED))
                return
            }
            if (support != PhoneControlScreenshotSupport.WINDOW) {
                complete(
                    PhoneControlResult.Unavailable(
                        PhoneControlUnavailable.WINDOW_SCREENSHOT_UNSUPPORTED,
                    ),
                )
                return
            }
            current
        } else {
            claimDenial(principal.owner)?.let {
                complete(it)
                return
            }
            PhoneControlRuntime.publish()
            // A display capture still needs a privacy check: read the active
            // window internally so a protected/password screen is never
            // captured merely because the caller omitted an observation.
            val ticket = fence.ticket(principal.owner)
                ?: run {
                    complete(PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN))
                    return
                }
            val capture = snapshotter.capture(
                owner = principal.owner,
                ticket = ticket,
                request = PhoneControlObserveRequest(),
                keyguardLocked = keyguardLocked(),
            ) ?: run {
                complete(PhoneControlResult.Failed(PhoneControlFailure.OBSERVATION_FAILED))
                return
            }
            val effective = PhoneControlPolicy.effectivePackages(principal, grant)
            PhoneControlPolicy.observationDenial(
                packageName = capture.observation.packageName,
                effectivePackages = effective,
                homePackage = homePackage(),
                allowGlobalNavigation = grant.allowGlobalNavigation,
                // A navigation-only Floe record never authorizes a capture.
                navigationMetadataOnly = false,
            )?.let {
                complete(PhoneControlResult.Denied(it))
                return
            }
            val local = record(capture, PhoneControlObserveRequest())
            // A denied screenshot's internal privacy probe is not an issued
            // observation. Never promote the Floe metadata probe into the
            // session's actionable record.
            if (latest == null && !local.observation.navigationOnly) latest = local
            local
        }
        PhoneControlPolicy.observationDenial(
            packageName = record.observation.packageName,
            effectivePackages = PhoneControlPolicy.effectivePackages(principal, grant),
            homePackage = homePackage(),
            allowGlobalNavigation = grant.allowGlobalNavigation,
            // Screenshot authorization is separate from safe navigation.
            navigationMetadataOnly = false,
        )?.let {
            complete(PhoneControlResult.Denied(it))
            return
        }
        val denial = PhoneControlPolicy.screenshotDenial(
            allowScreenshot = grant.allowScreenshot,
            keyguardLocked = keyguardLocked(),
            protectedWindow = record.protectedWindow,
            hasPassword = record.hasSensitiveField,
        )
        if (denial != null) {
            complete(PhoneControlResult.Denied(denial))
            return
        }
        // A window-scoped capture targets the recorded window id directly;
        // the system refuses a missing/secure/stale window instead of silently
        // widening to the display. A display capture without an observation
        // was already checked against the freshly observed active window.
        val scopedWindowId = if (windowScoped) record.observation.windowId else null
        if (scopedWindowId != null && scopedWindowId <= 0) {
            complete(PhoneControlResult.Unavailable(PhoneControlUnavailable.WINDOW_SCREENSHOT_UNSUPPORTED))
            return
        }
        if (!windowScoped) {
            // A whole-display capture includes every visible window. Refuse if
            // an observable IME, notification shade, dialog, toast, foreign
            // app or other overlay would be captured. Window-scoped API 34
            // capture does not use this scan and is never widened to display.
            displayCaptureGuard(record.observation.displayId, record)?.let {
                complete(PhoneControlResult.Denied(it))
                return
            }
        }
        val captureTicket = PhoneControlFence.Ticket(
            owner = record.observation.owner,
            fenceGeneration = record.observation.fenceGeneration,
            pageGeneration = record.observation.pageGeneration,
        )
        val captureStamp = PhoneControlCaptureStamp(
            fenceGeneration = record.observation.fenceGeneration,
            pageGeneration = record.observation.pageGeneration,
            windowId = record.observation.windowId,
            packageName = record.observation.packageName,
        )
        val opId = UUID.randomUUID().toString()
        pendingScreenshot = complete
        pendingClientToken = operationToken
        inFlightId = opId
        scheduleTimeout(opId, PhoneControlLimits.SCREENSHOT_TIMEOUT_MS)
        screenshotter.capture(
            displayId = record.observation.displayId,
            windowId = scopedWindowId,
            request = request.normalized(),
        ) { result ->
            if (inFlightId != opId) return@capture
            // The system capture is asynchronous. Revalidate the exact
            // fence/page/window/package that passed the privacy check; if the
            // page changed, discard the image and never blind-recapture.
            val verdict = fence.validate(captureTicket)
            val target = currentCaptureTarget(windowScoped, record)
            val observedAllowed = PhoneControlPolicy.observationDenial(
                packageName = record.observation.packageName,
                effectivePackages = PhoneControlPolicy.effectivePackages(principal, grant),
                homePackage = homePackage(),
                allowGlobalNavigation = grant.allowGlobalNavigation,
                navigationMetadataOnly = false,
            ) == null
            val overlayGuard = if (!windowScoped) {
                displayCaptureGuard(record.observation.displayId, record)
            } else {
                null
            }
            val state = fence.state()
            val guard = overlayGuard ?: captureCompletionDenial(
                stamp = captureStamp,
                verdict = verdict,
                currentFenceGeneration = state.fenceGeneration,
                currentPageGeneration = state.pageGeneration,
                currentWindowId = target.windowId,
                currentPackage = target.packageName,
                observedPackageAllowed = observedAllowed,
            )
            val mapped = when {
                guard != null -> PhoneControlResult.Denied(guard)
                result is PhoneControlResult.Failed &&
                    result.reason == PhoneControlFailure.CAPTURE_SECURE_WINDOW ->
                    PhoneControlResult.Denied(PhoneControlDenial.PROTECTED_WINDOW)
                else -> result
            }
            finishScreenshot(mapped)
        }
    }

    // ---------------------------------------------------------------------
    // Fences / lifecycle events
    // ---------------------------------------------------------------------

    fun stop() = applyGlobalBlocker(PhoneControlBlocker.STOPPED)

    fun takeover() = applyGlobalBlocker(PhoneControlBlocker.TAKEN_OVER)

    private fun applyGlobalBlocker(blocker: PhoneControlBlocker) {
        if (closed) return
        fence.block(blocker)
        latest = null
        abortInFlight(blocker, "phone control was fenced: ${blocker.name}")
        PhoneControlRuntime.publish()
    }

    fun release(owner: PhoneControlOwner) {
        if (closed) return
        if (fence.release(owner)) {
            latest = null
            abortInFlight(null, "the owning run ended; in-flight effect is unverified")
            PhoneControlRuntime.publish()
        }
    }

    fun onScreenOff() {
        if (closed) return
        fence.block(PhoneControlBlocker.LOCKED)
        latest = null
        abortInFlight(PhoneControlBlocker.LOCKED, "the device screen turned off")
        PhoneControlRuntime.publish()
    }

    fun onScreenInteractive() {
        if (closed) return
        if (!keyguardLocked()) {
            fence.clear(PhoneControlBlocker.LOCKED)
            PhoneControlRuntime.publish()
        }
    }

    fun onWindowChanged() {
        if (closed) return
        fence.onPageChanged()
        latest = null
        lastWindowChangeAt = SystemClock.elapsedRealtime()
        PhoneControlRuntime.publish()
    }

    fun onContentChanged() {
        lastContentChangeAt = SystemClock.elapsedRealtime()
    }

    fun onPlatformUserInteraction() {
        if (closed) return
        val now = SystemClock.elapsedRealtime()
        if (now <= suppressUserTouchUntil) return
        if (fence.state().owner == null && inFlightId == null) return
        fence.block(PhoneControlBlocker.USER_TOUCH)
        latest = null
        abortInFlight(PhoneControlBlocker.USER_TOUCH, "a user touch interrupted the run")
        PhoneControlRuntime.publish()
    }

    fun onServiceInterrupt() {
        if (closed) return
        abortInFlight(null, "the accessibility service interrupted feedback")
        PhoneControlRuntime.publish()
    }

    fun shutdown(blocker: PhoneControlBlocker) {
        if (closed) return
        closed = true
        fence.block(blocker)
        latest = null
        abortInFlight(blocker, "the accessibility service is no longer connected")
        screenshotter.close()
        pendingTimeout?.let { mainHandler.removeCallbacks(it) }
        pendingTimeout = null
        PhoneControlRuntime.publish()
    }

    // ---------------------------------------------------------------------
    // Dispatch / settle / completion
    // ---------------------------------------------------------------------

    private fun beginAction(
        opId: String,
        operationToken: String,
        actionName: String,
        complete: (PhoneControlResult<PhoneControlActionResult>) -> Unit,
        record: ObservationRecord,
        effective: Set<String>,
        allowGlobalNavigation: Boolean,
    ) {
        inFlightId = opId
        pendingClientToken = operationToken
        pendingAction = complete
        pendingActionState = PendingActionState(actionName)
        pendingActionRecord = record
        pendingEffectivePackages = effective
        pendingAllowGlobalNavigation = allowGlobalNavigation
        scheduleTimeout(opId, PhoneControlLimits.ACTION_TIMEOUT_MS)
    }

    /** Coroutine cancellation is not a fence: it aborts only this client's op. */
    fun cancelOperation(operationToken: String) {
        if (closed || pendingClientToken != operationToken) return
        abortInFlight(null, "the caller cancelled the operation")
        PhoneControlRuntime.publish()
    }

    private fun completeAfterDispatch(
        record: ObservationRecord,
        opId: String,
        actionName: String,
        dispatch: PhoneControlDispatch,
        gestureCompleted: Boolean?,
        failure: PhoneControlFailure?,
        note: String?,
    ) {
        if (inFlightId != opId) return
        pendingActionState?.dispatch = dispatch
        pendingActionState?.gestureCompleted = gestureCompleted
        pendingActionState?.note = note
        pendingActionRecord = record
        if (dispatch != PhoneControlDispatch.NOT_DISPATCHED) {
            suppressUserTouchUntil = max(
                suppressUserTouchUntil,
                SystemClock.elapsedRealtime() + 500,
            )
        }
        settleThenObserve(record, opId) { capture ->
            if (inFlightId != opId) return@settleThenObserve
            val observation = capture?.observation
            val blocker = fence.state().blocker
            if (failure != null) {
                val detail = when {
                    blocker != null -> "$note; fenced before the post-action observation"
                    observation == null -> "$note; post-action observation unavailable"
                    else -> note
                }
                finishAction(PhoneControlResult.Failed(failure, detail, observation))
                return@settleThenObserve
            }
            if (blocker != null) {
                finishAction(
                    PhoneControlResult.Failed(
                        PhoneControlFailure.CANCELLED,
                        "fenced after dispatch (${blocker.name}); the injected input may already have been delivered and the effect is unverified",
                    ),
                )
                return@settleThenObserve
            }
            val changed = if (observation != null) {
                PhoneControlPolicy.screenChanged(
                    previousFingerprint = record.fingerprint,
                    previousPackage = record.observation.packageName,
                    previousWindowId = record.observation.windowId,
                    nextFingerprint = capture!!.fingerprint,
                    nextPackage = observation.packageName,
                    nextWindowId = observation.windowId,
                )
            } else {
                null
            }
            finishAction(
                PhoneControlResult.Ok(
                    PhoneControlActionResult(
                        action = actionName,
                        dispatch = dispatch,
                        gestureCompleted = gestureCompleted,
                        observation = observation,
                        screenChanged = changed,
                        note = if (observation == null) {
                            "$note; post-action observation unavailable"
                        } else {
                            "$note; screen change is a bounded fingerprint heuristic"
                        },
                    ),
                ),
            )
        }
    }

    private fun settleThenObserve(
        record: ObservationRecord,
        opId: String,
        complete: (PhoneControlCapture?) -> Unit,
    ) {
        val started = SystemClock.elapsedRealtime()
        fun poll() {
            if (closed || inFlightId != opId) {
                complete(null)
                return
            }
            if (fence.state().blocker != null) {
                complete(null)
                return
            }
            if (keyguardLocked()) {
                fence.block(PhoneControlBlocker.LOCKED)
                latest = null
                PhoneControlRuntime.publish()
                complete(null)
                return
            }
            val now = SystemClock.elapsedRealtime()
            val lastActivity = max(lastWindowChangeAt, lastContentChangeAt)
            val quiet = now - lastActivity >= PhoneControlLimits.SETTLE_QUIET_MS
            val minimumElapsed = now - started >= PhoneControlLimits.SETTLE_MIN_MS
            val timedOut = now - started >= PhoneControlLimits.SETTLE_TIMEOUT_MS
            if ((minimumElapsed && quiet) || timedOut) {
                val ticket = fence.ticket(record.observation.owner)
                if (ticket != null) {
                    val capture = snapshotter.capture(
                        owner = record.observation.owner,
                        ticket = ticket,
                        request = record.request,
                        keyguardLocked = false,
                    )
                    if (capture != null) {
                        val denial = PhoneControlPolicy.observationDenial(
                            packageName = capture.observation.packageName,
                            effectivePackages = pendingEffectivePackages,
                            homePackage = homePackage(),
                            allowGlobalNavigation = pendingAllowGlobalNavigation,
                            navigationMetadataOnly = capture.observation.navigationOnly,
                        )
                        if (denial == null) {
                            latest = record(capture, record.request)
                            complete(capture)
                            return
                        }
                    }
                }
                if (timedOut) {
                    complete(null)
                    return
                }
            }
            mainHandler.postDelayed({ poll() }, 60)
        }
        mainHandler.postDelayed({ poll() }, 80)
    }

    private fun record(
        capture: PhoneControlCapture,
        request: PhoneControlObserveRequest,
    ): ObservationRecord = ObservationRecord(
        observation = capture.observation,
        records = capture.records,
        fingerprint = capture.fingerprint,
        protectedWindow = capture.protectedWindow,
        hasSensitiveField = capture.hasSensitiveField,
        request = request,
    )

    private fun scheduleTimeout(opId: String, timeoutMs: Long) {
        pendingTimeout?.let { mainHandler.removeCallbacks(it) }
        val runnable = Runnable { onOperationTimeout(opId) }
        pendingTimeout = runnable
        mainHandler.postDelayed(runnable, timeoutMs)
    }

    private fun rescheduleTimeout(opId: String, timeoutMs: Long) {
        if (inFlightId != opId) return
        scheduleTimeout(opId, timeoutMs)
    }

    private fun onOperationTimeout(opId: String) {
        if (inFlightId != opId) return
        val state = pendingActionState
        if (pendingAction != null) {
            if (state != null && state.dispatch != PhoneControlDispatch.NOT_DISPATCHED) {
                finishAction(
                    PhoneControlResult.Failed(
                        PhoneControlFailure.TIMEOUT,
                        "timed out after dispatch; the injected input may have been delivered and the effect is unverified",
                    ),
                )
            } else {
                finishAction(PhoneControlResult.Failed(PhoneControlFailure.TIMEOUT))
            }
        } else if (pendingScreenshot != null) {
            finishScreenshot(PhoneControlResult.Failed(PhoneControlFailure.TIMEOUT))
        }
    }

    private fun finishAction(result: PhoneControlResult<PhoneControlActionResult>) {
        val callback = pendingAction ?: return
        pendingAction = null
        pendingActionState = null
        pendingActionRecord = null
        pendingClientToken = null
        pendingEffectivePackages = emptySet()
        pendingAllowGlobalNavigation = false
        clearInFlight()
        runCatching { callback(result) }
        PhoneControlRuntime.publish()
    }

    private fun finishScreenshot(result: PhoneControlResult<PhoneControlScreenshot>) {
        val callback = pendingScreenshot ?: return
        pendingScreenshot = null
        pendingClientToken = null
        clearInFlight()
        runCatching { callback(result) }
        PhoneControlRuntime.publish()
    }

    private fun clearInFlight() {
        inFlightId = null
        pendingTimeout?.let { mainHandler.removeCallbacks(it) }
        pendingTimeout = null
    }

    private fun abortInFlight(blocker: PhoneControlBlocker?, reason: String) {
        if (pendingAction != null) {
            val state = pendingActionState
            if (state != null && state.dispatch != PhoneControlDispatch.NOT_DISPATCHED) {
                finishAction(
                    PhoneControlResult.Failed(
                        PhoneControlFailure.CANCELLED,
                        "$reason; the injected input may already have been delivered and the effect is unverified",
                    ),
                )
            } else {
                finishAction(
                    if (blocker != null) {
                        PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(blocker), reason)
                    } else {
                        PhoneControlResult.Failed(PhoneControlFailure.CANCELLED, reason)
                    },
                )
            }
        } else if (pendingScreenshot != null) {
            finishScreenshot(
                if (blocker != null) {
                    PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(blocker), reason)
                } else {
                    PhoneControlResult.Failed(PhoneControlFailure.CANCELLED, reason)
                },
            )
        }
    }

    // ---------------------------------------------------------------------
    // Small helpers
    // ---------------------------------------------------------------------

    private fun claimDenial(owner: PhoneControlOwner): PhoneControlResult.Denied? =
        when (val claim = fence.claim(owner)) {
            is PhoneControlFence.Claim.Blocked ->
                PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(claim.blocker))
            PhoneControlFence.Claim.ForeignRun ->
                PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN)
            PhoneControlFence.Claim.Ok -> null
        }

    private fun lockedDenial(): PhoneControlResult.Denied? {
        if (keyguardLocked() || powerManager?.isInteractive == false) {
            fence.block(PhoneControlBlocker.LOCKED)
            latest = null
            PhoneControlRuntime.publish()
            return PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED)
        }
        return null
    }


    private data class CaptureTarget(val windowId: Int?, val packageName: String?)

    @Suppress("DEPRECATION")
    private fun displayCaptureGuard(
        displayId: Int,
        record: ObservationRecord,
    ): PhoneControlDenial? {
        val windows = runCatching { service.windows }.getOrDefault(emptyList())
        // If the window inventory is unavailable we cannot prove that a
        // whole-display image is scoped to the observed app. Refuse.
        if (windows.isEmpty()) return PhoneControlDenial.PROTECTED_WINDOW
        val observed = ArrayList<PhoneControlDisplayWindow>(windows.size)
        for (info in windows) {
            try {
                if (android.os.Build.VERSION.SDK_INT >= 30 && info.displayId != displayId) {
                    continue
                }
                val bounds = Rect()
                runCatching { info.getBoundsInScreen(bounds) }
                val root = runCatching { info.root }.getOrNull()
                val packageName = root?.packageName?.toString()
                root?.let { runCatching { it.recycle() } }
                observed += PhoneControlDisplayWindow(
                    windowId = info.id,
                    packageName = packageName,
                    windowType = info.type,
                    bounds = PhoneControlBounds(
                        bounds.left,
                        bounds.top,
                        bounds.right,
                        bounds.bottom,
                    ),
                )
            } finally {
                runCatching { info.recycle() }
            }
        }
        val metrics = service.resources.displayMetrics
        return displayCaptureDenial(
            windows = observed,
            observedWindowId = record.observation.windowId,
            observedPackage = record.observation.packageName,
            homePackage = homePackage(),
            displayBounds = PhoneControlBounds(0, 0, metrics.widthPixels, metrics.heightPixels),
        )
    }

    @Suppress("DEPRECATION")
    private fun currentCaptureTarget(
        windowScoped: Boolean,
        record: ObservationRecord,
    ): CaptureTarget {
        if (!windowScoped) {
            val root = service.rootInActiveWindow ?: return CaptureTarget(null, null)
            return try {
                CaptureTarget(root.windowId, root.packageName?.toString())
            } finally {
                runCatching { root.recycle() }
            }
        }
        val windows = runCatching { service.windows }.getOrDefault(emptyList())
        try {
            val window = windows.firstOrNull { it.id == record.observation.windowId }
                ?: return CaptureTarget(null, null)
            val root = runCatching { window.root }.getOrNull()
            val packageName = root?.packageName?.toString()
            root?.let { runCatching { it.recycle() } }
            return CaptureTarget(window.id, packageName)
        } finally {
            windows.forEach { runCatching { it.recycle() } }
        }
    }

    private fun suppressOwnInput() {
        suppressUserTouchUntil = max(
            suppressUserTouchUntil,
            SystemClock.elapsedRealtime() + 600,
        )
    }

    private fun keyguardLocked(): Boolean =
        runCatching { keyguardManager?.isKeyguardLocked == true }.getOrDefault(true)

    private fun homePackage(): String? {
        homePackage?.let { return it }
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val resolved = runCatching {
            service.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }.getOrNull()
        val name = resolved?.activityInfo?.packageName
        homePackage = name
        return name
    }

    private fun verdictDenial(verdict: PhoneControlFence.Verdict): PhoneControlResult.Denied? =
        when (verdict) {
            PhoneControlFence.Verdict.Open -> null
            is PhoneControlFence.Verdict.Blocked ->
                PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(verdict.blocker))
            PhoneControlFence.Verdict.ForeignRun ->
                PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN)
            PhoneControlFence.Verdict.StaleFence ->
                PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
            PhoneControlFence.Verdict.StalePage ->
                PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        }

    private companion object {
        const val ACCESSIBILITY_GLOBAL_BACK = AccessibilityService.GLOBAL_ACTION_BACK
        const val ACCESSIBILITY_GLOBAL_HOME = AccessibilityService.GLOBAL_ACTION_HOME
    }
}
