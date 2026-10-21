// SPDX-License-Identifier: MPL-2.0
//
// Streaming tar.gz extractor for the qualification host (no third-party
// deps). Everything is bounded: the archive is decompressed incrementally,
// per-entry and total byte budgets are enforced, truncated payloads are an
// error, and paths are sanitized so nothing escapes the destination.
//
// Symlinks and hardlinks ARE materialized (a Debian rootfs needs /bin/sh and
// loader links), but never followed: any entry whose path crosses an existing
// symlink inside the destination is skipped, and link targets are stored
// verbatim without resolution.

package com.floe.linuxruntime.host

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.zip.GZIPInputStream

object TarGz {

    data class Result(
        val entries: Long,
        val files: Long,
        val directories: Long,
        val symlinks: Long,
        val hardlinks: Long,
        val skipped: Long,
        val bytesWritten: Long,
        val skippedReasons: List<String>,
    )

    private const val CHUNK = 64 * 1024
    private const val MAX_ENTRY_BYTES = 512L * 1024 * 1024 // 512 MiB per member
    private const val MAX_TOTAL_BYTES = 4L * 1024 * 1024 * 1024 // 4 GiB total

    @Throws(IOException::class)
    fun extract(archive: File, dest: File): Result {
        dest.mkdirs()
        val root = dest.canonicalFile
        var entries = 0L; var files = 0L; var dirs = 0L; var symlinks = 0L
        var hardlinks = 0L; var skipped = 0L; var total = 0L
        val reasons = mutableListOf<String>()

        GZIPInputStream(archive.inputStream().buffered(CHUNK)).use { gz ->
            val header = ByteArray(512)
            var pendingLongName: String? = null
            var pendingPaxPath: String? = null

            fun readFully(buf: ByteArray, off: Int, len: Int): Boolean {
                var got = 0
                while (got < len) {
                    val n = gz.read(buf, off + got, len - got)
                    if (n < 0) { if (got > 0) throw IOException("truncated tar header"); return false }
                    got += n
                }
                return true
            }

            fun skipFully(n: Long) {
                var left = n
                val scratch = ByteArray(CHUNK)
                while (left > 0) {
                    val want = minOf(left, scratch.size.toLong()).toInt()
                    val r = gz.read(scratch, 0, want)
                    if (r < 0) throw IOException("truncated tar payload")
                    left -= r
                }
            }

            while (true) {
                if (!readFully(header, 0, 512)) break // clean EOF between members
                if (header.all { it == 0.toByte() }) break
                entries++
                if (entries > 100_000) throw IOException("archive entry budget exceeded")

                val size = parseSize(header, 124, 12)
                val typeByte = header[156]
                val type = typeByte.toInt()
                if (size < 0 || size > MAX_ENTRY_BYTES) throw IOException("invalid entry size")
                if ((type == 'L'.code || type == 'K'.code || type == 'x'.code || type == 'g'.code) && size > 1_048_576) {
                    throw IOException("tar metadata budget exceeded")
                }

                if (type == 'L'.code) { // GNU longname
                    pendingLongName = readStringEntry(gz, size)
                    continue
                }
                if (type == 'K'.code) { // GNU longlink: skip (targets re-derived below)
                    skipFully(round512(size).toLong()); continue
                }
                if (type == 'x'.code || type == 'g'.code) { // pax
                    val payload = readStringEntry(gz, size)
                    if (type == 'x'.code) {
                        pendingPaxPath = parsePaxPath(payload)
                    }
                    continue
                }

                val rawName = parseString(header, 0, 100)
                val prefix = parseString(header, 345, 155)
                val name = pendingPaxPath ?: pendingLongName
                    ?: (if (prefix.isNotEmpty()) "$prefix/$rawName" else rawName)
                pendingLongName = null
                pendingPaxPath = null
                val linkName = parseString(header, 157, 100)

                if (name.isEmpty() || name.startsWith("/") || name.contains("../") ||
                    name == ".." || name.startsWith("./../")
                ) {
                    skipped++; reasons += "unsafe path: $name"
                    skipFully(round512(size).toLong())
                    continue
                }
                if (size > MAX_ENTRY_BYTES) {
                    skipped++; reasons += "entry too large: $name ($size)"
                    skipFully(round512(size).toLong())
                    continue
                }
                if (total + size > MAX_TOTAL_BYTES) {
                    throw IOException("total extract budget exceeded at $name")
                }

                val target = resolveNoFollow(root, name)
                if (target == null) {
                    skipped++; reasons += "path crosses symlink: $name"
                    skipFully(round512(size).toLong())
                    continue
                }

                when {
                    type == '5'.code || name.endsWith("/") -> {
                        if (isLink(target)) throw IOException("directory path is a symlink")
                        if (!target.isDirectory && !target.mkdirs()) throw IOException("cannot create directory")
                        dirs++
                        skipFully(round512(size).toLong())
                    }
                    type == '2'.code -> { // symlink: store target verbatim, never follow
                        target.parentFile?.mkdirs()
                        if (target.exists() || isLink(target)) target.delete()
                        val ok = runCatching {
                            java.nio.file.Files.createSymbolicLink(
                                target.toPath(), java.nio.file.Paths.get(linkName),
                            )
                        }.isSuccess
                        if (ok) symlinks++ else { skipped++; reasons += "symlink failed: $name" }
                        skipFully(round512(size).toLong())
                    }
                    type == '1'.code -> { // hardlink: target must resolve inside root
                        val linkTarget = resolveNoFollow(root, linkName)
                        if (linkTarget == null || isLink(linkTarget) || !linkTarget.isFile) {
                            skipped++; reasons += "hardlink target outside/missing: $name -> $linkName"
                        } else {
                            target.parentFile?.mkdirs()
                            if (target.exists() || isLink(target)) target.delete()
                            if (linkTarget.hardLinkToCompat(target)) hardlinks++ else {
                                linkTarget.copyTo(target, overwrite = true); files++
                            }
                        }
                        skipFully(round512(size).toLong())
                    }
                    type == '0'.code || type == 0 -> {
                        target.parentFile?.mkdirs()
                        if (isLink(target) && !target.delete()) throw IOException("cannot replace archive symlink")
                        val written = streamToFile(gz, target, size)
                        total += written; files++
                        val mode = parseString(header, 100, 8).trim().toIntOrNull(8)
                            ?: throw IOException("invalid archive mode: $name")
                        android.system.Os.chmod(target.path, mode and 511)
                    }
                    else -> {
                        skipped++; reasons += "unsupported type ${typeByte.toInt().toChar()}: $name"
                        skipFully(round512(size).toLong())
                    }
                }
                // consume padding to 512 boundary for members we handled inline
                val pad = round512(size) - size
                if (pad > 0 && (type == '0'.code || type == 0)) skipFully(pad)
            }
        }
        return Result(entries, files, dirs, symlinks, hardlinks, skipped, total, reasons.take(50))
    }

