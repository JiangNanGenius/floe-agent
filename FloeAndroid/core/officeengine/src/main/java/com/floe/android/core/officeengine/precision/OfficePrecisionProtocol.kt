// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine.precision

/**
 * Pure pinned-protocol facts for the fenced Office precision surface (G05-R2
 * P-A). Every wire string and answer shape here is anchored in the pinned
 * producer source at revision 2333344185931274f9c49d6c12a408cefcef6844
 * (Collabora Office Mobile 26.04.4.2 / code 937), NOT guessed:
 *
 * Requests (client→kit, dispatched by the SERVICE through the proven
 * postMobileMessageNative wire — never built from model/tool output):
 *  - `status` → answered with `status: <json>` (kit/ChildSession.cpp
 *    getStatus → LOKitHelper::documentStatus, kit/KitHelper.hpp:139-210:
 *    type/partscount/selectedpart/width/height/viewid [+readonly,
 *    lastcolumn/lastrow, partdimensions, pagerectangles, mode]).
 *  - `gettextselection mimetype=text/plain;charset=utf-8` → answered with
 *    `textselectioncontent: <raw text>` (single mime; ChildSession.cpp:1850-
 *    1915), `textselectioncontent:\n<json map>` (multi-mime only),
 *    `complexselection:` (selection ≥ 1 MiB) or
 *    `error: cmd=gettextselection kind=syntax`.
 *  - `commandvalues command=.uno:CellCursor` → answered with
 *    `commandvalues: {"commandName":".uno:CellCursor","commandValues":"EMPTY"
 *    |"<x> <y> <w> <h> <col> <row>"}` (ChildSession.cpp getCommandValues
 *    :1365-1421; the pinned frontend consumes commandValues through the same
 *    number-scan as the pushed `cellcursor:` frame — dist
 *    CanvasTileLayer.js _onCommandValuesMsg/_onCellCursorMsg).
 *  - `commandvalues command=.uno:ReadOnly` → the ordered barrier reply
 *    (already proven by OfficeReadOnlyProtocol; the kit processes document
 *    messages serially, so a barrier reply fences every earlier frame).
 *  - `getpresentationinfo` → answered with `presentationinfo: <json>`
 *    (ChildSession.cpp:1044, :4565).
 *  - `setclientpart part=<id>` → the core SET_PART callback answers with
 *    `setpart: part=<id actually shown>` (ChildSession.cpp setClientPart
 *    :4371-4394 + SET_PART case :5075-5085; a gone page selects nothing and
 *    the echo names the real part).
 *  - `uno .uno:SelectAll` → NO unocommandresult (not in the pinned notify
 *    list, ChildSession.cpp unoCommand :3481-3494); its real effect is the
 *    TEXT_SELECTION callback frame `textselection: <payload>` (:4998-5000).
 *  - `uno .uno:GoToCell {"ToPoint":{"type":"string","value":"<A1>"}}` → the
 *    producer's real cell navigation (dist CalcNotifications.js:52 sends
 *    exactly this shape); NO unocommandresult (not in the notify list), so
 *    completion is the semantic readback via the `.uno:CellCursor` pull
 *    (plus corroborating `celladdress:`/`cellcursor:`/`cellformula:` pushes,
 *    ChildSession.cpp :5019-5024, :5230-5233).
 *  - `paste mimetype=text/plain;charset=utf-8\n<base64 payload>` → answered
 *    with `pasteresult: success` or `pasteresult: fallback`
 *    (ChildSession.cpp paste :2097-2160; the MOBILEAPP branch base64-decodes
 *    the payload, and the pinned mobile frontend sends exactly this framing —
 *    dist Clipboard.js _pasteTypedBlob :359-377). This is the real producer
 *    text-insertion path: paste replaces the current selection or inserts at
 *    the cursor, in all three document families.
 *
 * Native→client frames observed BEFORE the WebView relay (they carry NO
 * operation id, so correlation is single-in-flight + lease + barrier based,
 * see OfficePrecisionLedger):
 *  - `status:`/`statusupdate:`/`partstatus:` JSON (see above),
 *  - `commandvalues: {...}` (commandName + commandValues),
 *  - `textselectioncontent: ...` / `complexselection:`,
 *  - `pasteresult: success|fallback`,
 *  - `setpart: part=<id>`,
 *  - `textselection: <payload>` ("EMPTY" clears; TEXT_SELECTION callback),
 *  - `graphicselection: <payload>` (GRAPHIC_SELECTION callback),
 *  - `cellcursor: EMPTY|<x> <y> <w> <h> <col> <row>`, `celladdress: <addr>`,
 *    `cellformula: <text>` (pushed Calc context; content NEVER logged),
 *  - `presentationinfo: <json>`,
 *  - `statechanged: <name>=<value>` (e.g. `.uno:ModifiedStatus=true`;
 *    corroboration only — NEVER mutation completion by itself),
 *  - `unocommandresult: {...}` — ONLY for the notify-list commands
 *    (Save/Undo/Redo/Cut/Copy/CopySlide/OpenHyperlink/Paste/PasteSpecial/
 *    CalculateSheet/CalculateHard/vnd.sun.star.script:*),
 *  - `error: cmd=<cmd> kind=<kind>` (per-command refusal/failure).
 *
 * This object is pure and JVM-testable: no Android imports, tolerant
 * scanners that only ever return witnesses they found exactly (same
 * discipline as CoolMessageTriage), and no org.json dependency.
 */
