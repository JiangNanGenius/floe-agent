// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI

/**
 * Seam between the installer and the network. Production uses
 * [HttpsByteFetch]; component checks inject an in-memory fake to exercise
 * digest, budget, cancellation and cache logic without any real request.
 * There is no credential or header injection anywhere on this path.
 */
interface ByteFetch {
    /** contentLength is -1 when the transport cannot know the size. */
    fun open(httpsUrl: String): FetchedStream
}

class FetchedStream(val contentLength: Long, val stream: InputStream)

class HttpsByteFetch(
    private val connectTimeoutMs: Int = 30_000,
    private val readTimeoutMs: Int = 60_000,
) : ByteFetch {

    override fun open(httpsUrl: String): FetchedStream {
        if (!httpsUrl.startsWith("https://")) {
            throw RootfsInstallException(
                InstallFailure.INVALID_CATALOG, "refusing non-HTTPS source",
            )
        }
        val connection = (URI.create(httpsUrl).toURL().openConnection() as? HttpURLConnection)
            ?: throw RootfsInstallException(
                InstallFailure.TRANSPORT_FAILED, "unsupported connection for $httpsUrl",
            )
        try {
            connection.requestMethod = "GET"
            connection.connectTimeout = connectTimeoutMs
            connection.readTimeout = readTimeoutMs
            connection.instanceFollowRedirects = true
            connection.useCaches = false
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) {
                throw RootfsInstallException(
                    InstallFailure.TRANSPORT_FAILED, "HTTP $code from catalog source",
                )
            }
            // Every redirect hop must stay on HTTPS (URL's handler follows
            // same-protocol redirects only; re-check the final URL anyway).
            if (!connection.url.toString().startsWith("https://")) {
                throw RootfsInstallException(
                    InstallFailure.TRANSPORT_FAILED, "redirect left HTTPS scope",
                )
            }
            val length = connection.getHeaderFieldLong("Content-Length", -1L)
            return FetchedStream(length, connection.inputStream)
        } catch (e: RootfsInstallException) {
            connection.disconnect()
            throw e
        } catch (e: IOException) {
            connection.disconnect()
            throw RootfsInstallException(InstallFailure.TRANSPORT_FAILED, httpsUrl, e)
        }
    }
}
