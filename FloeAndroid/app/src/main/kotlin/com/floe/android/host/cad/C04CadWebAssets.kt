// SPDX-License-Identifier: MPL-2.0
//
// Local-only asset origin for the CAD/3D WebView. Every request is answered
// by this interceptor: pinned viewer bytes come from the installed signed
// `cadpreview` split through the hash-verified CadViewerAssets provider,
// session bytes come from the exact immutable snapshots staged through the
// native workspace egress. Unknown hosts/schemes get a local 403, so the page
// can never reach the network, file://, content:// or another app's storage.
package com.floe.android.host.cad

import android.content.Context
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.nio.file.Files
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal data class C04CadServedResource(
    val name: String,
    val relativePath: String,
    val file: File,
    val byteCount: Long,
    val sha256: String,
    val mediaType: String,
) {
    fun verifiedFile(): File? {
        if (!file.isFile || !file.canRead()) return null
        if (Files.isSymbolicLink(file.toPath())) return null
        if (file.length() != byteCount) return null
        return file
    }
}

internal data class C04CadAssetSession(
    val sessionToken: String,
    val format: C04CadFormat,
    val manifest: ByteArray,
    val main: C04CadServedResource,
    val resources: Map<String, C04CadServedResource>,
)

internal class C04CadAssetRegistry {
    private val sessions = ConcurrentHashMap<String, C04CadAssetSession>()

    fun register(session: C04CadAssetSession) {
        sessions[session.sessionToken] = session
    }

    fun remove(sessionToken: String) {
        sessions.remove(sessionToken)
    }

    fun clear() {
        sessions.clear()
    }

    fun manifest(sessionToken: String): ByteArray? = sessions[sessionToken]?.manifest

    fun resource(sessionToken: String, resourceToken: String): C04CadServedResource? =
        sessions[sessionToken]?.resources?.get(resourceToken)
}

