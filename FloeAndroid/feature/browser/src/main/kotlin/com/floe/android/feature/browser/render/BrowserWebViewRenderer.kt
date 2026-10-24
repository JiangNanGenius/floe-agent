// SPDX-License-Identifier: MPL-2.0
package com.floe.android.feature.browser.render

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.DownloadListener
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import com.floe.android.feature.browser.api.BrowserServicePort
import com.floe.android.feature.browser.api.BrowserWebViewGateway
import com.floe.android.feature.browser.api.RendererScreenshot
import com.floe.android.feature.browser.api.RendererTabState
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Dumb android.webkit renderer/executor for one task's browser session.
 *
 * HARD invariants (enforced structurally, not aspirationally):
 *  - NEVER `addJavascriptInterface`: page code has no bridge into the app.
 *    The only script channel is `evaluateJavascript` with expressions built
 *    by Swift from whitelisted admitted actions (JSON-escaped), and its
 *    replies flow back as UNTRUSTED data through Main's JNI ingress.
 *  - Navigation authorization is Swift's: every resource request (main
 *    frame, iframe, redirect hop, subresource) is re-checked against the
 *    Swift `BrowserURLPolicy` through [BrowserServiceHooks.policyAllows] on
 *    the WebView's network thread. A denial returns an empty 403 response —
 *    a page (or a redirect/iframe) can never grant itself loopback or
 *    private-network access. Timeouts fail closed.
 *  - Login state lives in the real, process-global WebView cookie/data
 *    storage (preserved, not faked); per-profile isolation is a documented
 *    platform limitation (BrowserPlatformLimitations), never promised.
 *  - Background tabs get a REAL viewport through the offscreen surface host
 *    (Main attaches the Activity container): tabs are laid out at the
 *    1024x768-dp surface like the iOS original, so semantic observation
 *    works while another task's panel is on screen. View composition never
 *    creates authority and never destroys a tab.
 *  - Site permission prompts and SSL errors are refused (no silent grants);
 *    JavaScript dialogs are dismissed (no native-modal hijack). Human
 *    interaction happens in the projected panel only.
 */
