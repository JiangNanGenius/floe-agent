// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.File
import java.security.SecureRandom

/** A fully verified, unpublished revision living in private staging. */
class PreparedRootfs internal constructor(
    val installId: String,
    val stagingDirectory: File,
    val rootfsDirectory: File,
    val manifestFile: File,
    val manifest: RootfsManifest,
    internal val ownershipToken: String,
)

/** A published revision: NEW directory containing rootfs/ + manifest.json. */
class PublishedRootfs(
    val revisionDirectory: File,
    val rootfsDirectory: File,
    val manifest: RootfsManifest,
)

class WorkspaceSweepReport(
    val removedStaging: List<String>,
    val removedPartFiles: Int,
    val skippedForeign: Int,
    val removedCaches: List<String> = emptyList(),
)

/**
 * Transactional rootfs installer. The small service-facing surface for the
 * Main-owned runtime service is exactly:
 *
 *   val installer = RootfsInstaller(appPrivateWorkspaceDir)
 *   installer.install(catalog, newRevisionDir)                    // one-shot
 *   // or split:
 *   val prepared = installer.prepare(catalog, progress, cancel)   // download+verify+extract
 *   installer.publish(prepared, newRevisionDir)                   // atomic, NEW path only
 *   installer.discard(prepared)                                   // owner-marker-checked
 *   installer.verifyPublishedRevision(revisionDir)                // provenance re-read
 *   installer.sweepStaleWorkspace(maxAgeMs)                       // task-owned tmp gc
 *   installer.clearCache(catalog)                                 // storage accounting
 *
 * The installer never enumerates, selects or switches environments, never
 * overwrites an existing destination and never deletes a directory that does
 * not carry its own ownership marker. The published layout is
 * <revisionDir>/rootfs/ (guest tree) plus <revisionDir>/manifest.json; the FloeEnvironments
 * lease/CAS owner records the selection elsewhere.
 */