object OfficePrecisionProtocol {

    // ------------------------------------------------------------------
    // Bounds (bounded requests/answers; oversize is REFUSED, never
    // silently truncated — a 64 MiB ledger is deliberately NOT duplicated
    // here just because MobileSocket has that cap).
    // ------------------------------------------------------------------

    /** Max UTF-8 bytes for one text parameter (paste content). */
    const val MAX_TEXT_BYTES = 64 * 1024

    /**
     * Max answer payload carried back to the authorized owner, in UTF-8
     * BYTES. Sized from the real binder budget, not picked to look round
     * (Main marshalling review 2026-10-27): Parcel.writeString serializes
     * UTF-16, whose worst-case expansion from UTF-8 is exactly 2x (ASCII:
     * 1 byte → one UTF-16 code unit; every multibyte UTF-8 sequence maps to
     * ≤ its own byte count in UTF-16, non-BMP 4 bytes → 4 bytes). So
     * 256 KiB of UTF-8 content can never exceed 512 KiB of UTF-16 payload,
     * which with [REPLY_META_RESERVE_BYTES] stays under
     * [MAX_REPLY_PARCEL_BYTES] — comfortably inside the ~1 MiB binder
     * transaction budget. Oversize answers are REFUSED with their real byte
     * count (typed ANSWER_TOO_LARGE), never truncated with .take() and never
     * risking a TransactionTooLargeException that would lose an already
     * consumed mutation result. The pinned producer itself switches to
     * `complexselection:` at 1 MiB, so anything above this cap was already
     * headed for honest unavailability.
     */
    const val MAX_ANSWER_BYTES = 256 * 1024

    /** Conservative whole-result reply budget (binder ~1 MiB, 25% headroom). */
    const val MAX_REPLY_PARCEL_BYTES = 768 * 1024

    /**
     * Reserve for every non-content reply field (opId/token echo, state and
     * failure names, detail ≤ 240 chars, attestation lineage, ≤32 step
     * tokens, target scalars, ints/longs, parcel alignment). The actual
     * metadata observed on these replies is a few KiB; 64 KiB is deliberate
     * headroom, and the budget check below fails closed if a future field
     * ever exceeds it.
     */
    const val REPLY_META_RESERVE_BYTES = 64 * 1024

    /** Max total request payload accepted over the binder (oversize refused). */
    const val MAX_REQUEST_BYTES = 256 * 1024

    /** Bounded scalar sizes for parsed frame headers. */
    private const val MAX_SCALAR_CHARS = 512

