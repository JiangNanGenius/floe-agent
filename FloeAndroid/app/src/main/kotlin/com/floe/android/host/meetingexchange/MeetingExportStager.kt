// SPDX-License-Identifier: MPL-2.0
//
// One disposable app-private copy of a prepared document. The staged file is
// the only source handed to the destination writer; it is deleted in a
// finally block and bounded stale copies are swept on the next attempt, so a
// cancelled or process-killed export does not retain private notes forever.
package com.floe.android.host.meetingexchange

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.FilterOutputStream
import java.io.IOException
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.nio.file.Files

internal class StagedMeetingExport(
    val file: File,
    val byteCount: Long,
) {
    fun delete() {
        file.delete()
    }

    override fun toString(): String = "StagedMeetingExport(bytes=$byteCount)"
}

internal class MeetingExportStager(
    root: File,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val rootDir: File = root.absoluteFile

    @Synchronized
    fun stage(document: MeetingExportDocument): StagedMeetingExport {
        ensureRoot()
        sweep()
        if (document.byteCount <= 0L || document.byteCount > MeetingExportFormatter.MAX_EXPORT_BYTES) {
            throw MeetingExportSizeException()
        }
        val file = File.createTempFile("meeting-export-", ".${document.format.extension}", rootDir)
        var committed = false
        try {
            val counter = CountingOutputStream(BufferedOutputStream(FileOutputStream(file)))
            counter.use { output ->
                OutputStreamWriter(output, Charsets.UTF_8).use { writer ->
                    writer.write(document.text)
                }
            }
            val bytes = counter.count
            if (bytes <= 0L ||
                bytes > MeetingExportFormatter.MAX_EXPORT_BYTES ||
                bytes != document.byteCount
            ) {
                throw MeetingExportSizeException()
            }
            committed = true
            return StagedMeetingExport(file, bytes)
        } finally {
            if (!committed) file.delete()
        }
    }

    /**
     * Removes only direct regular files created by this stager. A symlink is
     * never followed or deleted through; unrelated cache files are untouched.
     */
    @Synchronized
    fun sweep() {
        val canonicalRoot = try {
            rootDir.canonicalFile
        } catch (_: IOException) {
            return
        }
        val files = canonicalRoot.listFiles()
            ?.asSequence()
            ?.filter { it.isFile && it.name.startsWith(TEMP_PREFIX) }
            ?.filter { !Files.isSymbolicLink(it.toPath()) }
            ?.filter {
                runCatching { it.canonicalFile.parentFile == canonicalRoot }.getOrDefault(false)
            }
            ?.sortedBy { it.lastModified() }
            ?.toMutableList()
            ?: return
        val now = clock()
        files.removeAll { file ->
            val stale = now - file.lastModified() > MAX_STAGED_AGE_MILLIS
            if (stale) file.delete()
            stale
        }
        var total = files.sumOf { it.length() }
        while (files.size > MAX_STAGED_FILES || total > MAX_STAGED_BYTES) {
            val oldest = files.removeFirstOrNull() ?: break
            total -= oldest.length()
            oldest.delete()
        }
    }

    private fun ensureRoot() {
        if (rootDir.isDirectory) return
        if (!rootDir.mkdirs() || !rootDir.isDirectory) {
            throw IOException("stagingRootUnavailable")
        }
    }

    private class CountingOutputStream(out: OutputStream) : FilterOutputStream(out) {
        var count: Long = 0L
            private set

        override fun write(b: Int) {
            out.write(b)
            count += 1L
        }

        override fun write(b: ByteArray, off: Int, len: Int) {
            out.write(b, off, len)
            count += len.toLong()
        }
    }

    private companion object {
        const val TEMP_PREFIX = "meeting-export-"
        const val MAX_STAGED_AGE_MILLIS = 60L * 60L * 1_000L
        const val MAX_STAGED_FILES = 8
        const val MAX_STAGED_BYTES = 64L * 1024L * 1024L
    }
}
