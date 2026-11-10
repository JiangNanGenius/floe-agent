// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.app.KeyguardManager
import android.content.Context
import android.graphics.Path
import android.graphics.Rect
import android.hardware.display.DisplayManager
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
    private val displays = service.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
    override val locked: Boolean get() = keyguard.isKeyguardLocked
    override val now: Long get() = SystemClock.elapsedRealtime()
    override val interactive: Boolean get() = runCatching { power.isInteractive }.getOrDefault(false)

    /**
     * The actual default-display power state: the platform must positively
     * report both an interactive power state and STATE_ON panel state. Uncertain
     * reads (missing display, throwing services) answer false, so reveal never
     * dispatches into a dozing/AOD or half-transitioned panel.
     * DisplayManager.getDisplay is API 17; Display.getState/STATE_ON are API 20, all
     * below minSdk 28, so no API guard is needed; the window-side
     * default-display membership keeps its real >= R guard.
     */
    private val displayPowerOn: Boolean
        get() = interactive && runCatching {
            displays.getDisplay(Display.DEFAULT_DISPLAY)?.state == Display.STATE_ON
        }.getOrDefault(false)

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
        val resolved = scanCredentialSurface().surface ?: return false
        @Suppress("DEPRECATION") resolved.root.recycle()
        return true
    }

    /**
     * The ONE pre-reveal readiness observation. Actual default-display power
     * decides first (no scan and no reveal plan while the panel is not
     * genuinely awake); an awake panel then decides on the same trusted
     * window scan that governs credential resolution, mapped through the pure
     * [mapRevealReadiness]. The closed surface-change trace already emitted by
     * the scan records which readiness layer decided, with no values.
     */
    override fun revealReadiness(): PhoneRevealReadiness {
        if (!displayPowerOn) return PhoneRevealReadiness.DISPLAY_IDLE
        val scan = scanCredentialSurface()
        val readiness = mapRevealReadiness(displayPowerOn = true, observation = scan.observation)
        scan.surface?.let { @Suppress("DEPRECATION") it.root.recycle() }
        return readiness
    }

    /** Accepts only the published fixed wake-outcome labels; ignores everything else. */
    override fun traceWakeStage(stage: String) {
        if (stage in WAKE_OUTCOME_STAGES) trace(stage)
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
        val resolved = scanCredentialSurface().surface ?: run {
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
                        // Secure fields may hide their content even after an
                        // accepted write. Never read it back or replay input.
                        if (locked) clickSubmit(root.windowId)
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
            if (locked) clickSubmit(root.windowId)
            return true
        } finally { @Suppress("DEPRECATION") root.recycle() }
    }

    /**
     * The ONE submit attempt on the freshly validated surface. The proven
     * native click channel (the control itself or its bounded clickable
     * SystemUI ancestor) keeps priority and unchanged accept/refuse
     * semantics. Only when it resolves to nothing does the OEM touch
     * fallback decide: a uniquely resolved, currently trusted native submit
     * control that advertises no click channel at all (recorded Samsung
     * key_enter_text on API 33) may act through one real bounded tap
     * gesture. Submission re-resolves the credential surface in the same
     * native window that received this attempt's input; bounds are limited
     * to that window's visible display area. Password contents are not read.
     * Any outcome remains dispatch-only: the caller's observed keyguard
     * read is the sole decider of an unlock.
     */
    private fun clickSubmit(inputWindowId: Int): Boolean {
        val resolved = scanCredentialSurface().surface ?: run {
            trace("SUBMIT_UNAVAILABLE")
            return false
        }
        val root = resolved.root
        try {
            if (!locked || !displayPowerOn || !resolved.ownershipTrusted ||
                root.windowId != inputWindowId) {
                trace("SUBMIT_UNAVAILABLE")
                return false
            }
            if (click(root, submitIds, allowSubmitAncestor = true)) {
                trace("SUBMIT_ACCEPTED")
                return true
            }
            val rect = Rect().also { root.getBoundsInScreen(it) }
            val metrics = service.resources.displayMetrics
            val visibleWindow = intArrayOf(
                rect.left.coerceAtLeast(0), rect.top.coerceAtLeast(0),
                rect.right.coerceAtMost(metrics.widthPixels), rect.bottom.coerceAtMost(metrics.heightPixels),
            )
            val tap = resolveNativeSubmitTap(root, visibleWindow)
            when {
                tap == null -> trace("SUBMIT_UNAVAILABLE")
                dispatchSubmitTap(tap) -> {
                    trace("SUBMIT_TAP_ACCEPTED")
                    return true
                }
                else -> trace("SUBMIT_TAP_REFUSED")
            }
            return false
        } finally { @Suppress("DEPRECATION") root.recycle() }
    }

    /** Closed stage labels only: never ids, text, counts, credentials or exception messages. */
    private fun trace(stage: String) {
        runCatching { android.util.Log.i("FloePhoneUnlock", stage) }
    }

    /**
     * One completed readiness scan: always the closed [SurfaceObservation]
     * (traced on change), plus the resolved trusted credential surface when
     * exactly one resolved. The surface root is owned by the caller and must be
     * recycled exactly once; all other retrieved roots are recycled here.
     */
    private class SurfaceScan(val observation: SurfaceObservation, val surface: ResolvedSurface?)

    /**
     * Freshly resolves the trusted default-display credential surface for the
     * current observation. The active-window root is kept as the fast path; if
     * it is null, foreign, stale or simply not the credential window, the
     * actually reported interactive window set decides via the pure selection,
     * with package/visibility/focus/lifecycle validation on every candidate.
     */
    private fun scanCredentialSurface(): SurfaceScan {
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
            return SurfaceScan(
                observation,
                chosen?.let { surface ->
                    ResolvedSurface(
                        root = surface,
                        trustedWindowIds = defaultDisplayWindowIds
                            ?: if (windows.isEmpty()) null
                               else windows.mapNotNull { w -> runCatching { w.id }.getOrNull() }.toSet(),
                    )
                },
            )
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
                            AccessibilitySubmitWalkNode(node, root.windowId, owned),
                            SUBMIT_ANCESTOR_MAX_HOPS) ?: continue
                        if (target.performClick()) return true
                    } finally { owned.forEach { @Suppress("DEPRECATION") it.recycle() } }
                }
            } finally { nodes.forEach { @Suppress("DEPRECATION") it.recycle() } }
        }
        return false
    }

    /**
     * One fresh bounded query pass over the fixed native submit ids on the
     * very root that was just validated, collecting touch-tap candidates
     * gated on native SystemUI package, enabled state, user visibility and
     * membership in the root's own window. Foreign, disabled, invisible or
     * stale-window nodes never qualify; the selection itself is the pure
     * [selectNativeSubmitTap] (unique winner, no click channel, positive
     * live bounds), so no second authority exists here.
     */
    private fun resolveNativeSubmitTap(
        root: AccessibilityNodeInfo,
        visibleWindow: IntArray,
    ): NativeSubmitTapPoint? {
        val owned = ArrayList<AccessibilityNodeInfo>()
        try {
            val candidates = ArrayList<SubmitWalkNode>()
            for (id in submitIds) {
                val nodes = root.findAccessibilityNodeInfosByViewId("com.android.systemui:id/$id")
                owned.addAll(nodes)
                for (node in nodes) {
                    if (node.packageName?.toString() != SYSTEM_UI_PACKAGE || !node.isEnabled ||
                        !node.isVisibleToUser || node.windowId != root.windowId) continue
                    candidates += AccessibilitySubmitWalkNode(node, root.windowId, owned)
                }
            }
            return selectNativeSubmitTap(candidates, visibleWindow)
        } finally { owned.forEach { @Suppress("DEPRECATION") it.recycle() } }
    }

    /**
     * The single OEM fallback effect: one real tap gesture at the validated
     * control's LIVE bounds centre. The return value is dispatch acceptance
     * only; the actual result arrives exactly once through the callback,
     * which emits closed trace labels and performs no input, state or
     * timing action, so even a callback landing after the attempt ended
     * cannot touch the transaction. A tap — accepted, completed, cancelled
     * or refused — is never an unlock claim; that stays the caller's
     * observed locked=false read, and nothing here retries or re-enters.
     */
    private fun dispatchSubmitTap(point: NativeSubmitTapPoint): Boolean {
        val path = Path().apply { moveTo(point.x.toFloat(), point.y.toFloat()) }
        var reported = false
        return runCatching {
            service.dispatchGesture(GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(path, 0, SUBMIT_TAP_DURATION_MS)).build(),
                object : AccessibilityService.GestureResultCallback() {
                    override fun onCompleted(gestureDescription: GestureDescription) {
                        if (reported) return
                        reported = true
                        trace("SUBMIT_TAP_COMPLETED")
                    }
                    override fun onCancelled(gestureDescription: GestureDescription) {
                        if (reported) return
                        reported = true
                        trace("SUBMIT_TAP_CANCELLED")
                    }
                }, handler)
        }.getOrDefault(false)
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
        // A real short press: long enough for the OEM keyguard view to see a
        // down/up pair, far shorter than any observation window it lands in.
        const val SUBMIT_TAP_DURATION_MS = 50L
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
    /** The node is currently visible to the user on the display. */
    val visibleToUser: Boolean get() = true
    /** The node still lives inside the very window whose root was freshly validated. */
    val sameWindowAsRoot: Boolean get() = true
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

