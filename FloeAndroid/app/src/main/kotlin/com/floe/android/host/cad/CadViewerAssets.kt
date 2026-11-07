// SPDX-License-Identifier: MPL-2.0
//
// Trusted viewer-byte provider for the C04A WebView. The pin manifest stays
// in the base APK (`assets/preview_components/cad.json`, immutable per
// release); the viewer bytes themselves are served from the installed signed
// `cadpreview` split through the merged AssetManager (SplitCompat makes the
// split visible to the running process after a system-validated install).
// Every pinned file is hashed on IO once per installed split identity in this
// process; replacement or a new process requires verification again.
package com.floe.android.host.cad

import android.content.Context
import com.floe.android.BuildConfig
import com.floe.android.host.cadcomponent.CadComponentController
import java.io.InputStream
import java.security.MessageDigest
import org.json.JSONObject

internal class CadViewerAssets(private val context: Context) {
    private val appContext = context.applicationContext
    private val manifestText = appContext.assets.open(PIN_MANIFEST_PATH)
        .bufferedReader().use { it.readText() }
    private val manifest = JSONObject(manifestText).also {
        require(it.getInt("schemaVersion") == 1) { "component_manifest_schema" }
        require(it.getString("id") == "cad-v1") { "component_manifest_id" }
        require(it.getString("sourceCommit").matches(Regex("[a-f0-9]{40}"))) {
            "component_manifest_source"
        }
    }
    private val rows = manifest.getJSONArray("files")
    private val manifestHash = digest(manifestText.toByteArray())

    /** Ordered pin rows; also the only names the WebView may ever request. */
    val pinnedNames: List<String> = (0 until rows.length()).map { index ->
        rows.getJSONObject(index).getString("name")
    }
    private val pinnedByName = pinnedNames.toSet()
    private val totalBytes: Long = (0 until rows.length()).sumOf {
        rows.getJSONObject(it).getLong("bytes")
    }

    @Volatile private var verifiedIdentity: String? = null

    fun ready(): Boolean = verifiedIdentity?.let { it == componentIdentity() } == true

    fun isPinnedName(name: String): Boolean = validPinnedName(name) && name in pinnedByName

    /** Streaming open of one pinned viewer file from the installed split.
     * Callers must hold [ready]; anything else fails closed. */
    fun openPinned(name: String): InputStream? {
        if (!ready() || !isPinnedName(name)) return null
        return try {
            appContext.assets.open("$CAD_VIEWER_ROOT/$name")
        } catch (_: Throwable) {
            null
        }
    }

    /** One-time (or post-upgrade) bounded verification of every pinned file.
     * Runs on the IO dispatcher; every byte is hashed against the manifest. */
    suspend fun ensureVerified(): Boolean {
        if (ready()) return true
        val identity = componentIdentity() ?: return false
        val ok = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            runCatching {
                for (index in 0 until rows.length()) {
                    val entry = rows.getJSONObject(index)
                    val name = entry.getString("name")
                    val expectedBytes = entry.getLong("bytes")
                    val expectedHash = entry.getString("sha256")
                    if (!validPinRow(name, expectedBytes, expectedHash)) {
                        return@runCatching false
                    }
                    val hash = MessageDigest.getInstance("SHA-256")
                    var bytes = 0L
                    appContext.assets.open("$CAD_VIEWER_ROOT/$name").use { input ->
                        val buffer = ByteArray(65_536)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            bytes += count
                            if (bytes > expectedBytes) return@runCatching false
                            hash.update(buffer, 0, count)
                        }
                    }
                    if (bytes != expectedBytes || hex(hash.digest()) != expectedHash) {
                        return@runCatching false
                    }
                }
                true
            }.getOrDefault(false)
        }
        val accepted = ok && identity == componentIdentity()
        verifiedIdentity = if (accepted) identity else null
        return accepted
    }

    fun invalidate() { verifiedIdentity = null }

    private fun componentIdentity(): String? = runCatching {
        val info = appContext.packageManager.getPackageInfo(appContext.packageName, 0)
        if (info.longVersionCode != BuildConfig.VERSION_CODE.toLong() ||
            !CadComponentController.installed(appContext)) return@runCatching null
        "${info.longVersionCode}:${info.lastUpdateTime}:" +
            info.applicationInfo?.splitSourceDirs.orEmpty().joinToString("|")
    }.getOrNull()

    companion object {
        private const val PIN_MANIFEST_PATH = "preview_components/cad.json"
        private const val CAD_VIEWER_ROOT = "cad_viewer"
        private const val MAX_PINNED_FILE_BYTES = 64L * 1024 * 1024
        private val NAME_PATTERN = Regex("[A-Za-z0-9_.-]+")
        private val DIGEST_PATTERN = Regex("[0-9a-f]{64}")

        /** Pure admission rules for one manifest pin row; the same predicates
         * gate every served byte and every verification pass. */
        fun validPinnedName(name: String): Boolean =
            name !in setOf(".", "..") && name.length <= 128 && name.matches(NAME_PATTERN)

        fun validPinRow(name: String, bytes: Long, sha256: String): Boolean =
            validPinnedName(name) && bytes in 0..MAX_PINNED_FILE_BYTES &&
                sha256.matches(DIGEST_PATTERN)

        private fun hex(value: ByteArray) = value.joinToString("") { "%02x".format(it) }
        private fun digest(value: ByteArray) = hex(
            MessageDigest.getInstance("SHA-256").digest(value))
    }
}
