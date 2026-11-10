// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.os.Handler

/** Host-only result. No lock-screen nodes or credentials enter model observations. */
enum class PhoneUnlockResult { ALREADY_UNLOCKED, UNLOCKED, USER_REQUIRED, CANCELLED, FAILED }
enum class PhoneRelockResult { LOCKED, ALREADY_LOCKED, USER_TAKEN_OVER, USER_REQUIRED }
data class PhoneRelockReceipt(val owner: PhoneControlOwner, val result: PhoneRelockResult)

/** Sentinel for "no wake lease owned"; generation counters inside a driver start above it. */
internal const val NO_WAKE_LEASE = 0L

/**
 * The complete fixed closed set of wake-outcome labels. WAKE_READY_INITIAL
 * proves the reveal was permitted by an actually observed power/window
 * readiness at the first observation deadline; WAKE_READY_LATE proves the
 * first deadline elapsed unready and genuine readiness appeared later inside
 * the bounded window; WAKE_TIMEOUT proves the bounded window ended without
 * any observed readiness, with zero reveal and zero credential input.
 * Nothing else may ever reach the wake trace channel.
 */
internal const val WAKE_READY_INITIAL = "WAKE_READY_INITIAL"
internal const val WAKE_READY_LATE = "WAKE_READY_LATE"
internal const val WAKE_TIMEOUT = "WAKE_TIMEOUT"
internal val WAKE_OUTCOME_STAGES = setOf(WAKE_READY_INITIAL, WAKE_READY_LATE, WAKE_TIMEOUT)

/** Effects stay on the AccessibilityService main looper; tests use a deterministic clock. */
internal interface PhoneUnlockDriver {
    val locked: Boolean
    val now: Long
    /** The display is actually on; uncertain reads must answer false so no lease survives blindly. */
    val interactive: Boolean
    fun after(delay: Long, action: () -> Unit): () -> Unit
    fun suppressInput(until: Long)
    /**
     * Takes or re-wakes ONE owned bounded wake lease and returns its generation
     * (> [NO_WAKE_LEASE]); 0 means no lease was taken, which never aborts the
     * attempt (the display may already be interactive). The timeout is only a
     * crash/leak backstop: the real end is the owner-matched [releaseWake].
     * A new acquisition must not stack counts behind an older unowned lease.
     */
    fun acquireWake(timeoutMs: Long): Long
    /** Re-arms the backstop of exactly the given still-held generation; stale generations no-op. */
    fun renewWake(generation: Long, timeoutMs: Long)
    /** Releases exactly the given generation; a stale callback can never drop a replacement lease. */
    fun releaseWake(generation: Long)
    /** True only while the real native SystemUI keyguard observably shows a credential surface. */
    fun credentialVisible(): Boolean
    /**
     * The ONE pre-reveal readiness observation: actual default-display power
     * state plus trusted native SystemUI window presence, decided by genuinely
     * observed platform reads. Uncertain reads report a not-ready outcome.
     * Only [PhoneRevealReadiness.REVEAL_READY] may permit the reveal swipe and
     * only [PhoneRevealReadiness.CREDENTIAL_VISIBLE] may permit entering it;
     * an accepted wake request or an elapsed deadline never qualifies.
     */
    fun revealReadiness(): PhoneRevealReadiness
    /**
     * Emits one fixed closed wake-outcome label ([PhoneControlUnlocker]
     * publishes the exact set) as device evidence of which readiness branch
     * actually ran. Hosts must ignore any string outside that set; nothing
     * else — no ids, counts, text, credentials or exception payloads — is
     * ever logged through this channel.
     */
    fun traceWakeStage(stage: String)
    /**
     * Returns dispatch acceptance only. [onGestureResult] reports the actual
     * gesture completion (true) or cancellation (false) exactly once; a lost
     * callback is bounded by the caller's deadline and never assumed ready.
     */
    fun showCredential(onGestureResult: (Boolean) -> Unit): Boolean
    /** Hands the credential to the system at most once; true means dispatched, never unlocked. */
    fun enterCredential(secret: CharArray): Boolean
    fun requestLock(): Boolean
}

