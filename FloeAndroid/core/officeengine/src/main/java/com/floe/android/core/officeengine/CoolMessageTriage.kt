package com.floe.android.core.officeengine

/**
 * Pure classifiers over the mobile fake-websocket message stream. The
 * prefixes and JSON field shapes are pinned by the staged 26.04 mobile dist
 * (dist/global.js + dist/bundle.js message handlers) and the pinned online
 * revision 2333344185931274f9c49d6c12a408cefcef6844 (wsd/ClientSession.cpp,
 * kit/ChildSession.cpp, common/SaveResult.hpp):
 *  - "progress:" carries the load progress JSON (id/text/value);
 *  - "status:" / "statusupdate:" / "partstatus:" carry document shape JSON
 *    (width/height in twip) — the document-dimensions witness;
 *  - "tile:" / "tilecombine:" / "delta:" are ACTUAL tile deliveries: encoded
 *    image payloads arriving from the kit (bundle.js decodes these into tile
 *    images). Delivery evidence — NOT yet painted-frame evidence;
 *  - "invalidatetiles:" is only a redraw REQUEST (diagnostic counter, never
 *    readiness proof — Main readiness correction 2026-10-26);
 *  - "error:" is a genuine failure notification; when it carries
 *    `cmd=`/`kind=` tokens the parse exposes them (save failures use
 *    cmd=save|storage kind=savefailed — see OfficeSaveProtocol);
 *  - "statechanged:" carries either a JSON object
 *    ({"commandName":...,"state"/"enabled":...}) or a `name=value` pair —
 *    both shapes are parsed (bundle.js _onStateChangedMsg handles both);
 *    `.uno:ModifiedStatus` here is the real dirty-state fact;
 *  - "unocommandresult:" / "commandresult: " carry UNO command completion
 *    JSON; for `.uno:Save` this is the producer's real save ack
 *    (success + result string; wsd additionally stamps isAutosave) — see
 *    OfficeSaveProtocol for the pinned outcome mapping;
 *  - "perm: " carries the session write permission ("edit"/"readonly") and
 *    "filemode:" the file-mode JSON — both are server-originated permission
 *    facts (wsd/ClientSession.cpp setReadOnly/sendFileMode);
 *  - "haspasswordtomodify:" marks a modify-password-protected document
 *    (not editable in this stage).
 *
 * READY additionally requires the host's painted-frame probe (a real
 * PixelCopy of the visible engine view), which the message stream alone can
 * never provide.
 */
object CoolMessageTriage {

    enum class Kind {
        PROGRESS,
        STATUS,
        TILE_DELIVERY,
        TILE_INVALIDATE,
        PART_SET,
        STATE_CHANGED,
        UNO_COMMAND_RESULT,
        PERM,
        FILEMODE,
        HAS_PASSWORD_TO_MODIFY,
        ERROR,
        OTHER,
    }

    /**
     * Returns the message kind plus the typed parse for the kinds that carry
     * decision-relevant facts. Never throws on malformed payloads: a field
     * that could not be parsed exactly stays null, so neither readiness nor
     * save success can ever be fabricated from a broken frame.
     */
    fun classify(message: ByteArray): TriageResult {
        if (message.isEmpty()) return TriageResult(Kind.OTHER)
        // Fast prefix scan over ASCII bytes without decoding big payloads.
        val prefix = message.prefixAscii(24)
        return when {
            prefix.startsWith("progress:") -> TriageResult(Kind.PROGRESS, progress = parseProgress(message))
            prefix.startsWith("statusupdate:") || prefix.startsWith("status:") ||
                prefix.startsWith("partstatus:") ->
                TriageResult(Kind.STATUS, shape = parseShape(message))
            prefix.startsWith("tile:") || prefix.startsWith("tilecombine:") ||
                prefix.startsWith("delta:") -> TriageResult(Kind.TILE_DELIVERY)
            prefix.startsWith("invalidatetiles:") -> TriageResult(Kind.TILE_INVALIDATE)
            prefix.startsWith("setpart:") -> TriageResult(Kind.PART_SET)
            prefix.startsWith("statechanged:") -> TriageResult(Kind.STATE_CHANGED, stateChange = parseStateChange(message))
            prefix.startsWith("unocommandresult:") || prefix.startsWith("commandresult:") ->
                TriageResult(Kind.UNO_COMMAND_RESULT, commandResult = parseCommandResult(message))
            prefix.startsWith("perm:") -> TriageResult(Kind.PERM, perm = parsePerm(message))
            prefix.startsWith("filemode:") -> TriageResult(Kind.FILEMODE, fileMode = parseFileMode(message))
            prefix.startsWith("haspasswordtomodify:") -> TriageResult(Kind.HAS_PASSWORD_TO_MODIFY)
            prefix.startsWith("error:") -> TriageResult(Kind.ERROR, error = parseError(message))
            else -> TriageResult(Kind.OTHER)
        }
    }

