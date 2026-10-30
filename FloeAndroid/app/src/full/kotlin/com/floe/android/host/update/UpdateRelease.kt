// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull

/** One release asset, already restricted to a public HTTPS download URL. */
internal data class ReleaseAsset(
    val name: String,
    val sizeBytes: Long,
    val downloadUrl: String,
)

/** A well-formed Android release candidate from the shared repository feed. */
internal data class AndroidRelease(
    val tag: String,
    val version: FloeVersion,
    val summary: String,
    val apk: ReleaseAsset,
    val checksums: ReleaseAsset,
    /**
     * Optional bounded `update-delta-v1.json` asset. Its presence alone grants
     * nothing: [UpdateDeltaPolicy] still requires SHA256SUMS to bind both this
     * manifest and its patch, and the manifest to bind the exact full-APK hash.
     */
    val delta: ReleaseAsset? = null,
    /** Bounded name→asset map of this release (safe names and HTTPS URLs only). */
    val assets: Map<String, ReleaseAsset> = emptyMap(),
)

/**
 * Android release discovery over the repository's own Releases API pages.
 *
 * Hard rules (they encode the settled release contract, not preferences):
 *  * only `android/v<semver>` tags are Android releases; the repository also
 *    publishes iOS `v*` releases, so `releases/latest` is never consulted;
 *  * drafts are skipped;
 *  * the release must carry exactly the configured Full ARM64 APK name for
 *    its own version plus a bounded `SHA256SUMS` asset, both on HTTPS;
 *  * a release with any of that missing is ignored, never repaired by
 *    guessing another asset, channel or filename.
 */
internal object AndroidReleaseFeed {
    const val CHECKSUMS_NAME = "SHA256SUMS"
    const val MAX_APK_BYTES = 2L * 1024L * 1024L * 1024L
    const val MAX_CHECKSUMS_BYTES = 256L * 1024L
    private const val MAX_TAG_CHARS = 96
    /** A release carries a handful of assets; never let a feed grow the map. */
    private const val MAX_ASSETS = 24

    fun apkName(version: FloeVersion): String = "Floe-Android-$version-full-arm64-v8a.apk"

    fun parsePage(json: String): List<AndroidRelease> {
        val root = runCatching { Json.parseToJsonElement(json) }.getOrNull() as? JsonArray
            ?: return emptyList()
        val releases = ArrayList<AndroidRelease>()
        for (element in root) {
            val release = element as? JsonObject ?: continue
            if (release.booleanOrNull("draft") == true) continue
            val tag = release.stringOrNull("tag_name") ?: continue
            if (tag.length > MAX_TAG_CHARS) continue
            val version = FloeVersion.fromAndroidTag(tag) ?: continue
            val assets = (release["assets"] as? JsonArray)?.mapNotNull { it.toAsset() } ?: emptyList()
            val apkName = apkName(version)
            val apk = assets.firstOrNull {
                it.name == apkName && it.sizeBytes in 1..MAX_APK_BYTES
            } ?: continue
            val checksums = assets.firstOrNull {
                it.name == CHECKSUMS_NAME && it.sizeBytes in 1..MAX_CHECKSUMS_BYTES
            } ?: continue
            // Keep a small, safe name→asset map so a manifest can name its
            // patch asset without ever trusting a URL taken from that manifest.
            val byName = LinkedHashMap<String, ReleaseAsset>()
            for (asset in assets) {
                if (byName.size >= MAX_ASSETS) break
                val allowedName = UpdateDeltaFormat.isSafeAssetName(asset.name) ||
                    asset.name == CHECKSUMS_NAME ||
                    asset.name == UpdateDeltaFormat.MANIFEST_ASSET
                if (!allowedName) continue
                byName.putIfAbsent(asset.name, asset)
            }
            releases += AndroidRelease(
                tag = tag,
                version = version,
                summary = ReleaseSummary.bounded(release.stringOrNull("body")),
                apk = apk,
                checksums = checksums,
                delta = byName[UpdateDeltaFormat.MANIFEST_ASSET]
                    ?.takeIf { it.sizeBytes in 1..UpdateDeltaFormat.MAX_MANIFEST_BYTES },
                assets = byName,
            )
        }
        return releases.distinctBy { it.tag }
    }

    private fun JsonObject.stringOrNull(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.booleanOrNull(key: String): Boolean? =
        (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun kotlinx.serialization.json.JsonElement.toAsset(): ReleaseAsset? {
        val asset = this as? JsonObject ?: return null
        val name = asset.stringOrNull("name") ?: return null
        val size = (asset["size"] as? JsonPrimitive)?.longOrNull ?: return null
        val url = asset.stringOrNull("browser_download_url") ?: return null
        if (name.isEmpty() || name.length > 160) return null
        if (!url.startsWith("https://")) return null
        return ReleaseAsset(name = name, sizeBytes = size, downloadUrl = url)
    }
}

internal object AndroidReleaseSelection {
    /**
     * Newest candidate strictly newer than [current]. A release whose version
     * equals or precedes the installed one is NOT an update (equal versions
     * and downgrades report "already current" — the tag number is never
     * treated as the installed versionCode).
     */
    fun newest(candidates: List<AndroidRelease>, current: FloeVersion): AndroidRelease? =
        candidates
            .filter { it.version > current }
            // Stable descending sort: the highest semantic version wins; on an
            // exact tie the first feed entry (GitHub's newest-first order) wins.
            .sortedWith(compareByDescending<AndroidRelease> { it.version })
            .firstOrNull()
}