/** One bounded attempt and an observed, exact-owner cleanup; never adopts a prior process lease. */
internal class PhoneControlUnlocker(
    private val driver: PhoneUnlockDriver,
    private val stateChanged: () -> Unit = {},
) {
    constructor(service: AccessibilityService, handler: Handler,
        suppressGeneratedEvents: (Long) -> Unit, stateChanged: () -> Unit = {}) :
        this(AndroidPhoneUnlockDriver(service, handler, suppressGeneratedEvents), stateChanged)

    private class Attempt(val owner: PhoneControlOwner, val token: String, val credential: CharArray,
        val current: () -> Boolean, val taskCurrent: () -> Boolean,
        val complete: (PhoneUnlockResult) -> Unit) {
        var effectIssued = false
        var gestureReported = false
        var timer: (() -> Unit)? = null
        var wakeGeneration: Long = NO_WAKE_LEASE
    }

    /**
     * The same owned wake lease carried from a successfully observed unlock
     * through the task-owned automatic UI phase. Renewal checks this exact
     * holder's live ownership and the real display state; it ends on
     * finish/takeover/screen-off/close and its backstop bounds any lost cleanup.
     */
    private class TaskWake(val owner: PhoneControlOwner, val generation: Long, val live: () -> Boolean)

    private companion object {
        // Bounded observation windows. They only cap waiting; every success
        // decision needs an actually observed keyguard/window state read, and
        // no elapsed window ever dispatches the reveal by itself.
        const val WAKE_OBSERVE_MS = 400L
        // Real devices legitimately exceed the first observation window while
        // the panel finishes waking: past WAKE_OBSERVE_MS the reveal waits on
        // genuinely observed power/window readiness inside this hard cap. The
        // whole wake leg (400 + 3000 + poll granularity) stays inside the
        // 4000ms attempt-lease backstop armed at acquisition, and the reveal
        // leg re-arms it exactly as before.
        const val REVEAL_READY_DEADLINE_MS = 3_000L
        const val GESTURE_CALLBACK_DEADLINE_MS = 2_000L
        const val SURFACE_SETTLE_MS = 1_500L
        const val UNLOCK_OBSERVE_MS = 2_500L
        const val POLL_MS = 100L
        // Wake-lease backstops. Android releases the lease itself if every
        // owner-matched release path is lost; each attempt leg below is
        // bounded well under the leg backstop, and every task-phase renewal
        // first re-checks live ownership plus an actually interactive display.
        const val WAKE_LEG_BACKSTOP_MS = 4_000L
        const val WAKE_TASK_BACKSTOP_MS = 45_000L
        const val WAKE_TASK_RENEW_MS = 30_000L
    }
    private class Settlement(val owner: PhoneControlOwner, val deadline: Long, val mayComplete: Boolean) {
        var lockRequested = false
        var timer: (() -> Unit)? = null
    }
    private val attempted = LinkedHashSet<PhoneControlOwner>()
    private var attempt: Attempt? = null
    private var unlockedFor: PhoneControlOwner? = null
    private var settlement: Settlement? = null
    private var taskWake: TaskWake? = null
    private var taskWakeTimer: (() -> Unit)? = null
    val isSettling: Boolean get() = settlement != null
    var lastRelockReceipt: PhoneRelockReceipt? = null
        private set

    fun userInteraction() {
        val owner = attempt?.owner ?: settlement?.owner ?: unlockedFor
        unlockedFor = null
        owner?.let { releaseTaskWake(it) }
        settlement?.timer?.invoke()
        settlement = null
        attempt?.let { finishAttempt(it, PhoneUnlockResult.CANCELLED, relinquished = true) }
        if (owner != null) report(owner, PhoneRelockResult.USER_TAKEN_OVER)
    }

    fun unlock(owner: PhoneControlOwner, token: String, credential: CharArray,
        isCurrent: () -> Boolean, complete: (PhoneUnlockResult) -> Unit) {
        unlock(owner, token, credential, isCurrent, isCurrent, complete)
    }

    fun unlock(owner: PhoneControlOwner, token: String, credential: CharArray,
        isCurrent: () -> Boolean, taskIsCurrent: () -> Boolean,
        complete: (PhoneUnlockResult) -> Unit) {
        if (attempt != null || settlement != null || !runCatching(isCurrent).getOrDefault(false) ||
            (unlockedFor != null && unlockedFor != owner)) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.CANCELLED); return
        }
        val locked = runCatching { driver.locked }.getOrNull()
        if (locked == null) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.FAILED); return
        }
        if (!locked) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.ALREADY_UNLOCKED); return
        }
        if (credential.isEmpty() || credential.size > 64 || !attempted.add(owner)) {
            credential.fill('\u0000'); complete(PhoneUnlockResult.USER_REQUIRED); return
        }
        while (attempted.size > 64) attempted.remove(attempted.first())
        val current = Attempt(owner, token, credential, isCurrent, taskIsCurrent, complete)
        attempt = current
        try {
            driver.suppressInput(driver.now + 6_000)
            // Wake may itself complete a trusted system unlock. Any uncertain
            // cancellation after an effect therefore needs observed settlement.
            current.effectIssued = true
            // Own the wake resource across the whole asynchronous reveal /
            // observation instead of a transient poke: the lease lives until
            // an owner-matched release, with the timeout as crash backstop.
            current.wakeGeneration = driver.acquireWake(WAKE_LEG_BACKSTOP_MS)
            observeWake(current, driver.now + WAKE_OBSERVE_MS)
        } catch (_: Exception) { finishAttempt(current, PhoneUnlockResult.FAILED) }
    }

    /**
     * Bounded observation after wake: only an actually observed unlock or a
     * visibly displayed native credential surface advances the transaction.
     * A merely elapsed window never advances to the reveal — it hands the
     * decision to [observeRevealReady], which accepts genuinely observed
     * power/window readiness only.
     */
    private fun observeWake(current: Attempt, deadline: Long) {
        if (attempt !== current) return
        if (!driver.locked) finishAttempt(current, PhoneUnlockResult.UNLOCKED)
        else if (driver.credentialVisible()) submitCredential(current)
        else if (driver.now >= deadline)
            observeRevealReady(current, driver.now + REVEAL_READY_DEADLINE_MS, initialPass = true)
        else later(current, minOf(POLL_MS, deadline - driver.now)) { observeWake(current, deadline) }
    }

    /**
     * The ONE reveal is decided by actual readiness, never by the wake request,
     * the lease or any deadline: only a [PhoneRevealReadiness.REVEAL_READY]
     * observation (default display genuinely awake plus a live trusted SystemUI
     * keyguard window) dispatches the single swipe, and a
     * [PhoneRevealReadiness.CREDENTIAL_VISIBLE] observation enters the already
     * resolved surface without swiping over it. Not-ready observations keep
     * polling inside the overall bounded window; when readiness is never
     * observed by its end the attempt ends as USER_REQUIRED with zero reveal
     * and zero credential input, releasing the owned wake lease through the
     * normal finish cleanup. The fixed closed stage proves which branch ran.
     */
    private fun observeRevealReady(current: Attempt, readyDeadline: Long, initialPass: Boolean) {
        if (attempt !== current) return
        if (!driver.locked) { finishAttempt(current, PhoneUnlockResult.UNLOCKED); return }
        // An uncertain readiness read is a not-ready read: it never reveals.
        val readiness = runCatching { driver.revealReadiness() }
            .getOrDefault(PhoneRevealReadiness.DISPLAY_IDLE)
        when (readiness) {
            PhoneRevealReadiness.CREDENTIAL_VISIBLE -> {
                driver.traceWakeStage(if (initialPass) WAKE_READY_INITIAL else WAKE_READY_LATE)
                submitCredential(current)
            }
            PhoneRevealReadiness.REVEAL_READY -> {
                driver.traceWakeStage(if (initialPass) WAKE_READY_INITIAL else WAKE_READY_LATE)
                reveal(current)
            }
            PhoneRevealReadiness.DISPLAY_IDLE, PhoneRevealReadiness.SYSTEM_UI_PENDING -> {
                if (driver.now >= readyDeadline) {
                    driver.traceWakeStage(WAKE_TIMEOUT)
                    finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
                } else later(current, minOf(POLL_MS, readyDeadline - driver.now)) {
                    observeRevealReady(current, readyDeadline, initialPass = false)
                }
            }
        }
    }

    /**
     * Reached only after [observeRevealReady] genuinely observed awake
     * power/window readiness. The reveal outcome itself is decided by the real
     * gesture callback; the pre-armed deadline only bounds a lost callback, a
     * dispatch return is never readiness, and the gesture is never
     * re-dispatched.
     */
    private fun reveal(current: Attempt) {
        if (attempt !== current) return
        // This leg can run up to callback deadline + surface settle; re-arm the
        // bounded backstop only while this exact live attempt owns the lease.
        driver.renewWake(current.wakeGeneration, WAKE_LEG_BACKSTOP_MS)
        later(current, GESTURE_CALLBACK_DEADLINE_MS) { reportGesture(current, false, observedFallback = true) }
        val dispatched = runCatching {
            driver.showCredential { completed ->
                // Callback delivery is outside the timer wrapper, so it needs its own fence.
                try { reportGesture(current, completed) }
                catch (_: Exception) { finishAttempt(current, PhoneUnlockResult.FAILED) }
            }
        }.getOrDefault(false)
        if (!dispatched) finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
    }

    /**
     * Gesture completion/cancellation arrives through exactly one fenced,
     * at-most-once path. Only the lost-callback deadline may fall back to an
     * actually observed native surface; an explicit cancellation is final.
     */
    private fun reportGesture(current: Attempt, completed: Boolean, observedFallback: Boolean = false) {
        if (attempt !== current || current.gestureReported) return
        if (!runCatching(current.current).getOrDefault(false)) {
            finishAttempt(current, PhoneUnlockResult.CANCELLED); return
        }
        current.gestureReported = true
        current.timer?.invoke(); current.timer = null
        val ready = completed || (observedFallback && runCatching { driver.credentialVisible() }.getOrDefault(false))
        if (!ready) finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
        else observeSurface(current, driver.now + SURFACE_SETTLE_MS)
    }

    /** Even a completed gesture is not proof of readiness; the keyguard state decides. */
    private fun observeSurface(current: Attempt, deadline: Long) {
        if (attempt !== current) return
        if (!driver.locked) finishAttempt(current, PhoneUnlockResult.UNLOCKED)
        else if (driver.credentialVisible()) submitCredential(current)
        else if (driver.now >= deadline) finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
        else later(current, minOf(POLL_MS, deadline - driver.now)) { observeSurface(current, deadline) }
    }

    /**
     * One credential hand-off per attempt. Acceptance is only "the system took
     * the input"; success always requires the observed unlock in [observeUnlock].
     */
    private fun submitCredential(current: Attempt) {
        if (attempt !== current) return
        if (!runCatching(current.current).getOrDefault(false)) {
            finishAttempt(current, PhoneUnlockResult.CANCELLED); return
        }
        if (!driver.locked) { finishAttempt(current, PhoneUnlockResult.UNLOCKED); return }
        // Keep our own async input echoes inside the takeover-suppression window.
        driver.suppressInput(driver.now + UNLOCK_OBSERVE_MS + 500)
        // The unlock-observation leg follows dispatch; re-arm the bounded
        // backstop for this exact live attempt before handing the credential.
        driver.renewWake(current.wakeGeneration, WAKE_LEG_BACKSTOP_MS)
        val dispatched = runCatching { driver.enterCredential(current.credential) }.getOrDefault(false)
        if (!dispatched) finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
        else observeUnlock(current, driver.now + UNLOCK_OBSERVE_MS)
    }

    /** System auto-submit and slow OEM unlocks land here; timeout never re-enters the credential. */
    private fun observeUnlock(current: Attempt, deadline: Long) {
        if (attempt !== current) return
        if (!driver.locked) finishAttempt(current, PhoneUnlockResult.UNLOCKED)
        else if (driver.now >= deadline) finishAttempt(current, PhoneUnlockResult.USER_REQUIRED)
        else later(current, minOf(POLL_MS, deadline - driver.now)) { observeUnlock(current, deadline) }
    }

    private fun later(current: Attempt, delay: Long, action: () -> Unit) {
        current.timer = driver.after(delay) {
            current.timer = null
            if (attempt !== current) return@after
            if (!runCatching(current.current).getOrDefault(false)) finishAttempt(current, PhoneUnlockResult.CANCELLED)
            else try { action() } catch (_: Exception) { finishAttempt(current, PhoneUnlockResult.FAILED) }
        }
    }

    private fun finishAttempt(current: Attempt, result: PhoneUnlockResult, relinquished: Boolean = false) {
        if (attempt !== current) return
        attempt = null
        current.timer?.invoke(); current.timer = null
        current.credential.fill('\u0000')
        driver.suppressInput(driver.now + 150)
        val actualUnlocked = runCatching { !driver.locked }.getOrDefault(false)
        if (!relinquished && actualUnlocked && current.effectIssued) unlockedFor = current.owner
        val actualResult = if (result == PhoneUnlockResult.UNLOCKED && !actualUnlocked)
            PhoneUnlockResult.USER_REQUIRED else result
        if (!relinquished && actualResult == PhoneUnlockResult.UNLOCKED && actualUnlocked &&
            current.effectIssued) {
            // The task actually got this device unlocked: carry the same owned
            // lease into the task-owned automatic UI phase instead of releasing
            // it mid-round-trip. Renewal stays bound to the attempt's live
            // ownership callback and the real display state.
            adoptTaskWake(current)
        } else {
            // Failure, cancel or relinquish: release our exact generation now.
            driver.releaseWake(current.wakeGeneration)
            current.wakeGeneration = NO_WAKE_LEASE
        }
        if (!relinquished && actualResult != PhoneUnlockResult.UNLOCKED && current.effectIssued) {
            // An in-flight system transition may finish after Cancel. No more
            // credential input is permitted; only observe and clean up our lease.
            settle(current.owner, mayComplete = true)
        }
        current.complete(actualResult)
    }

    fun finish(owner: PhoneControlOwner) {
        val pending = attempt
        if (pending?.owner == owner) {
            finishAttempt(pending, PhoneUnlockResult.CANCELLED)
        } else if (settlement?.owner == owner) {
            return
        } else if (unlockedFor == owner) {
            // Exact-owner task end: the automatic UI no longer needs the
            // display, so drop the wake lease before relock settlement.
            releaseTaskWake(owner)
            settle(owner, mayComplete = false)
        }
    }

    private fun settle(owner: PhoneControlOwner, mayComplete: Boolean) {
        if (settlement != null) return
        val value = Settlement(owner, driver.now + 1_800, mayComplete)
        settlement = value
        stateChanged()
        checkSettlement(value)
    }

    private fun checkSettlement(value: Settlement) {
        if (settlement !== value) return
        val locked = runCatching { driver.locked }.getOrNull()
        if (locked == null) { endSettlement(value, PhoneRelockResult.USER_REQUIRED); return }
        if (locked && value.lockRequested) { endSettlement(value, PhoneRelockResult.LOCKED); return }
        if (locked && (!value.mayComplete || driver.now >= value.deadline)) {
            endSettlement(value, PhoneRelockResult.ALREADY_LOCKED); return
        }
        if (!locked && !value.lockRequested) {
            value.lockRequested = true
            val accepted = runCatching { driver.requestLock() }.getOrDefault(false)
            if (!accepted) { endSettlement(value, PhoneRelockResult.USER_REQUIRED); return }
            // A true dispatch return is not proof of actual keyguard state.
        }
        if (driver.now >= value.deadline) { endSettlement(value, PhoneRelockResult.USER_REQUIRED); return }
        try { value.timer = driver.after(100) { value.timer = null; checkSettlement(value) } }
        catch (_: Exception) { endSettlement(value, PhoneRelockResult.USER_REQUIRED) }
    }

    private fun endSettlement(value: Settlement, result: PhoneRelockResult) {
        if (settlement !== value) return
        value.timer?.invoke()
        settlement = null
        releaseTaskWake(value.owner)
        if (unlockedFor == value.owner) unlockedFor = null
        report(value.owner, result)
    }

    /**
     * A real display-off signal ends every owned wake resource: never fight a
     * manual power-key screen-off, and a pending attempt ends conservatively as
     * takeover. A stale event whose display is actually interactive (our own
     * bounded wake still racing the broadcast) keeps the live attempt.
     * Pending relock settlement and existing ownership receipts are untouched.
     */
    fun onScreenOff() {
        // Conservative: an uncertain interactive read is treated as screen-off.
        if (runCatching { driver.interactive }.getOrDefault(false)) return
        taskWake?.let { releaseTaskWake(it) }
        val current = attempt ?: return
        finishAttempt(current, PhoneUnlockResult.CANCELLED, relinquished = true)
        report(current.owner, PhoneRelockResult.USER_TAKEN_OVER)
    }

    /** Exact-owner prompt drop at task-level end paths (fence release/close ordering races). */
    fun releaseTaskWake(owner: PhoneControlOwner) {
        taskWake?.takeIf { it.owner == owner }?.let { releaseTaskWake(it) }
    }

    /**
     * Safety-stop boundary: end the task wake lease now without touching any
     * ownership/relock receipt. The single holder slot means this can only be
     * the current owner's own lease; a replacement holder is impossible until
     * the existing ownership guard clears.
     */
    fun releaseTaskWake() {
        taskWake?.let { releaseTaskWake(it) }
    }

    /**
     * Ownership transfer is one-way: the attempt's generation moves into the
     * single holder slot, so no stale attempt path can release or renew it,
     * and a replacement owner is impossible while this holder exists (the
     * existing [unlockedFor] guard keeps rejecting foreign/partial transactions).
     */
    private fun adoptTaskWake(current: Attempt) {
        val generation = current.wakeGeneration
        current.wakeGeneration = NO_WAKE_LEASE
        if (generation == NO_WAKE_LEASE) return
        // Credential input remains fenced by the exact invocation. Only the
        // already-observed unlock transfers its wake lease to the live task;
        // a completed invocation is not the end of that task's UI work.
        val holder = TaskWake(current.owner, generation, current.taskCurrent)
        taskWake = holder
        val live = runCatching { holder.live() }.getOrDefault(false)
        val screenOn = runCatching { driver.interactive }.getOrDefault(false)
        if (!live || !screenOn) { releaseTaskWake(holder); return }
        try {
            // The attempt's short backstop cannot bridge the first 30s task
            // tick. Transfer its lifetime now while ownership is still live.
            driver.renewWake(generation, WAKE_TASK_BACKSTOP_MS)
            scheduleTaskWakeRenewal(holder)
        } catch (_: Exception) { releaseTaskWake(holder) }
    }

    private fun releaseTaskWake(holder: TaskWake) {
        if (taskWake !== holder) return
        taskWake = null
        taskWakeTimer?.invoke(); taskWakeTimer = null
        driver.releaseWake(holder.generation)
    }

    /**
     * Bounded renewal driven only by the existing lease holder: each firing
     * re-checks this exact holder, its live ownership callback and an actually
     * interactive display before re-arming the same backstop. When the lease
     * ends no timer remains, so this is never an idle poller.
     */
    private fun scheduleTaskWakeRenewal(holder: TaskWake) {
        taskWakeTimer?.invoke()
        taskWakeTimer = try {
            driver.after(WAKE_TASK_RENEW_MS) {
                taskWakeTimer = null
                if (taskWake !== holder) return@after
                val live = runCatching { holder.live() }.getOrDefault(false)
                val screenOn = runCatching { driver.interactive }.getOrDefault(false)
                if (!live || !screenOn) { releaseTaskWake(holder); return@after }
                try {
                    driver.renewWake(holder.generation, WAKE_TASK_BACKSTOP_MS)
                    scheduleTaskWakeRenewal(holder)
                } catch (_: Exception) { releaseTaskWake(holder) }
            }
        } catch (_: Exception) {
            releaseTaskWake(holder)
            null
        }
    }

    private fun report(owner: PhoneControlOwner, result: PhoneRelockResult) {
        lastRelockReceipt = PhoneRelockReceipt(owner, result)
        stateChanged()
    }

    fun cancel(token: String) {
        attempt?.takeIf { it.token == token }?.let { finishAttempt(it, PhoneUnlockResult.CANCELLED) }
    }

    fun close() {
        // Service teardown ends this incarnation's authority. Never leave a
        // delayed cleanup capable of locking a replacement session/user, and
        // never carry an owned wake lease past this process/session boundary.
        val pending = attempt
        val owner = pending?.owner ?: settlement?.owner ?: unlockedFor
        val uncertainInput = pending?.effectIssued == true
        owner?.let { releaseTaskWake(it) }
        taskWake?.let { releaseTaskWake(it) }
        settlement?.timer?.invoke()
        settlement = null
        unlockedFor = null
        pending?.let { finishAttempt(it, PhoneUnlockResult.CANCELLED, relinquished = true) }
        if (owner != null) report(owner,
            if (!uncertainInput && runCatching { driver.locked }.getOrDefault(false))
                PhoneRelockResult.ALREADY_LOCKED else PhoneRelockResult.USER_REQUIRED)
    }
}
