// SPDX-License-Identifier: MPL-2.0
package com.floe.android.bridge

import java.security.MessageDigest
import java.util.UUID
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Typed rejection raised by the device-workspace JNI adapter. Only the
 * numeric contract status is retained — workspace paths, digests, titles
 * and conversation ids NEVER enter the message.
 *
 * Status space (frozen lane contract; additive and disjoint from the
 * gateway -1xx, runtime-owner -2xx, attachment -3xx, skills-folder -4xx,
 * source-host -5xx, network-workspace -6xx, run-output -7xx and
 * device-history -80x vocabularies):
 *   0 ok; -105 invalid shape; -106 buffer too small;
 *   -801 unavailable (no live root generation / no such conversation);
 *   -802 fenced (epoch belongs to another/retired generation);
 *   -803 session unknown; -805 not shared / no eligible current root;
 *   -806 conflict; -808 oversized; -810 busy; -812 IO failure.
 */
class DeviceWorkspaceNativeException(val status: Int) :
    IllegalStateException("device_workspace_status_$status")

/**
 * Trusted App entry for the paired-device workspace lane (cross-endpoint v1
 * workspace extension). The Kotlin transport (`core:devicelink`) is the ONLY
 * caller: it owns per-peer/per-task authorization, UI consent and the
 * merge/conflict orchestration, then drives this object. Not a V3 command,
 * never model-reachable; the App calls it only from its own device-link
 * surfaces with the ACCEPTED native root epoch.
 *
 * Byte discipline: source bytes leave ONLY through <= 64 KiB pages over
 * opaque positive tickets ([read]); target bytes arrive as <= 64 KiB staged
 * appends ([write]) and become visible only after [targetCommit] verifies
 * the staged length + SHA-256 with the no-overwrite / explicit-previous-
 * digest contract native holds under the app-wide file-mutation lock.
 * Callers never hand paths, URIs, file descriptors or store handles to
 * native: every path is the canonical wire-relative original, validated
 * again on the native side before any filesystem operation.
 *
 * Cancellation is cooperative: chunk loops live in the transport, which
 * checks the coroutine between pages and always releases its ticket on
 * exit ([close] is idempotent for source, target and stage sessions).
 */
object DeviceWorkspaceNative {
    init { System.loadLibrary("floe_jni") }

    // ------------------------------------------------------------------
    // Raw JNI ABI (the ONE binary channel; Kotlin JNI only)
    // ------------------------------------------------------------------

    /**
     * One bounded UTF-8 JSON command. [input] is the request document,
     * the JSON reply (possibly empty) is written into [reply]; the return
     * value is the written length (0 for empty success) or a typed status.
     */
    external fun command(operation: String, input: ByteArray, reply: ByteArray): Int

    /**
     * Copy one <= 64 KiB page out of a prepared source session: [index] -1
     * is the manifest, >= 0 a prepared file entry. Returns bytes copied,
     * 0 at EOF, or a typed status.
     */
    external fun read(ticket: Long, index: Int, offset: Long, target: ByteArray): Int

    /**
     * Append one <= 64 KiB chunk to a target stage session. Returns 0 on
     * success or a typed status; the staged aggregate can never exceed the
     * 1 GiB file ceiling.
     */
    external fun write(ticket: Long, source: ByteArray, offset: Int, length: Int): Int

    // ------------------------------------------------------------------
    // Typed App-facing primitives (suspend, bounded, cooperative-cancel)
    // ------------------------------------------------------------------

    enum class TargetKind(val wire: String) { MISSING("missing"), DIRECTORY("directory"), FILE("file") }

    data class SourceSession(val ticket: Long, val manifestSize: Int)

    data class TargetInfo(val kind: TargetKind, val digest: String?)

    private const val CHUNK = 64 * 1024
    private const val REPLY_BYTES = 4096
    private const val SCOPE_BYTES = 256
    private const val PATH_BYTES = 1024
    private val digestPattern = Regex("[0-9a-f]{64}")

