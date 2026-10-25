package com.floe.android.core.officeengine

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.res.Configuration
import android.os.Bundle
import android.os.IBinder
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.Floe
import com.floe.android.design.FloeActivityIndicator
import com.floe.android.design.FloeCircleButton
import com.floe.android.design.FloeIcons
import com.floe.android.design.FloeText
import com.floe.android.design.FloeTheme
import com.floe.android.design.FloeThemeMode
import com.floe.android.design.FloeActionSheet
import com.floe.android.design.FloeCapsuleButton
import com.floe.android.design.FloeToolbar
import com.floe.android.design.FloeUnavailableView
import org.libreoffice.androidlib.COWebView

/**
 * The R1 viewer surface: Floe toolbar chrome (Back left, centered title,
 * contextual info action right) over the native engine WebView. The
 * engine/service lifetime is owned by [OfficeEngineService]; the composition
 * can disappear and rebuild without minting a new document or save authority
 * (the same session token reopens through the settle-then-create path).
 *
 * Main owns final visual acceptance and App routing; this chrome reuses the
 * pinned :core:designsystem components already accepted across the app (no
 * default Android toolbar, no new glyph approximations).
 */
class OfficePreviewActivity : ComponentActivity(), OfficeEngineService.OfficeEngineListener {

    private var service: OfficeEngineService? = null
    private var request: OfficePreviewRequest? = null
    private var bound = false
    private var ownerBound = false
    private var ownerConnected = false
    private var sessionBegunFor: OfficePreviewRequest? = null
    private var terminalOutcome: OfficeViewerOutcome? = null
    private var viewerView: COWebView? = null
    private var nativeGeneration = 0L

    /**
     * Parent close-intent capability + the parent-minted opaque viewer
     * incarnation, received ONLY from this Activity's own launch Intent
     * (OfficeCloseAckPolicy). They are handed to the service so an exact
     * user close can be acknowledged back to the App process before the
     * native BYE ends this process. Never written to logs or documents.
     */
    private var closeAck: android.os.IBinder? = null
    private var viewerIncarnation = -1L

