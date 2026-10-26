/* -*- tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * This Source Code Form is derived from the Collabora Online / LibreOffice
 * android lib (upstream COWebViewClient.java) and is subject to the terms of
 * the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed
 * with this file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Floe G05-R1 changes vs upstream:
 *  - The FQCN org.libreoffice.androidlib.COWebViewClient is REQUIRED: the
 *    prebuilt libandroidapp.so exports
 *    Java_org_libreoffice_androidlib_COWebViewClient_getEmbeddedMediaPath and
 *    resolves it lazily on the declaring class. Renaming is impossible.
 *  - Embedded media paths returned by the kit are canonicalised and confined
 *    to the explicitly supplied App-owned roots before any file is opened
 *    (upstream opened whatever path the kit returned).
 *  - Non-`cool:` requests are offline-locked: file:///android_asset/ and
 *    inline data/blob/about load as usual; every http(s)/content/other file
 *    request is answered 403. The upstream client allowed them to fall
 *    through to the network stack, which is not authorised for Floe preview.
 *  - The mobile socket is a bounded, session-owned [MobileSocket].
 */
package org.libreoffice.androidlib

import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.util.HashMap
import java.util.Objects

/**
 * Captures the `cool:` requests of the mobile dist so no local server socket
 * is hosted. Analogous to the iOS CoolURLSchemeHandler.
 */
class COWebViewClient(
    private val mediaRootPrefixes: List<String>,
    private val socketHost: MobileSocket.SocketHost,
) : WebViewClient() {

    val mobileSocket: MobileSocket = MobileSocket(socketHost)

    companion object {
        @JvmStatic
        fun response(code: Int, reasonPhrase: String, data: InputStream, headers: Map<String, String>): WebResourceResponse =
            WebResourceResponse(null, null, code, reasonPhrase, headers, data)

        @JvmStatic
        fun response(code: Int, reasonPhrase: String, data: InputStream, length: Long): WebResourceResponse {
            val headers = HashMap<String, String>()
            // Yes, the origin really is 'null' for 'file:' origins (upstream comment).
            headers["Access-Control-Allow-Origin"] = "null"
            headers["Content-Length"] = length.toString()
            return response(code, reasonPhrase, data, headers)
        }

        @JvmStatic
        fun response(code: Int, reasonPhrase: String, data: InputStream): WebResourceResponse {
            val headers = HashMap<String, String>()
            headers["Access-Control-Allow-Origin"] = "null"
            return response(code, reasonPhrase, data, headers)
        }

        @JvmStatic
        fun response(code: Int, reasonPhrase: String): WebResourceResponse {
            val data = ByteArrayInputStream(ByteArray(0))
            return response(code, reasonPhrase, data, 0)
        }

        private const val ASSET_PREFIX = "file:///android_asset/"
    }

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
        val url = request.url
        if (!Objects.equals(url.scheme, "cool")) {
            return offlineLock(view, request, url)
        }

        val path = url.path
        if (Objects.equals(path, "/cool/media")) {
            return handleMediaRequest(request)
        } else if (path != null && path.startsWith("/cool/mobilesocket/")) {
            return handleMobileSocketRequest(request)
        } else {
            return response(404, "Not Found")
        }
    }

    /** Offline-only viewer: only android_asset pages and inline data stay allowed. */
    private fun offlineLock(
        view: WebView,
        request: WebResourceRequest,
        url: Uri,
    ): WebResourceResponse? {
        return when (url.scheme) {
            "file" ->
                if (url.toString().startsWith(ASSET_PREFIX)) {
                    super.shouldInterceptRequest(view, request)
                } else {
                    response(403, "Forbidden")
                }
            "data", "blob", "about" -> super.shouldInterceptRequest(view, request)
            else -> response(403, "Forbidden")
        }
    }

    private fun handleMediaRequest(request: WebResourceRequest): WebResourceResponse {
        // Presentation mode hands us a broken (over-encoded) URI; the decode
        // step is upstream behaviour preserved verbatim.
        val uriDecoded = Uri.parse(Uri.decode(request.url.toString()))
        val tag = uriDecoded.getQueryParameter("Tag") ?: return response(404, "Not Found")

        val mediaPath = try {
            getEmbeddedMediaPath(tag)
        } catch (e: UnsatisfiedLinkError) {
            return response(503, "Service Unavailable")
        }
        if (mediaPath.isEmpty()) {
            return response(404, "Not Found")
        }

        val canonical = try {
            File(mediaPath).canonicalPath
        } catch (e: Exception) {
            return response(404, "Not Found")
        }
        val withinRoot = mediaRootPrefixes.any { prefix ->
            val p = prefix.removeSuffix("/")
            canonical == p || canonical.startsWith("$p/")
        }
        if (!withinRoot) {
            return response(403, "Forbidden")
        }

        val media = File(canonical)
        if (!media.isFile) {
            return response(404, "Not Found")
        }
        val data = try {
            FileInputStream(media)
        } catch (e: Exception) {
            return response(404, "Not Found")
        }
        return response(200, "OK", data, media.length())
    }

    private fun handleMobileSocketRequest(request: WebResourceRequest): WebResourceResponse {
        // Something like [ 'cool', 'mobilesocket', 'cool', 'wopipath', 'ws', 'ws', command, 'id' ].
        val path = request.url.pathSegments
        if (path.size < 7) {
            return response(400, "Bad Request")
        }
        if (path[6] == "open") {
            return mobileSocket.open()
        }
        // Anything except "open" is treated as "write" (upstream parity; the
        // page's "close" POST arrives here too and simply flushes pending data).
        return mobileSocket.write()
    }

    /// Declared on this exact class: JNI export
    /// Java_org_libreoffice_androidlib_COWebViewClient_getEmbeddedMediaPath.
    external fun getEmbeddedMediaPath(tag: String): String
}
