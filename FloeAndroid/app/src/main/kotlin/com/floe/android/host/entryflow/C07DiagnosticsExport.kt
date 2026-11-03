// SPDX-License-Identifier: MPL-2.0
//
// User-driven, local-only feedback/diagnostics export.
//
// Sources are the REAL existing projections: the shared-core handshake, the
// App runtime readiness facts, the local task-execution closed stage token and
// the user's own report text. Nothing is uploaded, no endpoint/token/account is
// involved, and no settings/database/log store is duplicated. The final text is
// bounded and scrubbed before it is written to the exact SAF document the
// person chose with ACTION_CREATE_DOCUMENT.
package com.floe.android.host.entryflow

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import com.floe.android.BuildConfig
import com.floe.android.FloeApplication
import com.floe.android.bridge.SwiftCore
import com.floe.android.host.RuntimeHost
import com.floe.android.host.RuntimeHostReadiness
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject

/** One real export receipt over the exact bytes handed to the provider. */
internal data class C07ExportReceipt(
    val byteCount: Long,
    val sha256: String,
) {
    val sha256Prefix: String get() = sha256.take(16)
}

internal object C07EntryRedactor {
    private val patterns: List<Pair<Regex, String>> = listOf(
        Regex(
            "(?i)\\b(authorization|bearer|api[-_ ]?key|access[-_ ]?token|" +
                "refresh[-_ ]?token|session[-_ ]?token|password|secret|cookie)\\b" +
                "\\s*[:=]\\s*\\S+",
        ) to "$1=<redacted>",
        Regex("(?i)\\b(?:bearer|token)\\s+[A-Za-z0-9._~+/-]{20,}=*") to "<redacted-token>",
        Regex("\\bsk-[A-Za-z0-9_-]{16,}\\b") to "<redacted-key>",
        Regex("\\bgh[pousr]_[A-Za-z0-9]{20,}\\b") to "<redacted-key>",
        Regex("\\bgithub_pat_[A-Za-z0-9_]{20,}\\b") to "<redacted-key>",
        Regex("\\bAKIA[0-9A-Z]{16}\\b") to "<redacted-key>",
        Regex("\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b") to "<redacted-key>",
        Regex(
            "\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\b",
        ) to "<redacted-jwt>",
        Regex("/(?:Users|home)/[^\\s/]+(?:/[^\\s]*)?") to "<path>",
        Regex("/data/(?:user|data)/[^\\s]*") to "<path>",
        Regex("/storage/(?:emulated|self)/[^\\s]*") to "<path>",
        Regex("\\b(?:content|file)://[^\\s]*") to "<uri>",
        Regex("\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b") to "<email>",
        Regex("\\b[A-Za-z0-9+/]{96,}={0,2}\\b") to "<blob>",
    )

    fun redact(input: String): String {
        var output = input.filter { it.code == 0x09 || it.code == 0x0A || it.code >= 0x20 }
        for ((pattern, replacement) in patterns) {
            output = pattern.replace(output, replacement)
        }
        return output
    }

    /** Redact first, then enforce the byte cap without splitting a code point. */
    fun bounded(input: String, maxBytes: Int): String {
        val redacted = redact(input)
        val bytes = redacted.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return redacted
        val marker = "\n[truncated]\n"
        val budget = (maxBytes - marker.toByteArray(Charsets.UTF_8).size).coerceAtLeast(1)
        val output = StringBuilder(budget)
        var used = 0
        var index = 0
        while (index < redacted.length) {
            val codePoint = redacted.codePointAt(index)
            val chars = Character.charCount(codePoint)
            val encoded = String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8).size
            if (used + encoded > budget) break
            output.appendCodePoint(codePoint)
            used += encoded
            index += chars
        }
        return output.toString() + marker
    }
}

internal object C07DiagnosticsExport {
    const val MAX_REPORT_BYTES = 160 * 1024
    private const val MAX_PROBLEM_CHARS = ENTRY_MAX_FEEDBACK_CHARS

    /**
     * Builds the report from actual existing sources. Runs off the main thread
     * at the caller; the handshake and the Linux stage read are bounded reads.
     */
    suspend fun build(
        context: Context,
        host: RuntimeHost?,
        problem: String,
        includeDiagnostics: Boolean,
    ): String {
        val safeProblem = problem.trim().take(MAX_PROBLEM_CHARS)
        val builder = StringBuilder(4_096)
        builder.append("Floe Agent feedback\n")
        builder.append("generated_at: ").append(Instant.now().toString()).append('\n')
        builder.append("app_version: ").append(BuildConfig.VERSION_NAME).append('\n')
        builder.append("build: ").append(BuildConfig.VERSION_CODE).append('\n')
        builder.append("debug: ").append(BuildConfig.DEBUG).append('\n')
        builder.append("android_sdk: ").append(Build.VERSION.SDK_INT).append('\n')
        builder.append("\n== user_report ==\n")
        builder.append(safeProblem.ifBlank { "(no description)" }).append('\n')

        if (includeDiagnostics) {
            builder.append("\n== runtime ==\n")
            builder.append(runtimeText(host)).append('\n')

            builder.append("\n== shared_core ==\n")
            builder.append(sharedCoreText()).append('\n')

            builder.append("\n== local_task_execution ==\n")
            builder.append(localTaskText(context)).append('\n')

            builder.append("\n== content_note ==\n")
            builder.append(
                "No prompts, answers, messages, credentials, database rows, " +
                    "parsed files, screenshots or provider responses are included.\n",
            )
        }
        return C07EntryRedactor.bounded(builder.toString(), MAX_REPORT_BYTES)
    }

