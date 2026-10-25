// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import android.content.Intent
import android.os.Bundle
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.viewinterop.AndroidView
import com.floe.android.design.*
import java.io.ByteArrayInputStream

/** Explicitly opened local legal/source details. This view has no engine JNI,
 * JavaScript, document bridge, file/provider authority or network loader.
 * Source links open only after a real user gesture in the system browser.
 */
class OfficeNoticesActivity : ComponentActivity() {
    private var noticesView: WebView? = null
    private var linkUnavailable by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (!OfficeWebViewDirectory.ensureOnce()) { finish(); return }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() = back()
        })
        setContent {
            val theme = runCatching { FloeThemeMode.valueOf(intent.getStringExtra("com.floe.office.THEME_MODE").orEmpty()) }
                .getOrDefault(FloeThemeMode.AUTO)
            FloeTheme(themeMode = theme) {
                OfficeWindowAppearance(this, theme)
                Column(Modifier.fillMaxSize().background(Floe.colors.readingSurface).safeDrawingPadding()) {
                    FloeToolbar(
                        title = stringResource(R.string.office_viewer_notices),
                        navigation = {
                            FloeCircleButton(FloeIcons.ChevronBack,
                                stringResource(R.string.office_notices_back), onClick = ::back)
                        },
                        showHairline = true,
                    )
                    AndroidView(
                        factory = { context ->
                            WebView(context).apply {
                                settings.javaScriptEnabled = false
                                settings.domStorageEnabled = false
                                settings.allowFileAccess = false
                                settings.allowContentAccess = false
                                settings.blockNetworkLoads = true
                                webViewClient = object : WebViewClient() {
                                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest): Boolean {
                                        val url = request.url
                                        if (isLocalNotice(url.toString())) return false
                                        if (request.isForMainFrame && request.hasGesture() && url.scheme == "https") {
                                            try { startActivity(Intent(Intent.ACTION_VIEW, url)) }
                                            catch (_: android.content.ActivityNotFoundException) { linkUnavailable = true }
                                        }
                                        return true
                                    }

                                    override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest): WebResourceResponse? =
                                        if (isLocalNotice(request.url.toString())) null else WebResourceResponse(
                                            "text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                                }
                                noticesView = this
                                loadUrl(ENTRY)
                            }
                        },
                        modifier = Modifier.weight(1f),
                        onRelease = { view ->
                            if (noticesView === view) { noticesView = null; view.destroy() }
                        },
                    )
                }
                if (linkUnavailable) FloeInfoDialog(
                    title = stringResource(R.string.office_viewer_notices),
                    message = stringResource(R.string.office_notices_link_unavailable),
                    confirmLabel = stringResource(R.string.office_viewer_done),
                    onDismiss = { linkUnavailable = false },
                )
            }
        }
    }

    private fun back() {
        val view = noticesView
        if (view?.canGoBack() == true) view.goBack() else finish()
    }

    override fun onDestroy() {
        noticesView?.destroy()
        noticesView = null
        super.onDestroy()
    }

    companion object {
        private const val ENTRY = "file:///android_asset/notices/index.html"
        private val LOCAL = setOf(ENTRY, "file:///android_asset/license.html", "file:///android_asset/notice.txt",
            "file:///android_asset/notices/source-index.json")
        private fun isLocalNotice(url: String): Boolean = url.substringBefore('#') in LOCAL
    }
}
