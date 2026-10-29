// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.ink

import com.floe.android.core.notesmedia.media.InkFormat
import com.floe.android.core.notesmedia.media.NotesMediaType
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets
import java.util.zip.CRC32

/** Typed decode/encode refusal. Path-free and safe for diagnostics. */
enum class InkCodecRefusal {
    BAD_MAGIC,
    UNSUPPORTED_VERSION,
    TRUNCATED,
    CHECKSUM_MISMATCH,
    TRAILING_BYTES,
    TOO_LARGE,
    TOO_MANY_STROKES,
    INVALID_FIELD,
}

sealed class InkDecodeResult {
    data class Ok(val snapshot: InkSnapshot) : InkDecodeResult()
    data class Invalid(val refusal: InkCodecRefusal) : InkDecodeResult()
}

sealed class InkEncodeResult {
    data class Ok(val bytes: ByteArray) : InkEncodeResult()
    data class Refused(val refusal: InkCodecRefusal) : InkEncodeResult()
}

/**
 * Versioned binary codec for the editable Android ink format.
 *
 * Why binary and not JSON: stroke input batches are already compact binary
 * (androidx.ink's `StrokeInputBatch` encoding), and a text envelope would
 * inflate them ~4x while adding a parser dependency. The format is explicit
 * and self-describing: magic + version + media type + geometry + strokes +
 * CRC-32. The decoder is strict (no trailing bytes, no silent truncation, no
 * unknown version reinterpretation) and returns a typed refusal. The original
 * file is never touched on failure.
 *
 * Compatibility: only [InkFormat.CURRENT] is written; [InkFormat.MIN_READABLE]
 * ..CURRENT are read. A newer file is refused, never converted to a blank
 * document. Apple PencilKit is a DIFFERENT media type and never reaches this
 * codec (see [com.floe.android.core.notesmedia.media.ForeignInkResource]).
 */
object InkDocumentCodec {

    private const val HEADER_BYTES = 12 // 8 magic + 2 version + 2 flags
    private const val U8_MAX = 0xFF
    private const val MAX_STRING_BYTES = InkFormat.MAX_STRING_CHARS * 4

    fun encode(snapshot: InkSnapshot): InkEncodeResult {
        if (snapshot.strokes.size > InkFormat.MAX_STROKES) {
            return InkEncodeResult.Refused(InkCodecRefusal.TOO_MANY_STROKES)
        }
        val out = ByteArrayOutputStream(1024 + snapshot.strokes.size * 128)
        try {
            out.write(InkFormat.MAGIC.toByteArray(StandardCharsets.US_ASCII))
            writeU16(out, InkFormat.CURRENT)
            writeU16(out, 0)
            writeString(out, NotesMediaType.FLOE_INK)
            writeString(out, snapshot.documentId)
            writeString(out, snapshot.geometry.pageKey)
            writeF32(out, snapshot.geometry.widthPt)
            writeF32(out, snapshot.geometry.heightPt)
            writeI64(out, snapshot.revision)
            writeU32(out, snapshot.strokes.size)
            for (stroke in snapshot.strokes) {
                writeI64(out, stroke.id)
                writeString(out, stroke.brush.familyId)
                writeI32(out, stroke.brush.colorArgb)
                writeF32(out, stroke.brush.widthPt)
                out.write(stroke.inputFormat and U8_MAX)
                writeU32(out, stroke.inputs.size)
                out.write(stroke.inputs)
                writeF32(out, stroke.bounds.left)
                writeF32(out, stroke.bounds.top)
                writeF32(out, stroke.bounds.right)
                writeF32(out, stroke.bounds.bottom)
                writeF32(out, stroke.transform.a)
                writeF32(out, stroke.transform.b)
                writeF32(out, stroke.transform.c)
                writeF32(out, stroke.transform.d)
                writeF32(out, stroke.transform.e)
                writeF32(out, stroke.transform.f)
                if (out.size().toLong() > InkFormat.MAX_DOCUMENT_BYTES) {
                    return InkEncodeResult.Refused(InkCodecRefusal.TOO_LARGE)
                }
            }
            val crc = CRC32()
            crc.update(out.toByteArray())
            writeU32(out, crc.value.toInt())
            val bytes = out.toByteArray()
            if (bytes.size.toLong() > InkFormat.MAX_DOCUMENT_BYTES) {
                return InkEncodeResult.Refused(InkCodecRefusal.TOO_LARGE)
            }
            return InkEncodeResult.Ok(bytes)
        } catch (_: Exception) {
            return InkEncodeResult.Refused(InkCodecRefusal.INVALID_FIELD)
        }
    }