    private var progress: OfficeViewerProgress? by mutableStateOf(null)
    private var noticeKey: String? by mutableStateOf(null)
    private var noticeDetail: String? by mutableStateOf(null)
    private var viewerUrl: String? by mutableStateOf(null)
    private var localFailure: Pair<OfficeFailureCode, String?>? by mutableStateOf(null)

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val engine = (binder as? OfficeEngineService.LocalBinder)?.service ?: return
            service = engine
            engine.addListener(this@OfficePreviewActivity)
            engine.setAppearance(appearanceOverride())
            maybeBeginSession()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // Engine process died (crash or reclamation): the exact mount is
            // gone. Originals and staged snapshots remain untouched.
            service = null
            deliverLocalFailure(OfficeFailureCode.PROCESS_LOST, null)
        }
    }

    /**
     * Connection to the inert App-process (main) host owner anchor. The
     * returned Binder carries no commands: connection success itself is the
     * signal that the cached freezer must keep the parent process — owner of
     * the close capability — available while this viewer is visible.
     */
    private val ownerConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            ownerConnected = true
            maybeBeginSession()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            // The App process that owns the close capability died or the
            // binding was lost. No guessed wait and no continue-without-owner:
            // the session can never be closed exactly, so fail honestly.
            ownerConnected = false
            deliverLocalFailure(OfficeFailureCode.PROCESS_LOST, null)
        }
    }

    /**
     * Admit the native session exactly once per request, only after BOTH (a)
     * the engine service in this process is connected and (b) the App-process
     * host owner is bound. Idempotent across connection ordering and engine
     * reconnects; never begins twice for the current request.
     */
    private fun maybeBeginSession() {
        val engine = service ?: return
        if (!ownerConnected) return
        val current = request ?: return
        if (sessionBegunFor === current) return
        sessionBegunFor = current
        engine.beginSession(current, closeAck, viewerIncarnation)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val received = if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(
                OfficeViewerOutcome.EXTRA_REQUEST,
                OfficePreviewRequest::class.java,
            )
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<OfficePreviewRequest>(OfficeViewerOutcome.EXTRA_REQUEST)
        }
        if (received == null) {
            finishWithOutcome(
                OfficeViewerOutcome("", false, OfficeFailureCode.INTERNAL, "missing request", 0, 0),
            )
            return
        }
        // Strict revalidation of anything that crossed a process boundary
        // (Main review 2026-10-26): shape rules again, and the parcelled
        // format must agree with the staged path; parse failures are kept.
        val valid = received.revalidated()
        if (valid.isFailure) {
            val exception = valid.exceptionOrNull() as? OfficeException
            finishWithOutcome(
                OfficeViewerOutcome(
                    sessionToken = received.sessionToken,
                    closedCleanly = false,
                    failure = exception?.code ?: OfficeFailureCode.INTERNAL,
                    message = exception?.message,
                    witnessWidthTwip = 0,
                    witnessHeightTwip = 0,
                ),
            )
            return
        }
        request = valid.getOrNull()

        // Capability extras are inert references owned by the launching App
        // process; read once from our own non-exported launch Intent. An
        // IBinder is NOT a Parcelable: it travels through the Bundle's
        // putBinder/getBinder pair (API 18+), never the getParcelable family.
        viewerIncarnation = intent.getLongExtra(OfficeCloseAckPolicy.EXTRA_VIEWER_INCARNATION, -1L)
        closeAck = intent.extras?.getBinder(OfficeCloseAckPolicy.EXTRA_CLOSE_ACK)

        if (!OfficeWebViewDirectory.ensureOnce()) {
            deliverLocalFailure(OfficeFailureCode.WEBVIEW_ISOLATION_FAILED, null)
            return
        }

        // Bind the App-process (main) host owner first: BIND_ADJUST_WITH_ACTIVITY
        // keeps the parent — owner of the close capability — unfrozen while
        // this viewer is visible. Inert Binder, same-UID, never exported.
        val ownerStart = Intent(this, OfficeHostOwnerService::class.java)
        ownerBound = bindService(
            ownerStart,
            ownerConnection,
            Context.BIND_AUTO_CREATE or Context.BIND_ADJUST_WITH_ACTIVITY,
        )
        if (!ownerBound) {
            deliverLocalFailure(OfficeFailureCode.INTERNAL, "host owner unavailable")
            return
        }

        val start = Intent(this, OfficeEngineService::class.java)
        bound = bindService(start, connection, Context.BIND_AUTO_CREATE)
        if (!bound) {
            deliverLocalFailure(OfficeFailureCode.INTERNAL, "engine service unavailable")
            return
        }

        setContent {
            val theme = runCatching { FloeThemeMode.valueOf(intent.getStringExtra("com.floe.office.THEME_MODE").orEmpty()) }
                .getOrDefault(FloeThemeMode.AUTO)
            FloeTheme(themeMode = theme) {
                OfficeWindowAppearance(this, theme)
                OfficeViewerScreen(
                    title = request?.displayName.orEmpty(),
                    progress = progress,
                    noticeKey = noticeKey,
                    noticeDetail = noticeDetail,
                    failure = localFailure,
                    viewerUrl = viewerUrl,
                    onBack = ::performBack,
                    onOpenNotices = {
                        startActivity(Intent(this, OfficeNoticesActivity::class.java).apply {
                            putExtra("com.floe.office.THEME_MODE", intent.getStringExtra("com.floe.office.THEME_MODE"))
                        })
                    },
                    createView = { context -> service?.newViewerWebView(context) },
                    onViewReady = { view ->
                        val token = request?.sessionToken
                        if (view != null && token != null) {
                            viewerView = view
                            service?.attachWebView(view, token, nativeGeneration)
                        } else if (view == null) {
                            deliverLocalFailure(OfficeFailureCode.WEBVIEW_ISOLATION_FAILED, null)
                        }
                    },
                    onViewLeaving = { view ->
                        val token = request?.sessionToken
                        if (token != null) service?.detachWebView(view, token, nativeGeneration)
                        if (viewerView === view) viewerView = null
                        view.destroy()
                    },
                )
            }
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = performBack()
        })
    }

    private fun performBack() {
        val token = request?.sessionToken
        val engine = service
        if (token == null || engine == null) {
            finishWithOutcome(
                terminalOutcome ?: OfficeViewerOutcome(token.orEmpty(), true, null, null, 0, 0),
            )
            return
        }
        if (engine.isMobileWizardVisible(token)) {
            engine.sendMobileWizardBack(token)
        } else {
            engine.requestClose(token, "user-back", userInitiated = true)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val dark = newConfig.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES
        service?.setAppearance(appearanceOverride())
        service?.onNightModeChanged(appearanceOverride() ?: dark)
    }

    private fun appearanceOverride(): Boolean? = when (intent.getStringExtra("com.floe.office.THEME_MODE")) {
        "LIGHT" -> false
        "DARK" -> true
        else -> null
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) request?.sessionToken?.let { service?.refreshVisibleFrame(it, nativeGeneration) }
    }

    override fun onDestroy() {
        if (bound) {
            runCatching { unbindService(connection) }
            bound = false
        }
        if (ownerBound) {
            runCatching { unbindService(ownerConnection) }
            ownerBound = false
        }
        ownerConnected = false
        service?.removeListener(this)
        super.onDestroy()
    }

    // --- OfficeEngineService.OfficeEngineListener (main thread) ---

    override fun onProgress(progress: OfficeViewerProgress) {
        if (!accepts(progress.sessionToken, progress.generation)) return
        this.progress = progress
        if (progress.state == OfficeViewerState.READY_READ_ONLY && noticeKey == "awaitingRender") {
            noticeKey = null
            noticeDetail = null
        }
    }

    private fun accepts(token: String, generation: Long): Boolean {
        if (isDestroyed || isFinishing || token != request?.sessionToken || generation < nativeGeneration) return false
        if (generation > nativeGeneration) nativeGeneration = generation
        return true
    }

    override fun onNotice(sessionToken: String, generation: Long, key: String, detail: String?) {
        if (!accepts(sessionToken, generation)) return
        noticeKey = key
        noticeDetail = detail
    }

    override fun onLoadUrl(sessionToken: String, generation: Long, url: String) {
        if (!accepts(sessionToken, generation)) return
        viewerUrl = url
    }

    /** Renderer success is separately verified by the owned canvas hook.
     * Here the visual-state callback and PixelCopy SUCCESS confirm that the
     * same live WebView surface reached the compositor. Pixel variance is
     * deliberately irrelevant: a legitimate blank document must pass.
     */
    override fun onPaintProbeRequested(sessionToken: String, generation: Long) {
        if (!accepts(sessionToken, generation)) return
        val view = viewerView
        if (view == null) { service?.reportPaintProbe(sessionToken, generation, false); return }
        val engine = service ?: return
        fun currentFrame(): Boolean = viewerView === view && !isDestroyed && !isFinishing &&
            request?.sessionToken == sessionToken && nativeGeneration == generation &&
            view.isAttachedToWindow && view.isShown && view.width >= 48 && view.height >= 48 && hasWindowFocus()
        fun answer(passed: Boolean) {
            if (viewerView === view && !isDestroyed && request?.sessionToken == sessionToken && nativeGeneration == generation)
                engine.reportPaintProbe(sessionToken, generation, passed)
        }
        if (!currentFrame()) { answer(false); return }
        try {
            view.postVisualStateCallback(generation, object : android.webkit.WebView.VisualStateCallback() {
                override fun onComplete(requestId: Long) {
                    if (!currentFrame()) { answer(false); return }
                    view.postOnAnimation frame@ {
                        if (!currentFrame()) { answer(false); return@frame }
                        val location = IntArray(2)
                        view.getLocationInWindow(location)
                        val width = minOf(view.width, 720)
                        val height = minOf(view.height, 480)
                        val x = location[0] + (view.width - width) / 2
                        val y = location[1] + (view.height - height) / 2
                        val bitmap = android.graphics.Bitmap.createBitmap(width, height, android.graphics.Bitmap.Config.ARGB_8888)
                        try {
                            android.view.PixelCopy.request(window, android.graphics.Rect(x, y, x + width, y + height), bitmap,
                                { result ->
                                    bitmap.recycle()
                                    answer(result == android.view.PixelCopy.SUCCESS && currentFrame())
                                }, android.os.Handler(mainLooper))
                        } catch (_: Exception) {
                            bitmap.recycle()
                            answer(false)
                        }
                    }
                }
            })
        } catch (_: Exception) { answer(false) }
    }

    override fun onTerminal(outcome: OfficeViewerOutcome) {
        if (outcome.sessionToken != request?.sessionToken || isDestroyed || isFinishing) return
        if (outcome.generation != 0L && !accepts(outcome.sessionToken, outcome.generation)) return
        finishWithOutcome(outcome)
    }

    private fun deliverLocalFailure(code: OfficeFailureCode, message: String?) {
        localFailure = code to message
        finishWithOutcome(
            OfficeViewerOutcome(
                sessionToken = request?.sessionToken.orEmpty(),
                closedCleanly = false,
                failure = code,
                message = message,
                witnessWidthTwip = 0,
                witnessHeightTwip = 0,
            ),
        )
    }

    private fun finishWithOutcome(outcome: OfficeViewerOutcome) {
        if (terminalOutcome != null) return
        terminalOutcome = outcome
        val data = Intent().apply {
            putExtra(OfficeViewerOutcome.EXTRA_SESSION_TOKEN, outcome.sessionToken)
            putExtra(OfficeViewerOutcome.EXTRA_CLOSED_CLEANLY, outcome.closedCleanly)
            outcome.failure?.let { failure ->
                putExtra(OfficeViewerOutcome.EXTRA_FAILURE_CODE, failure.name)
                outcome.message?.let { putExtra(OfficeViewerOutcome.EXTRA_FAILURE_MESSAGE, it) }
            }
            putExtra(OfficeViewerOutcome.EXTRA_WITNESS_WIDTH, outcome.witnessWidthTwip)
            putExtra(OfficeViewerOutcome.EXTRA_WITNESS_HEIGHT, outcome.witnessHeightTwip)
            putExtra(OfficeViewerOutcome.EXTRA_GENERATION, outcome.generation)
        }
        val resultCode = if (outcome.failure == null) RESULT_OK else RESULT_CANCELED
        setResult(resultCode, data)
        finish()
    }

    companion object {
        internal fun intentFor(context: Context, request: OfficePreviewRequest): Intent =
            Intent(context, OfficePreviewActivity::class.java).apply {
                putExtra(OfficeViewerOutcome.EXTRA_REQUEST, request)
            }
    }
}