    /**
     * Conservative serialized size of one string field as Parcel.writeString
     * will write it: 4-byte length prefix + 2 bytes per UTF-16 code unit +
     * 2-byte NUL, padded up to 4-byte parcel alignment.
     */
    fun utf16ParcelBytes(text: String?): Long {
        if (text == null) return 4L
        val raw = 4L + 2L * text.length + 2L
        return (raw + 3L) and -4L
    }

    /**
     * Conservative estimate of the FULL serialized binder reply for one
     * result (all string fields at their real UTF-16 cost + the metadata
     * reserve). Used BEFORE consuming/advertising a stored result, so an
     * oversize answer becomes a typed honest refusal instead of a lost
     * TransactionTooLarge reply.
     */
    fun estimateResultParcelBytes(result: OfficePrecisionResult): Long {
        var bytes = REPLY_META_RESERVE_BYTES.toLong()
        bytes += utf16ParcelBytes(result.opId)
        bytes += utf16ParcelBytes(result.sessionToken)
        bytes += utf16ParcelBytes(result.state.name)
        bytes += utf16ParcelBytes(result.action.name)
        bytes += utf16ParcelBytes(result.failure?.name)
        bytes += utf16ParcelBytes(result.detail)
        bytes += utf16ParcelBytes(result.attestation)
        bytes += 16L // longs + presence/kind ints
        when (val answer = result.answer) {
            null -> bytes += 4L
            is OfficePrecisionAnswer.TargetCaptured -> {
                val t = answer.target
                bytes += utf16ParcelBytes(t.handleId) + utf16ParcelBytes(t.sourceId) +
                    utf16ParcelBytes(t.sourceRevision) + utf16ParcelBytes(t.sourceLogicalPath) +
                    utf16ParcelBytes(t.workspaceId) + utf16ParcelBytes(t.ownerTaskId) +
                    utf16ParcelBytes(t.workingCopySha256) + utf16ParcelBytes(t.docType) +
                    utf16ParcelBytes(t.selectedPart) + 60L
            }
            is OfficePrecisionAnswer.DocumentContext ->
                bytes += utf16ParcelBytes(answer.docType) +
                    utf16ParcelBytes(answer.selectedPart) + 32L
            is OfficePrecisionAnswer.TextSelection ->
                bytes += utf16ParcelBytes(answer.text) + 12L
            is OfficePrecisionAnswer.CellCursor -> bytes += 32L
            is OfficePrecisionAnswer.PresentationInfo -> bytes += 12L
            is OfficePrecisionAnswer.SlideSelected -> bytes += utf16ParcelBytes(answer.shownPart)
            is OfficePrecisionAnswer.TextSelected -> bytes += 8L
            is OfficePrecisionAnswer.MutationApplied -> {
                bytes += 20L + utf16ParcelBytes(answer.workingCopySha256) +
                    utf16ParcelBytes(answer.contentReadback.name) +
                    utf16ParcelBytes(answer.consumedTargetHandle)
                answer.steps.take(32).forEach { bytes += utf16ParcelBytes(it) }
            }
        }
        return bytes
    }

    /** True when the full serialized reply would stay inside the budget. */
    fun fitsReplyBudget(result: OfficePrecisionResult): Boolean =
        estimateResultParcelBytes(result) <= MAX_REPLY_PARCEL_BYTES

    /**
     * True when one content string's own UTF-16 parcel cost stays inside the
     * reply budget after the metadata reserve. Enforced at ledger settle
     * time BEFORE an answer is stored/advertised, so an oversize selection
     * becomes a typed ANSWER_TOO_LARGE refusal (query) or an UNAVAILABLE
     * readback downgrade (completed mutation keeps its small receipt).
     */
    fun contentFitsReplyBudget(text: String): Boolean =
        utf16ParcelBytes(text) <= (MAX_REPLY_PARCEL_BYTES - REPLY_META_RESERVE_BYTES).toLong()

