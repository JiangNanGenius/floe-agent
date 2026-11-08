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
        "RUNTIME_BUSY", "environment_transaction_busy", "environment_transaction_requires_idle" -> "busy"
        "RUNTIME_CONNECTION_FAILED", "runtime_not_ready" -> "runtime"
        "COMPONENT_INCOMPATIBLE" -> "compatibility"
        // Bundled runtime-component preparation boundaries: closed, finite
        // codes so a component-stage failure names ONE check instead of
        // collapsing into an undifferentiated IllegalStateException.
        "COMPONENT_STAGING_UNAVAILABLE" -> "storage"
        "COMPONENT_ASSET_UNAVAILABLE", "COMPONENT_COPY_FAILED", "COMPONENT_SIZE_EXCEEDED", "COMPONENT_DIGEST_MISMATCH",
        "COMPONENT_ARCHIVE_UNREADABLE", "COMPONENT_PACKAGE_MISMATCH", "COMPONENT_VERSION_MISMATCH",
        "COMPONENT_CERTIFICATE_UNAVAILABLE", "COMPONENT_IDENTITY_MISMATCH",
        "COMPONENT_SESSION_FAILED", "COMPONENT_INSTALL_FAILED" -> "component"
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
            val type = (known ?: causes.last()).javaClass.simpleName
            return fromFields(type, stage, type)
        }
    }
}

internal class LinuxSetupException(val diagnostic: LinuxSetupDiagnostic, cause: Throwable? = null) : Exception(diagnostic.code, cause)
