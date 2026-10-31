// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Host callback that answers the live task/run/permission question for one
 * operation. It is called on the caller's thread before any node is read or
 * action dispatched. Returning `null` revokes; the callback is authoritative
 * and must not be replaced by a cached/opaque grant. It must be fast and must
 * not mutate permissions or perform blocking I/O.
 */
fun interface PhoneControlAuthority {
    fun authorize(principal: PhoneControlPrincipal): PhoneControlGrant?
}

/**
 * Small public phone-control API for the Full app host.
 *
 * The service is created by Android, so this client never binds it directly.
 * All operations are fenced by the host's live grant plus the service's
 * stop/takeover/lock/revocation generations. Actions are dispatched on the
 * AccessibilityService main thread, then re-observed; framework acceptance is
 * never reported as a semantic success.
 *
 * Construct through [PhoneControlModule.client]. A client is scoped to the
 * host's current task/run and should be closed when that run ends.
 */
class PhoneControlClient internal constructor(
    context: Context,
    private val authority: PhoneControlAuthority,
) : Closeable {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)

    @Volatile
    private var lastOwner: PhoneControlOwner? = null

    val isClosed: Boolean get() = closed.get()

    suspend fun observe(
        principal: PhoneControlPrincipal,
        request: PhoneControlObserveRequest = PhoneControlObserveRequest(),
    ): PhoneControlResult<PhoneControlObservation> {
        val grant = when (val answer = authorization(principal)) {
            is PhoneControlResult.Ok -> answer.value
            is PhoneControlResult.Denied -> return answer
            is PhoneControlResult.Unavailable -> return answer
            is PhoneControlResult.Failed -> return answer
        }
        return dispatch { session, _, finish ->
            finish(session.observe(principal, grant, request))
        }
    }

    suspend fun perform(
        principal: PhoneControlPrincipal,
        observationId: String,
        action: PhoneControlAction,
    ): PhoneControlResult<PhoneControlActionResult> {
        if (observationId.isBlank()) {
            return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        }
        val nodeRef = when (action) {
            is PhoneControlAction.Click -> action.nodeRef
            is PhoneControlAction.SetText -> action.nodeRef
            is PhoneControlAction.Scroll -> action.nodeRef
            is PhoneControlAction.Swipe -> action.nodeRef
            PhoneControlAction.Back, PhoneControlAction.Home, is PhoneControlAction.Launch -> null
        }
        if (nodeRef != null && nodeRef.isBlank()) {
            return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        }
        if (action is PhoneControlAction.SetText &&
            action.text.length > PhoneControlLimits.MAX_SET_TEXT_CHARS
        ) {
            return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        }
        if (action is PhoneControlAction.Launch &&
            (action.packageName.isBlank() ||
                action.packageName.length > PhoneControlLimits.MAX_PACKAGE_CHARS)
        ) {
            return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        }
        val grant = when (val answer = authorization(principal)) {
            is PhoneControlResult.Ok -> answer.value
            is PhoneControlResult.Denied -> return answer
            is PhoneControlResult.Unavailable -> return answer
            is PhoneControlResult.Failed -> return answer
        }
        return dispatch { session, token, finish ->
            session.perform(principal, grant, observationId, action, token, finish)
        }
    }

    /**
     * A window-scoped screenshot requires a current [observationId]. Without
     * one, an explicit display capture is performed (API 30+). On API 30-33 a
     * window-scoped request is refused instead of widening to the display.
     * The live grant's `allowScreenshot` must be enabled after the user sees
     * the whole-screen vs window scope; there is no default permission. A
     * display capture refuses observable IME/overlay/foreign windows.
     */
    suspend fun screenshot(
        principal: PhoneControlPrincipal,
        observationId: String?,
        request: PhoneControlScreenshotRequest = PhoneControlScreenshotRequest(),
    ): PhoneControlResult<PhoneControlScreenshot> {
        if (observationId != null && observationId.isBlank()) {
            return PhoneControlResult.Denied(PhoneControlDenial.INVALID_ARGUMENT)
        }
        val grant = when (val answer = authorization(principal)) {
            is PhoneControlResult.Ok -> answer.value
            is PhoneControlResult.Denied -> return answer
            is PhoneControlResult.Unavailable -> return answer
            is PhoneControlResult.Failed -> return answer
        }
        return dispatch { session, token, finish ->
            session.screenshot(principal, grant, observationId, request, token, finish)
        }
    }

    /**
     * Explicit host/UI re-arm after a user stop/takeover. This is not an Agent
     * tool: it must be called only from a user-visible re-enable action, and it
     * still requires a live host grant. It never clears LOCKED or a missing
     * service.
     */
    suspend fun arm(principal: PhoneControlPrincipal): PhoneControlResult<PhoneControlStatus> {
        when (val answer = authorization(principal)) {
            is PhoneControlResult.Ok -> Unit
            is PhoneControlResult.Denied -> return answer
            is PhoneControlResult.Unavailable -> return answer
            is PhoneControlResult.Failed -> return answer
        }
        return dispatch { session, _, finish ->
            finish(session.arm(principal))
        }
    }

    /** Always-available safety stop; idempotent and not gated on a grant. */
    fun stop() {
        if (closed.get()) return
        onMain { PhoneControlRuntime.session()?.stop() }
    }

    /** User took the device back; equivalent to stop with a different reason. */
    fun takeover() {
        if (closed.get()) return
        onMain { PhoneControlRuntime.session()?.takeover() }
    }

    fun status(): PhoneControlStatus = PhoneControlRuntime.snapshot()

    fun activation(): PhoneControlActivation = PhoneControlActivation(appContext)

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val owner = lastOwner ?: return
        onMain { PhoneControlRuntime.session()?.release(owner) }
    }

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
        } else {
            mainHandler.post(block)
        }
    }

    private fun authorization(
        principal: PhoneControlPrincipal,
    ): PhoneControlResult<PhoneControlGrant> {
        if (closed.get()) return PhoneControlResult.Denied(PhoneControlDenial.CLIENT_CLOSED)
        PhoneControlPolicy.principalDenial(principal)?.let {
            return PhoneControlResult.Denied(it)
        }
        if (PhoneControlRuntime.session() == null) {
            return PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED)
        }
        val grant = try {
            authority.authorize(principal)
        } catch (error: Exception) {
            null
        } ?: return PhoneControlResult.Denied(PhoneControlDenial.AUTHORIZATION_DENIED)
        PhoneControlPolicy.grantDenial(principal, grant)?.let {
            return PhoneControlResult.Denied(it)
        }
        lastOwner = principal.owner
        return PhoneControlResult.Ok(grant)
    }

    private suspend fun <T> dispatch(
        block: (
            session: PhoneControlSession,
            operationToken: String,
            finish: (PhoneControlResult<T>) -> Unit,
        ) -> Unit,
    ): PhoneControlResult<T> = suspendCancellableCoroutine { continuation ->
        val token = UUID.randomUUID().toString()
        val finished = AtomicBoolean(false)
        fun finish(result: PhoneControlResult<T>) {
            if (finished.compareAndSet(false, true) && continuation.isActive) {
                continuation.resume(result)
            }
        }
        val posted = mainHandler.post {
            if (!continuation.isActive) return@post
            val session = PhoneControlRuntime.session()
            if (session == null) {
                finish(PhoneControlResult.Unavailable(PhoneControlUnavailable.SERVICE_NOT_CONNECTED))
            } else {
                runCatching { block(session, token, ::finish) }
                    .onFailure { finish(PhoneControlResult.Failed(PhoneControlFailure.INTERNAL_ERROR)) }
            }
        }
        if (!posted) finish(PhoneControlResult.Failed(PhoneControlFailure.INTERNAL_ERROR))
        continuation.invokeOnCancellation {
            mainHandler.post { PhoneControlRuntime.session()?.cancelOperation(token) }
        }
    }
}
