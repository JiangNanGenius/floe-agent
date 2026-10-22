// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import org.tukaani.xz.CorruptedInputException
import org.tukaani.xz.MemoryLimitException
import org.tukaani.xz.XZInputStream

/**
 * Result counts for one extraction. Every archive member is accounted for:
 * materialized into the destination, explicitly excluded-and-counted per the
 * catalog device policy, or the run failed. Nothing is silently dropped.
 */
data class ExtractionStats(
    val entries: Long,
    val files: Long,
    val directories: Long,
    val symbolicLinks: Long,
    val hardLinks: Long,
    val excludedCharacterDevices: Long,
    val excludedBlockDevices: Long,
    val excludedFifos: Long,
    val metadataRecords: Long,
    val implicitDirectories: Long,
    val bytesWritten: Long,
    val mtimeFailures: Long,
)

/**
 * Streaming tar.xz materializer into a FRESH directory. It never touches an
 * existing rootfs: [extract] refuses a non-empty destination and the
 * installer only ever points it at private staging.
 *
 * Guarantees (all enforced, all failures abort the run):
 * - header checksum verified per member; base-256 sizes accepted
 * - pax ('x'/'g') and GNU ('L'/'K') extended records parsed with their own
 *   count and byte budgets; path/linkpath/size/mtime overrides applied
 * - absolute paths, '..' components and members outside the expected top
 *   prefix are rejected (UNSAFE_PATH)
 * - a member path crossing a stored symlink inside the destination aborts
 *   (WRITE_THROUGH_SYMLINK); symlink targets are stored verbatim, root-
 *   relative ones included, and are never followed during extraction
 * - hardlink members require an already-materialized regular target inside
 *   the destination (HARDLINK_TARGET_UNSAFE otherwise); no silent copies
 * - character/block/FIFO members are counted and excluded, or rejected, per
 *   the catalog policy; a device member with payload is corrupt
 * - truncation (EOF inside header/payload/missing end blocks) is an error
 * - per-member, total-bytes, entry-count and free-space-floor budgets
 * - cooperative cancellation between members and inside long payloads
 */
class TarXzExtractor(
    private val ops: PosixFileOps,
    private val decoderMemoryKiB: Int = 256 * 1024,
) {

    fun extract(
        archive: File,
        rootfsDirectory: File,
        catalog: RootfsCatalogEntry,
        progress: ProgressListener? = null,
        cancel: CancellationCheck? = null,
    ): ExtractionStats {
        if (ops.kind(rootfsDirectory) != FileKind.MISSING) {
            throw RootfsInstallException(
                InstallFailure.DESTINATION_COLLISION,
                "extraction target must be a fresh directory: ${rootfsDirectory.path}",
            )
        }
        ops.createDirectory(rootfsDirectory, 0x1ED) // 0755; root member re-modes
        if (catalog.requiresCaseSensitiveDestination) {
            // Two-byte probe: on a case-insensitive volume the lowercase
            // alias resolves to the uppercase file created above.
            val probe = File(rootfsDirectory, "FloeCaseProbe-A.tmp")
            val alias = File(rootfsDirectory, "floecaseprobe-a.tmp")
            try {
                probe.createNewFile()
                if (alias.exists()) {
                    throw RootfsInstallException(
                        InstallFailure.CASE_INSENSITIVE_DESTINATION,
                        "guest rootfs cannot live on a case-insensitive volume",
                    )
                }
            } finally {
                probe.delete()
            }
        }
        val state = ExtractionRun(ops, catalog, rootfsDirectory, progress, cancel, decoderMemoryKiB)
        // Any thrown failure aborts before publication; staging stays
        // uncommitted and the caller discards it. Exceptions propagate
        // verbatim (original failures are never softened).
        FileInputStream(archive).use { raw -> state.consume(raw) }
        return state.snapshot()
    }
}

