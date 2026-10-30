// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.network

import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import java.security.cert.CertPathValidatorException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.assertEquals
import org.junit.Test

class TlsFailureReasonTest {
    @Test fun expiredAndFutureCertificatesRetainTheirCauseWithoutMessageHeuristics() {
        assertEquals("tlsCertificateExpired", TlsFailureReason.code(
            SSLHandshakeException("hidden.host").apply { initCause(CertificateExpiredException()) }))
        assertEquals("tlsCertificateNotYetValid", TlsFailureReason.code(
            SSLHandshakeException("hidden.host").apply { initCause(CertificateNotYetValidException()) }))
    }
    @Test fun pathFailureAndUnknownTlsFailureRemainDistinct() {
        assertEquals("tlsTrustVerificationFailed", TlsFailureReason.code(
            SSLHandshakeException("private endpoint").apply { initCause(CertPathValidatorException()) }))
        assertEquals("tlsFailure", TlsFailureReason.code(SSLHandshakeException("expired is only prose")))
    }
    @Test fun platformPathReasonsDoNotNeedAnExpiredExceptionChild() {
        val expired = CertPathValidatorException("private", null, null, -1, CertPathValidatorException.BasicReason.EXPIRED)
        val future = CertPathValidatorException("private", null, null, -1, CertPathValidatorException.BasicReason.NOT_YET_VALID)
        assertEquals("tlsCertificateExpired", TlsFailureReason.code(expired))
        assertEquals("tlsCertificateNotYetValid", TlsFailureReason.code(future))
    }
    @Test fun cyclicCauseIsBounded() {
        val a = Exception("a")
        val b = Exception("b", a)
        a.initCause(b)
        assertEquals("tlsFailure", TlsFailureReason.code(a))
    }
}