    fun decode(bytes: ByteArray): InkDecodeResult {
        if (bytes.size < HEADER_BYTES + 4) return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        if (bytes.size.toLong() > InkFormat.MAX_DOCUMENT_BYTES) {
            return InkDecodeResult.Invalid(InkCodecRefusal.TOO_LARGE)
        }
        val magic = String(bytes, 0, 8, StandardCharsets.US_ASCII)
        if (magic != InkFormat.MAGIC) return InkDecodeResult.Invalid(InkCodecRefusal.BAD_MAGIC)
        val reader = Reader(bytes)
        reader.pos = 8
        val version = reader.u16() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        if (!InkFormat.readable(version)) {
            return InkDecodeResult.Invalid(InkCodecRefusal.UNSUPPORTED_VERSION)
        }
        reader.u16() // flags (reserved; must be ignored on read)
        val mediaType = reader.string(MAX_STRING_BYTES) ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        if (mediaType != NotesMediaType.FLOE_INK) return InkDecodeResult.Invalid(InkCodecRefusal.INVALID_FIELD)
        val documentId = reader.string(MAX_STRING_BYTES) ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        val pageKey = reader.string(MAX_STRING_BYTES) ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        val widthPt = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        val heightPt = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        val revision = reader.i64() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        val strokeCount = reader.u32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        if (strokeCount < 0) return InkDecodeResult.Invalid(InkCodecRefusal.INVALID_FIELD)
        if (strokeCount > InkFormat.MAX_STROKES) {
            return InkDecodeResult.Invalid(InkCodecRefusal.TOO_MANY_STROKES)
        }
        val strokes = ArrayList<InkStroke>(minOf(strokeCount, 64))
        for (i in 0 until strokeCount) {
            val id = reader.i64() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val family = reader.string(MAX_STRING_BYTES) ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val color = reader.i32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val width = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val inputFormat = reader.u8() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val inputLen = reader.u32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            if (inputLen <= 0 || inputLen > InkFormat.MAX_INPUT_BYTES_PER_STROKE) {
                return InkDecodeResult.Invalid(InkCodecRefusal.INVALID_FIELD)
            }
            if (!reader.has(inputLen)) return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val input = bytes.copyOfRange(reader.pos, reader.pos + inputLen)
            reader.pos += inputLen
            val l = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val t = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val r = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val b = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val a = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val bb = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val c = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val d = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val e = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val f = reader.f32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
            val stroke = try {
                InkStroke(
                    id = id,
                    brush = InkBrushSpec(family, color, width),
                    inputs = input,
                    bounds = InkBox(l, t, r, b),
                    inputFormat = inputFormat,
                    transform = InkAffine(a, bb, c, d, e, f),
                )
            } catch (_: IllegalArgumentException) {
                return InkDecodeResult.Invalid(InkCodecRefusal.INVALID_FIELD)
            }
            strokes.add(stroke)
        }
        if (reader.remaining() != 4) {
            return InkDecodeResult.Invalid(
                if (reader.remaining() < 4) InkCodecRefusal.TRUNCATED else InkCodecRefusal.TRAILING_BYTES,
            )
        }
        val declaredCrc = reader.u32() ?: return InkDecodeResult.Invalid(InkCodecRefusal.TRUNCATED)
        val crc = CRC32()
        crc.update(bytes, 0, bytes.size - 4)
        if (crc.value.toInt() != declaredCrc) {
            return InkDecodeResult.Invalid(InkCodecRefusal.CHECKSUM_MISMATCH)
        }
        val snapshot = try {
            InkSnapshot(
                documentId = documentId,
                geometry = InkPageGeometry(pageKey, widthPt, heightPt),
                revision = revision,
                strokes = strokes,
            )
        } catch (_: IllegalArgumentException) {
            return InkDecodeResult.Invalid(InkCodecRefusal.INVALID_FIELD)
        }
        return InkDecodeResult.Ok(snapshot)
    }

