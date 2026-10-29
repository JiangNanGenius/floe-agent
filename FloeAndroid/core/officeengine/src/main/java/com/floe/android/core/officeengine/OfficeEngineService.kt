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
import com.floe.android.core.officeengine.precision.OfficePrecisionAttestation
import com.floe.android.core.officeengine.precision.OfficePrecisionEngine
import com.floe.android.core.officeengine.precision.OfficePrecisionFailure
import com.floe.android.core.officeengine.precision.OfficePrecisionRequest
import com.floe.android.core.officeengine.precision.OfficePrecisionResult
import com.floe.android.core.officeengine.precision.OfficePrecisionState
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

        /**
         * Freshness/epoch fact for the cached [pageEditMode] observation
         * (page-mode79): the raw boolean stays the ordering fact for the
         * dispatch re-checks, while admission fast paths additionally
         * require this witness to be fresh and un-invalidated. A cached
         * EDITMODE-on that outlived the pinned page proxy's 30 s
         * no-response watchdog window can silently straddle the transport
         * death that forced the C15 first-failure after-effect UNKNOWN.
         * page-transport85: freshness additionally requires a recent REAL
         * activation witness stamp (fed from the FORWARD branch below) AND a
         * recent PAGE-REPORTED fresh-downlink health answer (fed only from
         * current-generation page-counter reads) — a fresh RAW bridge ack,
         * fresh uplinks, or host-served bytes alone are not admission facts.
         */
        private val pageEditModeFact = OfficePageEditModeWitness()

        /**
         * Real page-originated `useractive` uplink frames accepted for
         * forwarding — the edit-handshake transport witness. Only the page
         * emits this frame (the pinned kit never sends it downstream and the
         * host's own native wire never uses it), and the page can only
         * forward it while its socket transport is open.
         */
        private val pageActivationWitnessCount = java.util.concurrent.atomic.AtomicLong(0)

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
         *
         * page-transport85: host-side coalescing alone does not bound the
         * PAGE-side pending polls — a hidden/frozen renderer queues every
         * injection without executing it, and the wake replays the whole
         * flood before any queued XHR can complete. The page-side gate
         * ([transportPump]'s single-pending-poll bookkeeping, released only
         * by a served poll, a settled probe, a view change or the terminal)
         * is therefore checked in [triggerSend] before every injection.
         */
        private val sendTrigger = OfficeSendTrigger()

        /**
         * Service-owned bounded background transport pump (page-transport85):
         * ONE `ping` uplink + ONE poll probe per round, at most one round
         * open, so an ordinary model/approval wait with a hidden WebView
         * keeps a REAL `pong` waiting in the bounded MobileSocket queue (the
         * only kind of poll response that resets the page's
         * `lastDataTimestamp`, global.js:1731-1742) and at most ONE injection
         * queued toward the frozen renderer. Runs only while this mount is
         * live and READY — no PIP, no permanent keepalive, no new
         * permission; dies with the session. Pure decisions in
         * [OfficeTransportPump]; this field is its session wiring.
         */
        private val transportPump = OfficeTransportPump()
        private val transportPumpStarted = AtomicBoolean(false)

        /**
         * Host-observed wsd `pong rendercount=` frames (docx-socket-repair122).
         *
         * The pinned wsd answers a client `ping` itself, and the answer reaches
         * the HOST on `rawCallFakeWebsocketOnMessage` before it is queued for
         * the page — so one new sequence value is a real NATIVE-side liveness
         * witness that needs no page polling (a hidden page consumes no
         * downlink at all). It is the only proof that the in-process wsd /
         * FakeSocket / native session is still processing host uplinks during a
         * hidden approval wait; the ungated EDITMODE bridge post alone works on
         * a proxy whose transport is already gone and therefore proves nothing
         * about the native side.
         */
        private val pongSeq = java.util.concurrent.atomic.AtomicLong(0)
        @Volatile private var lastPongAtMs = 0L

        /** One bounded hidden-gate diagnostic per hidden window (never spam). */
        @Volatile private var hiddenProbeSuppressedLogged = false

        /**
         * Never-reused identities for `doSend()` injections (main-thread
         * mint). Every execution/settle callback carries its injection's
         * seq and is dropped unless it still matches the pump's single
         * outstanding injection, so a stale callback from a previous
         * view/socket generation or a superseded injection can never mark
         * a newer round executed or clear the newer gate (Main late
         * critical review 2026-10-28). View identity is re-checked on top.
         */
        private var nextInjectionSeq = 0L

        /**
         * Exact page/socket incarnation, independent of the mount generation.
         * Attach/detach, a repeated HULLO and a refused reload all advance it.
         * Preparation tokens and every probe/health continuation capture this
         * value, so an answer from the old page can never affect the new one.
         */
        private val transportGeneration = java.util.concurrent.atomic.AtomicLong(0)
        /** Lock order: ingress → preparation → generation; never reversed. */
        private val transportGenerationLock = Any()

        /** Read-only page/socket generation snapshot so an outer fence can observe the
         *  exact incarnation without exposing the AtomicLong for external mutation. */
        fun transportGenerationSnapshot(): Long = transportGeneration.get()

        /** Main-thread scheduling handles for the pump (never null after run). */
        @Volatile private var pumpTickTask: Runnable? = null
        @Volatile private var pumpSettleTask: Runnable? = null

        /** Kit `statechanged:` `.uno:ModifiedStatus` fact (null until first frame). */
        @Volatile var documentModified: Boolean? = null
            private set

        /** Bounded raw `statechanged:` states for chrome (.uno:Undo/.uno:Redo). */
        private val commandStates = LinkedHashMap<String, String>()

        /** Bounded per-session RAM-only diagnostic history (explicit local view). */
        val diagnostics = OfficeSessionDiagnostics()

        /** Pure save state machine (one pending flush; exports serialized). */
        val saveCoordinator = OfficeSaveCoordinator()

        /**
         * Fenced typed precision surface (G05-R2 P-A): structured target
         * capture/readback and native mutation dispatch over the PROVEN
         * postMobileMessageNative wire, with the mount-scoped correlation
         * ledger, native-operation lease and single-use target handles.
         * Dies with this Session — a new native incarnation starts with a
         * clean correlation/quarantine/handle state (the ONLY reconciliation
         * for a poisoned barrier or quarantined callback-answer kind).
         */
        val precision = OfficePrecisionEngine(PrecisionHostBridge())

        /**
         * Mount-side capabilities for [precision]. Identity facts come from
         * THIS session's own engine-owned record (never from callers or
         * document content); diagnostics record identity-safe summaries
         * only — never selected text, formulas, tokens or paths.
         */
        private inner class PrecisionHostBridge : OfficePrecisionEngine.OfficePrecisionHost {
            override fun sessionToken(): String = request.sessionToken
            override fun generation(): Long = this@Session.generation
            override fun documentFormat(): OfficeDocumentFormat = request.format
            override fun isReadyState(): Boolean =
                state == OfficeViewerState.READY_READ_ONLY || state == OfficeViewerState.READY_EDITABLE
            override fun isEditableReady(): Boolean =
                state == OfficeViewerState.READY_EDITABLE && editPermissionEstablished
            override fun isMountLive(): Boolean =
                !retired && !presentationSuperseded && !cancelled.get() &&
                    current === this@Session &&
                    state != OfficeViewerState.CLOSING && state != OfficeViewerState.CLOSED &&
                    !processRecoveryRequired.get()
            override fun saveBusy(): Boolean =
                saveCoordinator.pendingFlushOpId() != null || saveCoordinator.runningExportOpId() != null
            override fun workingCopyDigest(): Pair<String, Long>? =
                workingCopyFile?.let { OfficeRequestPolicy.digestWorkingCopy(it) }
            override fun ownerTaskId(): String? = request.ownerTaskId
            override fun workspaceId(): String? = request.workspaceId
            override fun sourceId(): String? = request.sourceId
            override fun sourceRevision(): String? = request.sourceRevision
            override fun sourceLogicalPath(): String? = request.sourceLogicalPath
            override fun documentModified(): Boolean? = this@Session.documentModified
            override fun isPageEditMode(): Boolean = this@Session.pageEditMode
            override fun prepareEditableView(
                opId: String,
                callback: (OfficePrecisionFailure?, String) -> Unit,
            ) = this@Session.prepareEditableView(opId) { result ->
                val failure = when (result.failure) {
                    null -> null
                    OfficeEditModePreparationFailure.TIMEOUT ->
                        OfficePrecisionFailure.TIMEOUT
                    OfficeEditModePreparationFailure.SESSION_ENDING ->
                        OfficePrecisionFailure.SESSION_ENDING
                    OfficeEditModePreparationFailure.TRANSPORT ->
                        OfficePrecisionFailure.TRANSPORT
                    else -> OfficePrecisionFailure.NOT_EDITABLE
                }
                // Null failure is the ONLY ready callback; detail never
                // promotes a command send or the global load barrier.
                callback(failure, "edit-preparation:" + result.detail)
            }
            override fun cancelEditableViewPreparation(opId: String) =
                this@Session.cancelEditableViewPreparation(opId)
            override fun sendOwnedNativeEditable() =
                host.postMobileMessageNative(OfficeReadOnlyProtocol.SET_VIEW_EDITABLE)
            override fun sendWire(message: String) = host.postMobileMessageNative(message)
            override fun runOnControlLane(task: Runnable): Boolean = try {
                controlExecutor.execute(task)
                true
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                false
            }
            override fun scheduleTimeout(delayMs: Long, task: Runnable): Any =
                task.also { mainHandler.postDelayed(it, delayMs) }
            override fun cancelTimeout(handle: Any) {
                if (handle is Runnable) mainHandler.removeCallbacks(handle)
            }
            override fun nativeIngressLock(): Any = host.nativeIngressLock
            override fun recordDiagnostic(detail: String) =
                this@Session.recordDiagnostic("precision", detail)
            override fun elapsedMs(): Long = android.os.SystemClock.elapsedRealtime()
        }

        private val editModePreparationHost = EditModePreparationHost()
        private val editModePreparation = OfficeEditModePreparation(editModePreparationHost)

        /** Android/WebView joins for the bounded real page EDITMODE handshake. */
        private inner class EditModePreparationHost : OfficeEditModePreparation.Host {
            override fun isMountLive(): Boolean =
                !retired && !presentationSuperseded && !cancelled.get() &&
                    current === this@Session &&
                    state != OfficeViewerState.CLOSING && state != OfficeViewerState.CLOSED &&
                    !processRecoveryRequired.get()

            override fun isEditableReady(): Boolean =
                state == OfficeViewerState.READY_EDITABLE && editPermissionEstablished

            override fun isPageEditMode(): Boolean = this@Session.pageEditMode

            override fun isPageEditModeFresh(): Boolean =
                pageEditModeFact.isFresh(android.os.SystemClock.elapsedRealtime())

            override fun activationWitnessCount(): Long = pageActivationWitnessCount.get()

            override fun pageTransportGeneration(): Long = transportGeneration.get()

            /**
             * ONE current page-truth transport-health read for the cached
             * fast path (Main late critical review 2026-10-28): admission
             * must never rest on host-side delivery bookkeeping alone, so
             * even the triple-fresh cached route ends in a real read of the
             * page's OWN counters on the CURRENT view, fenced by this exact
             * token at issuance and re-fenced at the continuation. False on
             * every stale/unreadable/fenced/replaced-view outcome — the
             * caller then takes the full ordered handshake route, whose
             * drain+probe+witness chain is the honest decider. A fresh
             * answer also re-stamps the witness's page-observed downlink
             * corroboration (the only feeder it has).
             */
            override fun verifyPageTransportHealth(
                token: OfficeEditModePreparationToken,
                onResult: (Boolean) -> Unit,
            ) = issuePageHealthVerification(token, attempt = 0, bounded = false, onResult = onResult)

            /**
             * The cold route's bounded FINAL verification
             * (office-background-repair118): the same read and the same
             * [OfficeTransportDrain.isFresh] criterion, retried within the
             * preparation's existing window while the page's socket stays
             * OPEN and merely stale, each retry arming ONE on-demand
             * heartbeat round exactly like the pre-handshake drain. A
             * closed/closing socket and an exhausted budget both refuse
             * immediately/ultimately with the unchanged typed detail; no
             * native or hook effect is ever repeated and no timeout is
             * added or extended.
             */
            override fun verifyPageTransportHealthUntilFresh(
                token: OfficeEditModePreparationToken,
                onResult: (Boolean) -> Unit,
            ) = issuePageHealthVerification(token, attempt = 0, bounded = true, onResult = onResult)

            /**
             * Issues ONE page-truth health read. [bounded] selects the cold
             * route's retry-on-stale-open continuation; the read itself, its
             * token/generation/view fencing and its witness stamp are
             * identical for both routes.
             */
            private fun issuePageHealthVerification(
                token: OfficeEditModePreparationToken,
                attempt: Int,
                bounded: Boolean,
                onResult: (Boolean) -> Unit,
            ) {
                mainHandler.post {
                    val view = webView
                    if (view == null) {
                        onResult(false)
                        return@post
                    }
                    val readGeneration = transportGeneration.get()
                    var issueFailed = false
                    val started = synchronized(host.nativeIngressLock) {
                        editModePreparation.runIfActive(token) {
                            if (isMountLive() && webView === view) {
                                val ok = runCatching {
                                    view.evaluateJavascript(
                                        OfficeReadOnlyProtocol.PAGE_TRANSPORT_HEALTH_SCRIPT,
                                    ) { raw ->
                                        mainHandler.post {
                                            onPageHealthVerificationRead(
                                                token, attempt, bounded,
                                                view, readGeneration, raw, onResult,
                                            )
                                        }
                                    }
                                }.isSuccess
                                if (!ok) issueFailed = true
                            } else {
                                issueFailed = true
                            }
                        }
                    }
                    // Fenced (cancelled/closed) preparations drop silently:
                    // the cancel/close owner already settled the operation.
                    if (started && issueFailed) onResult(false)
                }
            }

            /**
             * Main thread: one health-read continuation. The generation check
             * and its witness stamp stay atomic against HULLO/view changes;
             * the retry's heartbeat arming and the operation callback both
             * run OUTSIDE every monitor.
             */
            private fun onPageHealthVerificationRead(
                token: OfficeEditModePreparationToken,
                attempt: Int,
                bounded: Boolean,
                readView: COWebView,
                readGeneration: Long,
                raw: String?,
                onResult: (Boolean) -> Unit,
            ) {
                var health: OfficeReadOnlyProtocol.OfficeTransportHealth? = null
                var fenced = false
                val fresh = synchronized(transportGenerationLock) {
                    if (
                        transportPumpTerminal() || webView !== readView ||
                        transportGeneration.get() != readGeneration
                    ) {
                        fenced = true
                        false
                    } else {
                        fenced = false
                        val parsed = OfficeReadOnlyProtocol.parseTransportHealth(raw)
                        health = parsed
                        val current = OfficeTransportDrain.isFresh(parsed)
                        if (current) {
                            pageEditModeFact.onPageReportedFreshDownlink(
                                android.os.SystemClock.elapsedRealtime(),
                            )
                        }
                        current
                    }
                }
                if (fenced) {
                    onResult(false)
                    return
                }
                // docx-socket-repair122 — hidden-window final verification.
                // While the page window is hidden no poll response can be
                // consumed, so page-consumed freshness is unattainable BY
                // CONSTRUCTION; retrying/injecting would only walk the pinned
                // ladder and could close the socket. The hidden route therefore
                // verifies the ONE criterion that is both real and sufficient
                // for what it admitted on: the page's OWN socket object is
                // still open (`readyState === 1`; a 1006 close sets it to 3),
                // read live with NO injection. The native-side liveness the
                // admission also required (a fresh host-observed `pong`) has
                // already been proven by the gate, and the effect/verification
                // wire never traverses the page.
                if (bounded && !isPageVisibleNow(readView)) {
                    val verdict = OfficeHiddenTransportAdmission.decide(health)
                    if (verdict != OfficeHiddenTransportAdmission.Verdict.ADMIT) {
                        recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_TRANSPORT,
                            "hidden final page-health verify refused " + verdict.name +
                                " readyState=" + (health?.readyState?.toString() ?: "unreadable") +
                                " msgInflight=" + (health?.msgInflight?.toString() ?: "-1") +
                                " stalenessMs=" + (health?.stalenessMs?.toString() ?: "-1"),
                        )
                    }
                    onResult(verdict == OfficeHiddenTransportAdmission.Verdict.ADMIT)
                    return
                }
                if (fresh || !bounded) {
                    onResult(fresh)
                    return
                }
                when (OfficeTransportDrain.decide(health, attempt)) {
                    OfficeTransportDrain.Decision.RETRY_WITH_PROBE -> {
                        // Open but stale, in-flight BELOW the pinned cap: an
                        // injection is provably safe (the pinned doSend()
                        // creates its XHR). Arm ONE on-demand heartbeat round —
                        // the same real recovery opportunity the pre-handshake
                        // drain already uses — then re-read. The next issuance
                        // re-fences the token, the mount and the captured view
                        // identity from scratch.
                        armDrainHeartbeat()
                        mainHandler.postDelayed(
                            {
                                issuePageHealthVerification(
                                    token, attempt + 1, bounded = true, onResult = onResult,
                                )
                            },
                            OfficeTransportDrain.RETRY_DELAY_MS,
                        )
                    }
                    OfficeTransportDrain.Decision.RETRY_READ_ONLY -> {
                        // In-flight cap pinned (or unreadable): an injection
                        // could only walk the ladder / never deliver data, and
                        // at >30 s staleness it would close the socket. Inject
                        // nothing; re-read while the page's own deferred polls
                        // drain (the window is visible on this route).
                        mainHandler.postDelayed(
                            {
                                issuePageHealthVerification(
                                    token, attempt + 1, bounded = true, onResult = onResult,
                                )
                            },
                            OfficeTransportDrain.RETRY_DELAY_MS,
                        )
                    }
                    OfficeTransportDrain.Decision.PROCEED_SCRIPT,
                    OfficeTransportDrain.Decision.REFUSE_ARMED,
                    -> {
                        // Closed/closing socket, an unreadable page, a budget
                        // exhausted below the cap, or a cap still pinned: the
                        // unchanged typed pre-dispatch refusal (never a burst
                        // into a certain close). Record the page's OWN counters
                        // (identity-safe: no path, no content, no token) so the
                        // next live occurrence pins closed-vs-stale without
                        // another diagnostic build.
                        recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_TRANSPORT,
                            "final page-health verify refused readyState=" +
                                (health?.readyState?.toString() ?: "unreadable") +
                                " msgInflight=" + (health?.msgInflight?.toString() ?: "-1") +
                                " stalenessMs=" + (health?.stalenessMs?.toString() ?: "-1") +
                                " attempts=" + (attempt + 1),
                        )
                        onResult(false)
                    }
                }
            }

            override fun sendNativeEditable(token: OfficeEditModePreparationToken): Boolean =
                synchronized(host.nativeIngressLock) {
                    if (!isMountLive()) {
                        false
                    } else {
                        // Lock order is ALWAYS ingress -> preparation ->
                        // generation. Cancel takes the same order; a HULLO
                        // cannot slip between the token check and native send.
                        var dispatched = false
                        val active = editModePreparation.runIfActive(token) {
                            synchronized(transportGenerationLock) {
                                if (transportGeneration.get() == token.pageGeneration) {
                                    host.postMobileMessageNative(OfficeReadOnlyProtocol.SET_VIEW_EDITABLE)
                                    dispatched = true
                                }
                            }
                        }
                        active && dispatched
                    }
                }

            override fun enterPageEditMode(
                token: OfficeEditModePreparationToken,
                onHookResult: (Boolean) -> Unit,
            ) {
                mainHandler.post {
                    // docx-socket-repair122 — route by the LIVE page-window
                    // visibility:
                    //
                    //  * HIDDEN: no drain (it can inject nothing useful; a
                    //    hidden page consumes no polls) and NO probe burst
                    //    (that is what closed the socket in C17). Gate on the
                    //    page's own open socket plus a real host-observed wsd
                    //    `pong`, then run the same ordered hooks without the
                    //    burst and verify the page's own open socket once.
                    //  * VISIBLE: the unchanged bounded wake drain (read-first
                    //    since 122) followed by the ordered burst handshake.
                    if (!isPageVisibleNow()) {
                        recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_TRANSPORT,
                            "enter-edit hidden route admitted for gating",
                        )
                        runHiddenTransportGate(token, 0) { admitted, reason ->
                            if (admitted) {
                                runEnterEditScript(token, hiddenRoute = true, onHookResult = onHookResult)
                            } else {
                                recordDiagnostic(
                                    OfficeSessionDiagnostics.KIND_TRANSPORT,
                                    "hidden enter-edit gate refused: " + reason,
                                )
                                // Typed pre-dispatch refusal: nothing was
                                // injected, the socket and the document stay
                                // usable, and the next op (or the same op once
                                // the viewer is visible) re-witnesses honestly.
                                onHookResult(false)
                            }
                        }
                        return@post
                    }
                    runPageTransportDrain(
                        token,
                        0,
                        { runEnterEditScript(token, hiddenRoute = false, onHookResult = onHookResult) },
                        { reason ->
                            recordDiagnostic(
                                OfficeSessionDiagnostics.KIND_TRANSPORT,
                                "pre-handshake drain refused armed: " + reason,
                            )
                            // No injection was made and no effect answered:
                            // the page is merely waiting for its own deferred
                            // polls. Refuse honestly instead of killing it.
                            onHookResult(false)
                        },
                    )
                }
            }

            /**
             * Hidden-window transport gate (docx-socket-repair122): ONE
             * page-truth health read requiring the page's own socket object to
             * be OPEN, then a real host-observed wsd `pong` for the host `ping`
             * — native-side liveness that needs no page polling. Bounded by
             * [OfficeHiddenTransportAdmission.GATE_ATTEMPTS] x
             * [OfficeHiddenTransportAdmission.PONG_WAIT_MS] inside the
             * preparation's unchanged timeout. Never injects a `doSend()`.
             */
            private fun runHiddenTransportGate(
                token: OfficeEditModePreparationToken,
                attempt: Int,
                onResult: (Boolean, String) -> Unit,
            ) {
                val view = webView
                if (view == null) {
                    onResult(false, "no-view")
                    return
                }
                val readGeneration = transportGeneration.get()
                var issueFailed = false
                val started = synchronized(host.nativeIngressLock) {
                    editModePreparation.runIfActive(token) {
                        if (!editModePreparationHost.isMountLive() || webView !== view) {
                            issueFailed = true
                        } else {
                            val issued = runCatching {
                                view.evaluateJavascript(
                                    OfficeReadOnlyProtocol.PAGE_TRANSPORT_HEALTH_SCRIPT,
                                ) { raw ->
                                    mainHandler.post {
                                        onHiddenTransportGateRead(
                                            token, attempt, view, readGeneration, raw, onResult,
                                        )
                                    }
                                }
                            }.isSuccess
                            if (!issued) issueFailed = true
                        }
                    }
                }
                if (started && issueFailed) onResult(false, "hidden-gate-issue-failed")
            }

            private fun onHiddenTransportGateRead(
                token: OfficeEditModePreparationToken,
                attempt: Int,
                readView: COWebView,
                readGeneration: Long,
                raw: String?,
                onResult: (Boolean, String) -> Unit,
            ) {
                val active = synchronized(host.nativeIngressLock) {
                    editModePreparation.runIfActive(token) { }
                }
                if (!active) return
                val health = synchronized(transportGenerationLock) {
                    if (webView === readView && transportGeneration.get() == readGeneration) {
                        OfficeReadOnlyProtocol.parseTransportHealth(raw)
                    } else {
                        null
                    }
                }
                when (OfficeHiddenTransportAdmission.decide(health)) {
                    OfficeHiddenTransportAdmission.Verdict.ADMIT ->
                        verifyHiddenWsdAlive(token, attempt, onResult)
                    OfficeHiddenTransportAdmission.Verdict.REFUSE_SOCKET_CLOSED ->
                        onResult(
                            false,
                            "page-socket-closed readyState=" +
                                (health?.readyState?.toString() ?: "unreadable"),
                        )
                    OfficeHiddenTransportAdmission.Verdict.REFUSE_UNREADABLE ->
                        onResult(false, "page-health-unreadable")
                }
            }

            /**
             * One real native liveness proof for the hidden route: send the
             * pinned `ping` uplink and wait for a NEW `pong` to reach the HOST
             * (`onMessageToJs` stamps [pongSeq] before the frame is queued for
             * the page). Proves the in-process wsd / FakeSocket / native session
             * still processes host uplinks — exactly the channel the effect
             * wire uses — while the page consumes no downlink. Retried within
             * the bounded gate budget; never an injection.
             */
            private fun verifyHiddenWsdAlive(
                token: OfficeEditModePreparationToken,
                attempt: Int,
                onResult: (Boolean, String) -> Unit,
            ) {
                val active = synchronized(host.nativeIngressLock) {
                    editModePreparation.runIfActive(token) { }
                }
                if (!active) return
                val baseline = pongSeq.get()
                val pingSent = runCatching {
                    host.postMobileMessageNative(OfficeReadOnlyProtocol.TRANSPORT_PING)
                }.isSuccess
                if (!pingSent) {
                    onResult(false, "hidden-ping-failed")
                    return
                }
                mainHandler.postDelayed(
                    {
                        val stillActive = synchronized(host.nativeIngressLock) {
                            editModePreparation.runIfActive(token) { }
                        }
                        if (!stillActive) return@postDelayed
                        when {
                            pongSeq.get() > baseline ->
                                onResult(true, "wsd-pong")
                            attempt + 1 >= OfficeHiddenTransportAdmission.GATE_ATTEMPTS ->
                                onResult(
                                    false,
                                    "wsd-pong-missing attempts=" + (attempt + 1) +
                                        " lastPongAtMs=" + lastPongAtMs,
                                )
                            else -> runHiddenTransportGate(token, attempt + 1, onResult)
                        }
                    },
                    OfficeHiddenTransportAdmission.PONG_WAIT_MS,
                )
            }

            override fun runOnControlLane(task: Runnable): Boolean = try {
                controlExecutor.execute(task)
                true
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                false
            }

            override fun scheduleTimeout(delayMs: Long, task: Runnable): Any =
                task.also { mainHandler.postDelayed(it, delayMs) }

            override fun cancelTimeout(handle: Any) {
                if (handle is Runnable) mainHandler.removeCallbacks(handle)
            }

            override fun recordDiagnostic(detail: String) {
                this@Session.recordDiagnostic(OfficeSessionDiagnostics.KIND_STATE, detail)
            }
        }

        fun prepareEditableView(
            opId: String,
            callback: (OfficeEditModePreparationResult) -> Unit,
        ) {
            editRequested = true
            editModePreparation.prepare(opId) { result ->
                if (!result.isReady) editRequested = pageEditMode
                publishEditState()
                callback(result)
            }
        }

        fun cancelEditableViewPreparation(opId: String) {
            synchronized(host.nativeIngressLock) {
                editModePreparation.cancel(opId)
            }
        }

        private fun closeEditModePreparation() {
            synchronized(host.nativeIngressLock) {
                editModePreparation.close()
            }
        }

        // --- genuine background transport (page-transport85) ---
        //
        // The pinned mobile page has no polling of its own and can never
        // re-open its native session (MobileSocket.kt class header). A
        // hidden page consumes no poll response, so its `lastDataTimestamp`
        // cannot be refreshed and a `doSend()` injection in that state can
        // only walk the pinned ladder toward the fatal 30 s close.
        //
        // docx-socket-repair122 (actual C17 DOCX first failure, 2026-10-29):
        // the earlier revision injected heartbeat probes DURING the hidden
        // window on the assumption that an injected `doSend()` would not
        // execute on a hidden WebView. The retained C17 logcat disproves that
        // (injected JS does execute; only the page's loads are deferred), and
        // the injected probe was the execution context of the 17:04:00.123
        // code-1006 close. The transport section therefore now:
        //  * injects NO `doSend()` while the page window is not visible
        //    ([isPageVisibleNow] gates every probe),
        //  * keeps at most one real `pong` waiting in the bounded queue (one
        //    `ping` per hidden window) for the wake drain to deliver,
        //  * reads the page's own counters BEFORE arming any poll, and never
        //    arms one while the in-flight counter is pinned at its cap,
        //  * refuses honestly (no burst) if the cap is still pinned when the
        //    bounded budget ends, instead of closing a merely-deferred page,
        //  * gives the hidden edit preparation a real admission route built on
        //    the page's open socket + a host-observed wsd `pong` + the same
        //    ordered hooks without the probe burst.
        // Everything here is mount-owned: no PIP, no permanent keepalive,
        // no new permission, and no injection can outlive the mount.

        /** True once this mount can never run transport work again. */
        private fun transportPumpTerminal(): Boolean =
            retired || presentationSuperseded || cancelled.get() ||
                current !== this@Session ||
                state == OfficeViewerState.CLOSING || state == OfficeViewerState.CLOSED ||
                processRecoveryRequired.get()

        /**
         * Live page-window visibility (docx-socket-repair122).
         *
         * True only when the current engine WebView is attached, itself
         * VISIBLE and its WINDOW is VISIBLE. That is the same predicate the
         * WebView framework uses to drive the Chromium page's visibility
         * state, evaluated at the injection point — no cached lifecycle flag,
         * no resume/pause race, no assumption about activity state.
         *
         * Why every `doSend()` injection must check it: a hidden page defers
         * its loads, so a poll response cannot be consumed (the C17 evidence:
         * the enter-edit handshake's four polls were still `msgInflight` 20+ s
         * later), while injected `evaluateJavascript` still executes (the
         * post-close 'sending on closed socket' lines). An injection in that
         * state can therefore never deliver data; it only walks the pinned
         * throttle ladder, and once staleness passes 30 s that same `doSend()`
         * closes the socket with code 1006 (pinned global.js 1696-1716) — the
         * actual C17 DOCX first failure during the background approval wait.
         */
        fun isPageVisibleNow(view: COWebView? = webView): Boolean =
            view != null && view.isShown && view.windowVisibility == View.VISIBLE

        private fun startTransportPump() {
            if (!transportPumpStarted.compareAndSet(false, true)) return
            recordDiagnostic(
                OfficeSessionDiagnostics.KIND_TRANSPORT,
                "transport heartbeat pump started",
            )
            scheduleTransportPumpTick(OfficeTransportPump.DEFAULT_HEARTBEAT_INTERVAL_MS)
        }

        private fun scheduleTransportPumpTick(delayMs: Long) {
            val task = Runnable { pumpTick() }
            pumpTickTask = task
            mainHandler.postDelayed(task, delayMs)
        }

        /**
         * One heartbeat tick (main thread). Skips work while not READY or
         * without a live view/socket (a detached window keeps ticking so the
         * pump survives view reconstruction), and stops rescheduling only at
         * the mount terminal or after a failed native ping — the existing
         * transportFailed/process-recovery guards own that failure honestly.
         */
        private fun pumpTick() {
            pumpTickTask = null
            if (transportPumpTerminal() || transportPump.isStopped()) return
            val ready = state == OfficeViewerState.READY_READ_ONLY ||
                state == OfficeViewerState.READY_EDITABLE
            if (ready && webView != null && socket != null) {
                when (transportPump.onTick(android.os.SystemClock.elapsedRealtime())) {
                    OfficeTransportPump.TickDecision.HEARTBEAT -> {
                        val pingSent = runCatching {
                            host.postMobileMessageNative(OfficeReadOnlyProtocol.TRANSPORT_PING)
                        }.isSuccess
                        if (!pingSent) {
                            transportPump.stop()
                            recordDiagnostic(
                                OfficeSessionDiagnostics.KIND_TRANSPORT,
                                "heartbeat ping failed; pump stopped",
                            )
                            return
                        }
                        issueTransportProbe(transportPump.currentRoundId())
                    }
                    // The ping already exists for this open round; only its
                    // probe was gated by ordinary traffic. Never ping twice.
                    OfficeTransportPump.TickDecision.PROBE ->
                        issueTransportProbe(transportPump.currentRoundId())
                    OfficeTransportPump.TickDecision.IDLE -> Unit
                }
            }
            scheduleTransportPumpTick(OfficeTransportPump.DEFAULT_HEARTBEAT_INTERVAL_MS)
        }

        private fun stopTransportPump() {
            transportPump.stop()
            pumpTickTask?.let { mainHandler.removeCallbacks(it) }
            pumpTickTask = null
            pumpSettleTask?.let { mainHandler.removeCallbacks(it) }
            pumpSettleTask = null
        }

        /**
         * Attach/detach, repeated HULLO or refused reload: advance the exact
         * page/socket incarnation before dropping its pump/freshness facts.
         * Execution-point fencing is immediate; settlement returns to the
         * ordinary control lane so no precision callback runs on a native
         * bridge thread or underneath the ingress/preparation monitors.
         */
        fun onTransportGenerationChanged() {
            synchronized(transportGenerationLock) {
                transportGeneration.incrementAndGet()
                transportPump.reset()
                pumpSettleTask?.let { mainHandler.removeCallbacks(it) }
                pumpSettleTask = null
                pageEditModeFact.onPageLifecycleRestart()
            }
            val settle = Runnable {
                if (!retired && current === this@Session) {
                    editModePreparation.onPageTransportGenerationChanged()
                }
            }
            try {
                controlExecutor.execute(settle)
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                // Teardown owns final settlement; the generation check in
                // runIfActive has already fenced every later side effect.
            }
        }

        /**
         * Issues ONE bounded `doSend()` poll probe with an execution
         * callback, honoring the page-side single-pending-poll gate.
         * [roundId] is the heartbeat round this probe belongs to (0 for
         * drain-only probes). The callback distinguishes a frozen renderer
         * (never fires; the injection stays the one pending poll) from an
         * executed probe whose `doSend()` early-returned at the pinned
         * `msgInflight >= 4` gate (fires, then settles after
         * [OfficeTransportPump.PROBE_SETTLE_MS]). Both the never-reused
         * injection seq and the captured view identity are re-checked in
         * every continuation: a stale callback from a previous
         * view/socket generation mutates nothing.
         */
        private fun issueTransportProbe(roundId: Long) {
            val view = webView ?: return
            // docx-socket-repair122: the host is the ONLY `doSend()` source
            // (pinned MobileSocket deletes/no-ops `_setPollInterval`), so
            // suppressing injections while the page window is hidden makes a
            // watchdog close during a hidden approval wait IMPOSSIBLE — no
            // injection, no watchdog evaluation, and nothing else can close the
            // pinned socket (its `close()` is a no-op and a hidden page consumes
            // no polls). The heartbeat's real `pong` waits in the bounded queue
            // and is delivered by the first poll the wake drain arms.
            if (!isPageVisibleNow(view)) {
                if (!hiddenProbeSuppressedLogged) {
                    hiddenProbeSuppressedLogged = true
                    recordDiagnostic(
                        OfficeSessionDiagnostics.KIND_TRANSPORT,
                        "transport probe suppressed: page window hidden",
                    )
                }
                return
            }
            if (hiddenProbeSuppressedLogged) hiddenProbeSuppressedLogged = false
            synchronized(transportGenerationLock) {
                if (transportPumpTerminal() || webView !== view || transportPump.pollOutstanding()) return
                val probeGeneration = transportGeneration.get()
                val seq = ++nextInjectionSeq
                transportPump.onInjectionIssued(seq, roundId)
                val issued = runCatching {
                    // docx-socket-repair122: the page-side safe probe refuses
                    // `doSend()` itself while `msgInflight >= 4`, so no host
                    // injection path (pump tick, drain retry, final verify) can
                    // reach the pinned watchdog branch even if a health read and
                    // the injection straddle a page-side state change.
                    view.evaluateJavascript(OfficeReadOnlyProtocol.PAGE_SAFE_POLL_PROBE_SCRIPT) {
                        mainHandler.post {
                            synchronized(transportGenerationLock) {
                                if (
                                    transportPumpTerminal() || webView !== view ||
                                    transportGeneration.get() != probeGeneration
                                ) return@post
                                onTransportProbeExecuted(seq)
                            }
                        }
                    }
                }.isSuccess
                if (!issued) {
                    transportPump.onInjectionIssueFailed(seq, android.os.SystemClock.elapsedRealtime())
                }
            }
        }

        /** Main thread: arms the bounded settle window for an executed probe. */
        private fun onTransportProbeExecuted(injectionSeq: Long) {
            // A stale callback must not even REPLACE the current injection's
            // settle task. The pump accepts only the exact outstanding seq.
            if (!transportPump.onProbeExecuted(injectionSeq)) return
            pumpSettleTask?.let { mainHandler.removeCallbacks(it) }
            val settle = Runnable {
                pumpSettleTask = null
                // Identity-matched inside the pump: a settle for a
                // superseded/stale injection is a deterministic no-op and
                // can never clear the current outstanding injection.
                transportPump.onProbeSettled(
                    injectionSeq,
                    android.os.SystemClock.elapsedRealtime(),
                )
            }
            pumpSettleTask = settle
            mainHandler.postDelayed(settle, OfficeTransportPump.PROBE_SETTLE_MS)
        }

        /**
         * Bounded pre-handshake wake drain ([OfficeTransportDrain]).
         *
         * docx-socket-repair122 — READ FIRST, then inject only when the page's
         * own counters make the injection provably non-fatal: each iteration
         * READS the page's transport counters (no WebView mutation), and only
         * a [OfficeTransportDrain.Decision.RETRY_WITH_PROBE] outcome arms ONE
         * poll (plus one real `ping` so the delivered frame is a `pong`). The
         * previous revision injected before every read; on a page left hidden
         * with the handshake's polls pinned at the in-flight cap that first
         * injection could only walk the ladder and closed the socket once
         * staleness passed 30 s — the actual C17 wake shape. A budget that
         * ends with the cap still pinned now refuses
         * ([OfficeTransportDrain.Decision.REFUSE_ARMED]) instead of running
         * the handshake's probe burst into the same close.
         *
         * The drain still never ADMITS: [onFinished] proceeds to the real
         * handshake script, which remains the single admission verdict.
         * [onArmedRefused] is the one new honest outcome — a typed
         * pre-dispatch refusal with no injection, so a merely-deferred page
         * is never killed. It runs on the main thread.
         *
         * [token] non-null fences every issuance and continuation under the
         * ingress→preparation lock order (an owned preparation: cancel/close
         * drops the chain with no further WebView step); null is the manual
         * requestEdit path, fenced by session liveness only. Neither callback
         * runs under the ingress/preparation monitors.
         */
        internal fun runPageTransportDrain(
            token: OfficeEditModePreparationToken?,
            attempt: Int,
            onFinished: () -> Unit,
            onArmedRefused: (String) -> Unit,
        ) {
            if (attempt >= OfficeTransportDrain.MAX_ATTEMPTS) {
                onFinished()
                return
            }
            val view = webView
            if (view == null) {
                onFinished()
                return
            }
            val readGeneration = transportGeneration.get()
            if (token != null) {
                var proceedOutsideLocks = false
                synchronized(host.nativeIngressLock) {
                    editModePreparation.runIfActive(token) {
                        if (editModePreparationHost.isMountLive() && webView === view) {
                            if (!issueTransportHealthRead(
                                    token, attempt, view, readGeneration, onFinished, onArmedRefused,
                                )
                            ) {
                                proceedOutsideLocks = true
                            }
                        } else {
                            // Mount gone mid-preparation: the script's own
                            // fence reports the honest typed failure.
                            proceedOutsideLocks = true
                        }
                    }
                }
                // A fenced (cancelled/closed) preparation drops the chain
                // here without touching the WebView: the cancel/close owner
                // has already settled the operation.
                if (proceedOutsideLocks) onFinished()
                return
            }
            if (transportPumpTerminal() || webView !== view) return
            if (!issueTransportHealthRead(null, attempt, view, readGeneration, onFinished, onArmedRefused)) {
                onFinished()
            }
        }

        /** Issues one read-only health read; false when it could not start. */
        private fun issueTransportHealthRead(
            token: OfficeEditModePreparationToken?,
            attempt: Int,
            view: COWebView,
            readGeneration: Long,
            onFinished: () -> Unit,
            onArmedRefused: (String) -> Unit,
        ): Boolean = runCatching {
            view.evaluateJavascript(OfficeReadOnlyProtocol.PAGE_TRANSPORT_HEALTH_SCRIPT) { raw ->
                // Captured view AND page/socket generation travel with the
                // answer: neither an old view nor a pre-HULLO answer may
                // continue or authorize a chain against the new incarnation.
                mainHandler.post {
                    onTransportHealthRead(
                        token, attempt, view, readGeneration, raw, onFinished, onArmedRefused,
                    )
                }
            }
        }.isSuccess

        private fun onTransportHealthRead(
            token: OfficeEditModePreparationToken?,
            attempt: Int,
            readView: COWebView,
            readGeneration: Long,
            raw: String?,
            onFinished: () -> Unit,
            onArmedRefused: (String) -> Unit,
        ) {
            // Re-fence at the real continuation point: a settled preparation
            // or terminated manual session drives no further WebView step.
            if (token != null) {
                val active = synchronized(host.nativeIngressLock) {
                    editModePreparation.runIfActive(token) { }
                }
                if (!active) return
            } else if (transportPumpTerminal()) {
                return
            }
            // Stale-view answer: NOT a health fact. Treat it as unreadable
            // so the bounded retry re-reads the CURRENT page instead of
            // proceeding on observations from a replaced incarnation.
            val health = synchronized(transportGenerationLock) {
                val current = if (webView === readView && transportGeneration.get() == readGeneration) {
                    OfficeReadOnlyProtocol.parseTransportHealth(raw)
                } else {
                    null
                }
                if (OfficeTransportDrain.isFresh(current)) {
                    // PAGE-CONSUMED downlink truth, stamped atomically with
                    // the generation check so a pre-HULLO answer cannot
                    // re-corroborate the new page incarnation.
                    pageEditModeFact.onPageReportedFreshDownlink(
                        android.os.SystemClock.elapsedRealtime(),
                    )
                }
                current
            }
            when (OfficeTransportDrain.decide(health, attempt)) {
                OfficeTransportDrain.Decision.RETRY_WITH_PROBE -> {
                    // Safe to arm one poll (in-flight below the pinned cap, so
                    // the injected doSend() creates its XHR and cannot reach
                    // the watchdog branch). Make it able to witness REAL data:
                    // open an on-demand heartbeat round (one `ping`; strictly
                    // one open round at a time) so the pong is in the bounded
                    // queue for this poll to deliver.
                    armDrainHeartbeat()
                    mainHandler.postDelayed(
                        { runPageTransportDrain(token, attempt + 1, onFinished, onArmedRefused) },
                        OfficeTransportDrain.RETRY_DELAY_MS,
                    )
                }
                OfficeTransportDrain.Decision.RETRY_READ_ONLY -> {
                    // The page's in-flight counter is pinned at the cap, or the
                    // answer was unreadable: an injection could only walk the
                    // ladder (never deliver data), and at >30 s staleness it
                    // closes the socket. Inject NOTHING and re-read; the page's
                    // own deferred polls complete when the window is visible.
                    mainHandler.postDelayed(
                        { runPageTransportDrain(token, attempt + 1, onFinished, onArmedRefused) },
                        OfficeTransportDrain.RETRY_DELAY_MS,
                    )
                }
                OfficeTransportDrain.Decision.PROCEED_SCRIPT -> {
                    // office-background-repair118: proceeding WITHOUT fresh
                    // page-truth means either a closed/closing socket (the
                    // actual DOCX `page-edit-hook-unavailable` shape — the
                    // drain cannot heal a 1006 close, only refuse honestly),
                    // an unreadable page or a stale budget exhausted with the
                    // in-flight counter BELOW the cap (an injection there is
                    // provably safe). Record the page's OWN counters
                    // (identity-safe: readyState/msgInflight/staleness only —
                    // never a path, token or content) so the next device
                    // occurrence pins the cause without guessing.
                    if (!OfficeTransportDrain.isFresh(health)) {
                        recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_TRANSPORT,
                            "pre-handshake drain proceeded readyState=" +
                                (health?.readyState?.toString() ?: "unreadable") +
                                " msgInflight=" + (health?.msgInflight?.toString() ?: "-1") +
                                " stalenessMs=" + (health?.stalenessMs?.toString() ?: "-1") +
                                " attempts=" + (attempt + 1),
                        )
                    }
                    onFinished()
                }
                OfficeTransportDrain.Decision.REFUSE_ARMED -> {
                    // The in-flight cap is still pinned after the whole
                    // bounded budget: running the handshake's synchronous
                    // probe burst would close a page that is only waiting for
                    // its own deferred polls. Refuse honestly with NO
                    // injection; the socket and the document stay usable.
                    val reason = "in-flight-cap-pinned readyState=" +
                        (health?.readyState?.toString() ?: "unreadable") +
                        " msgInflight=" + (health?.msgInflight?.toString() ?: "-1") +
                        " stalenessMs=" + (health?.stalenessMs?.toString() ?: "-1") +
                        " attempts=" + (attempt + 1)
                    recordDiagnostic(
                        OfficeSessionDiagnostics.KIND_TRANSPORT,
                        "pre-handshake drain refused armed: " + reason,
                    )
                    onArmedRefused(reason)
                }
            }
        }

        /**
         * One on-demand heartbeat for the drain's retry path: opens a pump
         * round when none is open (bounded by the pump's single-round rule),
         * sends the real `ping` and arms the poll probe that can carry the
         * `pong` back to the page. A failed native ping stops the pump — the
         * existing transportFailed/process-recovery guards own that failure.
         */
        private fun armDrainHeartbeat() {
            if (transportPumpTerminal() || transportPump.isStopped()) return
            if (webView == null || socket == null) return
            if (!transportPump.requestRound()) {
                // Reuse the already-pinged open round; a foreign ordinary
                // probe may have just settled and freed its missing probe.
                issueTransportProbe(transportPump.currentRoundId())
                return
            }
            val pingSent = runCatching {
                host.postMobileMessageNative(OfficeReadOnlyProtocol.TRANSPORT_PING)
            }.isSuccess
            if (!pingSent) {
                transportPump.stop()
                recordDiagnostic(
                    OfficeSessionDiagnostics.KIND_TRANSPORT,
                    "drain heartbeat ping failed; pump stopped",
                )
                return
            }
            issueTransportProbe(transportPump.currentRoundId())
        }

        /**
         * The real enter-edit handshake execution point (page-mode79's
         * queued-runnable body, unchanged): issuance re-fenced under the
         * ingress→preparation lock order, the hook result marshalled to the
         * main handler outside every monitor. hookRan=true only completes the
         * owned phase latch; READY additionally requires the EDITMODE/
         * activation candidate and this operation's final page-health read.
         */
        private fun runEnterEditScript(
            token: OfficeEditModePreparationToken,
            hiddenRoute: Boolean,
            onHookResult: (Boolean) -> Unit,
        ) {
            // docx-socket-repair122: the synchronous 24-call `doSend()` burst
            // exists only to force the pinned watchdog to evaluate NOW. It is
            // fatal on a hidden page whose in-flight counter is pinned at the
            // cap (C17), so the hidden route NEVER bursts and a visible route
            // that has just gone hidden downgrades to the same ordered hooks
            // WITHOUT the burst. The session never injects a `doSend()` while
            // the window is hidden. Diagnostic outside every monitor.
            recordDiagnostic(
                OfficeSessionDiagnostics.KIND_TRANSPORT,
                "enter-edit script hiddenRoute=" + hiddenRoute +
                    " visibleNow=" + isPageVisibleNow(),
            )
            var hookFailed = false
            val started = synchronized(host.nativeIngressLock) {
                editModePreparation.runIfActive(token) {
                    synchronized(transportGenerationLock) {
                        if (!editModePreparationHost.isMountLive() || transportGeneration.get() != token.pageGeneration) {
                            hookFailed = true
                        } else {
                            val view = webView
                            if (view == null) {
                                hookFailed = true
                            } else {
                                // Injection-time visibility is authoritative: a
                                // window that hid between the route decision and
                                // this execution point must not force the
                                // watchdog (the only thing the burst can do).
                                val burst = !hiddenRoute && isPageVisibleNow(view)
                                val script = if (burst) {
                                    OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT
                                } else {
                                    OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT_NO_PROBE
                                }
                                runCatching {
                                    view.evaluateJavascript(script) { raw ->
                                        val ok = raw?.trim('"') == "true"
                                        // Never invoke precision under the
                                        // ingress/preparation monitors.
                                        mainHandler.post { onHookResult(ok) }
                                    }
                                }.onFailure { hookFailed = true }
                            }
                        }
                    }
                }
            }
            if (started && hookFailed) onHookResult(false)
        }

        /** Serialized page fact fan-out for precision and the pending flush. */
        private fun onPageEditModeForOwnedOperations(on: Boolean, pageGeneration: Long) {
            // The fact was observed on a specific page/socket incarnation.
            // A stale OFF must neither settle a newer preparation nor drive
            // its precision ledger into after-effect UNKNOWN.
            if (transportGeneration.get() != pageGeneration) return
            editModePreparation.onPageEditMode(on, pageGeneration)
            if (!on) {
                var settleFlush: (() -> Unit)? = null
                synchronized(transportGenerationLock) {
                    // Recheck at the ACTUAL ledger effect: a HULLO racing the
                    // preparation fan-out must not turn its older OFF into a
                    // new-generation precision UNKNOWN or flush abort.
                    if (transportGeneration.get() != pageGeneration) return
                    precision.onPageViewingObserved()
                    val opId = saveCoordinator.pendingFlushOpId()
                    if (opId != null) {
                        if (saveCoordinator.isFlushDispatched()) {
                            recordDiagnostic(
                                OfficeSessionDiagnostics.KIND_SAVE,
                                "page viewing after flush dispatch op=$opId; awaiting real save outcome",
                            )
                        } else {
                            saveCoordinator.abortDispatch(opId, "page-viewing-before-flush")?.let { outcome ->
                                // External completion stays outside every
                                // generation/ingress/preparation monitor.
                                settleFlush = {
                                    this@OfficeEngineService.completeFlush(this@Session, outcome)
                                }
                            }
                        }
                    }
                }
                settleFlush?.invoke()
            }
        }

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
            // The transport heartbeat starts exactly when the mount becomes
            // genuinely usable (document loaded, permission barrier observed,
            // render witnessed) and never earlier: before READY there is no
            // loaded document for the pinned `ping` to reference
            // (ClientSession answers `nodocloaded`), and an OPENING mount's
            // load burst already drives its own polls.
            if (next == OfficeViewerState.READY_READ_ONLY || next == OfficeViewerState.READY_EDITABLE) {
                startTransportPump()
            }
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
            // No heartbeat/injection may be issued for a closing mount, and
            // no queued pump task may act after teardown (page-transport85:
            // after-close JavaScript can never touch a later mount).
            stopTransportPump()
            // Fence any queued native/JS edit-preparation execution before
            // settling operations; late hooks cannot enter a closing mount.
            closeEditModePreparation()
            // Precision operations awaiting a native answer can never
            // receive one after this mount ends: settle them UNKNOWN
            // (effects uncertain, ALL data retained, never auto-undone)
            // before the outcome snapshot.
            precision.onMountTerminal()
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
            if (message == "HULLO" && !hulloClaimed.compareAndSet(false, true)) {
                // A repeated handshake frame means the page restarted its
                // native channel: the cached EDITMODE fact describes the
                // previous page incarnation and cannot vouch for a new owned
                // operation. The frame itself is still never forwarded — the
                // pinned androidapp.cpp binds exactly one fake-socket native
                // session per createCOOLWSD lifetime, so a second connect is
                // not a supported producer path.
                onTransportGenerationChanged()
                recordDiagnostic(
                    OfficeSessionDiagnostics.KIND_STATE,
                    "page handshake after first HULLO; transport generation advanced",
                )
                return false
            }
            if (OfficeReadOnlyProtocol.isReservedQuery(message)) return false
            if (OfficeReadOnlyProtocol.command(message) == "load") {
                var refusedReload = false
                val forward = synchronized(this) {
                    when {
                        // Same evaluation order as the historical single-load
                        // authority: an already-forwarded snapshot makes any
                        // later load frame a page reload attempt.
                        loadForwarded -> {
                            refusedReload = true
                            false
                        }
                        !OfficeReadOnlyProtocol.matchesSnapshotLoad(message, File(request.stagedFilePath)) -> false
                        else -> {
                            loadForwarded = true
                            true
                        }
                    }
                }
                if (!forward) {
                    if (refusedReload) {
                        // A page-issued reload `load` (the pinned mobile
                        // transport can never re-open its native session):
                        // the cached page-edit fact no longer describes the
                        // live page incarnation.
                        onTransportGenerationChanged()
                        recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_STATE,
                            "page reload load frame refused; transport generation advanced",
                        )
                    }
                    notifyNotice("loadError", null)
                    return false
                }
            }
            // The page's own edit-mode notice (pinned Android behaviour: the
            // bundle posts EDITMODE on/off around _enterEditMode /
            // _enterReadOnlyMode). Real page-state witness; consumed here and
            // never forwarded (it is not a native protocol command).
            if (OfficeReadOnlyProtocol.command(message) == "EDITMODE") {
                val on = message.substringAfter(' ', "").trim() == "on"
                if (editable) {
                    val observedGeneration = transportGeneration.get()
                    pageEditMode = on
                    pageEditModeFact.onPageFact(on, android.os.SystemClock.elapsedRealtime())
                    recordDiagnostic(OfficeSessionDiagnostics.KIND_STATE, "page EDITMODE=$on")
                    publishEditState()
                    runCatching {
                        controlExecutor.execute {
                            if (retired || presentationSuperseded || current !== this@Session) return@execute
                            onPageEditModeForOwnedOperations(on, observedGeneration)
                        }
                    }
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
                CoolMessageGate.Decision.FORWARD,
                CoolMessageGate.Decision.FORWARD_AFTER,
                -> {
                    // Precision lease (G05-R2 P-A): while a typed precision
                    // operation is ACTUALLY executing (never while a model
                    // thinks between ops), competing page retarget/write
                    // traffic is fenced — mouse/key/selecttext/setpart/uno/
                    // save/setviewreadonly/dialog/window commands AND the
                    // reply-collision query class. Only pure render/tile/
                    // keepalive traffic flows (fail-closed allowlist inside
                    // the engine). A blocked attempt had no native effect,
                    // so it does NOT advance the manual-input epoch; the
                    // honest notice is emitted once per operation.
                    val head = OfficeReadOnlyProtocol.command(message)
                    if (precision.blocksPageCommand(head)) {
                        if (precision.claimLeaseNoticeOnce(precision.ledger.armedOpId())) {
                            notifyNotice("precisionBusy", null)
                        }
                        return false
                    }
                    precision.noteForwardedPageCommand(head)
                    if (head == "useractive") {
                        // The page can only emit this frame while its socket
                        // transport is open (pinned Socket.ts gate + mobile
                        // bridge uplink), so one real forwarded frame is the
                        // edit-handshake transport liveness witness (see
                        // OfficeEditModePreparation). The kit never sends
                        // `useractive` downstream and the host's own native
                        // wire never uses it, so this count cannot be fed by
                        // anything but the live page. The monotonic count is
                        // the handshake-baseline witness; the freshness stamp
                        // additionally corroborates the cached fast path
                        // (page-transport85 finding A: a fresh RAW EDITMODE
                        // ack without a recent real witness frame is not an
                        // admission fact — the bridge works on a dying proxy).
                        pageActivationWitnessCount.incrementAndGet()
                        pageEditModeFact.onActivationWitness(android.os.SystemClock.elapsedRealtime())
                    }
                    return true
                }
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
            // docx-socket-repair122: a host-observed wsd `pong` is recorded
            // HERE, before the frame is queued for the page, so the hidden
            // route has a real native-side liveness witness that does not need
            // any page polling (a hidden page consumes no downlink at all). The
            // frame is still relayed to the page unchanged below.
            if (OfficeReadOnlyProtocol.isTransportPong(message)) {
                pongSeq.incrementAndGet()
                lastPongAtMs = android.os.SystemClock.elapsedRealtime()
            }
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
                CoolMessageTriage.Kind.STATUS -> {
                    triage.shape?.let { shape ->
                        witnessWidthTwip = shape.widthTwip
                        witnessHeightTwip = shape.heightTwip
                        establishNativePermission()
                        maybePromoteReady()
                    }
                    // Precision correlation observes the real status frame
                    // BEFORE the WebView relay (exact `status:` prefix only
                    // settles a status pull; statusupdate/partstatus never do).
                    precision.observeNativeFrame(triage, message)
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
                    // Precision tracks ModifiedStatus as corroboration only
                    // (never as completion evidence by itself).
                    precision.observeNativeFrame(triage, message)
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
                    } else if (precision.observeNativeFrame(triage, message)) {
                        // The error frame named the ARMED precision step's
                        // own command: it is that operation's producer
                        // refusal (consumed as its typed FAILED result),
                        // NOT a document failure — the mount stays open and
                        // usable. Every other error keeps the exact existing
                        // generic behaviour below (nothing is suppressed).
                        recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_NATIVE_ERROR,
                            "error consumed as precision operation refusal cmd=${info?.cmd}",
                        )
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
                // Precision-surface answer/effect frames: correlated BEFORE
                // the WebView relay, then relayed unchanged below (the page
                // keeps seeing every frame exactly as before).
                CoolMessageTriage.Kind.COMMAND_VALUE,
                CoolMessageTriage.Kind.TEXT_SELECTION_CONTENT,
                CoolMessageTriage.Kind.COMPLEX_SELECTION,
                CoolMessageTriage.Kind.PASTE_RESULT,
                CoolMessageTriage.Kind.PART_SET,
                CoolMessageTriage.Kind.TEXT_SELECTION,
                CoolMessageTriage.Kind.GRAPHIC_SELECTION,
                CoolMessageTriage.Kind.CELL_CURSOR,
                CoolMessageTriage.Kind.CELL_ADDRESS,
                CoolMessageTriage.Kind.CELL_FORMULA,
                CoolMessageTriage.Kind.PRESENTATION_INFO,
                -> {
                    precision.observeNativeFrame(triage, message)
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
            // Page-side single-pending-poll gate (page-transport85): an
            // injection not yet matched by a served poll is skipped — the
            // pending poll drains the whole bounded batch, and
            // MobileSocket.write()'s tail re-arm continues the chain on
            // arrival. Stacking injections behind a frozen renderer is the
            // C15 wake flood that walked the pinned throttle ladder to its
            // cap and armed the fatal 30 s close.
            if (transportPump.pollOutstanding()) return
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
                    // when this runnable was scheduled. Re-check the page-side
                    // gate at the real execution point too: between claim and
                    // run another path (pump probe, drain probe) may have
                    // become the one pending poll.
                    if (webView === view) {
                        // Ordinary traffic uses the SAME execution-identified
                        // probe as heartbeat/drain. Without that callback an
                        // arrival-safe gate could never distinguish this
                        // injection from up to four older in-flight XHRs.
                        issueTransportProbe(0L)
                    }
                }
            }.getOrDefault(false)
            if (!posted) sendTrigger.release()
        }

        override fun onPollServed() {
            // Called for a planned non-failure response from MobileSocket.write()
            // on the WebView network thread. The pump accepts it as progress
            // only after the CURRENT injection's execution callback; an old
            // pre-freeze XHR cannot release the queued-injection gate.
            // Deliberately NOT an admission-freshness fact: serving a body
            // is a delivery opportunity, not a page-consumption proof (Main
            // late critical review 2026-10-28). Downlink freshness for
            // admission is stamped only by reads of the page's OWN counters
            // (runPageTransportDrain / verifyPageTransportHealth).
            transportPump.onPollServed(android.os.SystemClock.elapsedRealtime())
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
        // A fresh view carries a fresh MobileSocket (fresh serial space and
        // poll reality): drop any injection/round bookkeeping from the old
        // one so the heartbeat pump re-arms against the live transport.
        session.onTransportGenerationChanged()
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
            // Injections queued toward the leaving view can never arrive:
            // drop the page-side gate and round bookkeeping with it.
            session.onTransportGenerationChanged()
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

        override fun onPollServed() {
            delegate?.onPollServed()
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
        // Precision lease mutual exclusion (one native-session operation at
        // a time): a flush/export is refused while a typed capture/apply
        // actually executes; the precision submit side checks saveBusy()
        // symmetrically. The save protocol itself is unchanged.
        if (session.precision.leaseActive()) {
            return rejectedReceipt(
                op,
                OfficeSaveFailureCode.INTERNAL,
                "a precision operation holds the native session lease",
            )
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
            // A queued page hook/native preparation must not fire after the
            // exact pre-dispatch cancellation has already been acknowledged.
            session.cancelEditableViewPreparation(opId)
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
        // The precision lease fences nativeReadOnly toggles: flipping view
        // permissions mid-capture/apply could break the trusted mutation in
        // flight (and is itself a retarget-class state change). Short and
        // bounded — never held while a model thinks between operations.
        if (session.precision.leaseActive()) {
            session.recordDiagnostic("precision", "requestEdit refused: lease active")
            return false
        }
        session.editRequested = enable
        session.recordDiagnostic(OfficeSessionDiagnostics.KIND_STATE, "host requestEdit enable=$enable")
        controlExecutor.execute {
            if (session.retired || session.cancelled.get() || current !== session) return@execute
            // Ingress-monitor re-check: the binder-time lease pre-check is a
            // TOCTOU; the real setviewreadonly send either happens now under
            // the shared monitor or is honestly refused (never flips
            // nativeReadOnly underneath a precision capture/apply).
            var leaseBlocked = false
            val sendFailed = synchronized(session.host.nativeIngressLock) {
                if (!session.precision.canDispatchCompetingNative()) {
                    leaseBlocked = true
                    false
                } else {
                    runCatching {
                        session.host.postMobileMessageNative(
                            if (enable) OfficeReadOnlyProtocol.SET_VIEW_EDITABLE else OfficeReadOnlyProtocol.SET_VIEW_READ_ONLY,
                        )
                    }.isFailure
                }
            }
            when {
                leaseBlocked -> {
                    session.editRequested = !enable
                    session.recordDiagnostic("precision", "edit-toggle refused at dispatch: lease active")
                    session.notifyNotice("precisionBusy", null)
                    session.publishEditState()
                }
                sendFailed -> session.transportFailed("edit-toggle")
            }
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
            val entryGeneration = session.transportGenerationSnapshot()
            fun refuseEntry() {
                session.editRequested = !enable
                session.notifyNotice("editEntryUnavailable", null)
                session.publishEditState()
            }
            fun evaluateEntry() {
                if (session.retired || session.presentationSuperseded || current !== session) return
                if (session.webView !== view || session.transportGenerationSnapshot() != entryGeneration) {
                    // The view OR same-view page/socket incarnation changed
                    // during the bounded drain: this toggle targeted the old
                    // page — honest refusal, never an injection into the new.
                    refuseEntry()
                    return
                }
                // docx-socket-repair122: never run the synchronous 24-call
                // `doSend()` burst on a hidden page — it can only walk the
                // pinned ladder and, past 30 s staleness with the in-flight
                // counter at its cap, close the socket. The manual toggle
                // (like the owned handshake) uses the same ordered hooks
                // without the burst whenever the page window is not visible.
                val script = when {
                    !enable -> OfficeReadOnlyProtocol.PAGE_ENTER_VIEW_SCRIPT
                    session.isPageVisibleNow(view) -> OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT
                    else -> OfficeReadOnlyProtocol.PAGE_ENTER_EDIT_SCRIPT_NO_PROBE
                }
                runCatching {
                    view.evaluateJavascript(script) { raw ->
                        if (
                            session.retired || session.presentationSuperseded || current !== session ||
                            session.webView !== view || session.transportGenerationSnapshot() != entryGeneration
                        ) return@evaluateJavascript
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
                    refuseEntry()
                }
            }
            if (enable && session.isPageVisibleNow(view)) {
                // A manual edit entry shares the owned handshake's bounded
                // wake drain (page-transport85, read-first since
                // docx-socket-repair122): a page just woken from a hidden wait
                // gets the real opportunity to complete its deferred polls and
                // deliver the heartbeat's real `pong` before any probe is
                // armed. An in-flight counter still pinned at the cap after the
                // budget refuses honestly instead of running the burst.
                // A hidden window skips the drain entirely: no poll can be
                // armed there, and the no-burst script's own readyState /
                // connected() gates decide honestly.
                session.runPageTransportDrain(
                    null,
                    0,
                    { evaluateEntry() },
                    { reason ->
                        session.recordDiagnostic(
                            OfficeSessionDiagnostics.KIND_TRANSPORT,
                            "manual edit-entry drain refused armed: " + reason,
                        )
                        refuseEntry()
                    },
                )
            } else {
                evaluateEntry()
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
        // Manual history is fenced while a precision operation executes: an
        // undo landing between a mutation's steps would corrupt both the
        // document target and the correlation (one mutation in flight per
        // native session). Honest refusal; retry after the lease clears.
        if (session.precision.leaseActive()) {
            session.recordDiagnostic("precision", "requestEditHistory refused: lease active")
            return false
        }
        controlExecutor.execute {
            if (session.retired || session.cancelled.get() || current !== session) return@execute
            // Ingress-monitor re-check: a manual undo/redo landing between a
            // precision mutation's steps would corrupt both the document
            // target and the frame correlation — the REAL send is refused
            // under the shared monitor, honestly noticed, never silently.
            var leaseBlocked = false
            val sendFailed = synchronized(session.host.nativeIngressLock) {
                if (!session.precision.canDispatchCompetingNative()) {
                    leaseBlocked = true
                    false
                } else {
                    runCatching {
                        session.host.postMobileMessageNative(
                            if (redo) "uno .uno:Redo" else "uno .uno:Undo",
                        )
                    }.isFailure
                }
            }
            when {
                leaseBlocked -> {
                    session.recordDiagnostic("precision", "edit-history refused at dispatch: lease active")
                    session.notifyNotice("precisionBusy", null)
                }
                sendFailed -> session.transportFailed("edit-history")
            }
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

    // --- precision surface entry points (G05-R2 P-A, same-UID binder) ---

    /**
     * Fenced admission of one typed precision operation. Returns the
     * synchronous ADMITTED acknowledgement or the exact typed REJECTED
     * result (also stored for the answer read). NEVER a completion claim:
     * the terminal result arrives via [readPrecisionAnswerFromBinder].
     */
    internal fun postPrecisionCommandFromBinder(
        request: OfficePrecisionRequest,
    ): OfficePrecisionResult {
        val now = android.os.SystemClock.elapsedRealtime()
        val session = current
        if (session == null || session.retired ||
            session.request.sessionToken != request.sessionToken ||
            session.generation != request.generation
        ) {
            // No engine to fence through: answer with the same typed honesty
            // (the mount identity simply does not exist here).
            return OfficePrecisionResult(
                opId = request.opId,
                sessionToken = request.sessionToken,
                generation = request.generation,
                action = request.action,
                state = OfficePrecisionState.REJECTED,
                failure = OfficePrecisionFailure.SESSION_MISMATCH,
                detail = "no-live-mount-for-this-identity",
                answer = null,
                attestation = OfficePrecisionAttestation.REFUSED_BEFORE_DISPATCH,
                submittedAtElapsedMs = now,
                completedAtElapsedMs = now,
            )
        }
        return session.precision.submit(request)
    }

    /**
     * Reads (and consumes) the terminal result of one exact fenced
     * precision op — the ONLY path typed answer content leaves the engine
     * (same-UID binder + exact token/generation fence). Null while pending
     * or unknown.
     */
    internal fun readPrecisionAnswerFromBinder(
        opId: String,
        sessionToken: String,
        generation: Long,
    ): OfficePrecisionResult? {
        val session = current ?: return null
        return session.precision.readAnswer(opId, sessionToken, generation)
    }

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
                session.cancelEditableViewPreparation(op.opId)
            }
            return
        }
        session.prepareEditableView(op.opId) { result ->
            // Cancellation or mount terminal may have settled this exact op
            // while the page hook was queued. A late callback sends nothing.
            if (session.saveCoordinator.pendingFlushOpId() != op.opId) return@prepareEditableView
            if (!result.isReady) {
                session.saveCoordinator.abortDispatch(
                    op.opId,
                    "edit-preparation:" + result.detail,
                )?.let { outcome -> completeFlush(session, outcome) }
            } else {
                dispatchFlushAfterEditPreparation(session, op)
            }
        }
    }

    /** Sends native editable + save atomically after the REAL page edit witness. */
    private fun dispatchFlushAfterEditPreparation(session: Session, op: OfficeSaveRequest) {
        if (session.saveCoordinator.pendingFlushOpId() != op.opId) return
        if (session.retired || session.cancelled.get() || current !== session) {
            session.saveCoordinator.abortDispatch(op.opId, "mount-ended-before-flush")?.let { outcome ->
                completeFlush(session, outcome)
            }
            return
        }
        try {
            var alreadySettled = false
            val refusal = synchronized(session.host.nativeIngressLock) {
                when {
                    !session.precision.canDispatchCompetingNative() -> "precision-lease-at-dispatch"
                    !session.pageEditMode -> "page-viewing-before-flush"
                    // Mark BEFORE any native call. Cancel either wins here
                    // (mark=false, no send) or becomes STILL_IN_FLIGHT; it can
                    // never acknowledge pre-dispatch cancel then allow save.
                    !session.saveCoordinator.markFlushDispatched(op.opId) -> {
                        alreadySettled = true
                        null
                    }
                    else -> {
                        val sent = OfficeOwnedEditDispatch.run(
                            isPageEditMode = { session.pageEditMode },
                            sendNativeEditable = {
                                session.host.postMobileMessageNative(OfficeReadOnlyProtocol.SET_VIEW_EDITABLE)
                            },
                            sendOperation = {
                                if (session.saveCoordinator.pendingFlushOpId() != op.opId ||
                                    !session.saveCoordinator.isFlushDispatched() ||
                                    !session.saveCoordinator.markSaveCommandDispatched(op.opId)
                                ) {
                                    throw IllegalStateException("stale-flush-dispatch")
                                }
                                // Ack ownership starts only here, immediately
                                // before the REAL save call—not during edit.
                                session.host.postMobileMessageNative(
                                    OfficeSaveProtocol.flushMessage(op.saveIfUnmodified),
                                )
                            },
                        )
                        if (sent) null else "page-viewing-before-flush"
                    }
                }
            }
            if (alreadySettled) return
            if (refusal != null) {
                session.saveCoordinator.abortDispatch(op.opId, refusal)?.let { outcome ->
                    completeFlush(session, outcome)
                }
                return
            }
            session.recordDiagnostic(
                OfficeSessionDiagnostics.KIND_SAVE,
                "flush dispatched after page-edit witness op=${op.opId}",
            )
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
        // Precision ops never survive their mount (settle UNKNOWN/REJECTED,
        // data retained; idempotent with deliverTerminal's settle).
        session.precision.onMountTerminal()
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
