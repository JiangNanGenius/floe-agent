// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

class VerifiedArchive(
    val file: File,
    val sha256Hex: String,
    val bytes: Long,
    val reusedCache: Boolean,
)

/**
 * Bounded streaming fetch with only-verified cache reuse.
 *
 * - Downloads into a task-owned `part-<installId>.part` file, never directly
 *   into the cache name; the part is hashed while streaming (no bulk read).
 * - The received SHA-256 must equal the catalog pin before the part is
 *   renamed to the cache entry. A mismatch or any failure deletes only our
 *   own part file.
 * - Cache reuse always re-hashes the stored file first; a corrupt cache is
 *   discarded and refetched. The `.verified` sidecar is provenance only,
 *   never trust.
 * - Disk floor (reserveBytes) is checked preflight and periodically during
 *   the stream; exceeding maxArchiveBytes or the floor aborts the download.
 */
class RootfsArchiveFetcher(
    private val ops: PosixFileOps,
    private val transport: ByteFetch,
    private val reserveBytes: Long,
) {
    fun fetch(
        entry: RootfsCatalogEntry,
        downloadDir: File,
        installId: String,
        progress: ProgressListener? = null,
        cancel: CancellationCheck? = null,
    ): VerifiedArchive {
        require(installId.matches(HEX_ID)) { "installId must be lowercase hex" }
        ops.ensureDirectoryTree(downloadDir)
        val cacheFile = File(downloadDir, "archive-" + entry.archiveSha256)
        val sidecar = File(downloadDir, "archive-" + entry.archiveSha256 + ".verified")

        if (ops.kind(cacheFile) == FileKind.REGULAR) {
            if (cancel?.isCancelled() == true) {
                throw RootfsCancelledException("before cache verify")
            }
            // Only verified cache reuse: re-hash the stored bytes, always.
            val observed = sha256Of(cacheFile, cancel)
            if (observed == entry.archiveSha256 && cacheFile.length() in 1..entry.maxArchiveBytes) {
                writeSidecar(sidecar, entry, cacheFile.length(), reused = true)
                return VerifiedArchive(cacheFile, entry.archiveSha256, cacheFile.length(), true)
            }
            // Corrupt or wrong cache under our own archive-<sha> name: ours.
            cacheFile.delete()
            sidecar.delete()
        }
        val part = File(downloadDir, "part-$installId.part")
        if (ops.kind(part) != FileKind.MISSING) part.delete()
        val usable = ops.usableSpace(downloadDir)
        if (usable < entry.knownArchiveBytes + reserveBytes) {
            throw RootfsInstallException(
                InstallFailure.DISK_BUDGET,
                "need ${entry.knownArchiveBytes + reserveBytes} bytes free, have $usable",
            )
        }
        var fetchedLengthKnown = -1L
        val digest = MessageDigest.getInstance("SHA-256")
        var received = 0L
        var nextDiskCheck = DISK_CHECK_STRIDE
        var nextProgress = 0L
        try {
            ops.createNewFile(part).use { sink ->
                val fetched = transport.open(entry.httpsUrl)
                fetched.stream.use { source ->
                    fetchedLengthKnown = fetched.contentLength
                    if (fetched.contentLength > entry.maxArchiveBytes) {
                        throw RootfsInstallException(
                            InstallFailure.ARCHIVE_TOO_LARGE,
                            "Content-Length ${fetched.contentLength} exceeds budget",
                        )
                    }
                    val buffer = ByteArray(CHUNK)
                    while (true) {
                        if (cancel?.isCancelled() == true) {
                            throw RootfsCancelledException("during download at $received bytes")
                        }
                        val n = source.read(buffer)
                        if (n < 0) break
                        if (n == 0) continue
                        received += n
                        if (received > entry.maxArchiveBytes) {
                            throw RootfsInstallException(
                                InstallFailure.ARCHIVE_TOO_LARGE, "streamed past budget",
                            )
                        }
                        digest.update(buffer, 0, n)
                        sink.write(buffer, 0, n)
                        if (received >= nextDiskCheck) {
                            nextDiskCheck += DISK_CHECK_STRIDE
                            if (ops.usableSpace(downloadDir) < reserveBytes) {
                                throw RootfsInstallException(
                                    InstallFailure.DISK_BUDGET,
                                    "free-space floor crossed at $received bytes",
                                )
                            }
                        }
                        if (received >= nextProgress) {
                            nextProgress += PROGRESS_STRIDE
                            progress?.onProgress(
                                RootfsInstallProgress(
                                    InstallPhase.DOWNLOAD, received,
                                    fetched.contentLength, 0L, 0L,
                                ),
                            )
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            part.delete()
            if (t is RootfsInstallException || t is RootfsCancelledException) throw t
            throw RootfsInstallException(
                InstallFailure.UNEXPECTED_IO, "download failed after $received bytes", t,
            )
        }
        // sink closed by use(); validate after the stream completed cleanly.
        if (received < 1 || received > entry.maxArchiveBytes) {
            part.delete()
            throw RootfsInstallException(
                InstallFailure.ARCHIVE_TOO_LARGE, "received $received bytes",
            )
        }
        if (fetchedLengthKnown > 0 && received != fetchedLengthKnown) {
            part.delete()
            throw RootfsInstallException(
                InstallFailure.ARCHIVE_TRUNCATED,
                "stream ended at $received of $fetchedLengthKnown bytes",
            )
        }
        val observed = digest.encodeHexLower()
        if (observed != entry.archiveSha256) {
            part.delete()
            throw RootfsInstallException(
                InstallFailure.DIGEST_MISMATCH, "got $observed want ${entry.archiveSha256}",
            )
        }
        progress?.onProgress(
            RootfsInstallProgress(InstallPhase.DOWNLOAD, received, received, 0L, 0L),
        )
        ops.atomicMove(part, cacheFile)
        writeSidecar(sidecar, entry, received, reused = false)
        progress?.onProgress(
            RootfsInstallProgress(InstallPhase.VERIFY_ARCHIVE, received, received, 0L, 0L),
        )
        return VerifiedArchive(cacheFile, observed, received, false)
    }

    private fun writeSidecar(sidecar: File, entry: RootfsCatalogEntry, bytes: Long, reused: Boolean) {
        ops.writeText(
            sidecar,
            "{catalog=" + entry.catalogId + ",sha256=" + entry.archiveSha256 +
                ",bytes=" + bytes + ",verifiedAtMs=" + System.currentTimeMillis() +
                ",reused=" + reused + "}\n",
        )
    }

    private fun sha256Of(file: File, cancel: CancellationCheck?): String {
        val digest = MessageDigest.getInstance("SHA-256")
        try {
            FileInputStream(file).use { input ->
                val buffer = ByteArray(CHUNK)
                var sinceCheck = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                    sinceCheck += n
                    if (sinceCheck >= DISK_CHECK_STRIDE) {
                        sinceCheck = 0
                        if (cancel?.isCancelled() == true) {
                            throw RootfsCancelledException("during cache re-hash")
                        }
                    }
                }
            }
        } catch (t: java.io.IOException) {
            throw RootfsInstallException(
                InstallFailure.UNEXPECTED_IO, "cannot re-hash cache ${file.name}", t,
            )
        }
        return digest.encodeHexLower()
    }

    private companion object {
        const val CHUNK = 64 * 1024
        const val DISK_CHECK_STRIDE = 16L * 1024 * 1024
        const val PROGRESS_STRIDE = 1L * 1024 * 1024
        val HEX_ID = Regex("^[0-9a-f]{8,64}$")
    }
}

private val HEX_DIGITS = "0123456789abcdef".toCharArray()

internal fun MessageDigest.encodeHexLower(): String {
    val bytes = digest()
    val out = CharArray(bytes.size * 2)
    for (i in bytes.indices) {
        val v = bytes[i].toInt() and 0xFF
        out[i * 2] = HEX_DIGITS[v shr 4]
        out[i * 2 + 1] = HEX_DIGITS[v and 0x0F]
    }
    return String(out)
}
