package com.floe.android.core.officeengine

import android.app.Service
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.hardware.input.InputManager
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.InputDevice
import android.view.View
import android.webkit.WebView
import com.floe.android.core.officeengine.OfficeRequestPolicy.formatForPath
import java.io.File
import java.util.Collections
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.libreoffice.androidlib.COWebView
import org.libreoffice.androidlib.COWebViewClient
import org.libreoffice.androidlib.EngineBridge
import org.libreoffice.androidlib.LOActivity
import org.libreoffice.androidlib.MobileSocket
import org.libreoffice.androidlib.lok.LokClipboardData

/**
 * Owns the native engine lifetime in the dedicated `:floe_office` process.
 *
 * Authority rules (Main host contract):
 *  - The SERVICE (not any Activity/composition) owns staging checks, the
 *    single active engine session, the blocking native calls
 *    (createCOOLWSD/BYE/saveAs surfaces) and their settle exactly-once.
 *  - One active document per native lifetime: opens are serialized on the
 *    control thread; BYE runs on its own close worker because upstream
 *    closeDocument() may block until COOLWSD's run loop releases the mutex.
 *  - Callbacks are fenced by session generation: a retired session's late
 *    native callbacks are dropped quietly and can never retire or reopen a
 *    replacement (the replacement's createCOOLWSD swaps the native globals
 *    only after the previous BYE settled).
 *  - Readiness requires concrete witnesses (document shape + tile
 *    invalidation). Progress text, page finish and "loaded library" never
 *    imply rendering.
 */
class OfficeEngineService : Service() {

    /** Delivery sink implemented by the viewer Activity (main thread). */
    interface OfficeEngineListener {
        fun onProgress(progress: OfficeViewerProgress)

        /** Honest notices for refused routes; display strings live in the App/UI layer. */
        fun onNotice(sessionToken: String, generation: Long, key: String, detail: String?)

        /** Issued once per mount after native create completed; the view loads then. */
        fun onLoadUrl(sessionToken: String, generation: Long, url: String)

        /**
         * One painted-frame probe attempt requested against the visible
         * engine view. The host performs a PixelCopy and must answer exactly
         * once via [OfficeEngineService.reportPaintProbe]. Refusing or
         * failing honestly keeps the mount at AWAITING_FIRST_RENDER.
         */
        fun onPaintProbeRequested(sessionToken: String, generation: Long)

        /** Terminal for one exact mount, delivered exactly once. */
        fun onTerminal(outcome: OfficeViewerOutcome)

        /**
         * One typed save/export receipt for the exact mount (R2). Delivered
         * on the main thread, once per state transition of an operation:
         * the synchronous SUBMITTED/REJECTED acknowledgement is ALSO
         * returned from [OfficeEngineService.submitSaveOperation]; terminal
         * states (FLUSHED/UNMODIFIED/OUTPUT_READY/FAILED/CANCELLED/UNKNOWN)
         * arrive here exactly once. Default no-op keeps R1 hosts compiling.
         */
        fun onSaveReceipt(receipt: OfficeSaveReceipt) {}

        /**
         * Live edit/dirty/undo projection for the exact mount (R2). Observed
         * facts only — never a readiness claim. Default no-op keeps R1 hosts
         * compiling.
         */
        fun onEditState(state: OfficeEditState) {}

        /**
         * The App settled one Save-Copy handoff after its REAL provider
         * write + readback (R2, Main integration decision 2026-10-26). Only
         * this event may make the viewer display a terminal copy outcome; a
         * picker-result acceptance means "accepted for processing" and the
         * module's own OUTPUT_READY receipt stays a private artifact fact.
         * Default no-op keeps R1 hosts compiling.
         */
        fun onHostSaveSettlement(settlement: OfficeHostSaveSettlement) {}
    }

    inner class LocalBinder : Binder() {
        val service: OfficeEngineService get() = this@OfficeEngineService
    }

    /** Pending page-load listeners owned by one WebView. */
    private class LoadGeometryGuard(
        val view: COWebView,
        val layoutListener: View.OnLayoutChangeListener,
        val attachListener: View.OnAttachStateChangeListener,
    )

    private inner class Session(
        val request: OfficePreviewRequest,
        val generation: Long,
        val closeAck: android.os.IBinder?,
        val viewerIncarnation: Long,
        val hostSaveChannel: android.os.IBinder?,
    ) : EngineBridge, MobileSocket.SocketHost {
        val host = LOActivity(this)
        val cancelled = AtomicBoolean(false)
        @Volatile var state: OfficeViewerState = OfficeViewerState.IDLE
            private set
        @Volatile var webView: COWebView? = null
        @Volatile var retired = false
            private set
        @Volatile var presentationSuperseded = false
        private val permissionPolicyQueued = AtomicBoolean(false)

        /**
         * The ordered native reply to the service-issued permission command
         * arrived (R1: setviewreadonly true; R2 EDIT: setviewreadonly false).
         * The kit processes document messages serially, so this reply proves
         * our permission command was already applied — it is an ordering
         * barrier, not a view-permission getter.
         */
        @Volatile var permissionBarrierObserved = false
            private set
        @Volatile var nativeLoadReadOnly: Boolean? = null
            private set
        private var loadForwarded = false

        // --- R2 editable-session facts (observed native/page truth only) ---

        /** True when this mount was explicitly requested with EDIT permission. */
        val editable: Boolean get() = request.permission == OfficePermission.EDIT

        /** Canonical staged file (working copy in EDIT); set during open. */
        @Volatile var workingCopyFile: File? = null

        /** Server `perm:` frame value ("edit"/"readonly") — unmasked native truth. */
        @Volatile var nativePerm: String? = null
            private set

        /** Server `filemode:` readOnly fact — unmasked native truth. */
        @Volatile var nativeFileModeReadOnly: Boolean? = null
            private set

        /** A modify-password-protected document is not editable in this stage. */
        @Volatile var hasPasswordToModify = false
            private set

        /** Host asked for edit mode (intent); the page witness below is the fact. */
        @Volatile var editRequested = false

        /** Page reported its own EDITMODE on/off (real page-state witness). */
        @Volatile var pageEditMode = false
            private set

        /** Full native edit-permission witness set completed for this mount. */
        @Volatile var editPermissionEstablished = false
            private set

        /**
         * First host-bridge `hideProgressbar` consumption recorded once (the
         * pinned bundle posts it on every document load AND on every
         * MobileWizard window open; unbounded entries would evict real
         * diagnostic facts from the bounded history).
         */
        private val hostUiProgressConsumed = AtomicBoolean(false)

        /**
         * Coalesces the host-driven `window.socket.doSend()` polls: at most
         * one is pending per view, and the pending window ends immediately
         * before the poll is issued so the tail of an engine burst still arms
         * the next one. The pinned mobile socket has no polling interval of
         * its own, and an un-coalesced trigger flood is what walked the page's
         * throttle ladder to its cap and armed its fatal 30 s no-response
         * watchdog (see [OfficeSendTrigger] and MobileSocket's class header).
         */
        private val sendTrigger = OfficeSendTrigger()

        /** Kit `statechanged:` `.uno:ModifiedStatus` fact (null until first frame). */
        @Volatile var documentModified: Boolean? = null
            private set

        /** Bounded raw `statechanged:` states for chrome (.uno:Undo/.uno:Redo). */
        private val commandStates = LinkedHashMap<String, String>()

        /** Bounded per-session RAM-only diagnostic history (explicit local view). */
        val diagnostics = OfficeSessionDiagnostics()

        /** Pure save state machine (one pending flush; exports serialized). */
        val saveCoordinator = OfficeSaveCoordinator()

        /** Receipts issued for this mount, bounded; feeds the close outcome extras. */
        private val issuedReceipts = ArrayList<OfficeSaveReceipt>()

        /** Pending flush timeout tasks, keyed by opId (armed on main handler). */
        private val flushTimeoutTasks = HashMap<String, Runnable>()

        /**
         * Serializes the blocking JNI saveAs against the fatal BYE path: an
         * export either completes before the close posts BYE, or waits for
         * the close to settle and then aborts honestly (never a saveAs on a
         * document the native lifetime already released).
         */
        val nativeCallLock = java.util.concurrent.locks.ReentrantLock()

        fun commandState(name: String): String? = synchronized(commandStates) { commandStates[name] }

        fun recordCommandState(name: String, state: String?) {
            if (state == null) return
            synchronized(commandStates) {
                commandStates.remove(name)
                commandStates[name] = state
                while (commandStates.size > MAX_COMMAND_STATES) {
                    val oldest = commandStates.keys.iterator().next()
                    commandStates.remove(oldest)
                }
            }
        }

        fun recordDiagnostic(kind: String, detail: String?) {
            diagnostics.record(android.os.SystemClock.elapsedRealtime(), kind, detail)
        }

        fun rememberReceipt(receipt: OfficeSaveReceipt) {
            synchronized(issuedReceipts) {
                issuedReceipts.add(receipt)
                while (issuedReceipts.size > OfficeViewerOutcome.MAX_RECEIPT_DESCRIPTORS) {
                    issuedReceipts.removeAt(0)
                }
            }
        }

        fun receiptDescriptors(): List<String> = synchronized(issuedReceipts) {
            issuedReceipts.map { it.descriptorLine() }
        }

        fun armFlushTimeout(opId: String, task: Runnable) {
            synchronized(flushTimeoutTasks) { flushTimeoutTasks[opId] = task }
        }

        fun disarmFlushTimeout(opId: String) {
            val task = synchronized(flushTimeoutTasks) { flushTimeoutTasks.remove(opId) }
            if (task != null) mainHandler.removeCallbacks(task)
        }

        fun disarmAllFlushTimeouts() {
            val tasks = synchronized(flushTimeoutTasks) {
                val copy = flushTimeoutTasks.values.toList()
                flushTimeoutTasks.clear()
                copy
            }
            tasks.forEach { mainHandler.removeCallbacks(it) }
        }
        private val rendererDrawVerified = AtomicBoolean(false)
        private val witnessNonce get() = request.sessionToken + ":" + generation
        private var witnessInjectionAttempts = 0
        var witnessWidthTwip = 0
            private set
        var witnessHeightTwip = 0
            private set
        var tilesInvalidateCount = 0
            private set

        /**
         * Called by the host after its one painted-frame probe attempt for
         * this exact mount. True promotes READY (all three witnesses); false
         * keeps the mount honestly at AWAITING_FIRST_RENDER with bounded
         * retries, never a blank "ready".
         */
        fun onPaintProbe(passed: Boolean) {
            if (retired || state != OfficeViewerState.AWAITING_FIRST_RENDER) return
            if (passed && rendererDrawVerified.get()) {
                paintedFrameVerified = true
                maybePromoteReady()
                return
            }
            if (probeRoundsLeft > 0) {
                probeRoundsLeft--
                mainHandler.postDelayed({ requestPaintProbe() }, PAINT_PROBE_RETRY_MS)
            } else {
                notifyNotice("awaitingRender", null)
            }
        }

        /** Ask the host (Activity window) for one PixelCopy painted-frame probe. */
        fun requestPaintProbe() {
            if (retired) return
            mainHandler.post {
                if (retired || presentationSuperseded || current !== this@Session) return@post
                if (!rendererDrawVerified.get()) {
                    queryRendererWitness()
                    return@post
                }
                listeners.forEach { l -> runCatching { l.onPaintProbeRequested(request.sessionToken, generation) } }
            }
        }
        @Volatile var mobileWizardVisible = false
        @Volatile var lastPhaseText: String? = null
        @Volatile var lastPercent: Int? = null
        var pendingLoadUrl: String? = null

        /**
         * One-shot geometry guard for the initial page load (main-thread
         * only). While a pending load waits, the guard's OWNERS are exactly
         * the armed [COWebView]: its attach-state and layout-change listeners
         * funnel into [maybeStartPendingLoad], and both are removed together.
         * A callback acts only while it still belongs to the currently armed
         * guard on the live view, so a stale view's late event can never
         * tear down a replacement's guard or start another mount's load.
         */
        private var loadGeometryGuard: LoadGeometryGuard? = null

        /** Bounded first-arming diagnostic per mount (not per event). */
        private var loadGeometryGateDiagnosed = false

        /** One accepted numeric geometry fact per mount, even if JS retries. */
        private val viewportGeometryDiagnosed = AtomicBoolean(false)

        /**
         * Single initial-load funnel for BOTH load branches (attachWebView's
         * pending consumption and the already-attached view race in runOpen).
         * The page load never starts until the exact live view is attached
         * to its window with positive real layout size; otherwise a one-shot
         * guard resumes it on this view's actual attach/layout events.
         *
         * Mechanism (G05-R2, actual Alpha13 C03): the frontend measures its
         * initial canvas geometry from the live DOM at doc-layer setup, and
         * only the Calc/zoom paths re-run that measurement — a Writer page
         * that begins loading into a not-yet-laid-out (0x0) view can latch a
         * zero first canvas until a REAL viewport change re-runs the resize
         * chain (the observed C03 steady state; exact internal latching path
         * stays in the private handoff evidence). Waiting for the actual
         * layout is a lifecycle invariant, not a sleep, resize hack, poll,
         * or readiness claim: honest readiness still requires the real
         * witnesses (shape + tile delivery + permission barrier + PixelCopy
         * paint probe + renderer draw).
         */
        fun maybeStartPendingLoad() {
            val url = pendingLoadUrl ?: return
            if (retired || presentationSuperseded || cancelled.get() || current !== this) return
            val view = webView ?: return
            if (!OfficeLoadGeometry.permitsInitialLoad(view.isAttachedToWindow, view.width, view.height)) {
                armLoadGeometryGuard(view)
                return
            }
            pendingLoadUrl = null
            disarmLoadGeometryGuard()
            val loadResult = runCatching { view.loadUrl(url) }
            if (loadResult.isSuccess) {
                // ONE bounded numeric fact, recorded only when the load was
                // actually accepted (coordinator acceptance 2026-10-26): lets
                // the device run distinguish a real positive-size preload
                // from a source-only claim without claiming any outcome.
                recordDiagnostic(
                    OfficeSessionDiagnostics.KIND_LIFECYCLE,
                    "page load started at layout ${view.width}x${view.height} attached=${view.isAttachedToWindow}",
                )
            } else {
                // Honest failure fact, no retry loop, no fabricated state:
                // the existing loadError notice path stays the user-visible
                // truth and readiness witnesses remain unsatisfied.
                recordDiagnostic(
                    OfficeSessionDiagnostics.KIND_LIFECYCLE,
                    "page load rejected: " + (loadResult.exceptionOrNull()?.javaClass?.simpleName ?: "unknown"),
                )
                notifyNotice("loadError", null)
            }
        }

        private fun armLoadGeometryGuard(view: COWebView) {
            val existing = loadGeometryGuard
            if (existing != null && existing.view === view) return // already guarding THIS exact view
            // Re-pointing to a different view: remove the old guard's own
            // listeners from the view they were registered on, never from
            // whatever session.webView happens to be now.
            disarmLoadGeometryGuard()
            if (!loadGeometryGateDiagnosed) {
                loadGeometryGateDiagnosed = true
                recordDiagnostic(
                    OfficeSessionDiagnostics.KIND_LIFECYCLE,
                    "page load geometry-gated (${view.width}x${view.height}, attached=${view.isAttachedToWindow})",
                )
            }
            val layoutListener = View.OnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                guardedViewGeometryChanged(v)
            }
            val attachListener = object : View.OnAttachStateChangeListener {
                override fun onViewAttachedToWindow(v: View) = guardedViewGeometryChanged(v)
                // Detach with the view still guarded: the mount is leaving;
                // detachWebView/disarm owns removal. Nothing loads from here.
                override fun onViewDetachedFromWindow(v: View) = Unit
            }
            loadGeometryGuard = LoadGeometryGuard(view, layoutListener, attachListener)
            view.addOnLayoutChangeListener(layoutListener)
            view.addOnAttachStateChangeListener(attachListener)
        }