internal class C04CadWebAssetServer(
    private val context: Context,
    private val registry: C04CadAssetRegistry,
) {
    private val viewerAssets = CadViewerAssets(context)

    /** Bounded pre-render verification of every pinned viewer file
     * inside the installed signed split; cached by manifest hash + version. */
    suspend fun ensureAssetsVerified(): Boolean = viewerAssets.ensureVerified()
    fun invalidateAssets() = viewerAssets.invalidate()

    fun serve(request: WebResourceRequest?): WebResourceResponse? {
        val uri = request?.url ?: return forbidden()
        val scheme = uri.scheme?.lowercase(Locale.ROOT) ?: return forbidden()
        when (scheme) {
            "about" -> return null
            "blob" -> return if (uri.toString().startsWith("blob:$ORIGIN/", ignoreCase = true)) {
                // WebView-internal, same-origin blob URLs only (the DXF
                // renderer uses one for its immutable in-memory DXF bytes).
                null
            } else {
                forbidden()
            }
            "data" -> return null // embedded glTF buffers/images are inert
            "https" -> Unit
            else -> return forbidden()
        }
        if (uri.host?.equals(HOST, ignoreCase = true) != true || uri.userInfo != null ||
            (uri.port != -1 && uri.port != 443)
        ) {
            return forbidden()
        }
        val encodedPath = uri.encodedPath ?: return notFound()
        if (encodedPath.contains('%') || encodedPath.contains('\\') ||
            encodedPath.contains("..") || encodedPath.length > 2048
        ) {
            return forbidden()
        }
        val segments = uri.pathSegments
        if (segments.any { it.isEmpty() }) return notFound()
        return when {
            segments.size == 2 && segments[0] == "viewer" -> serveAsset(segments[1])
            segments.size == 3 && segments[0] == "session" &&
                segments[2] == "manifest.json" -> serveManifest(segments[1])
            segments.size == 3 && segments[0] == "resource" ->
                serveResource(segments[1], segments[2])
            else -> notFound()
        }
    }

    private fun serveAsset(name: String): WebResourceResponse {
        val mime = ASSET_MIME[name] ?: return notFound()
        // Only names pinned by the base-APK manifest are served, and only
        // after the signed split's bytes passed the full manifest verification.
        val stream: InputStream = try {
            viewerAssets.openPinned(name) ?: return notFound()
        } catch (_: Throwable) {
            return notFound()
        }
        val headers = mutableMapOf(
            "Cache-Control" to "no-store",
            "X-Content-Type-Options" to "nosniff",
            "Cross-Origin-Resource-Policy" to "same-origin",
        )
        if (name == "index.html") {
            headers["Content-Security-Policy"] = CSP
        }
        return WebResourceResponse(mime, textEncoding(mime), 200, "OK", headers, stream)
    }

    private fun serveManifest(sessionToken: String): WebResourceResponse {
        if (!isUUID(sessionToken)) return notFound()
        val bytes = registry.manifest(sessionToken) ?: return notFound()
        return response(
            mime = "application/json",
            status = 200,
            reason = "OK",
            body = ByteArrayInputStream(bytes),
            length = bytes.size.toLong(),
        )
    }

    private fun serveResource(sessionToken: String, resourceToken: String): WebResourceResponse {
        if (!isUUID(sessionToken) || !isUUID(resourceToken)) return notFound()
        val resource = registry.resource(sessionToken, resourceToken) ?: return notFound()
        val file = resource.verifiedFile() ?: return notFound()
        val stream = try {
            FileInputStream(file)
        } catch (_: Throwable) {
            return notFound()
        }
        return response(
            mime = resource.mediaType,
            status = 200,
            reason = "OK",
            body = stream,
            length = resource.byteCount,
        )
    }

    private fun response(
        mime: String,
        status: Int,
        reason: String,
        body: InputStream?,
        length: Long? = null,
    ): WebResourceResponse {
        val headers = mutableMapOf(
            "Cache-Control" to "no-store",
            "X-Content-Type-Options" to "nosniff",
        )
        if (length != null) headers["Content-Length"] = length.toString()
        return WebResourceResponse(
            mime, textEncoding(mime), status, reason, headers,
            body ?: ByteArrayInputStream(ByteArray(0)),
        )
    }

    private fun forbidden(): WebResourceResponse = WebResourceResponse(
        "text/plain", "utf-8", 403, "Forbidden",
        mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"),
        ByteArrayInputStream(ByteArray(0)),
    )

    private fun notFound(): WebResourceResponse = WebResourceResponse(
        "text/plain", "utf-8", 404, "Not Found",
        mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"),
        ByteArrayInputStream(ByteArray(0)),
    )

    private fun isUUID(value: String): Boolean = try {
        UUID.fromString(value).toString().equals(value, ignoreCase = true)
    } catch (_: IllegalArgumentException) {
        false
    }

    private fun textEncoding(mime: String): String? = when {
        mime.startsWith("text/") -> "utf-8"
        mime == "application/json" -> "utf-8"
        mime == "application/javascript" -> "utf-8"
        else -> null
    }

    companion object {
        const val HOST = "cad.floe.invalid"
        const val ORIGIN = "https://cad.floe.invalid"
        const val VIEWER_PATH = "/viewer/index.html"

        private const val CSP =
            "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; " +
                "style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; " +
                "connect-src 'self' blob:; worker-src 'self' blob:; font-src 'self'; " +
                "base-uri 'none'; form-action 'none'; object-src 'none'; " +
                "frame-ancestors 'none'"

        private val ASSET_MIME = mapOf(
            "index.html" to "text/html",
            "loader.js" to "text/javascript",
            "floecad.js" to "text/javascript",
            "viewer.js" to "text/javascript",
            "viewer.css" to "text/css",
            "dxf.js" to "text/javascript",
            "dxf-worker.js" to "text/javascript",
            "mesh.js" to "text/javascript",
            "cad-worker.js" to "text/javascript",
            "occt-worker.js" to "text/javascript",
            "occt-import-js.js" to "text/javascript",
            "floe_cad_engine.js" to "text/javascript",
            "floe_cad_engine_bg.wasm" to "application/wasm",
            "occt-import-js.wasm" to "application/wasm",
            "MiSans-Regular.ttf" to "font/ttf",
        )
    }
}
