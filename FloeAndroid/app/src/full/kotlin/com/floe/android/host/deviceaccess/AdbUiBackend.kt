// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import android.app.KeyguardManager
import android.content.Context
import android.os.SystemClock
import com.floe.android.phonecontrol.PhoneControlAction
import com.floe.android.phonecontrol.PhoneControlActionResult
import com.floe.android.phonecontrol.PhoneControlBackend
import com.floe.android.phonecontrol.PhoneControlBounds
import com.floe.android.phonecontrol.PhoneControlDenial
import com.floe.android.phonecontrol.PhoneControlDetailPage
import com.floe.android.phonecontrol.PhoneControlDispatch
import com.floe.android.phonecontrol.PhoneControlFailure
import com.floe.android.phonecontrol.PhoneControlLimits
import com.floe.android.phonecontrol.PhoneControlObservation
import com.floe.android.phonecontrol.PhoneControlObservationText
import com.floe.android.phonecontrol.PhoneControlObserveRequest
import com.floe.android.phonecontrol.PhoneControlOwner
import com.floe.android.phonecontrol.PhoneControlPrincipal
import com.floe.android.phonecontrol.PhoneControlRangeInfo
import com.floe.android.phonecontrol.PhoneControlResult
import com.floe.android.phonecontrol.PhoneControlScreenshot
import com.floe.android.phonecontrol.PhoneControlScreenshotRequest
import com.floe.android.phonecontrol.PhoneControlStructuredAdapter
import com.floe.android.phonecontrol.PhoneControlStructuredNode
import com.floe.android.phonecontrol.PhoneControlStructuredPage
import com.floe.android.phonecontrol.PhoneControlUnavailable
import com.floe.android.rootsystem.GrantReceipt
import com.floe.android.rootsystem.OperationClaim
import com.floe.android.rootsystem.RootResult
import com.floe.android.rootsystem.RootSystemController
import com.floe.android.rootsystem.SystemOperation
import com.floe.android.rootsystem.UiActRequest
import com.floe.android.rootsystem.UiAction
import com.floe.android.rootsystem.UiBackendStatus
import com.floe.android.rootsystem.UiDispatchOutcome
import com.floe.android.rootsystem.UiObservation
import com.floe.android.rootsystem.UiObserveRequest
import com.floe.android.rootsystem.UiScreenshotInfo
import com.floe.android.rootsystem.UiScreenshotRequest
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Pure, non-authorizing mapping from the existing phone-control action model
 * to the typed UI request. It preserves the exact `sensitiveText` intent:
 * ordinary text stays false and can never enter a protected field, while an
 * explicit sensitive payload is marked true and dispatched once.
 */
internal object AdbUiActMapping {

    /** A failed invoked mutation needs readback; it is not proof of rejection. */
    fun failureReason(code: String): PhoneControlFailure =
        if (code == "timeout") PhoneControlFailure.TIMEOUT else PhoneControlFailure.INTERNAL_ERROR

    fun request(
        observationId: String,
        nodeRef: String?,
        action: PhoneControlAction,
    ): UiActRequest = UiActRequest(
        observationId = observationId,
        nodeRef = nodeRef,
        action = when (action) {
            is PhoneControlAction.Click -> UiAction.CLICK
            is PhoneControlAction.SetText -> UiAction.SET_TEXT
            is PhoneControlAction.Scroll -> UiAction.SCROLL
            is PhoneControlAction.Swipe -> UiAction.SWIPE
            is PhoneControlAction.Focus -> UiAction.FOCUS
            is PhoneControlAction.Commit -> UiAction.COMMIT
            PhoneControlAction.Back -> UiAction.BACK
            PhoneControlAction.Home -> UiAction.HOME
            is PhoneControlAction.Launch -> UiAction.LAUNCH
        },
        direction = when (action) {
            is PhoneControlAction.Scroll ->
                if (action.direction ==
                    com.floe.android.phonecontrol.PhoneControlScrollDirection.FORWARD
                ) {
                    "forward"
                } else {
                    "backward"
                }
            is PhoneControlAction.Swipe -> action.direction.name.lowercase()
            else -> null
        },
        targetPackage = (action as? PhoneControlAction.Launch)?.packageName,
        sensitiveText = (action as? PhoneControlAction.SetText)?.text,
        sensitiveTextIntent = (action as? PhoneControlAction.SetText)?.sensitive == true,
    )

