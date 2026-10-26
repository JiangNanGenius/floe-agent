package com.floe.android.core.officeengine

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import java.io.File
import java.io.IOException

/**
 * One-time extraction of the packaged `unpack` profile skeleton into
 * `$APP_DATA_DIR` (upstream LOActivity.init() behaviour, preserved with Floe
 * honesty rules):
 *  - cancellable loop owned by the SERVICE, not by any view;
 *  - the completion marker is only written after a full, uncancelled pass;
 *  - the fontconfig cachedir line is rewritten to the RUNNING package
 *    (OfficePayloadBootstrap.rewriteFontsConf) — the staged APK baked the
 *    upstream application id, which is not this app's identity;
 *  - nothing is deleted; re-extraction overwrites idempotently;
 *  - native preview policy is an explicit packaged XCD in the real
 *    xcsxcu registry layer. This producer has NO user: layer, so writing
 *    registrymodifications.xcu here would not enforce native policy.
 */
internal class OfficeUnpackPreparation(
    private val context: Context,
    private val prefs: SharedPreferences,
) {
    companion object {
        private const val TAG = "OfficeUnpack"
    }

    /**
     * Blocking; call from the service control thread only. Returns false with
     * an honest [lastError] when cancelled or failed; the caller must NOT
     * attempt a native load after a false.
     */
    @Volatile
    var lastError: String? = null
        private set

    fun prepare(cancelled: () -> Boolean, onProgress: (filesDone: Int, filesTotal: Int) -> Unit): Boolean {
        lastError = null
        val payloadRevision = BuildConfig.OFFICE_PAYLOAD_SOURCE_REV
        val marker = OfficePayloadBootstrap.unpackMarker(payloadRevision, context.packageName)
        val dataDir = context.applicationInfo?.dataDir
            ?: run {
                lastError = "dataDir unavailable"
                return false
            }
        val targetRoot = File(dataDir)
        if (!OfficePayloadBootstrap.needsExtraction(prefs.getString(OfficePayloadBootstrap.KEY_UNPACK_MARKER, ""), payloadRevision, context.packageName)) {
            return true
        }
        val assets = context.assets
        val files = ArrayList<String>()
        try {
            walkAssets(assets, OfficePayloadBootstrap.UNPACK_ASSET_ROOT, files)
        } catch (e: Exception) {
            lastError = "asset listing failed: ${e.message}"
            return false
        }
        val total = files.size
        var done = 0
        for (assetPath in files) {
            if (cancelled()) {
                lastError = "cancelled"
                return false
            }
            val rel = OfficePayloadBootstrap.unpackTargetRelPath(assetPath) ?: continue
            val target = File(targetRoot, rel)
            val tmp = File(target.parentFile, target.name + ".part")
            try {
                target.parentFile?.mkdirs()
                tmp.outputStream().buffered().use { out ->
                    if (assetPath.endsWith("etc/fonts/fonts.conf")) {
                        val content = assets.open(assetPath).bufferedReader().use { it.readText() }
                        out.write(
                            OfficePayloadBootstrap
                                .rewriteFontsConf(content, context.packageName, dataDir)
                                .toByteArray(Charsets.UTF_8),
                        )
                    } else {
                        assets.open(assetPath).use { input -> input.copyTo(out) }
                    }
                }
                if (target.exists() && !target.delete() && !cancelled()) {
                    // A previously read-only leftover is exceptional; fail the
                    // step rather than pretend the profile is current.
                    lastError = "cannot replace ${target.name}"
                    tmp.delete()
                    return false
                }
                if (!tmp.renameTo(target)) {
                    lastError = "cannot commit ${target.name}"
                    tmp.delete()
                    return false
                }
            } catch (e: IOException) {
                lastError = "extract ${File(assetPath).name}: ${e.message}"
                runCatching { tmp.delete() }
                return false
            }
            done++
            onProgress(done, total)
        }
        prefs.edit().putString(OfficePayloadBootstrap.KEY_UNPACK_MARKER, marker).commit()
        Log.i(TAG, "engine profile extracted ($done/$total files)")
        return true
    }

    private fun walkAssets(assets: android.content.res.AssetManager, path: String, out: MutableList<String>) {
        val entries = assets.list(path) ?: return
        for (entry in entries) {
            val child = "$path/$entry"
            val children = assets.list(child)
            if (children != null && children.isNotEmpty()) {
                walkAssets(assets, child, out)
            } else if (children != null) {
                // Directory without children: create it so the profile layout
                // matches the packaged tree (engine expects dirs like
                // user/ extensions roots to exist at first write).
                out.add(child)
            }
        }
    }
}