/** One streaming run; all mutable counters live here, never on the extractor. */
private class ExtractionRun(
    private val ops: PosixFileOps,
    private val catalog: RootfsCatalogEntry,
    private val root: File,
    private val progress: ProgressListener?,
    private val cancel: CancellationCheck?,
    private val decoderMemoryKiB: Int,
) {
    private var entries = 0L
    private var files = 0L
    private var directories = 0L
    private var symbolicLinks = 0L
    private var hardLinks = 0L
    private var charExcluded = 0L
    private var blockExcluded = 0L
    private var fifoExcluded = 0L
    private var metadataRecords = 0L
    private var implicitDirectories = 0L
    private var bytesWritten = 0L
    private var mtimeFailures = 0L

    private var pendingLongName: String? = null
    private var pendingLongLink: String? = null
    private var paxPath: String? = null
    private var paxLinkPath: String? = null
    private var paxSize: Long? = null
    private var paxMtimeSeconds: Long? = null

    fun consume(raw: InputStream) {
        val xz = try {
            XZInputStream(raw, decoderMemoryKiB)
        } catch (e: MemoryLimitException) {
            throw decodeFailure("xz decoder needs more than ${decoderMemoryKiB / 1024} MiB", e)
        } catch (e: CorruptedInputException) {
            throw decodeFailure("xz container corrupt", e)
        } catch (e: IOException) {
            throw decodeFailure("xz stream cannot be opened", e)
        }
        val header = ByteArray(512)
        try {
            while (true) {
                checkCancel("between members")
                if (!readBlock(xz, header)) {
                    throw fail(InstallFailure.ARCHIVE_TRUNCATED, "stream ended without end marker")
                }
                if (isZeroBlock(header)) {
                    // Two zero blocks terminate; anything after must be zeros/EOF.
                    if (!readBlock(xz, header)) return
                    if (isZeroBlock(header)) {
                        drainTrailingZeros(xz)
                        return
                    }
                    throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "member follows end marker")
                }
                processMember(xz, header)
            }
        } catch (e: RootfsInstallException) {
            throw e
        } catch (e: RootfsCancelledException) {
            throw e
        } catch (e: CorruptedInputException) {
            throw decodeFailure("xz stream corrupt mid-decode", e)
        } catch (e: EOFException) {
            throw truncated("xz stream ended abruptly")
        } catch (e: IOException) {
            throw decodeFailure("xz read failed: ${e.message}", e)
        }
    }


    private fun processMember(xz: InputStream, header: ByteArray) {
        if (!verifyHeaderChecksum(header)) {
            throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "member ${entries + 1}")
        }
        val sizeField = parseOctalField(header, 124, 12)
            ?: throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "bad size field")
        if (sizeField < 0) {
            throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "negative size $sizeField")
        }
        val type = header[156].toInt().toChar()
        if (type == 'L' || type == 'K' || type == 'x' || type == 'g') {
            metadataRecords += 1
            if (metadataRecords > catalog.maxMetadataRecords) {
                throw fail(InstallFailure.METADATA_BUDGET, "record count exceeded")
            }
            if (sizeField > catalog.maxMetadataRecordBytes) {
                throw fail(
                    InstallFailure.METADATA_BUDGET,
                    "record of $sizeField bytes exceeds ${catalog.maxMetadataRecordBytes}",
                )
            }
            val payload = readBytesMember(xz, sizeField)
            when (type) {
                'L' -> pendingLongName = decodeCString(payload)
                'K' -> pendingLongLink = decodeCString(payload)
                'g' -> Unit // global pax: counted and validated, not applied
                else -> applyPaxFileRecord(payload)
            }
            return
        }
        val prefix = parseStringField(header, 345, 155)
        val rawName = parseStringField(header, 0, 100)
        val ustarName = if (prefix.isNotEmpty() && rawName.isNotEmpty()) "$prefix/$rawName" else rawName
        val name = paxPath ?: pendingLongName ?: ustarName
        pendingLongName = null
        paxPath = null
        val rawLink = parseStringField(header, 157, 100)
        val linkText = paxLinkPath ?: pendingLongLink ?: rawLink
        pendingLongLink = null
        paxLinkPath = null
        val size = paxSize ?: sizeField
        paxSize = null
        val mtimeSeconds = paxMtimeSeconds ?: parseOctalField(header, 136, 12)
        paxMtimeSeconds = null
        if (size < 0 || size > Long.MAX_VALUE - 512) {
            throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "resolved size overflow")
        }
        if (mtimeSeconds == null || mtimeSeconds < 0) {
            throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "bad mtime field")
        }
        if (size > catalog.maxEntryBytes) {
            throw fail(
                InstallFailure.SIZE_BUDGET, "member $name size $size exceeds ${catalog.maxEntryBytes}",
            )
        }
        if (bytesWritten + size > catalog.maxTotalExtractBytes) {
            throw fail(InstallFailure.SIZE_BUDGET, "total extract budget exceeded at $name")
        }
        entries += 1
        if (entries > catalog.maxEntries) {
            throw fail(InstallFailure.ENTRY_BUDGET, "more than ${catalog.maxEntries} members")
        }
        val mode = (parseOctalField(header, 100, 8)
            ?: throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "bad mode field for $name")).toInt()
        val asDir = type == '5' ||
            (name.endsWith('/') && (type == '0' || type == 0.toChar()))
        if (asDir) {
            requireZeroPayload(size, "directory $name")
            materializeDirectory(name, mode, mtimeSeconds)
        } else {
            when (type) {
                '0', '7', 0.toChar() -> {
                    // memberParts() rejects empty/NUL/traversal names.
                    materializeRegular(name, size, mode, mtimeSeconds, xz)
                }
                '2' -> materializeSymlink(name, linkText)
                '1' -> materializeHardlink(name, linkText)
                '3' -> materializeExcludedDevice(name, size, isChar = true)
                '4' -> materializeExcludedDevice(name, size, isChar = false)
                '6' -> materializeExcludedFifo(name, size)
                else -> throw fail(InstallFailure.ENTRY_TYPE_UNSUPPORTED, "type '$type'")
            }
        }
        checkCancel("after member $name")
        emitProgress(force = entries % EMIT_EVERY_ENTRIES == 0L)
    }

    /**
     * pax framing is BYTE-based (GNU/POSIX): record lengths count bytes,
     * values may be UTF-8 (Debian ships accented certificate filenames).
     * Records are parsed over raw bytes; only path/linkpath are decoded to
     * strings, as the standard mandates UTF-8 for those keys.
     */
    private fun applyPaxFileRecord(payload: ByteArray) {
        var index = 0
        while (index < payload.size) {
            var digitsEnd = index
            while (digitsEnd < payload.size &&
                (payload[digitsEnd].toInt() and 0xFF) in 0x30..0x39
            ) digitsEnd += 1
            if (digitsEnd == index || digitsEnd >= payload.size ||
                (payload[digitsEnd].toInt() and 0xFF) != 0x20
            ) {
                throw fail(
                    InstallFailure.ARCHIVE_HEADER_CORRUPT,
                    "malformed pax record framing at byte $index of ${payload.size}",
                )
            }
            val length = String(payload, index, digitsEnd - index, Charsets.US_ASCII)
                .toLongOrNull()
                ?: throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "pax record length")
            if (length <= 0 || length > Int.MAX_VALUE || index + length > payload.size ||
                payload[(index + length - 1).toInt()] != '\n'.code.toByte()
            ) {
                throw fail(
                    InstallFailure.ARCHIVE_HEADER_CORRUPT,
                    "pax record overflow at byte $index (len $length, size ${payload.size})",
                )
            }
            val bodyFrom = digitsEnd + 1
            val bodyTo = (index + length - 1).toInt() // exclusive of the trailing newline
            var equals = bodyFrom
            while (equals < bodyTo && (payload[equals].toInt() and 0xFF) != 0x3D) equals += 1
            if (equals == bodyFrom || equals >= bodyTo) {
                throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "pax record without key")
            }
            val key = String(payload, bodyFrom, equals - bodyFrom, Charsets.US_ASCII)
            when (key) {
                "path" -> paxPath = String(payload, equals + 1, bodyTo - equals - 1, Charsets.UTF_8)
                "linkpath" -> paxLinkPath =
                    String(payload, equals + 1, bodyTo - equals - 1, Charsets.UTF_8)
                "mtime" -> {
                    val text = String(payload, equals + 1, bodyTo - equals - 1, Charsets.US_ASCII)
                    paxMtimeSeconds = text.substringBefore('.', text).toLongOrNull()
                        ?: throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "pax mtime")
                }
                "size" -> {
                    val parsed = String(payload, equals + 1, bodyTo - equals - 1, Charsets.US_ASCII)
                        .toLongOrNull()
                        ?: throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "pax size")
                    if (parsed < 0) {
                        throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "negative pax size")
                    }
                    paxSize = parsed
                }
                else -> Unit // uninteresting pax keys (atime/ctime/uid/...) ignored
            }
            index += length.toInt()
        }
    }

    /** GNU longname/longlink payload: NUL-terminated UTF-8 text. */
    private fun decodeCString(bytes: ByteArray): String {
        var end = 0
        while (end < bytes.size && bytes[end] != 0.toByte()) end += 1
        return String(bytes, 0, end, Charsets.UTF_8)
    }


    /**
     * Normalize one archive path into destination-relative components.
     * Rejects absolute paths, '..' components, NUL bytes, overlong paths and
     * anything outside the catalog's single expected top prefix.
     */
    private fun memberParts(rawName: String): List<String> {
        // A trailing slash is a directory spelling, not an empty component.
        val name = rawName.trimEnd('/')
        if (name.isEmpty() ||
            name.toByteArray(Charsets.UTF_8).size > MAX_PATH_BYTES ||
            name.indexOf(Char(0)) >= 0
        ) {
            throw fail(InstallFailure.UNSAFE_PATH, "empty/overlong/NUL path: $name")
        }
        if (name.startsWith("/")) {
            throw fail(InstallFailure.UNSAFE_PATH, "absolute path: $name")
        }
        val components = name.split('/').filter { it != "." }
        if (components.any {
                it.isEmpty() || it == ".." ||
                    it.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES
            }
        ) {
            throw fail(InstallFailure.UNSAFE_PATH, "unsafe component: $name")
        }
        val prefix = catalog.expectedTopPrefix
        if (prefix.isNotEmpty()) {
            if (components.firstOrNull() != prefix) {
                throw fail(
                    InstallFailure.UNSAFE_PATH,
                    "member $name outside expected top prefix $prefix",
                )
            }
            return components.drop(1)
        }
        return components
    }

    /**
     * Resolve destination components without ever following a stored
     * symlink. Intermediate directories that the archive forgot to declare
     * are created (0755, counted as implicit). A leaf that already exists is
     * reported by kind so each member type can decide; symlinked leaves
     * always mean collision because extraction must not write through them.
     */
    private fun resolveLeaf(parts: List<String>): Pair<File, FileKind> {
        var cursor = root
        for (index in parts.indices) {
            val next = File(cursor, parts[index])
            val last = index == parts.lastIndex
            when (val kind = ops.kind(next)) {
                FileKind.MISSING -> if (!last) {
                    ops.createDirectory(next, 0x1ED)
                    implicitDirectories += 1
                }
                FileKind.DIRECTORY -> if (!last) cursor = next else return next to kind
                FileKind.SYMLINK -> if (!last) {
                    throw fail(
                        InstallFailure.WRITE_THROUGH_SYMLINK,
                        parts.joinToString("/"),
                    )
                }
                else -> if (!last) {
                    throw fail(
                        InstallFailure.DESTINATION_COLLISION,
                        "non-directory parent in ${parts.joinToString("/")}",
                    )
                }
            }
            if (last) {
                val leafKind = if (parts.isEmpty()) FileKind.DIRECTORY else ops.kind(next)
                return next to leafKind
            }
            cursor = next
        }
        // Empty parts: the archive root member maps onto root itself.
        return root to ops.kind(root)
    }

    private fun materializeDirectory(name: String, mode: Int, mtimeSeconds: Long) {
        val (leaf, kind) = resolveLeaf(memberParts(name))
        when (kind) {
            FileKind.MISSING -> ops.createDirectory(leaf, modeSafe(mode, 0x1ED))
            FileKind.DIRECTORY -> ops.chmod(leaf, modeSafe(mode, 0x1ED))
            else -> throw fail(InstallFailure.DESTINATION_COLLISION, "directory onto $kind: $name")
        }
        if (kind == FileKind.MISSING) directories += 1
        stampTime(leaf, mtimeSeconds)
    }

    private fun materializeSymlink(name: String, linkText: String) {
        if (linkText.isEmpty() || linkText.indexOf(Char(0)) >= 0) {
            throw fail(InstallFailure.UNSAFE_PATH, "empty/NUL symlink target for $name")
        }
        // The target string is stored verbatim (root-relative targets like
        // /proc/self/fd are legitimate guest semantics) and never resolved
        // against the host here.
        val (leaf, kind) = resolveLeaf(memberParts(name))
        if (kind != FileKind.MISSING) {
            throw fail(InstallFailure.DESTINATION_COLLISION, "symlink onto $name")
        }
        ops.symlink(leaf, linkText)
        symbolicLinks += 1
    }

    private fun materializeHardlink(name: String, linkText: String) {
        // A hardlink must reference an already-materialized regular member
        // inside the destination (same archive). Member-relative paths use
        // the identical prefix/traversal rules; symlink or directory targets
        // are refused so no link escapes or aliases a live structure.
        val targetParts = memberParts(linkText)
        if (targetParts.isEmpty()) {
            throw fail(InstallFailure.HARDLINK_TARGET_UNSAFE, "$name -> $linkText (archive root)")
        }
        val (target, targetKind) = resolveLeaf(targetParts)
        if (targetKind != FileKind.REGULAR) {
            throw fail(
                InstallFailure.HARDLINK_TARGET_UNSAFE,
                "$name -> $linkText is $targetKind",
            )
        }
        val (leaf, kind) = resolveLeaf(memberParts(name))
        if (kind != FileKind.MISSING) {
            throw fail(InstallFailure.DESTINATION_COLLISION, "hardlink onto $name")
        }
        ops.hardLink(target, leaf)
        hardLinks += 1
    }

    private fun materializeExcludedDevice(name: String, size: Long, isChar: Boolean) {
        requireZeroPayload(size, "device $name")
        if (catalog.deviceNodePolicy == DeviceNodePolicy.REJECT) {
            throw fail(InstallFailure.DEVICE_ENTRY_DISALLOWED, "device member $name")
        }
        if (isChar) charExcluded += 1 else blockExcluded += 1
    }

    private fun materializeExcludedFifo(name: String, size: Long) {
        requireZeroPayload(size, "fifo $name")
        if (catalog.deviceNodePolicy == DeviceNodePolicy.REJECT) {
            throw fail(InstallFailure.DEVICE_ENTRY_DISALLOWED, "fifo member $name")
        }
        fifoExcluded += 1
    }

    private fun materializeRegular(name: String, size: Long, mode: Int, mtimeSeconds: Long, xz: InputStream) {
        val (leaf, kind) = resolveLeaf(memberParts(name))
        if (kind != FileKind.MISSING) {
            throw fail(InstallFailure.DESTINATION_COLLISION, "file onto $name")
        }
        if (ops.usableSpace(root) < MIN_FREE_FLOOR_BYTES) {
            throw fail(InstallFailure.DISK_BUDGET, "free-space floor before $name")
        }
        ops.createNewFile(leaf).use { sink ->
            var left = size
            val buffer = ByteArray(CHUNK)
            while (left > 0) {
                if (cancel?.isCancelled() == true) {
                    throw RootfsCancelledException("inside payload of $name")
                }
                val want = minOf(left, buffer.size.toLong()).toInt()
                val n = xz.read(buffer, 0, want)
                if (n < 0) {
                    throw fail(InstallFailure.ARCHIVE_TRUNCATED, "payload of $name")
                }
                sink.write(buffer, 0, n)
                left -= n
                bytesWritten += n
            }
        }
        skipPadding(xz, size)
        ops.chmod(leaf, modeSafe(mode, 0x1A4))
        files += 1
        stampTime(leaf, mtimeSeconds)
    }

    private fun requireZeroPayload(size: Long, what: String) {
        if (size != 0L) {
            throw fail(InstallFailure.ARCHIVE_HEADER_CORRUPT, "$what carries a payload")
        }
    }

    private fun modeSafe(mode: Int, fallback: Int): Int =
        if (mode in 0..0xFFF) mode and 0xFFF else fallback

    private fun stampTime(leaf: File, mtimeSeconds: Long) {
        if (!ops.setModificationTime(leaf, mtimeSeconds * 1000L)) mtimeFailures += 1
    }

    private fun checkCancel(where: String) {
        if (cancel?.isCancelled() == true) {
            throw RootfsCancelledException(where)
        }
    }

    private fun emitProgress(force: Boolean) {
        val listener = progress ?: return
        if (!force) return
        listener.onProgress(
            RootfsInstallProgress(
                InstallPhase.EXTRACT, -1L, -1L, entries, bytesWritten,
            ),
        )
    }

    private fun fail(failure: InstallFailure, detail: String): RootfsInstallException =
        RootfsInstallException(failure, detail)

    private fun decodeFailure(detail: String, cause: Throwable) =
        RootfsInstallException(InstallFailure.DECODE_FAILED, detail, cause)

    fun snapshot() = ExtractionStats(
        entries, files, directories, symbolicLinks, hardLinks,
        charExcluded, blockExcluded, fifoExcluded,
        metadataRecords, implicitDirectories, bytesWritten, mtimeFailures,
    )
}