    /** Wire commands (exact spellings the pinned producer parses). */
    const val CMD_STATUS = "status"
    const val CMD_GET_TEXT_SELECTION = "gettextselection mimetype=text/plain;charset=utf-8"
    const val CMD_CELL_CURSOR_VALUES = "commandvalues command=.uno:CellCursor"
    const val CMD_BARRIER = "commandvalues command=.uno:ReadOnly"
    const val CMD_PRESENTATION_INFO = "getpresentationinfo"
    const val CMD_SELECT_ALL = "uno .uno:SelectAll"

    /** The kit UNO command name carried by the ordered barrier reply. */
    const val BARRIER_COMMAND_NAME = ".uno:ReadOnly"

    /** The commandvalues pull used for Calc cursor readback. */
    const val CELL_CURSOR_COMMAND_NAME = ".uno:CellCursor"

    /** MIME used for the pinned mobile paste framing. */
    const val PASTE_MIME = "text/plain;charset=utf-8"

    // ------------------------------------------------------------------
    // Request builders (internal translation layer; the PUBLIC surface is
    // the typed OfficePrecisionAction — raw wire/UNO/key strings are never
    // accepted from callers, model output or document content).
    // ------------------------------------------------------------------

    fun setClientPart(partId: String): String? =
        if (isValidPartId(partId)) "setclientpart part=$partId" else null

    fun goToCell(cellAddress: String): String? =
        if (isValidCellAddress(cellAddress)) {
            "uno .uno:GoToCell {\"ToPoint\":{\"type\":\"string\",\"value\":\"" +
                escapeJsonString(canonicalCellAddress(cellAddress)) + "\"}}"
        } else {
            null
        }

    /**
     * Builds the pinned MOBILEAPP paste frame: header line + base64 payload
     * (ChildSession::paste base64-decodes on mobile; Clipboard.js sends
     * exactly this). Base64 keeps arbitrary text (newlines, quotes, unicode)
     * off the wire framing entirely — an injected newline or protocol token
     * inside the text can never split or forge a command.
     */
    fun pasteText(text: String): String? {
        if (!isValidPasteText(text)) return null
        val bytes = text.toByteArray(Charsets.UTF_8)
        return "paste mimetype=$PASTE_MIME\n" + base64Encode(bytes)
    }

    // ------------------------------------------------------------------
    // Parameter validation (fail-closed; refusal reasons are path-free).
    // ------------------------------------------------------------------

    private val PART_ID_REGEX = Regex("^[0-9]{1,9}$")

    /** A1 cell reference with optional `$` anchors (no sheet qualifier). */
    private val CELL_ADDRESS_REGEX = Regex("^\\$?[A-Za-z]{1,3}\\$?[1-9][0-9]{0,6}$")

    fun isValidPartId(partId: String?): Boolean =
        partId != null && PART_ID_REGEX.matches(partId)

    fun isValidCellAddress(address: String?): Boolean {
        if (address == null || !CELL_ADDRESS_REGEX.matches(address)) return false
        if (cellAddressToRow(address) == null) return false
        // Calc's real column bound (XFD = 16384). Checked HERE with the same
        // fold cellAddressToColumn uses, without re-entering it (no
        // recursion): an in-range row must not make XFE1..ZZZ... look valid.
        var col = 0
        for (ch in address.replace("$", "").takeWhile { it.isLetter() }.uppercase()) {
            col = col * 26 + (ch - 'A' + 1)
            if (col > 16384) return false
        }
        return true
    }

    /** Uppercase, `$`-stripped canonical form used in the GoToCell payload. */
    fun canonicalCellAddress(address: String): String =
        address.replace("$", "").uppercase()

    fun isValidPasteText(text: String?): Boolean {
        if (text == null) return false
        if (text.contains('\u0000')) return false
        val bytes = text.toByteArray(Charsets.UTF_8)
        return bytes.isNotEmpty() && bytes.size <= MAX_TEXT_BYTES
    }