/**
 * Viewer layout: compact Floe toolbar row (Back left, title, contextual info
 * action right), the document content area (engine WebView) below, an honest
 * progress row outside the document viewport until real paint witnesses arrive, an optional notice line
 * for refused routes, and a terminal error view. Native content fills only
 * the content area and never covers the host toolbar.
 */
@Composable
private fun OfficeViewerScreen(
    title: String,
    progress: OfficeViewerProgress?,
    noticeKey: String?,
    noticeDetail: String?,
    failure: Pair<OfficeFailureCode, String?>?,
    viewerUrl: String?,
    onBack: () -> Unit,
    onOpenNotices: () -> Unit,
    createView: (Context) -> COWebView?,
    onViewReady: (COWebView?) -> Unit,
    onViewLeaving: (COWebView) -> Unit,
) {
    val state = progress?.state ?: OfficeViewerState.IDLE
    var showInfo by remember { mutableStateOf(false) }
    FloeActionSheet(visible = showInfo, onDismiss = { showInfo = false }, maxCardWidth = 420.dp) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            FloeText(stringResource(R.string.office_viewer_readonly_cd), style = Floe.typography.toolbarTitle)
            FloeText(stringResource(R.string.office_viewer_preview_info), color = Floe.colors.secondaryLabel)
            FloeCapsuleButton(stringResource(R.string.office_viewer_notices), onClick = {
                showInfo = false
                onOpenNotices()
            })
            FloeCapsuleButton(stringResource(R.string.office_viewer_done), onClick = { showInfo = false })
        }
    }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Floe.colors.readingSurface)
            .safeDrawingPadding(),
    ) {
        FloeToolbar(
            title = title,
            navigation = {
                FloeCircleButton(
                    icon = FloeIcons.ChevronBack,
                    contentDescription = stringResource(R.string.office_viewer_back_cd),
                    onClick = onBack,
                )
            },
            actions = {
                FloeCircleButton(
                    icon = FloeIcons.InfoCircle,
                    contentDescription = stringResource(R.string.office_viewer_readonly_cd),
                    onClick = { showInfo = true },
                )
            },
            showHairline = true,
        )
        // Honest lifecycle representation (Main decision 2026-10-26): the
        // opening row is shown only while a document genuinely still opens.
        // FAILED keeps the notice row with the actual error detail; CLOSING
        // waits on the bounded close/reclaim path. Neither may keep claiming
        // "Opening" indefinitely. Same rows and layout, state condition only.
        if (failure == null && state != OfficeViewerState.READY_READ_ONLY &&
            state != OfficeViewerState.FAILED && state != OfficeViewerState.CLOSING
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().heightIn(min = 36.dp).padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FloeActivityIndicator(modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = stringResource(R.string.office_viewer_opening),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                )
            }
        }
        noticeKey?.let { key ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 40.dp)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                NoticeGlyph(key)
                Spacer(Modifier.width(10.dp))
                FloeText(
                    text = noticeText(key, noticeDetail),
                    style = Floe.typography.metadata,
                    color = Floe.colors.secondaryLabel,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        ) {
            val failureState = failure
            if (failureState != null) {
                FloeUnavailableView(
                    icon = FloeIcons.WarningTriangle,
                    title = stringResource(R.string.office_viewer_failed_title),
                    description = failureMessage(failureState.first, failureState.second),
                    modifier = Modifier.align(Alignment.Center),
                )
            } else {
                val url = viewerUrl
                if (url != null) {
                    AndroidView(
                        factory = { context ->
                            val view = createView(context)
                            onViewReady(view)
                            view ?: android.view.View(context)
                        },
                        modifier = Modifier.fillMaxSize(),
                        onRelease = { view ->
                            if (view is COWebView) onViewLeaving(view)
                        },
                    )

                }
            }
        }
    }
}

