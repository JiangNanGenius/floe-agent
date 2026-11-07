// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.IOException
import java.net.URI

/** Transport choices only. Release metadata and checksums keep their canonical source. */
internal enum class UpdateDownloadSource(val id: String, private val prefix: String) {
    GITHUB("github", ""),
    GHFAST("ghfast", "https://ghfast.top/"),
    GH_PROXY("gh-proxy", "https://gh-proxy.com/");

    fun assetUrl(canonical: String): String {
        if (this == GITHUB) return canonical
        val uri = runCatching { URI(canonical) }.getOrNull()
            ?: throw IOException("invalid-update-asset")
        // Never turn a persisted/model-authored URL into an arbitrary proxy request.
        val base = "/${UpdateConfig.REPOSITORY_OWNER}/${UpdateConfig.REPOSITORY_NAME}/releases/download/android/v"
        val tail = uri.rawPath?.takeIf { it.startsWith(base) }?.removePrefix(base)
        val version = tail?.substringBefore('/')
        val asset = tail?.substringAfter('/', "")
        if (uri.scheme != "https" || uri.host != "github.com" || uri.port != -1 ||
            uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null ||
            version.isNullOrEmpty() || FloeVersion.parse(version) == null || asset.isNullOrEmpty() ||
            !asset.matches(Regex("Floe-Android-[0-9A-Za-z.-]+\\.(apk|delta)")) ||
            uri.normalize().rawPath != uri.rawPath
        ) throw IOException("invalid-update-asset")
        return prefix + canonical
    }

    companion object {
        fun fromId(id: String?): UpdateDownloadSource = entries.firstOrNull { it.id == id } ?: GITHUB
    }
}

internal data class UpdateSourceState(
    val selected: UpdateDownloadSource,
    val switching: Boolean = false,
    /** A real ranged response could not safely extend the existing prefix. */
    val restarted: Boolean = false,
)