/** A validated live-bounds centre for the ONE OEM touch-tap submit path. */
internal data class NativeSubmitTapPoint(val x: Int, val y: Int)

/**
 * The OEM submit fallback decision, proven against the recorded Samsung
 * structure: [com.android.systemui:id/key_enter_text] is a native TextView
 * with enabled=true, clickable=false and an
 * entirely nonclickable ancestry (keyguard_host_view -> unnamed
 * FrameLayout -> root), for which the existing click route did not submit. The live adapter also
 * checks offered ACTION_CLICK before permitting this fallback.
 * Such a control may act through a real touch tap only when it is native
 * SystemUI, enabled, visible to the user, still inside the very window
 * whose credential surface was freshly validated, positively bounded, and
 * advertises NO click channel at all. A control that does advertise
 * clickability or an ACTION_CLICK keeps its own accept/refuse semantics
 * final — its refusal is never bypassed by a tap, and this uses only the
 * node's live bounds centre, never saved coordinates, never an inferred
 * point and never a general unlock gesture.
 */
internal fun nativeSubmitTapPoint(node: SubmitWalkNode, visibleWindow: IntArray): NativeSubmitTapPoint? {
    if (!node.systemUiPackage || !node.enabled || !node.visibleToUser || !node.sameWindowAsRoot) return null
    if (node.clickable) return null
    val box = node.bounds
    if (!boundsPositivelyContain(visibleWindow, box)) return null
    return NativeSubmitTapPoint(box[0] + (box[2] - box[0]) / 2, box[1] + (box[3] - box[1]) / 2)
}

