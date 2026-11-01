// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.creative

import com.floe.android.feature.canvas.CreativeException
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

data class CreativeStagedBytes(val byteCount: Long, val sha256: String)

/**
 * Bounded SAF/stream copy into a caller-owned staging target. The pump never
 * interprets an arbitrary path: the caller supplies a File already validated
 * under the accepted root. Partial bytes are deleted on any failure or
 * cancellation, and the final name appears only after a complete fsync.
 */
internal class CreativeSourcePump(
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    suspend fun stage(
        input: InputStream,
        target: File,
        maximumBytes: Long,
        isCancelled: () -> Boolean = { false },
    ): CreativeStagedBytes = withContext(ioDispatcher) {
        require(maximumBytes > 0)
        val directory = target.parentFile
            ?: throw CreativeException("assetStagingInvalid", "missingStagingDirectory")
        if (!directory.isDirectory && !directory.mkdirs()) {
            throw CreativeException("assetStagingUnavailable", "stagingUnavailable", retryable = true)
        }
        if (target.exists()) {
            throw CreativeException("assetStagingInvalid", "stagingTokenCollision")
        }
        val part = File(directory, ".${target.name}.${UUID.randomUUID()}.part")
        var total = 0L
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            FileOutputStream(part).use { output ->
                val buffer = ByteArray(1 shl 20)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    if (isCancelled()) throw CancellationException("creative import cancelled")
                    val read = input.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    total += read
                    if (total > maximumBytes) {
                        throw CreativeException(
                            "assetTooLarge", "stagedAssetTooLarge", retryable = false)
                    }
                    digest.update(buffer, 0, read)
                    output.write(buffer, 0, read)
                }
                output.flush()
                output.fd.sync()
            }
            if (total <= 0L) throw CreativeException("assetEmpty", "stagedAssetEmpty")
            val digestHex = digest.digest().joinToString("") { "%02x".format(it) }
            if (!part.renameTo(target)) {
                throw CreativeException("assetStagingUnavailable", "stagingCommitFailed", retryable = true)
            }
            CreativeStagedBytes(total, digestHex)
        } catch (error: CancellationException) {
            part.delete()
            throw error
        } catch (error: CreativeException) {
            part.delete()
            throw error
        } catch (error: Throwable) {
            part.delete()
            throw CreativeException(
                "assetStagingUnavailable", "stagingReadFailed", retryable = true, cause = error)
        } finally {
            part.delete()
        }
    }

    fun discard(target: File) {
        target.delete()
    }
}