    data class TriageResult(
        val kind: Kind,
        val progress: ProgressInfo? = null,
        val shape: DocumentShape? = null,
        val stateChange: StateChange? = null,
        val commandResult: CommandResult? = null,
        val perm: String? = null,
        val fileMode: FileMode? = null,
        val error: ErrorInfo? = null,
    )

    data class ProgressInfo(val id: String?, val text: String?, val value: Int?)

    data class DocumentShape(val widthTwip: Int, val heightTwip: Int)

    /**
     * One `statechanged:` fact. [state] is the RAW state string exactly as
     * the producer sent it (JSON string/bool/number all normalize to their
     * text form; the `enabled` alias is accepted because bundle.js reads
     * either). Never interpreted beyond OfficeEditState.commandEnabled.
     */
    data class StateChange(val commandName: String, val state: String?)

    /** One `.uno:*` completion frame (the `.uno:Save` case is the save ack). */
    data class CommandResult(
        val commandName: String?,
        val success: Boolean?,
        val resultValue: String?,
        val isAutosave: Boolean,
    )

    /** Server `filemode:` facts (wsd/ClientSession.cpp sendFileMode). */
    data class FileMode(val readOnly: Boolean, val editComment: Boolean, val manageRedlines: Boolean)

    /** `error: cmd=<cmd> kind=<kind> ...` tokens when present (null otherwise). */
    data class ErrorInfo(val cmd: String?, val kind: String?)

    private fun ByteArray.prefixAscii(max: Int): String {
        val end = minOf(max, size)
        val sb = StringBuilder(end)
        for (i in 0 until end) {
            val b = this[i].toInt() and 0xff
            sb.append(if (b in 0x20..0x7e) b.toChar() else ' ')
        }
        return sb.toString()
    }

    private fun payloadText(message: ByteArray, prefixLength: Int): String {
        val text = String(message, Charsets.UTF_8)
        return if (text.length > prefixLength) text.substring(prefixLength).trim() else ""
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

    /** Handles BOTH pinned wire shapes: JSON object or `name=value`. */
    private fun parseStateChange(message: ByteArray): StateChange? {
        val payload = payloadText(message, "statechanged:".length)
        if (payload.isEmpty()) return null
        if (payload.startsWith("{")) {
            val name = jsonStringField(payload, "commandName") ?: return null
            val state = jsonRawField(payload, "state") ?: jsonRawField(payload, "enabled")
            return StateChange(name, state)
        }
        val eq = payload.indexOf('=')
        if (eq <= 0) return null
        val name = payload.substring(0, eq).trim()
        if (name.isEmpty() || name.length > 256) return null
        return StateChange(name, payload.substring(eq + 1).trim())
    }

    private fun parseCommandResult(message: ByteArray): CommandResult? {
        val text = String(message, Charsets.UTF_8)
        val brace = text.indexOf('{')
        if (brace < 0) return null
        val json = text.substring(brace)
        val name = jsonStringField(json, "commandName")
        val success = jsonBoolField(json, "success")
        // result:{ "type":"string", "value":"unmodified" } — scan the nested object.
        val resultValue = jsonNestedStringValue(json, "result", "value")
        val isAutosave = jsonBoolField(json, "isAutosave") == true
        if (name == null && success == null && resultValue == null) return null
        return CommandResult(name, success, resultValue, isAutosave)
    }

    private fun parsePerm(message: ByteArray): String? {
        val payload = payloadText(message, "perm:".length)
        // Only the two protocol values are meaningful; anything else stays null.
        return when (payload) {
            "edit", "readonly" -> payload
            else -> null
        }
    }

    private fun parseFileMode(message: ByteArray): FileMode? {
        val text = String(message, Charsets.UTF_8)
        val brace = text.indexOf('{')
        if (brace < 0) return null
        val json = text.substring(brace)
        val readOnly = jsonBoolField(json, "readOnly") ?: return null
        val editComment = jsonBoolField(json, "editComment") ?: false
        val manageRedlines = jsonBoolField(json, "manageRedlines") ?: false
        return FileMode(readOnly, editComment, manageRedlines)
    }

    private fun parseError(message: ByteArray): ErrorInfo? {
        val payload = payloadText(message, "error:".length)
        if (payload.isEmpty()) return null
        var cmd: String? = null
        var kind: String? = null
        for (token in payload.split(' ')) {
            when {
                token.startsWith("cmd=") -> cmd = token.substring(4).takeIf { it.isNotEmpty() && it.length <= 64 }
                token.startsWith("kind=") -> kind = token.substring(5).takeIf { it.isNotEmpty() && it.length <= 64 }
            }
        }
        return ErrorInfo(cmd, kind)
    }

    private fun jsonNumberField(json: String, key: String): Int? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*(-?\\d+)").find(json) ?: return null
        return match.groupValues[1].toIntOrNull()
    }

