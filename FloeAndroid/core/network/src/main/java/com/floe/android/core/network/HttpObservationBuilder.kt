// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import org.json.JSONArray
import org.json.JSONObject

/** Pure HTTPS result builder; keeps raw Location headers out of the output. */
internal object HttpObservationBuilder {
    private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)

    fun build(initial: HttpTarget, chain: HttpChainResult, probeTotalMs: Long): ProbeResult {
        val last = chain.hops.lastOrNull()
        val observations = JSONObject().apply {
            put("requestedUrl", initial.redacted)
            put("redirectCount", chain.hops.count { it.statusCode in REDIRECT_CODES })
            put("bodyRead", false)
            put("probeTotalMs", probeTotalMs)
            put(
                "redirects",
                JSONArray().apply {
                    chain.hops.forEachIndexed { index, hop ->
                        put(
                            JSONObject()
                                .put("url", hop.target.redacted)
                                .put("statusCode", hop.statusCode)
                                .apply {
                                    chain.hops.getOrNull(index + 1)?.let {
                                        put("redirectedTo", it.target.redacted)
                                    }
                                },
                        )
                    }
                },
            )
            if (last != null) {
                put("finalUrl", last.target.redacted)
                put("statusCode", last.statusCode)
                last.contentType?.let { put("contentType", it) }
                last.contentLength?.takeIf { it >= 0 }?.let { put("contentLength", it) }
                // Location is deliberately NOT copied into responseHeaders:
                // it may carry one-time auth query tokens. Redirect targets are
                // already redacted in the redirects array.
                put("responseHeaders", JSONObject().apply {
                    last.headers.forEach { (name, value) ->
                        if (!name.equals("location", ignoreCase = true)) {
                            put(name, value)
                        }
                    }
                })
                put("tls", JSONObject().apply {
                    last.tlsProtocol?.let { put("protocol", it) }
                    last.cipherSuite?.let { put("cipherSuite", it) }
                    put("certificateChainAnalyzed", (last.certificateObservation?.optInt("inspectedCount", 0) ?: 0) > 0)
                    last.certificateObservation?.let { put("peerCertificates", it) }
                    put("hostnameVerification", "platformDefault")
                    put("trust", "platformDefault")
                })
                put("phaseTimings", JSONObject().apply {
                    last.dnsMs?.let { put("dnsMs", it) }
                    last.tcpConnectMs?.let { put("tcpConnectMs", it) }
                    last.tlsHandshakeMs?.let { put("tlsHandshakeMs", it) }
                    last.responseHeadersMs?.let { put("responseHeadersMs", it) }
                    last.totalMs?.let { put("totalMs", it) }
                })
                put("phaseTimingsNote", JSONArray().apply {
                    put("dnsMs is the preflight resolution on the captured Network before the socket is pinned to a verified address.")
                    put("tcpConnectMs is the TCP connect to the pinned address.")
                    put("tlsHandshakeMs is the TLS handshake using platform default trust and hostname verification.")
                    put("responseHeadersMs covers request write and response-header read; no body is read.")
                    put("totalMs is the final hop total; probeTotalMs includes redirects.")
                })
            }
            chain.stoppedReason?.let { put("stoppedReason", it) }
        }
        val limitations = ArrayList<String>()
        limitations += chain.limitations
        limitations += "Only HTTPS is used in this batch; cleartext HTTP and non-HTTPS redirects are not followed."
        limitations += "The destination name is resolved once and the TCP socket is pinned to a verified address; the original hostname is still used for SNI and platform default hostname verification."
        limitations += "The diagnostic connects directly on the captured Network and does not use an app HTTP proxy."
        limitations += "Certificate metadata is available only after platform trust and hostname verification succeed; no insecure retry, independent trust-path or revocation check is performed."
        limitations += "No cookies or Authorization headers are sent and no response body is read."
        if (chain.stoppedReason != null) {
            limitations += "The HTTPS diagnostic stopped with: ${chain.stoppedReason}."
        }
        return ProbeResult(
            status = chain.status,
            observations = observations,
            limitations = limitations,
            target = initial.redacted,
            missingPermissions = chain.missingPermissions,
        )
    }
}
