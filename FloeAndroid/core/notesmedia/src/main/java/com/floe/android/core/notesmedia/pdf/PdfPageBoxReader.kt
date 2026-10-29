// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.notesmedia.pdf

import com.floe.android.core.notesmedia.media.Sha256
import java.io.ByteArrayInputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream

/**
 * Bounded, READ-ONLY PDF page-geometry reader.
 *
 * Why this exists: the shared Office PDF renderer deliberately exposes only a
 * page COUNT and a rasterized page (its isolated binder protocol has no page
 * size transaction, and `android.graphics.pdf.PdfRenderer` in the app process
 * would be a second parser for untrusted bytes). Annotation/ink export and
 * "correct paper coordinates" nevertheless need the real page box. This reader
 * extracts ONLY the page tree metadata (MediaBox/CropBox/Rotate) from the
 * verified snapshot:
 *
 *  - it never renders, never touches the renderer, never writes anything;
 *  - it is bounded in file size, object count, nesting depth, retained nodes,
 *    per-stream decompression and total inflation, and it polls cancellation;
 *  - it supports plain xref files AND Flate-compressed object streams
 *    (`/Type /ObjStm`), which is what modern producers emit;
 *  - it reports a TYPED refusal instead of guessing. A PDF whose page tree it
 *    cannot prove is never exported with invented page dimensions;
 *  - the resulting [PdfPageGeometry] is bound to the source's SHA-256, so a
 *    stale geometry can be detected after the source changed.
 *
 * Honest limits (documented, not hidden): linearized/encrypted documents
 * whose page tree is only reachable through encrypted object streams are
 * refused; unsupported stream filters are refused; page boxes are read from
 * the newest definition of each object number (later definitions win, which
 * matches incremental-update semantics for the fields we consume).
 */
class PdfPageBoxReader(private val limits: Limits = Limits()) {

    data class Limits(
        val maxFileBytes: Long = 128L shl 20,
        val maxObjects: Int = 200_000,
        val maxDepth: Int = 64,
        val maxRetainedNodes: Int = 1_000_000,
        val maxStreamBytes: Int = 16 shl 20,
        val maxTotalInflateBytes: Long = 64L shl 20,
        val maxPages: Int = PdfPageId.MAX_PAGE_INDEX,
        val maxDictEntries: Int = 64,
        val maxArrayItems: Int = 65_536,
    )

    fun read(
        file: File,
        sourceSha256: String,
        isCancelled: () -> Boolean = { false },
    ): PdfGeometryResult {
        if (!Sha256.isValid(sourceSha256)) return PdfGeometryResult.Refused(PdfGeometryRefusal.MALFORMED, false)
        if (!file.isFile) return PdfGeometryResult.Refused(PdfGeometryRefusal.NOT_REGULAR, false)
        val length = file.length()
        if (length <= 0L) return PdfGeometryResult.Refused(PdfGeometryRefusal.EMPTY, false)
        if (length > limits.maxFileBytes) return PdfGeometryResult.Refused(PdfGeometryRefusal.TOO_LARGE, false)

        var raf: RandomAccessFile? = null
        val buffer: ByteBuffer
        try {
            raf = RandomAccessFile(file, "r")
            buffer = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0L, length)
        } catch (_: Exception) {
            runCatching { raf?.close() }
            return PdfGeometryResult.Refused(PdfGeometryRefusal.IO_ERROR, false)
        }
        return try {
            Parser(buffer, limits, isCancelled).run(sourceSha256)
        } catch (_: PdfAbort) {
            val reason = if (isCancelled()) PdfGeometryRefusal.CANCELLED else PdfGeometryRefusal.MALFORMED
            PdfGeometryResult.Refused(reason, false)
        } catch (_: Exception) {
            PdfGeometryResult.Refused(PdfGeometryRefusal.IO_ERROR, false)
        } finally {
            runCatching { raf?.close() }
        }
    }

    // ------------------------------------------------------------------
    // Result identity
    // ------------------------------------------------------------------
}

sealed class PdfGeometryResult {
    data class Ok(val geometry: PdfPageGeometry) : PdfGeometryResult()
    data class Refused(val reason: PdfGeometryRefusal, val encrypted: Boolean) : PdfGeometryResult()
}