    /** 0-based column index of an A1 address (null when out of range). */
    fun cellAddressToColumn(address: String): Int? {
        if (!isValidCellAddress(address)) return null
        val letters = address.replace("$", "").takeWhile { it.isLetter() }
        var col = 0
        for (ch in letters.uppercase()) {
            col = col * 26 + (ch - 'A' + 1)
            if (col > 16384) return null // Calc's real column bound (XFD).
        }
        return col - 1
    }

    /** 0-based row index of an A1 address (null when out of range). */
    fun cellAddressToRow(address: String): Int? {
        val digits = address.replace("$", "").takeLastWhile { it.isDigit() }
        val row = digits.toLongOrNull() ?: return null
        if (row < 1L || row > 1048576L) return null // Calc's real row bound.
        return (row - 1).toInt()
    }

    // ------------------------------------------------------------------
    // Answer-frame payload parsers (pure, tolerant, fail-closed).
    // ------------------------------------------------------------------

    /**
     * Parses the pinned JSON status payload (`status: {json}`):
     * type/partscount/selectedpart/width/height/viewid. Missing or
     * unparseable fields stay null — never defaulted.
     */
    data class DocumentStatusInfo(
        val docType: String?,
        val partsCount: Int?,
        val selectedPart: String?,
        val widthTwip: Int?,
        val heightTwip: Int?,
        val viewId: Int?,
        val readOnly: Boolean?,
    )

    fun parseDocumentStatus(payload: String): DocumentStatusInfo? {
        val brace = payload.indexOf('{')
        if (brace < 0) return null
        val json = payload.substring(brace)
        val width = jsonNumberField(json, "width")
        val height = jsonNumberField(json, "height")
        val type = jsonStringField(json, "type")
        val parts = jsonNumberField(json, "partscount")
        val selected = jsonStringField(json, "selectedpart")
        val viewId = jsonNumberField(json, "viewid")
        val readOnly = jsonBoolField(json, "readonly")
        if (type == null && parts == null && selected == null && width == null) return null
        return DocumentStatusInfo(type, parts, selected, width, height, viewId, readOnly)
    }

    /**
     * Parses a `.uno:CellCursor` commandValues payload: `EMPTY`, or six
     * integers in the pinned order (x, y, width, height — twips — then the
     * 0-based column and row), exactly the number-scan the pinned frontend
     * performs. Returns null for EMPTY/unparseable (honest absence).
     */
    data class CellCursorInfo(
        val xTwip: Int,
        val yTwip: Int,
        val widthTwip: Int,
        val heightTwip: Int,
        val column: Int,
        val row: Int,
    )

