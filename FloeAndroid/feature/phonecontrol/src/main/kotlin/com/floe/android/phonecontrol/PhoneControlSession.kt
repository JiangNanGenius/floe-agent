// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.view.Display
import android.view.accessibility.AccessibilityEvent
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
    private var pendingObserve: ((PhoneControlResult<PhoneControlObservation>) -> Unit)? = null
    private var pendingClientToken: String? = null
    private var pendingTimeout: Runnable? = null

    private var pendingEffectivePackages: Set<String> = emptySet()
    private var pendingAllowGlobalNavigation = false
    private var lastWindowChangeAt = 0L
    private var lastContentChangeAt = 0L
    private var suppressUserTouchUntil = 0L
    private val ownInputEcho = PhoneOwnInputEcho()
    @Volatile var lastUserInteractionAt: Long = SystemClock.elapsedRealtime()
        private set
    @Volatile var lastUserInteractionWallMillis: Long = System.currentTimeMillis()
        private set
    private val unlocker = PhoneControlUnlocker(service, mainHandler,
        suppressGeneratedEvents = { until ->
            suppressUserTouchUntil = until
            // Every unlock-attempt effect (reveal, credential entry, settle)
            // is our own input; its platform echoes must stay attributable
            // to the task even when delivery lags past `until`.
            ownInputEcho.noteOwnInput(SystemClock.uptimeMillis())
        },
        stateChanged = { PhoneControlRuntime.publish() })
    val automationFinishing: Boolean get() = unlocker.isSettling
    val relockReceipt: PhoneRelockReceipt? get() = unlocker.lastRelockReceipt

    fun unlockForTask(principal: PhoneControlPrincipal, operationToken: String, credential: CharArray,
        isCurrent: () -> Boolean, taskIsCurrent: () -> Boolean,
        complete: (PhoneUnlockResult) -> Unit) {
        unlocker.unlock(principal.owner, operationToken, credential, isCurrent, taskIsCurrent) { result ->
            if (result == PhoneUnlockResult.UNLOCKED || result == PhoneUnlockResult.ALREADY_UNLOCKED) {
                onScreenInteractive()
            }
            complete(result)
        }
    }

    fun finishAutomation(owner: PhoneControlOwner) {
        unlocker.finish(owner)
        // Ending a task must also release its actual service fence. Clearing
        // only the host's armedOwner leaves the next task permanently busy.
        // release is exact-owner guarded and invalidates old observations.
        release(owner)
    }

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

    private enum class NodeRequirement { CLICK, SET_TEXT, SCROLL, SWIPE, FOCUS, COMMIT }

    // ---------------------------------------------------------------------
    // Observation
    // ---------------------------------------------------------------------

    fun observe(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
        request: PhoneControlObserveRequest,
        operationToken: String,
        complete: (PhoneControlResult<PhoneControlObservation>) -> Unit,
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
        lockedDenial()?.let { complete(it); return }
        claimDenial(principal.owner)?.let { complete(it); return }
        PhoneControlRuntime.publish()
        val ticket = fence.ticket(principal.owner)
            ?: run {
                complete(PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN))
                return
            }
        val normalized = request.normalized()
        val first = snapshotter.capture(
            owner = principal.owner,
            ticket = ticket,
            request = normalized,
            keyguardLocked = keyguardLocked(),
            isCancelled = { closed },
        )
        if (first != null) {
            complete(acceptObservation(principal, grant, first, normalized))
            return
        }
        // The active accessibility window can stay unpublished for a bounded
        // interval right after an in-call automatic unlock (demonstrated
        // Samsung first-observe failure: keyguard already reported unlocked at
        // the failure second while no active window root existed yet). Wait
        // inside the existing bounded settle lifecycle instead of failing the
        // observation; every terminal path below is owned by the existing
        // fence/cancel/abort machinery.
        val opId = UUID.randomUUID().toString()
        inFlightId = opId
        pendingClientToken = operationToken
        pendingObserve = complete
        PhoneControlObservationReadiness(
            driver = object : PhoneObservationReadinessDriver {
                override val now: Long get() = SystemClock.elapsedRealtime()
                override fun after(delayMs: Long, action: () -> Unit): () -> Unit {
                    val runnable = Runnable { action() }
                    mainHandler.postDelayed(runnable, delayMs)
                    return { mainHandler.removeCallbacks(runnable) }
                }
                override fun stillCurrent(): Boolean = !closed && inFlightId == opId
                override fun blocker(): PhoneControlBlocker? = fence.state().blocker
                override fun keyguardLocked(): Boolean = this@PhoneControlSession.keyguardLocked()
                override fun capture(): PhoneControlCapture? {
                    val live = fence.ticket(principal.owner) ?: return null
                    return snapshotter.capture(
                        owner = principal.owner,
                        ticket = live,
                        request = normalized,
                        keyguardLocked = keyguardLocked(),
                        isCancelled = { closed || inFlightId != opId },
                    )
                }
            },
        ).start { result ->
            if (inFlightId != opId) return@start
            when (result) {
                is PhoneControlResult.Ok ->
                    finishObserve(acceptObservation(principal, grant, result.value, normalized))
                is PhoneControlResult.Denied ->
                    if (result.reason == PhoneControlDenial.DEVICE_LOCKED) {
                        // A relock during the wait fences the run exactly like
                        // the synchronous lockedDenial/settle paths.
                        fence.block(PhoneControlBlocker.LOCKED)
                        latest = null
                        finishObserve(result)
                    } else {
                        finishObserve(result)
                    }
                is PhoneControlResult.Unavailable,
                is PhoneControlResult.Failed,
                -> finishObserve(result)
            }
        }
    }

    /** Policy acceptance shared by the synchronous capture and the bounded
     *  post-transition readiness gate; mints the session record only for a
     *  foreground the live grant may observe. */
    private fun acceptObservation(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
        capture: PhoneControlCapture,
        request: PhoneControlObserveRequest,
    ): PhoneControlResult<PhoneControlObservation> {
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
        latest = record(capture, request)
        PhoneControlRuntime.publish()
        return PhoneControlResult.Ok(capture.observation)
    }

    /**
     * One bounded page of the RETAINED observation named by [observationId].
     * This is a read of data that was already authorized and captured: it never
     * performs a new screen read, never replaces the session's latest record,
     * never bumps a generation and never extends the observation TTL. The exact
     * owner, fence/page generation, TTL and current package scope are
     * revalidated before a page is returned.
     */
    fun detail(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
        observationId: String,
        offset: Int,
        complete: (PhoneControlResult<PhoneControlDetailPage>) -> Unit,
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
        lockedDenial()?.let { complete(it); return }
        val record = latest
        if (record == null || record.observation.observationId != observationId) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.STALE_OBSERVATION))
            return
        }
        if (record.observation.owner != principal.owner) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN))
            return
        }
        verdictDenial(
            fence.validate(
                PhoneControlFence.Ticket(
                    owner = record.observation.owner,
                    fenceGeneration = record.observation.fenceGeneration,
                    pageGeneration = record.observation.pageGeneration,
                ),
            ),
        )?.let {
            complete(it)
            return
        }
        if (SystemClock.elapsedRealtime() > record.observation.expiresAtElapsedRealtimeMillis) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.OBSERVATION_EXPIRED))
            return
        }
        // The live grant may have narrowed its package scope since capture.
        PhoneControlPolicy.observationDenial(
            packageName = record.observation.packageName,
            effectivePackages = PhoneControlPolicy.effectivePackages(principal, grant),
            homePackage = homePackage(),
            allowGlobalNavigation = grant.allowGlobalNavigation,
            navigationMetadataOnly = record.observation.navigationOnly,
        )?.let {
            complete(PhoneControlResult.Denied(it))
            return
        }
        if (offset < 0 || offset > PhoneControlLimits.MAX_NODES) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT))
            return
        }
        complete(
            PhoneControlResult.Ok(
                PhoneControlObservationText.detail(record.observation, offset),
            ),
        )
    }

    fun arm(principal: PhoneControlPrincipal): PhoneControlResult<PhoneControlStatus> {
        if (closed) return PhoneControlResult.Denied(PhoneControlDenial.SERVICE_DISCONNECTED)
        if (inFlightId != null || unlocker.isSettling) {
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
        traceObservationClear("explicit_arm")
        latest = null
        PhoneControlRuntime.publish()
        return PhoneControlResult.Ok(PhoneControlRuntime.snapshot())
    }

    /** Launching an explicitly allowed app does not require reading the current
     * window. This bootstraps from Floe/launcher without exposing either tree. */
    fun launchApplication(principal: PhoneControlPrincipal, grant: PhoneControlGrant,
                          packageName: String): PhoneControlResult<PhoneControlActionResult> {
        if (closed) return PhoneControlResult.Denied(PhoneControlDenial.SERVICE_DISCONNECTED)
        if (inFlightId != null) return PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT)
        lockedDenial()?.let { return it }
        PhoneControlPolicy.grantDenial(principal, grant)?.let { return PhoneControlResult.Denied(it) }
        // Same effective/non-Floe/protected target rule as device.act launch:
        // the live grant can narrow the caller's request and can never list
        // Floe/system-installer identities as launchable targets.
        PhoneControlPolicy.launchDenial(
            packageName,
            PhoneControlPolicy.effectivePackages(principal, grant),
        )?.let { return PhoneControlResult.Denied(it) }
        when (val claim = fence.claim(principal.owner)) {
            is PhoneControlFence.Claim.Blocked -> return PhoneControlResult.Denied(PhoneControlPolicy.denialForBlocker(claim.blocker))
            PhoneControlFence.Claim.ForeignRun -> return PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN)
            PhoneControlFence.Claim.Ok -> Unit
        }
        val intent = service.packageManager.getLaunchIntentForPackage(packageName)
            ?: return PhoneControlResult.Unavailable(PhoneControlUnavailable.LAUNCH_TARGET_UNAVAILABLE)
        latest = null
        fence.onPageChanged()
        suppressOwnInput()
        return try {
            service.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or Intent.FLAG_ACTIVITY_NO_USER_ACTION))
            PhoneControlRuntime.publish()
            PhoneControlResult.Ok(PhoneControlActionResult("launch", PhoneControlDispatch.ACCEPTED,
                null, null, null, "Launch requested. Observe the target app before further actions."))
        } catch (_: Exception) { PhoneControlResult.Failed(PhoneControlFailure.ACTION_REJECTED) }
    }

    /**
     * Launch ONE typed App-owned read-only document VIEW while the App itself
     * may be backgrounded.
     *
     * This is intentionally not a general Intent/launch API. The request is
     * built by the trusted host from a verified handoff record; here every
     * field is revalidated against the live grant and the exact installed
     * component, and the only extras are the read grant flag plus ClipData.
     * The AccessibilityService binding is what lets the real Activity start
     * happen without an operator returning to Floe; it is the same platform
     * exemption the existing `device.act launch` path already uses.
     *
     * [stillCurrent] is the host's exact native-ticket/owner/generation fence.
     * It is checked again immediately before `startActivity`, and the session
     * fence/observation is invalidated so no stale page survives the launch.
     * An accepted start is NOT observed playback, import or save.
     */
    fun launchDocumentView(
        principal: PhoneControlPrincipal,
        grant: PhoneControlGrant,
        request: PhoneControlDocumentViewRequest,
        stillCurrent: () -> Boolean,
        complete: (PhoneControlResult<PhoneControlActionResult>) -> Unit,
    ) {
        if (closed) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.SERVICE_DISCONNECTED))
            return
        }
        if (inFlightId != null) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.OPERATION_IN_FLIGHT))
            return
        }
        lockedDenial()?.let { complete(it); return }
        PhoneControlPolicy.grantDenial(principal, grant)?.let {
            complete(PhoneControlResult.Denied(it))
            return
        }
        val effective = PhoneControlPolicy.effectivePackages(principal, grant)
        val authority = "${service.packageName}.externaledits"
        PhoneControlPolicy.documentViewDenial(request, authority, effective)?.let {
            complete(PhoneControlResult.Denied(it))
            return
        }
        when (val claim = fence.claim(principal.owner)) {
            is PhoneControlFence.Claim.Blocked ->
                return complete(PhoneControlResult.Denied(
                    PhoneControlPolicy.denialForBlocker(claim.blocker)))
            PhoneControlFence.Claim.ForeignRun ->
                return complete(PhoneControlResult.Denied(PhoneControlDenial.FOREIGN_RUN))
            PhoneControlFence.Claim.Ok -> Unit
        }
        if (!stillCurrent()) {
            complete(PhoneControlResult.Failed(PhoneControlFailure.CANCELLED))
            return
        }
        val uri = Uri.parse(request.uri)
        if (!validDocumentUri(uri, authority, request.displayName)) {
            complete(PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT))
            return
        }
        // Re-prove the EXACT selected component for this exact URI/MIME. A
        // handler that disappeared, moved or no longer accepts the document
        // is an honest target-unavailable, never a chooser fallback.
        val probe = Intent(Intent.ACTION_VIEW)
            .addCategory(Intent.CATEGORY_DEFAULT)
            .setDataAndType(uri, request.mimeType)
        val exactInstalled = runCatching {
            service.packageManager.queryIntentActivities(probe, 0)
        }.getOrDefault(emptyList()).any { info ->
            info.activityInfo?.packageName == request.packageName &&
                info.activityInfo?.name == request.className
        }
        if (!exactInstalled) {
            complete(PhoneControlResult.Unavailable(
                PhoneControlUnavailable.LAUNCH_TARGET_UNAVAILABLE))
            return
        }
        if (!stillCurrent()) {
            complete(PhoneControlResult.Failed(PhoneControlFailure.CANCELLED))
            return
        }
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, request.mimeType)
            .setClassName(request.packageName, request.className)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            .apply { clipData = ClipData.newRawUri(request.displayName, uri) }
        latest = null
        fence.onPageChanged()
        suppressOwnInput()
        // Last cancellation fence: a Stop/takeover that landed while the
        // main-thread hop was pending must not produce a late viewer.
        if (!stillCurrent()) {
            complete(PhoneControlResult.Failed(PhoneControlFailure.CANCELLED))
            return
        }
        // The OS dispatch boundary is separate from every post-start effect.
        // Only the closed known no-dispatch exceptions are a retryable
        // rejection; any other exception after the call was attempted has an
        // unknown outcome and must never be replayed.
        try {
            service.startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            complete(PhoneControlResult.Failed(PhoneControlFailure.ACTION_REJECTED,
                "The target document VIEW handler is not installed"))
            return
        } catch (_: SecurityException) {
            complete(PhoneControlResult.Failed(PhoneControlFailure.ACTION_REJECTED,
                "The target refused the document VIEW grant"))
            return
        } catch (_: Exception) {
            complete(PhoneControlResult.Failed(PhoneControlFailure.INTERNAL_ERROR,
                "The document VIEW outcome is unknown; do not repeat open"))
            return
        }
        // startActivity returned: the OS accepted the explicit start. A status
        // publication or caller-callback failure after this point is not a
        // launch rejection and must not permit a duplicate VIEW.
        runCatching { PhoneControlRuntime.publish() }
        complete(PhoneControlResult.Ok(PhoneControlActionResult(
            "documentView", PhoneControlDispatch.ACCEPTED, null, null, null,
            "Launch requested. Observe the target app before further actions.")))
    }

    private fun validDocumentUri(uri: Uri, expectedAuthority: String,
                                 displayName: String): Boolean {
        if (uri.scheme != "content" || uri.authority != expectedAuthority ||
            uri.query != null || uri.fragment != null
        ) return false
        val segments = uri.pathSegments
        if (segments.size != 4) return false
        if (segments[0] != "working" || segments[1] != "views") return false
        if (runCatching { UUID.fromString(segments[2]) }.isFailure) return false
        if (segments[3] != displayName) return false
        return segments.none { it.isEmpty() || it == "." || it == ".." }
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
        // The IME-action node operation is public API 30+. Older supported
        // platforms have no equivalent node action, so report that honestly
        // instead of pretending a click/search succeeded.
        if (action is PhoneControlAction.Commit && Build.VERSION.SDK_INT < 30) {
            complete(
                PhoneControlResult.Unavailable(
                    PhoneControlUnavailable.IME_ACTION_UNSUPPORTED,
                    "IME action submission needs Android 11 or newer on this device",
                ),
            )
            return
        }
        val record = latest
        val early = validateBeforeDispatch(record, principal, observationId, action, grant)
        if (early != null) {
            val state = fence.state()
            android.util.Log.i(
                "FloePhoneControl",
                "action_refused reason=${early.reason.name}" +
                    " has_observation=${record != null}" +
                    " id_matches=${record?.observation?.observationId == observationId}" +
                    " owner_matches=${record?.observation?.owner == principal.owner}" +
                    " fence_matches=${record?.observation?.fenceGeneration == state.fenceGeneration}" +
                    " page_matches=${record?.observation?.pageGeneration == state.pageGeneration}" +
                    " remaining_ms=${record?.observation?.expiresAtElapsedRealtimeMillis?.minus(SystemClock.elapsedRealtime())}",
            )
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
            is PhoneControlAction.Click -> {
                val node = record.records[action.nodeRef]
                    ?: return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                if (!node.visible) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                }
                if (!node.enabled) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
                }
            }
            is PhoneControlAction.Focus -> {
                val node = record.records[action.nodeRef]
                    ?: return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                if (!node.visible) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                }
                if (!node.enabled) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
                }
            }
            is PhoneControlAction.Commit -> {
                val node = record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
                if (!node.visible) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                }
                if (!node.enabled) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
                }
                if (!node.editable) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_EDITABLE)
                }
            }
            is PhoneControlAction.SetText -> {
                if (action.text.length > PhoneControlLimits.MAX_SET_TEXT_CHARS) {
                    return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
                }
                val node = record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
                if (!node.visible) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                }
                if (!node.enabled) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
                }
                if (!node.editable) return PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_EDITABLE)
                PhoneControlPolicy.fieldActionDenial(
                    node,
                    sensitiveInput = action.sensitive,
                )?.let {
                    return PhoneControlResult.Denied(it)
                }
            }
            is PhoneControlAction.Scroll -> {
                val node = record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
                if (!node.visible) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                }
                if (!node.enabled) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
                }
                if (!node.scrollable && node.actions.none { it.isScrollAction }) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_SCROLLABLE)
                }
            }
            is PhoneControlAction.Swipe -> {
                val node = record.records[action.nodeRef] ?: return PhoneControlResult.Denied(
                    PhoneControlDenial.NODE_UNAVAILABLE,
                )
                if (!node.visible) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_UNAVAILABLE)
                }
                if (!node.enabled) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_DISABLED)
                }
                PhoneControlPolicy.fieldActionDenial(node)?.let {
                    return PhoneControlResult.Denied(it)
                }
                val horizontal = action.direction == PhoneControlSwipeDirection.LEFT ||
                    action.direction == PhoneControlSwipeDirection.RIGHT
                val span = if (horizontal) node.bounds.width else node.bounds.height
                if (span < PhoneControlLimits.MIN_SWIPE_PX) {
                    return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
                }
                // A coordinate swipe is a scroll gesture, not a synthetic tap:
                // only perform it inside a real scrollable region (the node
                // itself, an enclosing scroller, an advertised scroll action,
                // or a captured scrollable descendant).
                if (!insideScrollableRegion(record, node, action.nodeRef)) {
                    return PhoneControlResult.Denied(PhoneControlDenial.NODE_NOT_SCROLLABLE)
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
                sensitiveInput = action.sensitive,
            )
            is PhoneControlAction.Scroll -> nodeAction(
                effective, record, action.nodeRef, NodeRequirement.SCROLL, opId,
                actionName = action.wireName, scrollDirection = action.direction, setText = null,
            )
            is PhoneControlAction.Swipe -> swipeAction(
                effective, record, action.nodeRef, action.direction, opId,
            )
            is PhoneControlAction.Focus -> nodeAction(
                effective, record, action.nodeRef, NodeRequirement.FOCUS, opId,
                actionName = action.wireName, scrollDirection = null, setText = null,
            )
            is PhoneControlAction.Commit -> nodeAction(
                effective, record, action.nodeRef, NodeRequirement.COMMIT, opId,
                actionName = action.wireName, scrollDirection = null, setText = null,
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
        sensitiveInput: Boolean = false,
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
                validateResolved(
                    node, nodeRecord, record, effective, requirement, sensitiveInput,
                )?.let {
                    finishAction(PhoneControlResult.Denied(it))
                    return
                }
                suppressOwnInput()
                var dispatchNote: String? = null
                val accepted = when (requirement) {
                    NodeRequirement.CLICK -> {
                        val flagClickable = runCatching { node.isClickable }.getOrDefault(false)
                        val ok = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        if (ok && !flagClickable) {
                            dispatchNote = "platform ACTION_CLICK accepted " +
                                "(isClickable=false); re-observe the effect"
                        }
                        ok
                    }
                    NodeRequirement.FOCUS -> node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                    // Android 11+ only; perform() refuses older platforms before
                    // any claim is taken. The guard also keeps the constant off
                    // older runtimes.
                    NodeRequirement.COMMIT -> if (Build.VERSION.SDK_INT >= 30) {
                        node.performAction(
                            AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id,
                        )
                    } else {
                        false
                    }
                    // Exact bytes go to the framework once, including a
                    // sensitive credential: nothing here logs, echoes,
                    // persists or blindly retries the payload.
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
                    val note = dispatchNote ?: when (requirement) {
                        NodeRequirement.SET_TEXT ->
                            "setText accepted; field buffer only, not a committed value; " +
                                "verify the enclosing value by observing"
                        NodeRequirement.FOCUS ->
                            "focus accepted; verify the focused field/IME by re-observation"
                        NodeRequirement.COMMIT ->
                            "IME action accepted; not proof a search/date committed; " +
                                "re-observe the result"
                        else ->
                            "framework accepted the action; re-observation is the effect check"
                    }
                    completeAfterDispatch(
                        record, opId, actionName, PhoneControlDispatch.ACCEPTED, null,
                        null,
                        note,
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
        ownInputEcho.noteOwnInput(SystemClock.uptimeMillis())
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
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
            Intent.FLAG_ACTIVITY_NO_USER_ACTION)
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
        sensitiveInput: Boolean = false,
    ): PhoneControlDenial? {
        val className = node.className?.toString().orEmpty()
        if (className != nodeRecord.className) return PhoneControlDenial.NODE_UNAVAILABLE
        val viewId = runCatching { node.viewIdResourceName }.getOrNull()
        if (viewId != nodeRecord.viewId) return PhoneControlDenial.NODE_UNAVAILABLE
        if (!runCatching { node.isVisibleToUser }.getOrDefault(false)) {
            return PhoneControlDenial.NODE_UNAVAILABLE
        }
        if (!runCatching { node.isEnabled }.getOrDefault(false)) {
            return PhoneControlDenial.NODE_DISABLED
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
            // The platform's own ACTION_CLICK advertisement is real declared
            // capability; a View that reports isClickable=false can still
            // expose it. Model-facing flags say click when either is present.
            NodeRequirement.CLICK ->
                if (runCatching { node.isClickable }.getOrDefault(false) ||
                    advertised(node, AccessibilityNodeInfo.ACTION_CLICK)
                ) {
                    null
                } else {
                    PhoneControlDenial.NODE_NOT_CLICKABLE
                }
            NodeRequirement.SET_TEXT -> when {
                !runCatching { node.isEditable }.getOrDefault(false) ->
                    PhoneControlDenial.NODE_NOT_EDITABLE
                // Fresh-tree recheck: a live protected field still refuses
                // ordinary text. The explicit sensitive route may fill it,
                // and the framework call alone is never treated as semantic
                // success — the contents are never read back either.
                !sensitiveInput && runCatching { node.isPassword }.getOrDefault(false) ->
                    PhoneControlDenial.SENSITIVE_FIELD
                else -> null
            }
            NodeRequirement.SCROLL ->
                if (runCatching { node.isScrollable }.getOrDefault(false) ||
                    advertisedScroll(node)
                ) {
                    null
                } else {
                    PhoneControlDenial.NODE_NOT_SCROLLABLE
                }
            NodeRequirement.FOCUS ->
                if (runCatching { node.isFocusable }.getOrDefault(false) ||
                    advertised(node, AccessibilityNodeInfo.ACTION_FOCUS)
                ) {
                    null
                } else {
                    PhoneControlDenial.NODE_NOT_FOCUSABLE
                }
            NodeRequirement.COMMIT -> when {
                !runCatching { node.isEditable }.getOrDefault(false) ->
                    PhoneControlDenial.NODE_NOT_EDITABLE
                // The IME action targets the focused editor. A field that
                // advertises the action itself is a platform-declared
                // capability even before it is focused; otherwise require real
                // input focus.
                runCatching { node.isFocused }.getOrDefault(false) ||
                    advertisedImeEnter(node) -> null
                else -> PhoneControlDenial.NODE_NOT_FOCUSED
            }
            NodeRequirement.SWIPE -> null
        }
    }

    /** True only when the live node advertises this exact platform action. */
    private fun advertised(node: AccessibilityNodeInfo, actionId: Int): Boolean =
        runCatching { node.actionList.any { it?.id == actionId } }.getOrDefault(false)

    private fun advertisedScroll(node: AccessibilityNodeInfo): Boolean =
        runCatching {
            node.actionList.any { action -> action?.id?.let { it in SCROLL_ACTION_IDS } == true }
        }.getOrDefault(false)

    private fun advertisedImeEnter(node: AccessibilityNodeInfo): Boolean =
        Build.VERSION.SDK_INT >= 30 &&
            advertised(node, AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)

    /**
     * A coordinate swipe may only run inside a real scrollable region: the
     * node, an enclosing scroll container, an advertised scroll action, or a
     * captured scrollable descendant. It never synthesizes a tap on a
     * read-only node.
     */
    private fun insideScrollableRegion(
        record: ObservationRecord,
        node: PhoneControlNodeRecord,
        nodeRef: String,
    ): Boolean {
        if (node.scrollable || node.insideScrollable ||
            node.actions.any { it.isScrollAction }
        ) {
            return true
        }
        val byRef = record.observation.nodes.associateBy { it.ref }
        for (candidate in record.observation.nodes) {
            if (!candidate.scrollable && candidate.actions.none { it.isScrollAction }) continue
            var parent = candidate.parentRef
            var hops = 0
            while (parent != null && hops < PhoneControlLimits.MAX_DEPTH) {
                if (parent == nodeRef) return true
                parent = byRef[parent]?.parentRef
                hops++
            }
        }
        return false
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
                isCancelled = { closed },
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

    fun stop() {
        // An explicit safety stop ends the task wake lease immediately; the
        // STOPPED blocker itself is not a user takeover, so ownership and the
        // existing relock receipts stay exactly as they were.
        unlocker.releaseTaskWake()
        applyGlobalBlocker(PhoneControlBlocker.STOPPED)
    }

    fun takeover() {
        unlocker.userInteraction()
        applyGlobalBlocker(PhoneControlBlocker.TAKEN_OVER)
    }

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
            // The task's automatic UI ownership ends here even when the host
            // closed the client before finish(); the wake-lease drop is
            // exact-owner guarded and idempotent after any earlier finish path.
            unlocker.releaseTaskWake(owner)
            latest = null
            abortInFlight(null, "the owning run ended; in-flight effect is unverified")
            PhoneControlRuntime.publish()
        }
    }

    fun onScreenOff() {
        if (closed) return
        // End owned wake resources before anything else touches the screen-off
        // path: never fight a manual power key, and a pending unlock attempt
        // conservatively settles as user takeover instead of re-waking.
        unlocker.onScreenOff()
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

    fun onWindowChanged(
        eventType: Int = 0,
        sourceWindowId: Int = -1,
        windowChanges: Int = 0,
        packageName: String? = null,
    ) {
        if (closed) return
        // Attribute the event before destroying a live observation: transient
        // windows from other packages (toasts, heads-up, system dialogs,
        // Floe's own overlay) leave the observed page untouched, while real
        // navigation and same-app page changes still clear it. Unattributable
        // events stay conservative and always invalidate.
        latest?.observation?.let { observation ->
            val keepsObservation = !windowEventInvalidates(
                observedWindowId = observation.windowId,
                observedPackageName = observation.packageName,
                eventWindowId = sourceWindowId,
                eventPackageName = packageName,
                isWindowStateChanged = eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
                activeWindowChanged =
                    eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED &&
                    (windowChanges and AccessibilityEvent.WINDOWS_CHANGE_ACTIVE) != 0,
            )
            if (keepsObservation) {
                traceObservationKept(eventType, sourceWindowId, windowChanges)
                return
            }
        }
        traceObservationClear("window_event", eventType, sourceWindowId, windowChanges)
        fence.onPageChanged()
        latest = null
        lastWindowChangeAt = SystemClock.elapsedRealtime()
        PhoneControlRuntime.publish()
    }

    fun onContentChanged() {
        lastContentChangeAt = SystemClock.elapsedRealtime()
    }

    /**
     * A semantic click/scroll inside Floe's own window. Programmatic own-App
     * UI (chat streaming/autoscroll while the protected page stays visible
     * after an automatic unlock) and a real user click both emit these
     * events; the genuine user touch is delivered separately by the trusted
     * own-App Activity hook, so this path never marks human presence, never
     * releases owned wake/relock and never fences the run.
     */
    fun onOwnAppSemanticEvent() {
        if (closed) return
        if (fence.state().owner != null) {
            // Closed diagnostic token only: no event text, package,
            // coordinates or payload — it identifies a later device trigger's
            // kind without reading the event.
            runCatching { android.util.Log.i("FloePhoneUnlock", "OWN_APP_SEMANTIC_EVENT_IGNORED") }
        }
    }

    /**
     * Trusted physical input on Floe's own Activity (touch or key), reported
     * through the neutral core-contract bridge. This is real user presence
     * and takes over exactly like a raw external touch: it marks the last
     * user interaction, stops owned relock, blocks the fence with USER_TOUCH
     * and aborts in-flight work. Unlike the platform accessibility stream,
     * this signal is trusted by construction, so no echo/suppression check
     * runs on it.
     */
    fun onOwnAppUserInteraction() {
        if (closed) return
        val now = SystemClock.elapsedRealtime()
        lastUserInteractionAt = now
        lastUserInteractionWallMillis = System.currentTimeMillis()
        if (fence.state().owner != null) {
            runCatching { android.util.Log.i("FloePhoneUnlock", "OWN_APP_USER_INTERACTION") }
        }
        unlocker.userInteraction()
        if (fence.state().owner == null && inFlightId == null) return
        traceObservationClear("own_app_user_interaction")
        fence.block(PhoneControlBlocker.USER_TOUCH)
        latest = null
        abortInFlight(PhoneControlBlocker.USER_TOUCH, "a user touch on Floe's own window interrupted the run")
        PhoneControlRuntime.publish()
    }

    fun onPlatformUserInteraction(eventUptimeMillis: Long? = null) {
        if (closed) return
        val now = SystemClock.elapsedRealtime()
        if (now <= suppressUserTouchUntil) return
        // Correlate delayed events with the bounded own-input interval.
        // Events outside it retain the existing user-takeover path.
        if (eventUptimeMillis != null && ownInputEcho.isOwnEcho(eventUptimeMillis)) {
            // Closed diagnostic token only: no event text, credential,
            // coordinates, identity or per-keystroke timing enters the log.
            runCatching { android.util.Log.i("FloePhoneUnlock", "LATE_OWN_INPUT_ECHO_IGNORED") }
            return
        }
        lastUserInteractionAt = now
        val lag = eventUptimeMillis?.let { (SystemClock.uptimeMillis() - it).coerceIn(0, 60_000) } ?: 0
        lastUserInteractionWallMillis = System.currentTimeMillis() - lag
        if (fence.state().owner != null) {
            val token = if (lag > 1_500) "OWNED_PHONE_USER_EVENT_LATE" else "OWNED_PHONE_USER_EVENT_FRESH"
            runCatching { android.util.Log.i("FloePhoneUnlock", token) }
        }
        unlocker.userInteraction()
        if (fence.state().owner == null && inFlightId == null) return
        traceObservationClear("user_interaction")
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
        unlocker.close()
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
        unlocker.cancel(operationToken)
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
                        isCancelled = { closed || inFlightId != opId },
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

    private fun finishObserve(result: PhoneControlResult<PhoneControlObservation>) {
        val callback = pendingObserve ?: return
        pendingObserve = null
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
        } else if (pendingObserve != null) {
            // Readiness-wait abort: stop/takeover/user-touch/screen-off,
            // run release and caller cancellation all terminate the pending
            // observation here, exactly once; the gate's stray poll sees
            // stillCurrent()==false and stops without a second completion.
            finishObserve(
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

    /** Only numeric transition metadata for an already-owned observation; no
     * node text, packages, credentials, owner IDs or observation IDs are logged. */
    private fun traceObservationClear(
        reason: String,
        eventType: Int = 0,
        sourceWindowId: Int = -1,
        windowChanges: Int = 0,
    ) {
        val observation = latest?.observation ?: return
        android.util.Log.i(
            "FloePhoneControl",
            "observation_cleared reason=$reason event=$eventType" +
                " source_window=$sourceWindowId observed_window=${observation.windowId}" +
                " changes=$windowChanges fence=${observation.fenceGeneration}" +
                " page=${observation.pageGeneration}" +
                " remaining_ms=${observation.expiresAtElapsedRealtimeMillis - SystemClock.elapsedRealtime()}",
        )
    }

    /** Numeric-only evidence that an attributed, unrelated window event kept
     * the observation; no text, packages or task/session identifiers. */
    private fun traceObservationKept(eventType: Int, sourceWindowId: Int, windowChanges: Int) {
        val observation = latest?.observation ?: return
        android.util.Log.i(
            "FloePhoneControl",
            "observation_kept event=$eventType" +
                " source_window=$sourceWindowId observed_window=${observation.windowId}" +
                " changes=$windowChanges fence=${observation.fenceGeneration}" +
                " page=${observation.pageGeneration}" +
                " remaining_ms=${observation.expiresAtElapsedRealtimeMillis - SystemClock.elapsedRealtime()}",
        )
    }

    private fun suppressOwnInput() {
        suppressUserTouchUntil = max(
            suppressUserTouchUntil,
            SystemClock.elapsedRealtime() + 600,
        )
        ownInputEcho.noteOwnInput(SystemClock.uptimeMillis())
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

        /**
         * Platform-declared scroll ids. ACTION_SCROLL_UP/DOWN/LEFT/RIGHT are
         * public since API 23 (below the 28 floor); they are read through the
         * AccessibilityAction object because the int constants on
         * AccessibilityNodeInfo are not part of the current public surface.
         */
        val SCROLL_ACTION_IDS: Set<Int> = setOf(
            AccessibilityNodeInfo.ACTION_SCROLL_FORWARD,
            AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD,
            AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_UP.id,
            AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_DOWN.id,
            AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_LEFT.id,
            AccessibilityNodeInfo.AccessibilityAction.ACTION_SCROLL_RIGHT.id,
        )
    }
}
