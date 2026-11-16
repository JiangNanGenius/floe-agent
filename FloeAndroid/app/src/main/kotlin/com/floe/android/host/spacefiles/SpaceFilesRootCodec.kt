// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.spacefiles

import com.floe.android.safgateway.SafUriRef
import org.json.JSONArray
import org.json.JSONObject

/**
 * Saved-root metadata codec.
 *
 * What is stored is ONLY: the exact `content://` tree string, its display
 * name and the time it was added. No permission bit, no document id, no
 * derived path and no "last known contents" is persisted — those would be a
 * stale second truth. Every open re-probes the OS grant.
 */
internal object SpaceFilesRootCodec {

    fun encode(roots: List<SpaceFilesRoot>): String {
        val array = JSONArray()
        roots.forEach { root ->
            array.put(
                JSONObject()
                    .put("uri", root.uri.uriString)
                    .put("name", root.name)
                    .put("savedAtMillis", root.savedAtMillis),
            )
        }
        return array.toString()
    }

    /** Malformed/foreign rows are dropped, never guessed. */
    fun decode(raw: String?): List<SpaceFilesRoot> {
        if (raw.isNullOrBlank()) return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val seen = HashSet<String>()
        val roots = ArrayList<SpaceFilesRoot>(array.length())
        for (index in 0 until array.length()) {
            val item = array.optJSONObject(index) ?: continue
            val uriString = item.optString("uri").takeIf { it.startsWith("content://") } ?: continue
            val uri = runCatching { SafUriRef(uriString) }.getOrNull() ?: continue
            if (!seen.add(uri.uriString)) continue
            roots += SpaceFilesRoot(
                uri = uri,
                name = item.optString("name"),
                savedAtMillis = item.optLong("savedAtMillis", 0L),
            )
        }
        return roots
    }
}