public class BrowserWebViewRenderer(
    private val context: Context,
    private val service: BrowserServicePort,
    private val hooks: BrowserServiceHooks,
) : BrowserWebViewGateway {
    private val main = Handler(Looper.getMainLooper())
    private val popupTokens = AtomicLong(1)

    private companion object {
        /** A window.open that never issues its first request is decided
         * with an honest empty URL (blocked natively). */
        const val POPUP_CAPTURE_TIMEOUT_MILLIS = 2_500L
    }

    private class Slot(
        val tabId: String,
        var webView: WebView? = null,
        var probeSource: String = "",
        var pendingLoad: String? = null,
        var state: RendererTabState = RendererTabState(null, null, false, 1.0, 1.0, 0.0, 0.0),
        var projected: Boolean = false,
        /** Owner-tracked loading truth. Android's WebView exposes no public
         * `isLoading`; this mirrors the REAL bound page callbacks
         * (onPageStarted → true; onPageFinished / main-frame error /
         * SSL cancel / stopLoading / surface replacement → false). */
        var loading: Boolean = false,
    )

    private val slots = ConcurrentHashMap<String, Slot>()
    private val surfaces = ConcurrentHashMap<Long, WebView>()
    private var released = AtomicBoolean(false)

    /** Offscreen host installed by Main's App composition (Activity-owned
     * container). Without it, non-projected tabs still exist but viewport
     * capture/state reflect the last laid-out surface honestly (the probe's
     * degraded snapshot), never a synthetic page. */
    private var offscreenHost: ViewGroup? = null

    public fun attachOffscreenHost(host: ViewGroup) {
        main.post {
            offscreenHost = host
            // Lay out any tab surfaces that were created before the host.
            slots.values.forEach { adoptIntoHost(it) }
        }
    }

    public fun detachOffscreenHost() {
        main.post { offscreenHost = null }
    }

    // MARK: - Gateway (called from Main's JNI bridge, any thread)

    override fun createTab(tabId: String, probeSource: String) = onMain {
        if (released.get() || slots.containsKey(tabId)) return@onMain
        val slot = Slot(tabId = tabId, probeSource = probeSource)
        slots[tabId] = slot
        val view = newWebView(tabId)
        slot.webView = view
        adoptIntoHost(slot)
        slot.pendingLoad?.let { url -> slot.pendingLoad = null; view.loadUrl(url) }
    }

    override fun destroyTab(tabId: String) = onMain {
        val slot = slots.remove(tabId) ?: return@onMain
        slot.webView?.let { view ->
            (view.parent as? ViewGroup)?.removeView(view)
            runCatching { view.stopLoading() }
            runCatching { view.destroy() }
        }
    }

    override fun navigate(tabId: String, url: String) = onMain {
        val slot = slots[tabId]
        val view = slot?.webView
        if (view == null) {
            slot?.pendingLoad = url
        } else {
            // Swift already validated this URL; onInterceptRequest re-checks
            // it (and every redirect hop) against the policy anyway.
            view.loadUrl(url)
        }
    }

    override fun goBack(tabId: String) = onMain { slots[tabId]?.webView?.goBack() }
    override fun goForward(tabId: String) = onMain { slots[tabId]?.webView?.goForward() }
    override fun reload(tabId: String) = onMain { slots[tabId]?.webView?.reload() }
    override fun stopLoading(tabId: String) = onMain {
        val slot = slots[tabId] ?: return@onMain
        slot.webView?.stopLoading()
        // An owner-initiated stop ends the load and the WebView fires no
        // completion callback for it: reset the tracked truth here.
        slot.loading = false
    }

    /** Synchronous read used by the JNI proxy: main-thread getters with a
     * short bounded wait; falls back to the last trusted cached facts. A
     * stale surface never grants capability — it only describes a page. */
    override fun state(tabId: String): RendererTabState? {
        val slot = slots[tabId] ?: return null
        if (Looper.myLooper() == Looper.getMainLooper()) return refreshState(slot)
        val latch = CountDownLatch(1)
        var fresh: RendererTabState? = null
        main.post {
            fresh = refreshState(slot)
            latch.countDown()
        }
        return if (latch.await(150, TimeUnit.MILLISECONDS)) fresh ?: slot.state else slot.state
    }

    override fun evaluate(tabId: String, expression: String, timeoutMs: Int, reply: (String?) -> Unit) {
        val once = AtomicBoolean(false)
        val deliver: (String?) -> Unit = { value ->
            if (once.compareAndSet(false, true)) reply(value)
        }
        main.post {
            val view = slots[tabId]?.webView
            if (view == null || released.get()) {
                deliver(null)
                return@post
            }
            runCatching {
                view.evaluateJavascript(expression) { value -> deliver(value ?: "null") }
            }.onFailure { deliver(null) }
        }
        // The Swift side races its own deadline; this local deadline only
        // guarantees the JNI reply callback fires exactly once so no bridge
        // continuation is left dangling.
        main.postDelayed({ deliver(null) }, (timeoutMs.toLong() + 500L).coerceAtMost(60_000L))
    }

    /** Main's future popup-propagation seam: bind a platform-created popup
     * WebView into a Swift-minted tab, replacing the slot's auto-surface.
     * G04's own onCreateWindow path never calls this (documented delta); it
     * exists so a later decision can propagate real window handles without
     * any authority change — Swift admitted the URL before this is reached. */
    override fun adoptPopupSurface(tabId: String, surfaceToken: Long) = onMain {
        val slot = slots[tabId] ?: return@onMain
        val incoming = surfaces.remove(surfaceToken) ?: return@onMain
        slot.webView?.let { old ->
            (old.parent as? ViewGroup)?.removeView(old)
            runCatching { old.destroy() }
            // The replaced surface's in-flight load ends with it; the adopted
            // surface reports its own callbacks from here on.
            slot.loading = false
        }
        configureSurface(incoming, tabId)
        slot.webView = incoming
        adoptIntoHost(slot)
        slot.pendingLoad?.let { url ->
            slot.pendingLoad = null
            incoming.loadUrl(url)
        }
    }

    override fun captureScreenshot(tabId: String, reply: (RendererScreenshot?) -> Unit) {
        val once = AtomicBoolean(false)
        main.post {
            val slot = slots[tabId]
            val view = slot?.webView
            if (view == null || released.get() || view.width <= 0 || view.height <= 0) {
                if (once.compareAndSet(false, true)) reply(null)
                return@post
            }
            var bitmap: Bitmap? = null
            try {
                bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
                view.draw(Canvas(bitmap))
                val jpeg = java.io.ByteArrayOutputStream(128 * 1024)
                bitmap.compress(Bitmap.CompressFormat.JPEG, 78, jpeg)
                val bytes = jpeg.toByteArray()
                val shot = RendererScreenshot(
                    jpeg = bytes,
                    pixelWidth = bitmap.width,
                    pixelHeight = bitmap.height,
                    state = refreshState(slot),
                )
                if (once.compareAndSet(false, true)) reply(shot)
            } catch (_: Exception) {
                if (once.compareAndSet(false, true)) reply(null)
            } finally {
                bitmap?.recycle()
            }
        }
    }

    override fun release() = onMain {
        if (!released.compareAndSet(false, true)) return@onMain
        slots.values.forEach { slot ->
            slot.webView?.let { view ->
                (view.parent as? ViewGroup)?.removeView(view)
                runCatching { view.stopLoading() }
                runCatching { view.destroy() }
            }
        }
        slots.clear()
        surfaces.values.forEach { runCatching { it.destroy() } }
        surfaces.clear()
        runCatching { CookieManager.getInstance().flush() }
    }

    /** Flush real cookie/storage state (Main calls on background/pause). */
    public fun flushPersistentState() {
        runCatching { CookieManager.getInstance().flush() }
    }

    // MARK: - Composition interop (main thread; NO authority, NO destruction)

    /** The panel's AndroidView factory calls this to project the ACTIVE tab.
     * Re-parenting only; the tab's lifetime stays Swift-owned. */
    public fun surfaceForProjection(tabId: String): WebView? {
        check(Looper.myLooper() == Looper.getMainLooper())
        val slot = slots[tabId] ?: return null
        val view = slot.webView ?: return null
        (view.parent as? ViewGroup)?.removeView(view)
        slot.projected = true
        return view
    }

    /** Compose disposed the AndroidView: move the surface back to the
     * offscreen host. The tab keeps running either way. */
    public fun releaseFromProjection(tabId: String) = onMain {
        val slot = slots[tabId] ?: return@onMain
        slot.projected = false
        adoptIntoHost(slot)
    }

    /** Popups: WebChromeClient asks Swift; the decision binds a platform
     * surface token (a real window.open-created WebView would be adopted;
     * G04 always routes popups into ordinary session tabs, and the token map
     * is retained for Main's future propagation decision). */
    public fun pendingPopupSurfaceToken(view: WebView?): Long {
        val token = popupTokens.getAndIncrement()
        if (view != null) surfaces[token] = view
        return token
    }

    public fun discardPopupSurface(token: Long) = onMain {
        val view = surfaces.remove(token)
        runCatching { view?.destroy() }
    }

    // MARK: - Internals

    private fun onMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    private fun refreshState(slot: Slot): RendererTabState {
        val view = slot.webView
        val fresh = if (view == null) {
            slot.state
        } else {
            RendererTabState(
                url = view.url,
                title = view.title,
                isLoading = slot.loading,
                viewportWidth = if (view.width > 0) view.width.toDouble() else 1024.0 * view.resources.displayMetrics.density.toDouble(),
                viewportHeight = if (view.height > 0) view.height.toDouble() else 768.0 * view.resources.displayMetrics.density.toDouble(),
                scrollX = view.scrollX.toDouble(),
                scrollY = view.scrollY.toDouble(),
            )
        }
        slot.state = fresh
        return fresh
    }

    private fun adoptIntoHost(slot: Slot) {
        val view = slot.webView ?: return
        if (slot.projected) return
        val host = offscreenHost
        if (host == null) {
            // No host yet: lay the view out at the standard offscreen
            // viewport so measurement is honest; rendering may be degraded
            // until Main attaches the host (documented limitation).
            val density = view.resources.displayMetrics.density
            val w = (1024 * density).toInt()
            val h = (768 * density).toInt()
            view.measure(
                View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY),
            )
            view.layout(0, 0, w, h)
            return
        }
        (view.parent as? ViewGroup)?.removeView(view)
        val density = view.resources.displayMetrics.density
        val params = ViewGroup.LayoutParams((1024 * density).toInt(), (768 * density).toInt())
        view.layoutParams = params
        runCatching { host.addView(view) }
    }

    private fun newWebView(tabId: String): WebView = configureSurface(WebView(context), tabId)

    /** The single place that gives EVERY surface (created or adopted) the
     * hard rules: JS + DOM storage on, file/content access off, popup
     * admission through WebChromeClient, per-request policy re-gating,
     * download forwarding and cookie-backed real login storage. Adoption
     * without this would silently create an ungated page. */
    private fun configureSurface(view: WebView, tabId: String): WebView {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            // Real cookies persist in the process-global storage: login
            // state is preserved, not faked (BrowserPlatformLimitations
            // documents the isolation ceiling honestly).
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            // Popups surface through onCreateWindow where Swift decides;
            // without this, window.open would silently hijack the current
            // tab instead of entering the admission path.
            setSupportMultipleWindows(true)
            cacheMode = android.webkit.WebSettings.LOAD_DEFAULT
            // The real public WebSettings pair isAlgorithmicDarkeningAllowed /
            // setAlgorithmicDarkeningAllowed (API 33): keep the WebView's own
            // darkening policy off so pages render exactly as on iOS.
            if (android.os.Build.VERSION.SDK_INT >= 33) {
                isAlgorithmicDarkeningAllowed = false
            }
        }
        view.setBackgroundColor(0xFFFFFFFF.toInt())
        view.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                super.onPageStarted(view, url, favicon)
                slots[tabId]?.loading = true
                service.ingestLifecycle(hooks.lifecycleEventJson("loadStarted", tabId))
                injectProbe(tabId)
            }

            override fun onPageCommitVisible(view: WebView?, info: String?) {
                super.onPageCommitVisible(view, info)
                // The exact iOS didCommit role: document identity rotates so
                // pre-navigation refs/evidence die with the old document.
                service.ingestLifecycle(hooks.lifecycleEventJson("loadCommitted", tabId))
                injectProbe(tabId)
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                slots[tabId]?.loading = false
                injectProbe(tabId)
                val finishedUrl = url ?: view?.url
                val title = view?.title
                service.ingestLifecycle(hooks.lifecycleFinishedJson(tabId, finishedUrl, title))
            }

            override fun onReceivedError(
                view: WebView?,
                request: WebResourceRequest?,
                error: WebResourceError?,
            ) {
                super.onReceivedError(view, request, error)
                if (request?.isForMainFrame == true) {
                    // A failed main-frame load ends that load for real; some
                    // WebView builds never follow it with onPageFinished.
                    slots[tabId]?.loading = false
                    if (error != null) {
                        service.ingestLifecycle(
                            hooks.lifecycleFailedJson(
                                tabId = tabId,
                                domain = "webview",
                                code = error.errorCode,
                                description = error.description?.toString() ?: "load failed",
                            ),
                        )
                    }
                }
            }

            override fun onReceivedHttpError(
                view: WebView?,
                request: WebResourceRequest?,
                errorResponse: WebResourceResponse?,
            ) {
                super.onReceivedHttpError(view, request, errorResponse)
                if (request?.isForMainFrame == true) {
                    service.ingestLifecycle(
                        hooks.lifecycleFailedJson(
                            tabId = tabId,
                            domain = "http",
                            code = errorResponse?.statusCode ?: -1,
                            description = errorResponse?.reasonPhrase ?: "http error",
                        ),
                    )
                }
            }

            override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
                // No silent TLS grants: the original delegate policy stays.
                handler?.cancel()
                // Cancelling ends the main-frame load with no finish callback.
                slots[tabId]?.loading = false
            }

            /** The navigation gate for EVERY frame and redirect hop. Runs on
             * the WebView network thread (never UI), so a bounded synchronous
             * Swift policy call is safe. Fail closed. */
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                val url = request?.url?.toString() ?: return null
                val allowed = hooks.policyAllowsSync(tabId = tabId, url = url, isMainFrame = request.isForMainFrame)
                if (allowed) return null
                return WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), java.io.ByteArrayInputStream(ByteArray(0)))
            }
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: android.webkit.PermissionRequest?) {
                // Sites never receive device permissions silently.
                runCatching { request?.deny() }
            }

            override fun onCreateWindow(
                view: WebView?,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: android.os.Message?,
            ): Boolean {
                // Popups/new windows are Swift decisions. The platform's
                // throwaway window is NEVER propagated to the app UI: it is
                // routed into one popup STAGING surface that answers every
                // request (its main frame included) with a local 403, so no
                // popup content is ever fetched before Swift admits the URL;
                // staging exists only to capture the window.open target
                // honestly and is destroyed right after. Swift then admits
                // the URL into an ordinary session tab or blocks it.
                // window.open handles are not propagated (documented delta);
                // shouldInterceptRequest re-gates every resource that tab
                // then requests, so a page cannot conjure access either.
                if (released.get()) return false
                val requestId = java.util.UUID.randomUUID().toString()
                val transport = resultMsg?.obj as? WebView.WebViewTransport
                if (transport == null) {
                    hooks.requestPopup(tabId, requestId, "")
                    return true
                }
                transport.webView = stagePopupCapture(tabId, requestId)
                resultMsg?.sendToTarget()
                return true
            }

            override fun onJsAlert(
                view: WebView?, url: String?, message: String?, result: android.webkit.JsResult?,
            ): Boolean {
                result?.cancel()
                return true
            }

            override fun onJsConfirm(
                view: WebView?, url: String?, message: String?, result: android.webkit.JsResult?,
            ): Boolean {
                result?.cancel()
                return true
            }

            override fun onJsPrompt(
                view: WebView?, url: String?, message: String?, defaultValue: String?, result: android.webkit.JsPromptResult?,
            ): Boolean {
                result?.cancel()
                return true
            }
        }
        view.setDownloadListener(DownloadListener { url, userAgent, contentDisposition, mimeType, contentLength ->
            service.requestDownload(
                requestId = java.util.UUID.randomUUID().toString(),
                queryJson = hooks.downloadQueryJson(tabId, url, userAgent, contentDisposition, mimeType, contentLength),
            )
        })
        return view
    }


    /**
     * One throwaway popup STAGING surface (UI thread creation, never
     * attached to a window, JS disabled). Its WebViewClient answers EVERY
     * request — including the main frame — with a local empty 403, so
     * nothing is fetched; its only job is to observe the window.open target
     * URL from the platform's own request stream and deliver it (exactly
     * once, with a bounded fallback) to the Swift popup decision. Then the
     * staging surface is destroyed. A decision with an empty URL is blocked
     * natively (fail closed), never retried from page content.
     */
    private fun stagePopupCapture(sourceTabId: String, requestId: String): WebView {
        val staging = WebView(context)
        staging.settings.apply {
            javaScriptEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            domStorageEnabled = false
            setSupportMultipleWindows(false)
        }
        val delivered = AtomicBoolean(false)
        fun deliver(url: String?) {
            if (!delivered.compareAndSet(false, true)) return
            main.post { runCatching { staging.destroy() } }
            hooks.requestPopup(sourceTabId, requestId, url ?: "")
        }
        staging.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?, request: WebResourceRequest?,
            ): WebResourceResponse {
                if (request?.isForMainFrame == true) deliver(request.url?.toString())
                return WebResourceResponse(
                    "text/plain", "utf-8", 403, "Forbidden", emptyMap(),
                    java.io.ByteArrayInputStream(ByteArray(0)),
                )
            }

            override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
                deliver(url ?: view?.url)
            }
        }
        // Bounded fallback: a window.open that never produces a request is
        // decided with an honest empty URL (Swift blocks it typed).
        main.postDelayed({ deliver(null) }, POPUP_CAPTURE_TIMEOUT_MILLIS)
        return staging
    }

    private fun injectProbe(tabId: String) {
        val slot = slots[tabId] ?: return
        val source = slot.probeSource
        if (source.isEmpty()) return
        // Re-injection is idempotent (the IIFE returns early when installed);
        // document-start support varies by WebView build (documented).
        slot.webView?.evaluateJavascript("(function{$source})();", null)
    }
}

