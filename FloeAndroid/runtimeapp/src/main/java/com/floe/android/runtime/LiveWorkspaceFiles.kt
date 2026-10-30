// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.util.Base64

/**
 * G07.3A — bounded READ-ONLY live guest file snapshots.
 *
 * WHY this exists: the native Core and the runtime UID are different processes
 * with different UIDs, and the guest `/workspace` is a directory owned by the
 * runtime process that PRoot mounts into the guest. Core cannot see bytes the
 * terminal created until the writable export runs at session close. The Files
 * surface therefore needs a READ-ONLY view over the EXISTING runtime IPC while
 * the PTY session is still live — without closing it, without forcing an
 * export and without pretending an unstable read was complete.
 *
 * Safety contract (enforced here, not by the caller):
 *  * The root is the live session's OWN canonical workspace directory
 *    (`Running.workspaceRoot`), resolved in [LinuxRuntimeOperations]. No
 *    caller-supplied absolute path, symlink root or environment root is used.
 *  * Relative paths are validated component-by-component. Absolute paths,
 *    empty components, `.`/`..`, NUL, control characters, trailing slashes and
 *    over-long paths are refused. Every component is `lstat`ed with
 *    NOFOLLOW_LINKS; a symlink anywhere in the path is refused for CONTENT
 *    reads and listed (never followed) in a tree.
 *  * Bounds: <= [MAX_TREE_ENTRIES] entries, depth <= [MAX_DEPTH], path <=
 *    1024 bytes; content reads <= [MAX_READ_BYTES] bytes and offsets must be
 *    inside the file. The JSON envelope (base64 expands 4/3) stays well under
 *    the frozen 64 KiB runtime wire.
 *  * Metadata/content consistency: the file is opened O_NOFOLLOW; `fstat` is
 *    taken before and after the read and the path is re-lstat'ed. A size,
 *    mtime, device, inode or short-read change returns a typed `retry`, never
 *    a partial "snapshot complete". A race that makes the path change type is
 *    `retry` too.
 *  * Nothing is written, created, deleted, renamed, exported or closed. This
 *    path cannot mutate the workspace, Core drafts or the writable export.
 */