        private fun guardedViewGeometryChanged(v: View) {
            val guard = loadGeometryGuard ?: return
            // Own-guard + live-view fences first: a foreign/stale callback
            // returns without disarming anything newer.
            if (guard.view !== v || webView !== v) return
            if (retired || presentationSuperseded || current !== this@Session) {
                if (loadGeometryGuard === guard) disarmLoadGeometryGuard()
                return
            }
            maybeStartPendingLoad()
        }

        /** Main-thread only; removes BOTH listeners from the guard's own view. */
        fun disarmLoadGeometryGuard() {
            val guard = loadGeometryGuard ?: return
            loadGeometryGuard = null
            guard.view.removeOnLayoutChangeListener(guard.layoutListener)
            guard.view.removeOnAttachStateChangeListener(guard.attachListener)
        }

        val terminalDelivered = AtomicBoolean(false)
        val nativeCloseClaimed = AtomicBoolean(false)
        val hulloClaimed = AtomicBoolean(false)
        @Volatile var nativeHandshakeComplete = false
        val nativeCreateStarted = AtomicBoolean(false)
        val nativeCreateSettled = CountDownLatch(1)
        val settleLatches = CopyOnWriteArrayList<CountDownLatch>()
        val socket: MobileSocket?
            get() = webView?.getWebViewClient()?.mobileSocket

        @Volatile
        var tileDeliveryCount = 0
            private set

        @Volatile
        var paintedFrameVerified = false
            private set

        private var probeRoundsLeft = PAINT_PROBE_MAX_ROUNDS
        private val probeScheduled = AtomicBoolean(false)

        fun setState(next: OfficeViewerState) {
            state = next
            recordDiagnostic(OfficeSessionDiagnostics.KIND_STATE, "state=${next.name}")
            publishProgress()
        }

        fun publishProgress() {
            mainHandler.post {
                if (retired || presentationSuperseded || current !== this@Session) return@post
                listeners.forEach { l ->
                    runCatching {
                        l.onProgress(
                            OfficeViewerProgress(
                                state = state,
                                phaseText = lastPhaseText,
                                percent = lastPercent,
                                documentWitness = if (
                                    witnessWidthTwip > 0 && witnessHeightTwip > 0 &&
                                    tileDeliveryCount > 0 && paintedFrameVerified && permissionBarrierObserved && rendererDrawVerified.get()
                                ) {
                                    OfficeDocumentWitness(
                                        widthTwip = witnessWidthTwip,
                                        heightTwip = witnessHeightTwip,
                                        tileDeliveryCount = tileDeliveryCount,
                                        paintedFrameVerified = true,
                                        tilesInvalidateCount = tilesInvalidateCount,
                                        readOnlyBarrierObserved = permissionBarrierObserved && !editable,
                                        rendererDrawVerified = rendererDrawVerified.get(),
                                        editPermissionObserved = editPermissionEstablished,
                                    )
                                } else {
                                    null
                                },
                                sessionToken = request.sessionToken,
                                generation = generation,
                            ),
                        )
                    }
                }
            }
        }

        fun notifyNotice(key: String, detail: String?) {
            // The bounded history survives later notices overwriting the
            // transient row (R1 C8 lesson: startup facts stayed lost).
            recordDiagnostic(
                OfficeSessionDiagnostics.KIND_NOTICE,
                key + (detail?.let { ": " + it.take(120) } ?: ""),
            )
            mainHandler.post {
                if (retired || presentationSuperseded || current !== this@Session) return@post
                listeners.forEach { runCatching { it.onNotice(request.sessionToken, generation, key, detail) } }
            }
        }

        /**
         * Synchronously acknowledges one exact user close-intent to the App
         * process BEFORE the fatal native BYE (see [OfficeCloseAckPolicy]:
         * the pinned engine's last-session BYE ends in std::_exit(0) which
         * bypasses every Java result path). Returns whether the parent
         * accepted this exact mount's close; the teardown proceeds either
         * way and no acknowledgement ever claims closedCleanly.
         */
        fun acknowledgeUserClose(reason: String?): Boolean {
            val accepted = OfficeCloseAck.ackClose(
                closeAck,
                request.sessionToken,
                generation,
                viewerIncarnation,
                reason,
            )
            Log.i(TAG, "close-intent acknowledged=$accepted for generation $generation")
            return accepted
        }

        /** Delivers the terminal result exactly once for this mount. */
        fun deliverTerminal(closedCleanly: Boolean, failure: OfficeFailureCode?, message: String?) {
            if (!terminalDelivered.compareAndSet(false, true)) return
            // A flush still awaiting its native ack can never receive one
            // after this mount ends: settle it UNKNOWN (honest — the App must
            // not read it as committed nor as certainly-not-written) BEFORE
            // the outcome snapshots the receipt list.
            disarmAllFlushTimeouts()
            saveCoordinator.onMountTerminal()?.let { outcome ->
                this@OfficeEngineService.completeFlush(this@Session, outcome)
            }
            val outcome = OfficeViewerOutcome(
                sessionToken = request.sessionToken,
                closedCleanly = closedCleanly,
                failure = failure,
                message = message,
                witnessWidthTwip = witnessWidthTwip,
                witnessHeightTwip = witnessHeightTwip,
                generation = generation,
                dirtyAtClose = documentModified == true,
                editPermissionEstablished = editPermissionEstablished,
                saveReceiptCount = receiptDescriptors().size,
                saveReceiptDescriptors = receiptDescriptors(),
            )
            recordDiagnostic(
                OfficeSessionDiagnostics.KIND_LIFECYCLE,
                "terminal closedCleanly=$closedCleanly failure=${failure?.name} dirty=${documentModified}",
            )
            val recipients = listeners.toList()
            mainHandler.post {
                if (presentationSuperseded) return@post
                recipients.forEach { runCatching { it.onTerminal(outcome) } }
            }
        }

        // --- EngineBridge (may be called on native threads; NEVER throws) ---

        override fun onMessageFromJs(message: String): Boolean {
            if (retired || presentationSuperseded) return false
            if (OfficeReadOnlyProtocol.command(message) == OfficeRenderWitness.COMMAND) {
                observeRendererWitness(message)
                return false
            }
            if (OfficeReadOnlyProtocol.command(message) == OfficeViewportGeometry.COMMAND) {
                if (current !== this@Session) return false
                OfficeViewportGeometry.diagnosticDetail(message)?.let { detail ->
                    if (viewportGeometryDiagnosed.compareAndSet(false, true)) {
                        recordDiagnostic(OfficeSessionDiagnostics.KIND_LIFECYCLE, detail)
                    }
                }
                return false
            }
            if (message == "HULLO" && !hulloClaimed.compareAndSet(false, true)) return false
            if (OfficeReadOnlyProtocol.isReservedQuery(message)) return false
            if (OfficeReadOnlyProtocol.command(message) == "load") {
                synchronized(this) {
                    if (loadForwarded || !OfficeReadOnlyProtocol.matchesSnapshotLoad(message, File(request.stagedFilePath))) {
                        notifyNotice("loadError", null)
                        return false
                    }
                    loadForwarded = true
                }
            }
            // The page's own edit-mode notice (pinned Android behaviour: the
            // bundle posts EDITMODE on/off around _enterEditMode /
            // _enterReadOnlyMode). Real page-state witness; consumed here and
            // never forwarded (it is not a native protocol command).
            if (OfficeReadOnlyProtocol.command(message) == "EDITMODE") {
                val on = message.substringAfter(' ', "").trim() == "on"
                if (editable) {
                    pageEditMode = on
                    recordDiagnostic(OfficeSessionDiagnostics.KIND_STATE, "page EDITMODE=$on")
                    publishEditState()
                }
            }
            // The native save ack (kit postDirectMessage on Android) shares
            // this entry point with page messages, so it is recorded as a
            // diagnostic fact ONLY — completion proof is the unforgeable
            // native→page `unocommandresult:` frame (see OfficeSaveProtocol).
            if (message.startsWith("SAVE ")) {
                recordDiagnostic(
                    OfficeSessionDiagnostics.KIND_SAVE,
                    "native SAVE ack observed: " + message.removePrefix("SAVE ").take(160),
                )
            }
            if (!permissionBarrierObserved && OfficeReadOnlyProtocol.isInteraction(message)) return false
            val outcome = CoolMessageGate.decide(
                message,
                if (editable) CoolMessageGate.Mode.EDITABLE else CoolMessageGate.Mode.READ_ONLY,
            )
            val rest = message.substringAfter(' ', "")
            when (outcome.decision) {
                CoolMessageGate.Decision.BLOCK_WITHOUT_NOTICE -> {
                    when (outcome.noticeKey) {
                        "bye" -> this@OfficeEngineService.requestClose(
                            request.sessionToken,
                            "page-close",
                            userInitiated = true,
                        )
                        null -> when {
                            message.startsWith("MOBILEWIZARD") -> mobileWizardVisible = rest.trim() == "show"
                            // Upstream-parity host-bridge consumption (gate
                            // BLOCK_WITHOUT_NOTICE): kept as ONE inspectable
                            // fact; never a notice, never an error, never
                            // readiness evidence.
                            message.startsWith("hideProgressbar") ->
                                if (hostUiProgressConsumed.compareAndSet(false, true)) {
                                    recordDiagnostic(
                                        OfficeSessionDiagnostics.KIND_STATE,
                                        "host UI hideProgressbar consumed",
                                    )
                                }
                        }
                    }
                    return false
                }
                CoolMessageGate.Decision.BLOCK_ROUTE -> {
                    notifyNotice(outcome.noticeKey ?: "routeUnavailable", rest.take(200))
                    return false
                }
                CoolMessageGate.Decision.BLOCK_MACRO -> {
                    notifyNotice(outcome.noticeKey ?: "macroBlocked", rest.take(200))
                    return false
                }
                CoolMessageGate.Decision.FORWARD -> return true
                CoolMessageGate.Decision.FORWARD_AFTER -> return true
            }
        }

