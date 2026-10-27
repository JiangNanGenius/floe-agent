// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.officeai.verification

import java.io.File
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.util.zip.Inflater

internal sealed class ZipOpenResult {
    data class Ready(val zip: BoundedZipReader) : ZipOpenResult()
    data class Refused(val code: String) : ZipOpenResult()
}

internal sealed class PartReadResult {
    data class Bytes(val data: ByteArray) : PartReadResult()
    data class Refused(val code: String) : PartReadResult()
    object Missing : PartReadResult()
}

/** Reads ZIP packages WITHOUT extracting to the filesystem and WITHOUT ever
 * holding the whole artifact in memory: it parses the End-Of-Central-Directory
 * and the central directory records directly (java.util.zip exposes no
 * per-entry encryption flag, so the raw records are the only honest way to
 * refuse encrypted entries), bounds entry count and declared inflation, and
 * decompresses ONLY the explicitly requested parts with a hard output cap.
 * Uses only RandomAccessFile + java.util.zip.Inflater, stable on JVM and
 * Android API 28..37.
 */
internal class BoundedZipReader private constructor(
    private val file: RandomAccessFile,
    private val entries: Map<String, ZipEntryMeta>,
) {

    fun hasPart(name: String): Boolean = entries.containsKey(name)

    /** Returns the decompressed bytes of one part, bounded by MAX_PART_BYTES. */
    fun readPart(name: String): PartReadResult {
        val meta = entries[name] ?: return PartReadResult.Missing
        return try {
            readEntry(meta)
        } catch (error: RuntimeException) {
            PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
        }
    }

    fun close() {
        try {
            file.close()
        } catch (error: RuntimeException) {
            // Closing is best-effort; the file itself is never modified.
        }
    }

    private fun readEntry(meta: ZipEntryMeta): PartReadResult {
        if (meta.uncompressedSize > VerificationLimits.MAX_PART_BYTES) {
            return PartReadResult.Refused(VerificationCodes.ZIP_PART_TOO_LARGE)
        }
        if (meta.compressedSize > VerificationLimits.MAX_PART_BYTES) {
            return PartReadResult.Refused(VerificationCodes.ZIP_PART_TOO_LARGE)
        }
        val header = readAt(meta.localHeaderOffset, 30L)
            ?: return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
        if (u32LE(header, 0) != LOCAL_HEADER_SIGNATURE) {
            return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
        }
        val localNameLen = u16LE(header, 26)
        val localExtraLen = u16LE(header, 28)
        val localMethod = u16LE(header, 8)
        if (localMethod != meta.method) {
            return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
        }
        val localNameBytes = readAt(meta.localHeaderOffset + 30L, localNameLen.toLong())
            ?: return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
        if (String(localNameBytes, StandardCharsets.UTF_8) != meta.name) {
            return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
        }
        val dataStart = meta.localHeaderOffset + 30L + localNameLen + localExtraLen
        val compressed = readAt(dataStart, meta.compressedSize)
            ?: return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
        return when (meta.method) {
            0 -> {
                if (meta.compressedSize != meta.uncompressedSize) {
                    PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
                } else {
                    PartReadResult.Bytes(compressed)
                }
            }
            8 -> inflateDeflate(compressed, meta.uncompressedSize)
            else -> PartReadResult.Refused(VerificationCodes.ZIP_UNSUPPORTED_METHOD)
        }
    }

    private fun inflateDeflate(compressed: ByteArray, declaredSize: Long): PartReadResult {
        if (compressed.isEmpty()) {
            return if (declaredSize == 0L) {
                PartReadResult.Bytes(ByteArray(0))
            } else {
                PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
            }
        }
        val inflater = Inflater(true)
        try {
            inflater.setInput(compressed)
            val out = java.io.ByteArrayOutputStream(
                minOf(
                    declaredSize.coerceAtLeast(64L),
                    1L shl 20,
                ).toInt(),
            )
            val buffer = ByteArray(VerificationLimits.READ_CHUNK_BYTES)
            val cap = VerificationLimits.MAX_PART_BYTES
            while (!inflater.finished()) {
                if (inflater.needsInput() || inflater.needsDictionary()) {
                    return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
                }
                val produced = try {
                    inflater.inflate(buffer)
                } catch (error: java.util.zip.DataFormatException) {
                    return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
                }
                if (produced == 0) {
                    return PartReadResult.Refused(VerificationCodes.ZIP_MALFORMED)
                }
                if (out.size().toLong() + produced > cap) {
                    return PartReadResult.Refused(VerificationCodes.ZIP_PART_TOO_LARGE)
                }
                out.write(buffer, 0, produced)
            }
            return PartReadResult.Bytes(out.toByteArray())
        } finally {
            inflater.end()
        }
    }

    private fun readAt(offset: Long, length: Long): ByteArray? {
        if (offset < 0L || length < 0L) return null
        val size = length.toInt()
        if (size.toLong() != length) return null
        return try {
            val buffer = ByteArray(size)
            if (offset + length > file.length()) return null
            file.seek(offset)
            file.readFully(buffer)
            buffer
        } catch (error: Exception) {
            null
        }
    }

    companion object {
        private const val EOCD_SIGNATURE = 0x06054B50L
        private const val EOCD64_LOCATOR_SIGNATURE = 0x07064B50L
        private const val EOCD64_RECORD_SIGNATURE = 0x06064B50L
        private const val CENTRAL_SIGNATURE = 0x02014B50L
        private const val LOCAL_HEADER_SIGNATURE = 0x04034B50L
        private const val CENTRAL_FIXED_BYTES = 46L
        private const val EOCD_MIN_BYTES = 22L
        private const val EOCD_SEARCH_TAIL_BYTES = 65557L

        fun open(file: File): ZipOpenResult {
            val raf = try {
                RandomAccessFile(file, "r")
            } catch (error: Exception) {
                return ZipOpenResult.Refused(VerificationCodes.ARTIFACT_MISSING)
            }
            val parsed = try {
                parseCentralDirectory(raf)
            } catch (error: Exception) {
                runCatching { raf.close() }
                return ZipOpenResult.Refused(VerificationCodes.ZIP_MALFORMED)
            }
            return when (parsed) {
                is CentralParse.Failed -> {
                    runCatching { raf.close() }
                    ZipOpenResult.Refused(parsed.code)
                }
                is CentralParse.Ok -> ZipOpenResult.Ready(
                    BoundedZipReader(raf, parsed.entries),
                )
            }
        }

        private sealed class CentralParse {
            data class Ok(val entries: Map<String, ZipEntryMeta>) : CentralParse()
            data class Failed(val code: String) : CentralParse()
        }

        private fun parseCentralDirectory(file: RandomAccessFile): CentralParse {
            val length = try {
                file.length()
            } catch (error: Exception) {
                return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
            }
            if (length < EOCD_MIN_BYTES) {
                return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
            }
            val tailLen = minOf(length, EOCD_SEARCH_TAIL_BYTES)
            val tail = ByteArray(tailLen.toInt())
            try {
                file.seek(length - tailLen)
                file.readFully(tail)
            } catch (error: Exception) {
                return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
            }
            var eocdInTail = -1
            var cursor = tail.size - EOCD_MIN_BYTES.toInt()
            while (cursor >= 0) {
                if (u32LE(tail, cursor) == EOCD_SIGNATURE) break
                cursor -= 1
            }
            if (cursor < 0) {
                return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
            }
            eocdInTail = cursor
            val eocdPos = length - tailLen + eocdInTail
            var entryCount = u16LE(tail, eocdInTail + 10).toLong()
            var cdSize = u32LE(tail, eocdInTail + 12).toLong()
            var cdOffset = u32LE(tail, eocdInTail + 16).toLong()
            if (entryCount == 0xFFFFL || cdSize == 0xFFFFFFFFL || cdOffset == 0xFFFFFFFFL) {
                val locatorPos = eocdPos - 20L
                if (locatorPos < 0L) {
                    return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                }
                val locator = readStatic(file, locatorPos, 20)
                    ?: return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                if (u32LE(locator, 0) != EOCD64_LOCATOR_SIGNATURE) {
                    return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                }
                val recordPos = u64LE(locator, 8)
                val record = readStatic(file, recordPos, 56)
                    ?: return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                if (u32LE(record, 0) != EOCD64_RECORD_SIGNATURE) {
                    return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                }
                entryCount = u64LE(record, 32)
                cdSize = u64LE(record, 40)
                cdOffset = u64LE(record, 48)
            }
            if (entryCount > VerificationLimits.MAX_ENTRIES) {
                return CentralParse.Failed(VerificationCodes.ZIP_TOO_MANY_ENTRIES)
            }
            if (cdSize > VerificationLimits.MAX_CENTRAL_DIR_BYTES) {
                return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
            }
            if (cdOffset < 0L || cdSize < 0L || cdOffset + cdSize > length) {
                return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
            }
            val central = readStatic(file, cdOffset, cdSize)
                ?: return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
            val entries = LinkedHashMap<String, ZipEntryMeta>()
            var totalUncompressed = 0L
            var pos = 0
            var scanned = 0
            while (scanned < entryCount) {
                if (pos + CENTRAL_FIXED_BYTES.toInt() > central.size) {
                    return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                }
                if (u32LE(central, pos) != CENTRAL_SIGNATURE) {
                    return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                }
                val flags = u16LE(central, pos + 8)
                val method = u16LE(central, pos + 10)
                var compressedSize = u32LE(central, pos + 20).toLong()
                var uncompressedSize = u32LE(central, pos + 24).toLong()
                val nameLen = u16LE(central, pos + 28)
                val extraLen = u16LE(central, pos + 30)
                val commentLen = u16LE(central, pos + 32)
                var localOffset = u32LE(central, pos + 42).toLong()
                if (nameLen > VerificationLimits.MAX_ENTRY_NAME_BYTES) {
                    return CentralParse.Failed(VerificationCodes.ZIP_UNSAFE_ENTRY)
                }
                val recordEnd = pos + CENTRAL_FIXED_BYTES.toInt() + nameLen + extraLen + commentLen
                if (recordEnd > central.size) {
                    return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                }
                val rawName = central.copyOfRange(pos + 46, pos + 46 + nameLen)
                val name = String(rawName, StandardCharsets.UTF_8)
                if (!isSafePartName(name)) {
                    return CentralParse.Failed(VerificationCodes.ZIP_UNSAFE_ENTRY)
                }
                if (uncompressedSize == 0xFFFFFFFFL || compressedSize == 0xFFFFFFFFL ||
                    localOffset == 0xFFFFFFFFL
                ) {
                    val extra = central.copyOfRange(
                        pos + 46 + nameLen,
                        pos + 46 + nameLen + extraLen,
                    )
                    val zip64 = parseZip64Extra(extra, uncompressedSize, compressedSize, localOffset)
                        ?: return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                    uncompressedSize = zip64.first
                    compressedSize = zip64.second
                    localOffset = zip64.third
                }
                if (flags and 0x1 != 0 || method == 99) {
                    return CentralParse.Failed(VerificationCodes.ZIP_ENCRYPTED)
                }
                if (method != 0 && method != 8) {
                    return CentralParse.Failed(VerificationCodes.ZIP_UNSUPPORTED_METHOD)
                }
                if (uncompressedSize < 0L || compressedSize < 0L || localOffset < 0L) {
                    return CentralParse.Failed(VerificationCodes.ZIP_MALFORMED)
                }
                if (totalUncompressed <= Long.MAX_VALUE - uncompressedSize) {
                    totalUncompressed += uncompressedSize
                } else {
                    return CentralParse.Failed(VerificationCodes.ZIP_UNBOUNDED)
                }
                if (!entries.containsKey(name) && uncompressedSize > 0L) {
                    entries.put(
                        name,
                        ZipEntryMeta(name, method, compressedSize, uncompressedSize, localOffset),
                    )
                } else if (!entries.containsKey(name)) {
                    entries.put(
                        name,
                        ZipEntryMeta(name, method, compressedSize, 0L, localOffset),
                    )
                }
                pos = recordEnd
                scanned += 1
            }
            val allowance = VerificationLimits.MIN_INFLATION_ALLOWANCE_BYTES +
                length * VerificationLimits.MAX_INFLATION_RATIO
            if (totalUncompressed > allowance) {
                return CentralParse.Failed(VerificationCodes.ZIP_UNBOUNDED)
            }
            return CentralParse.Ok(entries)
        }

        private fun isSafePartName(name: String): Boolean {
            if (name.isEmpty() || name.startsWith("/") || name.contains("\\")) return false
            for (segment in name.split("/")) {
                if (segment == "..") return false
            }
            return true
        }

        private fun parseZip64Extra(
            extra: ByteArray,
            uncompressed: Long,
            compressed: Long,
            offset: Long,
        ): Triple<Long, Long, Long>? {
            var u = uncompressed
            var c = compressed
            var o = offset
            var pos = 0
            while (pos + 4 <= extra.size) {
                val id = u16LE(extra, pos)
                val size = u16LE(extra, pos + 2)
                val bodyStart = pos + 4
                if (size > extra.size - bodyStart) break
                if (id == 0x0001) {
                    var field = bodyStart
                    if (u == 0xFFFFFFFFL) {
                        if (field + 8 > bodyStart + size) return null
                        u = u64LE(extra, field)
                        field += 8
                    }
                    if (c == 0xFFFFFFFFL) {
                        if (field + 8 > bodyStart + size) return null
                        c = u64LE(extra, field)
                        field += 8
                    }
                    if (o == 0xFFFFFFFFL) {
                        if (field + 8 > bodyStart + size) return null
                        o = u64LE(extra, field)
                        field += 8
                    }
                }
                pos = bodyStart + size
            }
            return Triple(u, c, o)
        }

        private fun readStatic(file: RandomAccessFile, offset: Long, length: Long): ByteArray? {
            if (offset < 0L || length < 0L || offset + length > file.length()) return null
            val size = length.toInt()
            if (size.toLong() != length) return null
            return try {
                val buffer = ByteArray(size)
                file.seek(offset)
                file.readFully(buffer)
                buffer
            } catch (error: Exception) {
                null
            }
        }

        private fun u16LE(bytes: ByteArray, at: Int): Int =
            (bytes[at].toInt() and 0xFF) or ((bytes[at + 1].toInt() and 0xFF) shl 8)

        private fun u32LE(bytes: ByteArray, at: Int): Long =
            (bytes[at].toLong() and 0xFF) or
                ((bytes[at + 1].toLong() and 0xFF) shl 8) or
                ((bytes[at + 2].toLong() and 0xFF) shl 16) or
                ((bytes[at + 3].toLong() and 0xFF) shl 24)

        private fun u64LE(bytes: ByteArray, at: Int): Long {
            var value = 0L
            for (index in 0 until 8) {
                value = value or ((bytes[at + index].toLong() and 0xFF) shl (8 * index))
            }
            return value
        }
    }
}

internal data class ZipEntryMeta(
    val name: String,
    val method: Int,
    val compressedSize: Long,
    val uncompressedSize: Long,
    val localHeaderOffset: Long,
)
