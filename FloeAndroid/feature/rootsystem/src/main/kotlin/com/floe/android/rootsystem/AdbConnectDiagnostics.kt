// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem

import moe.shizuku.adb.AdbClient

/**
 * Bounded, secret-free diagnostic tokens for a failed embedded-ADB transport.
 *
 * The controller used to flatten every connection failure to `adb_connect`.
 * These tokens expose only the local failure class; no peer data, certificate,
 * token, command or exception text is included. In particular, a TLS-layer
 * failure is NOT proof that the peer rejected our identity: it can also be a
 * local cipher/protocol/IO failure or a server-certificate problem. Never
 * delete stored pairing trust from this classification alone.
 */
internal object AdbConnectDiagnostics {
    const val CONNECT = "adb_connect"
    const val TLS = "adb_connect_tls"
    const val REFUSED = "adb_connect_refused"
    const val HOST = "adb_connect_host"
    const val IO = "adb_connect_io"
    const val TIMEOUT = "adb_connect_timeout"
    const val PROTOCOL = "adb_connect_protocol"
    const val OUTPUT = "adb_connect_output"

    fun codeFor(failure: AdbClient.Failure): String = when (failure) {
        is AdbClient.Failure.Connect -> when (failure.code) {
            "tls" -> TLS
            "connect" -> REFUSED
            "host" -> HOST
            "io" -> IO
            else -> CONNECT
        }
        is AdbClient.Failure.Timeout -> TIMEOUT
        is AdbClient.Failure.Protocol -> PROTOCOL
        is AdbClient.Failure.OutputTooLarge -> OUTPUT
    }
}
