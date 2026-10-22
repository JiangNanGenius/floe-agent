// SPDX-License-Identifier: MPL-2.0
//
// Transactional rootfs installation subsystem (G03-R2).
//
// This package installs a rootfs archive into a NEW, non-existing revision
// path that the CALLER resolved. It is not an environment registry, not a
// job database and not a security boundary. FloeEnvironments remains the
// sole authority for which revision is selected; the installer only produces
// fully verified, prepared or published revision data. PRoot is not
// isolation; device nodes under /dev are runtime-bound by the launcher, so
// the fixed catalog profile excludes them explicitly and counts them.

package com.floe.android.linuxruntime.install

/** Monotonic stages emitted through [ProgressListener]. */
enum class InstallPhase { PREFLIGHT, DOWNLOAD, VERIFY_ARCHIVE, EXTRACT, PUBLISH }

data class RootfsInstallProgress(
    val phase: InstallPhase,
    val archiveBytesDone: Long,
    val archiveBytesTotal: Long,
    val entriesDone: Long,
    val extractedBytesDone: Long,
) {
    init {
        require(archiveBytesTotal >= -1L)
    }
}

/**
 * Cooperative cancellation. Checked between download chunks and between tar
 * entries; never mid-header. A cancelled run is reported as
 * [RootfsCancelledException] after task-owned cleanup, never as success.
 */
fun interface CancellationCheck {
    fun isCancelled(): Boolean
}

fun interface ProgressListener {
    fun onProgress(progress: RootfsInstallProgress)
}
