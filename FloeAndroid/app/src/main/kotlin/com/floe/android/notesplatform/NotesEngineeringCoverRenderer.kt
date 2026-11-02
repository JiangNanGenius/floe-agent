// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import com.floe.android.feature.notes.ui.api.NotesEngineeringCoverRequest
import com.floe.android.host.cad.C04CadAssetRegistry
import com.floe.android.host.cad.C04CadAssetSession
import com.floe.android.host.cad.C04CadFormat
import com.floe.android.host.cad.C04CadServedResource
import com.floe.android.host.cad.C04CadWebAssetServer
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/** One bounded, serial renderer over the same pinned offline CAD viewer.
 * Its source is an authorized Notes resource, never a model-provided path.
 * Only the viewer's captured canvas is returned; failure keeps the text cover.
 */
internal class NotesEngineeringCoverRenderer(
    private val broker: NotesPlatformActivityBroker,
    private val stagingRoot: File,
) {
    private val gate = Mutex()
    private val pending = AtomicInteger()
    private val closed = java.util.concurrent.atomic.AtomicBoolean(false)
    @Volatile private var activeResult: CompletableDeferred<ByteArray?>? = null

    fun close() {
        closed.set(true)
        activeResult?.complete(null)
    }
    private class Bridge(private val receive: (String) -> Unit) {
        @JavascriptInterface fun postEvent(raw: String) = receive(raw)
    }

    suspend fun render(request: NotesEngineeringCoverRequest): ByteArray? {
        if (closed.get() || request.bytes.isEmpty() || request.bytes.size > MAX_SOURCE_BYTES) return null
        val format = C04CadFormat.entries.firstOrNull {
            it.extension == request.fileName.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
        } ?: return null
        // A Notes resource is one file. Directory packages and external sidecars
        // require their own authorized package/resource resolver, not guessed paths.
        if (format == C04CadFormat.FLOECAD) return null
        if (pending.incrementAndGet() > 16) { pending.decrementAndGet(); return null }
        return try {
            withTimeoutOrNull(60_000L) {
                gate.withLock {
                    if (closed.get()) null else withTimeoutOrNull(25_000L) { renderOne(request, format) }
                }
            }
        } finally { pending.decrementAndGet() }
    }

    private suspend fun renderOne(request: NotesEngineeringCoverRequest, format: C04CadFormat): ByteArray? {
        val id = UUID.randomUUID().toString()
        val token = UUID.randomUUID().toString()
        val directory = File(stagingRoot, "engineering-covers/$id")
        val source = File(directory, "source.${format.extension}")
        val registry = C04CadAssetRegistry()
        var view: WebView? = null
        try {
            withContext(Dispatchers.IO) {
                check(directory.mkdirs())
                source.outputStream().use { it.write(request.bytes) }
            }
            val sha = MessageDigest.getInstance("SHA-256").digest(request.bytes)
                .joinToString("") { "%02x".format(it) }
            val manifest = JSONObject().put("session", id).put("format", format.extension)
                .put("options", JSONObject().put("theme", "light"))
                .put("main", JSONObject().put("token", token)
                    .put("name", "drawing.${format.extension}").put("byteCount", request.bytes.size)
                    .put("sha256", sha).put("mediaType", format.mimeType))
                .put("resources", JSONArray()).toString().toByteArray()
            val resource = C04CadServedResource("drawing.${format.extension}", source.name,
                source, request.bytes.size.toLong(), sha, format.mimeType)
            registry.register(C04CadAssetSession(id, format, manifest, resource, mapOf(token to resource)))
            return withContext(Dispatchers.Main.immediate) {
                val activity = broker.currentActivity() ?: return@withContext null
                val decor = activity.window.decorView as? ViewGroup ?: return@withContext null
                if (closed.get()) return@withContext null
                val result = CompletableDeferred<ByteArray?>()
                activeResult = result
                if (closed.get()) result.complete(null)
                val handler = Handler(Looper.getMainLooper())
                val web = WebView(activity)
                view = web
                val server = C04CadWebAssetServer(activity, registry)
                var captureRequested = false
                web.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = false
                    databaseEnabled = false
                    allowFileAccess = false
                    allowContentAccess = false
                    javaScriptCanOpenWindowsAutomatically = false
                    setSupportMultipleWindows(false)
                    mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
                    cacheMode = WebSettings.LOAD_NO_CACHE
                    mediaPlaybackRequiresUserGesture = true
                }
                web.alpha = 0f
                web.isFocusable = false
                web.isClickable = false
                web.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                web.webChromeClient = object : WebChromeClient() {
                    override fun onPermissionRequest(request: PermissionRequest?) { request?.deny() }
                }
                web.webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(v: WebView?, request: WebResourceRequest?): WebResourceResponse? =
                        server.serve(request)
                    override fun shouldOverrideUrlLoading(v: WebView?, request: WebResourceRequest?): Boolean = true
                    override fun onRenderProcessGone(v: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                        result.complete(null)
                        return true
                    }
                }
                web.addJavascriptInterface(Bridge { raw ->
                    if (raw.length <= MAX_EVENT_CHARS) handler.post {
                        if (result.isCompleted || view !== web) return@post
                        try {
                            val event = JSONObject(raw)
                            if (event.optString("session") != id) return@post
                            when (event.optString("type")) {
                                "ready" -> {
                                    val facts = event.optJSONObject("facts") ?: return@post
                                    if (!facts.optBoolean("rendered") || facts.optInt("frameSequence") < 1) {
                                        result.complete(null)
                                    } else if (!captureRequested) {
                                        captureRequested = true
                                        web.evaluateJavascript("window.floeCadViewer.capture('cover')", null)
                                    }
                                }
                                "capture" -> {
                                    if (!captureRequested || event.optString("requestId") != "cover") return@post
                                    val url = event.optString("dataUrl")
                                    if (!url.startsWith(PNG_PREFIX)) { result.complete(null); return@post }
                                    val bytes = Base64.decode(url.substring(PNG_PREFIX.length), Base64.DEFAULT)
                                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                                    val valid = bytes.size in 1..MAX_PNG_BYTES &&
                                        bounds.outMimeType == "image/png" &&
                                        bounds.outWidth in 1..2048 && bounds.outHeight in 1..2048 &&
                                        bounds.outWidth == event.optInt("width") &&
                                        bounds.outHeight == event.optInt("height") &&
                                        event.optInt("frameSequence") > 1
                                    result.complete(bytes.takeIf { valid })
                                }
                                "error", "captureError" -> result.complete(null)
                            }
                        } catch (_: Exception) { result.complete(null) }
                    }
                }, "C04Bridge")
                // Attach behind the normal App content. The actual renderer
                // gets a measured window surface without opening a screen,
                // taking input/focus, or requesting an overlay permission.
                decor.addView(web, 0, ViewGroup.LayoutParams(480, 360))
                web.measure(View.MeasureSpec.makeMeasureSpec(480, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(360, View.MeasureSpec.EXACTLY))
                web.layout(0, 0, 480, 360)
                web.loadUrl("${C04CadWebAssetServer.ORIGIN}${C04CadWebAssetServer.VIEWER_PATH}?session=$id")
                result.await()
            }
        } finally {
            activeResult = null
            withContext(NonCancellable + Dispatchers.Main.immediate) {
                view?.let { web ->
                    view = null
                    web.removeJavascriptInterface("C04Bridge")
                    (web.parent as? ViewGroup)?.removeView(web)
                    web.stopLoading()
                    web.destroy()
                }
            }
            registry.clear()
            withContext(NonCancellable + Dispatchers.IO) { directory.deleteRecursively() }
        }
    }

    private companion object {
        const val MAX_SOURCE_BYTES = 8 * 1024 * 1024
        const val MAX_PNG_BYTES = 2 * 1024 * 1024
        const val MAX_EVENT_CHARS = 3 * 1024 * 1024
        const val PNG_PREFIX = "data:image/png;base64,"
    }
}
