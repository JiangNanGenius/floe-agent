// SPDX-License-Identifier: MPL-2.0
package com.floe.android.core.officeengine

import java.io.File
import java.net.URI
import java.net.URLDecoder

/** Pinned protocol, not guessed UNO options. ChildSession.cpp handles
 * setviewreadonly by setting the actual kit view read-only and disabling
 * comment/redline mutations. The following reserved commandvalues reply is
 * an ordered barrier after that command, not a general view-permission getter.
 * Core's .uno:ReadOnly reports LOAD-readonly (and edit-password state); it
 * does not report generic kit-view readonly for ordinary documents.
 *
 * R2 editable sessions (kit/ChildSession.cpp `setviewreadonly` branch at the
 * pinned revision): `value=false` calls setViewReadOnly(viewId,false) plus
 * setAllowChangeComments/ManageRedlines(true) — the same real per-view
 * permission command the page's own Viewing/Editing toggle uses. The
 * `.uno:ReadOnly` barrier reply still only attests LOAD-readonly; an EDIT
 * mount therefore requires it to answer false AND the server-originated
 * `perm: edit` / `filemode:` permission frames (see OfficeEngineService)
 * before it may claim edit permission.
 */
internal object OfficeReadOnlyProtocol {
    const val SET_VIEW_READ_ONLY = "setviewreadonly value=true"
    const val SET_VIEW_EDITABLE = "setviewreadonly value=false"
    const val QUERY_BARRIER = "commandvalues command=.uno:ReadOnly"
    private val report = Regex(
        """\s*commandvalues:\s*\{\s*"commandName"\s*:\s*"\.uno:ReadOnly"\s*,\s*"success"\s*:\s*(true|false|"true"|"false")\s*\}\s*""",
    )

    /**
     * Guarded entry into the pinned page's own edit mode, in the exact order
     * the C15 first-failure causal record requires (page-mode79):
     *
     * 1. `app.idleHandler.notifyActive()` (Control.IdleHandler.ts:215-224) —
     *    the engine's OWN genuine activity path (the one a real tap on the
     *    idle overlay uses): refreshes the activity timestamp, stops the
     *    out-of-focus timer and, when the page was deactivated, re-activates
     *    it (`useractive` while the socket is connected, `map.loadDocument()`
     *    otherwise). Guarded: a missing hook is skipped, never an error.
     * 2. A bounded synchronous `doSend()` probe on the raw mobile socket
     *    (`window.socket`, global.js MobileSocket/ProxySocket). The pinned
     *    proxy parks its 30 s no-response watchdog inside `doSend`
     *    (global.js:1688-1717: `msgInflight >= 4` walks a throttle ladder to
     *    the cap, then closes with code 1006 once `lastDataTimestamp` is
     *    older than 30 s). Forcing the page to evaluate that state NOW makes
     *    a dying transport close BEFORE the edit ack — the drift is then a
     *    typed pre-dispatch refusal instead of an after-effect UNKNOWN. On a
     *    healthy transport the probe just issues ordinary downlink polls (at
     *    most four before the inflight cap absorbs the rest); the ladder it
     *    walks is reset by the next real data (global.js:1737). 24 calls is
     *    the exact worst case from the pinned floor to the cap
     *    (25·1.15^22 ≥ 500) plus the closing call.
     * 3. `app.socket.connected()` (Socket.ts:780-782, `readyState === 1`) —
     *    a dead or never-opened transport is a plain false result; the
     *    session refuses edit mode honestly instead of pretending.
     * 4. `app.socket.sendMessage('useractive')` — the real transport witness.
     *    The inactivity gate always passes `useractive` (Socket.ts:206-216)
     *    and forwards it exactly when the socket is open; on mobile the frame
     *    travels over the bridge (global.js:1896-1898 `MobileSocket.send` →
     *    `postMobileMessage`), so the host observes it as one real forwarded
     *    uplink frame BEFORE the EDITMODE ack below (same JS thread, ordered
     *    synchronous bridge calls). wsd/kit handle it as the standard
     *    keepalive (pinned wsd/ClientSession.cpp:1600).
     * 5. `_proceedEditMode()` — the exact function the engine's mobile edit
     *    affordance invokes (bundle.js: readonlyStartingFormats check,
     *    password-to-modify prompt, mobile-edit-button hide,
     *    `_enterEditMode("edit")` → real `setviewreadonly value=false` +
     *    EDITMODE notice). The guard makes a missing/renamed hook a plain
     *    false result. Main owns any decision to replace this with a
     *    host-native toggle.
     *
     * The script never fabricates the ack: readiness still requires the
     * page's own EDITMODE-on observation AND the witness frame (see
     * OfficeEditModePreparation).
     */
    const val PAGE_ENTER_EDIT_SCRIPT =
        "(function(){try{" +
            "var ih=window.app&&window.app.idleHandler;" +
            "if(ih&&typeof ih.notifyActive==='function'){ih.notifyActive();}" +
            "var ps=window.socket;" +
            "if(ps&&typeof ps.doSend==='function'){" +
            "for(var i=0;i<24&&ps.readyState===1;i++){ps.doSend();}}" +
            "var s=window.app&&window.app.socket;" +
            "if(!(s&&typeof s.connected==='function'&&s.connected())){return false;}" +
            "if(typeof s.sendMessage==='function'){s.sendMessage('useractive');}" +
            "var m=window.app&&window.app.map;" +
            "if(m&&typeof m._proceedEditMode==='function'){m._proceedEditMode();return true;}" +
            "return false;}catch(e){return false;}})()"