    private fun jsonStringField(json: String, key: String): String? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*\"([^\"\\\\]*)\"").find(json) ?: return null
        return match.groupValues[1]
    }

    private fun jsonBoolField(json: String, key: String): Boolean? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*(true|false|\"true\"|\"false\")").find(json)
            ?: return null
        return match.groupValues[1].trim('"') == "true"
    }

    /** Raw scalar (string/bool/number) as text; null when absent. */
    private fun jsonRawField(json: String, key: String): String? {
        val match = Regex("\"" + Regex.escape(key) + "\"\\s*:\\s*(\"[^\"\\\\]*\"|true|false|-?\\d+)").find(json)
            ?: return null
        return match.groupValues[1].trim('"')
    }

    /** `"outer":{ ... "inner":"value" ... }` — scans only the nested object. */
    private fun jsonNestedStringValue(json: String, outerKey: String, innerKey: String): String? {
        val outer = Regex("\"" + Regex.escape(outerKey) + "\"\\s*:\\s*\\{").find(json) ?: return null
        var depth = 0
        var end = -1
        for (i in (outer.range.last - 1)..json.lastIndex) {
            when (json[i]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) {
                        end = i
                        break
                    }
                }
            }
        }
        if (end < 0) return null
        val nested = json.substring(outer.range.last - 1, end + 1)
        return jsonStringField(nested, innerKey)
    }
}

/**
 * The JS -> native message gate (transport-level enforcement only; NOT a
 * claim about kernel macro policy).
 *
 * Returns the forwarding decision plus an optional honest notice for the
 * host UI. R1 (readOnly = true) keeps the preview refusals exactly as
 * shipped. R2 adds the EDITABLE mode: genuine editing traffic (input,
 * in-place `save`, undo/redo and other ordinary UNO commands, the page's own
 * `setviewreadonly` toggle) flows to the pinned producer, while every
 * egress/authority route stays refused in BOTH modes: downloads/exports
 * (module API owns staged export), print, file-copy, hyperlinks, URL
 * save-as, storage upload, rename, password entry, script execution and all
 * macro commands. The native save ack ("SAVE", uppercase — kit
 * postDirectMessage on Android) is consumed quietly in editable mode and is
 * never forwarded back into native; it is also never treated as save proof
 * (the page shares this entry point and could forge the string — see
 * OfficeSaveProtocol).
 *
 * Host-bridge parity (Alpha13 repair 2026-10-26): every message the pinned
 * upstream LOActivity consumes Java-side in beforeMessageFromWebView (BYE,
 * PRINT, SAVE, downloadas, exportfile, DIM_SCREEN, LIGHT_SCREEN,
 * MOBILEWIZARD, HYPERLINK, EDITMODE, REQUESTFILECOPY, hideProgressbar) is
 * intercepted here or in the session — none may reach the kit, which answers
 * unknown non-protocol tokens with a `kind=unknown` error frame. Everything
 * upstream FORWARDS (lowercase protocol traffic and the clipboard/dialog
 * bridge tokens) keeps the same forwarding behaviour here; nothing is
 * swallowed broadly and real native errors stay inspectable.
 */
object CoolMessageGate {

    enum class Decision { FORWARD, FORWARD_AFTER, BLOCK_ROUTE, BLOCK_MACRO, BLOCK_WITHOUT_NOTICE }

    data class Outcome(val decision: Decision, val noticeKey: String? = null)

    /** Command prefixes refused in every mode (macro/authority routes). */
    private val BLOCKED_UNO_COMMANDS = setOf(
        ".uno:RunMacro",
        ".uno:BasicIDEAppear",
        ".uno:MacroDialog",
        ".uno:OpenMacroDlg",
        ".uno:MacroOrganizer",
        ".uno:InsertGraphic",
        ".uno:InsertObject",
        ".uno:ChangePassword",
        ".uno:SetPassword",
    )