@Composable
private fun NoticeGlyph(key: String) {
    val icon = when (key) {
        "loadError", "transportFailed", "jsError" -> FloeIcons.WarningTriangle
        "macroBlocked" -> FloeIcons.ShieldAlert
        else -> FloeIcons.InfoCircle
    }
    Image(
        imageVector = icon,
        contentDescription = null,
        colorFilter = ColorFilter.tint(Floe.colors.secondaryLabel),
        modifier = Modifier.size(18.dp),
    )
}

@Composable
private fun noticeText(key: String, detail: String?): String {
    val base = when (key) {
        "saveRouteUnavailable" -> stringResource(R.string.office_notice_save_unavailable)
        "editModeBlocked" -> stringResource(R.string.office_notice_readonly_only)
        "linkBlocked" -> stringResource(R.string.office_notice_link_blocked)
        "macroBlocked" -> stringResource(R.string.office_notice_macro_blocked)
        "transportFailed" -> stringResource(R.string.office_notice_transport_failed)
        "loadError" -> stringResource(R.string.office_notice_load_error)
        "jsError" -> stringResource(R.string.office_notice_internal_error)
        "awaitingRender" -> stringResource(R.string.office_notice_awaiting_render)
        else -> stringResource(R.string.office_notice_internal_error)
    }
    return base
}