    /**
     * The HIDDEN-WINDOW variant of [PAGE_ENTER_EDIT_SCRIPT]
     * (docx-socket-repair122): the same ordered hooks, WITHOUT the
     * synchronous 24-call `doSend()` probe burst.
     *
     * Why the burst must not run while the page window is hidden: the burst
     * exists only to force the pinned proxy to evaluate its watchdog NOW
     * (page-mode79's pre-dispatch-refusal contract). On a hidden page a poll
     * cannot complete (its loads are deferred), so the burst cannot restore
     * anything; with the in-flight counter already at its cap the calls only
     * walk the throttle ladder, and the moment staleness passes 30 s the same
     * `doSend()` closes the socket with code 1006 — the exact C17 DOCX first
     * failure (`owned-app-logcat.txt` line 170, 17:04:00.141, fired ~22 s
     * after a successful selectAll while the window was hidden for the
     * approval). Nothing in the page can recover a closed socket, so the
     * hidden route must never force that evaluation.
     *
     * The hooks themselves are unchanged and remain the real witness chain:
     * the page's OWN raw socket must be open (`window.socket.readyState === 1`
     * — a 1006 close sets it to 3), the app-level `connected()` gate must also
     * pass, then `notifyActive()` (Control.IdleHandler; it forwards
     * `useractive` while connected and would only call `map.loadDocument()`
     * when the socket is NOT connected — both gates above run FIRST so a dead
     * or closing page can never be reloaded by this script), the real
     * `useractive` uplink witness and `_proceedEditMode()` (the engine's own
     * mobile edit affordance -> real `setviewreadonly value=false` + EDITMODE
     * notice). On mobile the page's uplink is the bridge itself
     * (global.js `MobileSocket.send` -> `postMobileMessage`, pinned extract
     * lines 1895-1897), NOT the poll queue, so every command and witness here
     * travels while the window is hidden; only the DOWNLINK is deferred, and
     * the hidden route never depends on it.
     */
    const val PAGE_ENTER_EDIT_SCRIPT_NO_PROBE =
        "(function(){try{" +
            "var ps=window.socket;" +
            "if(!ps||ps.readyState!==1){return false;}" +
            "var s=window.app&&window.app.socket;" +
            "if(!(s&&typeof s.connected==='function'&&s.connected())){return false;}" +
            "var ih=window.app&&window.app.idleHandler;" +
            "if(ih&&typeof ih.notifyActive==='function'){ih.notifyActive();}" +
            "if(typeof s.sendMessage==='function'){s.sendMessage('useractive');}" +
            "var m=window.app&&window.app.map;" +
            "if(m&&typeof m._proceedEditMode==='function'){m._proceedEditMode();return true;}" +
            "return false;}catch(e){return false;}})()"

    /** Guarded return to the pinned page's viewing mode (mirror of the above). */
    const val PAGE_ENTER_VIEW_SCRIPT =
        "(function(){try{var m=window.app&&window.app.map;" +
            "if(m&&typeof m._enterReadOnlyMode==='function'){m._enterReadOnlyMode('readonly');return true;}" +
            "return false;}catch(e){return false;}})()"

