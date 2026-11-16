// SPDX-License-Identifier: MPL-2.0
package com.floe.android.host

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import org.junit.Assert.*
import org.junit.Test

class BrowserTabProjectionDecodeTest {
    private val first = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private val second = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private fun row(id: String, title: String = "", active: String = "false") =
        """{"id":"$id","url":"","title":"$title","isActive":$active}"""
    private fun decode(value: String) = decodeBrowserTabRows(Json.parseToJsonElement(value))

    @Test fun completeListKeepsTheNativeOrderAndEmptyListsRemainEmpty() {
        assertTrue(decodeBrowserTabRows(null)!!.isEmpty())
        assertTrue(decodeBrowserTabRows(JsonNull)!!.isEmpty())
        assertTrue(decode("[]")!!.isEmpty())
        val tabs = requireNotNull(decode("[${row(second, "Second")},${row(first, "First", "true")}]"))
        assertEquals(listOf(second, first), tabs.map { it.id })
        assertEquals(listOf("Second", "First"), tabs.map { it.title })
        assertEquals(listOf(false, true), tabs.map { it.isActive })
    }

    @Test fun partialOrDuplicateEntriesNeverShiftTheVisibleOrdinals() {
        val good = row(first)
        for (invalid in listOf(
            "[$good,{},${row(second)}]",
            "[$good,${row(first.uppercase())}]",
            "[$good,${row("not-a-uuid")} ]",
            "[$good,{\"id\":\"$second\",\"url\":\"\",\"isActive\":false}]",
            "[$good,${row(second, active = "\"false\"")}]",
            "[$good,null]",
            "{}",
        )) assertNull(decode(invalid))
        assertEquals(listOf(first, second), requireNotNull(decode("[$good,${row(second)}]")).map { it.id })
    }
}
