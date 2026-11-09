// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.PowerManager
import android.os.SystemClock
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo

/**
 * Android effects for the existing task-owned unlock transaction.
 *
 * Nothing here decides unlock success: gesture/key/text dispatch only means the
 * system accepted an effect. The caller observes actual keyguard state within
 * bounded windows, so a false callback is impossible from this side.
 */
internal class AndroidPhoneUnlockDriver(
    private val service: AccessibilityService,
    private val handler: Handler,
    private val suppress: (Long) -> Unit,
) : PhoneUnlockDriver {
    private val keyguard = service.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
    private val power = service.getSystemService(Context.POWER_SERVICE) as PowerManager
    override val locked: Boolean get() = keyguard.isKeyguardLocked
    override val now: Long get() = SystemClock.elapsedRealtime()
    override val interactive: Boolean get() = runCatching { power.isInteractive }.getOrDefault(false)
    override fun suppressInput(until: Long) = suppress(until)
    override fun after(delay: Long, action: () -> Unit): () -> Unit {
        val work = Runnable { action() }
        check(handler.postDelayed(work, delay))
        return { handler.removeCallbacks(work) }
    }

    /**
     * One reusable, single-reference wake lease with generation fencing. The
     * timeout is only Android's own backstop (process death or a lost cleanup
     * path can never strand the display); every normal end is the owner-matched
     * [releaseWake]. Renewals replace the same reference, so counts cannot
     * accumulate, and a stale generation can neither renew nor release a
     * replacement owner's lease.
     */
    @Suppress("DEPRECATION")
    private val wakeLock: PowerManager.WakeLock =
        power.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "Floe:TaskUnlock").apply { setReferenceCounted(false) }
    private var wakeSequence = 0L
    private var wakeHeldGeneration = NO_WAKE_LEASE

    override fun acquireWake(timeoutMs: Long): Long {
        trace("WAKE_REQUESTED")
        if (timeoutMs <= 0) return NO_WAKE_LEASE
        return try {
            if (wakeHeldGeneration != NO_WAKE_LEASE) {
                // Defensive: only one owner can exist at a time, so any prior
                // reference is already unowned; drop it instead of stacking.
                wakeHeldGeneration = NO_WAKE_LEASE
                runCatching { wakeLock.release() }
            }
            wakeSequence += 1
            wakeHeldGeneration = wakeSequence
            wakeLock.acquire(timeoutMs)
            trace("WAKE_LEASE_ACQUIRED")
            wakeHeldGeneration
        } catch (_: Exception) {
            // No lease: the attempt continues (the display may already be on),
            // and every later renew/release on generation 0 stays a no-op.
            wakeHeldGeneration = NO_WAKE_LEASE
            trace("WAKE_LEASE_UNAVAILABLE")
            NO_WAKE_LEASE
        }
    }

    override fun renewWake(generation: Long, timeoutMs: Long) {
        if (generation == NO_WAKE_LEASE || generation != wakeHeldGeneration || timeoutMs <= 0) return
        try {
            // Replace rather than accumulate: release + re-acquire keeps exactly
            // one live reference behind a fresh bounded backstop.
            runCatching { wakeLock.release() }
            wakeLock.acquire(timeoutMs)
            trace("WAKE_LEASE_RENEWED")
        } catch (_: Exception) {
            wakeHeldGeneration = NO_WAKE_LEASE
        }
    }

    override fun releaseWake(generation: Long) {
        if (generation == NO_WAKE_LEASE || generation != wakeHeldGeneration) return
        wakeHeldGeneration = NO_WAKE_LEASE
        runCatching { wakeLock.release() }
        trace("WAKE_LEASE_RELEASED")
    }

    /**
     * Dispatches the reveal swipe with a real gesture callback. The return value
     * is only "dispatch accepted"; [onGestureResult] reports the actual system
     * result exactly once (completed true / cancelled false) on the service
     * looper. A lost callback is bounded by the caller's deadline, never assumed.
     */
    override fun showCredential(onGestureResult: (Boolean) -> Unit): Boolean {
        val metrics = service.resources.displayMetrics
        val path = Path().apply {
            moveTo(metrics.widthPixels * .5f, metrics.heightPixels * .82f)
            lineTo(metrics.widthPixels * .5f, metrics.heightPixels * .25f)
        }
        var reported = false
        val accepted = service.dispatchGesture(GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 300)).build(),
            object : AccessibilityService.GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription) {
                    if (reported) return
                    reported = true
                    trace("REVEAL_COMPLETED")
                    onGestureResult(true)
                }
                override fun onCancelled(gestureDescription: GestureDescription) {
                    if (reported) return
                    reported = true
                    trace("REVEAL_CANCELLED")
                    onGestureResult(false)
                }
            }, handler)
        trace(if (accepted) "REVEAL_ACCEPTED" else "REVEAL_REFUSED")
        return accepted
    }

    /**
     * True only while a fresh, trusted default-display SystemUI window actually
     * observably shows a credential field, a labelled submit control or keypad
     * digits, and the display is genuinely interactive. Metadata only: no node
     * text, content or app windows enter the result.
     */
    override fun credentialVisible(): Boolean {
        val resolved = resolveCredentialSurface() ?: return false
        @Suppress("DEPRECATION")
        resolved.root.recycle()
        return true
    }

    override fun requestLock(): Boolean =
        service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_LOCK_SCREEN)

    /**
     * Hands the credential to the system at most once per call. Returning true
     * means input was dispatched, not unlocked: some surfaces auto-submit the
     * final entry and others need one real submit action. The caller's observed
     * keyguard check decides the outcome; nothing here retries or replays input.
     * The surface is re-resolved and its ownership rechecked immediately before
     * the single dispatch, so a tree that went stale, foreign or ambiguous
     * between the visibility observation and this call can never receive input.
     */
    override fun enterCredential(secret: CharArray): Boolean {
        val resolved = resolveCredentialSurface() ?: run {
            trace("CREDENTIAL_ROOT_UNAVAILABLE"); return false
        }
        val root = resolved.root
        try {
            if (root.packageName?.toString() != SYSTEM_UI_PACKAGE || !resolved.ownershipTrusted) {
                trace("CREDENTIAL_WINDOW_UNAVAILABLE"); return false
            }
            for (id in credentialFieldIds) {
                val nodes = root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/$id")
                try {
                    val field = nodes.firstOrNull { it.isEditable && it.isPassword && it.isVisibleToUser &&
                        it.packageName?.toString() == SYSTEM_UI_PACKAGE && it.windowId == root.windowId }
                    if (field != null && field.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT }) {
                        val value = String(secret)
                        val accepted = field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value)
                        })
                        trace(if (accepted) "SET_TEXT_ACCEPTED" else "SET_TEXT_REFUSED")
                        if (!accepted) return false
                        // One best-effort submit while still locked; a refused or
                        // absent submit stays for the observer/auto-submit path.
                        if (locked) clickSubmit(root)
                        return true
                    }
                } finally { nodes.forEach { @Suppress("DEPRECATION") it.recycle() } }
            }
            if (!secret.all { it in '0'..'9' }) {
                trace("CREDENTIAL_FIELD_UNAVAILABLE"); return false
            }
            for (digit in secret) {
                if (!click(root, listOf("key$digit", "key_$digit"), allowSubmitAncestor = false)) {
                    trace("KEYPAD_ACTION_UNAVAILABLE"); return false
                }
            }
            trace("KEYPAD_INPUT_DISPATCHED")
            // Some configured PIN screens submit the final digit themselves.
            if (locked) clickSubmit(root)
            return true
        } finally { @Suppress("DEPRECATION") root.recycle() }
    }

    private fun clickSubmit(root: AccessibilityNodeInfo): Boolean {
        val accepted = click(root, submitIds, allowSubmitAncestor = true)
        trace(if (accepted) "SUBMIT_ACCEPTED" else "SUBMIT_UNAVAILABLE")
        return accepted
    }

    /** Closed stage labels only: never ids, text, counts, credentials or exception messages. */
    private fun trace(stage: String) {
        runCatching { android.util.Log.i("FloePhoneUnlock", stage) }
    }

    /**
     * Freshly resolves the trusted default-display credential surface for the
     * current observation. The active-window root is kept as the fast path; if
     * it is null, foreign, stale or simply not the credential window, the
     * actually reported interactive window set decides via the pure selection,
     * with package/visibility/focus/lifecycle validation on every candidate.
     * The returned root is owned by the caller and must be recycled exactly
     * once; all other retrieved roots are recycled here.
     */
    private fun resolveCredentialSurface(): ResolvedSurface? {
        val displayInteractive = interactive
        // rootInActiveWindow may name a window on another logical display; the
        // interactive window set is the platform's own default-display view.
        val windows: List<AccessibilityWindowInfo> = if (displayInteractive)
            runCatching { service.windows }.getOrDefault(emptyList()) else emptyList()
        val defaultDisplayWindowIds: Set<Int>? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
            windows.mapNotNull { window ->
                runCatching { if (window.displayId == Display.DEFAULT_DISPLAY) window.id else null }.getOrNull()
            }.toSet()
        else null
        val activeRoot = if (displayInteractive) runCatching { service.rootInActiveWindow }.getOrNull() else null
        val retrieved = ArrayList<AccessibilityNodeInfo>()
        var chosen: AccessibilityNodeInfo? = null
        try {
            val windowCandidates = windows.map { WindowSurfaceCandidate(it, retrieved) { node ->
                hasCredentialContent(node)
            } }
            val activeCandidate = if (activeRoot != null)
                ActiveRootSurfaceCandidate(activeRoot, defaultDisplayWindowIds) {
                    hasCredentialContent(activeRoot)
                }
            else null
            val observation = selectCredentialSurface(displayInteractive, activeCandidate, windowCandidates)
            traceSurfaceChange(observation)
            chosen = when (observation.outcome) {
                SurfaceStage.SURFACE_READY_ACTIVE_ROOT -> activeRoot
                SurfaceStage.SURFACE_READY_WINDOW ->
                    windowCandidates.getOrNull(observation.windowIndex)?.retrievedRoot()
                else -> null
            }
            return chosen?.let { surface ->
                ResolvedSurface(
                    root = surface,
                    trustedWindowIds = defaultDisplayWindowIds
                        ?: if (windows.isEmpty()) null
                           else windows.mapNotNull { w -> runCatching { w.id }.getOrNull() }.toSet(),
                )
            }
        } finally {
            if (activeRoot != null && activeRoot !== chosen) {
                @Suppress("DEPRECATION") activeRoot.recycle()
            }
            retrieved.forEach { node ->
                if (node !== chosen) runCatching { @Suppress("DEPRECATION") node.recycle() }
            }
            // Window metadata objects return to the platform pool even on the
            // active-root fast path where no window root was ever retrieved.
            windows.forEach { info -> runCatching { @Suppress("DEPRECATION") info.recycle() } }
        }
    }

    private var lastSurfaceTrace: String? = null

    /**
     * Emits the closed readiness sequence only when it changes, so the bounded
     * 100ms polls leave an actionable transition trace (for example
     * ACTIVE_ROOT_ABSENT WINDOW_SURFACE_PENDING -> ACTIVE_ROOT_ABSENT
     * SURFACE_READY_WINDOW) without values or log spam.
     */
    private fun traceSurfaceChange(observation: SurfaceObservation) {
        val text = observation.traceText()
        if (text == lastSurfaceTrace) return
        lastSurfaceTrace = text
        trace(text)
    }

    private fun hasCredentialContent(root: AccessibilityNodeInfo): Boolean =
        anyVisible(root, credentialFieldIds) || anyVisible(root, submitIds) || anyVisible(root, keypadSampleIds)

    private fun anyVisible(root: AccessibilityNodeInfo, ids: List<String>): Boolean {
        for (id in ids) {
            val nodes = root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/$id")
            try { if (nodes.any { it.isEnabled && it.isVisibleToUser }) return true }
            finally { nodes.forEach { @Suppress("DEPRECATION") it.recycle() } }
        }
        return false
    }

    private fun click(root: AccessibilityNodeInfo, ids: List<String>, allowSubmitAncestor: Boolean): Boolean {
        for (id in ids) {
            val nodes = root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/$id")
            try {
                for (node in nodes) {
                    if (node.packageName?.toString() != SYSTEM_UI_PACKAGE || !node.isEnabled) continue
                    // Ownership recheck: the acting node must live in the very
                    // window whose root was freshly resolved and validated.
                    if (node.windowId != root.windowId) continue
                    val offersClick = runCatching {
                        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }
                    }.getOrDefault(false)
                    if (acceptsNativeClickAction(node.isEnabled, node.isClickable, offersClick)) {
                        if (node.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true
                        if (node.isClickable) continue
                        // An offered-but-refused click on a node not marked
                        // clickable may still act through its bounded SystemUI
                        // ancestor; a plain clickable refusal stays final.
                    }
                    if (!allowSubmitAncestor) continue
                    // OEM submit labels (for example Samsung's nonclickable
                    // key_enter_text) act only through their real bounded,
                    // enabled and clickable SystemUI ancestor; never an
                    // inferred screen coordinate and never outside SystemUI.
                    val owned = ArrayList<AccessibilityNodeInfo>()
                    try {
                        val target = findBoundedClickableSubmitAncestor(
                            AccessibilitySubmitWalkNode(node, owned), SUBMIT_ANCESTOR_MAX_HOPS) ?: continue
                        if (target.performClick()) return true
                    } finally { owned.forEach { @Suppress("DEPRECATION") it.recycle() } }
                }
            } finally { nodes.forEach { @Suppress("DEPRECATION") it.recycle() } }
        }
        return false
    }

    /** A caller-owned credential surface root plus the window ids validated for it. */
    private class ResolvedSurface(val root: AccessibilityNodeInfo, val trustedWindowIds: Set<Int>?) {
        /** Final ownership recheck before the single credential dispatch. */
        val ownershipTrusted: Boolean
            get() = trustedWindowIds == null || root.windowId in trustedWindowIds
    }

    /** The fast path root: trusted only while it is current and on the default display. */
    private class ActiveRootSurfaceCandidate(
        private val root: AccessibilityNodeInfo,
        private val defaultDisplayWindowIds: Set<Int>?,
        private val probe: () -> Boolean,
    ) : SurfaceCandidate {
        override val onDefaultDisplay: Boolean
            get() = defaultDisplayWindowIds?.contains(root.windowId) ?: true
        override val contentAvailable: Boolean get() = true
        override val trustedSystemUiRoot: Boolean
            get() = root.packageName?.toString() == SYSTEM_UI_PACKAGE
        override val lifecycleConsistent: Boolean get() = root.windowId >= 0
        override val inputFocused: Boolean get() = true
        override fun showsCredentialContent(): Boolean = runCatching(probe).getOrDefault(false)
    }

    /**
     * One window of the interactive set. Its root is retrieved lazily and only
     * after the cheap display gate needs it; every retrieved root is tracked so
     * the resolver recycles all but the finally chosen surface.
     */
    private class WindowSurfaceCandidate(
        private val window: AccessibilityWindowInfo,
        private val retrieved: MutableList<AccessibilityNodeInfo>,
        private val probe: (AccessibilityNodeInfo) -> Boolean,
    ) : SurfaceCandidate {
        private var retrievedRoot: AccessibilityNodeInfo? = null
        private var probed = false
        fun retrievedRoot(): AccessibilityNodeInfo? = root()
        private fun root(): AccessibilityNodeInfo? {
            if (!probed) {
                probed = true
                retrievedRoot = runCatching { window.root }.getOrNull()?.also { retrieved += it }
            }
            return retrievedRoot
        }
        override val onDefaultDisplay: Boolean
            get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                runCatching { window.displayId == Display.DEFAULT_DISPLAY }.getOrDefault(false)
            else true // The interactive window set is default-display-only below API 30.
        override val contentAvailable: Boolean get() = root() != null
        override val trustedSystemUiRoot: Boolean
            get() = root()?.packageName?.toString() == SYSTEM_UI_PACKAGE
        override val lifecycleConsistent: Boolean
            get() = root()?.let { r ->
                runCatching { window.id == r.windowId }.getOrDefault(false)
            } == true
        override val inputFocused: Boolean
            get() = runCatching { window.isActive || window.isFocused }.getOrDefault(false)
        override fun showsCredentialContent(): Boolean {
            val node = root() ?: return false
            return runCatching { probe(node) }.getOrDefault(false)
        }
    }

    private companion object {
        const val SYSTEM_UI_PACKAGE = "com.android.systemui"
        val credentialFieldIds = listOf("passwordEntry", "pinEntry", "password_entry", "pin_entry")
        val submitIds = listOf("key_enter", "key_enter_text", "password_confirm", "ok")
        val keypadSampleIds = listOf("key1", "key_1", "key0", "key_0")
    }
}