    /** The sender's read-only scope proof for [taskID]. */
    suspend fun binding(epoch: Long, taskID: String): String = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        require(canonicalTaskID(taskID))
        val reply = ByteArray(REPLY_BYTES)
        val copied = command(
            "binding", json { put("epoch", epoch); put("taskID", taskID) }, reply)
        parseScope(reply, copied)
    }

    /**
     * The receiver's scope proof. The one operation allowed to create a
     * missing workspace binding (through the same task-private
     * ensureWorkspace/materialize path as the G04 workspace activation);
     * an existing binding is returned untouched.
     */
    suspend fun targetBinding(epoch: Long, taskID: String): String = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        require(canonicalTaskID(taskID))
        val reply = ByteArray(REPLY_BYTES)
        val copied = command(
            "targetBinding", json { put("epoch", epoch); put("taskID", taskID) }, reply)
        parseScope(reply, copied)
    }

    /** Opens one owned source session; the manifest is [SourceSession.manifestSize] bytes. */
    suspend fun sourceOpen(epoch: Long, taskID: String, scope: String): SourceSession =
        withContext(Dispatchers.IO) {
            coroutineContext.ensureActive()
            require(canonicalTaskID(taskID) && scope.isNotEmpty() && scope.length <= SCOPE_BYTES)
            val reply = ByteArray(REPLY_BYTES)
            val copied = command(
                "sourceOpen",
                json { put("epoch", epoch); put("taskID", taskID); put("scope", scope) },
                reply,
            )
            val root = replyObject(reply, copied)
            SourceSession(
                ticket = root.getLong("ticket"),
                manifestSize = root.getInt("manifestSize"),
            )
        }

    /** Opens one owned target session for the verified [scope]. */
    suspend fun targetOpen(epoch: Long, taskID: String, scope: String): Long =
        withContext(Dispatchers.IO) {
            coroutineContext.ensureActive()
            require(canonicalTaskID(taskID) && scope.isNotEmpty() && scope.length <= SCOPE_BYTES)
            val reply = ByteArray(REPLY_BYTES)
            val copied = command(
                "targetOpen",
                json { put("epoch", epoch); put("taskID", taskID); put("scope", scope) },
                reply,
            )
            replyObject(reply, copied).getLong("ticket")
        }

    /** Revalidates the session's epoch, store binding and pinned root identity. */
    suspend fun check(ticket: Long): Unit = ticketCommand("check", ticket)

    /** Confirms the prepared index still names the identical file bytes. */
    suspend fun sourceVerify(ticket: Long, index: Int): Unit = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        require(ticket > 0 && index >= 0)
        val reply = ByteArray(REPLY_BYTES)
        val copied = command(
            "sourceVerify", json { put("ticket", ticket); put("index", index) }, reply)
        throwOnFailure(copied)
    }

    /**
     * Classifies one target path (the canonical wire-relative original, or
     * its deterministic conflict location when [conflictDigest] is given).
     * A local symlink or parent structural collision surfaces as -806.
     */
    suspend fun targetInfo(
        ticket: Long,
        path: String,
        conflictDigest: String? = null,
    ): TargetInfo = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        requireValidPath(path)
        require(conflictDigest == null || digestPattern.matches(conflictDigest))
        val reply = ByteArray(REPLY_BYTES)
        val copied = command(
            "targetInfo",
            json {
                put("ticket", ticket)
                put("path", path)
                conflictDigest?.let { put("conflictDigest", it) }
            },
            reply,
        )
        val root = replyObject(reply, copied)
        val kind = when (root.getString("kind")) {
            "missing" -> TargetKind.MISSING
            "directory" -> TargetKind.DIRECTORY
            "file" -> TargetKind.FILE
            else -> throw DeviceWorkspaceNativeException(-105)
        }
        val digest = if (root.isNull("digest")) null else root.getString("digest")
        require(digest == null || digestPattern.matches(digest))
        TargetInfo(kind, digest)
    }

    /**
     * Creates the directory chain for one manifest directory entry
     * (idempotent). [conflictDigest] requests the deterministic conflict
     * copy instead and must equal the SHA-256 of the raw UTF-8 [path] —
     * the exact digest this operation scopes by (frozen donor parity for
     * directory conflict copies, including empty directories).
     */
    suspend fun targetDirectory(
        ticket: Long,
        path: String,
        conflictDigest: String? = null,
    ): Unit = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        requireValidPath(path)
        if (conflictDigest != null) {
            require(digestPattern.matches(conflictDigest))
            require(conflictDigest == sha256Hex(path.encodeToByteArray())) {
                "directory conflictDigest must equal sha256(original path)"
            }
        }
        val reply = ByteArray(REPLY_BYTES)
        val copied = command(
            "targetDirectory",
            json {
                put("ticket", ticket)
                put("path", path)
                conflictDigest?.let { put("conflictDigest", it) }
            },
            reply,
        )
        throwOnFailure(copied)
    }

    /** Opens one staged temp file under the target root; returns its ticket. */
    suspend fun targetStage(ticket: Long): Long = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        require(ticket > 0)
        val reply = ByteArray(REPLY_BYTES)
        val copied = command("targetStage", json { put("ticket", ticket) }, reply)
        replyObject(reply, copied).getLong("ticket")
    }

    /**
     * Commits the sealed stage as [path]: [expectedDigest] omitted means
     * exclusive creation; [expectedDigest] names the exact previous digest
     * the current leaf must match before it is replaced; [conflictDigest]
     * stores the bytes at the deterministic
     * `Floe Sync Conflicts/<digest>/<path>` location instead (never both).
     */
    suspend fun targetCommit(
        ticket: Long,
        path: String,
        digest: String,
        size: Long,
        expectedDigest: String? = null,
        conflictDigest: String? = null,
    ): Unit = withContext(Dispatchers.IO) {
        coroutineContext.ensureActive()
        require(ticket > 0)
        requireValidPath(path)
        require(digestPattern.matches(digest) && size >= 0)
        require(expectedDigest == null || digestPattern.matches(expectedDigest))
        require(conflictDigest == null || digestPattern.matches(conflictDigest))
        require(expectedDigest == null || conflictDigest == null)
        val reply = ByteArray(REPLY_BYTES)
        val copied = command(
            "targetCommit",
            json {
                put("ticket", ticket)
                put("path", path)
                put("digest", digest)
                put("size", size)
                expectedDigest?.let { put("expectedDigest", it) }
                conflictDigest?.let { put("conflictDigest", it) }
            },
            reply,
        )
        throwOnFailure(copied)
    }

    /** Idempotent close for a source, target or stage ticket. */
    suspend fun close(ticket: Long): Unit = ticketCommand("close", ticket)

    // ------------------------------------------------------------------
    // Mapping helpers (status -> typed failure; JSON -> typed values)
    // ------------------------------------------------------------------

    private suspend fun ticketCommand(operation: String, ticket: Long): Unit =
        withContext(Dispatchers.IO) {
            coroutineContext.ensureActive()
            require(ticket > 0)
            val reply = ByteArray(REPLY_BYTES)
            val copied = command(operation, json { put("ticket", ticket) }, reply)
            throwOnFailure(copied)
        }

    private fun json(body: JSONObject.() -> Unit): ByteArray =
        JSONObject().apply(body).toString().encodeToByteArray()

    private fun throwOnFailure(copied: Int) {
        if (copied < 0) throw DeviceWorkspaceNativeException(copied)
    }

    private fun parseScope(reply: ByteArray, copied: Int): String {
        val scope = replyObject(reply, copied).getString("scope")
        require(scope.isNotEmpty() && scope.length <= SCOPE_BYTES && !scope.contains('/'))
        return scope
    }

    private fun replyObject(reply: ByteArray, copied: Int): JSONObject {
        if (copied < 0) throw DeviceWorkspaceNativeException(copied)
        require(copied in 1..reply.size)
        return try {
            JSONObject(reply.decodeToString(endIndex = copied, throwOnInvalidSequence = true))
        } catch (_: Exception) {
            throw DeviceWorkspaceNativeException(-105)
        }
    }

    private fun requireValidPath(path: String) {
        require(path.isNotEmpty() && path.length <= PATH_BYTES)
        require(!path.startsWith("/") && !path.startsWith("~") && !path.contains('\u0000'))
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return buildString(digest.size * 2) {
            for (byte in digest) {
                val value = byte.toInt() and 255
                append("0123456789abcdef"[value ushr 4])
                append("0123456789abcdef"[value and 15])
            }
        }
    }

    /** Lint-friendly reference for hosts that validate ids before calling. */
    fun canonicalTaskID(value: String): Boolean =
        try {
            UUID.fromString(value).toString().equals(value, ignoreCase = true)
        } catch (failure: IllegalArgumentException) {
            false
        }
}
