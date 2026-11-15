// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

import com.floe.android.runtimeipc.RuntimeWire
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * One native `listPage` exchange. Production binds the authentic
 * [LinuxAuthorityClient]; JVM regressions supply deterministic fixtures.
 */
internal fun interface RuntimeCatalogPageSource {
    fun page(projectID: String?, cursor: String?, limit: Int): JSONObject
}

/**
 * Bounded READ-ONLY collector for the native environment catalog.
 *
 * The measured Full1.0.12/code120 failure was a real native refusal
 * (`authority_replyTooLarge`): the runtime fetched the legacy global
 * `environment.list` reply and only then filtered the requested project in
 * Kotlin, so one large registry overflowed the frozen 65536-byte native wire
 * ceiling before the scoped rows were ever visible.
 *
 * This reader never asks for the global overflow: it walks the ADDITIVE native
 * `listPage` operation (which filters the trusted project on the native side
 * BEFORE encoding) and reconstructs ONLY complete pages into the ordinary
 * `{baseRevision, environments, projectID, workspaceOwnerID}` result the
 * existing App parsers already consume.
 *
 * Strictness (every deviation is a typed `RuntimeAuthorityRefusal`, never a
 * partial success):
 *  * page scope / project / workspace-owner echoes must match the request;
 *  * `baseRevision` and `total` must be stable across pages;
 *  * ids must be unique across pages (no duplicates) and the aggregate must
 *    reach `total` on the terminal page (no silent loss);
 *  * every continuation must advance and must not repeat;
 *  * every returned row must belong to the requested scope (a scoped page may
 *    only contain the owner's project row and sessions chained to it);
 *  * the reconstructed result must still fit the bounded runtime reply
 *    envelope — otherwise the read fails explicitly instead of dropping rows.
 *
 * The codes it raises (`invalidWire`, `replyTooLarge`, `catalogChanged`,
 * `cancelled`) are exactly the closed version-1 authority vocabulary, so the
 * existing [RuntimeAuthorityRefusal] diagnostic seam keeps carrying a bounded
 * code only — never prose, paths or row content. Nothing here acquires,
 * launches, releases, migrates or writes: it is a metadata read over the
 * ORIGINAL registry.
 */