@Composable
private fun failureMessage(code: OfficeFailureCode, detail: String?): String {
    val base = when (code) {
        OfficeFailureCode.STAGED_FILE_MISSING -> stringResource(R.string.office_fail_missing)
        OfficeFailureCode.STAGED_FILE_MISMATCH -> stringResource(R.string.office_fail_mismatch)
        OfficeFailureCode.UNSUPPORTED_FORMAT -> stringResource(R.string.office_fail_format)
        OfficeFailureCode.PAYLOAD_PREPARE_FAILED -> stringResource(R.string.office_fail_prepare)
        OfficeFailureCode.NATIVE_LOAD_FAILED -> stringResource(R.string.office_fail_native)
        OfficeFailureCode.ENGINE_BUSY -> stringResource(R.string.office_fail_busy)
        OfficeFailureCode.WEBVIEW_ISOLATION_FAILED -> stringResource(R.string.office_fail_isolation)
        OfficeFailureCode.LOAD_ERROR -> stringResource(R.string.office_fail_load)
        OfficeFailureCode.TRANSPORT_FAILURE -> stringResource(R.string.office_fail_transport)
        OfficeFailureCode.ROUTE_UNAVAILABLE -> stringResource(R.string.office_fail_route)
        OfficeFailureCode.SESSION_CANCELLED -> stringResource(R.string.office_fail_cancelled)
        OfficeFailureCode.PROCESS_LOST -> stringResource(R.string.office_fail_process_lost)
        OfficeFailureCode.INTERNAL -> stringResource(R.string.office_fail_internal)
    }
    return base
}
