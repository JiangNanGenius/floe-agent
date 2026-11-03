// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.dataexchange

import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Application-owned C07 job -> verified local share file. No view-page export. */
internal object C08TaskTranscriptExport {
    const val MAX_BYTES = 64L * 1024 * 1024

    suspend fun create(
        cacheDirectory: File,
        conversationID: String,
        epoch: Long,
        current: () -> Boolean,
        client: C07DataExchangeClient = C07DataExchangeClient(),
    ): File {
        val owner = C07ExchangeOwner(UUID.randomUUID().toString(), epoch)
        val root = File(cacheDirectory, "task-exports")
        check(root.mkdirs() || root.isDirectory)
        check(root.canonicalFile.parentFile == cacheDirectory.canonicalFile)
        // Existing grants expire with this cache policy; do not touch current files.
        val expiry = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        root.listFiles()?.filter { it.isFile && it.lastModified() < expiry }?.forEach { it.delete() }
        check((root.listFiles()?.sumOf { it.length() } ?: 0L) <= 256L * 1024 * 1024) { "taskExportCacheFull" }
        var jobID: String? = null
        var file: File? = null
        var complete = false
        try {
            return withTimeout(120_000) {
                check(current()) { "superseded" }
                val id = client.taskExportBegin(owner, conversationID)
                jobID = id
                var job: C07Job
                while (true) {
                    currentCoroutineContext().ensureActive()
                    check(current()) { "superseded" }
                    job = client.status(owner, id)
                    require(job.jobID == id && job.kind == "taskExport")
                    when (job.phase) {
                        "ready", "complete" -> break
                        "failed", "cancelled" -> throw C07ClientFailure(job.errorCode ?: "exportFailed", "taskExportFailed")
                        else -> delay(100)
                    }
                }
                val bytes = requireNotNull(job.fileByteCount)
                val expectedSha = requireNotNull(job.fileSha256)
                require(bytes in 1..MAX_BYTES && expectedSha.matches(Regex("[0-9a-f]{64}")))
                val destination = File.createTempFile("task-", ".jsonl", root)
                file = destination
                val digest = MessageDigest.getInstance("SHA-256")
                var offset = 0L
                destination.outputStream().use { output ->
                    while (offset < bytes) {
                        currentCoroutineContext().ensureActive()
                        check(current()) { "superseded" }
                        val chunk = client.read(owner, id, offset, C07DataExchangeClient.MAX_CHUNK)
                        require(chunk.totalBytes == bytes && chunk.nextOffset == offset + chunk.data.size &&
                            chunk.nextOffset <= bytes && chunk.data.isNotEmpty() && chunk.eof == (chunk.nextOffset == bytes))
                        output.write(chunk.data)
                        digest.update(chunk.data)
                        offset = chunk.nextOffset
                    }
                    output.flush()
                }
                val actualSha = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                require(offset == bytes && destination.length() == bytes && actualSha == expectedSha)
                check(current()) { "superseded" }
                complete = true
                destination
            }
        } finally {
            if (!complete) file?.delete()
            jobID?.let { id ->
                withContext(NonCancellable) {
                    if (!complete) runCatching { client.cancel(owner, id) }
                    runCatching { client.close(owner, id) }
                }
            }
        }
    }
}
