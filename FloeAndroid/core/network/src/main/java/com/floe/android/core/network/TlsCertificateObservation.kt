// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.security.MessageDigest
import java.security.cert.Certificate
import java.security.cert.X509Certificate
import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject

/** Peer metadata only, collected AFTER the platform trust/hostname checks.
 * Never a replacement trust manager, revocation check or certificate pin. */
internal object TlsCertificateObservation {
    private const val MAX_CERTIFICATES = 8
    private const val MAX_CERTIFICATE_BYTES = 256 * 1024
    private const val MAX_TOTAL_BYTES = 1024 * 1024

    fun capture(chain: Array<Certificate>, observedAtMillis: Long): JSONObject {
        val certificates = JSONArray()
        var bytes = 0
        var truncated = chain.size > MAX_CERTIFICATES
        var unreadable = 0
        for ((index, certificate) in chain.take(MAX_CERTIFICATES).withIndex()) {
            val x509 = certificate as? X509Certificate
            if (x509 == null) { unreadable++; continue }
            try {
                val der = x509.encoded
                if (der.size > MAX_CERTIFICATE_BYTES || der.size > MAX_TOTAL_BYTES - bytes) {
                    truncated = true
                    break
                }
                bytes += der.size
                val notBefore = x509.notBefore.time
                val notAfter = x509.notAfter.time
                certificates.put(JSONObject()
                    .put("chainIndex", index)
                    .put("sha256", MessageDigest.getInstance("SHA-256").digest(der)
                        .joinToString("") { "%02x".format(it.toInt() and 255) })
                    .put("subject", safe(x509.subjectX500Principal.name))
                    .put("issuer", safe(x509.issuerX500Principal.name))
                    .put("alternativeNames", alternativeNames(x509))
                    .put("alternativeNamesTruncated", x509.subjectAlternativeNames.orEmpty().size > 16)
                    .put("notBefore", Instant.ofEpochMilli(notBefore).toString())
                    .put("notAfter", Instant.ofEpochMilli(notAfter).toString())
                    .put("validAtObservation", observedAtMillis >= notBefore && observedAtMillis <= notAfter)
                    .put("notYetValid", observedAtMillis < notBefore)
                    .put("expired", observedAtMillis > notAfter)
                    .put("signatureAlgorithm", safe(x509.sigAlgName))
                    .put("publicKeyAlgorithm", safe(x509.publicKey.algorithm))
                    .put("certificateAuthority", x509.basicConstraints >= 0))
            } catch (failure: java.security.GeneralSecurityException) {
                unreadable++
            } catch (failure: IllegalArgumentException) {
                unreadable++
            }
        }
        return JSONObject()
            .put("analysis", "peerMetadataOnly")
            .put("observedAt", Instant.ofEpochMilli(observedAtMillis).toString())
            .put("presentedCount", chain.size)
            .put("inspectedCount", certificates.length())
            .put("truncated", truncated)
            .put("unreadableCount", unreadable)
            .put("revocationChecked", false)
            .put("certificates", certificates)
    }

    private fun alternativeNames(certificate: X509Certificate): JSONArray = JSONArray().apply {
        // DNS/IP identities only, never email or URI query/userinfo material.
        certificate.subjectAlternativeNames.orEmpty().take(16).forEach { entry ->
            val type = entry.getOrNull(0) as? Int ?: return@forEach
            val value = entry.getOrNull(1) as? String ?: return@forEach
            if (type == 2 || type == 7) put(JSONObject()
                .put("type", if (type == 2) "DNS" else "IP").put("value", safe(value)))
        }
    }

    private fun safe(value: String): String = value.filterNot { it.isISOControl() }.take(128)
}