internal class RuntimeEnvironmentCatalogReader(
    private val source: RuntimeCatalogPageSource,
    private val pageLimit: Int = DEFAULT_PAGE_LIMIT,
    private val maximumPages: Int = DEFAULT_MAXIMUM_PAGES,
    private val maximumRows: Int = DEFAULT_MAXIMUM_ROWS,
    private val maximumResultBytes: Int = RuntimeWire.MAX_JSON_BYTES - ENVELOPE_RESERVE_BYTES,
    private val cancelled: () -> Boolean = { false },
) {
    init {
        require(pageLimit in 1..MAXIMUM_PAGE_LIMIT) { "catalog page limit out of range" }
        require(maximumPages >= 1) { "catalog page budget out of range" }
        require(maximumRows >= 1) { "catalog row budget out of range" }
        require(maximumResultBytes > 0 && maximumResultBytes <= RuntimeWire.MAX_JSON_BYTES) {
            "catalog result budget out of range"
        }
    }

    /**
     * Reads the complete catalog. [projectID] must already be the canonical
     * uppercase UUID the caller validated; null = the global enumeration.
     */
    fun read(projectID: String?): JSONObject {
        val rows = JSONArray()
        val rowIDs = HashSet<String>()
        var cursor: String? = null
        var baseRevision = ""
        var echoProjectID: String? = null
        var echoOwnerID: String? = null
        var total: Int? = null
        var pages = 0
        val expectedScope = if (projectID == null) "all" else "project"

        while (true) {
            if (cancelled()) throw RuntimeAuthorityRefusal("cancelled")
            if (pages >= maximumPages) throw RuntimeAuthorityRefusal("invalidWire")
            val page = guardPage { source.page(projectID, cursor, pageLimit) }
            pages++

            if (page.optString("scope") != expectedScope) refuse()
            val pageBase = requiredString(page, "baseRevision")
            if (pageBase.isEmpty() || pageBase.length > MAXIMUM_BASE_REVISION_CHARS) refuse()
            baseRevision = when (val previous = baseRevision) {
                "" -> pageBase
                pageBase -> previous
                else -> refuse()
            }

            val pageProject = stringOrNull(page, "projectID")
            val pageOwner = stringOrNull(page, "workspaceOwnerID")
            if (projectID == null) {
                if (pageProject != null || pageOwner != null) refuse()
            } else {
                if (pageProject != projectID) refuse()
                if (pageOwner == null || !HEX64.matches(pageOwner)) refuse()
                echoProjectID = when (val previous = echoProjectID) {
                    null -> pageProject
                    pageProject -> previous
                    else -> refuse()
                }
                echoOwnerID = when (val previous = echoOwnerID) {
                    null -> pageOwner
                    pageOwner -> previous
                    else -> refuse()
                }
            }

            val pageTotal = requiredInt(page, "total")
            if (pageTotal < 0 || pageTotal > maximumRows) refuse()
            total = when (val previous = total) {
                null -> pageTotal
                pageTotal -> previous
                else -> refuse()
            }

            val pageRows = page.optJSONArray("environments") ?: refuse()
            if (pageRows.length() > pageLimit) refuse()
            if (rows.length() + pageRows.length() > maximumRows) refuse()
            for (index in 0 until pageRows.length()) {
                // Every element must be a metadata OBJECT in both scopes; an
                // unscoped read keeps the legacy tolerance for its kind set.
                val row = pageRows.optJSONObject(index) ?: refuse()
                val unscopedID = stringOrNull(row, "id")
                if (unscopedID != null && !rowIDs.add(unscopedID)) refuse()
                if (projectID != null) {
                    val id = requiredString(row, "id")
                    if (!IDENTIFIER.matches(id)) refuse()
                    when (requiredString(row, "kind")) {
                        "project" -> if (requiredString(row, "ownerID") != pageOwner) refuse()
                        "session" -> {
                            if (!IDENTIFIER.matches(requiredString(row, "parentID"))) refuse()
                        }
                        else -> refuse()
                    }
                }
                rows.put(row)
            }

            val next = stringOrNull(page, "nextCursor")
            if (next == null) {
                // Terminal page: the aggregate must equal the advertised
                // complete inventory, or this is a silent truncation.
                if (rows.length() != pageTotal) refuse()
                break
            }
            if (next.isEmpty() || next.length > MAXIMUM_CURSOR_CHARS ||
                next.any { it.code < 33 || it.code > 126 }
            ) {
                refuse()
            }
            // No-progress / repeated page: a continuation must advance the
            // reader and there must still be unread rows.
            if (next == cursor || pageRows.length() == 0 || rows.length() >= pageTotal) refuse()
            cursor = next
        }

        if (projectID != null) {
            // Final chain check over the COMPLETE aggregate: every session
            // must chain to a project row in this scope (no foreign session),
            // and a non-empty aggregate must expose that project row.
            val projectIDs = HashSet<String>()
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: refuse()
                if (requiredString(row, "kind") == "project") projectIDs.add(requiredString(row, "id"))
            }
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: refuse()
                if (requiredString(row, "kind") == "session" &&
                    requiredString(row, "parentID") !in projectIDs
                ) {
                    refuse()
                }
            }
            if (rows.length() > 0 && projectIDs.isEmpty()) refuse()
        }

        val result = JSONObject()
            .put("baseRevision", baseRevision)
            .put("environments", rows)
        if (projectID != null) {
            val resolvedProject = echoProjectID
            val resolvedOwner = echoOwnerID
            if (resolvedProject == null || resolvedOwner == null) refuse()
            result.put("projectID", resolvedProject)
                .put("workspaceOwnerID", resolvedOwner)
        }
        // The EXISTING bounded runtime reply envelope stays authoritative:
        // a complete catalog that cannot fit fails explicitly; it is never
        // silently cut down to a "successful" partial list.
        if (result.toString().toByteArray(Charsets.UTF_8).size > maximumResultBytes) {
            throw RuntimeAuthorityRefusal("replyTooLarge")
        }
        return result
    }

    private fun refuse(): Nothing = throw RuntimeAuthorityRefusal("invalidWire")

    /** Strict JSON types: a numeric/object value never coerces into a field. */
    private fun requiredString(page: JSONObject, key: String): String =
        stringOrNull(page, key) ?: refuse()

    private fun stringOrNull(page: JSONObject, key: String): String? {
        val value = page.opt(key) ?: return null
        if (value === JSONObject.NULL) return null
        return value as? String ?: refuse()
    }

    private fun requiredInt(page: JSONObject, key: String): Int =
        when (val value = page.opt(key)) {
            is Int -> value
            is Long -> value.toInt().takeIf { it.toLong() == value } ?: refuse()
            is Short -> value.toInt()
            else -> refuse()
        }

    private inline fun <T> guardPage(block: () -> T): T =
        try {
            block()
        } catch (refusal: RuntimeAuthorityRefusal) {
            throw refusal
        } catch (_: JSONException) {
            refuse()
        }

    internal companion object {
        /** Native `listPage` bound; the reader also uses it as its page size. */
        const val MAXIMUM_PAGE_LIMIT = 200
        const val DEFAULT_PAGE_LIMIT = MAXIMUM_PAGE_LIMIT
        /** Loop guard only; the byte/envelope bounds bind far earlier. */
        const val DEFAULT_MAXIMUM_PAGES = 64
        /** Matches the strict App catalog parser's own row ceiling. */
        const val DEFAULT_MAXIMUM_ROWS = 2048
        /** Binder reply envelope (`{version,id,ok,result}`) headroom. */
        const val ENVELOPE_RESERVE_BYTES = 512
        const val MAXIMUM_CURSOR_CHARS = 96
        const val MAXIMUM_BASE_REVISION_CHARS = 64

        private val HEX64 = Regex("^[0-9a-f]{64}$")
        private val IDENTIFIER = Regex("^[A-Za-z0-9._-]{1,128}$")
    }
}