class RootfsInstaller(
    val workspaceRoot: File,
    private val ops: PosixFileOps = PosixFileOps.discover(),
    private val transport: ByteFetch = HttpsByteFetch(),
    private val reserveBytes: Long = DEFAULT_RESERVE_BYTES,
) {
    init {
        require(workspaceRoot.isAbsolute && workspaceRoot.path.indexOf(Char(0)) < 0) {
            "workspaceRoot must be an absolute, NUL-free caller-resolved directory"
        }
    }

    /**
     * Download (or verified-reuse), extract into a fresh private staging
     * revision, verify budgets/minimums, and leave a manifest inside the
     * staging directory. On ANY failure or cancellation: staging is removed
     * (only after the ownership marker verifies), no publication happened,
     * and any previously published revision is untouched.
     */
    fun prepare(
        catalog: RootfsCatalogEntry,
        progress: ProgressListener? = null,
        cancel: CancellationCheck? = null,
    ): PreparedRootfs {
        val installId = newInstallId()
        emit(progress, InstallPhase.PREFLIGHT, -1L, -1L, 0L, 0L)
        ops.ensureDirectoryTree(stagingRoot)
        val staging = File(stagingRoot, installId)
        if (ops.kind(staging) != FileKind.MISSING) {
            throw RootfsInstallException(
                InstallFailure.DESTINATION_COLLISION, "staging id reused: ${staging.path}",
            )
        }
        val token = newOwnershipToken()
        ops.createDirectory(staging, 0x1ED)
        val marker = File(staging, OWNER_MARKER_NAME)
        ops.writeText(marker, markerText(installId, token, catalog.catalogId))
        try {
            val archive = RootfsArchiveFetcher(ops, transport, reserveBytes)
                .fetch(catalog, downloadsDir(catalog), installId, progress, cancel)
            val rootfs = File(staging, ROOTFS_DIR_NAME)
            val stats = TarXzExtractor(ops).extract(archive.file, rootfs, catalog, progress, cancel)
                .let { stats -> verifyMinimums(catalog, stats); stats }
            val manifest = RootfsManifest(
                catalogId = catalog.catalogId,
                version = catalog.version,
                displayName = catalog.displayName,
                archiveFileName = catalog.archiveFileName,
                archiveUrl = catalog.httpsUrl,
                archiveSha256 = archive.sha256Hex,
                archiveBytes = archive.bytes,
                installId = installId,
                createdAtEpochMs = System.currentTimeMillis(),
                stats = stats,
            )
            val manifestFile = File(staging, MANIFEST_NAME)
            ops.writeText(manifestFile, manifest.toJson())
            return PreparedRootfs(installId, staging, rootfs, manifestFile, manifest, token)
        } catch (t: Throwable) {
            discardStagingIfOwned(staging, installId)
            if (t is RootfsInstallException || t is RootfsCancelledException) throw t
            throw RootfsInstallException(
                InstallFailure.UNEXPECTED_IO, "prepare failed for ${catalog.catalogId}", t,
            )
        }
    }

    /**
     * Atomically rename the fully verified staging directory into a NEW,
     * non-existing revision path resolved by the caller. If the target
     * exists, its parent is missing, or the rename fails for any reason
     * (including cross-device EXDEV), the existing state is preserved
     * unchanged and staging remains available for retry or discard.
     */
    fun publish(prepared: PreparedRootfs, targetRevisionDirectory: File): PublishedRootfs {
        require(targetRevisionDirectory.isAbsolute &&
            targetRevisionDirectory.path.indexOf(Char(0)) < 0) {
            "revision path must be absolute and NUL-free"
        }
        if (readOwnedMarker(prepared.stagingDirectory, prepared.installId)
                ?.ownershipToken != prepared.ownershipToken
        ) {
            throw RootfsInstallException(
                InstallFailure.OWNER_MARKER_MISSING,
                "staging ${prepared.stagingDirectory.name} is not installer-owned or changed",
            )
        }
        val parent = targetRevisionDirectory.parentFile
            ?: throw RootfsInstallException(
                InstallFailure.DESTINATION_PARENT_MISSING, targetRevisionDirectory.path,
            )
        if (ops.kind(parent) != FileKind.DIRECTORY) {
            throw RootfsInstallException(
                InstallFailure.DESTINATION_PARENT_MISSING, parent.path,
            )
        }
        if (ops.kind(targetRevisionDirectory) != FileKind.MISSING) {
            throw RootfsInstallException(
                InstallFailure.DESTINATION_EXISTS,
                "${targetRevisionDirectory.path} exists; in-use revisions are never overwritten",
            )
        }
        try {
            ops.atomicMove(prepared.stagingDirectory, targetRevisionDirectory)
        } catch (t: Throwable) {
            val detail = generateSequence<Throwable>(t) { it.cause }
                .joinToString("; ") { it.message ?: it.javaClass.simpleName }
            throw RootfsInstallException(
                if (detail.contains("EXDEV")) InstallFailure.CROSS_FILESTORE
                else InstallFailure.UNEXPECTED_IO,
                "publish ${prepared.stagingDirectory.name} -> ${targetRevisionDirectory.path} failed: $detail",
                t,
            )
        }
        // Publication transfers ownership to the caller authority: remove the
        // staging marker so no sweep can ever touch a published revision.
        val movedMarker = File(targetRevisionDirectory, OWNER_MARKER_NAME)
        if (readOwnedMarker(targetRevisionDirectory, prepared.installId)?.ownershipToken ==
            prepared.ownershipToken
        ) {
            movedMarker.delete()
        }
        if (ops.kind(File(targetRevisionDirectory, MANIFEST_NAME)) != FileKind.REGULAR) {
            throw RootfsInstallException(
                InstallFailure.STAGING_INCOMPLETE,
                "published revision lost its manifest mid-flight",
            )
        }
        return PublishedRootfs(
            targetRevisionDirectory,
            File(targetRevisionDirectory, ROOTFS_DIR_NAME),
            prepared.manifest,
        )
    }

    /** prepare + publish convenience for one-shot installs. */
    fun install(
        catalog: RootfsCatalogEntry,
        targetRevisionDirectory: File,
        progress: ProgressListener? = null,
        cancel: CancellationCheck? = null,
    ): PublishedRootfs = publish(prepare(catalog, progress, cancel), targetRevisionDirectory)

    /** Delete a prepared-but-unpublished revision. Requires the live marker. */
    fun discard(prepared: PreparedRootfs): Boolean {
        if (readOwnedMarker(prepared.stagingDirectory, prepared.installId)?.ownershipToken !=
            prepared.ownershipToken
        ) return false
        ops.deleteTree(prepared.stagingDirectory)
        return true
    }

    /**
     * Re-read a published revision's provenance without trusting in-memory
     * state: manifest parses, schema is 1, hash form is intact, rootfs/
     * exists as a directory, and the staging ownership marker is gone.
     */
    fun verifyPublishedRevision(revisionDirectory: File): RootfsManifest {
        if (ops.kind(File(revisionDirectory, OWNER_MARKER_NAME)) != FileKind.MISSING) {
            throw RootfsInstallException(
                InstallFailure.STAGING_INCOMPLETE,
                "${revisionDirectory.name} still carries an ownership marker",
            )
        }
        val manifestFile = File(revisionDirectory, MANIFEST_NAME)
        if (ops.kind(manifestFile) != FileKind.REGULAR) {
            throw RootfsInstallException(
                InstallFailure.STAGING_INCOMPLETE, "missing manifest in ${revisionDirectory.path}",
            )
        }
        val manifest = RootfsManifest.parse(ops.readText(manifestFile))
        if (ops.kind(File(revisionDirectory, ROOTFS_DIR_NAME)) != FileKind.DIRECTORY) {
            throw RootfsInstallException(
                InstallFailure.STAGING_INCOMPLETE, "missing rootfs tree in ${revisionDirectory.name}",
            )
        }
        return manifest
    }

    fun downloadsDir(catalog: RootfsCatalogEntry): File =
        File(File(workspaceRoot, DOWNLOADS_DIR_NAME), catalog.catalogId)

    /**
     * Task-owned tmp garbage collection. Removes ONLY staging directories
     * with a valid installer marker older than maxAgeMs and orphan part
     * files inside the installer's downloads directories older than
     * maxAgeMs. Foreign or unmarked entries are counted and left untouched;
     * verified cache archives are retained until clearCache.
     */
    fun sweepStaleWorkspace(maxAgeMs: Long): WorkspaceSweepReport {
        val removed = mutableListOf<String>()
        var skippedForeign = 0
        val stagingChildren = if (ops.kind(stagingRoot) == FileKind.DIRECTORY) {
            stagingRoot.listFiles() ?: throw RootfsInstallException(
                InstallFailure.UNEXPECTED_IO, "cannot list ${stagingRoot.path}",
            )
        } else {
            emptyArray()
        }
        for (child in stagingChildren) {
            if (ops.kind(child) != FileKind.DIRECTORY) { skippedForeign += 1; continue }
            val entry = readOwnedMarker(child, child.name)
            if (entry == null) { skippedForeign += 1; continue }
            if (System.currentTimeMillis() - entry.createdAtEpochMs < maxAgeMs) continue
            ops.deleteTree(child)
            removed += child.name
        }
        var removedParts = 0
        val downloadsRoot = File(workspaceRoot, DOWNLOADS_DIR_NAME)
        if (ops.kind(downloadsRoot) == FileKind.DIRECTORY) {
            val catalogDirs = downloadsRoot.listFiles() ?: throw RootfsInstallException(
                InstallFailure.UNEXPECTED_IO, "cannot list ${downloadsRoot.path}",
            )
            val now = System.currentTimeMillis()
            for (dir in catalogDirs) {
                if (ops.kind(dir) != FileKind.DIRECTORY) continue
                for (file in dir.listFiles() ?: continue) {
                    if (ops.kind(file) == FileKind.REGULAR && PART_NAME.matches(file.name) &&
                        now - file.lastModified() >= maxAgeMs
                    ) {
                        file.delete()
                        removedParts += 1
                    }
                }
            }
        }
        return WorkspaceSweepReport(removed, removedParts, skippedForeign)
    }

    /** Drop the installer's verified archive cache for one catalog entry. */
    fun clearCache(catalog: RootfsCatalogEntry): Long {
        val dir = downloadsDir(catalog)
        var freed = 0L
        for (file in dir.listFiles() ?: return 0L) {
            if (file.name == "archive-" + catalog.archiveSha256 ||
                file.name == "archive-" + catalog.archiveSha256 + ".verified"
            ) {
                freed += file.length()
                file.delete()
            }
        }
        return freed
    }

    private val stagingRoot: File get() = File(workspaceRoot, STAGING_DIR_NAME)

    private fun verifyMinimums(catalog: RootfsCatalogEntry, stats: ExtractionStats) {
        if (stats.files < catalog.minRegularFiles ||
            stats.directories < catalog.minDirectories ||
            stats.symbolicLinks < catalog.minSymbolicLinks
        ) {
            throw RootfsInstallException(
                InstallFailure.CONTENT_UNDERFLOW,
                "files ${stats.files}/${catalog.minRegularFiles} dirs " +
                    "${stats.directories}/${catalog.minDirectories} links " +
                    "${stats.symbolicLinks}/${catalog.minSymbolicLinks}",
            )
        }
    }

    private fun discardStagingIfOwned(staging: File, installId: String) {
        try {
            if (readOwnedMarker(staging, installId) != null) ops.deleteTree(staging)
        } catch (_: Throwable) {
            // Cleanup must never mask the original failure; the next sweep
            // removes the stale, still-marked staging directory.
        }
    }

    private fun newInstallId(): String {
        val bytes = ByteArray(8)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
    }

    private fun newOwnershipToken(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
    }

    private fun markerText(installId: String, token: String, catalogId: String): String =
        MARKER_SCHEMA + "\t" + installId + "\t" + token + "\t" +
            System.currentTimeMillis() + "\t" + catalogId + "\n"

    /**
     * Parse the ownership marker of a staging directory. Null when the
     * directory is foreign, tampered with, or lacks a well-formed marker:
     * this is what makes recursive deletion ownership-checked.
     */
    private fun readOwnedMarker(dir: File, expectedId: String): MarkerEntry? {
        val marker = File(dir, OWNER_MARKER_NAME)
        if (ops.kind(marker) != FileKind.REGULAR) return null
        if (!HEX_ID.matches(expectedId)) return null
        return try {
            val fields = ops.readText(marker).trim().split('\t')
            if (fields.size != 5 || fields[0] != MARKER_SCHEMA) return null
            if (fields[1] != expectedId || !TOKEN.matches(fields[2])) return null
            val createdAt = fields[3].toLongOrNull() ?: return null
            val catalogField = fields[4]
            if (createdAt < 1L || catalogField.isEmpty() || catalogField.contains('/') ||
                catalogField.contains("..") || catalogField.any { it == Char(0) }
            ) {
                return null
            }
            MarkerEntry(fields[1], fields[2], createdAt)
        } catch (_: Throwable) {
            null
        }
    }

    private fun emit(
        progress: ProgressListener?,
        phase: InstallPhase,
        archiveDone: Long,
        archiveTotal: Long,
        entries: Long,
        extracted: Long,
    ) {
        progress?.onProgress(
            RootfsInstallProgress(phase, archiveDone, archiveTotal, entries, extracted),
        )
    }

    private class MarkerEntry(val installId: String, val ownershipToken: String, val createdAtEpochMs: Long)

    companion object {
        const val STAGING_DIR_NAME = "staging"
        const val DOWNLOADS_DIR_NAME = "downloads"
        const val ROOTFS_DIR_NAME = "rootfs"
        const val MANIFEST_NAME = "manifest.json"
        const val OWNER_MARKER_NAME = ".floe-install-owner"
        const val DEFAULT_RESERVE_BYTES = 96L * 1024 * 1024
        private const val MARKER_SCHEMA = "floe-rootfs-stager-v1"
        private val HEX_ID = Regex("^[0-9a-f]{8,64}$")
        private val TOKEN = Regex("^[0-9a-f]{32}$")
        private val PART_NAME = Regex("^part-[0-9a-f]{8,64}\\.part$")
    }
}
