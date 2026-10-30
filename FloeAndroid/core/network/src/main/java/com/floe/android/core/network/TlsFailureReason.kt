// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import java.security.cert.CertificateException
import java.security.cert.CertPathValidatorException

/** Bounded cause inspection without exporting server names or exception prose. */
internal object TlsFailureReason {
    fun code(failure: Throwable): String {
        var current: Throwable? = failure
        val visited = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<Throwable, Boolean>())
        var trustFailure = false
        repeat(16) {
            val cause = current ?: return if (trustFailure) "tlsTrustVerificationFailed" else "tlsFailure"
            if (!visited.add(cause)) return if (trustFailure) "tlsTrustVerificationFailed" else "tlsFailure"
            when (cause) {
                is CertificateExpiredException -> return "tlsCertificateExpired"
                is CertificateNotYetValidException -> return "tlsCertificateNotYetValid"
                is CertPathValidatorException -> when (cause.reason) {
                    CertPathValidatorException.BasicReason.EXPIRED -> return "tlsCertificateExpired"
                    CertPathValidatorException.BasicReason.NOT_YET_VALID -> return "tlsCertificateNotYetValid"
                    else -> trustFailure = true
                }
                is CertificateException -> trustFailure = true
            }
            current = cause.cause
        }
        return if (trustFailure) "tlsTrustVerificationFailed" else "tlsFailure"
    }
}
