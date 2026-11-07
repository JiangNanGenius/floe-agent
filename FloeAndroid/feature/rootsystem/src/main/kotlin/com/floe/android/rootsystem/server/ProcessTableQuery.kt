// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.ProcessRecord
import com.floe.android.rootsystem.ipc.BinderProtocol

/** Parses already byte-bounded command output. Binder limits apply after
 * filtering, so a later process cannot disappear behind unrelated rows. */
internal object ProcessTableQuery {
    private val row = Regex("""^(\d+)\s+(\d+)\s+(.+)$""")

    fun parse(output: String): List<ProcessRecord> = output.lineSequence().mapNotNull { line ->
        val match = row.matchEntire(line.trim()) ?: return@mapNotNull null
        val pid = match.groupValues[1].toIntOrNull() ?: return@mapNotNull null
        val uid = match.groupValues[2].toIntOrNull() ?: return@mapNotNull null
        val name = match.groupValues[3].trim()
        if (name.isEmpty()) null else ProcessRecord(pid, uid, name.take(BinderProtocol.MAX_NAME))
    }.toList()

    fun select(records: List<ProcessRecord>, filter: String?, maxEntries: Int): List<ProcessRecord> {
        val needle = filter?.take(BinderProtocol.MAX_TEXT)?.lowercase()
        return records.asSequence()
            .filter { needle == null || it.name.lowercase().contains(needle) || it.pid.toString() == needle }
            .take(maxEntries.coerceIn(1, BinderProtocol.MAX_LIST))
            .toList()
    }
}
