package com.floe.android.core.officeengine

/**
 * Pure classifiers over the mobile fake-websocket message stream. The
 * prefixes and JSON field shapes are pinned by the staged 26.04 mobile dist
 * (dist/global.js + dist/bundle.js message handlers):
 *  - "progress:" carries the load progress JSON (id/text/value);
 *  - "status:" / "statusupdate:" / "partstatus:" carry document shape JSON
 *    (width/height in twip) — the document-dimensions witness;
 *  - "tile:" / "tilecombine:" / "delta:" are ACTUAL tile deliveries: encoded
 *    image payloads arriving from the kit (bundle.js decodes these into tile
 *    images). Delivery evidence — NOT yet painted-frame evidence;
 *  - "invalidatetiles:" is only a redraw REQUEST (diagnostic counter, never
 *    readiness proof — Main readiness correction 2026-10-26);
 *  - "error:" is a genuine load/format failure notification;
 *  - "statechanged:" / "setpart:" are document state facts.
 *
 * READY additionally requires the host's painted-frame probe (a real
 * PixelCopy of the visible engine view), which the message stream alone can
 * never provide.
 */
object CoolMessageTriage {

    enum class Kind { PROGRESS, STATUS, TILE_DELIVERY, TILE_INVALIDATE, PART_SET, STATE_CHANGED, ERROR, OTHER }

    /**
     * Returns the message kind plus, for STATUS, the parsed document shape.
     * Never throws on malformed payloads (status parse failure reports the
     * kind without witnesses, so readiness can never be fabricated).
     */
    fun classify(message: ByteArray): TriageResult {
        if (message.isEmpty()) return TriageResult(Kind.OTHER, null, null)
        // Fast prefix scan over ASCII bytes without decoding big payloads.
        val prefix = message.prefixAscii(24)
        return when {
            prefix.startsWith("progress:") -> TriageResult(Kind.PROGRESS, parseProgress(message), null)
            prefix.startsWith("statusupdate:") || prefix.startsWith("status:") ||
                prefix.startsWith("partstatus:") ->
                TriageResult(Kind.STATUS, null, parseShape(message))
            prefix.startsWith("tile:") || prefix.startsWith("tilecombine:") ||
                prefix.startsWith("delta:") -> TriageResult(Kind.TILE_DELIVERY, null, null)
            prefix.startsWith("invalidatetiles:") -> TriageResult(Kind.TILE_INVALIDATE, null, null)
            prefix.startsWith("setpart:") -> TriageResult(Kind.PART_SET, null, null)
            prefix.startsWith("statechanged:") -> TriageResult(Kind.STATE_CHANGED, null, null)
            prefix.startsWith("error:") -> TriageResult(Kind.ERROR, null, null)
            else -> TriageResult(Kind.OTHER, null, null)
        }
    }

    data class TriageResult(
        val kind: Kind,
        val progress: ProgressInfo?,
        val shape: DocumentShape?,
    )

    data class ProgressInfo(val id: String?, val text: String?, val value: Int?)

    data class DocumentShape(val widthTwip: Int, val heightTwip: Int)

    private fun ByteArray.prefixAscii(max: Int): String {
        val end = minOf(max, size)
        val sb = StringBuilder(end)
        for (i in 0 until end) {
            val b = this[i].toInt() and 0xff
            sb.append(if (b in 0x20..0x7e) b.toChar() else ' ')
        }
        return sb.toString()
    }

    /**
     * Minimal scanner for `"key":number` / `"key":"text"` fields inside the
     * JSON tail of an already-classified message. The framework JSON parser
     * is only available on device; the classification itself must also be
     * JVM-testable, so this scanner is deliberately tolerant and only ever
     * returns witnesses it found exactly (no defaults).
     */
    private fun parseProgress(message: ByteArray): ProgressInfo? {
        val text = String(message, Charsets.UTF_8)
        val brace = text.indexOf('{')
        if (brace < 0) return null
        val json = text.substring(brace)
        val id = jsonStringField(json, "id")
        val value = jsonNumberField(json, "value")
        val messageText = jsonStringField(json, "text")
        if (id == null && value == null && messageText == null) return null
        return ProgressInfo(id, messageText, value)
    }

    private fun parseShape(message: ByteArray): DocumentShape? {
        val text = String(message, Charsets.UTF_8)
        val brace = text.indexOf('{')
        if (brace < 0) return null
        val json = text.substring(brace)
        val width = jsonNumberField(json, "width") ?: return null
        val height = jsonNumberField(json, "height") ?: return null
        return DocumentShape(width, height)
    }

    private fun jsonNumberField(json: String, key: String): Int? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*(-?\\d+)").find(json) ?: return null
        return match.groupValues[1].toIntOrNull()
    }

    private fun jsonStringField(json: String, key: String): String? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*\"([^\"\\\\]*)\"").find(json) ?: return null
        return match.groupValues[1]
    }
}

/**
 * The JS -> native message gate for the R1 viewer (transport-level
 * enforcement only; NOT a claim about kernel macro policy).
 *
 * Returns the forwarding decision plus an optional honest notice for the
 * host UI. Upstream handled SAVE/downloadas/exportfile/PRINT/EDITMODE/
 * REQUESTFILECOPY/HYPERLINK with SAF pickers, external apps or copy flows
 * that R1 does not authorise; they are refused here with a visible outcome
 * instead of silently accepted. Macro invocation commands are blocked at the
 * message boundary (the pinned dist also defaults window.enableMacrosExecution
 * to false for the mobile initializers — evidence recorded in the module
 * PROVENANCE.md — but a renamed/enriched container's kernel behaviour stays a
 * device-verification item, not claimed).
 */
