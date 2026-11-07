// SPDX-License-Identifier: MPL-2.0
package com.floe.android.rootsystem.server

import com.floe.android.rootsystem.ProcessRecord
import com.floe.android.rootsystem.ipc.BinderProtocol
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessTableQueryTest {
    private val calculator = ProcessRecord(7001, 10272, "com.sec.android.app.popupcalculator")

    private fun table(): String = buildString {
        append("  PID UID NAME\n")
        repeat(BinderProtocol.MAX_LIST + 20) { index ->
            append("${index + 1} 0 kernel_$index\n")
        }
        append("${calculator.pid} ${calculator.uid} ${calculator.name}\n")
    }

    @Test
    fun matchingProcessAfterTheBinderLimitIsReturned() {
        val records = ProcessTableQuery.parse(table())
        assertEquals(
            listOf(calculator),
            ProcessTableQuery.select(records, calculator.name, 20),
        )
        // Package running-state lookup also needs UIDs from the full bounded table.
        assertTrue(calculator.uid in records.map { it.uid })
    }

    @Test
    fun numericAndCaseInsensitiveFiltersUseTheSameCompleteTable() {
        val records = ProcessTableQuery.parse(table())
        assertEquals(listOf(calculator), ProcessTableQuery.select(records, "7001", 1))
        assertEquals(listOf(calculator), ProcessTableQuery.select(records, "POPUPCALCULATOR", 1))
        assertTrue(ProcessTableQuery.select(records, "not-running", 20).isEmpty())
    }

    @Test
    fun replyRemainsBoundedAfterFiltering() {
        val records = ProcessTableQuery.parse(table()) + (1..600).map {
            ProcessRecord(8000 + it, 2000, "floe_worker_$it")
        }
        assertEquals(3, ProcessTableQuery.select(records, "floe_worker", 3).size)
        assertEquals(BinderProtocol.MAX_LIST, ProcessTableQuery.select(records, null, Int.MAX_VALUE).size)
    }

    @Test
    fun malformedRowsDoNotFabricateProcesses() {
        val records = ProcessTableQuery.parse(
            "PID UID NAME\nnot a process\n12 root wrong-uid\n999999999999 1000 overflow\n" +
                "  ${calculator.pid}   ${calculator.uid}   ${calculator.name}  \n",
        )
        assertEquals(listOf(calculator), records)
    }
}
