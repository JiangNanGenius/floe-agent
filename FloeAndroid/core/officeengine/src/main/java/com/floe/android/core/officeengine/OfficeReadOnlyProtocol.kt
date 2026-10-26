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
     * Guarded entry into the pinned page's own edit mode. `_proceedEditMode`
     * is the exact function the engine's mobile edit affordance invokes
     * (bundle.js: readonlyStartingFormats check, password-to-modify prompt,
     * mobile-edit-button hide, `_enterEditMode("edit")` → real
     * `setviewreadonly value=false` + EDITMODE notice). The guard makes a
     * missing/renamed hook a plain false result — the session then refuses
     * edit mode honestly instead of pretending the page is editable.
     * Main owns any decision to replace this with a host-native toggle.
     */
    const val PAGE_ENTER_EDIT_SCRIPT =
        "(function(){try{var m=window.app&&window.app.map;" +
            "if(m&&typeof m._proceedEditMode==='function'){m._proceedEditMode();return true;}" +
            "return false;}catch(e){return false;}})()"

    /** Guarded return to the pinned page's viewing mode (mirror of the above). */
    const val PAGE_ENTER_VIEW_SCRIPT =
        "(function(){try{var m=window.app&&window.app.map;" +
            "if(m&&typeof m._enterReadOnlyMode==='function'){m._enterReadOnlyMode('readonly');return true;}" +
            "return false;}catch(e){return false;}})()"

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