    /**
     * `.uno:EditDoc` is refused in preview. In editable mode the page's own
     * pinned edit entry (_proceedEditMode → _enterEditMode) may legitimately
     * issue it for documents whose EditDoc state is "false"; it is a real
     * producer command, not a macro route, so EDITABLE forwards it.
     */
    private val BLOCKED_UNO_COMMANDS_READ_ONLY = BLOCKED_UNO_COMMANDS + ".uno:EditDoc"

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

    /**
     * Known editable-mode wire commands (documentation + explicit intent;
     * the fall-through below forwards any non-denied command in EDITABLE,
     * matching how the pinned producer's own protocol surface works).
     */
    private val EDITABLE_EXTRA_COMMANDS = setOf(
        "save", // in-place working-copy save (real producer protocol)
        "dialog", "windowpaint", "contextmenu", "longrunningactiondetection",
        "textselectioncontent", "paste", "pastestyle",
        "formfieldevent", "celladdress", "cellcursor",
        "commandstatechanged", "updateinfo", "calcoutputsize", "editcell",
        "inputbarfocus", "textviewselection", "graphicviewselection",
        "cellselection", "tiledialog", "mobilewizard", "action", "slidelink",
        "searchdialog",
    )

    private val PREVIEW_UNO = setOf(
        ".uno:Copy", ".uno:SelectAll", ".uno:DeselectAll", ".uno:Zoom", ".uno:GoToCell",
        ".uno:GoToPage", ".uno:JumpToPage", ".uno:JumpToNextTable", ".uno:JumpToPrevTable",
    )

    /** R1-compatible entry point: preview gating. */
    fun decide(message: String, readOnly: Boolean): Outcome =
        decide(message, if (readOnly) Mode.READ_ONLY else Mode.EDITABLE)

    /** Mode the gate decides for; EDITABLE only ever comes from an explicit trusted host request. */
    enum class Mode { READ_ONLY, EDITABLE }