        override fun onMessageForwarded(message: String) {
            if (retired) return
            if (message == "HULLO") nativeHandshakeComplete = true
            when {
                message == "HULLO" && state == OfficeViewerState.OPENING -> {
                    setState(OfficeViewerState.AWAITING_FIRST_RENDER)
                    injectRendererWitness(pull = false)
                    maybePromoteReady()
                }
                CoolMessageGate.isClipboardCopyCommand(message) -> populateClipboard()
            }
        }

        override fun onMessageToJs(message: ByteArray) {
            if (retired) return
            OfficeReadOnlyProtocol.barrierReport(message)?.let { loadReadOnly ->
                if (permissionPolicyQueued.get()) {
                    nativeLoadReadOnly = loadReadOnly
                    permissionBarrierObserved = true
                    recordDiagnostic(
                        OfficeSessionDiagnostics.KIND_PERMISSION,
                        "barrier .uno:ReadOnly=$loadReadOnly editable=$editable",
                    )
                    maybePromoteReady()
                }
            }
            val triage = CoolMessageTriage.classify(message)
            when (triage.kind) {
                CoolMessageTriage.Kind.PROGRESS -> triage.progress?.let { p ->
                    if (p.id == "finish") lastPhaseText = null
                    p.text?.let { lastPhaseText = it }
                    p.value?.let { lastPercent = it }
                    publishProgress()
                }
                CoolMessageTriage.Kind.STATUS -> triage.shape?.let { shape ->
                    witnessWidthTwip = shape.widthTwip
                    witnessHeightTwip = shape.heightTwip
                    establishNativePermission()
                    maybePromoteReady()
                }
                CoolMessageTriage.Kind.TILE_DELIVERY -> {
                    tileDeliveryCount++
                    maybePromoteReady()
                }
                CoolMessageTriage.Kind.TILE_INVALIDATE -> {
                    // Redraw request ONLY (diagnostic; never readiness proof).
                    if (tilesInvalidateCount < Int.MAX_VALUE) tilesInvalidateCount++
                }
                CoolMessageTriage.Kind.STATE_CHANGED -> triage.stateChange?.let { change ->
                    recordCommandState(change.commandName, change.state)
                    if (change.commandName == ".uno:ModifiedStatus") {
                        documentModified = change.state == "true"
                        recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_STATE,
                            "ModifiedStatus=${change.state}",
                        )
                    }
                    publishEditState()
                }
                CoolMessageTriage.Kind.UNO_COMMAND_RESULT -> triage.commandResult?.let { result ->
                    if (result.commandName == OfficeSaveProtocol.SAVE_COMMAND_NAME) {
                        // The unforgeable native→page channel: this frame can
                        // only originate from the pinned kit (send2JS), which
                        // makes it the flush completion evidence.
                        val (flushOutcome, external) = saveCoordinator.onNativeSaveResult(
                            commandName = result.commandName ?: OfficeSaveProtocol.SAVE_COMMAND_NAME,
                            success = result.success,
                            resultValue = result.resultValue,
                            isAutosave = result.isAutosave,
                        )
                        if (flushOutcome != null) {
                            // Never throw across the JNI callback boundary:
                            // a shutdown control lane (teardown) drops the
                            // completion quietly — the mount terminal path
                            // settles the pending op as UNKNOWN anyway.
                            runCatching {
                                controlExecutor.execute { completeFlush(this@Session, flushOutcome) }
                            }
                        } else if (external != null) {
                            recordDiagnostic(
                                OfficeSessionDiagnostics.KIND_SAVE,
                                "external .uno:Save result=${external.verdict} autosave=${external.isAutosave}",
                            )
                        }
                    }
                }
                CoolMessageTriage.Kind.PERM -> {
                    nativePerm = triage.perm
                    recordDiagnostic(OfficeSessionDiagnostics.KIND_PERMISSION, "perm=${triage.perm}")
                    maybePromoteReady()
                }
                CoolMessageTriage.Kind.FILEMODE -> triage.fileMode?.let { mode ->
                    nativeFileModeReadOnly = mode.readOnly
                    recordDiagnostic(
                        OfficeSessionDiagnostics.KIND_PERMISSION,
                        "filemode readOnly=${mode.readOnly} editComment=${mode.editComment}",
                    )
                    maybePromoteReady()
                }
                CoolMessageTriage.Kind.HAS_PASSWORD_TO_MODIFY -> {
                    hasPasswordToModify = true
                    recordDiagnostic(OfficeSessionDiagnostics.KIND_PERMISSION, "haspasswordtomodify")
                    notifyNotice("protectedDocument", null)
                    maybePromoteReady()
                }
                CoolMessageTriage.Kind.ERROR -> {
                    val detail = String(message, Charsets.UTF_8).removePrefix("error:").trim().take(240)
                    val info = triage.error
                    recordDiagnostic(
                        OfficeSessionDiagnostics.KIND_NATIVE_ERROR,
                        "error cmd=${info?.cmd} kind=${info?.kind}",
                    )
                    if (OfficeSaveProtocol.isSaveRelatedError(info?.cmd, info?.kind)) {
                        // A save failure is an operation outcome, NOT a
                        // document failure: the mount stays open and usable.
                        notifyNotice("saveFailed", detail.ifEmpty { null })
                        saveCoordinator.onSaveErrorFrame(info?.cmd, info?.kind)?.let { flushOutcome ->
                            runCatching {
                                controlExecutor.execute { completeFlush(this@Session, flushOutcome) }
                            }
                        }
                    } else {
                        notifyNotice("loadError", detail.ifEmpty { null })
                        // Honest failure representation (Main decision 2026-10-26):
                        // a native error means this document is not viewable, so
                        // leave the opening states (the host must never keep
                        // displaying "Opening" indefinitely) and keep the actual
                        // detail in the notice above. Never implies READY, and
                        // does not fabricate a terminal: the user's own close of
                        // this state is an acknowledged user close whose result
                        // stays unclean.
                        when (state) {
                            OfficeViewerState.OPENING,
                            OfficeViewerState.AWAITING_FIRST_RENDER,
                            OfficeViewerState.READY_READ_ONLY,
                            OfficeViewerState.READY_EDITABLE,
                            -> setState(OfficeViewerState.FAILED)
                            else -> publishProgress()
                        }
                    }
                }
                else -> Unit
            }
            val s = socket
            if (s != null) {
                // R1 preview masks the permission frames so the page can
                // never believe it is writable. An explicit EDIT mount passes
                // the unmasked native truth through: those frames are the
                // page's own permission model AND this session's witnesses.
                val constrained = when {
                    !editable && message.size < 32 && message.toString(Charsets.UTF_8).startsWith("perm:") ->
                        "perm: readonly".toByteArray()
                    !editable && message.size < 4096 && message.toString(Charsets.UTF_8).startsWith("filemode:") ->
                        "filemode:{\"readOnly\":true,\"editComment\":false,\"manageRedlines\":false,\"viewModeExtensions\":\"\"}".toByteArray()
                    else -> message
                }
                if (!s.queueSend(constrained)) {
                    // queueSend already reported once through transportFailed.
                }
            } else {
                // No view/socket attached yet: the document is opening; keep
                // the message queued by re-arming via the pending view path
                // would require unbounded buffering, so this state is a real
                // transport failure for a live session.
                transportFailed("no-socket")
            }
        }

        /**
         * Issues the real pinned permission command for this mount and the
         * ordered `.uno:ReadOnly` barrier (kit/ChildSession.cpp
         * `setviewreadonly` branch). READ_ONLY mounts get the byte-identical
         * R1 sequence; EDIT mounts get `value=false` — the same command the
         * page's own Viewing/Editing toggle uses.
         */
        private fun establishNativePermission() {
            if (!permissionPolicyQueued.compareAndSet(false, true)) return
            try {
                controlExecutor.execute {
                    if (retired || cancelled.get() || current !== this@Session) return@execute
                    try {
                        // Real pinned ChildSession command, not a UI-only permission flag.
                        host.postMobileMessageNative(
                            if (editable) {
                                OfficeReadOnlyProtocol.SET_VIEW_EDITABLE
                            } else {
                                OfficeReadOnlyProtocol.SET_VIEW_READ_ONLY
                            },
                        )
                        host.postMobileMessageNative(OfficeReadOnlyProtocol.QUERY_BARRIER)
                    } catch (_: Throwable) {
                        transportFailed(if (editable) "edit-policy" else "readonly-policy")
                    }
                }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                transportFailed(if (editable) "edit-policy-unavailable" else "readonly-policy-unavailable")
            }
        }

        private fun maybePromoteReady() {
            if (state != OfficeViewerState.AWAITING_FIRST_RENDER) return
            if (witnessWidthTwip <= 0 || witnessHeightTwip <= 0 || tileDeliveryCount <= 0 || !permissionBarrierObserved) return
            if (paintedFrameVerified && rendererDrawVerified.get()) {
                if (editable) {
                    promoteEditableOrDegrade()
                    return
                }
                lastPercent = null
                lastPhaseText = null
                setState(OfficeViewerState.READY_READ_ONLY)
                return
            }
            if (probeRoundsLeft > 0 && probeScheduled.compareAndSet(false, true)) {
                // Give the compositor one frame window after tile delivery
                // before snapshotting; the probe itself is the witness.
                mainHandler.postDelayed({
                    probeScheduled.set(false)
                    requestPaintProbe()
                }, PAINT_PROBE_DELAY_MS)
            }
        }

        /**
         * Honest edited-ready promotion (Main contract 2026-10-26): an EDIT
         * mount claims READY_EDITABLE only with the real native permission
         * witnesses — server-originated `perm: edit` and/or
         * `filemode:{readOnly:false}` (unmasked), the ordered barrier reply
         * after our `setviewreadonly value=false`, and a `.uno:ReadOnly`
         * answer of false (the load itself is not read-only). A protected
         * document, a read-only answer, or missing permission frames degrade
         * the mount to READY_READ_ONLY with an explicit notice: viewable,
         * honestly not editable, working copy untouched.
         */
        private fun promoteEditableOrDegrade() {
            val permGranted = nativePerm == "edit" || nativeFileModeReadOnly == false
            val permDenied = nativePerm == "readonly" || nativeFileModeReadOnly == true
            when {
                hasPasswordToModify -> degradeToReadOnly("protectedDocument")
                permDenied || nativeLoadReadOnly == true -> degradeToReadOnly("editPermissionDenied")
                permGranted && nativeLoadReadOnly == false -> {
                    editPermissionEstablished = true
                    lastPercent = null
                    lastPhaseText = null
                    recordDiagnostic(
                        OfficeSessionDiagnostics.KIND_PERMISSION,
                        "edit permission established (perm=$nativePerm fileModeReadOnly=$nativeFileModeReadOnly barrier=$nativeLoadReadOnly)",
                    )
                    setState(OfficeViewerState.READY_EDITABLE)
                    publishEditState()
                }
                else -> degradeToReadOnly("editPermissionUnconfirmed")
            }
        }

        private fun degradeToReadOnly(noticeKey: String) {
            editPermissionEstablished = false
            recordDiagnostic(OfficeSessionDiagnostics.KIND_PERMISSION, "edit refused: $noticeKey")
            notifyNotice(noticeKey, null)
            lastPercent = null
            lastPhaseText = null
            setState(OfficeViewerState.READY_READ_ONLY)
            publishEditState()
        }

        /** Publishes the observed edit/dirty/undo projection (never a claim). */
        fun publishEditState() {
            val snapshot = editStateSnapshot()
            mainHandler.post {
                if (retired || presentationSuperseded || current !== this@Session) return@post
                listeners.forEach { l -> runCatching { l.onEditState(snapshot) } }
                this@OfficeEngineService.appHostChannel?.let { channel ->
                    OfficeHostSaveChannel.postEditState(channel, snapshot)
                }
            }
        }

        fun editStateSnapshot(): OfficeEditState = OfficeEditState(
            sessionToken = request.sessionToken,
            generation = generation,
            stateName = state.name,
            editRequested = editRequested,
            pageEditMode = pageEditMode,
            editPermissionEstablished = editPermissionEstablished,
            documentModified = documentModified,
            undoState = commandState(".uno:Undo"),
            redoState = commandState(".uno:Redo"),
        )

        private fun observeRendererWitness(message: String): Boolean {
            val report = OfficeRenderWitness.parse(message) ?: return false
            if (retired || presentationSuperseded || current !== this ||
                state != OfficeViewerState.AWAITING_FIRST_RENDER || !report.readyFor(witnessNonce)) return false
            if (rendererDrawVerified.compareAndSet(false, true)) {
                mainHandler.post {
                    if (retired || presentationSuperseded || current !== this@Session) return@post
                    // A genuine later paint gets its own bounded visual check,
                    // even if early pending polls exhausted their allowance.
                    probeRoundsLeft = PAINT_PROBE_MAX_ROUNDS
                    maybePromoteReady()
                }
            }
            return true
        }

        fun injectRendererWitness(pull: Boolean) {
            mainHandler.post {
                if (retired || presentationSuperseded || current !== this@Session) return@post
                val view = webView ?: return@post
                if (witnessInjectionAttempts >= 2) {
                    if (pull) queryRendererWitness()
                    return@post
                }
                witnessInjectionAttempts++
                val script = rendererWitnessScript.replace("__FLOE_NONCE_JSON__", org.json.JSONObject.quote(witnessNonce))
                runCatching { view.evaluateJavascript(script) {
                    if (pull && !retired && !presentationSuperseded && current === this@Session) queryRendererWitness()
                } }.onFailure { onPaintProbe(false) }
            }
        }

        private fun queryRendererWitness() {
            if (retired || presentationSuperseded || current !== this) return
            val view = webView ?: run { onPaintProbe(false); return }
            val query = "window.__floeRenderWitness ? window.__floeRenderWitness.query() : 'absent'"
            runCatching {
                view.evaluateJavascript(query) { raw ->
                    if (retired || presentationSuperseded || current !== this@Session) return@evaluateJavascript
                    val result = runCatching { org.json.JSONTokener(raw).nextValue() as? String }.getOrNull()
                    if (result == "absent" && witnessInjectionAttempts < 2) {
                        injectRendererWitness(pull = true)
                    } else if (!observeRendererWitness(result.orEmpty())) {
                        onPaintProbe(false)
                    }
                }
            }.onFailure { onPaintProbe(false) }
        }

        fun retryVisibleFrame() {
            mainHandler.post {
                if (retired || presentationSuperseded || current !== this@Session || state != OfficeViewerState.AWAITING_FIRST_RENDER) return@post
                probeRoundsLeft = PAINT_PROBE_MAX_ROUNDS
                maybePromoteReady()
            }
        }

        override fun onJsError(message: String) {
            Log.e(TAG, "Office page reported an error (generation $generation)")
            // Bounded history keeps this fact alive even when later generic
            // notices overwrite the transient notice row (R1 C8 lesson).
            recordDiagnostic(OfficeSessionDiagnostics.KIND_JS_ERROR, message)
            notifyNotice("jsError", message.take(3072))
        }

        override fun onJsDebug(message: String) {
            // Browser debug strings can contain document data. Keep them out of logs.
        }

        override fun hasHardwareKeyboard(): Boolean = this@OfficeEngineService.hasHardwareKeyboard()

        override fun isChromeOS(): Boolean = this@OfficeEngineService.isChromeOS()

        // --- MobileSocket.SocketHost ---

        override fun triggerSend() {
            val view = webView ?: return
            if (!sendTrigger.claim()) return
            // mainHandler (not view.post) so the claim is ALWAYS released: a
            // runnable queued on a detached view may never run, which would
            // leak the claim and stop every later poll.
            val posted = runCatching {
                mainHandler.post {
                    // Release BEFORE issuing the poll so a message enqueued
                    // from here on arms the next one (bounded-batch tail).
                    sendTrigger.release()
                    if (retired || presentationSuperseded || current !== this@Session) return@post
                    // Re-read: the poll belongs to the view that was attached
                    // when this runnable was scheduled.
                    if (webView === view) {
                        runCatching { view.loadUrl("javascript:window.socket.doSend();") }
                    }
                }
            }.getOrDefault(false)
            if (!posted) sendTrigger.release()
        }

        override fun transportFailed(reason: String) {
            if (retired) return
            Log.e(TAG, "transport failed ($generation): $reason")
            recordDiagnostic(OfficeSessionDiagnostics.KIND_TRANSPORT, reason)
            notifyNotice("transportFailed", reason)
            // A live-session transport failure can never imply readiness:
            // settle the exact mount once via the normal BYE path, carrying
            // the failure into the terminal outcome.
            this@OfficeEngineService.requestClose(
                request.sessionToken,
                reason,
                userInitiated = false,
                failure = OfficeFailureCode.TRANSPORT_FAILURE,
            )
        }

        fun retire() {
            retired = true
        }
    }

    /** Blocking BYE owner; separate from control so close never wedges opens. */
    private val closeWorker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "floe-office-close").apply { isDaemon = false }
    }
    private val controlExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "floe-office-control").apply { isDaemon = false }
    }
    private val mainHandler = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteList<OfficeEngineListener>()
    private val sessionLock = Any()

    @Volatile
    private var current: Session? = null

    @Volatile
    private var lastGeneration = 0L
    @Volatile private var darkAppearanceOverride: Boolean? = null

    /**
     * App-process event channel registered by a cross-process bind carrying
     * [OfficeEngineCommandsPolicy.EXTRA_HOST_SAVE_CHANNEL] (same UID only;
     * the Service is not exported). Receives typed save receipts, edit-state
     * snapshots and the save-target handoff transactions. Volatile single
     * registration: a rebind replaces it, and every event is fenced by the
     * exact session token + generation anyway.
     */
    @Volatile
    private var appHostChannel: android.os.IBinder? = null

    private val rendererWitnessScript: String by lazy {
        assets.open("floe-office/renderer-witness.js").bufferedReader(Charsets.UTF_8).use { it.readText() }.also {
            require(it.length in 1..32768 && it.split("__FLOE_NONCE_JSON__").size == 2) { "Invalid renderer witness asset" }
        }
    }

    private lateinit var prefs: SharedPreferences
    private var inputManager: InputManager? = null
    private var hardwareKeyboardAttached = false
    private val chromeOSFlag by lazy {
        packageManager.hasSystemFeature(FEATURE_ARC)
    }

    override fun onCreate() {
        super.onCreate()
        prefs = getSharedPreferences(OfficePayloadBootstrap.PREFS_NAME, Context.MODE_PRIVATE)
        instance = this
        registerHardwareKeyboard()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        runCatching {
            (getSystemService(Context.INPUT_SERVICE) as? InputManager)
                ?.unregisterInputDeviceListener(hardwareKeyboardListener)
        }
        // Service destruction alone does not end its process. An unexpected
        // live-owner teardown must not leave the global native server orphaned.
        current?.takeIf { !it.retired }?.let {
            reclaimOfficeProcess(it, OfficeFailureCode.PROCESS_LOST, "Office owner ended")
        }
        controlExecutor.shutdownNow()
        closeWorker.shutdownNow()
        super.onDestroy()
    }

    /**
     * Same-process viewers get the direct [LocalBinder] (R1 contract).
     *
     * The App (default) process binds with the DISTINCT explicit action
     * [OfficeEngineCommandsPolicy.ACTION_ENGINE_COMMANDS] and receives the
     * narrow command binder. Selection is by ACTION, never by extras:
     * Intent.filterEquals ignores extras and Android caches the first
     * onBind binder per bind identity, so an extras-only switch could hand
     * either binder to the wrong client depending on bind order (Main
     * integration review 2026-10-26). Defence in depth: the Service is not
     * exported, and the calling UID is re-checked here AND inside every
     * transaction.
     */
    override fun onBind(intent: Intent?): IBinder {
        if (intent?.action == OfficeEngineCommandsPolicy.ACTION_ENGINE_COMMANDS) {
            if (android.os.Binder.getCallingUid() != android.os.Process.myUid()) {
                Log.e(TAG, "refused cross-process engine bind from a foreign UID")
                return LocalBinder()
            }
            intent.extras?.getBinder(OfficeEngineCommandsPolicy.EXTRA_HOST_SAVE_CHANNEL)?.let {
                appHostChannel = it
            }
            return OfficeEngineCommandBinder(this)
        }
        return LocalBinder()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        // Only the command-action binding owns the App host channel; the
        // viewer's plain LocalBinder bind never touches it.
        if (intent?.action == OfficeEngineCommandsPolicy.ACTION_ENGINE_COMMANDS) {
            appHostChannel = null
        }
        return super.onUnbind(intent)
    }

    /**
     * Explicit (re)registration of the App host save-channel over an
     * already-cached command binding (onBind is not re-invoked for repeat
     * binds of the same identity). Same-UID is enforced by the command
     * binder before this is reached; null clears.
     */
    internal fun registerHostChannelFromBinder(channel: android.os.IBinder?): Boolean {
        appHostChannel = channel
        return true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    // ------------------------------------------------------------------
    // Public surface used by OfficePreviewActivity (same process)
    // ------------------------------------------------------------------

    fun addListener(listener: OfficeEngineListener) = listeners.add(listener)

    fun removeListener(listener: OfficeEngineListener) = listeners.remove(listener)

    /**
     * Creates the engine WebView on the UI thread AFTER
     * [OfficeWebViewDirectory] isolation succeeded. Returns null when the
     * suffix could not be established in this process (the caller surfaces
     * WEBVIEW_ISOLATION_FAILED rather than sharing the browser directory).
     */
    fun newViewerWebView(context: Context): COWebView? {
        if (!OfficeWebViewDirectory.ensureOnce()) return null
        val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        WebView.setWebContentsDebuggingEnabled(debuggable)
        val roots = engineConfinedRoots()
        val host = MutableSocketHost()
        val view = COWebView(context, roots, host).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            // file:///android_asset only; everything else is refused inside
            // COWebViewClient (offline viewer lock).
            isVerticalScrollBarEnabled = true
        }
        synchronized(socketHosts) { socketHosts[view] = host }
        return view
    }

    /** Attaches the freshly composed view to the active session and starts the page load. */
    fun attachWebView(view: COWebView, sessionToken: String, generation: Long) {
        val session = current ?: return
        if (session.request.sessionToken != sessionToken || session.generation != generation) return
        // Drop any previous guard BEFORE re-pointing the session view, so
        // its listeners are removed from the view that actually holds them.
        session.disarmLoadGeometryGuard()
        session.webView = view
        synchronized(socketHosts) { socketHosts[view]?.delegate = session }
        view.addJavascriptInterface(session.host, JAVASCRIPT_INTERFACE)
        // G05-R2 first-paint repair (2026-10-26): this factory callback runs
        // BEFORE Compose attaches/measures the view, so the load must not
        // start here at 0x0; the funnel loads only at this exact view's real
        // attached positive layout, otherwise its guard resumes it on the
        // view's actual attach/layout events. The redundant setState here is
        // dropped: runOpen already set OPENING before native create.
        session.maybeStartPendingLoad()
    }

    fun detachWebView(view: COWebView, sessionToken: String, generation: Long) {
        val session = current ?: return
        if (session.request.sessionToken != sessionToken || session.generation != generation || session.webView !== view) return
        session.webView?.let { view ->
            session.disarmLoadGeometryGuard()
            runCatching { view.evaluateJavascript("window.__floeRenderWitness && window.__floeRenderWitness.cancel()", null) }
            runCatching { view.removeJavascriptInterface(JAVASCRIPT_INTERFACE) }
            runCatching { view.getWebViewClient().mobileSocket.close() }
            synchronized(socketHosts) { socketHosts.remove(view)?.delegate = null }
        }
        session.webView = null
        session.pendingLoadUrl = null
    }

    /**
     * Socket host bound to a live session only while a view is attached.
     * Before/after that window the socket settles quietly (no phantom sends,
     * no crash): the page cannot exist without an attached session view.
     */
    private class MutableSocketHost : MobileSocket.SocketHost {
        @Volatile
        var delegate: MobileSocket.SocketHost? = null

        override fun triggerSend() {
            delegate?.triggerSend()
        }

        override fun transportFailed(reason: String) {
            delegate?.transportFailed(reason)
        }
    }

    /**
     * Queue a preview open for a validated request. Same-token calls after
     * view reconstruction reopen the same snapshot (replacing the dead page's
     * engine document after settling it). A different token while busy is
     * refused with ENGINE_BUSY (one document per native lifetime is real).
     */
    fun beginSession(
        request: OfficePreviewRequest,
        closeAck: android.os.IBinder?,
        viewerIncarnation: Long,
        hostSaveChannel: android.os.IBinder? = null,
    ) {
        if (processRecoveryRequired.get()) {
            failFast(request, OfficeFailureCode.ENGINE_BUSY, "Office process recovery pending")
            return
        }
        val existing = current
        if (existing != null && !existing.retired &&
            existing.request.sessionToken != request.sessionToken
        ) {
            failFast(request, OfficeFailureCode.ENGINE_BUSY, "another Office document holds the engine")
            return
        }
        // Replacing a presentation fences old queued UI/terminal callbacks
        // immediately, before the asynchronous native close starts.
        if (existing?.request?.sessionToken == request.sessionToken) {
            existing.presentationSuperseded = true
            existing.cancelled.set(true)
        }
        controlExecutor.execute {
            if (existing != null && !existing.retired &&
                existing.request.sessionToken == request.sessionToken &&
                existing.state != OfficeViewerState.IDLE
            ) {
                // View reconstruction re-open: settle the previous mount first.
                val settled = settleBlocking(existing, CLOSE_SETTLE_MS)
                if (!settled) {
                    failFast(
                        request,
                        OfficeFailureCode.LOAD_ERROR,
                        "previous engine document did not settle before reopen",
                    )
                    return@execute
                }
            }
            runOpen(request, closeAck, viewerIncarnation, hostSaveChannel)
        }
    }

    /** Cancel/retire for the exact session token; late calls cannot touch a replacement. */
    fun requestClose(
        sessionToken: String,
        reason: String?,
        userInitiated: Boolean,
        failure: OfficeFailureCode? = null,
    ) {
        val session: Session
        val beforeNative: Boolean
        synchronized(sessionLock) {
            session = current ?: return
            if (session.request.sessionToken != sessionToken || session.retired || session.state == OfficeViewerState.CLOSING) return
            session.cancelled.set(true)
            beforeNative = !session.nativeCreateStarted.get()
            session.setState(OfficeViewerState.CLOSING)
        }
        armCloseWatchdog(session)
        val effectiveFailure = failure ?: if (userInitiated) null else OfficeFailureCode.SESSION_CANCELLED
        if (beforeNative) {
            // Cancellation is requested now; release only after the current
            // digest/extraction task really settles on the same control lane.
            controlExecutor.execute {
                if (!session.retired) {
                    retireQuiet(session)
                    session.deliverTerminal(effectiveFailure == null, effectiveFailure, reason)
                }
            }
        } else if (session.nativeCloseClaimed.compareAndSet(false, true)) closeWorker.execute {
            runByeAndRetire(session, effectiveFailure == null, effectiveFailure, reason, userInitiated)
        }
    }

    /** Back-press routing honouring the kit's mobile wizard. */
    fun onBackPressed(sessionToken: String, onWizardLevelUp: () -> Unit, onRequestClose: () -> Unit) {
        val session = current ?: return onRequestClose()
        if (session.request.sessionToken != sessionToken) return onRequestClose()
        if (session.mobileWizardVisible) {
            onWizardLevelUp()
        } else {
            onRequestClose()
        }
    }

    /** Host appearance is supplied before open; AUTO follows device UI mode. */
    fun setAppearance(dark: Boolean?) {
        darkAppearanceOverride = dark
    }

    /** UI-driven night mode re-theming hook (parity with upstream updateDarkMode). */
    fun onNightModeChanged(dark: Boolean) {
        val session = current ?: return
        if (session.state != OfficeViewerState.READY_READ_ONLY &&
            session.state != OfficeViewerState.READY_EDITABLE
        ) return
        runCatching { session.host.sendToJs(if (dark) "mobile: darkthemeactivated" else "mobile: lightthemeactivated") }
    }

    /** Back routing while the kit's mobile wizard owns the top level. */
    fun sendMobileWizardBack(sessionToken: String) {
        val session = current ?: return
        if (session.request.sessionToken != sessionToken) return
        runCatching { session.host.sendToJs("mobile: mobilewizardback") }
    }

    /** True when the exact live session reports the kit wizard visible. */
    fun isMobileWizardVisible(sessionToken: String): Boolean {
        val session = current ?: return false
        return session.request.sessionToken == sessionToken && session.mobileWizardVisible
    }

    /** Answer for one probe against the exact session; late answers are dropped. */
    fun reportPaintProbe(sessionToken: String, generation: Long, passed: Boolean) {
        val session = current ?: return
        if (session.request.sessionToken != sessionToken || session.generation != generation || session.presentationSuperseded) return
        session.onPaintProbe(passed)
    }

    fun refreshVisibleFrame(sessionToken: String, generation: Long) {
        val session = current ?: return
        if (session.request.sessionToken == sessionToken && session.generation == generation) session.retryVisibleFrame()
    }

    /** Engine confinement roots for embedded media (canonical App-owned). */
    private fun engineConfinedRoots(): List<String> {
        val roots = ArrayList<String>(4)
        applicationInfo?.dataDir?.let { roots.add(it) }
        roots.add(cacheDir.absolutePath)
        roots.add(filesDir.absolutePath)
        return roots.map { runCatching { File(it).canonicalPath }.getOrDefault(it) }
    }

    // ------------------------------------------------------------------
    // R2: typed save/export operations, edit toggle, host bindings
    // ------------------------------------------------------------------

    /**
     * Submits one typed save/export operation for the EXACT live mount.
     * Returns the synchronous acknowledgement receipt (SUBMITTED or a
     * REJECTED with the honest reason); the terminal receipt arrives via
     * [OfficeEngineListener.onSaveReceipt] / the App host channel exactly
     * once. Never throws; never fabricates success.
     */
    fun submitSaveOperation(op: OfficeSaveRequest): OfficeSaveReceipt {
        val session = current
        if (session == null || session.retired || session.presentationSuperseded ||
            session.request.sessionToken != op.sessionToken || session.generation != op.generation
        ) {
            return rejectedReceipt(op, OfficeSaveFailureCode.SESSION_MISMATCH, "no live mount for this exact identity")
        }
        if (session.cancelled.get() || session.state == OfficeViewerState.CLOSING ||
            session.state == OfficeViewerState.CLOSED || processRecoveryRequired.get()
        ) {
            return rejectedReceipt(op, OfficeSaveFailureCode.SESSION_ENDING, "mount is closing")
        }
        return when (op.operation) {
            OfficeSaveOperation.WORKING_COPY_FLUSH -> {
                if (session.state != OfficeViewerState.READY_EDITABLE || !session.editPermissionEstablished) {
                    return rejectedReceipt(op, OfficeSaveFailureCode.NOT_EDITABLE, "mount is not editable-ready")
                }
                when (session.saveCoordinator.submitFlush(op.opId, op.saveIfUnmodified)) {
                    OfficeSaveCoordinator.SubmitDecision.ACCEPTED -> {
                        val receipt = receiptFor(
                            session, op, OfficeSaveState.SUBMITTED, null, null,
                            attestation = "accepted",
                        )
                        dispatchReceipt(session, receipt)
                        controlExecutor.execute { runFlush(session, op) }
                        receipt
                    }
                    OfficeSaveCoordinator.SubmitDecision.REJECTED_BUSY ->
                        rejectedReceipt(op, OfficeSaveFailureCode.FLUSH_ALREADY_IN_FLIGHT, "a flush is awaiting its native ack")
                    OfficeSaveCoordinator.SubmitDecision.REJECTED_STALE_ACK_RISK ->
                        rejectedReceipt(op, OfficeSaveFailureCode.STALE_ACK_QUARANTINE, "a previous flush ack went missing; export remains available")
                }
            }
            OfficeSaveOperation.STAGED_EXPORT -> {
                if (session.state != OfficeViewerState.READY_EDITABLE) {
                    return rejectedReceipt(op, OfficeSaveFailureCode.NOT_EDITABLE, "mount is not editable-ready")
                }
                if (!session.saveCoordinator.beginExport(op.opId)) {
                    return rejectedReceipt(op, OfficeSaveFailureCode.EXPORT_ALREADY_IN_FLIGHT, "another export holds the control lane")
                }
                val receipt = receiptFor(
                    session, op, OfficeSaveState.SUBMITTED, null, null,
                    attestation = "accepted",
                )
                dispatchReceipt(session, receipt)
                controlExecutor.execute { runExport(session, op) }
                receipt
            }
        }
    }

    /**
     * Honest cancel: only a not-yet-dispatched operation can be cancelled
     * (the pinned producer has no save-cancel command). After dispatch the
     * operation stays pending until its real ack/error, the bounded timeout
     * (UNKNOWN) or mount end (UNKNOWN); an export in its JNI/IO section runs
     * to quiescence and its receipt carries cancelRequested=true.
     */
    fun cancelSaveOperation(sessionToken: String, generation: Long, opId: String): OfficeSaveCoordinator.CancelDecision {
        val session = current ?: return OfficeSaveCoordinator.CancelDecision.UNKNOWN_OP
        if (session.request.sessionToken != sessionToken || session.generation != generation) {
            return OfficeSaveCoordinator.CancelDecision.UNKNOWN_OP
        }
        val decision = session.saveCoordinator.requestCancel(opId)
        session.recordDiagnostic(OfficeSessionDiagnostics.KIND_SAVE, "cancel op=$opId -> $decision")
        if (decision == OfficeSaveCoordinator.CancelDecision.CANCELLED_BEFORE_DISPATCH) {
            val receipt = OfficeSaveReceipt(
                opId = opId,
                sessionToken = sessionToken,
                generation = generation,
                operation = OfficeSaveOperation.WORKING_COPY_FLUSH,
                state = OfficeSaveState.CANCELLED,
                format = null,
                suggestedName = null,
                expectedBaseSha256 = session.request.sha256,
                workingCopySha256 = null,
                workingCopyBytes = 0L,
                outputDocumentPath = null,
                outputSha256 = null,
                outputBytes = 0L,
                failure = OfficeSaveFailureCode.CANCELLED_BEFORE_DISPATCH,
                message = "cancelled before dispatch; working copy untouched",
                cancelRequested = true,
                attestation = "cancel-before-dispatch",
                submittedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
                completedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
            )
            dispatchReceipt(session, receipt)
        }
        return decision
    }

    /**
     * Host-driven edit-mode toggle for the exact mount. Requires the full
     * native edit-permission witness set (READY_EDITABLE). Issues the real
     * pinned kit command (`setviewreadonly value=false|true`) on the control
     * lane and drives the pinned page entry (`_proceedEditMode` /
     * `_enterReadOnlyMode`) through a guarded injection; a missing page hook
     * is an honest refusal notice, never a fake edit state. The authoritative
     * page fact arrives as the page's own EDITMODE message.
     */
    fun requestEdit(sessionToken: String, generation: Long, enable: Boolean): Boolean {
        val session = current ?: return false
        if (session.retired || session.presentationSuperseded ||
            session.request.sessionToken != sessionToken || session.generation != generation
        ) return false
        if (session.state != OfficeViewerState.READY_EDITABLE || !session.editPermissionEstablished) return false
        session.editRequested = enable
        session.recordDiagnostic(OfficeSessionDiagnostics.KIND_STATE, "host requestEdit enable=$enable")
        controlExecutor.execute {
            if (session.retired || session.cancelled.get() || current !== session) return@execute
            runCatching {
                session.host.postMobileMessageNative(
                    if (enable) OfficeReadOnlyProtocol.SET_VIEW_EDITABLE else OfficeReadOnlyProtocol.SET_VIEW_READ_ONLY,
                )
            }.onFailure { session.transportFailed("edit-toggle") }
        }
        mainHandler.post {
            if (session.retired || session.presentationSuperseded || current !== session) return@post
            val view = session.webView
            if (view == null) {
                session.editRequested = !enable
                session.notifyNotice("editEntryUnavailable", null)
                session.publishEditState()
                return@post
            }
            val script = if (enable) {
                OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT
            } else {
                OfficeReadOnlyProtocol.PAGE_ENTER_VIEW_SCRIPT
            }
            runCatching {
                view.evaluateJavascript(script) { raw ->
                    if (session.retired || session.presentationSuperseded || current !== session) return@evaluateJavascript
                    val ok = raw?.trim('"') == "true"
                    if (!ok) {
                        // The pinned page hook is absent or threw: honest
                        // refusal — the kit view permission alone is NOT an
                        // edit-mode claim while the page stays in viewing.
                        session.editRequested = !enable
                        session.notifyNotice("editEntryUnavailable", null)
                        session.recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_STATE,
                            "page edit entry unavailable (enable=$enable)",
                        )
                    }
                    session.publishEditState()
                }
            }.onFailure {
                session.editRequested = !enable
                session.notifyNotice("editEntryUnavailable", null)
                session.publishEditState()
            }
        }
        return true
    }

    /** Runs one real `.uno:Undo`/`.uno:Redo` through the service (editable mounts only). */
    fun requestEditHistory(sessionToken: String, generation: Long, redo: Boolean): Boolean {
        val session = current ?: return false
        if (session.retired || session.presentationSuperseded ||
            session.request.sessionToken != sessionToken || session.generation != generation
        ) return false
        if (session.state != OfficeViewerState.READY_EDITABLE || !session.editPermissionEstablished) return false
        controlExecutor.execute {
            if (session.retired || session.cancelled.get() || current !== session) return@execute
            runCatching {
                session.host.postMobileMessageNative(
                    if (redo) "uno .uno:Redo" else "uno .uno:Undo",
                )
            }.onFailure { session.transportFailed("edit-history") }
        }
        return true
    }

    /** Observed edit-state snapshot for the exact mount (null when fenced/absent). */
    fun editState(sessionToken: String, generation: Long): OfficeEditState? {
        val session = current ?: return null
        if (session.request.sessionToken != sessionToken || session.generation != generation) return null
        return session.editStateSnapshot()
    }

    /**
     * Native mount generation for an exact live session token (0 when no
     * live mount). Deterministic acquisition path for the App adapter: every
     * fenced command needs the generation, and the token is App-minted.
     */
    fun currentGenerationFor(sessionToken: String): Long {
        val session = current ?: return 0L
        if (session.retired || session.request.sessionToken != sessionToken) return 0L
        return session.generation
    }

    /**
     * App→module Save-Copy settlement (Main integration decision 2026-10-26).
     * Narrow and fenced by the exact op + session token + native mount
     * generation: a stale or foreign settlement is refused, never applied.
     * The module records and forwards the verdict honestly; it never derives
     * COPY_SAVED from its own receipts, a picker acceptance or any native
     * fact — only the App's real provider transaction may settle.
     */
    fun settleHostSaveCopy(settlement: OfficeHostSaveSettlement): Boolean {
        val session = current ?: return false
        if (session.retired || session.presentationSuperseded ||
            session.request.sessionToken != settlement.sessionToken ||
            session.generation != settlement.generation
        ) return false
        if (!OfficeHostSaveHandoffPolicy.validOpId(settlement.opId)) return false
        session.recordDiagnostic(
            OfficeSessionDiagnostics.KIND_SAVE,
            "host settlement op=${settlement.opId} -> ${settlement.verdict.name}",
        )
        val recipients = listeners.toList()
        mainHandler.post {
            if (session.retired || session.presentationSuperseded || current !== session) return@post
            recipients.forEach { l -> runCatching { l.onHostSaveSettlement(settlement) } }
        }
        return true
    }

    internal fun settleHostSaveFromBinder(
        opId: String,
        sessionToken: String,
        generation: Long,
        verdictName: String?,
        message: String?,
    ): Boolean {
        val verdict = runCatching { OfficeHostSaveVerdict.valueOf(verdictName ?: "") }.getOrNull()
            ?: return false
        return settleHostSaveCopy(
            OfficeHostSaveSettlement(
                opId = opId,
                sessionToken = sessionToken,
                generation = generation,
                verdict = verdict,
                message = message?.take(240),
                settledAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
            ),
        )
    }

    /** Bounded RAM-only diagnostic snapshot for the exact mount. */
    fun diagnosticsSnapshot(sessionToken: String, generation: Long): List<OfficeSessionDiagnostics.Event>? {
        val session = current ?: return null
        if (session.request.sessionToken != sessionToken || session.generation != generation) return null
        return session.diagnostics.snapshot()
    }

    // --- narrow command-binder entry points (same-UID cross-process) ---

    internal fun submitSaveFromBinder(
        opId: String,
        sessionToken: String,
        generation: Long,
        operationName: String?,
        format: String?,
        options: String?,
        suggestedName: String?,
        saveIfUnmodified: Boolean,
    ): Int {
        val operation = runCatching { OfficeSaveOperation.valueOf(operationName ?: "") }.getOrNull()
            ?: return OfficeEngineCommandsPolicy.SUBMIT_REJECTED_SHAPE
        val op = OfficeSaveRequest.of(
            opId, sessionToken, generation, operation, format, options, suggestedName, saveIfUnmodified,
        ).getOrNull() ?: return OfficeEngineCommandsPolicy.SUBMIT_REJECTED_SHAPE
        val receipt = submitSaveOperation(op)
        return when (receipt.state) {
            OfficeSaveState.SUBMITTED -> OfficeEngineCommandsPolicy.SUBMIT_ACCEPTED
            OfficeSaveState.REJECTED -> when (receipt.failure) {
                OfficeSaveFailureCode.SESSION_MISMATCH -> OfficeEngineCommandsPolicy.SUBMIT_REJECTED_SESSION
                OfficeSaveFailureCode.FLUSH_ALREADY_IN_FLIGHT,
                OfficeSaveFailureCode.EXPORT_ALREADY_IN_FLIGHT,
                -> OfficeEngineCommandsPolicy.SUBMIT_REJECTED_BUSY
                OfficeSaveFailureCode.SESSION_ENDING -> OfficeEngineCommandsPolicy.SUBMIT_REJECTED_SESSION
                else -> OfficeEngineCommandsPolicy.SUBMIT_REJECTED_STATE
            }
            else -> OfficeEngineCommandsPolicy.SUBMIT_ACCEPTED
        }
    }

    internal fun cancelSaveFromBinder(opId: String, sessionToken: String, generation: Long): Int =
        when (cancelSaveOperation(sessionToken, generation, opId)) {
            OfficeSaveCoordinator.CancelDecision.UNKNOWN_OP -> OfficeEngineCommandsPolicy.CANCEL_UNKNOWN_OP
            OfficeSaveCoordinator.CancelDecision.CANCELLED_BEFORE_DISPATCH ->
                OfficeEngineCommandsPolicy.CANCEL_CANCELLED_BEFORE_DISPATCH
            OfficeSaveCoordinator.CancelDecision.STILL_IN_FLIGHT -> OfficeEngineCommandsPolicy.CANCEL_STILL_IN_FLIGHT
        }

    internal fun requestEditFromBinder(sessionToken: String, generation: Long, enable: Boolean): Boolean =
        requestEdit(sessionToken, generation, enable)

    internal fun requestEditHistoryFromBinder(sessionToken: String, generation: Long, redo: Boolean): Boolean =
        requestEditHistory(sessionToken, generation, redo)

    internal fun editStateFromBinder(sessionToken: String, generation: Long): OfficeEditState? =
        editState(sessionToken, generation)

    internal fun diagnosticsFromBinder(
        sessionToken: String,
        generation: Long,
    ): List<OfficeSessionDiagnostics.Event>? = diagnosticsSnapshot(sessionToken, generation)

    // --- save execution (control lane) ---

    /**
     * Dispatches one working-copy flush through the REAL protocol message
     * (upstream parity: the official app posts the same "save ..." string via
     * postMobileMessageNative). Completion is the kit's `.uno:Save`
     * unocommandresult observed on the native→page channel; this method only
     * dispatches and arms the bounded watchdog.
     */
    private fun runFlush(session: Session, op: OfficeSaveRequest) {
        if (session.retired || session.cancelled.get() || current !== session) {
            // The mount vanished between submit and lane execution: nothing
            // was dispatched, so this is an honest pre-dispatch cancel.
            if (session.saveCoordinator.requestCancel(op.opId) ==
                OfficeSaveCoordinator.CancelDecision.CANCELLED_BEFORE_DISPATCH
            ) {
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.CANCELLED,
                        OfficeSaveFailureCode.CANCELLED_BEFORE_DISPATCH, "mount ended before dispatch",
                        attestation = "cancel-before-dispatch", cancelRequested = true,
                    ),
                )
            }
            return
        }
        try {
            session.host.postMobileMessageNative(OfficeSaveProtocol.flushMessage(op.saveIfUnmodified))
            session.saveCoordinator.markFlushDispatched(op.opId)
            session.recordDiagnostic(OfficeSessionDiagnostics.KIND_SAVE, "flush dispatched op=${op.opId}")
            armFlushTimeout(session, op)
        } catch (t: Throwable) {
            session.saveCoordinator.abortDispatch(op.opId, t.javaClass.simpleName)?.let { outcome ->
                completeFlush(session, outcome)
            }
        }
    }

    private fun armFlushTimeout(session: Session, op: OfficeSaveRequest) {
        val task = Runnable {
            session.saveCoordinator.onTimeout(op.opId)?.let { outcome ->
                controlExecutor.execute { completeFlush(session, outcome) }
            }
        }
        session.armFlushTimeout(op.opId, task)
        mainHandler.postDelayed(task, SAVE_ACK_TIMEOUT_MS)
    }

    /**
     * Settles one flush verdict into its typed receipt. WRITTEN_ACK is only
     * a FLUSHED receipt after the working copy was actually re-read and
     * digested (real bytes, not the ack alone); an unreadable working copy
     * after a "success" ack is the honest ACK_WITHOUT_VERIFIABLE_BYTES
     * failure.
     */
    private fun completeFlush(session: Session, outcome: OfficeSaveCoordinator.FlushOutcome) {
        session.disarmFlushTimeout(outcome.opId)
        val op = OfficeSaveRequest(
            opId = outcome.opId,
            sessionToken = session.request.sessionToken,
            generation = session.generation,
            operation = OfficeSaveOperation.WORKING_COPY_FLUSH,
            format = null,
            options = null,
            suggestedName = null,
            saveIfUnmodified = false,
        )
        val file = session.workingCopyFile
        when (outcome.verdict) {
            OfficeSaveCoordinator.FlushVerdict.WRITTEN_ACK -> {
                val digest = file?.let { OfficeRequestPolicy.digestWorkingCopy(it) }
                if (digest == null) {
                    dispatchReceipt(
                        session,
                        receiptFor(
                            session, op, OfficeSaveState.FAILED,
                            OfficeSaveFailureCode.ACK_WITHOUT_VERIFIABLE_BYTES,
                            "native acked success but the working copy is not a readable regular file",
                            attestation = "uno-ack-unverified", cancelRequested = outcome.cancelRequested,
                        ),
                    )
                } else {
                    dispatchReceipt(
                        session,
                        receiptFor(
                            session, op, OfficeSaveState.FLUSHED, null, null,
                            attestation = "uno-ack+working-copy-digest",
                            workingCopySha256 = digest.first,
                            workingCopyBytes = digest.second,
                            cancelRequested = outcome.cancelRequested,
                        ),
                    )
                }
            }
            OfficeSaveCoordinator.FlushVerdict.UNMODIFIED -> {
                // Honest no-op: core wrote nothing. The current digest is
                // re-read so the App can compare against its base cheaply.
                val digest = file?.let { OfficeRequestPolicy.digestWorkingCopy(it) }
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.UNMODIFIED, null, outcome.detail,
                        attestation = "uno-ack-unmodified",
                        workingCopySha256 = digest?.first,
                        workingCopyBytes = digest?.second ?: 0L,
                        cancelRequested = outcome.cancelRequested,
                    ),
                )
            }
            OfficeSaveCoordinator.FlushVerdict.NATIVE_FAILED -> dispatchReceipt(
                session,
                receiptFor(
                    session, op, OfficeSaveState.FAILED,
                    if (outcome.detail?.startsWith("error:") == true) {
                        OfficeSaveFailureCode.NATIVE_ERROR
                    } else {
                        OfficeSaveFailureCode.NATIVE_REJECTED
                    },
                    outcome.detail,
                    attestation = "native-failure",
                    cancelRequested = outcome.cancelRequested,
                ),
            )
            OfficeSaveCoordinator.FlushVerdict.DISPATCH_FAILED -> dispatchReceipt(
                session,
                receiptFor(
                    session, op, OfficeSaveState.FAILED,
                    OfficeSaveFailureCode.INTERNAL, outcome.detail,
                    attestation = "dispatch-failed",
                    cancelRequested = outcome.cancelRequested,
                ),
            )
            OfficeSaveCoordinator.FlushVerdict.NO_PROOF -> dispatchReceipt(
                session,
                receiptFor(
                    session, op, OfficeSaveState.UNKNOWN,
                    when (outcome.detail) {
                        "timeout-without-ack" -> OfficeSaveFailureCode.TIMEOUT_WITHOUT_ACK
                        "mount-ended-without-ack" -> OfficeSaveFailureCode.MOUNT_ENDED_WITHOUT_ACK
                        else -> OfficeSaveFailureCode.AUTOSAVE_ACK_COLLISION
                    },
                    outcome.detail,
                    attestation = "no-proof",
                    cancelRequested = outcome.cancelRequested,
                ),
            )
        }
        session.publishEditState()
    }

    /**
     * Runs one staged export on the serialized control lane: synchronous JNI
     * saveAs into a FRESH op-owned file under the module-private outputs
     * root, then bounded real verification (regular file, 1..256 MiB, whole
     * read, format magic, digest). Void return alone is never success. The
     * working copy and every previously verified output are retained on all
     * paths; only THIS attempt's own unverified partial file is removed.
     */
    private fun runExport(session: Session, op: OfficeSaveRequest) {
        try {
            if (session.retired || session.cancelled.get() || current !== session ||
                session.state == OfficeViewerState.CLOSING || session.state == OfficeViewerState.CLOSED
            ) {
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.CANCELLED,
                        OfficeSaveFailureCode.CANCELLED_BEFORE_DISPATCH, "mount ended before export",
                        attestation = "cancel-before-dispatch", cancelRequested = true,
                    ),
                )
                return
            }
            val format = op.format ?: run {
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.REJECTED,
                        OfficeSaveFailureCode.INVALID_REQUEST, "export without format",
                        attestation = "rejected",
                    ),
                )
                return
            }
            val baseDir = File(noBackupFilesDir, "$OUTPUTS_DIR/${session.generation}")
            val canonicalBase = runCatching {
                if (!baseDir.isDirectory && !baseDir.mkdirs()) return@runCatching null
                baseDir.canonicalFile
            }.getOrNull()
            val noBackupCanonical = runCatching { noBackupFilesDir.canonicalPath }.getOrNull()
            if (canonicalBase == null || noBackupCanonical == null ||
                !canonicalBase.path.startsWith(noBackupCanonical.removeSuffix("/") + "/")
            ) {
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.FAILED,
                        OfficeSaveFailureCode.INTERNAL, "staged output root unavailable",
                        attestation = "output-root-failed",
                    ),
                )
                return
            }
            val outFile = File(canonicalBase, op.opId + "-" + android.os.SystemClock.elapsedRealtime() + "." + format)
            if (outFile.exists()) {
                // Unique names make this practically impossible; never
                // overwrite an existing artifact — refuse honestly instead.
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.FAILED,
                        OfficeSaveFailureCode.INTERNAL, "staged output name collision",
                        attestation = "output-collision",
                    ),
                )
                return
            }
            session.recordDiagnostic(OfficeSessionDiagnostics.KIND_SAVE, "export start op=${op.opId} format=$format")
            var threw: Throwable? = null
            // Serialize the blocking JNI saveAs against the fatal BYE path.
            session.nativeCallLock.lock()
            try {
                if (session.retired || session.cancelled.get() || current !== session) {
                    dispatchReceipt(
                        session,
                        receiptFor(
                            session, op, OfficeSaveState.CANCELLED,
                            OfficeSaveFailureCode.CANCELLED_BEFORE_DISPATCH, "mount ended before JNI saveAs",
                            attestation = "cancel-before-dispatch", cancelRequested = true,
                        ),
                    )
                    return
                }
                try {
                    // Upstream parity: File.toURI() form, format token as the
                    // filter argument, NO TakeOwnership (the loaded document
                    // identity never moves).
                    session.host.saveAs(outFile.toURI().toString(), format, op.options)
                } catch (t: Throwable) {
                    threw = t
                }
            } finally {
                session.nativeCallLock.unlock()
            }
            val cancelRequested = session.saveCoordinator.isExportCancelRequested(op.opId)
            if (threw != null) {
                runCatching { if (outFile.exists()) outFile.delete() }
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.FAILED,
                        OfficeSaveFailureCode.INTERNAL, threw.javaClass.simpleName,
                        attestation = "jni-saveas-threw", cancelRequested = cancelRequested,
                    ),
                )
                return
            }
            val verification = OfficeRequestPolicy.verifyStagedOutput(outFile, format)
            if (!verification.verified) {
                // Only THIS attempt's own unverified partial file is removed;
                // the working copy and prior verified outputs are retained.
                runCatching { if (outFile.exists()) outFile.delete() }
                dispatchReceipt(
                    session,
                    receiptFor(
                        session, op, OfficeSaveState.FAILED,
                        verification.failure ?: OfficeSaveFailureCode.INTERNAL,
                        "output verification failed (${verification.failure?.name})",
                        attestation = "output-verification-failed", cancelRequested = cancelRequested,
                    ),
                )
                return
            }
            dispatchReceipt(
                session,
                receiptFor(
                    session, op, OfficeSaveState.OUTPUT_READY, null, null,
                    attestation = "jni-saveas-sync+output-verified",
                    outputDocumentPath = outFile.canonicalPath,
                    outputSha256 = verification.sha256,
                    outputBytes = verification.bytes,
                    cancelRequested = cancelRequested,
                ),
            )
        } finally {
            session.saveCoordinator.endExport(op.opId)
        }
    }

    private fun receiptFor(
        session: Session,
        op: OfficeSaveRequest,
        state: OfficeSaveState,
        failure: OfficeSaveFailureCode?,
        message: String?,
        attestation: String,
        workingCopySha256: String? = null,
        workingCopyBytes: Long = 0L,
        outputDocumentPath: String? = null,
        outputSha256: String? = null,
        outputBytes: Long = 0L,
        cancelRequested: Boolean = false,
    ): OfficeSaveReceipt = OfficeSaveReceipt(
        opId = op.opId,
        sessionToken = session.request.sessionToken,
        generation = session.generation,
        operation = op.operation,
        state = state,
        format = op.format,
        suggestedName = op.suggestedName,
        expectedBaseSha256 = session.request.sha256,
        workingCopySha256 = workingCopySha256,
        workingCopyBytes = workingCopyBytes,
        outputDocumentPath = outputDocumentPath,
        outputSha256 = outputSha256,
        outputBytes = outputBytes,
        failure = failure,
        message = message?.take(240),
        cancelRequested = cancelRequested,
        attestation = attestation,
        submittedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
        completedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
    )

    private fun rejectedReceipt(
        op: OfficeSaveRequest,
        failure: OfficeSaveFailureCode,
        message: String,
    ): OfficeSaveReceipt = OfficeSaveReceipt(
        opId = op.opId,
        sessionToken = op.sessionToken,
        generation = op.generation,
        operation = op.operation,
        state = OfficeSaveState.REJECTED,
        format = op.format,
        suggestedName = op.suggestedName,
        expectedBaseSha256 = null,
        workingCopySha256 = null,
        workingCopyBytes = 0L,
        outputDocumentPath = null,
        outputSha256 = null,
        outputBytes = 0L,
        failure = failure,
        message = message,
        cancelRequested = false,
        attestation = "rejected",
        submittedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
        completedAtElapsedMs = android.os.SystemClock.elapsedRealtime(),
    )

    /** Delivers one receipt to the App host channel FIRST, then in-process. */
    private fun dispatchReceipt(session: Session, receipt: OfficeSaveReceipt) {
        session.rememberReceipt(receipt)
        session.recordDiagnostic(
            OfficeSessionDiagnostics.KIND_SAVE,
            "receipt op=${receipt.opId} ${receipt.operation.name} -> ${receipt.state.name}" +
                (receipt.failure?.let { " ($it)" } ?: ""),
        )
        val recipients = listeners.toList()
        mainHandler.post {
            // REAL happens-before (Main ordering constraint 2026-10-26):
            // postReceipt is a synchronous binder transaction, so the App has
            // stored the verified OUTPUT_READY facts BEFORE the in-process
            // listener runs and the viewer may call the host prepare seam.
            (session.hostSaveChannel ?: appHostChannel)?.let { channel ->
                OfficeHostSaveChannel.postReceipt(channel, receipt)
            }
            if (!session.presentationSuperseded) {
                recipients.forEach { l -> runCatching { l.onSaveReceipt(receipt) } }
            }
        }
    }

    // ------------------------------------------------------------------
    // Open pipeline (control thread)
    // ------------------------------------------------------------------

    private fun runOpen(
        request: OfficePreviewRequest,
        closeAck: android.os.IBinder?,
        viewerIncarnation: Long,
        hostSaveChannel: android.os.IBinder?,
    ) {
        // Re-check ownership under the lock: two begins queued back-to-back
        // must not both mount (the native lifetime carries exactly one
        // document at a time).
        val conflicting = synchronized(sessionLock) { current?.takeIf { !it.retired } }
        if (conflicting != null) {
            if (conflicting.request.sessionToken == request.sessionToken &&
                conflicting.state == OfficeViewerState.IDLE
            ) {
                // A queued duplicate of the same still-IDLE mount: ignore.
                return
            }
            failFast(request, OfficeFailureCode.ENGINE_BUSY, "another Office document holds the engine")
            return
        }
        val session = Session(request, ++lastGeneration, closeAck, viewerIncarnation, hostSaveChannel)
        synchronized(sessionLock) { current = session; session.setState(OfficeViewerState.STAGING) }
        // Publish the initial snapshot so an App-side host channel learns the
        // exact (token, generation) identity as soon as the mount exists.
        session.publishEditState()
        try {
            // A valid service owner outlives a view reconstruction. This is
            // not sticky, not a foreground keepalive, and stops on settlement.
            startService(Intent(this, OfficeEngineService::class.java))
        } catch (_: IllegalStateException) {
            failFast(request, OfficeFailureCode.INTERNAL, "preview owner unavailable")
            return
        }

        // 1. Trusted staged snapshot: canonical containment + size + digest.
        val (file, pathFailure) = OfficeRequestPolicy.resolveStagedFile(
            appRootPaths = rootsForPolicy(),
            stagedFilePath = request.stagedFilePath,
        )
        if (file == null) {
            failFast(request, pathFailure?.code ?: OfficeFailureCode.STAGED_FILE_MISSING, pathFailure?.message)
            return
        }
        if (formatForPath(file.canonicalPath) != request.format) {
            failFast(request, OfficeFailureCode.UNSUPPORTED_FORMAT, "staged file format mismatch")
            return
        }
        if (!OfficeRequestPolicy.verifyStagedDigest(file, request.lengthBytes, request.sha256)) {
            failFast(request, OfficeFailureCode.STAGED_FILE_MISMATCH, "staged snapshot digest does not match")
            return
        }
        // EDIT admission (R2, fail-closed): the staged file must be a
        // separately owned MUTABLE working copy. A read-only staged snapshot
        // (R1 stagers setReadOnly) or any non-writable file is refused —
        // an immutable input or provider original can never be mounted
        // editable or saved over.
        if (request.permission == OfficePermission.EDIT && !file.canWrite()) {
            failFast(
                request,
                OfficeFailureCode.STAGED_FILE_MISMATCH,
                "editable session requires a writable working copy",
            )
            return
        }
        session.workingCopyFile = runCatching { file.canonicalFile }.getOrNull()
        session.recordDiagnostic(
            OfficeSessionDiagnostics.KIND_LIFECYCLE,
            "open permission=${request.permission} format=${request.format} bytes=${request.lengthBytes}",
        )
        if (session.cancelled.get()) return

        // 2. Engine profile extraction (idempotent, cancellable, service-owned).
        val unpack = OfficeUnpackPreparation(this, prefs)
        val prepared = unpack.prepare(
            cancelled = { session.cancelled.get() },
            onProgress = { done, total ->
                if (total > 0) {
                    session.lastPhaseText = null
                    session.lastPercent = (done * 100L / total).toInt().coerceIn(0, 99)
                    session.publishProgress()
                }
            },
        )
        if (!prepared) {
            if (session.cancelled.get()) return
            failFast(
                request,
                OfficeFailureCode.PAYLOAD_PREPARE_FAILED,
                unpack.lastError ?: "engine profile preparation failed",
            )
            return
        }

        // Preparation can outlive a Back/cancel or replacement. Never create
        // an orphan native mount after that exact request has retired.
        if (session.retired || session.cancelled.get() || current !== session) return

        // Load the small owned observer on the control thread, before the
        // renderer can request it. Missing assets are an actionable failure.
        if (runCatching { rendererWitnessScript }.isFailure) {
            failFast(request, OfficeFailureCode.INTERNAL, "renderer witness asset unavailable")
            return
        }

        // 3. Native library gate (honest, never fatal).
        if (!LOActivity.ensureNativeLoaded()) {
            failFast(
                request,
                OfficeFailureCode.NATIVE_LOAD_FAILED,
                LOActivity.nativeLoadError(),
            )
            return
        }

        // 4. Create the engine mount for this exact snapshot.
        val dataDir = applicationInfo?.dataDir ?: run {
            failFast(request, OfficeFailureCode.INTERNAL, "dataDir unavailable")
            return
        }
        val urlToLoad = OfficeRequestPolicy.engineLoadUrl(file.canonicalPath)
        val uiMode = if (isLargeScreen()) UI_MODE_NOTEBOOKBAR else UI_MODE_CLASSIC
        val languageTag = request.languageTag ?: Locale.getDefault().toLanguageTag()
        // Admission and a STAGING close use the same lock. A slow dlopen
        // cannot revive a request that was cancelled while loading libraries.
        synchronized(sessionLock) {
            if (session.retired || session.cancelled.get() || current !== session) return
            session.nativeCreateStarted.set(true)
            session.setState(OfficeViewerState.OPENING)
        }
        try {
            session.host.createCOOLWSD(
                dataDir = dataDir,
                cacheDir = cacheDir.absolutePath,
                apkFile = packageResourcePath ?: "",
                assetManager = assets,
                loadFileURL = urlToLoad,
                uiMode = uiMode,
                userName = USER_NAME,
            )
        } catch (t: Throwable) {
            Log.e(TAG, "createCOOLWSD threw", t)
            reclaimOfficeProcess(session, OfficeFailureCode.NATIVE_LOAD_FAILED, t.javaClass.simpleName)
            return
        } finally {
            session.nativeCreateSettled.countDown()
        }
        if (session.retired || session.cancelled.get() || current !== session) return

        val viewerUrl = buildViewerUrl(urlToLoad, languageTag, uiMode, session)
        session.pendingLoadUrl = viewerUrl
        // BOTH load paths now converge on Session.maybeStartPendingLoad():
        // a live view loads only at real attached positive layout size, and
        // a not-yet-composed view receives the URL through onLoadUrl and is
        // gated by attachWebView through the identical funnel.
        mainHandler.post {
            if (session.retired || session.presentationSuperseded || current !== session) return@post
            if (session.webView == null) {
                // No view yet: onLoadUrl makes the Activity compose the
                // AndroidView; attachWebView then consumes pendingLoadUrl
                // through the SAME real-layout funnel (never at 0x0).
                runCatching { listeners.toList().forEach { it.onLoadUrl(request.sessionToken, session.generation, viewerUrl) } }
            } else {
                // G05-R2 first-paint repair (2026-10-26): the previous
                // branch loaded directly here with no attach/size check.
                // An already-attached view (rare reconstruction race) now
                // goes through the identical geometry gate: load when this
                // exact view is attached with positive real layout size,
                // otherwise its next layout pass resumes the same funnel.
                session.maybeStartPendingLoad()
            }
        }
    }

    private fun buildViewerUrl(
        documentUrl: String,
        languageTag: String,
        uiMode: String,
        session: Session,
    ): String {
        val builder = StringBuilder("file:///android_asset/dist/cool.html?file_path=")
            .append(documentUrl)
            .append("&closebutton=1")
            .append("&lang=").append(android.net.Uri.encode(languageTag))
            // Upstream parity (LOActivity.java:1283-1285): the page URL
            // permission parameter is the pinned mobile frontend's initial
            // permission ("edit" for an editable document, "readonly" for a
            // protected one). READ_ONLY mounts keep the exact R1 value.
            .append(if (session.editable) "&permission=edit" else "&permission=readonly")
        if (uiMode == UI_MODE_NOTEBOOKBAR) {
            builder.append("&userinterfacemode=notebookbar")
        }
        if (isDarkMode()) {
            builder.append("&darkTheme=true")
        }
        return builder.toString()
    }

    private fun rootsForPolicy(): List<String> {
        val roots = ArrayList<String>(5)
        applicationInfo?.dataDir?.let { roots.add(it) }
        roots.add(cacheDir.absolutePath)
        roots.add(filesDir.absolutePath)
        roots.add(noBackupFilesDir.absolutePath)
        return roots
    }

    private fun failFast(request: OfficePreviewRequest, code: OfficeFailureCode, message: String?) {
        val session = current
        if (session != null && session.request.sessionToken == request.sessionToken && !session.retired) {
            // The mount being failed is this exact request's own session:
            // retire it (retireQuiet clears only when it is still current).
            retireQuiet(session)
            session.deliverTerminal(false, code, message)
        } else {
            // A different live session holds the engine: report the refusal
            // for this request only; the holder stays intact.
            val outcome = OfficeViewerOutcome(
                request.sessionToken, false, code, message, 0, 0,
            )
            mainHandler.post { listeners.toList().forEach { runCatching { it.onTerminal(outcome) } } }
        }
    }

    /**
     * BYE on the close worker, then retire; terminal delivered after settle.
     *
     * Pinned-engine truth (OfficeCloseAckPolicy): the last-session BYE can
     * end in std::_exit(0) on the native thread, so the JNI call never
     * returns and the post-BYE settle/deliverTerminal below may never run.
     * A user close is therefore acknowledged to the App process SYNCHRONOUSLY
     * BEFORE the BYE is posted; the acknowledgement records close ownership
     * only — it never claims closedCleanly and never replaces the Activity
     * result contract.
     */
    private fun runByeAndRetire(
        session: Session,
        closedCleanly: Boolean,
        failure: OfficeFailureCode?,
        message: String?,
        userInitiated: Boolean,
    ) {
        if (userInitiated) session.acknowledgeUserClose(message)
        // The native close pipe exists only after HULLO. Closing an empty
        // server before that handshake can block forever in the fixed SDK.
        // Reclaim only our dedicated process, with an unclean result and the
        // private input preserved, instead of inventing a clean close.
        val initialized = runCatching { session.nativeCreateSettled.await(CLOSE_SETTLE_MS, TimeUnit.MILLISECONDS) }.getOrDefault(false)
        if (!initialized || !session.nativeHandshakeComplete) {
            reclaimOfficeProcess(session, failure ?: OfficeFailureCode.SESSION_CANCELLED, "closed before native handshake")
            return
        }
        // BYE may still block in native code; the independently armed main
        // watchdog bounds that lifetime without blocking either UI or opens.
        // The native-call lock serializes BYE against an in-flight blocking
        // JNI saveAs on the control lane (cancel/close quiescence: the export
        // either finished before BYE, or it waits and then aborts honestly).
        val thrown = session.nativeCallLock.run {
            lock()
            try {
                runCatching { session.host.postMobileMessageNative("BYE") }.exceptionOrNull()
            } finally {
                unlock()
            }
        }
        if (thrown != null) {
            Log.e(TAG, "BYE failed for generation ${session.generation}", thrown)
        }
        settle(session)
        session.deliverTerminal(closedCleanly && thrown == null,
            failure ?: if (thrown != null) OfficeFailureCode.TRANSPORT_FAILURE else null, message)
    }

    /** Bounded wait used by the reopen path; honest refusal on non-settle. */
    private fun settleBlocking(session: Session, timeoutMs: Long): Boolean {
        if (session.retired) return true
        if (!session.nativeCreateStarted.get()) {
            // This method runs on the control lane after the old preparation
            // returned, so no extraction worker is still writing its profile.
            retireQuiet(session)
            return true
        }
        val latch = CountDownLatch(1)
        session.settleLatches.add(latch)
        // A user close may already own BYE. A reconstruction must join it,
        // never enqueue a second global-native close that can hit a new mount.
        if (session.retired) latch.countDown()
        armCloseWatchdog(session)
        if (session.nativeCloseClaimed.compareAndSet(false, true)) closeWorker.execute {
            runByeAndRetire(
                session,
                false,
                OfficeFailureCode.SESSION_CANCELLED,
                "presentation replaced",
                userInitiated = false,
            )
        }
        val settled = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        if (!settled) reclaimOfficeProcess(session, OfficeFailureCode.PROCESS_LOST, "native close did not settle")
        return settled
    }

    private fun armCloseWatchdog(session: Session) {
        mainHandler.postDelayed({
            if (!session.retired) reclaimOfficeProcess(session, OfficeFailureCode.PROCESS_LOST, "native close timeout")
        }, CLOSE_SETTLE_MS)
    }

    private fun reclaimOfficeProcess(session: Session, failure: OfficeFailureCode, reason: String) {
        if (!processRecoveryRequired.compareAndSet(false, true)) return
        session.cancelled.set(true)
        session.deliverTerminal(false, failure, reason)
        Log.w(TAG, "Office process recovery scheduled ($reason)")
        mainHandler.postDelayed({
            // Never force-stop the package or touch the Main process, other
            // apps, credentials or user files. R1 previews own only copies.
            if (android.app.Application.getProcessName() == packageName + ":floe_office") {
                android.os.Process.killProcess(android.os.Process.myPid())
            } else {
                Log.e(TAG, "Refused Office recovery outside dedicated process")
            }
        }, 600L)
    }

    private fun settle(session: Session) {
        session.retire()
        synchronized(sessionLock) {
            if (current === session) current = null
        }
        stopSelf()
        mainHandler.post {
            val view = session.webView
            session.webView = null
            if (view != null) {
                runCatching { view.getWebViewClient().mobileSocket.close() }
                runCatching { view.destroy() }
            }
            session.settleLatches.forEach { it.countDown() }
            session.settleLatches.clear()
        }
    }

    private fun retireQuiet(session: Session) {
        session.retire()
        synchronized(sessionLock) { if (current === session) current = null }
        stopSelf()
    }

    // ------------------------------------------------------------------
    // Clipboard (copy-out only in R1; paste routing is kernel-gated)
    // ------------------------------------------------------------------

    private fun populateClipboard() {
        val session = current ?: return
        try {
            val data = LokClipboardData()
            if (!session.host.getClipboardContent(data)) {
                Log.w(TAG, "no clipboard content for copy")
                return
            }
            val clipboardFile = File(cacheDir, CLIPBOARD_FILE_NAME)
            runCatching { data.writeToFile(clipboardFile) }
            val text = data.getText()
            var html = data.getHtml() ?: return
            val idx = html.indexOf("<meta name=\"generator\" content=\"")
                .let { if (it < 0) html.indexOf("<meta http-equiv=\"content-type\" content=\"text/html;") else it }
            if (idx >= 0) {
                html = StringBuilder(html)
                    .insert(idx, "<meta name=\"origin\" content=\"${clipboardMagic()}\"/>\n")
                    .toString()
            }
            val clip = ClipData.newHtmlText(ClipDescription.MIMETYPE_TEXT_HTML, text, html)
            (getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager)
                ?.setPrimaryClip(clip)
        } catch (t: Throwable) {
            // Never propagate across the JS bridge thread into the engine.
            Log.e(TAG, "populateClipboard failed", t)
        }
    }

    private fun clipboardMagic(): String = CLIPBOARD_COOL_SIGNATURE + loadSignatureMillis

    // ------------------------------------------------------------------
    // Hardware keyboard parity + ChromeOS
    // ------------------------------------------------------------------

    private val hardwareKeyboardListener = object : InputManager.InputDeviceListener {
        override fun onInputDeviceAdded(deviceId: Int) = updateHardwareKeyboard()
        override fun onInputDeviceRemoved(deviceId: Int) = updateHardwareKeyboard()
        @Deprecated("deprecated in API level 29 but still invoked by the platform")
        override fun onInputDeviceChanged(deviceId: Int) = updateHardwareKeyboard()
    }

    private fun registerHardwareKeyboard() {
        val im = getSystemService(Context.INPUT_SERVICE) as? InputManager ?: return
        inputManager = im
        hardwareKeyboardAttached = queryKeyboardAttached(im)
        runCatching { im.registerInputDeviceListener(hardwareKeyboardListener, mainHandler) }
    }

    private fun updateHardwareKeyboard() {
        val im = inputManager ?: return
        val attached = queryKeyboardAttached(im)
        if (attached == hardwareKeyboardAttached) return
        hardwareKeyboardAttached = attached
        val session = current ?: return
        runCatching {
            session.host.sendToJs(
                if (attached) "mobile: hardwarekeyboardattached" else "mobile: hardwarekeyboarddetached",
            )
        }
    }

    private fun queryKeyboardAttached(im: InputManager): Boolean {
        return im.inputDeviceIds.any { id ->
            val device = im.getInputDevice(id) ?: return@any false
            // getSupportedSources() is not part of the SDK37 public API
            // surface (only getSources()); use the public `sources` value.
            // Parentheses required: named infix (`and`) binds looser than
            // comparison in Kotlin, so `a and b != 0` would parse wrong.
            (device.sources and InputDevice.SOURCE_KEYBOARD) != 0 && !device.isVirtual
        }
    }

    private fun hasHardwareKeyboard(): Boolean = hardwareKeyboardAttached

    private fun isChromeOS(): Boolean = chromeOSFlag

    private fun isLargeScreen(): Boolean =
        resources.configuration.smallestScreenWidthDp >= 600

    private fun isDarkMode(): Boolean = darkAppearanceOverride ?: (
        resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES)

    companion object {
        private const val TAG = "OfficeEngineService"
        private const val JAVASCRIPT_INTERFACE = "COOLMessageHandler"
        private const val FEATURE_ARC = "org.chromium.arc.device_management"
        private const val UI_MODE_NOTEBOOKBAR = "notebookbar"
        private const val UI_MODE_CLASSIC = "classic"
        private const val USER_NAME = "Guest User"
        private const val CLIPBOARD_FILE_NAME = "LibreofficeClipboardFile.data"
        private const val CLIPBOARD_COOL_SIGNATURE = "cool-clip-magic-4a22437e49a8-"
        private const val CLOSE_SETTLE_MS = 20_000L

        /**
         * Bounded window for the working-copy flush ack. This is a FAILURE
         * watchdog (honest UNKNOWN on expiry), never a success timer: no
         * sleep or elapsed time is ever treated as proof of a save.
         */
        private const val SAVE_ACK_TIMEOUT_MS = 30_000L

        /** Cap for the raw `statechanged:` command-state map (chrome info). */
        private const val MAX_COMMAND_STATES = 64

        /** Module-private staged-output root under noBackupFilesDir. */
        private const val OUTPUTS_DIR = "floe-office-outputs"

        // Painted-frame probe schedule (witnesses, not fabricated timeouts:
        // failing probes keep the state honestly at AWAITING_FIRST_RENDER).
        private const val PAINT_PROBE_DELAY_MS = 120L
        private const val PAINT_PROBE_RETRY_MS = 600L
        private const val PAINT_PROBE_MAX_ROUNDS = 6

        @Volatile
        private var instance: OfficeEngineService? = null
        private val processRecoveryRequired = AtomicBoolean(false)

        /** Diagnostics only: never a readiness claim. */
        internal fun activeSessionTokenForDiagnostics(): String? =
            instance?.current?.takeIf { !it.retired }?.request?.sessionToken
    }

    private val loadSignatureMillis = android.os.SystemClock.uptimeMillis()

    /** Socket hosts for views created but not yet bound to a live session. */
    private val socketHosts =
        Collections.synchronizedMap(java.util.IdentityHashMap<COWebView, MutableSocketHost>())
}

/** Minimal lock-free listener list (main-thread reads; any-thread adds). */
internal class CopyOnWriteList<T> {
    @Volatile
    private var items: List<T> = emptyList()

    fun add(item: T) = synchronized(this) { items = items + item }

    fun remove(item: T) = synchronized(this) {
        items = items.filterNot { it === item }
    }

    fun forEach(action: (T) -> Unit) = items.toList().forEach(action)

    fun toList(): List<T> = items.toList()
}
