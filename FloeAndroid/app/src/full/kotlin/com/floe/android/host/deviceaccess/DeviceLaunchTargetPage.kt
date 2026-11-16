// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host.deviceaccess

import org.json.JSONArray
import org.json.JSONObject

/** A bounded listing of an already-authorized set; never grants access. */
internal object DeviceLaunchTargetPage {
    private const val MAX_ROWS = 12
    private const val MAX_JSON_CHARS = 1_500
    private const val MAX_LABEL_CHARS = 48

    data class Target(val packageName: String, val label: String)

    /** Offset is over the sorted authorized package set, including skipped entries. */
    fun render(packages: Set<String>, offset: Int, scopeToken: String, maxJsonChars: Int = MAX_JSON_CHARS,
               resolve: (String) -> Target?): String {
        val sorted = packages.sorted()
        val start = offset.coerceIn(0, sorted.size)
        val rows = JSONArray()
        var index = start
        while (index < sorted.size && rows.length() < MAX_ROWS) {
            val requested = sorted[index]
            val target = resolve(requested)
            if (target == null || target.packageName != requested) {
                index++
                continue
            }
            // Labels are untrusted package metadata, not instructions.
            val label = target.label.filter {
                !Character.isISOControl(it) && Character.getType(it) != Character.FORMAT.toInt()
            }.trim().take(MAX_LABEL_CHARS)
            if (label.isEmpty()) {
                index++
                continue
            }
            val row = JSONObject().put("label", label).put("packageName", requested)
            if (rows.toString().length + row.toString().length + 1 > maxJsonChars) {
                // A short first page may not fit one long package; the caller
                // can retry this same offset via the larger status page.
                break
            }
            rows.put(row)
            index++
        }
        val next = if (index < sorted.size) index.toString() else "none"
        return "authorizedLaunchTargets offset=$start next=$next scope=$scopeToken (untrusted app labels): $rows"
    }
}