// ---------------------------------------------------------------------------
// Tar primitives (pure byte logic; no allocation beyond fixed buffers).
// ---------------------------------------------------------------------------

private const val CHUNK = 64 * 1024
private const val EMIT_EVERY_ENTRIES = 128L
private const val MAX_PATH_BYTES = 4096
private const val MAX_NAME_BYTES = 255
private const val MIN_FREE_FLOOR_BYTES = 16L * 1024 * 1024

private fun truncated(detail: String) =
    RootfsInstallException(InstallFailure.ARCHIVE_TRUNCATED, detail)

/** Reads one full 512-byte block. False only on clean EOF at a block boundary. */
private fun readBlock(source: InputStream, buffer: ByteArray): Boolean {
    var got = 0
    while (got < 512) {
        val n = source.read(buffer, got, 512 - got)
        if (n < 0) {
            if (got == 0) return false
            throw truncated("partial header block ($got/512)")
        }
        got += n
    }
    return true
}

private fun isZeroBlock(header: ByteArray): Boolean = header.all { it == 0.toByte() }

private fun drainTrailingZeros(source: InputStream) {
    val block = ByteArray(512)
    while (readBlock(source, block)) {
        if (!isZeroBlock(block)) {
            throw RootfsInstallException(
                InstallFailure.ARCHIVE_HEADER_CORRUPT, "trailing garbage after end marker",
            )
        }
    }
}

