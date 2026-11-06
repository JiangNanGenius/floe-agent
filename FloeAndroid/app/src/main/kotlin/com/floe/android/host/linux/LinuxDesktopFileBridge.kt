// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.linux

import com.floe.android.host.G04TerminalHostController
import com.floe.android.host.externaledit.ExternalEditPolicy
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Binary transport over the existing owner-checked live guest file API. A
 * single file revision must cover every page and the final read-back probe. */
internal class LinuxDesktopFileBridge(private val terminal: G04TerminalHostController,
    private val taskID: String, private val sessionID: String, private val generation: String,
    private val isCurrent: () -> Boolean) {
    internal class Failure(val code: String) : Exception(code)
    suspend fun probe(path: String): G04TerminalHostController.LiveFilePage = page(path, 0, 1)

    suspend fun copy(path: String, destination: File, expectedSHA256: String? = null): String {
        val first = page(path, 0, 24 * 1_024)
        require(first.size in 0..ExternalEditPolicy.MAX_BYTES)
        var offset = 0L
        var current = first
        val hash = MessageDigest.getInstance("SHA-256")
        FileOutputStream(destination).use { output ->
            while (true) {
                check(current.fileRevision == first.fileRevision && current.size == first.size &&
                    current.workspaceKey == first.workspaceKey && current.offset == offset)
                check(current.bytes == current.content.size && current.bytes in 0..24 * 1_024 &&
                    current.bytes.toLong() <= first.size - offset)
                check(hex(MessageDigest.getInstance("SHA-256").digest(current.content)) == current.digest)
                output.write(current.content); hash.update(current.content)
                offset += current.bytes
                if (offset == first.size) { check(!current.truncated); break }
                check(current.bytes > 0 && current.truncated)
                current = page(path, offset, 24 * 1_024)
            }
            output.fd.sync()
        }
        val final = probe(path)
        check(final.fileRevision == first.fileRevision && final.size == first.size &&
            final.workspaceKey == first.workspaceKey)
        val digest = hex(hash.digest())
        check(expectedSHA256 == null || digest == expectedSHA256)
        return first.fileRevision
    }

    private suspend fun page(path: String, offset: Long, bytes: Int): G04TerminalHostController.LiveFilePage {
        currentCoroutineContext().ensureActive()
        check(isCurrent())
        require(ExternalEditPolicy.validPath(path))
        val reply = terminal.readLiveFilePage(taskID, sessionID, path, offset, bytes)
        check(isCurrent())
        val page = when (reply) {
            is G04TerminalHostController.LiveFilesReply.Page -> reply.page
            is G04TerminalHostController.LiveFilesReply.Failed -> {
                // Closed diagnostic vocabulary only: no guest output or file paths.
                val reason = reply.reason?.takeIf { it in setOf(
                    "staleLiveSession", "pathOutOfScope", "invalidOffset", "offsetPastEnd",
                    "readFailed", "liveFilesUnavailable", "replyMalformed", "timedOut",
                ) } ?: "unavailable"
                throw Failure("guest_$reason")
            }
            else -> throw Failure("guest_unavailable")
        }
        if (page.sessionID != sessionID) throw Failure("session_changed")
        if (page.generation != generation) throw Failure("generation_changed")
        if (page.path != path || page.offset != offset) throw Failure("page_identity_changed")
        if (!page.fileRevision.matches(Regex("[a-f0-9]{64}"))) throw Failure("revision_missing")
        return page
    }
    private fun hex(value: ByteArray) = value.joinToString("") { "%02x".format(it) }
}