/** Upper bound on SystemUI-only parent hops used to reach an OEM submit container. */
internal const val SUBMIT_ANCESTOR_MAX_HOPS = 4

/** Android-free view of one keyguard node so the OEM submit decision is pure and testable. */
internal interface SubmitWalkNode {
    val systemUiPackage: Boolean
    val enabled: Boolean
    val clickable: Boolean
    /** Screen bounds as [left, top, right, bottom]. */
    val bounds: IntArray
    val parent: SubmitWalkNode?
    fun performClick(): Boolean
}

/**
 * An ancestor may act for the labelled child only when it positively contains
 * the child's observed bounds; equal bounds and sentinel zero-area boxes are
 * rejected instead of guessed.
 */
internal fun boundsPositivelyContain(container: IntArray, contained: IntArray): Boolean =
    container.size == 4 && contained.size == 4 &&
        contained[2] > contained[0] && contained[3] > contained[1] &&
        container[2] > container[0] && container[3] > container[1] &&
        container[0] <= contained[0] && container[1] <= contained[1] &&
        container[2] >= contained[2] && container[3] >= contained[3]

/**
 * Walks at most [maxHops] parents for an enabled, clickable node inside the
 * same native SystemUI window that actually bounds [child]. A foreign-package
 * ancestor stops the walk entirely; the recorded Samsung empty-keyguard
 * ancestry (key_enter_text -> keyguard_host_view -> unnamed FrameLayout, all
 * nonclickable) intentionally finds nothing here.
 */