    /**
     * The pinned protocol's ONE real, document-independent downlink
     * heartbeat request (page-transport85): wsd answers a client `ping`
     * itself with `pong rendercount=<n>` (wsd/ClientSession.cpp:1006-1009
     * at revision 2333344185931274f9c49d6c12a408cefcef6844). Verified
     * producer facts this relies on:
     *
     * - It is answered by WSD, never forwarded to the kit, and only after
     *   the document is loaded (`getDocURL()` non-empty; before that it is
     *   an `error: cmd=ping kind=nodocloaded` — the pump starts at READY,
     *   so the loaded branch is the only one it can hit).
     * - The `pong rendercount=` reply is neither a `status:`/`statusupdate:`
     *   nor a `commandvalues:` frame, so it cannot settle a precision
     *   correlation, the `.uno:ReadOnly` barrier or the save protocol —
     *   [CoolMessageTriage] classifies it OTHER and the relay passes it
     *   through to the page unchanged.
     * - The pinned page tolerates it: browser/src/app/Socket.ts consumes
     *   `pong ` only under `_debug.pingOn` (off in production) and otherwise
     *   falls through to the unknown-message debug log, which the host
     *   already ignores.
     * - It is real downlink data: the poll response carrying it is
     *   non-empty, and ONLY a non-empty 200 resets the page's
     *   `lastDataTimestamp` and throttle ladder (global.js:1731-1742) —
     *   the exact state the 30 s no-response watchdog reads
     *   (global.js:1696-1711). An empty poll cannot keep the transport
     *   alive; this frame can.
     * - The uplink write is message-atomic under the producer's global
     *   FakeSocket mutex (net/FakeSocket.cpp `fakeSocketWrite`), so a
     *   main-thread heartbeat can never interleave with a control-lane
     *   command frame.
     *
     * Side effect (verified, accepted): wsd counts `ping` as a user
     * interaction token (common/Protocol.hpp `tokenIndicatesUserInteraction`
     * — it excludes only tile/status/state/userinactive), refreshing the
     * session's own last-activity bookkeeping. That is keepalive semantics,
     * not authority: it never marks the document modified
     * (`tokenIndicatesDocumentModification` excludes it), never touches the
     * host-side admission facts, and this native channel hosts exactly one
     * session per mount.
     */
    const val TRANSPORT_PING = "ping"

    /**
     * READ-ONLY page transport health read for the bounded pre-admission
     * wake drain ([OfficeTransportDrain]). Reads the page's OWN pinned
     * counters — `readyState` (global.js:1552), `msgInflight` (1555) and
     * `lastDataTimestamp` age against the page's `performance.now()`
     * (1564/1739) — and returns `"<readyState>|<msgInflight>|<ageMs>"`,
     * or `nosocket`/`err`. Contains no `doSend`, no `sendMessage`, no
     * mutation of any page or transport state; it can never itself walk the
     * throttle ladder or close the socket. A missing `lastDataTimestamp` or
     * clock anomaly reports age `-1` (treated as NOT fresh: honest).
     */
    const val PAGE_TRANSPORT_HEALTH_SCRIPT =
        "(function(){try{var ps=window.socket;if(!ps)return 'nosocket';" +
            "var rs=ps.readyState|0;var infl=ps.msgInflight|0;var age=-1;" +
            "if(typeof ps.lastDataTimestamp==='number'&&typeof performance!=='undefined'&&typeof performance.now==='function'){" +
            "age=(performance.now()-ps.lastDataTimestamp)|0;}" +
            "return rs+'|'+infl+'|'+age;}catch(e){return 'err';}})()"

    /**
     * ONE guarded `doSend()` poll probe with an evaluateJavascript result
     * callback, so the host observes EXECUTION (not just issuance) — the
     * signal that separates a frozen renderer (callback never fires; the
     * injection stays the single pending poll) from an executed probe whose
     * `doSend()` early-returned at the pinned `msgInflight >= 4` gate.
     * Heartbeat, wake-drain AND ordinary [OfficeSendTrigger] traffic all use
     * this execution-identified form: without it, an older pre-freeze XHR
     * could be mistaken for the current injection and unlock the poll gate.
     * docx-socket-repair122: since every host injection must also be unable to
     * reach the pinned watchdog branch, the form the host actually injects is
     * [PAGE_SAFE_POLL_PROBE_SCRIPT] (same execution semantics, plus the
     * page-side `msgInflight >= 4` refusal documented there); this raw shape
     * stays as the documented baseline.
     */
    const val PAGE_POLL_PROBE_SCRIPT =
        "(function(){try{if(window.socket&&typeof window.socket.doSend==='function'){" +
            "window.socket.doSend();return true;}return false;}catch(e){return false;}})()"