/**
 * Narrow host hooks the renderer needs, implemented by Main's JNI adapter:
 *  - [policyAllowsSync] → Swift `BrowserURLPolicy.validate` (+ preview
 *    allocation logic), bounded (<=3 s), FAIL CLOSED on timeout/error.
 *  - lifecycle JSON builders keep the wire shape identical to Swift
 *    `BrowserRendererLifecycleEvent`.
 *  - [requestPopup] → Swift `popupDecision`; the staging surface delivers
 *    the captured window.open URL (or "" when none ever appeared, which
 *    Swift blocks typed) and is destroyed. Admitted popups arrive back as
 *    ordinary renderer tickets — G04 opens them as ordinary session tabs.
 */
public interface BrowserServiceHooks {
    public fun policyAllowsSync(tabId: String, url: String, isMainFrame: Boolean): Boolean
    public fun lifecycleEventJson(kind: String, tabId: String): String
    public fun lifecycleFinishedJson(tabId: String, url: String?, title: String?): String
    public fun lifecycleFailedJson(tabId: String, domain: String, code: Int, description: String): String
    public fun requestPopup(tabId: String, requestId: String, url: String)
    public fun downloadQueryJson(
        tabId: String,
        url: String,
        userAgent: String,
        contentDisposition: String,
        mimeType: String,
        contentLength: Long,
    ): String
}