/** Path-free refusal identity. UI shows a localized message; diagnostics may log the code. */
enum class PdfGeometryRefusal {
    EMPTY,
    TOO_LARGE,
    NOT_REGULAR,
    IO_ERROR,
    CANCELLED,
    NOT_A_PDF,
    MALFORMED,
    NO_CATALOG,
    PAGE_TREE_UNREADABLE,
    TOO_MANY_PAGES,
    NODE_LIMIT,
    UNSUPPORTED_FILTER,
    DECOMPRESSION_LIMIT,
}

// ----------------------------------------------------------------------------
// Implementation (private; no Android types, JVM-testable)
// ----------------------------------------------------------------------------

private class PdfAbort : RuntimeException()

private sealed interface V
private class VNum(val value: Double) : V
private class VName(val name: String) : V
private class VRef(val obj: Int) : V
private class VArr(val items: List<V>) : V
private class VDict(val entries: Map<String, V>) : V
private class VBool(val value: Boolean) : V
private object VNull : V
private object VStr : V

private class ObjRec(
    val num: Int,
    val type: String?,
    val dict: Map<String, V>?,
)

private class Parser(
    private val buf: ByteBuffer,
    private val limits: PdfPageBoxReader.Limits,
    private val isCancelled: () -> Boolean,
) {
    private val limit = buf.limit()
    private var pos = 0
    private var nodesLeft = limits.maxRetainedNodes
    private var inflatedTotal = 0L

    private val objects = HashMap<Int, ObjRec>()
    private val directInts = HashMap<Int, Long>()
    private val trailers = ArrayList<Map<String, V>>()
    private var encrypted = false
    private var sawPdfHeader = false

    fun run(sourceSha256: String): PdfGeometryResult {
        scanHeader()
        if (!sawPdfHeader) return PdfGeometryResult.Refused(PdfGeometryRefusal.NOT_A_PDF, false)
        scanObjects()
        scanTrailers()
        val pages = buildPageTree()
        if (pages == null) {
            return PdfGeometryResult.Refused(PdfGeometryRefusal.PAGE_TREE_UNREADABLE, encrypted)
        }
        if (pages.isEmpty()) return PdfGeometryResult.Refused(PdfGeometryRefusal.PAGE_TREE_UNREADABLE, encrypted)
        return PdfGeometryResult.Ok(PdfPageGeometry(sourceSha256, pages, encrypted))
    }

    // ------------------------------------------------------------------
    // Header / scanning
    // ------------------------------------------------------------------

    private fun scanHeader() {
        val cap = minOf(limit, 1024)
        for (i in 0..(cap - 5)) {
            if (buf.get(i) == '%'.code.toByte() && buf.get(i + 1) == 'P'.code.toByte() &&
                buf.get(i + 2) == 'D'.code.toByte() && buf.get(i + 3) == 'F'.code.toByte() &&
                buf.get(i + 4) == '-'.code.toByte()
            ) {
                sawPdfHeader = true
                return
            }
        }
    }

    private fun scanObjects() {
        var pos = 0
        var parsed = 0
        while (pos < limit) {
            if (isCancelled()) throw PdfAbort()
            val kw = findKeyword(pos, "obj") ?: return
            val header = readObjectHeader(kw) ?: run { pos = kw + 3; continue }
            val (num, gen) = header
            this.pos = kw + 3
            val value = try {
                parseValue(0)
            } catch (_: PdfAbort) {
                throw PdfAbort()
            } catch (_: Exception) {
                null
            }
            if (value == null) {
                pos = kw + 3
                continue
            }
            parsed++
            if (parsed > limits.maxObjects) throw PdfAbort()
            var afterValue = this.pos
            // Is a stream attached?
            val streamPos = keywordAhead(afterValue, "stream")
            if (value is VDict && streamPos != null) {
                val end = skipStream(value.entries, streamPos + 6) ?: throw PdfAbort()
                recordObject(num, gen, value, streamBytes = streamData(value.entries, streamPos + 6, end))
                pos = end
            } else {
                recordObject(num, gen, value, streamBytes = null)
                pos = afterValue
            }
            if (pos <= kw) pos = kw + 3
            if (parsed % 128 == 0 && isCancelled()) throw PdfAbort()
        }
    }

    /**
     * Classic `trailer << ... >>` dictionaries (and their /Encrypt marker) are
     * not objects, so they are collected in a second bounded pass. A false
     * `trailer` token inside binary data simply fails to parse and is skipped.
     */
    private fun scanTrailers() {
        var p = 0
        while (p < limit) {
            if (isCancelled()) throw PdfAbort()
            val at = findKeyword(p, "trailer") ?: return
            this.pos = at + 7
            val value = try {
                parseValue(0)
            } catch (_: PdfAbort) {
                throw PdfAbort()
            } catch (_: Exception) {
                null
            }
            if (value is VDict) {
                trailers.add(value.entries)
                if (value.entries.containsKey("Encrypt")) encrypted = true
            }
            p = if (this.pos > at) this.pos else at + 7
        }
    }

    private fun recordObject(num: Int, gen: Int, value: V, streamBytes: ByteArray?) {
        if (num <= 0 || gen < 0) return
        if (value is VNum) {
            directInts[num] = value.value.toLong()
            return
        }
        if (value !is VDict) return
        val type = (value.entries["Type"] as? VName)?.name
        if (type == "XRef") {
            trailers.add(value.entries)
            if (value.entries.containsKey("Encrypt")) encrypted = true
        }
        if (type == "ObjStm" && streamBytes != null) {
            decodeObjectStream(value.entries, streamBytes)
            return
        }
        objects[num] = ObjRec(num, type, filterDict(value.entries))
    }

    private fun filterDict(entries: Map<String, V>): Map<String, V> {
        var result: MutableMap<String, V>? = null
        for ((k, v) in entries) {
            if (k in RETAINED_KEYS) {
                if (result == null) result = HashMap(minOf(entries.size, RETAINED_KEYS.size))
                result[k] = v
            }
        }
        return result ?: emptyMap()
    }

    private fun decodeObjectStream(dict: Map<String, V>, rawStream: ByteArray) {
        val n = (dict["N"] as? VNum)?.value?.toInt() ?: throw PdfAbort()
        val first = (dict["First"] as? VNum)?.value?.toInt() ?: throw PdfAbort()
        if (n <= 0 || n > limits.maxObjects || first < 0) throw PdfAbort()
        val decoded = inflateIfNeeded(dict, rawStream) ?: throw PdfAbort()
        if (first >= decoded.size) throw PdfAbort()
        val inner = ByteBuffer.wrap(decoded)
        val offsets = IntArray(n * 2)
        val innerParser = Parser(inner, limits, isCancelled)
        for (i in 0 until n * 2) {
            val v = innerParser.parseValue(0) as? VNum ?: throw PdfAbort()
            offsets[i] = v.value.toInt()
        }
        var lastPos = innerParser.pos
        for (i in 0 until n) {
            val objNum = offsets[i * 2]
            val rel = offsets[i * 2 + 1]
            if (objNum <= 0 || rel < 0) throw PdfAbort()
            val start = first + rel
            // After the (objNum, offset) header the cursor sits exactly at the
            // first contained object; equal is legal, only backward is not.
            if (start < lastPos || start >= decoded.size) throw PdfAbort()
            innerParser.pos = start
            val value = innerParser.parseValue(0) ?: throw PdfAbort()
            lastPos = innerParser.pos
            if (value is VDict) {
                val type = (value.entries["Type"] as? VName)?.name
                if (type == "XRef") {
                    trailers.add(value.entries)
                    if (value.entries.containsKey("Encrypt")) encrypted = true
                }
                if (type != "ObjStm") objects[objNum] = ObjRec(objNum, type, filterDict(value.entries))
            } else if (value is VNum) {
                directInts[objNum] = value.value.toLong()
            }
        }
    }

    private fun inflateIfNeeded(dict: Map<String, V>, raw: ByteArray): ByteArray? {
        val filter = dict["Filter"]
        val names = when (filter) {
            null -> emptyList()
            is VName -> listOf(filter.name)
            is VArr -> filter.items.mapNotNull { (it as? VName)?.name }
            else -> return null
        }
        if (names.isEmpty()) return raw
        if (names.size != 1 || names[0] != "FlateDecode") return null
        if (dict["DecodeParms"] != null || dict["DP"] != null) return null
        if (raw.isEmpty() || raw.size > limits.maxStreamBytes) throw PdfAbort()
        val maxOut = limits.maxStreamBytes
        val remainingBudget = limits.maxTotalInflateBytes - inflatedTotal
        if (remainingBudget <= 0) throw PdfAbort()
        val out = java.io.ByteArrayOutputStream(minOf(raw.size * 4, maxOut))
        try {
            InflaterInputStream(ByteArrayInputStream(raw), Inflater(), 64 * 1024).use { input ->
                val b = ByteArray(64 * 1024)
                while (true) {
                    val count = input.read(b)
                    if (count < 0) break
                    out.write(b, 0, count)
                    if (out.size() > maxOut || out.size().toLong() > remainingBudget) {
                        throw PdfAbort()
                    }
                    if (isCancelled()) throw PdfAbort()
                }
            }
        } catch (_: PdfAbort) {
            throw PdfAbort()
        } catch (_: Exception) {
            return null
        }
        inflatedTotal += out.size()
        return out.toByteArray()
    }

    /**
     * Finds the end of a stream body after the `stream` keyword at [dataStart].
     * Returns the position AFTER `endstream`, or null when the stream is not
     * terminable within the file (malformed).
     */
    private fun skipStream(dict: Map<String, V>, dataStartRaw: Int): Int? {
        var start = dataStartRaw
        // "stream" must be followed by CRLF or LF per spec; tolerate spaces.
        while (start < limit && isSpace(buf.get(start).toInt() and 0xff) &&
            buf.get(start) != '\r'.code.toByte() && buf.get(start) != '\n'.code.toByte()
        ) {
            start++
        }
        if (start < limit && buf.get(start) == '\r'.code.toByte()) start++
        if (start < limit && buf.get(start) == '\n'.code.toByte()) start++
        val declared = resolveLength(dict["Length"])
        if (declared != null && declared > 0 && declared < (limit - start)) {
            val end = start + declared.toInt()
            val after = skipWs(end)
            if (keywordAt(after, "endstream") != null) return after + 9
        }
        // Fallback: bounded scan for `endstream`.
        val needle = "endstream"
        var p = start
        while (p <= limit - needle.length) {
            if (isCancelled()) throw PdfAbort()
            if (buf.get(p) == 'e'.code.toByte() && keywordAt(p, needle) != null) return p + needle.length
            p++
        }
        return null
    }

    private fun streamData(dict: Map<String, V>, dataStartRaw: Int, endAfterEndstream: Int): ByteArray? {
        // Only object streams need the bytes; return a bounded slice.
        val type = (dict["Type"] as? VName)?.name ?: return null
        if (type != "ObjStm") return null
        var start = dataStartRaw
        while (start < limit && isSpace(buf.get(start).toInt() and 0xff) &&
            buf.get(start) != '\r'.code.toByte() && buf.get(start) != '\n'.code.toByte()
        ) {
            start++
        }
        if (start < limit && buf.get(start) == '\r'.code.toByte()) start++
        if (start < limit && buf.get(start) == '\n'.code.toByte()) start++
        var end = endAfterEndstream - 9
        // Trim the EOL that precedes `endstream`.
        while (end > start && (buf.get(end - 1) == '\n'.code.toByte() || buf.get(end - 1) == '\r'.code.toByte())) end--
        if (end <= start) return null
        val len = end - start
        if (len > limits.maxStreamBytes) throw PdfAbort()
        val out = ByteArray(len)
        for (i in 0 until len) out[i] = buf.get(start + i)
        return out
    }

    private fun resolveLength(v: V?): Long? = when (v) {
        null -> null
        is VNum -> v.value.toLong()
        is VRef -> directInts[v.obj]
        else -> null
    }

    // ------------------------------------------------------------------
    // Value parsing
    // ------------------------------------------------------------------

    fun parseValue(depth: Int): V? {
        if (depth > limits.maxDepth) throw PdfAbort()
        if (--nodesLeft < 0) throw PdfAbort()
        if (isCancelled()) throw PdfAbort()
        skipWsInPlace()
        if (pos >= limit) return null
        val c = buf.get(pos)
        return when {
            c == '<'.code.toByte() -> {
                if (pos + 1 < limit && buf.get(pos + 1) == '<'.code.toByte()) parseDict(depth) else parseHexString()
            }
            c == '['.code.toByte() -> parseArray(depth)
            c == '/'.code.toByte() -> parseName()
            c == '('.code.toByte() -> parseLiteralString()
            c == 't'.code.toByte() && keywordAt(pos, "true") != null -> { pos += 4; VBool(true) }
            c == 'f'.code.toByte() && keywordAt(pos, "false") != null -> { pos += 5; VBool(false) }
            c == 'n'.code.toByte() && keywordAt(pos, "null") != null -> { pos += 4; VNull }
            c == '+'.code.toByte() || c == '-'.code.toByte() || c == '.'.code.toByte() || c.isDigit() -> parseNumberOrRef()
            else -> null
        }
    }

    private fun parseDict(depth: Int): V {
        pos += 2
        val entries = HashMap<String, V>(8)
        while (true) {
            skipWsInPlace()
            if (pos >= limit) throw PdfAbort()
            if (buf.get(pos) == '>'.code.toByte() && pos + 1 < limit && buf.get(pos + 1) == '>'.code.toByte()) {
                pos += 2
                return VDict(entries)
            }
            if (buf.get(pos) != '/'.code.toByte()) {
                // Malformed dict: skip one token and stop failing the object.
                throw PdfAbort()
            }
            val name = parseName() as VName
            val value = parseValue(depth + 1) ?: throw PdfAbort()
            if (name.name in RETAINED_KEYS && entries.size < limits.maxDictEntries) entries[name.name] = value
        }
    }

    private fun parseArray(depth: Int): V {
        pos += 1
        val items = ArrayList<V>(minOf(8, limits.maxArrayItems))
        while (true) {
            skipWsInPlace()
            if (pos >= limit) throw PdfAbort()
            if (buf.get(pos) == ']'.code.toByte()) {
                pos += 1
                return VArr(items)
            }
            val v = parseValue(depth + 1) ?: throw PdfAbort()
            if (items.size < limits.maxArrayItems) items.add(v)
        }
    }

    private fun parseName(): V {
        pos += 1
        val sb = StringBuilder()
        while (pos < limit) {
            val b = buf.get(pos).toInt() and 0xff
            if (isDelimiter(b) || isSpace(b)) break
            if (b == '#'.code && pos + 2 < limit) {
                val hi = hexVal(buf.get(pos + 1))
                val lo = hexVal(buf.get(pos + 2))
                if (hi >= 0 && lo >= 0) {
                    sb.append(((hi shl 4) or lo).toChar())
                    pos += 3
                    continue
                }
            }
            sb.append(b.toChar())
            pos++
        }
        return VName(sb.toString())
    }

    private fun parseLiteralString(): V {
        pos += 1
        var depth = 1
        while (pos < limit) {
            val b = buf.get(pos)
            when {
                b == '\\'.code.toByte() -> pos += 2
                b == '('.code.toByte() -> { depth++; pos++ }
                b == ')'.code.toByte() -> {
                    depth--
                    pos++
                    if (depth == 0) return VStr
                }
                else -> pos++
            }
        }
        throw PdfAbort()
    }

    private fun parseHexString(): V {
        pos += 1
        while (pos < limit && buf.get(pos) != '>'.code.toByte()) pos++
        if (pos >= limit) throw PdfAbort()
        pos += 1
        return VStr
    }

    private fun parseNumberOrRef(): V {
        val first = readNumber() ?: throw PdfAbort()
        if (first.isInteger) {
            val save = pos
            skipWsInPlace()
            if (pos < limit && buf.get(pos).isDigit()) {
                val second = readNumber()
                if (second != null && second.isInteger) {
                    skipWsInPlace()
                    if (pos < limit && buf.get(pos) == 'R'.code.toByte()) {
                        pos++
                        return VRef(first.intValue)
                    }
                }
            }
            pos = save
        }
        return VNum(first.value)
    }

    private class ParsedNumber(val value: Double, val isInteger: Boolean, val intValue: Int)

    private fun readNumber(): ParsedNumber? {
        val start = pos
        if (pos < limit && (buf.get(pos) == '+'.code.toByte() || buf.get(pos) == '-'.code.toByte())) pos++
        var digits = 0
        var dot = false
        while (pos < limit) {
            val b = buf.get(pos)
            if (b.isDigit()) { digits++; pos++ }
            else if (b == '.'.code.toByte() && !dot) { dot = true; pos++ }
            else break
        }
        if (digits == 0) { pos = start; return null }
        val text = StringBuilder(pos - start)
        for (i in start until pos) text.append(buf.get(i).toInt().toChar())
        val value = text.toString().toDoubleOrNull() ?: return null
        return ParsedNumber(value, !dot, value.toInt())
    }

    // ------------------------------------------------------------------
    // Page tree
    // ------------------------------------------------------------------

    private class Inherited(
        val media: VArr?,
        val crop: VArr?,
        val rotation: Double?,
        val explicitRotation: Boolean,
    )

    private fun buildPageTree(): List<PdfPageBox>? {
        val rootRef = resolveCatalogRef() ?: return null
        val catalog = objects[rootRef] ?: return null
        val pagesRef = (catalog.dict?.get("Pages") as? VRef) ?: return null
        val out = ArrayList<PdfPageBox>()
        val onPath = HashSet<Int>()
        val ok = walk(pagesRef.obj, Inherited(null, null, null, false), 0, out, onPath)
        if (!ok) return null
        return out
    }

    private fun resolveCatalogRef(): Int? {
        for (i in trailers.indices.reversed()) {
            val root = trailers[i]["Root"] as? VRef
            if (root != null && objects.containsKey(root.obj)) return root.obj
        }
        var best = -1
        for ((num, rec) in objects) {
            if (rec.type == "Catalog" && num > best) best = num
        }
        return if (best > 0) best else null
    }

    private fun walk(
        ref: Int,
        inherited: Inherited,
        depth: Int,
        out: MutableList<PdfPageBox>,
        onPath: MutableSet<Int>,
    ): Boolean {
        if (depth > limits.maxDepth) throw PdfAbort()
        if (isCancelled()) throw PdfAbort()
        if (!onPath.add(ref)) return false
        try {
            val rec = objects[ref] ?: return false
            val dict = rec.dict ?: return false
            val type = rec.type
            val media = (dict["MediaBox"] as? VArr) ?: inherited.media
            val crop = (dict["CropBox"] as? VArr) ?: inherited.crop
            val rotateValue = (dict["Rotate"] as? VNum)?.value
            val rotation = rotateValue ?: inherited.rotation
            val explicit = rotateValue != null || inherited.explicitRotation
            if (type == "Page" || (type == null && media != null && dict["Kids"] == null)) {
                val box = buildBox(media, crop, rotation, explicit) ?: return false
                out.add(box)
                if (out.size > limits.maxPages) {
                    throw PdfAbort()
                }
                return true
            }
            val kids = dict["Kids"] as? VArr ?: return false
            if (kids.items.isEmpty()) return true
            for (kid in kids.items) {
                val kidRef = kid as? VRef ?: return false
                if (!walk(kidRef.obj, Inherited(media, crop, rotation, explicit), depth + 1, out, onPath)) {
                    return false
                }
            }
            return true
        } finally {
            onPath.remove(ref)
        }
    }

    private fun buildBox(media: VArr?, crop: VArr?, rotation: Double?, explicit: Boolean): PdfPageBox? {
        val mediaBox = media?.let(::numbersOrNull) ?: return null
        var x0 = minOf(mediaBox[0], mediaBox[2])
        var y0 = minOf(mediaBox[1], mediaBox[3])
        var x1 = maxOf(mediaBox[0], mediaBox[2])
        var y1 = maxOf(mediaBox[1], mediaBox[3])
        val cropBox = crop?.let(::numbersOrNull)
        if (cropBox != null) {
            val cx0 = minOf(cropBox[0], cropBox[2])
            val cy0 = minOf(cropBox[1], cropBox[3])
            val cx1 = maxOf(cropBox[0], cropBox[2])
            val cy1 = maxOf(cropBox[1], cropBox[3])
            val ix0 = maxOf(x0, cx0)
            val iy0 = maxOf(y0, cy0)
            val ix1 = minOf(x1, cx1)
            val iy1 = minOf(y1, cy1)
            // A degenerate intersection is not a usable page box; keep the media box.
            if (ix1 - ix0 >= 1.0 && iy1 - iy0 >= 1.0) {
                x0 = ix0; y0 = iy0; x1 = ix1; y1 = iy1
            }
        }
        val w = (x1 - x0).toFloat()
        val h = (y1 - y0).toFloat()
        if (!w.isFinite() || !h.isFinite() || w < PdfPageBox.MIN_POINTS || h < PdfPageBox.MIN_POINTS ||
            w > PdfPageBox.MAX_POINTS || h > PdfPageBox.MAX_POINTS
        ) {
            return null
        }
        val turns = PdfPageBox.normalizeRotation((rotation ?: 0.0).toFloat())
        return PdfPageBox(
            widthPt = w,
            heightPt = h,
            rotationQuarterTurns = turns,
            explicitRotation = explicit,
        )
    }

    private fun numbersOrNull(arr: VArr): DoubleArray? {
        if (arr.items.size != 4) return null
        val out = DoubleArray(4)
        for (i in 0..3) {
            val n = (arr.items[i] as? VNum)?.value ?: return null
            if (!n.isFinite()) return null
            out[i] = n
        }
        return out
    }

    // ------------------------------------------------------------------
    // Lexing helpers
    // ------------------------------------------------------------------

    private fun skipWsInPlace() {
        pos = skipWs(pos)
    }

    private fun skipWs(from: Int): Int {
        var p = from
        while (p < limit) {
            val b = buf.get(p).toInt() and 0xff
            if (isSpace(b)) { p++; continue }
            if (b == '%'.code) {
                while (p < limit && buf.get(p) != '\n'.code.toByte() && buf.get(p) != '\r'.code.toByte()) p++
                continue
            }
            break
        }
        return p
    }

    private fun keywordAt(at: Int, word: String): Int? {
        if (at < 0 || at + word.length > limit) return null
        for (i in word.indices) {
            if (buf.get(at + i) != word[i].code.toByte()) return null
        }
        val after = at + word.length
        if (after < limit && !isDelimiterOrSpace(buf.get(after).toInt() and 0xff)) return null
        return after
    }

    private fun keywordAhead(from: Int, word: String): Int? {
        val p = skipWs(from)
        val after = keywordAt(p, word) ?: return null
        return if (after >= 0) p else null
    }

    private fun findKeyword(from: Int, word: String): Int? {
        var p = from
        val n = word.length
        while (p <= limit - n) {
            if (buf.get(p) == word[0].code.toByte() && keywordAt(p, word) != null) {
                val prev = if (p == 0) ' '.code else buf.get(p - 1).toInt() and 0xff
                if (isSpace(prev) || prev == '>'.code || prev == ']'.code) return p
            }
            p++
            if ((p and 0xffff) == 0 && isCancelled()) throw PdfAbort()
        }
        return null
    }

    /** Reads `num gen obj`: returns (num, gen) or null when this was a false match. */
    private fun readObjectHeader(objKeywordAt: Int): Pair<Int, Int>? {
        var p = objKeywordAt - 1
        while (p >= 0 && isSpace(buf.get(p).toInt() and 0xff)) p--
        val genEnd = p
        while (p >= 0 && buf.get(p).isDigit()) p--
        if (genEnd == p) return null
        val gen = intFrom(p + 1, genEnd + 1) ?: return null
        while (p >= 0 && isSpace(buf.get(p).toInt() and 0xff)) p--
        val numEnd = p
        while (p >= 0 && buf.get(p).isDigit()) p--
        if (numEnd == p) return null
        val num = intFrom(p + 1, numEnd + 1) ?: return null
        return num to gen
    }

    private fun intFrom(start: Int, endExclusive: Int): Int? {
        if (endExclusive - start !in 1..10) return null
        var value = 0L
        for (i in start until endExclusive) {
            val d = buf.get(i).toInt() - '0'.code
            if (d !in 0..9) return null
            value = value * 10 + d
            if (value > Int.MAX_VALUE) return null
        }
        return value.toInt()
    }

    private fun hexVal(b: Byte): Int = when (val c = (b.toInt() and 0xff).toChar()) {
        in '0'..'9' -> c - '0'
        in 'a'..'f' -> c - 'a' + 10
        in 'A'..'F' -> c - 'A' + 10
        else -> -1
    }

    private fun Byte.isDigit(): Boolean = this >= '0'.code.toByte() && this <= '9'.code.toByte()

    companion object {
        private val RETAINED_KEYS = setOf(
            "Type", "Pages", "Kids", "Parent", "MediaBox", "CropBox", "Rotate",
            "Length", "N", "First", "Filter", "DecodeParms", "DP", "Root", "Encrypt", "Count",
        )

        private fun isSpace(b: Int): Boolean =
            b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32

        private fun isDelimiterOrSpace(b: Int): Boolean = isSpace(b) || isDelimiter(b)

        private fun isDelimiter(b: Int): Boolean =
            b == '('.code || b == ')'.code || b == '<'.code || b == '>'.code ||
                b == '['.code || b == ']'.code || b == '{'.code || b == '}'.code ||
                b == '/'.code || b == '%'.code
    }
}
