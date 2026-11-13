// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import android.content.Context
import android.os.SystemClock
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.SystemOperation
import com.floe.android.rootsystem.UiAction
import com.floe.android.rootsystem.UiActRequest
import com.floe.android.rootsystem.UiActResult
import com.floe.android.rootsystem.UiBackendStatus
import com.floe.android.rootsystem.UiBounds
import com.floe.android.rootsystem.UiDispatchOutcome
import com.floe.android.rootsystem.UiNode
import com.floe.android.rootsystem.UiObservation
import com.floe.android.rootsystem.UiObserveRequest
import com.floe.android.rootsystem.UiScreenshotChunk
import com.floe.android.rootsystem.UiScreenshotInfo
import com.floe.android.rootsystem.UiScreenshotRequest
import com.floe.android.rootsystem.ipc.BinderProtocol
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

/**
 * Bounded typed UI adaptation over the real AndroidUiAutomationBridge.
 *
 * This layer owns only ephemeral observation/screenshot state. It creates no
 * authorization: every operation is already fenced by the live grant at the
 * binder and controller. Observation/page ids are opaque, single-owner and
 * short-lived; a new observation supersedes action use of an older page.
 */
internal class UiOperations(
    context: Context,
    private val identity: ServerIdentity,
) : Closeable {

    class UiException(val code: String) : Exception(code)

    private data class StoredObservation(
        val taskId: String,
        val runId: String,
        val epoch: Long,
        val grantId: String,
        val requestId: String,
        val page: AndroidUiAutomationBridge.Page,
        val expiresAtElapsed: Long,
        val userRevision: Long,
    )

    private data class StoredScreenshot(
        val requestId: String,
        val taskId: String,
        val runId: String,
        val epoch: Long,
        val grantId: String,
        val bytes: ByteArray,
        val mimeType: String,
        val width: Int,
        val height: Int,
        val originalWidth: Int,
        val originalHeight: Int,
        val rotation: Int,
        val displayId: Int,
        val capturedAtElapsed: Long,
        val expiresAtElapsed: Long,
    )

    private val bridge = AndroidUiAutomationBridge(context)
    private val gate = Any()
    private val operationGate = Any()
    private val observations = LinkedHashMap<String, StoredObservation>()
    private val latestByOwner = HashMap<String, String>()
    private val screenshots = LinkedHashMap<String, StoredScreenshot>()
    private val generation = AtomicLong(0L)

    fun supported(): Boolean = bridge.supported()

    fun status(): UiBackendStatus {
        if (identity.mode != com.floe.android.rootsystem.policy.AccessPolicy.MODE_ADB) {
            return UiBackendStatus(
                ready = false,
                live = true,
                mode = identity.mode,
                effectiveUid = identity.serverUid,
                protocolVersion = BinderProtocol.VERSION,
                reason = "adb_backend_required",
            )
        }
        if (!bridge.supported()) {
            return UiBackendStatus(
                ready = false,
                live = true,
                mode = identity.mode,
                effectiveUid = identity.serverUid,
                protocolVersion = BinderProtocol.VERSION,
                reason = "ui_automation_unavailable",
            )
        }
        return try {
            synchronized(operationGate) { bridge.ensureConnected() }
            UiBackendStatus(
                ready = true,
                live = true,
                mode = identity.mode,
                effectiveUid = identity.serverUid,
                protocolVersion = BinderProtocol.VERSION,
                capabilities = CAPABILITIES,
                screenSupport = "display",
                userInteractionElapsedRealtimeMillis =
                    bridge.lastUserInteractionElapsedRealtime(),
                observationTtlMillis = AndroidUiAutomationBridge.OBSERVATION_TTL_MS,
                maxNodes = AndroidUiAutomationBridge.MAX_NODES,
            )
        } catch (e: AndroidUiAutomationBridge.UiBridgeException) {
            UiBackendStatus(
                ready = false,
                live = true,
                mode = identity.mode,
                effectiveUid = identity.serverUid,
                protocolVersion = BinderProtocol.VERSION,
                capabilities = CAPABILITIES,
                screenSupport = "display",
                reason = e.code,
            )
        } catch (_: Throwable) {
            UiBackendStatus(
                ready = false,
                live = true,
                mode = identity.mode,
                effectiveUid = identity.serverUid,
                protocolVersion = BinderProtocol.VERSION,
                capabilities = CAPABILITIES,
                screenSupport = "display",
                reason = "ui_automation_unavailable",
            )
        }
    }

    fun observe(
        claim: OperationClaim,
        targets: Set<String>,
        request: UiObserveRequest,
        cancelled: () -> Boolean,
    ): UiObservation {
        if (targets.isEmpty()) throw UiException("ui_target_required")
        sweep()
        val pageGeneration = generation.incrementAndGet()
        val page = try {
            synchronized(operationGate) {
                bridge.observe(targets, request, cancelled, pageGeneration)
            }
        } catch (e: AndroidUiAutomationBridge.UiBridgeException) {
            throw UiException(e.code)
        }
        synchronized(gate) {
            val id = page.observationId
            observations[id] = StoredObservation(
                taskId = claim.taskId,
                runId = claim.runId,
                epoch = claim.epoch,
                grantId = claim.grantId,
                requestId = claim.requestId,
                page = page,
                expiresAtElapsed = page.expiresAtElapsed,
                userRevision = page.userInteractionRevision,
            )
            latestByOwner[ownerKey(claim)] = id
            trimObservationsLocked()
        }
        return page.toObservation()
    }

    fun act(
        claim: OperationClaim,
        targets: Set<String>,
        request: UiActRequest,
        cancelled: () -> Boolean,
    ): UiActResult {
        if (targets.isEmpty()) throw UiException("ui_target_required")
        sweep()
        if (request.action == UiAction.LAUNCH) {
            if (request.observationId.isNotEmpty() || request.nodeRef != null) {
                throw UiException("ui_observation_invalid")
            }
            val execution = try {
                synchronized(operationGate) {
                    bridge.act(
                        page = null,
                        nodeRef = null,
                        action = request.action,
                        direction = null,
                        text = null,
                        sensitiveIntent = false,
                        ownerToken = ownerToken(claim),
                        requestId = claim.requestId,
                        targetPackage = request.targetPackage,
                        targets = targets,
                        cancelled = cancelled,
                    )
                }
            } catch (e: AndroidUiAutomationBridge.UiBridgeException) {
                throw UiException(e.code)
            }
            return UiActResult(
                action = request.action.wireName,
                dispatch = execution.dispatch,
                method = execution.method,
                screenChanged = null,
                observation = null,
                detailCode = execution.detailCode,
                detail = execution.detail,
            )
        }
        val page = synchronized(gate) {
            val stored = observations[request.observationId]
                ?: throw UiException("ui_observation_invalid")
            if (stored.taskId != claim.taskId || stored.runId != claim.runId ||
                stored.epoch != claim.epoch || stored.grantId != claim.grantId
            ) {
                throw UiException("ui_observation_invalid")
            }
            if (latestByOwner[ownerKey(claim)] != request.observationId) {
                throw UiException("stale_observation")
            }
            if (SystemClock.elapsedRealtime() > stored.expiresAtElapsed) {
                observations.remove(request.observationId)
                throw UiException("observation_expired")
            }
            if (stored.userRevision != bridge.userInteractionRevision()) {
                // The live user touched the screen after this observation; the
                // page is no longer the verified base for an action.
                throw UiException("stale_observation")
            }
            stored.page
        }
        if (page.navigationOnly) {
            if (request.action != UiAction.BACK && request.action != UiAction.HOME) {
                throw UiException("navigation_only")
            }
        }
        if (!page.navigationOnly && page.packageName != null &&
            page.packageName !in targets
        ) {
            throw UiException("target_not_authorized")
        }
        val execution = try {
            synchronized(operationGate) {
                bridge.act(
                    page = page,
                    nodeRef = request.nodeRef,
                    action = request.action,
                    direction = request.direction,
                    text = request.sensitiveText,
                    sensitiveIntent = request.sensitiveTextIntent,
                    ownerToken = ownerToken(claim),
                    requestId = claim.requestId,
                    targetPackage = request.targetPackage,
                    targets = targets,
                    cancelled = cancelled,
                )
            }
        } catch (e: AndroidUiAutomationBridge.UiBridgeException) {
            throw UiException(e.code)
        }
        if (execution.dispatch == UiDispatchOutcome.NOT_DISPATCHED) {
            return UiActResult(
                action = request.action.wireName,
                dispatch = execution.dispatch,
                method = execution.method,
                screenChanged = null,
                observation = null,
                detailCode = execution.detailCode,
                detail = execution.detail,
            )
        }
        // ACCEPTED/UNKNOWN is never semantic success: read the real screen
        // once and return it as the next observation base. A failed read is
        // honest null, never a fabricated or replayed page.
        val fresh = runCatching {
            observe(
                claim = claim,
                targets = targets,
                request = UiObserveRequest(),
                cancelled = cancelled,
            )
        }.getOrNull()
        // Only a real package/window transition is provable here; an
        // in-place UI change is not claimed as "changed" or "unchanged".
        val changed = if (fresh != null &&
            (fresh.packageName != page.packageName || fresh.windowId != page.windowId)
        ) {
            true
        } else {
            null
        }
        return UiActResult(
            action = request.action.wireName,
            dispatch = execution.dispatch,
            method = execution.method,
            screenChanged = changed,
            observation = fresh,
            detailCode = execution.detailCode,
            detail = execution.detail,
        )
    }

    fun screenshotBegin(
        claim: OperationClaim,
        targets: Set<String>,
        request: UiScreenshotRequest,
        cancelled: () -> Boolean,
    ): UiScreenshotInfo {
        if (targets.isEmpty()) throw UiException("ui_target_required")
        if (request.observationId != null) {
            throw UiException("window_screenshot_unsupported")
        }
        sweep()
        val pageGeneration = generation.incrementAndGet()
        val capture = try {
            synchronized(operationGate) {
                bridge.screenshot(targets, request, cancelled, pageGeneration)
            }
        } catch (e: AndroidUiAutomationBridge.UiBridgeException) {
            throw UiException(e.code)
        }
        val id = UUID.randomUUID().toString()
        val now = SystemClock.elapsedRealtime()
        val stored = StoredScreenshot(
            requestId = claim.requestId,
            taskId = claim.taskId,
            runId = claim.runId,
            epoch = claim.epoch,
            grantId = claim.grantId,
            bytes = capture.bytes,
            mimeType = "image/jpeg",
            width = capture.width,
            height = capture.height,
            originalWidth = capture.originalWidth,
            originalHeight = capture.originalHeight,
            rotation = capture.rotation,
            displayId = capture.displayId,
            capturedAtElapsed = now,
            expiresAtElapsed = now + SCREENSHOT_TTL_MS,
        )
        synchronized(gate) {
            trimScreenshotsLocked(keepBytes = stored.bytes.size + 64 * 1024)
            screenshots[id] = stored
        }
        return UiScreenshotInfo(
            screenshotId = id,
            mimeType = stored.mimeType,
            width = stored.width,
            height = stored.height,
            originalWidth = stored.originalWidth,
            originalHeight = stored.originalHeight,
            rotation = stored.rotation,
            displayId = stored.displayId,
            bytesTotal = stored.bytes.size,
            capturedAtElapsed = stored.capturedAtElapsed,
        )
    }

    fun screenshotRead(
        claim: OperationClaim,
        screenshotId: String,
        offset: Int,
        maxBytes: Int,
    ): UiScreenshotChunk {
        sweep()
        return synchronized(gate) {
            val stored = screenshots[screenshotId] ?: throw UiException("screenshot_unknown")
            if (stored.taskId != claim.taskId || stored.runId != claim.runId ||
                stored.epoch != claim.epoch || stored.grantId != claim.grantId ||
                stored.requestId != claim.requestId
            ) {
                throw UiException("screenshot_unknown")
            }
            if (offset < 0 || offset > stored.bytes.size) throw UiException("offset")
            val limit = maxBytes.coerceIn(1, BinderProtocol.MAX_UI_SCREENSHOT_CHUNK)
            val end = minOf(stored.bytes.size, offset + limit)
            val chunk = if (offset == end) ByteArray(0) else stored.bytes.copyOfRange(offset, end)
            UiScreenshotChunk(
                bytes = chunk,
                done = end >= stored.bytes.size,
                bytesRead = end,
            )
        }
    }

    fun screenshotClose(claim: OperationClaim, screenshotId: String): Boolean {
        val removed = synchronized(gate) {
            val stored = screenshots[screenshotId] ?: return@synchronized false
            if (stored.taskId != claim.taskId || stored.runId != claim.runId ||
                stored.epoch != claim.epoch || stored.grantId != claim.grantId ||
                stored.requestId != claim.requestId
            ) {
                return@synchronized false
            }
            screenshots.remove(screenshotId)
            stored.bytes.fill(0)
            true
        }
        return removed
    }

    /**
     * Claim-bound cancellation from the typed uiCancel transaction. The full
     * task/run/epoch/grant/request identity must match the active lease, so an
     * older task cannot release a successor task's held input.
     */
    fun cancel(claim: OperationClaim) {
        bridge.cancelOwnedInput(claim.requestId, ownerToken(claim))
        clearScreenshots(claim.requestId)
    }

    /** Legacy requestId-only cancellation; still cannot match a successor. */
    fun cancel(requestId: String) {
        bridge.cancelOwnedInput(requestId)
        clearScreenshots(requestId)
    }

    private fun clearScreenshots(requestId: String) {
        synchronized(gate) {
            for ((id, stored) in screenshots.entries.toList()) {
                if (stored.requestId == requestId) {
                    stored.bytes.fill(0)
                    screenshots.remove(id)
                }
            }
        }
    }

    override fun close() {
        synchronized(gate) {
            observations.clear()
            latestByOwner.clear()
            for (stored in screenshots.values) stored.bytes.fill(0)
            screenshots.clear()
        }
        bridge.close()
    }

    private fun sweep() {
        val now = SystemClock.elapsedRealtime()
        synchronized(gate) {
            val expired = observations.filterValues { now > it.expiresAtElapsed }.keys
            for (id in expired) observations.remove(id)
            for ((owner, id) in latestByOwner.entries.toList()) {
                if (observations[id] == null) latestByOwner.remove(owner)
            }
            for ((id, stored) in screenshots.entries.toList()) {
                if (now > stored.expiresAtElapsed) {
                    stored.bytes.fill(0)
                    screenshots.remove(id)
                }
            }
        }
    }

    private fun trimObservationsLocked() {
        while (observations.size > MAX_OBSERVATIONS) {
            val oldest = observations.keys.firstOrNull() ?: return
            observations.remove(oldest)
        }
        if (latestByOwner.size > MAX_OWNERS) {
            val first = latestByOwner.keys.firstOrNull() ?: return
            latestByOwner.remove(first)
        }
    }

    private fun trimScreenshotsLocked(keepBytes: Int) {
        var total = screenshots.values.sumOf { it.bytes.size } + keepBytes
        while (screenshots.size >= MAX_SCREENSHOTS || total > MAX_SCREENSHOT_TOTAL_BYTES) {
            val oldest = screenshots.keys.firstOrNull() ?: return
            val removed = screenshots.remove(oldest) ?: return
            total -= removed.bytes.size
            removed.bytes.fill(0)
        }
    }

    private fun ownerKey(claim: OperationClaim): String =
        claim.taskId + ":" + claim.runId + ":" + claim.epoch + ":" + claim.grantId

    /** Full ownership token; the lease also keeps the exact requestId. */
    private fun ownerToken(claim: OperationClaim): String =
        ownerKey(claim) + "|" + claim.requestId

    private fun AndroidUiAutomationBridge.Page.toObservation(): UiObservation =
        UiObservation(
            observationId = observationId,
            packageName = packageName,
            windowId = windowId,
            windowType = windowType,
            windowTitle = windowTitle,
            displayId = displayId,
            rootClassName = rootClassName,
            rotation = rotation,
            capturedAtElapsed = capturedAtElapsed,
            expiresAtElapsed = expiresAtElapsed,
            generation = generation,
            userInteractionRevision = userInteractionRevision,
            nodes = nodes.map { node ->
                UiNode(
                    ref = node.ref,
                    parentRef = node.parentRef,
                    depth = node.depth,
                    className = node.className,
                    packageName = node.packageName,
                    viewId = node.viewId,
                    text = node.text,
                    contentDescription = node.contentDescription,
                    hintText = node.hintText,
                    bounds = UiBounds(
                        node.bounds.left, node.bounds.top,
                        node.bounds.right, node.bounds.bottom,
                    ),
                    visible = node.visible,
                    enabled = node.enabled,
                    clickable = node.clickable,
                    editable = node.editable,
                    scrollable = node.scrollable,
                    focusable = node.focusable,
                    focused = node.focused,
                    selected = node.selected,
                    checkable = node.checkable,
                    checked = node.checked,
                    password = node.password,
                    redacted = node.redacted,
                    insideScrollable = node.insideScrollable,
                    actions = node.actions,
                    range = node.range,
                    path = node.path,
                )
            },
            scannedNodeCount = scannedNodeCount,
            truncated = truncated,
            maxDepthReached = maxDepthReached,
            scanLimited = scanLimited,
            timeLimited = timeLimited,
            selectionLimited = false,
            textLimited = textLimited,
            sensitiveWindow = sensitiveWindow,
            hasSensitiveField = hasSensitiveField,
            navigationOnly = navigationOnly,
        )

    private companion object {
        const val MAX_OBSERVATIONS = 16
        const val MAX_OWNERS = 8
        const val MAX_SCREENSHOTS = 2
        const val MAX_SCREENSHOT_TOTAL_BYTES = 16 * 1024 * 1024
        const val SCREENSHOT_TTL_MS = 60_000L
        val CAPABILITIES = setOf(
            "ui.automation", "ui.observe", "ui.act", "ui.screenshot", "ui.display",
        )
    }
}
