// SPDX-License-Identifier: MPL-2.0
//
// Bounded write of one prepared meeting export to the exact system document
// the user selected. A successful result requires a complete write followed by
// an identical read-back; partial writes, revoked grants and provider errors
// are reported as failures, never as "saved".
package com.floe.android.host.meetingexchange

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal class MeetingDocumentWriter(
    private val stager: MeetingExportStager,
    private val maxBytes: Long = MeetingExportFormatter.MAX_EXPORT_BYTES,
) {
    /**
     * Coroutine cancellation is propagated after the staged source is deleted.
     * A cancelled call is never a saved result; the system provider may have
     * received a partial document. The caller owns that user-visible state.
     */
    suspend fun write(
        target: MeetingDocumentTarget,
        selectedMeetingId: String?,
        openOutput: () -> OutputStream?,
        openReadback: () -> InputStream?,
    ): MeetingDocumentWriteResult {
        currentCoroutineContext().ensureActive()
        if (target.meetingId != target.document.meetingId) {
            return failed(MeetingExportFailureCode.MEETING_CHANGED)
        }
        if (selectedMeetingId == null || selectedMeetingId != target.meetingId) {
            return failed(MeetingExportFailureCode.MEETING_CHANGED)
        }
        if (!target.uri.startsWith("content://")) {
            return failed(MeetingExportFailureCode.INVALID_DESTINATION)
        }
        if (target.document.byteCount <= 0L || target.document.byteCount > maxBytes) {
            return failed(MeetingExportFailureCode.TOO_LARGE)
        }

        val staged = try {
            stager.stage(target.document)
        } catch (_: MeetingExportSizeException) {
            return failed(MeetingExportFailureCode.TOO_LARGE)
        } catch (_: Exception) {
            return failed(MeetingExportFailureCode.WRITE_FAILED)
        }

        try {
            currentCoroutineContext().ensureActive()
            if (staged.byteCount <= 0L || staged.byteCount > maxBytes) {
                return failed(MeetingExportFailureCode.TOO_LARGE)
            }
            val empty = try {
                val input = openReadback() ?: return failed(MeetingExportFailureCode.DESTINATION_UNREADABLE)
                input.use { it.read() == -1 }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: SecurityException) {
                return failed(MeetingExportFailureCode.WRITE_PERMISSION_MISSING)
            } catch (_: IOException) {
                return failed(MeetingExportFailureCode.DESTINATION_UNREADABLE)
            } catch (_: Exception) {
                return failed(MeetingExportFailureCode.DESTINATION_UNREADABLE)
            }
            if (!empty) {
                return failed(MeetingExportFailureCode.DESTINATION_NOT_EMPTY)
            }

            val receipt = try {
                transfer(
                    source = staged.file,
                    expectedBytes = staged.byteCount,
                    openOutput = {
                        openOutput() ?: throw IOException("destinationWriteUnavailable")
                    },
                    openReadback = {
                        openReadback() ?: throw IOException("destinationReadUnavailable")
                    },
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: SecurityException) {
                return failed(MeetingExportFailureCode.WRITE_PERMISSION_MISSING)
            } catch (_: IOException) {
                return failed(MeetingExportFailureCode.WRITE_FAILED)
            } catch (_: Exception) {
                return failed(MeetingExportFailureCode.WRITE_FAILED)
            }
            if (receipt.bytes != staged.byteCount) {
                return failed(MeetingExportFailureCode.WRITE_FAILED)
            }
            return MeetingDocumentWriteResult.Written(receipt.bytes, receipt.sha256)
        } finally {
            staged.delete()
        }
    }

    /**
     * Streams the staged bytes, then reads the destination back and requires
     * the same length and SHA-256. A provider that drops, truncates or changes
     * bytes can therefore never produce a "saved" result.
     */
    private suspend fun transfer(
        source: File,
        expectedBytes: Long,
        openOutput: () -> OutputStream,
        openReadback: () -> InputStream,
    ): TransferReceipt {
        val buffer = ByteArray(64 * 1024)
        val digest = MessageDigest.getInstance("SHA-256")
        var written = 0L
        currentCoroutineContext().ensureActive()
        source.inputStream().use { input ->
            openOutput().use { output ->
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val read = input.read(buffer)
                    if (read < 0) break
                    written += read
                    require(written <= expectedBytes) { "sourceChanged" }
                    output.write(buffer, 0, read)
                    digest.update(buffer, 0, read)
                }
                require(written == expectedBytes) { "sourceChanged" }
                output.flush()
            }
        }
        val expectedDigest = digest.digest()

        val readbackDigest = MessageDigest.getInstance("SHA-256")
        var readback = 0L
        var zeroReads = 0
        currentCoroutineContext().ensureActive()
        openReadback().use { input ->
            while (true) {
                currentCoroutineContext().ensureActive()
                val read = input.read(buffer)
                if (read < 0) break
                if (read == 0) {
                    if (++zeroReads > 3) throw IOException("readStalled")
                    continue
                }
                zeroReads = 0
                readback += read
                require(readback <= expectedBytes) { "receiptMismatch" }
                readbackDigest.update(buffer, 0, read)
            }
        }
        require(readback == expectedBytes && MessageDigest.isEqual(expectedDigest, readbackDigest.digest())) {
            "receiptMismatch"
        }
        currentCoroutineContext().ensureActive()
        return TransferReceipt(
            bytes = written,
            sha256 = expectedDigest.joinToString("") { "%02x".format(it.toInt() and 0xff) },
        )
    }

    private fun failed(code: MeetingExportFailureCode): MeetingDocumentWriteResult =
        MeetingDocumentWriteResult.Failed(MeetingExportFailure(code))

    private data class TransferReceipt(val bytes: Long, val sha256: String)
}
