// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import moe.shizuku.adb.AdbClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AdbConnectDiagnosticsTest {

    @Test
    fun typedTransportFailuresBecomeBoundedTokens() {
        assertEquals(
            AdbConnectDiagnostics.TLS,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Connect("tls")),
        )
        assertEquals(
            AdbConnectDiagnostics.REFUSED,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Connect("connect")),
        )
        assertEquals(
            AdbConnectDiagnostics.HOST,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Connect("host")),
        )
        assertEquals(
            AdbConnectDiagnostics.IO,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Connect("io")),
        )
        assertEquals(
            AdbConnectDiagnostics.TIMEOUT,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Timeout("connect")),
        )
        assertEquals(
            AdbConnectDiagnostics.PROTOCOL,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Protocol("cnxn")),
        )
        assertEquals(
            AdbConnectDiagnostics.OUTPUT,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.OutputTooLarge(1024)),
        )
        assertEquals(
            AdbConnectDiagnostics.CONNECT,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Connect("other")),
        )

        val tokens = listOf(
            AdbConnectDiagnostics.CONNECT,
            AdbConnectDiagnostics.TLS,
            AdbConnectDiagnostics.REFUSED,
            AdbConnectDiagnostics.HOST,
            AdbConnectDiagnostics.IO,
            AdbConnectDiagnostics.TIMEOUT,
            AdbConnectDiagnostics.PROTOCOL,
            AdbConnectDiagnostics.OUTPUT,
        )
        tokens.forEach { token ->
            assertTrue(token, token.matches(Regex("^adb_connect(_[a-z_]+)?$")))
        }
    }

    @Test
    fun aTlsLayerFailureStaysADiagnosticTokenOnly() {
        // A client-side TLS failure must not be treated as a peer
        // authorization verdict; trust removal stays an explicit user action.
        assertEquals(
            AdbConnectDiagnostics.TLS,
            AdbConnectDiagnostics.codeFor(AdbClient.Failure.Connect("tls")),
        )
        assertTrue(AdbConnectDiagnostics.TLS.matches(Regex("^adb_connect_[a-z_]+$")))
    }
}
