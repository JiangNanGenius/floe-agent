// SPDX-License-Identifier: MPL-2.0
package com.floe.android.notesplatform

import android.content.Intent
import android.os.Bundle
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.lifecycleScope
import com.floe.android.FloeApplication
import com.floe.android.R
import com.floe.android.RuntimeBootstrapCapability
import com.floe.android.design.*
import com.floe.android.host.cad.*
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/** Internal preview of the exact Notes-authorized immutable staged attachment.
 * Reuses C04's pinned assets, resource verifier, camera and network-denying server.
 * No task/workspace identity is fabricated and no file path enters the Intent.
 */
class NotesEngineeringPreviewActivity : ComponentActivity() {
    private val registry = C04CadAssetRegistry()
    private val sessionID = UUID.randomUUID().toString()
    private var web: WebView? = null
    private var prepared by mutableStateOf(false)
    private var ready by mutableStateOf(false)
    private var failed by mutableStateOf(false)
    private var sourceName by mutableStateOf("")
    private var format: C04CadFormat? = null
    private var ownerEpoch = 0L
    private var shareToken: String? = null

    private class Bridge(private val receive: (String) -> Unit) {
        @JavascriptInterface fun postEvent(value: String) { if (value.length <= 65_536) receive(value) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ownerEpoch = intent.getLongExtra(EPOCH, 0)
        shareToken = intent.getStringExtra(TOKEN)
        val app = application as? FloeApplication
        val entry = NotesShareRegistry.resolve(shareToken)
        if (app == null || entry == null || ownerEpoch <= 0 || app.runtimeHost?.nativeRootEpoch() != ownerEpoch) {
            finish(); return
        }
        sourceName = entry.displayName
        format = C04CadFormat.fromPath(sourceName)
        if (format == null || format == C04CadFormat.FLOECAD) { finish(); return }
        lifecycleScope.launch {
            app.runtimeBootstrapCapability.collect { capability ->
                if (capability !is RuntimeBootstrapCapability.OwnedStoreReady ||
                    app.runtimeHost?.nativeRootEpoch() != ownerEpoch) retire()
            }
        }
        lifecycleScope.launch {
            delay(30_000)
            if (!ready && !failed && !isFinishing) fail()
        }
        setContent {
            FloeTheme {
                Column(Modifier.fillMaxSize().systemBarsPadding().padding(12.dp)) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FloeText(sourceName, style = Floe.typography.body, modifier = Modifier.weight(1f), maxLines = 1)
                        FloeCapsuleAction(stringResource(R.string.done), onClick = { finish() })
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Control(R.string.workspace_document_cad_zoom_in, "zoomIn")
                        Control(R.string.workspace_document_cad_zoom_out, "zoomOut")
                        Control(R.string.workspace_document_cad_fit, "fit")
                        Control(R.string.workspace_document_cad_reset, "reset")
                        if (format != C04CadFormat.DXF && format != C04CadFormat.DWG) {
                            Control(R.string.workspace_document_cad_orbit_left, "orbitLeft")
                            Control(R.string.workspace_document_cad_orbit_right, "orbitRight")
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    if (failed) FloeText(stringResource(R.string.workspace_document_cad_failed_title), style = Floe.typography.body)
                    else if (!ready) FloeText(stringResource(R.string.workspace_document_cad_rendering), style = Floe.typography.body)
                    if (prepared) Box(Modifier.fillMaxWidth().weight(1f)) {
                        AndroidView(modifier = Modifier.fillMaxSize(), factory = { makeWebView() })
                    }
                    else Spacer(Modifier.weight(1f))
                    FloeText(stringResource(if (format == C04CadFormat.DXF || format == C04CadFormat.DWG)
                        R.string.workspace_document_cad_hint_2d else R.string.workspace_document_cad_hint_3d), style = Floe.typography.metadata)
                }
            }
        }
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    check(NotesPlatformFiles.isPlainFile(entry.file, NotesPlatformFiles.MAX_STAGED_PICK_BYTES))
                    val resourceToken = UUID.randomUUID().toString()
                    val chosen = requireNotNull(format)
                    val sha = NotesPlatformFiles.sha256(entry.file)
                    val resource = C04CadServedResource(entry.displayName, entry.file.name,
                        entry.file, entry.byteCount, sha, chosen.mimeType)
                    val manifest = JSONObject().put("session", sessionID).put("format", chosen.extension)
                        .put("options", JSONObject().put("theme", "light"))
                        .put("main", JSONObject().put("token", resourceToken).put("name", entry.displayName)
                            .put("byteCount", entry.byteCount).put("sha256", sha).put("mediaType", chosen.mimeType))
                        .put("resources", JSONArray()).toString().toByteArray()
                    registry.register(C04CadAssetSession(sessionID, chosen, manifest, resource, mapOf(resourceToken to resource)))
                }
                if (app.runtimeHost?.nativeRootEpoch() != ownerEpoch || isFinishing) { finish(); return@launch }
                prepared = true
            } catch (_: Exception) { fail() }
        }
    }

    @Composable private fun Control(label: Int, command: String) {
        FloeCapsuleAction(stringResource(label), enabled = ready, onClick = {
            web?.evaluateJavascript("window.floeCadViewer && window.floeCadViewer.command(${JSONObject.quote(command)})", null)
        })
    }

    private fun makeWebView(): WebView {
        val server = C04CadWebAssetServer(this, registry)
        return WebView(this).also { view ->
            web = view
            view.layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
                android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            )
            view.settings.apply {
                javaScriptEnabled = true; domStorageEnabled = false; databaseEnabled = false
                allowFileAccess = false; allowContentAccess = false
                javaScriptCanOpenWindowsAutomatically = false; setSupportMultipleWindows(false)
                mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW; cacheMode = WebSettings.LOAD_NO_CACHE
            }
            view.webChromeClient = object : WebChromeClient() {
                override fun onPermissionRequest(request: PermissionRequest?) { request?.deny() }
            }
            view.webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? = server.serve(request)
                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?) = true
                override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                    fail(); prepared = false
                    view?.destroy(); if (web === view) web = null
                    return true
                }
            }
            view.addJavascriptInterface(Bridge { raw -> runOnUiThread {
                if (web !== view || isFinishing) return@runOnUiThread
                if ((application as? FloeApplication)?.runtimeHost?.nativeRootEpoch() != ownerEpoch) {
                    retire(); return@runOnUiThread
                }
                runCatching {
                    val event = JSONObject(raw)
                    if (event.optString("session") != sessionID) return@runCatching
                    when (event.optString("type")) {
                        "ready" -> {
                            val facts = event.optJSONObject("facts")
                            if (facts?.optBoolean("rendered") == true && facts.optInt("frameSequence") > 0) {
                                ready = true
                                setResult(RESULT_OK, Intent().putExtra("rendered", true))
                            } else fail()
                        }
                        "error" -> fail()
                    }
                }.onFailure { fail() }
            } }, "C04Bridge")
            view.loadUrl("${C04CadWebAssetServer.ORIGIN}${C04CadWebAssetServer.VIEWER_PATH}?session=$sessionID")
        }
    }

    private fun retire() {
        ready = false
        setResult(RESULT_CANCELED)
        finish()
    }

    private fun fail() {
        ready = false; failed = true
        setResult(RESULT_CANCELED, Intent().putExtra("failed", true))
    }

    override fun onDestroy() {
        web?.let { it.stopLoading(); it.removeJavascriptInterface("C04Bridge"); it.destroy() }
        web = null; registry.clear()
        super.onDestroy()
    }
    companion object {
        const val TOKEN = "notesEngineeringShareToken"
        const val EPOCH = "notesEngineeringOwnerEpoch"
    }
}
