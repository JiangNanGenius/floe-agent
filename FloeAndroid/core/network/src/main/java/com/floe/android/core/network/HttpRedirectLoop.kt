// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.net.SocketTimeoutException
import java.util.concurrent.CancellationException

internal data class HttpHop(
    val target: HttpTarget,
    val statusCode: Int,
    val location: String?,
    val cipherSuite: String?,
    val contentType: String?,
    val contentLength: Long?,
    val headers: Map<String, String> = emptyMap(),
    val tlsProtocol: String? = null,
    val dnsMs: Long? = null,
    val tcpConnectMs: Long? = null,
    val tlsHandshakeMs: Long? = null,
    val responseHeadersMs: Long? = null,
    val totalMs: Long? = null,
)

internal class HttpFetchException(
    val status: ObservationStatus,
    val code: String,
    message: String? = null,
    val missingPermissions: List<String> = emptyList(),
) : Exception(message ?: code)

internal interface HttpFetcher {
    suspend fun fetch(target: HttpTarget, timeoutMs: Int): HttpHop
}

internal data class HttpChainResult(
    val status: ObservationStatus,
    val hops: List<HttpHop>,
    val finalTarget: HttpTarget?,
    val stoppedReason: String?,
    val limitations: List<String> = emptyList(),
    val missingPermissions: List<String> = emptyList(),
)

/**
 * Pure redirect walker. Every hop revalidates its exact scheme, userinfo,
 * host policy and redirect bound before the next request; a redirect to
 * cleartext or an unapproved destination is reported as partial, never
 * followed silently.
 */
internal object HttpRedirectLoop {
    private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)

    suspend fun follow(
        initial: HttpTarget,
        maxRedirects: Int,
        timeoutMs: Int,
        fetcher: HttpFetcher,
        elapsedMillis: () -> Long,
    ): HttpChainResult {
        val hops = ArrayList<HttpHop>()
        var current = initial
        var redirects = 0
        val deadline = elapsedMillis() + timeoutMs
        while (true) {
            val remaining = deadline - elapsedMillis()
            if (remaining <= 0L) {
                return HttpChainResult(
                    status = ObservationStatus.TIMEOUT,
                    hops = hops,
                    finalTarget = current,
                    stoppedReason = "timeout",
                    limitations = listOf("The HTTPS diagnostic exceeded its bounded timeout."),
                )
            }
            val hop = try {
                fetcher.fetch(current, remaining.toInt().coerceAtLeast(1))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: HttpFetchException) {
                val status = when {
                    failure.status == ObservationStatus.PERMISSION_REQUIRED -> ObservationStatus.PERMISSION_REQUIRED
                    hops.isEmpty() -> failure.status
                    else -> ObservationStatus.PARTIAL
                }
                return HttpChainResult(
                    status = status,
                    hops = hops,
                    finalTarget = current,
                    stoppedReason = failure.code,
                    limitations = listOfNotNull(failure.message),
                    missingPermissions = failure.missingPermissions,
                )
            } catch (_: SocketTimeoutException) {
                return HttpChainResult(
                    status = ObservationStatus.TIMEOUT,
                    hops = hops,
                    finalTarget = current,
                    stoppedReason = "timeout",
                    limitations = listOf("The HTTPS request timed out."),
                )
            } catch (failure: Exception) {
                return HttpChainResult(
                    status = ObservationStatus.ERROR,
                    hops = hops,
                    finalTarget = current,
                    stoppedReason = "requestFailed",
                    limitations = listOf(
                        "The HTTPS request failed (${failure.javaClass.simpleName.take(64)}).",
                    ),
                )
            }

            hops += hop
            val location = hop.location
            if (hop.statusCode in REDIRECT_CODES && !location.isNullOrBlank()) {
                if (redirects >= maxRedirects) {
                    return HttpChainResult(
                        status = ObservationStatus.PARTIAL,
                        hops = hops,
                        finalTarget = current,
                        stoppedReason = "redirectLimitReached",
                        limitations = listOf("The redirect limit was reached; the final location was not followed."),
                    )
                }
                val next = try {
                    current.resolveRedirect(location)
                } catch (failure: TargetSyntaxException) {
                    return HttpChainResult(
                        status = ObservationStatus.PARTIAL,
                        hops = hops,
                        finalTarget = current,
                        stoppedReason = "invalidRedirect",
                        limitations = listOf(failure.message ?: "The redirect target is invalid."),
                    )
                } catch (failure: TargetPolicyException) {
                    return HttpChainResult(
                        status = ObservationStatus.PARTIAL,
                        hops = hops,
                        finalTarget = current,
                        stoppedReason = failure.code,
                        limitations = listOf(failure.message ?: "The redirect target is not permitted."),
                    )
                }
                try {
                    NetworkTargetPolicy.checkHttpTargetPolicy(next)
                } catch (failure: TargetPolicyException) {
                    return HttpChainResult(
                        status = ObservationStatus.PARTIAL,
                        hops = hops,
                        finalTarget = current,
                        stoppedReason = failure.code,
                        limitations = listOf(failure.message ?: "The redirect target is not permitted."),
                    )
                }
                if (next.scheme != "https") {
                    return HttpChainResult(
                        status = ObservationStatus.PARTIAL,
                        hops = hops,
                        finalTarget = current,
                        stoppedReason = if (next.cleartext) {
                            "cleartextRedirectBlocked"
                        } else {
                            "unsupportedRedirectScheme"
                        },
                        limitations = listOf(
                            if (next.cleartext) {
                                "A redirect to cleartext HTTP was not followed."
                            } else {
                                "A redirect to a non-HTTPS scheme was not followed."
                            },
                        ),
                    )
                }
                current = next
                redirects++
                continue
            }
            return HttpChainResult(
                status = ObservationStatus.OK,
                hops = hops,
                finalTarget = current,
                stoppedReason = null,
            )
        }
    }
}