    /** Static diagnostic note; never carries input text or node content. */
    fun note(detailCode: String?, detail: String?): String? =
        listOfNotNull(detailCode, detail).joinToString(" ").ifEmpty { null }
}

internal data class AdbUiSessionSpec(
    val grantId: String,
    val owner: PhoneControlOwner,
    val epoch: Long,
    val targets: Set<String>,
    val screenAllowed: Boolean,
    val screenshotAllowed: Boolean,
    val expiresAtMillis: Long,
)

/**
 * App-side adapter for the typed ADB structured-UI backend.
 *
 * It owns only the live session projection + retained observations. It never
 * widens the user's selected device-app targets, never reuses package-management
 * grants, and never treats a paired/stale helper as ready. Every call carries
 * the ordinary task/run/epoch/grant claim into the existing RootSystemController
 * authority path.
 */
internal class AdbUiBackend(
    private val context: Context,
    private val controller: () -> RootSystemController?,
    private val registerSession: suspend (AdbUiSessionSpec) -> RootResult<GrantReceipt>,
    private val revokeSession: suspend (String) -> Unit,
    private val ownerIsLive: (PhoneControlOwner, Long) -> Boolean,
) : Closeable {

    private data class Session(
        val spec: AdbUiSessionSpec,
        val registeredAtElapsed: Long,
    )

    private data class Retained(
        val observation: PhoneControlObservation,
        val serverObservationId: String,
        val refAliases: Map<String, String>,
        val owner: PhoneControlOwner,
        val epoch: Long,
        val grantId: String,
        val expiresAtElapsed: Long,
    )

    private val gate = Any()
    private val lifecycleScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var session: Session? = null
    private val retained = LinkedHashMap<String, Retained>()
    private val latestByOwner = HashMap<PhoneControlOwner, String>()
    private val activeScreenshotClaims = java.util.Collections.synchronizedSet(
        HashSet<OperationClaim>(),
    )
    private val lastClaims = java.util.concurrent.ConcurrentHashMap<String, OperationClaim>()

    @Volatile
    var readiness: UiBackendStatus? = null
        private set

    @Volatile
    private var lastMutationDispatch: PhoneControlDispatch? = null

    @Volatile
    private var lastMutationOwner: PhoneControlOwner? = null

    fun isReady(): Boolean = readiness?.ready == true

    fun isArmed(owner: PhoneControlOwner, epoch: Long): Boolean =
        synchronized(gate) {
            val current = session ?: return false
            current.spec.owner == owner && current.spec.epoch == epoch &&
                SystemClock.elapsedRealtime() < current.registeredAtElapsed +
                SESSION_TTL_ELAPSED &&
                ownerIsLive(owner, epoch)
        }

    fun targets(owner: PhoneControlOwner): Set<String>? = synchronized(gate) {
        session?.takeIf { it.spec.owner == owner }?.spec?.targets
    }

    fun screenshotAllowed(owner: PhoneControlOwner): Boolean = synchronized(gate) {
        session?.takeIf { it.spec.owner == owner }?.spec?.screenshotAllowed == true
    }

    fun screenAllowed(owner: PhoneControlOwner): Boolean = synchronized(gate) {
        session?.takeIf { it.spec.owner == owner }?.spec?.screenAllowed == true
    }

    fun awaitingReadback(owner: PhoneControlOwner): Boolean =
        lastMutationOwner == owner && lastMutationDispatch?.let { dispatch ->
            com.floe.android.phonecontrol.PhoneControlStructuredRouting.requiresReadback(dispatch)
        } == true

    fun clearReadback(owner: PhoneControlOwner) {
        if (lastMutationOwner == owner) {
            lastMutationDispatch = null
            lastMutationOwner = null
        }
    }

    suspend fun refreshReadiness(): UiBackendStatus? {
        val status = try {
            withTimeoutOrNull(5_000) { controller()?.uiBackendStatus() }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Throwable) {
            null
        }
        readiness = status
        return status
    }

    suspend fun arm(
        owner: PhoneControlOwner,
        epoch: Long,
        targets: Set<String>,
        screenAllowed: Boolean,
        screenshotAllowed: Boolean,
    ): PhoneControlResult<Unit> {
        if (targets.isEmpty()) return PhoneControlResult.Denied(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
        )
        val ready = refreshReadiness()
        if (ready?.ready != true) {
            return PhoneControlResult.Unavailable(
                PhoneControlUnavailable.STRUCTURED_UI_NOT_READY,
                ready?.reason,
            )
        }
        if (keyguardLocked()) return PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED)
        if (!screenAllowed) return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        if (!ownerIsLive(owner, epoch)) {
            return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        }
        synchronized(gate) {
            val current = session
            if (current != null && current.spec.owner == owner && current.spec.epoch == epoch &&
                current.spec.targets == targets &&
                current.spec.screenshotAllowed == screenshotAllowed
            ) {
                return PhoneControlResult.Ok(Unit)
            }
        }
        revokeActive()
        val spec = AdbUiSessionSpec(
            grantId = "adbui:" + UUID.randomUUID().toString(),
            owner = owner,
            epoch = epoch,
            targets = targets.take(PhoneControlLimits.MAX_TARGET_PACKAGES).toSet(),
            screenAllowed = screenAllowed,
            screenshotAllowed = screenshotAllowed,
            expiresAtMillis = System.currentTimeMillis() + SESSION_TTL_MILLIS,
        )
        return when (val registration = registerSession(spec)) {
            is RootResult.Ok -> {
                synchronized(gate) {
                    session = Session(spec, SystemClock.elapsedRealtime())
                    retained.clear()
                    latestByOwner.clear()
                    lastMutationDispatch = null
                    lastMutationOwner = null
                }
                PhoneControlResult.Ok(Unit)
            }
            is RootResult.Denied -> PhoneControlResult.Denied(
                PhoneControlDenial.AUTHORIZATION_DENIED,
                registration.code,
            )
            is RootResult.Unavailable -> PhoneControlResult.Unavailable(
                PhoneControlUnavailable.STRUCTURED_UI_NOT_READY,
                registration.code,
            )
            is RootResult.Failed -> PhoneControlResult.Failed(
                PhoneControlFailure.INTERNAL_ERROR,
                registration.code,
            )
        }
    }

    suspend fun observe(
        principal: PhoneControlPrincipal,
        request: PhoneControlObserveRequest = PhoneControlObserveRequest(),
    ): PhoneControlResult<PhoneControlObservation> {
        val current = sessionFor(principal)
            ?: return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        val ready = refreshReadiness()
        if (ready?.ready != true) {
            return PhoneControlResult.Unavailable(
                PhoneControlUnavailable.STRUCTURED_UI_NOT_READY,
                ready?.reason,
            )
        }
        if (keyguardLocked()) return PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED)
        if (!ownerIsLive(principal.owner, principal.epoch)) {
            return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        }
        val normalized = request.normalized()
        val operationClaim = claim(current, principal, "observe")
        return when (val result = controller()?.uiObserve(
            operationClaim,
            UiObserveRequest(
                maxNodes = normalized.maxNodes,
                maxDepth = normalized.maxDepth,
                includeInvisible = normalized.includeInvisible,
                textBudgetChars = normalized.textBudgetChars,
            ),
        )) {
            is RootResult.Ok -> {
                val observation = retain(result.value, principal, current, normalized)
                clearReadback(principal.owner)
                PhoneControlResult.Ok(observation)
            }
            is RootResult.Denied -> mapDenied(result.code)
            is RootResult.Unavailable -> mapUnavailable(result.code)
            is RootResult.Failed -> PhoneControlResult.Failed(
                PhoneControlFailure.OBSERVATION_FAILED,
                result.code,
            )
            null -> PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED)
        }
    }

    suspend fun observeDetail(
        principal: PhoneControlPrincipal,
        observationId: String,
        offset: Int,
    ): PhoneControlResult<PhoneControlDetailPage> {
        if (offset < 0 || offset > PhoneControlLimits.MAX_NODES) {
            return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        }
        val current = sessionFor(principal)
            ?: return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        if (!ownerIsLive(principal.owner, principal.epoch)) {
            return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        }
        val stored = synchronized(gate) {
            if (latestByOwner[principal.owner] != observationId) return@synchronized null
            retained[observationId]?.takeIf {
                it.owner == principal.owner && it.epoch == principal.epoch &&
                    it.grantId == current.spec.grantId
            }
        } ?: return PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        if (SystemClock.elapsedRealtime() > stored.expiresAtElapsed) {
            synchronized(gate) { retained.remove(observationId) }
            return PhoneControlResult.Denied(PhoneControlDenial.OBSERVATION_EXPIRED)
        }
        return PhoneControlResult.Ok(
            PhoneControlObservationText.detail(stored.observation, offset),
        )
    }

    suspend fun perform(
        principal: PhoneControlPrincipal,
        observationId: String,
        action: PhoneControlAction,
    ): PhoneControlResult<PhoneControlActionResult> {
        if (action is PhoneControlAction.Launch) {
            return launchApplication(principal, action.packageName)
        }
        val backend = PhoneControlBackend.fromObservationId(observationId)
        if (backend != PhoneControlBackend.ADB_UI_AUTOMATION) {
            return PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        }
        val current = sessionFor(principal)
            ?: return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        if (!ownerIsLive(principal.owner, principal.epoch)) {
            return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        }
        if (keyguardLocked()) return PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED)
        val stored = synchronized(gate) {
            if (latestByOwner[principal.owner] != observationId) return@synchronized null
            retained[observationId]?.takeIf {
                it.owner == principal.owner && it.epoch == principal.epoch &&
                    it.grantId == current.spec.grantId
            }
        } ?: return PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        if (SystemClock.elapsedRealtime() > stored.expiresAtElapsed) {
            synchronized(gate) { retained.remove(observationId) }
            return PhoneControlResult.Denied(PhoneControlDenial.OBSERVATION_EXPIRED)
        }
        val serverId = stored.serverObservationId
        val requestedNodeRef = when (action) {
            is PhoneControlAction.Click -> action.nodeRef
            is PhoneControlAction.SetText -> action.nodeRef
            is PhoneControlAction.Scroll -> action.nodeRef
            is PhoneControlAction.Swipe -> action.nodeRef
            is PhoneControlAction.Focus -> action.nodeRef
            is PhoneControlAction.Commit -> action.nodeRef
            PhoneControlAction.Back, PhoneControlAction.Home -> null
            is PhoneControlAction.Launch -> null
        }
        val nodeRef = if (requestedNodeRef == null) {
            null
        } else {
            stored.refAliases[requestedNodeRef]
                ?: return PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        }
        val operationClaim = claim(current, principal, "act")
        val request = AdbUiActMapping.request(serverId, nodeRef, action)
        return when (val result = controller()?.uiAct(operationClaim, request)) {
            is RootResult.Ok -> {
                if (result.value.dispatch == UiDispatchOutcome.NOT_DISPATCHED) {
                    mapNotDispatched(result.value.detailCode)
                } else {
                    val dispatch = when (result.value.dispatch) {
                        UiDispatchOutcome.ACCEPTED -> PhoneControlDispatch.ACCEPTED
                        UiDispatchOutcome.UNKNOWN -> PhoneControlDispatch.UNKNOWN
                        UiDispatchOutcome.NOT_DISPATCHED -> PhoneControlDispatch.NOT_DISPATCHED
                    }
                    val fresh = result.value.observation?.let {
                        retain(it, principal, current)
                    }
                    lastMutationDispatch = dispatch
                    lastMutationOwner = principal.owner
                    PhoneControlResult.Ok(
                        PhoneControlActionResult(
                            action = result.value.action,
                            dispatch = dispatch,
                            // A partial/thrown injected gesture did not
                            // complete as one sequence; the release attempt
                            // is reported through the static note.
                            gestureCompleted = if (
                                result.value.dispatch == UiDispatchOutcome.UNKNOWN &&
                                result.value.method?.startsWith("input") == true
                            ) {
                                false
                            } else {
                                null
                            },
                            observation = fresh,
                            screenChanged = result.value.screenChanged,
                            note = AdbUiActMapping.note(
                                result.value.detailCode,
                                result.value.detail,
                            ),
                            method = result.value.method,
                        ),
                    )
                }
            }
            is RootResult.Denied -> mapDenied(result.code)
            is RootResult.Unavailable -> mapUnavailable(result.code)
            is RootResult.Failed -> PhoneControlResult.Failed(
                AdbUiActMapping.failureReason(result.code),
                result.code,
            )
            null -> PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED)
        }
    }

    suspend fun launchApplication(
        principal: PhoneControlPrincipal,
        packageName: String,
    ): PhoneControlResult<PhoneControlActionResult> {
        val current = sessionFor(principal)
            ?: return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        if (packageName !in current.spec.targets) {
            return PhoneControlResult.Denied(PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED)
        }
        if (!ownerIsLive(principal.owner, principal.epoch)) {
            return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        }
        val operationClaim = claim(current, principal, "launch")
        return when (val result = controller()?.uiAct(
            operationClaim,
            UiActRequest(
                observationId = "",
                nodeRef = null,
                action = UiAction.LAUNCH,
                targetPackage = packageName,
            ),
        )) {
            is RootResult.Ok -> {
                if (result.value.dispatch == UiDispatchOutcome.NOT_DISPATCHED) {
                    mapNotDispatched(result.value.detailCode)
                } else {
                    val dispatch = if (result.value.dispatch == UiDispatchOutcome.ACCEPTED) {
                        PhoneControlDispatch.ACCEPTED
                    } else {
                        PhoneControlDispatch.UNKNOWN
                    }
                    lastMutationDispatch = dispatch
                    lastMutationOwner = principal.owner
                    PhoneControlResult.Ok(
                        PhoneControlActionResult(
                            action = "launch",
                            dispatch = dispatch,
                            gestureCompleted = null,
                            observation = null,
                            screenChanged = null,
                            note = AdbUiActMapping.note(
                                result.value.detailCode,
                                result.value.detail,
                            ),
                            method = result.value.method,
                        ),
                    )
                }
            }
            is RootResult.Denied -> mapDenied(result.code)
            is RootResult.Unavailable -> mapUnavailable(result.code)
            is RootResult.Failed -> PhoneControlResult.Failed(
                AdbUiActMapping.failureReason(result.code),
                result.code,
            )
            null -> PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED)
        }
    }

    suspend fun screenshot(
        principal: PhoneControlPrincipal,
        observationId: String?,
        request: PhoneControlScreenshotRequest = PhoneControlScreenshotRequest(),
    ): PhoneControlResult<PhoneControlScreenshot> {
        if (observationId != null) {
            return PhoneControlResult.Unavailable(
                PhoneControlUnavailable.WINDOW_SCREENSHOT_UNSUPPORTED,
                "The ADB structured-UI backend captures the display only",
            )
        }
        val current = sessionFor(principal)
            ?: return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        if (!current.spec.screenshotAllowed) {
            return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        }
        if (!ownerIsLive(principal.owner, principal.epoch)) {
            return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        }
        if (keyguardLocked()) return PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED)
        val normalized = request.normalized()
        val shotRequestId = requestId(principal, "shot")
        val operationClaim = claim(current, principal, "shot", shotRequestId)
        activeScreenshotClaims.add(operationClaim)
        val begin = controller()?.uiScreenshotBegin(
            operationClaim,
            UiScreenshotRequest(
                observationId = null,
                maxBytes = normalized.maxBytes,
                maxDimension = normalized.maxDimension,
                quality = normalized.quality,
            ),
        ) ?: run {
            activeScreenshotClaims.remove(operationClaim)
            return PhoneControlResult.Unavailable(
                PhoneControlUnavailable.SERVICE_NOT_CONNECTED,
            )
        }
        val info: UiScreenshotInfo = when (begin) {
            is RootResult.Ok -> begin.value
            is RootResult.Denied -> {
                activeScreenshotClaims.remove(operationClaim)
                return mapScreenshotDenied(begin.code)
            }
            is RootResult.Unavailable -> {
                activeScreenshotClaims.remove(operationClaim)
                return mapUnavailable(begin.code)
            }
            is RootResult.Failed -> {
                activeScreenshotClaims.remove(operationClaim)
                return PhoneControlResult.Failed(
                    if (begin.code == "image_too_large") {
                        PhoneControlFailure.IMAGE_TOO_LARGE
                    } else {
                        PhoneControlFailure.SCREENSHOT_FAILED
                    },
                    begin.code,
                )
            }
        }
        val output = ByteArrayOutputStream()
        var offset = 0
        var closed = false
        try {
            while (true) {
                val chunk = controller()?.uiScreenshotRead(
                    operationClaim,
                    info.screenshotId,
                    offset,
                    64 * 1024,
                ) ?: return PhoneControlResult.Unavailable(
                    PhoneControlUnavailable.SERVICE_NOT_CONNECTED,
                )
                when (chunk) {
                    is RootResult.Ok -> {
                        if (output.size() + chunk.value.bytes.size > normalized.maxBytes) {
                            return PhoneControlResult.Failed(PhoneControlFailure.IMAGE_TOO_LARGE)
                        }
                        output.write(chunk.value.bytes)
                        val next = chunk.value.bytesRead
                        if (next <= offset && !chunk.value.done) {
                            return PhoneControlResult.Failed(
                                PhoneControlFailure.SCREENSHOT_FAILED,
                                "chunk_stalled",
                            )
                        }
                        offset = next
                        if (chunk.value.done) break
                    }
                    is RootResult.Denied -> return mapScreenshotDenied(chunk.code)
                    is RootResult.Unavailable -> return mapUnavailable(chunk.code)
                    is RootResult.Failed -> return PhoneControlResult.Failed(
                        if (chunk.code == "image_too_large") {
                            PhoneControlFailure.IMAGE_TOO_LARGE
                        } else {
                            PhoneControlFailure.SCREENSHOT_FAILED
                        },
                        chunk.code,
                    )
                }
            }
            val bytes = output.toByteArray()
            if (bytes.isEmpty()) {
                return PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED)
            }
            return PhoneControlResult.Ok(
                PhoneControlScreenshot(
                    bytes = bytes,
                    mimeType = info.mimeType,
                    width = info.width,
                    height = info.height,
                    capturedAtElapsedRealtimeMillis = info.capturedAtElapsed,
                    windowId = null,
                    originalWidth = info.originalWidth,
                    originalHeight = info.originalHeight,
                    rotation = info.rotation,
                    displayId = info.displayId,
                ),
            )
        } finally {
            if (!closed) {
                closed = true
                controller()?.uiScreenshotClose(operationClaim, info.screenshotId)
                activeScreenshotClaims.remove(operationClaim)
                output.reset()
            }
        }
    }

    private suspend fun revokeActive() {
        val active = synchronized(gate) {
            val current = session
            session = null
            retained.clear()
            latestByOwner.clear()
            lastMutationDispatch = null
            lastMutationOwner = null
            current
        }
        if (active != null) {
            runCatching { revokeSession(active.spec.grantId) }
        }
    }

    suspend fun stop(owner: PhoneControlOwner) {
        val pending = synchronized(activeScreenshotClaims) {
            activeScreenshotClaims.toList()
        }
        val activeController = controller()
        for (claim in pending) {
            if (claim.taskId == owner.taskID.toString() && claim.runId == owner.runID.toString()) {
                runCatching { activeController?.cancelOperation(claim) }
            }
        }
        lastClaims.remove(ownerKey(owner))?.let { claim ->
            runCatching { activeController?.cancelOperation(claim) }
        }
        activeScreenshotClaims.clear()
        val active = synchronized(gate) {
            session?.takeIf { it.spec.owner == owner }
        }
        if (active != null) {
            synchronized(gate) {
                if (session?.spec?.grantId == active.spec.grantId) {
                    session = null
                    retained.clear()
                    latestByOwner.clear()
                    lastMutationDispatch = null
                    lastMutationOwner = null
                }
            }
            runCatching { revokeSession(active.spec.grantId) }
        }
    }

    fun onServiceLost() {
        synchronized(gate) {
            session = null
            retained.clear()
            latestByOwner.clear()
            lastMutationDispatch = null
            lastMutationOwner = null
        }
        lastClaims.clear()
        activeScreenshotClaims.clear()
        readiness = null
    }

    override fun close() {
        activeScreenshotClaims.clear()
        lastClaims.clear()
        val active = synchronized(gate) {
            val current = session
            session = null
            retained.clear()
            latestByOwner.clear()
            lastMutationDispatch = null
            lastMutationOwner = null
            current
        }
        if (active != null) {
            lifecycleScope.launch {
                runCatching { revokeSession(active.spec.grantId) }
            }
        }
    }

    // ------------------------------------------------------------- internals

    private fun sessionFor(principal: PhoneControlPrincipal): Session? = synchronized(gate) {
        session?.takeIf {
            it.spec.owner == principal.owner && it.spec.epoch == principal.epoch &&
                SystemClock.elapsedRealtime() <
                it.registeredAtElapsed + SESSION_TTL_ELAPSED
        }
    }

    private fun claim(
        current: Session,
        principal: PhoneControlPrincipal,
        suffix: String,
        fixedRequestId: String? = null,
    ): OperationClaim {
        val resolvedRequestId = fixedRequestId ?: requestId(principal, suffix)
        val claim = OperationClaim(
            taskId = principal.owner.taskID.toString(),
            runId = principal.owner.runID.toString(),
            epoch = principal.epoch,
            grantId = current.spec.grantId,
            requestId = resolvedRequestId.take(128),
            callId = principal.callID?.take(128),
        )
        lastClaims[ownerKey(principal.owner)] = claim
        return claim
    }

    private fun requestId(principal: PhoneControlPrincipal, suffix: String): String {
        val base = principal.callID?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString()
        return ("$base:adbui:$suffix").take(128)
    }

    private fun retain(
        observation: UiObservation,
        principal: PhoneControlPrincipal,
        current: Session,
        request: PhoneControlObserveRequest = PhoneControlObserveRequest(),
    ): PhoneControlObservation {
        val page = PhoneControlStructuredPage(
            observationId = observation.observationId,
            packageName = observation.packageName,
            windowId = observation.windowId,
            windowType = observation.windowType,
            windowTitle = observation.windowTitle,
            displayId = observation.displayId,
            rootClassName = observation.rootClassName,
            rotation = observation.rotation,
            capturedAtElapsedRealtimeMillis = observation.capturedAtElapsed,
            expiresAtElapsedRealtimeMillis = observation.expiresAtElapsed,
            generation = observation.generation,
            userInteractionRevision = observation.userInteractionRevision,
            nodes = observation.nodes.map { node ->
                PhoneControlStructuredNode(
                    ref = node.ref,
                    parentRef = node.parentRef,
                    path = node.path,
                    depth = node.depth,
                    className = node.className,
                    packageName = node.packageName,
                    viewId = node.viewId,
                    text = node.text,
                    contentDescription = node.contentDescription,
                    hintText = node.hintText,
                    bounds = PhoneControlBounds(
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
                    range = node.range?.let {
                        PhoneControlRangeInfo(it.min, it.max, it.current)
                    },
                )
            },
            scannedNodeCount = observation.scannedNodeCount,
            truncated = observation.truncated,
            maxDepthReached = observation.maxDepthReached,
            scanLimited = observation.scanLimited,
            timeLimited = observation.timeLimited,
            textLimited = observation.textLimited,
            sensitiveWindow = observation.sensitiveWindow,
            navigationOnly = observation.navigationOnly,
            hasSensitiveField = observation.hasSensitiveField,
        )
        val mapped = PhoneControlStructuredAdapter.toMapped(
            page = page,
            owner = principal.owner,
            fenceGeneration = principal.generation,
            request = request,
        )
        val appId = mapped.observation.observationId
        synchronized(gate) {
            retained[appId] = Retained(
                observation = mapped.observation,
                serverObservationId = observation.observationId,
                refAliases = mapped.refAliases,
                owner = principal.owner,
                epoch = principal.epoch,
                grantId = current.spec.grantId,
                expiresAtElapsed = observation.expiresAtElapsed,
            )
            latestByOwner[principal.owner] = appId
            while (retained.size > MAX_RETAINED) {
                val oldest = retained.keys.firstOrNull() ?: break
                retained.remove(oldest)
            }
        }
        return mapped.observation
    }

    private fun mapDenied(code: String): PhoneControlResult<Nothing> = when (code) {
        "locked" -> PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED)
        "protected_target" -> PhoneControlResult.Denied(PhoneControlDenial.PROTECTED_WINDOW)
        "target_not_authorized" -> PhoneControlResult.Denied(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
        )
        "ui_scope", "ui_target_required", "ui_target_not_authorized" ->
            PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        "ui_observation_invalid", "observation_expired", "stale_observation" ->
            PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        "rotation_changed", "window_changed" ->
            PhoneControlResult.Denied(PhoneControlDenial.WINDOW_CHANGED)
        "sensitive_field" ->
            PhoneControlResult.Denied(PhoneControlDenial.SENSITIVE_FIELD)
        "sensitive_field_changed" ->
            PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        "node_disabled" -> PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
        "not_editable" -> PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_EDITABLE)
        "text_required" -> PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        "no_bounds", "node_required", "node_changed" ->
            PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
        "cancelled" -> PhoneControlResult.Failed(PhoneControlFailure.CANCELLED)
        else -> PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED, code)
    }

    private fun mapNotDispatched(code: String?): PhoneControlResult<Nothing> = when (code) {
        "stale_observation", "observation_invalid", "node_changed", "rotation_changed" ->
            PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        "sensitive_field" ->
            PhoneControlResult.Denied(PhoneControlDenial.SENSITIVE_FIELD)
        "sensitive_field_changed" ->
            PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION)
        "node_disabled" -> PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
        "not_editable" -> PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_EDITABLE)
        "text_required" -> PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        "not_scrollable" -> PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_SCROLLABLE)
        "not_clickable" -> PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_CLICKABLE)
        "no_bounds", "node_required" ->
            PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
        "action_unsupported" -> PhoneControlResult.Unavailable(
            PhoneControlUnavailable.GESTURE_UNSUPPORTED,
            code,
        )
        else -> PhoneControlResult.Failed(
            PhoneControlFailure.ACTION_REJECTED,
            code,
        )
    }

    private fun mapUnavailable(code: String): PhoneControlResult<Nothing> = when (code) {
        "window_screenshot_unsupported" ->
            PhoneControlResult.Unavailable(PhoneControlUnavailable.WINDOW_SCREENSHOT_UNSUPPORTED)
        "ui_automation_unavailable", "ui_not_ready" ->
            PhoneControlResult.Unavailable(PhoneControlUnavailable.STRUCTURED_UI_NOT_READY)
        "service_died" ->
            PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED)
        else -> PhoneControlResult.Unavailable(
            PhoneControlUnavailable.STRUCTURED_UI_NOT_READY,
            code,
        )
    }

    private fun mapScreenshotDenied(code: String): PhoneControlResult<Nothing> = when (code) {
        "locked" -> PhoneControlResult.Denied(PhoneControlDenial.DEVICE_LOCKED)
        "protected_target" -> PhoneControlResult.Denied(PhoneControlDenial.PROTECTED_WINDOW)
        "overlay_present" -> PhoneControlResult.Denied(PhoneControlDenial.PROTECTED_WINDOW)
        "window_changed" -> PhoneControlResult.Denied(PhoneControlDenial.WINDOW_CHANGED)
        "target_not_authorized" -> PhoneControlResult.Denied(
            PhoneControlDenial.TARGET_PACKAGE_NOT_ALLOWED,
        )
        "ui_screenshot_scope", "ui_scope" ->
            PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        "ui_not_ready", "ui_automation_unavailable" ->
            PhoneControlResult.Unavailable(PhoneControlUnavailable.STRUCTURED_UI_NOT_READY)
        "cancelled" -> PhoneControlResult.Failed(PhoneControlFailure.CANCELLED)
        "image_too_large" -> PhoneControlResult.Failed(PhoneControlFailure.IMAGE_TOO_LARGE)
        else -> PhoneControlResult.Failed(PhoneControlFailure.SCREENSHOT_FAILED, code)
    }

    private fun ownerKey(owner: PhoneControlOwner): String =
        owner.taskID.toString() + ":" + owner.runID.toString()

    private fun keyguardLocked(): Boolean = runCatching {
        (context.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)
            ?.isKeyguardLocked == true
    }.getOrDefault(true)

    private companion object {
        const val SESSION_TTL_MILLIS = 10 * 60 * 1000L
        const val SESSION_TTL_ELAPSED = 10 * 60 * 1000L
        const val MAX_RETAINED = 8
    }
}