private fun verifyHeaderChecksum(header: ByteArray): Boolean {
    var unsigned = 0L
    for (i in header.indices) unsigned += (header[i].toInt() and 0xFF)
    // The checksum field itself is treated as eight spaces in the sum.
    for (i in 148 until 156) unsigned -= (header[i].toInt() and 0xFF)
    unsigned += 8L * 32L
    val stored = parseOctalField(header, 148, 8) ?: return false
    return stored == unsigned
}

/** Octal ASCII field with GNU space/NUL tolerance, or base-256 (high bit). */
private fun parseOctalField(header: ByteArray, offset: Int, length: Int): Long? {
    if (header[offset].toInt() and 0x80 != 0) {
        var value = (header[offset].toInt() and 0x7F).toLong()
        for (i in offset + 1 until offset + length) value = (value shl 8) or (header[i].toLong() and 0xFF)
        return value
    }
    var value = -1L
    for (i in offset until offset + length) {
        val b = header[i].toInt() and 0xFF
        if (b == '0'.code) {
            value = if (value < 0) 0L else (value shl 3)
            continue
        }
        if (b in '1'.code..'7'.code) {
            value = if (value < 0) 0L else value shl 3
            value = value or (b - '0'.code).toLong()
            continue
        }
        if (b == ' '.code || b == 0) {
            if (value >= 0) break // trailing terminator
            continue // leading padding
        }
        return null
    }
    return if (value < 0) 0L else value
}

private fun parseStringField(header: ByteArray, offset: Int, length: Int): String {
    var end = offset
    while (end < offset + length && header[end] != 0.toByte()) end++
    return String(header, offset, end - offset, Charsets.UTF_8)
}

/** Reads exactly size bytes plus block padding; EOF is truncation. */
private fun readBytesMember(source: InputStream, size: Long): ByteArray {
    val bytes = ByteArray(size.toInt()) // size already bounded by metadata budget
    var got = 0
    while (got < bytes.size) {
        val n = source.read(bytes, got, bytes.size - got)
        if (n < 0) throw truncated("partial extended header member")
        got += n
    }
    skipPadding(source, size)
    return bytes
}

private fun skipPadding(source: InputStream, size: Long) {
    val pad = ByteArray(512)
    var left = ((size + 511L) / 512L) * 512L - size
    while (left > 0) {
        val want = minOf(left, pad.size.toLong()).toInt()
        val n = source.read(pad, 0, want)
        if (n < 0) throw truncated("block padding")
        left -= n
    }
}