object CoolMessageGate {

    enum class Decision { FORWARD, FORWARD_AFTER, BLOCK_ROUTE, BLOCK_MACRO, BLOCK_WITHOUT_NOTICE }

    data class Outcome(val decision: Decision, val noticeKey: String? = null)

    /** Command prefixes refused for R1 preview (edit/save/export/print). */
    private val BLOCKED_UNO_COMMANDS = setOf(
        ".uno:RunMacro",
        ".uno:BasicIDEAppear",
        ".uno:MacroDialog",
        ".uno:OpenMacroDlg",
        ".uno:MacroOrganizer",
        ".uno:EditDoc",
        ".uno:InsertGraphic",
        ".uno:InsertObject",
        ".uno:ChangePassword",
        ".uno:SetPassword",
    )

    private val PREVIEW_COMMANDS = setOf(
        "coolclient", "loolclient", "load", "loadwithpassword", "status", "statusupdate",
        "useractive", "userinactive", "clientzoom", "clientvisiblearea", "clientarea",
        "clientchangeduimode", "setclientpart", "selectclientpart", "setpage", "partpagerectangles",
        "tile", "tilecombine", "tileprocessed", "canceltiles", "renderfont", "rendersearchresult",
        "commandvalues", "getchildid", "getpresentationinfo", "getslidesections", "gettextselection",
        "selecttext", "windowselecttext", "selectgraphic", "resetselection", "key", "mouse",
        "windowkey", "windowmouse", "windowgesture", "resizewindow", "paintwindow", "renderwindow",
        "a11ystate", "geta11yfocusedparagraph", "geta11ycaretposition", "ping", "versionbar",
    )
    private val PREVIEW_UNO = setOf(
        ".uno:Copy", ".uno:SelectAll", ".uno:DeselectAll", ".uno:Zoom", ".uno:GoToCell",
        ".uno:GoToPage", ".uno:JumpToPage", ".uno:JumpToNextTable", ".uno:JumpToPrevTable",
    )

    fun decide(message: String, readOnly: Boolean): Outcome {
        if (message.length > 65536 || message.any { it == '\n' || it == '\r' || it == '\u0000' }) {
            return Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
        }
        val parts = message.split(" ", limit = 2)
        val command = parts.first()
        val rest = parts.getOrNull(1).orEmpty()
        return when (command) {
            // Termination: intercepted by the session (never blindly forwarded;
            // settle happens once on the close worker).
            "BYE" -> Outcome(Decision.BLOCK_WITHOUT_NOTICE, "bye")
            "HULLO" -> Outcome(Decision.FORWARD)
            OfficeRenderWitness.COMMAND -> Outcome(Decision.BLOCK_WITHOUT_NOTICE)
            // Save/export/print/edit-mode/copy flows are outside R1 authority.
            "save", "SAVE", "downloadas", "exportfile", "PRINT", "REQUESTFILECOPY" ->
                Outcome(Decision.BLOCK_ROUTE, "saveRouteUnavailable")
            "EDITMODE" ->
                if (readOnly && rest.trim() == "on") {
                    Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
                } else {
                    Outcome(Decision.BLOCK_WITHOUT_NOTICE, null)
                }
            "HYPERLINK" -> Outcome(Decision.BLOCK_ROUTE, "linkBlocked")
            "MOBILEWIZARD" -> Outcome(Decision.BLOCK_WITHOUT_NOTICE, null) // tracked by the session
            "DIM_SCREEN", "LIGHT_SCREEN" -> Outcome(Decision.BLOCK_WITHOUT_NOTICE, null)
            "loadwithpassword" -> Outcome(Decision.FORWARD) // kit drives its own wizard
            "uno" -> {
                val unoCommand = rest.split(" ", limit = 2).first()
                when {
                    unoCommand in BLOCKED_UNO_COMMANDS -> Outcome(Decision.BLOCK_MACRO, "macroBlocked")
                    readOnly && unoCommand == ".uno:Save" -> Outcome(Decision.BLOCK_ROUTE, "saveRouteUnavailable")
                    readOnly && unoCommand !in PREVIEW_UNO -> Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
                    else -> Outcome(Decision.FORWARD)
                }
            }
            // Only the service issues native-policy control messages. The
            // browser cannot clear view readonly or approve external updates.
            "setviewreadonly", "permissionmode" -> Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
            "allowlinkupdate", "editwithpassword", "executescript", "proxyreturn" ->
                Outcome(Decision.BLOCK_ROUTE, "linkBlocked")
            "clientlog", "clientdebug", "sallogoverride", "loggingleveloverride", "TRACEEVENT" ->
                Outcome(Decision.BLOCK_WITHOUT_NOTICE)
            "browsersetting" -> Outcome(Decision.FORWARD)
            "statusupdate" -> Outcome(Decision.FORWARD)
            else -> if (readOnly && command !in PREVIEW_COMMANDS) Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
                    else Outcome(Decision.FORWARD)
        }
    }

    /** afterMessageFromWebView equivalent: only copy/cut need follow-up. */
    fun isClipboardCopyCommand(message: String): Boolean {
        val parts = message.split(" ", limit = 3)
        return parts.size >= 2 && parts[0] == "uno" &&
            (parts[1] == ".uno:Copy" || parts[1] == ".uno:Cut")
    }
}