    private fun runtimeText(host: RuntimeHost?): String {
        val readiness = host?.readiness?.value ?: return "runtime: unavailable"
        val store = when (readiness.store) {
            is RuntimeHostReadiness.StoreReadiness.OwnedStoreReady -> "ready"
            is RuntimeHostReadiness.StoreReadiness.Failed -> "failed"
            RuntimeHostReadiness.StoreReadiness.Stopped -> "stopped"
            RuntimeHostReadiness.StoreReadiness.Idle -> "idle"
            is RuntimeHostReadiness.StoreReadiness.Starting -> "starting"
            RuntimeHostReadiness.StoreReadiness.WaitingGateway -> "waiting_gateway"
        }
        val gateway = when (readiness.gateway) {
            RuntimeHostReadiness.GatewayReadiness.Ready -> "ready"
            RuntimeHostReadiness.GatewayReadiness.Loading -> "loading"
            is RuntimeHostReadiness.GatewayReadiness.Failed -> "failed"
        }
        return buildString {
            append("runtime_store: ").append(store).append('\n')
            append("runtime_gateway: ").append(gateway).append('\n')
            append("domains: ").append(readiness.domains.size).append('\n')
            append("conversation_domain: ").append(readiness.conversationDomainAdmitted).append('\n')
            append("run_domain: ").append(readiness.runDomainAdmitted).append('\n')
            append("temporary_domain: ").append(readiness.temporaryDomainAdmitted).append('\n')
            append("attachment_staging: ").append(readiness.attachmentStagingAdmitted).append('\n')
            append("provider_configuration: ")
                .append(readiness.providerConfigurationAdmitted).append('\n')
        }
    }

    private fun sharedCoreText(): String = try {
        val response = JSONObject(SwiftCore.handshake())
        "shared_core_ok: " + response.optBoolean("ok", false) + "\n" +
            "shared_core_version: " + response.optInt("version", -1)
    } catch (_: Throwable) {
        "shared_core_ok: false\nshared_core_version: -1"
    }

    private suspend fun localTaskText(context: Context): String {
        val app = context.applicationContext as? FloeApplication ?: return "lane:unbound"
        return try {
            app.linuxTaskExecutionDiagnostic()
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            "lane:unbound"
        }
    }

    /**
     * Writes the exact report to the newly created SAF document. The result
     * URI is required to be `content:` with a live write grant, the payload is
     * capped before opening, and a failed/cancelled write removes the partial
     * document with DocumentsContract (best effort) instead of leaving a
     * silent half-report.
     */
    suspend fun write(
        context: Context,
        uri: Uri,
        text: String,
        resultFlags: Int,
    ): C07ExportReceipt {
        if (uri.scheme != "content") throw IOException("invalidDestination")
        if ((resultFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == 0) {
            throw IOException("writeGrantMissing")
        }
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > MAX_REPORT_BYTES) throw IOException("invalidSize")
        val resolver = context.contentResolver
        // Best-effort no-overwrite guard: CREATE_DOCUMENT normally returns a
        // new empty document, but a provider that hands back an existing
        // non-empty document must not be truncated by this export.
        val existingSize = runCatching {
            resolver.openFileDescriptor(uri, "r")?.use { it.statSize }
        }.getOrNull()
        if (existingSize != null && existingSize > 0L) {
            throw IOException("destinationNotEmpty")
        }
        val digest = MessageDigest.getInstance("SHA-256")
        var completed = false
        try {
            val stream = resolver.openOutputStream(uri, "wt") ?: throw IOException("openFailed")
            stream.use { output ->
                var offset = 0
                while (offset < bytes.size) {
                    currentCoroutineContext().ensureActive()
                    val count = minOf(32 * 1024, bytes.size - offset)
                    output.write(bytes, offset, count)
                    digest.update(bytes, offset, count)
                    offset += count
                }
                output.flush()
            }
            completed = true
        } finally {
            if (!completed) {
                runCatching { DocumentsContract.deleteDocument(resolver, uri) }
                    .onFailure { runCatching { resolver.delete(uri, null, null) } }
            }
        }
        return C07ExportReceipt(
            byteCount = bytes.size.toLong(),
            sha256 = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) },
        )
    }

    /** A bounded filename hint; the provider chooses the final location. */
    fun suggestedFileName(): String =
        "floe-feedback-" + Instant.now().toString().replace(':', '-').take(19) + ".txt"
}