    /**
     * The injection-safety-aware variant of [PAGE_POLL_PROBE_SCRIPT]
     * (docx-socket-repair122). EVERY host poll injection uses this form, so the
     * PAGE ITSELF refuses to evaluate `doSend()` while its in-flight counter is
     * pinned at the pinned cap of 4 (global.js 1696) — the only state in which
     * a `doSend()` can reach the fatal throttle/watchdog branch. The guard is
     * evaluated atomically in the page, so there is no host-side TOCTOU between
     * a health read and the injection.
     *
     * Why this is never a lost opportunity: with `msgInflight >= 4` the pinned
     * `doSend()` early-returns BEFORE creating its XHR, so such an injection
     * could never deliver a byte — it could only walk the throttle ladder, and
     * at >30 s staleness the same call closes the socket with code 1006. The
     * expression `false` it returns is not a failure signal to the host; the
     * injection still executed (the pump's execution callback is
     * value-independent) and its bounded settle releases the single-pending-poll
     * gate exactly as before.
     */
    const val PAGE_SAFE_POLL_PROBE_SCRIPT =
        "(function(){try{var ps=window.socket;" +
            "if(!ps||typeof ps.doSend!=='function')return false;" +
            "if((ps.msgInflight|0)>=4)return false;" +
            "ps.doSend();return true;}catch(e){return false;}})()"

    /** One parsed [PAGE_TRANSPORT_HEALTH_SCRIPT] answer (page truth). */
    data class OfficeTransportHealth(
        val readyState: Int,
        val msgInflight: Int,
        val stalenessMs: Long,
    )

    /**
     * Parses the raw evaluateJavascript answer of
     * [PAGE_TRANSPORT_HEALTH_SCRIPT]. Null for `nosocket`, `err`, a missing
     * callback value or any malformed answer — an unreadable page is never
     * promoted to a health fact ([OfficeTransportDrain] keeps retrying
     * within its bound and then lets the real handshake decide).
     */
    fun parseTransportHealth(raw: String?): OfficeTransportHealth? {
        val text = raw?.trim()?.trim('"') ?: return null
        val parts = text.split('|')
        if (parts.size != 3) return null
        val readyState = parts[0].toIntOrNull() ?: return null
        val msgInflight = parts[1].toIntOrNull() ?: return null
        val staleness = parts[2].toIntOrNull() ?: return null
        return OfficeTransportHealth(readyState, msgInflight, staleness.toLong())
    }

    /**
     * True for the pinned wsd's own `pong rendercount=<n>` heartbeat answer
     * (docx-socket-repair122). This frame is produced by wsd itself
     * (ClientSession `ping` handler), never by the kit, and the host observes
     * it on `rawCallFakeWebsocketOnMessage` BEFORE it is queued for the page —
     * so one arrival is a real NATIVE-side liveness witness that needs no
     * page polling and no page consumption. It proves the in-process wsd /
     * FakeSocket / native session processed a host uplink and emitted a real
     * downlink frame while the page window was hidden, which the ungated
     * EDITMODE bridge post alone cannot prove. The frame is then relayed to
     * the page unchanged (the pinned page tolerates an unsolicited `pong`).
     */
    fun isTransportPong(message: ByteArray): Boolean {
        if (message.size < 4 || message.size > 64) return false
        return message[0] == 'p'.code.toByte() && message[1] == 'o'.code.toByte() &&
            message[2] == 'n'.code.toByte() && message[3] == 'g'.code.toByte()
    }

    fun barrierReport(message: ByteArray): Boolean? {
        if (message.size > 4096) return null
        val match = report.matchEntire(message.toString(Charsets.UTF_8)) ?: return null
        return match.groupValues[1].trim('"') == "true"
    }

    fun command(message: String): String = message.substringBefore(' ')

    fun isReservedQuery(message: String): Boolean = message == QUERY_BARRIER

    /** The native session may load its one exact snapshot only. No host,
     * query, fragment or guessed workspace path can become file authority. */
    fun matchesSnapshotLoad(message: String, expected: File): Boolean = runCatching {
        val tokens = message.split(' ', limit = 3)
        if (tokens.size < 2 || tokens[0] != "load" || !tokens[1].startsWith("url=")) return false
        val uri = URI(URLDecoder.decode(tokens[1].removePrefix("url="), "UTF-8"))
        uri.scheme == "file" && uri.authority.isNullOrEmpty() && uri.query == null && uri.fragment == null &&
            File(uri.path).canonicalFile == expected.canonicalFile
    }.getOrDefault(false)

    /** Loading/render queries may run before the native policy barrier;
     * user interactions (and any in-place `save`) wait for that barrier to
     * avoid an editable window before the permission command was applied. */
    fun isInteraction(message: String): Boolean = command(message) in setOf(
        "uno", "key", "mouse", "windowkey", "windowmouse", "windowgesture",
        "selecttext", "selectgraphic", "windowselecttext", "resetselection",
        "save",
    )
}