    /** Reads only the version field (diagnostics/UI capability reporting). */
    fun probeVersion(bytes: ByteArray): Int? {
        if (bytes.size < HEADER_BYTES) return null
        if (String(bytes, 0, 8, StandardCharsets.US_ASCII) != InkFormat.MAGIC) return null
        return ((bytes[8].toInt() and 0xff) shl 8) or (bytes[9].toInt() and 0xff)
    }

    // ------------------------------------------------------------------
    // Writer helpers
    // ------------------------------------------------------------------

    private fun writeU16(out: ByteArrayOutputStream, value: Int) {
        out.write((value ushr 8) and 0xff)
        out.write(value and 0xff)
    }

    private fun writeU32(out: ByteArrayOutputStream, value: Int) {
        out.write((value ushr 24) and 0xff)
        out.write((value ushr 16) and 0xff)
        out.write((value ushr 8) and 0xff)
        out.write(value and 0xff)
    }

    private fun writeI32(out: ByteArrayOutputStream, value: Int) = writeU32(out, value)

    private fun writeI64(out: ByteArrayOutputStream, value: Long) {
        writeU32(out, (value ushr 32).toInt())
        writeU32(out, value.toInt())
    }

    private fun writeF32(out: ByteArrayOutputStream, value: Float) = writeI32(out, value.toRawBits())

    private fun writeString(out: ByteArrayOutputStream, value: String) {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        require(bytes.size <= MAX_STRING_BYTES) { "Codec string too long" }
        writeU16(out, bytes.size)
        out.write(bytes)
    }

    // ------------------------------------------------------------------
    // Reader
    // ------------------------------------------------------------------

    private class Reader(private val bytes: ByteArray) {
        var pos: Int = 0

        fun remaining(): Int = bytes.size - pos
        fun has(count: Int): Boolean = remaining() >= count

        fun u8(): Int? {
            if (!has(1)) return null
            return bytes[pos++].toInt() and 0xff
        }

        fun u16(): Int? {
            if (!has(2)) return null
            val v = ((bytes[pos].toInt() and 0xff) shl 8) or (bytes[pos + 1].toInt() and 0xff)
            pos += 2
            return v
        }

        fun u32(): Int? {
            if (!has(4)) return null
            val v = ((bytes[pos].toInt() and 0xff) shl 24) or
                ((bytes[pos + 1].toInt() and 0xff) shl 16) or
                ((bytes[pos + 2].toInt() and 0xff) shl 8) or
                (bytes[pos + 3].toInt() and 0xff)
            pos += 4
            return v
        }

        fun i32(): Int? = u32()

        fun i64(): Long? {
            val hi = u32() ?: return null
            val lo = u32() ?: return null
            return (hi.toLong() shl 32) or (lo.toLong() and 0xffffffffL)
        }

        fun f32(): Float? = i32()?.let { Float.fromBits(it) }

        fun string(maxBytes: Int): String? {
            val length = u16() ?: return null
            if (length < 0 || length > maxBytes || !has(length)) return null
            val value = String(bytes, pos, length, StandardCharsets.UTF_8)
            pos += length
            return value
        }
    }
}