/**
 * Exactly one eligible OEM control may act. Two eligible labels on the
 * current surface are ambiguous and nothing is tapped, matching the surface
 * resolver's unique-winner refusal discipline; unqualified candidates never
 * create ambiguity because they cannot act at all.
 */
internal fun selectNativeSubmitTap(
    candidates: List<SubmitWalkNode>,
    visibleWindow: IntArray,
): NativeSubmitTapPoint? {
    // A refused click through an ancestor must not be bypassed by tapping
    // its nonclickable child or a different labelled sibling.
    if (candidates.any { node ->
            node.systemUiPackage && node.enabled && node.visibleToUser && node.sameWindowAsRoot &&
                (node.clickable || findBoundedClickableSubmitAncestor(node) != null)
        }) return null
    return candidates.mapNotNull { nativeSubmitTapPoint(it, visibleWindow) }.singleOrNull()
}

/** Adapter for the live tree; parents are tracked for recycling by the driver. */
private class AccessibilitySubmitWalkNode(
    private val node: AccessibilityNodeInfo,
    private val rootWindowId: Int,
    private val owned: MutableList<AccessibilityNodeInfo>,
) : SubmitWalkNode {
    override val systemUiPackage: Boolean
        get() = node.packageName?.toString() == "com.android.systemui"
    override val enabled: Boolean get() = node.isEnabled
    override val clickable: Boolean get() = node.isClickable ||
        node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }
    override val visibleToUser: Boolean get() = node.isVisibleToUser
    override val sameWindowAsRoot: Boolean get() = node.windowId == rootWindowId
    override val bounds: IntArray
        get() {
            val rect = Rect()
            node.getBoundsInScreen(rect)
            return intArrayOf(rect.left, rect.top, rect.right, rect.bottom)
        }
    override val parent: SubmitWalkNode?
        get() = node.parent?.let {
            owned.add(it)
            AccessibilitySubmitWalkNode(it, rootWindowId, owned)
        }
    override fun performClick(): Boolean = node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
}
