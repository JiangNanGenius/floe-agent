// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.networkartifact

import com.floe.android.core.pcap.PcapAnalysisOptions
import com.floe.android.core.pcap.PcapAnalysisStatus
import com.floe.android.core.pcap.PcapAnalyzer
import com.floe.android.core.pcap.PcapCancellation
import com.floe.android.core.pcap.PcapCaptureFormat
import com.floe.android.core.pcap.PcapLimits
import com.floe.android.core.pcap.PcapSource
import com.floe.android.core.pcap.PcapSummary
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.UUID

/** Explicit SAF/content seam; production resolves one picked URI, tests inject bytes. */
interface PcapContentSource {
    val displayName: String?
    val mimeType: String?
    val declaredBytes: Long?
    fun openStream(): InputStream
}

enum class PcapImportFailure {
    SOURCE_TOO_LARGE,
    SOURCE_UNAVAILABLE,
    UNSUPPORTED_FORMAT,
    READ_FAILED,
    STORE_FAILED,
    STORE_FULL,
    CANCELLED,
}

sealed interface PcapImportResult {
    data class Success(val analysisID: String, val summary: PcapSummary) : PcapImportResult
    data class Failure(val failure: PcapImportFailure) : PcapImportResult
}

internal class FilePcapSource(
    private val file: File,
    override val label: String?,
) : PcapSource {
    override val sizeBytes: Long get() = file.length()
    override fun openStream(): InputStream = FileInputStream(file)
}

/**
 * Copies one picked capture into an App-private staging file in 64 KiB
 * chunks with the existing 128 MiB cap, analyses it under the 30 s / 2 M
 * packet / 65k flow bounds, stores the bounded summary, and deletes the raw
 * copy in `finally` on every path. No arbitrary path or URI is accepted.
 */
class PcapImportRunner(
    private val store: com.floe.android.core.pcap.PcapAnalysisStore,
    private val stagingDirectory: File,
    private val analyzer: PcapAnalyzer = PcapAnalyzer(),
    private val idFactory: () -> String = { UUID.randomUUID().toString() },
    private val now: () -> Long = System::currentTimeMillis,
    private val maxStoredAnalyses: Int = PcapLimits.MAX_STORED_ANALYSES,
) {
    fun import(
        source: PcapContentSource,
        detailed: Boolean,
        ownerTaskId: String? = null,
        ownerWorkspaceId: String? = null,
        agentReadable: Boolean = false,
        cancellation: PcapCancellation = PcapCancellation.NONE,
        onProgress: (Long) -> Unit = {},
    ): PcapImportResult {
        val declared = source.declaredBytes
        if (declared != null && declared > PcapLimits.MAX_SOURCE_BYTES) {
            return PcapImportResult.Failure(PcapImportFailure.SOURCE_TOO_LARGE)
        }
        if (store.list().size >= maxStoredAnalyses) {
            return PcapImportResult.Failure(PcapImportFailure.STORE_FULL)
        }
        val analysisID = idFactory()
        require(runCatching { UUID.fromString(analysisID) }.isSuccess) { "analysis ID must be a UUID" }
        if (!stagingDirectory.isDirectory && !stagingDirectory.mkdirs()) {
            return PcapImportResult.Failure(PcapImportFailure.READ_FAILED)
        }
        val raw = File(stagingDirectory, "capture-$analysisID.part")
        var copied = 0L
        var stream: InputStream? = null
        try {
            stream = try {
                source.openStream()
            } catch (_: SecurityException) {
                return PcapImportResult.Failure(PcapImportFailure.SOURCE_UNAVAILABLE)
            } catch (_: IOException) {
                return PcapImportResult.Failure(PcapImportFailure.SOURCE_UNAVAILABLE)
            }
            FileOutputStream(raw, false).use { output ->
                val buffer = ByteArray(CHUNK_BYTES)
                while (true) {
                    if (cancellation.isCancelled()) {
                        return PcapImportResult.Failure(PcapImportFailure.CANCELLED)
                    }
                    val read = try {
                        stream.read(buffer, 0, buffer.size)
                    } catch (_: IOException) {
                        return PcapImportResult.Failure(PcapImportFailure.READ_FAILED)
                    }
                    if (read < 0) break
                    if (read == 0) continue
                    copied += read
                    if (copied > PcapLimits.MAX_SOURCE_BYTES) {
                        return PcapImportResult.Failure(PcapImportFailure.SOURCE_TOO_LARGE)
                    }
                    output.write(buffer, 0, read)
                    onProgress(copied)
                }
                output.flush()
                output.fd.sync()
            }
            if (cancellation.isCancelled()) {
                return PcapImportResult.Failure(PcapImportFailure.CANCELLED)
            }
            val summary = analyzer.analyze(
                FilePcapSource(raw, source.displayName),
                PcapAnalysisOptions(
                    analysisID = analysisID,
                    sourceLabel = source.displayName,
                    detailed = detailed,
                    createdAtEpochMillis = now(),
                    cancellation = cancellation,
                ),
            )
            if (summary.cancelled) return PcapImportResult.Failure(PcapImportFailure.CANCELLED)
            if (summary.status == PcapAnalysisStatus.FAILED) {
                return PcapImportResult.Failure(
                    if (summary.format == PcapCaptureFormat.UNKNOWN) {
                        PcapImportFailure.UNSUPPORTED_FORMAT
                    } else {
                        PcapImportFailure.READ_FAILED
                    },
                )
            }
            runCatching { store.write(summary, ownerTaskId, ownerWorkspaceId, agentReadable) }.getOrElse {
                return PcapImportResult.Failure(PcapImportFailure.STORE_FAILED)
            }
            return PcapImportResult.Success(analysisID, summary)
        } catch (_: SecurityException) {
            return PcapImportResult.Failure(PcapImportFailure.SOURCE_UNAVAILABLE)
        } catch (_: IOException) {
            return PcapImportResult.Failure(PcapImportFailure.READ_FAILED)
        } finally {
            runCatching { stream?.close() }
            // The raw capture never survives: success, failure or cancellation.
            runCatching { if (raw.exists()) raw.delete() }
        }
    }

    private companion object {
        const val CHUNK_BYTES = 64 * 1024
    }
}