    fun decide(message: String, mode: Mode): Outcome {
        if (message.length > 65536) return Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
        val editable = mode == Mode.EDITABLE
        // Framing guard with pinned keyboard-protocol parity (G05-R2,
        // 2026-10-26): the mobile bundle terminates ONLY its keyboard frames
        // with a single trailing LF (TextInput.js `_sendKeyEvent` sends
        // `key …\n` / `windowkey …\n`), the mobile ProxySocket passes them
        // to postMobileMessage unchanged, and upstream forwards those frames
        // to the kit VERBATIM (LOActivity.postMobileMessage ->
        // beforeMessageFromWebView has no key case). Refusing every LF
        // dropped each real Ctrl+A/Enter/Ctrl+End command and surfaced the
        // misleading editModeBlocked preview notice during live editing.
        // ONE trailing LF is protocol content ONLY for these two commands;
        // embedded LF, any CR, NUL, double terminators, oversize frames, and
        // trailing LF on any other command stay refused. Preview denial
        // authority is unchanged: the native barrier/perm/filemode witnesses
        // still gate read-only truth; no guard is weakened here.
        val frameHead = message.substringBefore(' ')
        val frameBody =
            if ((frameHead == "key" || frameHead == "windowkey") && message.endsWith("\n")) {
                message.dropLast(1)
            } else {
                message
            }
        if (frameBody.any { it == '\n' || it == '\r' || it == '\u0000' }) {
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
            // The native save ack (kit postDirectMessage, Android): consume
            // quietly; NEVER forward it back into native and never treat it
            // as proof (the page shares this entry point).
            "SAVE" ->
                if (editable) Outcome(Decision.BLOCK_WITHOUT_NOTICE, null)
                else Outcome(Decision.BLOCK_ROUTE, "saveRouteUnavailable")
            // In-place save: real producer protocol, but only for an explicit
            // editable session; preview keeps the honest refusal.
            "save" ->
                if (editable) Outcome(Decision.FORWARD)
                else Outcome(Decision.BLOCK_ROUTE, "saveRouteUnavailable")
            // Egress/authority routes stay refused in BOTH modes: the module
            // API (staged export + host handoff) owns every byte that leaves
            // the working copy; the WebView has no download/print authority;
            // `insertfile` could point the kit at an arbitrary path (ingress
            // authority) and `versionrestore` belongs to WOPI hosts.
            "downloadas", "exportfile", "PRINT", "REQUESTFILECOPY", "saveas", "exportas",
            "savetostorage", "renamefile", "insertfile", "versionrestore",
            -> Outcome(Decision.BLOCK_ROUTE, "saveRouteUnavailable")
            "EDITMODE" ->
                if (editable || rest.trim() != "on") {
                    Outcome(Decision.BLOCK_WITHOUT_NOTICE, null) // tracked by the session
                } else {
                    Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
                }
            "HYPERLINK" -> Outcome(Decision.BLOCK_ROUTE, "linkBlocked")
            "MOBILEWIZARD" -> Outcome(Decision.BLOCK_WITHOUT_NOTICE, null) // tracked by the session
            "DIM_SCREEN", "LIGHT_SCREEN" -> Outcome(Decision.BLOCK_WITHOUT_NOTICE, null)
            // Android host-bridge UI notice, NOT a protocol command: the pinned
            // mobile bundle posts a bare `hideProgressbar` through
            // window.postMobileMessage when a document finishes loading
            // (bundle.js Map.js:365 docloaded handler, guarded by
            // ThisIsTheAndroidApp) and again on every MobileWizard window
            // open (bundle.js MobileWizardWindow.js:496). Upstream consumes it
            // Java-side and NEVER forwards it (beforeMessageFromWebView
            // `case "hideProgressbar"` -> dismiss progress -> return false,
            // release-source LOActivity.java:1567-1578). This session has no
            // JS-driven progress dialog — the host chrome is driven by the
            // native `progress:` frames — so it is consumed quietly in BOTH
            // modes (preview previously emitted a spurious editModeBlocked
            // notice on every load). Forwarding it is a real fault: the pinned
            // in-process ClientSession does not know the command and answers
            // `error: cmd=hideProgressbar kind=unknown` (ClientSession.cpp:1735
            // at the pinned online revision), which both the page (AlertDialog +
            // broken modal focus) and this module (fatal non-save ERROR branch)
            // would read as a document failure — the actual Alpha13 tablet
            // FAILED session of 2026-10-26.
            "hideProgressbar" -> Outcome(Decision.BLOCK_WITHOUT_NOTICE, null)
            "loadwithpassword" -> Outcome(Decision.FORWARD) // kit drives its own wizard
            "uno" -> {
                val unoCommand = rest.split(" ", limit = 2).first()
                val blocked = if (editable) BLOCKED_UNO_COMMANDS else BLOCKED_UNO_COMMANDS_READ_ONLY
                when {
                    unoCommand in blocked -> Outcome(Decision.BLOCK_MACRO, "macroBlocked")
                    !editable && unoCommand == ".uno:Save" -> Outcome(Decision.BLOCK_ROUTE, "saveRouteUnavailable")
                    !editable && unoCommand !in PREVIEW_UNO -> Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
                    else -> Outcome(Decision.FORWARD)
                }
            }
            // Only the service issues native-policy control messages in
            // preview. In an editable session the page's own pinned
            // Viewing/Editing toggle (setviewreadonly) is the real producer
            // command and must reach the kit — otherwise the page and the
            // kit view disagree (the stale-mismatch class of bug Main hit on
            // iOS). The browser can still never approve external updates or
            // change the permission MODE itself.
            "setviewreadonly" ->
                if (editable) Outcome(Decision.FORWARD) else Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
            "permissionmode" -> Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
            "allowlinkupdate", "editwithpassword", "executescript", "proxyreturn" ->
                Outcome(Decision.BLOCK_ROUTE, "linkBlocked")
            "clientlog", "clientdebug", "sallogoverride", "loggingleveloverride", "TRACEEVENT" ->
                Outcome(Decision.BLOCK_WITHOUT_NOTICE)
            "browsersetting" -> Outcome(Decision.FORWARD)
            "statusupdate" -> Outcome(Decision.FORWARD)
            else ->
                // Preview keeps the strict allowlist. An editable session
                // forwards everything not denied above: the pinned producer
                // answers unknown commands itself, and an allowlist could
                // never honestly enumerate the whole editing protocol.
                if (!editable && command !in PREVIEW_COMMANDS) {
                    Outcome(Decision.BLOCK_ROUTE, "editModeBlocked")
                } else {
                    Outcome(Decision.FORWARD)
                }
        }
    }

    /** afterMessageFromWebView equivalent: only copy/cut need follow-up. */
    fun isClipboardCopyCommand(message: String): Boolean {
        val parts = message.split(" ", limit = 3)
        return parts.size >= 2 && parts[0] == "uno" &&
            (parts[1] == ".uno:Copy" || parts[1] == ".uno:Cut")
    }

    /** Diagnostic classification only: known preview/editable wire command. */
    fun isKnownCommand(command: String): Boolean =
        command in PREVIEW_COMMANDS || command in EDITABLE_EXTRA_COMMANDS
}