internal fun findBoundedClickableSubmitAncestor(
    child: SubmitWalkNode,
    maxHops: Int = SUBMIT_ANCESTOR_MAX_HOPS,
): SubmitWalkNode? {
    val childBounds = child.bounds
    var node = child.parent
    var hop = 0
    while (node != null && hop < maxHops) {
        if (!node.systemUiPackage) return null
        if (node.enabled && node.clickable &&
            boundsPositivelyContain(node.bounds, childBounds)) return node
        node = node.parent
        hop += 1
    }
    return null
}

/** Adapter for the live tree; parents are tracked for recycling by the driver. */
private class AccessibilitySubmitWalkNode(
    private val node: AccessibilityNodeInfo,
    private val owned: MutableList<AccessibilityNodeInfo>,
) : SubmitWalkNode {
    override val systemUiPackage: Boolean
        get() = node.packageName?.toString() == "com.android.systemui"
    override val enabled: Boolean get() = node.isEnabled
    override val clickable: Boolean get() = node.isClickable ||
        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }
    override val bounds: IntArray
        get() {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            return intArrayOf(rect.left, rect.top, rect.right, rect.bottom)
        }
    override val parent: SubmitWalkNode?
        get() = node.parent?.let {
            owned.add(it)
            AccessibilitySubmitWalkNode(it, owned)
        }
    override fun performClick(): Boolean = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
}
