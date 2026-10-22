// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.install

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import org.tukaani.xz.LZMA2Options
import org.tukaani.xz.XZOutputStream

/**
 * Synthetic tar/tar.xz fixtures for focused component checks. Headers are
 * assembled byte-exactly (including checksums), so corruption tests target
 * precisely one field. Production code and these fixtures share no helper.
 */
class TarArchive(private val prefix: String = "top") {
    private val out = ByteArrayOutputStream()

    private fun headerBlock(
        name: String, mode: Int, size: Long, type: Char, link: String, mtime: Long,
    ): ByteArray {
        val block = ByteArray(512)
        writeField(block, 0, 100, name)
        writeOctal(block, 100, 8, mode.toLong())
        writeOctal(block, 108, 8, 0) // uid
        writeOctal(block, 116, 8, 0) // gid
        writeOctal(block, 124, 12, size)
        writeOctal(block, 136, 12, mtime)
        writeField(block, 148, 8, "        ") // spaces during checksum
        block[156] = type.code.toByte()
        writeField(block, 157, 100, link)
        writeField(block, 257, 6, "ustar")
        writeField(block, 263, 2, "00")
        var sum = 0L
        for (b in block) sum += (b.toInt() and 0xFF)
        writeOctal(block, 148, 8, sum)
        return block
    }

    private fun writeField(block: ByteArray, offset: Int, length: Int, value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        for (i in 0 until minOf(length, bytes.size)) block[offset + i] = bytes[i]
    }

    private fun writeOctal(block: ByteArray, offset: Int, length: Int, value: Long) {
        val octal = java.lang.Long.toOctalString(value)
        val padded = if (octal.length > length) octal.takeLast(length)
        else octal.padStart(length, '0')
        writeField(block, offset, length, padded)
    }

    private fun pad(bytes: Int) {
        val filler = ((512L - bytes % 512L) % 512L).toInt()
        out.write(ByteArray(filler))
    }

    private fun emitPaxThen(headers: Map<String, String>?) {
        if (headers.isNullOrEmpty()) return
        val sb = StringBuilder()
        for ((key, value) in headers) {
            val kv = "$key=$value"
            var len = kv.length + 3
            while (true) {
                val candidate = len.toString().length + 1 + kv.length + 1
                if (candidate == len) break
                len = candidate
            }
            sb.append(len).append(' ').append(kv).append('\n')
        }
        val payload = sb.toString().toByteArray(Charsets.UTF_8)
        out.write(headerBlock("././@PaxHeader", 0x124, payload.size.toLong(), 'x', "", 0))
        out.write(payload)
        pad(payload.size)
    }

    fun directory(name: String, mode: Int = 0x1ED, mtime: Long = MTIME): TarArchive {
        emitPaxThen(null)
        out.write(headerBlock("$prefix/$name", mode, 0, '5', "", mtime))
        return this
    }

    fun file(
        name: String, content: ByteArray, mode: Int = 0x1A4, mtime: Long = MTIME,
        paxHeaders: Map<String, String>? = null,
    ): TarArchive {
        emitPaxThen(paxHeaders)
        val bytes = content
        out.write(headerBlock("$prefix/$name", mode, bytes.size.toLong(), '0', "", mtime))
        out.write(bytes)
        pad(bytes.size)
        return this
    }

    fun symlink(name: String, targetText: String, mtime: Long = MTIME): TarArchive {
        out.write(headerBlock("$prefix/$name", 0x1FF, 0, '2', targetText, mtime))
        return this
    }

    fun hardlink(name: String, targetName: String, mtime: Long = MTIME): TarArchive {
        out.write(headerBlock("$prefix/$name", 0x1A4, 0, '1', "$prefix/$targetName", mtime))
        return this
    }

    fun rootDirectory(mode: Int = 0x1ED): TarArchive {
        out.write(headerBlock(prefix, mode, 0, '5', "", MTIME))
        return this
    }

    fun characterDevice(name: String, mode: Int = 0x1B6): TarArchive {
        out.write(headerBlock("$prefix/$name", mode, 0, '3', "", MTIME))
        return this
    }

    fun blockDevice(name: String, mode: Int = 0x1B6): TarArchive {
        out.write(headerBlock("$prefix/$name", mode, 0, '4', "", MTIME))
        return this
    }

    fun fifo(name: String, mode: Int = 0x1B6): TarArchive {
        out.write(headerBlock("$prefix/$name", mode, 0, '6', "", MTIME))
        return this
    }

    /** Raw GNU longname ('L') + longlink ('K') support for hostile cases. */
    fun longSymlink(longName: String, targetText: String, longTarget: Boolean): TarArchive {
        emitLong('L', longName)
        if (longTarget) emitLong('K', targetText)
        out.write(
            headerBlock("././@LongLink", 0x1FF, 0, '2', if (longTarget) "" else targetText, MTIME),
        )
        return this
    }

    private fun emitLong(type: Char, value: String) {
        val payload = value.toByteArray(Charsets.UTF_8)
        out.write(headerBlock("././@LongLink", 0, payload.size.toLong(), type, "", 0))
        out.write(payload)
        pad(payload.size)
    }

    /** Raw byte mutation hooks for corruption tests. */
    fun toTar(): ByteArray {
        val copy = ByteArrayOutputStream()
        out.writeTo(copy)
        copy.write(ByteArray(1024)) // two zero end blocks
        return copy.toByteArray()
    }

    fun toXz(tarOverride: ByteArray? = null): ByteArray {
        val bytes = tarOverride ?: toTar()
        val compressed = ByteArrayOutputStream()
        XZOutputStream(compressed, LZMA2Options(1)).use { it.write(bytes) }
        return compressed.toByteArray()
    }

