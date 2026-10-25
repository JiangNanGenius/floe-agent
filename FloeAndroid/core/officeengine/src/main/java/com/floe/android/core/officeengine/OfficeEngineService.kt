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
    }

    inner class LocalBinder : Binder() {
        val service: OfficeEngineService get() = this@OfficeEngineService
    }

    private inner class Session(
        val request: OfficePreviewRequest,
        val generation: Long,
        val closeAck: android.os.IBinder?,
        val viewerIncarnation: Long,
    ) : EngineBridge, MobileSocket.SocketHost {
        val host = LOActivity(this)
        val cancelled = AtomicBoolean(false)
        @Volatile var state: OfficeViewerState = OfficeViewerState.IDLE
            private set
        @Volatile var webView: COWebView? = null
        @Volatile var retired = false
            private set
        @Volatile var presentationSuperseded = false
        private val readOnlyPolicyQueued = AtomicBoolean(false)
        @Volatile var readOnlyBarrierObserved = false
            private set
        @Volatile var nativeLoadReadOnly: Boolean? = null
            private set
        private var loadForwarded = false
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
                                    tileDeliveryCount > 0 && paintedFrameVerified && readOnlyBarrierObserved && rendererDrawVerified.get()
                                ) {
                                    OfficeDocumentWitness(
                                        widthTwip = witnessWidthTwip,
                                        heightTwip = witnessHeightTwip,
                                        tileDeliveryCount = tileDeliveryCount,
                                        paintedFrameVerified = true,
                                        tilesInvalidateCount = tilesInvalidateCount,
                                        readOnlyBarrierObserved = readOnlyBarrierObserved,
                                        rendererDrawVerified = rendererDrawVerified.get(),
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
            val outcome = OfficeViewerOutcome(
                sessionToken = request.sessionToken,
                closedCleanly = closedCleanly,
                failure = failure,
                message = message,
                witnessWidthTwip = witnessWidthTwip,
                witnessHeightTwip = witnessHeightTwip,
                generation = generation,
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
            if (!readOnlyBarrierObserved && OfficeReadOnlyProtocol.isInteraction(message)) return false
            val outcome = CoolMessageGate.decide(message, readOnly = true)
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
                if (readOnlyPolicyQueued.get()) {
                    nativeLoadReadOnly = loadReadOnly
                    readOnlyBarrierObserved = true
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
                    establishNativeReadOnly()
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
                CoolMessageTriage.Kind.ERROR -> {
                    val detail = String(message, Charsets.UTF_8).removePrefix("error:").trim().take(240)
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
                        -> setState(OfficeViewerState.FAILED)
                        else -> publishProgress()
                    }
                }
                else -> Unit
            }
            val s = socket
            if (s != null) {
                val constrained = when {
                    message.size < 32 && message.toString(Charsets.UTF_8).startsWith("perm:") ->
                        "perm: readonly".toByteArray()
                    message.size < 4096 && message.toString(Charsets.UTF_8).startsWith("filemode:") ->
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

        private fun establishNativeReadOnly() {
            if (!readOnlyPolicyQueued.compareAndSet(false, true)) return
            try {
                controlExecutor.execute {
                    if (retired || cancelled.get() || current !== this@Session) return@execute
                    try {
                        // Real pinned ChildSession command, not a UI-only permission flag.
                        host.postMobileMessageNative(OfficeReadOnlyProtocol.SET_VIEW_READ_ONLY)
                        host.postMobileMessageNative(OfficeReadOnlyProtocol.QUERY_BARRIER)
                    } catch (_: Throwable) {
                        transportFailed("readonly-policy")
                    }
                }
            } catch (_: java.util.concurrent.RejectedExecutionException) {
                transportFailed("readonly-policy-unavailable")
            }
        }

        private fun maybePromoteReady() {
            if (state != OfficeViewerState.AWAITING_FIRST_RENDER) return
            if (witnessWidthTwip <= 0 || witnessHeightTwip <= 0 || tileDeliveryCount <= 0 || !readOnlyBarrierObserved) return
            if (paintedFrameVerified && rendererDrawVerified.get()) {
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
            notifyNotice("jsError", message.take(240))
        }

        override fun onJsDebug(message: String) {
            // Browser debug strings can contain document data. Keep them out of logs.
        }

        override fun hasHardwareKeyboard(): Boolean = this@OfficeEngineService.hasHardwareKeyboard()

        override fun isChromeOS(): Boolean = this@OfficeEngineService.isChromeOS()

        // --- MobileSocket.SocketHost ---

        override fun triggerSend() {
            val view = webView ?: return
            runCatching {
                view.post {
                    runCatching { view.loadUrl("javascript:window.socket.doSend();") }
                }
            }
        }

        override fun transportFailed(reason: String) {
            if (retired) return
            Log.e(TAG, "transport failed ($generation): $reason")
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

        override fun isClosed(): Boolean = retired || cancelled.get()

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

    override fun onBind(intent: Intent?): IBinder = LocalBinder()

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
        session.webView = view
        synchronized(socketHosts) { socketHosts[view]?.delegate = session }
        view.addJavascriptInterface(session.host, JAVASCRIPT_INTERFACE)
        session.pendingLoadUrl?.let { url ->
            session.pendingLoadUrl = null
            view.loadUrl(url)
            session.setState(OfficeViewerState.OPENING)
        }
    }

    fun detachWebView(view: COWebView, sessionToken: String, generation: Long) {
        val session = current ?: return
        if (session.request.sessionToken != sessionToken || session.generation != generation || session.webView !== view) return
        session.webView?.let { view ->
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

        override fun isClosed(): Boolean = delegate?.isClosed() ?: true
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
            runOpen(request, closeAck, viewerIncarnation)
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
        if (session.state != OfficeViewerState.READY_READ_ONLY) return
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
    // Open pipeline (control thread)
    // ------------------------------------------------------------------

    private fun runOpen(
        request: OfficePreviewRequest,
        closeAck: android.os.IBinder?,
        viewerIncarnation: Long,
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
        val session = Session(request, ++lastGeneration, closeAck, viewerIncarnation)
        synchronized(sessionLock) { current = session; session.setState(OfficeViewerState.STAGING) }
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
        // If the view was already attached (rare race), load now; otherwise
        // attachWebView will consume pendingLoadUrl.
        mainHandler.post {
            if (session.retired || session.presentationSuperseded || current !== session) return@post
            val view = session.webView
            if (view != null) {
                session.pendingLoadUrl = null
                runCatching { view.loadUrl(viewerUrl) }
            } else {
                runCatching { listeners.toList().forEach { it.onLoadUrl(request.sessionToken, session.generation, viewerUrl) } }
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
            .append("&permission=readonly")
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
        val thrown = runCatching { session.host.postMobileMessageNative("BYE") }.exceptionOrNull()
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