    /** Read a small string member (longname/pax) fully. */
    private fun readStringEntry(gz: InputStream, size: Long): String {
        val buf = ByteArray(size.toInt())
        var got = 0
        while (got < size) {
            val n = gz.read(buf, got, (size - got).toInt())
            if (n < 0) throw IOException("truncated tar string member")
            got += n
        }
        val pad = round512(size) - size
        skipN(gz, pad)
        return String(buf, Charsets.UTF_8).trimEnd('\u0000')
    }

    private fun skipN(gz: InputStream, n: Long) {
        var left = n
        val scratch = ByteArray(CHUNK)
        while (left > 0) {
            val want = minOf(left, scratch.size.toLong()).toInt()
            val r = gz.read(scratch, 0, want)
            if (r < 0) throw IOException("truncated tar")
            left -= r
        }
    }

    /** Stream exactly [size] bytes to [target]; error if the archive truncates. */
    private fun streamToFile(gz: InputStream, target: File, size: Long): Long {
        var left = size
        var written = 0L
        target.outputStream().buffered(CHUNK).use { out ->
            val buf = ByteArray(CHUNK)
            while (left > 0) {
                val want = minOf(left, buf.size.toLong()).toInt()
                val n = gz.read(buf, 0, want)
                if (n < 0) throw IOException("truncated payload writing ${target.name}")
                out.write(buf, 0, n)
                left -= n; written += n
            }
        }
        return written
    }

    /**
     * Resolve [name] under [root] without following ANY symlink component.
     * Returns null if a path component is an existing symlink (possible
     * escape), otherwise the absolute target file (which may not exist yet).
     */
    private fun resolveNoFollow(root: File, name: String): File? {
        var cur = root
        val parts = name.split('/').filter { it.isNotEmpty() && it != "." }
        for ((idx, part) in parts.withIndex()) {
            if (part == "..") return null
            val next = File(cur, part)
            if (isLink(next)) {
                return if (idx == parts.lastIndex) next else null // symlink as leaf is ok
            }
            if (idx < parts.lastIndex && next.exists() && !next.isDirectory) return null
            cur = next
        }
        return cur
    }

    private fun isLink(f: File): Boolean =
        runCatching { java.nio.file.Files.isSymbolicLink(f.toPath()) }.getOrDefault(false)

    private fun File.hardLinkToCompat(target: File): Boolean = runCatching {
        java.nio.file.Files.createLink(target.toPath(), this.toPath())
        true
    }.getOrDefault(false)

    /** Minimal pax path attribute extraction ("25 path=<value>\n"). */
    private fun parsePaxPath(payload: String): String? {
        var i = 0
        while (i < payload.length) {
            val sp = payload.indexOf(' ', i)
            if (sp < 0) return null
            val len = payload.substring(i, sp).toIntOrNull() ?: return null
            if (len <= 0 || i + len > payload.length) return null
            val rec = payload.substring(sp + 1, i + len - 1) // drop trailing \n
            if (rec.startsWith("path=")) return rec.removePrefix("path=")
            i += len
        }
        return null
    }

    private fun round512(size: Long): Long = (size + 511) / 512 * 512

    private fun parseString(header: ByteArray, at: Int, len: Int): String {
        var end = at
        while (end < at + len && header[end] != 0.toByte()) end++
        return String(header, at, end - at, Charsets.UTF_8)
    }

    private fun parseSize(header: ByteArray, at: Int, len: Int): Long {
        if (header[at].toInt() and 0x80 != 0) {
            var v = 0L
            for (i in at + 1 until at + len) v = (v shl 8) or (header[i].toLong() and 0xFF)
            return v
        }
        return parseString(header, at, len).trim().toLongOrNull(8) ?: 0L
    }
}
