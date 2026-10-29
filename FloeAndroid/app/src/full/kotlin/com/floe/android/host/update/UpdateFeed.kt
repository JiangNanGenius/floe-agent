// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.update

import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI

/**
 * Public, credential-free GitHub release feed access.
 *
 * The updater reads only the repository's own Releases API listing (which the
 * repository publishes for the Android channel as `android/v*` prereleases).
 * No token, cookie, header dump, prompt content or credential is ever read or
 * logged here; requests are anonymous and bounded.
 */
internal sealed class FeedFailure(message: String) : Exception(message) {
    class Transport(detail: String) : FeedFailure(detail)
    class RateLimited : FeedFailure("github-rate-limited")
}

internal data class FeedPage(val body: String, val nextPage: Int?)

internal interface ReleaseFeed {
    fun fetchPage(page: Int): FeedPage
}

internal class GitHubAndroidReleaseFeed(
    owner: String,
    repo: String,
    private val connectTimeoutMs: Int = 20_000,
    private val readTimeoutMs: Int = 30_000,
    private val maxPageBytes: Long = 2L * 1024L * 1024L,
) : ReleaseFeed {

    private val base = "https://api.github.com/repos/$owner/$repo/releases"

    override fun fetchPage(page: Int): FeedPage {
        if (page < 1 || page > MAX_PAGES) throw FeedFailure.Transport("page-out-of-range")
        val connection = try {
            (URI.create("$base?per_page=30&page=$page").toURL().openConnection() as? HttpURLConnection)
        } catch (failure: IOException) {
            throw FeedFailure.Transport("connection-open-failed")
        } ?: throw FeedFailure.Transport("unsupported-connection")
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.instanceFollowRedirects = true
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/vnd.github+json")
            connection.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
            // GitHub requires a User-Agent; this identifies the app only.
            connection.setRequestProperty("User-Agent", "floe-android-update")
            val code = connection.responseCode
            if (code == HttpURLConnection.HTTP_FORBIDDEN || code == 429) {
                if (connection.getHeaderField("X-RateLimit-Remaining") == "0" || code == 429) {
                    throw FeedFailure.RateLimited()
                }
                throw FeedFailure.Transport("http-$code")
            }
            if (code != HttpURLConnection.HTTP_OK) throw FeedFailure.Transport("http-$code")
            if (!connection.url.toString().startsWith("https://")) {
                throw FeedFailure.Transport("redirect-left-https")
            }
            val body = connection.inputStream.use { readBounded(it, maxPageBytes) }
            val nextPage = GitHubLinkHeader.nextPage(connection.getHeaderField("Link"), MAX_PAGES)
            return FeedPage(body = body, nextPage = nextPage)
        } catch (failure: FeedFailure) {
            connection.disconnect()
            throw failure
        } catch (failure: IOException) {
            connection.disconnect()
            throw FeedFailure.Transport("io")
        }
    }

    private fun readBounded(input: InputStream, limit: Long): String {
        val builder = StringBuilder()
        val buffer = ByteArray(16 * 1024)
        var total = 0L
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > limit) throw FeedFailure.Transport("feed-oversized")
            builder.append(String(buffer, 0, count, Charsets.UTF_8))
        }
        return builder.toString()
    }

    companion object {
        /** Bounded pagination: 3 pages cover the current Android release history. */
        const val MAX_PAGES = 3
    }
}

/**
 * Redirect-aware HTTPS GET for the downloadable artifacts (APK and its
 * SHA256SUMS). Resume sends `Range` plus `If-Range` so the server decides
 * whether the staged prefix still belongs to the same artifact.
 */
internal data class DownloadResponse(
    val code: Int,
    val contentLength: Long,
    val contentRangeStart: Long?,
    val contentRangeTotal: Long?,
    val etag: String?,
    val stream: InputStream,
)

internal interface DownloadTransport {
    fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse
}

internal class HttpsDownloadTransport(
    private val connectTimeoutMs: Int = 30_000,
    private val readTimeoutMs: Int = 60_000,
) : DownloadTransport {

    override fun open(url: String, rangeFrom: Long?, ifRangeEtag: String?): DownloadResponse {
        if (!url.startsWith("https://")) throw IOException("refusing non-HTTPS source")
        val connection = try {
            (URI.create(url).toURL().openConnection() as? HttpURLConnection)
        } catch (failure: IOException) {
            throw IOException("connection-open-failed", failure)
        } ?: throw IOException("unsupported-connection")
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.instanceFollowRedirects = true
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/octet-stream")
            connection.setRequestProperty("User-Agent", "floe-android-update")
            if (rangeFrom != null && rangeFrom > 0L) {
                connection.setRequestProperty("Range", "bytes=$rangeFrom-")
                if (!ifRangeEtag.isNullOrEmpty()) connection.setRequestProperty("If-Range", ifRangeEtag)
            }
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK && code != 206) {
                throw IOException("http-$code")
            }
            if (!connection.url.toString().startsWith("https://")) {
                throw IOException("redirect-left-https")
            }
            val contentRange = connection.getHeaderField("Content-Range")
            val (rangeStart, rangeTotal) = parseContentRange(contentRange)
            return DownloadResponse(
                code = code,
                contentLength = connection.getHeaderFieldLong("Content-Length", -1L),
                contentRangeStart = rangeStart,
                contentRangeTotal = rangeTotal,
                etag = connection.getHeaderField("ETag"),
                stream = connection.inputStream,
            )
        } catch (failure: IOException) {
            connection.disconnect()
            throw failure
        }
    }

    /** `bytes <start>-<end>/<total>`; both numbers absent for `*` totals. */
    private fun parseContentRange(header: String?): Pair<Long?, Long?> {
        if (header.isNullOrBlank()) return null to null
        val match = CONTENT_RANGE.matchEntire(header.trim()) ?: return null to null
        val start = match.groupValues[1].toLongOrNull()
        val end = match.groupValues[2].toLongOrNull()
        val total = match.groupValues[3].toLongOrNull()
        // The start must be real; the total may legitimately be `*`.
        if (start == null) return null to null
        return start to (total ?: end?.plus(1L))
    }

    private companion object {
        val CONTENT_RANGE = Regex("^bytes\\s+(\\d{1,12})-(\\d{1,12})/(\\d{1,12}|\\*)$")
    }
}