internal class LiveWorkspaceFiles(
    /** Measured runtime boot token; injectable so the focused JVM regression
     *  does not depend on Android's Process stub. */
    private val generation: () -> String = { RuntimeProcessIdentity.bootToken },
    /** Focused-test seam that runs AFTER the page read and BEFORE the
     *  metadata/content consistency check. Production is the empty lambda. */
    private val beforeConsistencyCheck: () -> Unit = {},
) {
    enum class Kind(val wire: String) { FILE("file"), DIRECTORY("directory"), SYMLINK("symlink"), OTHER("other") }

    /**
     * Lists one directory level (or a bounded recursive tree when
     * `recursive` is true). Returned paths are canonical RELATIVE paths with
     * `/` separators. Sorting is deterministic (byte order) so paging /
     * golden fixtures are stable.
     */
    fun tree(root: File, payload: JSONObject): JSONObject {
        val relative = payload.optString("relativePath", "")
        val maxEntries = payload.optInt("maxEntries", DEFAULT_TREE_ENTRIES)
            .coerceIn(1, MAX_TREE_ENTRIES)
        val maxDepth = payload.optInt("maxDepth", DEFAULT_DEPTH).coerceIn(0, MAX_DEPTH)
        val recursive = payload.optBoolean("recursive", true)
        val base = safeDirectory(root, relative) ?: return refused("pathOutOfScope")
        val entries = ArrayList<JSONObject>(minOf(maxEntries, 128))
        val listing = StringBuilder()
        var serializedBudget = 0
        val pending = ArrayDeque<Pair<File, String>>()
        pending.addLast(base to relative)
        var truncated = false
        while (pending.isNotEmpty()) {
            val (directory, prefix) = pending.removeFirst()
            // BOUNDED per-directory enumeration: never materialize the whole
            // directory. Keep at most `remaining + 1` lexicographically
            // smallest names in a max-heap; the extra one proves truncation.
            // A real deadline bounds pathological directories (the output
            // itself is already bounded; memory must be too).
            val capacity = maxEntries - entries.size
            if (capacity <= 0) { truncated = true; break }
            val keep = capacity + 1
            val heap = java.util.PriorityQueue<String>(keep, compareByDescending { it })
            var enumerated = 0
            var timedOut = false
            val deadlineNanos = System.nanoTime() + DIRECTORY_ENUMERATION_BUDGET_NANOS
            try {
                Files.newDirectoryStream(directory.toPath()).use { stream ->
                    for (child in stream) {
                        val name = child.fileName.toString()
                        enumerated++
                        if ((enumerated and 0xFF) == 0 && System.nanoTime() >= deadlineNanos) {
                            timedOut = true
                            break
                        }
                        if (heap.size < keep) {
                            heap.add(name)
                        } else {
                            val largest = heap.peek()
                            if (largest != null && name < largest) {
                                heap.poll()
                                heap.add(name)
                            }
                        }
                    }
                }
            } catch (_: Exception) {
                return refused("readFailed")
            }
            if (timedOut) truncated = true
            val children = heap.sorted()
            val overflow = children.size > capacity
            val outputCount = minOf(children.size, capacity)
            if (overflow) truncated = true
            for (index in 0 until outputCount) {
                if (entries.size >= maxEntries || serializedBudget >= MAX_TREE_BYTES) {
                    truncated = true; break
                }
                val name = children[index]
                val path = childPath(prefix, name)
                val pathBytes = path.toByteArray(Charsets.UTF_8).size
                if (pathBytes > MAX_PATH_BYTES || serializedBudget + pathBytes + 96 > MAX_TREE_BYTES) {
                    truncated = true; break
                }
                serializedBudget += pathBytes + 96
                val file = File(directory, name)
                val attributes = try {
                    Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, NOFOLLOW_LINKS)
                } catch (_: Exception) {
                    // Vanished between listing and lstat: honest typed retry.
                    return retry("changedDuringListing")
                }
                val kind = when {
                    attributes.isSymbolicLink -> Kind.SYMLINK
                    attributes.isDirectory -> Kind.DIRECTORY
                    attributes.isRegularFile -> Kind.FILE
                    else -> Kind.OTHER
                }
                val size = if (kind == Kind.FILE) attributes.size() else 0L
                val mtime = attributes.lastModifiedTime().toMillis()
                entries.add(JSONObject()
                    .put("path", path)
                    .put("kind", kind.wire)
                    .put("size", size)
                    .put("mtimeMillis", mtime))
                listing.append(path).append('|').append(kind.wire).append('|')
                    .append(size).append('|').append(mtime).append('\n')
                if (kind == Kind.DIRECTORY && recursive && prefixDepth(path) < maxDepth) {
                    pending.addLast(file to path)
                }
            }
            if (entries.size >= maxEntries || serializedBudget >= MAX_TREE_BYTES) {
                truncated = true; break
            }
            if (overflow) { truncated = true; break }
        }
        return JSONObject()
            .put("state", "ok")
            .put("entries", org.json.JSONArray().also { array -> entries.forEach { array.put(it) } })
            .put("truncated", truncated)
            .put("listingToken", sha256Hex(generation() + "\n" + listing.toString()))
            // No pagination cursor: `truncated` means this bounded listing is
            // incomplete. A consumer must narrow the subtree (Main uses a
            // maxDepth=0 direct-children preview), never concatenate pages.
            .put("generation", generation())
    }

    /** Reads one bounded page of one regular file. */
    fun read(root: File, payload: JSONObject): JSONObject {
        val relative = payload.optString("relativePath", "")
        val offset = payload.optLong("offset", 0L)
        val maxBytes = payload.optInt("maxBytes", DEFAULT_READ_BYTES).coerceIn(1, MAX_READ_BYTES)
        if (offset < 0) return refused("invalidOffset")
        val resolved = safeRegularFile(root, relative) ?: return refused("pathOutOfScope")
        val file = resolved.first
        val before = resolved.second
        if (offset > before.size()) return refused("offsetPastEnd")
        val remaining = before.size() - offset
        if (remaining == 0L) {
            return JSONObject().put("state", "ok").put("path", relative)
                .put("offset", offset).put("bytes", 0).put("size", before.size())
                .put("mtimeMillis", before.lastModifiedTime().toMillis())
                .put("digest", sha256Hex(""))
                .put("consistencyToken", pageToken(generation(), relative, offset, 0,
                    before.size(), before.lastModifiedTime().toMillis(), sha256Hex("")))
                .put("truncated", false).put("generation", generation())
        }
        val length = minOf(remaining, maxBytes.toLong()).toInt()
        val bytes = ByteArray(length)
        try {
            FileChannel.open(file.toPath(), java.nio.file.StandardOpenOption.READ, NOFOLLOW_LINKS).use { channel ->
                var position = offset
                var filled = 0
                val buffer = ByteBuffer.wrap(bytes)
                while (filled < length) {
                    val read = channel.read(buffer, position)
                    if (read <= 0) break
                    filled += read
                    position += read
                }
                if (filled != length) return retry("shortRead")
            }
        } catch (_: Exception) {
            return retry("readFailed")
        }
        beforeConsistencyCheck()
        // Metadata/content consistency: the SAME path must still describe the
        // SAME file with the SAME size/mtime after the read.
        val after = try {
            Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        } catch (_: Exception) {
            return retry("changedDuringRead")
        }
        if (after.isSymbolicLink || !after.isRegularFile ||
            after.size() != before.size() ||
            after.lastModifiedTime() != before.lastModifiedTime() ||
            after.fileKey() != before.fileKey()) {
            return retry("changedDuringRead")
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it) }
        return JSONObject()
            .put("state", "ok")
            .put("path", relative)
            .put("offset", offset)
            .put("bytes", length)
            .put("size", before.size())
            .put("mtimeMillis", before.lastModifiedTime().toMillis())
            .put("digest", digest)
            .put("consistencyToken", pageToken(generation(), relative, offset, length,
                before.size(), before.lastModifiedTime().toMillis(), digest))
            .put("contentBase64", Base64.getEncoder().encodeToString(bytes))
            .put("truncated", offset + length < before.size())
            .put("generation", generation())
    }

    // ---- path safety ----------------------------------------------------------

    private fun safeDirectory(root: File, relative: String): File? {
        if (!validRelative(relative)) return null
        val canonicalRoot = canonicalRoot(root) ?: return null
        if (relative.isEmpty()) return canonicalRoot
        val resolved = resolveComponents(canonicalRoot, relative, allowFinalSymlink = false) ?: return null
        return resolved.first.takeIf { it.isDirectory }
    }

    private fun safeRegularFile(root: File, relative: String): Pair<File, BasicFileAttributes>? {
        if (relative.isEmpty() || !validRelative(relative)) return null
        val canonicalRoot = canonicalRoot(root) ?: return null
        val (file, attributes) = resolveComponents(canonicalRoot, relative, allowFinalSymlink = false)
            ?: return null
        if (!attributes.isRegularFile) return null
        return file to attributes
    }

    /**
     * Resolves [relative] under [root] ONE component at a time with
     * NOFOLLOW_LINKS. A symlink at any component refuses. The final component
     * must exist; intermediate components must be real directories.
     */
    private fun resolveComponents(
        root: File,
        relative: String,
        allowFinalSymlink: Boolean,
    ): Pair<File, BasicFileAttributes>? {
        val components = relative.split('/')
        var directory = root
        for ((index, component) in components.withIndex()) {
            val last = index == components.lastIndex
            val child = File(directory, component)
            val attributes = try {
                Files.readAttributes(child.toPath(), BasicFileAttributes::class.java, NOFOLLOW_LINKS)
            } catch (_: Exception) {
                return null
            }
            if (attributes.isSymbolicLink) {
                if (!(last && allowFinalSymlink)) return null
            } else if (!last && !attributes.isDirectory) {
                return null
            }
            if (last) return child to attributes
            directory = child
        }
        return null
    }

    private fun canonicalRoot(root: File): File? {
        return try {
            // NEVER use canonicalFile here: it RESOLVES a symlinked root. The
            // runtime hands an already absolute/normalized owned path; this
            // lstat is the no-follow proof that the root is a real directory.
            val path = root.toPath().toAbsolutePath().normalize()
            if (path != root.toPath()) {
                null
            } else {
                val attributes = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
                path.toFile().takeIf { attributes.isDirectory && !attributes.isSymbolicLink }
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Grammar only: identity and containment are proven by the lstat walk. */
    private fun validRelative(relative: String): Boolean {
        if (relative.isEmpty()) return true
        if (relative.length > MAX_PATH_BYTES) return false
        if (relative.startsWith("/") || relative.contains('\\') || relative.contains('\u0000')) return false
        if (relative.endsWith("/")) return false
        val components = relative.split('/')
        if (components.size > MAX_COMPONENTS) return false
        return components.all { component ->
            component.isNotEmpty() && component != "." && component != ".." &&
                component.none { it.code < 0x20 || it.code == 0x7f }
        }
    }

    /**
     * Page consistency token: SHA-256 over the page's closed identity tuple.
     * It is NOT a whole-file/tree snapshot; it lets a preview prove the exact
     * bytes+version it displayed, and a re-read with a different token means
     * the page changed. Consumers validate [digest] over the decoded bytes and
     * strict UTF-8 separately; the token only fences identity.
     */
    private fun pageToken(generation: String, path: String, offset: Long, bytes: Int,
                          size: Long, mtimeMillis: Long, digest: String): String =
        sha256Hex("g073a-page-v1\n$generation\n$path\n$offset\n$bytes\n$size\n$mtimeMillis\n$digest")

    private fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private fun childPath(prefix: String, name: String): String =
        if (prefix.isEmpty()) name else "$prefix/$name"

    private fun prefixDepth(path: String): Int = if (path.isEmpty()) 0 else path.count { it == '/' } + 1

    private fun refused(code: String): JSONObject =
        JSONObject().put("state", "refused").put("code", code)

    private fun retry(code: String): JSONObject =
        JSONObject().put("state", "retry").put("code", code)

    companion object {
        const val MAX_TREE_ENTRIES = 512
        const val DEFAULT_TREE_ENTRIES = 200
        const val MAX_DEPTH = 8
        const val DEFAULT_DEPTH = 3
        const val MAX_READ_BYTES = 24 * 1024
        /** Total serialized listing budget (the runtime wire envelope is
         *  64 KiB; long guest paths could otherwise exceed it). */
        const val MAX_TREE_BYTES = 48 * 1024
        /** Wall-clock budget for ONE directory's bounded enumeration. */
        const val DIRECTORY_ENUMERATION_BUDGET_NANOS = 1_500_000_000L
        const val DEFAULT_READ_BYTES = 16 * 1024
        const val MAX_PATH_BYTES = 1_024
        const val MAX_COMPONENTS = 64
    }
}
