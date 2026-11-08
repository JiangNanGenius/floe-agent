// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.IOException
import java.net.URI
import kotlinx.coroutines.CancellationException

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
            !asset.matches(Regex("(?:Floe-Android-[0-9A-Za-z.-]+\\.(?:apk|delta)|Floe-(?:Office|CAD)-Preview-[0-9A-Za-z.-]+\\.component)")) ||
            uri.normalize().rawPath != uri.rawPath
        ) throw IOException("invalid-update-asset")
        return prefix + canonical
    }

    companion object {
        fun fromId(id: String?): UpdateDownloadSource = entries.firstOrNull { it.id == id } ?: GITHUB
    }
}

/**
 * The single official alias for a release asset: the SAME asset through the
 * repository's own public GitHub REST address
 * (`https://api.github.com/repos/<owner>/<repo>/releases/assets/<id>`), served
 * anonymously with `Accept: application/octet-stream` after a 302 redirect.
 *
 * This is not another mirror, account or provider: it is GitHub's own asset
 * endpoint for the exact asset the release feed already validated. The
 * validator is strict so a feed or persisted record can never turn the alias
 * into an arbitrary API request.
 */
internal object OfficialAssetRoute {
    private val ASSET_ID = Regex("[0-9]{1,20}")

    fun validatedApiUrl(raw: String?): String? {
        if (raw.isNullOrEmpty() || raw.length > 200) return null
        val uri = runCatching { URI.create(raw) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.host != "api.github.com" || uri.port != -1) return null
        if (uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null) return null
        val path = uri.rawPath ?: return null
        if (uri.normalize().rawPath != path) return null
        val base = "/repos/${UpdateConfig.REPOSITORY_OWNER}/${UpdateConfig.REPOSITORY_NAME}/releases/assets/"
        if (!path.startsWith(base)) return null
        if (!path.removePrefix(base).matches(ASSET_ID)) return null
        return raw
    }

    /** Shared by self-updates and optional components; callers retain writer ownership. */
    suspend fun open(
        primaryUrl: String,
        apiUrl: String?,
        payload: Boolean,
        request: suspend (String) -> DownloadResponse,
        onAlias: () -> Unit = {},
    ): DownloadResponse {
        val alias = validatedApiUrl(apiUrl)
        val routes = if (alias == null) listOf(primaryUrl) else listOf(primaryUrl, alias)
        for ((index, url) in routes.withIndex()) {
            try {
                val response = request(url)
                if (payload && response.contentType?.contains("json", ignoreCase = true) == true) {
                    runCatching { response.stream.close() }
                    throw JsonAssetBodyException()
                }
                if (index > 0) onAlias()
                return response
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val canAlias = when (failure) {
                    is DownloadStatusException -> failure.statusCode in 500..599
                    is IOException -> true
                    else -> false
                }
                if (index == routes.lastIndex || !canAlias) throw failure
            }
        }
        error("no-asset-route")
    }
}

internal data class UpdateSourceState(
    val selected: UpdateDownloadSource,
    val switching: Boolean = false,
    /** A real ranged response could not safely extend the existing prefix. */
    val restarted: Boolean = false,
    /**
     * The canonical route failed and the SAME asset was then served through
     * the validated official GitHub REST alias. Diagnostics only: the selected
     * source, the release identity and every integrity check are unchanged.
     */
    val officialAliasUsed: Boolean = false,
)
