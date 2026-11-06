// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.components

import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.attribute.BasicFileAttributes

/** Called under the component store's mutex, with no active readers.
 * A verified stage already owns a synced .ready marker. Each rename is atomic;
 * the previous directory remains recoverable until the promoted stage exists.
 * This is process-interruption recovery, not a guarantee against failing media.
 */
internal class ComponentDirectoryCommit(
    private val root: File,
    private val id: String,
    private val move: (File, File) -> Unit = { from, to ->
        Files.move(from.toPath(), to.toPath(), ATOMIC_MOVE); Unit
    },
    private val removeTree: (File) -> Unit = ::removeComponentTree,
) {
    val directory = File(root, id)
    val previous = File(root, "$id.previous")

    class RestorePending(cause: Throwable) : IOException("component_restore_pending", cause)
    class CleanupPending(cause: Throwable) : IOException("component_cleanup_pending", cause)

    init { require(id.matches(Regex("[a-z0-9-]{1,48}"))) }

    fun recover() {
        validate()
        if (!exists(previous)) return
        if (hasCompletionMarker(directory)) {
            // Promotion finished before interruption; never roll it back merely
            // because removal of its old cache was interrupted.
            try { removeTree(previous) } catch (failure: Exception) { throw CleanupPending(failure) }
        } else {
            try {
                if (exists(directory)) removeTree(directory)
                move(previous, directory)
            } catch (failure: Exception) { throw RestorePending(failure) }
        }
    }

    fun promote(stage: File) {
        validateStage(stage)
        check(hasCompletionMarker(stage)) { "component_stage_unverified" }
        recover()
        if (exists(directory)) move(directory, previous)
        try {
            move(stage, directory)
        } catch (failure: Exception) {
            if (exists(previous)) {
                try { move(previous, directory) }
                catch (restore: Exception) {
                    restore.addSuppressed(failure)
                    throw RestorePending(restore)
                }
            }
            throw failure
        }
        // A cleanup failure keeps the new component usable and the previous
        // bytes intact. The caller can distinguish it from failed promotion.
        recover()
    }

    fun discardStage(stage: File) {
        validateStage(stage)
        if (exists(stage)) removeTree(stage)
    }

    fun discardStaleStages() {
        validate()
        root.listFiles().orEmpty().filter { it.name.startsWith("$id.install-") }.forEach {
            try { discardStage(it) } catch (failure: Exception) { throw CleanupPending(failure) }
        }
    }

    fun uninstall() {
        validate()
        // Delete the fallback first. A successful uninstall cannot resurrect it
        // on the next process start. Failures retain a retryable cache state.
        if (exists(previous)) removeTree(previous)
        if (exists(directory)) {
            Files.deleteIfExists(File(directory, ".ready").toPath())
            removeTree(directory)
        }
        discardStaleStages()
    }

    /** Actual component/cache bytes, including retained and partial downloads.
     * Components are flat files; no links or nested external trees are followed.
     */
    fun storedBytes(): Long {
        if (Files.isSymbolicLink(root.toPath())) return 0
        return root.listFiles().orEmpty().filter {
            it.name == id || it.name == "$id.previous" || it.name.startsWith("$id.install-")
        }.sumOf { dir ->
            if (!Files.isDirectory(dir.toPath(), NOFOLLOW_LINKS)) 0L else
                dir.listFiles().orEmpty().filter { Files.isRegularFile(it.toPath(), NOFOLLOW_LINKS) }
                    .sumOf { it.length() }
        }
    }

    private fun validate() {
        for (path in listOf(root, directory, previous)) {
            check(!Files.isSymbolicLink(path.toPath())) { "component_link_refused" }
            check(!exists(path) || Files.isDirectory(path.toPath(), NOFOLLOW_LINKS)) { "component_directory_required" }
        }
    }

    private fun validateStage(stage: File) {
        validate()
        check(stage.absoluteFile.parentFile == root.absoluteFile && stage.name.startsWith("$id.install-"))
        check(!Files.isSymbolicLink(stage.toPath())) { "component_link_refused" }
        check(!exists(stage) || Files.isDirectory(stage.toPath(), NOFOLLOW_LINKS))
    }

    companion object {
        private fun exists(file: File) = Files.exists(file.toPath(), NOFOLLOW_LINKS)
        fun hasCompletionMarker(directory: File): Boolean = runCatching {
            if (!Files.isDirectory(directory.toPath(), NOFOLLOW_LINKS)) return@runCatching false
            val marker = File(directory, ".ready")
            Files.isRegularFile(marker.toPath(), NOFOLLOW_LINKS) && marker.length() == 64L &&
                marker.readText().matches(Regex("[a-f0-9]{64}"))
        }.getOrDefault(false)
    }
}

/** Do not traverse a symlink left in a private cache during removal. */
private fun removeComponentTree(file: File) {
    if (!Files.exists(file.toPath(), NOFOLLOW_LINKS)) return
    Files.walkFileTree(file.toPath(), object : SimpleFileVisitor<Path>() {
        override fun visitFile(path: Path, attrs: BasicFileAttributes): FileVisitResult {
            Files.delete(path)
            return FileVisitResult.CONTINUE
        }
        override fun postVisitDirectory(path: Path, error: IOException?): FileVisitResult {
            if (error != null) throw error
            Files.delete(path)
            return FileVisitResult.CONTINUE
        }
    })
}
