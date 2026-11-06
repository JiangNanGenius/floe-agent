// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

/** Closed, non-sensitive diagnostics. Never accepts paths, commands or exception messages. */
data class LinuxSetupDiagnostic(val code: String, val stage: String, val exceptionType: String = "") {
    val category: String get() = when (code) {
        "HTTP_401", "HTTP_403", "HTTP_404", "HTTP_429", "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504" -> "server"
        "DISK_BUDGET", "ENOSPC", "INSTALL_FAILED_INSUFFICIENT_STORAGE" -> "storage"
        "UnknownHostException" -> "dns"
        "SocketTimeoutException", "TimeoutException" -> "timeout"
        "SSLHandshakeException", "SSLException" -> "tls"
        "TRANSPORT_FAILED", "ConnectException", "SocketException" -> "network"
        "DIGEST_MISMATCH", "ARCHIVE_TRUNCATED", "ARCHIVE_HEADER_CORRUPT", "DECODE_FAILED",
        "CONTENT_UNDERFLOW", "ARCHIVE_TOO_LARGE" -> "archive"
        "COMPONENT_CANCELLED" -> "cancelled"
        "COMPONENT_BLOCKED", "SecurityException" -> "permission"
        "RUNTIME_BUSY" -> "busy"
        "COMPONENT_INCOMPATIBLE" -> "compatibility"
        else -> "unknown"
    }
    companion object {
        private val token = Regex("[A-Za-z0-9_]{1,96}")
        private val stages = setOf("status", "component", "connect", "prepare", "preflight", "download",
            "verify_archive", "extract", "publish", "configure", "local_network", "unknown")
        fun fromFields(code: String, stage: String, type: String = "") = LinuxSetupDiagnostic(
            code.takeIf { it.matches(token) } ?: "OPERATION_FAILED",
            stage.takeIf { it in stages } ?: "unknown", type.takeIf { it.matches(token) }.orEmpty())
        fun fromThrowable(error: Throwable, stage: String): LinuxSetupDiagnostic {
            (error as? LinuxSetupException)?.let { return it.diagnostic }
            val causes = generateSequence(error) { it.cause }.take(8).toList()
            val known = causes.firstOrNull { it is java.net.UnknownHostException ||
                it is java.net.SocketTimeoutException || it is java.util.concurrent.TimeoutException ||
                it is javax.net.ssl.SSLException || it is java.net.ConnectException || it is SecurityException }
            val type = (known ?: error).javaClass.simpleName
            return fromFields(type, stage, type)
        }
    }
}

internal class LinuxSetupException(val diagnostic: LinuxSetupDiagnostic) : Exception(diagnostic.code)