    companion object {
        const val MTIME = 1_706_705_216L
    }
}

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

internal fun sha256Hex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").apply { update(bytes) }.encodeHexLower()

internal fun sha256HexFile(file: File): String =
    MessageDigest.getInstance("SHA-256").apply {
        FileInputStream(file).use { update(it.readBytes()) }
    }.encodeHexLower()

/** Synthetic catalog sized for a produced archive; production fields explicit. */
internal fun catalogFor(
    archive: ByteArray,
    prefix: String = "top",
    maxEntries: Long = 1_000_000,
    maxTotalExtractBytes: Long = 64L * 1024 * 1024,
    maxEntryBytes: Long = 8L * 1024 * 1024,
    maxMetadataRecords: Long = 1_000_000,
    maxMetadataRecordBytes: Long = 1024L * 1024,
    devicePolicy: DeviceNodePolicy = DeviceNodePolicy.EXCLUDE_AND_COUNT,
    minRegularFiles: Long = 0,
    minDirectories: Long = 0,
    minSymbolicLinks: Long = 0,
): RootfsCatalogEntry = RootfsCatalogEntry(
    catalogId = "test-catalog-fixed",
    version = "v1",
    displayName = "Synthetic test catalog",
    archiveFileName = "fixture.tar.xz",
    httpsUrl = "https://invalid.floe.test/fixture.tar.xz",
    archiveSha256 = sha256Hex(archive),
    knownArchiveBytes = archive.size.toLong(),
    maxArchiveBytes = archive.size.toLong() * 2 + 64,
    maxEntryBytes = maxEntryBytes,
    maxTotalExtractBytes = maxTotalExtractBytes,
    maxEntries = maxEntries,
    maxMetadataRecords = maxMetadataRecords,
    maxMetadataRecordBytes = maxMetadataRecordBytes,
    expectedTopPrefix = prefix,
    deviceNodePolicy = devicePolicy,
    minRegularFiles = minRegularFiles,
    minDirectories = minDirectories,
    minSymbolicLinks = minSymbolicLinks,
)

/** In-memory transport: no network anywhere in the focused checks. */
internal class FakeFetch(private val bytes: ByteArray) : ByteFetch {
    var openCount = 0
    override fun open(httpsUrl: String): FetchedStream {
        openCount += 1
        return FetchedStream(bytes.size.toLong(), bytes.inputStream())
    }
}

internal class FileBytesFetch(private val file: File) : ByteFetch {
    var openCount = 0
    override fun open(httpsUrl: String): FetchedStream {
        openCount += 1
        return FetchedStream(file.length(), FileInputStream(file))
    }
}

/** Delegation seam to force free-space floors without touching the volume. */
internal class LowDiskOps(
    private val delegate: PosixFileOps,
    var usable: Long,
) : PosixFileOps by delegate {
    override fun usableSpace(file: File): Long = usable
}

internal fun unixModeAt(file: File): Int =
    (java.nio.file.Files.getAttribute(file.toPath(), "unix:mode") as Int) and 0xFFF

internal fun expectInstall(block: () -> Unit): Pair<InstallFailure, String> {
    val error = runCatching { block() }.exceptionOrNull()
    check(error is RootfsInstallException) { "expected RootfsInstallException, got $error" }
    return error.failure to error.detail
}

internal fun expectCancelled(block: () -> Unit) {
    val error = runCatching { block() }.exceptionOrNull()
    check(error is RootfsCancelledException) { "expected cancellation, got $error" }
}

/** Build one raw tar member with an arbitrary (hostile) name. */
internal fun rawTarMember(
    name: String,
    type: Char,
    mode: Int = 0x1A4,
    link: String = "",
    content: ByteArray = ByteArray(0),
): ByteArray {
    val block = ByteArray(512)
    val nameBytes = name.toByteArray(Charsets.UTF_8)
    for (i in 0 until minOf(100, nameBytes.size)) block[i] = nameBytes[i]
    writeOctalField(block, 100, 8, mode.toLong())
    writeOctalField(block, 108, 8, 0)
    writeOctalField(block, 116, 8, 0)
    writeOctalField(block, 124, 12, content.size.toLong())
    writeOctalField(block, 136, 12, 1_706_705_216L)
    "        ".toByteArray().copyInto(block, 148)
    block[156] = type.code.toByte()
    val linkBytes = link.toByteArray(Charsets.UTF_8)
    for (i in 0 until minOf(100, linkBytes.size)) block[157 + i] = linkBytes[i]
    "ustar".toByteArray().copyInto(block, 257)
    block[262] = 0
    "00".toByteArray().copyInto(block, 263)
    var sum = 0L
    for (b in block) sum += (b.toInt() and 0xFF)
    writeOctalField(block, 148, 8, sum)
    val out = java.io.ByteArrayOutputStream()
    out.write(block)
    out.write(content)
    out.write(ByteArray(((512L - content.size % 512L) % 512L).toInt()))
    return out.toByteArray()
}

internal fun hostileTar(vararg members: ByteArray): ByteArray =
    java.io.ByteArrayOutputStream().apply {
        members.forEach { write(it) }
        write(ByteArray(1024))
    }.toByteArray()

internal fun writeOctalField(block: ByteArray, offset: Int, length: Int, value: Long) {
    val octal = java.lang.Long.toOctalString(value).padStart(length, '0')
    octal.toByteArray().copyInto(block, offset, 0, length)
}

internal fun xzOf(tar: ByteArray): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    org.tukaani.xz.XZOutputStream(out, org.tukaani.xz.LZMA2Options(1)).use { it.write(tar) }
    return out.toByteArray()
}