    fun parseCellCursorPayload(payload: String?): CellCursorInfo? {
        if (payload == null) return null
        if (payload.contains("EMPTY")) return null
        val numbers = Regex("-?\\d+").findAll(payload).mapNotNull { it.value.toIntOrNull() }.toList()
        if (numbers.size < 6) return null
        return CellCursorInfo(numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5])
    }

    /** True when the payload is the producer's explicit EMPTY cursor answer. */
    fun isCellCursorEmpty(payload: String?): Boolean = payload?.contains("EMPTY") == true

    /** `pasteresult:` verdict token ("success"/"fallback"; null otherwise). */
    fun parsePasteVerdict(payload: String): String? {
        val token = payload.trim().substringBefore(' ').take(32)
        return when (token) {
            "success", "fallback" -> token
            else -> null
        }
    }

    // ------------------------------------------------------------------
    // textselectioncontent framing: `textselectioncontent: <raw>` (single
    // mime) or `textselectioncontent:\n<json map>` (multi mime). The raw
    // form may itself contain newlines, so the split is on the FIRST
    // delimiter character only and the content is never trimmed.
    // ------------------------------------------------------------------

    const val TEXT_SELECTION_CONTENT_PREFIX = "textselectioncontent:"

    data class TextSelectionContent(
        /** True when the answer used the multi-mime `\n` + JSON map form. */
        val multiFormatJson: Boolean,
        val text: String,
        val byteCount: Int,
        /** True when the frame exceeded [MAX_ANSWER_BYTES] (content dropped). */
        val oversize: Boolean,
    )

    /**
     * Extracts the selection content from a raw `textselectioncontent:`
     * frame. [messageUtf8] is the full frame text. Oversize answers are
     * REFUSED with their real byte count, never truncated.
     */
    fun parseTextSelectionContent(messageUtf8: String): TextSelectionContent? {
        if (!messageUtf8.startsWith(TEXT_SELECTION_CONTENT_PREFIX)) return null
        val rest = messageUtf8.substring(TEXT_SELECTION_CONTENT_PREFIX.length)
        val multiFormatJson = rest.startsWith("\n")
        val content = if (multiFormatJson) rest.substring(1) else rest.removePrefix(" ")
        val bytes = content.toByteArray(Charsets.UTF_8).size
        if (bytes > MAX_ANSWER_BYTES) {
            return TextSelectionContent(multiFormatJson, "", bytes, oversize = true)
        }
        return TextSelectionContent(multiFormatJson, content, bytes, oversize = false)
    }

    // ------------------------------------------------------------------
    // commandvalues header parse (bounded scalars only; payloads are
    // extracted separately and only while an operation is armed).
    // ------------------------------------------------------------------

    data class CommandValuesHeader(val commandName: String?, val commandValues: String?)

    fun parseCommandValuesHeader(json: String): CommandValuesHeader? {
        val name = jsonStringField(json, "commandName")?.take(MAX_SCALAR_CHARS)
        val values = jsonStringField(json, "commandValues")?.take(MAX_SCALAR_CHARS)
        if (name == null && values == null) return null
        return CommandValuesHeader(name, values)
    }

    // ------------------------------------------------------------------
    // Minimal JSON scanners (same tolerant discipline as CoolMessageTriage;
    // JVM-testable, no org.json, no defaults invented).
    // ------------------------------------------------------------------

    internal fun jsonNumberField(json: String, key: String): Int? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*(-?\\d+)").find(json) ?: return null
        return match.groupValues[1].toIntOrNull()
    }

    internal fun jsonStringField(json: String, key: String): String? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*\"([^\"\\\\]*)\"").find(json)
            ?: return null
        return match.groupValues[1]
    }

    internal fun jsonBoolField(json: String, key: String): Boolean? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*(true|false|\"true\"|\"false\")")
            .find(json) ?: return null
        return match.groupValues[1].trim('"') == "true"
    }

    private fun escapeJsonString(value: String): String = buildString(value.length + 8) {
        for (ch in value) {
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (ch.code < 0x20) append("\\u%04x".format(ch.code)) else append(ch)
            }
        }
    }

    // ------------------------------------------------------------------
    // Pure RFC 4648 base64 encoder (standard alphabet, with padding —
    // byte-identical to the window.btoa output the pinned mobile frontend
    // sends, which ChildSession::paste decodes with macaron::Base64).
    // android.util.Base64 is deliberately NOT used so this stays JVM-testable.
    // ------------------------------------------------------------------

    private const val B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    fun base64Encode(input: ByteArray): String {
        val out = StringBuilder((input.size + 2) / 3 * 4)
        var index = 0
        while (index < input.size) {
            val b0 = input[index].toInt() and 0xff
            val b1 = if (index + 1 < input.size) input[index + 1].toInt() and 0xff else -1
            val b2 = if (index + 2 < input.size) input[index + 2].toInt() and 0xff else -1
            out.append(B64_ALPHABET[b0 shr 2])
            if (b1 < 0) {
                out.append(B64_ALPHABET[(b0 and 0x03) shl 4]).append("==")
                break
            }
            out.append(B64_ALPHABET[((b0 and 0x03) shl 4) or (b1 shr 4)])
            if (b2 < 0) {
                out.append(B64_ALPHABET[(b1 and 0x0f) shl 2]).append('=')
                break
            }
            out.append(B64_ALPHABET[((b1 and 0x0f) shl 2) or (b2 shr 6)]).append(B64_ALPHABET[b2 and 0x3f])
            index += 3
        }
        return out.toString()
    }
}
